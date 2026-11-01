"""Access control in front of the public hosts (docs/single-sign-on.md), from outside.

tests/e2e-fxa.sh runs these first, in tests/browser, with CLIENT_CERT=1 (FFS_ACCESS=mtls)
or SSO=authelia (FFS_ACCESS=authelia), in Caddy (tests/caddy/<FFS_ACCESS>/);
test_fxa_browser.py then signs up and syncs through it.

Environment:
  FFS_ACCESS       mtls or authelia
  FXA_CONTENT_URL, FXA_AUTH_URL, FXA_PROFILE_URL, FXA_PAIRING_URL, SYNC_PUBLIC_URL  the public URLs
  ADMIN_URL        the admin UI
"""

import os
import socket
import ssl
import time
from urllib.parse import urlsplit

import pytest
import requests

import test_fxa_browser as browser

ACCESS = os.environ["FFS_ACCESS"]
CA = "/caddy-ca/root.crt"
CERTS = "/client-certs"
CONTENT = os.environ["FXA_CONTENT_URL"].rstrip("/")
ADMIN = os.environ.get("ADMIN_URL", "https://admin.fxa.test").rstrip("/")
# what Firefox fetches in the background, without cookies or a client certificate
OPEN = {
    "accounts API": os.environ["FXA_AUTH_URL"],
    "profile server": os.environ["FXA_PROFILE_URL"],
    "pairing server": os.environ["FXA_PAIRING_URL"].replace("wss://", "https://"),
    "Sync server": os.environ["SYNC_PUBLIC_URL"],
}
# the paths of the accounts pages' host that stay open: Firefox's configuration, the
# OpenID Connect discovery (the admin UI's server), the health checks (its public checks)
OPEN_PATHS = ["/.well-known/fxa-client-configuration", "/.well-known/openid-configuration", "/__heartbeat__"]
# pages of the sign-up and the sign-in, behind the access control
PAGES = ["/", "/signin", "/oauth/signup", "/authorization"]

mtls = pytest.mark.skipif(ACCESS != "mtls", reason="CLIENT_CERT=1 only")
sso = pytest.mark.skipif(ACCESS != "authelia", reason="SSO=authelia only")
AUTHELIA = "https://auth.fxa.test"
ADMIN_SSO = "https://admin-sso.fxa.test"


def anonymous():
    """A session with neither the client certificate nor Authelia's cookie (tests/conftest.py)"""
    http = requests.Session()
    http.cert = None
    http.cookies.clear()
    http.verify = CA
    return http


def first_line(url, cert=None):
    """A TLS connection and one request: the status line, or the TLS error. With TLS 1.3 a
    refused certificate shows at the first read, after the handshake"""
    host = urlsplit(url).hostname
    ctx = ssl.create_default_context(cafile=CA)
    if cert:
        ctx.load_cert_chain(f"{CERTS}/{cert}.crt", f"{CERTS}/{cert}.key")
    try:
        with socket.create_connection((host, 443), timeout=10) as raw, ctx.wrap_socket(raw, server_hostname=host) as tls:
            tls.sendall(f"GET /__heartbeat__ HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode())
            return tls.recv(64).decode(errors="replace").split("\r\n")[0] or "closed"
    except (ssl.SSLError, ConnectionError) as e:
        return f"TLS error: {e}"


@mtls
@pytest.mark.parametrize("path", PAGES)
def test_pages_need_the_client_certificate(path):
    res = anonymous().get(f"{CONTENT}{path}", allow_redirects=False, timeout=10)
    assert res.status_code == 403, (res.status_code, res.text[:200])
    http = anonymous()
    http.cert = (f"{CERTS}/client.crt", f"{CERTS}/client.key")
    res = http.get(f"{CONTENT}{path}", allow_redirects=False, timeout=10)
    assert res.status_code < 500 and res.status_code != 403, (res.status_code, res.text[:200])


@mtls
def test_a_certificate_of_another_ca_is_refused():
    assert first_line(CONTENT, cert="other").startswith("TLS error")
    assert first_line(ADMIN, cert="other").startswith("TLS error")


@pytest.mark.parametrize("path", OPEN_PATHS)
def test_open_paths_of_the_pages_host(path):
    res = anonymous().get(f"{CONTENT}{path}", allow_redirects=False, timeout=10)
    assert res.status_code == 200, (res.status_code, res.text[:200])


@pytest.mark.parametrize("name", OPEN)
def test_firefox_background_hosts_answer_anybody(name):
    # no certificate, no cookie: what Firefox sends them
    assert first_line(OPEN[name]).startswith("HTTP/1.1 "), name
    if name != "pairing server":
        res = anonymous().get(f"{OPEN[name]}/__heartbeat__", allow_redirects=False, timeout=10)
        assert res.status_code == 200, (name, res.status_code)


@mtls
def test_admin_ui_refused_at_the_handshake_without_a_certificate():
    answer = first_line(ADMIN)
    assert answer.startswith("TLS error") and "CERTIFICATE_REQUIRED" in answer.upper(), answer
    assert first_line(ADMIN, cert="client").startswith("HTTP/1.1 ")


# what Firefox sends, the cause of what the hosts above leave open: each way Firefox makes
# requests, to the admin UI's host, which refuses connections without the certificate
FIREFOX_REQUESTS = """
const [url, done] = arguments;
const { RESTRequest } = ChromeUtils.importESModule("resource://services-common/rest.sys.mjs");
const status = p => p.then(r => r.status, e => "refused");
(async () => {
  const rest = new RESTRequest(url);
  return {
    // the accounts API, the tokenserver, the profile, Firefox's configuration
    rest: await rest.get().then(() => rest.response.status, () => "refused"),
    // the Sync server (services/sync/modules/resource.sys.mjs)
    fetch: await status(fetch(url, { cache: "no-store" })),
    // what does send it, for comparison
    fetch_with_credentials: await status(fetch(url, { cache: "no-store", credentials: "include" })),
  };
})().then(done, e => done({ error: String(e) }));
"""


@mtls
def test_firefox_background_requests_send_no_client_certificate():
    driver = browser.start_firefox()
    try:
        driver.get(f"{ADMIN}/login")
        assert "password" in driver.page_source, "a page in a tab sends the certificate"
        found = browser.chrome(driver, FIREFOX_REQUESTS, f"{ADMIN}/login")
    finally:
        browser.quit_firefox(driver)
    assert found == {"rest": "refused", "fetch": "refused", "fetch_with_credentials": 200}, found


@sso
@pytest.mark.parametrize("path", PAGES)
def test_pages_need_the_sso_sign_in(path):
    res = anonymous().get(f"{CONTENT}{path}", allow_redirects=False, timeout=10)
    assert res.status_code == 302 and res.headers["Location"].startswith(f"{AUTHELIA}/?rd="), (res.status_code, res.headers)
    # with Authelia's session cookie (tests/conftest.py)
    res = requests.get(f"{CONTENT}{path}", allow_redirects=False, verify=CA, timeout=10)
    assert res.status_code < 500 and not res.headers.get("Location", "").startswith(AUTHELIA), (res.status_code, res.headers)


@sso
def test_firefox_meets_authelia_before_the_sign_up():
    driver = browser.start_firefox(sso=False)
    try:
        driver.get(f"{CONTENT}/")
        time.sleep(2)
        assert driver.current_url.startswith(f"{AUTHELIA}/"), driver.current_url
        browser.sso_sign_in(driver)
        for _ in range(20):
            if browser.visible(driver, browser.EMAIL_INPUT):
                break
            time.sleep(0.5)
        assert browser.visible(driver, browser.EMAIL_INPUT), driver.page_source[:1000]
    finally:
        browser.quit_firefox(driver)


@sso
def test_admin_ui_signs_in_with_authelia():
    # admin-sso.fxa.test: forward auth, the email in Remote-Email (ADMIN_AUTH_HEADER)
    res = anonymous().get(f"{ADMIN_SSO}/", allow_redirects=False, timeout=10)
    assert res.status_code == 302 and res.headers["Location"].startswith(f"{AUTHELIA}/?rd="), res.status_code
    driver = browser.start_firefox()
    try:
        driver.get(f"{ADMIN_SSO}/")
        time.sleep(2)
        assert driver.current_url == f"{ADMIN_SSO}/" and "Sign out" in driver.page_source, driver.current_url
        assert '<span class="hint">sso@example.com</span>' in driver.page_source
        # the header the client sends, replaced by Authelia's
        http = requests.Session()
        http.verify = CA
        page = http.get(f"{ADMIN_SSO}/", headers={"Remote-Email": "admin@example.com"}, timeout=10).text
        assert '<span class="hint">sso@example.com</span>' in page, page[:500]
    finally:
        browser.quit_firefox(driver)


@sso
def test_admin_ui_host_without_sso_ignores_the_header():
    # admin.fxa.test drops the header the client sends: no sign-in with a forged one
    http = anonymous()
    res = http.get(f"{ADMIN}/", headers={"Remote-Email": "sso@example.com"}, timeout=10)
    assert urlsplit(res.url).path == "/login", res.url
