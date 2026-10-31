# Databases

This page is for choosing the database of the Sync server and of the self-hosted accounts, and for running them on a server you already have. It holds the only table of supported versions. Read your install page first: [docker compose](install/compose.md), [Podman](install/podman.md) or [Helm](install/helm.md).

## Choose a backend

By default the stack starts its own database containers. You choose the server software once, before the first start.

| Component | Backend | How to choose it |
|---|---|---|
| Sync server | MariaDB (the default) | nothing to do |
| Sync server | MySQL | [MySQL instead of MariaDB](#mysql-instead-of-mariadb) |
| Sync server | PostgreSQL | [PostgreSQL](#postgresql) |
| Self-hosted accounts | MySQL (the default, what Mozilla runs) | nothing to do |
| Self-hosted accounts | MariaDB | [MySQL or MariaDB](accounts.md#mysql-or-mariadb) |

Each backend has volumes of its own. Switching an existing install starts with empty databases and leaves the old data in the old volumes. Moving data between MariaDB and MySQL takes a dump and a reload, which is not tested here.

To use a server you already run instead of the containers, see [Your own server](#your-own-server).

## Supported versions

### Servers

"Tested" is what CI runs on every image before it is published. Which job runs which one: [the test matrix](development/testing.md#test-matrix).

| Component | Backend | Supported | Tested |
|---|---|---|---|
| Sync server | MariaDB | 10.10 and later | `mariadb:lts` (12 today) |
| Sync server | MySQL | 8.0 and later, 9 included | `mysql:lts` (9 today) and `mysql:8` (8.4) |
| Sync server | PostgreSQL | 11 and later | `postgres:latest` (18 today) |
| Accounts | MySQL | 8.4 and 9 | `mysql:lts` (9 today), and `mysql:8` (8.4) with `mysql_native_password` |
| Accounts | MariaDB | 11.4 and later | `mariadb:lts` (12 today) and `mariadb:11` (11.8) |
| Accounts | Redis (cache, no volume) | the image's | `redis:alpine` |

MySQL 8.0 reached its end of life in April 2026. It still works for the Sync server, but it is not tested here.

Some of these need an accounts image with [the upstream patches](reference/images.md#upstream-patches):

| Accounts database | Our accounts images | Mozilla's image, or ours built before the patch |
|---|---|---|
| MySQL 9 | yes | no: MySQL 9 has no `mysql_native_password`, the only method Mozilla's driver speaks |
| MySQL 8.4 with its default `caching_sha2_password` | yes | no |
| MySQL 8.4 with `mysql_native_password=ON`, the accounts' user on it | yes | yes |
| MariaDB 12 and later | yes | no: the migrations stop with `ER_CANT_DROP_FIELD_OR_KEY` |
| MariaDB 11.4 to 11.8 | yes | yes |

The patches are [mozilla/fxa#21554](https://github.com/mozilla/fxa/pull/21554) for MySQL ([MySQL 9](accounts.md#mysql-9)) and [mozilla/fxa#21494](https://github.com/mozilla/fxa/pull/21494) for MariaDB ([MariaDB 12](accounts.md#mariadb-12)). The Sync server's patches fix an upstream test and the order of tied nodes. They don't change which servers the Sync server supports.

### Default tags and pins

The defaults follow each database's long-term tag: `mariadb:lts` and `mysql:lts`. PostgreSQL has no such tag, so each install is pinned to the major `postgres:latest` had when it was set up. When `lts` moves, a server set to it upgrades the data at its first start on the new major, and there is no way back but a backup. With no image setting at all, the containers refuse data of another major instead.

Each setting, its default, the pins `prepare_environment.sh` writes, and how to move to a newer major: [Database majors](upgrading.md#database-majors). The images the stack builds on top of these (the init containers): [Images](reference/images.md#sync-server).

## MySQL instead of MariaDB

This is about the stack's database containers for Sync. The two Sync databases (`syncstorage_db`, `tokenserver_db`) can run on MySQL instead of MariaDB. MySQL is what upstream syncstorage-rs is developed and tested on. The Sync images (`syncstorage-rs-mysql`, `syncstorage-rs-mysql-init`) are the same for both.

To choose it:

- With `prepare_environment.sh`: answer `mysql` to the database backend question. It writes `SYNC_DB=mysql` and `SYNC_DB_TLS_VERIFY=false`, and puts [compose/sync-mysql.yml](/compose/sync-mysql.yml) in `COMPOSE_FILE`.
- By hand, in `.env`:

  ```ini
  SYNC_DB=mysql
  COMPOSE_FILE=compose/sync.yml:compose/sync-mysql.yml
  ```

  The other files as before ([The compose files](install/compose.md#the-compose-files)).
- With Quadlets, the units of [config/quadlet/sync-mysql/](/config/quadlet/sync-mysql) replace the two MariaDB units.
- With the Helm chart: `database.backend: mysql`.

What differs from MariaDB:

- MySQL has its own volumes: `syncstorage-db-mysql` and `tokenserver-db-mysql` (Quadlets: `firefox-sync-syncstorage-db-mysql` and `firefox-sync-tokenserver-db-mysql`). Going back to MariaDB finds MariaDB's volumes as you left them.
- MariaDB's dumps use its `uca1400` collations, which MySQL rejects. See [Move an existing install](#move-an-existing-install).
- No binary logging (`--disable-log-bin`), as in the MariaDB containers. No replica reads it, and MySQL would keep 30 days of every change.
- The users use MySQL's default `caching_sha2_password`.
- The init container's client connects over TLS without checking MySQL's self-signed certificate (`SYNC_DB_TLS_VERIFY=false`). Without it the init fails with `ERROR 2026`.
- The image is `SYNC_MYSQL_IMAGE`, see [Database majors](upgrading.md#database-majors).

To keep binary logs (a replica, point-in-time recovery), replace `--disable-log-bin` with `--log-bin-trust-function-creators=ON` in the `command` (Quadlets: `Exec=`). Without that flag the init container cannot create the max users procedure and trigger (`ERROR 1419`).

On kind or k3s on an Ubuntu host with `mysql-server` installed, see [Troubleshooting](troubleshooting.md#kubernetes) (AppArmor).

## PostgreSQL

The Sync server can run on PostgreSQL, with the `syncstorage-rs-postgres` images and [compose/sync-postgres.yml](/compose/sync-postgres.yml). `prepare_environment.sh` sets both when you answer `postgres` to the database backend question. The self-hosted accounts cannot use PostgreSQL.

With Quadlets, the units of [config/quadlet/sync-postgres/](/config/quadlet/sync-postgres) replace those of the Sync server, its migrations, its init container and the backups. They add `firefox-sync-postgres-db`, the one database, in its own volume `firefox-sync-postgres-db`, and `firefox-sync-sync-role-init`, which gives the Sync server its own role before the migrations, as compose's `sync_role_init`. The MariaDB units are not installed.

`SYNC_POSTGRES_IMAGE` pins the PostgreSQL major of each install, for `postgres_db` and the backups: see [PostgreSQL](upgrading.md#postgresql).

With your own server, `SYNC_POSTGRES_IMAGE` is only the client of the backups. `pg_dump` must be at least the server's major: set it to your server's major or a newer one. With Helm, the same goes for `database.image.postgres`.

## Your own server

You can use a MariaDB, MySQL or PostgreSQL server you already run instead of the stack's containers. Check its version in [Supported versions](#supported-versions).

What changes:

- `SYNC_DB_CONTAINERS=0` in `.env`, and `FXA_DB_CONTAINERS=0` for the accounts. Those containers are not started; everything else is the same. With Helm: `database.bundled: false`, see [With Helm](#with-helm).
- You create the databases and users once, as an administrator of your server. The stack needs no administrator account there, unless you [let it apply them](#let-the-stack-apply-them) itself.
- At every start, before the migrations, the stack checks that those users, grants and databases are there, and stops naming what is missing: see [When a release needs new users or grants](#when-a-release-needs-new-users-or-grants). The SQL is numbered, and your server keeps a record of what ran: see [Setup migrations](#setup-migrations).
- The migrations and the init container still run at every start, as those users. The stack creates and updates the tables, the max users trigger and the sign-up policy.
- The admin UI has a database and two users of its own on that server, out of the Sync server's reach. See [Database users](reference/database-users.md#the-admin-uis-own-database).
- Backups are yours: the backup service dumps the stack's containers only. Your backup job can record its runs for the admin UI, see [Backups](backups.md#your-own-database-server). The Helm chart's backups do run against your server, as its users.

Every setting, with its Helm value: [Settings](reference/settings.md#your-own-database-server).

### Server requirements

- **Reachable from the containers.** `localhost` and `127.0.0.1` are the container itself, not your host. Use a host name or an IPv4 address: `prepare_environment.sh` refuses an IPv6 address.
    - A server on the Docker host: the address of the Docker bridge (often `172.17.0.1`), with the server listening there. The containers connect from the stack's own network: allow its subnet (`docker network inspect firefox-sync_default`) in the firewall and in the users' host part. See [Docker's networking docs](https://docs.docker.com/engine/network/).
    - With Podman: `host.containers.internal`, the host's main address, not `127.0.0.1`. The server must listen there and accept connections from that address. See [Podman's networking docs](https://docs.podman.io/en/latest/markdown/podman-network.1.html).
    - A server elsewhere: its host name or address.
    - Kubernetes: a host name or IPv4 address the pods resolve and reach. A Service of type `ExternalName` works too. Allow the pod network, or the nodes' addresses if the cluster masquerades outgoing traffic.
- **Plain connections, on a trusted network only.** The Sync server and the accounts cannot use TLS to their database. Keep the database on the same host, or on a private network or VPN you trust.
    - PostgreSQL: `host` lines (not `hostssl`) in `pg_hba.conf` for these users, with `scram-sha-256`. For example: `host syncserver syncserver 172.16.0.0/12 scram-sha-256`.
    - MariaDB and MySQL: `require_secure_transport=OFF`. This setting is server-wide. If other applications on that server need TLS, give this stack a server or instance of its own ([MySQL's docs](https://dev.mysql.com/doc/refman/8.4/en/using-encrypted-connections.html)).
- **MariaDB and MySQL with binary logging** (the default on MySQL): `log_bin_trust_function_creators=ON`. Without it the users cannot create the max users trigger or the sign-up policy's function and trigger (`ERROR 1419`). On MySQL:

  ```sql
  SET PERSIST log_bin_trust_function_creators = ON;
  ```

  On MariaDB, run this and set the same in `my.cnf`:

  ```sql
  SET GLOBAL log_bin_trust_function_creators = 1;
  ```

  Granting `SUPER` instead works too, but is not recommended.
- **MariaDB and MySQL:** `explicit_defaults_for_timestamp=ON`, the default since MySQL 8.0 and MariaDB 10.10.
- **The accounts on MySQL with an image without mozilla/fxa#21554:** MySQL 8.4 started with `mysql_native_password=ON`, and the accounts' user created with it. `prepare_environment.sh` writes the SQL that way for such an image. With our images nothing is needed. MariaDB needs nothing either.

### Create the databases and users

The SQL is in [db/mysql/setup/](/db/mysql/setup) (MariaDB and MySQL) and [db/postgres/setup/](/db/postgres/setup), numbered files with `@NAME@` placeholders: the [setup migrations](#setup-migrations). What each user gets, and why: [Database users](reference/database-users.md).

1. Run `./prepare_environment.sh` and answer `y` to "Use an existing database server instead of starting one?". For the accounts, answer `y` to the same question about them too.

   It fills in the placeholders with the names and generated passwords of `.env`, and writes `database-setup.sql` (and `database-setup-fxa.sql` for the accounts), readable by you only: every setup migration, then the `INSERT`s that record them on your server.
1. Optional: replace `'%'` in every line of the file with your containers' network, for example `'172.16.0.0/255.240.0.0'`. With `'%'` the users connect from any address, and the passwords are the only check.
1. Run the file as an administrator of your server:

   ```bash
   mysql -h db.example.com -u root -p < database-setup.sql          # MySQL
   mariadb -h db.example.com -u root -p < database-setup.sql        # MariaDB (its client may not install a mysql command)
   psql -h db.example.com -U postgres -f database-setup.sql         # PostgreSQL
   mysql -h db.example.com -u root -p < database-setup-fxa.sql      # the accounts, MySQL
   mariadb -h db.example.com -u root -p < database-setup-fxa.sql    # the accounts, MariaDB
   ```

1. Delete the file: it holds the passwords.

A database of the stack's name that another role owns is not taken over: the PostgreSQL SQL stops there, before any change, and says so. Give it to the stack's role yourself if it is the stack's, or choose another name. It needs `psql` 10 or later (`\if`).

Rules for names and passwords:

- Passwords: only `A-Z a-z 0-9 . _ ~ -`, because they are part of the database URLs. The generated ones are letters and digits.
- The Sync users need a password. The init container refuses an empty one or a `<REPLACE_WITH_...>` placeholder, so a passwordless login (`trust` in `pg_hba.conf`) keeps the Sync server down.
- Names: `a-z`, `0-9` and `_`.

Running `prepare_environment.sh` again makes new passwords and new secrets for everything else (`SYNC_MASTER_SECRET`, the accounts' keys). The SQL sets the passwords of existing users again, so a new setup matches its new `.env`. For an install that already runs, don't: see [Move an existing install](#move-an-existing-install).

### Setup migrations

The SQL of your server is a folder of numbered files per scope, one change each, in the order they run:

| Scope | Files | What |
|---|---|---|
| `sync` | [db/mysql/setup/sync/](/db/mysql/setup/sync) (MariaDB, MySQL), [db/postgres/setup/sync/](/db/postgres/setup/sync) | the Sync databases and users, the admin UI's |
| `fxa` | [db/mysql/setup/fxa-mysql/](/db/mysql/setup/fxa-mysql), [db/mysql/setup/fxa-mariadb/](/db/mysql/setup/fxa-mariadb) | the accounts' users, the sign-up policy's, the admin UI's |
| `sync-bootstrap`, `fxa-bootstrap` | [db/mysql/setup/sync-bootstrap/](/db/mysql/setup/sync-bootstrap), [db/postgres/setup/sync-bootstrap/](/db/postgres/setup/sync-bootstrap), [db/mysql/setup/fxa-bootstrap/](/db/mysql/setup/fxa-bootstrap) | the [bootstrap account](#the-bootstrap-account), which you run |

Each file starts with a header: why it is there, which release brought it, and how to run it by hand. A file never changes once released: a later change is a new file with the next number. `tests/setup_migrations.sh` checks every file against its checksum in [db/setup-manifest](/db/setup-manifest), and that the released ones are still there as they were. The version of a server is the highest number it recorded; a release expects the highest number it ships.

#### The record of the setup migrations

Your server records each file that ran in a table `ffs_setup_migrations`: in the tokenserver database (`SYNC_TOKENSERVER_DB_NAME`), in PostgreSQL's Sync database (`SYNC_POSTGRES_NAME`, a table of its owner), in the accounts' `ffs`. One row per file: its scope, number, name, checksum, when it ran and how:

- `bootstrap`: `db-bootstrap` ran it as the [bootstrap account](#let-the-stack-apply-them);
- `manual`: you ran it, with the `INSERT`s of `database-setup.sql` or `db-setup.sh pending`;
- `baseline`: an install from before the setup migrations, whose server had all of it already;
- `containers`: the stack's own database containers, which create the same users themselves; the init container records the files.

Next to it, `ffs_setup_state` keeps the result of the last start (`ok`, `pending`, `drift`, `missing`, `error`), which the admin UI shows. Why there and not in the admin UI's own database: these databases exist in every install (the admin UI's is optional), the stack's own users can write them when no bootstrap account is set, and the init container records there with the database containers. The Sync server's user could change these rows. That grants nothing: the check of the end state below reads the server itself, never the record. At worst such a change stops a start.

At every start:

- Files the server has not recorded are pending. With the bootstrap account, `db-bootstrap` runs them in order and records each one. Without it, the start stops with `setup migrations NNN-MMM not applied`, their SQL with `<SETTING>` for the passwords, and the `INSERT`s that record them.
- Then it checks the end state of every file, as the stack's own users: each user signs in and has its grants, the databases exist (PostgreSQL: owned by the stack's roles, closed to the others). A grant revoked by hand is drift: the bootstrap runs the files again once and checks again; without it, the start stops naming the statements.
- Nothing recorded yet, an install from before the setup migrations: when the end state is there, every file is recorded as `baseline`. Otherwise the start stops with the list of what is missing.
- A recorded file whose checksum is not this release's file stops the start: an image or checkout with edited files.
- Recorded numbers above this release's (an older release on a newer setup): a warning, the start goes on.

One start at a time per server: the step takes a lock (`GET_LOCK`, `pg_advisory_lock`), so that replicas of the Helm chart wait for each other.

The admin UI shows the version of each scope next to the schema levels, with what this release expects and the drift, and alerts on a change: see [Versions and schema levels](admin/monitoring.md#setup-migrations).

### When a release needs new users or grants

At every start, before the migrations, a one-shot step checks your server against the [setup migrations](#setup-migrations) of this release: `db-bootstrap` for the Sync databases, `fxa-db-bootstrap` for the accounts. A release that needs a new user or grant ships a new file: until your server has it, the start stops there, before anything else runs, with its SQL:

```text
✗ ERROR: the Sync databases: setup migrations 002 not applied (your server has version 001, this release expects 002). Their SQL, to run as the server's administrator (the passwords as <SETTING>, those of .env):
    -- ==== setup migration 002-....sql (scope sync)
    ...
  Print it again: docker compose run --rm --no-deps db-bootstrap pending sync (--passwords: filled in); ...
```

A user or grant missing from what the files give (revoked by hand, a user dropped) stops it too, naming each statement:

```text
✗ ERROR: the Sync databases on your server lack what this release needs (setup migrations 001, version 001):
  - 'ffs_admin_sync' cannot sign in on db.example.com:3306 (ERROR 1045 (28000): Access denied ...): CREATE USER IF NOT EXISTS 'ffs_admin_sync'@'%' IDENTIFIED BY '<ADMIN_DB_PASSWORD>'; ALTER USER 'ffs_admin_sync'@'%' IDENTIFIED BY '<ADMIN_DB_PASSWORD>';
```

Read it with `docker compose logs db-bootstrap` (`fxa-db-bootstrap`), `journalctl --user -u firefox-sync-db-bootstrap` (`firefox-sync-fxa-db-bootstrap`) with the Quadlets, or `kubectl logs deploy/<release>-firefox-sync-syncstorage -c db-bootstrap` (the accounts: `deploy/<release>-firefox-sync-fxa-auth`). The admin UI's setup checks show its own users' grants too.

To fix it, either:

- Run the pending files alone. With docker compose, `docker compose run --rm --no-deps db-bootstrap pending sync --passwords > pending.sql` (`fxa-db-bootstrap pending fxa` for the accounts) prints their SQL with the passwords of `.env`, and the `INSERT`s that record them (`manual`); without `--passwords` they are `<SETTING>`. With the Quadlets and Helm the log above has them, the passwords to fill in from `.env` or your Secret. Run it as in [Create the databases and users](#create-the-databases-and-users), delete it, start the stack again.
- Or run all of them again: `./prepare_environment.sh --upgrade` writes `database-setup.sql` (and `database-setup-fxa.sql`) of this release again, with the names and passwords of `.env`, and keeps the one of before as `database-setup.sql.before-upgrade-<UTC time>`. Its statements can run again: they create what is missing and set the passwords, and the `INSERT`s record the files once. Helm: fill in the files of [db/mysql/setup/sync/](/db/mysql/setup/sync) or [db/postgres/setup/sync/](/db/postgres/setup/sync) of the new chart again, as in [With Helm](#with-helm).
- Or [let the stack apply them](#let-the-stack-apply-them).

#### Let the stack apply them

With an account that can create users, the same step runs the [setup migrations](#setup-migrations) your server lacks itself at every start, as that account, records them, then checks the end state, and runs them all again once if something is missing (drift). A release that needs more then needs nothing from you. If the SQL fails, the start stops there, with the server's error in the log.

- docker compose and the Quadlets: `SYNC_DB_BOOTSTRAP_USER` and `SYNC_DB_BOOTSTRAP_PASSWORD` in `.env` (`FXA_DB_BOOTSTRAP_USER` and `FXA_DB_BOOTSTRAP_PASSWORD` for the accounts). `prepare_environment.sh` asks "Let the stack apply database changes itself at start?", default no, and writes the account's SQL to `database-bootstrap.sql` (`database-bootstrap-fxa.sql`). `--upgrade` keeps your choice, and asks nothing.
- Helm: `database.external.bootstrap.user` (`fxa.database.external.bootstrap.user`), and its password in your `existingSecret` as `SYNC_DB_BOOTSTRAP_PASSWORD` (`FXA_DB_BOOTSTRAP_PASSWORD`). The SQL is filled in from the values and the Secret.

It runs the SQL as `prepare_environment.sh` writes it: users with the host part `'%'`, and both Sync databases on one server (with `SYNC_STORAGE_DB_HOST` on another server it refuses: run the SQL by hand there). For other host parts, run your edited file by hand instead: an account of a stack name on another host stops the bootstrap (below). One start at a time: replicas of the chart wait for the lock.

**The trade-off.** The stack then holds the password of an account that can create users. Its rights on databases are limited to the stack's own, but its rights on users are not:

- MariaDB: `CREATE USER` can also change, rename or drop any account of the server, `root` too. MariaDB has nothing that protects an account from it. Whoever gets this password can make themselves the server's administrator.
- MySQL 8.0.16 and later: the same, except for the accounts with `SYSTEM_USER`. `root` has it; give it to every administrator account of the server, so that the bootstrap account cannot change them.
- PostgreSQL 16 and later: `CREATEROLE` reaches only the roles it created, or was given `ADMIN OPTION` on. Before 16 it reaches every role but the superusers, also the predefined ones such as `pg_read_server_files`: close to a superuser.

So use it with a database server, or an instance, that the stack has to itself. Otherwise keep the default: the stack then holds no such password, and you run the SQL after an upgrade yourself.

What the stack does with that account, whatever it could do:

- It creates and changes the users of the SQL only, under the names of `.env`. It refuses a name of the server's own accounts (`root`, `mysql`, `postgres`...) and its own name as one of them.
- MariaDB and MySQL: a user of such a name that exists already must be the one of the SQL, `'name'@'%'`, alone of its name, and sign in there with the password of `.env` (`CURRENT_USER()` that account): otherwise it is someone else's, and the start stops without changing it. Another account of that name (`'name'@'10.%'`, or a role) stops it too, named: the bootstrap never creates `'name'@'%'` beside it, which would widen where that name signs in from. Before any change of a file, every user of the file is checked.
- PostgreSQL: a role of such a name is the stack's when the bootstrap account administers it (`ADMIN OPTION`: the roles it created, and those `database-bootstrap.sql` gives it), or when it owns the stack's database of its name. A sign-in proves nothing there (`pg_hba.conf` may trust it): a role it does not administer stops the start, untouched.
- It refuses an account that is an administrator, also through its roles (a `SET ROLE` away): on MariaDB and MySQL one with more than `CREATE USER` on the whole server (`SYSTEM_USER`, `SUPER`, `ALL PRIVILEGES`...), a privilege on the `mysql` schema, or a proxy grant; on PostgreSQL a superuser, `BYPASSRLS`, `REPLICATION`, or a member of a superuser role, of `pg_execute_server_program`, `pg_read_server_files`, `pg_write_server_files`, `pg_read_all_data` or `pg_write_all_data`.

#### The bootstrap account

Create it once, as an administrator of your server, with the names of your databases. `prepare_environment.sh` fills these in from `.env` into `database-bootstrap.sql`; the files are the setup migrations of [db/mysql/setup/sync-bootstrap/](/db/mysql/setup/sync-bootstrap), [db/mysql/setup/fxa-bootstrap/](/db/mysql/setup/fxa-bootstrap) and [db/postgres/setup/sync-bootstrap/](/db/postgres/setup/sync-bootstrap). A release that needs more for that account brings a new file there, which you run: the account cannot give itself more.

MariaDB and MySQL, for Sync:

```sql
CREATE USER IF NOT EXISTS 'ffs_bootstrap'@'%' IDENTIFIED BY '<SYNC_DB_BOOTSTRAP_PASSWORD>';
ALTER USER 'ffs_bootstrap'@'%' IDENTIFIED BY '<SYNC_DB_BOOTSTRAP_PASSWORD>';
GRANT CREATE USER ON *.* TO 'ffs_bootstrap'@'%';
GRANT SELECT (User, Host) ON mysql.user TO 'ffs_bootstrap'@'%';
GRANT ALL PRIVILEGES ON `tokenserver`.* TO 'ffs_bootstrap'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON `syncstorage`.* TO 'ffs_bootstrap'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON `ffs_admin`.* TO 'ffs_bootstrap'@'%' WITH GRANT OPTION;
```

For the accounts, the same with `FXA_DB_BOOTSTRAP_PASSWORD`, and the databases `fxa`, `fxa_oauth`, `fxa_profile`, `pushbox` and `ffs` instead of the three above.

- `CREATE USER` creates the stack's users, and sets their passwords again (`ALTER USER`).
- `SELECT (User, Host) ON mysql.user`: which accounts of the stack's names exist, on which hosts. Nothing else of `mysql.user`, not the passwords' hashes.
- `ALL PRIVILEGES ... WITH GRANT OPTION` on each database creates it, and gives the stack's users their grants there: a user can only grant what it has, with `GRANT OPTION`. The SQL grants `CREATE ROUTINE`, `TRIGGER`, `EXECUTE` and more; `ALL PRIVILEGES` covers them, `EVENT` too.
- Nothing more. The procedures, triggers and events are created later by the init container and `fxa-policy`, as the stack's own users. The server still needs `log_bin_trust_function_creators=ON` for them with binary logging, see [Server requirements](#server-requirements); `SUPER` is not needed.

PostgreSQL, a role that is no superuser, run as a superuser:

```sql
CREATE ROLE ffs_bootstrap LOGIN;
ALTER ROLE ffs_bootstrap LOGIN CREATEROLE CREATEDB NOSUPERUSER NOREPLICATION NOBYPASSRLS PASSWORD '<SYNC_DB_BOOTSTRAP_PASSWORD>';
-- only for the roles that exist already (database-setup.sql run before by another role):
GRANT syncserver TO ffs_bootstrap WITH ADMIN OPTION;
GRANT ffs_admin_ui TO ffs_bootstrap WITH ADMIN OPTION;
GRANT ffs_admin_sync TO ffs_bootstrap WITH ADMIN OPTION;
```

- `CREATEROLE` creates the roles and sets their passwords; on PostgreSQL 16 and later only of the roles it created or administers, hence `ADMIN OPTION` on those that exist. The bootstrap takes only the roles it administers for the stack's (before 16 it gives itself `ADMIN OPTION` on those it creates), so give it `ADMIN OPTION` only on roles that are the stack's.
- `CREATEDB` creates the databases. The SQL makes the account a member of their owners, so that it may create them for those owners and close them to the other roles.

The stack's tests run the bootstrap with exactly these accounts, on MariaDB, MySQL and PostgreSQL ([Testing](development/testing.md)).

### With docker compose

1. Create the databases and users, and check the [server requirements](#server-requirements).
1. For a new install, run `./prepare_environment.sh`, or set the variables in `.env` by hand. For an install that already runs, see [Move an existing install](#move-an-existing-install).
1. Start the stack, with `COMPOSE_FILE` as before:

   ```bash
   docker compose up -d
   ```

   `deploy.replicas` of the database services is `0`, so compose starts the migrations without waiting for them.

`docker compose ps` then shows no database container. `db-bootstrap` (and `fxa-db-bootstrap`) runs first and exits: see [When a release needs new users or grants](#when-a-release-needs-new-users-or-grants). It mounts `db/` (the script and the setup migrations); `docker compose run --rm --no-deps db-bootstrap pending sync` prints what your server lacks. To go back, set `SYNC_DB_CONTAINERS=1` and the default server names.

### With Quadlets

With `SYNC_DB_CONTAINERS=0`, `prepare_environment.sh` installs no `firefox-sync-syncstorage-db` or `firefox-sync-tokenserver-db` unit (with PostgreSQL, no `firefox-sync-postgres-db`). With `FXA_DB_CONTAINERS=0`, no `firefox-sync-fxa-db` unit. It removes them from the other units' `After=` and `Requires=`. It installs `firefox-sync-db-bootstrap` (`firefox-sync-fxa-db-bootstrap`) instead, which the migrations require: see [When a release needs new users or grants](#when-a-release-needs-new-users-or-grants). It is a one-shot unit without `RemainAfterExit`: inactive once it ran, it runs again whenever the migrations start again (the stack started, `systemctl --user restart firefox-sync-syncstorage-migrate`), not only at boot.

The migrations retry until your server answers. A server on the same host is `host.containers.internal`, see [Server requirements](#server-requirements).

### With Helm

There is no `prepare_environment.sh` here: you fill in the SQL by hand.

1. Create the databases and users with the files of [db/mysql/setup/sync/](/db/mysql/setup/sync) or [db/postgres/setup/sync/](/db/postgres/setup/sync), in order (the first run of an install without their `INSERT`s is recorded as its baseline). Replace each `@NAME@` with the names of the values below and your passwords:
    - `@ADMIN_DATABASE@`, `@ADMIN_USER@` and `@ADMIN_SYNC_USER@` are `database.admin.name`, `.user` and `.syncUser`.
    - `@ADMIN_PASSWORD@` is `ADMIN_DB_PASSWORD`, not the admin UI's sign-in password.

   Check the [server requirements](#server-requirements).
1. Create a Secret with those passwords and the stack's secrets: see [existingSecret](install/helm.md#existingsecret) for its keys per backend. The chart refuses to render without it.
1. Set the values:

    ```yaml
    existingSecret: ffs-secrets
    database:
      backend: mysql            # mariadb, mysql or postgres: your server's
      bundled: false
      external:
        host: db.example.com
        port: ""                # empty: 3306, or 5432 for postgres
        # MariaDB, MySQL: the names of the SQL (these are the defaults); storageHost and
        # storagePort for a storage database on another server
        tokenserverDatabase: tokenserver
        tokenserverUser: tokenserver
        storageDatabase: syncstorage
        storageUser: syncstorage
        # PostgreSQL: postgresDatabase and postgresUser (syncserver, syncserver)
        tlsVerify: false
    ```

Each value and its `.env` name: [Settings](reference/settings.md#your-own-database-server).

`database.external.tlsVerify` (MariaDB, MySQL) says whether the init container and the backups check the server's certificate. It is `false` by default: MySQL's own certificate is self-signed, and a managed service's CA is not in the images (`ERROR 2026`). Set `true` only with a certificate from a CA the images trust, for that host name.

The chart then has no database pods, volumes or Secret of its own. The Sync server's pod waits for your server in its `wait-db` init container. Its `db-bootstrap` init container then checks the [setup migrations](#setup-migrations) (a ConfigMap of the chart's copies), or applies those your server lacks with `database.external.bootstrap.user` ([Let the stack apply them](#let-the-stack-apply-them)), and stops the pod while one is missing or a login is refused, with their SQL in its log:

```bash
kubectl logs deploy/<release>-firefox-sync-syncstorage -c db-bootstrap
```

The self-hosted accounts on your own MySQL or MariaDB server ([Self-hosted accounts](install/helm.md#self-hosted-accounts)):

1. Create their users with the files of [db/mysql/setup/fxa-mysql/](/db/mysql/setup/fxa-mysql) or [db/mysql/setup/fxa-mariadb/](/db/mysql/setup/fxa-mariadb). Replace `@FXA_USER@` and `@FXA_POLICY_USER@` with `fxa.database.external.user` (`fxa`) and `.policyUser` (`ffs_policy`), and the `@FXA_*PASSWORD@` with their passwords and the admin UI's. Check the [server requirements](#server-requirements), the accounts' on MySQL too.
1. Put those passwords into your `existingSecret`, as `FXA_MYSQL_PASSWORD`, `FXA_MYSQL_POLICY_PASSWORD` and `FXA_ADMIN_DB_PASSWORD`, with the accounts' other keys ([existingSecret](install/helm.md#existingsecret)).
1. Set the values:

    ```yaml
    fxa:
      database:
        backend: mysql          # or mariadb: your server's
        bundled: false
        external:
          host: fxadb.example.com
          port: ""              # empty: 3306
          user: fxa
          policyUser: ffs_policy   # empty: user, with its password
    ```

The chart then runs no accounts database. `fxa.database.image.*` is only the client of the backups and of the auth pod's `wait-db` and `db-bootstrap`. The auth pod waits for your server there, and stops in `db-bootstrap` while a user or grant of the SQL is missing or a login is refused: `kubectl logs deploy/<release>-firefox-sync-fxa-auth -c db-bootstrap`.

To move a chart install with bundled databases to your server: dump it as in [Restore on Kubernetes](backups.md#restore-on-kubernetes), load the dumps as in [Move an existing install](#move-an-existing-install), and use the passwords of the chart's Secret in your SQL and your `existingSecret`.

## Move an existing install

From the stack's containers to your own server, with docker compose. Moving from another Sync server instead: see [Migrating](migrating.md).

Not covered by the tests: check the result before you remove the old volumes. Moving a Quadlet install is not described here: `prepare_environment.sh` writes these values into its units.

1. Keep your `.env`, and don't run `prepare_environment.sh` again. It would replace `.env` with new secrets and passwords. You change `.env` by hand in step 6.
1. Stop the stack, without `-v` (that deletes the volumes with your data):

   ```bash
   docker compose down
   ```

1. Start only the database containers: `postgres_db` instead with PostgreSQL, and `fxa-db` too with the accounts.

   ```bash
   docker compose up -d tokenserver_db syncstorage_db
   ```

1. Dump the data:
    - MariaDB, the same for `syncstorage_db`:

      ```bash
      docker compose exec tokenserver_db sh -c 'MYSQL_PWD="$MARIADB_PASSWORD" mariadb-dump -u"$MARIADB_USER" --routines --triggers "$MARIADB_DATABASE"' > tokenserver.sql
      ```

      These dumps load into MariaDB 10.10 and later only: MySQL rejects their `uca1400` collations.
    - MySQL (`SYNC_DB=mysql`), the same for `syncstorage_db`. The stack's users have no `PROCESS` privilege, hence `--no-tablespaces`:

      ```bash
      docker compose exec tokenserver_db sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" mysqldump -u"$MYSQL_USER" --routines --triggers --no-tablespaces "$MYSQL_DATABASE"' > tokenserver.sql
      ```

    - PostgreSQL, as the Sync server's role, like the backups:

      ```bash
      docker compose run --rm --no-deps -T --entrypoint sh sync_role_init -c 'PGPASSWORD="$POSTGRES_SYNC_PASSWORD" pg_dump -h "$POSTGRES_SERVER" -U "$POSTGRES_SYNC_USER" --no-owner --no-acl "$POSTGRES_DATABASE"' > syncserver.sql
      ```

      An install from before `SYNC_POSTGRES_APP_USER` runs its Sync server as the superuser anyway:

      ```bash
      docker compose exec postgres_db sh -c 'pg_dump -U "$POSTGRES_USER" --no-owner --no-acl "$POSTGRES_DB"' > syncserver.sql
      ```

    - The admin UI's database (the event log, the audit trail), as its user. Use `mysqldump ... --no-tablespaces` with `SYNC_DB=mysql`:

      ```bash
      docker compose exec tokenserver_db sh -c 'MYSQL_PWD="$ADMIN_DB_PASSWORD" mariadb-dump -u"$ADMIN_DB_USER" --single-transaction "$ADMIN_DB_NAME"' > ffs_admin.sql
      docker compose exec postgres_db pg_dump -U ffs_admin_ui --no-owner --no-acl ffs_admin > ffs_admin.sql   # PostgreSQL
      ```

    - The accounts. Use `mariadb-dump` instead of `mysqldump` with `FXA_DB=mariadb`, and load it into the same kind of server (MySQL to MariaDB or back is not tested):

      ```bash
      docker compose exec fxa-db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysqldump -uroot --routines --triggers --databases fxa fxa_oauth fxa_profile pushbox ffs'  > fxa.sql
      ```

1. Create the databases and users on your server with the passwords already in your `.env`:
    1. Copy the files of [db/mysql/setup/sync/](/db/mysql/setup/sync), [db/postgres/setup/sync/](/db/postgres/setup/sync) or `db/mysql/setup/fxa-<FXA_DB>/`, in order (the record of the setup migrations comes with the dumps below: `ffs_setup_migrations`, how `containers`).
    1. Replace each `@NAME@` with its value from `.env`: `@SYNC_TOKENSERVER_PASSWORD@` is `SYNC_TOKENSERVER_DB_PASSWORD`, `@FXA_ADMIN_PASSWORD@` is `FXA_ADMIN_DB_PASSWORD`, and so on. Keep the database and user names of `.env`.
    1. For the accounts, add `FXA_MYSQL_USER`, `FXA_MYSQL_POLICY_USER` and `FXA_MYSQL_POLICY_PASSWORD` to `.env`: the containers used `root`.
    1. Run the SQL as in [Create the databases and users](#create-the-databases-and-users), then load the dumps:

       ```bash
       mariadb -h db.example.com -u root -p tokenserver < tokenserver.sql
       mariadb -h db.example.com -u root -p syncstorage < syncstorage.sql
       psql -h db.example.com -U syncserver -d syncserver -f syncserver.sql    # as the owner: its tables
       mariadb -h db.example.com -u ffs_admin_ui -p ffs_admin < ffs_admin.sql   # psql -U ffs_admin_ui -d ffs_admin -f ffs_admin.sql
       mysql -h db.example.com -u root -p < fxa.sql                             # mariadb with FXA_DB=mariadb
       ```

   The accounts' dump creates its databases itself. Its triggers, views and procedures name `root` as their definer. Before loading it, replace ``DEFINER=`root`@`%` `` with `FXA_MYSQL_POLICY_USER` for the `ffs` objects and the trigger on `fxa.accounts`, and with `FXA_MYSQL_USER` for Mozilla's procedures. Or let `fxa-policy` recreate its own objects at the next start.
1. In `.env`, set `SYNC_DB_CONTAINERS=0`, `SYNC_DB_TLS_VERIFY=false` and the `_HOST` and `_PORT` settings (`SYNC_TOKENSERVER_DB_HOST`, `SYNC_POSTGRES_HOST` and so on). For the accounts, also `FXA_DB_CONTAINERS=0`, `FXA_MYSQL_HOST`, `FXA_MYSQL_PORT` and the users of step 5.
1. Start the stack:

   ```bash
   docker compose up -d
   ```

The old volumes stay until you remove them, with `docker volume rm`, or `docker compose down -v` while `SYNC_DB_CONTAINERS=1`.

## Passwords in commands

The commands of these pages never put a password after `-p` or in a URL. The arguments of a process show in `ps` to every user of the host, and a command you type stays in your shell history. The stack's scripts, units and chart do the same.

- **Typed by hand:** `-p` with nothing after it, and the client asks for the password. `psql` asks by itself when the server wants one.
- **Inside a container of the stack**, whose environment holds the password: the client reads it from `MYSQL_PWD` (MariaDB, MySQL) or `PGPASSWORD`, set from that variable in `sh -c '...'`. The single quotes keep the host's shell from expanding it: only the container's `sh` reads the value.

    ```bash
    docker compose exec tokenserver_db sh -c 'MYSQL_PWD="$MARIADB_PASSWORD" mariadb -u"$MARIADB_USER" "$MARIADB_DATABASE"'
    ```

- **In a script on the host**, for your own server, such as a backup job: a file that only you can read. Give it to MariaDB's and MySQL's clients with `--defaults-extra-file`, which must be their first option:

    ```bash
    install -m 600 /dev/null "$HOME/.ffs-admin.cnf"   # then, with an editor, the two lines below
    ```

    ```ini
    [client]
    password=<the password>
    ```

    ```bash
    mariadb --defaults-extra-file="$HOME/.ffs-admin.cnf" -h db.example.com -u ffs_admin_ui ffs_admin -e 'SELECT 1'
    ```

    `psql` and `pg_dump` read `~/.pgpass` (mode 600, lines `host:port:database:user:password`) by themselves, or the file named by `PGPASSFILE`.

## Troubleshooting

Errors from the database, the init container and the accounts' migrations: see [Troubleshooting](troubleshooting.md#databases).
