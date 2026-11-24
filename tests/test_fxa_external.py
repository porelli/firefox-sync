"""Access managed elsewhere with the self-hosted accounts (ADMIN_ACCESS_EXTERNAL,
FXA_ACCESS_DB_PASSWORD, docs/admin/accounts.md#access-managed-elsewhere): another system keeps
the sign-up allowlist as ffs_access, and disables, enables or deletes accounts by email.

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

from test_fxa_admin import ADMIN, Admin, create, exists

ADDRESS = f"ffs-external-{uuid.uuid4().hex[:10]}@example.org"


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


def disabled(fxa):
    return fxa.execute(sqltext("SELECT disabledAt IS NOT NULL FROM fxa.accounts WHERE normalizedEmail = :e"), {"e": ADDRESS}).scalar()


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
