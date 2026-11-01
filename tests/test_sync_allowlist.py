"""Invite-only Sync (SYNC_ALLOWED_ACCOUNTS, docs/limits.md#sync_allowed_accounts) through the
tokenserver, with the mock FxA (whose accounts have the uids chosen here), and the admin UI.

Runs in the syncstorage-rs image like test_admin_sync.py, see tests/e2e.sh: the stack has
SYNC_ALLOWED_ACCOUNTS=initial:<LISTED> and max users unlimited. tests/e2e.sh runs -k
sync_while_off first, with the allowlist off (an account from before it), -k read_only
at the end with a plain list (read-only in the admin UI), and the rest between them.
Environment: as test_admin_sync.py.
"""

import os
import re
import time

import pytest
import requests
from sqlalchemy.sql import text as sqltext

from test_admin_sync import ADMIN, METRICS_TOKEN, Admin, admin_db  # noqa: F401 (admin_db is a fixture)
from test_client_flow import EMAIL_DOMAIN, Storage, db, login  # noqa: F401 (db is a fixture)

# the uids of the tests (tests/e2e.sh gives LISTED to SYNC_ALLOWED_ACCOUNTS)
LISTED = "a1" * 16
UNLISTED = "b2" * 16
REJECTED = "c3" * 16
BY_HAND = "d4" * 16
WHILE_FULL = "e5" * 16
LISTED_FULL = "f6" * 16
# synced before the allowlist was on
OLD = "09" * 16
# allowed after the refused tries of test_refused_tries_leave_the_node_load
NODE_UID = "7e" * 16
# refused while the list of pending ones is full
FULL_LIST = "8f" * 16


@pytest.fixture(scope="module")
def recorded(db):
    """the refusals are recorded (pending): Aria (MariaDB), MyISAM (the stack's MySQL), not in
    InnoDB (your own MySQL with binary logging), see db/mysql/init/db_init.sh"""
    if os.environ["BACKEND"] != "mysql":
        return True
    engine = db.execute(sqltext("SELECT engine FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'sync_refused_accounts'")).scalar()
    return engine.lower() != "innodb"


def rows(db, uid):
    return db.execute(sqltext("SELECT COUNT(*) FROM users WHERE email = :e"), {"e": f"{uid}@{EMAIL_DOMAIN}"}).scalar()


def refused(db, uid):
    """attempts and rejected of the account's refusal, None without one"""
    row = db.execute(sqltext("SELECT attempts, rejected_at IS NOT NULL FROM sync_refused_accounts WHERE uid = :u"), {"u": uid}).first()
    return None if row is None else (row[0], bool(row[1]))


def refusal_events(admin_db, uid):
    return admin_db.execute(sqltext("SELECT COUNT(*) FROM ffs_events WHERE kind = 'sign-up refused' AND detail LIKE :d"),
                            {"d": f"Sync: account {uid} is not on the allowlist%"}).scalar()


def until(check, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if check():
            return True
        time.sleep(1)
    return False


def table_of(page, name):
    m = re.search(rf'<table id="{name}"[^>]*>(.*?)</table>', page, re.S)
    return m.group(1) if m else ""


def metrics():
    return requests.get(f"{ADMIN}/metrics", headers={"Authorization": f"Bearer {METRICS_TOKEN}"}, timeout=30).text


# what the tokenserver answers a refused account, an internal error: the database error of the
# trigger's SIGNAL, with PostgreSQL the row it does not find (see db/postgres/init/allowlist.sql)
REFUSED = 500


def refused_login(uid, **token):
    res = login(uid, **token)
    assert res.status_code == REFUSED, (res.status_code, res.text)
    return res


def node_load(db):
    """current_load of the stack's node, and the accounts it has"""
    return tuple(db.execute(sqltext("""SELECT n.current_load,
        (SELECT COUNT(DISTINCT u.email) FROM users u WHERE u.nodeid = n.id AND u.replaced_at IS NULL)
        FROM nodes n JOIN services s ON n.service = s.id WHERE s.service = 'sync-1.5' AND TRIM(TRAILING '/' FROM n.node) = :node"""),
        {"node": os.environ["SYNC_PUBLIC_URL"].rstrip("/")}).first())


def sync_now(uid, **token):
    """a token, and a write with it: the account syncs"""
    res = login(uid, **token)
    assert res.status_code == 200, res.text
    storage = Storage(res.json())
    res = storage.request("PUT", "/storage/meta/global", {"id": "global", "payload": "{}"})
    assert res.status_code == 200, res.text


@pytest.fixture(scope="module")
def admin():
    return Admin()


def test_listed_uid_syncs(db):
    sync_now(LISTED)
    assert rows(db, LISTED) == 1 and refused(db, LISTED) is None


def test_unlisted_uid_refused_and_pending(db, admin, admin_db, recorded):
    for _ in range(2):
        refused_login(UNLISTED)
    assert rows(db, UNLISTED) == 0
    if not recorded:
        assert refused(db, UNLISTED) is None and "ffs_sync_pending_accounts 0\n" in metrics()
        return
    assert refused(db, UNLISTED) == (2, False)
    # the event of its first refusal, once (sign-up refused, alerted)
    assert until(lambda: refusal_events(admin_db, UNLISTED) == 1)
    page = admin.get("/")
    pending = table_of(page, "sync-pending")
    assert f'<tr data-uid="{UNLISTED}">' in pending and f'href="/sync/allowlist/allow?uid={UNLISTED}"' in pending, page[:5000]
    assert "1 account waiting for your approval to sync (SYNC_ALLOWED_ACCOUNTS)." in page
    assert "ffs_sync_pending_accounts 1\n" in metrics()
    assert refusal_events(admin_db, UNLISTED) == 1


def test_approve_lets_the_next_try_through(db, admin, admin_db, recorded):
    page, done = admin.confirm(f"/sync/allowlist/allow?uid={UNLISTED}", reason="my sister")
    assert "This account can start to sync" in page
    if not recorded:
        # not pending: allowed by its uid (Allow a uid)
        assert f"Allowed Sync account {UNLISTED}" in done
        sync_now(UNLISTED)
        return
    assert "It was refused 2 times" in page and f"Approved Sync account {UNLISTED}" in done
    assert refused(db, UNLISTED) is None
    sync_now(UNLISTED)
    assert rows(db, UNLISTED) == 1
    assert f'<tr data-uid="{UNLISTED}">' in table_of(admin.get("/"), "sync-allowed")
    assert admin_db.execute(sqltext("SELECT COUNT(*) FROM ffs_events WHERE kind = 'admin' AND detail = :d"),
                            {"d": f"Approved Sync account {UNLISTED} by admin (password): my sister"}).scalar() == 1
    assert "ffs_sync_pending_accounts 0\n" in metrics()


def test_keys_change_of_an_allowed_account(db):
    # a password reset: new keys, a new row for the same email, which the trigger lets in
    time.sleep(1.1)
    now = int(time.time())
    sync_now(LISTED, generation=now, keys_changed_at=now, client_state="bbbb")
    assert rows(db, LISTED) == 2


def test_sync_while_off(db):
    # with the allowlist off: an account like any other
    sync_now(OLD)
    assert rows(db, OLD) == 1


def test_an_account_from_before_the_allowlist_keeps_working(db):
    # synced before the allowlist was on, not on it: it still syncs, and changes its keys
    assert rows(db, OLD) == 1 and refused(db, OLD) is None
    time.sleep(1.1)
    now = int(time.time())
    sync_now(OLD, generation=now, keys_changed_at=now, client_state="bbbb")
    assert rows(db, OLD) == 2 and refused(db, OLD) is None


def test_reject(db, admin, admin_db, recorded):
    if not recorded:
        pytest.skip("no pending accounts on this server")
    refused_login(REJECTED)
    assert until(lambda: refusal_events(admin_db, REJECTED) == 1)
    page, done = admin.confirm(f"/sync/allowlist/reject?uid={REJECTED}")
    assert "It stays refused" in page and f"Rejected Sync account {REJECTED}" in done
    assert refused(db, REJECTED) == (1, True)
    page = admin.get("/")
    assert f'data-uid="{REJECTED}"' not in table_of(page, "sync-pending") and f'<tr data-uid="{REJECTED}">' in table_of(page, "sync-rejected")
    # refused again, counted, no new event
    refused_login(REJECTED)
    assert refused(db, REJECTED) == (2, True)
    time.sleep(6)
    assert refusal_events(admin_db, REJECTED) == 1


def test_allow_a_uid_and_remove_it(db, admin):
    page, done = admin.confirm(f"/sync/allowlist/allow?uid={BY_HAND.upper()}&note=Bob%27s+laptop")
    assert "Its note on the list: Bob&#39;s laptop" in page and f"Allowed Sync account {BY_HAND}" in done
    allowed = table_of(admin.get("/"), "sync-allowed")
    assert re.search(rf'<tr data-uid="{BY_HAND}"><td><code>{BY_HAND}</code> <span class="quiet-text">not synced yet</span></td><td>[^<]* by admin \(password\)</td><td>Bob&#39;s laptop</td>', allowed), allowed
    sync_now(BY_HAND)
    page, done = admin.confirm(f"/sync/allowlist/remove?uid={BY_HAND}")
    assert "If it syncs already, it keeps working" in page and f"Removed Sync account {BY_HAND} from the allowlist" in done
    assert f'data-uid="{BY_HAND}"' not in table_of(done, "sync-allowed")
    # it has its rows: it keeps syncing
    sync_now(BY_HAND)
    # a uid that is not one: refused by the form, nothing listed
    res = admin.http.get(f"{ADMIN}/sync/allowlist/allow?uid=bob", timeout=30)
    assert "an account id is 32 hexadecimal characters" in res.text


def test_with_max_users(db, admin, recorded):
    # the allowlist first, then max users: full, an unlisted account is refused by the
    # allowlist (pending), a listed one by max users (not pending: it is allowed already)
    admin.confirm(f"/sync/allowlist/allow?uid={LISTED_FULL}")
    full = db.execute(sqltext("SELECT COUNT(DISTINCT email) FROM users")).scalar()
    db.execute(sqltext("UPDATE config SET config_value = :v WHERE config_key = 'max_users'"), {"v": str(full)})
    try:
        refused_login(WHILE_FULL)
        assert refused(db, WHILE_FULL) == ((1, False) if recorded else None)
        refused_login(LISTED_FULL)
        assert refused(db, LISTED_FULL) is None and rows(db, LISTED_FULL) == 0
        # an account already here still changes its keys
        time.sleep(1.1)
        now = int(time.time())
        sync_now(LISTED, generation=now, keys_changed_at=now, client_state="cccc")
        # room again: the listed one gets in, the other is still refused
        db.execute(sqltext("UPDATE config SET config_value = :v WHERE config_key = 'max_users'"), {"v": str(full + 1)})
        refused_login(WHILE_FULL)
        assert refused(db, WHILE_FULL) == ((2, False) if recorded else None)
        sync_now(LISTED_FULL)
    finally:
        db.execute(sqltext("UPDATE config SET config_value = 'unlimited' WHERE config_key = 'max_users'"))


def test_refused_tries_leave_the_node_load(db, admin):
    # every refused try adds one to the node's load (the tokenserver counts it before the
    # INSERT the trigger refuses): the admin UI counts it again, at once from 10 off (which also
    # takes back the tries of the tests before), and says so in the setup checks; an allowed
    # account still gets the node
    accounts = node_load(db)[1]
    for i in range(12):
        refused_login(f"5{i:x}" * 16)
    assert until(lambda: node_load(db) == (accounts, accounts)), (node_load(db), accounts)
    page = admin.get("/")
    assert "<td>Sync node load</td><td><span class=\"pill warn\">warning</span>" in page and page.count("<td>Sync node load</td>") == 1
    admin.confirm(f"/sync/allowlist/allow?uid={NODE_UID}")
    sync_now(NODE_UID)
    assert rows(db, NODE_UID) == 1 and node_load(db) == (accounts + 1, accounts + 1)


def test_cap_of_the_pending_list(db, admin, recorded):
    # 1000 accounts kept: a new one takes the place of the oldest pending one already alerted,
    # never of a rejected one or one not alerted yet; with none to let go it is refused without
    # a record, counted, and the admin UI says so
    if not recorded:
        pytest.skip("no pending accounts on this server")
    # (the pending ones of the tests before, alerted: rejected for the length of this one, so that
    # only its own rows can go)
    pending = [r[0] for r in db.execute(sqltext("SELECT uid FROM sync_refused_accounts WHERE uid <> '*dropped*' AND rejected_at IS NULL"))]
    db.execute(sqltext("UPDATE sync_refused_accounts SET rejected_at = 1 WHERE uid <> '*dropped*' AND rejected_at IS NULL"))
    kept = db.execute(sqltext("SELECT COUNT(*) FROM sync_refused_accounts WHERE uid <> '*dropped*'")).scalar()
    fill = [{"u": f"cap{i:04d}", "t": 1000 + i} for i in range(1000 - kept)]
    db.execute(sqltext("INSERT INTO sync_refused_accounts (uid, first_at, last_at, attempts, rejected_at, rejected_by, reported_at) "
                       "VALUES (:u, :t, :t, 1, :t, 'test', :t)"), fill)
    try:
        refused_login(FULL_LIST)
        assert refused(db, FULL_LIST) is None
        assert db.execute(sqltext("SELECT attempts FROM sync_refused_accounts WHERE uid = '*dropped*'")).scalar() == 1
        page = admin.get("/")
        assert "<td>Pending accounts list</td><td><span class=\"pill warn\">warning</span></td><td>1 account refused without a record" in page, page[:5000]
        assert "ffs_sync_refusals_dropped 1\n" in metrics()
        # the oldest pending one already alerted goes, the rejected ones stay
        db.execute(sqltext("UPDATE sync_refused_accounts SET rejected_at = NULL WHERE uid IN ('cap0000', 'cap0001')"))
        refused_login(FULL_LIST)
        assert refused(db, FULL_LIST) == (1, False)
        assert db.execute(sqltext("SELECT uid FROM sync_refused_accounts WHERE uid IN ('cap0000', 'cap0001')")).scalar() == "cap0001"
        assert db.execute(sqltext("SELECT COUNT(*) FROM sync_refused_accounts WHERE uid <> '*dropped*'")).scalar() == 1000
    finally:
        db.execute(sqltext("DELETE FROM sync_refused_accounts WHERE uid LIKE 'cap%' OR uid IN ('*dropped*', :u)"), {"u": FULL_LIST})
        for uid in pending:
            db.execute(sqltext("UPDATE sync_refused_accounts SET rejected_at = NULL WHERE uid = :u"), {"u": uid})


def test_read_only(db, recorded):
    # SYNC_ALLOWED_ACCOUNTS=<uids>: the list of .env, no Approve, Allow or Remove; Reject works
    admin = Admin()
    page = admin.get("/")
    assert "<code>SYNC_ALLOWED_ACCOUNTS</code> in .env sets the list on every start" in page, page[:5000]
    assert 'id="allow-uid"' not in page and "/sync/allowlist/remove?" not in page and "/sync/allowlist/allow?" not in page
    csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', page).group(1)
    res = admin.http.post(f"{ADMIN}/sync/allowlist/allow", data={"csrf": csrf, "uid": WHILE_FULL}, timeout=30)
    assert "the allowlist is managed by SYNC_ALLOWED_ACCOUNTS in .env" in res.text, res.text[:3000]
    assert rows(db, WHILE_FULL) == 0
    if not recorded:
        return
    assert f'<tr data-uid="{WHILE_FULL}">' in table_of(page, "sync-pending") and refused(db, WHILE_FULL)[1] is False
    page, done = admin.confirm(f"/sync/allowlist/reject?uid={WHILE_FULL}")
    assert f"Rejected Sync account {WHILE_FULL}" in done and refused(db, WHILE_FULL)[1] is True
