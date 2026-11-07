# Upgrading

How to upgrade a running install: new images of the Sync server, the admin UI and the self-hosted accounts, with docker compose, the Quadlets or the Helm chart. It also covers upgrading from the earlier firefox-sync release (and Watchtower on its images), the renamed settings, and moving a database to a newer major. Make a backup first: see [Backups](backups.md).

## How the images move

By default every image follows a moving tag, and a new upstream release is published here only after the tests passed with it:

| Image | Setting | Default |
|---|---|---|
| the Sync server and its init container | `SYNC_IMAGE_TAG`, `SYNC_INIT_IMAGE_TAG` | `latest` |
| the admin UI | `ADMIN_IMAGE` | `<IMAGE_REPOSITORY>:admin-latest` |
| the self-hosted accounts | `FXA_VERSION` | `fxa-mono-latest` |

To decide when to upgrade instead, pin a tag in `.env` (Helm: in your values), and change it to upgrade. Which tags exist: [Images](reference/images.md). What changed between two releases of this repository: [CHANGELOG.md](/CHANGELOG.md), and the GitHub releases (`vYYYY.MM.DD`), each with the upstream versions and the image tags and digests it corresponds to ([Releases](development/releasing.md#releases)). The database images move differently: see [Database majors](#database-majors).

The database migrations run before each service starts and cannot be undone. Going back to an older release means restoring a backup.

## Sync server

With docker compose:

```bash
docker compose pull
docker compose up -d
```

The migrations and the init container run before the Sync server starts. Firefox needs nothing. The admin UI's image is pulled and replaced by the same commands.

With Quadlets, see [Quadlets](#quadlets). With the Helm chart, see [Helm](#helm). From the earlier firefox-sync release, see [The earlier firefox-sync release](#the-earlier-firefox-sync-release).

## Self-hosted accounts

A new Mozilla release comes about every two weeks. It is published here only after the tests passed with it on amd64 and arm64, including a real Firefox signing up and syncing, and an install of the previous release upgraded to it. Sessions, devices, OAuth tokens and Sync data are kept: Firefox stays signed in.

With docker compose:

1. Make a backup of the accounts. With the backup service: `docker compose exec backup-fxa sh /ffs-backup/backup.sh now`. Without it, back up the `fxa-db` volume (`fxa-db-mariadb` with MariaDB) and the `fxa-keys` volume. With your own database server, back up its `fxa`, `fxa_oauth`, `fxa_profile`, `pushbox` and `ffs` databases.
1. To decide when to upgrade, pin a release in `.env`, for example `FXA_VERSION=fxa-mono-v1.349.0`, and change it to upgrade.
1. Pull and start, pinned or not:

    ```bash
    docker compose pull
    docker compose up -d
    ```

    `docker compose up -d` alone does not upgrade `fxa-mono-latest`: it keeps the image it has. `up -d` runs `fxa-migrations` with the new image, then `fxa-policy` (it installs the sign-up policy and the admin UI's procedures again over the migrated databases), and only then replaces the accounts services.
1. Check the result:
    - `docker compose ps -a fxa-migrations fxa-policy` says `Exited (0)` for both;
    - `docker compose ps` shows the other services `(healthy)`. The accounts services can take a few minutes, `(health: starting)` until then;
    - the [admin UI](admin/README.md)'s overview shows the new release next to "Accounts API", all parts up, and the new schema levels of the accounts databases, with an event of kind `update` for each one that migrated.

    If `fxa-migrations` failed, `docker compose up -d` stops there with an error, and `docker compose logs fxa-migrations` says why. To go back to the older release, restore the backup ([Restore](backups.md#restore)).

With the Helm chart:

1. Make a backup: `kubectl create job --from=cronjob/ffs-firefox-sync-backup backup-now-$(date +%s)` dumps the accounts first. The keys stay on their PVC or in `fxa.keys.existingSecret`, untouched.
1. Pin a release in your values, for example `fxa.image.tag: fxa-mono-v1.349.0`, and change it to upgrade. With `fxa-mono-latest` and `image.pullPolicy: IfNotPresent`, a node that has the image never pulls a newer one.
1. `helm upgrade` as in [Helm](#helm). The auth pod stops, and its new pod runs the migrations, then the sign-up policy, in its init containers before it serves. The content and profile servers wait for it.
1. Check `kubectl logs deploy/ffs-firefox-sync-fxa-auth -c migrations`, and the admin UI's overview as above. A failed migration keeps the auth pod in `Init:Error` and out of its Service. To go back to the older release, restore the backup ([Restore on Kubernetes](backups.md#restore-on-kubernetes)).

To move from Mozilla's image to the builds of this repository, or back, change `FXA_IMAGE`, `FXA_VERSION` and `FXA_ARCH` together (Helm: `fxa.image.repository` and `.tag`), then follow the same steps. The pairing server follows `FXA_IMAGE`: with Mozilla's image set `FXA_PAIRING_IMAGE` too (Helm: `fxa.pairing.image`), see [Pairing](reverse-proxy.md#pairing). For example from `FXA_IMAGE=docker.io/mozilla/fxa-mono`, `FXA_VERSION=v1.345.2`, `FXA_ARCH=amd64` to `FXA_IMAGE=ghcr.io/porelli/firefox-sync`, `FXA_VERSION=fxa-mono-latest`, `FXA_ARCH=arm64`. It is the same software: the databases and the keys stay.

Accounts releases from v1.349.0 on need this repository from the same time or later, Mozilla's images too: the auth server then refuses to start without its key `mfa.jwt.secretKey` (`Config 'mfa.jwt.secretKey' must be set in production`), which `config/fxa/oauth-clients.js` now derives from `FXA_OAUTH_SECRET` at every start. Update the checkout (or the chart) before the image. Older releases get the key too: until then they signed those tokens, which guard the password, email, 2-step, recovery key and passkey changes, with Mozilla's published default.

Don't stay too far behind: Firefox refuses to sign in to accounts servers that are too old for it. For example Firefox 154 needs a recent release, because it switched to Bearer tokens.

## Quadlets

`prepare_environment.sh` writes the images and the values of `.env` into the unit files. Podman does not pull a tag it already has, and the one-shot units (the migrations, the init container, the sign-up policy) ran at the first start and stay active: a new image alone does not migrate.

`./prepare_environment.sh --upgrade` renders the units again from your `.env`, with every password and secret it has: nothing to set by hand in the databases. A new firefox-sync release, the Sync server and the admin UI:

1. Make a backup: `systemctl --user start firefox-sync-backup.service` (with self-hosted accounts it backs them up first), or back up the volumes.
1. Stop the units, the one-shot ones too (they stay active and would not run again), and the backup timer, so that no backup starts halfway: `systemctl --user stop firefox-sync-backup.timer firefox-sync-syncstorage.service firefox-sync-admin.service firefox-sync-syncstorage-migrate.service firefox-sync-tokenserver-db-init.service firefox-sync-tokenserver-db.service firefox-sync-syncstorage-db.service`. Without the database containers, the last two are not there. With PostgreSQL, they are `firefox-sync-sync-role-init.service firefox-sync-postgres-db.service`.
1. Get the new files (`git pull` in the clone), and keep your `.env`. Without `--upgrade`, `./prepare_environment.sh` asks first and upgrades by default: don't choose `new` there, that is a new install, with new passwords that the databases don't have (it keeps the old file as `.env.before-setup-<UTC time>`).
1. Run `./prepare_environment.sh --upgrade`. It asks nothing:
    - in `.env` it does what it does for compose ([With docker compose](#with-docker-compose)): it renames the old setting names, sets `ADMIN_DB_PASSWORD` (the database containers create the admin UI's users with it at their next start) and writes the database majors the install runs;
    - it adds every line of [.env-example](/.env-example) that your `.env` lacks, with its default. A secret gets a new random value only when it is not there at all;
    - the old file stays as `.env.before-upgrade-<UTC time>`, readable by you only, as `.env` (every run that changes it keeps one of its own);
    - then it renders the units from that `.env` into `~/.config/containers/systemd/` (the backup timer into `~/.config/systemd/user/`), writes only those that change, keeps all the units of before in `quadlets.before-<UTC time>/` of the checkout, and runs `systemctl --user daemon-reload`. Units of before with their passwords in them get them out, into their environment files ([Quadlets](install/podman.md#quadlets)), with the same values.

    Run twice, the second run changes nothing. With your own database server (`SYNC_DB_CONTAINERS=0`) it also writes `database-setup.sql`: run it there as its administrator before the next start (`mariadb -h <host> -u root -p < database-setup.sql`, `mysql` for MySQL; its statements can run again), unless the stack applies it itself ([Let the stack apply them](databases.md#let-the-stack-apply-them)). It creates the admin UI's database and users with `ADMIN_DB_PASSWORD`. The admin UI's unit has no Sync password to fall back to as compose has, so without those users it does not start.
1. Pull the new images: `grep -h '^Image=' ~/.config/containers/systemd/firefox-sync-*.container | cut -d= -f2 | sort -u | xargs -n1 podman pull`.
1. Start them again. The migrations and the init container run first:

    ```bash
    systemctl --user start firefox-sync-admin.service firefox-sync-syncstorage.service
    ```

    With self-hosted accounts, start their units too, as in [Self-hosted accounts](install/podman.md#self-hosted-accounts). With the nightly backups on, start their timer again: `systemctl --user start firefox-sync-backup.timer`.

`--upgrade` and `--render-units` read `.env` as compose does: a comment after a value starts with a space before its `#` (`SYNC_MAX_USERS=5 # a comment`). After a tab, the `#` and what follows are part of the value, for compose too.

Which units `--upgrade` renders: the units installed in `~/.config/containers/systemd/` when they are this install's, without asking.

- Units rendered from this checkout (they mount its `config/backup/`): rendered again.
- Units of the earlier release, which name no checkout ([With Quadlets](#with-quadlets)): rendered again when they have the `SYNC_MASTER_SECRET` of your `.env`, so were rendered from it. It says so.
- Units of another checkout, or of the earlier release with another `SYNC_MASTER_SECRET`: left as they are. It says what it found. If they are this install's, `./prepare_environment.sh --render-units` renders them from this `.env` (the units of before kept as above).

To go back: the old files and images, the newest `.env.before-upgrade-<time>` as `.env`, the files of `quadlets.before-<time>/` back into `~/.config/containers/systemd/` (`firefox-sync-backup.timer` into `~/.config/systemd/user/`) with the `firefox-sync-*.env` files of the new units removed there when the units of before have none, `systemctl --user daemon-reload`, and the backup of step 1: see [Rollback](#rollback).

New images of the same release, without new files: steps 5 and 6, with the units stopped as in step 2.

The self-hosted accounts:

1. Make a backup: `systemctl --user start firefox-sync-backup.service` (it backs up the accounts first).
1. Get the new image. With `fxa-mono-latest`: `podman pull ghcr.io/porelli/firefox-sync:fxa-mono-latest` (with `--arch` as `FXA_ARCH`). Pinned: change `FXA_VERSION` in `.env`, render the accounts' units again from it ([Change a setting](install/podman.md#change-a-setting)), and pull the release:

    ```bash
    ./prepare_environment.sh --render-units
    podman pull ghcr.io/porelli/firefox-sync:fxa-mono-v1.349.0
    ```

1. Run the migrations again. Restarting their unit restarts, in order, the units that require it: the sign-up policy, then the auth server, the accounts pages, the profile server and the admin UI. The profile worker and its static server do not require it, so restart them too:

    ```bash
    systemctl --user restart firefox-sync-fxa-migrations.service firefox-sync-fxa-profile-worker.service firefox-sync-fxa-profile-static.service
    journalctl --user -u firefox-sync-fxa-migrations.service -n 20
    ```

    It returns once the migrations ran. The other units restart after, as at the first start (minutes).

The units have `AutoUpdate=registry`. `podman auto-update` (and its timer) replaces the running accounts services when `fxa-mono-latest` moves, **without running the migrations**: the new release then runs on the old schema until they run. With self-hosted accounts, pin `FXA_VERSION` and upgrade with the steps above, or run the restart of the migrations right after each `podman auto-update`.

## Helm

A new chart version, with your values file (recommended):

```bash
helm upgrade ffs oci://ghcr.io/porelli/firefox-sync/charts/firefox-sync --version <new version> \
  -f my-values.yaml --wait --timeout 10m
```

- Without your values file at hand, use `--reset-then-reuse-values` instead of `-f my-values.yaml` (Helm 3.14 or later): the new version's defaults, then the values you gave at the last install or upgrade.
- Never use `--reuse-values` to move to another chart version. It takes the old version's defaults with your values, so a value the new version added or changed is missing or old: a render that fails, or a setting that is silently off. See [helm upgrade](https://helm.sh/docs/helm/helm_upgrade/).
- Always give `--version`: without it Helm takes the newest chart.
- To change a setting in the version that runs, as the admin UI's commands do: `--reuse-values --version <the release's chart version>` (`helm list` shows it, `firefox-sync-<version>`). For example `helm upgrade ffs oci://ghcr.io/porelli/firefox-sync/charts/firefox-sync --version 0.1.0 --reuse-values --set backup.enabled=true`.

The Sync server stops, then starts again with its migrations and init container first (`strategy: Recreate`): a minute without Sync, which Firefox retries. The generated secrets are read back. Never change `SYNC_MASTER_SECRET` or `METRICS_HASH_SECRET` in your `existingSecret` (every Firefox would have to sign in again), nor a database password the server already has.

What else to watch:

- **The images.** `image.syncstorageTag`, `image.initTag` and `image.adminTag` follow `latest`. With `image.pullPolicy: IfNotPresent` (the default) a node that has `latest` does not pull a newer one. Either pin the tags and change them on upgrade, or set `image.pullPolicy: Always` and run `kubectl rollout restart deploy/ffs-firefox-sync-syncstorage` (the admin UI: `deploy/ffs-firefox-sync-admin`) to take the newest.
- **The database images** (`database.image.<backend>`): see [Database majors](#database-majors). Pin PostgreSQL's major in your values from the first install.
- **`admin.smtp.*` is now `smtp.*`.** Chart 0.2.0 moved it to the top level, shared with the self-hosted accounts: rename it in a values file of 0.1.0-dev.1. See [Notifications](reference/settings.md#notifications).
- **The volumes of the database servers** keep their size and storage class: see [Volumes](install/helm.md#volumes).
- **existingSecret.** A key a new chart version needs goes into it before the upgrade, or the pods wait in `CreateContainerConfigError`. The release notes say so. (`ADMIN_DB_PASSWORD` and `POSTGRES_SYNC_PASSWORD` came during the pre-releases of 0.1.0.) The chart's own Secret gets a new key by itself. See [existingSecret](install/helm.md#existingsecret).

`helm uninstall ffs` removes the pods and Services and keeps the data: the Secret, the backups' PVC, the databases' PVCs (`data-ffs-firefox-sync-*`, `data-mariadb-ffs-firefox-sync-fxa-db-0`; Kubernetes never deletes a StatefulSet's), and the accounts' keys and avatars (`ffs-firefox-sync-fxa-keys`, `ffs-firefox-sync-fxa-profile-images`). A new install with the same release name finds them, and the Sync data in them, if it has the same values: save them with `helm get values ffs -o yaml > my-values.yaml` before the uninstall. To remove it all for good: `kubectl delete secret,pvc -l app.kubernetes.io/instance=ffs`.

## The earlier firefox-sync release

From the release porelli/firefox-sync published before this one: commit [ca9101d](https://github.com/porelli/firefox-sync/tree/ca9101d2c53769424d5b17b50f65a6899f2755c6) (October 2026), with its `docker-compose.yml`, `docker-compose.postgres.yml` or its Quadlets, the images `syncstorage-rs-mysql-latest`, `syncstorage-rs-postgres-latest` and their init images, an `.env` with `MAX_USERS`, `SYNCSTORAGE_DOMAIN` and the other names of [Renamed settings](#renamed-settings), and no admin UI. What changed since: [CHANGELOG.md](/CHANGELOG.md).

The same stack: upgrade in place, nothing to export. The volumes (`<directory>_tokenserver-db`, `<directory>_syncstorage-db`, `<directory>_postgres-db`) keep their names as long as you run compose from the same directory. Installs older than that release (an `.env` without `MAX_USERS`, or with one `MARIADB_USER` for both databases) are not covered here: set this release up next to them and move the databases as in [Moving the database](migrating.md#moving-the-database).

### Watchtower and podman auto-update

This release publishes its images under the same tags as the earlier one. If Watchtower, a `docker compose pull` on a timer or `podman auto-update` (the earlier Quadlets have `AutoUpdate=registry`) follows them, the new images run with your files and `.env` of before, before you upgrade anything. That is safe, and changes nothing you set:

- Watchtower and `podman auto-update` replace the running Sync server only. The new one starts with the configuration of before and runs the new syncstorage-rs migrations itself. The init container and the migrations container are not running, so they are left as they are until the next `docker compose up -d` (or the next start of the units).
- `docker compose pull && docker compose up -d` with the files of before also runs the new init container. It reads the settings of before (`MAX_USERS`, `SYNCSTORAGE_DOMAIN` and the database names) and keeps what they did: the same user limit, set again at every start, the same node. Invite-only Sync stays off. It also creates the tables and procedures this release uses, which the earlier init container leaves alone.
- The data stays where it is, and Firefox needs nothing.
- None of the new features is on: no admin UI, no backups, no reverse proxy configuration. They come with the upgrade of the files below.
- One difference: the new init container stops on a `MAX_USERS` it cannot read (empty, or not a number), and the Sync server then does not start; the earlier one let nobody new in. `MAX_USERS` also takes `unlimited` now. See [SYNC_MAX_USERS](limits.md#sync_max_users).

To choose when the images change instead, pin their tags in `.env` (`SYNCSTORAGE_IMAGE_TAG` and `SYNCSTORAGE_INIT_IMAGE_TAG`, for example `0.24.0-20261102T154558`, the last images of the earlier release), or leave the containers out of Watchtower. Then upgrade the files as below.

Tested: `tests/migrate.sh watchtower` (`watchtower-postgres` on PostgreSQL) runs the earlier release as its setup writes it, with its images served by a registry of the test. It then publishes this release's images under the same tags, and runs Watchtower (`--run-once`, its defaults). After that it runs `docker compose pull && docker compose up -d` with the files of before, and `MAX_USERS=3`. Each time the accounts, their data and the user limit are as before. `tests/migrate.sh firefox-sync-public-quadlets` does the same with the earlier Quadlets and `podman auto-update`.

### Files that moved

The compose files are now in `compose/`: one for the Sync server, one per database, the same for the accounts ([The compose files](install/compose.md#the-compose-files)). The services, containers, volumes and settings keep their names.

| Before (`COMPOSE_FILE`) | Now |
|---|---|
| none, or `docker-compose.yml` | `compose/sync.yml:compose/sync-mariadb.yml` |
| `docker-compose.postgres.yml` | `compose/sync.yml:compose/sync-postgres.yml` |
| `-f docker-compose.podman.yml` | `:compose/podman.yml` |

Run the one command, in the checkout:

```bash
./prepare_environment.sh --upgrade
```

It writes the new names in `COMPOSE_FILE` (your own files stay in it, after them; with docker compose on the Podman socket also `compose/podman.yml`, which the setup of before had only in its `-f` command) and `COMPOSE_PROJECT_NAME` with the directory's name, the project's name before, and says so. Without `COMPOSE_PROJECT_NAME`, compose would name the project after `compose/`, the directory of the first file, and find none of your containers and volumes.

Without it:

- `COMPOSE_FILE=docker-compose.postgres.yml`: `docker compose` stops at once, the old file not found (`no such file or directory`). Nothing starts or changes until you run `--upgrade`.
- No `COMPOSE_FILE` (Sync on MariaDB): `docker-compose.yml` is still there and runs the files of `compose/`, as the same project (with the compose of the [requirements](install/compose.md#requirements)). `--upgrade` writes `COMPOSE_FILE` there too, unless you have a `docker-compose.override.yml`, which compose reads only without `COMPOSE_FILE`.
- Your own scripts and units with `-f`: change the names, and add `--env-file .env` (compose looks for `.env` in the directory of the first file; without it, it stops: `required variable SYNC_MASTER_SECRET is missing a value`). An exported `COMPOSE_FILE` or `COMPOSE_PROJECT_NAME` (your shell, a unit's `Environment=`) wins over `.env`: `--upgrade` says so, change it there too.
- Your own compose files in `COMPOSE_FILE`: their relative paths are now relative to `compose/` (`./config` becomes `../config`).

Other files that moved. The image names and the names of the installed Quadlet units did not change.

- `syncstorage-rs-init/` and `syncstorage-rs-init-postgres/` are now `db/mysql/init/` and `db/postgres/init/`. This only matters if you build the init images yourself (`docker build db/mysql/init`).
- `PODMAN.md` is now [Podman](install/podman.md).
- nginx: the Sync server's host needs `client_max_body_size 10m;` (nginx refuses more than 1 MB by default). Your `config/nginx/syncstorage-rs.conf` (written once by `prepare_environment.sh`) and your own proxy keep their setting. Add it to the `server` block of your Sync host, see [Request size](reverse-proxy.md#request-size).
- The nginx example `config/nginx/syncstorage-rs-example.conf` is gone: `prepare_environment.sh` (and `--upgrade`, `--render-proxy`) now writes the configuration of the reverse proxy into `proxy/`, for nginx, Caddy and Traefik, with every rule of [Reverse proxy](reverse-proxy.md). Your `config/nginx/syncstorage-rs.conf`, unused by the stack, is moved into `proxy/old/` (as `syncstorage-rs.conf-<UTC time>`) by `--upgrade`, which says so: its host name and port are those of the setup that wrote it. Use `proxy/nginx.conf`, and take the old file out of your nginx if you copied it there.
- The systemd example `config/systemd/syncstorage-rs-example.service` stays; your `config/systemd/syncstorage-rs.service` runs `docker compose up` in the checkout and needs nothing.
- `--upgrade` checks the ports of this host the stack publishes: one that something else listens on now (not this stack's own containers) moves to the next free port, said, and `proxy/` is written again with it: put the new file into your proxy ([Ports in use](reverse-proxy.md#ports-in-use)).
- Not a git clone: after copying the new files, delete the old `docker-compose.postgres.yml`, `docker-compose.podman.yml`, `PODMAN.md`, `syncstorage-rs-init/` and `syncstorage-rs-init-postgres/`.

### Your own database server: the setup migrations

The earlier release had no setting for it: with `MARIADB_*_SERVER` (or `POSTGRES_SERVER`) pointing at your server, its database containers ran anyway, unused. To stop them, set `SYNC_DB_CONTAINERS=0` after the upgrade ([Your own server](databases.md#your-own-server)). The SQL of your own server is now the numbered [setup migrations](databases.md#setup-migrations), recorded on the server as they run. At the first start with `SYNC_DB_CONTAINERS=0`, `db-bootstrap` finds the users, grants and databases you made by hand there, and records every file as `baseline`. If a user or grant of the Sync server is missing there, that start stops, naming it, and the Sync server stays down until you run `database-setup.sql` (`./prepare_environment.sh --upgrade` writes it with `SYNC_DB_CONTAINERS=0`): run it before that start if you are not sure, or check first with `docker compose run --rm --no-deps db-bootstrap sync`, which changes no user or grant without a bootstrap account (it records what it finds). What only the admin UI's own users and database lack (`ADMIN_DB_PASSWORD` set, the admin UI's part of `database-setup.sql` never run) is a warning: Sync starts as before, the admin UI shows it. With the stack's own database containers the init container records them (`containers`). The admin UI shows the version of each server ([Setup migrations](admin/monitoring.md#setup-migrations)).

### The database majors of an install from before

The earlier release ran `mariadb:lts`, which upgraded the data of the Sync databases whenever a pull brought a new major, and `postgres:18`. The database images now follow each database's long-term tag, but refuse data of another major. `./prepare_environment.sh --upgrade` (compose and Quadlets) writes the pins that keep the install where it is, and says so: `SYNC_MARIADB_IMAGE` with the major the data holds (for example `mariadb:12`, read from the volume or the running server), `SYNC_POSTGRES_IMAGE=postgres:18`. The pins are in [Database majors](#database-majors).

**If you update the files without it**, the MariaDB containers do not start rather than upgrade the data on a new major: `docker compose logs` shows [db/mysql/keep-major.sh](/db/mysql/keep-major.sh)'s `this database is MariaDB 11, the image is MariaDB 12`. Run `--upgrade` then.

Moving to the newer major later is up to you, with a backup first: [MariaDB](#mariadb), [PostgreSQL](#postgresql).

### With docker compose

1. Back up the volumes, or dump the databases (see [Move an existing install](databases.md#move-an-existing-install)).
1. Get the new files (`git pull` in the clone). Keep your `.env`: don't set it up again (`new` at the setup's first question), it would generate new passwords that the databases don't have.
1. Run `./prepare_environment.sh --upgrade`. It changes only what this release needs, keeps every value already there, and leaves the old file as `.env.before-upgrade-<UTC time>` (readable by you only, as `.env`):
    - it renames the settings your `.env` has under their old names ([Renamed settings](#renamed-settings));
    - it writes the files of `compose/` in `COMPOSE_FILE`, and `COMPOSE_PROJECT_NAME` ([Files that moved](#files-that-moved));
    - it sets `ADMIN_DB_PASSWORD`, the password of the admin UI's database users ([The admin UI's own database](#the-admin-uis-own-database));
    - with the PostgreSQL container, it sets `SYNC_POSTGRES_APP_USER` and `SYNC_POSTGRES_APP_PASSWORD`, a role of the Sync server's own that is no superuser;
    - it writes the database majors the install runs ([The database majors of an install from before](#the-database-majors-of-an-install-from-before));
    - it writes the configuration of the reverse proxy into `proxy/` ([Files that moved](#files-that-moved)).

    With your own database server and `SYNC_DB_CONTAINERS=0`, run the `database-setup.sql` it writes there first. Run it before the next step: a line of `.env-example` added under its new name before the rename would hide your value under the old one (compose reads the new name first).
1. Run `docker compose pull && docker compose up -d`. `SYNC_MAX_USERS=N` works as `MAX_USERS=N` did (set at every start); `SYNC_MAX_USERS=initial:N` lets the admin UI manage it ([Limits](limits.md#sync_max_users)).

Firefox needs nothing. The settings this release added have their defaults in the compose files: add those you want from [.env-example](/.env-example), for example the [admin UI](admin/README.md) (`COMPOSE_PROFILES=admin` and `ADMIN_PASSWORD`) or the [backups](backups.md#the-backup-service).

### With Quadlets

The steps of [Quadlets](#quadlets), with the units of the earlier release: it has no admin UI and no backups, so stop them with

```bash
systemctl --user stop firefox-sync-syncstorage.service firefox-sync-syncstorage-migrate.service firefox-sync-tokenserver-db-init.service firefox-sync-tokenserver-db.service firefox-sync-syncstorage-db.service
```

and start them again with `systemctl --user start firefox-sync-syncstorage.service`. The units of that release name no checkout: `--upgrade` renders them again when they have the `SYNC_MASTER_SECRET` of your `.env`, and says so. It renames the old setting names in `.env`, adds what this release needs and the lines of `.env-example` your `.env` lacks, and renders the units from that `.env`, with the passwords they had (now in the units' environment files).

### Rollback

Put back the old files and images, with the `.env.before-upgrade-<time>` of the upgrade as `.env` (Quadlets: and the units of `quadlets.before-<time>/`, see [Quadlets](#quadlets)) and the backup of the volumes of step 1. The earlier release reads only the old setting names, and its images moved on: pin `SYNCSTORAGE_IMAGE_TAG` and `SYNCSTORAGE_INIT_IMAGE_TAG` in that `.env` to its last images, `0.24.0-20261102T154558`. The migrations of the newer syncstorage-rs cannot be undone, so roll back everything together, with the backup, never one image alone.

### The admin UI's own database

The admin UI is new for an install of the earlier release: `--upgrade` gives it its own users and database (`ADMIN_DB_PASSWORD`), out of the Sync server's reach, before its first start. Why that matters: [The admin UI's own database](reference/database-users.md#the-admin-uis-own-database).

Without `--upgrade` (its `.env` has no `ADMIN_DB_PASSWORD`) the admin UI still starts: it connects as the Sync users and keeps its tables in the tokenserver database. Its setup check of the event log fails and says how to move it, and its log says so at every start. To move it later:

1. Run `./prepare_environment.sh --upgrade`. It adds `ADMIN_DB_PASSWORD` (32 letters and digits), `ADMIN_DB_NAME`, `ADMIN_DB_USER`, `ADMIN_DB_SYNC_USER`, and with the PostgreSQL container `SYNC_POSTGRES_APP_USER` and `SYNC_POSTGRES_APP_PASSWORD`. By hand: `ADMIN_DB_PASSWORD=$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 32)` in `.env`, the same for `SYNC_POSTGRES_APP_PASSWORD`, with `SYNC_POSTGRES_APP_USER=syncserver_app`.
1. Your own server only: run the new `database-setup.sql` there (`--upgrade` writes it again; its statements can run again), or the admin UI's statements of the SQL with that password. With `SYNC_DB_BOOTSTRAP_USER` the stack does it at the next start ([Let the stack apply them](databases.md#let-the-stack-apply-them)).
1. Run `docker compose pull && docker compose up -d`.

At that start:

- the database containers are created again with the users, and the init container gives the grants (with PostgreSQL also the Sync tables to the Sync server's role);
- at its first start the admin UI copies its tables of the tokenserver database into `ffs_admin` in one transaction (the events in their order, every note, metric and backup run), then drops them through `ffs_drop_admin_tables`;
- the event log gets an event of kind `update` with what moved. It is done once (recorded in `ffs_meta`). Admin UI tables found in the tokenserver database later (a backup of before restored, or rows the Sync server's user put there) are not copied again: the setup check names them.

When something is missing:

- If the admin UI cannot read the old tables (a grant missing on your own server), it copies nothing and leaves them where they are. The setup check says why, nothing is lost, and the next start tries again.
- If it copied them but cannot drop them (no `EXECUTE`), they stay in the tokenserver database, within the Sync server's reach, until you drop them as the tokenserver user: `DROP TABLE ffs_events, ffs_metrics, ffs_gauges, ffs_account_notes, ffs_schema_levels, ffs_jobs, ffs_backups;`. The setup check says so too.
- If `ffs_admin_ui` cannot create its tables in `ffs_admin` (its grant missing), the admin UI does not start and says why. The old tables stay untouched.

Your own backup jobs that record their runs write into `ffs_admin` as `ffs_admin_ui` ([Your own database server](backups.md#your-own-database-server)).

### Tested

- docker compose: `tests/migrate.sh firefox-sync-public` (MariaDB) and `firefox-sync-public-postgres`. The earlier release's files, set up by its own `prepare_environment.sh` with its images (`0.24.0-20261102T154558`), two accounts sync and a third is refused at `MAX_USERS=2`. Then the new files over them as `git pull` leaves them, `./prepare_environment.sh --upgrade`, `docker compose pull && docker compose up -d`, the admin UI on: the same volumes, the same accounts on the same node with their data, the database majors pinned, `config/nginx/syncstorage-rs.conf` moved into `proxy/old/`, and `SYNC_MAX_USERS` and the admin UI count the accounts.
- The Quadlets: `tests/migrate.sh firefox-sync-public-quadlets`. The earlier release's units, set up by its `prepare_environment.sh`, `podman auto-update` with the new images, then the steps of [With Quadlets](#with-quadlets): the units of before found and rendered again with every secret, the same accounts and data, the user limit.
- Watchtower and `podman auto-update` on the files of before: [Watchtower and podman auto-update](#watchtower-and-podman-auto-update).
- The old setting names: `tests/podman.sh` starts its compose phase from an `.env` with only the old names and has `--upgrade` rename them; `tests/e2e.sh` starts its install from before with only the old names.
- The files moved to `compose/`: `tests/podman.sh` (compose on the Podman socket) and `tests/e2e.sh` have `--upgrade` write `COMPOSE_FILE` from each layout of the earlier release (none, `docker-compose.postgres.yml`) and `COMPOSE_PROJECT_NAME`, and start the stack with it; without `COMPOSE_FILE`, `docker-compose.yml` finds the running MariaDB stack.
- The admin UI's own database: `tests/e2e.sh` (MariaDB, MySQL and PostgreSQL) and `tests/podman.sh` start the admin UI without `ADMIN_DB_PASSWORD`, then run `--upgrade`.
- Not tested: the backup and the rollback.

## Renamed settings

The settings of the Sync server in `.env` now have the `SYNC_` prefix, like the `FXA_`, `ADMIN_` and `BACKUP_` ones. The old names keep working for now and will be removed in a later release: compose reads the old name when the new one is not set (also from the environment it runs in).

| Old name | New name |
|---|---|
| `MARIADB_TOKENSERVER_DATABASE`, `_USER`, `_PASSWORD`, `_SERVER`, `_SERVER_PORT` | `SYNC_TOKENSERVER_DB_NAME`, `_USER`, `_PASSWORD`, `_HOST`, `_PORT` |
| `MARIADB_SYNCSTORAGE_DATABASE`, `_USER`, `_PASSWORD`, `_SERVER`, `_SERVER_PORT` | `SYNC_STORAGE_DB_NAME`, `_USER`, `_PASSWORD`, `_HOST`, `_PORT` |
| `POSTGRES_DATABASE`, `_USER`, `_PASSWORD`, `_SERVER`, `_SERVER_PORT` | `SYNC_POSTGRES_NAME`, `_USER`, `_PASSWORD`, `_HOST`, `_PORT` |
| `MAX_USERS` | `SYNC_MAX_USERS` |
| `CONTAINER_EXPORT_PORT` | `SYNC_EXPORT_PORT` |
| `SYNCSTORAGE_DOMAIN` | `SYNC_PUBLIC_URL` |
| `METRICS_HASH_SECRET` | `SYNC_METRICS_HASH_SECRET` |
| `REPOSITORY` | `IMAGE_REPOSITORY` |
| `SYNCSTORAGE_IMAGE`, `SYNCSTORAGE_IMAGE_TAG` | `SYNC_IMAGE`, `SYNC_IMAGE_TAG` |
| `SYNCSTORAGE_INIT_IMAGE`, `SYNCSTORAGE_INIT_IMAGE_TAG` | `SYNC_INIT_IMAGE`, `SYNC_INIT_IMAGE_TAG` |

Unchanged: `SYNC_MASTER_SECRET`, `SYNC_DB`, `COMPOSE_FILE`, `COMPOSE_PROFILES` and every `FXA_*`, `ADMIN_*` and `BACKUP_*`. Every setting and its old name: [Settings](reference/settings.md).

### How to rename them

- **docker compose:** `./prepare_environment.sh --upgrade` renames them in your `.env`, in place and with their values as they are, and prints what it renamed. It handles indented lines, `export NAME=...`, quotes and CRLF line ends. The old file stays as `.env.before-upgrade-<UTC time>`.
- **Quadlets:** they have no fallback of their own. `--upgrade` renames them in `.env` and renders the units from it, always with the new names ([Quadlets](#quadlets)).

With both names in `.env`, `--upgrade` keeps the new one and removes the old, unless the new one has no value of its own: empty, a `<REPLACE_WITH_...>` placeholder, or the default of `.env-example` (as when added from it). Then it takes the old one's value, with a WARNING whenever that changes what compose ran with: `SYNC_X: effective value <a> -> <b>`. Check it against `.env.before-upgrade-<UTC time>`.

### When both names are set

For example the lines of `.env-example` added before `--upgrade`, or an old name exported in the shell or CI that runs docker compose next to an `.env` with the new ones. Compose would take the new ones, placeholders and defaults included. So the migrations and the init container refuse to start, `docker compose up -d` fails and the Sync server stays down, with:

```text
ERROR: SYNC_X and X are both set (in .env or in the environment docker compose runs in): run ./prepare_environment.sh --upgrade for .env, or unset X in your shell
```

`--upgrade` cannot clear a name of the environment: it lists those still set in its own. The init container also refuses an empty public URL or database password, or one that is still a `<REPLACE_WITH_...>` placeholder (the database containers refuse such an `ADMIN_DB_PASSWORD`). With neither `SYNC_EXPORT_PORT` nor `CONTAINER_EXPORT_PORT` set (or both empty), the Sync server is published on `127.0.0.1:5000`; before, it was a random port on every interface.

### While old names are left

- The init container logs a warning that lists them (`docker compose logs tokenserver_db_init`), and the admin UI's setup check "Old setting names (.env, environment)" fails. Compose passes them to it as `FFS_OLD_ENV_NAMES`.
- The variables inside the containers keep their names: commands such as `docker compose exec tokenserver_db sh -c 'mariadb -u"$MARIADB_USER" ...'`, or those of `sync_role_init` with `$POSTGRES_SYNC_USER`, work as before.
- Your own scripts that read `.env`, or set its settings in the environment of compose (`MAX_USERS=5 docker compose up -d`), need the new names.
- Rolling back to a release from before: it reads only the old names, so put the `.env.before-upgrade-<time>` of that upgrade back.

## Database majors

Each database image moves to a new major in its own way. Which majors are supported and tested: [Supported versions](databases.md#supported-versions).

| Database | Setting (Helm value) | Not set | New installs (`prepare_environment.sh`) | Installs from before (`--upgrade`) | On a new major |
|---|---|---|---|---|---|
| Sync on MariaDB: `syncstorage_db`, `tokenserver_db`, `backup` | `SYNC_MARIADB_IMAGE` (`database.image.mariadb`) | `mariadb:lts` | `mariadb:lts` | the major of the data, for example `mariadb:12` | not set: the containers refuse to start on data of another major; set: the data is upgraded at the first start (`MARIADB_AUTO_UPGRADE`) |
| Sync on MySQL (`SYNC_DB=mysql`): the same three | `SYNC_MYSQL_IMAGE` (`database.image.mysql`) | `mysql:lts` | `mysql:lts` | `mysql:8` | not set: the container refuses to start on data of another major; set: the data is upgraded at the first start |
| Sync on PostgreSQL: `postgres_db`, `backup` | `SYNC_POSTGRES_IMAGE` (`database.image.postgres`) | `postgres:latest` | the major `postgres:latest` is at, for example `postgres:18` | `postgres:18` | the container stops on another major's data, whatever the setting says, and says what to pin |
| accounts on MySQL (`FXA_DB=mysql`): `fxa-db`, `backup-fxa` | `FXA_MYSQL_IMAGE` (`fxa.database.image.mysql`), `FXA_MYSQL_ARGS` (the chart: from the image) | `mysql:lts` | `mysql:lts` with our accounts images; `mysql:8` and `FXA_MYSQL_ARGS` with others | `mysql:8` and `FXA_MYSQL_ARGS` | not set: `fxa-db` refuses to start on data of another major; set: the data is upgraded at the first start |
| accounts on MariaDB (`FXA_DB=mariadb`): `fxa-db`, `backup-fxa` | `FXA_MARIADB_IMAGE` (`fxa.database.image.mariadb`) | `mariadb:lts` | `mariadb:lts` | `mariadb:11` | not set: `fxa-db` refuses to start on data of another major; set: the data is upgraded at the first start (`MARIADB_AUTO_UPGRADE`) |
| the accounts' cache: `fxa-redis` | none (`fxa.redis.image`) | `redis:alpine` | nothing | nothing | no data to upgrade |

- The setting is also the image of the backups of that database, so the dump's client matches the server.
- "Installs from before" are those set up by a release that did not write these settings. `./prepare_environment.sh --upgrade` on one (compose and Quadlets), the setup run again, or a new setup that finds its database volumes, writes the same pins.
- `prepare_environment.sh` reads the label of the accounts image to choose between `mysql:lts` and `mysql:8` ([Upstream patches](reference/images.md#upstream-patches)). When it cannot read the label, it writes `mysql:8` and says so. It reads the local image when there is one, so pull a newer accounts image before running it.
- A new setup over the PostgreSQL volume of an earlier install is pinned to the major in its `PG_VERSION`. One where the major of `postgres:latest` cannot be read (no runtime, no registry) stops with an error.
- With Quadlets, `prepare_environment.sh` writes the same images into the units when it installs them. It reads the major of `postgres:latest` with Podman, the image store the units run from.
- `lts` moves to the next long-term major when MariaDB or MySQL releases it. The next pull brings it (`docker compose pull`, or the Quadlets' `AutoUpdate=registry` on its own), and the server upgrades the data at its next start, with no way back but a backup. To choose when the data moves, pin a major: `mariadb:12`, `mysql:9`, `postgres:18` (Helm: fully qualified, `docker.io/library/mysql:9`).
- The refusal on another MariaDB or MySQL major comes from [db/mysql/keep-major.sh](/db/mysql/keep-major.sh), only while the setting is not set: `keep-major.sh: this database is MySQL 8, the image is MySQL 9`. Set the setting to the major the data has, or move it as in [MariaDB](#mariadb) or [MySQL 8 to 9](#mysql-8-to-9). PostgreSQL's comes from [db/postgres/keep-major.sh](/db/postgres/keep-major.sh) (the chart: its `db-major` init container), whatever the setting says.
- `FXA_MYSQL_ARGS` is `--mysql-native-password=ON --authentication-policy=mysql_native_password` for accounts images without [mozilla/fxa#21554](https://github.com/mozilla/fxa/pull/21554) (Mozilla's, and ours from before). MySQL 9 refuses those options. Which images have it: [MySQL or MariaDB](accounts.md#mysql-or-mariadb).
- With your own database server, the setting is only the backups' client: see [PostgreSQL](databases.md#postgresql).
- A chart cannot read the image's major at install, as `prepare_environment.sh` does: pin `database.image.postgres` in your values (`kubectl exec sts/ffs-firefox-sync-postgres -- postgres --version` shows the major the release runs). The install's NOTES say so too.
- `helm upgrade` refuses a `database.image.<backend>` that would move the bundled database to another major (two numbered majors, or a numbered major to `lts` or `latest`), before applying anything: `firefox-sync: database.image.mysql is ... but the bundled database ... runs ...`. Set it back to the running image. With MariaDB and MySQL, `--set database.allowMajorUpgrade=true` upgrades in place (a backup first); set it back to `false` in the next upgrade, since `--reuse-values` keeps it and the next major would then go through too. PostgreSQL never: a dump and restore ([PostgreSQL](#postgresql)). While its `db-major` init container keeps it stopped on another major's data, its image may change, to go back to the major of the data. The check needs the cluster, so `helm template` skips it, and it does not see `lts` moving on under the same name: pin a major for that.
- The chart's bundled accounts database (`fxa.enabled`) has the same check, with `fxa.database.allowMajorUpgrade`, which goes back to `false` after the move too: `firefox-sync: fxa.database.image.mysql is ... but the bundled accounts database ... runs ...`. From MySQL 8, move its users off `mysql_native_password` first ([MySQL 8 to 9](#mysql-8-to-9), step 2, with `kubectl exec sts/ffs-firefox-sync-fxa-db`), then one `helm upgrade` with `fxa.database.image.mysql: docker.io/library/mysql:lts` and `fxa.database.allowMajorUpgrade: true` moves it: the chart then drops the native password options (step 3) with the same upgrade.
- The chart has no `FXA_MYSQL_ARGS`: it gives `fxa-db` the `mysql_native_password` options when `fxa.database.image.mysql` is a MySQL 8 pin (`docker.io/library/mysql:8`, `mysql:8.4`...), and none with any other image. Its default `mysql:lts` needs an accounts image with mozilla/fxa#21554, as ours have: with Mozilla's image (`fxa.image.repository: docker.io/mozilla/fxa-mono`) or one of ours from before, set `fxa.database.image.mysql: docker.io/library/mysql:8`. A chart cannot read the image's label, as `prepare_environment.sh` does; the NOTES say which applies.

### MariaDB

The Sync databases on MariaDB: `SYNC_MARIADB_IMAGE` (Helm: `database.image.mariadb`). On `mariadb:lts`, the next pull after `lts` moves brings the new major, and at its first start `MARIADB_AUTO_UPGRADE` upgrades the data. A pinned major (`mariadb:12`) stays; to move it, make a backup (`docker compose exec backup sh /ffs-backup/backup.sh now`), then set `SYNC_MARIADB_IMAGE=mariadb:lts` (or the next major) and run `docker compose pull && docker compose up -d`. Make sure the [backup service](backups.md#the-backup-service) runs.

The accounts on MariaDB (`FXA_DB=mariadb`): from MariaDB 11 (`FXA_MARIADB_IMAGE=mariadb:11`) to `lts` (12), or from a pinned major to the next one once the `test-mariadb` job of [fxa.yml](/.github/workflows/fxa.yml) on `mariadb:lts` passes on it. MariaDB 12 needs our accounts images: [MariaDB 12](accounts.md#mariadb-12). Following `fxa-mono-latest`, the pull of step 3 brings one if yours is older; with a pinned `FXA_VERSION`, pin a release whose image has the fix.

1. Make a backup of the accounts: `docker compose exec backup-fxa sh /ffs-backup/backup.sh now`, or of the `fxa-db-mariadb` volume with the stack stopped. It is the only way back: the older MariaDB cannot open the data once the newer one started on it.
1. Set `FXA_MARIADB_IMAGE=mariadb:lts` in `.env`, to follow MariaDB's long-term major from now on, or the major you move to (`mariadb:12`), to choose the next move too.
1. Run `docker compose pull && docker compose up -d`. At its first start the new MariaDB upgrades the data itself (`MARIADB_AUTO_UPGRADE`: `mariadb-upgrade`, after a backup of its system tables). `docker compose logs fxa-db` says `Finished mariadb-upgrade`. Then the migrations and the services start as after any upgrade.
1. Check as in [Self-hosted accounts](#self-hosted-accounts), step 4. The admin UI's overview also shows the new version next to "Accounts database". If anything fails: stop the stack, and restore the backup into an empty `fxa-db-mariadb` volume with the older `FXA_MARIADB_IMAGE` ([Restore](backups.md#restore)).

With Quadlets: make the backup (`systemctl --user start firefox-sync-backup.service`), set `FXA_MARIADB_IMAGE=mariadb:lts` in `.env`, then render the units again ([Change a setting](install/podman.md#change-a-setting)) and restart the database:

```bash
./prepare_environment.sh --render-units
podman pull docker.io/library/mariadb:lts
systemctl --user restart firefox-sync-fxa-db.service
```

The units that require it start again after it: the migrations, the sign-up policy, the accounts' services and the admin UI. `journalctl --user -u firefox-sync-fxa-db.service` says `Finished mariadb-upgrade`.

Tested locally, not in CI (it takes an install, a backup and two starts of the accounts), from 11 to `lts` (12): `FXA_DB=mariadb FXA_MARIADB_FROM=mariadb:11 FXA_MARIADB_IMAGE=mariadb:lts tests/fxa-upgrade.sh`, an install on 11 with an account, a device and Sync data, moved with these steps. The Quadlet steps: `FXA_DB=mariadb FXA_MARIADB_FROM=mariadb:11 tests/podman.sh` (CI: syncstorage-rs.yml `test-podman`, `fxa-mariadb`), the accounts' units started on 11 and moved with the commands above, as this page writes them.

### MySQL 8 to 9

From MySQL 8 (the installs from before, pinned as in [Database majors](#database-majors)) to `mysql:lts` (MySQL 9), when you choose. MySQL upgrades the data in place at its first start on the newer major (8.4 to 9, long-term release to long-term release, a path MySQL supports). There is no way back but a backup.

The accounts' users come first. They are on `mysql_native_password`, and MySQL 9 cannot load it: `Plugin 'mysql_native_password' is not loaded`, for root too.

The accounts (`FXA_DB=mysql`):

1. Use an accounts image with [mozilla/fxa#21554](https://github.com/mozilla/fxa/pull/21554), still on `mysql:8` with `FXA_MYSQL_ARGS`: upgrade as in [Self-hosted accounts](#self-hosted-accounts). Ours have it ([MySQL or MariaDB](accounts.md#mysql-or-mariadb)); with a pinned `FXA_VERSION`, use a release whose image has the label. `./prepare_environment.sh --upgrade` says when the image has it.
1. Move the users to `caching_sha2_password`. List the ones still on `mysql_native_password`:

    ```bash
    docker compose exec fxa-db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -e "SELECT user, host, plugin FROM mysql.user WHERE plugin = \"mysql_native_password\""'
    ```

    `fxa-db` has `root`@`%` and `root`@`localhost` (`FXA_MYSQL_USER`, with the password `FXA_MYSQL_PASSWORD` of `.env`). `ffs_admin` gets `caching_sha2_password` from `fxa-policy` itself at its next start. Change each with its own password, in `mysql -uroot -p` in that container:

    ```sql
    ALTER USER 'root'@'%' IDENTIFIED WITH caching_sha2_password BY '<FXA_MYSQL_PASSWORD>';
    ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '<FXA_MYSQL_PASSWORD>';
    ```

    Run the query again: nothing is left. On your own server, do the same for `FXA_MYSQL_USER` (and any other user of the list), as its administrator.
1. Only after step 2 (a user left on `mysql_native_password`, root too, cannot log in without the options): remove `FXA_MYSQL_ARGS` from `.env` (on your own server, `mysql_native_password=ON` from its configuration) and run `docker compose up -d`: `fxa-db` restarts on MySQL 8 without `mysql_native_password`. Check that the accounts work: a sign-in, and the admin UI's overview all up.
1. Make a backup of the accounts, the only way back: `docker compose exec backup-fxa sh /ffs-backup/backup.sh now`, or of the `fxa-db` volume with the stack stopped. Then set `FXA_MYSQL_IMAGE=mysql:lts` in `.env` (or the major, `mysql:9`, to choose the next move too) and run `docker compose pull && docker compose up -d`. At that start MySQL upgrades the data (`docker compose logs fxa-db`).

    Check as in [Self-hosted accounts](#self-hosted-accounts), step 4: the admin UI's overview shows the new version next to "Accounts database". If anything fails: stop the stack, and restore the backup into an empty `fxa-db` volume on `mysql:8` ([Restore](backups.md#restore)).

The Sync databases (`SYNC_DB=mysql`): their users are on `caching_sha2_password` already. Make a backup (`docker compose exec backup sh /ffs-backup/backup.sh now`), set `SYNC_MYSQL_IMAGE=mysql:lts` in `.env`, and run `docker compose pull && docker compose up -d`.

With Quadlets, the same steps with these changes. A change of `.env` goes into the units with `./prepare_environment.sh --render-units` ([Change a setting](install/podman.md#change-a-setting)), and restarting a database unit restarts the units that require it after it, the migrations first:

- step 2: the query in the database's container,

    ```bash
    podman exec firefox-sync-fxa-db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -e "SELECT user, host, plugin FROM mysql.user WHERE plugin = \"mysql_native_password\""'
    ```

    and the `ALTER USER` statements in `podman exec -it firefox-sync-fxa-db mysql -uroot -p`;
- step 3: remove `FXA_MYSQL_ARGS` from `.env`, then run `./prepare_environment.sh --render-units` and `systemctl --user restart firefox-sync-fxa-db.service`;
- step 4: the backup is `systemctl --user start firefox-sync-backup.service`. Then set `FXA_MYSQL_IMAGE=mysql:lts` in `.env`, and run `./prepare_environment.sh --render-units`, `podman pull docker.io/library/mysql:lts` and `systemctl --user restart firefox-sync-fxa-db.service`;
- the Sync databases: `SYNC_MYSQL_IMAGE=mysql:lts` in `.env`, the same commands, and `systemctl --user restart firefox-sync-tokenserver-db.service firefox-sync-syncstorage-db.service`.

If MySQL 9 already started with a user still on `mysql_native_password`, see [Troubleshooting](troubleshooting.md#databases).

Tested:

- `FXA_FROM=<an older accounts image> tests/fxa-upgrade.sh` (`FXA_MYSQL_TO=mysql:lts`, the default with a new image that has mozilla/fxa#21554): an install on `mysql:8` with `mysql_native_password`, an account with a device and Sync data; the new files without the settings (`fxa-db` refuses the data), `--upgrade`, the accounts upgraded, then steps 2 to 4, the account of before and new ones on MySQL 9.
- `SYNC_DB=mysql SYNC_MYSQL_IMAGE=mysql:8 tests/e2e.sh mysql`: `--upgrade` pins an install from before, `mysql:lts` unset refuses its data, then `SYNC_MYSQL_IMAGE=mysql:lts` moves it (no backup step).
- The Quadlet steps: `SYNC_DB=mysql SYNC_MYSQL_FROM=mysql:8 FXA_MYSQL_FROM=mysql:8 tests/podman.sh` (CI: syncstorage-rs.yml `test-podman`, `sync-mysql`): the Sync databases and the accounts' started on `mysql:8` (the accounts with `mysql_native_password`), then moved with the commands above, as this page writes them.
- Not tested: your own server.

### PostgreSQL

PostgreSQL has no long-term tag (every major is supported for five years), so `SYNC_POSTGRES_IMAGE` pins the major of each install. The official image keeps its data at `/var/lib/postgresql/<major>/docker` and cannot open another major's data. On such data the container stops first and says what to set ([db/postgres/keep-major.sh](/db/postgres/keep-major.sh), whatever `SYNC_POSTGRES_IMAGE` says; the chart's `db-major` init container does the same). Left unset, `postgres:latest` would stop the server at the next major.

To move to a newer major, dump and restore:

1. Make a backup: `docker compose exec backup sh /ffs-backup/backup.sh now`.
1. Set `SYNC_POSTGRES_IMAGE` to the new major, for example `postgres:19`.
1. Restore the backup into an empty `postgres-db` volume, as in [Restore](backups.md#restore).

`pg_upgrade` works too, but is not automated here: see [PostgreSQL's pg_upgrade](https://www.postgresql.org/docs/current/pgupgrade.html). With the Helm chart, the same with `database.image.postgres` and [Restore on Kubernetes](backups.md#restore-on-kubernetes).

Tested: `PG_MAJOR_MOVE=1 tests/e2e.sh postgres` (in CI, syncstorage-rs.yml `test`): an install on the major before that of `postgres:latest`, with accounts and Sync data, then these three steps. Before the restore the new major refuses the old data and leaves it as it is; after it, the new major runs on the new volume and the same accounts read back the same items. Not tested: `pg_upgrade`, the Helm chart.
