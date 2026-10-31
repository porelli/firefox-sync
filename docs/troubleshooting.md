# Troubleshooting

Symptoms and their fixes, by area. Each entry starts with what you see: an error text, a state, a log line. For how the stack is set up, start from [the docs index](README.md).

## Sync server

- **`docker compose up -d` fails, the Sync server stays down, with `ERROR: SYNC_X and X are both set ...`.** A setting has both its old and its new name, in `.env` or in the environment docker compose runs in. Run `./prepare_environment.sh --upgrade` for `.env`, or `unset` the old name in your shell. See [When both names are set](upgrading.md#when-both-names-are-set).
- **The init container refuses to start on an empty value, or on a `<REPLACE_WITH_...>` placeholder.** The public URL or a database password was never filled in. Set it in `.env` ([Settings](reference/settings.md#sync)).
- **The init container logs a warning listing old setting names, and the setup check "Old setting names (.env, environment)" fails.** Run `./prepare_environment.sh --upgrade`: see [Renamed settings](upgrading.md#renamed-settings).
- **`413 Request Entity Too Large` in `about:sync-log`.** The reverse proxy's limit of the request body is lower than the Sync server's: raise it, see [Request size](reverse-proxy.md#request-size). With the Helm chart, the Ingress annotation: see [Ingress](install/helm.md#ingress).
- **Anything else in `SYNC_MAX_USERS`** (empty, not a number) stops the init container, and with it the Sync server. The forms it takes: [Limits](limits.md#sync_max_users).
- **The account limit does not change after editing `.env`.** With `initial:N` the value is set only once; after that the admin UI manages it. See [Limits](limits.md#sync_max_users).

## Databases

- **`ERROR 1419 ... You do not have the SUPER privilege and binary logging is enabled`** (init container or `fxa-policy`). Set `log_bin_trust_function_creators=ON` on the server: see [Server requirements](databases.md#server-requirements).
- **`ERROR 2026 ... self-signed certificate in certificate chain`, then "Timeout waiting for database connection" in the init container.** Set `SYNC_DB_TLS_VERIFY=false` (Helm: `database.external.tlsVerify: false`).
- **"Timeout waiting for database connection", or the migrations never finish.** The containers cannot reach the server. Check the host (not `localhost`), the port, the server's listen address, the firewall and the users' host part. Test from the stack's network: `docker compose run --rm --no-deps --entrypoint mariadb tokenserver_db_init --host=... --user=... -p --skip-ssl-verify-server-cert -e 'SELECT 1'`. With the Helm chart: `kubectl logs deploy/<release>-firefox-sync-syncstorage -c wait-db` (the server answers) and `-c db-bootstrap` (the logins).
- **`the Sync databases on your server lack what this release needs`** (or the accounts' databases), in `db-bootstrap` or `fxa-db-bootstrap`. A user, grant or database of `database-setup.sql` is missing, or a login is refused: the error names the statement. **`setup migrations NNN not applied`**: this release needs a file your server has not run, its SQL follows in the log. See [When a release needs new users or grants](databases.md#when-a-release-needs-new-users-or-grants).
- **`setup migrations of ... were applied as another file than this release's`**, in `db-bootstrap`. A file of `db/*/setup/` differs from the one that ran on your server: an edited checkout or image. Use this release's files; see [Setup migrations](databases.md#setup-migrations).
- **`Access denied` from PostgreSQL, or `no pg_hba.conf entry`.** Add a `host` line for the containers' addresses: see [Server requirements](databases.md#server-requirements).
- **A MariaDB or MySQL container does not start, with `keep-major.sh: this database is MySQL 8, the image is MySQL 9`** (or MariaDB). Its image setting (`SYNC_MARIADB_IMAGE`, `SYNC_MYSQL_IMAGE`, `FXA_MARIADB_IMAGE` or `FXA_MYSQL_IMAGE`) is not set, and its `lts` default is another major than the data. `./prepare_environment.sh --upgrade` pins it ([The database majors of an install from before](upgrading.md#the-database-majors-of-an-install-from-before)). To move the data to the new major instead: [MySQL 8 to 9](upgrading.md#mysql-8-to-9).
- **`Plugin 'mysql_native_password' is not loaded`** (MySQL 9, also for `root`). A user is still on `mysql_native_password`: for example an install from before moved to `mysql:lts` without step 2 of [MySQL 8 to 9](upgrading.md#mysql-8-to-9). Back on `FXA_MYSQL_IMAGE=mysql:8` the data no longer opens, because MySQL 9 upgraded it. Either restore the backup of that procedure ([Restore](backups.md#restore)), or start MySQL 9 once with `--skip-grant-tables`, run `FLUSH PRIVILEGES` and the `ALTER USER` of step 2.
- **The PostgreSQL container does not start, with `keep-major.sh: this database is PostgreSQL 18 ... Not started.`** The image is another major than the data: `SYNC_POSTGRES_IMAGE` is unset and `postgres:latest` moved on, or the pin changed. Set it to the major the data has (the message names it): see [PostgreSQL](upgrading.md#postgresql).
- **The setup check of the event log fails, and the admin UI's log says the event log is in the tokenserver database.** An install from before `ADMIN_DB_PASSWORD`: see [The admin UI's own database](upgrading.md#the-admin-uis-own-database).

## Self-hosted accounts

- **`ER_NOT_SUPPORTED_AUTH_MODE` from `fxa-migrations` or `fxa-auth`.** The accounts image has no [mozilla/fxa#21554](https://github.com/mozilla/fxa/pull/21554) (Mozilla's images, or ours from before). Then `FXA_MYSQL_USER` must use `mysql_native_password`, on MySQL 8.4 with `mysql_native_password=ON` (`fxa-db`: `FXA_MYSQL_IMAGE=mysql:8` with `FXA_MYSQL_ARGS`). Use our current images for MySQL 9: see [MySQL or MariaDB](accounts.md#mysql-or-mariadb).
- **`ER_CANT_DROP_FIELD_OR_KEY: Can't DROP FOREIGN KEY ..._ibfk_1` from `fxa-migrations`.** The server is MariaDB 12 and the accounts image does not have [mozilla/fxa#21494](https://github.com/mozilla/fxa/pull/21494) (Mozilla's images, or ours from before). Use our current images, or MariaDB 11.4 to 11.8 on a new database: see [MariaDB 12](accounts.md#mariadb-12).
- **`docker compose up -d` stops with an error after an upgrade.** `fxa-migrations` failed: `docker compose logs fxa-migrations` says why. To go back to the older release, restore the backup: see [Self-hosted accounts](upgrading.md#self-hosted-accounts).
- **The accounts services stay `(health: starting)`.** They can take a few minutes after a start or an upgrade.
- **A new release runs on the old schema with Quadlets.** `podman auto-update` replaced the accounts services without running the migrations: see [Quadlets](upgrading.md#quadlets).
- **Firefox refuses to sign in to your accounts server.** The release is too old for that Firefox (for example Firefox 154 needs a recent one, because it switched to Bearer tokens). Upgrade: see [Self-hosted accounts](upgrading.md#self-hosted-accounts).

## Backups

- **The `backup` or `backup-fxa` container is `unhealthy`.** Its loop stopped, its last run failed, or the last good run is more than 25 hours old. `docker compose logs backup` says which. See [Check that it runs](backups.md#check-that-it-runs).
- **A run failed with "another backup run ... was still going on".** A run waits for the one going on at most an hour, then fails. Check what holds the lock: a run that was killed has its lock taken over by the next run.
- **A restore loaded nothing, but did not fail.** Without `gunzip -t` a missing run (mistyped, or pruned by `BACKUP_KEEP`) gives the client an empty input, which it takes as a success. Use the commands of [Restore](backups.md#restore): they check the file first.
- **The restore of `ffs` fails on a `DEFINER`.** Restore the accounts as the user that made the dumps (`FXA_MYSQL_USER`): see [Restore](backups.md#restore).

## Podman

- **A setting changed in `.env` has no effect.** The installed units hold their own copy of the values: change it there, see [Change a setting](install/podman.md#change-a-setting).
- **`prepare_environment.sh` stops with `ERROR: <unit> needs <NAME>, which is not set in .env`.** A unit has a `%NAME%` placeholder the script has no value for: the units of `config/quadlet/` and the script come from different releases. Use the files of one release.
- **A one-shot unit does not run again** (the migrations, the init container, the sign-up policy). They stay "active" after their first run. Stop them along with the units that need them, as in [Quadlets](upgrading.md#quadlets).
- **A unit points at `config/database/admin-user.sh`, which is gone.** Units rendered before the release that added `db/`: run `./prepare_environment.sh --upgrade` ([Files that moved](upgrading.md#files-that-moved)).
- **The Sync server's state, logs and health checks.** See [Check the units](install/podman.md#check-the-units).
- **MySQL containers that cannot find `/etc/my.cnf` or their error messages, and that Podman cannot stop (`given PID did not die within timeout`), on an Ubuntu host with `mysql-server` installed.** The host's AppArmor profile for `/usr/sbin/mysqld` confines the `mysqld` of the `mysql` image in rootless Podman's containers too, as in [Kubernetes](#kubernetes): disable that profile as said there, or use MariaDB (the default) or PostgreSQL.
- **`rootless netns: kill network process: permission denied` on Ubuntu 26.04.** Ubuntu's AppArmor profile of `pasta` refuses the signal Podman sends it when the last container of its bridge networks goes ([Ubuntu bug 2154379](https://bugs.launchpad.net/bugs/2154379)): `docker compose up` on the Podman socket cannot remove the containers it recreates. Until Ubuntu fixes it, let `pasta` receive that signal, as CI does ([pasta-apparmor.sh](/.github/scripts/pasta-apparmor.sh)), and again after an update of the `passt` package puts the profile back:

    ```bash
    sudo sed -i 's|^\(\s*include <abstractions/pasta>\)$|\1\n  signal (receive) set=(term) peer=podman,|' /etc/apparmor.d/usr.bin.pasta
    sudo apparmor_parser -r /etc/apparmor.d/usr.bin.pasta
    ```

## Kubernetes

- **The Sync server's pod stays in `Init:` (`Init:Error`, `Init:CrashLoopBackOff`).** Read the logs of its init containers, in their order: `kubectl logs deploy/ffs-firefox-sync-syncstorage -c wait-db` (the database servers answer), `-c db-bootstrap` (your own server: its users and grants, a refused password stops it here), `-c sync-role` (PostgreSQL), `-c migrate` (a refused password of the bundled servers), `-c db-init` (`maxUsers`). A database server: `kubectl logs sts/ffs-firefox-sync-tokenserver-db` and `sts/ffs-firefox-sync-storage-db` (MariaDB, MySQL), `sts/ffs-firefox-sync-postgres` (PostgreSQL).
- **The accounts' auth pod stays in `Init:`.** Read its init containers' logs in their order: `kubectl logs deploy/ffs-firefox-sync-fxa-auth -c keys-copy` (with `fxa.keys.existingSecret`), `-c wait-db`, `-c db-bootstrap` (your own server: its users and grants), `-c migrations` (a refused password, or the database image of [MySQL 9](accounts.md#mysql-9)), `-c policy`, `-c wait-redis`. The content and profile pods wait for it in `wait-accounts` and `wait-auth`.
- **`CreateContainerConfigError`.** A key is missing from your `existingSecret`: `kubectl describe pod` names it. See [existingSecret](install/helm.md#existingsecret).
- **`helm install` fails with `firefox-sync: ...` before anything starts.** The values are refused: a release name too long, `database.bundled=false` without `database.external.host` or `existingSecret`, the admin UI's Ingress on the Sync server's host... The message says what to set.
- **`helm upgrade` fails with `StatefulSet.apps ... is invalid: spec: Forbidden: updates to statefulset spec`.** `database.persistence.*` changed, which Kubernetes never changes. The chart refuses that change first, unless it cannot read the cluster (`helm template`, a GitOps render). See [Volumes](install/helm.md#volumes).
- **`413 Request Entity Too Large` in `about:sync-log`.** The body size of the Ingress: see [Ingress](install/helm.md#ingress).
- **A node keeps an old `latest` image.** With `image.pullPolicy: IfNotPresent` it does not pull a newer one: see [Helm](upgrading.md#helm).
- **The bundled MySQL in `CrashLoopBackOff` on kind or k3s, on an Ubuntu host with `mysql-server` installed.** The host's AppArmor profile for `/usr/sbin/mysqld` also confines the `mysqld` of the `mysql` image, in pods that run unconfined. It denies `/etc/my.cnf`, `/usr/share/mysql-8.4` and the init file of the admin UI's users: the first start aborts half-way, and every next one finds no `mysql.user`. Disable that profile (the host's own MySQL then runs unconfined too), then delete the PVC of the half-made database:

    ```bash
    sudo ln -s /etc/apparmor.d/usr.sbin.mysqld /etc/apparmor.d/disable/ && sudo apparmor_parser -R /etc/apparmor.d/usr.sbin.mysqld
    ```

    Or use MariaDB (the default) or PostgreSQL. Docker's containers are not affected: they run in `docker-default`.
- **`helm upgrade` fails with `firefox-sync: database.image.<backend> is ... but the bundled database ... runs ...`.** The new image would move the data to another major: see [Database majors](upgrading.md#database-majors).

## Admin UI

- **A setup check fails.** Each check says what is wrong and what to do: see [Setup checks](admin/monitoring.md#setup-checks).
- **The admin UI does not start, and says `ffs_admin_ui` cannot create its tables.** Its grant on `ffs_admin` is missing on your own server: run the new `database-setup.sql` there ([The admin UI's own database](upgrading.md#the-admin-uis-own-database)).
- **With Quadlets on your own server, the admin UI does not start after an upgrade.** Its unit has only `ADMIN_DB_PASSWORD`: create its users first ([With Quadlets](upgrading.md#with-quadlets)).
- **Max users edits, slot resets or account deletions fail with a missing procedure.** An older init image runs with the newer admin UI: see [Rollback](upgrading.md#rollback).
