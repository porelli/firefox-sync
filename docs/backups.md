# Backups

How to back up a firefox-sync install, copy the backups off the machine, and restore them on the same host or a new one. It covers docker compose, the Quadlets and the Helm chart. Set up the stack first: see [the docs index](README.md).

## What to keep

What a restore needs, from most to least important:

| What | Where | Why |
|---|---|---|
| `.env` | the stack's directory (Kubernetes: the chart's Secret or your `existingSecret`, and your values) | every password and secret (`SYNC_MASTER_SECRET`, the accounts' keys...). **Critical**: without it nothing restored works as before |
| the `fxa-keys` volume | self-hosted accounts | the keys the accounts service signs with. **Critical**: new keys sign every Firefox out |
| the accounts databases | `fxa`, `fxa_oauth`, `fxa_profile`, `pushbox`, `ffs` | the accounts, their devices, the sign-up policy. **Critical**: if they are lost, everybody creates a new account |
| the tokenserver database | `tokenserver` (or the PostgreSQL database) | which account syncs where, and max users. **Important**: without it every account starts over with empty storage, and Firefox uploads again |
| the admin UI's database | `ffs_admin` | the event log, the audit trail, the notes, the backup runs. If it is lost, the admin UI starts with an empty log |
| the storage database | `syncstorage` (or the PostgreSQL database) | the Sync data, encrypted by Firefox. **Rebuildable**: each Firefox uploads what it has |

`.env` and `fxa-keys` change rarely: copy them off the host once, and again after each change. The databases change every minute: that is what the backup service is for.

On Kubernetes, keep a copy of the chart's Secret with your values: the backups do not have it. The command is in [The Secret](install/helm.md#the-secret).

## The backup service

The backup service is optional. Every night it dumps each database into a volume of its own, keeps the newest runs and records each run for the admin UI.

| Method | Turn it on |
|---|---|
| docker compose | add `backup` to `COMPOSE_PROFILES` in `.env` (`COMPOSE_PROFILES=admin,backup`), then `docker compose up -d`. `prepare_environment.sh` adds it when you answer yes to "Enable nightly backups?" (`backups=yes` by [name](install/compose.md#answers-by-name)) |
| Quadlets | the units are installed, off unless you answered yes to that question: `systemctl --user enable --now firefox-sync-backup.timer` |
| Helm | `backup.enabled: true`, see [Kubernetes](#kubernetes) |

### What it does

- **When.** Every night at `BACKUP_TIME` (`03:00`, UTC). With compose, a backup container that starts after `BACKUP_TIME` and did not run that day runs at once. With Quadlets the timer catches up after a night the host was off.
- **Where.** `<scope>/<UTC time>/<database>.sql.gz` in the `backups` volume, with the scopes `sync/` and `accounts/`. The volume is `<project>_backups` with compose (for example `firefox-sync_backups`), `firefox-sync-backups` with Quadlets.
- **How many.** The newest `BACKUP_KEEP` runs (7) stay, older ones are deleted. A failed run leaves nothing and keeps the older copies.
- **Checks.** Each file must pass `gzip -t`, or the run fails. The files are readable by root only (0600).
- **As whom.** It runs in the images of the databases, already on the host, as the stack's own users: the tokenserver and storage users (with PostgreSQL the Sync server's role `SYNC_POSTGRES_APP_USER`), the admin UI's user for `ffs_admin.sql.gz`, and `FXA_MYSQL_USER` for the accounts.
- **One at a time.** A run started while another is going on waits for it, at most an hour, then fails. The lock is `.lock-<scope>` in the volume. The lock of a run that was killed is taken over by the next run (after a day when that run was in another container).
- **Retries.** A dump that fails because a table changed while it ran (MariaDB and MySQL error 1412) or was dropped after the dump listed it (error 1146, PostgreSQL's "relation does not exist"), for example as the admin UI moves its tables at an upgrade, is tried again once, 10 seconds later.

<details><summary>Why the dumps are made the way they are</summary>

- MariaDB: `mariadb-dump --single-transaction --routines --triggers`.
- PostgreSQL: `pg_dump --no-owner --no-privileges`. The roles a dump would name exist on a new server only after the init container ran, and it gives the grants again at every start. `ffs_admin` is also dumped with `--clean --if-exists`, so it restores over its tables.
- The accounts: `mysqldump` (`mariadb-dump` with `FXA_DB=mariadb`), with the events, and without the trigger of the sign-up policy. `fxa-policy` installs it again at every start, before the accounts service, so a copy restored elsewhere never puts it on the real `fxa.accounts`.

</details>

### Run one now

| Method | Command |
|---|---|
| docker compose | `docker compose exec backup sh /ffs-backup/backup.sh now`, and `backup-fxa` for the accounts |
| Quadlets | `systemctl --user start firefox-sync-backup.service` (it runs the accounts' backup first) |
| Helm | `kubectl create job --from=cronjob/ffs-firefox-sync-backup backup-now-$(date +%s)` |

### Check that it runs

Each run is a row of `ffs_backups` in the admin UI's database: when it started and finished, whether it worked, its size, where, and the error. The admin UI reads that table; it never sees the volume. It shows the runs in three places:

- the Health section of the overview, for example "Last backup of the Sync databases: 2026-10-13 03:00, 1.2 MB, ok", or the error and the last good run;
- [Needs attention](admin/monitoring.md#needs-attention), with an alert when a run fails or the last good one is older than 36 hours, and again when they work again;
- [Prometheus](admin/monitoring.md#prometheus): `ffs_backup_age_seconds{scope}` and `ffs_backup_last_ok{scope}`.

The rows are written as the admin UI's user. Without `ADMIN_DB_PASSWORD` (an install from before it) they go to the tokenserver database, as the tokenserver user. The accounts' runs are recorded by the Sync backup service, because the accounts' image has no PostgreSQL client: within a minute with compose, right after the run with Quadlets. The rows are kept for `ADMIN_AUDIT_RETENTION_DAYS`.

Without the admin UI:

- docker compose: `docker compose ps` shows the `backup` and `backup-fxa` containers as `unhealthy` when their loop stopped, their last run failed, or the last good run is more than 25 hours old. A run going on counts as healthy.
- Quadlets: the backups are one-shot units of the timer, without a health check. `systemctl --user status firefox-sync-backup.service` says how the last one ended.
- Helm: see [Kubernetes](#kubernetes).

## Kubernetes

With the Helm chart:

```yaml
backup:
  enabled: true
  schedule: "0 3 * * *"   # cron, UTC
  keep: 7
```

The CronJob `ffs-firefox-sync-backup` runs the same `backup.sh` in the database's image. It dumps the tokenserver, the storage and the admin UI's database into the PersistentVolumeClaim `ffs-firefox-sync-backups`, which `helm uninstall` keeps.

- `backup.schedule` replaces `BACKUP_TIME`. A daily `M H * * *` is also what the admin UI says ("every night at 03:00 UTC"). Any other schedule runs as given, but that text is then approximate. A schedule rarer than every 36 hours makes the alert of a too old backup fire between runs.
- `backup.keep` is `BACKUP_KEEP`.
- `backup.activeDeadlineSeconds` (82800, 23 hours): a run still going then is stopped and fails. One run at a time (`concurrencyPolicy: Forbid`): a hung dump would hold back every later one.
- With your own database server (`database.bundled: false`) it runs too, as the users of its SQL, next to the server's own backups.
- With the self-hosted accounts (`fxa.enabled`) on their bundled database (`fxa.database.bundled: true`), the same Job first dumps their five databases into `accounts/<UTC time>/`, as compose's `backup-fxa` does: in its init container `backup-accounts`, in the accounts database's image, as its `root`. With your own accounts server it dumps the Sync databases alone, as compose does: see [Your own database server](#your-own-database-server). A failed dump is recorded and alerted, and the Sync databases are dumped all the same. A dump that hangs instead holds back the Sync one, which starts only after it, until `backup.activeDeadlineSeconds` stops the whole run. Their signing keys are not in the backups: see [The signing keys](install/helm.md#the-signing-keys).

Without the admin UI:

```bash
kubectl get cronjob ffs-firefox-sync-backup -o jsonpath='{.status.lastSuccessfulTime}'   # the last run that worked
kubectl get jobs
kubectl logs job/<name>
```

## Copy them off the host

The volume is on the same disk as the databases: a dead disk takes both. Copy it elsewhere, for example every morning from cron:

```bash
# docker compose (the volume is named after the directory of the stack)
docker run --rm -v firefox-sync_backups:/backups:ro -v "$PWD":/out busybox tar -C /backups -czf /out/ffs-backups.tar.gz .
# Podman (Quadlets)
podman volume export firefox-sync-backups > ffs-backups.tar
# and once, after each change: .env and the accounts' keys
docker run --rm -v firefox-sync_fxa-keys:/keys:ro -v "$PWD":/out busybox tar -C /keys -czf /out/fxa-keys.tar.gz .
```

Then `scp` or `rsync` the files to another machine. The volume is named after the compose project: `COMPOSE_PROJECT_NAME` of `.env` (the directory of the checkout, [The compose files](install/compose.md#the-compose-files)), unless `-p` sets another. So it is `firefox-sync_backups` only in a directory called `firefox-sync`.

The dumps hold what the databases hold: emails, the event log, the accounts' password checks. Keep the copies as private as `.env`, and encrypted if they leave your own machines.

## Copy them off the cluster

The PVC is in the cluster, often on the same storage as the databases. Copy it elsewhere, for example every morning, with a pod that mounts it (the dumps are root's, 0600):

```bash
kubectl run ffs-backups --image=busybox --restart=Never --overrides='{"spec": {"containers": [{"name": "ffs-backups",
  "image": "busybox", "command": ["sleep", "3600"], "volumeMounts": [{"name": "backups", "mountPath": "/backups"}]}],
  "volumes": [{"name": "backups", "persistentVolumeClaim": {"claimName": "ffs-firefox-sync-backups"}}]}}'
kubectl wait --for=condition=Ready pod/ffs-backups
kubectl exec ffs-backups -- tar -C /backups -czf - . > ffs-backups.tar.gz
kubectl delete pod ffs-backups
```

The PVC is `ReadWriteOnce`: while a backup runs on another node, the pod waits for it. Keep the copy as private as the Secret: the dumps hold the event log and the accounts' ids.

## Your own database server

The backup service of compose and the Quadlets is for the stack's own database containers. On [your own server](databases.md#your-own-server), use the server's own backups: the accounts' user of the stack cannot read `ffs` there. The Helm chart's CronJob is the exception for the Sync databases: it also dumps them on your own server, see [Kubernetes](#kubernetes). Not the accounts': with your own accounts server it skips them, as compose does, so use the server's own backups for their five databases (`fxa`, `fxa_oauth`, `fxa_profile`, `pushbox` and `ffs`).

Back up the admin UI's database too: it holds the event log. To have the admin UI watch your backups, have your backup job record each run in that database, as its user (`ffs_admin_ui`; before `ADMIN_DB_PASSWORD`, the tokenserver database as the tokenserver user). The admin UI creates the table when it starts:

```sql
-- MariaDB and MySQL
CREATE TABLE IF NOT EXISTS ffs_backups (id BIGINT AUTO_INCREMENT PRIMARY KEY, scope VARCHAR(32) NOT NULL, started BIGINT NOT NULL,
  finished BIGINT NOT NULL, ok SMALLINT NOT NULL, bytes BIGINT NOT NULL, error VARCHAR(512) NOT NULL DEFAULT '', location VARCHAR(255) NOT NULL DEFAULT '',
  KEY ffs_backups_started (started));
-- PostgreSQL: the same columns, with id BIGSERIAL PRIMARY KEY and without the KEY line
```

`scope` is `sync` or `accounts`. The times are milliseconds since 1970. `ok` is 1 or 0, with the reason in `error`. `bytes` is the size. At the end of your job, for example:

```bash
mariadb --defaults-extra-file="$HOME/.ffs-admin.cnf" -h db.example.com -u ffs_admin_ui ffs_admin -e \
  "INSERT INTO ffs_backups (scope, started, finished, ok, bytes, location) VALUES ('sync', ${START}000, $(date +%s)000, 1, ${BYTES}, 'backup-host:/srv/ffs')"
```

`.ffs-admin.cnf` holds the password of `ffs_admin_ui`, in a file only the job's user can read: see [Passwords in commands](databases.md#passwords-in-commands).

## Restore

On Kubernetes, see [Restore on Kubernetes](#restore-on-kubernetes). With Quadlets, see [Restore with Quadlets](#restore-with-quadlets).

With docker compose, on the same host or a new one: you need the `.env` of the stack. With self-hosted accounts, also put the `fxa-keys` volume back first, with `tar -x` into it.

1. Stop the stack and start its databases alone, empty or not:
    1. Stop the stack with `docker compose down` (not `-v`).
    1. To start from empty databases, remove their volumes. A new host has none yet.

        | Backend | Command |
        |---|---|
        | MariaDB | `docker volume rm firefox-sync_tokenserver-db firefox-sync_syncstorage-db` |
        | `SYNC_DB=mysql` | `docker volume rm firefox-sync_tokenserver-db-mysql firefox-sync_syncstorage-db-mysql` |
        | PostgreSQL | `docker volume rm firefox-sync_postgres-db` |
        | self-hosted accounts, also | `docker volume rm firefox-sync_fxa-db` (`docker volume rm firefox-sync_fxa-db-mariadb` with `FXA_DB=mariadb`) |

        PostgreSQL's dump loads only into an empty database: with PostgreSQL, always remove `postgres-db`. The dumps of MariaDB and MySQL drop and create each table again, so they also load into the old databases.
    1. On a new host, put the copy of the backups volume back: `docker run --rm -v firefox-sync_backups:/backups -v "$PWD":/in busybox tar -C /backups -xzf /in/ffs-backups.tar.gz`. Compose then warns that it did not create that volume; it uses it all the same.
    1. Start the databases alone and wait until they answer: `docker compose up -d --wait tokenserver_db syncstorage_db`. With PostgreSQL: `docker compose up -d --wait postgres_db`. With self-hosted accounts, add `fxa-db` (the service has that name with `FXA_DB=mariadb` too).
1. Pick a run: `docker compose run --rm --no-deps --entrypoint ls backup /backups/sync` (and `/backups/accounts` with self-hosted accounts). Each command below checks its file with `gunzip -t` first. Without that check, a wrong run (or one already pruned by `BACKUP_KEEP`) gives the client an empty input, which it takes as a success.
1. The accounts, as the user that made the dumps: `FXA_MYSQL_USER`, root in the stack. Restore `ffs` last: its views read the other databases. With `FXA_DB=mariadb`, use `mariadb` instead of `mysql`:

    ```bash
    docker compose run --rm --no-deps --entrypoint sh backup-fxa -c '
      run=/backups/accounts/20261013T030000Z; export MYSQL_PWD="$FXA_DB_PASSWORD"
      for db in fxa fxa_oauth fxa_profile pushbox ffs; do
        mysql -h "$FXA_DB_HOST" -u"$FXA_DB_USER" -e "CREATE DATABASE IF NOT EXISTS $db" &&
        gunzip -t $run/$db.sql.gz && gunzip -c $run/$db.sql.gz | mysql -h "$FXA_DB_HOST" -u"$FXA_DB_USER" $db || exit 1
      done'
    ```

    The views and procedures of `ffs` carry that user as their `DEFINER`. Only that user, or one with `SET_ANY_DEFINER` (`SET_USER_ID` on MySQL before 8.2, `SET USER` on MariaDB), can restore them. At the next start `fxa-policy` installs the trigger of the sign-up policy again, and the admin UI's user and its grants, before the accounts service starts.
1. The tokenserver, as the tokenserver user: it is the `DEFINER` of the max users trigger and procedure. With `SYNC_DB=mysql`, use `mysql` instead of `mariadb`:

    ```bash
    docker compose run --rm --no-deps --entrypoint sh backup -c '
      f=/backups/sync/20261013T030000Z/$TOKENSERVER_DB_NAME.sql.gz
      gunzip -t "$f" && gunzip -c "$f" |
        MYSQL_PWD="$TOKENSERVER_DB_PASSWORD" mariadb -h "$TOKENSERVER_DB_HOST" -u"$TOKENSERVER_DB_USER" "$TOKENSERVER_DB_NAME"'
    # PostgreSQL (tokenserver and storage, one database): into the empty database, as the
    # Sync server's role SYNC_POSTGRES_APP_USER (TOKENSERVER_DB_USER of the backups, SYNC_POSTGRES_USER
    # without it), which this creates first. Not as the superuser: what the dump holds is
    # that role's, its functions would run with the superuser's rights. The dump names no
    # role (pg_dump --no-owner --no-privileges), the init container gives the grants at the
    # next start
    docker compose run --rm sync_role_init
    docker compose run --rm --no-deps --entrypoint sh backup -c '
      f=/backups/sync/20261013T030000Z/$TOKENSERVER_DB_NAME.sql.gz
      gunzip -t "$f" && gunzip -c "$f" |
        PGPASSWORD="$TOKENSERVER_DB_PASSWORD" psql -h "$TOKENSERVER_DB_HOST" -U "$TOKENSERVER_DB_USER" -d "$TOKENSERVER_DB_NAME" -v ON_ERROR_STOP=1'
    ```

1. The admin UI's database, as its user `ADMIN_DB_USER`. The stack's database containers create it, empty, at their start. The dump drops and creates its tables again, which its grants allow (`DROP` and `LOCK TABLES` included):

    ```bash
    docker compose run --rm --no-deps --entrypoint sh backup -c '
      f=/backups/sync/20261013T030000Z/$ADMIN_DB_NAME.sql.gz
      gunzip -t "$f" && gunzip -c "$f" |
        MYSQL_PWD="$ADMIN_DB_PASSWORD" mariadb -h "$TOKENSERVER_DB_HOST" -u"$ADMIN_DB_USER" "$ADMIN_DB_NAME"'
    # PostgreSQL: the init container creates it and the roles, after step 4 (it runs the
    # migrations first, on the database restored there), then exits:
    docker compose run --rm tokenserver_db_init
    docker compose run --rm --no-deps --entrypoint sh backup -c '
      f=/backups/sync/20261013T030000Z/$ADMIN_DB_NAME.sql.gz
      gunzip -t "$f" && gunzip -c "$f" |
        PGPASSWORD="$ADMIN_DB_PASSWORD" psql -h "$TOKENSERVER_DB_HOST" -U "$ADMIN_DB_USER" -d "$ADMIN_DB_NAME" -v ON_ERROR_STOP=1'
    ```

    A dump of the tokenserver from before `ADMIN_DB_PASSWORD` brings the admin UI's old tables back into the tokenserver database. They are not copied again (the setup check names them): drop them as the tokenserver user.
1. The storage: prefer to leave it empty. A copy of last night is older than what the browsers have, so Firefox would get back items that were changed or deleted since. With the storage empty, each Firefox finds the server empty and uploads what it has. Empty means a new `syncstorage-db` volume, or [Reset the Sync data](admin/accounts.md#sync-data) of each account after the restore.

    Restore it only when no device has the data any more: as in step 4, with `$STORAGE_DB_NAME`, `$STORAGE_DB_HOST`, `$STORAGE_DB_USER` and `$STORAGE_DB_PASSWORD`. With PostgreSQL the storage is in the one dump of step 4 and comes back with it: reset the Sync data of each account afterwards to have it empty.
1. Start the stack with `docker compose up -d`. The migrations bring an older schema up to date, and the overview records the change of the schema levels (an event of kind `update`).

## Restore with Quadlets

The same order as [Restore](#restore), with the Quadlet units and `podman`.

Stop every unit but the databases, including the one-shot units that ran at start (they stay "active" and would not run again):

```bash
systemctl --user stop firefox-sync-syncstorage.service firefox-sync-admin.service \
  firefox-sync-syncstorage-migrate.service firefox-sync-tokenserver-db-init.service
# with the accounts
systemctl --user stop firefox-sync-fxa-content.service firefox-sync-fxa-profile.service \
  firefox-sync-fxa-profile-worker.service firefox-sync-fxa-profile-static.service firefox-sync-fxa-auth.service \
  firefox-sync-fxa-policy.service firefox-sync-fxa-migrations.service
```

Then read each file out of the volume into the database container, as its own user:

```bash
set -o pipefail   # a missing or broken dump fails its line, instead of an empty restore
run=20261013T030000Z
dump() { podman run --rm -v firefox-sync-backups:/backups:ro docker.io/library/mariadb:lts gunzip -c "/backups/$1"; }
for db in fxa fxa_oauth fxa_profile pushbox ffs; do   # MariaDB accounts: mariadb and $MARIADB_ROOT_PASSWORD
  podman exec firefox-sync-fxa-db sh -c "MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" mysql -uroot -e 'CREATE DATABASE IF NOT EXISTS $db'"
  dump accounts/$run/$db.sql.gz | podman exec -i firefox-sync-fxa-db sh -c "MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" mysql -uroot $db"
done
dump sync/$run/tokenserver.sql.gz | podman exec -i firefox-sync-tokenserver-db sh -c 'MYSQL_PWD="$MARIADB_PASSWORD" mariadb -u"$MARIADB_USER" "$MARIADB_DATABASE"'
dump sync/$run/ffs_admin.sql.gz | podman exec -i firefox-sync-tokenserver-db sh -c 'MYSQL_PWD="$ADMIN_DB_PASSWORD" mariadb -u"$ADMIN_DB_USER" "$ADMIN_DB_NAME"'
# only when no device has the data any more (step 6 above)
dump sync/$run/syncstorage.sql.gz | podman exec -i firefox-sync-syncstorage-db sh -c 'MYSQL_PWD="$MARIADB_PASSWORD" mariadb -u"$MARIADB_USER" "$MARIADB_DATABASE"'
```

With `SYNC_DB=mysql` the Sync databases take `MYSQL_PWD="$MYSQL_PASSWORD" mysql -u"$MYSQL_USER" "$MYSQL_DATABASE"`. (Why the passwords go in `MYSQL_PWD`: [Passwords in commands](databases.md#passwords-in-commands).) The files are named after the databases of `.env` (`SYNC_TOKENSERVER_DB_NAME`, `SYNC_STORAGE_DB_NAME`).

With PostgreSQL the dump loads only into an empty database, as in [Restore](#restore): stop the database too, remove its volume, and load each dump as the role that owns it, the Sync server's (`FFS_SYNC_USER` in the database container) and the admin UI's. The init container makes the admin UI's database and roles again, between the two. `dump` as above, the file named after `SYNC_POSTGRES_NAME`:

```bash
systemctl --user stop firefox-sync-syncstorage.service firefox-sync-admin.service \
  firefox-sync-syncstorage-migrate.service firefox-sync-tokenserver-db-init.service \
  firefox-sync-sync-role-init.service firefox-sync-postgres-db.service
podman volume rm firefox-sync-postgres-db
systemctl --user start firefox-sync-sync-role-init.service   # the empty database, and the Sync server's role
dump sync/$run/syncserver.sql.gz | podman exec -i firefox-sync-postgres-db sh -c 'PGPASSWORD="$FFS_SYNC_PASSWORD" psql -h 127.0.0.1 -U "$FFS_SYNC_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1'
systemctl --user start firefox-sync-tokenserver-db-init.service   # the migrations, then the admin UI's database
dump sync/$run/ffs_admin.sql.gz | podman exec -i firefox-sync-postgres-db sh -c 'PGPASSWORD="$ADMIN_DB_PASSWORD" psql -h 127.0.0.1 -U "$ADMIN_DB_USER" -d "$ADMIN_DB_NAME" -v ON_ERROR_STOP=1'
```

The storage is in that one dump: to have it empty, reset the Sync data of each account afterwards (step 6 of [Restore](#restore)).

Start them again as at install: the Sync server and the accounts' units pull in the one-shot ones.

```bash
systemctl --user start firefox-sync-syncstorage.service
# with the accounts
systemctl --user start firefox-sync-fxa-content.service firefox-sync-fxa-profile.service \
  firefox-sync-fxa-profile-worker.service firefox-sync-fxa-profile-static.service
```

`firefox-sync-fxa-policy.service` must run again: the dump of `fxa` has no trigger of the sign-up policy. Without it, only the admin UI's sign-up gate holds closed or allowlist sign-ups.

## Restore on Kubernetes

The same steps as [Restore](#restore), with `kubectl`, in Jobs made from the backup CronJob's spec. Read that section for what to restore, in which order, and why the storage is better left empty.

On a new cluster, first:

1. Create your copy of the Secret, in the same namespace: `kubectl apply -f ffs-secret.json`, or your `existingSecret`. `helm install` with the same release name takes it over and keeps its data.
1. `helm install` with your values, as at the start, with `backup.enabled: true`: the restore runs in Jobs of the backup CronJob, on its PVC.
1. Put the copy of the backups back, with the pod of [Copy them off the cluster](#copy-them-off-the-cluster): `kubectl exec -i ffs-backups -- tar -C /backups -xzf - < ffs-backups.tar.gz`.

Then, on the same cluster or the new one, with `F=ffs-firefox-sync`:

1. Stop the Sync server and the admin UI: `kubectl scale deploy/$F-syncstorage --replicas=0`, and `kubectl scale deploy/$F-admin --replicas=0` with the admin UI. With the self-hosted accounts, also their servers: `kubectl scale deploy/$F-fxa-auth deploy/$F-fxa-content deploy/$F-fxa-profile --replicas=0`.
1. Empty the databases. PostgreSQL's dump loads only into an empty database, so do it there always. The dumps of MariaDB and MySQL drop and create each table again, so they also load into the old databases. The data of a database server is its PVC, `data-<its pod>`:

    ```bash
    for db in postgres; do   # MariaDB and MySQL: tokenserver-db storage-db; with the accounts, also fxa-db
      kubectl scale sts/$F-$db --replicas=0
      kubectl wait --for=delete pod/$F-$db-0 --timeout=5m
      kubectl delete pvc data-$F-$db-0
      kubectl scale sts/$F-$db --replicas=1
      kubectl rollout status sts/$F-$db --timeout=30m
    done
    ```

    The bundled accounts database on MariaDB (`fxa.database.backend: mariadb`) has the PVC `data-mariadb-$F-fxa-db-0` instead. On your own accounts server, empty its databases there, or leave them: the accounts' dumps drop and create each table again.

1. Pick a run: `run=20261013T030000Z`, one of the list of the pod of [Copy them off the cluster](#copy-them-off-the-cluster) (`kubectl exec ffs-backups -- ls /backups/sync`, and `/backups/accounts` with the self-hosted accounts). Delete that pod before the restores (`kubectl delete pod ffs-backups`): the PVC is `ReadWriteOnce`, and on another node the Jobs below would wait for it. Each restore runs the command of [Restore](#restore) in a Job of the backup CronJob's spec (its variables, its volume), as the stack's users:

    ```bash
    restore() {   # restore <job name> <command> [container: backup, the Sync scope's, or backup-accounts]
      kubectl create job --from=cronjob/$F-backup "$1" --dry-run=client -o json |
        jq --arg c "$2" --arg n "${3:-backup}" '.spec.template.spec |= (.containers = [(.initContainers // []) + .containers | .[]
          | select(.name == $n) | .command = ["sh", "-c", $c] | del(.args)] | del(.initContainers))' |
        kubectl apply -f - || return 1
      local deadline=$(( $(date +%s) + 600 ))
      until kubectl get job "$1" -o jsonpath='{.status.conditions[*].type}' | grep -qE 'Complete|Failed'; do
        [ "$(date +%s)" -lt "$deadline" ] || { echo "job/$1 not done after 10 minutes: kubectl describe job/$1"; return 1; }
        sleep 2
      done
      kubectl logs "job/$1"
      [ "$(kubectl get job "$1" -o jsonpath='{.status.succeeded}')" = 1 ]
    }
    ```

1. With the self-hosted accounts, first their databases, as the user that made the dumps ([Restore](#restore) step 3), in the container `backup-accounts`. Use `mariadb` instead of `mysql` with `fxa.database.backend: mariadb`. Their run is the same night's, in `/backups/accounts`, a few seconds or minutes before the Sync one:

    ```bash
    accounts_run=20261013T030000Z
    restore restore-accounts 'run=/backups/accounts/'$accounts_run'; export MYSQL_PWD="$FXA_DB_PASSWORD"
      for db in fxa fxa_oauth fxa_profile pushbox ffs; do
        mysql -h "$FXA_DB_HOST" -P "$FXA_DB_PORT" -u"$FXA_DB_USER" -e "CREATE DATABASE IF NOT EXISTS $db" &&
        gunzip -t $run/$db.sql.gz && gunzip -c $run/$db.sql.gz | mysql -h "$FXA_DB_HOST" -P "$FXA_DB_PORT" -u"$FXA_DB_USER" $db || exit 1
      done' backup-accounts
    ```

1. MariaDB and MySQL (`mysql` instead of `mariadb` with MySQL): the tokenserver, then the admin UI's database (the database servers create it, empty, at their start). The storage only when no device has the data any more:

    ```bash
    restore restore-tokenserver 'f=/backups/sync/'$run'/$TOKENSERVER_DB_NAME.sql.gz
      gunzip -t "$f" && gunzip -c "$f" | MYSQL_PWD="$TOKENSERVER_DB_PASSWORD" mariadb -h "$TOKENSERVER_DB_HOST" -u"$TOKENSERVER_DB_USER" "$TOKENSERVER_DB_NAME"'
    restore restore-admin 'f=/backups/sync/'$run'/$ADMIN_DB_NAME.sql.gz
      gunzip -t "$f" && gunzip -c "$f" | MYSQL_PWD="$ADMIN_DB_PASSWORD" mariadb -h "$TOKENSERVER_DB_HOST" -u"$ADMIN_DB_USER" "$ADMIN_DB_NAME"'
    # only when no device has the data any more
    restore restore-storage 'f=/backups/sync/'$run'/$STORAGE_DB_NAME.sql.gz
      gunzip -t "$f" && gunzip -c "$f" | MYSQL_PWD="$STORAGE_DB_PASSWORD" mariadb -h "$STORAGE_DB_HOST" -u"$STORAGE_DB_USER" "$STORAGE_DB_NAME"'
    kubectl scale deploy/$F-syncstorage --replicas=1
    ```

    PostgreSQL: first the Sync server's role (the `sync-role` init container of the Sync server, alone), then the one Sync database as that role. The Sync server's init container then creates the admin UI's database and roles, and its dump goes in after it:

    ```bash
    kubectl get deploy $F-syncstorage -o json | jq '{apiVersion: "v1", kind: "Pod", metadata: {name: "ffs-sync-role"},
      spec: {restartPolicy: "Never", containers: [.spec.template.spec.initContainers[] | select(.name == "sync-role")]}}' | kubectl apply -f -
    kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/ffs-sync-role --timeout=5m && kubectl delete pod ffs-sync-role
    restore restore-sync 'f=/backups/sync/'$run'/$TOKENSERVER_DB_NAME.sql.gz
      gunzip -t "$f" && gunzip -c "$f" |
        PGPASSWORD="$TOKENSERVER_DB_PASSWORD" psql -h "$TOKENSERVER_DB_HOST" -U "$TOKENSERVER_DB_USER" -d "$TOKENSERVER_DB_NAME" -v ON_ERROR_STOP=1'
    kubectl scale deploy/$F-syncstorage --replicas=1
    kubectl rollout status deploy/$F-syncstorage --timeout=10m
    restore restore-admin 'f=/backups/sync/'$run'/$ADMIN_DB_NAME.sql.gz
      gunzip -t "$f" && gunzip -c "$f" |
        PGPASSWORD="$ADMIN_DB_PASSWORD" psql -h "$TOKENSERVER_DB_HOST" -U "$ADMIN_DB_USER" -d "$ADMIN_DB_NAME" -v ON_ERROR_STOP=1'
    ```

1. Start the admin UI again with `kubectl scale deploy/$F-admin --replicas=1`. With the accounts, their servers too: `kubectl scale deploy/$F-fxa-auth deploy/$F-fxa-content deploy/$F-fxa-profile --replicas=1` (auth's init containers install the sign-up policy's trigger again, and the admin UI's user). Then remove what the restore left: `kubectl delete job restore-accounts restore-tokenserver restore-admin restore-storage restore-sync --ignore-not-found`. The migrations bring an older schema up to date. A later `helm upgrade` keeps the chart's replicas (one each).

## Test a restore

Now and then, check that a dump restores. This loads the newest accounts dump into a scratch database next to the real ones, without stopping anything (it is what `tests/e2e-fxa.sh` does):

```bash
docker compose run --rm --no-deps --entrypoint sh backup-fxa -c '
  run=$(ls -1d /backups/accounts/* | tail -1); export MYSQL_PWD="$FXA_DB_PASSWORD"; db="mysql -h $FXA_DB_HOST -u$FXA_DB_USER"
  $db -e "CREATE DATABASE ffs_restore_test" && gunzip -c $run/fxa.sql.gz | $db ffs_restore_test &&
  $db -e "SELECT COUNT(*) AS restored FROM ffs_restore_test.accounts; SELECT COUNT(*) AS now FROM fxa.accounts"
  $db -e "DROP DATABASE ffs_restore_test"'
```

The two counts match, or the restored one is a bit lower (accounts created since the night). The tokenserver user cannot create databases, so for the Sync databases only `gzip -t` is checked at every run. The full test is a restore on another machine with a copy of `.env`, which is what `tests/e2e.sh` does: see [Testing](development/testing.md).
