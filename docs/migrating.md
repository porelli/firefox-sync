# Migrating

How to move to firefox-sync from another self-hosted Firefox Sync setup, and how to move a firefox-sync install from docker compose to Kubernetes. To upgrade firefox-sync itself, including from the earlier release, see [Upgrading](upgrading.md).

Each section says on its `Tested:` line whether and how it was tested. The database moves are tested by [`tests/migrate.sh`](/tests/migrate.sh) `<scenario>`: an account of upstream's mock accounts server writes its data through the old stack, the commands of this page move it as written here, and the same account (same uid and keys) reads it back through firefox-sync, on the new node, with `SYNC_MAX_USERS` and the admin UI counting it. The old stacks run in containers: their own compose files where they publish images, otherwise the same database server, names and schema.

Keep the old server until every device syncs with the new one.

## How to choose

| You run | Sync data | Accounts | Section |
|---|---|---|---|
| the earlier release of firefox-sync | upgrade in place | - | [The earlier firefox-sync release](upgrading.md#the-earlier-firefox-sync-release) |
| firefox-sync with docker compose or the Quadlets, to Kubernetes | dump and restore | Mozilla's | [From docker compose to Kubernetes](#from-docker-compose-to-kubernetes) |
| Mozilla's syncstorage-rs compose files | start fresh, or move the database | Mozilla's | [syncstorage-rs](#mozillas-syncstorage-rs-compose-files) |
| dan-r/syncstorage-rs-docker, MASH | start fresh, or move the database | Mozilla's | [dan-r](#dan-rsyncstorage-rs-docker-and-mash) |
| jeena/fxsync-docker | start fresh, or move the database | Mozilla's | [jeena](#jeenafxsync-docker) |
| NixOS `services.firefox-syncserver` | start fresh, or move the database | Mozilla's | [NixOS](#nixos-servicesfirefox-syncserver) |
| YunoHost `syncserver-rs` | start fresh, or move the database | Mozilla's | [YunoHost](#yunohost-syncserver-rs_ynh) |
| the Python syncserver (any image) | start fresh only | Mozilla's | [Python syncserver](#the-python-syncserver) |
| jackyzy823/fxa-selfhosting | start fresh only | must move | [fxa-selfhosting](#jackyzy823fxa-selfhosting) |

From docker compose to the Quadlets on the same host: make a backup with compose and restore it with the Quadlets, as in [Backups](backups.md#restore-with-quadlets). Not tested.

## Start fresh first

The Sync server keeps a copy of what your browsers already have, encrypted with keys derived from your account password. When Firefox finds an empty server for an account whose keys did not change, it uploads everything it has on its next sync. Other devices merge their own data in when they sync after it.

So for every server that only does Sync (you sign in with Mozilla's accounts, or your accounts stay where they are), the simplest and safest way is to start fresh:

1. Set up firefox-sync ([the docs index](README.md)). Set `SYNC_MAX_USERS` to at least the number of accounts that will use it ([Limits](limits.md#sync_max_users)).
1. Start with the device that has the most data, usually your main desktop:
    - if the address of the Sync server changes: disconnect Sync and choose to keep the data on the device (Firefox asks), set the new address ([Firefox](firefox.md)), sign in again and sync;
    - if you keep the same address (your reverse proxy now sends it to firefox-sync, see below): restart Firefox and use `Sync Now`. Firefox may use its token from the old server for up to an hour; disconnecting and signing in again switches it at once.
1. Wait until that device has synced (`about:sync-log` on desktop, or the account's storage in the [admin UI](admin/README.md)), then do the other devices one at a time.

The data kept only on the old server is lost: for example the data of a device you no longer have. If no device has everything, move the database instead: see the sections below for the setups where that works.

To keep the same address, the path must match too: firefox-sync's tokenserver is at `https://<host>/1.0/sync/1.5` and the storage at `https://<host>/1.5/<uid>`. Set `SYNC_PUBLIC_URL` to the old host name and point the reverse proxy for that host to firefox-sync: see [Reverse proxy](reverse-proxy.md#host-names-and-ports) (with the Helm chart, `syncDomain` and its Ingress).

Rollback: stop the old stack (`docker compose stop`, not `down -v`) instead of removing it. Until all devices have synced with firefox-sync, going back is pointing the reverse proxy, or the Firefox setting, back to it and starting it.

Tested: not as a migration. It is what Firefox does with any new server: [`tests/test_fxa_browser.py`](/tests/test_fxa_browser.py) syncs a real Firefox to an empty one.

## Moving the database

This only works between syncstorage-rs servers (the Rust one) on the same kind of database, and only with the same accounts service. Then the accounts keep their Sync ids and their data, and Firefox goes on syncing without uploading everything again.

- **The same accounts service.** The tokenserver knows an account as `<fxa uid>@<FXA_EMAIL_DOMAIN>` in its `users` table, with the `generation`, `keys_changed_at` and `client_state` of the account's keys. With Mozilla's accounts that is `api.accounts.firefox.com` everywhere. A different `FXA_EMAIL_DOMAIN` makes every account a new one: then start fresh.
    - Check the old `users` table: `SELECT DISTINCT email FROM users`. A configuration that sets no email domain gets syncstorage-rs' default, `api-accounts.stage.mozaws.net` (Mozilla's test servers): for example Mozilla's `docker-compose.mysql.yaml` and `docker-compose.postgres.yaml` as they are.
    - Loaded with `FXA_EMAIL_DOMAIN=api.accounts.firefox.com`, such accounts are not found: the tokenserver makes new, empty ones, and `SYNC_MAX_USERS`, counting the old ones too, refuses them.
- **The same kind of database.**
    - MariaDB or MySQL to firefox-sync's MariaDB (the default): supported. Dumps of MySQL 8 use the `utf8mb4_0900_ai_ci` collation, which MariaDB knows from 11.4.5 on; the stack runs `mariadb:lts`, newer than that. Tested from MySQL 8.0, MariaDB 10.6, 10.11 and 11.4 into `mariadb:lts`.
    - To firefox-sync on MySQL (`SYNC_DB=mysql`): only dumps from MySQL, or from MariaDB before 11. MariaDB 11 and newer write `uca1400` collations that MySQL rejects. Tested from MySQL 8.0 into `mysql:lts`; dumps of MariaDB into MySQL were not tested.
    - PostgreSQL to firefox-sync's PostgreSQL: supported. Tested from PostgreSQL 15, 17 and 18 into the stack's.
    - MySQL or MariaDB to PostgreSQL, or back: not a plain dump, not supported. Start fresh.
- **Whole databases**, including `__diesel_schema_migrations`: it tells syncstorage-rs which migrations already ran. firefox-sync runs the newest syncstorage-rs, so it applies the migrations the old server did not have yet. Going back to an older version afterwards is not possible.
- **Into empty databases, before firefox-sync's first start.** At the start, syncstorage-rs adds the node for `SYNC_PUBLIC_URL` if it is missing. Then the init container moves every account to that node and takes the old nodes out ([db_init.sql](/db/mysql/init/db_init.sql), [PostgreSQL](/db/postgres/init/db_init.sql)). So the old node URL does not need to be changed by hand.
- **`SYNC_MAX_USERS` at least the number of accounts.** Accounts that are already in the database always get in, but with fewer seats than accounts, new ones are refused.
- `SYNC_MASTER_SECRET` and `SYNC_METRICS_HASH_SECRET` don't need to be the old ones: Firefox gets a new token when the old one is refused. The tests use new ones: the accounts sign in again and find their data. That Firefox asks for a new token by itself was not tested.

### Loading into firefox-sync

1. Set up firefox-sync with `./prepare_environment.sh` (MariaDB or PostgreSQL, as the old server), but don't run `docker compose up -d` yet. New volumes are empty.
1. Stop the old server, except its database, so that nothing changes during the dump. Make the dumps (see each section): `tokenserver.sql` and `syncstorage.sql` for MariaDB or MySQL, `syncserver.sql` (or three files) for PostgreSQL.
1. Start only the database containers and load the dumps. PostgreSQL loads as the Sync server's role, never as the superuser: see [PostgreSQL users](reference/database-users.md#postgresql).
    ```bash
    # MariaDB (compose/sync-mariadb.yml)
    docker compose up -d --wait tokenserver_db syncstorage_db
    docker compose exec -T tokenserver_db sh -c 'MYSQL_PWD="$MARIADB_PASSWORD" mariadb -u"$MARIADB_USER" "$MARIADB_DATABASE"' < tokenserver.sql
    docker compose exec -T syncstorage_db sh -c 'MYSQL_PWD="$MARIADB_PASSWORD" mariadb -u"$MARIADB_USER" "$MARIADB_DATABASE"' < syncstorage.sql

    # MySQL (SYNC_DB=mysql, compose/sync-mysql.yml): the same, with the MySQL client
    docker compose up -d --wait tokenserver_db syncstorage_db
    docker compose exec -T tokenserver_db sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" mysql -u"$MYSQL_USER" "$MYSQL_DATABASE"' < tokenserver.sql
    docker compose exec -T syncstorage_db sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" mysql -u"$MYSQL_USER" "$MYSQL_DATABASE"' < syncstorage.sql

    # PostgreSQL (compose/sync-postgres.yml): as the Sync server's role
    # SYNC_POSTGRES_APP_USER, created first. Not as SYNC_POSTGRES_USER, the superuser: what the dump
    # brings (functions in a CHECK, an index, a view) would run with its rights (reference/database-users.md)
    docker compose up -d --wait postgres_db
    docker compose run --rm sync_role_init
    docker compose run --rm --no-deps -T --entrypoint sh sync_role_init -c 'PGPASSWORD="$POSTGRES_SYNC_PASSWORD" psql -h "$POSTGRES_SERVER" -U "$POSTGRES_SYNC_USER" -d "$POSTGRES_DATABASE" -v ON_ERROR_STOP=1' < syncserver.sql
    ```
    With Quadlets, MariaDB or MySQL: `systemctl --user start firefox-sync-tokenserver-db.service firefox-sync-syncstorage-db.service`, then, once `podman healthcheck run firefox-sync-tokenserver-db` and `firefox-sync-syncstorage-db` pass, the same with `podman exec -i firefox-sync-tokenserver-db sh -c '...' < tokenserver.sql` and `firefox-sync-syncstorage-db`, then start `firefox-sync-syncstorage.service`. PostgreSQL: `systemctl --user start firefox-sync-sync-role-init.service` (the database starts first), then `podman exec -i firefox-sync-postgres-db sh -c 'PGPASSWORD="$FFS_SYNC_PASSWORD" psql -h 127.0.0.1 -U "$FFS_SYNC_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1' < syncserver.sql`, then start `firefox-sync-syncstorage.service`.

    With [your own database server](databases.md#your-own-server), load them with `mariadb` or `psql` as in [Move an existing install](databases.md#move-an-existing-install) (not tested).
1. `docker compose up -d`.
1. Point your reverse proxy, or Firefox, to firefox-sync, as in [Start fresh first](#start-fresh-first). Firefox does not need to sign out: on its next token it is sent to the new node and finds its data there.

To Kubernetes: load the dumps into docker compose as above, then follow [From docker compose to Kubernetes](#from-docker-compose-to-kubernetes) (not tested).

### Checking the result

- `docker compose logs tokenserver_db_init` shows `Current users: N`, the number of accounts of the old server.
- The [admin UI](admin/README.md) (`COMPOSE_PROFILES=admin`) lists the accounts on its first page, with what each stores.
- In the tokenserver database every current account points to the new node:
    ```bash
    docker compose exec tokenserver_db sh -c 'MYSQL_PWD="$MARIADB_PASSWORD" mariadb -u"$MARIADB_USER" "$MARIADB_DATABASE" -e "SELECT u.uid, u.email, u.generation, u.keys_changed_at, u.client_state, n.node FROM users u JOIN nodes n ON n.id = u.nodeid WHERE u.replaced_at IS NULL"'
    # MySQL (SYNC_DB=mysql)
    docker compose exec tokenserver_db sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" mysql -u"$MYSQL_USER" "$MYSQL_DATABASE" -e "SELECT u.uid, u.email, u.generation, u.keys_changed_at, u.client_state, n.node FROM users u JOIN nodes n ON n.id = u.nodeid WHERE u.replaced_at IS NULL"'
    # PostgreSQL, as the Sync server's role (never SYNC_POSTGRES_USER on the Sync database, reference/database-users.md)
    docker compose run --rm --no-deps -T --entrypoint sh sync_role_init -c 'PGPASSWORD="$POSTGRES_SYNC_PASSWORD" psql -h "$POSTGRES_SERVER" -U "$POSTGRES_SYNC_USER" -d "$POSTGRES_DATABASE" -c "SELECT u.uid, u.email, u.generation, u.keys_changed_at, u.client_state, n.node FROM users u JOIN nodes n ON n.id = u.nodeid WHERE u.replaced_at IS NULL"'
    ```
- On desktop, `about:sync-log` shows syncs without errors, and a new profile signed in to the same account gets the bookmarks without any other device uploading them first.

Rollback: as in [Start fresh first](#start-fresh-first). What was synced to firefox-sync in the meantime is not on the old server, but the devices still have it and upload it again.

Tested: the steps above (docker compose; not your own database server) in every scenario of the sections below. The Quadlets: `tests/podman.sh` (`SYNC_DB=mysql`, `SYNC_DB=postgres` too) loads the dumps of a Quadlet install into a new one with the commands above, as written here. `tests/migrate.sh` runs the commands of this section and of "Checking the result" as written, with the admin UI on. Not tested with a real Firefox: the client is upstream's test client, signing in like Firefox does after a sign-in.

## From docker compose to Kubernetes

The same images and databases, moved to the [Helm chart](install/helm.md) with a dump and a restore.

With the self-hosted accounts, they move in the same steps: see [With the self-hosted accounts](#with-the-self-hosted-accounts) below for what each step adds.

1. On the compose host, with this release: the earlier one first needs [The earlier firefox-sync release](upgrading.md#the-earlier-firefox-sync-release), so that `.env` has the `SYNC_` names. Stop the Sync server and the admin UI, so that nothing changes after the dump, and make one with the [backup service](backups.md#the-backup-service). If it is off, turn it on for this: `COMPOSE_PROFILES=...,backup` and `docker compose up -d backup`.

    ```bash
    docker compose stop syncstorage ffs-admin
    docker compose exec backup sh /ffs-backup/backup.sh now
    docker compose cp backup:/backups ffs-backups && tar -C ffs-backups -czf ffs-backups.tar.gz . && rm -rf ffs-backups
    ```

    `docker compose cp` reads the backup service's volume whatever the compose project is called.

    The files are named after the databases of `.env` (`SYNC_TOKENSERVER_DB_NAME`, `SYNC_STORAGE_DB_NAME`, `SYNC_POSTGRES_NAME`, `ADMIN_DB_NAME`). The chart's restore reads `tokenserver`, `syncstorage` (PostgreSQL: `syncserver`) and `ffs_admin`: with other names, rename them in the copy.

    With the Quadlets: `systemctl --user stop firefox-sync-syncstorage.service firefox-sync-admin.service`, `systemctl --user start firefox-sync-backup.service`, then `podman volume export firefox-sync-backups | gzip > ffs-backups.tar.gz` (the restore reads a gzipped tar).
1. Create an [existingSecret](install/helm.md#existingsecret) with the secrets of `.env`, so that the Sync server keeps its `SYNC_MASTER_SECRET` and `SYNC_METRICS_HASH_SECRET`. New ones work too: Firefox gets a new token when the old one is refused. The chart's keys are not all named as in `.env`:

    ```bash
    v() { grep -m1 "^$1=" .env | cut -d= -f2-; }
    kubectl create secret generic ffs-secrets \
      --from-literal=SYNC_MASTER_SECRET="$(v SYNC_MASTER_SECRET)" --from-literal=METRICS_HASH_SECRET="$(v SYNC_METRICS_HASH_SECRET)" \
      --from-literal=ADMIN_PASSWORD="$(v ADMIN_PASSWORD)" --from-literal=ADMIN_DB_PASSWORD="$(v ADMIN_DB_PASSWORD)" \
      --from-literal=TOKENSERVER_DB_PASSWORD="$(v SYNC_TOKENSERVER_DB_PASSWORD)" --from-literal=STORAGE_DB_PASSWORD="$(v SYNC_STORAGE_DB_PASSWORD)"
    # PostgreSQL, instead of the last two: POSTGRES_PASSWORD from SYNC_POSTGRES_PASSWORD,
    # POSTGRES_SYNC_PASSWORD from SYNC_POSTGRES_APP_PASSWORD
    ```

    The bundled databases are new: their passwords need not be the old ones, but none may be empty. An `.env` without `ADMIN_DB_PASSWORD` or `SYNC_POSTGRES_APP_PASSWORD` needs one generated.
1. Write your values from `.env`. Each setting's value is in the Helm column of [Settings](reference/settings.md). The ones that matter here:
    - `SYNC_PUBLIC_URL` becomes `syncDomain`: keep it, so Firefox goes on with the same address;
    - `SYNC_DB` becomes `database.backend` (`postgres` with `compose/sync-postgres.yml` in `COMPOSE_FILE`);
    - `SYNC_POSTGRES_IMAGE` becomes `database.image.postgres`: the same major (its dump also loads into a newer one);
    - `backup.enabled: true` is needed for the restore;
    - and `existingSecret: ffs-secrets`, and the Ingress ([Install](install/helm.md#install)).
1. Run `helm install` with them, put the copy into the backups' PVC and restore it: [Restore on Kubernetes](backups.md#restore-on-kubernetes), "On a new cluster", from step 3 (the Secret is your `existingSecret`).
1. Point the host name to the Ingress (DNS, or your reverse proxy), then check as in [Checking the result](#checking-the-result): `kubectl logs deploy/ffs-firefox-sync-syncstorage -c db-init` shows `Current users: N`. Firefox needs nothing: the same address, the same accounts on the same node.

With your own database server (`SYNC_DB_CONTAINERS=0`) there is nothing to move: stop the stack (`docker compose down`), put the passwords of `.env` into the `existingSecret` as above, and point the chart to the same server and names ([With Helm](databases.md#with-helm)).

Rollback: `docker compose start syncstorage ffs-admin` (or the Quadlets) and the host name back to it, as long as nothing synced to Kubernetes in the meantime. What did is still on the devices, which upload it again.

### With the self-hosted accounts

The accounts keep their databases, their keys and their secrets, so Firefox stays signed in. Each step above adds:

1. **The dump.** Stop the accounts too, and dump them first, with `backup-fxa`. The copy of `/backups` then has both `sync/` and `accounts/`:

    ```bash
    docker compose stop syncstorage ffs-admin fxa-auth fxa-content fxa-profile
    docker compose exec backup-fxa sh /ffs-backup/backup.sh now
    ```

    Then the `backup.sh now` of `backup` and the copy, as above. The keys, from their volume, with the `tar` of [Copy them off the host](backups.md#copy-them-off-the-host): `fxa-keys.tar.gz`. The avatars of the `fxa-profile-images` volume are in no backup and don't move: the accounts show the default one until their owners upload theirs again.
1. **The secrets.** Put the keys into a Secret of their own, for `fxa.keys.existingSecret`:

    ```bash
    mkdir fxa-keys && tar -C fxa-keys -xzf fxa-keys.tar.gz
    kubectl create secret generic ffs-fxa-keys --from-file=fxa-keys/secret-key.json --from-file=fxa-keys/public-key.json \
      --from-file=fxa-keys/vapid-keys.json --from-file=fxa-keys/openid-key.json
    ```

    Add the accounts' secrets of `.env` to `ffs-secrets`, with the same names: `FXA_AUTH_SECRET`, `FXA_OAUTH_SECRET`, `FXA_PROFILE_SECRET`, `FXA_FLOW_ID_KEY`, `FXA_SESSION_TOKEN_HANDLE_KEY`, `FXA_CONTENT_SESSION_SECRET`, `FXA_MYSQL_PASSWORD`, `FXA_ADMIN_DB_PASSWORD` and `FXA_SMTP_PASS`. `FXA_REDIS_PASSWORD` is the chart's own: generate one. Every key: [existingSecret](install/helm.md#existingsecret).
1. **The values.** `fxa.enabled: true`, the same three URLs, `fxa.database.backend` as `FXA_DB`, `fxa.keys.existingSecret: ffs-fxa-keys`, the top-level `smtp.*` from `FXA_SMTP_*`, and `fxa.ingress` ([Self-hosted accounts](install/helm.md#self-hosted-accounts)). Each setting's value: [Settings](reference/settings.md#accounts).
1. **The restore.** [Restore on Kubernetes](backups.md#restore-on-kubernetes) restores the accounts' run first, from `/backups/accounts`. Use the run of the same night as the Sync one.
1. **The host names.** Point the four of them to the Ingress controller.

With your own accounts database server (`FXA_DB_CONTAINERS=0`), skip the dump and the restore of the accounts: point `fxa.database.external.*` to the same server ([With Helm](databases.md#with-helm)), with `FXA_MYSQL_POLICY_PASSWORD` in `ffs-secrets` too.

Tested: not as a migration. `tests/helm-fxa.sh` restores the chart's own accounts dump with the command of [Restore on Kubernetes](backups.md#restore-on-kubernetes), into a scratch database.

Tested: not as a migration. `tests/helm.sh e2e` restores the chart's own backups with the commands of [Restore](backups.md#restore) in pods of the backup's spec, as [Restore on Kubernetes](backups.md#restore-on-kubernetes) does. Those steps as written were run once on kind (MariaDB, PostgreSQL), not in CI.

## Mozilla's syncstorage-rs compose files

[mozilla-services/syncstorage-rs](https://github.com/mozilla-services/syncstorage-rs) ships [docker/docker-compose.one-shot.mysql.yaml](https://github.com/mozilla-services/syncstorage-rs/blob/master/docker/docker-compose.one-shot.mysql.yaml) and [docker-compose.one-shot.postgres.yaml](https://github.com/mozilla-services/syncstorage-rs/blob/master/docker/docker-compose.one-shot.postgres.yaml) (images `ghcr.io/mozilla-services/syncstorage-rs/syncserver-mysql` and `syncserver-postgres`). [docker-compose.mysql.yaml](https://github.com/mozilla-services/syncstorage-rs/blob/master/docker/docker-compose.mysql.yaml) and [docker-compose.postgres.yaml](https://github.com/mozilla-services/syncstorage-rs/blob/master/docker/docker-compose.postgres.yaml) are its end-to-end test setup, which some people run too.

| File | Database | Databases, user |
|---|---|---|
| `docker-compose.one-shot.mysql.yaml` | MySQL 8.0, containers `syncserver-tokenserver-db` and `syncserver-sync-db` | `tokenserver`, `syncstorage`, user `sync` / `sync` |
| `docker-compose.one-shot.postgres.yaml` | PostgreSQL 18, container `syncserver-postgres` | one database `syncserver`, user `sync` / `sync` (the same layout as firefox-sync) |
| `docker-compose.mysql.yaml` | MySQL 8.0, services `tokenserver-db` and `sync-db` | `tokenserver`, `syncstorage`, user `test` / `test` |
| `docker-compose.postgres.yaml` | PostgreSQL 18, services `tokenserver-db` and `sync-db` | `tokenserver`, `syncstorage`, user `test` / `test` |

Recommended: start fresh. The database path is supported. Its node is `SYNC_TOKENSERVER__INIT_NODE_URL` (`http://localhost:8000` by default); firefox-sync moves the accounts to its own.

The dumps, as the user of each database container's environment (`MYSQL_USER`, `MYSQL_PASSWORD`); with your own changes the database names may differ:

```bash
# MySQL, one-shot file
docker exec syncserver-tokenserver-db sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" mysqldump -u"$MYSQL_USER" --single-transaction --no-tablespaces --set-gtid-purged=OFF tokenserver' > tokenserver.sql
docker exec syncserver-sync-db sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" mysqldump -u"$MYSQL_USER" --single-transaction --no-tablespaces --set-gtid-purged=OFF syncstorage' > syncstorage.sql

# MySQL, the test setup (from the directory of your checkout)
dc="docker compose -f docker/docker-compose.mysql.yaml exec -T"
$dc tokenserver-db sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" mysqldump -u"$MYSQL_USER" --single-transaction --no-tablespaces --set-gtid-purged=OFF tokenserver' > tokenserver.sql
$dc sync-db sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" mysqldump -u"$MYSQL_USER" --single-transaction --no-tablespaces --set-gtid-purged=OFF syncstorage' > syncstorage.sql

# PostgreSQL, one-shot file: one database, like firefox-sync
docker exec syncserver-postgres pg_dump -U sync --no-owner --no-acl syncserver > syncserver.sql
```

PostgreSQL with two databases (the test setup) into firefox-sync's one: both have a `__diesel_schema_migrations` table, with different rows. Dump the tokenserver whole, the storage without that table, then its rows only, and load the three files in this order:

```bash
dc="docker compose -f docker/docker-compose.postgres.yaml exec -T"
$dc tokenserver-db pg_dump -U test --no-owner --no-acl tokenserver > syncserver.sql
$dc sync-db pg_dump -U test --no-owner --no-acl --exclude-table=__diesel_schema_migrations syncstorage > syncstorage.sql
$dc sync-db pg_dump -U test --data-only --table=__diesel_schema_migrations syncstorage > syncstorage-migrations.sql
# then, in firefox-sync, as in "Loading into firefox-sync" (sync_role_init first), with each file in turn:
# docker compose run --rm --no-deps -T --entrypoint sh sync_role_init -c 'PGPASSWORD="$POSTGRES_SYNC_PASSWORD" psql -h "$POSTGRES_SERVER" -U "$POSTGRES_SYNC_USER" -d "$POSTGRES_DATABASE" -v ON_ERROR_STOP=1' < <file>
```

Then [Loading into firefox-sync](#loading-into-firefox-sync). Firefox: the same `.../1.0/sync/1.5` path, so with the same host name nothing changes on the devices.

Tested: with the files of syncstorage-rs master (530d0f0) and the published 0.23.3 images. `tests/migrate.sh upstream-mysql` (one-shot MySQL to firefox-sync's MariaDB), `upstream-mysql-to-mysql` (the same to `SYNC_DB=mysql`), `upstream-mysql-testsetup` (`docker-compose.mysql.yaml`), `upstream-postgres` (one-shot PostgreSQL) and `upstream-postgres-2db` (`docker-compose.postgres.yaml`, the three files). The test files got a node URL, the tokenserver and `api.accounts.firefox.com` as email domain (see [Moving the database](#moving-the-database)).

## dan-r/syncstorage-rs-docker (and MASH)

[dan-r/syncstorage-rs-docker](https://github.com/dan-r/syncstorage-rs-docker) ([docker-compose.yaml](https://github.com/dan-r/syncstorage-rs-docker/blob/main/docker-compose.yaml), [entrypoint.sh](https://github.com/dan-r/syncstorage-rs-docker/blob/main/app/entrypoint.sh), [init.sql](https://github.com/dan-r/syncstorage-rs-docker/blob/main/data/initdb.d/init.sql)) runs:

- one `linuxserver/mariadb:10.6.13` container `firefox_mariadb`, with its data in `./data/config`;
- the databases `syncstorage_rs` and `tokenserver_rs`, user `sync`;
- syncstorage-rs built from a pinned commit of June 2025. Its entrypoint sets node 1 to `SYNC_URL`, and `SYNC_CAPACITY` limits the accounts.

The [MASH playbook](https://github.com/mother-of-all-self-hosting/mash-playbook) installs a fork of it ([ansible-role-syncstorage-rs-docker](https://github.com/mother-of-all-self-hosting/ansible-role-syncstorage-rs-docker)) with the same database names on its MySQL or MariaDB server.

Recommended: start fresh. The database path is supported (MariaDB 10.6 into MariaDB):

```bash
docker exec firefox_mariadb sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mariadb-dump -uroot --single-transaction --no-tablespaces tokenserver_rs' > tokenserver.sql
docker exec firefox_mariadb sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mariadb-dump -uroot --single-transaction --no-tablespaces syncstorage_rs' > syncstorage.sql
```

With MASH, run it against the server of `syncstorage_rs_docker_database_mysql_hostname`, with `mysqldump` if that is MySQL. Then [Loading into firefox-sync](#loading-into-firefox-sync), with `SYNC_MAX_USERS` at least the accounts you had (`SYNC_CAPACITY`). Firefox: `SYNC_URL/1.0/sync/1.5`, the same path as firefox-sync.

Tested: `tests/migrate.sh dan-r`, its layout rather than its image (which builds from source): `linuxserver/mariadb:10.6.13` as `firefox_mariadb` with its `init.sql`, syncstorage-rs 0.18.3 (its pinned commit is 0.18.3 and 8 commits without migrations), the services and nodes rows of its entrypoint, then the commands above. firefox-sync then adds the newer migrations. MASH: not tested.

## jeena/fxsync-docker

[jeena/fxsync-docker](https://github.com/jeena/fxsync-docker), archived on GitHub (moved to [git.jeena.net](https://git.jeena.net/jeena/fxsync-docker)), the inspiration of this project. Its [docker-compose.yaml](https://github.com/jeena/fxsync-docker/blob/main/docker-compose.yaml) runs `mozilla/syncstorage-rs:0.13.6` with two `mariadb:10.11` containers, `firefox_tokenserver_db` (`tokenserver`) and `firefox_syncstorage_db` (`syncstorage`), one user `MARIADB_USER` for both, and node 1 set to `DOMAIN`.

Recommended: start fresh. The database path is supported:

```bash
docker exec firefox_tokenserver_db sh -c 'MYSQL_PWD="$MARIADB_PASSWORD" mariadb-dump -u"$MARIADB_USER" --single-transaction --no-tablespaces tokenserver' > tokenserver.sql
docker exec firefox_syncstorage_db sh -c 'MYSQL_PWD="$MARIADB_PASSWORD" mariadb-dump -u"$MARIADB_USER" --single-transaction --no-tablespaces syncstorage' > syncstorage.sql
```

Then [Loading into firefox-sync](#loading-into-firefox-sync). syncstorage-rs 0.13.6 is old: firefox-sync runs the migrations added since. Firefox: the same path.

Tested: `tests/migrate.sh jeena`, its `docker-compose.yaml` as it is (`mozilla/syncstorage-rs:0.13.6`, `mariadb:10.11`, its init container), changed only for the test: the mock as accounts server, no published port.

## NixOS services.firefox-syncserver

The NixOS module ([firefox-syncserver.nix](https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/services/networking/firefox-syncserver.nix)) runs syncstorage-rs with one database for the tokenserver and the storage, `firefox_syncserver` by default (`services.firefox-syncserver.database.name`). It is on the local `services.mysql` server (MariaDB or MySQL, `database.type = "mysql"`) or on PostgreSQL (`database.type = "postgresql"`). With `singleNode.enable` it sets node 1 to `singleNode.url` and its capacity.

Recommended: start fresh. The database path is supported. On the NixOS host, as root:

```bash
# MariaDB: one database, split into firefox-sync's two (the migrations table goes into both)
sudo mariadb-dump --single-transaction --no-tablespaces firefox_syncserver users nodes services __diesel_schema_migrations > tokenserver.sql
sudo mariadb-dump --single-transaction --no-tablespaces firefox_syncserver bso collections user_collections batch_uploads batch_upload_items __diesel_schema_migrations > syncstorage.sql
# MySQL (services.mysql.package = pkgs.mysql80 or newer): the same with mysqldump instead of mariadb-dump

# PostgreSQL: one database, like firefox-sync
sudo -u postgres pg_dump --no-owner --no-acl firefox_syncserver > syncserver.sql
```

Then [Loading into firefox-sync](#loading-into-firefox-sync), and `services.firefox-syncserver.enable = false` once all devices synced. Firefox: the same path.

Tested: the module's layout in containers, not on NixOS: one database `firefox_syncserver` for syncstorage-rs 0.23.3. `tests/migrate.sh nixos-mysql` (MariaDB 11.4, whose image has `mariadb-dump` but no `mysqldump`; the table lists are all its tables) and `nixos-postgres` (PostgreSQL 17), the commands above run as root in the database container. MySQL with `mysqldump`: not tested.

## YunoHost syncserver-rs_ynh

[YunoHost-Apps/syncserver-rs_ynh](https://github.com/YunoHost-Apps/syncserver-rs_ynh) builds syncstorage-rs on the YunoHost server. Since `0.23.3~ynh9` it uses PostgreSQL with two databases, `syncserver_rs` (storage) and `syncserver_rs_tokenserver` ([config.toml](https://github.com/YunoHost-Apps/syncserver-rs_ynh/blob/master/conf/config.toml), [install](https://github.com/YunoHost-Apps/syncserver-rs_ynh/blob/master/scripts/install)). Before that it used MariaDB, and that upgrade did not copy the data: the clients uploaded it again. MariaDB databases of the same names left from then are old.

Recommended: start fresh. The database path is supported, into firefox-sync's PostgreSQL. As root on the YunoHost server:

```bash
sudo -u postgres pg_dump --no-owner --no-acl syncserver_rs_tokenserver > syncserver.sql
sudo -u postgres pg_dump --no-owner --no-acl --exclude-table=__diesel_schema_migrations syncserver_rs > syncstorage.sql
sudo -u postgres pg_dump --data-only --table=__diesel_schema_migrations syncserver_rs > syncstorage-migrations.sql
```

Load the three files in this order, as for [the two-database PostgreSQL](#mozillas-syncstorage-rs-compose-files), then [Loading into firefox-sync](#loading-into-firefox-sync). Firefox: YunoHost's address is `https://<domain><path>/1.0/sync/1.5`. With a path, change the setting on the devices, or rewrite the path in your reverse proxy. Remove the app once all devices synced.

Tested: the app's layout in containers, not on YunoHost: `tests/migrate.sh yunohost`, syncstorage-rs 0.23.3 on PostgreSQL 15 (bookworm's) with the two databases of one owner, the commands above run as `postgres` in the database container. The path rewrite and the MariaDB databases of before `0.23.3~ynh9`: not tested.

## The Python syncserver

[mozilla-services/syncserver](https://github.com/mozilla-services/syncserver), archived by Mozilla in 2023 and replaced by syncstorage-rs, and the images built on it: [crazy-max/docker-firefox-syncserver](https://github.com/crazy-max/docker-firefox-syncserver) (archived), [snw35/ffsync](https://github.com/snw35/ffsync), `mozilla/syncserver`. It keeps the tokenserver and the storage in one SQLAlchemy database (`syncserver.sqluri`: SQLite `syncserver.db` by default, or MySQL or PostgreSQL) with its own schema, which syncstorage-rs does not read.

Recommended: start fresh only. Its address is `https://<host>/token/1.0/sync/1.5`. Either change the setting on the devices to firefox-sync's `.../1.0/sync/1.5`, or keep the host name and have your reverse proxy send `/token/` to firefox-sync without the prefix:

```nginx
location /token/ { proxy_pass http://127.0.0.1:5000/; }
```

Tested: no.

## jackyzy823/fxa-selfhosting

[jackyzy823/fxa-selfhosting](https://github.com/jackyzy823/fxa-selfhosting) runs Mozilla accounts and the Python syncserver, from [docker-compose.tmpl.yml](https://github.com/jackyzy823/fxa-selfhosting/blob/master/docker-compose.tmpl.yml) and your `config.yml` ([config.yml.sample](https://github.com/jackyzy823/fxa-selfhosting/blob/master/config.yml.sample)):

- one MySQL 8.4 container `mysqldb`, user `root` without a password, data in `<persistencepath>/mysql_data`: the accounts in `fxa`, `fxa_oauth`, `fxa_profile` and `pushbox` (created by Mozilla's `patcher.mjs`, like here), the Python syncserver in `sync`;
- `fxa_version` in `config.yml` (`v1.342.2` in the sample): the release of `mozilla/fxa-mono`;
- the keys, generated inside the `fxa-auth-server` container at every start when missing, in `/fxa/packages/fxa-auth-server/dist/packages/fxa-auth-server/config/`: `secret-key.json`, `public-key.json`, `vapid-keys.json`, `key.json` (and `newKey.json`, `oldKey.json` after a key rotation). There is no volume for them: a new container gets new keys;
- the avatars in `<persistencepath>/public`;
- the host names `<content>`, `<auth>`, `<oauth>`, `<profile>`, `<sync>` of `domain.name` (`www`, `api`, `oauth`, `profile`, `token` in the sample): the accounts API and OAuth on two host names (here one, `FXA_AUTH_URL`), and Sync at `https://token.<domain>/token/1.0/sync/1.5`.

The accounts must move: an account is the record in `fxa.accounts`, and its Sync keys are derived from its password and that record. New accounts, even with the same email and password, have new keys, and every device would have to sign up again. The Sync data cannot move (Python syncserver): start fresh for it, after the accounts moved. None of this has been tested.

1. Check the versions. firefox-sync runs the newest accounts release it tested (`FXA_VERSION=fxa-mono-latest`). It must be the same as `fxa_version` or newer: the migrations only go forward. If yours is newer, pin `FXA_VERSION` to a release at least as new (`fxa-mono-<release>`, see [Self-hosted accounts](upgrading.md#self-hosted-accounts)).
1. Set up firefox-sync with self-hosted accounts on MySQL ([Set up](accounts.md#set-up)), but don't start it. Then in `.env`:
    - keep the old public URLs: `FXA_CONTENT_URL=https://<content>.<domain>`, `FXA_AUTH_URL=https://<auth>.<domain>`, `FXA_PROFILE_URL=https://<profile>.<domain>`, `FXA_EMAIL_DOMAIN=<auth>.<domain>`;
    - set `FXA_OAUTH_SECRET` and `FXA_AUTH_SECRET` to `secrets.authsecret`, and `FXA_PROFILE_SECRET` to `secrets.profileserver_authsecret_bearertoken` of `config.yml`. That may not be needed, but it is the safe side. If they are still the sample values, use new ones and expect to sign in again everywhere;
    - `SYNC_PUBLIC_URL` can be `https://<sync>.<domain>`.
1. On the old server, stop everything but the database, dump the accounts and copy the keys:
    ```bash
    docker compose stop && docker compose start mysqldb
    docker compose exec -T mysqldb mysqldump -uroot --single-transaction --set-gtid-purged=OFF --routines --triggers \
      --databases fxa fxa_oauth fxa_profile pushbox > fxa.sql
    mkdir old-keys
    for f in secret-key.json public-key.json vapid-keys.json key.json newKey.json oldKey.json; do
      docker compose cp fxa-auth-server:/fxa/packages/fxa-auth-server/dist/packages/fxa-auth-server/config/$f old-keys/
    done   # newKey.json and oldKey.json are often missing; without the old container, skip this
    ```
1. In firefox-sync, load the dump into the new, empty `fxa-db`, then the keys into the `fxa-keys` volume and the avatars, all before the accounts start:
    ```bash
    docker compose up -d --wait fxa-db
    docker compose exec -T fxa-db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot' < fxa.sql
    docker compose run --rm --no-deps -v "$PWD/old-keys:/old:ro" fxa-keys-owner sh -c '
      cp /old/secret-key.json /old/public-key.json /old/vapid-keys.json /fxa-keys/ &&
      cp /old/key.json /fxa-keys/openid-key.json &&
      { [ ! -f /old/newKey.json ] || cp /old/newKey.json /fxa-keys/openid-newKey.json; } &&
      { [ ! -f /old/oldKey.json ] || cp /old/oldKey.json /fxa-keys/openid-oldKey.json; } &&
      chown 10001:10001 /fxa-keys/*.json'
    docker compose run --rm --no-deps --user root -v /path/to/old/public:/old:ro fxa-profile-worker sh -c '
      cp -a /old/. /fxa/packages/fxa-profile-server/var/public/ && chown -R 10001:10001 /fxa/packages/fxa-profile-server/var/public'
    docker compose up -d
    ```
    The names come from [compose/fxa.yml](/compose/fxa.yml) (`SECRET_KEY_FILE`, `PUBLIC_KEY_FILE`, `VAPID_KEYS_FILE`, `FXA_OPENID_KEYFILE`, `FXA_OPENID_NEWKEYFILE`, `FXA_OPENID_OLDKEYFILE`). `fxa-migrations` then upgrades the schema, `fxa-policy` installs the [sign-up policy](accounts.md#who-can-sign-up), and the OAuth clients are registered again for `FXA_CONTENT_URL`. Leave out `sync` (the Python syncserver) and `ffs`. Loading into MariaDB (`FXA_DB=mariadb`) is not covered: keep MySQL.
1. Set up the reverse proxy (`proxy/` of `prepare_environment.sh`, [Reverse proxy](reverse-proxy.md#host-names-and-ports)): the content, auth and profile host names to the new ports, and also `<oauth>.<domain>` to `FXA_AUTH_EXPORT_PORT`, because Firefox keeps the OAuth address it read when it signed in. For Sync, either keep `https://<sync>.<domain>` with `/token/` sent to firefox-sync without the prefix (`location /token/ { proxy_pass http://127.0.0.1:5000/; }`) and the rest to firefox-sync as it is, or change the devices (next step).
1. Firefox: the accounts address stays the same ([Self-hosted accounts](firefox.md#self-hosted-accounts)).
    - With the `/token/` rewrite, the devices stay signed in and upload their data to the empty Sync server.
    - Without it, sign out on each device (keeping the data), restart Firefox and sign in again with the same email and password: Firefox reads the addresses again from the accounts server. On Android also set `Custom Sync server` to `SYNC_PUBLIC_URL/1.0/sync/1.5`.

    Start with the device that has the most data, as in [Start fresh first](#start-fresh-first).

Checking: the [admin UI](admin/README.md) lists the old accounts with their emails, `docker compose exec fxa-db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -e "SELECT COUNT(*) FROM fxa.accounts"'` gives their number, and an existing account signed in on a new profile gets the bookmarks of its other devices: its keys did not change.

Rollback: stop firefox-sync, start the old stack and point the reverse proxy back. Accounts created and passwords changed in the meantime are not on the old server.

Tested: no.

## Other setups

Helm charts (for example [holysoles/fx-syncstorage-chart](https://github.com/holysoles/fx-syncstorage-chart), MySQL), the Home Assistant add-on [Aghabeiki/firefox-sync-addon](https://github.com/Aghabeiki/firefox-sync-addon) (MariaDB) and other packagings of syncstorage-rs work the same way. Find the database type and the database names in their configuration (`SYNC_SYNCSTORAGE__DATABASE_URL` and `SYNC_TOKENSERVER__DATABASE_URL`, or `syncstorage.database_url` and `tokenserver.database_url`), then start fresh, or dump as in [Moving the database](#moving-the-database). One database for both is split as for [NixOS](#nixos-servicesfirefox-syncserver) (MySQL or MariaDB), or loaded as it is (PostgreSQL).

Tested: no.
