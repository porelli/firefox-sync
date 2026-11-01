"""The admin UI with Mozilla's accounts: the Sync part only (no FxA database).

Runs after test_client_flow.py in the syncstorage-rs image, see tests/e2e.sh: the
account "alice" of the mock FxA syncs, SYNC_MAX_USERS is 1 (SYNC_MAX_USERS=initial:1 in .env, so
that the page manages it). tests/e2e.sh also runs the read-only test (-k read_only) while
the stack has a plain SYNC_MAX_USERS=1. The test stack sets
ADMIN_STALE_DAYS=0, METRICS_FLUSH_SECONDS=5, HEALTH_CHECK_SECONDS=5 and METRICS_TOKEN
(tests/compose/sync.yml).

Environment (besides those of test_client_flow.py):
  ADMIN_URL       the admin UI inside the stack's network (http://ffs-admin:8080)
  ADMIN_PASSWORD  its password
  BACKEND         mysql or postgres
  MAX_USERS_SETTING  SYNC_MAX_USERS of the stack as in .env (initial:1 or 1), SYNC_MAX_USERS the number
  ADMIN_DB_URL    the admin UI's own database (the event log, the notes), as its user
"""

import html
import json
import os
import re
import time
import urllib.parse as urlparse
from urllib.parse import urlsplit

import pytest
import requests
from sqlalchemy import create_engine
from sqlalchemy.sql import text as sqltext

from test_client_flow import EMAIL_DOMAIN, PROXY_HEADERS, SERVER, Storage, db, login  # noqa: F401 (db is a fixture)

ADMIN = os.environ["ADMIN_URL"].rstrip("/")
MYSQL = os.environ["BACKEND"] == "mysql"
METRICS_TOKEN = "ffs-test-metrics-token"
# SYNC_MAX_USERS=initial:N: max users is changed on the page, otherwise it is read-only there
EDITABLE = os.environ.get("MAX_USERS_SETTING", "").startswith("initial:")
editable = pytest.mark.skipif(not EDITABLE, reason="needs SYNC_MAX_USERS=initial:N")
# PostgreSQL keeps the storage in the tokenserver database; the admin UI has its own
DB_SIZES = (("Tokenserver", "Sync storage") if MYSQL else ("Sync (tokenserver and storage)",)) + ("Admin UI",)


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

    def post(self, path, **form):
        csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', self.get("/")).group(1)
        res = self.http.post(f"{ADMIN}{path}", data={"csrf": csrf, **form}, timeout=30)
        assert res.status_code == 200, res.text[:500]
        assert not failed(res.text), failed(res.text)
        return res.text

    def confirm(self, path, ok=True, **form):
        """Follows a link to a confirm page and submits its form (its token, hidden fields)"""
        page = self.get(path)
        action = re.search(r'<form method="post" action="([^"]+)" id="confirm">', page)
        assert action and 'id="cancel">Cancel</a>' in page, page[:3000]
        # (as a browser reads them: a note with a quote is &#39; in the page)
        fields = {k: html.unescape(v) for k, v in re.findall(r'<input type="hidden" name="([^"]+)" value="([^"]*)">', page.split('id="confirm">')[1])}
        res = self.http.post(f"{ADMIN}{action.group(1).replace('&amp;', '&')}", data={**fields, **form}, timeout=60)
        assert res.status_code == 200, res.text[:500]
        if ok:
            assert not failed(res.text), failed(res.text)
        return page, res.text


@pytest.fixture(scope="module")
def alice():
    # test_client_flow.py ended with a key change of alice: a new tokenserver uid, so
    # new (empty) storage. Sync bookmarks again with new keys, like Firefox after a
    # password reset; the admin UI shows the storage of the current keys.
    # The generation must grow: that key change may have been in this same second.
    time.sleep(1.1)
    now = int(time.time())
    res = login("alice", generation=now, keys_changed_at=now, client_state="cccc")
    assert res.status_code == 200, res.text
    storage = Storage(res.json())
    bookmarks = [{"id": f"bookmark{i:03d}", "payload": json.dumps({"title": "x" * 100})} for i in range(5)]
    res = storage.request("POST", "/storage/bookmarks", bookmarks)
    assert res.status_code == 200 and len(res.json()["success"]) == 5, res.text
    return storage


@pytest.fixture(scope="module")
def storage_db():
    # the storage database (with PostgreSQL the tokenserver's)
    url = os.environ["SYNC_SYNCSTORAGE__DATABASE_URL"]
    if url.startswith("postgres://"):
        url = url.replace("postgres://", "postgresql://", 1)
    conn = create_engine(url).execution_options(isolation_level="AUTOCOMMIT").connect()
    yield conn
    conn.close()


@pytest.fixture(scope="module")
def admin_db():
    # the admin UI's own database (ADMIN_DB_NAME), as its user: the event log, the notes
    url = os.environ["ADMIN_DB_URL"]
    if url.startswith("postgres://"):
        url = url.replace("postgres://", "postgresql://", 1)
    conn = create_engine(url).execution_options(isolation_level="AUTOCOMMIT").connect()
    yield conn
    conn.close()


@pytest.fixture(scope="module")
def admin(alice):
    # e2e.sh restarted the admin UI, and with it the Sync server: wait for a health
    # check that sees it up. Not before alice synced: /metrics caches the storage totals
    deadline = time.time() + 30
    while time.time() < deadline:
        res = requests.get(f"{ADMIN}/metrics", headers={"Authorization": f"Bearer {METRICS_TOKEN}"}, timeout=30)
        if 'ffs_up{component="Sync server"} 1\n' in res.text:
            break
        time.sleep(1)
    return Admin()


def test_sign_in_needs_the_password():
    http = requests.Session()
    res = http.get(f"{ADMIN}/", timeout=30)
    assert res.url.endswith("/login") and '<label for="password">' in res.text and 'name="password"' in res.text
    res = http.post(f"{ADMIN}/login", data={"password": "wrong"}, timeout=30)
    assert "Wrong password" in res.text
    assert http.get(f"{ADMIN}/", timeout=30).url.endswith("/login")
    # a form posted from another site, even with the right password
    res = http.post(f"{ADMIN}/login", data={"password": os.environ["ADMIN_PASSWORD"]},
                    headers={"Origin": "http://evil.example"}, timeout=30)
    assert res.status_code == 403
    assert http.get(f"{ADMIN}/", timeout=30).url.endswith("/login")


def test_forms_refuse_other_sites_and_missing_tokens(admin):
    csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', admin.get("/")).group(1)
    res = admin.http.post(f"{ADMIN}/sync/max-users", data={"csrf": csrf, "max_users": "50"},
                          headers={"Origin": "http://evil.example"}, timeout=30)
    assert res.status_code == 403
    res = admin.http.post(f"{ADMIN}/sync/max-users", data={"max_users": "50"}, timeout=30)
    assert res.status_code == 403
    assert re.search(r'id="sync-max-users">1<', admin.get("/"))


def test_health(admin):
    page = admin.get("/")
    health = page.split('<table id="health"')[1].split("</table>")[0]
    # Notifications: ADMIN_NOTIFY of the test stack (tests/notify_sink.py answers)
    components = ["Admin UI", "Sync server", "Tokenserver database", "Admin UI database", "Notifications"] + (["Storage database"] if MYSQL else [])
    for component in components:
        row = re.search(r"<td>" + re.escape(component) + r"</td><td>(.*?)</td>", health)
        assert row and '<span class="ok">up</span>' in row.group(1), (component, health)
    # the databases report their versions (MariaDB 11.x, MySQL 8.4.x on your own server or with SYNC_DB=mysql, PostgreSQL 18.x)
    database = os.environ.get("DATABASE_SERVER") or ("MariaDB" if MYSQL else "PostgreSQL")
    assert re.search(r"<td>Tokenserver database</td><td>.*?</td><td>" + database + r" \d+\.\d+", health), health
    # max users, with the accounts against it (1 of 1 here: full, a problem to check)
    users, max_users = (int(re.search(r'id="sync-' + i + r'">(\d+)<', page).group(1)) for i in ("users", "max-users"))
    limit = re.search(r"<td>Max users</td><td>(.*?)</td>", health)
    assert limit, health
    if users >= max_users:
        assert '<span class="pill warn">full</span>' in limit.group(1) and f"{users} of {max_users} accounts are taken (SYNC_MAX_USERS)" in limit.group(1), limit.group(1)
    else:
        assert f"{users} of {max_users} taken" in limit.group(1), limit.group(1)
    # the thresholds of the errors and of the growth of the databases (too little history
    # here to compare: a day), fine
    for name, detail in (("Sync error rate", "in the last 15 minutes, alert from 10% and 20 errors"), ("Database growth", "from a day of history on")):
        row = re.search(r"<td>" + name + r"</td><td>(.*?)</td>", health)
        assert row and '<span class="ok">up</span>' in row.group(1) and detail in row.group(1), (name, health)
    # without self-hosted accounts there is nothing else to check; no SMTP server
    # (FXA_SMTP_HOST empty: the alerts go to ADMIN_NOTIFY), no public checks
    # (ADMIN_PUBLIC_CHECK=false in the test stack)
    assert len(re.findall(r"<tr><td>", health)) == len(components) + 3, health
    assert "Accounts" not in health and "Email (SMTP)" not in health and "Public" not in health
    # and nothing to say about the missing SMTP server
    assert "SMTP" not in page.split('id="attention"')[1].split("</section>")[0]
    assert 'action="/alerts/test"' not in page and "ffs_cert_expiry_seconds" not in requests.get(
        f"{ADMIN}/metrics", headers={"Authorization": f"Bearer {METRICS_TOKEN}"}, timeout=30).text


# ADMIN_NOTIFY of the test stack (tests/compose/sync.yml): a webhook and a Slack-style
# one, both to tests/notify_sink.py
SINK = "http://notify-sink:8000"
SINK_NAMES = "webhook+http://notify-sink:8000, slack+http://notify-sink:8000"
NOTIFY_SECRETS = ("ffs-test-hook-secret", "ffs-test-hook-token", "ffs-test-slack-secret")


def received(path, until=lambda r: True, timeout=30):
    """The requests the sink got under path, once one of them is until (ALERT_INTERVAL_SECONDS is 5)"""
    deadline = time.time() + timeout
    while True:
        got = [r for r in requests.get(f"{SINK}/_received", timeout=10).json() if r["path"].startswith(path)]
        if any(until(r) for r in got) or time.time() > deadline:
            return got
        time.sleep(1)


def test_notifications(admin):
    # a sign-in: an alert of kind admin, without email (no SMTP server in the test stack)
    Admin()
    def signed_in(r):
        return any(e["kind"] == "admin" and e["text"].startswith("signed in") for e in json.loads(r["body"])["events"])
    hooks = received("/hook/ffs-test-hook-secret", signed_in)
    assert hooks and any(signed_in(r) for r in hooks), hooks
    hook = next(r for r in hooks if signed_in(r))
    payload = json.loads(hook["body"])
    # the documented schema (docs/admin/alerts.md#webhook-schema), the token in its header, not in the URL
    assert set(payload) == {"source", "kind", "severity", "title", "text", "link", "events", "dropped"}, payload
    assert payload["source"] == "firefox-sync" and payload["severity"] in ("info", "warning") and payload["title"].startswith("firefox-sync: "), payload
    assert payload["link"] == "http://ffs-admin:8080/activity" and "Details: http://ffs-admin:8080/activity" in payload["text"], payload
    assert all(re.match(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$", e["time"]) for e in payload["events"]), payload
    assert hook["method"] == "POST" and hook["path"] == "/hook/ffs-test-hook-secret" and hook["headers"]["Authorization"] == "Bearer ffs-test-hook-token", hook
    assert hook["headers"]["Content-Type"] == "application/json" and hook["headers"]["User-Agent"].startswith("firefox-sync-admin/"), hook
    # the same alerts, in Slack's format
    slack = received("/services/T0/B0/ffs-test-slack-secret", lambda r: "signed in" in json.loads(r["body"])["text"])
    text = json.loads(slack[-1]["body"])["text"]
    assert text.startswith("*firefox-sync: ") and "<http://ffs-admin:8080/activity|Open the admin UI>" in text, text
    # the test button: one click, sent right away to both
    requests.delete(f"{SINK}/_received", timeout=10)
    page = admin.post("/alerts/test-notification")
    assert f"Sent a test notification to {SINK_NAMES}" in html.unescape(page), page[:3000]
    tests = [r for r in requests.get(f"{SINK}/_received", timeout=10).json() if '"kind": "test"' in r["body"] or "test notification" in r["body"]]
    assert {r["path"].split("/")[1] for r in tests} == {"hook", "services"}, tests
    assert "sent by admin (password)" in json.loads(next(r for r in tests if r["path"].startswith("/hook/"))["body"])["text"]
    # its status on the overview and in Prometheus, in the audit trail; no secret anywhere
    page = admin.get("/")
    status = html.unescape(page.split('id="notify-status"')[1].split("</div>")[0])
    assert "Notifications to webhook+http://notify-sink:8000: last sent" in status and "Notifications to slack+http://notify-sink:8000: last sent" in status, status
    assert 'action="/alerts/test-notification"' in page and all(secret not in page for secret in NOTIFY_SECRETS)
    assert "Sent a test notification to" in admin.get("/activity?kind=admin")
    metrics = requests.get(f"{ADMIN}/metrics", headers={"Authorization": f"Bearer {METRICS_TOKEN}"}, timeout=30).text
    for name in SINK_NAMES.split(", "):
        assert re.search(r'^ffs_notify_failures_total\{destination="' + re.escape(name) + r'"\} \d+$', metrics, re.M) and f'ffs_notify_send_failing{{destination="{name}"}} 0\n' in metrics, metrics
    assert "ffs_alert_send_failing" not in metrics and all(secret not in metrics for secret in NOTIFY_SECRETS)
    # and the audit event of the test reaches the webhook as an alert
    assert received("/hook/", lambda r: "Sent a test notification" in r["body"])


def table(page, name):
    """The rows of a table of a page, as lists of cells (tags removed)"""
    body = page.split(f'<table id="{name}"')[1].split("</table>")[0].split("<tbody>")[1]
    return [[re.sub(r"<[^>]+>", "", cell).strip() for cell in re.findall(r"<td>(.*?)</td>", row, re.S)]
            for row in re.findall(r"<tr[^>]*>(.*?)</tr>", body, re.S)]


def test_schema_levels(admin):
    rows = {row[0]: row for row in table(admin.get("/"), "schema")}
    for name in (("Tokenserver", "Sync storage") if MYSQL else ("Sync (tokenserver and storage)",)):
        # the newest migration of syncstorage-rs (diesel) and when it ran
        assert name in rows and re.match(r"^\d{4}", rows[name][1]) and re.match(r"^\d{4}-\d\d-\d\d \d\d:\d\d$", rows[name][2]), rows


def test_setup_checks_and_nodes(admin):
    page = admin.get("/")
    checks = {row[0]: row for row in table(page, "setup")}
    domain = os.environ["SYNC_PUBLIC_URL"].rstrip("/")
    assert checks["Sync node"][1] == "ok" and domain in checks["Sync node"][2], checks
    # the mock FxA serves the keys of the sign-ins (FXA_OAUTH_SERVER_URL=http://mock_fxa:6000)
    assert checks["Sign-in keys (FXA_OAUTH_SERVER_URL)"][1] == "ok" and "http://mock_fxa:6000/v1/jwks answers" in checks["Sign-in keys (FXA_OAUTH_SERVER_URL)"][2], checks
    assert checks["Account emails (FXA_EMAIL_DOMAIN)"][1] == "ok", checks
    # the event log in its own database: out of the Sync server's reach (in the stack's
    # PostgreSQL container the Sync server has its own role, SYNC_POSTGRES_APP_USER, no superuser)
    log = checks["Event log (ADMIN_DB_PASSWORD)"]
    assert log[1] == "ok" and "users cannot read or change them" in log[2], log
    # users per node, with its capacity, load, places and backoff
    node = [row for row in table(page, "nodes") if row[0] == domain]
    assert node and node[0][1] == "in use" and node[0][2] == "1" and all(re.match(r"^-?\d+$", c) for c in node[0][3:]), table(page, "nodes")


@editable
def test_email_domain_mismatch(admin, db):
    # an account of another FXA_EMAIL_DOMAIN, as after a change of it (max users 2 to let it in)
    admin.post("/sync/max-users", max_users="2")
    other = "0123abcd@old-domain.invalid"
    try:
        db.execute(sqltext("INSERT INTO users (service, email, generation, client_state, created_at, nodeid) "
                           "SELECT service, :email, 1, 'aa', 1, nodeid FROM users WHERE email = :alice"),
                   {"email": other, "alice": f"alice@{EMAIL_DOMAIN}"})
        checks = {row[0]: row for row in table(admin.get("/"), "setup")}
        check = checks["Account emails (FXA_EMAIL_DOMAIN)"]
        assert check[1] == "warning" and f"FXA_EMAIL_DOMAIN is {EMAIL_DOMAIN}" in check[2] and "@old-domain.invalid (1)" in check[2], check
        assert "counts twice against max users (2 of 2 used)" in check[2], check
    finally:
        db.execute(sqltext("DELETE FROM users WHERE email = :email"), {"email": other})
        admin.post("/sync/max-users", max_users="1")
    assert {row[0]: row for row in table(admin.get("/"), "setup")}["Account emails (FXA_EMAIL_DOMAIN)"][1] == "ok"


def test_connect_a_device(admin):
    # Mozilla's accounts: Firefox is pointed to this tokenserver
    page = admin.get("/connect")
    domain = os.environ["SYNC_PUBLIC_URL"].rstrip("/")
    steps = page.split('id="device-steps"')[1]
    assert f"identity.sync.tokenserver.uri and set it to {domain}/1.0/sync/1.5" in steps, steps[:2000]
    assert "Custom Sync Token Server URI" in steps and "autoconfig" not in steps


def config_row(page, setting):
    """The value and the origin of a setting of the Configuration page, in plain text"""
    row = re.search(r"<tr><td>" + re.escape(setting) + r"</td>(.*?)</tr>", page, re.S)
    assert row, (setting, page[:3000])
    return " ".join(html.unescape(re.sub(r"<[^>]+>", " ", row.group(1))).split())


def test_configuration_page(admin):
    page = admin.get("/config")
    domain = os.environ["SYNC_PUBLIC_URL"].rstrip("/")
    assert config_row(page, "Sync server").startswith(f"{domain} SYNC_PUBLIC_URL"), config_row(page, "Sync server")
    assert config_row(page, "Sync node handed out").startswith(domain)
    # where max users comes from: initial:N is managed on the overview, N is fixed
    row = config_row(page, "Max users")
    assert f"SYNC_MAX_USERS={os.environ['MAX_USERS_SETTING']}:" in row and ("then on the overview" in row) == EDITABLE, row
    # the Sync databases, the settings of the test stack (tests/compose/sync.yml)
    assert ("Databases" in page) == MYSQL and ("PostgreSQL, tokenserver and storage in one database" in page) == (not MYSQL)
    if MYSQL:
        # the server as the health check read it (MariaDB 11.8.3, MySQL 8.4.6), not only the kind
        assert re.match(r"(MariaDB|MySQL) \d+\.\d+[.\d]* SYNC_DB ", config_row(page, "Databases")), config_row(page, "Databases")
    assert config_row(page, "Time zone").startswith("Europe/Rome ADMIN_TZ")
    assert config_row(page, "OpenID Connect issuer").startswith("http://dex:5556/dex ")
    assert config_row(page, "Published on").startswith("127.0.0.1:"), config_row(page, "Published on")
    assert config_row(page, "Public checks").startswith("off ADMIN_PUBLIC_CHECK")
    # the secrets: whether they are set, never their value
    assert config_row(page, "Password").startswith("set ADMIN_PASSWORD")
    assert config_row(page, "Client secret").startswith("set ADMIN_OIDC_CLIENT_SECRET")
    assert config_row(page, "Prometheus").startswith("set ADMIN_METRICS_TOKEN")
    # the admin UI's own database and users (ADMIN_DB_PASSWORD): its reader on the Sync data
    own = urlsplit(os.environ["ADMIN_DB_URL"])
    row = config_row(page, "Admin UI database")
    assert row.startswith(f"{own.username} on ") and f"database {own.path.lstrip('/')}" in row, row
    assert config_row(page, "Admin UI database password").startswith("set ADMIN_DB_PASSWORD")
    # ADMIN_NOTIFY: the destinations as scheme://host, never their paths and tokens
    assert config_row(page, "Notifications to").startswith(f"{SINK_NAMES} ADMIN_NOTIFY shown without"), config_row(page, "Notifications to")
    secrets = [os.environ["ADMIN_PASSWORD"], METRICS_TOKEN, "ffs-test-dex-client-secret", os.environ["SYNC_MASTER_SECRET"], *NOTIFY_SECRETS,
               urlsplit(os.environ["SYNC_SYNCSTORAGE__DATABASE_URL"]).password, own.password]
    for secret in secrets:
        assert secret and secret not in page
    # what disagrees: the cookie of the test stack over plain HTTP (ADMIN_INSECURE_COOKIE)
    hints = page.split('<section id="hints">')[1].split("</section>")[0]
    assert "ADMIN_INSECURE_COOKIE is set" in hints and "not a loopback address" not in hints, hints


def test_database_sizes(admin):
    sizes = re.search(r"Databases: (.*?)history on the Activity page", admin.get("/"))
    assert sizes, "database sizes line"
    for name in DB_SIZES:
        assert re.search(re.escape(name) + r" [\d.]+ [KMG]?B;", sizes.group(1)), (name, sizes.group(1))


def test_max_users_and_accounts(admin):
    page = admin.get("/")
    assert re.search(r'id="sync-users">1<', page), page[:3000]
    assert re.search(r'id="sync-max-users">1<', page), page[:3000]
    # Mozilla's accounts: the server only knows the account id, linked to its page
    assert "Sync accounts" in page and "Sign-ups" not in page
    row = re.search(r'<tr><td><a href="/users/alice"><code>alice</code></a></td>(.*?)</tr>', page)
    assert row, page[:3000]
    # ADMIN_STALE_DAYS=0: inactive right away; 5 bookmarks of 100 bytes and more
    assert 'class="badge">inactive' in row.group(1), row.group(1)
    stored = re.search(r"<td>([\d.]+ [KMG]?B), (\d+) items</td>", row.group(1))
    assert stored and int(stored.group(2)) == 5, row.group(1)


def test_account_page(admin):
    page = admin.get("/users/alice")
    assert "<code>alice</code>" in page
    assert "Syncing since" in page
    collections = page.split('<table id="collections"')[1].split("</table>")[0]
    assert re.search(r"<td>bookmarks</td><td>5</td><td>[\d.]+ [KMG]?B</td><td>\d{4}-\d\d-\d\d \d\d:\d\d</td>", collections), collections
    # no devices nor sessions with Mozilla's accounts
    assert "Devices" not in page
    assert admin.http.get(f"{ADMIN}/users/nobody", timeout=30).status_code == 404


def test_prometheus(admin, alice):
    assert requests.get(f"{ADMIN}/metrics", timeout=30).status_code == 404
    res = requests.get(f"{ADMIN}/metrics", headers={"Authorization": "Bearer wrong"}, timeout=30)
    assert res.status_code == 404
    res = requests.get(f"{ADMIN}/metrics", headers={"Authorization": f"Bearer {METRICS_TOKEN}"}, timeout=30)
    assert res.status_code == 200, res.text
    metrics = res.text
    for line in ("ffs_sync_accounts 1\n", "ffs_sync_max_users 1\n", 'ffs_up{component="Sync server"} 1\n',
                 'ffs_up{component="Tokenserver database"} 1\n') + (('ffs_up{component="Storage database"} 1\n',) if MYSQL else ()):
        assert line in metrics, line
    assert int(re.search(r"^ffs_sync_stored_items (\d+)$", metrics, re.M).group(1)) >= 5, metrics
    assert int(re.search(r"^ffs_sync_stored_bytes (\d+)$", metrics, re.M).group(1)) >= 500, metrics
    for name in DB_SIZES:
        assert re.search(r'^ffs_database_bytes\{database="' + re.escape(name) + r'"\} [1-9]\d*$', metrics, re.M), name
    assert "ffs_accounts " not in metrics
    # ffs_statsd_total counts what the admin UI received since it started, and e2e.sh restarted
    # it, and the Sync server with it, just before. The Sync server buffers its metrics until a
    # datagram is full, so alice's sign-in and upload may still sit there: more traffic sends
    # them (/metrics counts them as they come, not at METRICS_FLUSH_SECONDS)
    request_counted = re.compile(r'^ffs_statsd_total\{name="syncstorage_request_[^"]*"\} [1-9]', re.M)
    deadline = time.time() + 30
    while not request_counted.search(metrics) and time.time() < deadline:
        for _ in range(10):
            assert alice.request("GET", "/info/collections").status_code == 200
        time.sleep(1)
        metrics = requests.get(f"{ADMIN}/metrics", headers={"Authorization": f"Bearer {METRICS_TOKEN}"}, timeout=30).text
    assert request_counted.search(metrics), metrics[-3000:]


@pytest.mark.skipif(EDITABLE, reason="SYNC_MAX_USERS=initial:N, the page manages max users")
def test_max_users_read_only(db):
    # not the admin fixture: this runs before test_client_flow.py, without alice
    admin = Admin()
    page = admin.get("/")
    before = re.search(r'id="sync-max-users">(\d+)<', page).group(1)
    assert re.search(r'<input id="max_users" [^>]*required disabled>', page), page[:3000]
    assert f"managed by SYNC_MAX_USERS in .env; set SYNC_MAX_USERS=initial:{before} to manage it here" in page
    csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', page).group(1)
    res = admin.http.post(f"{ADMIN}/sync/max-users", data={"csrf": csrf, "max_users": str(int(before) + 1)}, timeout=30)
    assert res.status_code == 200 and "managed by SYNC_MAX_USERS in .env" in res.text, res.text[:3000]
    assert "Max users set" not in res.text
    assert db.execute(sqltext("SELECT config_value FROM config WHERE config_key = 'max_users'")).scalar() == before
    assert re.search(r'id="sync-max-users">' + before + "<", admin.get("/"))


@editable
def test_max_users_from_the_page(admin, db):
    bob = f"bob@{EMAIL_DOMAIN}"
    page = admin.get("/")
    assert re.search(r'<input id="max_users" [^>]*required>', page) and "Managed here" in page, page[:3000]
    page = admin.post("/sync/max-users", max_users="2")
    assert "Max users set to 2" in page and re.search(r'id="sync-max-users">2<', page)
    try:
        assert db.execute(sqltext("SELECT config_value FROM config WHERE config_key = 'max_users'")).scalar() == "2"
        # the tokenserver lets a second account in right away
        res = login("bob")
        assert res.status_code == 200, res.text
        assert re.search(r'id="sync-users">2<', admin.get("/"))
    finally:
        db.execute(sqltext("DELETE FROM users WHERE email = :email"), {"email": bob})
        # back to 1 for the following tests
        page = admin.post("/sync/max-users", max_users="1")
    assert "Max users set to 1" in page and re.search(r'id="sync-max-users">1<', page)
    assert login("bob").status_code != 200


@editable
def test_bad_max_users_refused(admin):
    csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', admin.get("/")).group(1)
    res = admin.http.post(f"{ADMIN}/sync/max-users", data={"csrf": csrf, "max_users": "-1"}, timeout=30)
    assert "max users must be a number" in res.text
    assert re.search(r'id="sync-max-users">1<', admin.get("/"))


@editable
def test_activity_page(admin, alice):
    # metrics are written every METRICS_FLUSH_SECONDS (5 in the tests)
    deadline = time.time() + 60
    while True:
        # the Sync server buffers its metrics until a datagram is full: more traffic sends them
        # (a POST too: the one of the fixture can be lost when e2e.sh restarts the admin UI,
        # and the Sync server with it, while it still buffers)
        # an empty batch: a post_collection request that stores nothing (later tests count
        # alice's items)
        posted_batch = alice.request("POST", "/storage/bookmarks", [])
        assert posted_batch.status_code == 200, posted_batch.text
        for _ in range(10):
            assert alice.request("GET", "/info/collections").status_code == 200
        page = admin.get("/activity?range=24h")
        requests_total = int(re.search(r"Sync requests <strong>(\d+)</strong>", page).group(1))
        tokens = re.search(r"Sync tokens issued <strong>[1-9]\d*</strong>", page)
        posted = "<code>syncstorage.request.post_collection</code>" in page
        if requests_total > 0 and tokens and posted and "Max users set to 1" in page or time.time() > deadline:
            break
        time.sleep(3)
    assert requests_total > 0, page[:3000]
    assert "Last metrics received" in page
    assert re.search(r"Sync tokens issued <strong>[1-9]\d*</strong>", page), page[:3000]
    assert "<code>syncstorage.request.post_collection</code>" in page
    events = page.split('<table id="events"')[1].split("</table>")[0]
    for event in ("signed in (password)", "failed sign-in (password)", "Max users set to 2 by admin (password)", "Max users set to 1 by admin (password)"):
        assert f"<td>{event}</td>" in events, (event, events[:3000])
    for name in DB_SIZES:
        assert re.search(r"Database " + re.escape(name) + r" <strong>[\d.]+ [KMG]?B</strong>", page), (name, page[:3000])
    for span in ("7d", "30d"):
        assert "Sync requests" in admin.get(f"/activity?range={span}")


def error_count(page, metric):
    """The count of a kind of the errors of an activity page, 0 when it has none"""
    row = re.search(r'<tr data-metric="' + re.escape(metric) + r'"><td>[^<]*</td><td>[^<]*</td><td>[^<]*</td><td>(\d+)</td>', page)
    return int(row.group(1)) if row else 0


def test_errors_by_kind(admin, alice):
    # the statsd names syncstorage-rs counts them by (admin/testdata/statsd-packets.jsonl)
    kinds = ("syncstorage.request.error.hawk.missing_header", "syncstorage.request.validate.bad_bso_body", "tokens refused")
    before = {k: error_count(admin.get("/activity"), k) for k in kinds}
    # a request without Hawk, an item that is no string, a token of an older generation
    path = urlparse.urlparse(alice.endpoint).path
    assert requests.get(f"{SERVER}{path}/info/collections", headers=PROXY_HEADERS, timeout=30).status_code == 401
    assert alice.request("PUT", "/storage/bookmarks/bad", {"payload": 5}).status_code == 400
    assert login("alice", generation=1, keys_changed_at=1, client_state="cccc").status_code == 401
    # the refused token counts once a datagram of the Sync server came 40 s after it
    deadline = time.time() + 120
    while True:
        # more traffic: the Sync server sends its metrics when a datagram is full
        for _ in range(10):
            assert alice.request("GET", "/info/collections").status_code == 200
        page = admin.get("/activity")
        counts = {k: error_count(page, k) for k in kinds}
        if all(counts[k] > before[k] for k in kinds) or time.time() > deadline:
            break
        time.sleep(3)
    assert all(counts[k] > before[k] for k in kinds), (before, counts, page.split('id="errors"')[1][:3000])
    errors = page.split('id="errors"')[1].split("</table>")[0]
    for row in ("<td>Hawk authentication: missing header</td><td>401</td><td>Sync storage</td>",
                "<td>invalid request: bad bso body</td><td>400</td><td>Sync storage</td>", "<td>tokens refused</td><td>401, 500</td><td>Tokenserver</td>"):
        assert row in errors, (row, errors)
    assert int(re.search(r"Errors <strong>(\d+)</strong>", page).group(1)) >= 3, page[:3000]
    assert 'id="error-rate">Last 15 minutes: ' in page and "An alert from 10% of the requests and 20 errors" in page, page[:3000]
    metrics = requests.get(f"{ADMIN}/metrics", headers={"Authorization": f"Bearer {METRICS_TOKEN}"}, timeout=30).text
    for kind, status, service in (("request.error.hawk.missing_header", "401", "Sync storage"), ("request.validate.bad_bso_body", "400", "Sync storage")):
        assert re.search(r'^ffs_sync_errors_total\{service="' + service + '",status="' + status + '",kind="' + re.escape(kind) + r'"\} [1-9]', metrics, re.M), (kind, metrics[-3000:])
    # the tokens refused: no counter (verified minus issued goes down), the two to subtract
    assert 'kind="tokens_refused"' not in metrics, metrics[-3000:]
    verified, issued = (int(re.search(r'^ffs_statsd_total\{name="syncstorage_token_' + n + r'"\} (\d+)$', metrics, re.M).group(1)) for n in ("verification", "creation"))
    assert verified > issued, (verified, issued)
    # a handful of errors: no spike (ADMIN_ERROR_RATE_MIN_ERRORS 20)
    assert "\nffs_sync_error_spike 0\n" in metrics and re.search(r"^ffs_sync_error_ratio [0-9.e-]+$", metrics, re.M), metrics[-3000:]


def events_of(page):
    """The rows of the event log of an activity page: (when, kind, detail)"""
    table = page.split('<table id="events"')[1].split("</table>")[0]
    return re.findall(r"<tr[^>]*><td>([^<]*)</td><td>([^<]*)</td><td>([^<]*)</td></tr>", table)


@editable
def test_audit_trail_filters_and_pages(admin, admin_db):
    admin.post("/sync/max-users", max_users="1")
    page = admin.get("/activity?kind=admin&q=MAX")
    events = events_of(page)
    assert events and all(kind == "admin" and "max" in detail.lower() for _, kind, detail in events), events
    assert "Max users set to 1 by admin (password)" in [detail for _, _, detail in events], events
    assert '<option value="admin" selected>' in page and 'name="q" type="search" value="MAX"' in page
    # older than ADMIN_RETENTION_DAYS (30), kept for ADMIN_AUDIT_RETENTION_DAYS: 350 of them, 100 a page
    old = int((time.time() - 40 * 86400) * 1000)
    marker = f"ffs-page-{int(time.time())}"
    try:
        for i in range(350):
            admin_db.execute(sqltext("INSERT INTO ffs_events (at, kind, detail) VALUES (:at, 'admin', :detail)"),
                       {"at": old + i, "detail": f"{marker} {i:03d} by admin (password)"})
        seen, path, pages = [], f"/activity?kind=admin&q={marker}", 0
        while path:
            page = admin.get(path)
            seen += [detail for _, _, detail in events_of(page)]
            older = re.search(r'<a href="([^"]*)" rel="next" id="older">', page)
            path = older.group(1).replace("&amp;", "&") if older else None
            pages += 1
            assert pages < 10, path
        assert pages == 4 and seen == [f"{marker} {i:03d} by admin (password)" for i in reversed(range(350))], (pages, seen[:3], len(seen))
        # the link back to the newest
        assert 'id="newest"' in page and f"q={marker}" in page
    finally:
        admin_db.execute(sqltext("DELETE FROM ffs_events WHERE detail LIKE :marker"), {"marker": f"{marker} %"})


def test_local_time_label(admin):
    # ADMIN_TZ=Europe/Rome in tests/compose/sync.yml: said once, at the bottom
    for path in ("/", "/activity", "/users/alice"):
        page = admin.get(path)
        # BACKUP_TIME is set in UTC: the backups say so, with the local time first
        if path == "/":
            card = re.search(r'<section class="card" aria-labelledby="backups-title".*?</section>', page, re.S).group(0)
            assert re.search(r"[Ee]very night at \d\d:\d\d \(<code>BACKUP_TIME=\d\d:\d\d</code>, in UTC\)", card), card[:1000]
            page = page.replace(card, "")
        assert page.count("Times in Europe/Rome") == 1 and "UTC" not in page.replace("Times in Europe/Rome", ""), (path, page[-500:])


def test_no_security_page_without_accounts(admin):
    for path in ("/", "/activity", "/users/alice"):
        assert 'href="/security"' not in admin.get(path), path
    assert admin.http.get(f"{ADMIN}/security", timeout=30).status_code == 404
    # nor the forms of the self-hosted accounts
    csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', admin.get("/")).group(1)
    for path in ("/accounts/signups", "/accounts/alice/disable", "/accounts/invite", "/accounts/allowlist/remove", "/accounts/max-accounts", "/maintenance/prune"):
        assert admin.http.post(f"{ADMIN}{path}", data={"csrf": csrf, "mode": "closed"}, timeout=30).status_code == 404, path
    # and their confirm pages
    for path in ("/maintenance/prune", "/accounts/allowlist/remove?entry=x%40example.com"):
        assert admin.http.get(f"{ADMIN}{path}", timeout=30).status_code == 404, path


def test_label_on_a_sync_account(admin):
    # Mozilla's accounts: only the id is known, the note says whose it is
    page = admin.post("/users/alice/note", note="Alice <laptop>")
    assert 'Note of account alice set to &#34;Alice &lt;laptop&gt;&#34;' in page, page[:3000]
    assert 'value="Alice &lt;laptop&gt;"' in page
    row = re.search(r'<tr><td><a href="/users/alice"><code>alice</code></a>(.*?)</td>', admin.get("/"))
    assert row and row.group(1) == ' <span class="note">Alice &lt;laptop&gt;</span>', row and row.group(1)
    # in the event log when the result is shown (recorded before the redirect)
    page = admin.get("/activity?kind=admin&q=alice")
    assert "<td>admin</td><td>Note of account alice set to &#34;Alice &lt;laptop&gt;&#34; by admin (password)</td>" in page, (failed(page), events_of(page)[:5])
    # only accounts the server knows, at most 500 characters
    csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', admin.get("/")).group(1)
    assert admin.http.post(f"{ADMIN}/users/nobody/note", data={"csrf": csrf, "note": "x"}, timeout=30).status_code == 404
    res = admin.http.post(f"{ADMIN}/users/alice/note", data={"csrf": csrf, "note": "x" * 501}, timeout=30)
    assert failed(res.text) == ["a note has at most 500 characters, not 501"], failed(res.text)
    page = admin.post("/users/alice/note", note="")
    assert "Removed the note of account alice" in page and 'class="note"' not in admin.get("/")


def rows_of(db, email):
    return db.execute(sqltext("SELECT uid, client_state, replaced_at FROM users WHERE email = :email ORDER BY uid"),
                      {"email": email}).fetchall()


@editable
def test_sync_rows_after_a_key_change(admin, alice, db):
    # the fixture changed alice's keys (client state cccc, a new keys_changed_at)
    rows = rows_of(db, f"alice@{EMAIL_DOMAIN}")
    assert len(rows) >= 2 and rows[-1][1] == "cccc" and rows[-1][2] is None and all(r[2] is not None for r in rows[:-1]), rows
    page = admin.get("/users/alice")
    shown = table(page, "sync-rows")
    assert [int(r[0].split()[0]) for r in shown] == [r[0] for r in rows], shown
    assert shown[-1][0] == f"{rows[-1][0]} current" and shown[-1][1] == "cccc" and shown[-1][5] == "", shown
    # the old ones replaced (a date), not current
    assert all("current" not in r[0] and re.match(r"^\d{4}-\d\d-\d\d \d\d:\d\d$", r[5]) for r in shown[:-1]), shown
    assert 'id="flags">Nothing odd in these rows.' in page, page.split('id="sync-rows"')[1][:3000]
    # found by its tokenserver uid
    res = admin.http.get(f"{ADMIN}/find", params={"q": str(rows[0][0])}, timeout=30)
    assert res.url == f"{ADMIN}/users/alice", res.url
    res = admin.http.get(f"{ADMIN}/find", params={"q": "999999999"}, timeout=30)
    assert failed(res.text) == ['No account &#34;999999999&#34;: search an email, an account id or a tokenserver uid.'], failed(res.text)
    # and the search of the overview, by any of its tokenserver uids (the replaced one too)
    for uid in (rows[0][0], rows[-1][0]):
        page = admin.get(f"/?q={uid}")
        assert [r[0] for r in table(page, "sync-accounts")] == ["alice"], table(page, "sync-accounts")
        assert f'id="search-result">1 account matching &#34;{uid}&#34;' in page and f'value="{uid}"' in page, page[:3000]
    page = admin.get("/?q=999999999")
    assert "No account matches." in page and table(page, "sync-accounts") == [[]], table(page, "sync-accounts")
    # part of the id, or of the label
    assert [r[0] for r in table(admin.get("/?q=lic"), "sync-accounts")] == ["alice"]


def collections_of(storage):
    res = storage.request("GET", "/info/collections")
    assert res.status_code == 200, res.text
    return set(res.json())


@editable
def test_reset_sync_data(admin, alice, db):
    history = [{"id": f"history{i}", "payload": json.dumps({"url": "x" * 50})} for i in range(3)]
    assert alice.request("POST", "/storage/history", history).status_code == 200
    assert collections_of(alice) == {"bookmarks", "history"}
    users = len(rows_of(db, f"alice@{EMAIL_DOMAIN}"))
    # a collection it does not have: no confirm page
    assert admin.http.get(f"{ADMIN}/users/alice/reset-sync?collection=nosuch", timeout=30).status_code == 404

    # one collection: only that one goes
    page, done = admin.confirm("/users/alice/reset-sync?collection=history")
    assert "Reset the history collection of account alice?" in page and "3 items" in page, page[:3000]
    assert "Reset the history collection of account alice (3 items" in done, done[:3000]
    assert collections_of(alice) == {"bookmarks"}
    assert len(alice.request("GET", "/storage/bookmarks").json()) == 5

    # everything: the next sync finds the server empty, the account and its row stay
    page, done = admin.confirm("/users/alice/reset-sync")
    assert "Data that is only on the server is lost" in page and 'name="free_slot"' in page, page[:3000]
    assert "Reset the Sync data of account alice (5 items" in done, done[:3000]
    assert collections_of(alice) == set()
    assert alice.request("GET", "/storage/meta/global").status_code == 404
    assert len(rows_of(db, f"alice@{EMAIL_DOMAIN}")) == users and re.search(r'id="sync-users">1<', admin.get("/"))
    # and Firefox uploads again
    bookmarks = [{"id": f"bookmark{i:03d}", "payload": json.dumps({"title": "y" * 100})} for i in range(2)]
    assert alice.request("POST", "/storage/bookmarks", bookmarks).status_code == 200
    assert collections_of(alice) == {"bookmarks"}
    assert "<td>admin</td><td>Reset the Sync data of account alice (5 items" in admin.get("/activity?kind=admin&q=Reset")

    # freeing the slot: the rows go, max users counts it no more
    page, done = admin.confirm("/users/alice/reset-sync", free_slot="1")
    assert f"and freed its max users slot ({users} tokenserver rows)" in done, done[:3000]
    assert rows_of(db, f"alice@{EMAIL_DOMAIN}") == [] and re.search(r'id="sync-users">0<', admin.get("/"))
    # the next token goes through max users again (1: room for one)
    res = login("alice", generation=int(time.time()), keys_changed_at=int(time.time()), client_state="eeee")
    assert res.status_code == 200, res.text
    assert collections_of(Storage(res.json())) == set()
    assert re.search(r'id="sync-users">1<', admin.get("/"))


def storage_ids(storage_db, query, **args):
    return [r[0] for r in storage_db.execute(sqltext(query), args).fetchall()]


@editable
def test_purge_expired_and_orphaned_data(admin, db, storage_db):
    alice_email = f"alice@{EMAIL_DOMAIN}"
    # new keys again (a newer keys_changed_at): the eeee row is replaced now, kept a day
    time.sleep(1.1)
    token = login("alice", generation=int(time.time()), keys_changed_at=int(time.time()), client_state="eeef").json()
    live = Storage(token)
    assert live.request("POST", "/storage/bookmarks", [{"id": "kept", "payload": "x" * 20}]).status_code == 200
    current = token["uid"]
    bso, user, coll = ("bso", "userid", "collection") if MYSQL else ("bsos", "user_id", "collection_id")
    history = storage_db.execute(sqltext("SELECT " + ("id" if MYSQL else "collection_id") + " FROM collections WHERE name = 'history'")).scalar()
    now = int(time.time() * 1000)
    day = 86400 * 1000
    # a row of alice replaced two days ago, with data on its keys
    db.execute(sqltext("INSERT INTO users (service, email, generation, client_state, created_at, replaced_at, nodeid, keys_changed_at) "
                       "SELECT service, email, 0, 'dddd', :created, :replaced, nodeid, 1 FROM users WHERE uid = :uid"),
               {"created": now - 3 * day, "replaced": now - 2 * day, "uid": current})
    old = db.execute(sqltext("SELECT MAX(uid) FROM users WHERE email = :email AND client_state = 'dddd'"), {"email": alice_email}).scalar()

    def put(userid, item, expired):
        if MYSQL:
            # as the Sync server does: a write changes the collections, which the storage report's cache watches
            storage_db.execute(sqltext("INSERT INTO user_collections (userid, collection, last_modified) VALUES (:u, :c, :m) "
                                       "ON DUPLICATE KEY UPDATE last_modified = GREATEST(last_modified, VALUES(last_modified))"),
                               {"u": userid, "c": history, "m": now - day})
            storage_db.execute(sqltext("INSERT INTO bso (userid, collection, id, payload, payload_size, modified, ttl) "
                                       "VALUES (:u, :c, :i, :p, 10, :m, :t)"),
                               {"u": userid, "c": history, "i": item, "p": "z" * 10, "m": now - day, "t": now - 1000 if expired else now + 365 * day})
        else:
            storage_db.execute(sqltext("INSERT INTO user_collections (user_id, collection_id, modified) VALUES (:u, :c, NOW() - INTERVAL '1 day') "
                                       "ON CONFLICT DO NOTHING"), {"u": userid, "c": history})
            storage_db.execute(sqltext("INSERT INTO bsos (user_id, collection_id, bso_id, payload, modified, expiry) "
                                       "VALUES (:u, :c, :i, :p, NOW() - INTERVAL '1 day', NOW() + " + ("INTERVAL '-1 second'" if expired else "INTERVAL '365 days'") + ")"),
                               {"u": userid, "c": history, "i": item, "p": "z" * 10})
    for i in range(2):
        put(old, f"old{i}", False)
    for i in range(3):
        put(current, f"expired{i}", True)

    page = admin.get("/")
    totals = {r[0]: r for r in table(page, "storage-totals")}
    assert totals["Expired"][1] == "3" and totals["Orphaned"][1] == "2", totals
    orphans = table(page, "orphans")
    assert orphans == [["replaced keys", alice_email, str(old), "2 items, 20 B"]], orphans
    live_before = int(totals["Live"][1])

    confirm, done = admin.confirm("/storage/purge")
    assert "1 orphans: 2 items, 20 B" in confirm and "3 expired items, 30 B" in confirm, confirm[:3000]
    assert "Purged the Sync storage: 1 orphans (2 items, 20 B, 1 tokenserver rows), 3 expired items (30 B), 0 stale batches" in done, done[:3000]
    # exactly those: the replaced row and its data, the expired items; the live data stays
    assert storage_ids(storage_db, f"SELECT {coll} FROM {bso} WHERE {user} = :u", u=old) == []
    assert db.execute(sqltext("SELECT COUNT(*) FROM users WHERE uid = :u"), {"u": old}).scalar() == 0
    assert storage_ids(storage_db, f"SELECT {coll} FROM {bso} WHERE {user} = :u AND " + ("ttl < :now" if MYSQL else "expiry < NOW()"), u=current, now=now) == []
    assert live.request("GET", "/storage/bookmarks").json() == ["kept"]
    after = {r[0]: r for r in table(admin.get("/"), "storage-totals")}
    assert after["Expired"][1] == "0" and after["Orphaned"][1] == "0" and int(after["Live"][1]) == live_before, after
    assert re.search(r'id="sync-users">1<', admin.get("/"))


@editable
def test_delete_the_sync_data_of_an_account(admin, db):
    # Mozilla's accounts: the rows and the data of the id, the account itself is Mozilla's
    alice_email = f"alice@{EMAIL_DOMAIN}"
    assert rows_of(db, alice_email)
    page = admin.get("/users/alice")
    assert 'href="/users/alice/delete"' in page
    confirm = admin.get("/users/alice/delete")
    assert "Delete the Sync data of account alice?" in confirm and '<label for="confirm_email">Type the account id to confirm</label>' in confirm, confirm[:3000]
    # the id typed must be this one
    _, res = admin.confirm("/users/alice/delete", ok=False, confirm_email="bob")
    assert failed(res) == ["the account id typed is not this one: nothing deleted"], failed(res)
    assert rows_of(db, alice_email)
    _, done = admin.confirm("/users/alice/delete", confirm_email="alice")
    assert "Deleted the Sync data of account alice (" in done, done[:3000]
    assert rows_of(db, alice_email) == [] and re.search(r'id="sync-users">0<', done)
    assert admin.http.get(f"{ADMIN}/users/alice", timeout=30).status_code == 404
    assert "<td>admin</td><td>Deleted the Sync data of account alice" in admin.get("/activity?kind=admin&q=Deleted")
    # it can sync here again, as a new account
    res = login("alice", generation=int(time.time()), keys_changed_at=int(time.time()), client_state="ffff")
    assert res.status_code == 200, res.text


def attention_of(page):
    """The lines of Needs attention: (text, link)"""
    box = page.split('<section id="attention">')[1].split("</section>")[0]
    return [(re.sub(r"<[^>]+>", "", text).strip(), href) for text, href in re.findall(r'<li>(.*?) <a href="([^"]*)">', box, re.S)]


def test_backups_on_the_overview(admin):
    # tests/e2e.sh ran the backup service (with EXTERNAL_DB=1: the INSERT of your own backups)
    deadline = time.time() + 30
    while True:
        page = admin.get("/")
        line = re.search(r'<p class="hint" data-scope="sync">(.*?)</p>', page, re.S)
        if line or time.time() > deadline:
            break
        time.sleep(1)
    assert line, page.split('<div id="backups">')[1][:1000]
    text = re.sub(r"<[^>]+>", "", line.group(1))
    assert re.match(r"Last backup of the Sync databases: \d{4}-\d\d-\d\d \d\d:\d\d, [\d.]+ [KMG]?B, ok\.$", text), text
    assert not [a for a in attention_of(page) if "backup" in a[0]], attention_of(page)
    metrics = requests.get(f"{ADMIN}/metrics", headers={"Authorization": f"Bearer {METRICS_TOKEN}"}, timeout=30).text
    age = re.search(r'^ffs_backup_age_seconds\{scope="sync"\} (\d+)$', metrics, re.M)
    assert age and int(age.group(1)) < 3600 and 'ffs_backup_last_ok{scope="sync"} 1' in metrics, metrics[-2000:]


@editable
def test_near_max_users_line(admin, db, admin_db):
    before = re.search(r'id="sync-max-users">(\d+)<', admin.get("/")).group(1)
    users = int(re.search(r'id="sync-users">(\d+)<', admin.get("/")).group(1))
    metrics = lambda: requests.get(f"{ADMIN}/metrics", headers={"Authorization": f"Bearer {METRICS_TOKEN}"}, timeout=30).text
    try:
        # every place taken: a line, a link to the form, the health row (counted by the
        # light), gauges, an event (and alert) once
        page = admin.post("/sync/max-users", max_users=str(users))
        line = f"{users} of {users} accounts are taken (SYNC_MAX_USERS): new accounts are refused by the Sync server until it is raised."
        assert (line, "#sync") in attention_of(page), attention_of(page)
        assert 'id="sync">' in page and 'id="sync-limit-state">full: new accounts are refused<' in page
        health = page.split('<table id="health"')[1].split("</table>")[0]
        assert re.search(r'<td>Max users</td><td><span class="pill warn">full</span>', health), health
        assert re.search(r'id="health-light">.*?<span class="n">\d+</span><span class="word"><span class="part"> parts?</span> to check', page, re.S), page[:2000]
        assert "ffs_sync_near_max_users 1\n" in metrics() and "ffs_sync_full 1\n" in metrics()
        query = sqltext("SELECT COUNT(*) FROM ffs_events WHERE kind = 'attention' AND detail LIKE '%accounts are taken (SYNC_MAX_USERS)%'")
        deadline = time.time() + 30
        while admin_db.execute(query).scalar() == 0 and time.time() < deadline:
            time.sleep(1)
        assert admin_db.execute(query).scalar() >= 1
        page = admin.post("/sync/max-users", max_users=str(users * 10 + 10))
        assert not [a for a in attention_of(page) if "accounts are taken" in a[0]], attention_of(page)
        health = page.split('<table id="health"')[1].split("</table>")[0]
        assert re.search(rf'<td>Max users</td><td><span class="ok">up</span> <span class="hint">{users} of {users * 10 + 10} taken</span>', health), health
        assert "ffs_sync_near_max_users 0\n" in metrics() and "ffs_sync_full 0\n" in metrics()
    finally:
        admin.post("/sync/max-users", max_users=before)


@editable
def test_unlimited_max_users(admin, db):
    """No limit (SYNC_MAX_USERS=initial:unlimited, or "No limit" on the page): the trigger lets everybody in"""
    before = re.search(r'id="sync-max-users">(\d+)<', admin.get("/")).group(1)
    bob = f"bob-unlimited@{EMAIL_DOMAIN}"
    try:
        page = admin.post("/sync/max-users", max_users=before, unlimited="1")
        assert "Max users set to unlimited" in page and 'id="sync-max-users">unlimited<' in page, page[:3000]
        assert "with no limit (<code>SYNC_MAX_USERS=unlimited</code>)" in page
        assert re.search(r'<input type="checkbox" name="unlimited" value="1" checked>', page)
        assert db.execute(sqltext("SELECT config_value FROM config WHERE config_key = 'max_users'")).scalar() == "unlimited"
        # a new account: let in, not counted against anything
        res = login("bob-unlimited")
        assert res.status_code == 200, res.text
        page = admin.get("/")
        assert not [a for a in attention_of(page) if "accounts are taken" in a[0]], attention_of(page)
        assert re.search(r"<td>Max users</td><td><span class=\"ok\">up</span> <span class=\"hint\">\d+ accounts?, no limit</span>", page), page[:3000]
        metrics = requests.get(f"{ADMIN}/metrics", headers={"Authorization": f"Bearer {METRICS_TOKEN}"}, timeout=30).text
        assert "ffs_sync_max_users" not in metrics and "ffs_sync_full 0\n" in metrics, metrics[:2000]
        assert "Max users set to unlimited by admin (password)" in [d for _, _, d in events_of(admin.get("/activity?kind=admin&q=unlimited"))]
    finally:
        db.execute(sqltext("DELETE FROM users WHERE email = :e"), {"e": bob})
        page = admin.post("/sync/max-users", max_users=before)
        assert f'id="sync-max-users">{before}<' in page
    # a number again: the trigger counts again
    if int(re.search(r'id="sync-users">(\d+)<', page).group(1)) >= int(before):
        assert login("carol-unlimited").status_code != 200


def test_sign_out(admin):
    csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', admin.get("/")).group(1)
    res = admin.http.post(f"{ADMIN}/logout", data={"csrf": csrf}, timeout=30)
    assert res.url.endswith("/login")
    assert admin.http.get(f"{ADMIN}/", timeout=30).url.endswith("/login")
