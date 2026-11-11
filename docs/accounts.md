# Self-hosted Mozilla accounts

By default Firefox signs in with Mozilla accounts (`accounts.firefox.com`), and only the Sync data is on your server. This page adds the accounts service too, so that signing in, the account keys and the Sync data all stay on your server. Set up the Sync server first, with your install page from [the documentation](README.md).

Mozilla does not support self-hosting its accounts service, and changes it every couple of weeks. A new release is published here only after the tests passed with it. Pin `FXA_VERSION` to choose when you take one, see [Upgrading](upgrading.md#self-hosted-accounts).

## Requirements

- The accounts image, about 5 GB unpacked. By default it is this project's build of Mozilla's newest tested release, for amd64 and arm64. Which images you can use: [Images](reference/images.md#accounts).
- 3-4 GB of RAM for the whole stack.
- An SMTP server. New accounts and new sign-ins are confirmed with a code sent by email, so without it nobody can sign up. The admin UI can send its alerts through the same server, see [Alerts](admin/alerts.md).
- A database: the stack's `fxa-db` container, or your own server. See [MySQL or MariaDB](#mysql-or-mariadb).
- Four host names behind your reverse proxy, with HTTPS: `accounts.`, `api.`, `profile.` and `sync.`. What each one proxies to: [Host names and ports](reverse-proxy.md#host-names-and-ports).

## Set up

`prepare_environment.sh` does the whole setup, for docker compose and for Quadlets.

1. Run it, and choose `self-hosted` for "Which accounts people sign in with" (`accounts=self-hosted` by [name](install/compose.md#answers-by-name)):

   ```bash
   ./prepare_environment.sh
   ```

   Its part about the accounts asks for their three public URLs (by default `accounts.`, `api.` and `profile.` under your domain, see [The public addresses](install/compose.md#the-public-addresses)), the [database](#mysql-or-mariadb) of the accounts, your SMTP server, [who can sign up](#who-can-sign-up), the most accounts, the [security history](#security-history) and, with docker compose, your own [pairing server](reverse-proxy.md#pairing). It generates the secrets and points the Sync server to your accounts. With docker compose, it sets `COMPOSE_FILE` so that `docker compose up -d` starts everything. The configuration of the reverse proxy, in `proxy/`, gets their hosts too ([Reverse proxy](reverse-proxy.md#host-names-and-ports)).
1. With the admin UI, choose `accounts` for how admins sign in, then give the admins' emails (only those get in, not every account) and the public URL of the admin UI. See [Signing in](admin/signing-in.md#self-hosted-accounts).
1. Start everything. With docker compose:

   ```bash
   docker compose up -d
   ```

   With Quadlets, start the accounts' units as in [Podman](install/podman.md#self-hosted-accounts).

   The first start takes a few minutes: the databases are created, then the keys are generated.
1. [Set up Firefox](firefox.md#self-hosted-accounts).

The keys are kept in the `fxa-keys` volume. Don't lose it: without it every session becomes invalid. Back it up with the databases, see [Backups](backups.md#what-to-keep).

With the Helm chart there is no `prepare_environment.sh`: the values do it, see [Self-hosted accounts](install/helm.md#self-hosted-accounts). The keys are on a PVC there: see [The signing keys](install/helm.md#the-signing-keys).

### Set up by hand

1. Fill in the `SELF-HOSTED MOZILLA ACCOUNTS` section of `.env`:
    - the three URLs: `FXA_CONTENT_URL`, `FXA_AUTH_URL` and `FXA_PROFILE_URL`;
    - a different random value for each `FXA_*_SECRET`, `FXA_FLOW_ID_KEY`, `FXA_SESSION_TOKEN_HANDLE_KEY`, `FXA_CONTENT_SESSION_SECRET`, `FXA_MYSQL_PASSWORD` and `FXA_ADMIN_DB_PASSWORD`;
    - who can sign up: `FXA_SIGNUPS` and `FXA_SIGNUP_ALLOWLIST`, see [Who can sign up](#who-can-sign-up);
    - your SMTP server.
1. Point the Sync server to your accounts service instead of Mozilla's:

   ```ini
   FXA_OAUTH_SERVER_URL=http://fxa-auth:9000/v1
   FXA_EMAIL_DOMAIN=api.example.com
   ```

   `FXA_EMAIL_DOMAIN` must be the host name of `FXA_AUTH_URL`.
1. Add `compose/fxa.yml` and `compose/fxa-mysql.yml` (or [fxa-mariadb.yml](#mysql-or-mariadb)) to `COMPOSE_FILE`, see [The compose files](install/compose.md#the-compose-files).
1. Start everything:

   ```bash
   docker compose up -d
   ```

Every setting: [Settings](reference/settings.md#accounts).

## MySQL or MariaDB

Mozilla runs and supports its accounts on MySQL only, so `fxa-db` is MySQL by default. The stack can run the accounts on MariaDB instead, if you would rather run only MariaDB. Every release is tested here on both, with the same tests: sign-up, Sync, the sign-up policy, the admin UI and a real Firefox. Which versions: [Supported versions](databases.md#supported-versions).

To choose MariaDB:

- With `prepare_environment.sh`: choose `mariadb` for the engine of the accounts' database (`fxa_db=mariadb`). The default is `mysql`, whatever you chose for Sync: following Sync's default (MariaDB) would move most new installs off what Mozilla supports.
- By hand: `FXA_DB=mariadb` in `.env`. With docker compose, `compose/fxa-mariadb.yml` in place of `compose/fxa-mysql.yml` in `COMPOSE_FILE` ([The compose files](install/compose.md#the-compose-files)):

  ```ini
  COMPOSE_FILE=compose/sync.yml:compose/sync-mariadb.yml:compose/fxa.yml:compose/fxa-mariadb.yml
  ```

  With Quadlets, `prepare_environment.sh` installs `config/quadlet/fxa/mariadb/` in place of the MySQL unit.
- With the Helm chart: `fxa.database.backend: mariadb`, see [MySQL or MariaDB](install/helm.md#mysql-or-mariadb).

Choose before the first start. MariaDB gets its own volume, `fxa-db-mariadb` (Quadlets: `firefox-sync-fxa-db-mariadb`), because it cannot open MySQL's data files. Switching an existing install leaves the MySQL data in `fxa-db` and starts with no accounts. Moving the data takes a dump and a reload, which is not tested here.

Mozilla could release a migration that works on MySQL only. A release is published here once it passes on MySQL: a failure on MariaDB does not hold it back. With MariaDB, pin `FXA_VERSION`, and upgrade once a release passed the `test-mariadb` jobs of [fxa.yml](/.github/workflows/fxa.yml).

The image of `fxa-db` is `FXA_MYSQL_IMAGE` or `FXA_MARIADB_IMAGE`. Their defaults, the pins for installs from before, and moving to a newer major: [Database majors](upgrading.md#database-majors).

### MySQL 9

Mozilla's accounts use a MySQL driver that speaks `mysql_native_password` only. MySQL 8.4 has that method off by default, and MySQL 9 removed it. [mozilla/fxa#21709](https://github.com/mozilla/fxa/pull/21709), merged after v1.349.0, replaces the driver with `mysql2`, which also speaks MySQL's default, `caching_sha2_password`. Our images built before it was merged had the same change from our own pull request, mozilla/fxa#21554, and `prepare_environment.sh` counts their label as having it.

Until a release includes it, the accounts images built here have it, see [Upstream patches](reference/images.md#upstream-patches). Mozilla's own images and ours built before it don't. With them, `fxa-db` runs `mysql:8` with `FXA_MYSQL_ARGS`, and your own server must be MySQL 8.4 with `mysql_native_password=ON`.

`prepare_environment.sh` reads the image's label and writes the right settings. It warns, with `--upgrade` too, when `FXA_MYSQL_IMAGE` and the image don't match. A mismatch shows as `ER_NOT_SUPPORTED_AUTH_MODE` in `fxa-migrations` and `fxa-auth`, see [Troubleshooting](troubleshooting.md#databases).

### MariaDB 12

MariaDB 12 names unnamed foreign keys `1`, `2`, and so on, where MySQL and MariaDB 11 name them `<table>_ibfk_N`. Mozilla's migrations drop foreign keys by those names, so on a new database on MariaDB 12 they stop at the first one:

```text
ER_CANT_DROP_FIELD_OR_KEY: Can't DROP FOREIGN KEY deviceCommands_ibfk_1
```

No server setting changes that. [mozilla/fxa#21494](https://github.com/mozilla/fxa/pull/21494) fixes it, and the accounts images built here have it until a release includes it ([Upstream patches](reference/images.md#upstream-patches)). With Mozilla's own images, or ours built before it, use `FXA_MARIADB_IMAGE=mariadb:11`.

`prepare_environment.sh` warns, with `--upgrade` too, when the accounts would run on MariaDB 12 or later, or on your own MariaDB server, with an image that does not have it. The admin UI does not check it: it cannot inspect images.

## Who can sign up

Anybody who can reach your accounts pages can create an account, and with it use your Sync server. `FXA_SIGNUPS` in `.env`, or the admin UI's sign-ups page, says who can:

| `FXA_SIGNUPS` | Who can create an account |
|---|---|
| `open` (default) | anybody who can reach your accounts pages |
| `allowlist` | only the emails (`alice@example.com`) and domains (`@example.com`) of `FXA_SIGNUP_ALLOWLIST`, comma-separated |
| `closed` | nobody |

`prepare_environment.sh` asks for the allowlist (empty: `open`). Existing accounts are never affected: disable them in the admin UI instead, see [Sign out and disable](admin/accounts.md#sign-out-and-disable).

How many accounts can be created at all, whoever signs up, is `FXA_MAX_ACCOUNTS`, see [Limits](limits.md#fxa_max_accounts).

How the policy is enforced:

- The accounts database refuses the account itself. `fxa-policy` runs before the accounts service at every start, and installs a trigger on the accounts table and the `ffs` database it reads the policy from. So nothing that reaches the accounts service, by any path, can create an account the policy does not allow.
- So that people see why, the admin UI also answers sign-up requests itself. Your reverse proxy sends `POST /v1/account/create` of the accounts API host name to `ADMIN_GATE_EXPORT_PORT` (`127.0.0.1:8091`), see [Host names and ports](reverse-proxy.md#host-names-and-ports). Refused sign-ups then show "The request was blocked for security reasons" instead of "Unexpected error".
- The policy itself lives in the accounts database (`ffs.settings` and `ffs.signup_allowlist`), not in `.env`. Both `.env` and the admin UI's page write it there.

`.env` and the page share the policy like this:

1. At every start, `fxa-policy` compares `FXA_SIGNUPS` and `FXA_SIGNUP_ALLOWLIST` with the values it read from `.env` at the start before. It keeps those in `ffs.settings`.
1. On the first start, or when you changed either of them in `.env`, the values of `.env` replace the policy, including what was set on the page.
1. Otherwise the policy stays as it is in the database. What you set on the page survives restarts and upgrades.

So to take the policy back from the page, change `.env` and run `docker compose up -d`. With Quadlets, change `.env`, render the units again ([Change a setting](install/podman.md#change-a-setting)) and restart `firefox-sync-fxa-policy.service`. `FXA_SIGNUPS=allowlist` with an empty `FXA_SIGNUP_ALLOWLIST` lets nobody sign up, and `fxa-policy` logs a warning. `FXA_MAX_ACCOUNTS` follows its own rules, see [Limits](limits.md#fxa_max_accounts).

The page itself (the allowlist, removing entries): [Sign-ups](admin/accounts.md#sign-ups).

## Security history

The security history is off by default. With it on, the accounts service records every sign-in with the IP address it came from.

To turn it on, set this in `.env` (`prepare_environment.sh` asks, default no), then `docker compose up -d`:

```ini
FXA_ACCOUNT_EVENTS=true
```

The accounts service then keeps a history of every account in `fxa.securityEvents`. It records each sign-in and wrong password, password change and reset, two-step authentication turned on or off, recovery key created or removed, backup codes, secondary emails, passkeys and sign-outs. Each entry has its time, **the IP address it came from** and the browser's user agent.

The owner sees it in Recent activity of the account settings. The admin UI shows it on the account page, and alerts when a password, the primary email or a way to sign in or recover changes: see [Security history](admin/accounts.md#security-history).

With the history on, Mozilla would let later sign-ins from the same IP address skip the code sent by email for 7 days. The stack turns that off (`IP_PROFILING_RECENCY=0`): the sign-in code is asked exactly as with the history off.

<details><summary>Why: what the setting changes in Mozilla's code</summary>

Read in fxa-mono v1.347.x. The setting is `ACCOUNT_EVENTS_ENABLED` of the auth server, on in Mozilla's defaults.

- Off, the auth server replaces its `AccountEventsManager` with one that does nothing (`bin/key_server.js`). No security event is written, and Recent activity stays empty.
- On, every event is written to the accounts database. The other part of it, email events in Google's Firestore, stays off with `FIRESTORE_ENABLED=false`.
- The auth server also reads the history at sign-in. After a confirmed sign-in from an IP address, later sign-ins from it skip the email code for `IP_PROFILING_RECENCY` (7 days), the sign-ins of Firefox for Sync too. From a shared network a password alone would then be enough. The stack sets it to 0, in `compose/fxa.yml` and the Quadlets.
- The other skips don't depend on the setting. The one for a known browser (`SIGNIN_CONFIRMATION_DEVICE_FINGERPRINTING_ENABLED`) is off in Mozilla's defaults. The one for accounts created less than 48 hours ago applies either way.

</details>

Privacy, plainly:

- The IP address is stored as it is, next to a keyed hash of it (`IP_HMAC_KEY`), which therefore hides nothing. IP addresses are personal data in many countries: tell the people who use your server.
- Mozilla never prunes the history: its procedures delete it only with the account. The admin UI's daily pruning removes events older than `ADMIN_RETENTION_DAYS` (30), see [Maintenance and retention](admin/storage.md#maintenance-and-retention). Without the admin UI nothing does: run this yourself, regularly:

  ```sql
  DELETE FROM fxa.securityEvents WHERE createdAt < (UNIX_TIMESTAMP() - 30 * 86400) * 1000;
  ```

- Turning it off again stops new entries. Those already recorded stay until they are pruned or the account is deleted.
- The IP addresses are in other places too. Deleting rows of `fxa.securityEvents` leaves them there:
    - the events of kind `security` in the admin UI's event log, in its own database (see [Event log](admin/monitoring.md#event-log) to delete them);
    - the admin UI's alert emails, in the admins' mailboxes;
    - the accounts' backups: `fxa.securityEvents` is in every dump, for the newest `BACKUP_KEEP` runs.
- The admin UI reads the name, time, IP address and whether the sign-in was confirmed, not the rest. The full entry can hold the recovery phone's number.

## Telemetry

Nothing leaves the stack. The accounts services send no telemetry, metrics or error reports to Mozilla or anybody else. Mozilla's defaults already send little from a self-hosted install. The stack also turns every one of these paths off by name, so that a default that changes in a new release cannot turn one on.

The settings are in one file, [config/fxa/no-telemetry.env](/config/fxa/no-telemetry.env). Every accounts service reads it: compose (`env_file` in `compose/fxa.yml`), the Quadlets (`EnvironmentFile=`) and the Helm chart (its copy, `files/fxa/no-telemetry.env`, as the first env entries of every accounts container). Each service reads its own settings and ignores the rest. It is not a setting of `.env`: edit the file only to turn something on knowingly.

The one exception is `GLEAN_SERVER_ENDPOINT`, set in the content server's environment because it is your `FXA_CONTENT_URL`. The accounts pages run Glean whatever `GLEAN_ENABLED` and `GLEAN_UPLOAD_ENABLED` say: while nobody is signed in always, for a signed-in account when its data collection switch (below) is on. They send their pings to `GLEAN_SERVER_ENDPOINT`, and to Mozilla's `incoming.telemetry.mozilla.org` when it is empty. Here they go to the accounts pages themselves, which answer 404 and keep nothing: the content server logs the request's path, not what it carried.

| What | Where it would go | Mozilla's default | Here |
| --- | --- | --- | --- |
| Glean in the accounts pages: usage pings from the browser | `incoming.telemetry.mozilla.org` (`GLEAN_SERVER_ENDPOINT`) | on in the pages (see below), Mozilla's endpoint | `GLEAN_ENABLED=false`, `GLEAN_UPLOAD_ENABLED=false`, and `GLEAN_SERVER_ENDPOINT` the accounts pages themselves (`FXA_CONTENT_URL`) |
| Glean events of the content and auth servers | their logs, which Mozilla's own deployment ships to its telemetry | on | `CONTENT_SERVER_GLEAN_ENABLED=false`, `AUTH_GLEAN_ENABLED=false` |
| Amplitude events | the logs, which Mozilla ships to Amplitude | on | `AMPLITUDE_ENABLED=false` (auth), `AMPLITUDE_DISABLED=true` (content) |
| The pages' flow events | the content server's log | on | `FLOW_METRICS_DISABLED=true` |
| Sentry error reports, of the servers and of the pages | the Sentry project of `SENTRY_DSN` | none (empty) | `SENTRY_DSN` empty |
| StatsD metrics | `DD_AGENT_HOST` (auth), `METRIC_HOST` (content), `PAIR_STATSD_HOST` (pairing server) | off, off, `localhost:8125` | `STATSD_ENABLE=false`, `METRIC_ENABLED=false`, `PAIR_STATSD_HOST` empty |
| OpenTelemetry traces | Google Cloud Trace or an OTLP collector | off | `TRACING_GCP_EXPORTER_ENABLED=false`, `TRACING_OTEL_EXPORTER_ENABLED=false`, `TRACING_SAMPLE_RATE=0` |
| Nimbus experiments | Mozilla's Cirrus service (`NIMBUS_CIRRUS_HOST`) | off | `NIMBUS_ENABLED=false` |
| The pairing server's IP reputation | an IP reputation service | none (empty) | `PAIR_IP_REPUTATION_SERVER` empty |

The other Mozilla and Google services the accounts service knows (Firestore, SNS, the customs server, Twilio, the GeoIP lookup) are off too, in the environment of each service: see [What works](#what-works).

Two things still reach Mozilla, by design and only when someone uses them: pairing a phone with a QR code goes through Mozilla's channel server unless you [run your own](reverse-proxy.md#pairing), and Firefox's send tab uses Mozilla's push service. Firefox itself has its own telemetry, its own setting in Firefox.

**The switch in the account settings.** The account settings show "Allow Mozilla accounts to send technical and interaction data to Mozilla" under Data collection and use. It is part of Mozilla's pages, kept as it is. It stores a preference for that account (`metricsOptOutAt` in the accounts database) and tells the Firefox signed in to it. Off, the pages run no Glean while that account is signed in; on, they send their pings to themselves, as above. Nothing reaches Mozilla either way.

To be sure it stays so:

- The admin UI's setup check **Telemetry of the accounts pages** reads the settings the accounts pages run with, every hour, and warns when Glean, Sentry or Nimbus is on, or the Glean endpoint is not the accounts pages themselves (empty is Mozilla's), naming where the data would go ([Setup checks](admin/monitoring.md#setup-checks)).
- The real-Firefox tests ([Testing](development/testing.md)) record every request the accounts pages and the admin UI make, and fail on any to a host outside the stack.

## What works

- Tested on every release: sign-up, email confirmation, sign-in, OAuth for Sync, syncing, and a second device. A real Firefox signs up on one profile through the accounts pages, and a second profile signs in and receives its bookmark.
- Send tab to device uses Mozilla's public push service, as Firefox does with Mozilla accounts.
- Pairing a phone with a QR code ([Pair a phone](firefox.md#pair-a-phone)) uses Mozilla's channel server, unless you run your own: see [Pairing](reverse-proxy.md#pairing). Its image follows `FXA_IMAGE`; with Mozilla's accounts image, set `FXA_PAIRING_IMAGE` too.
- The accounts service rate-limits sign-in attempts itself, in Redis, with upstream's `rate-limit-rules.txt`. For example: 5 failed sign-ins per IP address and email in 15 minutes. It reads the client's address from `X-Forwarded-For`, see [Client IP address](reverse-proxy.md#client-ip-address).
- Not available: payments and subscriptions, the recovery phone (SMS), sign-in with Google or Apple, and the deferred clean-up tasks and event notifications to other services. They need Google Cloud. The [security history](#security-history) does not.

### Only your own accounts

A Sync server with self-hosted accounts syncs only the accounts of that accounts service. Mozilla's accounts don't work there, and an account of another self-hosted server doesn't either. The reason is the token check. Firefox sends the Sync server an OAuth access token, and the Sync server checks it with `FXA_OAUTH_SERVER_URL`, your accounts service. A JWT has to be signed by one of its keys (`/jwks`). Any other token is sent to its `/verify`, and Firefox's tokens from these accounts are of that kind. A token signed by Mozilla's accounts, or by any other key, is refused with 401 `invalid-credentials`, and the tokenserver records nothing for it. The tests check this on every release ([Testing](development/testing.md)). The admin UI's setup check **Sign-in keys** says so too. To sync a Mozilla account, use a Sync server set up with Mozilla's accounts, the default.

Upgrades: [Upgrading](upgrading.md#self-hosted-accounts). The tests: [Testing](development/testing.md).
