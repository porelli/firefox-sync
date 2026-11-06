"""A real Firefox signs up and syncs with the self-hosted Mozilla accounts.

Two Firefox profiles go through the accounts web pages like a user would: the first
signs up (confirmation code from the mail catcher) and syncs a bookmark, the second
signs in and must receive it. Runs in tests/browser (Mozilla's Firefox build and
geckodriver) on the network of tests/e2e-fxa.sh.

Environment:
  FXA_CONTENT_URL  public URL of the accounts web pages
  MAILPIT_URL      mail catcher API, e.g. http://mailpit:8025
  FIREFOX_BINARY   default: /usr/bin/firefox
  GECKODRIVER      default: /usr/local/bin/geckodriver
  FFS_ACCESS       the access control in front of the hosts (tests/e2e-fxa.sh): mtls, each
                   Firefox has the client certificate /client-certs/client.p12 in its profile;
                   authelia, each Firefox signs in to Authelia first (FFS_SSO_USER, FFS_SSO_PASSWORD)
  BROWSER_ARTIFACTS  a directory: on a failure, the page source and a screenshot of every
                   open Firefox go there (the job log gets the Firefox version, the address,
                   the text and the form fields of the page either way)

Nothing leaves the stack (docs/accounts.md#telemetry): every Firefox records every request its
pages make (WebDriver BiDi, network.beforeRequestSent of its own session), and each test fails
when its pages asked a host outside the stack (the hosts under the domain of FXA_CONTENT_URL)
that is not in ALLOWED_HOSTS, a telemetry or error-report host first of all.
"""

import json
import os
import re
import subprocess
import tempfile
import threading
import time
import uuid
import warnings
from urllib.parse import urlsplit

import pytest
import requests
import websocket
from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.firefox.options import Options
from selenium.webdriver.firefox.service import Service

CONTENT = os.environ["FXA_CONTENT_URL"].rstrip("/")
MAILPIT = os.environ.get("MAILPIT_URL", "http://mailpit:8025").rstrip("/")
EMAIL = f"ffs-browser-{uuid.uuid4().hex[:12]}@example.com"
PASSWORD = f"Ffs-{uuid.uuid4().hex}"
BOOKMARK_URL = "https://example.org/self-hosted-fxa"
BOOKMARK_TITLE = "Self-hosted FxA test bookmark"
# the accounts pages' fields by their role, not one exact markup
EMAIL_INPUT = "input[type=email], input[autocomplete=email], input[autocomplete=username], input[name=email]"
PASSWORD_INPUT = "input[type=password]"
CODE_INPUT = "input[autocomplete=one-time-code], input[name=code], input[inputmode=numeric]"
SUBMIT = "button[type=submit]"


# nothing leaves the stack: the stack's hosts are those under the domain of FXA_CONTENT_URL
# (accounts.fxa.test: .fxa.test, the test reverse proxy's names, Authelia's too)
STACK_DOMAIN = "." + urlsplit(CONTENT).hostname.split(".", 1)[1]
# hosts outside the stack the pages may load, each with why: none (the accounts pages load
# everything from their own hosts: content-server.js points the CDN's URLs to FXA_CONTENT_URL,
# their fonts and images are files of the content server)
ALLOWED_HOSTS = {}
# the telemetry and error-report hosts, named as such when the pages ask one
TELEMETRY_HOSTS = re.compile(r"(^|\.)(mozilla\.org|mozilla\.com|mozilla\.net|mozaws\.net|firefox\.com|"
                             r"google-analytics\.com|googletagmanager\.com)$|sentry|amplitude|telemetry")
# every request of every Firefox's pages (url, its browsing context), as they come
REQUESTS = []


def outside_stack(url):
    """The host of a request outside the stack and not allowed, else None (about:, data:,
    blob: and the browser's own schemes are no request to a host)"""
    parts = urlsplit(url)
    host = (parts.hostname or "").lower()
    if parts.scheme not in ("http", "https", "ws", "wss") or not host:
        return None
    if host.endswith(STACK_DOMAIN) or host in ALLOWED_HOSTS:
        return None
    return host


def record_requests(driver):
    """Record every request of this Firefox's pages into REQUESTS: a WebDriver BiDi connection
    of its own to the session (webSocketUrl), subscribed to network.beforeRequestSent before
    the first page loads. Requests of the browser itself (updates, its own services) belong to
    no page and are not events there."""
    ws = websocket.create_connection(driver.capabilities["webSocketUrl"], timeout=30, suppress_origin=True)
    ws.send(json.dumps({"id": 1, "method": "session.subscribe", "params": {"events": ["network.beforeRequestSent"]}}))
    while True:
        reply = json.loads(ws.recv())
        if reply.get("id") == 1:
            assert reply.get("type") == "success", f"WebDriver BiDi: no network events: {reply}"
            break
    ws.settimeout(None)

    def listen():
        try:
            while True:
                event = json.loads(ws.recv())
                if event.get("method") == "network.beforeRequestSent":
                    REQUESTS.append((event["params"]["request"]["url"], event["params"].get("context")))
        except Exception:  # (the browser quit: its connection closed)
            pass

    threading.Thread(target=listen, daemon=True).start()


def requests_outside_stack(start):
    """The requests outside the stack since REQUESTS[start], one line each"""
    out = []
    for url, _ in REQUESTS[start:]:
        host = outside_stack(url)
        if host:
            kind = "a telemetry or error-report host" if TELEMETRY_HOSTS.search(host) else "outside the stack"
            out.append(f"{host} ({kind}): {url[:200]}")
    return sorted(set(out))


# the Firefox profiles of the running test (and first_device's): dumped when it fails
LIVE = []
ACCESS = os.environ.get("FFS_ACCESS", "none")
CLIENT_P12 = "/client-certs/client.p12"


def add_client_certificate(profile, p12=CLIENT_P12):
    """The client certificate in the profile's own certificate database, as a user imports it
    (Settings, Certificates, Your Certificates, Import): a new database, then the PKCS#12"""
    db = f"sql:{profile}"
    subprocess.run(["certutil", "-N", "-d", db, "--empty-password"], check=True, capture_output=True)
    subprocess.run(["pk12util", "-i", p12, "-d", db, "-W", "ffs-test"], check=True, capture_output=True)


def sso_sign_in(driver):
    """Authelia's sign-in page, where the accounts pages send a browser without its session
    cookie (on the parent domain: the cookie of every host); back on the accounts pages"""
    driver.get(f"{CONTENT}/")
    for _ in range(30):
        if driver.current_url.startswith("https://auth.fxa.test/") and visible(driver, "#username-textfield"):
            break
        time.sleep(0.5)
    assert driver.current_url.startswith("https://auth.fxa.test/"), f"not sent to Authelia: {driver.current_url}"
    visible(driver, "#username-textfield")[0].send_keys(os.environ["FFS_SSO_USER"])
    visible(driver, "#password-textfield")[0].send_keys(os.environ["FFS_SSO_PASSWORD"])
    visible(driver, "#sign-in-button")[0].click()
    for _ in range(30):
        if driver.current_url.startswith(f"{CONTENT}/"):
            return
        time.sleep(0.5)
    raise AssertionError(f"Authelia did not send Firefox back to the accounts pages: {driver.current_url}")


def start_firefox(client_certificate=None, sso=None, **extra_prefs):
    profile = tempfile.mkdtemp(prefix="ffs-firefox-")
    if client_certificate is None:
        client_certificate = ACCESS == "mtls"
    if client_certificate:
        add_client_certificate(profile)
        # sends it without asking (the default asks every time)
        extra_prefs.setdefault("security.default_personal_cert", "Select Automatically")
    prefs = {
        "identity.fxaccounts.autoconfig.uri": CONTENT,
        "browser.aboutwelcome.enabled": False,
        "datareporting.policy.dataSubmissionPolicyBypassNotification": True,
        "identity.fxaccounts.loglevel": "Debug",
        **extra_prefs,
    }
    with open(os.path.join(profile, "user.js"), "w") as f:
        for k, v in prefs.items():
            f.write(f"user_pref({json.dumps(k)}, {json.dumps(v)});\n")
    opts = Options()
    opts.binary_location = os.environ.get("FIREFOX_BINARY", "/usr/bin/firefox")
    opts.add_argument("-headless")
    opts.add_argument("-profile")
    opts.add_argument(profile)
    # WebDriver BiDi too: record_requests
    opts.set_capability("webSocketUrl", True)
    log = open(os.path.join(tempfile.gettempdir(), f"{os.path.basename(profile)}.log"), "w")
    service = Service(
        executable_path=os.environ.get("GECKODRIVER", "/usr/local/bin/geckodriver"),
        service_args=["--allow-system-access"],
        log_output=log,
    )
    driver = webdriver.Firefox(options=opts, service=service)
    LIVE.append(driver)
    record_requests(driver)
    if sso is None:
        sso = ACCESS == "authelia"
    if sso:
        sso_sign_in(driver)
    return driver


def quit_firefox(driver):
    if driver in LIVE:
        LIVE.remove(driver)
    driver.quit()


def firefox_version(driver):
    caps = driver.capabilities
    return f"Firefox {caps.get('browserVersion')} ({caps.get('platformName')}), geckodriver {caps.get('moz:geckodriverVersion')}"


PAGE_SUMMARY = """
    const shown = e => !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
    const attrs = e => ['type', 'name', 'id', 'autocomplete', 'inputmode', 'role', 'href', 'data-testid']
      .filter(a => e.getAttribute(a)).map(a => `${a}=${e.getAttribute(a)}`).join(' ');
    const fields = [...document.querySelectorAll('input, button, a[role=button], select, textarea')].filter(shown)
      .map(e => `<${e.tagName.toLowerCase()} ${attrs(e)}${e.disabled ? ' disabled' : ''}> ${(e.innerText || e.value || '').trim().slice(0, 60)}`);
    return { title: document.title, text: (document.body || {}).innerText || '', fields };
"""


def describe(driver, name):
    """What every open window of this Firefox shows (for a failure): the job log gets the
    version, the address, the text and the form fields; BROWSER_ARTIFACTS the page source and
    a screenshot."""
    out = [f"---- {name}: {firefox_version(driver)}"]
    artifacts = os.environ.get("BROWSER_ARTIFACTS")
    try:
        handles = driver.window_handles
        current = driver.current_window_handle
    except Exception as e:  # (the browser is gone)
        return f"{out[0]}: no window ({e})"
    for i, handle in enumerate(handles):
        try:
            driver.switch_to.window(handle)
            page = driver.execute_script(PAGE_SUMMARY)
            out.append(f"window {i + 1}/{len(handles)}{' (current)' if handle == current else ''}: {driver.current_url} {page['title']!r}")
            out.append("  text: " + " | ".join(line.strip() for line in page["text"].splitlines() if line.strip())[:1500])
            out.extend(f"  {f}" for f in page["fields"][:40])
            if artifacts:
                os.makedirs(artifacts, exist_ok=True)
                base = os.path.join(artifacts, f"{re.sub(r'[^A-Za-z0-9_.-]', '_', name)}-{i + 1}")
                with open(f"{base}.html", "w") as f:
                    f.write(driver.page_source)
                driver.save_screenshot(f"{base}.png")
                out.append(f"  page source and screenshot: {os.path.basename(base)}.html, .png")
        except Exception as e:
            out.append(f"window {i + 1}: not readable ({e})")
    try:
        driver.switch_to.window(current)
    except Exception:
        pass
    return "\n".join(out)


@pytest.fixture(autouse=True)
def browsers(request):
    """Each test's Firefox profiles quit after it; when it failed, what they showed first.
    Then the requests of its pages (first_device's too) outside the stack: none."""
    failed = request.session.testsfailed
    started = len(LIVE)
    asked = len(REQUESTS)
    yield
    if request.session.testsfailed > failed:
        # its own and first_device, when it uses it
        drivers = ([request.getfixturevalue("first_device")] if "first_device" in request.fixturenames else []) + LIVE[started:]
        dumps = [describe(d, f"{request.node.name}-firefox{i + 1}") for i, d in enumerate(drivers)]
        # (to the job log, past pytest's capture: the failed test's report is out already)
        with request.config.pluginmanager.getplugin("capturemanager").global_and_fixture_disabled():
            print(f"\n==== {request.node.name} failed, its Firefox windows:\n" + "\n".join(dumps), flush=True)
    for driver in LIVE[started:]:
        quit_firefox(driver)
    outside = requests_outside_stack(asked)
    if outside:
        pytest.fail(f"the pages of {request.node.name} made {len(outside)} request(s) outside the stack (nothing may leave it, "
                    "docs/accounts.md#telemetry; ALLOWED_HOSTS for one that must be):\n  " + "\n  ".join(outside), pytrace=False)


@pytest.fixture(scope="session", autouse=True)
def version_banner(request):
    """The Firefox version, first in the log: when only these tests fail, a new Firefox
    (tests/browser installs the latest) or a new accounts release are the suspects."""
    out = os.popen(f"{os.environ.get('FIREFOX_BINARY', '/usr/bin/firefox')} --version 2>/dev/null").read().strip()
    with request.config.pluginmanager.getplugin("capturemanager").global_and_fixture_disabled():
        print(f"\n{out or 'Firefox: version unknown'}, accounts pages {CONTENT}", flush=True)
    yield
    # the hosts the pages asked, with how many requests each (the record of what they load)
    hosts = {}
    for url, _ in REQUESTS:
        parts = urlsplit(url)
        key = f"{parts.scheme}://{parts.hostname}" if parts.hostname else parts.scheme + ":"
        hosts[key] = hosts.get(key, 0) + 1
    with request.config.pluginmanager.getplugin("capturemanager").global_and_fixture_disabled():
        print(f"\nthe pages' {len(REQUESTS)} requests, by host: " + ", ".join(f"{h} {n}" for h, n in sorted(hosts.items())), flush=True)


def chrome(driver, script, *args):
    """Privileged JavaScript in the browser (async: resolve with the last argument)."""
    with driver.context(driver.CONTEXT_CHROME):
        return driver.execute_async_script(script, *args)


def mail_codes(email):
    found = requests.get(f"{MAILPIT}/api/v1/search", params={"query": f"to:{email}"}, timeout=10).json()
    for message in found.get("messages", []):
        headers = requests.get(f"{MAILPIT}/api/v1/message/{message['ID']}/headers", timeout=10).json()
        for name in ("X-Verify-Short-Code", "X-Verify-Code", "X-Signin-Verify-Code"):
            if headers.get(name):
                yield headers[name][0]


def visible(driver, css):
    return [e for e in driver.find_elements(By.CSS_SELECTOR, css) if e.is_displayed() and e.is_enabled()]


def signed_in_user(driver):
    return chrome(driver, """
        const done = arguments[arguments.length - 1];
        const { getFxAccountsSingleton } = ChromeUtils.importESModule("resource://gre/modules/FxAccounts.sys.mjs");
        getFxAccountsSingleton().getSignedInUser().then(u => done(u ? { email: u.email, uid: u.uid, verified: !!u.verified } : null), e => done(null));
    """)


def first_uid(first_device):
    user = signed_in_user(first_device)
    assert user, "the first Firefox is not signed in: test_sign_up_and_sync failed before"
    return user["uid"]


def open_sign_in(driver):
    """Click 'Sign in' in the Sync preferences: the accounts pages in a new tab"""
    chrome(driver, """
        const done = arguments[arguments.length - 1];
        Services.wm.getMostRecentWindow("navigator:browser").gSync.openFxAEmailFirstPage("preferences").then(() => done(), () => done());
    """)
    time.sleep(3)
    driver.switch_to.window(driver.window_handles[-1])


def sign_in(driver):
    """Click 'Sign in' in the Sync preferences, then fill in the accounts pages."""
    open_sign_in(driver)

    def finished(heading):
        user = signed_in_user(driver)
        if user and (user["verified"] or "Sync is turned on" in heading or "signed in" in heading.lower()):
            return user

    return fill_in_accounts_pages(driver, finished)


def follow_new_window(driver, known):
    """The newest window or tab, when the accounts pages opened one (or closed the current
    one); known: the window handles seen so far, updated."""
    handles = driver.window_handles
    new = [h for h in handles if h not in known]
    known.update(handles)
    try:
        closed = driver.current_window_handle not in handles
    except Exception:  # (NoSuchWindowException: the current one is closed)
        closed = True
    if new or closed:
        driver.switch_to.window((new or handles)[-1])


def fill_in_page(driver, email, code=None):
    """One accounts page, by the role of its fields (their markup changes between releases:
    the email-first page has <input type=text autocomplete=email> since v1.348.0): the email,
    the password(s) or the confirmation code (code(): the next one from the mailbox, or None
    while none came), then its submit button. What it did, for the error."""
    passwords = visible(driver, PASSWORD_INPUT)
    emails = [e for e in visible(driver, EMAIL_INPUT) if not e.get_attribute("readonly")]
    codes = visible(driver, CODE_INPUT)
    if passwords:
        for field in passwords:
            field.clear()
            field.send_keys(PASSWORD)
        done = f"{len(passwords)} password(s)"
    elif emails:
        emails[0].clear()
        emails[0].send_keys(email)
        done = "email"
    elif codes and code:
        value = code()
        if not value:
            return "waiting for the code"
        codes[0].clear()
        codes[0].send_keys(value)
        done = "code"
    else:
        done = "nothing to fill in"
    buttons = visible(driver, SUBMIT)
    if buttons:
        done += f", clicked {buttons[0].text.strip()[:40]!r}"  # (before: the click can replace it)
        buttons[0].click()
    return done


def heading_of(driver):
    return driver.execute_script("return (document.querySelector('h1,h2')||{}).innerText||''")


def fill_in_accounts_pages(driver, finished, used_codes=(), email=EMAIL, codes=True):
    """The accounts pages, page after page, until finished(heading) returns something.
    used_codes: confirmation codes already in the mailbox, not for this sign-in; codes
    False: never one (someone whose codes never arrive)."""
    used_codes = set(used_codes)

    def next_code():
        if not codes:
            return None
        fresh = [c for c in mail_codes(email) if c not in used_codes]
        if fresh:
            used_codes.add(fresh[0])
            return fresh[0]

    known, steps = set(driver.window_handles), []
    for _ in range(15):
        time.sleep(3)
        follow_new_window(driver, known)
        heading = heading_of(driver)
        result = finished(heading)
        if result:
            return result
        steps.append(f"{driver.current_url.split('?')[0]} {heading!r}: {fill_in_page(driver, email, next_code)}")
    raise AssertionError(f"sign-in did not finish ({firefox_version(driver)}), last page: "
                         f"{driver.current_url.split('?')[0]} {heading!r}; the pages and what the test did:\n  "
                         + "\n  ".join(steps[-8:]) + "\n(the last page's text and fields: '==== <this test> failed' in the log)")


def wait_for_sync(driver, timeout=180):
    """Firefox finishes in the background: Sync keys from the web pages, then Sync itself."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        state = chrome(driver, """
            const done = arguments[arguments.length - 1];
            const { getFxAccountsSingleton } = ChromeUtils.importESModule("resource://gre/modules/FxAccounts.sys.mjs");
            const { Weave } = ChromeUtils.importESModule("resource://services-sync/main.sys.mjs");
            getFxAccountsSingleton().keys.hasKeysForScope("https://identity.mozilla.com/apps/oldsync")
              .then(keys => done({ keys, setup: Weave.Status.checkSetup() }), e => done({ error: String(e) }));
        """)
        if state.get("keys") and state.get("setup") != "service.client_not_configured":
            return state
        time.sleep(5)
    raise AssertionError(f"Firefox never got the Sync keys: {state}")


SYNC = """
    const [url, title, done] = arguments;
    const { PlacesUtils } = ChromeUtils.importESModule("resource://gre/modules/PlacesUtils.sys.mjs");
    const { Weave } = ChromeUtils.importESModule("resource://services-sync/main.sys.mjs");
    (async () => {
      if (title) {
        await PlacesUtils.bookmarks.insert({ parentGuid: PlacesUtils.bookmarks.toolbarGuid, url, title });
      }
      for (let i = 0; i < 3; i++) { await Weave.Service.sync({ why: "user" }); }
      const found = [];
      await PlacesUtils.bookmarks.fetch({ url }, b => found.push(b.title));
      return { status: Weave.Status.sync, cluster: Weave.Service.clusterURL, found };
    })().then(done, e => done({ error: String(e) }));
"""


@pytest.fixture(scope="module")
def first_device():
    driver = start_firefox()
    yield driver
    quit_firefox(driver)


def test_sign_up_and_sync(first_device):
    user = sign_in(first_device)
    assert user["email"] == EMAIL
    wait_for_sync(first_device)
    result = chrome(first_device, SYNC, BOOKMARK_URL, BOOKMARK_TITLE)
    assert result.get("status") == "success.sync", result
    assert result["found"] == [BOOKMARK_TITLE]


def test_second_device_gets_the_bookmark(first_device):
    driver = start_firefox()
    user = sign_in(driver)
    assert user["uid"] == first_uid(first_device)
    wait_for_sync(driver)
    result = chrome(driver, SYNC, BOOKMARK_URL, None)
    assert result.get("status") == "success.sync", result
    assert result["found"] == [BOOKMARK_TITLE], result


def test_admin_shows_the_devices_and_the_data(first_device):
    # the two Firefox profiles above, as the admin UI sees them
    if not os.environ.get("ADMIN_PASSWORD"):
        pytest.skip("no admin UI")
    admin = os.environ.get("ADMIN_URL", "https://admin.fxa.test").rstrip("/")
    http = requests.Session()
    http.verify = "/caddy-ca/root.crt"
    http.post(f"{admin}/login", data={"password": os.environ["ADMIN_PASSWORD"]}, timeout=30)
    uid = first_uid(first_device)
    page = http.get(f"{admin}/users/{uid}", timeout=30).text
    assert EMAIL in page, page[:1000]
    # errors of the queries (Devices: ..., Sync storage: ...)
    assert 'class="failed"' not in page, re.findall(r'class="failed"[^>]*>([^<]*)', page)
    devices = page.split('<table id="devices"')[1].split("</table>")[0]
    assert devices.count("<tr><td>") >= 2 and "Firefox" in devices, devices
    collections = page.split('<table id="collections"')[1].split("</table>")[0]
    assert "<td>bookmarks</td>" in collections, collections


def test_admin_sign_in_with_the_account(first_device):
    # the admin UI signs in with these accounts: ADMIN_ALLOWED_USERS=@example.com in
    # tests/e2e-fxa.sh, a new Firefox with the account of the tests above
    if not os.environ.get("ADMIN_FXA_CLIENT_ID"):
        pytest.skip("the admin UI does not sign in with these accounts")
    admin = os.environ.get("ADMIN_URL", "https://admin.fxa.test").rstrip("/")
    driver = start_firefox()
    stale = set(mail_codes(EMAIL))
    driver.get(f"{admin}/login")
    driver.find_element(By.LINK_TEXT, "Sign in with Mozilla account").click()

    def finished(heading):
        # the callback's page moves on to the dashboard by itself
        if driver.current_url == f"{admin}/" and "Sign out" in driver.page_source:
            return driver.page_source

    page = fill_in_accounts_pages(driver, finished, used_codes=stale)
    assert f'<span class="hint">{EMAIL}</span>' in page, page[:2000]


def test_refused_sign_up_shows_an_error():
    # FXA_SIGNUP_ALLOWLIST of tests/e2e-fxa.sh: example.org is not on it
    driver = start_firefox()
    driver.get(f"{CONTENT}/")
    address = f"ffs-refused-{uuid.uuid4().hex[:8]}@example.org"
    text, steps = "", []
    for _ in range(10):
        time.sleep(3)
        text = driver.execute_script("return document.body.innerText")
        if "blocked" in text.lower():
            break
        if visible(driver, CODE_INPUT):
            raise AssertionError("refused sign-up got to the confirmation code")
        steps.append(f"{heading_of(driver)!r}: {fill_in_page(driver, address)}")
    assert "blocked" in text.lower(), (steps[-5:], text[:600])


def admin_browser(**prefs):
    """A Firefox signed in to the admin UI with the password, or None without it"""
    if not os.environ.get("ADMIN_PASSWORD"):
        return None, None
    admin = os.environ.get("ADMIN_URL", "https://admin.fxa.test").rstrip("/")
    driver = start_firefox(**prefs)
    driver.get(f"{admin}/login")
    driver.find_element(By.ID, "password").send_keys(os.environ["ADMIN_PASSWORD"])
    driver.find_element(By.CSS_SELECTOR, "form[action='/login'] button[type=submit]").click()
    for _ in range(20):
        if driver.current_url == f"{admin}/" and "Sign out" in driver.page_source:
            return driver, admin
        time.sleep(0.5)
    raise AssertionError(f"admin sign-in failed: {driver.current_url}")


def test_admin_fits_a_phone():
    # a window is at least 500 px wide: zoomed in to 139%, the page gets 360 CSS pixels,
    # like most phones (the media queries follow the zoom)
    driver, admin = admin_browser()
    if not driver:
        pytest.skip("no admin UI")
    driver.set_window_size(500, 1028)
    for path in ("/", "/activity", "/security", "/config"):
        driver.get(f"{admin}{path}")
        with driver.context(driver.CONTEXT_CHROME):
            driver.execute_script("gBrowser.selectedBrowser.fullZoom = 500 / 360")
        time.sleep(0.5)
        width = driver.execute_script("return window.innerWidth")
        assert 350 <= width <= 370, f"the window is {width} CSS px wide"
        # the page itself does not scroll sideways, the wide tables do in their box
        scroll = driver.execute_script("return Math.max(document.body.scrollWidth, document.documentElement.scrollWidth)")
        # (what sticks out, for the error)
        widest = driver.execute_script("""return [...document.querySelectorAll('body *')].map(e => [e.getBoundingClientRect().right, e.tagName + '.' + e.className])
            .sort((x, y) => y[0] - x[0]).slice(0, 3)""")
        assert scroll <= width, (path, scroll, width, widest)
        # the stylesheet applies (style-src 'self' of the CSP): buttons tall enough to tap
        # (the shown ones: those of a closed <details> have no box)
        heights = driver.execute_script("return [...document.querySelectorAll('main button, header nav a')].map(e => e.getBoundingClientRect().height).filter(h => h > 0)")
        assert heights and min(heights) >= 44, (path, heights)
        if path == "/":
            accounts = driver.find_element(By.ID, "accounts")
            assert accounts.find_element(By.XPATH, "..").get_attribute("class") == "scroll"


def test_admin_disables_through_the_confirm_page(first_device):
    # last of the tests of this account: it gets signed out, then enabled again
    driver, admin = admin_browser()
    if not driver:
        pytest.skip("no admin UI")
    uid = first_uid(first_device)
    # the account through the search of the list (50 a page)
    driver.find_element(By.ID, "find-q").send_keys(EMAIL)
    driver.find_element(By.CSS_SELECTOR, "#find button[type=submit]").click()
    time.sleep(1)
    driver.find_element(By.CSS_SELECTOR, f'tr[data-email="{EMAIL}"] a[href="/accounts/{uid}/disable"]').click()
    assert driver.current_url == f"{admin}/accounts/{uid}/disable"
    page = driver.page_source
    assert f"Disable {EMAIL}?" in page and "Firefox" in page.split('id="confirm-devices"')[1], page[:3000]
    # the CSP blocks inline styles and scripts: the page is styled by the stylesheet only
    color = driver.execute_script("return getComputedStyle(document.querySelector('#confirm button.danger')).backgroundColor")
    assert color == "rgb(180, 35, 42)", color
    assert driver.find_element(By.ID, "cancel").get_attribute("href") == f"{admin}/users/{uid}"
    driver.find_element(By.ID, "reason").send_keys("browser test")
    driver.find_element(By.CSS_SELECTOR, "#confirm button[type=submit]").click()
    time.sleep(1)
    assert driver.current_url == f"{admin}/users/{uid}", driver.current_url
    message = driver.find_element(By.CSS_SELECTOR, "p.message[role=status]").text
    assert message.startswith(f"Disabled {EMAIL} (uid {uid[:8]})"), message
    assert "disabled" in driver.find_element(By.TAG_NAME, "main").text
    # enabling is one click
    driver.find_element(By.CSS_SELECTOR, f'form[action="/accounts/{uid}/enable"] button').click()
    time.sleep(1)
    assert driver.find_element(By.CSS_SELECTOR, "p.message[role=status]").text.startswith(f"Enabled {EMAIL}")


def test_invite_link_fills_in_the_email():
    # the link of an invitation (docs/admin/accounts.md#invitations): the accounts pages open with the email filled in
    if not os.environ.get("ADMIN_PASSWORD"):
        pytest.skip("no admin UI")
    admin = os.environ.get("ADMIN_URL", "https://admin.fxa.test").rstrip("/")
    http = requests.Session()
    http.verify = "/caddy-ca/root.crt"
    http.post(f"{admin}/login", data={"password": os.environ["ADMIN_PASSWORD"]}, timeout=30)
    csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', http.get(f"{admin}/", timeout=30).text).group(1)
    address = f"ffs-invite-{uuid.uuid4().hex[:8]}@example.com"
    res = http.post(f"{admin}/accounts/invite", data={"csrf": csrf, "email": address}, timeout=30)
    assert f"Invited {address}" in res.text, res.text[:2000]
    link = None
    for _ in range(30):
        found = requests.get(f"{MAILPIT}/api/v1/search", params={"query": f"to:{address}"}, timeout=10).json().get("messages", [])
        if found:
            text = requests.get(f"{MAILPIT}/api/v1/message/{found[0]['ID']}", timeout=10).json()["Text"]
            link = re.search(r"https://\S+/\?email=\S+", text).group(0)
            break
        time.sleep(1)
    assert link and link.startswith(CONTENT), link
    driver = start_firefox()
    driver.get(link)
    seen = ""
    for _ in range(20):
        time.sleep(1.5)
        values = [e.get_attribute("value") for e in visible(driver, EMAIL_INPUT)]
        seen = " ".join(values) + " " + driver.execute_script("return document.body.innerText")
        if address in seen:
            break
    # filled in the email field, or shown on the sign-up page it moves on to
    assert address in seen, (driver.current_url.split("?")[0], seen[:600])
    print(f"invite link: {driver.current_url.split('?')[0]}, email in a field: {address in values}")


def firefox_state(driver):
    """Where a Firefox is: the page (address, heading), the account and whether it has the Sync keys"""
    state = chrome(driver, """
        const done = arguments[arguments.length - 1];
        const { getFxAccountsSingleton } = ChromeUtils.importESModule("resource://gre/modules/FxAccounts.sys.mjs");
        const fxa = getFxAccountsSingleton();
        fxa.getSignedInUser().then(u => u ? fxa.keys.hasKeysForScope("https://identity.mozilla.com/apps/oldsync")
            .then(keys => done({ user: true, verified: !!u.verified, keys }), () => done({ user: true, verified: !!u.verified, keys: false }))
          : done({ user: false, verified: false, keys: false }), e => done({ error: String(e) }));
    """)
    try:
        state["page"] = f"{driver.current_url.split('?')[0]} {heading_of(driver)!r}"
        state["code_prompt"] = bool(visible(driver, CODE_INPUT))
    except Exception as e:  # (the tab closed)
        state["page"], state["code_prompt"] = f"none ({type(e).__name__})", False
    return state


def test_admin_confirms_a_sign_up_waiting_for_its_code():
    # someone whose codes never arrive: Firefox signs up and waits at the code prompt, the
    # admin confirms the email and that sign-in (docs/admin/accounts.md#their-confirmation-email-never-arrived).
    # What Firefox does then is recorded (a warning in the summary), not required: the
    # accounts pages do not poll the session, nor does Firefox in the OAuth flow
    if not os.environ.get("ADMIN_PASSWORD"):
        pytest.skip("no admin UI")
    admin = os.environ.get("ADMIN_URL", "https://admin.fxa.test").rstrip("/")
    address = f"ffs-browser-{uuid.uuid4().hex[:12]}@example.com"
    driver = start_firefox()
    open_sign_in(driver)
    fill_in_accounts_pages(driver, lambda heading: visible(driver, CODE_INPUT) and not visible(driver, PASSWORD_INPUT) and "code prompt",
                           email=address, codes=False)
    http = requests.Session()
    http.verify = "/caddy-ca/root.crt"
    http.post(f"{admin}/login", data={"password": os.environ["ADMIN_PASSWORD"]}, timeout=30)
    found = re.search(r'<tr data-email="' + re.escape(address) + r'">\s*<td><a href="/users/([0-9a-f]{32})">',
                      http.get(f"{admin}/", params={"q": address}, timeout=30).text)
    assert found, f"{address} not in the admin UI"
    uid = found.group(1)
    page = http.get(f"{admin}/accounts/{uid}/confirm-email", timeout=30).text
    assert '<table id="confirm-pending"' in page and "Firefox" in page.split('<table id="confirm-pending"')[1].split("</table>")[0], page[:3000]
    form = page.split('id="confirm">')[1]
    fields = dict(re.findall(r'<input type="hidden" name="([^"]+)" value="([^"]*)">', form))
    done = http.post(f"{admin}/accounts/{uid}/confirm-email", data={**fields, "reason": "browser test: no code"}, timeout=30).text
    assert f"Confirmed the email of {address} (uid {uid[:8]}) and its 1 pending sign-in" in done, re.findall(r'class="(?:message|failed)"[^>]*>([^<]*)', done)
    user = http.get(f"{admin}/users/{uid}", timeout=30).text
    assert "unconfirmed sign-in" not in user.split('<table id="sessions"')[1].split("</table>")[0], user[-4000:]

    # by itself, for a minute: does the page move on, does Firefox get the keys?
    seen, by_itself = [], None
    for _ in range(12):
        time.sleep(5)
        state = firefox_state(driver)
        if not seen or state != seen[-1]:
            seen.append(state)
        if state.get("keys") or not state.get("code_prompt"):
            by_itself = state
            break
    # then what the docs tell the person: sign in again in that Firefox (no code: the
    # account is less than 48 hours old)
    again = None
    if not (by_itself and by_itself.get("keys")):
        try:
            open_sign_in(driver)
            fill_in_accounts_pages(driver, lambda heading: firefox_state(driver).get("keys") and "keys", email=address, codes=False)
            again = firefox_state(driver)
        except Exception as e:  # (an observation: whatever Firefox shows instead)
            again = {"failed": f"{type(e).__name__}: {str(e).splitlines()[0][:300] if str(e) else ''}"}
            try:
                again.update(firefox_state(driver))
            except Exception:
                pass
    warnings.warn(f"admin confirm, Firefox at the code prompt ({firefox_version(driver)}): by itself within 60 s: "
                  f"{by_itself or 'nothing'}; states {seen}; signing in again: {again or 'not needed'}")
