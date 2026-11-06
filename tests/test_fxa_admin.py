"""Who can use the self-hosted accounts: sign-up policy, admin UI, rate limits.

Runs after test_fxa_flow.py in the syncstorage-rs image (PyFxA), see tests/e2e-fxa.sh.
The stack starts with FXA_SIGNUPS=allowlist and FXA_SIGNUP_ALLOWLIST=@example.com,
invited@example.net.

Environment (besides those of test_fxa_flow.py):
  ADMIN_URL          public URL of the admin UI
  ADMIN_PASSWORD     its password
  FXA_DIRECT_URL     the auth server itself, without the sign-up gate (http://fxa-auth:9000)
  ADMIN_FXA_CLIENT_ID the admin UI's OAuth client: it signs in with these accounts
                     (ADMIN_ALLOWED_USERS=@example.com)
  TOKENSERVER_DB_TYPE the Sync databases' server, as the admin UI's: mysql (empty) or
                     postgres (one database, no storage database of its own)
"""

import html
import json
import os
import re
import time
import uuid
from urllib.parse import parse_qs, urlsplit

import pytest
import requests
from fxa._utils import HawkTokenAuth
from fxa.core import Client
from fxa.errors import ClientError, ServerError

from test_fxa_flow import AUTH, CONTENT, FIREFOX_CLIENT_ID, SYNC, authorize, storage, sync_token, wait_for_code

ADMIN = os.environ["ADMIN_URL"].rstrip("/")
DIRECT = os.environ["FXA_DIRECT_URL"].rstrip("/")
# one address of example.net on the allowlist (a new one every run: the tests also
# run again against a kept stack, tests/e2e-fxa.sh RERUN=1)
INVITED = f"invited-{uuid.uuid4().hex[:8]}@example.net"
ADMIN_CLIENT_ID = os.environ.get("ADMIN_FXA_CLIENT_ID", "")
# PostgreSQL: the tokenserver and the storage in one database, as the admin UI names it
SYNC_POSTGRES = os.environ.get("TOKENSERVER_DB_TYPE") == "postgres"
TOKENSERVER = "Sync (tokenserver and storage)" if SYNC_POSTGRES else "Tokenserver"
sso = pytest.mark.skipif(not ADMIN_CLIENT_ID, reason="the admin UI does not sign in with these accounts")


def email(domain):
    return f"ffs-admin-{uuid.uuid4().hex[:10]}@{domain}"


def exists(address):
    res = requests.post(f"{AUTH}/v1/account/status", json={"email": address}, timeout=30)
    assert res.status_code == 200, res.text
    return res.json()["exists"]


def create(address, server=AUTH):
    return requests.post(f"{server}/v1/account/create", json={"email": address, "authPW": "00" * 32}, timeout=30)


def failed(page):
    """The errors a page shows (database queries that failed...)"""
    return re.findall(r'class="failed"[^>]*>([^<]*)', page)


class Admin:
    """The admin UI, used like a browser: forms with the CSRF token of the page."""

    def __init__(self):
        self.http = requests.Session()
        res = self.http.post(f"{ADMIN}/login", data={"password": os.environ["ADMIN_PASSWORD"]}, timeout=30)
        assert res.status_code == 200 and "Sign out" in res.text, res.text[:500]

    def get(self, path):
        res = self.http.get(f"{ADMIN}{path}", timeout=30)
        assert res.status_code == 200, (path, res.status_code, res.text[:500])
        assert not failed(res.text), (path, failed(res.text))
        return res.text

    def page(self):
        return self.get("/")

    def search(self, q):
        """The overview with the accounts list searched for q (50 a page, newest first)"""
        return self.get("/?" + requests.compat.urlencode({"q": q}))

    def csrf(self):
        return re.search(r'name="csrf" value="([0-9a-f]+)"', self.page()).group(1)

    def post(self, path, **form):
        res = self.http.post(f"{ADMIN}{path}", data={"csrf": self.csrf(), **form}, timeout=30)
        assert res.status_code == 200, res.text[:500]
        assert not failed(res.text), failed(res.text)
        return res.text

    def uid(self, address):
        row = re.search(r'<tr data-email="' + re.escape(address) + r'">\s*<td><a href="/users/([0-9a-f]{32})">', self.search(address), re.S)
        assert row, f"{address} not in the accounts list"
        return row.group(1)

    def confirm(self, path, ok=True, **form):
        """Follows a link to a confirm page and submits its form (its CSRF token, hidden fields)"""
        page = self.get(path)
        action = re.search(r'<form method="post" action="([^"]+)" id="confirm">', page)
        assert action and 'id="cancel">Cancel</a>' in page, page[:3000]
        fields = dict(re.findall(r'<input type="hidden" name="([^"]+)" value="([^"]*)">', page.split('id="confirm">')[1]))
        res = self.http.post(f"{ADMIN}{html.unescape(action.group(1))}", data={**fields, **form}, timeout=60)
        assert res.status_code == 200 and (not ok or not failed(res.text)), (res.status_code, failed(res.text), res.text[:500])
        return page, res.text

    def events(self, **query):
        page = self.get("/activity?" + "&".join(f"{k}={requests.utils.quote(v)}" for k, v in query.items()))
        table = page.split('<table id="events"')[1].split("</table>")[0]
        return re.findall(r"<tr[^>]*><td>[^<]*</td><td>([^<]*)</td><td>([^<]*)</td></tr>", table)


@pytest.fixture(scope="module")
def admin():
    return Admin()


@pytest.fixture(scope="module", autouse=True)
def signup_policy():
    # the policy of a fresh stack (FXA_SIGNUP_ALLOWLIST), whatever an earlier run left
    Admin().post("/accounts/signups", mode="allowlist", allowlist=f"@example.com\n{INVITED}")


def test_admin_needs_the_password():
    http = requests.Session()
    res = http.get(f"{ADMIN}/", timeout=30)
    assert res.url.endswith("/login")
    res = http.post(f"{ADMIN}/login", data={"password": "wrong"}, timeout=30)
    assert "Wrong password" in res.text
    # a form posted from another site
    res = http.post(f"{ADMIN}/login", data={"password": os.environ["ADMIN_PASSWORD"]},
                    headers={"Origin": "https://evil.example"}, timeout=30)
    assert res.status_code == 403


def test_signup_refused_with_a_readable_error():
    address = email("example.org")
    res = create(address)
    assert res.status_code == 400 and res.json()["errno"] == 125, res.text
    assert not exists(address)


def test_signup_refused_without_the_gate():
    # straight to the auth server: the database refuses it
    address = email("example.org")
    res = create(address, server=DIRECT)
    assert res.status_code >= 400, res.text
    assert not exists(address)


def test_allowlist_matches_emails_and_domains():
    # @example.com is on the list, of example.net only INVITED
    assert create(email("example.com")).status_code == 200
    res = create(email("example.net"))
    assert res.status_code == 400, res.text


def test_signups_closed_and_reopened(admin):
    admin.post("/accounts/signups", mode="closed", allowlist="")
    res = create(email("example.com"))
    assert res.status_code == 400 and res.json()["errno"] == 125, res.text
    admin.post("/accounts/signups", mode="open", allowlist="")
    address = email("example.org")
    assert create(address).status_code == 200
    assert exists(address)
    # kept by tests/e2e-fxa.sh after a restart, @example.com for the browser tests
    page = admin.post("/accounts/signups", mode="allowlist", allowlist=f"@example.com\n{INVITED}\nkept@example.net")
    assert "kept@example.net" in page


@pytest.fixture(scope="module")
def invited():
    password = uuid.uuid4().hex
    client = Client(server_url=f"{AUTH}/v1")
    created = int(time.time() * 1000)
    session = client.create_account(INVITED, password, keys=True)
    session.verify_email_code(wait_for_code(INVITED))
    return {"client": client, "session": session, "password": password, "keys_changed_at": created}


def tokenserver(bearer, key_id):
    return requests.get(f"{SYNC}/1.0/sync/1.5", headers={"Authorization": f"Bearer {bearer}", "X-KeyID": key_id}, timeout=30)


def test_admin_lists_accounts(admin, invited):
    page = admin.page()
    assert INVITED in page
    assert invited["session"].uid in page
    # the newest first, 50 a page
    assert re.search(r'<span id="accounts-shown">1–\d+</span> of <span id="accounts-total">\d+</span>, newest first', page), page.split('id="pages"')[1][:500]


def sso_start(http):
    """The admin UI's /auth/login: the authorization request to the accounts pages"""
    res = http.get(f"{ADMIN}/auth/login", allow_redirects=False, timeout=30)
    assert res.status_code == 303, res.text[:500]
    url = urlsplit(res.headers["Location"])
    assert f"{url.scheme}://{url.netloc}{url.path}" == f"{CONTENT}/authorization", res.headers["Location"]
    query = {k: v[0] for k, v in parse_qs(url.query).items()}
    assert query["client_id"] == ADMIN_CLIENT_ID and query["redirect_uri"] == f"{ADMIN}/auth/callback", query
    assert query["code_challenge_method"] == "S256" and query["code_challenge"] and query["state"], query
    return query


def sso_code(session, query):
    """What the accounts pages do for a signed-in user: a code for the admin UI"""
    token_id = HawkTokenAuth(session.token, "sessionToken").id
    keys = ("client_id", "scope", "state", "code_challenge", "code_challenge_method", "redirect_uri")
    return requests.post(f"{AUTH}/v1/oauth/authorization", json={k: query[k] for k in keys},
                         headers={"Authorization": f"Bearer fxs_{token_id}"}, timeout=30)


def sso_callback(http, session):
    query = sso_start(http)
    res = sso_code(session, query)
    assert res.status_code == 200, res.text
    assert res.json()["state"] == query["state"], res.text
    return http.get(f"{ADMIN}/auth/callback", params={"code": res.json()["code"], "state": query["state"]}, timeout=30)


@sso
def test_admin_sso_client_registered():
    # discovery of the accounts as an OpenID Connect provider, and the admin UI's client
    discovery = requests.get(f"{CONTENT}/.well-known/openid-configuration", timeout=30).json()
    assert discovery["issuer"] == CONTENT and discovery["authorization_endpoint"] == f"{CONTENT}/authorization", discovery
    client = requests.get(f"{AUTH}/v1/client/{ADMIN_CLIENT_ID}", timeout=30).json()
    assert client["trusted"] is True and client["redirect_uri"] == f"{ADMIN}/auth/callback", client
    assert "Sign in with Mozilla account" in requests.get(f"{ADMIN}/login", timeout=30).text


@sso
def test_admin_sso_with_an_allowed_account():
    address = email("example.com")
    session = Client(server_url=f"{AUTH}/v1").create_account(address, uuid.uuid4().hex)
    # a password alone is not enough (SERVICES_WITH_EMAIL_VERIFICATION): no code yet
    res = sso_code(session, sso_start(requests.Session()))
    assert res.status_code == 400 and res.json()["errno"] == 138, res.text
    session.verify_email_code(wait_for_code(address))
    http = requests.Session()
    res = sso_callback(http, session)
    assert res.status_code == 200 and urlsplit(res.url).path == "/auth/callback", (res.url, res.text[:500])
    page = http.get(f"{ADMIN}/", timeout=30)
    assert page.url == f"{ADMIN}/" and "Sign out" in page.text, (page.url, page.text[:500])
    assert f'<span class="hint">{address}</span>' in page.text
    assert f"signed in: {address} (oidc)" in Admin().get("/activity?range=24h")


@sso
def test_admin_sso_refuses_other_accounts(invited):
    # on the sign-up allowlist, not on ADMIN_ALLOWED_USERS
    http = requests.Session()
    res = sso_callback(http, invited["session"])
    assert urlsplit(res.url).path == "/login" and "Single sign-on failed" in res.text, res.url
    assert http.get(f"{ADMIN}/", timeout=30).url.endswith("/login")
    assert f"failed sign-in: {INVITED} (oidc): not allowed" in Admin().get("/activity?range=24h")


def reset_code(address):
    """A password reset started (the code from the email typed in): its passwordForgotToken
    and the code that trades it for an accountResetToken"""
    from test_fxa_flow import MAILPIT
    seen = {m["ID"] for m in requests.get(f"{MAILPIT}/api/v1/search", params={"query": f"to:{address}"}, timeout=10).json().get("messages", [])}
    res = requests.post(f"{AUTH}/v1/password/forgot/send_otp", json={"email": address}, timeout=30)
    assert res.status_code == 200, res.text
    deadline = time.time() + 60
    otp = None
    while not otp and time.time() < deadline:
        for m in requests.get(f"{MAILPIT}/api/v1/search", params={"query": f"to:{address}"}, timeout=10).json().get("messages", []):
            if m["ID"] not in seen:
                otp = (requests.get(f"{MAILPIT}/api/v1/message/{m['ID']}/headers", timeout=10).json().get("X-Password-Forgot-Otp") or [None])[0]
        time.sleep(1)
    assert otp, f"no password reset email for {address}"
    res = requests.post(f"{AUTH}/v1/password/forgot/verify_otp", json={"email": address, "code": otp}, timeout=30)
    assert res.status_code == 200, res.text
    return res.json()["token"], res.json()["code"]


def use_reset_code(token, code):
    return requests.post(f"{AUTH}/v1/password/forgot/verify_code", json={"code": code},
                         auth=HawkTokenAuth(token, "passwordForgotToken"), timeout=30)


def test_disabled_account_is_locked_out(admin, invited):
    session = invited["session"]
    bearer, key_id = sync_token(session, invited["keys_changed_at"])
    assert tokenserver(bearer, key_id).status_code == 200
    # another one, not used yet: the tokenserver caches what /v1/verify said for 5 minutes
    unused = authorize(session)
    # a password reset started before: Mozilla's revokeAccountTokens_1 ends it too
    forgot = reset_code(INVITED)
    uid = admin.uid(INVITED)
    assert uid == session.uid
    # the list only links to the confirm page, which names the account and its sessions
    row = account_row(admin, INVITED)
    assert f'href="/accounts/{uid}/disable"' in row and "<form" not in row, row
    page, done = admin.confirm(f"/accounts/{uid}/disable", reason="ffs test: locked out")
    assert f"Disable {INVITED}?" in page and 'id="confirm-sessions"' in page, page[:3000]
    assert f"Disabled {INVITED} (uid {uid[:8]})" in done
    assert "disabled" in account_row(admin, INVITED)
    # who did what, on which account, and why
    assert ("admin", f"Disabled {INVITED} (uid {uid[:8]}) by admin (password): ffs test: locked out") in admin.events(kind="admin", q=INVITED)

    # signed out everywhere, and no new sign-in
    with pytest.raises(ClientError):
        session.get_email_status()
    with pytest.raises(ClientError):
        invited["client"].login(INVITED, invited["password"], keys=True)
    # and its access tokens are revoked, for the tokenserver too
    verified = requests.post(f"{AUTH}/v1/verify", json={"token": unused}, timeout=30)
    assert verified.status_code != 200, verified.text
    res = tokenserver(unused, key_id)
    assert res.status_code == 401, res.text

    admin.post(f"/accounts/{uid}/enable")
    session = invited["client"].login(INVITED, invited["password"], keys=True)
    assert session.uid == uid
    # enabled again, the reset started before stays dead: its token was deleted
    res = use_reset_code(*forgot)
    assert res.status_code == 401, res.text


def test_sign_out_everywhere(admin):
    address, password = email("example.com"), uuid.uuid4().hex
    client = Client(server_url=f"{AUTH}/v1")
    first = client.create_account(address, password)
    first.verify_email_code(wait_for_code(address))
    second = client.login(address, password)
    refresh = authorize(first, full=True, offline=True)["refresh_token"]
    for s in (first, second):
        assert requests.get(f"{AUTH}/v1/recovery_email/status", headers=bearer(s), timeout=30).status_code == 200
    uid = first.uid
    assert 'id="sign-out-all"' in admin.get(f"/users/{uid}")
    page, done = admin.confirm(f"/accounts/{uid}/sign-out-all")
    assert f"Sign out everywhere {address}?" in page and "Python" in page, page[:3000]
    assert f"Signed out {address} (uid {uid[:8]}) everywhere" in done
    # every session token refused, the refresh token too
    for s in (first, second):
        res = requests.get(f"{AUTH}/v1/recovery_email/status", headers=bearer(s), timeout=30)
        assert res.status_code == 401, res.text
    res = requests.post(f"{AUTH}/v1/oauth/token", json={"grant_type": "refresh_token", "client_id": FIREFOX_CLIENT_ID, "refresh_token": refresh}, timeout=30)
    assert res.status_code in (400, 401), res.text
    # still active: a new sign-in works right away, and a password reset
    row = account_row(admin, address)
    # the usual state is kept for screen readers only
    assert '<td class="status"><span class="visually-hidden">enabled</span>' in row, row
    again = client.login(address, password)
    assert requests.get(f"{AUTH}/v1/recovery_email/status", headers=bearer(again), timeout=30).status_code == 200
    res = use_reset_code(*reset_code(address))
    assert res.status_code == 200 and res.json()["accountResetToken"], res.text
    assert ("admin", f"Signed out {address} (uid {uid[:8]}) everywhere by admin (password)") in admin.events(kind="admin", q=address)


def test_access_tokens_are_short_lived():
    # FXA_ACCESS_TOKEN_LIFETIME, 60 minutes by default
    address = email("example.com")
    session = Client(server_url=f"{AUTH}/v1").create_account(address, uuid.uuid4().hex, keys=True)
    session.verify_email_code(wait_for_code(address))
    granted = authorize(session, full=True)
    assert 0 < granted["expires_in"] <= 3600, granted


def test_max_users_from_admin(admin):
    page = admin.page()
    users = int(re.search(r'id="sync-users">(\d+)<', page).group(1))
    before = int(re.search(r'id="sync-max-users">(\d+)<', page).group(1))
    # tests/e2e-fxa.sh runs the stack with SYNC_MAX_USERS=initial:10: the page manages it
    assert "Managed here" in page and not re.search(r'<input id="max_users" [^>]*disabled>', page), page[:3000]
    admin.post("/sync/max-users", max_users=str(users))
    try:
        # a new account cannot start syncing while the server is full
        client = Client(server_url=f"{AUTH}/v1")
        address = email("example.com")
        created = int(time.time() * 1000)
        session = client.create_account(address, uuid.uuid4().hex, keys=True)
        session.verify_email_code(wait_for_code(address))
        bearer, key_id = sync_token(session, created)
        res = tokenserver(bearer, key_id)
        assert res.status_code != 200, res.text
        # room again: the same account gets in
        admin.post("/sync/max-users", max_users=str(users + 1))
        assert tokenserver(bearer, key_id).status_code == 200
    finally:
        # 7: tests/e2e-fxa.sh checks that a restart keeps it
        admin.post("/sync/max-users", max_users="7" if before != 7 else "8")


def test_max_accounts_from_admin(admin, fxa_db):
    """FXA_MAX_ACCOUNTS (not set in tests/e2e-fxa.sh: initial:unlimited, managed on the page)"""
    page = admin.page()
    assert 'id="fxa-max-accounts">unlimited<' in page and " created, no limit" in page, page[:3000]
    assert re.search(r'<td>Max accounts</td><td><span class="ok">up</span> <span class="hint">\d+ accounts?, no limit</span>', page), page[:3000]
    assert not re.search(r'<input id="max_accounts" [^>]*disabled', page)
    count = int(re.search(r'id="fxa-accounts">(\d+)<', page).group(1))
    assert count == sql(fxa_db, "SELECT COUNT(*) FROM fxa.accounts").scalar()
    metrics = lambda: requests.get(f"{ADMIN}/metrics", headers={"Authorization": "Bearer ffs-test-metrics-token"}, timeout=30).text
    assert f"ffs_accounts {count}\n" in metrics() and "ffs_accounts_max" not in metrics()
    try:
        # full: the gate says so, the database refuses it too, the page and the alerts tell
        page = admin.post("/accounts/max-accounts", max_accounts=str(count))
        assert f"Max accounts set to {count}" in page and f'id="fxa-max-accounts">{count}<' in page
        line = f"{count} of {count} accounts are created (FXA_MAX_ACCOUNTS): sign-ups are refused until it is raised."
        assert (line, "#signups") in attention_of(page), attention_of(page)
        assert re.search(r'<td>Max accounts</td><td><span class="pill warn">full</span>', page), page[:3000]
        address = email("example.com")  # on the allowlist: refused only because it is full
        res = create(address)
        assert res.status_code == 400 and res.json()["errno"] == 125 and "This server is full" in res.json()["message"], res.text
        res = create(address, server=DIRECT)
        assert res.status_code >= 400 and not exists(address), res.text
        assert any(d == f"{address} (the server is full: FXA_MAX_ACCOUNTS)" for _, d in admin.events(kind="sign-up refused", q=address)), admin.events(kind="sign-up refused")
        assert "ffs_accounts_full 1\n" in metrics() and f"ffs_accounts_max {count}\n" in metrics()
        deadline = time.time() + 30
        while not any("accounts are created (FXA_MAX_ACCOUNTS)" in d for _, d in admin.events(kind="attention")) and time.time() < deadline:
            time.sleep(1)
        assert any("accounts are created (FXA_MAX_ACCOUNTS)" in d for _, d in admin.events(kind="attention")), admin.events(kind="attention")
        # room for one: in
        admin.post("/accounts/max-accounts", max_accounts=str(count + 1))
        assert create(address).status_code == 200 and exists(address)
    finally:
        page = admin.post("/accounts/max-accounts", max_accounts="", unlimited="1")
    assert "Max accounts set to unlimited" in page and 'id="fxa-max-accounts">unlimited<' in page
    assert ("admin", "Max accounts set to unlimited by admin (password)") in admin.events(kind="admin", q="Max accounts")


def test_spoofed_forwarded_for_does_not_bypass_rate_limit():
    # the auth server takes the client IP from X-Forwarded-For (CLIENT_ADDRESS_DEPTH):
    # a client sending its own must still be counted as itself
    address = email("example.com")
    for i in range(10):
        res = requests.post(f"{AUTH}/v1/account/login", json={"email": address, "authPW": "00" * 32},
                            headers={"X-Forwarded-For": f"198.51.100.{i + 1}"}, timeout=30)
        if res.status_code == 429:
            assert res.json()["errno"] == 114, res.text
            return
    raise AssertionError("a new X-Forwarded-For on every attempt escaped the rate limit")


def test_user_page_shows_what_is_stored(admin):
    address = email("example.com")
    created = int(time.time() * 1000)
    session = Client(server_url=f"{AUTH}/v1").create_account(address, uuid.uuid4().hex, keys=True)
    session.verify_email_code(wait_for_code(address))
    bearer, key_id = sync_token(session, created)
    token = tokenserver(bearer, key_id).json()
    bookmarks = [{"id": f"bookmark{i:03d}", "payload": json.dumps({"title": "x" * 100})} for i in range(3)]
    assert storage(token, "POST", "/storage/bookmarks", bookmarks).status_code == 200
    page = admin.get(f"/users/{session.uid}")
    assert address in page
    assert re.search(r"<td>bookmarks</td><td>3</td>", page), page[:2000]
    assert "Sessions" in page and "Python" in page  # PyFxA's session


def test_activity_page():
    # a fresh session: the events of the other tests are there, and the metrics of
    # the sync above (written every METRICS_FLUSH_SECONDS in the tests)
    admin = Admin()
    deadline = time.time() + 30
    while True:
        page = admin.get("/activity?range=24h")
        requests_total = int(re.search(r"Sync requests <strong>(\d+)</strong>", page).group(1))
        if requests_total > 0 or time.time() > deadline:
            break
        time.sleep(3)
    assert requests_total > 0, page[:2000]
    assert "syncstorage.request.post_collection" in page
    for event in ("sign-up refused", "signed in", "Max users set", f"Disabled {INVITED}", "sign-up"):
        assert event in page, event
    assert re.search(r"Database Tokenserver <strong>[\d.]+ [KMG]?B", page), "database size chart"
    admin.get("/activity?range=30d")


def test_health_and_sizes(admin):
    page = admin.page()
    health = page.split('<table id="health"')[1].split("</table>")[0]
    # (PostgreSQL: its check the tokenserver's)
    storage = () if SYNC_POSTGRES else ("Storage database",)
    for component in ("Sync server", "Tokenserver database", *storage, "Admin UI database", "Accounts API", "Accounts pages",
                      "Profile server", "Accounts database", "Accounts Redis"):
        row = re.search(r"<td>" + component + r"</td><td>(.*?)</td><td>(.*?)</td>", health)
        assert row and "up" in row.group(1), (component, health)
    # versions from /__version__ (our syncstorage images fill it in since APP_BUILD_REVISION 2)
    assert re.search(r"<td>Accounts API</td><td>[^<]*<span[^>]*>up</span></td><td>\d+\.\d+", health), health
    assert re.search(r"Databases: .*" + re.escape(TOKENSERVER) + r" \d", page), page[:3000]
    # FXA_DB_SERVER: set by e2e-fxa.sh from FXA_MYSQL_IMAGE (MariaDB with FXA_DB=mariadb)
    for component, v in (("Accounts database", os.environ.get("FXA_DB_SERVER") or r"MySQL \d+\.\d+"), ("Accounts Redis", r"Redis \d"), ("Profile server", r"\d+\.\d+")):
        assert re.search(r"<td>" + component + r"</td><td>[^<]*<span[^>]*>up</span></td><td>" + v, health), (component, health)


def test_inactive_and_unconfirmed_badges(admin):
    # the test stack marks right away (ADMIN_STALE_DAYS=0, ADMIN_UNCONFIRMED_HOURS=0); the
    # list shows those of a badge alone, as Needs attention links to
    assert 'class="badge">inactive' in admin.get("/?show=inactive")
    page = admin.get("/?show=unconfirmed")
    assert 'class="badge">unconfirmed' in page and 'id="search-result"' in page and re.search(r'id="search-result">\d+ accounts? that never confirmed their email\.', page)
    assert page.count("<tr data-email=") == page.count('<span class="badge">unconfirmed</span>'), page.split('<table id="accounts"')[1][:3000]
    assert any(href == "/?show=unconfirmed#accounts" for _, href in attention_of(admin.page()))


def test_security_page_lifts_a_block(admin):
    address = email("example.com")
    login = lambda: requests.post(f"{AUTH}/v1/account/login", json={"email": address, "authPW": "00" * 32}, timeout=30)
    codes = [login().status_code for _ in range(7)]
    assert 429 in codes, codes
    page = admin.get("/security")
    key = re.search(r'name="key" value="(rate-limit:block:[^"]*' + re.escape(address) + r'[^"]*)"', page)
    assert key, page[:3000]
    csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', page).group(1)
    res = admin.http.post(f"{ADMIN}/security/unblock", data={"csrf": csrf, "key": key.group(1)}, timeout=30)
    assert "Lifted the block" in res.text
    assert login().status_code == 400


def test_security_page_lists_attempts(admin):
    # below the block (5 in 15 minutes), at least half way: listed
    address = email("example.com")
    for _ in range(3):
        res = requests.post(f"{AUTH}/v1/account/login", json={"email": address, "authPW": "00" * 32}, timeout=30)
        assert res.status_code == 400, res.text
    attempts = admin.get("/security").split('<table id="attempts"')[1].split("</table>")[0]
    assert re.search(r"<code>[^<]*" + re.escape(address) + r"[^<]*</code></td><td>accountLogin</td><td>3 of \d+</td>", attempts), attempts[:3000]
    # only blocks can be lifted
    res = admin.http.post(f"{ADMIN}/security/unblock", data={"csrf": admin.csrf(), "key": f"rate-limit:attempts:email={address}:accountLogin:5-900-900"}, timeout=30)
    assert failed(res.text) == ["not a block"], failed(res.text)


def bearer(session):
    from fxa._utils import HawkTokenAuth
    return {"Authorization": f"Bearer fxs_{HawkTokenAuth(session.token, 'sessionToken').id}"}


def test_sign_out_one_session_and_one_device(admin):
    import hashlib
    from fxa._utils import HawkTokenAuth
    address, password = email("example.com"), uuid.uuid4().hex
    client = Client(server_url=f"{AUTH}/v1")
    first = client.create_account(address, password)
    first.verify_email_code(wait_for_code(address))
    second = client.login(address, password)
    third = client.login(address, password)
    device = requests.post(f"{AUTH}/v1/account/device", json={"name": "ffs test device", "type": "desktop"},
                           headers=bearer(third), timeout=30)
    assert device.status_code == 200, device.text

    # one session: the others keep working
    ref = hashlib.sha256(bytes.fromhex(HawkTokenAuth(second.token, "sessionToken").id)).hexdigest()
    page = admin.get(f"/users/{first.uid}")
    assert f"/sessions/{ref}/sign-out" in page and "ffs test device" in page, page[:3000]
    # in the event log as a new device
    assert f"<td>new device</td><td>{address}: ffs test device (desktop)</td>" in admin.get("/activity"), "new device event"
    csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', page).group(1)
    res = admin.http.post(f"{ADMIN}/users/{first.uid}/sessions/{ref}/sign-out", data={"csrf": csrf}, timeout=30)
    assert f"Signed out a session of {address}" in res.text
    with pytest.raises(ClientError):
        second.get_email_status()
    first.get_email_status()

    # one device, with its session
    res = admin.http.post(f"{ADMIN}/users/{first.uid}/devices/{device.json()['id']}/sign-out", data={"csrf": csrf}, timeout=30)
    assert "Signed out a device" in res.text and "ffs test device" not in res.text
    with pytest.raises(ClientError):
        third.get_email_status()
    first.get_email_status()


def test_sign_out_a_device_of_a_refresh_token(admin):
    # the mobile apps register their device with an OAuth refresh token, not a session
    address = email("example.com")
    session = Client(server_url=f"{AUTH}/v1").create_account(address, uuid.uuid4().hex)
    session.verify_email_code(wait_for_code(address))
    refresh = authorize(session, full=True, offline=True)["refresh_token"]
    device = requests.post(f"{AUTH}/v1/account/device", json={"name": "ffs mobile device", "type": "mobile"},
                           headers={"Authorization": f"Bearer {refresh}"}, timeout=30)
    assert device.status_code == 200, device.text
    renew = lambda: requests.post(f"{AUTH}/v1/oauth/token", json={"grant_type": "refresh_token", "client_id": FIREFOX_CLIENT_ID,
                                                                   "refresh_token": refresh}, timeout=30)
    assert renew().status_code == 200
    assert "ffs mobile device" in admin.get(f"/users/{session.uid}")

    # through its confirm page, which shows that device only
    page, done = admin.confirm(f"/users/{session.uid}/devices/{device.json()['id']}/sign-out")
    assert "ffs mobile device" in page.split('id="confirm-devices"')[1] and 'id="confirm-sessions"' not in page, page[:3000]
    assert "Signed out a device" in done and "ffs mobile device" not in done
    # no new access tokens with it; the session of the account is another sign-in
    res = renew()
    assert res.status_code in (400, 401), res.text
    session.get_email_status()


def test_sign_out_needs_the_right_account(admin):
    # the procedures sign out only what belongs to the account of the URL
    import hashlib
    a, b = member(), member()
    b_session, b_address = b[1], b[2]
    device = requests.post(f"{AUTH}/v1/account/device", json={"name": "ffs device of b", "type": "desktop"},
                           headers=bearer(b_session), timeout=30)
    assert device.status_code == 200, device.text
    b_ref = hashlib.sha256(bytes.fromhex(HawkTokenAuth(b_session.token, "sessionToken").id)).hexdigest()
    a_uid, csrf = a[1].uid, admin.csrf()
    res = admin.http.post(f"{ADMIN}/users/{a_uid}/devices/{device.json()['id']}/sign-out", data={"csrf": csrf}, timeout=30)
    assert failed(res.text) == ["no such device"], failed(res.text)
    res = admin.http.post(f"{ADMIN}/users/{a_uid}/sessions/{b_ref}/sign-out", data={"csrf": csrf}, timeout=30)
    assert failed(res.text) == ["no such session"], failed(res.text)
    # b is still signed in, its device still there, and nothing was recorded
    b_session.get_email_status()
    assert "ffs device of b" in admin.get(f"/users/{b_session.uid}")
    a[1].get_email_status()
    lines = [d for _, d in admin.events(kind="admin", q=b_address) + admin.events(kind="admin", q=a[2])]
    assert not [d for d in lines if "Signed out a device" in d or "Signed out a session" in d], lines


def test_alert_emails():
    # sent every ALERT_INTERVAL_SECONDS (5 in the tests) to ADMIN_ALERT_EMAIL
    from test_fxa_flow import MAILPIT
    deadline = time.time() + 60
    while time.time() < deadline:
        found = requests.get(f"{MAILPIT}/api/v1/search", params={"query": "to:admin@fxa.test"}, timeout=10).json()
        text = " ".join(requests.get(f"{MAILPIT}/api/v1/message/{m['ID']}", timeout=10).json().get("Text", "")
                        for m in found.get("messages", []))
        # every change made in the admin UI, with who made it. Not health: the components
        # that came up after the admin UI are in its startup grace, not alerted (e2e-fxa.sh
        # checks that, e2e.sh the alerts of the Sync server going down)
        if "sign-up refused" in text and "admin: signed in" in text and "sign-up: " in text and \
                f"admin: Disabled {INVITED}" in text and "by admin (password)" in text:
            return
        time.sleep(3)
    raise AssertionError(f"alerts missing: {text[:2000]}")


def test_alert_notifications():
    # the same alerts, also to ADMIN_NOTIFY (a webhook to tests/notify_sink.py), besides the
    # email: with the accounts the SMTP server stays, it sends their codes
    deadline, events = time.time() + 60, []
    while time.time() < deadline:
        hooks = [r for r in requests.get("http://notify-sink:8000/_received", timeout=10).json() if r["path"] == "/fxa-hook/ffs-test-fxa-secret"]
        events = [e for r in hooks for e in json.loads(r["body"])["events"]]
        kinds = {e["kind"] for e in events}
        if {"sign-up refused", "admin"} <= kinds and any(e["text"].startswith(f"Disabled {INVITED}") for e in events):
            break
        time.sleep(3)
    else:
        raise AssertionError(f"notifications missing: {events[:50]}")
    payload = json.loads(hooks[-1]["body"])
    # the link of the admin UI, from its public callback (ADMIN_OIDC_REDIRECT_URL)
    assert payload["source"] == "firefox-sync" and payload["link"] == "https://admin.fxa.test/activity", payload
    # the SMTP server is still checked and needed: a setup check says why
    page = requests.Session()
    res = page.post(f"{ADMIN}/login", data={"password": os.environ["ADMIN_PASSWORD"]}, timeout=30)
    assert "Email of the accounts (FXA_SMTP_HOST)" in res.text and "codes of new accounts and new sign-ins" in res.text, res.text[:3000]
    assert "ffs-test-fxa-secret" not in res.text and "ffs-test-fxa-secret" not in page.get(f"{ADMIN}/config", timeout=30).text


def test_prometheus():
    assert requests.get(f"{ADMIN}/metrics", timeout=30).status_code == 404
    res = requests.get(f"{ADMIN}/metrics", headers={"Authorization": "Bearer ffs-test-metrics-token"}, timeout=30)
    assert res.status_code == 200, res.text
    for line in ("ffs_sync_accounts ", 'ffs_up{component="Sync server"} 1', "ffs_accounts ", 'ffs_database_bytes{database="Accounts"}',
                 'ffs_statsd_total{name="syncstorage_'):
        assert line in res.text, line


# account support: how an account signs in, and helping its owner (docs/admin/accounts.md#helping-account-owners)

def totp_code(secret, at=None):
    """The code of an authenticator app (RFC 6238, SHA-1, 30 s, 6 digits)"""
    import base64
    import hashlib
    import hmac
    import struct
    key = base64.b32decode(secret.upper() + "=" * (-len(secret) % 8))
    digest = hmac.new(key, struct.pack(">Q", int((at or time.time()) // 30)), hashlib.sha1).digest()
    offset = digest[-1] & 15
    return "%06d" % ((struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF) % 1000000)


def mails(address, query=""):
    from test_fxa_flow import MAILPIT
    found = requests.get(f"{MAILPIT}/api/v1/search", params={"query": f"to:{address} {query}".strip()}, timeout=10).json()
    return found.get("messages", [])


def mail_header(address, name, seen=()):
    """The header name of the first new email to address"""
    from test_fxa_flow import MAILPIT
    deadline = time.time() + 60
    while time.time() < deadline:
        for m in mails(address):
            if m["ID"] not in seen:
                value = requests.get(f"{MAILPIT}/api/v1/message/{m['ID']}/headers", timeout=10).json().get(name)
                if value:
                    return value[0]
        time.sleep(1)
    raise AssertionError(f"no email with {name} for {address}")


def mfa(session, address, action):
    """The JWT of the account settings for a change (an email code first, like the pages)"""
    seen = {m["ID"] for m in mails(address)}
    res = requests.post(f"{AUTH}/v1/mfa/otp/request", json={"action": action}, headers=bearer(session), timeout=30)
    assert res.status_code == 200, res.text
    code = mail_header(address, "X-Account-Change-Verify-Code", seen)
    res = requests.post(f"{AUTH}/v1/mfa/otp/verify", json={"action": action, "code": code}, headers=bearer(session), timeout=30)
    assert res.status_code == 200, res.text
    return {"Authorization": f"Bearer {res.json()['accessToken']}"}


def enable_totp(session, address, codes=8):
    """Two-step authentication with an authenticator app and backup codes, like the settings page"""
    jwt = mfa(session, address, "2fa")
    res = requests.post(f"{AUTH}/v1/mfa/totp/create", json={}, headers=jwt, timeout=30)
    assert res.status_code == 200, res.text
    secret = res.json()["secret"]
    res = requests.post(f"{AUTH}/v1/mfa/recoveryCodes", json={"recoveryCodes": [uuid.uuid4().hex[:10] for _ in range(codes)]}, headers=jwt, timeout=30)
    assert res.status_code == 200, res.text
    res = requests.post(f"{AUTH}/v1/mfa/totp/setup/verify", json={"code": totp_code(secret)}, headers=jwt, timeout=30)
    assert res.status_code == 200, res.text
    res = requests.post(f"{AUTH}/v1/mfa/totp/setup/complete", json={}, headers=jwt, timeout=30)
    assert res.status_code == 200, res.text
    return secret


def member(keys=False):
    """A confirmed account of @example.com: (client, session, email, password)"""
    address, password = email("example.com"), uuid.uuid4().hex
    client = Client(server_url=f"{AUTH}/v1")
    session = client.create_account(address, password, keys=keys)
    session.verify_email_code(wait_for_code(address))
    return client, session, address, password


def account_row(admin, address):
    return re.search(r'<tr data-email="' + re.escape(address) + r'">(.*?)</tr>', admin.search(address), re.S).group(1)


def attention_of(page):
    """The lines of Needs attention: (text, link)"""
    box = page.split('<section id="attention">')[1].split("</section>")[0]
    return [(html.unescape(re.sub(r"<[^>]+>", "", text)).strip(), html.unescape(href)) for text, href in re.findall(r'<li>(.*?) <a href="([^"]*)">', box, re.S)]


def signed_in(client, address, password):
    """A full sign-in, with the email code when the accounts service asks for one"""
    session = client.login(address, password, keys=True)
    assert session.verificationMethod != "totp-2fa", "still asks for the authenticator's code"
    if not session.verified:
        res = requests.post(f"{AUTH}/v1/session/verify_code", json={"code": wait_for_code(address)},
                            auth=HawkTokenAuth(session.token, "sessionToken"), timeout=30)
        assert res.status_code == 200, res.text
    return session


def test_two_step_authentication_turned_off(admin):
    client, session, address, password = member()
    uid = session.uid
    row = account_row(admin, address)
    assert '<span class="badge">no recovery key</span>' in row and "2-step" not in row, row
    enable_totp(session, address)
    assert '<span class="badge">2-step</span>' in account_row(admin, address)
    page = admin.get(f"/users/{uid}")
    assert '<span id="recovery-codes">8</span> backup codes left' in page and f'href="/accounts/{uid}/remove-totp"' in page, page[:4000]
    # the authenticator's code is needed now
    assert client.login(address, password).verificationMethod == "totp-2fa"

    page, done = admin.confirm(f"/accounts/{uid}/remove-totp", sign_out="1", reason="ffs test: lost phone")
    assert f"Turn off two-step authentication of {address}?" in page and 'name="sign_out" value="1" checked' in page, page[:3000]
    assert f"Turned off two-step authentication of {address} (uid {uid[:8]}) (signed out everywhere, owner notified)" in done, done[:3000]
    assert "2-step" not in account_row(admin, address)
    assert "backup codes left" not in admin.get(f"/users/{uid}")
    # signed out everywhere (on by default), then the password and an email code are enough
    with pytest.raises(ClientError):
        session.get_email_status()
    again = signed_in(client, address, password)
    assert requests.get(f"{AUTH}/v1/totp/exists", headers=bearer(again), timeout=30).json()["exists"] is False
    authorize(again)
    # the owner hears of it, the admins too (the alert of the admin event)
    deadline = time.time() + 30
    while not mails(address, 'subject:"Two-step authentication turned off"') and time.time() < deadline:
        time.sleep(1)
    assert mails(address, 'subject:"Two-step authentication turned off"'), "no notice to the owner"
    assert ("admin", f"Turned off two-step authentication of {address} (uid {uid[:8]}) (signed out everywhere, owner notified) by admin (password): ffs test: lost phone") \
        in admin.events(kind="admin", q=address)


def test_recovery_key_removed(admin):
    client, session, address, password = member()
    res = requests.post(f"{AUTH}/v1/recoveryKey", json={"recoveryKeyId": uuid.uuid4().hex, "recoveryData": "eyJhbGciOiJkaXIifQ..ffs.test.data"},
                        headers=bearer(session), timeout=30)
    assert res.status_code == 200, res.text
    exists = lambda: requests.post(f"{AUTH}/v1/recoveryKey/exists", json={}, headers=bearer(session), timeout=30).json()["exists"]
    assert exists()
    assert "no recovery key" not in account_row(admin, address)
    # without signing out: the box unchecked
    _, done = admin.confirm(f"/accounts/{session.uid}/remove-recovery-key")
    assert f"Removed the account recovery key of {address} (uid {session.uid[:8]}) (owner notified)" in done, done[:3000]
    assert not exists()
    assert '<span class="badge">no recovery key</span>' in account_row(admin, address)
    assert mails(address, 'subject:"Account recovery key removed"'), "no notice to the owner"


def test_secondary_emails_listed(admin):
    client, session, address, password = member()
    second = f"ffs-second-{uuid.uuid4().hex[:8]}@example.org"
    jwt = mfa(session, address, "email")
    res = requests.post(f"{AUTH}/v1/mfa/recovery_email", json={"email": second}, headers=jwt, timeout=30)
    assert res.status_code == 200, res.text
    # in the accounts database once confirmed (until then the accounts service keeps it in Redis)
    res = requests.post(f"{AUTH}/v1/mfa/recovery_email/secondary/verify_code", json={"email": second, "code": wait_for_code(second)}, headers=jwt, timeout=30)
    assert res.status_code == 200, res.text
    emails = admin.get(f"/users/{session.uid}").split('<table id="emails"')[1].split("</table>")[0]
    assert re.search(r"<td>" + re.escape(address) + r"</td><td>primary</td><td>yes</td>", emails), emails
    assert re.search(r"<td>" + re.escape(second) + r"</td><td>secondary</td><td>yes</td>", emails), emails
    # found by its secondary email: on the overview, and /find goes to its page
    assert f'href="/users/{session.uid}"' in admin.search(second)
    res = admin.http.get(f"{ADMIN}/find", params={"q": second.upper()}, allow_redirects=False, timeout=30)
    assert res.status_code == 303 and res.headers["Location"] == f"/users/{session.uid}", (res.status_code, res.headers.get("Location"))


def session_ref(session):
    """The ref of a session in the admin UI: SHA-256 of its token id"""
    import hashlib
    return hashlib.sha256(bytes.fromhex(HawkTokenAuth(session.token, "sessionToken").id)).hexdigest()


def session_status(session):
    """What the accounts service says of a session: verified (the email and the sign-in), sessionVerified, emailVerified"""
    res = requests.get(f"{AUTH}/v1/recovery_email/status", auth=HawkTokenAuth(session.token, "sessionToken"), timeout=30)
    assert res.status_code == 200, res.text
    return res.json()


def pending_sign_ins(admin):
    """The accounts the Needs attention line counts, with a sign-in waiting for its code (0: no line)"""
    for text, href in attention_of(admin.page()):
        if "with a sign-in that never entered its email code" in text:
            assert "Confirm it if you know it is them" in text, text
            return int(text.split()[0]), href
    return 0, None


def test_confirm_an_email_from_the_admin_ui(admin):
    address, password = email("example.com"), uuid.uuid4().hex
    client = Client(server_url=f"{AUTH}/v1")
    created = int(time.time() * 1000)
    # signed up, the code never entered: its sign-in waits too
    session = client.create_account(address, password, keys=True)
    uid, ref = session.uid, session_ref(session)
    assert session_status(session)["sessionVerified"] is False
    waiting, _ = pending_sign_ins(admin)
    assert waiting >= 1
    assert f'href="/accounts/{uid}/confirm-email"' in admin.get(f"/users/{uid}")
    page, done = admin.confirm(f"/accounts/{uid}/confirm-email", reason="ffs test: the code never arrived")
    assert "skips the proof" in page and "The sign-in below, waiting for its code, is confirmed too" in page, page[:3000]
    assert '<table id="confirm-pending"' in page and f'name="sessions" value="{ref}"' in page, page[:3000]
    want = f"Confirmed the email of {address} (uid {uid[:8]}) and its 1 pending sign-in (owner notified)"
    assert want in done, done[:3000]
    assert '<span class="visually-hidden">, email confirmed</span></td>' in account_row(admin, address) and "/confirm-email" not in admin.get(f"/users/{uid}")
    # the sign-in of the sign-up confirmed as its code would: its keys, and Sync
    status = session_status(session)
    assert status["verified"] is True and status["sessionVerified"] is True and status["emailVerified"] is True, status
    bearer_token, key_id = sync_token(session, created)
    assert tokenserver(bearer_token, key_id).status_code == 200
    assert "unconfirmed sign-in" not in account_row(admin, address)
    assert pending_sign_ins(admin)[0] == waiting - 1
    assert ("admin", f"{want} by admin (password): ffs test: the code never arrived") in admin.events(kind="admin", q=address)
    assert mails(address, 'subject:"email confirmed by an administrator"'), "no notice to the owner"
    # a new sign-in works as for any account
    signed_in(client, address, password)
    # confirmed already (a second click, a stale page): refused, recorded once
    res = admin.http.post(f"{ADMIN}/accounts/{uid}/confirm-email", data={"csrf": admin.csrf()}, timeout=30)
    assert failed(res.text) == ["the email is already confirmed"], failed(res.text)
    assert len([d for _, d in admin.events(kind="admin", q=address) if d.startswith("Confirmed the email")]) == 1


def test_confirm_a_new_sign_in_from_the_admin_ui(admin, fxa_db):
    client, session, address, password = member(keys=True)
    uid = session.uid
    # older than the 48 hours in which Mozilla skips the sign-in code of a new account
    sql(fxa_db, "UPDATE fxa.accounts SET createdAt = createdAt - 3 * 86400000 WHERE normalizedEmail = :e", e=address)
    second = client.login(address, password, keys=True)
    assert not second.verified, "no sign-in code asked"
    ref = session_ref(second)
    # only for the sign-in waiting: not for the first one, confirmed with its code
    page = admin.get(f"/users/{uid}")
    assert f'href="/users/{uid}/sessions/{ref}/confirm"' in page and f'/sessions/{session_ref(session)}/confirm"' not in page, page[-6000:]
    waiting, href = pending_sign_ins(admin)
    assert waiting >= 1 and (waiting > 1 or href == f"/users/{uid}#sessions-card"), (waiting, href)

    page, done = admin.confirm(f"/users/{uid}/sessions/{ref}/confirm", reason="ffs test: a new laptop, they called")
    assert f"Confirm a sign-in of {address}?" in page and "whoever has the password gets in" in page and '<table id="confirm-pending"' in page, page[:3000]
    confirmed = re.search(r"Confirmed a sign-in of " + re.escape(f"{address} (uid {uid[:8]})") + r" \(([^()]+)\) \(owner notified\)", html.unescape(done))
    assert confirmed, done[:3000]
    assert session_status(second)["sessionVerified"] is True
    second.fetch_keys()
    authorize(second)
    page = admin.get(f"/users/{uid}")
    assert f'/sessions/{ref}/confirm"' not in page and "unconfirmed sign-in" not in account_row(admin, address)
    assert pending_sign_ins(admin)[0] == waiting - 1
    assert mails(address, 'subject:"A sign-in to your account confirmed by an administrator"'), "no notice to the owner"
    assert ("admin", f"{confirmed.group(0)} by admin (password): ffs test: a new laptop, they called") in admin.events(kind="admin", q=address)
    # again (a stale page): refused, nothing recorded
    res = admin.http.post(f"{ADMIN}/users/{uid}/sessions/{ref}/confirm", data={"csrf": admin.csrf()}, timeout=30)
    assert failed(res.text) == ["the sign-in is already confirmed"], failed(res.text)
    assert len([d for _, d in admin.events(kind="admin", q=address) if d.startswith("Confirmed a sign-in")]) == 1


def session_cells(admin, uid, session):
    """The cells of a session on the account page: (confirmed, signed in, last used)"""
    import hashlib
    ref = hashlib.sha256(bytes.fromhex(HawkTokenAuth(session.token, "sessionToken").id)).hexdigest()
    page = admin.get(f"/users/{uid}")
    assert HawkTokenAuth(session.token, "sessionToken").id not in page, "a session token id on the page"
    rows = page.split('<table id="sessions"')[1].split("</table>")[0]
    row = [r for r in rows.split("<tr>") if f"/sessions/{ref}/" in r]
    assert row, rows
    cells = re.findall(r"<td>(.*?)</td>", row[0])
    times = re.findall(r'<time datetime="([^"]+)">', row[0])
    return cells[3], times[0], times[1]


def test_unconfirmed_sign_in_and_last_used(admin):
    address, password = email("example.com"), uuid.uuid4().hex
    session = Client(server_url=f"{AUTH}/v1").create_account(address, password)
    confirmed, _, _ = session_cells(admin, session.uid, session)
    assert 'class="badge">unconfirmed sign-in' in confirmed and 'class="badge">unconfirmed sign-in' in account_row(admin, address)
    session.verify_email_code(wait_for_code(address))
    confirmed, signed, used = session_cells(admin, session.uid, session)
    assert "unconfirmed" not in confirmed and "unconfirmed sign-in" not in account_row(admin, address), confirmed
    # the accounts service writes the use to Redis only
    time.sleep(1.5)
    assert requests.get(f"{AUTH}/v1/account/devices", headers=bearer(session), timeout=30).status_code == 200
    _, signed_after, used_after = session_cells(admin, session.uid, session)
    assert used_after > used and used_after > signed_after, (signed_after, used, used_after)


EVENTS = os.environ.get("FXA_ACCOUNT_EVENTS", "") == "true"


def new_code(address, seen):
    """The sign-in code of the first email to address not in seen"""
    from test_fxa_flow import MAILPIT
    deadline = time.time() + 60
    while time.time() < deadline:
        for m in mails(address):
            if m["ID"] not in seen:
                headers = requests.get(f"{MAILPIT}/api/v1/message/{m['ID']}/headers", timeout=10).json()
                if headers.get("X-Signin-Verify-Code"):
                    return headers["X-Signin-Verify-Code"][0]
        time.sleep(1)
    raise AssertionError(f"no new sign-in code for {address}")


def security_history(admin, uid):
    """The security history of the account page: (event, when, IP address, confirmed)"""
    page = admin.get(f"/users/{uid}")
    if '<table id="security-events"' not in page:
        return []
    table = page.split('<table id="security-events"')[1].split("</table>")[0]
    return [tuple(html.unescape(re.sub(r"<[^>]+>", "", c)).strip() for c in re.findall(r"<td>(.*?)</td>", row, re.S))
            for row in re.findall(r"<tr>(.*?)</tr>", table, re.S) if "<td>" in row]


@pytest.mark.skipif(not EVENTS, reason="FXA_ACCOUNT_EVENTS is not true: no security history")
def test_security_history(admin, fxa_db):
    from fxa.crypto import derive_key, quick_stretch_password
    client, session, address, password = member()
    uid = session.uid
    # older than the 48 hours in which Mozilla skips the sign-in code of a new account
    sql(fxa_db, "UPDATE fxa.accounts SET createdAt = createdAt - 3 * 86400000 WHERE normalizedEmail = :e", e=address)

    def confirmed_sign_in(pw):
        seen = {m["ID"] for m in mails(address)}
        # a code to type, as Firefox asks (not the link of the default)
        signed = client.login(address, pw, keys=True, verification_method="email-otp")
        assert not signed.verified, "no sign-in code asked"
        res = requests.post(f"{AUTH}/v1/session/verify_code", json={"code": new_code(address, seen)},
                            auth=HawkTokenAuth(signed.token, "sessionToken"), timeout=30)
        assert res.status_code == 200, res.text
        return signed

    confirmed_sign_in(password)
    # a confirmed sign-in from this address: Mozilla would let the next ones skip the code
    # for 7 days, the stack never (IP_PROFILING_RECENCY=0)
    second = client.login(address, password, keys=True, verification_method="email-otp")
    assert not second.verified, "the sign-in code skipped for a known IP address"
    # the password changed in the account settings (a new wrapped key: this account has no data)
    auth_pw = lambda pw: derive_key(quick_stretch_password(address, pw), "authPW").hex()
    new_password = uuid.uuid4().hex
    res = requests.post(f"{AUTH}/v1/mfa/password/change", headers=mfa(session, address, "password"), timeout=30,
                        json={"email": address, "oldAuthPW": auth_pw(password), "authPW": auth_pw(new_password), "wrapKb": os.urandom(32).hex()})
    assert res.status_code == 200, res.text
    again = confirmed_sign_in(new_password)
    res = requests.post(f"{AUTH}/v1/recoveryKey", json={"recoveryKeyId": uuid.uuid4().hex, "recoveryData": "eyJhbGciOiJkaXIifQ..ffs.test.data"},
                        headers=bearer(again), timeout=30)
    assert res.status_code == 200, res.text
    # two-step authentication: on (with its backup codes), the authenticator app replaced,
    # new backup codes, off; all by the owner
    enable_totp(again, address)
    jwt = mfa(again, address, "2fa")
    res = requests.post(f"{AUTH}/v1/mfa/totp/replace/start", json={}, headers=jwt, timeout=30)
    assert res.status_code == 200, res.text
    res = requests.post(f"{AUTH}/v1/mfa/totp/replace/confirm", json={"code": totp_code(res.json()["secret"])}, headers=jwt, timeout=30)
    assert res.status_code == 200, res.text
    res = requests.put(f"{AUTH}/v1/mfa/recoveryCodes", json={"recoveryCodes": [uuid.uuid4().hex[:10] for _ in range(8)]}, headers=jwt, timeout=30)
    assert res.status_code == 200, res.text
    res = requests.post(f"{AUTH}/v1/mfa/totp/destroy", json={}, headers=jwt, timeout=30)
    assert res.status_code == 200, res.text
    res = requests.delete(f"{AUTH}/v1/recoveryKey", headers=bearer(again), timeout=30)
    assert res.status_code == 200, res.text
    # the password forgotten: reset with the code of the email
    res = use_reset_code(*reset_code(address))
    assert res.status_code == 200, res.text
    res = requests.post(f"{AUTH}/v1/account/reset", json={"authPW": auth_pw(uuid.uuid4().hex)},
                        auth=HawkTokenAuth(res.json()["accountResetToken"], "accountResetToken"), timeout=30)
    assert res.status_code == 200, res.text

    history = security_history(admin, uid)
    events = [row[0] for row in history]
    changes = ["password changed", "recovery key created", "two-step authentication turned on", "authenticator app replaced",
               "backup codes created", "two-step authentication turned off", "recovery key removed", "password reset (forgotten password)"]
    for event in ["signed in", "new password saved", "backup codes set (turning on two-step authentication)"] + changes:
        assert event in events, (event, history)
    logins = [row for row in history if row[0] == "signed in"]
    ip = logins[0][2]
    assert re.fullmatch(r"[0-9a-f.:]+", ip) and all(row[2] == ip for row in logins), history
    # the second sign-in never entered its code
    assert [row[3] for row in logins].count("not confirmed") >= 1 and "yes" in [row[3] for row in logins], history
    assert "account.password_changed" not in admin.get(f"/users/{uid}"), "Mozilla's name instead of the label"
    # the changes: events of kind security, alerts, Prometheus
    want = [f"{address} (uid {uid[:8]}): {change}, from {ip}" for change in changes]
    deadline = time.time() + 90
    while time.time() < deadline:
        logged = [detail for _, detail in admin.events(kind="security", q=address)]
        alerts = alert_text()
        if all(w in logged for w in want) and all(f"security: {w}" in alerts for w in want):
            break
        time.sleep(3)
    else:
        raise AssertionError(f"security events {logged}, alerts {alert_text()[:3000]}")
    # each once; not the sign-ins, nor what comes with a change already alerted (a password
    # change records a "new password saved" too, turning on 2-step its backup codes)
    assert sorted(logged) == sorted(want), logged
    assert alerts.count(f"security: {address} (uid {uid[:8]}): password changed") == 1, alerts[:3000]
    for quiet in ("new password saved", "backup codes set", "signed in"):
        assert f"{address} (uid {uid[:8]}): {quiet}" not in alerts, (quiet, alerts[:3000])
    res = requests.get(f"{ADMIN}/metrics", headers={"Authorization": "Bearer ffs-test-metrics-token"}, timeout=30)
    for name in ("account.login", "account.password_changed", "account.password_reset_success", "account.recovery_key_added",
                 "account.two_factor_replace_success", "account.reset"):
        assert re.search(r'^ffs_security_events_total\{event="' + re.escape(name) + r'"\} [1-9]', res.text, re.M), (name, res.text[-2000:])


@pytest.mark.skipif(EVENTS, reason="FXA_ACCOUNT_EVENTS is true")
def test_security_history_off(admin):
    client, session, address, password = member()
    signed_in(client, address, password)
    page = admin.get(f"/users/{session.uid}")
    assert 'id="events-off"' in page and "<code>FXA_ACCOUNT_EVENTS=true</code>" in page and not security_history(admin, session.uid), page[-4000:]


def alert_text():
    from test_fxa_flow import MAILPIT
    found = mails("admin@fxa.test")
    return " ".join(requests.get(f"{MAILPIT}/api/v1/message/{m['ID']}", timeout=10).json().get("Text", "") for m in found)


def test_blocked_member_alert_and_lift(admin):
    client, session, address, password = member()
    stranger = email("example.org")
    # (not with PyFxA: it waits for the end of a block)
    login = lambda who: requests.post(f"{AUTH}/v1/account/login", json={"email": who, "authPW": "00" * 32}, timeout=30).status_code
    for who in (address, stranger):
        codes = [login(who) for _ in range(7)]
        assert 429 in codes, codes
    # one alert (HEALTH_CHECK_SECONDS and ALERT_INTERVAL_SECONDS are 5 in the tests)
    deadline = time.time() + 60
    while f"blocked: {address} (uid {session.uid[:8]}) blocked until" not in alert_text() and time.time() < deadline:
        time.sleep(2)
    time.sleep(12)  # a few more rounds: still one
    text = alert_text()
    assert text.count(f"blocked: {address} (uid {session.uid[:8]}) blocked until") == 1, text[-3000:]
    assert stranger not in text, "alert for an email that has no account"
    assert '<span class="badge">blocked</span>' in account_row(admin, address)
    # in Needs attention, with the Security page; the list of the blocked has it
    assert any(re.match(r"\d+ accounts? blocked by the rate limits\.$", text) and href == "/security" for text, href in attention_of(admin.page())), attention_of(admin.page())
    assert f'<tr data-email="{address}">' in admin.get("/?show=blocked")
    # lifted from the account page
    page = admin.get(f"/users/{session.uid}")
    box = page.split('id="blocked"')[1].split("</div>")[0]
    key = re.search(r'name="key" value="([^"]+)"', box).group(1)
    csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', page).group(1)
    res = admin.http.post(f"{ADMIN}/security/unblock", data={"csrf": csrf, "key": key, "back": f"/users/{session.uid}"}, timeout=30)
    assert res.url.endswith(f"/users/{session.uid}") and "Lifted the block" in res.text and 'id="blocked"' not in res.text, res.text[:3000]
    assert login(address) == 400
    client.login(address, password)
    assert ("blocked", f"{address} (uid {session.uid[:8]})") in [(k, d.split(" blocked until")[0]) for k, d in admin.events(kind="blocked", q=address)]


def test_inactive_device_line_and_badge(admin):
    # ADMIN_STALE_DAYS=0 in the test stack: every device is inactive
    _, session, address, _ = member()
    device = requests.post(f"{AUTH}/v1/account/device", json={"name": "ffs old laptop", "type": "desktop"}, headers=bearer(session), timeout=30)
    assert device.status_code == 200, device.text
    lines = [(text, href) for text, href in attention_of(admin.page()) if "not used for 0 days (ADMIN_STALE_DAYS)" in text]
    assert len(lines) == 1 and re.match(r"\d+ devices? of \d+ accounts? not used for 0 days", lines[0][0]), attention_of(admin.page())
    href = lines[0][1]
    assert href in ("/?show=inactive-devices#accounts", f"/users/{session.uid}#devices"), href
    if href.startswith("/?"):
        assert re.search(r'inactive device', account_row(admin, address)) and f'<tr data-email="{address}">' in admin.get(href.split("#")[0])
    page = admin.get(f"/users/{session.uid}")
    row = re.search(r"<tr><td>ffs old laptop</td>(.*?)</tr>", page.split('<table id="devices"')[1], re.S)
    assert row and '<span class="badge">inactive</span>' in row.group(1), page.split('<table id="devices"')[1][:2000]


def test_search_by_part_of_an_email(admin):
    _, session, address, _ = member()
    part = address.split("@")[0][-7:].upper()
    page = admin.search(part)
    assert page.count("<tr data-email=") == 1 and f'<tr data-email="{address}">' in page, page.split('<table id="accounts"')[1][:2000]
    assert f'id="search-result">1 account matching &#34;{part}&#34;' in page and f'value="{part}"' in page
    # its account id, and nothing for what no account has
    assert f'<tr data-email="{address}">' in admin.search(session.uid[:12])
    assert "No account matches." in admin.search("ffs-nobody-has-this")


def test_unknown_account_changes_nothing(admin):
    # valid hex, no account: refused by the procedure, no event, no note
    uid = uuid.uuid4().hex
    res = admin.http.post(f"{ADMIN}/accounts/{uid}/disable", data={"csrf": admin.csrf(), "reason": "ffs test"}, timeout=30)
    assert failed(res.text) == ["no such account"], failed(res.text)
    assert not admin.events(kind="admin", q=uid), admin.events(kind="admin", q=uid)

def test_notes_and_the_disable_reason(admin):
    client, session, address, password = member()
    uid = session.uid
    page = admin.post(f"/users/{uid}/note", note="<b>Alice</b> from accounting")
    assert f"Note of {address} (uid {uid[:8]}) set to" in page
    assert '<span class="note">&lt;b&gt;Alice&lt;/b&gt; from accounting</span>' in account_row(admin, address)
    assert 'value="&lt;b&gt;Alice&lt;/b&gt; from accounting"' in admin.get(f"/users/{uid}")
    res = admin.http.post(f"{ADMIN}/users/{uid}/note", data={"csrf": admin.csrf(), "note": "x" * 501}, timeout=30)
    assert failed(res.text) == ["a note has at most 500 characters, not 501"], failed(res.text)
    # the reason of the confirm page goes into the note
    admin.confirm(f"/accounts/{uid}/disable", reason="ffs test: left the company")
    assert '<span class="note">&lt;b&gt;Alice&lt;/b&gt; from accounting; ffs test: left the company</span>' in account_row(admin, address)
    admin.post(f"/accounts/{uid}/enable")
    admin.post(f"/users/{uid}/note", note="")
    assert 'class="note"' not in account_row(admin, address)
    events = [d for _, d in admin.events(kind="admin", q=address)]
    assert any(d.startswith(f"Note of {address} (uid {uid[:8]}) set to") for d in events), events
    assert f"Removed the note of {address} (uid {uid[:8]}) by admin (password)" in events, events


# email delivery, what the server sees of its public URLs, onboarding (docs/admin/monitoring.md)

def health_row(admin, component, timeout=90):
    """The status cell of a component in the health table, once it is up (or the last one)"""
    deadline = time.time() + timeout
    while True:
        health = admin.page().split('<table id="health"')[1].split("</table>")[0]
        row = re.search(r"<td>" + re.escape(component) + r"</td><td>(.*?)</td>", health)
        if row and '<span class="ok">up</span>' in row.group(1) or time.time() > deadline:
            return row.group(1) if row else health
        time.sleep(3)


def mail_text(message_id):
    from test_fxa_flow import MAILPIT
    return requests.get(f"{MAILPIT}/api/v1/message/{message_id}", timeout=10).json()


def test_smtp_health_and_test_email(admin):
    # mailpit:1025 of the test stack, which accepts any password
    row = health_row(admin, "Email (SMTP)")
    assert '<span class="ok">up</span>' in row and "mailpit:1025, signs in as test" in row, row
    before = {m["ID"] for m in mails("admin@fxa.test", 'subject:"firefox-sync: test email"')}
    # a typed address is never used
    page = admin.post("/alerts/test", to="someone@example.org")
    assert "Sent a test email to admin@fxa.test" in page, page[:2000]
    deadline = time.time() + 30
    while not {m["ID"] for m in mails("admin@fxa.test", 'subject:"firefox-sync: test email"')} - before and time.time() < deadline:
        time.sleep(1)
    new = [m for m in mails("admin@fxa.test", 'subject:"firefox-sync: test email"') if m["ID"] not in before]
    assert new and "Alerts reach you this way" in mail_text(new[0]["ID"])["Text"], new
    assert not mails("someone@example.org"), "sent to the typed address"
    assert ("admin", "Sent a test email to admin@fxa.test by admin (password)") in admin.events(kind="admin", q="test email")
    # the last alert email (sent every ALERT_INTERVAL_SECONDS=5), in Prometheus too
    assert re.search(r'id="alert-status">Alert emails to admin@fxa.test: last sent \d{4}-', admin.page()), admin.page()[:3000]
    metrics = requests.get(f"{ADMIN}/metrics", headers={"Authorization": "Bearer ffs-test-metrics-token"}, timeout=30).text
    assert int(re.search(r"^ffs_alert_last_success_timestamp_seconds (\d+)$", metrics, re.M).group(1)) > time.time() - 3600, metrics


def test_public_urls_and_certificates(admin):
    # through the reverse proxy under test (TEST_PROXY of tests/e2e-fxa.sh): certificates of 30 days,
    # Caddy's own CA (CADDY_ACME_CA=internal of proxy/Caddyfile.bundled) or a test CA
    for component, host in (("Public Sync URL", "sync.fxa.test"), ("Public accounts pages", "accounts.fxa.test"),
                            ("Public accounts API", "api.fxa.test"), ("Public profile server", "profile.fxa.test")):
        row = health_row(admin, component)
        days = re.search(re.escape(host) + r": reachable, certificate expires in (\d+) days", row)
        assert '<span class="ok">up</span>' in row and days and 14 <= int(days.group(1)) <= 30, (component, row)
    row = health_row(admin, "Sign-up gate")
    assert "POST api.fxa.test/v1/account/create goes through the sign-up gate" in row, row
    metrics = requests.get(f"{ADMIN}/metrics", headers={"Authorization": "Bearer ffs-test-metrics-token"}, timeout=30).text
    for host in ("sync.fxa.test", "accounts.fxa.test", "api.fxa.test", "profile.fxa.test"):
        seconds = re.search(r'^ffs_cert_expiry_seconds\{host="' + re.escape(host) + r'"\} (\d+)$', metrics, re.M)
        assert seconds and int(seconds.group(1)) > 14 * 86400, (host, metrics[-2000:])
    # FXA_OAUTH_SERVER_URL answers, the node is the public Sync URL
    checks = admin.page().split('<table id="setup"')[1].split("</table>")[0]
    # (and the accounts pages send nothing out of the stack: their Glean endpoint is themselves)
    for name in ("Sync node", r"Sign-in keys \(FXA_OAUTH_SERVER_URL\)", r"Account emails \(FXA_EMAIL_DOMAIN\)", "Telemetry of the accounts pages"):
        assert re.search(r"<td>" + name + r'</td><td><span class="ok">ok</span>', checks), (name, checks)


def test_gate_probe_creates_nothing(admin):
    # with open sign-ups: the gate answers the probe of its own token only, anything else
    # goes on to the accounts service, which creates nothing from an empty body
    policy = re.search(r'<textarea id="allowlist" name="allowlist" rows="5">(.*?)</textarea>', admin.page(), re.S).group(1)
    total = lambda: re.search(r'<span id="accounts-total">(\d+)</span>', admin.page()).group(1)
    accounts = total()
    admin.post("/accounts/signups", mode="open", allowlist="")
    try:
        for token in ("", "guessed-token"):
            res = requests.post(f"{AUTH}/v1/account/create", data="{}", timeout=30,
                                headers={"Content-Type": "application/json", "X-Ffs-Gate-Probe": token})
            assert res.status_code == 400 and "X-Ffs-Gate-Probe" not in res.headers, (token, res.status_code, res.headers)
        assert total() == accounts
    finally:
        admin.post("/accounts/signups", mode="allowlist", allowlist=policy)


def test_schema_levels(admin):
    schema = admin.page().split('<table id="schema"')[1].split("</table>")[0]
    levels = dict(re.findall(r"<tr><td>([^<]+)</td><td>([^<]*)</td>", schema))
    # the accounts databases' schema-patch-level (fxa 201, fxa_oauth 40 in v1.348), and syncstorage-rs's migrations
    assert int(levels["fxa"]) >= 201 and int(levels["fxa_oauth"]) >= 40, levels
    for name in ("fxa_profile", TOKENSERVER) + (() if SYNC_POSTGRES else ("Sync storage",)):
        assert levels.get(name), (name, levels)
    # FxA records no time: said, not left blank; syncstorage-rs's migrations have theirs
    for name in ("fxa", "fxa_oauth", "fxa_profile", "pushbox"):
        assert re.search(r"<tr><td>" + name + r'</td><td>\d+</td><td><span class="quiet-text">not recorded by FxA</span></td></tr>', schema), (name, schema)
    assert re.search(r"<tr><td>" + re.escape(TOKENSERVER) + r"</td><td>\d+[^<]*</td><td>\d{4}-\d\d-\d\d \d\d:\d\d</td></tr>", schema), schema


def allowlist_row(admin, address):
    row = re.search(r'<tr data-entry="' + re.escape(address) + r'">(.*?)</tr>', admin.page(), re.S)
    return row and row.group(1)


def test_invite_sign_up_and_remove(admin):
    address = email("example.net")  # not on the allowlist: example.net is not
    page = admin.post("/accounts/invite", email=address)
    assert f"Invited {address} (added to the sign-up allowlist), email sent" in page, page[:2000]
    deadline = time.time() + 30
    while not mails(address) and time.time() < deadline:
        time.sleep(1)
    found = mails(address)
    assert found and found[0]["Subject"] == "Your Firefox Sync account on accounts.fxa.test", found
    message = mail_text(found[0]["ID"])
    text = message["Text"]
    # this server's values, plain text only
    for part in (f"identity.fxaccounts.autoconfig.uri to {CONTENT}", f"{CONTENT}/?email={requests.utils.quote(address, safe='')}",
                 f"Custom Mozilla account server to {CONTENT}. Leave Custom Sync server empty", f"Custom Account Content Server URI to {CONTENT}"):
        assert part in text, (part, text)
    assert not message.get("HTML"), "an HTML part"
    row = allowlist_row(admin, address)
    assert row and "not signed up yet" in row and re.search(r"invited \d{4}-\d\d-\d\d", row), row
    # they sign up: the allowlist lets them in, the row says so
    session = Client(server_url=f"{AUTH}/v1").create_account(address, uuid.uuid4().hex)
    session.verify_email_code(wait_for_code(address))
    row = allowlist_row(admin, address)
    assert row and re.search(r"signed up on \d{4}-\d\d-\d\d", row) and f'href="/users/{session.uid}"' in row, row
    # Remove is a link to a confirm page, which says what happens; its form removes it
    assert f'href="/accounts/allowlist/remove?entry={requests.utils.quote(address)}"' in row and 'action="/accounts/allowlist/remove"' not in admin.page()
    confirm, page = admin.confirm(f"/accounts/allowlist/remove?entry={requests.utils.quote(address)}")
    assert "An account already created with it stays" in confirm and f'<input type="hidden" name="entry" value="{address}">' in confirm, confirm[:3000]
    assert f"Removed {address} from the sign-up allowlist" in page and not allowlist_row(admin, address)
    assert ("admin", f"Removed {address} from the sign-up allowlist by admin (password)") in admin.events(kind="admin", q=address)
    # the account stays
    assert f'<tr data-email="{address}">' in admin.page()


def test_stale_policy_save_keeps_new_invitations(admin):
    # a page loaded before an invitation, saved after it: the invitation stays
    stale = admin.page()
    policy = re.search(r'<textarea id="allowlist" name="allowlist" rows="5">(.*?)</textarea>', stale, re.S).group(1)
    loaded = html.unescape(re.search(r'<input type="hidden" name="loaded" value="([^"]*)">', stale).group(1))
    address = email("example.net")
    assert "added to the sign-up allowlist" in admin.post("/accounts/invite", email=address)
    try:
        admin.post("/accounts/signups", mode="allowlist", allowlist=html.unescape(policy), loaded=loaded)
        assert allowlist_row(admin, address), "invitation dropped by a stale save"
    finally:
        admin.post("/accounts/allowlist/remove", entry=address)


def test_invite_without_the_allowlist(admin):
    policy = re.search(r'<textarea id="allowlist" name="allowlist" rows="5">(.*?)</textarea>', admin.page(), re.S).group(1)
    try:
        for mode in ("open", "closed"):
            admin.post("/accounts/signups", mode=mode, allowlist=policy)
            address = email("example.org")
            res = admin.http.post(f"{ADMIN}/accounts/invite", data={"csrf": admin.csrf(), "email": address}, timeout=30)
            assert f"Invited {address}, email sent" in res.text, res.text[:2000]
            assert not allowlist_row(admin, address), "allowlist changed"
            warnings = failed(res.text)
            if mode == "closed":
                assert warnings == [f"sign-ups are closed: {address} cannot create an account until you open them"], warnings
            else:
                assert not warnings, warnings
            deadline = time.time() + 30
            while not mails(address) and time.time() < deadline:
                time.sleep(1)
            text = mail_text(mails(address)[0]["ID"])["Text"]
            assert ("Sign-ups are closed for now" in text) == (mode == "closed"), text
    finally:
        admin.post("/accounts/signups", mode="allowlist", allowlist=policy)


def test_connect_a_device_page(admin):
    steps = admin.get("/connect").split('id="device-steps"')[1]
    for part in (f"identity.fxaccounts.autoconfig.uri to {CONTENT}", f"Custom Mozilla account server to {CONTENT}. Leave Custom Sync server empty",
                 "tap the Firefox logo 5 times", "Connect another device", "wss://pairing.fxa.test"):
        assert part in steps, (part, steps[:3000])


def config_row(page, setting):
    """The value and the origin of a setting of the Configuration page, in plain text"""
    row = re.search(r"<tr><td>" + re.escape(setting) + r"</td>(.*?)</tr>", page, re.S)
    assert row, (setting, page[:3000])
    return " ".join(html.unescape(re.sub(r"<[^>]+>", " ", row.group(1))).split())


def test_configuration_page(admin):
    page = admin.get("/config")
    for setting, value in (("Accounts pages", CONTENT), ("Accounts API", AUTH), ("Sync server", SYNC),
                           ("Pairing server", "wss://pairing.fxa.test"), ("SMTP server", "mailpit")):
        assert config_row(page, setting).startswith(value + " "), (setting, config_row(page, setting))
    accounts = page.split('id="accounts-settings"')[1].split("</section>")[0]
    # the version the health check read from the server (9.7.2, 8.4.6)
    assert re.match((os.environ.get("FXA_DB_SERVER") or r"MySQL \d+\.\d+") + r"[.\d]* FXA_DB ", config_row(accounts, "Database")), config_row(accounts, "Database")
    # the settings of fxa-auth, given to the admin UI for this page (not the defaults)
    assert config_row(page, "Access token lifetime") == "60 minutes FXA_ACCESS_TOKEN_LIFETIME of the access tokens of Firefox"
    assert config_row(page, "Client IP address").startswith("2 FXA_CLIENT_ADDRESS_DEPTH")
    assert config_row(page, "Sign-up gate published on").startswith("127.0.0.1:")
    assert "FXA_SIGNUPS" in config_row(page, "Sign-ups") and "FXA_MAX_ACCOUNTS=" in config_row(page, "Max accounts")
    # the security history as the admin UI runs (FXA_ACCOUNT_EVENTS, true in tests/e2e-fxa.sh)
    want = "on" if EVENTS else "off"
    assert config_row(page, "Security history").startswith(want + " "), config_row(page, "Security history")
    # the admin UI signs in with these accounts (ADMIN_FXA_CLIENT_ID)
    if ADMIN_CLIENT_ID:
        assert "the self-hosted accounts" in config_row(page, "OpenID Connect issuer")
    # secrets: set, never their value
    assert config_row(page, "Password").startswith("set ADMIN_PASSWORD")
    assert config_row(page, "Password of ffs_admin (accounts)").startswith("set FXA_ADMIN_DB_PASSWORD")
    secrets = [os.environ["ADMIN_PASSWORD"], "ffs-test-metrics-token", urlsplit(os.environ["FXA_TEST_DB_URL"]).password,
               urlsplit(os.environ["SYNC_SYNCSTORAGE__DATABASE_URL"]).password, urlsplit(os.environ["ADMIN_DB_URL"]).password]
    for secret in secrets:
        assert secret and secret not in page
    # the test stack agrees with itself: the email domain, the sign-in keys, https
    hints = page.split('<section id="hints">')[1].split("</section>")[0]
    for wrong in ("FXA_EMAIL_DOMAIN is", "FXA_OAUTH_SERVER_URL is", "not an https:// URL", "not a wss:// URL", "are both on"):
        assert wrong not in hints, hints


# the life of an account: deleting it, its Sync data, pruning (docs/admin/accounts.md)

@pytest.fixture(scope="module")
def fxa_db():
    # the accounts database itself (FXA_MYSQL_USER), to look at and to age rows
    from sqlalchemy import create_engine
    conn = create_engine(os.environ["FXA_TEST_DB_URL"]).execution_options(isolation_level="AUTOCOMMIT").connect()
    yield conn
    conn.close()


@pytest.fixture(scope="module")
def sync_dbs():
    # the tokenserver, the storage, and the admin UI's own database (the notes) as its user
    from sqlalchemy import create_engine
    conns = [create_engine(os.environ[name]).execution_options(isolation_level="AUTOCOMMIT").connect()
             for name in ("SYNC_TOKENSERVER__DATABASE_URL", "SYNC_SYNCSTORAGE__DATABASE_URL", "ADMIN_DB_URL")]
    yield conns
    for c in conns:
        c.close()


def sql(conn, query, **args):
    from sqlalchemy.sql import text as sqltext
    return conn.execute(sqltext(query), args)


def syncing(session, created):
    """Sync a few bookmarks, like Firefox after sign-in: the Sync token"""
    bearer, key_id = sync_token(session, created)
    res = tokenserver(bearer, key_id)
    assert res.status_code == 200, res.text
    token = res.json()
    bookmarks = [{"id": f"bookmark{i:03d}", "payload": json.dumps({"title": "x" * 50})} for i in range(4)]
    assert storage(token, "POST", "/storage/bookmarks", bookmarks).status_code == 200
    return token


def sync_users(admin):
    return int(re.search(r'id="sync-users">(\d+)<', admin.page()).group(1))


@pytest.fixture
def room(admin):
    """Room for a few more accounts on the Sync server, max users as it was afterwards"""
    before = re.search(r'id="sync-max-users">(\d+)<', admin.page()).group(1)
    admin.post("/sync/max-users", max_users=str(sync_users(admin) + 3))
    yield
    admin.post("/sync/max-users", max_users=before)


def test_delete_an_account_for_good(admin, fxa_db, sync_dbs, room):
    tokens_db, storage_db, admin_db = sync_dbs
    address, password = email("example.net"), uuid.uuid4().hex
    # on the allowlist by itself (example.net is not)
    assert "added to the sign-up allowlist" in admin.post("/accounts/invite", email=address)
    client = Client(server_url=f"{AUTH}/v1")
    created = int(time.time() * 1000)
    session = client.create_account(address, password, keys=True)
    session.verify_email_code(wait_for_code(address))
    uid = session.uid
    token = syncing(session, created)
    users = sync_users(admin)
    path = f"/users/{uid}/delete"

    # active: not offered, and refused by the procedure itself
    page = admin.get(f"/users/{uid}")
    assert f'href="{path}"' not in page and "To delete this account for good, disable it first." in page
    assert admin.http.get(f"{ADMIN}{path}", timeout=30).status_code == 404
    res = admin.http.post(f"{ADMIN}{path}", data={"csrf": admin.csrf(), "confirm_email": address}, timeout=30)
    assert failed(res.text) == ["only a disabled account can be deleted: disable it first"], failed(res.text)
    assert exists(address)

    admin.confirm(f"/accounts/{uid}/disable")
    assert f'href="{path}"' in admin.get(f"/users/{uid}")
    admin.post(f"/users/{uid}/note", note="ffs test: to be forgotten")
    assert sql(admin_db, "SELECT COUNT(*) FROM ffs_account_notes WHERE uid = :u", u=uid).scalar() == 1
    # the email typed must match
    page, res = admin.confirm(path, ok=False, confirm_email="someone@example.net")
    assert f"Delete {address}?" in page and "fxa-profile-images" in page and '<label for="confirm_email">Type the email of the account' in page, page[:3000]
    assert [html.unescape(f) for f in failed(res)] == ["the email typed is not the account's: nothing deleted"], failed(res)
    assert exists(address)

    _, done = admin.confirm(path, confirm_email=address.upper(), reason="ffs test: asked to be forgotten")
    deleted = f"Deleted {address} (uid {uid}) and its Sync data (4 items, 252 B, 1 tokenserver rows)"
    assert deleted in done, done[:3000]
    # gone from the accounts service, the list and max users
    assert not exists(address)
    with pytest.raises(ClientError) as e:
        client.login(address, password)
    assert e.value.errno == 102, e.value  # unknown account
    assert f'<tr data-email="{address}">' not in admin.search(address) and sync_users(admin) == users - 1
    assert admin.http.get(f"{ADMIN}/users/{uid}", timeout=30).status_code == 404
    assert sql(fxa_db, "SELECT deletionReason FROM fxa.deletedAccounts WHERE uid = UNHEX(:uid)", uid=uid).scalar() == "fxa_admin_requested_account_delete"
    for table in ("fxa_oauth.refreshTokens", "fxa_oauth.tokens", "fxa_oauth.codes"):
        assert sql(fxa_db, f"SELECT COUNT(*) FROM {table} WHERE userId = UNHEX(:uid)", uid=uid).scalar() == 0, table
    # the tokenserver rows and the storage of their uids, and its note
    assert sql(tokens_db, "SELECT COUNT(*) FROM users WHERE email LIKE :e", e=f"{uid}@%").scalar() == 0
    assert sql(admin_db, "SELECT COUNT(*) FROM ffs_account_notes WHERE uid = :u", u=uid).scalar() == 0
    assert sql(storage_db, "SELECT COUNT(*) FROM bso WHERE userid = :u", u=token["uid"]).scalar() == 0
    # it cannot sign up again: no longer on the allowlist
    assert not allowlist_row(admin, address)
    res = create(address)
    assert res.status_code == 400 and res.json()["errno"] == 125, res.text
    # who did it, which account (the email stays in the event log), why
    assert ("admin", f"{deleted} by admin (password): ffs test: asked to be forgotten") in admin.events(kind="admin", q=address), admin.events(kind="admin", q=address)


def destroy(client, address, password):
    """POST /account/destroy, as the account settings do, with a confirmed sign-in"""
    from fxa._utils import hexstr
    from fxa.crypto import derive_auth_pw
    session = signed_in(client, address, password)
    stretched = session.stretchpwd if isinstance(session.stretchpwd, bytes) else (session.stretchpwd.v2 or session.stretchpwd.v1)
    try:
        client.apiclient.post("/account/destroy", {"email": address, "authPW": hexstr(derive_auth_pw(stretched))}, auth=session._auth)
    except ServerError:
        # the account is deleted, then the auth server fails to queue the rest of the
        # cleanup (Google Cloud Tasks, not part of this stack): what the purge is for
        pass


def test_reset_sync_of_an_account_that_never_synced(admin):
    # no tokenserver row: nothing to reset, no confirm page
    _, session, address, _ = member()
    uid = session.uid
    assert admin.http.get(f"{ADMIN}/users/{uid}/reset-sync", timeout=30).status_code == 404
    res = admin.http.post(f"{ADMIN}/users/{uid}/reset-sync", data={"csrf": admin.csrf()}, timeout=30)
    assert failed(res.text) == ["this account does not use this Sync server"], failed(res.text)
    assert not [d for _, d in admin.events(kind="admin", q=address) if d.startswith("Reset")]


def test_self_deleted_account_purged(admin, room, sync_dbs):
    address, password = email("example.com"), uuid.uuid4().hex
    client = Client(server_url=f"{AUTH}/v1")
    created = int(time.time() * 1000)
    session = client.create_account(address, password, keys=True)
    session.verify_email_code(wait_for_code(address))
    users = sync_users(admin)
    token = syncing(session, created)
    assert sync_users(admin) == users + 1
    admin.post(f"/users/{session.uid}/note", note="ffs test: deleted by its owner")
    count_notes = lambda: sql(sync_dbs[2], "SELECT COUNT(*) FROM ffs_account_notes WHERE uid = :u", u=session.uid).scalar()
    assert count_notes() == 1
    # its owner deletes it in the account settings: the Sync side is left behind
    destroy(client, address, password)
    assert not exists(address)
    orphans = table_rows(admin.page(), "orphans")
    mine = [o for o in orphans if o[1] == f"{session.uid}@api.fxa.test"]
    assert mine == [["account deleted", f"{session.uid}@api.fxa.test", str(token["uid"]), "4 items, 252 B"]], orphans
    assert sync_users(admin) == users + 1
    gone = len([o for o in orphans if o[0] == "account deleted"])
    _, done = admin.confirm("/storage/purge")
    assert re.search(r"Purged the Sync storage: [1-9]\d* orphans \(", done), done[:3000]
    # the slot is free again (and those of the others deleted, by earlier runs on a kept stack)
    assert sync_users(admin) == users + 1 - gone and f"{session.uid}@api.fxa.test" not in admin.page()
    # and its note: personal data, with no account page left to remove it from
    assert count_notes() == 0


def table_rows(page, name):
    """The rows of a table of a page, as lists of cells (tags removed)"""
    if f'<table id="{name}"' not in page:
        return []
    body = page.split(f'<table id="{name}"')[1].split("</table>")[0].split("<tbody>")[1]
    return [[re.sub(r"<[^>]+>", "", cell).strip() for cell in re.findall(r"<td>(.*?)</td>", row, re.S)]
            for row in re.findall(r"<tr[^>]*>(.*?)</tr>", body, re.S)]


def test_prune_expired_tokens(admin, fxa_db):
    client, session, address, password = member()
    uid = session.uid
    old = int(time.time() * 1000) - 40 * 86400 * 1000
    stale, kept = os.urandom(32), os.urandom(32)
    sql(fxa_db, "INSERT INTO fxa.unblockCodes (uid, unblockCodeHash, createdAt) VALUES (UNHEX(:uid), :hash, :at)", uid=uid, hash=os.urandom(32), at=old)
    for token in (stale, kept):
        sql(fxa_db, "INSERT INTO fxa.sessionTokens (tokenId, tokenData, uid, createdAt, uaBrowser) VALUES (:id, :data, UNHEX(:uid), :at, 'ffs-prune-test')",
            id=token, data=os.urandom(32), uid=uid, at=old)
    # a Firefox's session: it has a device
    sql(fxa_db, "INSERT INTO fxa.devices (uid, id, sessionTokenId, name, type, createdAt) VALUES (UNHEX(:uid), :id, :token, 'ffs prune test', 'desktop', :at)",
        uid=uid, id=os.urandom(16), token=kept, at=old)
    count = lambda q, **a: sql(fxa_db, q, uid=uid, **a).scalar()
    # a confirm page first: it deletes for good
    assert '<a href="/maintenance/prune" class="button secondary" id="prune">' in admin.get("/activity")
    confirm, page = admin.confirm("/maintenance/prune")
    assert "Prune the accounts database?" in confirm and "older than 30 days" in confirm, confirm[:3000]
    assert re.search(r"Pruned the accounts database: [1-9]\d* unblock codes, \d+ sign-in codes, \d+ reset and password tokens, [1-9]\d* sessions without a device", page), page[:3000]
    assert count("SELECT COUNT(*) FROM fxa.unblockCodes WHERE uid = UNHEX(:uid)") == 0
    assert count("SELECT COUNT(*) FROM fxa.sessionTokens WHERE tokenId = :t", t=stale) == 0
    assert count("SELECT COUNT(*) FROM fxa.sessionTokens WHERE tokenId = :t", t=kept) == 1
    # the account's own sign-in is new: kept too
    session.get_email_status()
    # when, and what it did
    jobs = admin.get("/activity").split('<table id="jobs"')[1].split("</table>")[0]
    assert re.search(r'<tr data-job="prune"><td>Prune the accounts database</td><td>\d{4}-\d\d-\d\d \d\d:\d\d</td><td>Pruned the accounts database: [1-9]', jobs), jobs
    assert re.search(r'id="prune-last-ran">[^<]*last pruned: \d{4}-\d\d-\d\d', admin.page())
    sql(fxa_db, "DELETE FROM fxa.devices WHERE uid = UNHEX(:uid)", uid=uid)
    sql(fxa_db, "DELETE FROM fxa.sessionTokens WHERE tokenId = :t", t=kept)


def test_delete_old_unconfirmed_accounts(admin, fxa_db):
    old, fresh = email("example.com"), email("example.com")
    for address in (old, fresh):
        Client(server_url=f"{AUTH}/v1").create_account(address, uuid.uuid4().hex)
    sql(fxa_db, "UPDATE fxa.accounts SET createdAt = createdAt - 10 * 86400000 WHERE normalizedEmail = :e", e=old)
    page, done = admin.confirm("/accounts/unconfirmed?days=1")
    listed = page.split('id="confirm-unconfirmed"')[1].split("</table>")[0]
    assert old in listed and fresh not in listed, listed
    assert re.search(r"Deleted [1-9]\d* accounts that never confirmed their email in 1 day: ", done), done[:3000]
    # the event names them
    assert any(old in d for _, d in admin.events(kind="admin", q=old)), admin.events(kind="admin", q=old)
    assert not exists(old) and exists(fresh)
    assert sql(fxa_db, "SELECT COUNT(*) FROM fxa.deletedAccounts WHERE deletionReason = 'fxa_unverified_account_delete'").scalar() >= 1
