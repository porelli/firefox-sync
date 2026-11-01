-- SYNC_ALLOWED_ACCOUNTS, invite-only Sync (docs/limits.md#sync_allowed_accounts), and the
-- recount of the nodes' load: applied by db_init.sh after db_init.sql, every start. db_init.sh
-- creates sync_refused_accounts first (its engine depends on the server), and appends the
-- statements of the setting: the list, on or off, and the trigger, which exists only while
-- the allowlist is on.

-- the account ids (the uid of a Mozilla account, the part before the @ of the tokenserver's
-- email) that may start to sync
CREATE TABLE IF NOT EXISTS sync_allowed_accounts (
    uid VARCHAR(32) PRIMARY KEY,
    note VARCHAR(255) NOT NULL DEFAULT '',
    added_at BIGINT NOT NULL,
    added_by VARCHAR(255) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Called by the trigger BeforeInsertAllowedUser, before BeforeInsertUser (SYNC_MAX_USERS): an
-- account not on the list is refused whether or not there is room, and recorded in
-- sync_refused_accounts, where the admin UI shows it as pending. That table is Aria (MariaDB)
-- or MyISAM (MySQL) where it can be (db_init.sh): its row stays when SIGNAL undoes the INSERT
-- into users. An email that has a row already is no new account (a keys change adds a row for
-- it, as do the accounts from before the allowlist): never refused here. At most 1000 accounts
-- are kept: a new one takes the place of the oldest pending one whose event the admin UI wrote
-- (never a rejected one, never one not reported yet); when there is none, it is refused
-- without a record, counted in the row '*dropped*' (no uid: 32 hexadecimal characters), which
-- the admin UI shows. 'allowed_accounts' not 'on' (or no row): everyone gets in.
-- (While this is replaced at a start, the trigger finds no procedure: an INSERT fails then,
-- it is never let in unchecked.)
DROP PROCEDURE IF EXISTS ffs_check_allowed_account;

DELIMITER //
CREATE PROCEDURE ffs_check_allowed_account(IN new_email VARCHAR(255))
BEGIN
    DECLARE account VARCHAR(255);
    DECLARE now_ms BIGINT;
    DECLARE keep INT;

    IF EXISTS (SELECT 1 FROM config WHERE config_key = 'allowed_accounts' AND config_value = 'on')
       AND NOT EXISTS (SELECT 1 FROM users WHERE email = new_email) THEN
        SET account = LOWER(SUBSTRING_INDEX(new_email, '@', 1));
        IF NOT EXISTS (SELECT 1 FROM sync_allowed_accounts WHERE uid = account) THEN
            SET now_ms = CAST(UNIX_TIMESTAMP(CURRENT_TIMESTAMP(3)) * 1000 AS SIGNED);
            SET account = LEFT(account, 64);
            SET keep = 1;
            IF NOT EXISTS (SELECT 1 FROM sync_refused_accounts WHERE uid = account)
               AND (SELECT COUNT(*) FROM sync_refused_accounts WHERE uid <> '*dropped*') >= 1000 THEN
                DELETE FROM sync_refused_accounts
                WHERE uid <> '*dropped*' AND rejected_at IS NULL AND reported_at IS NOT NULL
                ORDER BY last_at, uid LIMIT 1;
                IF ROW_COUNT() = 0 THEN
                    SET keep = 0;
                    INSERT INTO sync_refused_accounts (uid, first_at, last_at, attempts, reported_at)
                    VALUES ('*dropped*', now_ms, now_ms, 1, now_ms)
                    ON DUPLICATE KEY UPDATE last_at = now_ms, attempts = attempts + 1;
                END IF;
            END IF;
            IF keep = 1 THEN
                INSERT INTO sync_refused_accounts (uid, first_at, last_at, attempts)
                VALUES (account, now_ms, now_ms, 1)
                ON DUPLICATE KEY UPDATE last_at = now_ms, attempts = attempts + 1;
            END IF;
            SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Account not on the allowlist (SYNC_ALLOWED_ACCOUNTS)';
        END IF;
    END IF;
END //
DELIMITER ;

-- What the admin UI changes, with the privileges of this user (its own has SELECT and
-- EXECUTE here, see db/mysql/admin-user.sh): with SYNC_ALLOWED_ACCOUNTS=admin or initial:
-- allow an account (Approve, Allow a uid), remove it from the list, reject a pending one;
-- and always: mark a refusal as alerted, recount the load of a node
DROP PROCEDURE IF EXISTS ffs_allow_account;

DELIMITER //
CREATE PROCEDURE ffs_allow_account(IN account VARCHAR(64), IN account_note VARCHAR(255), IN by_whom VARCHAR(255))
BEGIN
    IF account IS NULL OR LOWER(account) NOT REGEXP '^[0-9a-f]{32}$' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'an account id is 32 hexadecimal characters';
    END IF;
    INSERT INTO sync_allowed_accounts (uid, note, added_at, added_by)
    VALUES (LOWER(account), COALESCE(account_note, ''), CAST(UNIX_TIMESTAMP(CURRENT_TIMESTAMP(3)) * 1000 AS SIGNED), by_whom)
    ON DUPLICATE KEY UPDATE note = VALUES(note);
    DELETE FROM sync_refused_accounts WHERE uid = LOWER(account);
END //
DELIMITER ;

DROP PROCEDURE IF EXISTS ffs_remove_allowed_account;

DELIMITER //
CREATE PROCEDURE ffs_remove_allowed_account(IN account VARCHAR(64))
BEGIN
    DELETE FROM sync_allowed_accounts WHERE uid = LOWER(account);
END //
DELIMITER ;

DROP PROCEDURE IF EXISTS ffs_reject_account;

DELIMITER //
CREATE PROCEDURE ffs_reject_account(IN account VARCHAR(64), IN by_whom VARCHAR(255))
BEGIN
    UPDATE sync_refused_accounts
    SET rejected_at = CAST(UNIX_TIMESTAMP(CURRENT_TIMESTAMP(3)) * 1000 AS SIGNED), rejected_by = by_whom
    WHERE uid = LOWER(account) AND rejected_at IS NULL;
END //
DELIMITER ;

-- the admin UI's event of a refusal is written: no second one, after a restart neither
DROP PROCEDURE IF EXISTS ffs_mark_refusal_reported;

DELIMITER //
CREATE PROCEDURE ffs_mark_refusal_reported(IN account VARCHAR(64))
BEGIN
    UPDATE sync_refused_accounts
    SET reported_at = CAST(UNIX_TIMESTAMP(CURRENT_TIMESTAMP(3)) * 1000 AS SIGNED)
    WHERE uid = account AND reported_at IS NULL;
END //
DELIMITER ;

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
-- tried: the next recount corrects it.
DROP PROCEDURE IF EXISTS ffs_resync_node_load;

DELIMITER //
CREATE PROCEDURE ffs_resync_node_load(IN node_url VARCHAR(255))
BEGIN
    START TRANSACTION;
    -- (two statements: MySQL does not say in which order a multi-table UPDATE assigns)
    UPDATE nodes n
    JOIN services s ON s.service = 'sync-1.5' AND n.service = s.id
    LEFT JOIN (SELECT nodeid, COUNT(DISTINCT email) AS real_load FROM users WHERE replaced_at IS NULL GROUP BY nodeid) u ON u.nodeid = n.id
    SET n.available = GREATEST(0, LEAST(n.available + GREATEST(n.current_load - COALESCE(u.real_load, 0), 0), n.capacity - COALESCE(u.real_load, 0)))
    WHERE (node_url IS NULL OR TRIM(TRAILING '/' FROM n.node) = TRIM(TRAILING '/' FROM node_url)) AND n.downed = 0 AND n.current_load <> COALESCE(u.real_load, 0);
    UPDATE nodes n
    JOIN services s ON s.service = 'sync-1.5' AND n.service = s.id
    LEFT JOIN (SELECT nodeid, COUNT(DISTINCT email) AS real_load FROM users WHERE replaced_at IS NULL GROUP BY nodeid) u ON u.nodeid = n.id
    SET n.current_load = COALESCE(u.real_load, 0)
    WHERE (node_url IS NULL OR TRIM(TRAILING '/' FROM n.node) = TRIM(TRAILING '/' FROM node_url)) AND n.current_load <> COALESCE(u.real_load, 0);
    COMMIT;
END //
DELIMITER ;
