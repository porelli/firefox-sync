# Changelog

What changed for those who run firefox-sync. A release gets the entries of Unreleased: see [Releasing](docs/development/releasing.md#releases).

## Unreleased

### Breaking

- Self-hosted accounts with an SMTP user and password on port 587: they now need the server to offer STARTTLS, see Security below. A relay without TLS gets no email until you set `ADMIN_SMTP_INSECURE_AUTH=1` or `FXA_SMTP_REQUIRE_TLS=false`.

### Added

- Access managed elsewhere, for integrators: with `ADMIN_ACCESS_EXTERNAL=1` (Helm: `admin.accessExternal`) another system decides who may use the server. The admin UI shows the limits, the allowlists and the sign-ups read-only, refuses every change of them, and asks nobody to approve an account or raise a limit. The init container and `fxa-policy` leave the rows of the allowlists to that system and refuse a `SYNC_ALLOWED_ACCOUNTS` or `FXA_SIGNUP_ALLOWLIST`. Reset and deletion of Sync data stay. With self-hosted accounts, `FXA_ACCESS_DB_PASSWORD` (Helm: `fxa.accessDbPassword`) gives that system a database user, `ffs_access`, for the sign-up allowlist and to disable, enable or delete accounts by email. The database enforces the mode too: at every start the init container and `fxa-policy` take back the admin UI's database grants on max users, the allowlists and the sign-up policy, and give them again once it is off, and a setup check compares the grants with the mode. With self-hosted accounts the admin UI's Enable then refuses an account whose email the sign-up policy refuses ("not on the access list managed elsewhere"), and its Delete leaves the sign-up allowlist to that system; Disable stays. On MariaDB and MySQL the admin UI's reader now gets `EXECUTE` per procedure instead of on the whole tokenserver database, in both modes. On your own MariaDB or MySQL server that takes `GRANT OPTION` for the tokenserver's user, once: without it the init container keeps the database-wide grant, and with `ADMIN_ACCESS_EXTERNAL` on it does not start, see [The database enforces it too](docs/admin/accounts.md#the-database-enforces-it-too). See [Access managed elsewhere](docs/admin/accounts.md#access-managed-elsewhere).
- Helm: `admin.passwordSignIn: false` turns the admin UI's password sign-in off, with single sign-on or a trusted header: no `ADMIN_PASSWORD` is generated or passed, one already in the Secret is not used. See [Ways to sign in](docs/admin/signing-in.md#ways-to-sign-in).

### Changed

### Fixed

- Admin UI, PostgreSQL: the Event log setup check no longer warns when the Sync tables belong to a superuser that only runs the migrations: it checks the role the Sync server connects as. See [Setup checks](docs/admin/monitoring.md).

### Security

- Self-hosted accounts: the SMTP password and the emails go over STARTTLS only. Until now the accounts used STARTTLS only when the server offered it, so anyone between them and the SMTP server could remove it and read `FXA_SMTP_PASS` and the sign-in codes. `FXA_SMTP_REQUIRE_TLS` (Helm: `smtp.requireTLS`) decides. Empty, the default: required with `FXA_SMTP_USER` and `FXA_SMTP_PASS` over STARTTLS, unless `ADMIN_SMTP_INSECURE_AUTH`, as the admin UI already does. `true` requires it also without a password. It works with every accounts image, through the auth server's config file. See [Email](docs/accounts.md#email).

## v2026.11.23 — 2026-11-23

### Changed

- PostgreSQL 19: a new install on the stack's PostgreSQL container is pinned to 19, the major of `postgres:latest` now. An install on 18 stays on 18. Moving it to 19 takes a backup, the new major and a restore, tested from 18 to 19: see [PostgreSQL](docs/upgrading.md#postgresql).
- The accounts on MySQL 9 (`mysql:lts`) now work with Mozilla's own images too, from v1.350.0 on: Mozilla released the driver change our images carried. `prepare_environment.sh` writes `FXA_MYSQL_IMAGE=mysql:lts` for any accounts image of v1.350.0 or later, and `mysql:8` with `FXA_MYSQL_ARGS` only for older ones. See [MySQL 9](docs/accounts.md#mysql-9).

### Fixed

- With your own PostgreSQL server, the setup and `--upgrade` no longer pin `SYNC_POSTGRES_IMAGE`. There it is only the client of `db-bootstrap` and the backups, and pinned to 18 its `pg_dump` refused a server on 19. A pin already in `.env` stays, with a note: remove the line to follow `postgres:latest`. See [PostgreSQL](docs/databases.md#postgresql).

## v2026.11.16 — 2026-11-16

Upstream only: syncstorage-rs 0.25.0, accounts v1.349.0.

## v2026.11.08 — 2026-11-08

### Breaking

- The first release since commit ca9101d (October 2026), the layout this repository had until now. How to upgrade from it: [The earlier firefox-sync release](docs/upgrading.md#the-earlier-firefox-sync-release).
- The compose files moved to `compose/`. With `COMPOSE_FILE=docker-compose.postgres.yml` compose stops until you run `./prepare_environment.sh --upgrade`, which writes the new names and `COMPOSE_PROJECT_NAME`. Without `COMPOSE_FILE`, `docker-compose.yml` still works and finds the same containers. See [Files that moved](docs/upgrading.md#files-that-moved).
- To upgrade with docker compose: `git pull`, `./prepare_environment.sh --upgrade`, then `docker compose pull && docker compose up -d`. See [With docker compose](docs/upgrading.md#with-docker-compose).
- To upgrade with the Quadlets: stop the units, `git pull`, `./prepare_environment.sh --upgrade` (it renders the units again from your `.env`, every password kept), pull the images, start them. See [With Quadlets](docs/upgrading.md#with-quadlets). The new units mount files of the checkout: keep it where it is.
- With Watchtower, a `docker compose pull` on a timer or `podman auto-update` on the `-latest` tags, the new images run with your files and `.env` of before: that works and changes nothing you set. The new features need the upgrade above. See [Watchtower and podman auto-update](docs/upgrading.md#watchtower-and-podman-auto-update).
- The Sync settings have the `SYNC_` prefix (`MAX_USERS` is `SYNC_MAX_USERS`, `SYNCSTORAGE_DOMAIN` is `SYNC_PUBLIC_URL`...). The old names still work for now; `--upgrade` renames them. See [Renamed settings](docs/upgrading.md#renamed-settings).
- The MariaDB containers no longer upgrade their data when `mariadb:lts` moves to a new major: `--upgrade` pins the major the data has, and the containers refuse data of another major. PostgreSQL stays on 18. See [Database majors](docs/upgrading.md#database-majors).
- `config/nginx/syncstorage-rs-example.conf` is gone: the setup and `--upgrade` write the reverse proxy's configuration into `proxy/` and move your `config/nginx/syncstorage-rs.conf` into `proxy/old/`. The Sync host needs `client_max_body_size 10m;`. See [Reverse proxy](docs/reverse-proxy.md).
- The init container stops, and the Sync server with it, on a `SYNC_MAX_USERS` it cannot read (empty or not a number), on a placeholder of `.env-example`, and on a setting given under both its old and new name. Before, a broken limit let nobody new in. See [SYNC_MAX_USERS](docs/limits.md#sync_max_users).
- Installs older than ca9101d are not covered by `--upgrade`: move their databases as in [Moving the database](docs/migrating.md#moving-the-database).

### Added

- An optional admin UI: accounts, storage, health, setup checks, an event log, Prometheus metrics, and a page to connect Firefox (a `user.js` download, QR codes). See [Admin UI](docs/admin/README.md).
- Alerts by email, or to Slack, Discord, Teams, ntfy, Gotify, Telegram, Matrix or a webhook. See [Alerts](docs/admin/alerts.md).
- Invite-only Sync (`SYNC_ALLOWED_ACCOUNTS`), off unless you set it. `SYNC_MAX_USERS` also takes `unlimited` and `initial:N` (managed in the admin UI). See [Limits](docs/limits.md).
- Optional nightly backups of every database, and restores. See [Backups](docs/backups.md).
- Experimental self-hosted Mozilla accounts, with every telemetry path off. See [Self-hosted accounts](docs/accounts.md).
- A Helm chart for Kubernetes. See [Helm](docs/install/helm.md).
- MySQL for the Sync databases (`SYNC_DB=mysql`), and the Quadlets on PostgreSQL. See [Databases](docs/databases.md).
- Your own database server, its SQL as numbered setup migrations applied or checked at every start. See [Your own server](docs/databases.md#your-own-server).
- The reverse proxy's configuration for nginx, Caddy and Traefik in `proxy/`, or a bundled Caddy. See [Reverse proxy](docs/reverse-proxy.md).
- A setup asked one component at a time, with a review before it writes anything; `--upgrade` and `--render-units` for an install that runs. See [Docker compose](docs/install/compose.md).
- Healthchecks for every long-running container.
- This changelog, and the docs as a website.

### Changed

- Releases are now `vYYYY.MM.DD`, cut after the weekly builds only when this changelog or an upstream version (syncstorage-rs, the accounts, the pairing server, the upstream patches) changed; their notes list both. The image tags stay as they were (`syncstorage-rs-mysql-latest`, `-<release>`, `-<release>-<build date>`...). See [Releasing](docs/development/releasing.md#releases).
- syncstorage-rs 0.24.1, with the [upstream patches](docs/reference/images.md#upstream-patches) these images carry.
- A new install publishes the Sync server on `127.0.0.1` only. An install from before keeps its `CONTAINER_EXPORT_PORT`. With no port set at all it is `127.0.0.1:5000`, before a random port on every interface.
- `PODMAN.md` is now [Podman](docs/install/podman.md); `syncstorage-rs-init/` and `syncstorage-rs-init-postgres/` are now `db/mysql/init/` and `db/postgres/init/`.
- The admin UI, when you turn it on, compares the running versions with the newest releases on GitHub (`ADMIN_UPDATE_CHECK`) and checks your public URLs every hour (`ADMIN_PUBLIC_CHECK`). Set them to `false` to stop that. See [Settings](docs/reference/settings.md).
- The accounts images carry Mozilla's switch to the mysql2 driver, [mozilla/fxa#21709](https://github.com/mozilla/fxa/pull/21709) (merged, not in a release yet), instead of our mozilla/fxa#21554, plus [mozilla/fxa#21731](https://github.com/mozilla/fxa/pull/21731): with mysql2, a wrong `FXA_MYSQL_PASSWORD` made `fxa-migrations` exit without an error instead of stopping at once with `Access denied`. Images with either pull request in their label work on MySQL 9. See [Upstream patches](docs/reference/images.md#upstream-patches).

### Fixed

- nginx refused Sync requests over 1 MB (large batches): the configuration it gets now accepts 10 MB.
- The migrations step no longer hangs when syncstorage-rs does not stop: it is killed 30 s after SIGTERM.
- The init containers' wait for the database says why it waits.

### Security

- On PostgreSQL the Sync server connects as a role of its own that is no superuser (`SYNC_POSTGRES_APP_USER`, set by `--upgrade`).
- The admin UI has database users and a database of its own, out of the Sync server's reach (`ADMIN_DB_PASSWORD`, set by `--upgrade`).
- The Sync server and its migrations run without raw sockets (`cap_drop: NET_RAW`).
- No passwords on command lines or in healthchecks; the Quadlets keep their secrets in environment files readable by you only, not in the units.
