"""An upgrade of the self-hosted accounts in place, see tests/fxa-upgrade.sh.

FXA_UPGRADE_PHASE=before, on the older release: an account signs up and syncs, its
session registers a device, it gets an OAuth refresh token (like the mobile apps),
and what the after phase needs is kept in UPGRADE_STATE. FXA_UPGRADE_PHASE=after,
on the new release: the same session, device, refresh token and Sync data still
work, a new sign-in too, and the admin UI shows the new release, all healthy. The after
phase can run again (after another step of the upgrade).

Runs inside the syncstorage-rs image (PyFxA), like test_fxa_flow.py.

Environment (besides those of test_fxa_flow.py):
  FXA_UPGRADE_PHASE  before or after
  UPGRADE_STATE      the file kept between the two phases (written by before)
  FXA_NEW_VERSION    after: the release the admin UI must show, e.g. 1.347.3
  FXA_OLD_LEVELS, FXA_NEW_LEVELS  the schema-patch-levels before and after the upgrade,
                     "fxa=198 fxa_oauth=39 fxa_profile=4 pushbox=2"
  ADMIN_URL, ADMIN_PASSWORD  the admin UI
"""

import json
import os
import re
import time
import uuid

import pytest
import requests
from fxa.core import Client, Session

from test_fxa_flow import AUTH, FIREFOX_CLIENT_ID, SYNC, authorize, storage, sync_token, wait_for_code

PHASE = os.environ["FXA_UPGRADE_PHASE"]
STATE = os.environ["UPGRADE_STATE"]
ADMIN = os.environ["ADMIN_URL"].rstrip("/")
BOOKMARKS = ["bookmark000", "bookmark001", "bookmark002"]
before = pytest.mark.skipif(PHASE != "before", reason="before the upgrade only")
after = pytest.mark.skipif(PHASE != "after", reason="after the upgrade only")


def bearer(token):
    from fxa._utils import HawkTokenAuth
    return {"Authorization": f"Bearer fxs_{HawkTokenAuth(token, 'sessionToken').id}"}


def sync_with(session, key_id):
    """A Sync token with an OAuth token of this session, as Firefox gets one every hour"""
    res = requests.get(f"{SYNC}/1.0/sync/1.5", headers={"Authorization": f"Bearer {authorize(session)}", "X-KeyID": key_id}, timeout=30)
    assert res.status_code == 200, res.text
    return res.json()


def renew(refresh_token):
    return requests.post(f"{AUTH}/v1/oauth/token", json={"grant_type": "refresh_token", "client_id": FIREFOX_CLIENT_ID,
                                                          "refresh_token": refresh_token}, timeout=30)


@pytest.fixture(scope="module")
def state():
    if PHASE == "before":
        kept = {}
        yield kept
        with open(STATE, "w") as f:
            json.dump(kept, f)
    else:
        with open(STATE) as f:
            yield json.load(f)


@before
def test_before_sign_up_device_and_sync(state):
    email, password = f"ffs-upgrade-{uuid.uuid4().hex[:10]}@example.com", uuid.uuid4().hex
    client = Client(server_url=f"{AUTH}/v1")
    keys_changed_at = int(time.time() * 1000)
    session = client.create_account(email, password, keys=True)
    session.verify_email_code(wait_for_code(email))
    # the session of a Firefox has its device
    device = requests.post(f"{AUTH}/v1/account/device", json={"name": "ffs upgrade device", "type": "desktop"},
                           headers=bearer(session.token), timeout=30)
    assert device.status_code == 200, device.text
    # and a mobile app an OAuth refresh token
    refresh = authorize(session, full=True, offline=True)["refresh_token"]
    assert renew(refresh).status_code == 200

    bearer_token, key_id = sync_token(session, keys_changed_at)
    res = requests.get(f"{SYNC}/1.0/sync/1.5", headers={"Authorization": f"Bearer {bearer_token}", "X-KeyID": key_id}, timeout=30)
    assert res.status_code == 200, res.text
    token = res.json()
    meta = {"id": "global", "payload": json.dumps({"syncID": "upgradeabcde", "storageVersion": 5})}
    assert storage(token, "PUT", "/storage/meta/global", meta).status_code == 200
    bookmarks = [{"id": b, "payload": json.dumps({"title": b})} for b in BOOKMARKS]
    assert len(storage(token, "POST", "/storage/bookmarks", bookmarks).json()["success"]) == 3
    state.update(email=email, password=password, uid=session.uid, session_token=session.token, device=device.json()["id"],
                 refresh_token=refresh, keys_changed_at=keys_changed_at, key_id=key_id, sync_uid=token["uid"])


@after
def test_after_the_old_session_still_works(state):
    session = Session(Client(server_url=f"{AUTH}/v1"), state["email"], b"", state["uid"], state["session_token"])
    session.check_session_status()
    assert session.get_email_status()["verified"]
    devices = requests.get(f"{AUTH}/v1/account/devices", headers=bearer(state["session_token"]), timeout=30)
    assert devices.status_code == 200, devices.text
    mine = [d for d in devices.json() if d["id"] == state["device"]]
    assert mine and mine[0]["name"] == "ffs upgrade device" and mine[0]["isCurrentDevice"], devices.text


@after
def test_after_the_old_refresh_token_still_works(state):
    res = renew(state["refresh_token"])
    assert res.status_code == 200, res.text
    verified = requests.post(f"{AUTH}/v1/verify", json={"token": res.json()["access_token"]}, timeout=30).json()
    assert verified["client_id"] == FIREFOX_CLIENT_ID and verified["user"] == state["uid"], verified


@after
def test_after_the_sync_data_reads_back_with_the_old_session(state):
    session = Session(Client(server_url=f"{AUTH}/v1"), state["email"], b"", state["uid"], state["session_token"])
    token = sync_with(session, state["key_id"])
    # the same tokenserver user: no new node assignment, no empty storage
    assert token["uid"] == state["sync_uid"], token
    # (run again after a later step, fxa-upgrade.sh's MySQL ones: with what the first run wrote)
    assert sorted(storage(token, "GET", "/storage/bookmarks").json()) in (BOOKMARKS, sorted(BOOKMARKS + ["bookmark-after"]))
    assert json.loads(storage(token, "GET", "/storage/meta/global").json()["payload"])["syncID"] == "upgradeabcde"
    new = [{"id": "bookmark-after", "payload": json.dumps({"title": "after the upgrade"})}]
    assert len(storage(token, "POST", "/storage/bookmarks", new).json()["success"]) == 1


@after
def test_after_a_new_sign_in_syncs(state):
    session = Client(server_url=f"{AUTH}/v1").login(state["email"], state["password"], keys=True)
    if not session.get_email_status().get("sessionVerified", True):
        session.verify_email_code(wait_for_code(state["email"]))
    # the keys did not change: the same X-KeyID as before the upgrade
    bearer_token, key_id = sync_token(session, state["keys_changed_at"])
    assert key_id == state["key_id"]
    res = requests.get(f"{SYNC}/1.0/sync/1.5", headers={"Authorization": f"Bearer {bearer_token}", "X-KeyID": key_id}, timeout=30)
    assert res.status_code == 200, res.text
    token = res.json()
    assert token["uid"] == state["sync_uid"]
    assert sorted(storage(token, "GET", "/storage/bookmarks").json()) == sorted(BOOKMARKS + ["bookmark-after"])


@after
def test_after_a_new_account_signs_up():
    email = f"ffs-upgrade-new-{uuid.uuid4().hex[:10]}@example.com"
    session = Client(server_url=f"{AUTH}/v1").create_account(email, uuid.uuid4().hex)
    session.verify_email_code(wait_for_code(email))
    assert session.get_email_status()["verified"]


def admin():
    http = requests.Session()
    res = http.post(f"{ADMIN}/login", data={"password": os.environ["ADMIN_PASSWORD"]}, timeout=30)
    assert res.status_code == 200 and "Sign out" in res.text, res.text[:500]
    return http


def overview_table(http, table):
    """The table of the overview with that id, empty while the page has none: the admin UI
    shows the schema table only once it read the schemas, which it does after it starts"""
    page = http.get(f"{ADMIN}/", timeout=30).text
    return page.split(f'<table id="{table}"')[1].split("</table>")[0] if f'<table id="{table}"' in page else ""


def wait_for_levels(http, levels):
    """The schema table of the overview once it shows these levels (read every
    HEALTH_CHECK_SECONDS, 5 in the test stack)"""
    expected = dict(pair.split("=") for pair in levels.split())
    deadline = time.time() + 60
    while True:
        schema = overview_table(http, "schema")
        shown = dict(re.findall(r"<tr><td>([^<]+)</td><td>([^<]*)</td>", schema))
        if all(shown.get(db) == level for db, level in expected.items()) or time.time() > deadline:
            return expected, shown
        time.sleep(3)


@before
def test_before_the_admin_ui_records_the_schema_levels():
    # seen once before the upgrade: the change is an event after it
    expected, shown = wait_for_levels(admin(), os.environ["FXA_OLD_LEVELS"])
    assert all(shown.get(db) == level for db, level in expected.items()), (expected, shown)


@after
def test_after_the_admin_ui_records_the_migrations():
    http = admin()
    expected, shown = wait_for_levels(http, os.environ["FXA_NEW_LEVELS"])
    assert all(shown.get(db) == level for db, level in expected.items()), (expected, shown)
    old = dict(pair.split("=") for pair in os.environ["FXA_OLD_LEVELS"].split())
    activity = http.get(f"{ADMIN}/activity", timeout=30).text
    for db, level in expected.items():
        change = f"Schema of the {db} database changed from {old[db]} to {level}"
        assert (change in activity) == (old[db] != level), (change, activity.split('<table id="events"')[1][:3000])


@after
def test_after_the_admin_ui_shows_the_new_release_all_up(state):
    http = admin()
    version = re.escape(os.environ["FXA_NEW_VERSION"])
    # the versions are read every HEALTH_CHECK_SECONDS (5 in the test stack)
    deadline = time.time() + 60
    while True:
        health = overview_table(http, "health")
        if re.search(r"<td>Accounts API</td><td>[^<]*<span[^>]*>up</span></td><td>v?" + version + r"\b", health) or time.time() > deadline:
            break
        time.sleep(3)
    assert re.search(r"<td>Accounts API</td><td>[^<]*<span[^>]*>up</span></td><td>v?" + version + r"\b", health), health
    # FXA_NEW_DB_SERVER: the accounts database moved to another server version (fxa-upgrade.sh
    # FXA_MARIADB_FROM), as the health check reads it again
    db_server = os.environ.get("FXA_NEW_DB_SERVER")
    if db_server:
        row = r'<td>Accounts database</td><td><span class="ok">up</span>(?:(?!</td>).)*</td><td>' + db_server
        deadline = time.time() + 60
        while not re.search(row, health) and time.time() < deadline:
            time.sleep(3)
            health = overview_table(http, "health")
        assert re.search(row, health), health
    for component in ("Sync server", "Tokenserver database", "Storage database", "Accounts API", "Accounts pages",
                      "Profile server", "Accounts database", "Accounts Redis"):
        assert re.search(r"<td>" + component + r'</td><td><span class="ok">up</span>', health), (component, health)
    # the account of before the upgrade, with its device, in the admin UI
    account = http.get(f"{ADMIN}/users/{state['uid']}", timeout=30).text
    assert state["email"] in account and "ffs upgrade device" in account, account[:3000]
    assert 'class="failed"' not in account, account[:3000]
