-- SYNC_ALLOWED_ACCOUNTS, invite-only Sync (docs/limits.md#sync_allowed_accounts), and the
-- recount of the nodes' load: applied by db_init.sh after db_init.sql, every start, as the
-- owner of the Sync tables, in one transaction. db_init.sh appends the statements of the
-- setting: the list, on or off, and the trigger, which exists only while the allowlist is on.

-- the account ids (the uid of a Mozilla account, the part before the @ of the tokenserver's
-- email) that may start to sync
CREATE TABLE IF NOT EXISTS sync_allowed_accounts (
    uid VARCHAR(32) PRIMARY KEY,
    note VARCHAR(255) NOT NULL DEFAULT '',
    added_at BIGINT NOT NULL,
    added_by VARCHAR(255) NOT NULL
);

-- the accounts refused, the pending ones of the admin UI (rejected_at: rejected there)
CREATE TABLE IF NOT EXISTS sync_refused_accounts (
    uid VARCHAR(64) PRIMARY KEY,
    first_at BIGINT NOT NULL,
    last_at BIGINT NOT NULL,
    attempts INT NOT NULL DEFAULT 1,
    rejected_at BIGINT,
    rejected_by VARCHAR(255),
    -- named in the admin UI's event of it: a second pass finds it written (no second alert)
    id BIGSERIAL,
    -- the admin UI's event of it written
    reported_at BIGINT
);

-- a table of before (6356fcd, which had no allowed_accounts_initial): its initial: uids, if
-- any, were added then, not again; and its columns since
INSERT INTO config (config_key, config_value)
SELECT 'allowed_accounts_initial', 'applied'
WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = current_schema()
                  AND table_name = 'sync_refused_accounts' AND column_name = 'reported_at')
  AND EXISTS (SELECT 1 FROM sync_allowed_accounts)
ON CONFLICT (config_key) DO NOTHING;
ALTER TABLE sync_refused_accounts ADD COLUMN IF NOT EXISTS reported_at BIGINT;
ALTER TABLE sync_refused_accounts ADD COLUMN IF NOT EXISTS id BIGSERIAL;

-- The function of the trigger before_insert_allowed_user, which fires before before_insert_user
-- (SYNC_MAX_USERS: triggers fire in the order of their names): an account not on the list is
-- refused whether or not there is room. The row is skipped (RETURN NULL, the later triggers do
-- not run) rather than an error, so that its record in sync_refused_accounts is kept. The
-- tokenserver then finds no new row: its post_user (tokenserver-postgres/src/db/db_impl.rs,
-- "INSERT INTO users ... RETURNING uid" read with get_result) fails with NotFound, and the
-- request with a 5xx; were upstream to read the result otherwise, a refused account could
-- get a token: tests/test_sync_allowlist.py checks the status. At most 1000 accounts are
-- kept: a new one takes the place of the oldest pending one whose event the admin UI wrote
-- (never a rejected one, never one not reported yet); when there is none, it is refused
-- without a record, counted in the row '*dropped*' (no uid), which the admin UI shows. An email that has a row already is no new account (a keys change adds a row for
-- it, as do the accounts from before the allowlist): never refused here.
-- 'allowed_accounts' not 'on' (or no row): off, everyone gets in.
CREATE OR REPLACE FUNCTION ffs_check_allowed_account() RETURNS trigger AS $$
DECLARE
    account VARCHAR(255);
    now_ms BIGINT;
    keep BOOLEAN;
BEGIN
    IF EXISTS (SELECT 1 FROM config WHERE config_key = 'allowed_accounts' AND config_value = 'on')
       AND NOT EXISTS (SELECT 1 FROM users WHERE email = NEW.email) THEN
        account := lower(split_part(NEW.email, '@', 1));
        IF NOT EXISTS (SELECT 1 FROM sync_allowed_accounts WHERE uid = account) THEN
            now_ms := (EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::BIGINT;
            account := left(account, 64);
            keep := TRUE;
            IF NOT EXISTS (SELECT 1 FROM sync_refused_accounts WHERE uid = account)
               AND (SELECT COUNT(*) FROM sync_refused_accounts WHERE uid <> '*dropped*') >= 1000 THEN
                DELETE FROM sync_refused_accounts WHERE uid = (SELECT uid FROM sync_refused_accounts
                    WHERE uid <> '*dropped*' AND rejected_at IS NULL AND reported_at IS NOT NULL
                    ORDER BY last_at, uid LIMIT 1);
                IF NOT FOUND THEN
                    keep := FALSE;
                    INSERT INTO sync_refused_accounts (uid, first_at, last_at, attempts, reported_at)
                    VALUES ('*dropped*', now_ms, now_ms, 1, now_ms)
                    ON CONFLICT (uid) DO UPDATE SET last_at = EXCLUDED.last_at, attempts = sync_refused_accounts.attempts + 1;
                END IF;
            END IF;
            IF keep THEN
                INSERT INTO sync_refused_accounts (uid, first_at, last_at, attempts)
                VALUES (account, now_ms, now_ms, 1)
                ON CONFLICT (uid) DO UPDATE SET last_at = EXCLUDED.last_at, attempts = sync_refused_accounts.attempts + 1;
            END IF;
            RAISE WARNING 'Account % not on the allowlist (SYNC_ALLOWED_ACCOUNTS): refused', account;
            RETURN NULL;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- What the admin UI changes, with the privileges of the owner of the tables (db_init.sh
-- gives its role EXECUTE, admin_grants.sql; nobody else has it): with
-- SYNC_ALLOWED_ACCOUNTS=admin or initial: allow an account (Approve, Allow a uid), remove it
-- from the list, reject a pending one; and always: mark a refusal as alerted, recount the
-- load of a node
CREATE OR REPLACE FUNCTION ffs_allow_account(account TEXT, account_note TEXT, by_whom TEXT) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF account IS NULL OR lower(account) !~ '^[0-9a-f]{32}$' THEN
        RAISE EXCEPTION 'an account id is 32 hexadecimal characters';
    END IF;
    INSERT INTO sync_allowed_accounts (uid, note, added_at, added_by)
    VALUES (lower(account), COALESCE(left(account_note, 255), ''), (EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::BIGINT, left(by_whom, 255))
    ON CONFLICT (uid) DO UPDATE SET note = EXCLUDED.note;
    DELETE FROM sync_refused_accounts WHERE uid = lower(account);
END;
$$;
REVOKE ALL ON FUNCTION ffs_allow_account(TEXT, TEXT, TEXT) FROM PUBLIC;

CREATE OR REPLACE FUNCTION ffs_remove_allowed_account(account TEXT) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    DELETE FROM sync_allowed_accounts WHERE uid = lower(account);
END;
$$;
REVOKE ALL ON FUNCTION ffs_remove_allowed_account(TEXT) FROM PUBLIC;

CREATE OR REPLACE FUNCTION ffs_reject_account(account TEXT, by_whom TEXT) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    UPDATE sync_refused_accounts
    SET rejected_at = (EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::BIGINT, rejected_by = left(by_whom, 255)
    WHERE uid = lower(account) AND rejected_at IS NULL;
END;
$$;
REVOKE ALL ON FUNCTION ffs_reject_account(TEXT, TEXT) FROM PUBLIC;

-- the admin UI's event of a refusal is written: no second one, after a restart neither
CREATE OR REPLACE FUNCTION ffs_mark_refusal_reported(account TEXT) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    UPDATE sync_refused_accounts SET reported_at = (EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::BIGINT
    WHERE uid = account AND reported_at IS NULL;
END;
$$;
REVOKE ALL ON FUNCTION ffs_mark_refusal_reported(TEXT) FROM PUBLIC;

-- The load of the nodes of sync-1.5 counted again from their accounts: the tokenserver adds one
-- to current_load (and takes one from available) before it inserts a new account's row
-- (allocate_user: add_user_to_node, then post_user, each on its own), and nothing takes it
-- back when the INSERT is refused, by the allowlist or by SYNC_MAX_USERS: every refused try
-- would fill the node a little more. The load is the accounts assigned to the node: its
-- emails with a row that is not replaced, as the tokenserver counts one per allocation (a
-- keys change adds a row, not a load). What was counted too much goes back to available
-- (within capacity), on the nodes in use. node_url: that node only (with or without a trailing
-- /, as SYNC_PUBLIC_URL may have it); NULL: every node (the init container, at every start).
-- A recount between the tokenserver's add_user_to_node and its INSERT does not see that account
-- yet: the load is one low until the next recount (minutes), harmless at any real capacity.
-- The tokenserver takes no lock this could wait for (each statement on its own), so it is not
-- tried: the next recount corrects it. (In the init container's transaction, the DROP TRIGGER
-- before it holds users' lock: the tokenserver's reads of users wait for that transaction.)
CREATE OR REPLACE FUNCTION ffs_resync_node_load(node_url TEXT) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    UPDATE nodes n
    SET available = CASE WHEN n.downed = 0
            THEN GREATEST(0, LEAST(n.available + GREATEST(n.current_load - r.real_load, 0), n.capacity - r.real_load))
            ELSE n.available END,
        current_load = r.real_load
    FROM (SELECT n2.id, COUNT(DISTINCT u.email)::INT AS real_load
          FROM nodes n2 JOIN services s ON s.service = 'sync-1.5' AND n2.service = s.id
          LEFT JOIN users u ON u.nodeid = n2.id AND u.replaced_at IS NULL
          GROUP BY n2.id) r
    WHERE r.id = n.id AND (node_url IS NULL OR TRIM(TRAILING '/' FROM n.node) = TRIM(TRAILING '/' FROM node_url)) AND n.current_load <> r.real_load;
END;
$$;
REVOKE ALL ON FUNCTION ffs_resync_node_load(TEXT) FROM PUBLIC;
