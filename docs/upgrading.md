# Upgrading

How to upgrade a running install: new images of the Sync server, the admin UI and the self-hosted accounts, with docker compose, the Quadlets or the Helm chart. It also covers upgrading from an older firefox-sync release, the renamed settings, and moving a database to a newer major. Make a backup first: see [Backups](backups.md).

## How the images move

By default every image follows a moving tag, and a new upstream release is published here only after the tests passed with it:

| Image | Setting | Default |
|---|---|---|
| the Sync server and its init container | `SYNC_IMAGE_TAG`, `SYNC_INIT_IMAGE_TAG` | `latest` |
| the admin UI | `ADMIN_IMAGE` | `<IMAGE_REPOSITORY>:admin-latest` |
| the self-hosted accounts | `FXA_VERSION` | `fxa-mono-latest` |

To decide when to upgrade instead, pin a tag in `.env` (Helm: in your values), and change it to upgrade. Which tags exist: [Images](reference/images.md). The database images move differently: see [Database majors](#database-majors).

The database migrations run before each service starts and cannot be undone. Going back to an older release means restoring a backup.

## Sync server

With docker compose:

```bash
docker compose pull
docker compose up -d
```

The migrations and the init container run before the Sync server starts. Firefox needs nothing. The admin UI's image is pulled and replaced by the same commands.

With Quadlets, see [Quadlets](#quadlets). With the Helm chart, see [Helm](#helm). From an older firefox-sync release, see [Older firefox-sync releases](#older-firefox-sync-releases).

## Self-hosted accounts

A new Mozilla release comes about every two weeks. It is published here only after the tests passed with it on amd64 and arm64, including a real Firefox signing up and syncing, and an install of the previous release upgraded to it. Sessions, devices, OAuth tokens and Sync data are kept: Firefox stays signed in.

With docker compose:

1. Make a backup of the accounts. With the backup service: `docker compose exec backup-fxa sh /ffs-backup/backup.sh now`. Without it, back up the `fxa-db` volume (`fxa-db-mariadb` with MariaDB) and the `fxa-keys` volume. With your own database server, back up its `fxa`, `fxa_oauth`, `fxa_profile`, `pushbox` and `ffs` databases.
1. To decide when to upgrade, pin a release in `.env`, for example `FXA_VERSION=fxa-mono-v1.347.1`, and change it to upgrade.
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
1. Pin a release in your values, for example `fxa.image.tag: fxa-mono-v1.347.3`, and change it to upgrade. With `fxa-mono-latest` and `image.pullPolicy: IfNotPresent`, a node that has the image never pulls a newer one.
1. `helm upgrade` as in [Helm](#helm). The auth pod stops, and its new pod runs the migrations, then the sign-up policy, in its init containers before it serves. The content and profile servers wait for it.
1. Check `kubectl logs deploy/ffs-firefox-sync-fxa-auth -c migrations`, and the admin UI's overview as above. A failed migration keeps the auth pod in `Init:Error` and out of its Service. To go back to the older release, restore the backup ([Restore on Kubernetes](backups.md#restore-on-kubernetes)).

To move from Mozilla's image to the builds of this repository, or back, change `FXA_IMAGE`, `FXA_VERSION` and `FXA_ARCH` together (Helm: `fxa.image.repository` and `.tag`), then follow the same steps. For example from `FXA_IMAGE=docker.io/mozilla/fxa-mono`, `FXA_VERSION=v1.345.2`, `FXA_ARCH=amd64` to `FXA_IMAGE=ghcr.io/porelli/firefox-sync`, `FXA_VERSION=fxa-mono-latest`, `FXA_ARCH=arm64`. It is the same software: the databases and the keys stay.

Don't stay too far behind: Firefox refuses to sign in to accounts servers that are too old for it. For example Firefox 154 needs a recent release, because it switched to Bearer tokens.

## Quadlets

`prepare_environment.sh` writes the images and the values of `.env` into the unit files. Podman does not pull a tag it already has, and the one-shot units (the migrations, the init container, the sign-up policy) ran at the first start and stay active: a new image alone does not migrate.

`./prepare_environment.sh --upgrade` renders the units again from your `.env`, with every password and secret it has: nothing to set by hand in the databases. A new firefox-sync release, the Sync server and the admin UI:

1. Make a backup: `systemctl --user start firefox-sync-backup.service` (with self-hosted accounts it backs them up first), or back up the volumes.
1. Stop the units, the one-shot ones too (they stay active and would not run again), and the backup timer, so that no backup starts halfway: `systemctl --user stop firefox-sync-backup.timer firefox-sync-syncstorage.service firefox-sync-admin.service firefox-sync-syncstorage-migrate.service firefox-sync-tokenserver-db-init.service firefox-sync-tokenserver-db.service firefox-sync-syncstorage-db.service`. Without the database containers, the last two are not there. With PostgreSQL, they are `firefox-sync-sync-role-init.service firefox-sync-postgres-db.service`.
1. Get the new files (`git pull` in the clone), and keep your `.env`. Don't run `./prepare_environment.sh` without `--upgrade`: that is a new install, with new passwords that the databases don't have (it keeps the old file as `.env.before-setup-<UTC time>`).
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
- Units of an earlier release, which name no checkout (the releases before the backups, firefox-sync's `main` branch): rendered again when they have the `SYNC_MASTER_SECRET` of your `.env`, so were rendered from it. It says so.
- Units of another checkout, or of an earlier release with another `SYNC_MASTER_SECRET`: left as they are. It says what it found. If they are this install's, `./prepare_environment.sh --render-units` renders them from this `.env` (the units of before kept as above).

To go back: the old files and images, the newest `.env.before-upgrade-<time>` as `.env`, the files of `quadlets.before-<time>/` back into `~/.config/containers/systemd/` (`firefox-sync-backup.timer` into `~/.config/systemd/user/`) with the `firefox-sync-*.env` files of the new units removed there when the units of before have none, `systemctl --user daemon-reload`, and the backup of step 1: see [Rollback](#rollback).

New images of the same release, without new files: steps 5 and 6, with the units stopped as in step 2.

The self-hosted accounts:

1. Make a backup: `systemctl --user start firefox-sync-backup.service` (it backs up the accounts first).
1. Get the new image. With `fxa-mono-latest`: `podman pull ghcr.io/porelli/firefox-sync:fxa-mono-latest` (with `--arch` as `FXA_ARCH`). Pinned: change `FXA_VERSION` in `.env`, render the accounts' units again from it ([Change a setting](install/podman.md#change-a-setting)), and pull the release:

    ```bash
    ./prepare_environment.sh --render-units
    podman pull ghcr.io/porelli/firefox-sync:fxa-mono-v1.347.3
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

## Older firefox-sync releases

The same stack: upgrade in place, nothing to export. The volumes (`<directory>_tokenserver-db`, `<directory>_syncstorage-db`) keep their names as long as you run compose from the same directory.

### Files that moved

The compose files are now in `compose/`: one for the Sync server, one per database, the same for the accounts ([The compose files](install/compose.md#the-compose-files)). The services, containers, volumes and settings keep their names.

| Before (`COMPOSE_FILE`) | Now |
|---|---|
| none, or `docker-compose.yml` | `compose/sync.yml:compose/sync-mariadb.yml` |
| `docker-compose.yml:docker-compose.sync-mysql.yml` | `compose/sync.yml:compose/sync-mysql.yml` |
| `docker-compose.sync-postgres.yml` (before it, `docker-compose.postgres.yml`) | `compose/sync.yml:compose/sync-postgres.yml` |
| `:docker-compose.fxa.yml` | `:compose/fxa.yml:compose/fxa-mysql.yml` |
| `:docker-compose.fxa.yml:docker-compose.fxa-mariadb.yml` | `:compose/fxa.yml:compose/fxa-mariadb.yml` |
| `-f docker-compose.podman.yml` | `:compose/podman.yml` |

Run the one command, in the checkout:

```bash
./prepare_environment.sh --upgrade
```

It writes the new names in `COMPOSE_FILE` (your own files stay in it, after them; with docker compose on the Podman socket also `compose/podman.yml`, which the setup of before had only in its `-f` command) and `COMPOSE_PROJECT_NAME` with the directory's name, the project's name before, and says so. Without `COMPOSE_PROJECT_NAME`, compose would name the project after `compose/`, the directory of the first file, and find none of your containers and volumes.

Without it:

- `COMPOSE_FILE` with the old names: `docker compose` stops at once, the old file not found (`no such file or directory`). Nothing starts or changes until you run `--upgrade`.
- No `COMPOSE_FILE` (Sync on MariaDB): `docker-compose.yml` is still there and runs the files of `compose/`, as the same project (with the compose of the [requirements](install/compose.md#requirements)). `--upgrade` writes `COMPOSE_FILE` there too, unless you have a `docker-compose.override.yml`, which compose reads only without `COMPOSE_FILE`.
- Your own scripts and units with `-f`: change the names, and add `--env-file .env` (compose looks for `.env` in the directory of the first file; without it, it stops: `required variable SYNC_MASTER_SECRET is missing a value`). An exported `COMPOSE_FILE` or `COMPOSE_PROJECT_NAME` (your shell, a unit's `Environment=`) wins over `.env`: `--upgrade` says so, change it there too.
- Your own compose files in `COMPOSE_FILE`: their relative paths are now relative to `compose/` (`./config` becomes `../config`).

The release that added `db/` moved other files. The image names and the names of the installed Quadlet units did not change.

- `config/database/` is gone. `sync-mariadb.sql` became `db/mysql/sync.sql`, `sync-postgres.sql` `db/postgres/sync.sql`, and `fxa-mysql.sql`, `fxa-mariadb.sql` and `admin-user.sh` went to [db/mysql/](/db/mysql). They are now the [setup migrations](databases.md#setup-migrations) of [db/mysql/setup/](/db/mysql/setup) and [db/postgres/setup/](/db/postgres/setup). With your own database server, `prepare_environment.sh` reads them from there. If you fill in the SQL by hand, take it from the new paths ([Create the databases and users](databases.md#create-the-databases-and-users)).
- `syncstorage-rs-init/` and `syncstorage-rs-init-postgres/` are now `db/mysql/init/` and `db/postgres/init/`. This only matters if you build the init images yourself (`docker build db/mysql/init`).
- `config/quadlet/mysql/` is now `config/quadlet/sync-mysql/` (`SYNC_DB=mysql`), where `prepare_environment.sh` looks for it. The units keep their names, but the database units now mount `db/mysql/admin-user.sh`. Render them again before the next start (`--upgrade` does, [Quadlets](#quadlets)): the old units point at `config/database/admin-user.sh`, which `git pull` removes.
- nginx: [config/nginx/syncstorage-rs-example.conf](/config/nginx/syncstorage-rs-example.conf) now has `client_max_body_size 10m;`. Your `config/nginx/syncstorage-rs.conf` (written once by `prepare_environment.sh`) and your own proxy keep their setting. Add it to the `server` block of your Sync host, see [Request size](reverse-proxy.md#request-size).
- Not a git clone: after copying the new files, delete the old `config/database/`, `config/quadlet/mysql/`, `syncstorage-rs-init/` and `syncstorage-rs-init-postgres/`.

### Your own database server: the setup migrations

The SQL of your own server is now the numbered [setup migrations](databases.md#setup-migrations), recorded on the server as they run. Nothing to do for an install from before them: at its first start of this release `db-bootstrap` (`fxa-db-bootstrap`) finds the users, grants and databases of `database-setup.sql` there, and records every file as `baseline`; if something is missing, the start stops naming it, as before. `--upgrade` writes `database-setup.sql` (`database-setup-fxa.sql`) again and keeps the one of before as `database-setup.sql.before-upgrade-<UTC time>`, readable by you only. With the stack's own database containers the init container records them (`containers`). The admin UI shows the version of each server ([Setup migrations](admin/monitoring.md#setup-migrations)).

### The database majors of an install from before

The database images now follow each database's long-term tag, and an install from before runs an older major. `./prepare_environment.sh --upgrade` (compose and Quadlets) writes the pins that keep it where it is, and says so. The pins are in [Database majors](#database-majors).

**If you update the files without it**:

- the MariaDB and MySQL containers (the Sync databases, and the accounts' `fxa-db`) do not start rather than upgrade the data: `docker compose logs` shows [db/mysql/keep-major.sh](/db/mysql/keep-major.sh)'s `this database is MySQL 8, the image is MySQL 9` (or `MariaDB 11`, `MariaDB 12`). Run `--upgrade` then.
- The Sync databases on the MariaDB containers ran `mariadb:lts` before, which upgraded their data whenever a pull brought a new major. `--upgrade` now writes `SYNC_MARIADB_IMAGE` with the major their data holds (for example `mariadb:12`, read from their volume or the running server), and they stay there.

Moving to the newer major later is up to you, with a backup first: [MariaDB](#mariadb), [MySQL 8 to 9](#mysql-8-to-9), [PostgreSQL](#postgresql).

### With docker compose

1. Back up the volumes, or dump the databases (see [Move an existing install](databases.md#move-an-existing-install)).
1. Get the new files (`git pull` in the clone). Keep your `.env`: don't run `./prepare_environment.sh` again, it would generate new passwords that the databases don't have.
1. Run `./prepare_environment.sh --upgrade`. It changes only what this release needs, keeps every value already there, and leaves the old file as `.env.before-upgrade-<UTC time>` (readable by you only, as `.env`):
    - it renames the settings your `.env` has under their old names ([Renamed settings](#renamed-settings));
    - it writes the files of `compose/` in `COMPOSE_FILE`, and `COMPOSE_PROJECT_NAME` ([Files that moved](#files-that-moved));
    - it sets `ADMIN_DB_PASSWORD`, the password of the admin UI's database users: at the next start the event log and the audit trail move out of the Sync server's reach ([The admin UI's own database](#the-admin-uis-own-database));
    - with the PostgreSQL container, it sets `SYNC_POSTGRES_APP_USER` and `SYNC_POSTGRES_APP_PASSWORD`, a role of the Sync server's own that is no superuser;
    - it writes the database majors the install runs ([Database majors](#database-majors)).

    Don't skip it: without it the admin UI keeps the event log in the tokenserver database, which the Sync server's user can rewrite, and its setup check fails. With your own database server, run the `database-setup.sql` it writes there first. Run it before the next step: a line of `.env-example` added under its new name before the rename would hide your value under the old one (compose reads the new name first).
1. Add the lines of [.env-example](/.env-example) that your `.env` lacks, with their default values, and change none of yours:
    - releases from before December 2024 have no `SYNC_TOKENSERVER_DB_HOST`, `_PORT`, `_NAME` (and the same for `SYNC_STORAGE_DB_`), `IMAGE_REPOSITORY`, `SYNC_IMAGE*`, `SYNC_INIT_IMAGE*`, `FXA_EMAIL_DOMAIN` and `FXA_OAUTH_SERVER_URL`: copy them from `.env-example`;
    - the first release (July 2024) had one `MARIADB_USER` and `MARIADB_PASSWORD` for both databases, and no `SYNC_MAX_USERS`: set `SYNC_TOKENSERVER_DB_USER` and `SYNC_STORAGE_DB_USER` to that user, `SYNC_TOKENSERVER_DB_PASSWORD` and `SYNC_STORAGE_DB_PASSWORD` to that password, and `SYNC_MAX_USERS` to at least the number of accounts.
1. Run `docker compose pull && docker compose up -d`. `SYNC_MAX_USERS=N` works as before (set at every start); `SYNC_MAX_USERS=initial:N` lets the admin UI manage it ([Limits](limits.md#sync_max_users)).

Firefox needs nothing.

### With Quadlets

For installs since November 2025: the steps of [Quadlets](#quadlets). `--upgrade` renames the old setting names in `.env`, adds what this release needs and the lines of `.env-example` your `.env` lacks (the step 4 of compose, done for you), and renders the units from that `.env`, with the passwords they had.

### Rollback

Put back the old files and images, with the `.env.before-upgrade-<time>` of the upgrade as `.env` (Quadlets: and the units of `quadlets.before-<time>/`, see [Quadlets](#quadlets)) and the backup of the volumes of step 1. An older release reads only the old setting names: pin `SYNCSTORAGE_IMAGE_TAG` and `SYNCSTORAGE_INIT_IMAGE_TAG` there to the old tags, and `ADMIN_IMAGE` to the admin UI of then. The migrations of the newer syncstorage-rs cannot be undone, nor the move of the event log, so roll back everything together, never one image alone:

- An older admin UI (from before `ADMIN_DB_PASSWORD`) creates its tables again, empty, in the tokenserver database, and records there, within the Sync server's reach. The event log and the audit trail since the upgrade stay in `ffs_admin`, which it does not read. Going forward again later, the newer admin UI does not copy those tables a second time: its setup check names them. Drop them as the tokenserver user once you have looked at them.
- An older init image with the newer admin UI: on MariaDB and MySQL the admin UI's reader `ffs_admin_sync` changes the tokenserver database only through the init container's procedures (`ffs_set_max_users`, `ffs_delete_user_row`, `ffs_drop_admin_tables`), which an older init image does not create. On the databases of before (the backup), the max users edits, the resets that free a slot and the deleted accounts then fail with a missing procedure. Pin the init image back only together with the admin UI (`ADMIN_IMAGE`), or keep the init image of this release as long as its admin UI runs.

### The admin UI's own database

An install from before `ADMIN_DB_PASSWORD` (its `.env` has none) keeps working as it did: the admin UI connects as the Sync users and keeps its tables in the tokenserver database. Its setup check of the event log fails and says how to move it, and its log says so at every start. Why the move matters: [The admin UI's own database](reference/database-users.md#the-admin-uis-own-database).

1. Run `./prepare_environment.sh --upgrade`. It adds `ADMIN_DB_PASSWORD` (32 letters and digits), `ADMIN_DB_NAME`, `ADMIN_DB_USER`, `ADMIN_DB_SYNC_USER`, and with the PostgreSQL container `SYNC_POSTGRES_APP_USER` and `SYNC_POSTGRES_APP_PASSWORD`. By hand: `ADMIN_DB_PASSWORD=$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 32)` in `.env`, the same for `SYNC_POSTGRES_APP_PASSWORD`, with `SYNC_POSTGRES_APP_USER=syncserver_app`.
1. Your own server only: run the new `database-setup.sql` there (`--upgrade` writes it again; its statements can run again), or the admin UI's statements of the SQL with that password. With `SYNC_DB_BOOTSTRAP_USER` the stack does it at the next start ([Let the stack apply them](databases.md#let-the-stack-apply-them)).
1. Run `docker compose pull && docker compose up -d`.

At that start:

- the database containers are created again with the users, and the init container gives the grants (with PostgreSQL also the Sync tables to the Sync server's role);
- at its first start the admin UI copies its tables of the tokenserver database into `ffs_admin` in one transaction (the events in their order, every note, metric and backup run), then drops them through `ffs_drop_admin_tables`;
- the event log gets an event of kind `update` with what moved. It is done once (recorded in `ffs_meta`). Admin UI tables found in the tokenserver database later (a backup of before restored, or rows the Sync server's user put there) are not copied again: the setup check names them.

When something is missing:

- If the admin UI cannot read the old tables (a grant missing on your own server), it copies nothing and leaves them where they are. The setup check says why, nothing is lost, and the next start tries again.
- If it copied them but cannot drop them (no `EXECUTE`, an init image from before), they stay in the tokenserver database, within the Sync server's reach, until you drop them as the tokenserver user: `DROP TABLE ffs_events, ffs_metrics, ffs_gauges, ffs_account_notes, ffs_schema_levels, ffs_jobs, ffs_backups;`. The setup check says so too.
- If `ffs_admin_ui` cannot create its tables in `ffs_admin` (its grant missing), the admin UI does not start and says why. The old tables stay untouched.

Your own backup jobs that record their runs now write into `ffs_admin` as `ffs_admin_ui` ([Your own database server](backups.md#your-own-database-server)).

### Tested

- docker compose: `tests/migrate.sh firefox-sync-2024-12` (4705bda, images 0.18.2) and `firefox-sync-2024-07` (the first release, 7f52fa0, image 0.17.1). The old release's files and `.env`, an account syncs, then the new files over them, `./prepare_environment.sh --upgrade`, the missing lines of `.env-example` added as above, `docker compose pull && docker compose up -d`: the same volumes, the same accounts on the same node with their data, and `SYNC_MAX_USERS` and the admin UI count them.
- The Quadlets: `UPGRADE_FROM=<checkout of the release before> tests/podman.sh` (cb8e519, MariaDB containers) runs the steps of [Quadlets](#quadlets) except the pull: every password and secret of the old `.env` stays (under its new name), the units of before are kept, a second `--upgrade` changes nothing, and the stack starts with the passwords of before, with no `SET PASSWORD`. The admin UI's audit event of before moves into `ffs_admin`. `tests/podman.sh` also renders a running install again with a setting and an image changed (`--render-units`), and stops and starts it.
- The files moved to `compose/`: `tests/podman.sh` (compose on the Podman socket) and `tests/e2e.sh` have `--upgrade` write `COMPOSE_FILE` from each old layout (none, `docker-compose.sync-mysql.yml`, `docker-compose.postgres.yml`) and `COMPOSE_PROJECT_NAME`, and start the stack with it; without `COMPOSE_FILE`, `docker-compose.yml` finds the running MariaDB stack. `tests/migrate.sh firefox-sync-2024-12` keeps the same volumes. `UPGRADE_FROM=<checkout of the release before> tests/e2e.sh` runs that release's compose files, then this tree's on the same volumes.
- The admin UI's own database: `tests/e2e.sh` with `UPGRADE_FROM` (MariaDB, MySQL and PostgreSQL), and `tests/podman.sh` with `prepare_environment.sh --upgrade`.
- The old setting names: `tests/podman.sh` starts its compose phase from an `.env` with only the old names and has `--upgrade` rename them; `tests/e2e.sh` starts its install from before with only the old names; `tests/migrate.sh firefox-sync-2024-12` upgrades a real `.env` of then.
- The Quadlets on your own database server: `EXTERNAL_DB=1 tests/podman.sh` (MariaDB `lts`; MySQL `lts` with `SYNC_DB=mysql`, PostgreSQL `latest` with `SYNC_DB=postgres`), the server outside the units, its databases and users made by `database-setup.sql`: the Sync server and the admin UI on it, a backup recorded there, `--upgrade` writing `database-setup.sql` again, a setting rendered again and every unit started again.
- Not tested: the backup and the rollback.

## Renamed settings

The settings of the Sync server in `.env` now have the `SYNC_` prefix, like the `FXA_`, `ADMIN_` and `BACKUP_` ones. The old names keep working for now and will be removed in a later release: compose reads the old name when the new one is not set (also from the environment it runs in).

| Old name | New name |
|---|---|
| `MARIADB_TOKENSERVER_DATABASE`, `_USER`, `_PASSWORD`, `_SERVER`, `_SERVER_PORT` | `SYNC_TOKENSERVER_DB_NAME`, `_USER`, `_PASSWORD`, `_HOST`, `_PORT` |
| `MARIADB_SYNCSTORAGE_DATABASE`, `_USER`, `_PASSWORD`, `_SERVER`, `_SERVER_PORT` | `SYNC_STORAGE_DB_NAME`, `_USER`, `_PASSWORD`, `_HOST`, `_PORT` |
| `POSTGRES_DATABASE`, `_USER`, `_PASSWORD`, `_SERVER`, `_SERVER_PORT` | `SYNC_POSTGRES_NAME`, `_USER`, `_PASSWORD`, `_HOST`, `_PORT` |
| `POSTGRES_SYNC_USER`, `POSTGRES_SYNC_PASSWORD` | `SYNC_POSTGRES_APP_USER`, `SYNC_POSTGRES_APP_PASSWORD` |
| `POSTGRES_IMAGE` | `SYNC_POSTGRES_IMAGE` |
| `MARIADB_TLS_VERIFY` | `SYNC_DB_TLS_VERIFY` |
| `DB_CONTAINERS` | `SYNC_DB_CONTAINERS` |
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
- The placeholders of `db/mysql/sync.sql` and `db/postgres/sync.sql` (now [db/mysql/setup/sync/](/db/mysql/setup/sync) and [db/postgres/setup/sync/](/db/postgres/setup/sync)), if you fill them in by hand: `@TOKENSERVER_*@` is now `@SYNC_TOKENSERVER_*@`, `@SYNCSTORAGE_*@` is `@SYNC_STORAGE_*@`, and `@POSTGRES_*@` is `@SYNC_POSTGRES_*@` (for example `@SYNC_TOKENSERVER_PASSWORD@`, `@SYNC_POSTGRES_DATABASE@`). The nginx example has `<SYNC_EXPORT_PORT>`.
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
