"""Access managed elsewhere with the self-hosted accounts (ADMIN_ACCESS_EXTERNAL,
FXA_ACCESS_DB_PASSWORD, docs/admin/accounts.md#access-managed-elsewhere): another system keeps
the sign-up allowlist as ffs_access, and disables, enables or deletes accounts by email. The
admin UI's Enable and Delete leave who has access to that system.

Runs in the syncstorage-rs image like test_fxa_admin.py, see tests/e2e-fxa.sh, which starts
fxa-policy and the admin UI with ADMIN_ACCESS_EXTERNAL=1 and FXA_SIGNUPS=allowlist first.

Environment (besides those of test_fxa_admin.py):
  FXA_ACCESS_DB_URL  the accounts database as ffs_access (mysql://ffs_access:...@.../ffs)
  FXA_TEST_DB_URL    the accounts database as their own user, to check what changed
"""

import os
import time
import uuid

import pytest
import requests
from sqlalchemy import create_engine
from sqlalchemy.exc import DBAPIError
from sqlalchemy.sql import text as sqltext

from fxa.core import Client
from test_fxa_admin import ADMIN, Admin, create, exists, failed, mfa
from test_fxa_flow import AUTH, SYNC, authorize, storage, sync_token, wait_for_code

ADDRESS = f"ffs-external-{uuid.uuid4().hex[:10]}@example.org"
# left disabled and off the list: tests/e2e-fxa.sh enables it once the mode is off
LEFT = f"ffs-external-left-{uuid.uuid4().hex[:10]}@example.org"
MEMBER = f"ffs-external-member-{uuid.uuid4().hex[:10]}@example.org"
# ffs_access's sweep (externalOnlySQL of admin/fxainit.go), and its brake's SQLSTATE (errSweepBrake)
SWEEP = "ffs.disable_accounts_not_allowed"
BRAKE = "45001"
# ffs.enable_account's refusal (errAccessElsewhere of admin/fxainit.go)
ELSEWHERE = "not on the access list managed elsewhere: the system that manages access enables this account"
# the access tokens of an account disabled by ffs_access refused within this many seconds: the
# admin UI revokes the queue in Redis every 5 (revokeInterval of admin/revoke.go)
REVOKED_WITHIN = 30


def connect(url):
    return create_engine(url).execution_options(isolation_level="AUTOCOMMIT").connect()


@pytest.fixture(scope="module")
def access():
    conn = connect(os.environ["FXA_ACCESS_DB_URL"])
    yield conn
    conn.close()


@pytest.fixture(scope="module")
def fxa():
    conn = connect(os.environ["FXA_TEST_DB_URL"])
    yield conn
    conn.close()


def refused(conn, query):
    with pytest.raises(DBAPIError) as e:
        conn.execute(sqltext(query))
    return str(e.value.orig)


def test_access_user_grants(access):
    # the rows of the sign-up allowlist: read, add, remove
    access.execute(sqltext("SELECT COUNT(*) FROM ffs.signup_allowlist")).scalar()
    # nothing of the accounts, nor the settings, nor the admin UI's procedures
    for query in ("SELECT COUNT(*) FROM fxa.accounts", "SELECT value FROM ffs.settings", "UPDATE ffs.settings SET value = 'open' WHERE name = 'signups'",
                  "UPDATE ffs.signup_allowlist SET entry = 'x' WHERE entry = 'y'", "CALL ffs.sign_out_all(UNHEX('00'))",
                  "CALL ffs.disable_account(UNHEX('00'))", "SELECT COUNT(*) FROM ffs.emails",
                  # the queue of the access tokens to revoke is the admin UI's
                  "SELECT COUNT(*) FROM ffs.pending_revocations", "DELETE FROM ffs.pending_revocations"):
        assert "denied" in refused(access, query), query


def test_signup_refused_then_allowed(access):
    res = create(ADDRESS)
    assert res.status_code == 400 and res.json()["errno"] == 125, res.text
    access.execute(sqltext("INSERT INTO ffs.signup_allowlist (entry) VALUES (:e)"), {"e": ADDRESS})
    res = create(ADDRESS)
    assert res.status_code == 200, res.text
    assert exists(ADDRESS)


def disabled(fxa, address=ADDRESS):
    return fxa.execute(sqltext("SELECT disabledAt IS NOT NULL FROM fxa.accounts WHERE normalizedEmail = :e"), {"e": address}).scalar()


def listed(access, address):
    return access.execute(sqltext("SELECT COUNT(*) FROM ffs.signup_allowlist WHERE entry = :e"), {"e": address}).scalar()


def sessions(fxa):
    return fxa.execute(sqltext("SELECT COUNT(*) FROM fxa.sessionTokens s JOIN fxa.accounts a ON a.uid = s.uid WHERE a.normalizedEmail = :e"),
                       {"e": ADDRESS}).scalar()


def verify(token):
    """fxa-auth's /v1/verify, which the tokenserver asks for an access token it has not seen"""
    return requests.post(f"{AUTH}/v1/verify", json={"token": token}, timeout=30)


def tokenserver(bearer, key_id):
    return requests.get(f"{SYNC}/1.0/sync/1.5", headers={"Authorization": f"Bearer {bearer}", "X-KeyID": key_id}, timeout=30)


def queued(fxa, uid):
    return fxa.execute(sqltext("SELECT COUNT(*) FROM ffs.pending_revocations WHERE uid = UNHEX(:u)"), {"u": uid}).scalar()


def revoked(fxa, uid, tokens, within=REVOKED_WITHIN):
    """Every access token refused by fxa-auth's /v1/verify within `within` seconds, and the
    account no longer queued: how long it took"""
    start = time.time()
    while True:
        answers = [verify(t) for t in tokens]
        if all(r.status_code != 200 for r in answers) and queued(fxa, uid) == 0:
            return time.time() - start
        assert time.time() - start < within, (f"still valid {within} s after the disable", [r.text for r in answers], queued(fxa, uid))
        time.sleep(1)


def test_disable_by_email_revokes_access_tokens(access, fxa):
    # an account syncing, then disabled by ffs_access: SQL cannot reach the access tokens in
    # fxa-auth's Redis, the admin UI revokes them (docs/admin/accounts.md#sign-out-and-disable)
    address = tag("revoke")
    access.execute(sqltext("INSERT INTO ffs.signup_allowlist (entry) VALUES (:e)"), {"e": address})
    try:
        created = int(time.time() * 1000)
        session = Client(server_url=f"{AUTH}/v1").create_account(address, uuid.uuid4().hex, keys=True)
        session.verify_email_code(wait_for_code(address))
        used, key_id = sync_token(session, created)
        res = tokenserver(used, key_id)
        assert res.status_code == 200, res.text
        token = res.json()
        assert storage(token, "GET", "/info/collections").status_code == 200
        # another one, never shown to the tokenserver (which caches what /v1/verify said for 5 minutes)
        unused = authorize(session)
        assert verify(unused).status_code == 200

        access.execute(sqltext("CALL ffs.disable_account_by_email(:e)"), {"e": address})
        took = revoked(fxa, session.uid, [used, unused])
        print(f"access tokens refused {took:.1f} s after ffs.disable_account_by_email")
        # the tokenserver too, with the X-KeyID it took before: no new Sync token
        res = tokenserver(unused, key_id)
        assert res.status_code == 401, res.text
        # what cannot be revoked: the Sync token handed out before works on the storage node until
        # it expires (its signature and expiry only, up to an hour)
        assert storage(token, "GET", "/info/collections").status_code == 200
    finally:
        access.execute(sqltext("DELETE FROM ffs.signup_allowlist WHERE entry = :e"), {"e": address})


def test_disable_enable_delete_by_email(access, fxa):
    assert disabled(fxa) == 0 and sessions(fxa) > 0
    # off the other system's list: the account stays until disabled, which signs it out everywhere
    access.execute(sqltext("DELETE FROM ffs.signup_allowlist WHERE entry = :e"), {"e": ADDRESS})
    assert exists(ADDRESS) and disabled(fxa) == 0
    access.execute(sqltext("CALL ffs.disable_account_by_email(:e)"), {"e": ADDRESS.upper()})
    assert disabled(fxa) == 1 and sessions(fxa) == 0
    access.execute(sqltext("CALL ffs.enable_account_by_email(:e)"), {"e": f" {ADDRESS} "})
    assert disabled(fxa) == 0
    # deletion only of a disabled account, as in the admin UI
    assert "only a disabled account can be deleted" in refused(access, f"CALL ffs.delete_account_by_email('{ADDRESS}')")
    access.execute(sqltext("CALL ffs.disable_account_by_email(:e)"), {"e": ADDRESS})
    access.execute(sqltext("CALL ffs.delete_account_by_email(:e)"), {"e": ADDRESS})
    assert not exists(ADDRESS)
    assert "no such account" in refused(access, f"CALL ffs.disable_account_by_email('{ADDRESS}')")


def test_admin_ui_leaves_access_alone(access, fxa):
    admin = Admin()
    for address in (LEFT, MEMBER):
        access.execute(sqltext("INSERT INTO ffs.signup_allowlist (entry) VALUES (:e)"), {"e": address})
        res = create(address)
        assert res.status_code == 200, res.text
    left, member = admin.uid(LEFT), admin.uid(MEMBER)
    # disabling stays the admin UI's, for incident response
    admin.confirm(f"/accounts/{left}/disable")
    assert disabled(fxa, LEFT) == 1
    # taken off the other system's list: Enable refused, in words, and the account stays disabled
    access.execute(sqltext("DELETE FROM ffs.signup_allowlist WHERE entry = :e"), {"e": LEFT})
    res = admin.http.post(f"{ADMIN}/accounts/{left}/enable", data={"csrf": admin.csrf(), "back": f"/users/{left}"}, timeout=30)
    assert res.status_code == 200 and failed(res.text) == [ELSEWHERE], failed(res.text)
    assert disabled(fxa, LEFT) == 1
    # on the list again: enabled, a full server too (the account is already counted, none added)
    access.execute(sqltext("INSERT INTO ffs.signup_allowlist (entry) VALUES (:e)"), {"e": LEFT})
    before = fxa.execute(sqltext("SELECT value FROM ffs.settings WHERE name = 'max_accounts'")).scalar()
    fxa.execute(sqltext("INSERT INTO ffs.settings (name, value) VALUES ('max_accounts', '0') ON DUPLICATE KEY UPDATE value = '0'"))
    try:
        assert fxa.execute(sqltext("SELECT ffs.signup_refusal(:e)"), {"e": LEFT}).scalar() == "full"
        admin.post(f"/accounts/{left}/enable")
    finally:
        if before is None:
            fxa.execute(sqltext("DELETE FROM ffs.settings WHERE name = 'max_accounts'"))
        else:
            fxa.execute(sqltext("UPDATE ffs.settings SET value = :v WHERE name = 'max_accounts'"), {"v": before})
    assert disabled(fxa, LEFT) == 0
    # left disabled and off the list for tests/e2e-fxa.sh
    admin.confirm(f"/accounts/{left}/disable")
    access.execute(sqltext("DELETE FROM ffs.signup_allowlist WHERE entry = :e"), {"e": LEFT})

    # deleted in the admin UI: the member's row stays, it can sign up again
    admin.confirm(f"/accounts/{member}/disable")
    _, done = admin.confirm(f"/users/{member}/delete", confirm_email=MEMBER)
    assert f"Deleted {MEMBER} (uid {member})" in done, done[:3000]
    assert not exists(MEMBER) and listed(access, MEMBER) == 1
    res = create(MEMBER)
    assert res.status_code == 200, res.text
    # gone for good once the other system says so
    access.execute(sqltext("CALL ffs.disable_account_by_email(:e)"), {"e": MEMBER})
    access.execute(sqltext("CALL ffs.delete_account_by_email(:e)"), {"e": MEMBER})
    assert not exists(MEMBER) and listed(access, MEMBER) == 1
    access.execute(sqltext("DELETE FROM ffs.signup_allowlist WHERE entry = :e"), {"e": MEMBER})


def test_admin_signups_read_only():
    admin = Admin()
    page = admin.page()
    assert "the system that decides who may use this server keeps these, read-only here" in page, page[:5000]
    for unwanted in ('action="/accounts/signups"', 'action="/accounts/invite"', 'action="/accounts/max-accounts"', "/accounts/allowlist/remove?entry="):
        assert unwanted not in page, unwanted
    csrf = admin.csrf()
    for path, form in (("/accounts/signups", {"mode": "open", "allowlist": ""}), ("/accounts/invite", {"email": "someone@example.org"}),
                       ("/accounts/allowlist/remove", {"entry": "@example.com"}), ("/accounts/max-accounts", {"max_accounts": "5"})):
        res = admin.http.post(f"{ADMIN}{path}", data={"csrf": csrf, **form}, timeout=30)
        assert "managed outside the admin UI (ADMIN_ACCESS_EXTERNAL): nothing changed here" in res.text, (path, res.text[:3000])
    assert requests.get(f"{ADMIN}/healthz", timeout=30).status_code == 200


def tag(name):
    return f"ffs-sweep-{name}-{uuid.uuid4().hex[:8]}@example.org"


def state(fxa, uid):
    """(disabledAt, sessions) of an account"""
    return tuple(fxa.execute(sqltext("SELECT disabledAt, (SELECT COUNT(*) FROM fxa.sessionTokens s WHERE s.uid = a.uid) FROM fxa.accounts a WHERE a.uid = UNHEX(:u)"),
                             {"u": uid}).one())


def not_allowed(fxa):
    """The enabled accounts whose current primary email (fxa.emails; the sign-up's without one),
    as given, the sign-up policy refuses with 'policy': {uid: email}, as the sweep sees them"""
    found = {}
    rows = fxa.execute(sqltext("SELECT HEX(a.uid), a.email, (SELECT e.email FROM fxa.emails e WHERE e.uid = a.uid AND e.isPrimary LIMIT 1) "
                               "FROM fxa.accounts a WHERE a.disabledAt IS NULL")).all()
    for uid, signup, primary in rows:
        address = primary or signup
        if fxa.execute(sqltext("SELECT ffs.signup_refusal(:e)"), {"e": address}).scalar() == "policy":
            found[uid] = address
    return found


def sweep_refused(access, p_max):
    """(SQLSTATE, message) of a refused sweep: GET DIAGNOSTICS on the same connection, right after
    it (the drivers give the error number and message only)"""
    dbapi = getattr(access.dialect, "loaded_dbapi", None) or access.dialect.dbapi
    cur = access.connection.cursor()
    try:
        with pytest.raises(dbapi.Error):
            cur.execute(f"CALL {SWEEP}({p_max})")
        cur.execute("GET DIAGNOSTICS CONDITION 1 @ffs_state = RETURNED_SQLSTATE, @ffs_text = MESSAGE_TEXT")
        cur.execute("SELECT @ffs_state, @ffs_text")
        return tuple(cur.fetchone())
    finally:
        cur.close()


def signed_up(address):
    """A confirmed account with a session, as Firefox signs up"""
    client = Client(server_url=f"{AUTH}/v1")
    session = client.create_account(address, uuid.uuid4().hex)
    session.verify_email_code(wait_for_code(address))
    return session


def change_primary(session, address, new):
    """The primary email changed as the account settings do: added, confirmed, made primary"""
    jwt = mfa(session, address, "email")
    res = requests.post(f"{AUTH}/v1/mfa/recovery_email", json={"email": new}, headers=jwt, timeout=30)
    assert res.status_code == 200, res.text
    res = requests.post(f"{AUTH}/v1/mfa/recovery_email/secondary/verify_code", json={"email": new, "code": wait_for_code(new)}, headers=jwt, timeout=30)
    assert res.status_code == 200, res.text
    res = requests.post(f"{AUTH}/v1/mfa/recovery_email/set_primary", json={"email": new}, headers=jwt, timeout=30)
    assert res.status_code == 200, res.text


def test_admin_enable_asks_the_current_primary_email(access, fxa):
    # the admin UI's Enable and the sweep: one rule, the current primary email, so the admin UI
    # never enables an account the next sweep disables again
    admin = Admin()
    off, off_to, on, on_to = tag("enable-off"), tag("enable-off-to"), tag("enable-on"), tag("enable-on-to")
    entries = [off, on, on_to]
    for entry in entries:
        access.execute(sqltext("INSERT INTO ffs.signup_allowlist (entry) VALUES (:e)"), {"e": entry})
    try:
        sessions = {address: signed_up(address) for address in (off, on)}
        # off: signed up on the list, primary changed to an email off it (the first stays on it)
        change_primary(sessions[off], off, off_to)
        # on: primary changed to an email on the list, the first one taken off it
        change_primary(sessions[on], on, on_to)
        access.execute(sqltext("DELETE FROM ffs.signup_allowlist WHERE entry = :e"), {"e": on})
        uid = {address: s.uid for address, s in sessions.items()}
        for address in (off, on):
            admin.confirm(f"/accounts/{uid[address]}/disable")
            assert disabled(fxa, address) == 1
        res = admin.http.post(f"{ADMIN}/accounts/{uid[off]}/enable", data={"csrf": admin.csrf(), "back": f"/users/{uid[off]}"}, timeout=30)
        assert res.status_code == 200 and failed(res.text) == [ELSEWHERE], failed(res.text)
        assert disabled(fxa, off) == 1
        admin.post(f"/accounts/{uid[on]}/enable")
        assert disabled(fxa, on) == 0
        # ffs_access finds both by the email they signed up with, which the accounts keep;
        # the new primary one finds none
        assert "no such account" in refused(access, f"CALL ffs.disable_account_by_email('{on_to}')")
        access.execute(sqltext("CALL ffs.disable_account_by_email(:e)"), {"e": on})
        assert disabled(fxa, on) == 1
    finally:
        for entry in entries:
            access.execute(sqltext("DELETE FROM ffs.signup_allowlist WHERE entry = :e"), {"e": entry})


def test_sweep_disables_accounts_off_the_list(access, fxa):
    domain = f"ffs-sweep-{uuid.uuid4().hex[:8]}.example.org"
    moved, moved_to, exact, leaver, gone = tag("moved"), tag("moved-to"), tag("exact"), tag("leaver"), tag("gone")
    member = f"someone-{uuid.uuid4().hex[:8]}@{domain}"
    # the accounts of the other tests off the list stay out of it: on the list for this test
    # (lower-cased, as the policy compares)
    others = not_allowed(fxa)
    entries = [moved, exact, leaver, gone, f"@{domain}"] + sorted({e.strip().lower() for e in others.values()})
    for entry in entries:
        access.execute(sqltext("INSERT IGNORE INTO ffs.signup_allowlist (entry) VALUES (:e)"), {"e": entry})
    try:
        assert not_allowed(fxa) == {}
        sessions = {address: signed_up(address) for address in (moved, exact, leaver, gone, member)}
        uid = {address: s.uid.upper() for address, s in sessions.items()}
        # signed up on the list, then the primary email changed to one that is not
        change_primary(sessions[moved], moved, moved_to)
        assert fxa.execute(sqltext("SELECT normalizedEmail FROM fxa.emails WHERE uid = UNHEX(:u) AND isPrimary"), {"u": uid[moved]}).scalar() == moved_to
        # off the list (the leaver), off the list and disabled already (gone)
        access.execute(sqltext("CALL ffs.disable_account_by_email(:e)"), {"e": gone})
        for entry in (leaver, gone):
            access.execute(sqltext("DELETE FROM ffs.signup_allowlist WHERE entry = :e"), {"e": entry})
        assert {u: e.lower() for u, e in not_allowed(fxa).items()} == {uid[moved]: moved_to, uid[leaver]: leaver}
        before = {address: state(fxa, u) for address, u in uid.items()}
        assert all(before[a][0] is None and before[a][1] > 0 for a in (moved, exact, leaver, member)) and before[gone][0] is not None, before
        # access tokens Firefox would hold: of those to disable, and of one that stays
        tokens = {address: authorize(sessions[address]) for address in (moved, leaver, exact)}
        assert all(verify(t).status_code == 200 for t in tokens.values())

        # refused, and nothing changed: the brake (2 to disable, more than 1 and 0), and p_max not a count
        assert sweep_refused(access, 1) == (BRAKE, "disable_accounts_not_allowed: 2 accounts would be disabled, more than p_max 1")
        assert sweep_refused(access, 0) == (BRAKE, "disable_accounts_not_allowed: 2 accounts would be disabled, more than p_max 0")
        for p_max in ("NULL", "-1"):
            assert sweep_refused(access, p_max) == ("45000", "disable_accounts_not_allowed: p_max must be a number, 0 or more")
        assert {address: state(fxa, u) for address, u in uid.items()} == before

        # p_max the real count passes: the two disabled and signed out everywhere, the count in its result
        assert dict(access.execute(sqltext(f"CALL {SWEEP}(:m)"), {"m": 2}).mappings().one()) == {"disabled": 2}
        after = {address: state(fxa, u) for address, u in uid.items()}
        for address in (moved, leaver):
            assert after[address][0] is not None and after[address][1] == 0, (address, after[address])
        # on the list (exact, @domain): as they were; disabled already: the same disabledAt, not counted
        for address in (exact, member, gone):
            assert after[address] == before[address], (address, after[address], before[address])
        # the access tokens of the two disabled revoked in Redis by the admin UI, the other's kept
        for address in (moved, leaver):
            took = revoked(fxa, uid[address], [tokens[address]])
            print(f"{address}: access token refused {took:.1f} s after the sweep")
        assert verify(tokens[exact]).status_code == 200
        # nothing left to do: 0, with p_max 0
        assert dict(access.execute(sqltext(f"CALL {SWEEP}(0)")).mappings().one()) == {"disabled": 0}
    finally:
        for entry in entries:
            access.execute(sqltext("DELETE FROM ffs.signup_allowlist WHERE entry = :e"), {"e": entry})
