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
import uuid

import pytest
import requests
from sqlalchemy import create_engine
from sqlalchemy.exc import DBAPIError
from sqlalchemy.sql import text as sqltext

from test_fxa_admin import ADMIN, Admin, create, exists, failed

ADDRESS = f"ffs-external-{uuid.uuid4().hex[:10]}@example.org"
# left disabled and off the list: tests/e2e-fxa.sh enables it once the mode is off
LEFT = f"ffs-external-left-{uuid.uuid4().hex[:10]}@example.org"
MEMBER = f"ffs-external-member-{uuid.uuid4().hex[:10]}@example.org"
# ffs.enable_account's refusal (errAccessElsewhere of admin/fxainit.go)
ELSEWHERE = "not on the access list managed elsewhere: the system that manages access enables this account"


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
                  "CALL ffs.disable_account(UNHEX('00'))", "SELECT COUNT(*) FROM ffs.emails"):
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
