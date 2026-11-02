# Install with Podman

This page installs the Sync server with rootless Podman, in one of two ways: Quadlets, which run the stack as systemd units of your user (recommended), or docker compose on the Podman socket. Read [What you need](../README.md#what-you-need) first.

## Requirements

- Podman 4.4 or later ([install](https://podman.io/docs/installation)), set up for rootless use ([Podman's rootless tutorial](https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md)).
- For docker compose on the Podman socket: `docker compose`, the version of [docker compose](compose.md#requirements). The Docker daemon is not needed.
- A host name with HTTPS, proxied to the port of the Sync server: your reverse proxy, or the bundled Caddy. See [Reverse proxy](../reverse-proxy.md).

The stack uses named volumes only, so rootless Podman handles their ownership, and SELinux labels stay on.

| | Quadlets | docker compose on the Podman socket |
|---|---|---|
| MariaDB, MySQL, PostgreSQL | yes | yes |
| self-hosted accounts | yes | yes |

## Quadlets

Quadlets are unit files that Podman turns into systemd services: see [podman-systemd.unit(5)](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html).

1. Clone the repository and run the setup script:

   ```bash
   git clone https://github.com/porelli/firefox-sync.git
   cd firefox-sync
   ./prepare_environment.sh
   ```

   It detects Podman and asks how the stack runs: `quadlets` (the default). Its other questions are those of [docker compose](compose.md#what-the-setup-script-asks), and so are its [answers by name](compose.md#answers-by-name) (`deploy=quadlets`). It writes `.env`, copies the units of [config/quadlet/](/config/quadlet) with your values into `~/.config/containers/systemd/` (the backup timer into `~/.config/systemd/user/`), and reloads systemd. The units hold no secret: the passwords, keys and tokens of a unit's container, and `ADMIN_NOTIFY`, are in its environment file next to it, `firefox-sync-<name>.env`, readable by you only, which the unit reads (`EnvironmentFile=`). Values there are as they are in `.env`, without the escapes of systemd.

1. Start the Sync server:

   ```bash
   systemctl --user start firefox-sync-syncstorage.service
   ```

   Its dependencies start first: the databases, the migrations, the init container and, when you enabled it, the admin UI.

1. Let your units start at boot without a login:

   ```bash
   loginctl enable-linger $USER
   ```

   Quadlets are generated units: their `[Install]` section starts them at boot, and `systemctl enable` does not work on them.

1. [Set up Firefox](../firefox.md).

To install the units somewhere else than `~/.config/containers/systemd/`, set `QUADLET_DIR` when you run the script:

```bash
QUADLET_DIR=/path/to/units ./prepare_environment.sh
```

Other choices of the setup script, with Quadlets:

- MySQL instead of MariaDB: see [Databases](../databases.md#mysql-instead-of-mariadb).
- PostgreSQL: see [Databases](../databases.md#postgresql).
- Your own database server: see [Databases](../databases.md#with-quadlets).
- The admin UI: see [Admin UI](../admin/README.md#set-up).
- The nightly backups: answered yes, it enables `firefox-sync-backup.timer`, see [Backups](../backups.md#the-backup-service). The pairing server is not asked: the Quadlets have none.
- The reverse proxy: its configuration is in `proxy/` ([Your own proxy](../reverse-proxy.md#your-own-proxy)). Answered `caddy`, the bundled Caddy gets a unit of its own, `firefox-sync-caddy.service`, on the host's network: start it with `systemctl --user start firefox-sync-caddy.service`. On ports 80 and 443, rootless Podman needs `net.ipv4.ip_unprivileged_port_start=80`, which the script checks: see [Rootless Podman and ports under 1024](../reverse-proxy.md#rootless-podman-and-ports-under-1024). The labels for Traefik are not offered: they are for docker compose.

### Self-hosted accounts

If you chose to self-host Mozilla accounts, the script also installs their units, `firefox-sync-fxa-*`. Start them:

```bash
systemctl --user start firefox-sync-fxa-content.service firefox-sync-fxa-profile.service \
  firefox-sync-fxa-profile-worker.service firefox-sync-fxa-profile-static.service
```

Their database, the migrations and the auth server start as dependencies. The rest of the setup is in [Self-hosted accounts](../accounts.md#set-up).

### Check the units

Status and logs:

```bash
systemctl --user status firefox-sync-syncstorage.service
journalctl --user -u firefox-sync-syncstorage.service -f
journalctl --user -u 'firefox-sync-*' -f
```

Health: every unit that keeps running has the healthcheck of its compose service, with the same timings. `podman ps` shows `(healthy)` next to each. One at a time:

```bash
podman healthcheck run firefox-sync-syncstorage; echo $?   # 0: healthy
```

The one-shot units have no healthcheck: the migrations, the init container, `fxa-keys-owner`, `fxa-policy` and the backups. `systemctl --user status <unit>` says how they ended.

Restart and stop:

```bash
systemctl --user restart firefox-sync-syncstorage.service
systemctl --user stop firefox-sync-syncstorage.service firefox-sync-syncstorage-db.service firefox-sync-tokenserver-db.service
```

With PostgreSQL the database unit is `firefox-sync-postgres-db.service`.

A new admin UI container restarts the Sync server: see [Sync metrics](../admin/monitoring.md#sync-metrics).

<details><summary>Podman before 5: the units start before their database is healthy</summary>

Podman 4.9 (Ubuntu 24.04) orders the units on the start of their container, not on its health: `Notify=healthy` needs Podman 5. Where compose waits for a healthy database, the next unit retries on its own instead: the migrations of the Sync server for 2 minutes, those of the accounts for 5. `Restart=always` starts again what gave up.

</details>

### Change a setting

The installed units and their environment files hold their own copy of the values of `.env`: a change of `.env` alone does nothing. To change a setting, or to pin an image (`SYNC_IMAGE_TAG`, `ADMIN_IMAGE`, `SYNC_MARIADB_IMAGE`...):

1. Change it in `.env`.
1. Render the units again from `.env`:

   ```bash
   ./prepare_environment.sh --render-units
   ```

   It asks nothing and keeps every password and secret. It reads `.env` as compose does (single and double quotes with their escapes, a comment after the value, `export`, `$$`; not the `${NAME}` of other values), writes only the units and environment files that change and lists them, keeps all those of before in `quadlets.before-<UTC time>/` of the checkout (readable by you only), and reloads systemd. Run again, it changes nothing. Without installed units (a compose install) it refuses; `./prepare_environment.sh --render-units --fresh` installs the units of `.env`. Before that it does to `.env` what `--upgrade` does ([Quadlets](../upgrading.md#quadlets)): on an `.env` of this release, nothing.
1. Restart the units it listed. A new image: pull it first (`podman pull`, the name of its `Image=` line). For example `SYNC_MAX_USERS` is in the init container and, with the admin UI, in its unit; the migrations run again before the Sync server starts:

   ```bash
   systemctl --user restart firefox-sync-tokenserver-db-init.service firefox-sync-syncstorage.service
   ```

   With the admin UI, also restart `firefox-sync-admin.service` when `SYNC_MAX_USERS` changes between a plain number and `initial:N` ([Limits](../limits.md#switch-between-the-forms)).

On a running install, `./prepare_environment.sh` first asks whether to upgrade it (the default: the same as `--upgrade`) or set it up again. Don't set it up again (`new`) there: that writes a new `.env` from `.env-example`, with new passwords and secrets that the databases don't have. It keeps the old file as `.env.before-setup-<UTC time>`.

Upgrading the images: see [Upgrading](../upgrading.md#quadlets).

## docker compose on the Podman socket

`docker compose` v2 can drive Podman through its Docker-compatible API, with the same compose files as Docker.

1. Run the setup script, and choose `compose` for how the stack runs (`deploy=compose` by name):

   ```bash
   ./prepare_environment.sh
   ```

1. Start the Podman API socket of your user, and point `docker compose` to it:

   ```bash
   systemctl --user enable --now podman.socket
   export DOCKER_HOST=unix://${XDG_RUNTIME_DIR}/podman/podman.sock
   ```

1. Check the optional services in `COMPOSE_PROFILES` of `.env`, as for [docker compose](compose.md#optional-services).

1. Start the stack:

   ```bash
   docker compose up -d
   ```

   `COMPOSE_FILE` in `.env` has the files of your choices ([The compose files](compose.md#the-compose-files)) and [compose/podman.yml](/compose/podman.yml), which gives the Sync server's healthcheck more time, for slower rootless starts.

Everything else works as in [docker compose](compose.md): logs with `docker compose logs -f`, `docker compose down` to stop.

The bundled Caddy (`PROXY=caddy`) on the Podman socket: on ports 80 and 443 it needs `net.ipv4.ip_unprivileged_port_start=80` ([Rootless Podman and ports under 1024](../reverse-proxy.md#rootless-podman-and-ports-under-1024)), and the port forwarding of rootless Podman hides the clients' addresses from it, which the accounts' limits count on: the Quadlets' Caddy, on the host's network, sees them ([The bundled Caddy](../reverse-proxy.md#the-bundled-caddy)). The labels for Traefik work there too, Traefik reading the Podman socket ([Traefik labels](../reverse-proxy.md#traefik-labels)).

## Why not podman-compose?

The stack starts in a precise order: the databases, then a one-shot container running the migrations, then the one-shot init that installs the limit of users, and only then the public Sync server, so that nobody can sign in before the limit exists.

podman-compose links containers with `podman create --requires`. Podman refuses to start a container whose required container has already exited ("generating dependency graph for container"), so the init and the Sync server never start. podman-compose also does not check that a one-shot container exited successfully. Use Quadlets or docker compose instead.

Something fails: see [Troubleshooting](../troubleshooting.md).
