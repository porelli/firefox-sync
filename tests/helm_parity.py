#!/usr/bin/env python3
"""The chart against compose: per pair (compose service -> chart container) the same env
variable names, the same values (but the hosts, compose's service names against the chart's
<fullname>-..., and the secrets, which must come from the Secret where compose has a secret
of .env), the same command and working directory, and probes that check what compose's
healthcheck checks with its timings. The scripts the chart copies are byte-identical to
compose's. The self-hosted accounts (compose/fxa.yml) too: the fxa-* cases.

  helm_parity.py [case...]   cases: see CASES (default: all), each with the admin UI and
                             the backups on and off

Needs docker compose (config only: no daemon) and helm. The test .env is .env-example as
tests/e2e.sh writes it: its placeholders filled, a few values per case.
"""
import glob
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile

import yaml

TESTS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TESTS)
CHART = os.path.join(REPO, "charts", "firefox-sync")
RELEASE = "test-release"
FULLNAME = f"{RELEASE}-firefox-sync"
DOMAIN = "example.test"
EXTDB = "extdb.example.test"

# the accounts' cases (CASES): all, those with the bundled accounts database, those with the pairing
# server; the Sync server is bundled MariaDB in all but fxa-postgres
FXA = "fxa-mysql,fxa-mysql8,fxa-mariadb,fxa-external,fxa-postgres"
FXA_BUNDLED = "fxa-mysql,fxa-mysql8,fxa-mariadb,fxa-postgres"
FXA_PAIRING = FXA_BUNDLED
SYNC_MARIADB = "mariadb,fxa-mysql,fxa-mysql8,fxa-mariadb,fxa-external"
SYNC_POSTGRES = "postgres,fxa-postgres"

MYSQL_SERVERS = f"{SYNC_MARIADB},mysql,external-mariadb,external-mysql"
BUNDLED = f"{SYNC_MARIADB},mysql,{SYNC_POSTGRES}"

# chart-only, compose-only or different, by design: "<cases>:<chart container>/<VAR>" -> why.
# <cases>: * or the cases (comma-separated) the reason holds for; every case of an entry must
# use it (with the admin UI and the backups on or off), else it is stale and fails
ALLOWED_DIFFERENCES = {
    # admin UI
    "*:admin/ADMIN_DEPLOYMENT": "the commands the admin UI shows: kubectl and helm (kubernetes), not docker compose (compose)",
    "*:admin/ADMIN_K8S_RELEASE": "chart-only: the release name for the helm commands the admin UI shows",
    "*:admin/ADMIN_K8S_NAMESPACE": "chart-only: the namespace for the kubectl commands the admin UI shows",
    "*:admin/ADMIN_K8S_FULLNAME": "chart-only: the chart's object names (fullnameOverride), which the admin UI builds from it",
    "*:admin/ADMIN_K8S_SECRET": "chart-only: the Secret's name (existingSecret) for the commands the admin UI shows",
    "*:admin/ADMIN_K8S_CHART": "chart-only: where the chart was published, for the helm upgrade commands the admin UI shows",
    "*:admin/ADMIN_K8S_CHART_VERSION": "chart-only: the release's chart version, the --version of the helm upgrade commands the admin UI shows",
    "*:admin/ADMIN_EXPORT_PORT": "compose-only: the host port compose publishes the admin UI on; the chart has a Service (and an Ingress)",
    "*:admin/ADMIN_INSECURE_COOKIE": "compose passes it empty when .env does not set it; the chart only when admin.insecureCookie "
    "is set (empty: off, as compose's), so that the default render stays that of 0.1.0",
    "*:admin/SMTP_INSECURE_AUTH": "as ADMIN_INSECURE_COOKIE: the chart only when smtp.insecureAuth is set",
    f"{BUNDLED}:admin/SYNC_DB_CONTAINERS": "compose passes it always; the chart only with database.bundled false (its "
    "setup check of database-setup.sql), so that the default render stays that of 0.1.0: unset, the admin UI takes 1",
    f"{BUNDLED}:admin/SYNC_DB_BOOTSTRAP_USER": "as SYNC_DB_CONTAINERS: with your own server only",
    # the old names of .env (docs/upgrading.md#renamed-settings): compose tells its containers which
    # are still set, or set with their new ones; the chart has no .env
    "*:migrate/FFS_BOTH_ENV_NAMES": "compose-only: the old .env names set with their new ones; the chart has no .env",
    "*:syncstorage/FFS_BOTH_ENV_NAMES": "as migrate's",
    "*:db-init/FFS_BOTH_ENV_NAMES": "as migrate's",
    f"{SYNC_POSTGRES},external-postgres:sync-role/FFS_BOTH_ENV_NAMES": "as migrate's",
    "external-mariadb,external-mysql,external-postgres:db-bootstrap/FFS_BOTH_ENV_NAMES": "as migrate's",
    "external-mariadb,external-mysql,external-postgres:db-bootstrap/FFS_SETUP_PENDING": "how db-bootstrap's message says to "
    "print the SQL of the setup migrations your server lacks again: docker compose run (compose), kubectl logs of its init "
    "container (the chart)",
    "fxa-external:fxa-db-bootstrap/FFS_SETUP_PENDING": "as db-bootstrap's",
    "fxa-external:fxa-db-bootstrap/FXA_MYSQL_ARGS": "compose-only: FXA_MYSQL_ARGS of .env says mysql_native_password for an "
    "accounts image without mozilla/fxa#21554 (the \"-- native:\" lines of db/mysql/setup/fxa-mysql); the chart's own server takes the "
    "server's default authentication, as docs/databases.md#with-helm says",
    "*:db-init/FFS_OLD_ENV_NAMES": "compose-only: the old .env names still set, for the init container's warning; no .env here",
    "*:admin/FFS_OLD_ENV_NAMES": "compose-only: the old .env names still set, for the admin UI's setup check; no .env here",
    # the Sync server
    "*:syncstorage/SYNC_STATSD_HOST": "chart-only as a variable: compose exports it in syncstorage's entrypoint when ffs-admin resolves; "
    "the chart sets it while the admin UI is on (its value is still compared with the export)",
    "*:syncstorage/SYNC_STATSD_PORT": "as SYNC_STATSD_HOST",
    # the chart passes the passwords as their own variables (from the Secret) and builds the
    # database URLs with $(VAR): compose interpolates them into the URLs (and a $(VAR) must use them)
    f"{MYSQL_SERVERS}:migrate/STORAGE_DB_PASSWORD": "chart-only: the password of SYNC_SYNCSTORAGE__DATABASE_URL, $(STORAGE_DB_PASSWORD) there",
    f"{MYSQL_SERVERS}:migrate/TOKENSERVER_DB_PASSWORD": "chart-only: the password of SYNC_TOKENSERVER__DATABASE_URL, $(TOKENSERVER_DB_PASSWORD) there",
    f"{SYNC_POSTGRES}:migrate/POSTGRES_SYNC_PASSWORD": "chart-only: the password of the database URLs (the Sync role), $(POSTGRES_SYNC_PASSWORD) there",
    "external-postgres:migrate/POSTGRES_PASSWORD": "chart-only: the password of the database URLs with your own server (no Sync role), "
    "$(POSTGRES_PASSWORD) there",
    f"{MYSQL_SERVERS}:syncstorage/STORAGE_DB_PASSWORD": "as migrate's",
    f"{MYSQL_SERVERS}:syncstorage/TOKENSERVER_DB_PASSWORD": "as migrate's",
    f"{SYNC_POSTGRES}:syncstorage/POSTGRES_SYNC_PASSWORD": "as migrate's",
    "external-postgres:syncstorage/POSTGRES_PASSWORD": "as migrate's",
    # the backups
    "mysql:backup/MARIADB_TLS_VERIFY": "bundled MySQL: false (the chart's one value, the init container's) where compose's backup "
    "inherits true; no effect: the backup image is MySQL's, backup.sh reads it with the MariaDB client only",
    f"{SYNC_MARIADB},mysql:db/FFS_MYSQL_IMAGE": "compose-only: SYNC_MARIADB_IMAGE or SYNC_MYSQL_IMAGE as set in .env (empty: the "
    "compose file's default), for db/mysql/keep-major.sh; the chart's image is always database.image.<backend>, chosen in "
    "the values, and checkDbMajor refuses another major (docs/upgrading.md#database-majors)",
    f"{SYNC_MARIADB},mysql:db/FFS_MYSQL_SETTING": "as FFS_MYSQL_IMAGE",
    f"{SYNC_POSTGRES}:db/FFS_POSTGRES_IMAGE": "compose-only in the server's container: SYNC_POSTGRES_IMAGE for the message of "
    "db/postgres/keep-major.sh, which the chart runs as its db-major init container (with database.image.postgres)",
    # the databases
    # the self-hosted accounts (compose/fxa.yml)
    f"{FXA_BUNDLED}:fxa-db/FFS_MYSQL_IMAGE": "compose-only: FXA_MYSQL_IMAGE or FXA_MARIADB_IMAGE as set in .env, for "
    "db/mysql/keep-major.sh; the chart's image is always fxa.database.image.<backend>, and checkFxaDbBackend refuses "
    "another major at render time (fxa.database.allowMajorUpgrade, docs/upgrading.md#database-majors)",
    f"{FXA_BUNDLED}:fxa-db/FFS_MYSQL_SETTING": "as FFS_MYSQL_IMAGE",
    f"{FXA}:profile-worker/WORKER_HOST": "chart-only 127.0.0.1 (compose 0.0.0.0): compose's worker is on a network of "
    "compose's own, a pod's IP is reachable from every pod; profile, its one client, is in the same pod",
    f"{FXA}:profile/WORKER_URL": "http://127.0.0.1:1113, not compose's fxa-profile-worker: the worker is in profile's pod, "
    "on its loopback alone (WORKER_HOST)",
    f"{FXA}:admin/ADMIN_GATE_EXPORT_PORT": "what the configuration page shows for the sign-up gate: the Service "
    "<fullname>-admin:8081 (the Ingress of the accounts' API routes to it), compose's host port",
    f"{FXA}:admin/FXA_REDIS": "chart-only: compose's admin UI finds Redis by its default, fxa-redis:6379; the chart's "
    "Service is <fullname>-fxa-redis",
    f"{FXA}:admin/FXA_CONTENT_INTERNAL_URL": "chart-only: compose's admin UI reaches the accounts' servers by its "
    "defaults, their compose service names; the chart's Services are <fullname>-fxa-*",
    f"{FXA}:admin/FXA_PROFILE_INTERNAL_URL": "as FXA_CONTENT_INTERNAL_URL",
    f"{FXA_PAIRING}:admin/FXA_PAIRING_INTERNAL_URL": "as FXA_CONTENT_INTERNAL_URL, with fxa.pairing.enabled",
    "fxa-external:admin/FXA_PAIRING_URL": "with fxa.pairing.url but fxa.pairing.enabled false (a pairing server of "
    "your own elsewhere: Firefox still gets the URL, content's PAIRING_SERVER_BASE_URI) the chart's is empty: the admin "
    "UI's health check of the pairing server goes to FXA_PAIRING_INTERNAL_URL, else http://fxa-pairing:8000, which no "
    "Service answers; compose with FXA_PAIRING_URL and no pairing profile checks a server that is not there",
    # fxa.extraCaCerts (the fxa-mariadb case sets it): a CA of your own for the accounts' public URLs
    "fxa-mariadb:auth/NODE_EXTRA_CA_CERTS": "chart-only: fxa.extraCaCerts, a CA of your own the accounts' servers trust "
    "for their public URLs; compose has no such setting (tests/compose/fxa.yml mounts its test CA itself)",
    "fxa-mariadb:content/NODE_EXTRA_CA_CERTS": "as auth's",
    "fxa-mariadb:profile/NODE_EXTRA_CA_CERTS": "as auth's",
    "fxa-mariadb:admin/SSL_CERT_DIR": "chart-only: fxa.extraCaCerts for the admin UI's public checks and sign-in (Go reads "
    "every PEM of the directory, next to the system's); compose has no such setting (the tests' SSL_CERT_FILE)",
}

# chart-only variables from the Secret that the program reads itself (no $(VAR) of another
# variable): "<cases>:<container>/<VAR>" -> why; each must be a secretKeyRef
ALLOWED_CHART_SECRETS = {
    f"{FXA}:redis/REDISCLI_AUTH": "chart-only: the password of the accounts' Redis (FXA_REDIS_PASSWORD), its requirepass "
    "read from stdin by the command (ALLOWED_COMMANDS) and redis-cli's for the probes; compose's Redis has none, on a "
    "network of compose's own, a pod's IP is reachable from every pod (and fxa-networkpolicy.yaml)",
    f"{FXA}:wait-redis/REDISCLI_AUTH": "chart-only: as redis', for the init container's redis-cli ping (compose's "
    "depends_on fxa-redis service_healthy)",
    **{f"{FXA}:auth/{prefix}REDIS_PASSWORD": f"chart-only: the password of Redis (as redis' REDISCLI_AUTH), with {prefix}REDIS_HOST"
       for prefix in ("", "ACCESS_TOKEN_", "REFRESH_TOKEN_", "CUSTOMS_", "RATELIMIT_", "METRICS_", "AUTH_CACHE_",
                      "RECOVERY_PHONE_", "PASSKEY_")},
    f"{FXA}:content/REDIS_PASSWORD": "chart-only: the password of Redis (as redis' REDISCLI_AUTH), of REDIS_HOST and "
    "FEATURE_FLAGS_REDIS_HOST",
    f"{FXA}:profile/REDIS_PASSWORD": "chart-only: the password of Redis (as redis' REDISCLI_AUTH), with REDIS_HOST",
    f"{FXA}:admin/FXA_REDIS_PASSWORD": "chart-only: the password of Redis (as redis' REDISCLI_AUTH), with FXA_REDIS",
}

# commands other than compose's, the chart's exactly: "<cases>:<container>" -> ([command, args], why)
ALLOWED_COMMANDS = {
    "*:syncstorage": ([["/app/bin/syncserver"], None],
                      "compose's entrypoint script only adds SYNC_STATSD_* (env here) before exec /app/bin/syncserver"),
    "*:backup": ([["sh", "/ffs-backup/backup.sh"], ["now"]],
                 "a CronJob runs backup.sh now at backup.schedule; compose's container runs backup.sh loop"),
    f"{SYNC_POSTGRES}:db": ([None, None],
                    "compose starts it through db/postgres/keep-major.sh (refuses another major's data, says what "
                    "to pin); the chart runs that as the db-major init container, then the image's entrypoint and command"),
    f"{SYNC_MARIADB}:db": ([None, ["sh", "/ffs-db/admin-user.sh", "mariadbd", "--explicit_defaults_for_timestamp"]],
                   "compose starts it through db/mysql/keep-major.sh (no upgrade of the data to another major with "
                   "SYNC_MARIADB_IMAGE unset in .env); the chart has no unset: database.image.mariadb"),
    "mysql:db": ([None, ["sh", "/ffs-db/admin-user.sh", "mysqld", "--disable-log-bin"]],
                 "compose starts it through db/mysql/keep-major.sh (no upgrade of the data to another major with "
                 "SYNC_MYSQL_IMAGE unset in .env); the chart has no unset: database.image.mysql"),
    # the accounts' database: compose's command without db/mysql/keep-major.sh (the chart refuses
    # another major at render time, checkFxaDbBackend) and the image's entrypoint (its default)
    "fxa-mysql,fxa-postgres:fxa-db": ([None, ["mysqld", "--event-scheduler=ON"]],
                                      "compose's command without db/mysql/keep-major.sh docker-entrypoint.sh (the "
                                      "render-time major guard instead); on mysql:lts no FXA_MYSQL_ARGS, as compose's"),
    "fxa-mysql8:fxa-db": ([None, ["mysqld", "--event-scheduler=ON", "--mysql-native-password=ON",
                                  "--authentication-policy=mysql_native_password"]],
                          "as fxa-mysql's; on a MySQL 8 pin the chart adds compose's FXA_MYSQL_ARGS of that pin "
                          "(prepare_environment.sh writes both), from the image's major (fxaDbArgs)"),
    "fxa-mariadb:fxa-db": ([None, ["mariadbd", "--event-scheduler=ON"]],
                           "as fxa-mysql's (compose/fxa-mariadb.yml's command)"),
    f"{FXA}:redis": ([["/bin/sh", "-c"], ['pass=$(printf %s "$REDISCLI_AUTH" | od -An -v -tx1 | tr -d \' \\n\' | '
                                         "sed 's/../\\\\x&/g')\nexec redis-server - <<EOF\nrequirepass \"$pass\"\nEOF\n"]],
                     "the image's redis-server with a password (REDISCLI_AUTH, chart-only: compose's Redis has none) "
                     "in its configuration from stdin, not in the pod spec or the process' arguments"),
    f"{FXA_BUNDLED}:backup-accounts": ([["sh", "-c", 'sh /ffs-backup/backup.sh now || echo "the accounts backup failed: recorded"'], None],
                                       "backup.sh now at backup.schedule (compose's loop), before the Sync scope in the same "
                                       "Job: a failed dump is left in /backups/.status for it to record, and Sync is dumped "
                                       "all the same"),
}

# probes with other timings than compose's healthcheck, the chart's exactly:
# "<cases>:<container>/<probe>" -> ((periodSeconds, timeoutSeconds, failureThreshold), why)
ALLOWED_PROBE_TIMINGS = {
    "*:syncstorage/readinessProbe": ((10, 10, 3), "compose's healthcheck is the livenessProbe; ready sooner (every 10 s, 3 failures) "
                                     "so that the Service gets it at once"),
    "*:admin/startupProbe": ((5, 5, 120), "the first start moves the tables of an older install: up to 10 minutes"),
    "*:admin/readinessProbe": ((10, 5, 3), "compose's healthcheck is the livenessProbe; ready sooner (every 10 s) for the Service"),
    f"{BUNDLED}:db/startupProbe": ((10, 5, 180), "the first start (a new database, a long recovery) gets up to 30 minutes; "
                                  "compose's start_period only delays counting the failures"),
    f"{BUNDLED}:db/livenessProbe": ((30, 10, 10), "restarted only after 5 minutes without an answer: compose never restarts an "
                                    "unhealthy database, and a restart in the middle of a recovery starts it over; readiness "
                                    "is compose's healthcheck"),
    # the accounts
    **{f"{FXA}:{c}/startupProbe": ((15, 10, 40), "compose's start_period 300 s plus the first start's key generation: "
                                   "up to 10 minutes, compose's interval and timeout")
       for c in ("auth", "content", "profile", "profile-worker", "profile-static")},
    f"{FXA_PAIRING}:pairing/startupProbe": ((10, 5, 30), "compose's start_period 30 s: up to 5 minutes, every 10 s"),
    f"{FXA_BUNDLED}:fxa-db/startupProbe": ((10, 5, 180), "as the Sync server's databases (db/startupProbe)"),
    f"{FXA_BUNDLED}:fxa-db/livenessProbe": ((30, 10, 10), "as the Sync server's databases (db/livenessProbe)"),
}

# the profile worker's probes: compose's check on 127.0.0.1, where it listens (WORKER_HOST)
WORKER_CHECK = ("exec", "node", "-e", "fetch('http://127.0.0.1:1113/__heartbeat__').then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))")

# probes that check other than compose's healthcheck, the chart's exactly:
# "<cases>:<container>/<probe>" -> (check, why)
ALLOWED_PROBE_CHECKS = {
    **{f"{FXA}:profile-worker/{p}": (WORKER_CHECK, "compose's command on 127.0.0.1, not an httpGet: the worker listens "
                                     "on the pod's loopback alone (WORKER_HOST), an httpGet goes to the pod's IP")
       for p in ("startupProbe", "readinessProbe", "livenessProbe")},
    f"{FXA}:admin/readinessProbe": (("tcp", "8081"), "with the accounts Ready once the sign-up gate (8081) listens too: "
                                    "the Ingress of the accounts' API sends the sign-ups there; its livenessProbe is "
                                    "compose's healthcheck"),
}

# containers of the chart that compose has no service for, without env (no credentials):
# "<cases>:<kind>/<workload name, a regex>/<container>" -> why
CHART_ONLY_CONTAINERS = {
    f"{SYNC_POSTGRES}:StatefulSet/{FULLNAME}-postgres/db-major": "compose runs db/postgres/keep-major.sh in postgres_db's entrypoint: "
    "refuses another major's data before the server starts",
    f"*:Deployment/{FULLNAME}-syncstorage/wait-db": "compose's depends_on service_healthy: waits for the database servers to answer",
    f"*:Deployment/{FULLNAME}-admin/wait-sync": "compose's ffs-admin depends_on tokenserver_db_init: the admin UI starts once the "
    "Sync server serves (its init containers succeeded)",
    f"*:Job/{FULLNAME}-backup-volume-[0-9a-f]{{8}}/bind": "binds the backups PVC at install (WaitForFirstConsumer storage "
    "classes), compose's volume needs nothing",
    # the accounts: compose's depends_on as init containers, what compose's volumes do by themselves
    f"{FXA}:Deployment/{FULLNAME}-fxa-auth/wait-db": "compose's depends_on fxa-db service_healthy: the accounts "
    "database answers (a ping, no credentials), also your own server",
    f"{FXA}:Deployment/{FULLNAME}-fxa-auth/wait-redis": "compose's depends_on fxa-redis service_healthy (REDISCLI_AUTH: "
    "ALLOWED_CHART_SECRETS)",
    f"{FXA}:Deployment/{FULLNAME}-fxa-content/wait-accounts": "compose's depends_on fxa-auth and fxa-profile service_healthy",
    f"{FXA}:Deployment/{FULLNAME}-fxa-profile/images-owner": "as compose's fxa-keys-owner for the avatars' volume: the "
    "image runs as 10001, new volumes are root's (compose's volume takes the image directory's owner)",
    f"{FXA}:Deployment/{FULLNAME}-fxa-profile/images-seed": "Docker copies the image's var/public into a new volume, "
    "Kubernetes does not: the same here",
    f"{FXA}:Deployment/{FULLNAME}-fxa-profile/wait-auth": "compose's depends_on fxa-migrations: the auth server answers "
    "once its pod migrated",
    f"{FXA}:Deployment/{FULLNAME}-fxa-profile/img-proxy": "the avatars under /img/ for the Ingress (files/fxa/img-proxy.js): "
    "compose's reverse proxy sends /img/ to fxa-profile-static, the prefix stripped",
    f"{FXA}:Deployment/{FULLNAME}-admin/wait-fxa": "compose's ffs-admin depends_on fxa-policy: the auth server answers "
    "once its init containers (the policy) succeeded",
}

# compose services the chart has none for, by design: "<cases>:<service>" -> why
COMPOSE_ONLY_SERVICES = {
    f"{BUNDLED}:db-bootstrap": "with the stack's database containers compose's db-bootstrap does nothing (db/db-setup.sh "
    "exits 0); the chart renders it with your own server only",
    f"{FXA_BUNDLED}:fxa-db-bootstrap": "as db-bootstrap, with the bundled accounts database",
    "fxa-external:backup-fxa": "with your own accounts server compose's backup-fxa is not used "
    "(docs/backups.md#your-own-database-server; e2e-fxa.sh runs no backup profile there): the stack's accounts user "
    "cannot read ffs; the chart renders no backup-accounts then",
}

# objects of the chart compose has nothing for, checked by kind: "<cases>:<kind>/<name, a regex>" -> why
CHART_ONLY_KINDS = ("NetworkPolicy",)
CHART_ONLY_OBJECTS = {
    f"{FXA}:NetworkPolicy/{FULLNAME}-fxa-redis": "fxa.networkPolicy: Redis only for the accounts' servers and the admin "
    "UI; compose's Redis is on a network of compose's own",
    f"{FXA_BUNDLED}:NetworkPolicy/{FULLNAME}-fxa-db": "as fxa-redis', the bundled accounts database (also the backups)",
}


def in_scope(key, case):
    """the entry's cases hold the case: (True, the rest of the key) or (False, None)"""
    scope, rest = key.split(":", 1)
    return (scope == "*" or case in scope.split(",")), rest


def entry(table, case, rest):
    """the key of the table for the case and the rest of a key, or None"""
    for key in table:
        ok, r = in_scope(key, case)
        if ok and r == rest:
            return key
    return None


# compose healthchecks the chart does as HTTP probes: the image has no shell
EQUIVALENT_CHECKS = {
    ("exec", "/ffs-admin", "healthcheck"): (
        ("http", "8080", "/healthz"),
        "admin/main.go: /ffs-admin healthcheck GETs http://127.0.0.1:<ADMIN_LISTEN, :8080>/healthz",
    ),
}
# compose's checks of the accounts' images (node, no curl): node -e "fetch('http://localhost:<port><path>')
# exits 0 on a 2xx", an httpGet of <port><path> -> ("http", port, path)
EQUIVALENT_CHECK_PATTERNS = [
    (re.compile(r"^fetch\('http://localhost:(\d+)(/[^']*)'\)\.then\(r => process\.exit\(r\.ok \? 0 : 1\), "
                r"\(\) => process\.exit\(1\)\)$"),
     "node's fetch() of the accounts' images: a 2xx answer, as an httpGet's 200-399 (their heartbeats answer 200 or 5xx)"),
]

# compose's scripts the chart carries a copy of
IDENTICAL_FILES = {
    "charts/firefox-sync/files/backup.sh": "config/backup/backup.sh",
    "charts/firefox-sync/files/admin-user.sh": "db/mysql/admin-user.sh",
    "charts/firefox-sync/files/postgres-keep-major.sh": "db/postgres/keep-major.sh",
    "charts/firefox-sync/files/db-setup.sh": "db/db-setup.sh",
    "charts/firefox-sync/files/fxa/content-server.js": "config/fxa/content-server.js",
    "charts/firefox-sync/files/fxa/oauth-clients.js": "config/fxa/oauth-clients.js",
}
# and the setup migrations of db/<engine>/setup/ (files/db/, tests/setup_migrations.sh too)
for _setup in sorted(glob.glob(os.path.join(REPO, "db", "*", "setup", "*", "*.sql"))):
    _rel = os.path.relpath(_setup, REPO)
    IDENTICAL_FILES["charts/firefox-sync/files/" + _rel] = _rel

# compose service -> chart (workload kind, workload name, container, key prefix, init or one-shot);
# a compose service of the case missing here fails
PAIRS = [
    ("db-bootstrap", "Deployment", f"{FULLNAME}-syncstorage", "db-bootstrap", "db-bootstrap", True),
    ("sync_role_init", "Deployment", f"{FULLNAME}-syncstorage", "sync-role", "sync-role", True),
    ("syncstorage_migrate", "Deployment", f"{FULLNAME}-syncstorage", "migrate", "migrate", True),
    ("tokenserver_db_init", "Deployment", f"{FULLNAME}-syncstorage", "db-init", "db-init", True),
    ("syncstorage", "Deployment", f"{FULLNAME}-syncstorage", "syncstorage", "syncstorage", False),
    ("ffs-admin", "Deployment", f"{FULLNAME}-admin", "admin", "admin", False),
    # compose's loop is a CronJob here: no probes to compare
    ("backup", "CronJob", f"{FULLNAME}-backup", "backup", "backup", True),
    ("tokenserver_db", "StatefulSet", f"{FULLNAME}-tokenserver-db", "db", "db", False),
    ("syncstorage_db", "StatefulSet", f"{FULLNAME}-storage-db", "db", "db", False),
    ("postgres_db", "StatefulSet", f"{FULLNAME}-postgres", "db", "db", False),
    # the accounts (compose/fxa.yml): auth's one-shot services are its init containers
    ("fxa-db", "StatefulSet", f"{FULLNAME}-fxa-db", "db", "fxa-db", False),
    ("fxa-redis", "Deployment", f"{FULLNAME}-fxa-redis", "redis", "redis", False),
    ("fxa-keys-owner", "Deployment", f"{FULLNAME}-fxa-auth", "keys-owner", "keys-owner", True),
    ("fxa-db-bootstrap", "Deployment", f"{FULLNAME}-fxa-auth", "db-bootstrap", "fxa-db-bootstrap", True),
    ("fxa-migrations", "Deployment", f"{FULLNAME}-fxa-auth", "migrations", "migrations", True),
    ("fxa-policy", "Deployment", f"{FULLNAME}-fxa-auth", "policy", "policy", True),
    ("fxa-auth", "Deployment", f"{FULLNAME}-fxa-auth", "auth", "auth", False),
    ("fxa-content", "Deployment", f"{FULLNAME}-fxa-content", "content", "content", False),
    # one pod: the three mount the avatars' volume (RWO)
    ("fxa-profile", "Deployment", f"{FULLNAME}-fxa-profile", "profile", "profile", False),
    ("fxa-profile-worker", "Deployment", f"{FULLNAME}-fxa-profile", "profile-worker", "profile-worker", False),
    ("fxa-profile-static", "Deployment", f"{FULLNAME}-fxa-profile", "profile-static", "profile-static", False),
    ("fxa-pairing", "Deployment", f"{FULLNAME}-fxa-pairing", "pairing", "pairing", False),
    # compose's loop, an init container of the backup CronJob here (before the Sync scope)
    ("backup-fxa", "CronJob", f"{FULLNAME}-backup", "backup-accounts", "backup-accounts", True),
]

# the hosts: compose's service names, the chart's Services
HOSTS = {
    "tokenserver_db": f"{FULLNAME}-tokenserver-db",
    "syncstorage_db": f"{FULLNAME}-storage-db",
    "postgres_db": f"{FULLNAME}-postgres",
    "syncstorage": f"{FULLNAME}-syncstorage",
    "ffs-admin": f"{FULLNAME}-admin",
    "fxa-db": f"{FULLNAME}-fxa-db",
    "fxa-redis": f"{FULLNAME}-fxa-redis",
    "fxa-auth": f"{FULLNAME}-fxa-auth",
    "fxa-profile": f"{FULLNAME}-fxa-profile",
    # (fxa-profile-worker: profile's WORKER_URL is 127.0.0.1, ALLOWED_DIFFERENCES)
    EXTDB: EXTDB,
}

# the compose files of Sync on each database (docs/install/compose.md#the-compose-files)
SYNC_FILES = {db: ["compose/sync.yml", f"compose/sync-{db}.yml"] for db in ("mariadb", "mysql", "postgres")}
# case -> compose files, .env values, helm values
CASES = {
    "mariadb": (SYNC_FILES["mariadb"], {}, ["--set", "database.backend=mariadb"]),
    "mysql": (SYNC_FILES["mysql"], {"SYNC_DB": "mysql"}, ["--set", "database.backend=mysql"]),
    "postgres": (SYNC_FILES["postgres"], {"SYNC_POSTGRES_APP_USER": "syncserver_app"}, ["--set", "database.backend=postgres"]),
    # your own server (docs/databases.md#your-own-server, prepare_environment.sh): no database containers, no TLS
    # check (MySQL's self-signed certificate); PostgreSQL without the Sync role
    # (the bootstrap account on: its password from the Secret, docs/databases.md#let-the-stack-apply-them)
    "external-mariadb": (SYNC_FILES["mariadb"],
                         {"SYNC_DB_CONTAINERS": "0", "SYNC_DB_TLS_VERIFY": "false", "SYNC_TOKENSERVER_DB_HOST": EXTDB,
                          "SYNC_STORAGE_DB_HOST": EXTDB, "SYNC_DB_BOOTSTRAP_USER": "ffs_bootstrap"},
                         ["--set", "database.backend=mariadb", "--set", "database.external.bootstrap.user=ffs_bootstrap"]),
    # (sync-mariadb.yml, as prepare_environment.sh writes for your own MySQL server: its client)
    "external-mysql": (SYNC_FILES["mariadb"],
                       {"SYNC_DB": "mysql", "SYNC_DB_CONTAINERS": "0", "SYNC_DB_TLS_VERIFY": "false",
                        "SYNC_TOKENSERVER_DB_HOST": EXTDB, "SYNC_STORAGE_DB_HOST": EXTDB, "SYNC_DB_BOOTSTRAP_PASSWORD": ""},
                       ["--set", "database.backend=mysql"]),
    "external-postgres": (SYNC_FILES["postgres"],
                          {"SYNC_DB_CONTAINERS": "0", "SYNC_POSTGRES_HOST": EXTDB, "SYNC_POSTGRES_APP_PASSWORD": "",
                           "SYNC_DB_BOOTSTRAP_PASSWORD": ""},
                          ["--set", "database.backend=postgres"]),
}
EXTERNAL_HELM = ["--set", "database.bundled=false", "--set", f"database.external.host={EXTDB}", "--set", "existingSecret=mine"]

# the self-hosted accounts: compose/fxa.yml and compose/fxa-<db>.yml on top, .env as prepare_environment.sh writes it
# for them, the matching values. The bundled accounts database without a policy user (its root
# installs the policy); the pairing server on (COMPOSE_PROFILES=pairing) but with your own server
# (ADMIN_UNCONFIRMED_HOURS: the chart passes it only when set, so set in both, 0 the edge)
FXA_ENV = {
    "FXA_CONTENT_URL": "https://accounts.example.test", "FXA_AUTH_URL": "https://api.example.test",
    "FXA_PROFILE_URL": "https://profile.example.test", "FXA_PAIRING_URL": "wss://pairing.example.test",
    "FXA_OAUTH_SERVER_URL": "http://fxa-auth:9000/v1", "FXA_EMAIL_DOMAIN": "api.example.test",
    "ADMIN_UNCONFIRMED_HOURS": "0",
}
FXA_HELM = ["--set", "fxa.enabled=true", "--set", "fxa.contentUrl=https://accounts.example.test",
            "--set", "fxa.authUrl=https://api.example.test", "--set", "fxa.profileUrl=https://profile.example.test",
            "--set", "fxa.pairing.url=wss://pairing.example.test", "--set", "admin.unconfirmedHours=0"]
FXA_BUNDLED_ENV = {**FXA_ENV, "FXA_MYSQL_POLICY_PASSWORD": ""}
FXA_PAIRING_HELM = FXA_HELM + ["--set", "fxa.pairing.enabled=true"]
# with the admin UI: signing in to it with the accounts (prepare_environment.sh's .env: the
# client id, the redirect URL, the trust in the accounts' emails, no other OpenID secret)
FXA_ADMIN_ENV = {
    "ADMIN_FXA_CLIENT_ID": "0123456789abcdef", "ADMIN_OIDC_REDIRECT_URL": "https://admin.example.test/auth/callback",
    "ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL": "true", "ADMIN_OIDC_CLIENT_SECRET": "", "ADMIN_ALLOWED_USERS": "you@example.test",
}
FXA_ADMIN_HELM = ["--set", "admin.fxaSignIn=true", "--set", "fxa.adminClientId=0123456789abcdef",
                  "--set", "admin.oidc.redirectUrl=https://admin.example.test/auth/callback",
                  "--set", "admin.allowed.users=you@example.test"]
FXA_FILES = SYNC_FILES["mariadb"] + ["compose/fxa.yml", "compose/fxa-mysql.yml"]
CASES.update({
    "fxa-mysql": (FXA_FILES, FXA_BUNDLED_ENV, ["--set", "database.backend=mariadb"] + FXA_PAIRING_HELM),
    # a MySQL 8 pin: compose's FXA_MYSQL_ARGS as prepare_environment.sh writes them for it
    "fxa-mysql8": (FXA_FILES, {**FXA_BUNDLED_ENV, "FXA_MYSQL_IMAGE": "mysql:8",
                               "FXA_MYSQL_ARGS": "--mysql-native-password=ON --authentication-policy=mysql_native_password"},
                   ["--set", "database.backend=mariadb", "--set", "fxa.database.image.mysql=docker.io/library/mysql:8"]
                   + FXA_PAIRING_HELM),
    # (also fxa.extraCaCerts: chart-only)
    "fxa-mariadb": (SYNC_FILES["mariadb"] + ["compose/fxa.yml", "compose/fxa-mariadb.yml"], {**FXA_BUNDLED_ENV, "FXA_DB": "mariadb"},
                    ["--set", "database.backend=mariadb", "--set", "fxa.database.backend=mariadb",
                     "--set", "fxa.extraCaCerts.configMap=ffs-test-ca"] + FXA_PAIRING_HELM),
    # your own accounts server, its users fxa and ffs_policy; a pairing server of your own elsewhere
    "fxa-external": (FXA_FILES, {**FXA_ENV, "FXA_DB_CONTAINERS": "0", "FXA_MYSQL_HOST": EXTDB, "FXA_MYSQL_USER": "fxa",
                                 "FXA_MYSQL_POLICY_USER": "ffs_policy", "FXA_DB_BOOTSTRAP_USER": "ffs_bootstrap"},
                     ["--set", "database.backend=mariadb", "--set", "fxa.database.bundled=false",
                      "--set", "fxa.database.external.bootstrap.user=ffs_bootstrap",
                      "--set", f"fxa.database.external.host={EXTDB}", "--set", "existingSecret=mine"] + FXA_HELM),
    "fxa-postgres": (SYNC_FILES["postgres"] + ["compose/fxa.yml", "compose/fxa-mysql.yml"],
                     {**FXA_BUNDLED_ENV, "SYNC_POSTGRES_APP_USER": "syncserver_app"},
                     ["--set", "database.backend=postgres"] + FXA_PAIRING_HELM),
})
# case -> the profiles it adds (to the admin UI's and the backups')
CASE_PROFILES = {c: ["pairing"] for c in FXA_PAIRING.split(",")}

SECRET = re.compile(r"s3cr3t(\d+)x")
# a secret in a normalized value: <secret:token number> (compose), <secret:key> (chart)
PLACEHOLDER = re.compile(r"<secret:([^>]*)>")


class Failures(list):
    def add(self, where, what):
        self.append(f"{where}: {what}")


def run(cmd, env=None):
    p = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if p.returncode != 0:
        sys.exit(f"{' '.join(cmd)} failed:\n{p.stderr}")
    return p.stdout


# --- the test .env: .env-example filled as tests/e2e.sh does it ---------------------------

def set_line(lines, name, value):
    """NAME=value of .env-example's names (the SYNC_ ones, docs/upgrading.md#renamed-settings)"""
    pattern = re.compile(rf"^{re.escape(name)}=")
    hits = [i for i, line in enumerate(lines) if pattern.match(line)]
    if not hits:
        # an optional one, commented out in .env-example (# FXA_PAIRING_URL=...): set
        commented = re.compile(rf"^#\s*{re.escape(name)}=")
        hits = [i for i, line in enumerate(lines) if commented.match(line)]
        for i in hits:
            lines[i] = re.sub(r"^#\s*", "", lines[i])
    if not hits:
        # appended, an old name compose reads only as a fallback: the case would test nothing
        sys.exit(f".env-example has no {name}: update helm_parity.py's CASES")
    for i in hits:
        lines[i] = lines[i].split("=", 1)[0] + "=" + value


def env_file(overrides, profiles):
    with open(os.path.join(REPO, ".env-example")) as f:
        lines = f.read().splitlines()
    out = []
    n = 0
    for line in lines:
        if re.match(r"^\s*#?\s*COMPOSE_FILE=", line):
            continue
        if re.match(r"^#\s*COMPOSE_PROFILES=", line):
            line = "COMPOSE_PROFILES=" + ",".join(profiles)
        m = re.match(r"^([A-Z][A-Z0-9_]*)=(.*)$", line)
        if m:
            name, value = m.groups()
            # every secret of .env, the optional ones too (the chart has them in its Secret):
            # one of its own each, recognizable in the values
            if "<REPLACE_WITH_SOMETHING_SECURE>" in value or (value == "" and re.search(r"(PASS|PASSWORD|SECRET|TOKEN|NOTIFY)$", name)):
                n += 1
                value = value.replace("<REPLACE_WITH_SOMETHING_SECURE>", f"s3cr3t{n}x") if value else f"s3cr3t{n}x"
            # what else is yours (the SMTP server and its sender...): unset, as the chart's
            # defaults (the Sync server's domain below)
            if "<REPLACE_WITH_" in value:
                value = ""
            line = f"{name}={value}"
        out.append(line)
    for name, value in dict(SYNC_PUBLIC_URL=f"https://{DOMAIN}", **overrides).items():
        set_line(out, name, value)
    return "\n".join(out) + "\n"


def compose_config(files, overrides, profiles):
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "test.env")
        with open(path, "w") as f:
            f.write(env_file(overrides, profiles))
        # nothing of this shell: .env alone (the shell wins over --env-file)
        env = {k: v for k, v in os.environ.items() if k in ("PATH", "HOME", "DOCKER_HOST", "DOCKER_CONFIG", "XDG_RUNTIME_DIR")}
        # (the project directory: compose/, the first file's, which the paths in the files are relative to)
        cmd = ["docker", "compose", "-p", "ffs-parity", "--env-file", path]
        for f_ in files:
            cmd += ["-f", os.path.join(REPO, f_)]
        return json.loads(run(cmd + ["config", "--format", "json"], env=env))["services"]


def helm_template(args):
    out = run(["helm", "template", RELEASE, CHART, "--set", f"syncDomain=https://{DOMAIN}"] + args)
    return [d for d in yaml.safe_load_all(out) if d]


# --- normalization ------------------------------------------------------------------------

def hosts(name, value, names):
    """the hosts of a value (all of it for a host's variable, or of its URLs) as <host:compose service>"""
    if re.search(r"(_HOST|_SERVER)$", name) and value in names:
        return f"<host:{names[value]}>"
    return re.sub(r"(://(?:[^/@\s]*@)?)([A-Za-z0-9_.-]+)",
                  lambda m: m.group(1) + (f"<host:{names[m.group(2)]}>" if m.group(2) in names else m.group(2)), value)


COMPOSE_HOSTS = {k: k for k in HOSTS}
CHART_HOSTS = {v: k for k, v in HOSTS.items()}


def compose_env(service):
    env = {}
    for name, value in (service.get("environment") or {}).items():
        # (compose's $$ is its escape of $: the container's value)
        value = "" if value is None else str(value).replace("$$", "$")
        env[name] = SECRET.sub(lambda m: f"<secret:{m.group(1)}>", hosts(name, value, COMPOSE_HOSTS))
    return env


def chart_env(container, where, failures):
    """name -> value, a secretKeyRef as <secret:key>, $(VAR) of an earlier variable expanded
    as Kubernetes does"""
    env = {}
    for e in container.get("env") or []:
        name = e["name"]
        if "value" in e or "valueFrom" not in e:
            value = hosts(name, str(e.get("value", "")), CHART_HOSTS)

            def ref(m):
                # (Kubernetes' escape of $, as compose's)
                if m.group(0) == "$$":
                    return "$"
                var = m.group(1)
                if var not in env:
                    failures.add(where, f"{name}: $({var}) before {var} is defined (Kubernetes leaves it as it is)")
                    return m.group(0)
                return env[var]
            env[name] = re.sub(r"\$\$|\$\(([A-Za-z_][A-Za-z0-9_]*)\)", ref, value)
        elif "secretKeyRef" in e["valueFrom"]:
            env[name] = f"<secret:{e['valueFrom']['secretKeyRef']['key']}>"
        else:
            env[name] = "<from:" + json.dumps(e["valueFrom"], sort_keys=True) + ">"
    return env


class Secrets:
    """compose's secrets (token numbers) against the chart's (keys of the Secret): one key per
    secret of .env and the other way round"""

    def __init__(self):
        self.key_of, self.token_of = {}, {}

    def same(self, compose, chart, where, failures):
        """compose and chart values equal, but for their secrets, which must pair up"""
        cparts, hparts = PLACEHOLDER.split(compose), PLACEHOLDER.split(chart)
        # literal, secret, literal, secret...
        if len(cparts) != len(hparts) or cparts[0::2] != hparts[0::2]:
            return False
        for token, key in zip(cparts[1::2], hparts[1::2]):
            if self.key_of.setdefault(token, key) != key:
                failures.add(where, f"compose's secret {token} is the Secret's {key} here, {self.key_of[token]} elsewhere")
            if self.token_of.setdefault(key, token) != token:
                failures.add(where, f"the Secret's {key} is compose's secret {token} here, {self.token_of[key]} elsewhere")
        return True


def duration(s):
    if not s:
        return 0
    total = 0.0
    for num, unit in re.findall(r"([\d.]+)(h|ms|m|s|us|ns)", s):
        total += float(num) * {"h": 3600, "m": 60, "s": 1, "ms": 1e-3, "us": 1e-6, "ns": 1e-9}[unit]
    return total


def expand(s, env):
    """${VAR} and $VAR of a shell command, from the container's env"""
    return re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)",
                  lambda m: env.get(m.group(1) or m.group(2), m.group(0)), s)


def check_of_exec(command, env):
    command = list(command)
    if len(command) == 3 and command[0] in ("sh", "/bin/sh") and command[1] == "-c":
        return ("exec",) + tuple(shlex.split(expand(command[2], env)))
    return ("exec",) + tuple(command)


def compose_check(hc, env):
    test = hc.get("test") or []
    if not test or test[0] == "NONE" or hc.get("disable"):
        return None
    if test[0] == "CMD-SHELL":
        check = check_of_exec(["sh", "-c", test[1].replace("$$", "$")], env)
    else:
        args = [a.replace("$$", "$") for a in test[1:]]
        m = re.match(r"^https?://(?:localhost|127\.0\.0\.1):(\d+)(/.*)$", args[-1]) if args and args[0] == "curl" else None
        if not m and len(args) == 3 and args[:2] == ["node", "-e"]:
            m = next((p.match(args[2]) for p, _ in EQUIVALENT_CHECK_PATTERNS if p.match(args[2])), None)
        check = ("http", m.group(1), m.group(2)) if m else check_of_exec(args, env)
    if check in EQUIVALENT_CHECKS:
        check = EQUIVALENT_CHECKS[check][0]
    return check


def chart_check(probe, container, env):
    if "exec" in probe:
        # the kubelet expands an exec probe's command as a container's: $$ is $
        return check_of_exec([a.replace("$$", "$") for a in probe["exec"]["command"]], env)
    if "httpGet" in probe:
        port = probe["httpGet"]["port"]
        for p in container.get("ports") or []:
            if p.get("name") == port:
                port = p["containerPort"]
        return ("http", str(port), probe["httpGet"].get("path", "/"))
    if "tcpSocket" in probe:
        port = probe["tcpSocket"]["port"]
        for p in container.get("ports") or []:
            if p.get("name") == port:
                port = p["containerPort"]
        return ("tcp", str(port))
    return ("other", json.dumps(probe, sort_keys=True))


# --- the comparison -----------------------------------------------------------------------

def workloads(docs):
    """(kind, name, container name) -> (container, is init)"""
    out = {}
    for d in docs:
        kind = d.get("kind")
        if kind not in ("Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"):
            continue
        spec = (d["spec"].get("jobTemplate") or {}).get("spec", d["spec"])["template"]["spec"]
        for init, key in ((True, "initContainers"), (False, "containers")):
            for c in spec.get(key) or []:
                out[(kind, d["metadata"]["name"], c["name"])] = (c, init)
    return out


def compare(case, label, services, docs, used, failures):
    """case: the key of CASES, label: it with the admin UI and backups on or off"""
    containers = workloads(docs)
    secrets = Secrets()
    paired = set()
    paired_services = set()

    def allowed(prefix, what, table=ALLOWED_DIFFERENCES):
        key = entry(table, case, f"{prefix}/{what}" if what else prefix)
        if key:
            used.add((key, case))
        return key

    for service_name, kind, workload, cname, prefix, one_shot in PAIRS:
        service = services.get(service_name)
        if service is not None and (service.get("deploy") or {}).get("replicas") == 0:
            service = None
        found = containers.get((kind, workload, cname))
        where = f"{label}: {service_name} -> {kind} {workload}/{cname}"
        if service is None and found is None:
            continue
        if service is not None:
            paired_services.add(service_name)
        if found is None and allowed(service_name, None, COMPOSE_ONLY_SERVICES):
            continue
        if service is None or found is None:
            failures.add(where, "in compose only" if found is None else "in the chart only")
            continue
        paired.add((kind, workload, cname))
        container, init = found
        if one_shot != init and kind != "CronJob":
            failures.add(where, f"{'an init' if init else 'a long-running'} container for a compose service that {'runs once' if one_shot else 'keeps running'}")

        # the variables: compose's entrypoint exports (syncstorage's SYNC_STATSD_*) count as
        # compose's where the chart has the variable
        cenv = compose_env(service)
        script = "\n".join((service.get("entrypoint") or []) + (service.get("command") or []))
        exports = {}
        for line in script.splitlines():
            m = re.match(r"^\s*export\s+(.*)$", line)
            if m:
                for assign in shlex.split(m.group(1)):
                    if "=" in assign:
                        k, v = assign.split("=", 1)
                        exports[k] = hosts(k, v, COMPOSE_HOSTS)
        henv = chart_env(container, where, failures)
        for name in sorted(set(cenv) | set(henv)):
            if name not in henv:
                if not allowed(prefix, name):
                    failures.add(where, f"{name} in compose only")
                continue
            if name not in cenv:
                if allowed(prefix, name, ALLOWED_CHART_SECRETS):
                    if not PLACEHOLDER.fullmatch(henv[name]):
                        failures.add(where, f"{name}: {henv[name]!r}, not from the Secret (ALLOWED_CHART_SECRETS)")
                    continue
                if name in exports:
                    if not secrets.same(exports[name], henv[name], where, failures):
                        failures.add(where, f"{name}: compose's entrypoint exports {exports[name]!r}, the chart has {henv[name]!r}")
                    if not allowed(prefix, name):
                        failures.add(where, f"{name} in compose's entrypoint script only")
                    continue
                # a password the chart passes on its own for a $(VAR) of another variable
                if not allowed(prefix, name):
                    failures.add(where, f"{name} in the chart only")
                continue
            if not secrets.same(cenv[name], henv[name], where, failures) and not allowed(prefix, name):
                failures.add(where, f"{name}: compose {cenv[name]!r}, chart {henv[name]!r}")
        # the chart-only variables allowed as passwords for $(VAR) must be used so
        for name in set(henv) - set(cenv) - set(exports):
            if entry(ALLOWED_CHART_SECRETS, case, f"{prefix}/{name}"):
                continue
            if name.endswith("PASSWORD") and not any(f"$({name})" in str(e.get("value", "")) for e in container.get("env") or []):
                failures.add(where, f"{name} in the chart only, and no $({name}) uses it")

        # the command: compose's entrypoint and command, the chart's command and args
        want = [service.get("entrypoint"), service.get("command")]
        got = [container.get("command"), container.get("args")]
        if want != got:
            key = allowed(prefix, None, ALLOWED_COMMANDS)
            if not key:
                failures.add(where, f"command: compose {json.dumps(want)}, chart {json.dumps(got)}")
            elif got != ALLOWED_COMMANDS[key][0]:
                failures.add(where, f"command: {json.dumps(got)}, not {json.dumps(ALLOWED_COMMANDS[key][0])} ({key})")

        # the working directory
        if service.get("working_dir") != container.get("workingDir"):
            failures.add(where, f"working directory: compose {service.get('working_dir')!r}, chart {container.get('workingDir')!r}")

        # the probes: compose's check in every one of them; its timings in each, but those
        # allowed to differ (and in one at least)
        if one_shot:
            continue
        hc = service.get("healthcheck") or {}
        want_check = compose_check(hc, cenv)
        probes = {k: container[k] for k in ("startupProbe", "readinessProbe", "livenessProbe") if k in container}
        if want_check is None:
            if probes:
                failures.add(where, f"probes {sorted(probes)}, compose has no healthcheck")
            continue
        if "readinessProbe" not in probes or "livenessProbe" not in probes:
            failures.add(where, f"a readinessProbe and a livenessProbe needed, it has {sorted(probes)}")
        timings = (duration(hc.get("interval") or "30s"), duration(hc.get("timeout") or "30s"), hc.get("retries", 3))
        start = duration(hc.get("start_period"))
        matching = []
        for kind_, probe in probes.items():
            got_check = chart_check(probe, container, henv)
            want_s, got_s = json.dumps(want_check), json.dumps(got_check)
            if not secrets.same(want_s, got_s, where, failures):
                key = allowed(prefix, kind_, ALLOWED_PROBE_CHECKS)
                if not key:
                    failures.add(where, f"{kind_} checks {got_check}, compose's healthcheck {want_check}")
                elif tuple(got_check) != ALLOWED_PROBE_CHECKS[key][0]:
                    failures.add(where, f"{kind_} checks {got_check}, not {ALLOWED_PROBE_CHECKS[key][0]} ({key})")
            got_t = (probe.get("periodSeconds", 10), probe.get("timeoutSeconds", 1), probe.get("failureThreshold", 3))
            key = allowed(prefix, kind_, ALLOWED_PROBE_TIMINGS)
            if key:
                if got_t != ALLOWED_PROBE_TIMINGS[key][0]:
                    failures.add(where, f"{kind_} every {got_t[0]} s, timeout {got_t[1]} s, {got_t[2]} failures; "
                                        f"not {ALLOWED_PROBE_TIMINGS[key][0]} ({key})")
            elif got_t == timings:
                matching.append(kind_)
            else:
                failures.add(where, f"{kind_} every {got_t[0]} s, timeout {got_t[1]} s, {got_t[2]} failures; "
                                    f"compose's healthcheck every {timings[0]:g} s, timeout {timings[1]:g} s, {timings[2]} retries")
        if not matching:
            failures.add(where, f"no probe with compose's healthcheck timings {timings}")
        # compose's start_period: within the startupProbe's time, or before the first check
        if start:
            window = 0
            if "startupProbe" in probes:
                p = probes["startupProbe"]
                window = p.get("initialDelaySeconds", 0) + p.get("periodSeconds", 10) * p.get("failureThreshold", 3)
            window = max([window] + [probes[k].get("initialDelaySeconds", 0) for k in matching])
            if window < start:
                failures.add(where, f"compose's start_period {start:g} s, the chart's probes count failures after {window} s")

    for key, (container, init) in containers.items():
        if key in paired:
            continue
        where = f"{label}: {key[0]} {key[1]}/{key[2]}"
        match = None
        for k in CHART_ONLY_CONTAINERS:
            ok, rest = in_scope(k, case)
            kind, workload, cname = rest.split("/")
            if ok and kind == key[0] and cname == key[2] and re.fullmatch(workload, key[1]):
                match = k
        if not match:
            failures.add(where, "no compose service for this container")
            continue
        used.add((match, case))
        # no env, but the chart-only secrets of ALLOWED_CHART_SECRETS
        if container.get("envFrom"):
            failures.add(where, f"envFrom in a chart-only container ({match})")
        for e in container.get("env") or []:
            secret = allowed(key[2], e["name"], ALLOWED_CHART_SECRETS)
            if not secret:
                failures.add(where, f"env in a chart-only container ({match}): {e['name']}")
            elif "secretKeyRef" not in (e.get("valueFrom") or {}):
                failures.add(where, f"{e['name']}: not from the Secret ({secret})")

    # the chart's objects compose has nothing for, of CHART_ONLY_KINDS
    for d in docs:
        if d.get("kind") not in CHART_ONLY_KINDS:
            continue
        name = f"{d['kind']}/{d['metadata']['name']}"
        match = None
        for k in CHART_ONLY_OBJECTS:
            ok, rest = in_scope(k, case)
            kind, pattern = rest.split("/", 1)
            if ok and kind == d["kind"] and re.fullmatch(pattern, d["metadata"]["name"]):
                match = k
        if match:
            used.add((match, case))
        else:
            failures.add(f"{label}: {name}", "chart-only, not in CHART_ONLY_OBJECTS")

    # every compose service is a chart container (but the database containers of your own server)
    for name, service in services.items():
        if name not in paired_services and (service.get("deploy") or {}).get("replicas") != 0 \
                and not entry(COMPOSE_ONLY_SERVICES, case, name):
            failures.add(f"{label}: {name}", "a compose service the chart has no container for")


def main(argv):
    cases = argv or list(CASES)
    failures = Failures()
    used = set()
    for path, original in IDENTICAL_FILES.items():
        with open(os.path.join(REPO, path), "rb") as a, open(os.path.join(REPO, original), "rb") as b:
            if a.read() != b.read():
                failures.add(path, f"differs from {original}")
    for case in cases:
        if case not in CASES:
            sys.exit(f"unknown case {case}: {' '.join(CASES)}")
        files, overrides, helm_args = CASES[case]
        if case.startswith("external-"):
            helm_args = helm_args + EXTERNAL_HELM
        fxa = case.startswith("fxa-")
        for admin in (True, False):
            for backup in (True, False):
                profiles = [p for p, on in (("admin", admin), ("backup", backup)) if on]
                name = f"{case} ({'+'.join(profiles) or 'no admin, no backup'})"
                env, args = dict(overrides), list(helm_args)
                if fxa and admin:
                    env.update(FXA_ADMIN_ENV)
                    args += FXA_ADMIN_HELM
                services = compose_config(files, env, profiles + CASE_PROFILES.get(case, []))
                docs = helm_template(args + ["--set", f"admin.enabled={str(admin).lower()}", "--set", f"backup.enabled={str(backup).lower()}"])
                before = len(failures)
                compare(case, name, services, docs, used, failures)
                print(("✓ " if len(failures) == before else "✗ ") + name)
    # each entry with its reason, used by every case it is for
    for table in ("ALLOWED_DIFFERENCES", "ALLOWED_CHART_SECRETS", "COMPOSE_ONLY_SERVICES", "CHART_ONLY_OBJECTS",
                  "CHART_ONLY_CONTAINERS", "ALLOWED_COMMANDS", "ALLOWED_PROBE_TIMINGS", "ALLOWED_PROBE_CHECKS"):
        for key, value in globals()[table].items():
            why = value if isinstance(value, str) else value[1]
            if not (isinstance(why, str) and why.strip()):
                failures.add(table, f"{key}: no reason")
    for table in ("ALLOWED_DIFFERENCES", "ALLOWED_CHART_SECRETS", "ALLOWED_COMMANDS", "ALLOWED_PROBE_TIMINGS",
                  "ALLOWED_PROBE_CHECKS", "CHART_ONLY_CONTAINERS", "COMPOSE_ONLY_SERVICES", "CHART_ONLY_OBJECTS"):
        for key in globals()[table]:
            unused = [c for c in cases if in_scope(key, c)[0] and (key, c) not in used]
            if unused:
                failures.add(table, f"{key} is used by no render of {', '.join(unused)}: narrow it or drop it")
    for f in failures:
        print("✗ " + f)
    if failures:
        return 1
    print(f"✓ the chart's env, commands, working directories and probes match compose's ({', '.join(cases)}; admin UI and "
          "backups on and off); "
          f"{', '.join(IDENTICAL_FILES)} identical to compose's")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
