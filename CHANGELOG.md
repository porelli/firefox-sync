# Changelog

What changed for those who run firefox-sync. A release gets the entries of Unreleased: see [Releasing](docs/development/releasing.md#releases).

## Unreleased

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

### Fixed

- nginx refused Sync requests over 1 MB (large batches): the configuration it gets now accepts 10 MB.
- The migrations step no longer hangs when syncstorage-rs does not stop: it is killed 30 s after SIGTERM.
- The init containers' wait for the database says why it waits.

### Security

- On PostgreSQL the Sync server connects as a role of its own that is no superuser (`SYNC_POSTGRES_APP_USER`, set by `--upgrade`).
- The admin UI has database users and a database of its own, out of the Sync server's reach (`ADMIN_DB_PASSWORD`, set by `--upgrade`).
- The Sync server and its migrations run without raw sockets (`cap_drop: NET_RAW`).
- No passwords on command lines or in healthchecks; the Quadlets keep their secrets in environment files readable by you only, not in the units.
