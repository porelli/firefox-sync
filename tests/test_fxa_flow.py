"""What Firefox does with a self-hosted Mozilla account (compose/fxa.yml).

Sign-up, email verification, keys, OAuth, tokenserver and sync, all against this
deployment through its public HTTPS URLs: no Mozilla service is involved.
Runs inside the syncstorage-rs image, which ships PyFxA (Mozilla's FxA client).

Environment:
  FXA_CONTENT_URL, FXA_AUTH_URL  public URLs of the accounts web pages and API
  SYNC_PUBLIC_URL             public URL of the sync server (node URL)
  MAILPIT_URL                    mail catcher API, e.g. http://mailpit:8025
  REQUESTS_CA_BUNDLE             CA of the test reverse proxy
"""

import base64
import hashlib
import json
import os
import time
import uuid
from urllib.parse import parse_qs, urlparse

import hawkauthlib
import pytest
import requests
from fxa._utils import HawkTokenAuth
from fxa.core import Client
from fxa.oauth import Client as OAuthClient
from webob import Request

CONTENT = os.environ["FXA_CONTENT_URL"].rstrip("/")
AUTH = os.environ["FXA_AUTH_URL"].rstrip("/")
SYNC = os.environ["SYNC_PUBLIC_URL"].rstrip("/")
MAILPIT = os.environ.get("MAILPIT_URL", "http://mailpit:8025").rstrip("/")
FIREFOX_CLIENT_ID = "5882386c6d801776"
SYNC_SCOPE = "https://identity.mozilla.com/apps/oldsync"
EMAIL = f"ffs-{uuid.uuid4().hex[:12]}@example.com"
PASSWORD = uuid.uuid4().hex


def wait_for_code(email, timeout=120):
    """Verification code from the email FxA sent to this address."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        found = requests.get(f"{MAILPIT}/api/v1/search", params={"query": f"to:{email}"}, timeout=10).json()
        for message in found.get("messages", []):
            headers = requests.get(f"{MAILPIT}/api/v1/message/{message['ID']}/headers", timeout=10).json()
            for name in ("X-Verify-Short-Code", "X-Verify-Code", "X-Signin-Verify-Code"):
                if headers.get(name):
                    return headers[name][0]
        time.sleep(2)
    raise AssertionError(f"no verification email for {email}")


def authorize(session, full=False, offline=False):
    """OAuth access token for Sync, requested like Firefox 154+ does.

    FxA is moving from Hawk to Bearer tokens (FXA-9392): /oauth/authorization
    now rejects Hawk-signed requests (PyFxA 0.8 authorize_token), Firefox sends
    `Bearer fxs_<token id>` instead. offline: also a refresh token, like the mobile apps.
    """
    oauth = OAuthClient(client_id=FIREFOX_CLIENT_ID, server_url=AUTH)
    challenge, verifier = oauth.generate_pkce_challenge()
    token_id = HawkTokenAuth(session.token, "sessionToken").id
    state = uuid.uuid4().hex
    res = requests.post(
        f"{AUTH}/v1/oauth/authorization",
        json={"client_id": FIREFOX_CLIENT_ID, "scope": SYNC_SCOPE, "state": state, **challenge,
              **({"access_type": "offline"} if offline else {})},
        headers={"Authorization": f"Bearer fxs_{token_id}"},
        timeout=30,
    )
    assert res.status_code == 200, res.text
    data = res.json()
    query = parse_qs(urlparse(data.get("redirect", "")).query)
    assert data.get("state", query.get("state", [None])[0]) == state
    code = data.get("code") or query["code"][0]
    granted = oauth.trade_code(code, **verifier)
    return granted if full else granted["access_token"]


def sync_token(session, keys_changed_at):
    """OAuth token for Sync and the X-KeyID header, like Firefox after sign-in.

    keys_changed_at is when the account keys were created; it must be the same on
    every device as long as the keys do not change.
    """
    _, kb = session.fetch_keys()
    client_state = hashlib.sha256(kb).digest()[:16]
    token = authorize(session)
    # what the tokenserver will see when it verifies the token
    verified = requests.post(f"{AUTH}/v1/verify", json={"token": token}, timeout=30).json()
    assert verified["client_id"] == FIREFOX_CLIENT_ID and SYNC_SCOPE in verified["scope"], verified
    key_id = f"{keys_changed_at}-{base64.urlsafe_b64encode(client_state).rstrip(b'=').decode()}"
    return token, key_id


def storage(token, method, path, body=None):
    url = f"{token['api_endpoint']}{path}"
    data = json.dumps(body).encode() if body is not None else None
    signed = Request.blank(url, method=method)
    if data is not None:
        signed.body = data
        signed.content_type = "application/json"
    hawkauthlib.sign_request(signed, token["id"], token["key"])
    headers = {"Authorization": signed.headers["Authorization"]}
    if data is not None:
        headers["Content-Type"] = "application/json"
    return requests.request(method, url, data=data, headers=headers, timeout=30)


@pytest.fixture(scope="module")
def account():
    client = Client(server_url=f"{AUTH}/v1")
    created = int(time.time() * 1000)
    session = client.create_account(EMAIL, PASSWORD, keys=True)
    session.verify_email_code(wait_for_code(EMAIL))
    return {"client": client, "session": session, "keys_changed_at": created}


def test_client_configuration():
    # what Firefox reads after setting identity.fxaccounts.autoconfig.uri
    conf = requests.get(f"{CONTENT}/.well-known/fxa-client-configuration", timeout=30).json()
    assert conf["auth_server_base_url"].rstrip("/") == AUTH
    assert conf["oauth_server_base_url"].rstrip("/") == AUTH
    assert conf["profile_server_base_url"].rstrip("/") == os.environ["FXA_PROFILE_URL"].rstrip("/")
    if os.environ.get("FXA_PAIRING_URL"):
        assert conf["pairing_server_base_uri"].rstrip("/") == os.environ["FXA_PAIRING_URL"].rstrip("/")
    assert conf["sync_tokenserver_base_url"].rstrip("/") == SYNC


def test_pages_served_by_this_deployment():
    # the pages are built with Mozilla's CDN in their asset URLs: blank pages if not rewritten
    page = requests.get(f"{CONTENT}/oauth/signup?showReactApp=true", timeout=30).text
    assert "cdn.accounts.firefox.com" not in page
    assert f"{CONTENT}/settings/prod/static/js/main." in page


def test_sign_up_and_first_sync(account):
    bearer, key_id = sync_token(account["session"], account["keys_changed_at"])
    res = requests.get(f"{SYNC}/1.0/sync/1.5", headers={"Authorization": f"Bearer {bearer}", "X-KeyID": key_id}, timeout=30)
    assert res.status_code == 200, res.text
    token = res.json()
    assert token["api_endpoint"] == f"{SYNC}/1.5/{token['uid']}"

    assert storage(token, "GET", "/info/collections").json() == {}
    assert storage(token, "GET", "/storage/meta/global").status_code == 404
    meta = {"id": "global", "payload": json.dumps({"syncID": "abcdefghijkl", "storageVersion": 5})}
    assert storage(token, "PUT", "/storage/meta/global", meta).status_code == 200
    bookmarks = [{"id": f"bookmark{i:03d}", "payload": json.dumps({"title": f"b{i}"})} for i in range(3)]
    assert len(storage(token, "POST", "/storage/bookmarks", bookmarks).json()["success"]) == 3
    account["uid"], account["key_id"] = token["uid"], key_id


def test_scoped_keys_for_sync(account):
    # how the accounts web pages get the Sync keys for Firefox (keys_jwe), without
    # it Firefox signs in but never syncs ("OAuth login completed without scoped keys")
    token_id = HawkTokenAuth(account["session"].token, "sessionToken").id
    res = requests.post(
        f"{AUTH}/v1/account/scoped-key-data",
        json={"client_id": FIREFOX_CLIENT_ID, "scope": SYNC_SCOPE},
        headers={"Authorization": f"Bearer fxs_{token_id}"},
        timeout=30,
    )
    assert res.status_code == 200, res.text
    assert "keyRotationSecret" in res.json()[SYNC_SCOPE] or "keyRotationTimestamp" in res.json()[SYNC_SCOPE], res.text


def test_second_device_sign_in(account):
    # a new sign-in with the password, as on a second device
    session = account["client"].login(EMAIL, PASSWORD, keys=True)
    if not session.get_email_status().get("sessionVerified", True):
        session.verify_email_code(wait_for_code(EMAIL))
    bearer, key_id = sync_token(session, account["keys_changed_at"])
    res = requests.get(f"{SYNC}/1.0/sync/1.5", headers={"Authorization": f"Bearer {bearer}", "X-KeyID": key_id}, timeout=30)
    assert res.status_code == 200, res.text
    token = res.json()
    assert token["uid"] == account["uid"]
    stored = storage(token, "GET", "/storage/bookmarks").json()
    assert sorted(stored) == ["bookmark000", "bookmark001", "bookmark002"]


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def jwt_parts(token):
    """The header and claims of a JWT (the accounts' access tokens are JWTs)"""
    def part(text):
        return json.loads(base64.urlsafe_b64decode(text + "=" * (-len(text) % 4)))
    header, claims, _ = token.split(".")
    return part(header), part(claims)


def forge_jwt(header, claims):
    """A JWT signed RS256 by a key made now: none of the accounts' keys (/v1/jwks)"""
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import padding, rsa
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    signed = f"{b64url(json.dumps(header).encode())}.{b64url(json.dumps(claims).encode())}"
    return f"{signed}.{b64url(key.sign(signed.encode(), padding.PKCS1v15(), hashes.SHA256()))}"


def tokenserver_rows():
    """The tokenserver's users (their node, generation, keys) as the Sync server's own database
    has them; None where the tests run without its URL (the chart's test pods)"""
    url = os.environ.get("SYNC_TOKENSERVER__DATABASE_URL")
    if not url:
        return None
    from sqlalchemy import create_engine
    from sqlalchemy.sql import text as sqltext
    with create_engine(url).connect() as conn:
        return sorted(tuple(row) for row in conn.execute(sqltext(
            "SELECT uid, email, nodeid, generation, keys_changed_at, client_state, replaced_at FROM users")))


def test_foreign_tokens_are_refused(account):
    # the Sync server verifies Firefox's access token with the keys of FXA_OAUTH_SERVER_URL
    # (its /v1/jwks, else its /v1/verify): a token of other accounts (Mozilla's) is refused,
    # whatever its claims say, and nothing is written for it
    session, key_id = account["session"], account["key_id"]
    real = authorize(session)
    kids = [key["kid"] for key in requests.get(f"{AUTH}/v1/jwks", timeout=30).json()["keys"]]
    if real.count(".") == 2:
        header, claims = jwt_parts(real)
        assert claims["sub"] == session.uid and SYNC_SCOPE in claims["scope"], (header, claims)
        assert header["kid"] in kids, (header, kids)
    else:
        # (an opaque access token: the claims of the accounts' JWTs)
        header = {"alg": "RS256", "typ": "at+jwt", "kid": kids[0]}
        claims = {"iss": AUTH, "aud": FIREFOX_CLIENT_ID, "client_id": FIREFOX_CLIENT_ID, "sub": session.uid, "scope": SYNC_SCOPE}
    # the same claims, just issued, valid for an hour
    now = int(time.time())
    forged = {**claims, "iat": now, "exp": now + 3600, "jti": uuid.uuid4().hex}
    tokens = {
        # (b) another key, a kid the accounts never had
        "unknown key": forge_jwt({**header, "kid": f"foreign-{uuid.uuid4().hex[:8]}"}, forged),
        # (c) the accounts' kid, another key: the signature does not match
        "accounts' kid, another key": forge_jwt(header, forged),
        # (d) not a JWT: what the Sync server asks FXA_OAUTH_SERVER_URL's /v1/verify about
        "opaque": uuid.uuid4().hex + uuid.uuid4().hex,
    }
    before = tokenserver_rows()

    def ask(token):
        return requests.get(f"{SYNC}/1.0/sync/1.5", headers={"Authorization": f"Bearer {token}", "X-KeyID": key_id}, timeout=30)

    # (a) the accounts' own token: a Sync token for this account
    res = ask(real)
    assert res.status_code == 200 and res.json()["uid"] == account["uid"], res.text
    seen = {}
    for name, token in tokens.items():
        res = ask(token)
        seen[name] = res.status_code
        assert res.status_code in (401, 403), (name, res.status_code, res.text)
        assert "api_endpoint" not in res.text and "invalid-credentials" in res.text, (name, res.text)
    print(f"foreign tokens ({'JWT' if real.count('.') == 2 else 'opaque'} access tokens here): {seen}")
    # no user row, no node assignment made or changed for them
    assert tokenserver_rows() == before, "the tokenserver's users changed for a refused token"
    # the opaque token was asked only of the stack's accounts API (tests/e2e-fxa.sh counts its
    # refused /verify in fxa-auth's log: this test sends none itself)
    oauth = os.environ.get("SYNC_TOKENSERVER__FXA_OAUTH_SERVER_URL")
    if oauth:
        assert urlparse(oauth).hostname == "fxa-auth" and urlparse(oauth).port == 9000, oauth
    # and the real token still works after them
    assert ask(real).status_code == 200


def test_wrong_password_rejected():
    with pytest.raises(Exception):
        Client(server_url=f"{AUTH}/v1").login(EMAIL, "not-the-password")


def test_repeated_wrong_passwords_are_blocked():
    # built-in rate limiting (config/rate-limit-rules.txt): at most 5 failed
    # sign-ins per IP address and email in 15 minutes
    for _ in range(10):
        res = requests.post(f"{AUTH}/v1/account/login", json={"email": EMAIL, "authPW": "00" * 32}, timeout=30)
        if res.status_code == 429:
            assert res.json()["errno"] == 114, res.text
            return
        assert res.status_code == 400, res.text
    raise AssertionError("10 wrong passwords in a row were not rate limited")


def admin_confirm(path, **form):
    """Signs in to the admin UI with its password, submits the form of a confirm page"""
    import re
    admin = os.environ["ADMIN_URL"].rstrip("/")
    http = requests.Session()
    res = http.post(f"{admin}/login", data={"password": os.environ["ADMIN_PASSWORD"]}, timeout=30)
    assert res.status_code == 200 and "Sign out" in res.text, res.text[:500]
    page = http.get(f"{admin}{path}", timeout=30).text
    form_html = page.split('id="confirm">')[1]
    fields = dict(re.findall(r'<input type="hidden" name="([^"]+)" value="([^"]*)">', form_html))
    action = re.search(r'<form method="post" action="([^"]+)" id="confirm">', page).group(1)
    res = http.post(f"{admin}{action}", data={**fields, **form}, timeout=60)
    assert res.status_code == 200 and 'class="failed"' not in res.text, res.text[:3000]
    return res.text


@pytest.mark.skipif(not os.environ.get("ADMIN_URL"), reason="no admin UI")
def test_sync_again_after_a_reset(account):
    # the admin resets the Sync data: the next sync finds the server empty and uploads again
    # (the keys of the first sync: the key fetch token is single use, and the wrong
    # passwords above block new sign-ins)
    session, key_id = account["session"], account["key_id"]
    uid = session.uid
    # something stored, and the tokenserver's row of before
    bearer = authorize(session)
    res = requests.get(f"{SYNC}/1.0/sync/1.5", headers={"Authorization": f"Bearer {bearer}", "X-KeyID": key_id}, timeout=30)
    assert res.status_code == 200, res.text
    tabs = [{"id": "tabs000", "payload": json.dumps({"title": "before the reset"})}]
    assert len(storage(res.json(), "POST", "/storage/tabs", tabs).json()["success"]) == 1
    assert "tabs" in storage(res.json(), "GET", "/info/collections").json()
    rows = tokenserver_rows()
    done = admin_confirm(f"/users/{uid}/reset-sync")
    assert "Reset the Sync data of" in done, done[:3000]
    # SYNC_DELETE_DATA=true: through the Sync server's data deletion endpoint, not the
    # storage database (what the admin UI does when the endpoint fails, and says so)
    if os.environ.get("SYNC_DELETE_DATA") == "true":
        assert "through the Sync server&#39;s data deletion endpoint" in done or "through the Sync server's data deletion endpoint" in done, done[:3000]
        assert "deleted in the storage database instead" not in done, done[:3000]
    # the data is gone, the user kept as it was: the same tokenserver row (no new generation,
    # keys or node: what upstream's test_delete_data.py asserts of the endpoint)
    assert tokenserver_rows() == rows
    bearer = authorize(session)
    res = requests.get(f"{SYNC}/1.0/sync/1.5", headers={"Authorization": f"Bearer {bearer}", "X-KeyID": key_id}, timeout=30)
    assert res.status_code == 200, res.text
    token = res.json()
    assert token["uid"] == account["uid"] and storage(token, "GET", "/info/collections").json() == {}
    assert storage(token, "GET", "/storage/meta/global").status_code == 404
    meta = {"id": "global", "payload": json.dumps({"syncID": "mnopqrstuvwx", "storageVersion": 5})}
    assert storage(token, "PUT", "/storage/meta/global", meta).status_code == 200
    # and with its max users slot freed: a new tokenserver row, a working token
    done = admin_confirm(f"/users/{uid}/reset-sync", free_slot="1")
    assert "freed its max users slot" in done, done[:3000]
    bearer = authorize(session)
    res = requests.get(f"{SYNC}/1.0/sync/1.5", headers={"Authorization": f"Bearer {bearer}", "X-KeyID": key_id}, timeout=30)
    assert res.status_code == 200, res.text
    fresh = res.json()
    assert fresh["uid"] != account["uid"] and storage(fresh, "GET", "/info/collections").json() == {}
    bookmarks = [{"id": "bookmark000", "payload": json.dumps({"title": "again"})}]
    assert len(storage(fresh, "POST", "/storage/bookmarks", bookmarks).json()["success"]) == 1
