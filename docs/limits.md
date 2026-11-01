# Who can use your server

This page explains the limits of firefox-sync: `SYNC_MAX_USERS`, how many accounts can use the Sync server, `SYNC_ALLOWED_ACCOUNTS`, which accounts can, and `FXA_MAX_ACCOUNTS`, how many self-hosted accounts can be created. Set them when you install: see [the index](README.md#choose-your-path).

syncstorage-rs has no allowlist. Anybody who can reach your server and has a Mozilla account can point Firefox to it. firefox-sync limits how many accounts can use it, and with [invite-only Sync](#sync_allowed_accounts) takes only the accounts you approve, by their account id. To choose by email instead, with an allowlist of emails and domains or closed sign-ups, self-host the accounts as well: only accounts created on your server can then sign in. See [Who can sign up](accounts.md#who-can-sign-up).

## The forms

The two limits take the same forms. The form says who sets the limit: the setting on every start, or the [admin UI](admin/accounts.md#limits).

| Value | The limit | In the admin UI |
|---|---|---|
| `5`, or `fixed:5` | 5, set again on every start, replacing any change | read-only |
| `initial:5` | 5, set only when there is no limit yet: the first start, or a new database | changes it, and the change is kept across restarts |
| `unlimited`, or `fixed:unlimited` | no limit, set on every start | read-only |
| `initial:unlimited` | no limit at first | changes it |
| `0` (any form) | no new account at all, on purpose | as its form says |

The number goes from 0 to 2147483647. Anything else, empty or not a number, stops the container that sets the limit, and with it the Sync server or the accounts service.

`prepare_environment.sh` asks for both, and writes `initial:` when you enable the admin UI.

## `SYNC_MAX_USERS`

The accounts that can use the Sync server (`1` in [.env-example](/.env-example)). With the Helm chart: `maxUsers` in your values, with the same forms (`"1"`).

- A trigger in the tokenserver database refuses new accounts once the limit is reached. The init container installs it, and the Sync server starts only after it did. With `unlimited` the trigger checks nothing.
- The limit counts accounts, not database rows. An account that changes its keys, for example after a password reset, is never locked out.
- A change made in the admin UI applies at once, without a restart.

## `SYNC_ALLOWED_ACCOUNTS`

Invite-only Sync, for Mozilla's accounts: only the accounts on a list can start to sync (empty in [.env-example](/.env-example): off). With the Helm chart: `allowedAccounts` in your values, with the same forms. `prepare_environment.sh` asks for it with Mozilla's accounts, and writes `admin` with the admin UI.

The tokenserver knows an account only as `<uid>@<FXA_EMAIL_DOMAIN>`: the uid is the account's permanent id, 32 hexadecimal characters, and the email never reaches your server. The list is of uids: see [Find the uid of an account](#find-the-uid-of-an-account).

| Value | The list | In the admin UI |
|---|---|---|
| empty | off: every account gets in, within `SYNC_MAX_USERS` | nothing shown |
| `<uid>,<uid>`, or `fixed:<uid>,...` | these uids, set again on every start | read-only: the pending accounts with Reject |
| `admin` | the uids you approve in the admin UI, kept across restarts | Approve, Reject, Allow a uid, Remove |
| `initial:<uid>,...` | these uids once, the first time an `initial:` list is applied (or on a new database), then as `admin`: a uid you remove later stays removed, a later `initial:` list adds nothing | as `admin` |

Spaces are dropped and the uids lowercased. Anything else, a uid that is not 32 hexadecimal characters or a plain list without one, stops the init container, and with it the Sync server, like a `SYNC_MAX_USERS` that is not valid.

- A trigger in the tokenserver database refuses a new account whose uid is not on the list; it exists only while the allowlist is on. Firefox gets an error, nothing is stored, and it tries again later by itself. The error is the Sync server's answer to a database error, a 500, which it logs and reports to Sentry like any other: a refused account trying again and again shows up there too.
- An account that has its rows in the tokenserver is never refused: one that synced before the allowlist was on, one that changes its keys (a password reset adds a row for the same email), one removed from the list after it synced. To stop an account that syncs, delete its Sync data on [its page](admin/accounts.md#delete-an-account).
- The allowlist comes before max users: an account not on the list is refused, and pending, whether or not there is room; an account on the list still needs a place under `SYNC_MAX_USERS`.
- Each refused uid is recorded with its first and last try and their count. Its first refusal is an event of the admin UI, `sign-up refused`, which alerts; the next tries do not. The event is written at least once: past the limit of 30 events a minute it waits for the next round, and after a crash between the event and its mark the admin UI finds the event (it names the refusal) and does not alert again.
- At most 1000 refused accounts are kept. A new one takes the place of the oldest pending one already alerted; a rejected one, or one not alerted yet, is never let go. With none to let go, the new account is refused without a record: the admin UI counts those (`ffs_sync_refusals_dropped`) and warns in its setup checks. Approve or reject pending accounts to make room. The admin UI lists it under Pending accounts, in [Needs attention](admin/monitoring.md#needs-attention), and Prometheus counts it (`ffs_sync_pending_accounts`). Approve lets its next try in, Reject takes it off the list of pending ones: see [Invite-only Sync](admin/accounts.md#invite-only-sync).
- The record has to outlive the refusal, which undoes the INSERT: MariaDB keeps it in an Aria table (crash-safe), PostgreSQL in its transaction, MySQL in a MyISAM table, which is not crash-safe: the stack's MySQL runs with `--myisam-recover-options=BACKUP,FORCE`, and the init container checks and repairs the table at every start. Where that cannot work, the record is in InnoDB, which the refusal undoes: the accounts are refused but not listed, the init container says so, and you allow them by their uid. That is MySQL with binary logging and `enforce_gtid_consistency` (MySQL 9 has it on with binary logging; the stack's MySQL runs without binary logging), where a trigger that writes MyISAM would refuse every new account; MySQL without `myisam_recover_options`; and a server that gives another engine (`enforce_storage_engine`, `disabled_storage_engines`).
- The tokenserver counts a new account in its node's load before it inserts the account, and a refusal does not take it back: refused tries, by the allowlist or by `SYNC_MAX_USERS`, would fill the node until it takes nobody. The init container counts the load again from the accounts at every start, and the admin UI every few minutes, at once when it is off by 10 or more: then its setup checks say so for a day ([Setup checks](admin/monitoring.md#setup-checks)). This runs on every install, the allowlist on or off.
- Turning it off keeps the list in the database, for the next time it is on. A change applies on the next start, as for the limits: [Switch between the forms](#switch-between-the-forms). From `admin` to a plain list, the list becomes the plain one; from a plain list to `admin`, the list stays and the admin UI manages it.

With [self-hosted accounts](accounts.md) the sign-up policy decides who has an account at all (`FXA_SIGNUPS`, `FXA_SIGNUP_ALLOWLIST`, see [Who can sign up](accounts.md#who-can-sign-up)): that is the control there, and `prepare_environment.sh` does not ask for this one. `SYNC_ALLOWED_ACCOUNTS` works there too, with the uids of the account pages of the admin UI, to keep some of those accounts off Sync.

### Find the uid of an account

The owner of the account finds it in a Firefox signed in to it:

- with the [About Sync](https://addons.mozilla.org/firefox/addon/about-sync/) add-on: its page shows the account, its `uid` among the details of Full Profile;
- in the Browser Console: set `devtools.chrome.enabled` to `true` in `about:config` (its command line needs it), open the console with Ctrl+Shift+J (Cmd+Shift+J on macOS), and run:

  ```js
  (await ChromeUtils.importESModule("resource://gre/modules/FxAccounts.sys.mjs").getFxAccountsSingleton().getSignedInUser()).uid
  ```

  It prints the uid, or fails when Firefox is signed in to no account. Checked with Firefox 159.

Or let them try: their first sync is refused, and its uid shows under Pending accounts with the time of the try.

## `FXA_MAX_ACCOUNTS`

With [self-hosted accounts](accounts.md): how many accounts the accounts service can have, whoever signs up and whatever the sign-up policy. Not set, or empty: `initial:unlimited`, so that existing setups do not change. With the Helm chart: `fxa.maxAccounts`, with the same forms.

- Every row of `fxa.accounts` counts: confirmed or not, disabled too. Delete the accounts that are gone, or the old unconfirmed ones, to make room.
- `fxa-policy` sets the limit before the accounts service starts.
- When the server is full, the database refuses the account itself: "Sign-up refused: the server is full (FXA_MAX_ACCOUNTS)". Two sign-ups at once cannot both take the last place.
- With the [sign-up gate](reverse-proxy.md#sign-up-gate), the sign-up page says "This server is full: it takes no new accounts".
- Each refused sign-up is an event of the admin UI, `sign-up refused`.

## Switch between the forms

A change of form applies on the next start, like any other change:

- From `initial:5` to `5`: 5 is set again on the next start.
- From `5` to `initial:5`: the value in the database stays, and the admin UI can change it.

The next start is `docker compose up -d`. With Quadlets, after rendering the units again ([Change a setting](install/podman.md#change-a-setting)):

```bash
systemctl --user restart firefox-sync-tokenserver-db-init.service firefox-sync-admin.service
```

With the Helm chart: `helm upgrade` with the new `maxUsers`, `allowedAccounts` or `fxa.maxAccounts`.

## Near and full

The admin UI warns twice for each limit:

- **near the limit**, from 90% of the places taken;
- **full**, when every place is taken.

Both show on the overview and in [Needs attention](admin/monitoring.md#needs-attention), and alert once when the state changes, also back under 90%. `0` never warns, since it is on purpose, and `unlimited` has nothing to warn about. Prometheus has both states as metrics: see [Prometheus](admin/monitoring.md#prometheus).
