#!/bin/bash
# Rootless podman test: docker compose on the Podman socket (MariaDB and PostgreSQL) and
# quadlets (MariaDB; MySQL and PostgreSQL rendered only), set up with prepare_environment.sh exactly like a user would.
# Needs rootless podman, docker compose (v2, no Docker daemon) and a systemd user session.
#
# Usage: tests/podman.sh
# Environment:
#   REPOSITORY  image repository (default: ghcr.io/porelli/firefox-sync)
#   TAG         tag suffix of both the app and init images (default: latest)
#   PORT        host port (default: 28660)
#   SLOT        runs next to each other on one host (tests/slot.sh): 1000 * SLOT added to the
#               ports (default 0). The Quadlets' units, containers and volumes have the names
#               of a user's install: one run of this test at a time per user in any case
#   INIT_TAG    tag suffix of the init images (default: TAG), e.g. ones built from this tree
#   SKIP_FXA    set to 1 to skip the quadlets with self-hosted accounts
#   EXTERNAL_DB set to 1: the quadlets also on a server of SYNC_DB outside them (SYNC_DB_CONTAINERS=0)
#   FXA_DB      mysql (default) or mariadb: the accounts database of the quadlets with accounts
#   FXA_MYSQL_FROM, FXA_MARIADB_FROM  e.g. mysql:8 (with mysql_native_password, as the installs from
#               before) or mariadb:11: the quadlets with accounts start their database on it, then move
#               it to lts with the commands of docs/upgrading.md#mysql-8-to-9 or #mariadb
#   SYNC_MYSQL_FROM  e.g. mysql:8, with SYNC_DB=mysql: the quadlets' Sync databases start on it, then
#               move to mysql:lts as docs/upgrading.md#mysql-8-to-9 says
#   SYNC_DB     mariadb (default), mysql or postgres: the Sync databases of the compose and quadlet phases
#               (MySQL, compose/sync-mysql.yml and config/quadlet/sync-mysql/: compose as an
#               install from before on mysql:8, pinned by --upgrade; the quadlets on mysql:lts.
#               PostgreSQL, config/quadlet/sync-postgres/: compose with PostgreSQL only, the quadlets
#               on the major of postgres:latest, with its major guard); the MySQL and PostgreSQL
#               quadlets are rendered and checked in any case
#   ADMIN_IMAGE     admin UI image to test, used as is, pulled when not here (default: built from admin/)
#   FXA_TEST_IMAGE  accounts image to test with the quadlets (a local one of podman used as it is), e.g.
#                   ghcr.io/porelli/firefox-sync:fxa-mono-v1.347.1, or a digest (default: REPOSITORY:fxa-mono-latest)
#   UPGRADE_FROM    a checkout of an earlier release (e.g. git worktree add /tmp/ffs-from <tag>):
#                   the quadlets (SYNC_DB=mariadb) start as an install of it, its files, admin UI
#                   and init image (built from it), then are upgraded to this tree as docs/upgrading.md#with-quadlets
#                   says for the Quadlets, and checked as a new install
set -u

TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CODE=$(dirname "${TESTS}")
# shellcheck source=tests/slot.sh
source "${TESTS}/slot.sh"
REPOSITORY=${REPOSITORY:-ghcr.io/porelli/firefox-sync}
TAG=${TAG:-latest}
INIT_TAG=${INIT_TAG:-${TAG}}
PORT=${PORT:-$((28660 + SLOT_PORTS))}
# the admin UI, the sign-up gate, the accounts' pages and API
ADMIN_PORT=$((28690 + SLOT_PORTS)) GATE_PORT=$((28691 + SLOT_PORTS)) CONTENT_PORT=$((28630 + SLOT_PORTS)) AUTH_PORT=$((28600 + SLOT_PORTS))
WORK=$(mktemp -d)
export QUADLET_DIR=${WORK}/quadlets-unused  # replaced below for the quadlet phase
# the backup timer: a plain systemd unit
SYSTEMD_USER_DIR=${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user
FAILED=0
# compose_healthy, quadlets_healthy, health_parity: the healthchecks of the stack
# shellcheck source=tests/healthy.sh
source "${TESTS}/healthy.sh"
# fxa_image_fixed: whether the accounts image has a fix of upstream-patches.yml
# shellcheck source=tests/fxa_fix.sh
source "${TESTS}/fxa_fix.sh"

check() { if [ "$1" = "$2" ]; then echo "PASS: $3"; else echo "FAIL: $3 (expected '$2', got '$1')"; FAILED=1; return 1; fi; }
hb() {
  local c
  for _ in $(seq 1 90); do
    c=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/__heartbeat__")
    [ "${c}" = 200 ] && break
    sleep 2
  done
  echo "${c}"
}
ctr() { podman ps -a -q --filter "label=com.docker.compose.service=$1" | head -1; }
# a unit with the variables of its environment file (firefox-sync-<name>.env, the secrets), these
# as Environment= lines; unit_count <regex> <unit>...: the lines of each that match, counted
unit_env() { cat "$1"; [ ! -f "${1%.*}.env" ] || sed 's/^/Environment=/' "${1%.*}.env"; }
unit_count() { local re=$1 u; shift; for u in "$@"; do unit_env "${u}" | grep -cE "${re}"; done | paste -sd' '; }
# no secret of .env (secret_setting of prepare_environment.sh, a value of 6 characters or more) in
# a unit, the timers or the units' environment files of others than this user; each unit's
# EnvironmentFile= there: "none", or what is wrong
units_secret_free() {
  ( source ./prepare_environment.sh && SCRIPT_DIR=${PWD} || exit 1
    local key value f out=""
    while IFS= read -r key; do
      secret_setting "${key}" || continue
      value=$(env_plain "${key}")
      [ "${#value}" -ge 6 ] && [[ "${value}" != *"<REPLACE_WITH_"* ]] || continue
      for f in "${QUADLET_DIR}"/firefox-sync-*.container "${QUADLET_DIR}"/firefox-sync-*.volume "${QUADLET_DIR}"/firefox-sync-*.network "${SYSTEMD_USER_DIR:-${HOME}/.config/systemd/user}"/firefox-sync-*.timer; do
        [ -f "${f}" ] || continue
        grep -qF -- "${value}" "${f}" || grep -qF -- "${value//%/%%}" "${f}" && out="${out} ${key}:$(basename "${f}")"
      done
    done < <(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}\([A-Z][A-Z0-9_]*\)=.*/\2/p' .env | sort -u)
    for f in "${QUADLET_DIR}"/firefox-sync-*.env; do
      [ -f "${f}" ] || continue
      [ "$(stat -c %a "${f}")" = 600 ] || out="${out} $(basename "${f}"):$(stat -c %a "${f}")"
      grep -qxF "EnvironmentFile=${f}" "${f%.env}.container" || out="${out} $(basename "${f%.env}.container"):no-EnvironmentFile"
    done
    echo "${out:- none}" | sed 's/^ //' )
}
started() { date -d "$(podman inspect -f "{{.State.$2}}" "$1" | sed 's/ +0000 UTC//; s/ [A-Z]*$//')" +%s%N; }

diagnose() {
  echo "---- diagnostics"
  [ -n "${1:-}" ] && tail -40 "$1"
  podman ps -a --format '{{.Names}} {{.Status}}'
  for c in $(podman ps -a --format '{{.Names}}'); do
    echo "---- ${c} (health: $(podman inspect -f '{{.State.Health.Status}}' "${c}" 2> /dev/null))"
    podman logs --tail 15 "${c}" 2>&1
  done
  systemctl --user list-timers --all --no-pager 2> /dev/null | head -10
}

podman --version
systemctl --user enable --now podman.socket > /dev/null 2>&1
export DOCKER_HOST=unix://${XDG_RUNTIME_DIR}/podman/podman.sock
docker compose version
podman info --format 'rootless={{.Host.Security.Rootless}} selinux={{.Host.Security.SELinuxEnabled}} cgroups={{.Host.CgroupsVersion}}'

# the functions of prepare_environment.sh on their tables first, .env as docker compose reads it
"${TESTS}/prepare_functions.sh" > "${WORK}/prepare-functions.log" 2>&1
rc=$? env_rows=$(grep -c '^PASS: env_plain: ' "${WORK}/prepare-functions.log")
check "${rc} $(grep -c '^FAIL' "${WORK}/prepare-functions.log") $([ "${env_rows}" -gt 30 ] && echo rows) $(grep -c '^PASS: docker compose reads' "${WORK}/prepare-functions.log")" "0 0 rows ${env_rows}" \
  "tests/prepare_functions.sh, docker compose reads each value of its .env table as env_plain"
[ "${rc}" = 0 ] || grep -v '^PASS' "${WORK}/prepare-functions.log"

# a copy of the repository, configured by prepare_environment.sh
cp -r "${CODE}" "${WORK}/ffs" && cd "${WORK}/ffs" || exit 1
rm -f .env
# ports of its own, next to whatever else runs on this host
# (UPGRADE_FROM: a release from before the SYNC_ names, REPOSITORY and SYNCSTORAGE_INIT_IMAGE_TAG)
example() { sed -i -e "s|^IMAGE_REPOSITORY=.*|IMAGE_REPOSITORY=${REPOSITORY}|" -e "s|^REPOSITORY=.*|REPOSITORY=${REPOSITORY}|" \
       -e "s|^SYNC_INIT_IMAGE_TAG=.*|SYNC_INIT_IMAGE_TAG=${INIT_TAG}|" -e "s|^SYNCSTORAGE_INIT_IMAGE_TAG=.*|SYNCSTORAGE_INIT_IMAGE_TAG=${INIT_TAG}|" \
       -e "s|^ADMIN_EXPORT_PORT=.*|ADMIN_EXPORT_PORT=127.0.0.1:${ADMIN_PORT}|" \
       -e "s|^ADMIN_GATE_EXPORT_PORT=.*|ADMIN_GATE_EXPORT_PORT=127.0.0.1:${GATE_PORT}|" \
       -e "s|^ADMIN_METRICS_TOKEN=.*|ADMIN_METRICS_TOKEN=ffs-test-metrics-token|" \
       -e "s|^ADMIN_UPDATE_CHECK=.*|ADMIN_UPDATE_CHECK=false|" \
       -e "s|^ADMIN_PUBLIC_CHECK=.*|ADMIN_PUBLIC_CHECK=false|" \
       -e "s|^FXA_CONTENT_EXPORT_PORT=.*|FXA_CONTENT_EXPORT_PORT=127.0.0.1:${CONTENT_PORT}|" \
       -e "s|^FXA_AUTH_EXPORT_PORT=.*|FXA_AUTH_EXPORT_PORT=127.0.0.1:${AUTH_PORT}|" \
       -e "s|^FXA_PROFILE_EXPORT_PORT=.*|FXA_PROFILE_EXPORT_PORT=127.0.0.1:$((28611 + SLOT_PORTS))|" \
       -e "s|^FXA_PROFILE_STATIC_EXPORT_PORT=.*|FXA_PROFILE_STATIC_EXPORT_PORT=127.0.0.1:$((28612 + SLOT_PORTS))|" \
       -e "s|^FXA_PAIRING_EXPORT_PORT=.*|FXA_PAIRING_EXPORT_PORT=127.0.0.1:$((28658 + SLOT_PORTS))|" "$1/.env-example"; }
example .
# the admin UI under test, where compose and the quadlets look for it
if [ -n "${ADMIN_IMAGE:-}" ]; then
  { podman image exists "${ADMIN_IMAGE}" || podman pull -q "${ADMIN_IMAGE}" > build-admin.log 2>&1; } && podman tag "${ADMIN_IMAGE}" "${REPOSITORY}:admin-latest" >> build-admin.log 2>&1
else
  podman build -q --format docker -t "${REPOSITORY}:admin-latest" admin > build-admin.log 2>&1
fi
rc=$?; check "${rc}" 0 "admin UI image"; [ "${rc}" = 0 ] || tail -5 build-admin.log
# answers: domain, compose dir, port, max users, backend, deploy method, user, image tag, admin UI,
# accounts, your own database server, alerts' destination, nightly backups ($3, default n)
setup() { printf '%s\n' ffs-e2e.invalid "" "${PORT}" 1 "$1" "$2" "" "${TAG}" "" "" "" "" "${3:-n}" | ./prepare_environment.sh > "setup-$1-$2.log" 2>&1; }
admin_up() {
  local c
  for _ in $(seq 1 30); do
    c=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${ADMIN_PORT}$1")
    [ "${c}" = 200 ] && break
    sleep 2
  done
  echo "${c}"
}
# the admin UI checks the components every 5 s here, as in the other tests
# (HEALTH_CHECK_SECONDS, a minute by default): what it sees is there within seconds, not at
# its next round a minute later. For compose an override (ADMIN_TEST_COMPOSE), for the
# Quadlets a line in the admin UI's unit once its checks are done (fast_admin_checks)
ADMIN_TEST_COMPOSE=(-f "${WORK}/admin-test.yml")
printf 'services:\n  ffs-admin:\n    environment:\n      HEALTH_CHECK_SECONDS: 5\n' > "${WORK}/admin-test.yml"
fast_admin_checks() {
  sed -i '/^\[Container\]$/a Environment=HEALTH_CHECK_SECONDS=5' "${QUADLET_DIR}/firefox-sync-admin.container" && systemctl --user daemon-reload
}
# Prometheus metrics of the admin UI, retried until they have every line given (its first
# check of the Quadlets runs before the Sync server is up; a check can take 10 s more on a
# timeout): "all", or the first missing
metrics_show() {
  local m line missing
  for _ in $(seq 1 75); do
    m=$(curl -s -H 'Authorization: Bearer ffs-test-metrics-token' http://127.0.0.1:${ADMIN_PORT}/metrics)
    missing=""
    for line in "$@"; do grep -qxF "${line}" <<< "${m}" || { missing=${line}; break; }; done
    [ -z "${missing}" ] && break
    sleep 2
  done
  echo "${missing:-all}"
}
SYNC_DB=${SYNC_DB:-mariadb}
case "${SYNC_DB}" in mariadb|mysql|postgres) ;; *) echo "SYNC_DB: mariadb, mysql or postgres"; exit 2 ;; esac
SYNC_UP=('ffs_up{component="Sync server"} 1' 'ffs_up{component="Tokenserver database"} 1')
# signed in with the default Secure cookie over plain http: curl, like browsers, keeps
# it for localhost
admin_sign_in() {
  local jar=${WORK}/cookies-$1
  curl -s -o /dev/null -c "${jar}" --data-urlencode "password=$(grep '^ADMIN_PASSWORD=' .env | cut -d= -f2)" http://localhost:${ADMIN_PORT}/login
  curl -s -b "${jar}" http://localhost:${ADMIN_PORT}/ | grep -q 'Sign out' && echo yes
}

env_of() { grep "^$1=" .env | cut -d= -f2; }
# SQL in the tokenserver database (MariaDB, MySQL, PostgreSQL), as the user given
compose_sql() { # backend user password database query
  if [ "$1" = postgres ]; then
    podman exec -e PGPASSWORD="$3" "$(ctr postgres_db)" psql -h 127.0.0.1 -U "$2" -d "$4" -tA -c "$5"
  else
    podman exec -e MYSQL_PWD="$3" "$(ctr tokenserver_db)" sh -c 'exec "$(command -v mariadb || command -v mysql)" "$@"' sql -u"$2" "$4" -sN -e "$5"
  fi
}

# docker compose as the setup has it in .env (COMPOSE_FILE, COMPOSE_PROJECT_NAME), with the admin
# UI's test override (ADMIN_TEST_COMPOSE)
dcp() { env COMPOSE_FILE="$(env_of COMPOSE_FILE):${ADMIN_TEST_COMPOSE[1]}" docker compose "$@"; }
# (timeout runs commands, not functions)
dcp_timeout() { timeout "$1" env COMPOSE_FILE="$(env_of COMPOSE_FILE):${ADMIN_TEST_COMPOSE[1]}" docker compose "${@:2}"; }
compose_test() {
  local backend=$1 sync_user sync_password sync_db admin_password sync_role sync_role_password old_files new_files
  echo "== docker compose on the Podman socket (${backend})"
  setup "${backend}" 2
  check "$?" 0 "prepare_environment.sh (${backend}, compose)"
  new_files=compose/sync.yml:compose/sync-${backend}.yml:compose/podman.yml
  check "$(env_of COMPOSE_FILE) $(env_of COMPOSE_PROJECT_NAME) $(grep -c '^  3. docker compose up -d$' "setup-${backend}-2.log")" "${new_files} ffs 1" \
    "prepare_environment.sh writes COMPOSE_FILE (compose/podman.yml too) and the project's name, prints the compose command (${backend})"
  # first as an install from before ADMIN_DB_PASSWORD (the admin UI's tables in the
  # tokenserver database), then upgraded below
  admin_password=$(env_of ADMIN_DB_PASSWORD)
  check "$(echo "${admin_password}" | grep -cE '^[A-Za-z0-9]{32}$')" 1 "prepare_environment.sh generates ADMIN_DB_PASSWORD (${backend})"
  sed -i 's|^ADMIN_DB_PASSWORD=.*|ADMIN_DB_PASSWORD=|' .env
  # PostgreSQL: a new install is pinned to the major of postgres:latest; one from before ran 18
  # without SYNC_POSTGRES_IMAGE (--upgrade pins it below)
  if [ "${backend}" = postgres ]; then
    pg_major=$(podman run --rm --entrypoint postgres docker.io/library/postgres:latest --version 2> /dev/null | sed -n 's/^postgres (PostgreSQL) \([0-9]*\)[^0-9].*/\1/p')
    check "$(env_of SYNC_POSTGRES_IMAGE)" "postgres:${pg_major}" "prepare_environment.sh pins PostgreSQL to the major of postgres:latest (postgres, compose)"
    sed -i 's|^SYNC_POSTGRES_IMAGE=.*|SYNC_POSTGRES_IMAGE=postgres:18|' .env
  fi
  # MariaDB: a new install is on mariadb:lts; one from before ran it without SYNC_MARIADB_IMAGE
  if [ "${backend}" = mariadb ]; then
    check "$(env_of SYNC_MARIADB_IMAGE)" mariadb:lts "prepare_environment.sh writes SYNC_MARIADB_IMAGE=mariadb:lts (mariadb, compose)"
    sed -i '/^SYNC_MARIADB_IMAGE=/d' .env
  fi
  # MySQL: a new install is on mysql:lts; one from before ran mysql:8 without SYNC_MYSQL_IMAGE
  # (--upgrade pins it below)
  if [ "${backend}" = mysql ]; then
    check "$(env_of SYNC_MYSQL_IMAGE)" mysql:lts "prepare_environment.sh writes SYNC_MYSQL_IMAGE=mysql:lts (mysql, compose)"
    sed -i 's|^SYNC_MYSQL_IMAGE=.*|SYNC_MYSQL_IMAGE=mysql:8|' .env
  fi
  # PostgreSQL: before, the Sync server connected as SYNC_POSTGRES_USER, the container's superuser
  sync_role=$(env_of SYNC_POSTGRES_APP_USER) sync_role_password=$(env_of SYNC_POSTGRES_APP_PASSWORD)
  if [ "${backend}" = postgres ]; then
    check "${sync_role} $(echo "${sync_role_password}" | grep -cE '^[A-Za-z0-9]{32}$')" "syncserver_app 1" "prepare_environment.sh gives the Sync server a role of its own (postgres)"
    sed -i -e 's|^SYNC_POSTGRES_APP_USER=.*|SYNC_POSTGRES_APP_USER=|' -e 's|^SYNC_POSTGRES_APP_PASSWORD=.*|SYNC_POSTGRES_APP_PASSWORD=|' .env
  fi
  if [ "${backend}" = postgres ]; then
    sync_user=$(env_of SYNC_POSTGRES_USER) sync_password=$(env_of SYNC_POSTGRES_PASSWORD) sync_db=$(env_of SYNC_POSTGRES_NAME)
  else
    sync_user=$(env_of SYNC_TOKENSERVER_DB_USER) sync_password=$(env_of SYNC_TOKENSERVER_DB_PASSWORD) sync_db=$(env_of SYNC_TOKENSERVER_DB_NAME)
  fi
  # and from before the SYNC_ names of the settings (docs/upgrading.md#renamed-settings): the old
  # ones only, which compose still reads
  local pair old_lines
  for pair in "${RENAMED_SETTINGS[@]}"; do sed -i "s|^${pair%%=*}=|${pair#*=}=|" .env; done
  old_lines=$(grep -cE "^($(IFS='|'; echo "${RENAMED_SETTINGS[*]#*=}"))=" .env)
  dcp_timeout 600 up -d > "compose-${backend}.log" 2>&1
  check "$?" 0 "docker compose up, before ADMIN_DB_PASSWORD, with the old setting names (${backend})"
  check "$(podman logs "$(ctr tokenserver_db_init)" 2>&1 | grep -c 'WARNING: settings under their old names, in .env or in the environment docker compose runs in')" 1 "the init container warns of the old setting names (${backend})"
  check "$(admin_up /login)" 200 "admin UI before ADMIN_DB_PASSWORD (compose, ${backend})"
  compose_sql "${backend}" "${sync_user}" "${sync_password}" "${sync_db}" \
    "INSERT INTO ffs_events (at, kind, detail) VALUES ($(date +%s)000, 'admin', 'ffs-podman: before the upgrade by admin (password)')" > /dev/null
  check "$?" 0 "an audit event in the tokenserver database, as before (${backend})"
  # an install from before compose/ (docs/upgrading.md#files-that-moved): COMPOSE_FILE with the old
  # names, no COMPOSE_PROJECT_NAME. MariaDB: none, docker-compose.yml, which includes those of
  # compose/ now: the stack's containers as they are; PostgreSQL: the name before docker-compose.sync-postgres.yml
  # (the setup of before had docker-compose.podman.yml in its -f command only: none for MariaDB
  # and PostgreSQL, --upgrade adds compose/podman.yml as compose runs on the Podman socket here)
  case "${backend}" in
    mariadb) old_files="" ;;
    mysql) old_files=docker-compose.yml:docker-compose.podman.yml:docker-compose.sync-mysql.yml ;;
    postgres) old_files=docker-compose.postgres.yml ;;
  esac
  sed -i -e '/^COMPOSE_FILE=/d' -e '/^COMPOSE_PROJECT_NAME=/d' .env
  [ -z "${old_files}" ] || echo "COMPOSE_FILE=${old_files}" >> .env
  [ -n "${old_files}" ] || check "$(docker compose ps -q syncstorage) $(docker compose config --services | grep -cxE 'syncstorage|tokenserver_db|syncstorage_db')" \
    "$(podman ps -q --no-trunc --filter label=com.docker.compose.project=ffs --filter label=com.docker.compose.service=syncstorage) 3" \
    "no COMPOSE_FILE: docker-compose.yml runs Sync on MariaDB, and finds the stack's containers (mariadb)"
  [ "${backend}" != mysql ] || sed -i '/^SYNC_MYSQL_IMAGE=/d' .env
  # (the old names left, as counted for the rename below)
  if [ "${backend}" = postgres ]; then
    sed -i '/^\(SYNC_\)\{0,1\}POSTGRES_IMAGE=/d' .env
    old_lines=$(grep -cE "^($(IFS='|'; echo "${RENAMED_SETTINGS[*]#*=}"))=" .env)
  fi
  # the upgrade, as docs/upgrading.md#with-docker-compose says: prepare_environment.sh --upgrade fills in what is missing
  ./prepare_environment.sh --upgrade > "upgrade-${backend}.log" 2>&1
  check "$?" 0 "prepare_environment.sh --upgrade (${backend})"
  check "$(grep -cE "^($(IFS='|'; echo "${RENAMED_SETTINGS[*]#*=}"))=" .env) $(grep -c '^Renamed in .env' "upgrade-${backend}.log") $(grep -c '^  [A-Z_]* -> [A-Z_]*$' "upgrade-${backend}.log")" \
    "0 1 ${old_lines}" "--upgrade renames the old setting names, and says so (${backend})"
  check "$(env_of COMPOSE_FILE) $(env_of COMPOSE_PROJECT_NAME) $(grep -c '^COMPOSE_FILE: the compose files moved to compose/' "upgrade-${backend}.log") $(grep -c '^COMPOSE_FILE: docker compose on the Podman socket: compose/podman.yml added' "upgrade-${backend}.log")" \
    "${new_files} ffs 1 $([ "${backend}" = mysql ] && echo 0 || echo 1)" \
    "--upgrade: COMPOSE_FILE ${old_files:-not set} with the files of compose/ and compose/podman.yml, the project's name, and says so (${backend})"
  check "$(env_of ADMIN_DB_PASSWORD | grep -cE '^[A-Za-z0-9]{32}$') $([ "${backend}" != postgres ] || env_of SYNC_POSTGRES_APP_USER)" \
    "1 $([ "${backend}" != postgres ] || echo syncserver_app)" "--upgrade generates the missing passwords (${backend})"
  [ "${backend}" != postgres ] || check "$(env_of SYNC_POSTGRES_IMAGE)" "postgres:18" "--upgrade writes SYNC_POSTGRES_IMAGE=postgres:18 for PostgreSQL (postgres)"
  [ "${backend}" != mysql ] || check "$(env_of FXA_DB | grep -c mariadb)" "0" "no FXA_MARIADB_IMAGE for MariaDB backend without accounts (${backend})"
  # MariaDB: an install from before SYNC_MARIADB_IMAGE, pinned to the major of its data
  if [ "${backend}" = mariadb ]; then
    mariadb_major=$(podman exec "$(ctr tokenserver_db)" mariadbd --version 2> /dev/null | sed -n 's/.* Ver \([0-9]*\)\..*/\1/p')
    check "$(env_of SYNC_MARIADB_IMAGE) $(grep -c "Sync databases stay on MariaDB ${mariadb_major}," "upgrade-${backend}.log")" "mariadb:${mariadb_major} 1" \
      "--upgrade pins the Sync MariaDB of an install from before to the major of its data (mariadb)"
  fi
  [ "${backend}" != mysql ] || check "$(env_of SYNC_MYSQL_IMAGE) $(grep -c 'Sync databases stay on MySQL 8' "upgrade-${backend}.log") $(env_of FXA_MYSQL_IMAGE)" "mysql:8 1 " \
    "--upgrade pins the Sync databases of an install from before on MySQL 8, nothing for the accounts it has not (mysql)"
  admin_password=$(env_of ADMIN_DB_PASSWORD)
  dcp_timeout 600 up -d >> "compose-${backend}.log" 2>&1
  check "$?" 0 "docker compose up (${backend})"
  check "$(hb)" 200 "/__heartbeat__ (compose, ${backend})"
  check "$(podman inspect -f '{{.State.ExitCode}}' "$(ctr syncstorage_migrate)")" 0 "migrate container exit code (${backend})"
  check "$(podman inspect -f '{{.State.ExitCode}}' "$(ctr tokenserver_db_init)")" 0 "init container exit code (${backend})"
  check "$([ "$(started "$(ctr syncstorage)" StartedAt)" -gt "$(started "$(ctr tokenserver_db_init)" FinishedAt)" ] && echo yes)" yes \
    "syncstorage started after the init (compose, ${backend})"
  check "$(admin_up /login)" 200 "admin UI (compose, ${backend})"
  check "$(admin_sign_in "${backend}")" yes "admin UI sign-in over http://localhost (compose, ${backend})"
  if [ "${backend}" != postgres ]; then
    check "$(metrics_show "${SYNC_UP[@]}" 'ffs_up{component="Storage database"} 1')" all "admin UI reaches the Sync server and its databases (compose, ${backend})"
  else
    check "$(metrics_show "${SYNC_UP[@]}")" all "admin UI reaches the Sync server and its database (compose, ${backend})"
  fi
  # (once more, restarted with the admin UI of the upgrade)
  check "$([ "$(podman logs "$(ctr syncstorage)" 2>&1 | grep -c 'Sending metrics to the admin UI')" -ge 1 ] && echo yes)" yes "Sync server sends metrics to the admin UI (compose, ${backend})"
  # the upgrade moved the event log into the admin UI's own database, out of the Sync user's reach
  admin_events() { compose_sql "${backend}" "$(env_of ADMIN_DB_USER)" "${admin_password}" "$(env_of ADMIN_DB_NAME)" "SELECT COUNT(*) FROM ffs_events WHERE detail LIKE '$1'"; }
  for _ in $(seq 1 30); do [ "$(admin_events 'ffs-podman: before the upgrade%' 2> /dev/null)" = 1 ] && break; sleep 2; done
  check "$(admin_events 'ffs-podman: before the upgrade%') $(admin_events 'Moved the admin UI%')" "1 1" "the audit trail of before moved into the admin UI's database (compose, ${backend})"
  check "$([ "$(admin_events '%')" -gt 2 ] && echo yes)" yes "the admin UI records its events there (compose, ${backend})"
  if [ "${backend}" = postgres ]; then
    # the Sync server's own role, no superuser, owns the Sync tables and cannot reach ffs_admin
    sync_role=$(env_of SYNC_POSTGRES_APP_USER) sync_role_password=$(env_of SYNC_POSTGRES_APP_PASSWORD)
    check "$(compose_sql postgres "${sync_role}" "${sync_role_password}" "${sync_db}" "SELECT rolsuper || ' ' || (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE relname = 'users' AND relnamespace = 'public'::regnamespace) FROM pg_roles WHERE rolname = current_user")" \
      "false ${sync_role}" "the Sync server's role is no superuser and owns the Sync tables (compose, postgres)"
    check "$(compose_sql postgres "${sync_role}" "${sync_role_password}" "$(env_of ADMIN_DB_NAME)" "SELECT 1" 2>&1 | grep -c 'permission denied')" 1 \
      "the Sync server's role cannot connect to the admin UI's database (compose, postgres)"
    check "$(compose_sql postgres "$(env_of ADMIN_DB_USER)" "${admin_password}" "$(env_of ADMIN_DB_NAME)" "SELECT pg_get_userbyid(datdba) || ' ' || has_database_privilege('public', datname, 'CONNECT') FROM pg_database WHERE datname = current_database()")" \
      "$(env_of ADMIN_DB_USER) false" "the admin UI's database is its role's, closed to PUBLIC (compose, postgres)"
  else
    check "$(compose_sql "${backend}" "${sync_user}" "${sync_password}" "${sync_db}" "SELECT COUNT(*) FROM $(env_of ADMIN_DB_NAME).ffs_events" 2>&1 | grep -c 'denied')" 1 \
      "the tokenserver user cannot read the event log (compose, ${backend})"
    check "$(compose_sql "${backend}" "${sync_user}" "${sync_password}" "${sync_db}" "INSERT INTO $(env_of ADMIN_DB_NAME).ffs_events (at, kind, detail) VALUES (1, 'admin', 'forged')" 2>&1 | grep -c 'denied')" 1 \
      "the tokenserver user cannot write the event log (compose, ${backend})"
  fi
  podman logs "$(ctr tokenserver_db_init)" 2>&1 | grep -E "Max users|ERROR"
  check "$(compose_healthy 300 dcp)" "all healthy" "every long-running container healthy, the one-shot ones exited 0 (compose, ${backend})"
  [ "${FAILED}" = 0 ] || diagnose "compose-${backend}.log"
  dcp down -v > /dev/null 2>&1
}
# (SYNC_DB=postgres: compose with PostgreSQL only, MariaDB's is the default run's)
[ "${SYNC_DB}" = postgres ] || compose_test "${SYNC_DB}"
compose_test postgres

echo "== where the Sync server listens: on this host only by default (nothing started)"
# answers as setup, the port: the default, a port alone, another address, not a port
port_setup() { printf '%s\n' ffs-e2e.invalid "" "$1" 1 mariadb 2 "" "${TAG}" "" "" "" "" n | ./prepare_environment.sh > setup-port.log 2>&1; }
rm -f .env .env.before-setup-*
port_setup ""
check "$? $(env_of SYNC_EXPORT_PORT) $(grep -c '^    proxy_pass http://127\.0\.0\.1:5000;$' config/nginx/syncstorage-rs.conf)" "0 127.0.0.1:5000 1" \
  "a new install: SYNC_EXPORT_PORT=127.0.0.1:5000, nginx proxies to it"
port_setup 5001
check "$? $(env_of SYNC_EXPORT_PORT) $(grep -c '^    proxy_pass http://127\.0\.0\.1:5001;$' config/nginx/syncstorage-rs.conf)" "0 127.0.0.1:5001 1" "a port alone: on 127.0.0.1"
port_setup 0.0.0.0:5002
check "$? $(env_of SYNC_EXPORT_PORT) $(grep -c '^    proxy_pass http://127\.0\.0\.1:5002;$' config/nginx/syncstorage-rs.conf)" "0 0.0.0.0:5002 1" "0.0.0.0:<port>: every interface, nginx on 127.0.0.1"
# run again on an install from before (a port alone in its .env: every interface), it keeps it
sed -i 's|^SYNC_EXPORT_PORT=.*|SYNC_EXPORT_PORT=5003|' .env
port_setup ""
newest_backup() { ls -1 "$1"-* 2> /dev/null | LC_ALL=C sort | tail -n 1; }
check "$? $(env_of SYNC_EXPORT_PORT) $(grep -c '^    proxy_pass http://127\.0\.0\.1:5003;$' config/nginx/syncstorage-rs.conf) $(grep -c '^SYNC_EXPORT_PORT=5003$' "$(newest_backup .env.before-setup)")" "0 5003 1 1" \
  "run again on an install: its SYNC_EXPORT_PORT kept, the .env of before as .env.before-setup-<time>"
# every run on an .env keeps its own copy (3 runs over one), the first one's passwords too; .env
# and its copies for this user only
first_setup=$(ls -1 .env.before-setup-* | LC_ALL=C sort | head -n 1)
check "$(ls -1 .env.before-setup-* | wc -l) $(grep -c '^SYNC_EXPORT_PORT=127.0.0.1:5000$' "${first_setup}") $(stat -c %a .env .env.before-setup-* | sort -u | paste -sd' ')" "3 1 600" \
  "a copy of .env for each setup run on it, none overwritten, .env and the copies 0600"
cp -p .env "${WORK}/port.env"
port_setup localhost:5004
check "$? $(grep -c "^ERROR: not a port or an address and port: 'localhost:5004'" setup-port.log) $(cmp -s .env "${WORK}/port.env" && echo kept)" "1 1 kept" "not a port: refused, .env as it was"
port_setup 256.1.1.1:5004
check "$? $(grep -c "^ERROR: not a port or an address and port: '256.1.1.1:5004'" setup-port.log)" "1 1" "an octet over 255: refused"
port_setup '[::]:5005'
check "$? $(env_of SYNC_EXPORT_PORT) $(grep -c '^    proxy_pass http://\[::1\]:5005;$' config/nginx/syncstorage-rs.conf)" "0 [::]:5005 1" "[::]:<port>: every interface (IPv6 too), nginx on [::1]"
# a value of an .env of before this script does not know: kept, said
sed -i 's|^SYNC_EXPORT_PORT=.*|SYNC_EXPORT_PORT=localhost:5006|' .env
port_setup ""
check "$? $(env_of SYNC_EXPORT_PORT) $(grep -c "^WARNING: SYNC_EXPORT_PORT='localhost:5006' of .env is not" setup-port.log)" "0 localhost:5006 1" "an unknown SYNC_EXPORT_PORT of .env: kept, with a warning"
port_setup '[:]:5000'
check "$? $(grep -c "^ERROR: not a port or an address and port: '\[:\]:5000'" setup-port.log)" "1 1" "not an IPv6 address ([:]): refused"
# .env a symlink (e.g. to a directory of secrets): it stays one, the file it names is written, 0600
mkdir -p "${WORK}/secrets" && mv .env "${WORK}/secrets/ffs.env" && ln -s "${WORK}/secrets/ffs.env" .env
port_setup 5007
check "$? $([ -L .env ] && echo link) $(grep -c '^SYNC_EXPORT_PORT=127.0.0.1:5007$' "${WORK}/secrets/ffs.env") $(stat -c %a "${WORK}/secrets/ffs.env") $(ls -A "${WORK}/secrets" | wc -l)" \
  "0 link 1 600 1" "setup on an .env that is a symlink: the symlink kept, its file written, 0600"
sed -i --follow-symlinks '/^ADMIN_DB_NAME=/d' .env
./prepare_environment.sh --upgrade < /dev/null > upgrade-symlink.log 2>&1
check "$? $([ -L .env ] && echo link) $(grep -c '^ADMIN_DB_NAME=' "${WORK}/secrets/ffs.env") $(stat -c %a "${WORK}/secrets/ffs.env")" "0 link 1 600" \
  "--upgrade on an .env that is a symlink: the symlink kept, its file written, 0600"
rm .env && mv "${WORK}/secrets/ffs.env" .env
# --render-units on a compose install: refused, nothing written; --fresh asks for it
port_setup ""
cp -p .env "${WORK}/port.env"
./prepare_environment.sh --render-units < /dev/null > render-compose.log 2>&1
check "$? $(grep -c '^ERROR: no Quadlet units in' render-compose.log) $(ls "${QUADLET_DIR}" 2> /dev/null | wc -l) $(cmp -s .env "${WORK}/port.env" && echo kept)" "1 1 0 kept" \
  "--render-units without installed units (a compose install): refused, no unit written"
QUADLET_DIR=${WORK}/fresh SYSTEMD_USER_DIR=${WORK}/fresh-timers ./prepare_environment.sh --render-units --fresh < /dev/null > render-fresh.log 2>&1
check "$? $(ls "${WORK}/fresh"/firefox-sync-syncstorage.container "${WORK}/fresh-timers"/firefox-sync-backup.timer 2> /dev/null | wc -l)" "0 2" "--render-units --fresh renders the units of a compose .env"
# the units of an earlier release, which name no checkout (before the backups: firefox-sync's
# main branch): --upgrade renders them when they have the SYNC_MASTER_SECRET of .env, says so
older_units() {
  local u
  rm -f "${WORK}/fresh/firefox-sync-backup.container" "${WORK}/fresh/firefox-sync-backup.env"
  sed -i '/^Volume=\//d' "${WORK}/fresh"/*.container
  # and their secrets in the units, as Environment= lines (before the environment files)
  for u in "${WORK}/fresh"/*.container; do
    [ -f "${u%.*}.env" ] || continue
    sed -i -e '/^EnvironmentFile=/d' -e "/^\[Container\]$/r /dev/stdin" "${u}" < <(sed 's/^/Environment=/' "${u%.*}.env")
    rm -f "${u%.*}.env"
  done
}
older_units
QUADLET_DIR=${WORK}/fresh SYSTEMD_USER_DIR=${WORK}/fresh-timers ./prepare_environment.sh --upgrade < /dev/null > upgrade-older-units.log 2>&1
check "$? $(grep -c '^NOTE: the Quadlet units in .* are of an earlier release of firefox-sync' upgrade-older-units.log) $(grep -c '^Rendering the Quadlet units from' upgrade-older-units.log) $(ls "${WORK}/fresh"/firefox-sync-backup.container 2> /dev/null | wc -l)" \
  "0 1 1 1" "--upgrade renders the units of an earlier release (no checkout in them) with the SYNC_MASTER_SECRET of .env, and says so"
# with another SYNC_MASTER_SECRET: said, not rendered (--render-units does)
older_units
sed -i 's/^Environment=SYNC_MASTER_SECRET=.*/Environment=SYNC_MASTER_SECRET=another/' "${WORK}/fresh/firefox-sync-syncstorage.container"
QUADLET_DIR=${WORK}/fresh SYSTEMD_USER_DIR=${WORK}/fresh-timers ./prepare_environment.sh --upgrade < /dev/null > upgrade-other-units.log 2>&1
check "$? $(grep -c 'with another SYNC_MASTER_SECRET than' upgrade-other-units.log) $(grep -c '^Rendering the Quadlet units from' upgrade-other-units.log) $(ls "${WORK}/fresh"/firefox-sync-backup.container 2> /dev/null | wc -l) $(grep -c '^Environment=SYNC_MASTER_SECRET=another$' "${WORK}/fresh/firefox-sync-syncstorage.container")" \
  "0 1 0 0 1" "--upgrade leaves the units of an earlier release with another SYNC_MASTER_SECRET as they are, and says so"
[ "${FAILED}" = 0 ] || cat upgrade-older-units.log upgrade-other-units.log
rm -rf .env .env.before-setup-* .env.before-upgrade-* quadlets.before-* "${WORK}/fresh" "${WORK}/fresh-timers"

# the admin UI quadlet gets every setting of the compose ffs-admin service (.env given: the first
# compose file is in compose/, compose would look there): the keys
# only in compose (allowed: $2, a regex), then those only in the quadlet
compose_env_keys() { docker compose --env-file .env --profile admin "$@" config --format json 2> /dev/null | jq -r '.services["ffs-admin"].environment | keys[]' | LC_ALL=C sort; }
quadlet_env_keys() { unit_env "$1" | sed -nE 's/^Environment="?([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p' | LC_ALL=C sort -u; }
env_keys_diff() {
  local compose quadlet
  compose=$(compose_env_keys $1) quadlet=$(quadlet_env_keys "${QUADLET_DIR}/firefox-sync-admin.container")
  [ -n "${compose}" ] || { echo "no compose environment"; return; }
  echo "$(LC_ALL=C comm -23 <(echo "${compose}") <(echo "${quadlet}") | grep -vxE "$2" | paste -sd' ')|$(LC_ALL=C comm -13 <(echo "${compose}") <(echo "${quadlet}") | paste -sd' ')"
}

echo "== quadlets (${SYNC_DB})"
export QUADLET_DIR=${HOME}/.config/containers/systemd
# what differs with PostgreSQL: its compose file, its units (one database and the role's
# init instead of two databases), what the admin UI reaches (one database)
if [ "${SYNC_DB}" = postgres ]; then
  sync_compose=(-f compose/sync.yml -f compose/sync-postgres.yml)
  DB_UNITS=(postgres-db sync-role-init)
  DB_UP=("${SYNC_UP[@]}")
else
  sync_compose=(-f compose/sync.yml -f "compose/sync-${SYNC_DB}.yml")
  DB_UNITS=(syncstorage-db tokenserver-db)
  DB_UP=("${SYNC_UP[@]}" 'ffs_up{component="Storage database"} 1')
fi
DB_SERVICES=("${DB_UNITS[@]/#/firefox-sync-}"); DB_SERVICES=("${DB_SERVICES[@]/%/.service}")
# the SQL of the Sync databases on MariaDB or MySQL: the database container's own client
# (mariadb, or mysql in the MySQL image); the phases after the first are on MariaDB
mariadb_sql() {
  ts_sql() { podman exec -e MYSQL_PWD="$(grep '^SYNC_TOKENSERVER_DB_PASSWORD=' .env | cut -d= -f2)" firefox-sync-tokenserver-db \
    sh -c 'exec "$(command -v mariadb || command -v mysql)" "$@"' sql -u"$(grep '^SYNC_TOKENSERVER_DB_USER=' .env | cut -d= -f2)" "$(grep '^SYNC_TOKENSERVER_DB_NAME=' .env | cut -d= -f2)" -sN -e "$1"; }
  # the admin UI's own database (the event log, the backup runs), as its user
  admin_db_sql() { podman exec -e MYSQL_PWD="$(env_of ADMIN_DB_PASSWORD)" firefox-sync-tokenserver-db \
    sh -c 'exec "$(command -v mariadb || command -v mysql)" "$@"' sql -u"$(env_of ADMIN_DB_USER)" "$(env_of ADMIN_DB_NAME)" -sN -e "$1"; }
  # the admin UI's reader of the Sync data: the tokenserver database, not the event log
  reader_sql() { podman exec -e MYSQL_PWD="$(env_of ADMIN_DB_PASSWORD)" "$1" sh -c 'exec "$(command -v mariadb || command -v mysql)" "$@"' sql \
    -u"$(env_of ADMIN_DB_SYNC_USER)" -sN -e "$2"; }
}
# SQL in the PostgreSQL container, as the role given: user password database query
pg_sql() { podman exec -e PGPASSWORD="$2" firefox-sync-postgres-db psql -h 127.0.0.1 -U "$1" -d "$3" -tA -c "$4"; }
# the passwords and secrets of an .env ($1) in another ($2), under their new names: "kept <n>",
# else the first that changed (not shown)
secrets_kept() {
  local key new pair n=0
  for key in $(sed -nE 's/^([A-Z][A-Z0-9_]*(PASSWORD|PASS|SECRET|KEY|TOKEN|_CLIENT_ID))=.+/\1/p' "$1"); do
    new=${key}
    for pair in "${RENAMED_SETTINGS[@]}"; do [ "${pair#*=}" = "${key}" ] && new=${pair%%=*}; done
    [ "$(grep "^${new}=" "$2" | cut -d= -f2-)" = "$(grep "^${key}=" "$1" | cut -d= -f2-)" ] || { echo "changed: ${key}"; return; }
    n=$((n + 1))
  done
  echo "kept ${n}"
}
if [ -n "${UPGRADE_FROM:-}" ]; then
  echo "== first the quadlets of ${UPGRADE_FROM}, then upgraded as docs/upgrading.md#with-quadlets says"
  [ "${SYNC_DB}" = mariadb ] || { echo "UPGRADE_FROM is for SYNC_DB=mariadb"; exit 2; }
  # that release where this tree is (its units mount files of it), this tree aside until the
  # upgrade brings it, as git pull does
  mv "${WORK}/ffs" "${WORK}/new" && cp -r "${UPGRADE_FROM}" "${WORK}/ffs" && cd "${WORK}/ffs" && rm -f .env && example . || exit 1
  # that release's admin UI and init image under the names of the units, this tree's aside
  INIT_IMAGE=${REPOSITORY}:syncstorage-rs-mysql-init-${INIT_TAG}
  # (releases before db/: syncstorage-rs-init)
  INIT_DIR=db/mysql/init; [ -d "${INIT_DIR}" ] || INIT_DIR=syncstorage-rs-init
  podman tag "${REPOSITORY}:admin-latest" localhost/ffs-admin:upgrade-to && podman tag "${INIT_IMAGE}" localhost/ffs-init:upgrade-to &&
    podman build -q --format docker -t "${REPOSITORY}:admin-latest" admin > "${WORK}/build-from.log" 2>&1 &&
    podman build -q -t "${INIT_IMAGE}" "${INIT_DIR}" >> "${WORK}/build-from.log" 2>&1
  check "$?" 0 "the admin UI and init images of ${UPGRADE_FROM}"
  setup mariadb 1
  check "$?" 0 "its prepare_environment.sh (quadlets)"
  timeout 900 systemctl --user start firefox-sync-syncstorage.service
  check "$?" 0 "its units started (quadlets)"
  check "$(hb) $(admin_up /login)" "200 200" "its Sync server and admin UI (quadlets)"
  FROM_ENV=${WORK}/from.env
  cp -p .env "${FROM_ENV}"
  # (a release from before the SYNC_ names: the old one)
  from_env() {
    local pair v
    v=$(grep "^$1=" "${FROM_ENV}" | cut -d= -f2)
    for pair in "${RENAMED_SETTINGS[@]}"; do
      [ -z "${v}" ] && [ "${pair%%=*}" = "$1" ] && v=$(grep "^${pair#*=}=" "${FROM_ENV}" | cut -d= -f2)
    done
    echo "${v}"
  }
  from_ts_sql() { podman exec -e MYSQL_PWD="$(from_env SYNC_TOKENSERVER_DB_PASSWORD)" firefox-sync-tokenserver-db \
    mariadb -u"$(from_env SYNC_TOKENSERVER_DB_USER)" "$(from_env SYNC_TOKENSERVER_DB_NAME)" -sN -e "$1"; }
  for _ in $(seq 1 30); do [ "$(from_ts_sql 'SELECT COUNT(*) FROM ffs_events' 2> /dev/null)" -gt 0 ] 2> /dev/null && break; sleep 2; done
  from_ts_sql "INSERT INTO ffs_events (at, kind, detail) VALUES ($(date +%s)000, 'admin', 'ffs-podman: before the Quadlet upgrade by admin (password)')"
  check "$?" 0 "an audit event in the tokenserver database, as before (quadlets)"
  # the upgrade: the units stopped, the one-shot ones too, as docs/upgrading.md#quadlets says
  STOP='systemctl --user stop firefox-sync-backup.timer firefox-sync-syncstorage.service firefox-sync-admin.service firefox-sync-syncstorage-migrate.service firefox-sync-tokenserver-db-init.service firefox-sync-tokenserver-db.service firefox-sync-syncstorage-db.service'
  check "$(grep -cF "\`${STOP}\`" "${CODE}/docs/upgrading.md")" 1 "docs/upgrading.md says \`${STOP}\`"
  timeout 300 ${STOP}
  # the new files, the .env of the install kept
  cp -p .env "${WORK}/new/.env" && cd "${WORK}" && rm -rf "${WORK}/ffs" && mv "${WORK}/new" "${WORK}/ffs" && cd "${WORK}/ffs" || exit 1
  # (the images of this tree are local: what docs/upgrading.md#quadlets pulls is here already)
  podman tag localhost/ffs-admin:upgrade-to "${REPOSITORY}:admin-latest" && podman tag localhost/ffs-init:upgrade-to "${INIT_IMAGE}"
  podman rmi localhost/ffs-admin:upgrade-to localhost/ffs-init:upgrade-to > /dev/null 2>&1
  # the units rendered again from that .env: every password and secret as it was, nothing asked
  ./prepare_environment.sh --upgrade < /dev/null > upgrade-quadlets.log 2>&1
  check "$?" 0 "prepare_environment.sh --upgrade (quadlets)"
  check "$(secrets_kept "${FROM_ENV}" .env | sed 's/ [0-9]*$//') $(grep -c '^Rendering the Quadlet units from' upgrade-quadlets.log) $(ls quadlets.before-*/firefox-sync-syncstorage.container 2> /dev/null | wc -l)" \
    "kept 1 1" "--upgrade renders the units from the .env of the install, every secret kept, the units of before kept (quadlets)"
  check "$(env_of ADMIN_DB_PASSWORD | grep -cE '^[A-Za-z0-9]{32}$') $(grep -cE "^($(IFS='|'; echo "${RENAMED_SETTINGS[*]#*=}"))=" .env)" "1 0" \
    "--upgrade gives the Quadlets ADMIN_DB_PASSWORD, renames the old setting names (quadlets)"
  check "$(stat -c %a .env .env.before-upgrade-* | sort -u | paste -sd' ') $(ls .env.before-upgrade-* | wc -l) $(cmp -s .env.before-upgrade-* "${FROM_ENV}" && echo before)" "600 1 before" \
    "--upgrade: .env and .env.before-upgrade-<time> (the .env of before) 0600"
  [ "${FAILED}" = 0 ] || cat upgrade-quadlets.log
  # run again: nothing to change
  cp -p .env "${WORK}/upgraded.env"
  ./prepare_environment.sh --upgrade < /dev/null > upgrade-quadlets-again.log 2>&1
  check "$? $(grep -c 'nothing changed$' upgrade-quadlets-again.log) $(ls -d quadlets.before-* | wc -l) $(cmp -s .env "${WORK}/upgraded.env" && echo same)" "0 1 1 same" \
    "--upgrade again: .env and the units as they are (quadlets)"
else
  setup "${SYNC_DB}" 1
  check "$?" 0 "prepare_environment.sh (quadlets)"
fi
# SYNC_MYSQL_FROM=mysql:8: the Sync databases start on it, as an install from before, and move to
# lts at the end of this phase as docs/upgrading.md#mysql-8-to-9 says for the Quadlets
if [ -n "${SYNC_MYSQL_FROM:-}" ]; then
  [ "${SYNC_DB}" = mysql ] || { echo "SYNC_MYSQL_FROM is for SYNC_DB=mysql"; exit 2; }
  sed -i "s|^SYNC_MYSQL_IMAGE=.*|SYNC_MYSQL_IMAGE=${SYNC_MYSQL_FROM}|" .env
  ./prepare_environment.sh --render-units < /dev/null > render-mysql-from.log 2>&1
  check "$? $(sed -n 's/^Image=//p' "${QUADLET_DIR}"/firefox-sync-{syncstorage-db,tokenserver-db,backup}.container | sort -u)" "0 docker.io/library/${SYNC_MYSQL_FROM}" \
    "the Sync databases and their backups on ${SYNC_MYSQL_FROM} first (quadlets)"
fi
# the Sync server on this host only for a new install (a port alone answered: 127.0.0.1),
# an install from before keeps what it has (a port alone: every interface)
if [ -n "${UPGRADE_FROM:-}" ]; then sync_listen=${PORT}; else sync_listen=127.0.0.1:${PORT}; fi
check "$(env_of SYNC_EXPORT_PORT) $(sed -n 's/^PublishPort=//p' "${QUADLET_DIR}/firefox-sync-syncstorage.container")" "${sync_listen} ${sync_listen}:8000" \
  "SYNC_EXPORT_PORT=${sync_listen} in .env and the Sync server's PublishPort (quadlets)"
# the healthchecks of compose, those of the Quadlets (as rendered from .env)
check "$(health_parity "${QUADLET_DIR}" docker compose --env-file .env --profile admin --profile backup "${sync_compose[@]}")" same "every long-running service has a healthcheck, the Quadlets compose's (${SYNC_DB})"
check "$(grep -l '%[A-Z_]*%' "${QUADLET_DIR}"/firefox-sync-* | wc -l)" 0 "no unreplaced placeholders in quadlets"
check "$(units_secret_free)" none "no secret of .env in the units, the secrets in their environment files, 0600 (quadlets)"
# with the admin UI, SYNC_MAX_USERS=initial:1: the init container and the admin UI both get it
check "$(grep -hcxF 'Environment=MAX_USERS=initial:1' "${QUADLET_DIR}/firefox-sync-tokenserver-db-init.container") $(grep -hcxF 'Environment="MAX_USERS=initial:1"' "${QUADLET_DIR}/firefox-sync-admin.container")" "1 1" \
  "SYNC_MAX_USERS=initial:1 in the init and admin UI quadlets"
# without the accounts: not their settings, nor those of the sign-up gate and of the unconfirmed accounts
# nor the Sync users' passwords: the Quadlets always have ADMIN_DB_PASSWORD, compose only passes them without it
check "$(env_keys_diff "${sync_compose[*]}" 'FXA_.*|ADMIN_SIGNUP_BURST|ADMIN_DELETE_UNCONFIRMED_DAYS|TOKENSERVER_DB_PASSWORD|STORAGE_DB_PASSWORD|FFS_OLD_ENV_NAMES')" "|" "admin quadlet passes every setting of the compose service (${SYNC_DB})"
check "$(unit_count '^Environment="?(TOKENSERVER|STORAGE)_DB_PASSWORD=' "${QUADLET_DIR}/firefox-sync-admin.container") $(unit_count '^Environment="?ADMIN_DB_PASSWORD=[A-Za-z0-9]{32}"?$' "${QUADLET_DIR}/firefox-sync-admin.container")" \
  "0 1" "the admin UI quadlet has its own database password, none of the Sync users"
# the help of the backups on the overview: their time, how many, the Quadlets' commands
check "$(grep -cxE 'Environment="(BACKUP_TIME=03:00|BACKUP_KEEP=7|ADMIN_DEPLOYMENT=quadlets)"' "${QUADLET_DIR}/firefox-sync-admin.container")" 3 \
  "BACKUP_TIME, BACKUP_KEEP and ADMIN_DEPLOYMENT=quadlets in the admin UI quadlet"
QUADLET=$(ls /usr/libexec/podman/quadlet /usr/lib/podman/quadlet 2> /dev/null | head -1)
"${QUADLET}" -dryrun -user > quadlet-dryrun.log 2>&1
check "$?" 0 "quadlet generator accepts the files"
# PostgreSQL: pinned to the major prepare_environment.sh read from Podman's postgres:latest (the
# store the units run from), the database and the backups on it, no --arch (this host's)
pg_latest_major() { podman run --rm --entrypoint postgres docker.io/library/postgres:latest --version 2> /dev/null | sed -n 's/^postgres (PostgreSQL) \([0-9]*\)[^0-9].*/\1/p'; }
pg_units_check() { # what
  pg_major=$(pg_latest_major)
  check "$(env_of SYNC_POSTGRES_IMAGE) $(sed -n 's/^Image=//p' "${QUADLET_DIR}"/firefox-sync-{postgres-db,backup}.container | paste -sd' ') $(grep -l '^PodmanArgs=.*--arch' "${QUADLET_DIR}"/firefox-sync-* 2> /dev/null | wc -l)" \
    "postgres:${pg_major} docker.io/library/postgres:${pg_major} docker.io/library/postgres:${pg_major} 0" \
    "SYNC_POSTGRES_IMAGE=postgres:${pg_major}, the major of Podman's postgres:latest, for the database and the backup units, no --arch ($1)"
  check "$(ls "${QUADLET_DIR}"/firefox-sync-*-db.container "${QUADLET_DIR}"/firefox-sync-*-db*.volume "${QUADLET_DIR}"/firefox-sync-sync-role-init.container 2> /dev/null | xargs -n1 basename | LC_ALL=C sort | paste -sd' ')" \
    "firefox-sync-postgres-db.container firefox-sync-postgres-db.volume firefox-sync-sync-role-init.container" "one PostgreSQL database and the role's init, no MariaDB or MySQL unit ($1)"
  check "$(unit_count '^Environment="?(SYNC_(SYNCSTORAGE|TOKENSERVER)__DATABASE_URL=postgres://syncserver_app:[A-Za-z0-9]+@firefox-sync-postgres-db:5432/syncserver|TOKENSERVER_DB_TYPE=postgres|TOKENSERVER_DB_HOST=firefox-sync-postgres-db)"?$' \
    "${QUADLET_DIR}"/firefox-sync-{syncstorage,syncstorage-migrate,admin,backup}.container)" "2 2 2 2" \
    "the Sync server, its migrations, the admin UI and the backups on PostgreSQL, as the Sync server's role ($1)"
}
[ "${SYNC_DB}" != postgres ] || pg_units_check quadlets
# the journal keeps earlier runs
fast_admin_checks
QUADLET_SINCE=$(date '+%Y-%m-%d %H:%M:%S')
timeout 900 systemctl --user start firefox-sync-syncstorage.service
check "$?" 0 "systemctl --user start firefox-sync-syncstorage.service"
# (docs/upgrading.md#quadlets: the backup timer again when the nightly backups are on; not here)
[ -z "${UPGRADE_FROM:-}" ] || ! systemctl --user is-enabled -q firefox-sync-backup.timer 2> /dev/null || systemctl --user start firefox-sync-backup.timer
for u in "${DB_UNITS[@]}" syncstorage-migrate tokenserver-db-init syncstorage; do
  printf '  %-22s %s\n' "${u}" "$(systemctl --user is-active "firefox-sync-${u}.service")"
done
check "$(hb)" 200 "/__heartbeat__ (quadlets)"
[ "${SYNC_DB}" != postgres ] || check "$(podman exec firefox-sync-postgres-db postgres --version | sed -n 's/^postgres (PostgreSQL) \([0-9]*\)[^0-9].*/\1/p')" "${pg_major}" \
  "the PostgreSQL that runs is the major prepare_environment.sh read (quadlets)"
sync_sockets=$(ss -Hltn "sport = :${PORT}" | awk '{ print $4 }' | sort -u | paste -sd' ')
if [ -n "${UPGRADE_FROM:-}" ]; then
  check "$([ -n "${sync_sockets}" ] && [ "${sync_sockets}" != "127.0.0.1:${PORT}" ] && echo every)" every "the Sync server listens on every interface, as before the upgrade (quadlets; ${sync_sockets})"
else
  check "${sync_sockets}" "127.0.0.1:${PORT}" "the Sync server listens on 127.0.0.1 only (quadlets)"
fi
check "$(podman inspect -f '{{.EffectiveCaps}}' firefox-sync-syncstorage | grep -c NET_RAW) $(grep -hcxF 'DropCapability=NET_RAW' "${QUADLET_DIR}"/firefox-sync-syncstorage{,-migrate}.container | paste -sd' ')" \
  "0 1 1" "the Sync server and its migrations without raw sockets (quadlets)"
journalctl --user -u firefox-sync-syncstorage-migrate.service --no-pager 2> /dev/null | grep -m1 "Migrations completed"
journalctl --user -u firefox-sync-tokenserver-db-init.service --no-pager 2> /dev/null | grep -m1 "Max users"
INIT_END=$(systemctl --user show -p ExecMainExitTimestampMonotonic --value firefox-sync-tokenserver-db-init.service)
APP_START=$(systemctl --user show -p ExecMainStartTimestampMonotonic --value firefox-sync-syncstorage.service)
check "$([ "${APP_START}" -gt "${INIT_END}" ] && echo yes)" yes "syncstorage started after the init (quadlets)"
# started with the Sync server (Wants=), before it
check "$(systemctl --user is-active firefox-sync-admin.service)" active "admin UI started with the Sync server (quadlets)"
check "$(admin_up /login)" 200 "admin UI (quadlets)"
check "$(journalctl --user -u firefox-sync-syncstorage.service --since "${QUADLET_SINCE}" --no-pager 2> /dev/null | grep -c 'Sending metrics to the admin UI')" 1 \
  "Sync server sends metrics to the admin UI (quadlets)"
check "$(admin_sign_in quadlets)" yes "admin UI sign-in over http://localhost (quadlets)"
check "$(metrics_show "${DB_UP[@]}")" all "admin UI reaches the Sync server and its databases (quadlets)"
check "$(podman healthcheck run firefox-sync-admin > /dev/null 2>&1; echo $?)" 0 "admin UI healthcheck (quadlets)"
# a new admin UI container restarts the Sync server, which resolves ffs-admin once
SYNC_PID=$(systemctl --user show -p MainPID --value firefox-sync-syncstorage.service)
timeout 300 systemctl --user restart firefox-sync-admin.service
for _ in $(seq 1 30); do
  pid=$(systemctl --user show -p MainPID --value firefox-sync-syncstorage.service)
  [ "${pid}" != "${SYNC_PID}" ] && [ "${pid}" != 0 ] && break
  sleep 2
done
check "$([ "${pid}" != "${SYNC_PID}" ] && echo yes)" yes "Sync server restarted with the admin UI (quadlets)"
check "$(hb)" 200 "/__heartbeat__ after the admin UI restart (quadlets)"
# backups: the timer installed, off until enabled; a run by hand
if [ "${SYNC_DB}" = postgres ]; then
  # the Sync server's role (the owner of the Sync tables), the admin UI's, its reader
  ts_sql() { pg_sql "$(env_of SYNC_POSTGRES_APP_USER)" "$(env_of SYNC_POSTGRES_APP_PASSWORD)" "$(env_of SYNC_POSTGRES_NAME)" "$1"; }
  admin_db_sql() { pg_sql "$(env_of ADMIN_DB_USER)" "$(env_of ADMIN_DB_PASSWORD)" "$(env_of ADMIN_DB_NAME)" "$1"; }
  reader_sql() { pg_sql "$(env_of ADMIN_DB_SYNC_USER)" "$(env_of ADMIN_DB_PASSWORD)" "$1" "$2"; }
  check "$([ "$(admin_db_sql "SELECT COUNT(*) FROM ffs_events")" -gt 0 ] && echo yes) $(ts_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name LIKE 'ffs\\_%' AND table_name NOT LIKE 'ffs\\_setup\\_%'")" \
    "yes 0" "the admin UI records its events in its own database, none in the Sync database (quadlets, postgres)"
  check "$(pg_sql "$(env_of SYNC_POSTGRES_APP_USER)" "$(env_of SYNC_POSTGRES_APP_PASSWORD)" "$(env_of ADMIN_DB_NAME)" "SELECT 1" 2>&1 | grep -c 'permission denied')" 1 \
    "the Sync server's role cannot connect to the admin UI's database (quadlets, postgres)"
  check "$(ts_sql "SELECT rolsuper || ' ' || (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE relname = 'users' AND relnamespace = 'public'::regnamespace) FROM pg_roles WHERE rolname = current_user")" \
    "false $(env_of SYNC_POSTGRES_APP_USER)" "the Sync server's role is no superuser and owns the Sync tables (quadlets, postgres)"
  check "$(reader_sql "$(env_of SYNC_POSTGRES_NAME)" "SELECT COUNT(*) > 0 FROM nodes") $(reader_sql "$(env_of ADMIN_DB_NAME)" "SELECT 1" 2>&1 | grep -c 'permission denied') $(reader_sql "$(env_of SYNC_POSTGRES_NAME)" "SELECT COUNT(*) >= 0 FROM bsos")" \
    "t 1 t" "the admin UI's reader reads the Sync database, not the admin UI's (quadlets, postgres)"
  SYNC_DUMPS="ffs_admin.sql.gz $(env_of SYNC_POSTGRES_NAME).sql.gz"
else
  mariadb_sql
  check "$([ "$(admin_db_sql "SELECT COUNT(*) FROM ffs_events")" -gt 0 ] && echo yes) $(ts_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name LIKE 'ffs\\_%' AND table_name NOT LIKE 'ffs\\_setup\\_%'")" \
    "yes 0" "the admin UI records its events in its own database, none in the tokenserver's (quadlets)"
  [ -z "${UPGRADE_FROM:-}" ] || check "$(admin_db_sql "SELECT COUNT(*) FROM ffs_events WHERE detail = 'ffs-podman: before the Quadlet upgrade by admin (password)' OR detail LIKE 'Moved the admin UI%'")" 2 \
    "the audit trail of ${UPGRADE_FROM} moved into the admin UI's database (quadlets upgraded)"
  check "$(ts_sql "SELECT COUNT(*) FROM $(env_of ADMIN_DB_NAME).ffs_events" 2>&1 | grep -c denied)" 1 "the tokenserver user cannot read the event log (quadlets)"
  check "$(reader_sql firefox-sync-tokenserver-db "SELECT COUNT(*) > 0 FROM $(env_of SYNC_TOKENSERVER_DB_NAME).nodes") $(reader_sql firefox-sync-tokenserver-db "SELECT COUNT(*) FROM $(env_of ADMIN_DB_NAME).ffs_events" 2>&1 | grep -c denied) $(reader_sql firefox-sync-syncstorage-db "SELECT COUNT(*) >= 0 FROM $(env_of SYNC_STORAGE_DB_NAME).bso")" \
    "1 1 1" "the admin UI's reader reads the Sync databases, not the event log (quadlets)"
  SYNC_DUMPS="ffs_admin.sql.gz syncstorage.sql.gz tokenserver.sql.gz"
fi
# the setup migrations (docs/databases.md#setup-migrations): recorded by the init container with
# the stack's database containers, the version in the admin UI
check "$(ts_sql "SELECT number, how FROM ffs_setup_migrations WHERE scope = 'sync' ORDER BY number" | tr '\t|' '  ' | paste -sd ',' -) $(metrics_show 'ffs_db_setup_version{scope="sync"} 1' 'ffs_db_setup_expected_version{scope="sync"} 1')" \
  "1 containers all" "the setup migrations recorded by the init container (how containers), version 1 in the admin UI (quadlets)"
check "$(grep -c '^OnCalendar=\*-\*-\* 03:00:00 UTC$' "${SYSTEMD_USER_DIR}/firefox-sync-backup.timer" 2> /dev/null) $(systemctl --user is-enabled firefox-sync-backup.timer 2> /dev/null)" "1 disabled" \
  "backup timer installed, not enabled (quadlets)"
check "$(systemctl --user show -p Triggers --value firefox-sync-backup.timer)" firefox-sync-backup.service "the backup timer starts the backup service"
timeout 300 systemctl --user start firefox-sync-backup.service
check "$?" 0 "systemctl --user start firefox-sync-backup.service (a backup by hand)"
check "$(admin_db_sql "SELECT COUNT(*) FROM ffs_backups WHERE scope = 'sync' AND ok = 1 AND bytes > 0")" 1 "the backup recorded in ffs_backups (quadlets)"
check "$(podman run --rm -v firefox-sync-backups:/backups:ro docker.io/library/mariadb:lts sh -c 'for f in /backups/sync/*/*.sql.gz; do gzip -t "$f" && basename "$f"; done' | sort | paste -sd' ')" \
  "${SYNC_DUMPS}" "the dumps in the firefox-sync-backups volume (quadlets)"
[ "${FAILED}" = 0 ] || journalctl --user -u firefox-sync-backup.service --no-pager | tail -20

echo "== the units of the running install rendered again from its .env: a setting changed, an image pinned"
cp -p .env "${WORK}/rendered.env"
backups=$(ls -d quadlets.before-* 2> /dev/null | wc -l)
# as an admin edits .env (the same admin UI under a name of its own: a pin)
podman tag "${REPOSITORY}:admin-latest" localhost/ffs-admin:pinned
# (with a comment after the value: dropped, as compose does)
sed -i 's|^ADMIN_STALE_DAYS=.*|ADMIN_STALE_DAYS=45  # was 90|' .env
# (a switch of the admin UI the units pass from .env, as compose: on its configuration page)
sed -i 's|^ADMIN_INSECURE_COOKIE=.*|ADMIN_INSECURE_COOKIE=1|' .env
grep -q '^ADMIN_IMAGE=' .env && sed -i 's|^ADMIN_IMAGE=.*|ADMIN_IMAGE=localhost/ffs-admin:pinned|' .env || echo 'ADMIN_IMAGE=localhost/ffs-admin:pinned' >> .env
cp -p .env "${WORK}/edited.env"
./prepare_environment.sh --render-units < /dev/null > render-units.log 2>&1
check "$?" 0 "prepare_environment.sh --render-units (quadlets)"
check "$(secrets_kept "${WORK}/rendered.env" .env | sed 's/ [0-9]*$//') $(cmp -s .env "${WORK}/edited.env" && echo same)" "kept same" "--render-units keeps every password and secret, and .env as it is (quadlets)"
check "$(units_secret_free)" none "--render-units: no secret of .env in the units, the secrets in their environment files, 0600"
# only the admin UI's unit changed (fast_admin_checks' line gone with it), the units of before kept
check "$(sed -n 's/^  ✓ //p' render-units.log | paste -sd' ') $(grep -cxE 'Image=localhost/ffs-admin:pinned|Environment="(ADMIN_STALE_DAYS=45|ADMIN_INSECURE_COOKIE=1)"' "${QUADLET_DIR}/firefox-sync-admin.container") $(($(ls -d quadlets.before-* | wc -l) - backups)) $(grep -Hc '^Image=localhost/ffs-admin:pinned' quadlets.before-*/firefox-sync-admin.container 2> /dev/null | grep -c ':0$')" \
  "firefox-sync-admin.container 3 1 $((backups + 1))" "--render-units writes the changed unit only, with ADMIN_IMAGE and the settings, the units of before kept (quadlets)"
./prepare_environment.sh --render-units < /dev/null > render-units-again.log 2>&1
check "$? $(grep -c 'nothing changed$' render-units-again.log) $(grep -c '✓' render-units-again.log) $(($(ls -d quadlets.before-* | wc -l) - backups)) $(cmp -s .env "${WORK}/edited.env" && echo same)" "0 1 0 1 same" \
  "--render-units again: nothing changes (quadlets)"
[ "${FAILED}" = 0 ] || cat render-units.log render-units-again.log
# every unit stopped and started again with the units rendered (daemon-reload done): the
# databases have the passwords of before, nothing set by hand
fast_admin_checks
timeout 300 systemctl --user stop firefox-sync-syncstorage.service firefox-sync-admin.service firefox-sync-syncstorage-migrate.service \
  firefox-sync-tokenserver-db-init.service "${DB_SERVICES[@]}"
timeout 900 systemctl --user start firefox-sync-admin.service firefox-sync-syncstorage.service
check "$?" 0 "the units started again, rendered again (quadlets)"
check "$(hb) $(admin_up /login) $(admin_sign_in rendered) $(podman inspect -f '{{.ImageName}}' firefox-sync-admin)" "200 200 yes localhost/ffs-admin:pinned" \
  "the Sync server, the admin UI with the same password and the image pinned (quadlets rendered again)"
check "$(metrics_show "${DB_UP[@]}")" all "admin UI reaches the Sync server and its databases, their passwords as before (quadlets rendered again)"
check "$(curl -s -b "${WORK}/cookies-rendered" http://localhost:${ADMIN_PORT}/config | grep -q 'also over plain HTTP' && echo yes)" yes "ADMIN_INSECURE_COOKIE of .env reaches the admin UI (quadlets)"

echo "== a backup restores, the way docs/backups.md#restore-with-quadlets says for the Quadlets"
if [ "${SYNC_DB}" = postgres ]; then
  # every table of the Sync database with its rows, its triggers and functions
  inventory() {
    local q t
    q="SELECT 'triggers', COUNT(*) FROM information_schema.triggers WHERE trigger_schema = 'public'
       UNION ALL SELECT 'routines', COUNT(*) FROM information_schema.routines WHERE routine_schema = 'public'"
    for t in $(ts_sql "SELECT tablename FROM pg_tables WHERE schemaname = 'public';"); do
      q="${q} UNION ALL SELECT '${t}', COUNT(*) FROM \"${t}\""
    done
    ts_sql "${q} ORDER BY 1;" | tr '|' ' '
  }
  ts_sql "INSERT INTO users (service, email, generation, client_state, created_at, nodeid) SELECT service, 'restore@ffs-e2e.invalid', 1, 'aa', 1, id FROM nodes LIMIT 1;" > /dev/null
  # Sync items of that user, as the Sync server writes them: payloads with quotes, a backslash
  # and a line break, which the dump has to carry as they are
  uid=$(ts_sql "SELECT uid FROM users WHERE email = 'restore@ffs-e2e.invalid'")
  ts_sql "WITH c AS (SELECT collection_id FROM collections WHERE name = 'bookmarks'),
      uc AS (INSERT INTO user_collections (user_id, collection_id, modified) SELECT ${uid}, collection_id, NOW() FROM c)
    INSERT INTO bsos (user_id, collection_id, bso_id, payload, modified, expiry)
      SELECT ${uid}, collection_id, 'restore-1', '{\"ciphertext\":\"it''s \\ ok\"}', NOW(), NOW() + INTERVAL '1 day' FROM c
      UNION ALL SELECT ${uid}, collection_id, 'restore-2', 'line' || chr(10) || 'break', NOW(), NOW() + INTERVAL '1 day' FROM c;" > /dev/null
  payloads() { ts_sql "SELECT MD5(STRING_AGG(bso_id || ':' || payload, '|' ORDER BY bso_id)) FROM bsos"; }
  PAYLOADS=$(payloads)
  # the units stopped as docs/backups.md#restore-with-quadlets says, the database too: PostgreSQL's
  # dump loads into an empty database only
  STOP_PG='systemctl --user stop firefox-sync-syncstorage.service firefox-sync-admin.service \
  firefox-sync-syncstorage-migrate.service firefox-sync-tokenserver-db-init.service \
  firefox-sync-sync-role-init.service firefox-sync-postgres-db.service'
  BACKUPS_MD=$(cat "${CODE}/docs/backups.md")
  # (a command of several lines too, as it is written there)
  documented() { [[ "${BACKUPS_MD}" == *"$1"* ]] && echo yes || echo "not in docs/backups.md"; }
  systemctl --user stop firefox-sync-syncstorage.service firefox-sync-admin.service firefox-sync-syncstorage-migrate.service firefox-sync-tokenserver-db-init.service
  BEFORE=$(inventory)
  check "$(echo "${BEFORE}" | grep -cE '^users 1$|^collections [1-9]|^bsos 2$')" 3 "a tokenserver user, the collections and 2 Sync items to back up (quadlets, postgres)"
  timeout 300 systemctl --user start firefox-sync-backup.service
  check "$?" 0 "a backup with the units stopped (quadlets, postgres)"
  EVENTS=$(admin_db_sql "SELECT COUNT(*) FROM ffs_events")
  run=$(podman run --rm -v firefox-sync-backups:/backups:ro docker.io/library/mariadb:lts ls /backups/sync | tail -1)
  dump() { podman run --rm -v firefox-sync-backups:/backups:ro docker.io/library/mariadb:lts gunzip -c "/backups/$1"; }
  check "$(grep -cxF 'set -o pipefail   # a missing or broken dump fails its line, instead of an empty restore' "${CODE}/docs/backups.md")" 1 "docs/backups.md's Quadlet restore sets pipefail"
  # the commands of docs/backups.md#restore-with-quadlets for PostgreSQL, each there word for word, then run
  # shellcheck disable=SC2016 # (expanded in the database container)
  PG_RESTORE=(
    "${STOP_PG}"
    'podman volume rm firefox-sync-postgres-db'
    'systemctl --user start firefox-sync-sync-role-init.service'
    "dump sync/\$run/syncserver.sql.gz | podman exec -i firefox-sync-postgres-db sh -c 'PGPASSWORD=\"\$FFS_SYNC_PASSWORD\" psql -h 127.0.0.1 -U \"\$FFS_SYNC_USER\" -d \"\$POSTGRES_DB\" -v ON_ERROR_STOP=1'"
    'systemctl --user start firefox-sync-tokenserver-db-init.service'
    "dump sync/\$run/ffs_admin.sql.gz | podman exec -i firefox-sync-postgres-db sh -c 'PGPASSWORD=\"\$ADMIN_DB_PASSWORD\" psql -h 127.0.0.1 -U \"\$ADMIN_DB_USER\" -d \"\$ADMIN_DB_NAME\" -v ON_ERROR_STOP=1'"
  )
  for c in "${PG_RESTORE[@]}"; do check "$(documented "${c}")" yes "docs/backups.md's Quadlet restore says: ${c%%$'\n'*}"; done
  eval "${PG_RESTORE[0]}" && podman volume rm firefox-sync-postgres-db > /dev/null
  check "$?" 0 "the database stopped, its volume removed (quadlets, postgres)"
  timeout 300 systemctl --user start firefox-sync-sync-role-init.service
  check "$? $(ts_sql "SELECT COUNT(*) FROM pg_tables WHERE schemaname = 'public'")" "0 0" "an empty database with the Sync server's role (quadlets, postgres)"
  # a run that is not there fails, nothing loaded
  missing=$( (set -o pipefail; eval "${PG_RESTORE[3]//\$run/20000101T000000Z}") >> restore.log 2>&1 || echo failed)
  check "${missing} $(ts_sql "SELECT COUNT(*) FROM pg_tables WHERE schemaname = 'public'")" "failed 0" "a restore of a run that is not there fails, loads nothing (quadlets, postgres)"
  (set -o pipefail; eval "${PG_RESTORE[3]}") >> restore.log 2>&1
  check "$?" 0 "$(env_of SYNC_POSTGRES_NAME) restored from ${run} as the Sync server's role (quadlets, postgres)"
  check "$(inventory)" "${BEFORE}" "the same rows in every table, the same triggers and functions (quadlets, postgres)"
  check "$(payloads)" "${PAYLOADS}" "the Sync items' payloads as they were (quadlets, postgres)"
  timeout 600 systemctl --user start firefox-sync-tokenserver-db-init.service
  check "$?" 0 "the migrations and the init container, the admin UI's database made again (quadlets, postgres)"
  (set -o pipefail; eval "${PG_RESTORE[5]}") >> restore.log 2>&1
  check "$?" 0 "ffs_admin restored from ${run} as its role (quadlets, postgres)"
  check "$(admin_db_sql "SELECT COUNT(*) FROM ffs_events")" "${EVENTS}" "the event log as it was (quadlets, postgres)"
else
  st_sql() { podman exec -e MYSQL_PWD="$(grep '^SYNC_STORAGE_DB_PASSWORD=' .env | cut -d= -f2)" firefox-sync-syncstorage-db \
    sh -c 'exec "$(command -v mariadb || command -v mysql)" "$@"' sql -u"$(grep '^SYNC_STORAGE_DB_USER=' .env | cut -d= -f2)" "$(grep '^SYNC_STORAGE_DB_NAME=' .env | cut -d= -f2)" -sN -e "$1"; }
  # every table of a database with its rows, its triggers and procedures: <sql function>
  inventory() {
    local q t
    q="SELECT 'triggers', COUNT(*) FROM information_schema.triggers WHERE trigger_schema = DATABASE()
       UNION ALL SELECT 'routines', COUNT(*) FROM information_schema.routines WHERE routine_schema = DATABASE()"
    for t in $("$1" "SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE';"); do
      q="${q} UNION ALL SELECT '${t}', COUNT(*) FROM \`${t}\`"
    done
    "$1" "${q} ORDER BY 1;" | tr '\t' ' '
  }
  ts_sql "INSERT INTO users (service, email, generation, client_state, created_at, nodeid) SELECT service, 'restore@ffs-e2e.invalid', 1, 'aa', 1, id FROM nodes LIMIT 1;"
  # Sync items of that user, as the Sync server writes them (no client here): payloads with
  # quotes, a backslash and a line break, which the dump has to carry as they are (Firefox's
  # are encrypted JSON, ASCII)
  uid=$(ts_sql "SELECT uid FROM users WHERE email = 'restore@ffs-e2e.invalid'")
  st_sql "SET @c = (SELECT id FROM collections WHERE name = 'bookmarks'), @m = UNIX_TIMESTAMP() * 1000;
    INSERT INTO user_collections (userid, collection, last_modified) VALUES (${uid}, @c, @m);
    INSERT INTO bso (userid, collection, id, payload, payload_size, modified, ttl) VALUES
      (${uid}, @c, 'restore-1', '{\"ciphertext\":\"it''s \\\\ ok\"}', 30, @m, @m + 86400000),
      (${uid}, @c, 'restore-2', CONCAT('line', CHAR(10), 'break'), 20, @m, @m + 86400000);"
  # (SHA2: MySQL 9 has no MD5)
  payloads() { st_sql "SELECT SHA2(GROUP_CONCAT(id, ':', payload ORDER BY id SEPARATOR '|'), 256) FROM bso"; }
  PAYLOADS=$(payloads)
  # the units stopped as docs/backups.md#restore-with-quadlets says (nothing writes: the databases hold what the dump holds)
  systemctl --user stop firefox-sync-syncstorage.service firefox-sync-admin.service \
    firefox-sync-syncstorage-migrate.service firefox-sync-tokenserver-db-init.service
  BEFORE=$(inventory ts_sql | sed 's/^/tokenserver /'; inventory st_sql | sed 's/^/storage /')
  check "$(echo "${BEFORE}" | grep -cE '^tokenserver users 1$|^storage collections [1-9]|^storage bso 2$')" 3 "a tokenserver user, the storage's collections and 2 Sync items to back up (quadlets)"
  timeout 300 systemctl --user start firefox-sync-backup.service
  check "$?" 0 "a backup with the units stopped (quadlets)"
  # what the restore has to bring back
  EVENTS=$(admin_db_sql "SELECT COUNT(*) FROM ffs_events")
  ts_sql "DELETE FROM users;"
  admin_db_sql "DELETE FROM ffs_events;"
  st_sql "DELETE FROM bso; DELETE FROM user_collections; DELETE FROM collections;"
  check "$(ts_sql 'SELECT COUNT(*) FROM users')-$(st_sql 'SELECT COUNT(*) FROM collections')-$(st_sql 'SELECT COUNT(*) FROM bso')" 0-0-0 "rows deleted before the restore (quadlets)"
  # the newest run, read out of the volume into each database container, as its own user
  run=$(podman run --rm -v firefox-sync-backups:/backups:ro docker.io/library/mariadb:lts ls /backups/sync | tail -1)
  dump() { podman run --rm -v firefox-sync-backups:/backups:ro docker.io/library/mariadb:lts gunzip -c "/backups/$1"; }
  # shellcheck disable=SC2016 # (expanded in the database container)
  if [ "${SYNC_DB}" = mysql ]; then load='MYSQL_PWD="$MYSQL_PASSWORD" mysql -u"$MYSQL_USER" "$MYSQL_DATABASE"'; else load='MYSQL_PWD="$MARIADB_PASSWORD" mariadb -u"$MARIADB_USER" "$MARIADB_DATABASE"'; fi
  # with set -o pipefail, as docs/backups.md#restore-with-quadlets says: a run that is not there fails, instead of loading nothing
  check "$(grep -cxF 'set -o pipefail   # a missing or broken dump fails its line, instead of an empty restore' "${CODE}/docs/backups.md")" 1 "docs/backups.md's Quadlet restore sets pipefail"
  missing=$( (set -o pipefail; dump "sync/20000101T000000Z/tokenserver.sql.gz" | podman exec -i firefox-sync-tokenserver-db sh -c "${load}") >> restore.log 2>&1 || echo failed)
  check "${missing}" failed "a restore of a run that is not there fails (quadlets)"
  for db in tokenserver syncstorage; do
    (set -o pipefail; dump "sync/${run}/${db}.sql.gz" | podman exec -i "firefox-sync-${db}-db" sh -c "${load}") >> restore.log 2>&1
    check "$?" 0 "${db} restored from ${run} as its user (quadlets)"
  done
  # the admin UI's database, as its user (the line of docs/backups.md#restore-with-quadlets, the client of the image)
  # shellcheck disable=SC2016
  admin_load='MYSQL_PWD="$ADMIN_DB_PASSWORD" mariadb -u"$ADMIN_DB_USER" "$ADMIN_DB_NAME"'
  check "$(grep -cF "dump sync/\$run/ffs_admin.sql.gz | podman exec -i firefox-sync-tokenserver-db sh -c '${admin_load}'" "${CODE}/docs/backups.md")" 1 "docs/backups.md's Quadlet restore of the admin UI's database"
  [ "${SYNC_DB}" = mysql ] && admin_load=${admin_load/ mariadb / mysql }
  (set -o pipefail; dump "sync/${run}/ffs_admin.sql.gz" | podman exec -i firefox-sync-tokenserver-db sh -c "${admin_load}") >> restore.log 2>&1
  check "$?" 0 "ffs_admin restored from ${run} as its user (quadlets)"
  check "$(admin_db_sql "SELECT COUNT(*) FROM ffs_events")" "${EVENTS}" "the event log as it was (quadlets)"
  check "$(inventory ts_sql | sed 's/^/tokenserver /'; inventory st_sql | sed 's/^/storage /')" "${BEFORE}" \
    "the same rows in every table, the same triggers and procedures (quadlets)"
  check "$(payloads)" "${PAYLOADS}" "the Sync items' payloads as they were (quadlets)"
fi
[ "${FAILED}" = 0 ] || tail -20 restore.log
timeout 900 systemctl --user start firefox-sync-syncstorage.service
check "$?" 0 "systemctl --user start firefox-sync-syncstorage.service (restored)"
check "$(hb)" 200 "/__heartbeat__ after the restore (quadlets)"
check "$(ts_sql "SELECT COUNT(*) FROM users WHERE email = 'restore@ffs-e2e.invalid'") $(systemctl --user is-active firefox-sync-admin.service)" "1 active" \
  "the restored user kept by the init, the admin UI started again (quadlets)"
check "$(quadlets_healthy 300)" "all healthy" "every long-running unit has a HealthCmd and passes podman healthcheck run (quadlets)"

if [ "${SYNC_DB}" = postgres ]; then
  echo "== the PostgreSQL install: --upgrade, a quoted .env, another major (quadlets)"
  cp -p .env "${WORK}/pg.env"
  ./prepare_environment.sh --upgrade < /dev/null > upgrade-pg.log 2>&1
  # (the admin UI's unit again without the line of fast_admin_checks)
  check "$? $(grep -c '^Nothing to add' upgrade-pg.log) $(sed -n 's/^  ✓ //p' upgrade-pg.log | paste -sd' ') $(cmp -s .env "${WORK}/pg.env" && echo same)" "0 1 firefox-sync-admin.container same" \
    "--upgrade on the PostgreSQL install of this release: nothing to change in .env, the units as rendered (quadlets)"
  # as compose reads it: quoted, with a comment
  sed -i 's|^SYNC_IMAGE=.*|SYNC_IMAGE="syncstorage-rs-postgres" # pg|' .env
  ./prepare_environment.sh --render-units < /dev/null > render-units-pg.log 2>&1
  check "$? $(grep -c 'nothing changed$' render-units-pg.log)" "0 1" "a quoted SYNC_IMAGE of PostgreSQL: the same units (quadlets)"
  cp -p "${WORK}/pg.env" .env
  # another major than the data's: the database does not start, keep-major.sh says what to set;
  # back to the major of the data, it starts as before
  other=$((pg_major - 1))
  sed -i "s|^SYNC_POSTGRES_IMAGE=.*|SYNC_POSTGRES_IMAGE=postgres:${other}|" .env
  ./prepare_environment.sh --render-units < /dev/null > render-units-pg-other.log 2>&1
  check "$? $(sed -n 's/^  ✓ //p' render-units-pg-other.log | LC_ALL=C sort | paste -sd' ')" "0 firefox-sync-backup.container firefox-sync-postgres-db.container" \
    "SYNC_POSTGRES_IMAGE=postgres:${other}: the database and the backup units rendered (quadlets)"
  podman pull -q "docker.io/library/postgres:${other}" > /dev/null 2>&1
  PG_SINCE=$(date '+%Y-%m-%d %H:%M:%S')
  timeout 300 systemctl --user stop firefox-sync-syncstorage.service firefox-sync-admin.service firefox-sync-postgres-db.service
  timeout 120 systemctl --user start firefox-sync-postgres-db.service > /dev/null 2>&1
  for _ in $(seq 1 30); do
    journalctl --user -u firefox-sync-postgres-db.service --since "${PG_SINCE}" --no-pager 2> /dev/null | grep -q 'keep-major.sh: this database is PostgreSQL' && break
    sleep 2
  done
  check "$(journalctl --user -u firefox-sync-postgres-db.service --since "${PG_SINCE}" --no-pager 2> /dev/null | grep -c "keep-major.sh: this database is PostgreSQL ${pg_major} .*the image is PostgreSQL ${other},\|Set SYNC_POSTGRES_IMAGE to the major of the data, postgres:${pg_major}\." | awk '{ print ($1 >= 2 ? 2 : $1) }') $(podman ps -q --filter name=firefox-sync-postgres-db --filter status=running | wc -l) $(podman run --rm -v firefox-sync-postgres-db:/v:ro docker.io/library/postgres:latest sh -c "ls /v" | grep -x '[0-9]*' | paste -sd' ')" \
    "2 0 ${pg_major}" "postgres:${other} on PostgreSQL ${pg_major}'s data: not started, keep-major.sh says what to set, the data as it was (quadlets)"
  timeout 120 systemctl --user stop firefox-sync-postgres-db.service; systemctl --user reset-failed firefox-sync-postgres-db.service 2> /dev/null
  cp -p "${WORK}/pg.env" .env
  ./prepare_environment.sh --render-units < /dev/null > render-units-pg-back.log 2>&1
  timeout 900 systemctl --user start firefox-sync-admin.service firefox-sync-syncstorage.service
  check "$? $(hb) $(ts_sql "SELECT COUNT(*) FROM users WHERE email = 'restore@ffs-e2e.invalid'")" "0 200 1" "back on postgres:${pg_major}: the Sync server and its data (quadlets)"
  podman rmi "docker.io/library/postgres:${other}" > /dev/null 2>&1
fi

if [ -n "${SYNC_MYSQL_FROM:-}" ]; then
  echo "== the Sync databases from ${SYNC_MYSQL_FROM} to mysql:lts, as docs/upgrading.md#mysql-8-to-9 says for the Quadlets"
  UPGRADING_MD=$(cat "${CODE}/docs/upgrading.md")
  for c in 'systemctl --user start firefox-sync-backup.service' './prepare_environment.sh --render-units' 'podman pull docker.io/library/mysql:lts' \
    'systemctl --user restart firefox-sync-tokenserver-db.service firefox-sync-syncstorage-db.service'; do
    check "$([[ "${UPGRADING_MD}" == *"\`${c}\`"* ]] && echo yes)" yes "docs/upgrading.md#mysql-8-to-9 says ${c} for the Quadlets"
  done
  mysql_major() { podman exec "firefox-sync-$1-db" mysqld --version | sed -n 's/.* Ver \([0-9][0-9]*\)\..*/\1/p'; }
  old_major=$(mysql_major tokenserver)
  timeout 300 systemctl --user start firefox-sync-backup.service
  check "$?" 0 "a backup before the move (quadlets, MySQL)"
  sed -i 's|^SYNC_MYSQL_IMAGE=.*|SYNC_MYSQL_IMAGE=mysql:lts|' .env
  ./prepare_environment.sh --render-units < /dev/null > render-mysql-lts.log 2>&1
  check "$? $(sed -n 's/^  ✓ //p' render-mysql-lts.log | grep -vx 'firefox-sync-admin.container' | LC_ALL=C sort | paste -sd' ')" \
    "0 firefox-sync-backup.container firefox-sync-syncstorage-db.container firefox-sync-tokenserver-db.container" "SYNC_MYSQL_IMAGE=mysql:lts in the database and backup units (quadlets)"
  podman pull -q docker.io/library/mysql:lts > /dev/null
  timeout 900 systemctl --user restart firefox-sync-tokenserver-db.service firefox-sync-syncstorage-db.service
  check "$? $(hb)" "0 200" "the databases restarted on mysql:lts, the Sync server after them (quadlets)"
  check "$([ "$(mysql_major tokenserver)" -gt "${old_major}" ] && [ "$(mysql_major syncstorage)" -gt "${old_major}" ] && echo yes) $(ts_sql "SELECT COUNT(*) FROM users WHERE email = 'restore@ffs-e2e.invalid'") $([ "$(payloads)" = "${PAYLOADS}" ] && echo same)" \
    "yes 1 same" "the Sync databases on MySQL $(mysql_major tokenserver) (from ${old_major}), their data as it was (quadlets)"
  check "$(admin_up /login) $(metrics_show "${DB_UP[@]}")" "200 all" "the admin UI reaches the databases on mysql:lts (quadlets)"
fi

if [ "${FAILED}" != 0 ]; then
  tail -20 quadlet-dryrun.log
  journalctl --user -u 'firefox-sync-*' --no-pager | tail -60
  diagnose
fi

stop_quadlets() {
  systemctl --user stop $(systemctl --user list-units --all --plain --no-legend 'firefox-sync-*' | awk '{print $1}') 2> /dev/null
  systemctl --user disable firefox-sync-backup.timer > /dev/null 2>&1
  rm -f "${QUADLET_DIR}"/firefox-sync-* "${SYSTEMD_USER_DIR}"/firefox-sync-*.timer
  systemctl --user daemon-reload
  podman volume rm -f $(podman volume ls -q | grep '^firefox-sync-') > /dev/null 2>&1
}

echo "== the dumps of an install loaded into a new one, as docs/migrating.md#loading-into-firefox-sync says for the Quadlets"
# the dumps: those of the last backup of this install, whole databases with the account and the
# Sync items of the restore above, as another syncstorage-rs server's would be
MIGRATING_MD=$(cat "${CODE}/docs/migrating.md")
mig_documented() { [[ "${MIGRATING_MD}" == *"$1"* ]] && echo yes || echo "not in docs/migrating.md"; }
run=$(podman run --rm -v firefox-sync-backups:/backups:ro docker.io/library/mariadb:lts ls /backups/sync | tail -1)
mkdir -p "${WORK}/dumps"
if [ "${SYNC_DB}" = postgres ]; then mig_dbs=(syncserver); else mig_dbs=(tokenserver syncstorage); fi
for db in "${mig_dbs[@]}"; do dump "sync/${run}/${db}.sql.gz" > "${WORK}/dumps/${db}.sql"; done
check "$(for db in "${mig_dbs[@]}"; do [ -s "${WORK}/dumps/${db}.sql" ] && echo "${db}"; done | paste -sd' ')" "${mig_dbs[*]}" "the dumps of ${run}"
stop_quadlets
# a new install (new passwords), not started
rm -f .env
setup "${SYNC_DB}" 1
check "$?" 0 "prepare_environment.sh for the new install (quadlets)"
if [ "${SYNC_DB}" = postgres ]; then
  # shellcheck disable=SC2016 # (expanded in the database container)
  MIG=('systemctl --user start firefox-sync-sync-role-init.service'
    "podman exec -i firefox-sync-postgres-db sh -c 'PGPASSWORD=\"\$FFS_SYNC_PASSWORD\" psql -h 127.0.0.1 -U \"\$FFS_SYNC_USER\" -d \"\$POSTGRES_DB\" -v ON_ERROR_STOP=1' < syncserver.sql")
else
  # the lines of docker compose there, as the Quadlets' with podman exec -i in the units' containers
  client=$([ "${SYNC_DB}" = mysql ] && echo mysql || echo mariadb)
  MIG=('systemctl --user start firefox-sync-tokenserver-db.service firefox-sync-syncstorage-db.service')
  for db in tokenserver syncstorage; do
    line=$(grep -m1 -E "^ *docker compose exec -T ${db}_db sh -c 'MYSQL_PWD=[^ ]* ${client} " "${CODE}/docs/migrating.md" | sed 's/^ *//')
    check "$([ -n "${line}" ] && echo yes)" yes "docs/migrating.md loads ${db}.sql with ${client} (docker compose)"
    MIG+=("$(sed "s/^docker compose exec -T ${db}_db /podman exec -i firefox-sync-${db}-db /" <<< "${line}")")
  done
  check "$(mig_documented "podman exec -i firefox-sync-tokenserver-db sh -c '...' < tokenserver.sql\` and \`firefox-sync-syncstorage-db")" yes \
    "docs/migrating.md says podman exec -i firefox-sync-tokenserver-db for the Quadlets, firefox-sync-syncstorage-db the same"
fi
check "$(mig_documented "${MIG[0]}")" yes "docs/migrating.md says ${MIG[0]}"
[ "${SYNC_DB}" != postgres ] || check "$(mig_documented "${MIG[1]}")" yes "docs/migrating.md says ${MIG[1]%% <*}"
check "$(mig_documented 'then start `firefox-sync-syncstorage.service`')" yes "docs/migrating.md says to start firefox-sync-syncstorage.service then"
eval "timeout 300 ${MIG[0]}"
check "$?" 0 "${MIG[0]} (quadlets)"
# (the databases answer: their healthchecks, as docs/migrating.md says)
for _ in $(seq 1 60); do
  ready=yes
  for u in "${DB_UNITS[@]}"; do [ "${u}" = sync-role-init ] || podman healthcheck run "firefox-sync-${u}" > /dev/null 2>&1 || ready=""; done
  [ -n "${ready}" ] && break
  sleep 2
done
for c in "${MIG[@]:1}"; do
  (cd "${WORK}/dumps" && eval "${c}") >> migrate-load.log 2>&1
  check "$?" 0 "loaded: ${c%% sh -c*}, $(sed 's/.*< //' <<< "${c}") (quadlets)"
done
timeout 900 systemctl --user start firefox-sync-syncstorage.service
check "$? $(hb) $(ts_sql "SELECT COUNT(*) FROM users WHERE email = 'restore@ffs-e2e.invalid'") $([ "$(payloads)" = "${PAYLOADS}" ] && echo same)" "0 200 1 same" \
  "the new install with the account and the Sync items of the dumps (quadlets)"
[ "${FAILED}" = 0 ] || tail -20 migrate-load.log
stop_quadlets

echo "== quadlets without the admin UI (mariadb)"
mariadb_sql
# a new install (the .env of the phase before pins its databases' major, which a setup run
# again keeps: UPGRADE_FROM's)
rm -f .env
# answers as setup, admin UI: n, the accounts and your own server: no, the nightly backups:
# yes. The Sync server starts without ffs-admin to resolve (the port as address and port)
printf '%s\n' ffs-e2e.invalid "" "127.0.0.1:${PORT}" 1 mariadb 1 "" "${TAG}" n "" "" y | ./prepare_environment.sh > setup-no-admin.log 2>&1
check "$?" 0 "prepare_environment.sh (quadlets, no admin UI)"
check "$(env_of COMPOSE_PROFILES) $(systemctl --user is-enabled firefox-sync-backup.timer 2> /dev/null)" "backup enabled" \
  "the nightly backups chosen: COMPOSE_PROFILES=backup, the backup timer enabled (quadlets)"
# rendered again: .env and the timer as they are, nothing asked
./prepare_environment.sh --render-units < /dev/null > render-no-admin.log 2>&1
check "$? $(env_of COMPOSE_PROFILES) $(systemctl --user is-enabled firefox-sync-backup.timer 2> /dev/null) $(grep -c 'nothing changed$' render-no-admin.log)" "0 backup enabled 1" \
  "--render-units keeps COMPOSE_PROFILES and the backup timer (quadlets)"
check "$(sed -n 's/^PublishPort=//p' "${QUADLET_DIR}/firefox-sync-syncstorage.container")" "127.0.0.1:${PORT}:8000" "127.0.0.1:<port> answered: the Sync server's PublishPort"
check "$(ls "${QUADLET_DIR}"/firefox-sync-admin.* 2> /dev/null | wc -l)" 0 "no admin UI quadlet"
check "$(grep -hcxF 'Environment=MAX_USERS=1' "${QUADLET_DIR}/firefox-sync-tokenserver-db-init.container")" 1 "plain SYNC_MAX_USERS=1 in the init quadlet"
check "$(sed -n 's/^Image=//p' "${QUADLET_DIR}"/firefox-sync-{syncstorage-db,tokenserver-db,backup}.container | paste -sd' ') $(env_of SYNC_MARIADB_IMAGE)" \
  "docker.io/library/mariadb:lts docker.io/library/mariadb:lts docker.io/library/mariadb:lts mariadb:lts" "the Sync MariaDB units on lts for a new install (SYNC_MARIADB_IMAGE)"
"${QUADLET}" -dryrun -user > quadlet-no-admin-dryrun.log 2>&1
check "$?" 0 "quadlet generator accepts the files without the admin UI"
QUADLET_SINCE=$(date '+%Y-%m-%d %H:%M:%S')
timeout 900 systemctl --user start firefox-sync-syncstorage.service
check "$?" 0 "systemctl --user start firefox-sync-syncstorage.service (no admin UI)"
check "$(hb)" 200 "/__heartbeat__ (quadlets, no admin UI)"
check "$(journalctl --user -u firefox-sync-syncstorage.service --since "${QUADLET_SINCE}" --no-pager 2> /dev/null | grep -c 'Sending metrics')" 0 \
  "no metrics host without the admin UI (quadlets)"
if [ "${FAILED}" != 0 ]; then
  tail -20 setup-no-admin.log quadlet-no-admin-dryrun.log
  journalctl --user -u 'firefox-sync-*' --since "${QUADLET_SINCE}" --no-pager | tail -40
fi

echo "== quadlets with the Sync databases on MySQL (SYNC_DB=mysql): only what is installed"
setup mysql 1
check "$?" 0 "prepare_environment.sh (quadlets, MySQL)"
check "$(health_parity "${QUADLET_DIR}" docker compose --env-file .env --profile admin --profile backup -f compose/sync.yml -f compose/sync-mysql.yml)" same "the MySQL Quadlets' healthchecks are compose's"
check "$(grep -c '^SYNC_DB=mysql$' .env) $(grep -c '^COMPOSE_FILE=compose/sync.yml:compose/sync-mysql.yml$' .env)" "1 1" "SYNC_DB=mysql in .env, with its compose file"
check "$(sed -n 's/^Image=//p' "${QUADLET_DIR}"/firefox-sync-{syncstorage-db,tokenserver-db,backup}.container | paste -sd' ') $(env_of SYNC_MYSQL_IMAGE)" \
  "docker.io/library/mysql:lts docker.io/library/mysql:lts docker.io/library/mysql:lts mysql:lts" "MySQL lts database and backup units for a new install"
check "$(ls "${QUADLET_DIR}"/firefox-sync-*-db*.volume 2> /dev/null | xargs -n1 basename | LC_ALL=C sort | paste -sd' ')" \
  "firefox-sync-syncstorage-db-mysql.volume firefox-sync-tokenserver-db-mysql.volume" "MySQL's own volumes, not MariaDB's"
check "$(grep -hcxE 'Exec=sh /ffs-db/admin-user\.sh mysqld --disable-log-bin|HealthCmd=MYSQL_PWD=\$\$\{MYSQL_PASSWORD\} mysqladmin ping -h 127\.0\.0\.1 --protocol=tcp -u(syncstorage|tokenserver) --silent' "${QUADLET_DIR}"/firefox-sync-{syncstorage,tokenserver}-db.container | paste -sd' ')" \
  "2 2" "MySQL without binary logging, healthcheck over TCP (the password in its environment, not on its command line)"
check "$(grep -cxF 'Environment=MARIADB_TLS_VERIFY=false' "${QUADLET_DIR}/firefox-sync-tokenserver-db-init.container")" 1 "init container does not check MySQL's self-signed certificate"
check "$(grep -l '%[A-Z_]*%' "${QUADLET_DIR}"/firefox-sync-* | wc -l)" 0 "no unreplaced placeholders in the MySQL quadlets"
check "$(units_secret_free)" none "no secret of .env in the MySQL units, the secrets in their environment files, 0600"
"${QUADLET}" -dryrun -user > quadlet-mysql-dryrun.log 2>&1
check "$?" 0 "quadlet generator accepts the MySQL database units"
stop_quadlets

if [ "${SYNC_DB}" != postgres ]; then
  echo "== quadlets with the Sync server on PostgreSQL: only what is installed (SYNC_DB=postgres runs them)"
  rm -f .env
  setup postgres 1
  check "$?" 0 "prepare_environment.sh (quadlets, PostgreSQL)"
  check "$(health_parity "${QUADLET_DIR}" docker compose --env-file .env --profile admin --profile backup -f compose/sync.yml -f compose/sync-postgres.yml)" same "the PostgreSQL Quadlets' healthchecks are compose's"
  pg_units_check "quadlets rendered"
  check "$(grep -l '%[A-Z_]*%' "${QUADLET_DIR}"/firefox-sync-* | wc -l) $(env_keys_diff "-f compose/sync.yml -f compose/sync-postgres.yml" 'FXA_.*|ADMIN_SIGNUP_BURST|ADMIN_DELETE_UNCONFIRMED_DAYS|TOKENSERVER_DB_PASSWORD|FFS_OLD_ENV_NAMES')" "0 |" \
    "no unreplaced placeholders, the admin UI's unit passes every setting of compose's (PostgreSQL)"
  check "$(units_secret_free)" none "no secret of .env in the PostgreSQL units, the secrets in their environment files, 0600"
  "${QUADLET}" -dryrun -user > quadlet-postgres-dryrun.log 2>&1
  check "$?" 0 "quadlet generator accepts the PostgreSQL units"
  stop_quadlets
  # with the accounts: their admin UI's unit on the Sync database of PostgreSQL too
  # (answers as setup, then the accounts' domain, SMTP host, port, user, password, sender, allowlist, admin emails)
  rm -f .env
  printf '%s\n' ffs-e2e.invalid "" "${PORT}" 1 postgres 1 "" "${TAG}" "" y fxa.invalid mail.invalid 587 test pw "" "" "" | ./prepare_environment.sh > setup-postgres-fxa.log 2>&1
  check "$? $(grep -hcxE 'Environment="(TOKENSERVER_DB_TYPE=postgres|TOKENSERVER_DB_HOST=firefox-sync-postgres-db|FXA_DB_HOST=fxa-db)"' "${QUADLET_DIR}/firefox-sync-admin.container") $(env_keys_diff "-f compose/sync.yml -f compose/sync-postgres.yml -f compose/fxa.yml -f compose/fxa-mysql.yml" 'FXA_PAIRING_URL|TOKENSERVER_DB_PASSWORD|FFS_OLD_ENV_NAMES')" "0 3 |" \
    "with the accounts: the admin UI's unit on PostgreSQL and the accounts, every setting of compose's (quadlets rendered)"
  "${QUADLET}" -dryrun -user > quadlet-postgres-fxa-dryrun.log 2>&1
  check "$?" 0 "quadlet generator accepts the PostgreSQL units with the accounts"
  stop_quadlets
  # your own PostgreSQL server: no database unit, nothing depends on one
  # (answers as setup, then: your own server? host, port, database, user)
  rm -f .env
  printf '%s\n' ffs-e2e.invalid "" "${PORT}" 1 postgres 1 "" "${TAG}" "" "" y pg.ffs-e2e.invalid "" "" "" "" n | ./prepare_environment.sh > setup-postgres-external.log 2>&1
  check "$? $(ls "${QUADLET_DIR}"/firefox-sync-*-db.* 2> /dev/null | wc -l) $(grep -hE '^(After|Requires)=.*-db\.service' "${QUADLET_DIR}"/firefox-sync-* | wc -l)" "0 0 0" \
    "your own PostgreSQL server: no database unit, no dependency on one (quadlets)"
  check "$(unit_count '^Environment="?(SYNC_SYNCSTORAGE__DATABASE_URL=postgres://syncserver:[A-Za-z0-9]+@pg\.ffs-e2e\.invalid:5432/syncserver|POSTGRES_SERVER=pg\.ffs-e2e\.invalid|POSTGRES_SYNC_USER=|TOKENSERVER_DB_HOST=pg\.ffs-e2e\.invalid)"?$' \
    "${QUADLET_DIR}"/firefox-sync-{syncstorage,tokenserver-db-init,sync-role-init,admin}.container)" "1 2 2 1" \
    "the units connect to your server as SYNC_POSTGRES_USER, no role of their own (quadlets)"
  "${QUADLET}" -dryrun -user > quadlet-postgres-external-dryrun.log 2>&1
  check "$?" 0 "quadlet generator accepts the PostgreSQL units without the database"
  stop_quadlets
  rm -f .env database-setup.sql
fi

if [ -n "${EXTERNAL_DB:-}" ]; then
  # a server of SYNC_DB outside the Quadlets (MariaDB lts and MySQL lts with binary logging,
  # PostgreSQL latest), its databases and users made by database-setup.sql as
  # docs/databases.md#create-the-databases-and-users says
  case "${SYNC_DB}" in
    mariadb) EXTDB_IMAGE=docker.io/library/mariadb:lts ;;
    mysql) EXTDB_IMAGE=docker.io/library/mysql:lts ;;
    postgres) EXTDB_IMAGE=docker.io/library/postgres:latest ;;
  esac
  echo "== quadlets on your own database server (${EXTDB_IMAGE##*/})"
  EXTDB=ffs-podman-extdb
  # SQL as the server's administrator, on stdin
  extdb_admin() {
    if [ "${SYNC_DB}" = postgres ]; then
      podman exec -i -e PGPASSWORD="${EXTDB_ROOT}" "${EXTDB}" psql -h 127.0.0.1 -U postgres -v ON_ERROR_STOP=1 -tA "$@"
    else
      podman exec -i -e MYSQL_PWD="${EXTDB_ROOT}" "${EXTDB}" sh -c 'exec "$(command -v mariadb || command -v mysql)" "$@"' sql -uroot -h 127.0.0.1 --protocol=tcp -sN "$@"
    fi
  }
  # database-setup.sql as prepare_environment.sh says to run it there (psql -f: an object that
  # exists already is said and passed, as when it runs again; mysql or mariadb <)
  extdb_setup() {
    if [ "${SYNC_DB}" = postgres ]; then
      podman exec -i -e PGPASSWORD="${EXTDB_ROOT}" "${EXTDB}" psql -h 127.0.0.1 -U postgres -q -f - < database-setup.sql
    else
      extdb_admin < database-setup.sql
    fi
  }
  # answers as above, no accounts, then: your own server? host, port, the databases and users
  # (MariaDB, MySQL: tokenserver database and user, storage database and user; PostgreSQL: the
  # database and its user), the alerts' destination, the nightly backups: yes
  rm -f .env database-setup.sql database-setup.sql.before-upgrade-* database-bootstrap.sql
  if [ "${SYNC_DB}" = postgres ]; then ext_names=("" ""); else ext_names=("" "" "" ""); fi
  # DB_BOOTSTRAP=1: then the stack applies database-setup.sql itself (the last question: yes,
  # the account ffs_bootstrap, a new password), docs/databases.md#let-the-stack-apply-them
  ext_bootstrap=()
  [ -n "${DB_BOOTSTRAP:-}" ] && ext_bootstrap=(y "" "")
  printf '%s\n' ffs-e2e.invalid "" "${PORT}" 1 "${SYNC_DB}" 1 "" "${TAG}" "" n y "${EXTDB}" "" "${ext_names[@]}" "" y "${ext_bootstrap[@]}" \
    | ./prepare_environment.sh > setup-external.log 2>&1
  check "$?" 0 "prepare_environment.sh (quadlets, your own ${SYNC_DB} server)"
  check "$(env_of SYNC_DB_CONTAINERS) $(ls "${QUADLET_DIR}"/firefox-sync-*-db.* 2> /dev/null | wc -l)" "0 0" "SYNC_DB_CONTAINERS=0, no database quadlets"
  check "$(units_secret_free)" none "no secret of .env in the units of your own server, the secrets in their environment files, 0600"
  check "$(grep -hE '^(After|Requires)=.*-db\.service' "${QUADLET_DIR}"/firefox-sync-* | wc -l) $(grep -c '^Requires=firefox-sync-syncstorage-migrate.service$' "${QUADLET_DIR}/firefox-sync-tokenserver-db-init.container")" "0 1" \
    "no dependencies on database units, the init still needs the migrations"
  # db-bootstrap before the migrations (and the Sync role), its account's password in its environment file
  check "$(grep -c '^Requires=.*firefox-sync-db-bootstrap\.service' "${QUADLET_DIR}"/firefox-sync-syncstorage-migrate.container) $(grep -c "^Environment=SYNC_DB_BOOTSTRAP_USER=$([ -n "${DB_BOOTSTRAP:-}" ] && echo ffs_bootstrap)$" "${QUADLET_DIR}"/firefox-sync-db-bootstrap.container) $(grep -c "^SYNC_DB_BOOTSTRAP_PASSWORD=$([ -n "${DB_BOOTSTRAP:-}" ] && echo '[A-Za-z0-9]\{32\}')$" "${QUADLET_DIR}"/firefox-sync-db-bootstrap.env)" \
    "1 1 1" "firefox-sync-db-bootstrap, required by the migrations: $([ -n "${DB_BOOTSTRAP:-}" ] && echo "ffs_bootstrap applies the SQL, its password in the unit's environment file" || echo "no account, it checks the SQL")"
  if [ "${SYNC_DB}" = postgres ]; then
    check "$(unit_count "^Environment=\"?(SYNC_SYNCSTORAGE__DATABASE_URL=postgres://syncserver:[A-Za-z0-9]+@${EXTDB}:5432/syncserver|POSTGRES_SERVER=${EXTDB}|TOKENSERVER_DB_HOST=${EXTDB})\"?$" \
      "${QUADLET_DIR}"/firefox-sync-{syncstorage,tokenserver-db-init,admin}.container)" "1 1 1" "quadlets connect to your server"
    ext_dumps="ffs_admin.sql.gz syncserver.sql.gz"
  else
    check "$(unit_count "^Environment=\"?(SYNC_SYNCSTORAGE__DATABASE_URL=mysql://syncstorage:[A-Za-z0-9]+@${EXTDB}:3306/syncstorage|MARIADB_SERVER=${EXTDB}|MARIADB_TLS_VERIFY=false|STORAGE_DB_HOST=${EXTDB})\"?$" \
      "${QUADLET_DIR}"/firefox-sync-{syncstorage,tokenserver-db-init,admin}.container)" "1 2 1" "quadlets connect to your server"
    ext_dumps="ffs_admin.sql.gz syncstorage.sql.gz tokenserver.sql.gz"
  fi
  "${QUADLET}" -dryrun -user > quadlet-external-dryrun.log 2>&1
  check "$?" 0 "quadlet generator accepts the files without database units"
  systemctl --user start firefox-sync-network-network.service
  EXTDB_ROOT=$(tr -dc '[:alnum:]' < /dev/urandom | head -c 24)
  podman rm -f "${EXTDB}" > /dev/null 2>&1
  case "${SYNC_DB}" in
    mariadb) podman run -d --name "${EXTDB}" --network firefox-sync --tmpfs /var/lib/mysql -e MARIADB_ROOT_PASSWORD="${EXTDB_ROOT}" \
      "${EXTDB_IMAGE}" mariadbd --log-bin=mysql-bin --server-id=1 --log-bin-trust-function-creators=1 > /dev/null ;;
    # binary logging is on by default: the trigger needs log_bin_trust_function_creators
    mysql) podman run -d --name "${EXTDB}" --network firefox-sync --tmpfs /var/lib/mysql -e MYSQL_ROOT_PASSWORD="${EXTDB_ROOT}" \
      "${EXTDB_IMAGE}" --log-bin-trust-function-creators=ON > /dev/null ;;
    postgres) podman run -d --name "${EXTDB}" --network firefox-sync --tmpfs /var/lib/postgresql -e POSTGRES_PASSWORD="${EXTDB_ROOT}" \
      "${EXTDB_IMAGE}" > /dev/null ;;
  esac
  # over TCP: while the images initialize, a temporary server listens on the socket only
  for _ in $(seq 1 90); do
    if [ "${SYNC_DB}" = postgres ]; then extdb_admin -c 'SELECT 1' < /dev/null > /dev/null 2>&1 && break
    else extdb_admin -e 'SELECT 1' < /dev/null > /dev/null 2>&1 && break; fi
    sleep 2
  done
  check "$(stat -c %a database-setup.sql)" 600 "database-setup.sql for this user only"
  # as prepare_environment.sh says to run it (psql -f, mysql or mariadb <), here in the server's
  # container; DB_BOOTSTRAP=1: database-bootstrap.sql, the account alone (the stack does the rest)
  sql_file=database-setup.sql
  [ -n "${DB_BOOTSTRAP:-}" ] && sql_file=database-bootstrap.sql
  if [ "${SYNC_DB}" = postgres ]; then said="psql -h ffs-podman-extdb -p 5432 -U postgres -f ${sql_file}"; else said="$([ "${SYNC_DB}" = mysql ] && echo MySQL || echo MariaDB): * $([ "${SYNC_DB}" = mysql ] && echo mysql || echo mariadb) -h ffs-podman-extdb -P 3306 -u root -p < ${sql_file}"; fi
  check "$(grep -c -- "${said}" setup-external.log)" 1 "prepare_environment.sh says how to run ${sql_file} (${SYNC_DB})"
  if [ -n "${DB_BOOTSTRAP:-}" ]; then
    check "$(stat -c %a database-bootstrap.sql)" 600 "database-bootstrap.sql for this user only"
    if [ "${SYNC_DB}" = postgres ]; then
      podman exec -i -e PGPASSWORD="${EXTDB_ROOT}" "${EXTDB}" psql -h 127.0.0.1 -U postgres -v ON_ERROR_STOP=1 -q -f - < database-bootstrap.sql > /dev/null
    else
      extdb_admin < database-bootstrap.sql > /dev/null
    fi
    check "$?" 0 "database-bootstrap.sql runs on the server: the bootstrap account alone"
  else
    extdb_setup > /dev/null
    check "$?" 0 "database-setup.sql runs on the server"
  fi
  timeout 900 systemctl --user start firefox-sync-admin.service firefox-sync-syncstorage.service
  check "$?" 0 "systemctl --user start firefox-sync-syncstorage.service (your own server)"
  check "$(hb)" 200 "/__heartbeat__ (quadlets, your own server)"
  # (each line twice in the journal: the unit's and the container's)
  check "$([ "$(journalctl --user -u firefox-sync-db-bootstrap.service --no-pager | grep -c "$([ -n "${DB_BOOTSTRAP:-}" ] && echo '✓ setup migrations 001.* applied as ffs_bootstrap' || echo '✓ the Sync databases on .*: every user, grant and database of the setup migrations 001.* is there, recorded as their baseline')")" -ge 1 ] && echo 1)" 1 \
    "firefox-sync-db-bootstrap $([ -n "${DB_BOOTSTRAP:-}" ] && echo "applied the setup migrations as ffs_bootstrap" || echo "found every user and grant of database-setup.sql: the baseline")"
  if [ "${SYNC_DB}" = postgres ]; then
    check "$(extdb_admin -d syncserver -c "SELECT COUNT(*) FROM pg_trigger WHERE tgname = 'before_insert_user'" < /dev/null) $(extdb_admin -d syncserver -c "SELECT pg_get_userbyid(relowner) FROM pg_class WHERE relname = 'users' AND relnamespace = 'public'::regnamespace" < /dev/null)" \
      "1 syncserver" "SYNC_MAX_USERS trigger on your server, the tables of SYNC_POSTGRES_USER (no superuser)"
    check "$(metrics_show "${SYNC_UP[@]}")" all "admin UI reaches your server (quadlets)"
  else
    check "$(extdb_admin -e "SELECT @@log_bin; SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_name = 'BeforeInsertUser'" < /dev/null | paste -sd' ')" \
      "1 1" "SYNC_MAX_USERS trigger on your server, with binary logging"
    check "$(metrics_show "${SYNC_UP[@]}" 'ffs_up{component="Storage database"} 1')" all "admin UI reaches your server (quadlets)"
  fi
  # the nightly backups: chosen, their timer on; one now, recorded in the admin UI's database there
  ext_backups() {
    if [ "${SYNC_DB}" = postgres ]; then extdb_admin -d ffs_admin -c "SELECT COUNT(*) FROM ffs_backups WHERE scope = 'sync' AND ok = 1 AND bytes > 0" < /dev/null
    else extdb_admin -e "SELECT COUNT(*) FROM ffs_admin.ffs_backups WHERE scope = 'sync' AND ok = 1 AND bytes > 0" < /dev/null; fi
  }
  check "$(env_of COMPOSE_PROFILES) $(systemctl --user is-enabled firefox-sync-backup.timer 2> /dev/null)" "admin,backup enabled" "the nightly backups chosen, the timer enabled (your own server)"
  timeout 300 systemctl --user start firefox-sync-backup.service
  check "$? $(ext_backups) $(podman run --rm -v firefox-sync-backups:/backups:ro "${EXTDB_IMAGE}" sh -c 'for f in /backups/sync/*/*.sql.gz; do gzip -t "$f" && basename "$f"; done' | sort | paste -sd' ')" \
    "0 1 ${ext_dumps}" "a backup of your server, recorded in its ffs_admin, the dumps in the volume (quadlets)"
  [ "${FAILED}" = 0 ] || journalctl --user -u firefox-sync-backup.service --no-pager | tail -20
  # the upgrade as docs/upgrading.md#quadlets says: --upgrade (database-setup.sql written
  # again, run there first), a setting changed and rendered again, every unit started again
  cp -p .env "${WORK}/external.env"
  ./prepare_environment.sh --upgrade < /dev/null > upgrade-external.log 2>&1
  if [ -n "${DB_BOOTSTRAP:-}" ]; then upgrade_said='^Your own database server: the stack applies the setup migrations it lacks itself at the next start, as ffs_bootstrap'
  else upgrade_said='^Your own database server: .*run database-setup.sql there first'; fi
  check "$? $(grep -c "${upgrade_said}" upgrade-external.log) $(grep -c 'nothing changed$' upgrade-external.log) $(cmp -s .env "${WORK}/external.env" && echo same) $(ls database-setup.sql.before-upgrade-* | wc -l) $(stat -c %a database-setup.sql.before-upgrade-*)" "0 1 1 same 1 600" \
    "--upgrade on your own server: database-setup.sql written again, the one of before kept (0600)$([ -n "${DB_BOOTSTRAP:-}" ] && echo ", the bootstrap kept"), nothing else to change (quadlets)"
  if [ -z "${DB_BOOTSTRAP:-}" ]; then
    extdb_setup > /dev/null 2> setup-sql-again.log
    check "$?" 0 "database-setup.sql runs again on the server"
  fi
  sed -i 's|^ADMIN_STALE_DAYS=.*|ADMIN_STALE_DAYS=45|' .env
  ./prepare_environment.sh --render-units < /dev/null > render-units-external.log 2>&1
  check "$? $(sed -n 's/^  ✓ //p' render-units-external.log | paste -sd' ')" "0 firefox-sync-admin.container" "--render-units on your own server: the admin UI's unit alone"
  # (the one-shot db-bootstrap is not active once it ran: no RemainAfterExit)
  check "$(systemctl --user is-active firefox-sync-db-bootstrap.service)" inactive "firefox-sync-db-bootstrap inactive once it ran"
  boot_runs() { journalctl --user -u firefox-sync-db-bootstrap.service --no-pager | grep -c 'Started firefox-sync-db-bootstrap.service\|Finished firefox-sync-db-bootstrap.service'; }
  runs_before=$(boot_runs)
  timeout 300 systemctl --user stop firefox-sync-syncstorage.service firefox-sync-admin.service firefox-sync-syncstorage-migrate.service \
    firefox-sync-tokenserver-db-init.service $([ "${SYNC_DB}" = postgres ] && echo firefox-sync-sync-role-init.service)
  timeout 900 systemctl --user start firefox-sync-admin.service firefox-sync-syncstorage.service
  check "$? $(hb) $(admin_up /login) $([ "$(boot_runs)" -gt "${runs_before}" ] && echo again)" "0 200 200 again" \
    "the units started again, rendered again (your own server): db-bootstrap ran again before the migrations"
  # a restart of the migrations alone runs it again too (it requires it, which is not active)
  runs_before=$(boot_runs)
  timeout 600 systemctl --user restart firefox-sync-syncstorage-migrate.service
  check "$? $([ "$(boot_runs)" -gt "${runs_before}" ] && echo again)" "0 again" "systemctl --user restart firefox-sync-syncstorage-migrate: db-bootstrap ran again first"
  [ "${FAILED}" = 0 ] || { journalctl --user -u 'firefox-sync-*' --no-pager | tail -40; podman logs --tail 20 "${EXTDB}"; }
  stop_quadlets
  podman rm -f "${EXTDB}" > /dev/null 2>&1
  podman network rm -f firefox-sync > /dev/null 2>&1
  rm -f .env database-setup.sql database-setup.sql.before-upgrade-* database-bootstrap.sql

  # the accounts on your own MySQL server: only what is installed (no MySQL here)
  # answers: ..., admin host, your own server for Sync? the accounts? host, port, user, policy user
  printf '%s\n' ffs-e2e.invalid "" "${PORT}" 1 mariadb 1 "" "${TAG}" "" y fxa.invalid mail.invalid 587 test pw "" "" "" \
    n y fxa-mysql.invalid "" "" "" | ./prepare_environment.sh > setup-fxa-external.log 2>&1
  check "$?" 0 "prepare_environment.sh (quadlets, accounts on your own server)"
  # (and firefox-sync-fxa-db-bootstrap: its users and grants checked before the migrations)
  check "$(ls "${QUADLET_DIR}"/firefox-sync-fxa-*.{container,volume} 2> /dev/null | wc -l) $(ls "${QUADLET_DIR}"/firefox-sync-fxa-db-bootstrap.container | wc -l)" "12 1" \
    "accounts quadlet files without the database, with fxa-db-bootstrap"
  check "$(grep -hoE '^Environment="(((AUTH|OAUTH|PROFILE|PUSHBOX)_)?MYSQL|FXA_DB)_HOST=[^"]*"' "${QUADLET_DIR}"/firefox-sync-{fxa-*,admin}.container | sed 's/.*=//' | sort | uniq -c | sed 's/^ *//')" \
    '10 fxa-mysql.invalid"' "the accounts connect to your server"
  check "$(grep -hcE '^Environment="(FXA_DB_ROOT_USER=ffs_policy|FXA_MYSQL_USER=fxa)"$' "${QUADLET_DIR}/firefox-sync-fxa-policy.container")" 2 "sign-up policy installed by ffs_policy"
  check "$(grep '^Requires=' "${QUADLET_DIR}/firefox-sync-fxa-migrations.container")" "Requires=firefox-sync-fxa-db-bootstrap.service" \
    "accounts migrations without the database unit, after fxa-db-bootstrap"
  "${QUADLET}" -dryrun -user > quadlet-fxa-external-dryrun.log 2>&1
  check "$?" 0 "quadlet generator accepts the accounts files without the database"
  stop_quadlets
fi

FXA_DB=${FXA_DB:-mysql}
fxa_db_image() { sed -n 's/^Image=//p' "${QUADLET_DIR}/firefox-sync-fxa-db.container" 2> /dev/null; }
if [ -z "${SKIP_FXA:-}" ] && [ "${FXA_DB}" != mariadb ]; then
  echo "== quadlets with the accounts on MariaDB: only what is installed"
  # answers: as below, then your own server for Sync? the accounts? the accounts database
  printf '%s\n' ffs-e2e.invalid "" "${PORT}" 1 mariadb 1 "" "${TAG}" "" y fxa.invalid mail.invalid 587 test pw "" "" "" \
    n n mariadb | ./prepare_environment.sh > setup-fxa-mariadb.log 2>&1
  check "$?" 0 "prepare_environment.sh (quadlets, accounts on MariaDB)"
  check "$(health_parity "${QUADLET_DIR}" docker compose --env-file .env --profile admin --profile backup --profile pairing -f compose/sync.yml -f compose/sync-mariadb.yml -f compose/fxa.yml -f compose/fxa-mariadb.yml)" same \
    "the Quadlets' healthchecks with the accounts on MariaDB are compose's"
  check "$(fxa_db_image) $(ls "${QUADLET_DIR}"/firefox-sync-fxa-db* 2> /dev/null | xargs -n1 basename | LC_ALL=C sort | paste -sd' ')" \
    "docker.io/library/mariadb:lts firefox-sync-fxa-db-mariadb.volume firefox-sync-fxa-db.container firefox-sync-fxa-db.env" "MariaDB lts unit (and its environment file) and its own volume, not MySQL's"
  check "$(sed -n 's/^Image=//p' "${QUADLET_DIR}/firefox-sync-backup-fxa.container")" docker.io/library/mariadb:lts "the backups of the accounts with the same MariaDB"
  "${QUADLET}" -dryrun -user > quadlet-fxa-mariadb-dryrun.log 2>&1
  check "$?" 0 "quadlet generator accepts the MariaDB accounts database"
  # a setting of the accounts changed in .env, rendered again: the units of the install (with
  # the accounts on MariaDB and the admin UI), only fxa-auth's changes
  check "$(grep -cxF 'Environment="LOG_LEVEL=INFO"' "${QUADLET_DIR}/firefox-sync-fxa-auth.container")" 1 "fxa-auth logs at INFO without FXA_LOG_LEVEL"
  cp -p .env "${WORK}/fxa-mariadb.env"
  echo 'FXA_LOG_LEVEL=DEBUG' >> .env
  ./prepare_environment.sh --render-units < /dev/null > render-units-fxa.log 2>&1
  check "$? $(sed -n 's/^  ✓ //p' render-units-fxa.log | paste -sd' ') $(grep -cxF 'Environment="LOG_LEVEL=DEBUG"' "${QUADLET_DIR}/firefox-sync-fxa-auth.container") $(secrets_kept "${WORK}/fxa-mariadb.env" .env | sed 's/ [0-9]*$//')" \
    "0 firefox-sync-fxa-auth.container 1 kept" "--render-units with the accounts on MariaDB: FXA_LOG_LEVEL in fxa-auth's unit alone, the secrets kept"
  [ "${FAILED}" = 0 ] || cat render-units-fxa.log
  # values written otherwise, as compose reads them: quoted with a comment, export; a name
  # .env lacks is not taken from this shell. The same units, nothing appended to .env
  units_sum() { cat "${QUADLET_DIR}"/firefox-sync-* | md5sum; }
  sum=$(units_sum)
  repo=$(env_of IMAGE_REPOSITORY)
  sed -i -e "s|^IMAGE_REPOSITORY=.*|IMAGE_REPOSITORY=\"${repo}\"  # a mirror|" -e 's|^ADMIN_DB_NAME=|export ADMIN_DB_NAME=|' \
    -e "s|^FXA_LOG_LEVEL=.*|FXA_LOG_LEVEL='DEBUG' # loud|" .env
  cp -p .env "${WORK}/fxa-written.env"
  ADMIN_TZ=Europe/Rome ADMIN_IMAGE=localhost/not-this:one ./prepare_environment.sh --render-units < /dev/null > render-units-quoted.log 2>&1
  check "$? $(grep -c 'nothing changed$' render-units-quoted.log) $([ "$(units_sum)" = "${sum}" ] && echo same) $(cmp -s .env "${WORK}/fxa-written.env" && echo kept) $(grep -c 'ADMIN_DB_NAME=' .env) $(grep -cxF "Image=${repo}:admin-latest" "${QUADLET_DIR}/firefox-sync-admin.container")" \
    "0 1 same kept 1 1" "quoted and commented values, export, this shell's ADMIN_TZ and ADMIN_IMAGE: the same units, .env as it was"
  # the units of before cannot be kept (one unreadable): nothing written
  sed -i "s|^FXA_LOG_LEVEL=.*|FXA_LOG_LEVEL=TRACE|" .env
  backups=$(ls -d quadlets.before-* 2> /dev/null | wc -l)
  chmod 000 "${QUADLET_DIR}/firefox-sync-network.network"
  ./prepare_environment.sh --render-units < /dev/null > render-units-nobackup.log 2>&1
  rc=$?
  chmod 644 "${QUADLET_DIR}/firefox-sync-network.network"
  check "${rc} $(grep -c '^ERROR: could not keep the units of before' render-units-nobackup.log) $([ "$(units_sum)" = "${sum}" ] && echo same) $(ls -d quadlets.before-* 2> /dev/null | wc -l)" "1 1 same ${backups}" \
    "the units of before not kept: --render-units writes no unit"
  # .env, its copies and the units of before: this user only
  check "$(stat -c %a .env .env.before-upgrade-* | sort -u | paste -sd' ') $(stat -c %a quadlets.before-* | sort -u | paste -sd' ')" "600 700" "--render-units: .env and its copies 0600, the units of before 0700"
  stop_quadlets
fi

if [ -z "${SKIP_FXA:-}" ]; then
  echo "== quadlets with self-hosted Mozilla accounts (${FXA_DB})"
  # answers: ..., image tag, admin UI, FxA, FxA domain, SMTP host, port, user, password, sender, allowlist,
  # admin emails, admin host, [your own server for Sync? the accounts? the accounts database]
  fxa_db_answers=()
  [ "${FXA_DB}" = mariadb ] && fxa_db_answers=(n n mariadb)
  # one pull up front, otherwise every unit pulls the 5 GB image at the same time; before
  # prepare_environment.sh, which reads its label (mozilla/fxa#21554: MySQL lts)
  case "$(uname -m)" in aarch64|arm64) fxa_arch=arm64 ;; *) fxa_arch=amd64 ;; esac
  fxa_image=$(grep '^IMAGE_REPOSITORY=' .env-example | cut -d= -f2):$(grep '^FXA_VERSION=' .env-example | cut -d= -f2)
  if [ -n "${FXA_TEST_IMAGE:-}" ]; then
    # the candidate, under the name the quadlets use
    # (a local build is used as it is)
    { podman image exists "${FXA_TEST_IMAGE}" || podman pull -q --arch "${fxa_arch}" "${FXA_TEST_IMAGE}" > /dev/null; } && podman tag "${FXA_TEST_IMAGE}" "${fxa_image}"
  else
    podman pull -q --arch "${fxa_arch}" "${fxa_image}" > /dev/null
  fi
  fxa_pulled=$?
  fxa_image_id=$(podman image inspect -f '{{.Id}}' "${fxa_image}" 2> /dev/null)
  printf '%s\n' ffs-e2e.invalid "" "${PORT}" 1 mariadb 1 "" "${TAG}" "" y fxa.invalid mail.invalid 587 test 'p%ss|w&rd' "" "@fxa.invalid" \
    "me@fxa.invalid" "" "${fxa_db_answers[@]}" \
    | ./prepare_environment.sh > setup-fxa-quadlets.log 2>&1
  check "$?" 0 "prepare_environment.sh (quadlets with accounts)"
  fxa_compose=(-f compose/sync.yml -f compose/sync-mariadb.yml -f compose/fxa.yml -f "compose/fxa-${FXA_DB}.yml")
  check "$(health_parity "${QUADLET_DIR}" docker compose --env-file .env --profile admin --profile backup --profile pairing "${fxa_compose[@]}")" same \
    "every long-running service has a healthcheck, the Quadlets with the accounts compose's (${FXA_DB})"
  check "$(ls "${QUADLET_DIR}"/firefox-sync-fxa-*.{container,volume} 2> /dev/null | wc -l)" 13 "accounts quadlet files installed"
  # MySQL: lts when the accounts image of .env has mozilla/fxa#21554, else 8 with mysql_native_password
  if [ "${FXA_DB}" = mariadb ]; then
    expected_image=docker.io/library/mariadb:lts expected_exec=mariadbd
  elif [ "$(env_of FXA_MYSQL_IMAGE)" = mysql:lts ]; then
    expected_image=docker.io/library/mysql:lts expected_exec="mysqld --event-scheduler=ON "
    check "[$(env_of FXA_MYSQL_ARGS)] $(grep -c 'does not have mozilla/fxa#21554' setup-fxa-quadlets.log)" "[] 0" "the accounts on MySQL lts: no mysql_native_password"
  else
    expected_image=docker.io/library/mysql:8 expected_exec="mysqld --event-scheduler=ON --mysql-native-password=ON --authentication-policy=mysql_native_password"
    check "$(env_of FXA_MYSQL_IMAGE) $(grep -cE 'does not have mozilla/fxa#21554|could not read the labels of' setup-fxa-quadlets.log)" "mysql:8 1" \
      "the accounts on MySQL 8 with mysql_native_password, for an accounts image without mozilla/fxa#21554 (said)"
  fi
  check "$(fxa_db_image) $(sed -n 's/^Image=//p' "${QUADLET_DIR}/firefox-sync-backup-fxa.container")" "${expected_image} ${expected_image}" "accounts database ${FXA_DB} and its backups"
  [ "${FXA_DB}" = mariadb ] || check "$(sed -n 's/^Exec=//p' "${QUADLET_DIR}/firefox-sync-fxa-db.container")" "${expected_exec}" "fxa-db's options (FXA_MYSQL_ARGS)"
  check "$(grep -c 'FXA_DB_HOST=fxa-db' "${QUADLET_DIR}/firefox-sync-admin.container")" 1 "admin UI quadlet for the accounts"
  # no pairing server in the quadlets
  check "$(env_keys_diff "-f compose/sync.yml -f compose/sync-mariadb.yml -f compose/fxa.yml -f compose/fxa-mysql.yml" 'FXA_PAIRING_URL|TOKENSERVER_DB_PASSWORD|STORAGE_DB_PASSWORD|FFS_OLD_ENV_NAMES')" "|" "admin quadlet with the accounts passes every setting of the compose service"
  # max accounts: not asked here (the last question), unlimited and managed in the admin UI
  check "$(cat "${QUADLET_DIR}/firefox-sync-fxa-policy.container" "${QUADLET_DIR}/firefox-sync-admin.container" | grep -cxF 'Environment="FXA_MAX_ACCOUNTS=initial:unlimited"')" 2 \
    "FXA_MAX_ACCOUNTS=initial:unlimited in the sign-up policy and admin UI quadlets"
  # the security history: not asked here either (EOF), off in the auth server and the admin UI;
  # never the sign-in code skipped for a known IP address
  check "$(cat "${QUADLET_DIR}/firefox-sync-fxa-auth.container" "${QUADLET_DIR}/firefox-sync-admin.container" | grep -cxE 'Environment="(ACCOUNT_EVENTS_ENABLED|FXA_ACCOUNT_EVENTS)=false"|Environment="IP_PROFILING_RECENCY=0"')" 3 \
    "no security history by default in the accounts and admin UI quadlets"
  check "$(grep -lE '%[A-Z][A-Z0-9_]*%' "${QUADLET_DIR}"/firefox-sync-* | wc -l)" 0 "no unreplaced placeholders"
  check "$(units_secret_free)" none "no secret of .env in the units of the accounts either, the secrets in their environment files, 0600"
  check "$(grep -cxF 'SMTP_PASS=p%ss|w&rd' "${QUADLET_DIR}/firefox-sync-fxa-auth.env") $(grep -c 'SMTP_PASS' "${QUADLET_DIR}/firefox-sync-fxa-auth.container")" "1 0" \
    "the SMTP password as it is in fxa-auth's environment file (no systemd there to escape a % for), none in its unit"
  # the admin UI signs in with these accounts: its OAuth client always asks the sign-in code
  admin_client=$(grep '^ADMIN_FXA_CLIENT_ID=' .env | cut -d= -f2)
  check "$(echo "${admin_client}" | grep -cE '^[0-9a-f]{16}$')" 1 "admin UI OAuth client id (quadlets)"
  check "$(grep -c "SERVICES_WITH_EMAIL_VERIFICATION=.*,${admin_client}\"" "${QUADLET_DIR}/firefox-sync-fxa-auth.container")" 1 \
    "accounts ask the sign-in code for the admin UI (quadlets)"
  # no defaults in Quadlets: without TRUST_UNVERIFIED_EMAIL every sign-in with the accounts fails
  check "$(grep -cE "^Environment=\"(ADMIN_OIDC_ISSUER=https://accounts.fxa.invalid|ADMIN_OIDC_CLIENT_ID=${admin_client}|ADMIN_ALLOWED_USERS=me@fxa.invalid|ADMIN_OIDC_REDIRECT_URL=https://admin.fxa.invalid/auth/callback|ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL=true|ADMIN_OIDC_NAME=Mozilla account)\"$" \
    "${QUADLET_DIR}/firefox-sync-admin.container")" 6 "admin UI signs in with the accounts (quadlets)"
  "${QUADLET}" -dryrun -user > quadlet-fxa-dryrun.log 2>&1
  check "$?" 0 "quadlet generator accepts the accounts files"
  # FXA_MARIADB_FROM / FXA_MYSQL_FROM: the accounts' database starts on that major, as an install
  # from before (MySQL 8: with mysql_native_password), and moves to lts below as
  # docs/upgrading.md#mariadb and #mysql-8-to-9 say for the Quadlets
  if [ "${FXA_DB}" = mariadb ] && [ -n "${FXA_MARIADB_FROM:-}" ]; then
    sed -i "s|^FXA_MARIADB_IMAGE=.*|FXA_MARIADB_IMAGE=${FXA_MARIADB_FROM}|" .env
    fxa_from=${FXA_MARIADB_FROM}
  elif [ "${FXA_DB}" = mysql ] && [ -n "${FXA_MYSQL_FROM:-}" ]; then
    sed -i -e '/^FXA_MYSQL_IMAGE=/d' -e '/^FXA_MYSQL_ARGS=/d' .env
    printf 'FXA_MYSQL_IMAGE=%s\nFXA_MYSQL_ARGS=%s\n' "${FXA_MYSQL_FROM}" "--mysql-native-password=ON --authentication-policy=mysql_native_password" >> .env
    fxa_from=${FXA_MYSQL_FROM}
  else
    fxa_from=""
  fi
  if [ -n "${fxa_from}" ]; then
    ./prepare_environment.sh --render-units < /dev/null > render-fxa-from.log 2>&1
    check "$? $(fxa_db_image) $(sed -n 's/^Image=//p' "${QUADLET_DIR}/firefox-sync-backup-fxa.container")" "0 docker.io/library/${fxa_from} docker.io/library/${fxa_from}" \
      "the accounts' database and its backups on ${fxa_from} first (quadlets)"
  fi
  fast_admin_checks
  check "${fxa_pulled}" 0 "pull mozilla/fxa-mono ${FXA_TEST_IMAGE:-${fxa_image}}"
  check "$(grep '^FXA_IMAGE=' .env | cut -d= -f2):$(grep '^FXA_VERSION=' .env | cut -d= -f2) $(grep '^FXA_ARCH=' .env | cut -d= -f2)" "${fxa_image} ${fxa_arch}" \
    "the accounts image pulled is the one of .env"
  # (all of them, as at boot: WantedBy=default.target)
  timeout 1200 systemctl --user start firefox-sync-syncstorage.service firefox-sync-fxa-content.service firefox-sync-fxa-profile.service \
    firefox-sync-fxa-profile-worker.service firefox-sync-fxa-profile-static.service firefox-sync-admin.service
  check "$?" 0 "systemctl --user start (syncstorage and accounts)"
  # the image the accounts' units run is the one whose label chose fxa-db's MySQL: lts only with
  # mozilla/fxa#21554 in it, and the units did not pull another one over it (podman 4 does with
  # --arch, which the units have only for another architecture)
  run_id=$(podman image inspect -f '{{.Id}}' "${fxa_image}" 2> /dev/null)
  check "$(sed -n 's/^Image=//p' "${QUADLET_DIR}"/firefox-sync-fxa-{migrations,auth}.container | sort -u) [$(grep -h '^PodmanArgs=--arch' "${QUADLET_DIR}"/firefox-sync-fxa-{migrations,auth}.container | sort -u)] $(grep -hc '^PodmanArgs=--network-alias=fxa-' "${QUADLET_DIR}"/firefox-sync-fxa-{migrations,auth}.container | awk '{ s += $1 } END { print s }') ${run_id}" \
    "${fxa_image} [$([ "${fxa_arch}" = "$(case "$(uname -m)" in aarch64|arm64) echo arm64 ;; *) echo amd64 ;; esac)" ] || echo "PodmanArgs=--arch=${fxa_arch}")] 2 ${fxa_image_id}" \
    "the accounts' units run ${fxa_image}, the image prepare_environment.sh read (not pulled over: no --arch on this host's architecture)"
  if [ "${FXA_DB}" != mariadb ] && [ -z "${fxa_from}" ]; then
    fxa_image_fixed mozilla/fxa#21554 "${fxa_image}" podman && want_db=docker.io/library/mysql:lts || want_db=docker.io/library/mysql:8
    check "$(fxa_db_image)" "${want_db}" "fxa-db's MySQL agrees with the image the units run ($([ "${want_db##*:}" = lts ] && echo with || echo without) mozilla/fxa#21554)"
  fi
  ok=""
  for _ in $(seq 1 225); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${CONTENT_PORT}/__heartbeat__)" = 200 ] && ok=yes && break
    sleep 2
  done
  check "${ok}" yes "accounts web pages answer (quadlets)"
  ok=""
  for _ in $(seq 1 225); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${AUTH_PORT}/__heartbeat__)" = 200 ] && ok=yes && break
    sleep 2
  done
  check "${ok}" yes "accounts API answers (quadlets)"
  if [ -n "${fxa_from}" ]; then
    echo "== the accounts' database from ${fxa_from} to lts, as docs/upgrading.md says for the Quadlets"
    UPGRADING_MD=$(cat "${CODE}/docs/upgrading.md")
    up_documented() { [[ "${UPGRADING_MD}" == *"$1"* ]] && echo yes || echo "not in docs/upgrading.md"; }
    fxa_sql() { podman exec -e MYSQL_PWD="$(env_of FXA_MYSQL_PASSWORD)" firefox-sync-fxa-db sh -c 'exec "$(command -v mariadb || command -v mysql)" "$@"' sql -uroot -sN -e "$1"; }
    accounts_up() {
      local c
      for _ in $(seq 1 225); do
        c=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${AUTH_PORT}/__heartbeat__")
        [ "${c}" = 200 ] && break
        sleep 2
      done
      echo "${c}"
    }
    old_db_version=$(fxa_sql "SELECT VERSION()")
    migrations_at=$(systemctl --user show -p ActiveEnterTimestampMonotonic --value firefox-sync-fxa-migrations.service)
    for c in 'systemctl --user start firefox-sync-backup.service' './prepare_environment.sh --render-units' "podman pull docker.io/library/${FXA_DB}:lts" 'systemctl --user restart firefox-sync-fxa-db.service'; do
      check "$(up_documented "${c}")" yes "docs/upgrading.md says ${c} for the Quadlets"
    done
    if [ "${FXA_DB}" = mysql ]; then
      # 2. the users off mysql_native_password: the query of the page, the ALTER USER statements
      # (in mysql -uroot -p there) with FXA_MYSQL_PASSWORD
      # shellcheck disable=SC2016
      query='podman exec firefox-sync-fxa-db sh -c '"'"'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -e "SELECT user, host, plugin FROM mysql.user WHERE plugin = \"mysql_native_password\""'"'"
      check "$(up_documented "${query}")" yes "docs/upgrading.md#mysql-8-to-9 lists the users on mysql_native_password with podman exec"
      check "$(eval "${query}" 2> /dev/null | awk 'NR > 1 { print $1 "@" $2 }' | LC_ALL=C sort | paste -sd' ')" "root@% root@localhost" "on mysql_native_password: root only (quadlets)"
      alter=$(sed -n "/^    ALTER USER 'root'@/p" "${CODE}/docs/upgrading.md" | sed -e 's/^ *//' -e "s/<FXA_MYSQL_PASSWORD>/$(env_of FXA_MYSQL_PASSWORD)/")
      check "$(echo "${alter}" | grep -c '^ALTER USER')" 2 "docs/upgrading.md#mysql-8-to-9's ALTER USER statements"
      fxa_sql "${alter}"
      check "$? [$(eval "${query}" 2> /dev/null | awk 'NR > 1')]" "0 []" "every user on caching_sha2_password (quadlets)"
      # 3. FXA_MYSQL_ARGS removed, rendered again, fxa-db restarted
      sed -i '/^FXA_MYSQL_ARGS=/d' .env
      ./prepare_environment.sh --render-units < /dev/null > render-fxa-native.log 2>&1
      check "$? $(sed -n 's/^Exec=//p' "${QUADLET_DIR}/firefox-sync-fxa-db.container")" "0 mysqld --event-scheduler=ON " "FXA_MYSQL_ARGS removed: fxa-db without mysql_native_password (quadlets)"
      # (the admin UI's unit rendered again too: its line of fast_admin_checks back)
      fast_admin_checks
      timeout 900 systemctl --user restart firefox-sync-fxa-db.service
      check "$? $(accounts_up) $(fxa_sql "SELECT COUNT(*) FROM information_schema.plugins WHERE plugin_name = 'mysql_native_password' AND plugin_status = 'ACTIVE'")" "0 200 0" \
        "fxa-db restarted on ${fxa_from} without mysql_native_password, the accounts API answers (quadlets)"
    fi
    # the backup, then the image of lts rendered into the units, pulled, the database restarted
    timeout 600 systemctl --user start firefox-sync-backup.service
    check "$?" 0 "a backup before the move (quadlets)"
    move_since=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "${FXA_DB}" = mariadb ]; then sed -i "s|^FXA_MARIADB_IMAGE=.*|FXA_MARIADB_IMAGE=mariadb:lts|" .env; else sed -i "s|^FXA_MYSQL_IMAGE=.*|FXA_MYSQL_IMAGE=mysql:lts|" .env; fi
    ./prepare_environment.sh --render-units < /dev/null > render-fxa-lts.log 2>&1
    check "$? $(sed -n 's/^  ✓ //p' render-fxa-lts.log | grep -vx 'firefox-sync-admin.container' | LC_ALL=C sort | paste -sd' ')" "0 firefox-sync-backup-fxa.container firefox-sync-fxa-db.container" "the image of lts in the accounts' database and backup units (quadlets)"
    fast_admin_checks
    podman pull -q "docker.io/library/${FXA_DB}:lts" > /dev/null
    timeout 900 systemctl --user restart firefox-sync-fxa-db.service
    check "$? $(accounts_up)" "0 200" "fxa-db restarted on lts, the accounts API answers (quadlets)"
    new_db_version=$(fxa_sql "SELECT VERSION()")
    echo "accounts database: ${old_db_version} -> ${new_db_version}"
    check "$([ "${old_db_version%%.*}" != "${new_db_version%%.*}" ] && [ "$(printf '%s\n' "${old_db_version%%-*}" "${new_db_version%%-*}" | sort -V | tail -n 1)" = "${new_db_version%%-*}" ] && echo yes) $(fxa_db_image)" \
      "yes docker.io/library/${FXA_DB}:lts" "the accounts' database on a newer major (${old_db_version%%-*} -> ${new_db_version%%-*}, quadlets)"
    if [ "${FXA_DB}" = mariadb ]; then
      check "$(journalctl --user -u firefox-sync-fxa-db.service --since "${move_since}" --no-pager 2> /dev/null | grep -c 'Finished mariadb-upgrade')" 1 "mariadb-upgrade ran at the first start on lts, as the page says (quadlets)"
    else
      check "$(podman exec firefox-sync-fxa-db cat /var/lib/mysql/mysql_upgrade_history 2> /dev/null | grep -o '"version":"[^"]*"' | tail -n 1)" "\"version\":\"${new_db_version}\"" \
        "MySQL upgraded the data in place at the first start on lts (quadlets)"
    fi
    # the units that require it started again after it
    check "$([ "$(systemctl --user show -p ActiveEnterTimestampMonotonic --value firefox-sync-fxa-migrations.service)" -gt "${migrations_at}" ] && echo yes) $(systemctl --user is-active firefox-sync-fxa-migrations.service firefox-sync-fxa-auth.service firefox-sync-admin.service | sort -u)" \
      "yes active" "the migrations ran again after the database, the accounts and the admin UI run (quadlets)"
  fi
  check "$(curl -s http://127.0.0.1:${CONTENT_PORT}/.well-known/fxa-client-configuration | grep -o '"auth_server_base_url":"[^"]*"')" '"auth_server_base_url":"https://api.fxa.invalid"' "client configuration (quadlets)"
  journalctl --user -u firefox-sync-fxa-policy.service --no-pager 2> /dev/null | grep -m1 "sign-ups:"
  check "$(journalctl --user -u firefox-sync-fxa-policy.service --no-pager 2> /dev/null | grep -q 'max accounts: unlimited (FXA_MAX_ACCOUNTS=initial:unlimited' && echo yes)" yes \
    "fxa-policy set max accounts (quadlets)"
  check "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"email":"someone@example.org","authPW":"00"}' http://127.0.0.1:${GATE_PORT}/v1/account/create)" 400 "sign-up gate refuses an email not on the allowlist (quadlets)"
  # the gate reaches the accounts API by its network alias: give it the same time as the checks above
  gate=""
  for _ in $(seq 1 30); do
    gate=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${GATE_PORT}/__heartbeat__)
    [ "${gate}" = 200 ] && break
    sleep 2
  done
  check "${gate}" 200 "sign-up gate forwards to the accounts API (quadlets)"
  [ "${gate}" = 200 ] || journalctl --user -u firefox-sync-admin.service --no-pager | tail -15
  # the admin UI with the accounts: grants, Redis, the internal URLs of the health checks
  check "$(metrics_show "${SYNC_UP[@]}" 'ffs_up{component="Storage database"} 1' 'ffs_up{component="Accounts API"} 1' \
    'ffs_up{component="Accounts pages"} 1' 'ffs_up{component="Profile server"} 1' 'ffs_up{component="Accounts database"} 1' \
    'ffs_up{component="Accounts Redis"} 1' 'ffs_accounts 0')" all "admin UI reaches the accounts services (quadlets)"
  check "$(podman healthcheck run firefox-sync-admin > /dev/null 2>&1; echo $?)" 0 "admin UI healthcheck (quadlets with accounts)"
  check "$(curl -s http://127.0.0.1:${ADMIN_PORT}/login | grep -c '>Sign in with Mozilla account</a>')" 1 "admin UI offers the accounts' sign-in (quadlets)"
  # the backup of the accounts runs with that of Sync, before it (WantedBy=, Before=)
  timeout 600 systemctl --user start firefox-sync-backup.service
  check "$?" 0 "systemctl --user start firefox-sync-backup.service (quadlets with accounts)"
  check "$(admin_db_sql "SELECT DISTINCT scope FROM ffs_backups WHERE ok = 1 ORDER BY scope" | paste -sd' ')" "accounts sync" "the backups of the accounts and of Sync recorded (quadlets)"
  [ "${FAILED}" = 0 ] || journalctl --user -u 'firefox-sync-backup*' --no-pager | tail -20
  check "$(quadlets_healthy 600)" "all healthy" "every long-running unit has a HealthCmd and passes podman healthcheck run (quadlets with accounts)"
  if [ "${FAILED}" != 0 ]; then
    journalctl --user -u 'firefox-sync-fxa-*' --no-pager | tail -40
  fi
  stop_quadlets
fi

echo "== cleanup"
rm -rf "${WORK}"

[ ${FAILED} = 0 ] && echo "RESULT podman: all checks passed" || echo "RESULT podman: some checks FAILED"
exit ${FAILED}
