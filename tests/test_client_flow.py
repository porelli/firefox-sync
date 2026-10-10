"""What a Firefox client does against this stack, through the public URL.

Runs inside the syncstorage-rs image (PYTHONPATH=/app) so that upstream's test
helpers and the mock FxA server can be reused. Requests are sent to the
container like the nginx example does: Host and X-Forwarded-Proto set to the
public URL, so tokens and hawk signatures are the ones a real client gets.

Environment:
  SYNC_SERVER_URL                  where syncstorage listens (http://syncstorage:8000)
  SYNCSTORAGE_DOMAIN               public URL (the node URL), e.g. https://sync.example.com
  SYNC_TOKENSERVER__DATABASE_URL   tokenserver database, to check what got stored
  MAX_USERS                        must be 1 for the user limit tests
"""

import json
import os
import time
import urllib.parse as urlparse

import hawkauthlib
import pytest
import requests
from sqlalchemy import create_engine
from sqlalchemy.sql import text as sqltext
from webob import Request

from integration_tests.tokenserver.helpers import build_oauth_headers

SERVER = os.environ.get("SYNC_SERVER_URL", "http://syncstorage:8000")
DOMAIN = os.environ["SYNCSTORAGE_DOMAIN"].rstrip("/")
PUBLIC = urlparse.urlparse(DOMAIN)
PROXY_HEADERS = {"Host": PUBLIC.netloc, "X-Forwarded-Proto": PUBLIC.scheme}
EMAIL_DOMAIN = "api-accounts.stage.mozaws.net"


@pytest.fixture(scope="module")
def db():
    url = os.environ["SYNC_TOKENSERVER__DATABASE_URL"]
    if url.startswith("postgres://"):
        url = url.replace("postgres://", "postgresql://", 1)
    conn = create_engine(url).execution_options(isolation_level="AUTOCOMMIT").connect()
    yield conn
    conn.close()


def accounts(db):
    return db.execute(sqltext("SELECT COUNT(DISTINCT email) FROM users")).scalar()


def login(user, generation=1, keys_changed_at=1, client_state="aaaa"):
    """GET /1.0/sync/1.5 with a (mock) FxA OAuth token, like Firefox after sign-in."""
    headers = build_oauth_headers(
        user=user,
        generation=generation,
        keys_changed_at=keys_changed_at,
        client_state=client_state,
    )
    headers.update(PROXY_HEADERS)
    return requests.get(f"{SERVER}/1.0/sync/1.5", headers=headers, timeout=30)


class Storage:
    """Hawk-signed requests to the node returned by the tokenserver."""

    def __init__(self, token):
        self.token = token
        self.endpoint = token["api_endpoint"]

    def request(self, method, path, body=None):
        url = f"{self.endpoint}{path}"
        data = json.dumps(body).encode() if body is not None else None
        # sign the request as the client sees it (public URL), send it to the container
        signed = Request.blank(url, method=method)
        if data is not None:
            signed.body = data
            signed.content_type = "application/json"
        hawkauthlib.sign_request(signed, self.token["id"], self.token["key"])
        headers = dict(PROXY_HEADERS, Authorization=signed.headers["Authorization"])
        if data is not None:
            headers["Content-Type"] = "application/json"
        target = SERVER + urlparse.urlparse(url).path
        query = urlparse.urlparse(url).query
        if query:
            target += "?" + query
        return requests.request(method, target, data=data, headers=headers, timeout=30)


def test_first_sign_in_and_sync(db):
    res = login("alice")
    assert res.status_code == 200, res.text
    token = res.json()
    # the client is sent to this server's public URL
    assert token["api_endpoint"] == f"{DOMAIN}/1.5/{token['uid']}"
    assert accounts(db) == 1

    storage = Storage(token)
    res = storage.request("GET", "/info/collections")
    assert res.status_code == 200, res.text
    assert res.json() == {}

    # a fresh account has no meta/global yet: must be 404, not 500 (issue #13)
    res = storage.request("GET", "/storage/meta/global")
    assert res.status_code == 404, res.text

    meta = {"id": "global", "payload": json.dumps({"syncID": "abcdefghijkl", "storageVersion": 5})}
    res = storage.request("PUT", "/storage/meta/global", meta)
    assert res.status_code == 200, res.text
    res = storage.request("GET", "/storage/meta/global")
    assert res.status_code == 200, res.text
    assert res.json()["payload"] == meta["payload"]

    bookmarks = [{"id": f"bookmark{i:03d}", "payload": json.dumps({"title": f"b{i}"})} for i in range(5)]
    res = storage.request("POST", "/storage/bookmarks", bookmarks)
    assert res.status_code == 200, res.text
    assert len(res.json()["success"]) == 5

    res = storage.request("GET", "/info/collections")
    assert set(res.json()) == {"meta", "bookmarks"}
    res = storage.request("GET", "/storage/bookmarks?full=1")
    assert sorted(b["id"] for b in res.json()) == [b["id"] for b in bookmarks]


def test_second_device_same_account(db):
    first = login("alice").json()
    again = login("alice").json()
    # same account, same storage
    assert again["uid"] == first["uid"]
    res = Storage(again).request("GET", "/storage/bookmarks")
    assert res.status_code == 200
    assert len(res.json()) == 5
    assert accounts(db) == 1


def test_max_users_rejects_new_account(db):
    assert os.environ.get("MAX_USERS") == "1"
    res = login("bob")
    assert res.status_code != 200, res.text
    assert accounts(db) == 1
    emails = {r[0] for r in db.execute(sqltext("SELECT DISTINCT email FROM users"))}
    assert emails == {f"alice@{EMAIL_DOMAIN}"}


def test_max_users_allows_key_change_of_existing_account(db):
    # e.g. after a password reset: new generation, keys and client state,
    # syncstorage-rs records it as a new users row for the same account
    res = login("alice", generation=int(time.time()), keys_changed_at=int(time.time()), client_state="bbbb")
    assert res.status_code == 200, res.text
    token = res.json()
    assert accounts(db) == 1
    rows = db.execute(sqltext("SELECT COUNT(*) FROM users")).scalar()
    assert rows >= 2

    storage = Storage(token)
    res = storage.request("GET", "/info/collections")
    assert res.status_code == 200, res.text
