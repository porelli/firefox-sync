#!/bin/bash
# Tests of docs/migrating.md (and of docs/upgrading.md for firefox-sync's public release): an
# account's data written through another Sync server, moved the way docs/migrating.md says,
# then read back through firefox-sync with the same FxA uid and keys (upstream's mock FxA,
# tests/migrate_client.py).
#
# Usage: tests/migrate.sh <scenario>
#   upstream-mysql           Mozilla's docker-compose.one-shot.mysql.yaml (MySQL 8.0,
#                            syncserver-mysql 0.23.3) -> firefox-sync on MariaDB
#   upstream-mysql-to-mysql  the same -> firefox-sync on MySQL (SYNC_DB=mysql, mysql:lts)
#   upstream-mysql-testsetup Mozilla's docker-compose.mysql.yaml (its end-to-end test setup) -> MariaDB
#   upstream-postgres        Mozilla's docker-compose.one-shot.postgres.yaml (PostgreSQL 18,
#                            one database) -> firefox-sync on PostgreSQL
#   upstream-postgres-2db    Mozilla's docker-compose.postgres.yaml (two databases) -> PostgreSQL
#   dan-r                    dan-r/syncstorage-rs-docker's layout (linuxserver/mariadb:10.6.13,
#                            syncstorage_rs and tokenserver_rs, the schema of its pinned
#                            syncstorage-rs commit, its services and nodes rows) -> MariaDB
#   jeena                    jeena/fxsync-docker's docker-compose.yaml (syncstorage-rs 0.13.6,
#                            mariadb:10.11) -> MariaDB
#   nixos-mysql              NixOS' layout: one database firefox_syncserver on MariaDB 11.4 ->
#                            firefox-sync's two
#   nixos-postgres           NixOS' layout on PostgreSQL 17 -> PostgreSQL
#   yunohost                 YunoHost's layout: two databases of one owner on PostgreSQL 15 -> PostgreSQL
#   firefox-sync-public      firefox-sync's public release (porelli/firefox-sync at ca9101d, its
#                            images 0.24.0) on MariaDB, upgraded in place as docs/upgrading.md says
#   firefox-sync-public-postgres  the same on PostgreSQL
#   watchtower               that release left as it is, the images of this one published under
#                            its tags: Watchtower recreates its containers, then docker compose
#                            pull && up -d with its files (docs/upgrading.md#watchtower-and-podman-auto-update)
#   watchtower-postgres      the same on PostgreSQL
#   firefox-sync-public-quadlets  that release's Quadlets (needs Podman and a systemd user
#                            session; the units are global: one at a time on a host): podman
#                            auto-update with the new images, then the upgrade of
#                            docs/upgrading.md#quadlets
#
# The old stacks run their real compose files (fetched from GitHub at pinned commits, with
# only what the test needs changed in an override: the mock FxA as accounts server, a node
# URL, no published ports, a published image instead of a build), or reproduce the layout
# where the original builds from source. The commands of the guide are run as written there:
# each one must be found, verbatim, in docs/migrating.md or docs/upgrading.md (guide()), so a
# command changed in the guide must be changed here too.
# The new stack is a copy of this tree set up like a user's install (.env, COMPOSE_FILE),
# with SYNC_MAX_USERS=2 and the admin UI; checked: the init container, the SQL of "Checking the
# result", the client (same uids, on the new node, the data as written, writable), max users
# (a third account refused at 2, let in at 3), the admin UI's first page, a restart.
#
# Runs on Docker (amd64 images run emulated elsewhere: binfmt). Own compose projects
# (mig-src-*, mig-dst-*), ports on 127.0.0.1 (PORT, default 28661, and PORT+20 for the
# admin UI); the old stacks keep the container names of their files (the commands of the
# guide use them). Images pulled for a scenario are removed at the end, except those of
# KEEP_IMAGES.
# Environment:
#   REPOSITORY, TAG  firefox-sync images under test (default ghcr.io/<owner>/<repo> of the repository
#                    this runs in: GITHUB_REPOSITORY, else the git remote origin, else
#                    ghcr.io/porelli/firefox-sync; latest)
#   INIT_TAG         the tag of the init images under test (default TAG; vm.sh: built from this tree)
#   ADMIN_IMAGE      the admin UI (default ffs-admin:test, built from admin/ when missing)
#   KEEP             1: leave the stacks running
#   SLOT             tests/slot.sh: 1, 2...: -s<SLOT> after the projects, PORT 28661 + 1000 * SLOT
#                    (the old stacks' container names are fixed: one run of a scenario at a time)
set -u

SCENARIO=${1:?usage: $0 <scenario>, see the top of $0}
TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CODE=$(dirname "${TESTS}")
# the commands of the guide: moving from another server, and upgrading an older firefox-sync
GUIDE=("${CODE}/docs/migrating.md" "${CODE}/docs/upgrading.md")
# shellcheck source=tests/slot.sh
source "${TESTS}/slot.sh"
# the images of the repository this runs in (vm.sh gives those of its remote)
repository_slug() {
  [ -n "${GITHUB_REPOSITORY:-}" ] && { echo "${GITHUB_REPOSITORY}"; return; }
  git -C "${CODE}" remote get-url origin 2> /dev/null | sed -n -e 's#/$##' -e 's#\.git$##' -e 's#^.*github\.com[:/]\([^/]*/[^/]*\)$#\1#p' | grep . && return
  echo porelli/firefox-sync
}
REPOSITORY=${REPOSITORY:-ghcr.io/$(repository_slug | tr '[:upper:]' '[:lower:]')}
TAG=${TAG:-latest}
INIT_TAG=${INIT_TAG:-${TAG}}
ADMIN_IMAGE=${ADMIN_IMAGE:-ffs-admin:test}
PORT=${PORT:-$((28661 + SLOT_PORTS))}
TEST_IMAGE=${REPOSITORY}:syncstorage-rs-mysql-${TAG}
KEEP_IMAGES=${KEEP_IMAGES:-mariadb:lts mysql:lts mysql:8 postgres:latest}
OLD_DOMAIN=https://sync-old.ffs-e2e.invalid
NEW_DOMAIN=https://sync-new.ffs-e2e.invalid
# Mozilla's syncstorage-rs, docker/ at a commit of master (the one-shot files are not in 0.23.3)
UPSTREAM_COMMIT=530d0f05da74819a93b870ecc956a03fa3e81f5a
UPSTREAM_IMAGE_TAG=0.23.3
WORK=$(mktemp -d /tmp/ffs-mig.XXXXXX)
SRC=${WORK}/old
DST=${WORK}/firefox-sync
SRC_PROJECT=mig-src-${SCENARIO}${SLOT_SUFFIX}
DST_PROJECT=mig-dst-${SCENARIO}${SLOT_SUFFIX}
STATE=${WORK}/state
mkdir -p "${SRC}" "${STATE}"
chmod 777 "${STATE}"

FAILED=0
PULLED=()
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILED=1; return 1; }
check() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (expected '$2', got '$1')"; fi; }
rnd() { tr -dc '[:alnum:]' < /dev/urandom | head -c 24; }

# a command (or lines run together in one shell) as the guide has it, in the current directory
guide() {
  local line
  for line in "$@"; do
    grep -qF -- "${line}" "${GUIDE[@]}" || { fail "command not in docs/migrating.md or docs/upgrading.md: ${line}"; return 1; }
    echo "  \$ ${line}"
  done
  # (not on stdin: docker compose exec -T would read the next lines)
  bash -o pipefail -c "$(printf '%s\n' "$@")" < /dev/null
}

# pulls an image if missing, to remove it at the end
need() {
  local img
  for img in "$@"; do
    docker image inspect "${img}" > /dev/null 2>&1 && continue
    echo "  pulling ${img}"
    # (amd64 only: run emulated)
    docker pull -q "${img}" > /dev/null 2>&1 || docker pull -q --platform linux/amd64 "${img}" > /dev/null || { fail "pull ${img}"; return 1; }
    case " ${KEEP_IMAGES} " in *" ${img} "*) ;; *) PULLED+=("${img}") ;; esac
  done
}

# the client of tests/migrate_client.py on a network: <network> <server URL> <public URL> <args>
client() {
  local net=$1 server=$2 domain=$3; shift 3
  docker run --rm --network "${net}" --user root --entrypoint sh \
    -v "${TESTS}:/tests:ro" -v "${STATE}:/state" \
    -e SYNC_SERVER_URL="${server}" -e SYNC_PUBLIC_URL="${domain}" -e ADMIN_URL=http://ffs-admin:8080 \
    -e PYTHONPATH=/app:/app/tools:/tests -e PYTHONDONTWRITEBYTECODE=1 \
    "${TEST_IMAGE}" -c "cd /app && python3 /tests/migrate_client.py $*" < /dev/null
}

teardown() {
  if [ -n "${KEEP:-}" ]; then echo "keeping the stacks (${WORK})"; return; fi
  echo "== teardown"
  [ -f "${SRC}/.teardown" ] && (cd "${SRC}" && bash .teardown) > /dev/null 2>&1
  unset COMPOSE_PROJECT_NAME
  [ -f "${DST}/.env" ] && (cd "${DST}" && docker compose down -v --remove-orphans) > /dev/null 2>&1
  [ ${#PULLED[@]} -gt 0 ] && docker rmi "${PULLED[@]}" > /dev/null 2>&1
  # files of the database containers (other owners)
  sudo rm -rf "${WORK}" 2> /dev/null || rm -rf "${WORK}"
}
trap teardown EXIT

fetch() { curl -sfL --retry 3 -o "$2" "$1" || { fail "download $1"; exit 1; }; }

# ---------- the new stack: a copy of this tree, set up like a user's install ----------

# <mariadb|mysql|postgres>: .env as prepare_environment.sh would write it, then the test's lines
dst_prepare() {
  DST_DB=$1
  # the old stack's project name was in the environment, firefox-sync's is in its .env
  unset COMPOSE_PROJECT_NAME
  mkdir -p "${DST}/tests"
  cp -r "${CODE}/docker-compose.yml" "${CODE}/compose" "${CODE}/.env-example" "${CODE}/config" "${CODE}/db" "${DST}/"
  mkdir -p "${DST}/tests/compose" && cp "${TESTS}/compose/migrate.yml" "${DST}/tests/compose/"
  local backend=mysql files=compose/sync.yml:compose/sync-${DST_DB}.yml
  [ "${DST_DB}" = postgres ] && backend=postgres
  sed -e "s|^SYNC_TOKENSERVER_DB_PASSWORD=.*|SYNC_TOKENSERVER_DB_PASSWORD=$(rnd)|" \
      -e "s|^SYNC_STORAGE_DB_PASSWORD=.*|SYNC_STORAGE_DB_PASSWORD=$(rnd)|" \
      -e "s|^SYNC_POSTGRES_PASSWORD=.*|SYNC_POSTGRES_PASSWORD=$(rnd)|" \
      -e "s|^SYNC_MASTER_SECRET=.*|SYNC_MASTER_SECRET=$(rnd)|" \
      -e "s|^SYNC_METRICS_HASH_SECRET=.*|SYNC_METRICS_HASH_SECRET=$(rnd)|" \
      -e "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=$(rnd)|" \
      -e "s|^ADMIN_DB_PASSWORD=.*|ADMIN_DB_PASSWORD=$(rnd)|" \
      -e "s|^SYNC_PUBLIC_URL=.*|SYNC_PUBLIC_URL=${NEW_DOMAIN}|" \
      -e "s|^SYNC_EXPORT_PORT=.*|SYNC_EXPORT_PORT=127.0.0.1:${PORT}|" \
      -e "s|^ADMIN_EXPORT_PORT=.*|ADMIN_EXPORT_PORT=127.0.0.1:$((PORT + 20))|" \
      -e "s|^SYNC_MAX_USERS=.*|SYNC_MAX_USERS=2|" \
      -e "s|^# COMPOSE_PROFILES=.*|COMPOSE_PROFILES=admin|" \
      -e "s|^SYNC_DB=.*|SYNC_DB=$([ "${DST_DB}" = mysql ] && echo mysql || echo mariadb)|" \
      -e "s|^IMAGE_REPOSITORY=.*|IMAGE_REPOSITORY=${REPOSITORY}|" \
      -e "s|^SYNC_IMAGE=.*|SYNC_IMAGE=syncstorage-rs-${backend}|" \
      -e "s|^SYNC_INIT_IMAGE=.*|SYNC_INIT_IMAGE=syncstorage-rs-${backend}-init|" \
      -e "s|^SYNC_IMAGE_TAG=.*|SYNC_IMAGE_TAG=${TAG}|" \
      -e "s|^SYNC_INIT_IMAGE_TAG=.*|SYNC_INIT_IMAGE_TAG=${TAG}|" \
      -e "s|^FXA_SMTP_HOST=.*|FXA_SMTP_HOST=|" \
      -e "/^# COMPOSE_FILE=/d" \
      -e "s|<REPLACE_WITH_SOMETHING_SECURE>|$(rnd)|" \
      -e "s|<REPLACE_WITH_[A-Z_]*>|placeholder.invalid|g" \
      "${CODE}/.env-example" > "${DST}/.env"
  # the PostgreSQL container: the Sync server's own role, as prepare_environment.sh sets it
  [ "${DST_DB}" = postgres ] && sed -i -e "s|^SYNC_POSTGRES_APP_USER=.*|SYNC_POSTGRES_APP_USER=syncserver_app|" \
    -e "s|^SYNC_POSTGRES_APP_PASSWORD=.*|SYNC_POSTGRES_APP_PASSWORD=$(rnd)|" "${DST}/.env"
  dst_test_env "${files}"
}

# the test's lines of .env: own project, the mock FxA as Mozilla's accounts (same email
# domain, api.accounts.firefox.com), the admin UI image and its trusted header
dst_test_env() {
  cat >> "${DST}/.env" <<EOF
# tests/migrate.sh
COMPOSE_PROJECT_NAME=${DST_PROJECT}
COMPOSE_FILE=$1:tests/compose/migrate.yml
FXA_OAUTH_SERVER_URL=http://mock_fxa:6000
ADMIN_IMAGE=${ADMIN_IMAGE}
MIG_TEST_IMAGE=${TEST_IMAGE}
MIG_TRUSTED=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16
EOF
}

dst() { (cd "${DST}" && docker compose "$@"); }
dst_sql() {
  case ${DST_DB} in
    mariadb) dst exec -T tokenserver_db sh -c 'MYSQL_PWD="$MARIADB_PASSWORD" mariadb -u"$MARIADB_USER" "$MARIADB_DATABASE" -sN -e "$0"' "$1" ;;
    mysql) dst exec -T tokenserver_db sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" mysql -u"$MYSQL_USER" "$MYSQL_DATABASE" -sN -e "$0"' "$1" ;;
    # as the Sync server's role, the owner of the tables (never the superuser, docs/reference/database-users.md#postgresql);
    # the public release has none (POSTGRES_USER owns them)
    postgres) dst exec -T postgres_db sh -c 'if [ -z "$2" ]; then psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tA -F "	" -c "$0"; else PGPASSWORD="$1" psql -h 127.0.0.1 -U "$2" -d "$POSTGRES_DB" -tA -F "	" -c "$0"; fi' "$1" \
      "$(grep '^SYNC_POSTGRES_APP_PASSWORD=' "${DST}/.env" | cut -d= -f2)" "$(grep '^SYNC_POSTGRES_APP_USER=' "${DST}/.env" | cut -d= -f2)" ;;
  esac < /dev/null 2> /dev/null
}
wait_init() { timeout 600 docker wait "$(dst ps -a -q tokenserver_db_init)"; }
dst_net() { echo "${DST_PROJECT}_default"; }

# "Loading into firefox-sync": the databases only, the dumps (in ${DST}), then the stack
dst_load() {
  echo "== loading into firefox-sync (${DST_DB})"
  cd "${DST}" || exit 1
  case ${DST_DB} in
    mariadb)
      guide "docker compose up -d --wait tokenserver_db syncstorage_db" > /dev/null 2>&1
      check "$?" 0 "database containers up"
      echo "  $(dst_sql 'SELECT VERSION()')"
      guide "docker compose exec -T tokenserver_db sh -c 'MYSQL_PWD=\"\$MARIADB_PASSWORD\" mariadb -u\"\$MARIADB_USER\" \"\$MARIADB_DATABASE\"' < tokenserver.sql"
      check "$?" 0 "tokenserver.sql loaded"
      guide "docker compose exec -T syncstorage_db sh -c 'MYSQL_PWD=\"\$MARIADB_PASSWORD\" mariadb -u\"\$MARIADB_USER\" \"\$MARIADB_DATABASE\"' < syncstorage.sql"
      check "$?" 0 "syncstorage.sql loaded" ;;
    mysql)
      guide "docker compose up -d --wait tokenserver_db syncstorage_db" > /dev/null 2>&1
      check "$?" 0 "database containers up"
      echo "  $(dst_sql 'SELECT VERSION()')"
      guide "docker compose exec -T tokenserver_db sh -c 'MYSQL_PWD=\"\$MYSQL_PASSWORD\" mysql -u\"\$MYSQL_USER\" \"\$MYSQL_DATABASE\"' < tokenserver.sql"
      check "$?" 0 "tokenserver.sql loaded"
      guide "docker compose exec -T syncstorage_db sh -c 'MYSQL_PWD=\"\$MYSQL_PASSWORD\" mysql -u\"\$MYSQL_USER\" \"\$MYSQL_DATABASE\"' < syncstorage.sql"
      check "$?" 0 "syncstorage.sql loaded" ;;
    postgres)
      guide "docker compose up -d --wait postgres_db" > /dev/null 2>&1
      check "$?" 0 "database container up"
      # the Sync server's role first: the dumps are loaded as it
      guide "docker compose run --rm sync_role_init" > "${WORK}/sync-role.log" 2>&1
      check "$?" 0 "the Sync server's role (sync_role_init)" || tail -5 "${WORK}/sync-role.log"
      echo "  $(dst_sql 'SELECT version()')"
      if [ -z "${PG_FILES:-}" ]; then
        guide "docker compose run --rm --no-deps -T --entrypoint sh sync_role_init -c 'PGPASSWORD=\"\$POSTGRES_SYNC_PASSWORD\" psql -h \"\$POSTGRES_SERVER\" -U \"\$POSTGRES_SYNC_USER\" -d \"\$POSTGRES_DATABASE\" -v ON_ERROR_STOP=1' < syncserver.sql" > "${WORK}/psql.log" 2>&1
        check "$?" 0 "syncserver.sql loaded" || tail -5 "${WORK}/psql.log"
      else
        # "with each file in turn", the command of the guide's comment
        local f line="# docker compose run --rm --no-deps -T --entrypoint sh sync_role_init -c 'PGPASSWORD=\"\$POSTGRES_SYNC_PASSWORD\" psql -h \"\$POSTGRES_SERVER\" -U \"\$POSTGRES_SYNC_USER\" -d \"\$POSTGRES_DATABASE\" -v ON_ERROR_STOP=1' < <file>"
        grep -qF -- "${line}" "${GUIDE[@]}" || fail "command not in docs/migrating.md or docs/upgrading.md: ${line}"
        for f in ${PG_FILES}; do
          line=${line#\# }
          echo "  \$ ${line%<file>}${f}"
          bash -c "${line%<file>}${f}" > "${WORK}/psql-${f}.log" 2>&1
          check "$?" 0 "${f} loaded" || tail -5 "${WORK}/psql-${f}.log"
        done
      fi ;;
  esac
  guide "docker compose up -d" > "${WORK}/up.log" 2>&1
  check "$?" 0 "docker compose up -d"
  check "$(wait_init)" 0 "init container exit code"
  check "$(state syncstorage_migrate ExitCode)" 0 "migrations of the newer syncstorage-rs"
  cd - > /dev/null || exit 1
}
state() { docker inspect -f "{{.State.$2}}" "$(dst ps -a -q "$1")" 2> /dev/null; }
hb() {
  for _ in $(seq 1 90); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/__heartbeat__")" = 200 ] && { echo 200; return; }
    sleep 1
  done
  echo down
}

# "Checking the result", the client, MAX_USERS, the admin UI, a restart. $1: the node URL
dst_verify() {
  local domain=${1:-${NEW_DOMAIN}} users
  echo "== checking the result"
  check "$(hb)" 200 "firefox-sync answers /__heartbeat__"
  check "$(dst logs tokenserver_db_init 2>&1 | grep -c 'Current users: 2$')" 1 "init container: Current users: 2"
  cd "${DST}" || exit 1
  case ${DST_DB} in
    mariadb)
      users=$(guide "docker compose exec tokenserver_db sh -c 'MYSQL_PWD=\"\$MARIADB_PASSWORD\" mariadb -u\"\$MARIADB_USER\" \"\$MARIADB_DATABASE\" -e \"SELECT u.uid, u.email, u.generation, u.keys_changed_at, u.client_state, n.node FROM users u JOIN nodes n ON n.id = u.nodeid WHERE u.replaced_at IS NULL\"'" 2>&1) ;;
    mysql)
      users=$(guide "docker compose exec tokenserver_db sh -c 'MYSQL_PWD=\"\$MYSQL_PASSWORD\" mysql -u\"\$MYSQL_USER\" \"\$MYSQL_DATABASE\" -e \"SELECT u.uid, u.email, u.generation, u.keys_changed_at, u.client_state, n.node FROM users u JOIN nodes n ON n.id = u.nodeid WHERE u.replaced_at IS NULL\"'" 2>&1) ;;
    postgres)
      users=$(guide "docker compose run --rm --no-deps -T --entrypoint sh sync_role_init -c 'PGPASSWORD=\"\$POSTGRES_SYNC_PASSWORD\" psql -h \"\$POSTGRES_SERVER\" -U \"\$POSTGRES_SYNC_USER\" -d \"\$POSTGRES_DATABASE\" -c \"SELECT u.uid, u.email, u.generation, u.keys_changed_at, u.client_state, n.node FROM users u JOIN nodes n ON n.id = u.nodeid WHERE u.replaced_at IS NULL\"'" 2>&1) ;;
  esac
  cd - > /dev/null || exit 1
  echo "${users}" | sed 's/^/    /'
  check "$(echo "${users}" | grep -E 'alice@|bob@' | grep -c "${domain}")" 2 "SQL of the guide: alice and bob on the node ${domain}"
  check "$(dst_sql "SELECT COUNT(*) FROM nodes WHERE node <> '${domain}' AND (downed = 0 OR available > 0)")" 0 "the old nodes are out of rotation"
  check "$(dst_sql "SELECT COUNT(*) FROM services WHERE service = 'sync-1.5'")" 1 "one sync-1.5 service"
  client "$(dst_net)" http://syncstorage:8000 "${domain}" check
  check "$?" 0 "the client reads its data back through firefox-sync"
  client "$(dst_net)" http://syncstorage:8000 "${domain}" new carol refused
  check "$?" 0 "SYNC_MAX_USERS=2 counts the moved accounts: a third one is refused"
  client "$(dst_net)" http://syncstorage:8000 "${domain}" admin 2
  check "$?" 0 "the admin UI lists the moved accounts"
  echo "== SYNC_MAX_USERS=3, restart"
  sed -i 's/^SYNC_MAX_USERS=.*/SYNC_MAX_USERS=3/' "${DST}/.env"
  dst up -d > /dev/null 2>&1
  check "$(wait_init)" 0 "init container exit code (restart)"
  check "$(hb)" 200 "/__heartbeat__ after the restart"
  client "$(dst_net)" http://syncstorage:8000 "${domain}" new carol ok
  check "$?" 0 "SYNC_MAX_USERS=3: the third account is let in"
  client "$(dst_net)" http://syncstorage:8000 "${domain}" check
  check "$?" 0 "the client reads its data back after the restart"
  check "$(dst logs syncstorage 2>&1 | grep -ciE 'panicked|"status":5[0-9][0-9]')" 0 "no panics or 5xx in the Sync server's logs"
}

# ---------- the old stacks ----------

# Mozilla's compose files, docker/ at UPSTREAM_COMMIT; <file> <mysql|postgres> [override]
upstream_src() {
  mkdir -p "${SRC}/docker"
  fetch "https://raw.githubusercontent.com/mozilla-services/syncstorage-rs/${UPSTREAM_COMMIT}/docker/$1" "${SRC}/docker/$1"
  cat > "${SRC}/docker/migrate-test.yaml"
  export COMPOSE_PROJECT_NAME=${SRC_PROJECT}
  echo "COMPOSE_PROJECT_NAME=${SRC_PROJECT} docker compose -f docker/$1 -f docker/migrate-test.yaml down -v --remove-orphans" > "${SRC}/.teardown"
  # and the database images of the file (docker.io/library/mysql:8.0, postgres:18 or 18.0)
  need "ghcr.io/mozilla-services/syncstorage-rs/syncserver-$2:${UPSTREAM_IMAGE_TAG}" \
    $(sed -n 's|^ *image: docker.io/library/||p' "${SRC}/docker/$1" | sort -u) || exit 1
  echo "== old stack: $1 (syncserver-$2:${UPSTREAM_IMAGE_TAG})"
  (cd "${SRC}" && docker compose -f "docker/$1" -f docker/migrate-test.yaml up -d --wait --wait-timeout 600) > "${WORK}/src-up.log" 2>&1
  check "$?" 0 "old stack up" || { tail -20 "${WORK}/src-up.log"; (cd "${SRC}" && docker compose -f "docker/$1" -f docker/migrate-test.yaml logs --tail 30); exit 1; }
}
src_stop() { (cd "${SRC}" && docker compose -f "docker/$1" -f docker/migrate-test.yaml stop "$2") > /dev/null 2>&1; }

# the client writes through the old server: <network> <server URL>
src_write() {
  echo "== writing through the old server"
  client "$1" "$2" "${OLD_DOMAIN}" write
  check "$?" 0 "alice and bob synced to the old server" || exit 1
}

# override of the one-shot files: the published image instead of a build, no published
# port (the test reaches it on its network), the mock FxA as accounts server, a node URL
oneshot_override() {
  cat <<EOF
services:
  syncserver:
    build: !reset null
    image: ghcr.io/mozilla-services/syncstorage-rs/syncserver-$1:${UPSTREAM_IMAGE_TAG}
    platform: linux/amd64
    ports: !reset []
    environment:
      SYNC_TOKENSERVER__FXA_OAUTH_SERVER_URL: http://mock_fxa:6000
      SYNC_TOKENSERVER__INIT_NODE_URL: ${OLD_DOMAIN}
  mock_fxa:
    image: ${TEST_IMAGE}
    entrypoint: ["sh", "/app/scripts/start_mock_fxa_server.sh"]
    environment:
      MOCK_FXA_SERVER_HOST: 0.0.0.0
      MOCK_FXA_SERVER_PORT: 6000
EOF
}

scenario_upstream_mysql() {
  local to=$1
  upstream_src docker-compose.one-shot.mysql.yaml mysql < <(oneshot_override mysql)
  src_write "${SRC_PROJECT}_default" http://syncserver:8000
  src_stop docker-compose.one-shot.mysql.yaml syncserver
  echo "== dumps (docs/migrating.md, Mozilla's compose files)"
  cd "${SRC}" || exit 1
  guide "docker exec syncserver-tokenserver-db sh -c 'MYSQL_PWD=\"\$MYSQL_PASSWORD\" mysqldump -u\"\$MYSQL_USER\" --single-transaction --no-tablespaces --set-gtid-purged=OFF tokenserver' > tokenserver.sql"
  check "$?" 0 "tokenserver dump"
  guide "docker exec syncserver-sync-db sh -c 'MYSQL_PWD=\"\$MYSQL_PASSWORD\" mysqldump -u\"\$MYSQL_USER\" --single-transaction --no-tablespaces --set-gtid-purged=OFF syncstorage' > syncstorage.sql"
  check "$?" 0 "syncstorage dump"
  echo "  source: MySQL $(docker exec syncserver-sync-db mysql -usync -psync -sN -e 'SELECT VERSION()' 2> /dev/null)"
  cd - > /dev/null || exit 1
  dst_prepare "${to}"
  cp "${SRC}"/*.sql "${DST}/"
  dst_load
  dst_verify
}

# the test setup docker-compose.mysql.yaml (users test), like upstream-postgres-2db
scenario_upstream_mysql_testsetup() {
  upstream_src docker-compose.mysql.yaml mysql <<EOF
services:
  sync-db:
    ports: !reset []
  tokenserver-db:
    ports: !reset []
  mock-fxa-server:
    image: ${TEST_IMAGE}
    entrypoint: ["sh", "/app/scripts/start_mock_fxa_server.sh"]
  syncserver:
    image: ghcr.io/mozilla-services/syncstorage-rs/syncserver-mysql:${UPSTREAM_IMAGE_TAG}
    platform: linux/amd64
    ports: !reset []
    environment:
      SYNC_TOKENSERVER__ENABLED: "true"
      # its default is Mozilla's stage accounts (api-accounts.stage.mozaws.net), see docs/migrating.md
      SYNC_TOKENSERVER__FXA_EMAIL_DOMAIN: api.accounts.firefox.com
      SYNC_TOKENSERVER__FXA_OAUTH_SERVER_URL: http://mock-fxa-server:6000
      SYNC_TOKENSERVER__INIT_NODE_URL: ${OLD_DOMAIN}
EOF
  src_write "${SRC_PROJECT}_default" http://syncserver:8000
  src_stop docker-compose.mysql.yaml syncserver
  echo "== dumps (docs/migrating.md, Mozilla's test setup)"
  cd "${SRC}" || exit 1
  guide 'dc="docker compose -f docker/docker-compose.mysql.yaml exec -T"' \
    "\$dc tokenserver-db sh -c 'MYSQL_PWD=\"\$MYSQL_PASSWORD\" mysqldump -u\"\$MYSQL_USER\" --single-transaction --no-tablespaces --set-gtid-purged=OFF tokenserver' > tokenserver.sql" \
    "\$dc sync-db sh -c 'MYSQL_PWD=\"\$MYSQL_PASSWORD\" mysqldump -u\"\$MYSQL_USER\" --single-transaction --no-tablespaces --set-gtid-purged=OFF syncstorage' > syncstorage.sql"
  check "$?" 0 "two dumps"
  cd - > /dev/null || exit 1
  dst_prepare mariadb
  cp "${SRC}"/*.sql "${DST}/"
  dst_load
  dst_verify
}

scenario_upstream_postgres() {
  upstream_src docker-compose.one-shot.postgres.yaml postgres < <(oneshot_override postgres)
  src_write "${SRC_PROJECT}_default" http://syncserver:8000
  src_stop docker-compose.one-shot.postgres.yaml syncserver
  echo "== dump (docs/migrating.md, Mozilla's compose files)"
  cd "${SRC}" || exit 1
  guide "docker exec syncserver-postgres pg_dump -U sync --no-owner --no-acl syncserver > syncserver.sql"
  check "$?" 0 "syncserver dump"
  cd - > /dev/null || exit 1
  dst_prepare postgres
  cp "${SRC}"/*.sql "${DST}/"
  dst_load
  dst_verify
}

scenario_upstream_postgres_2db() {
  # app:build is upstream's locally built image: the published one instead; the file sets
  # no node, no tokenserver (they come from its e2e override files)
  upstream_src docker-compose.postgres.yaml postgres <<EOF
services:
  sync-db:
    ports: !reset []
  tokenserver-db:
    ports: !reset []
  sync-db-setup:
    image: ghcr.io/mozilla-services/syncstorage-rs/syncserver-postgres:${UPSTREAM_IMAGE_TAG}
    platform: linux/amd64
  mock-fxa-server:
    image: ${TEST_IMAGE}
  syncserver:
    image: ghcr.io/mozilla-services/syncstorage-rs/syncserver-postgres:${UPSTREAM_IMAGE_TAG}
    platform: linux/amd64
    ports: !reset []
    environment:
      SYNC_TOKENSERVER__ENABLED: "true"
      # its default is Mozilla's stage accounts (api-accounts.stage.mozaws.net), see docs/migrating.md
      SYNC_TOKENSERVER__FXA_EMAIL_DOMAIN: api.accounts.firefox.com
      SYNC_TOKENSERVER__FXA_OAUTH_SERVER_URL: http://mock-fxa-server:6000
      SYNC_TOKENSERVER__INIT_NODE_URL: ${OLD_DOMAIN}
EOF
  src_write "${SRC_PROJECT}_default" http://syncserver:8000
  src_stop docker-compose.postgres.yaml syncserver
  echo "== dumps (docs/migrating.md, two PostgreSQL databases)"
  cd "${SRC}" || exit 1
  guide 'dc="docker compose -f docker/docker-compose.postgres.yaml exec -T"' \
    '$dc tokenserver-db pg_dump -U test --no-owner --no-acl tokenserver > syncserver.sql' \
    '$dc sync-db pg_dump -U test --no-owner --no-acl --exclude-table=__diesel_schema_migrations syncstorage > syncstorage.sql' \
    '$dc sync-db pg_dump -U test --data-only --table=__diesel_schema_migrations syncstorage > syncstorage-migrations.sql'
  check "$?" 0 "three dumps"
  local migrations
  migrations=$(docker compose -f docker/docker-compose.postgres.yaml exec -T sync-db psql -U test -d syncstorage -tA -c 'SELECT COUNT(*) FROM __diesel_schema_migrations' < /dev/null)
  migrations=$((migrations + $(docker compose -f docker/docker-compose.postgres.yaml exec -T tokenserver-db psql -U test -d tokenserver -tA -c 'SELECT COUNT(*) FROM __diesel_schema_migrations' < /dev/null)))
  cd - > /dev/null || exit 1
  dst_prepare postgres
  cp "${SRC}"/*.sql "${DST}/"
  PG_FILES="syncserver.sql syncstorage.sql syncstorage-migrations.sql" dst_load
  check "$([ "$(dst_sql 'SELECT COUNT(*) FROM __diesel_schema_migrations')" -ge "${migrations}" ] && echo yes)" yes \
    "the migrations of both databases in firefox-sync's one (${migrations} before)"
  dst_verify
}

# dan-r/syncstorage-rs-docker builds syncstorage-rs from commit 1dc4214 (June 2025, 0.18.3
# and 8 commits without migrations): firefox-sync's build of 0.18.3 instead, migrating
# like its entrypoint (diesel, here the server's own migrations), then the entrypoint's
# SQL for services and nodes, with its compose file's database container and names
DANR_COMMIT=main
scenario_dan_r() {
  local root=$(rnd) pw=$(rnd)
  mkdir -p "${SRC}/data/initdb.d" "${SRC}/data/config"
  fetch "https://raw.githubusercontent.com/dan-r/syncstorage-rs-docker/${DANR_COMMIT}/data/initdb.d/init.sql" "${SRC}/data/initdb.d/init.sql"
  fetch "https://raw.githubusercontent.com/dan-r/syncstorage-rs-docker/${DANR_COMMIT}/docker-compose.yaml" "${SRC}/upstream-docker-compose.yaml"
  grep -q 'linuxserver/mariadb:10.6.13' "${SRC}/upstream-docker-compose.yaml" || fail "dan-r's compose file no longer runs linuxserver/mariadb:10.6.13"
  local app=ghcr.io/porelli/firefox-sync:syncstorage-rs-mysql-0.18.3
  need linuxserver/mariadb:10.6.13 "${app}" || exit 1
  cat > "${SRC}/docker-compose.yaml" <<EOF
services:
  mariadb:
    container_name: firefox_mariadb
    image: linuxserver/mariadb:10.6.13
    volumes:
      - ./data/config:/config
      - ./data/initdb.d/init.sql:/config/initdb.d/init.sql
    environment:
      MYSQL_DATABASE: syncstorage
      MYSQL_USER: sync
      MYSQL_PASSWORD: ${pw}
      MYSQL_ROOT_PASSWORD: ${root}
  syncserver:
    container_name: firefox_syncserver
    image: ${app}
    environment:
      SYNC_HOST: 0.0.0.0
      SYNC_MASTER_SECRET: $(rnd)
      SYNC_SYNCSTORAGE__DATABASE_URL: mysql://sync:${pw}@mariadb:3306/syncstorage_rs
      SYNC_TOKENSERVER__DATABASE_URL: mysql://sync:${pw}@mariadb:3306/tokenserver_rs
      SYNC_TOKENSERVER__ENABLED: "true"
      SYNC_TOKENSERVER__RUN_MIGRATIONS: "true"
      SYNC_TOKENSERVER__NODE_TYPE: mysql
      SYNC_TOKENSERVER__FXA_EMAIL_DOMAIN: api.accounts.firefox.com
      SYNC_TOKENSERVER__FXA_METRICS_HASH_SECRET: $(rnd)
      SYNC_TOKENSERVER__FXA_OAUTH_SERVER_URL: http://mock_fxa:6000
  mock_fxa:
    image: ${TEST_IMAGE}
    entrypoint: ["sh", "/app/scripts/start_mock_fxa_server.sh"]
    environment:
      MOCK_FXA_SERVER_HOST: 0.0.0.0
      MOCK_FXA_SERVER_PORT: 6000
EOF
  export COMPOSE_PROJECT_NAME=${SRC_PROJECT}
  echo "COMPOSE_PROJECT_NAME=${SRC_PROJECT} docker compose down -v --remove-orphans" > "${SRC}/.teardown"
  cd "${SRC}" || exit 1
  echo "== old stack: dan-r's layout (linuxserver/mariadb:10.6.13, syncstorage-rs 0.18.3)"
  docker compose up -d mariadb mock_fxa > /dev/null 2>&1
  for _ in $(seq 1 90); do
    docker exec firefox_mariadb mysql -usync -p"${pw}" -e 'SELECT 1' tokenserver_rs > /dev/null 2>&1 && break
    sleep 2
  done
  check "$(docker exec firefox_mariadb mysql -usync -p"${pw}" -sN -e 'SHOW DATABASES' 2> /dev/null | grep -cE '^(syncstorage_rs|tokenserver_rs)$')" 2 "init.sql: syncstorage_rs and tokenserver_rs"
  # the migrations, then the entrypoint's SQL, then the server
  docker compose run --rm --no-deps -T --entrypoint sh syncserver -c '
    /app/bin/syncserver & pid=$!
    for i in $(seq 1 180); do curl -sf http://localhost:8000/__heartbeat__ > /dev/null && break; sleep 1; done
    kill $pid; wait $pid; true' > "${WORK}/src-migrate.log" 2>&1
  docker exec -i firefox_mariadb mysql -usync -p"${pw}" tokenserver_rs <<EOF
DELETE FROM services;
INSERT INTO services (id, service, pattern) VALUES
    (1, "sync-1.5", "{node}/1.5/{uid}");
INSERT INTO nodes (id, service, node, capacity, available, current_load, downed, backoff) VALUES
    (1, 1, "${OLD_DOMAIN}", 10, 10, 0, 0, 0)
    ON DUPLICATE KEY UPDATE node = "${OLD_DOMAIN}", capacity = 10, available = (SELECT 10 - current_load from (SELECT * FROM nodes) as n2 where id = 1);
EOF
  check "$?" 0 "dan-r's entrypoint SQL: service and node 1"
  docker compose up -d syncserver > /dev/null 2>&1
  for _ in $(seq 1 120); do
    docker compose exec -T syncserver curl -sf http://localhost:8000/__heartbeat__ > /dev/null 2>&1 && break
    sleep 2
  done
  cd - > /dev/null || exit 1
  src_write "${SRC_PROJECT}_default" http://syncserver:8000
  (cd "${SRC}" && docker compose stop syncserver) > /dev/null 2>&1
  echo "== dumps (docs/migrating.md, dan-r)"
  cd "${SRC}" || exit 1
  guide "docker exec firefox_mariadb sh -c 'MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" mariadb-dump -uroot --single-transaction --no-tablespaces tokenserver_rs' > tokenserver.sql"
  check "$?" 0 "tokenserver_rs dump"
  guide "docker exec firefox_mariadb sh -c 'MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" mariadb-dump -uroot --single-transaction --no-tablespaces syncstorage_rs' > syncstorage.sql"
  check "$?" 0 "syncstorage_rs dump"
  echo "  source: MariaDB $(docker exec firefox_mariadb mysql -usync -p"${pw}" -sN -e 'SELECT VERSION()' 2> /dev/null)"
  cd - > /dev/null || exit 1
  dst_prepare mariadb
  cp "${SRC}"/*.sql "${DST}/"
  dst_load
  check "$(dst_sql "SELECT COUNT(*) FROM __diesel_schema_migrations WHERE version LIKE '20260226185317%'")" 1 "firefox-sync added the migrations dan-r's syncstorage-rs did not have"
  dst_verify
}

# jeena/fxsync-docker: its compose file as it is, with the mock FxA as accounts server
JEENA_COMMIT=main
scenario_jeena() {
  fetch "https://raw.githubusercontent.com/jeena/fxsync-docker/${JEENA_COMMIT}/docker-compose.yaml" "${SRC}/docker-compose.yaml"
  need mozilla/syncstorage-rs:0.13.6 mariadb:10.11 || exit 1
  cat > "${SRC}/.env" <<EOF
MARIADB_USER=sync
MARIADB_PASSWORD=$(rnd)
SYNC_MASTER_SECRET=$(rnd)
METRICS_HASH_SECRET=$(rnd)
DOMAIN=${OLD_DOMAIN}
EOF
  cat > "${SRC}/migrate-test.yaml" <<EOF
services:
  syncstorage:
    platform: linux/amd64
    ports: !reset []
    environment:
      SYNC_TOKENSERVER__FXA_OAUTH_SERVER_URL: http://mock_fxa:6000/v1
  mock_fxa:
    image: ${TEST_IMAGE}
    entrypoint: ["sh", "/app/scripts/start_mock_fxa_server.sh"]
    environment:
      MOCK_FXA_SERVER_HOST: 0.0.0.0
      MOCK_FXA_SERVER_PORT: 6000
EOF
  export COMPOSE_PROJECT_NAME=${SRC_PROJECT}
  echo "COMPOSE_PROJECT_NAME=${SRC_PROJECT} docker compose -f docker-compose.yaml -f migrate-test.yaml down -v --remove-orphans" > "${SRC}/.teardown"
  cd "${SRC}" || exit 1
  echo "== old stack: jeena/fxsync-docker (syncstorage-rs 0.13.6, mariadb:10.11)"
  docker compose -f docker-compose.yaml -f migrate-test.yaml up -d > "${WORK}/src-up.log" 2>&1
  timeout 600 docker wait firefox_tokenserver_db_init > /dev/null
  check "$(docker inspect -f '{{.State.ExitCode}}' firefox_tokenserver_db_init)" 0 "its tokenserver_db_init"
  cd - > /dev/null || exit 1
  src_write "${SRC_PROJECT}_default" http://syncstorage:8000
  (cd "${SRC}" && docker compose -f docker-compose.yaml -f migrate-test.yaml stop syncstorage) > /dev/null 2>&1
  echo "== dumps (docs/migrating.md, jeena)"
  cd "${SRC}" || exit 1
  guide "docker exec firefox_tokenserver_db sh -c 'MYSQL_PWD=\"\$MARIADB_PASSWORD\" mariadb-dump -u\"\$MARIADB_USER\" --single-transaction --no-tablespaces tokenserver' > tokenserver.sql"
  check "$?" 0 "tokenserver dump"
  guide "docker exec firefox_syncstorage_db sh -c 'MYSQL_PWD=\"\$MARIADB_PASSWORD\" mariadb-dump -u\"\$MARIADB_USER\" --single-transaction --no-tablespaces syncstorage' > syncstorage.sql"
  check "$?" 0 "syncstorage dump"
  cd - > /dev/null || exit 1
  dst_prepare mariadb
  cp "${SRC}"/*.sql "${DST}/"
  dst_load
  dst_verify
}

# NixOS' module: one database for both, on the host's server (here a container, as root
# without a password like the unix socket of NixOS' root)
scenario_nixos() {
  local db=$1 image ctr=mig-nixos-db
  case ${db} in
    mysql) image=mariadb:11.4 ;;
    postgres) image=postgres:17 ;;
  esac
  need "${image}" "ghcr.io/mozilla-services/syncstorage-rs/syncserver-${db}:${UPSTREAM_IMAGE_TAG}" || exit 1
  local url
  if [ "${db}" = mysql ]; then
    url="mysql://firefox_syncserver:pw@db:3306/firefox_syncserver"
  else
    url="postgres://firefox_syncserver:pw@db:5432/firefox_syncserver"
  fi
  cat > "${SRC}/docker-compose.yaml" <<EOF
services:
  db:
    container_name: ${ctr}
    image: ${image}
    environment:
      MARIADB_ALLOW_EMPTY_ROOT_PASSWORD: "1"
      MARIADB_DATABASE: firefox_syncserver
      MARIADB_USER: firefox_syncserver
      MARIADB_PASSWORD: pw
      POSTGRES_PASSWORD: rootpw
      POSTGRES_HOST_AUTH_METHOD: trust
    healthcheck:
      test: ["CMD-SHELL", "$([ "${db}" = mysql ] && echo 'healthcheck.sh --connect --innodb_initialized' || echo 'pg_isready -U postgres')"]
      interval: 5s
      retries: 30
  syncserver:
    image: ghcr.io/mozilla-services/syncstorage-rs/syncserver-${db}:${UPSTREAM_IMAGE_TAG}
    platform: linux/amd64
    depends_on:
      db:
        condition: service_healthy
    environment:
      SYNC_HOST: 0.0.0.0
      SYNC_MASTER_SECRET: $(rnd)
      SYNC_SYNCSTORAGE__DATABASE_URL: ${url}
      SYNC_TOKENSERVER__DATABASE_URL: ${url}
      SYNC_TOKENSERVER__ENABLED: "true"
      SYNC_TOKENSERVER__RUN_MIGRATIONS: "true"
      SYNC_TOKENSERVER__NODE_TYPE: ${db}
      SYNC_TOKENSERVER__FXA_EMAIL_DOMAIN: api.accounts.firefox.com
      SYNC_TOKENSERVER__FXA_OAUTH_SERVER_URL: http://mock_fxa:6000
      SYNC_TOKENSERVER__INIT_NODE_URL: ${OLD_DOMAIN}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/__heartbeat__"]
      interval: 5s
      retries: 60
  mock_fxa:
    image: ${TEST_IMAGE}
    entrypoint: ["sh", "/app/scripts/start_mock_fxa_server.sh"]
    environment:
      MOCK_FXA_SERVER_HOST: 0.0.0.0
      MOCK_FXA_SERVER_PORT: 6000
EOF
  if [ "${db}" = postgres ]; then
    # the database and its owner, as the module creates them (ensureDatabases, ensureUsers)
    mkdir -p "${SRC}/initdb"
    printf "CREATE ROLE firefox_syncserver LOGIN PASSWORD 'pw';\nCREATE DATABASE firefox_syncserver OWNER firefox_syncserver;\n" > "${SRC}/initdb/init.sql"
    sed -i "s|    healthcheck:|    volumes: [\"./initdb:/docker-entrypoint-initdb.d:ro\"]\n    healthcheck:|" "${SRC}/docker-compose.yaml"
  fi
  export COMPOSE_PROJECT_NAME=${SRC_PROJECT}
  echo "COMPOSE_PROJECT_NAME=${SRC_PROJECT} docker compose down -v --remove-orphans" > "${SRC}/.teardown"
  echo "== old stack: NixOS' layout, one database firefox_syncserver on ${image}"
  (cd "${SRC}" && docker compose up -d --wait --wait-timeout 600) > "${WORK}/src-up.log" 2>&1
  check "$?" 0 "old stack up" || { tail -20 "${WORK}/src-up.log"; exit 1; }
  src_write "${SRC_PROJECT}_default" http://syncserver:8000
  (cd "${SRC}" && docker compose stop syncserver) > /dev/null 2>&1
  echo "== dumps (docs/migrating.md, NixOS, as root on the host: here in the database container)"
  cd "${SRC}" || exit 1
  if [ "${db}" = mysql ]; then
    local tables listed="users nodes services __diesel_schema_migrations bso collections user_collections batch_uploads batch_upload_items"
    tables=$(docker exec "${ctr}" mariadb -uroot -sN -e 'SHOW TABLES' firefox_syncserver | sort | paste -sd' ')
    check "${tables}" "$(echo "${listed}" | tr ' ' '\n' | sort -u | paste -sd' ')" "the guide's table lists cover every table of the database"
    local cmd
    for cmd in "sudo mariadb-dump --single-transaction --no-tablespaces firefox_syncserver users nodes services __diesel_schema_migrations > tokenserver.sql" \
               "sudo mariadb-dump --single-transaction --no-tablespaces firefox_syncserver bso collections user_collections batch_uploads batch_upload_items __diesel_schema_migrations > syncstorage.sql"; do
      grep -qF -- "${cmd}" "${GUIDE[@]}" || { fail "command not in docs/migrating.md or docs/upgrading.md: ${cmd}"; continue; }
      echo "  \$ ${cmd}   (in the container, without sudo)"
      bash -o pipefail -c "docker exec ${ctr} ${cmd#sudo }"
      check "$?" 0 "dump: ${cmd##*> }"
    done
  else
    local cmd="sudo -u postgres pg_dump --no-owner --no-acl firefox_syncserver > syncserver.sql"
    grep -qF -- "${cmd}" "${GUIDE[@]}" || fail "command not in docs/migrating.md or docs/upgrading.md: ${cmd}"
    echo "  \$ ${cmd}   (in the container: docker exec -u postgres)"
    docker exec -u postgres "${ctr}" pg_dump --no-owner --no-acl firefox_syncserver > syncserver.sql
    check "$?" 0 "dump: syncserver.sql"
  fi
  cd - > /dev/null || exit 1
  dst_prepare "$([ "${db}" = mysql ] && echo mariadb || echo postgres)"
  cp "${SRC}"/*.sql "${DST}/"
  dst_load
  dst_verify
}

# YunoHost's syncserver-rs_ynh (0.23.3~ynh9 and later): upstream 0.23.3 on the server's
# PostgreSQL (15 on bookworm), two databases of one owner, syncserver_rs (storage) and
# syncserver_rs_tokenserver
scenario_yunohost() {
  local ctr=mig-yunohost-db image=postgres:15
  need "${image}" "ghcr.io/mozilla-services/syncstorage-rs/syncserver-postgres:${UPSTREAM_IMAGE_TAG}" || exit 1
  mkdir -p "${SRC}/initdb"
  cat > "${SRC}/initdb/init.sql" <<EOF
CREATE ROLE syncserver_rs LOGIN PASSWORD 'pw';
CREATE DATABASE syncserver_rs OWNER syncserver_rs;
CREATE DATABASE syncserver_rs_tokenserver OWNER syncserver_rs;
EOF
  cat > "${SRC}/docker-compose.yaml" <<EOF
services:
  db:
    container_name: ${ctr}
    image: ${image}
    environment:
      POSTGRES_PASSWORD: rootpw
    volumes: ["./initdb:/docker-entrypoint-initdb.d:ro"]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      retries: 30
  syncserver:
    image: ghcr.io/mozilla-services/syncstorage-rs/syncserver-postgres:${UPSTREAM_IMAGE_TAG}
    platform: linux/amd64
    depends_on:
      db:
        condition: service_healthy
    environment:
      SYNC_HOST: 0.0.0.0
      SYNC_MASTER_SECRET: $(rnd)
      SYNC_SYNCSTORAGE__DATABASE_URL: postgres://syncserver_rs:pw@db/syncserver_rs
      SYNC_TOKENSERVER__DATABASE_URL: postgres://syncserver_rs:pw@db/syncserver_rs_tokenserver
      SYNC_TOKENSERVER__ENABLED: "true"
      SYNC_TOKENSERVER__RUN_MIGRATIONS: "true"
      SYNC_TOKENSERVER__NODE_TYPE: postgres
      SYNC_TOKENSERVER__FXA_EMAIL_DOMAIN: api.accounts.firefox.com
      SYNC_TOKENSERVER__FXA_OAUTH_SERVER_URL: http://mock_fxa:6000
      SYNC_TOKENSERVER__INIT_NODE_URL: ${OLD_DOMAIN}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/__heartbeat__"]
      interval: 5s
      retries: 60
  mock_fxa:
    image: ${TEST_IMAGE}
    entrypoint: ["sh", "/app/scripts/start_mock_fxa_server.sh"]
    environment:
      MOCK_FXA_SERVER_HOST: 0.0.0.0
      MOCK_FXA_SERVER_PORT: 6000
EOF
  export COMPOSE_PROJECT_NAME=${SRC_PROJECT}
  echo "COMPOSE_PROJECT_NAME=${SRC_PROJECT} docker compose down -v --remove-orphans" > "${SRC}/.teardown"
  echo "== old stack: YunoHost's layout, syncserver_rs and syncserver_rs_tokenserver on ${image}"
  (cd "${SRC}" && docker compose up -d --wait --wait-timeout 600) > "${WORK}/src-up.log" 2>&1
  check "$?" 0 "old stack up" || { tail -20 "${WORK}/src-up.log"; exit 1; }
  src_write "${SRC_PROJECT}_default" http://syncserver:8000
  (cd "${SRC}" && docker compose stop syncserver) > /dev/null 2>&1
  echo "== dumps (docs/migrating.md, YunoHost, as root on the server: here in the database container)"
  cd "${SRC}" || exit 1
  local cmd
  for cmd in "sudo -u postgres pg_dump --no-owner --no-acl syncserver_rs_tokenserver > syncserver.sql" \
             "sudo -u postgres pg_dump --no-owner --no-acl --exclude-table=__diesel_schema_migrations syncserver_rs > syncstorage.sql" \
             "sudo -u postgres pg_dump --data-only --table=__diesel_schema_migrations syncserver_rs > syncstorage-migrations.sql"; do
    grep -qF -- "${cmd}" "${GUIDE[@]}" || { fail "command not in docs/migrating.md or docs/upgrading.md: ${cmd}"; continue; }
    echo "  \$ ${cmd}   (docker exec -u postgres)"
    bash -o pipefail -c "docker exec -u postgres ${ctr} ${cmd#sudo -u postgres }" < /dev/null
    check "$?" 0 "dump: ${cmd##*> }"
  done
  cd - > /dev/null || exit 1
  dst_prepare postgres
  cp "${SRC}"/*.sql "${DST}/"
  PG_FILES="syncserver.sql syncstorage.sql syncstorage-migrations.sql" dst_load
  dst_verify
}

# ---------- firefox-sync's public release: ca9101d, the layout of porelli/firefox-sync before this one ----------
# (its docker-compose.yml, docker-compose.postgres.yml and Quadlets, the settings without the
# SYNC_ prefix, the images syncstorage-rs-<mysql|postgres>[-init]-latest; no admin UI)
PUBLIC_COMMIT=ca9101d2c53769424d5b17b50f65a6899f2755c6
# its images as they were published, by a tag that does not move (latest does: to this release)
PUBLIC_IMAGES=ghcr.io/porelli/firefox-sync
PUBLIC_BUILD=0.24.0-20261102T154558

# public_tree <dir>: that release's files, as a clone of it has them; its file list in <dir>/.public-files
public_tree() {
  mkdir -p "$1"
  curl -sfL --retry 3 "https://codeload.github.com/porelli/firefox-sync/tar.gz/${PUBLIC_COMMIT}" -o "${WORK}/public.tar.gz" \
    || { fail "download of ${PUBLIC_COMMIT}"; exit 1; }
  tar -xzf "${WORK}/public.tar.gz" -C "$1" --strip-components=1 || { fail "extract ${PUBLIC_COMMIT}"; exit 1; }
  tar -tzf "${WORK}/public.tar.gz" | sed 's|^[^/]*/||' | grep -v '/$' | grep . > "$1/.public-files"
}

# public_setup <dir> <mariadb|postgres> <compose|quadlets> <repository> <tag>: its own
# prepare_environment.sh, answered as a user does (MAX_USERS=2, the old node URL), its images
# <repository>:syncstorage-rs-*-<tag>, the mock FxA as accounts server (test only)
public_setup() {
  local dir=$1 db=$2 how=$3 repo=$4 tag=$5 answers=()
  sed -i -e "s|^REPOSITORY=.*|REPOSITORY=${repo}|" -e "s|^SYNCSTORAGE_INIT_IMAGE_TAG=.*|SYNCSTORAGE_INIT_IMAGE_TAG=${tag}|" \
    -e "s|^FXA_OAUTH_SERVER_URL=.*|FXA_OAUTH_SERVER_URL=http://mock_fxa:6000|" "${dir}/.env-example"
  # domain, directory, port, max users, database; with Podman installed how to deploy; user, image tag
  answers=("${OLD_DOMAIN#https://}" "" "127.0.0.1:${PORT}" 2 "${db}")
  command -v podman > /dev/null && answers+=("$([ "${how}" = quadlets ] && echo 1 || echo 2)")
  answers+=("" "${tag}")
  (cd "${dir}" && printf '%s\n' "${answers[@]}" | ./prepare_environment.sh) > "${WORK}/public-setup.log" 2>&1
  check "$?" 0 "its prepare_environment.sh (${db}, ${how})" || { tail -20 "${WORK}/public-setup.log"; exit 1; }
  [ "${how}" = compose ] || return 0
  cat > "${dir}/migrate-test.yml" <<EOF
services:
  mock_fxa:
    image: ${TEST_IMAGE}
    entrypoint: ["sh", "/app/scripts/start_mock_fxa_server.sh"]
    environment:
      MOCK_FXA_SERVER_HOST: 0.0.0.0
      MOCK_FXA_SERVER_PORT: 6000
EOF
  # (MariaDB: no COMPOSE_FILE, docker-compose.yml; PostgreSQL: COMPOSE_FILE=docker-compose.postgres.yml)
  if grep -q '^COMPOSE_FILE=' "${dir}/.env"; then
    sed -i 's|^COMPOSE_FILE=.*|&:migrate-test.yml|' "${dir}/.env"
  else
    printf '# tests/migrate.sh\nCOMPOSE_FILE=docker-compose.yml:migrate-test.yml\n' >> "${dir}/.env"
  fi
}

# public_pull <dir>: "git pull" from that release to this tree: its files removed, this tree's
# in their place; .env and the files the setup wrote (config/nginx/syncstorage-rs.conf...) stay
public_pull() {
  local dir=$1 f
  while IFS= read -r f; do rm -f "${dir}/${f}"; done < "${dir}/.public-files"
  for f in docker-compose.yml .env-example prepare_environment.sh compose config db setup; do cp -r "${CODE}/${f}" "${dir}/"; done
  mkdir -p "${dir}/tests/compose" && cp "${TESTS}/compose/migrate.yml" "${dir}/tests/compose/"
}

# the images under test, under the names .env gives them: <app> <init> of ${REPOSITORY}, the init
# image INIT_TAG (built from this tree), tagged ${TAG} for compose (whose pull brings the published one)
init_under_test() { echo "${REPOSITORY}:syncstorage-rs-$1-init-${INIT_TAG}"; }

# old_stack_up: that release's stack, the client's data written through it, MAX_USERS=2 counted
old_stack_up() {
  echo "== old stack: firefox-sync ${PUBLIC_COMMIT:0:7} ($1)"
  dst up -d > "${WORK}/src-up.log" 2>&1
  check "$?" 0 "old stack up" || { tail -20 "${WORK}/src-up.log"; exit 1; }
  check "$(wait_init)" 0 "its init container"
  check "$(hb)" 200 "its Sync server answers"
  src_write "${DST_PROJECT}_default" http://syncstorage:8000
  client "${DST_PROJECT}_default" http://syncstorage:8000 "${OLD_DOMAIN}" new carol refused
  check "$?" 0 "MAX_USERS=2 on the old stack: a third account is refused"
}

# firefox-sync of ca9101d upgraded in place as docs/upgrading.md#the-earlier-firefox-sync-release says (the
# same directory and volumes, its .env kept). <mariadb|postgres>
scenario_firefox_sync_public() {
  local db=$1 backend=mysql
  [ "${db}" = postgres ] && backend=postgres
  # the directory gives the compose project and the volume names, as with a clone
  DST=${WORK}/${DST_PROJECT}
  public_tree "${DST}"
  need "${PUBLIC_IMAGES}:syncstorage-rs-${backend}-${PUBLIC_BUILD}" "${PUBLIC_IMAGES}:syncstorage-rs-${backend}-init-${PUBLIC_BUILD}" || exit 1
  public_setup "${DST}" "${db}" compose "${PUBLIC_IMAGES}" "${PUBLIC_BUILD}"
  DST_DB=${db}
  old_stack_up "${db}"
  local volumes_before
  volumes_before=$(docker volume ls -q --filter "label=com.docker.compose.project=${DST_PROJECT}" | sort | paste -sd' ')
  echo "  volumes: ${volumes_before}"

  echo "== upgrade in place (docs/upgrading.md#the-earlier-firefox-sync-release)"
  public_pull "${DST}"
  local renamed
  renamed=$(grep -cE "^($(IFS='|'; echo "${RENAMED_SETTINGS[*]#*=}"))=" "${DST}/.env")
  (cd "${DST}" && ./prepare_environment.sh --upgrade) > "${WORK}/upgrade.log" 2>&1
  check "$? $(grep -cE '^ADMIN_DB_PASSWORD=[A-Za-z0-9]{32}$' "${DST}/.env")" "0 1" "./prepare_environment.sh --upgrade sets ADMIN_DB_PASSWORD" || cat "${WORK}/upgrade.log"
  check "$(grep -cE "^($(IFS='|'; echo "${RENAMED_SETTINGS[*]#*=}"))=" "${DST}/.env") $(grep -c '^  [A-Z_]* -> [A-Z_]*$' "${WORK}/upgrade.log")" "0 ${renamed}" \
    "--upgrade renames the ${renamed} old setting names of that .env" || cat "${WORK}/upgrade.log"
  # COMPOSE_FILE with the files of compose/, the test's own kept; the project's name next to it,
  # the directory's (compose/ first, compose would name it "compose": other volumes)
  check "$(sed -n 's/^COMPOSE_FILE=//p' "${DST}/.env") $(sed -n 's/^COMPOSE_PROJECT_NAME=//p' "${DST}/.env") $(grep -c '^COMPOSE_FILE: the compose files moved to compose/' "${WORK}/upgrade.log")" \
    "compose/sync.yml:compose/sync-${db}.yml:migrate-test.yml ${DST_PROJECT} 1" "--upgrade: COMPOSE_FILE with the files of compose/, the project's name, and says so"
  check "$(cd "${DST}" && docker compose config --format json | jq -r '.volumes | to_entries[] | .value.name' | grep -E 'tokenserver-db|syncstorage-db|postgres-db' | sort | paste -sd' ')" \
    "$(echo "${volumes_before}" | tr ' ' '\n' | grep -E 'tokenserver-db|syncstorage-db|postgres-db' | paste -sd' ')" "the Sync volumes of compose/, named as before (the project's name)"
  # the database majors: MariaDB on the major of its data (it ran mariadb:lts), PostgreSQL on 18
  if [ "${db}" = mariadb ]; then
    local major
    major=$(dst exec -T tokenserver_db mariadb --version < /dev/null 2> /dev/null | sed -nE 's/.* ([0-9]+)\.[0-9]+\.[0-9]+-MariaDB.*/\1/p')
    check "$(sed -n 's/^SYNC_MARIADB_IMAGE=//p' "${DST}/.env")" "mariadb:${major}" "--upgrade pins MariaDB to the major of the data (${major})"
  else
    check "$(sed -n 's/^SYNC_POSTGRES_IMAGE=//p' "${DST}/.env") $(grep -c '^SYNC_POSTGRES_APP_PASSWORD=[A-Za-z0-9]\{32\}$' "${DST}/.env")" "postgres:18 1" \
      "--upgrade pins PostgreSQL 18 and gives the Sync server a role of its own"
  fi
  # the nginx file the setup of then wrote: moved aside, the configuration of the proxy in proxy/
  check "$(ls "${DST}"/proxy/old/syncstorage-rs.conf-* 2> /dev/null | wc -l) $([ -f "${DST}/proxy/nginx.conf" ] && echo nginx)" "1 nginx" \
    "--upgrade moves config/nginx/syncstorage-rs.conf into proxy/old/, writes proxy/"
  # the admin UI, which that release did not have (docs/admin/README.md); the images under test,
  # the mock FxA and the test's own files
  sed -i -e "s|^IMAGE_REPOSITORY=.*|IMAGE_REPOSITORY=${REPOSITORY}|" -e "s|^SYNC_IMAGE_TAG=.*|SYNC_IMAGE_TAG=${TAG}|" \
      -e "s|^SYNC_INIT_IMAGE_TAG=.*|SYNC_INIT_IMAGE_TAG=${TAG}|" -e "/^COMPOSE_FILE=/d" -e "/^COMPOSE_PROJECT_NAME=/d" \
      -e "/^# tests\/migrate.sh/d" -e "/^FXA_OAUTH_SERVER_URL=/d" "${DST}/.env"
  rm -f "${DST}/migrate-test.yml"
  printf 'COMPOSE_PROFILES=admin\nADMIN_PASSWORD=%s\nADMIN_EXPORT_PORT=127.0.0.1:%s\n' "$(rnd)" "$((PORT + 20))" >> "${DST}/.env"
  dst_test_env "compose/sync.yml:compose/sync-${db}.yml"
  # docker compose pull would replace the init image built from this tree with the published one
  local init_image=${REPOSITORY}:syncstorage-rs-${backend}-init-${TAG} init_id
  [ "${INIT_TAG}" = "${TAG}" ] || docker tag "$(init_under_test "${backend}")" "${init_image}"
  init_id=$(docker image inspect -f '{{.Id}}' "${init_image}" 2> /dev/null)
  cd "${DST}" || exit 1
  guide "docker compose pull && docker compose up -d" > "${WORK}/up.log" 2>&1
  check "$?" 0 "docker compose pull && docker compose up -d" || tail -20 "${WORK}/up.log"
  if [ -n "${init_id}" ] && [ "$(docker image inspect -f '{{.Id}}' "${init_image}")" != "${init_id}" ]; then
    docker tag "${init_id}" "${init_image}"
    docker compose up -d > /dev/null 2>&1
  fi
  cd - > /dev/null || exit 1
  check "$(wait_init)" 0 "init container exit code"
  check "$(state syncstorage_migrate ExitCode)" 0 "migrations of the newer syncstorage-rs"
  check "$(docker volume ls -q --filter "label=com.docker.compose.project=${DST_PROJECT}" | grep -E 'tokenserver-db|syncstorage-db|postgres-db' | sort | paste -sd' ')" \
    "$(echo "${volumes_before}" | tr ' ' '\n' | grep -E 'tokenserver-db|syncstorage-db|postgres-db' | paste -sd' ')" "the same volumes"
  dst_verify "${OLD_DOMAIN}"
}

# a local registry with that release's images under its tags (latest): what its hosts pull from.
# <backend>; REG is its address
registry_up() {
  REG=127.0.0.1:$((PORT + 30))
  need docker.io/library/registry:2 || exit 1
  printf 'docker rm -f mig-registry%s\n' "${SLOT_SUFFIX}" >> "${SRC}/.teardown"
  docker rm -f "mig-registry${SLOT_SUFFIX}" > /dev/null 2>&1
  docker run -d --name "mig-registry${SLOT_SUFFIX}" -p "${REG}:5000" docker.io/library/registry:2 > /dev/null || { fail "registry"; exit 1; }
  for _ in $(seq 1 20); do curl -sf "http://${REG}/v2/" > /dev/null && break; sleep 1; done
  local t
  need "${PUBLIC_IMAGES}:syncstorage-rs-$1-${PUBLIC_BUILD}" "${PUBLIC_IMAGES}:syncstorage-rs-$1-init-${PUBLIC_BUILD}" || exit 1
  for t in "" -init; do
    registry_push "${PUBLIC_IMAGES}:syncstorage-rs-$1${t}-${PUBLIC_BUILD}" "syncstorage-rs-$1${t}-latest"
  done
}
# registry_push <image> <tag>: <image> published as REG/firefox-sync:<tag>, the host keeping what
# it had under that name (it has the image of before until something pulls)
registry_push() {
  local before
  before=$(docker image inspect -f '{{.Id}}' "${REG}/firefox-sync:$2" 2> /dev/null)
  docker tag "$1" "${REG}/firefox-sync:$2" && docker push -q "${REG}/firefox-sync:$2" > /dev/null || { fail "push $2"; exit 1; }
  [ -z "${before}" ] || docker tag "${before}" "${REG}/firefox-sync:$2"
}
image_of() { docker inspect -f '{{.Image}}' "$(dst ps -a -q "$1")" 2> /dev/null; }

# that release's stack, untouched, when the images of this release are published under its tags:
# Watchtower recreates the running containers with them (the same configuration, the files and
# .env of before), then `docker compose pull && docker compose up -d` (a cron, or after it)
# brings the init container and the migrations too (docs/upgrading.md#watchtower-and-podman-auto-update). <mariadb|postgres>
scenario_watchtower() {
  local db=$1 backend=mysql
  [ "${db}" = postgres ] && backend=postgres
  DST=${WORK}/${DST_PROJECT}
  registry_up "${backend}"
  public_tree "${DST}"
  public_setup "${DST}" "${db}" compose "${REG}/firefox-sync" latest
  DST_DB=${db}
  old_stack_up "${db}"
  local users_before old_app new_app names
  users_before=$(dst_sql "SELECT uid, email, nodeid, generation, keys_changed_at FROM users ORDER BY uid")
  old_app=$(image_of syncstorage)

  echo "== the images of this release under the same tags, Watchtower"
  registry_push "${REPOSITORY}:syncstorage-rs-${backend}-${TAG}" "syncstorage-rs-${backend}-latest"
  registry_push "$(init_under_test "${backend}")" "syncstorage-rs-${backend}-init-latest"
  need docker.io/containrrr/watchtower:latest || exit 1
  # (Watchtower's client is older than the API versions Docker 29 still accepts: the oldest it does)
  names=$(dst ps -a --format '{{.Name}}' | grep -v mock_fxa | paste -sd' ')
  # shellcheck disable=SC2086 # (the container names, one word each)
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -e DOCKER_API_VERSION="$(docker version -f '{{.Server.MinAPIVersion}}')" \
    docker.io/containrrr/watchtower:latest --run-once ${names} > "${WORK}/watchtower.log" 2>&1
  check "$? $(grep -c 'Session done.*Failed=0' "${WORK}/watchtower.log")" "0 1" "watchtower --run-once" || cat "${WORK}/watchtower.log"
  new_app=$(docker image inspect -f '{{.Id}}' "${REG}/firefox-sync:syncstorage-rs-${backend}-latest")
  check "$([ "${new_app}" != "${old_app}" ] && [ "$(image_of syncstorage)" = "${new_app}" ] && echo new) $(state syncstorage Running)" "new true" \
    "Watchtower recreated the Sync server with the new image (and the configuration of before)"
  check "$(hb)" 200 "the new Sync server answers, with the old compose file and .env"
  check "$(dst_sql "SELECT uid, email, nodeid, generation, keys_changed_at FROM users ORDER BY uid")" "${users_before}" "the accounts as they were"
  client "${DST_PROJECT}_default" http://syncstorage:8000 "${OLD_DOMAIN}" check
  check "$?" 0 "the client reads its data back through the new Sync server"
  client "${DST_PROJECT}_default" http://syncstorage:8000 "${OLD_DOMAIN}" new carol refused
  check "$?" 0 "MAX_USERS=2 still counts: a third account is refused"

  echo "== docker compose pull && docker compose up -d, with the files and .env of before"
  cd "${DST}" || exit 1
  guide "docker compose pull && docker compose up -d" > "${WORK}/up.log" 2>&1
  check "$?" 0 "docker compose pull && docker compose up -d (the files of before)" || tail -20 "${WORK}/up.log"
  cd - > /dev/null || exit 1
  check "$(wait_init) $(image_of tokenserver_db_init | grep -c "$(docker image inspect -f '{{.Id}}' "${REG}/firefox-sync:syncstorage-rs-${backend}-init-latest")")" "0 1" \
    "the new init container ran with the old setting names, exit code 0"
  check "$(state syncstorage_migrate ExitCode)" 0 "the new migrations"
  check "$(dst logs tokenserver_db_init 2>&1 | grep -c 'Current users: 2$') $(dst_sql "SELECT config_value FROM config WHERE config_key = 'max_users'")" "1 2" \
    "the init container counts the 2 accounts, max users 2 (MAX_USERS of before)"
  check "$(dst_sql "SELECT config_value FROM config WHERE config_key = 'allowed_accounts'")" off "invite-only Sync off, as before (no SYNC_ALLOWED_ACCOUNTS)"
  check "$(hb)" 200 "/__heartbeat__"
  check "$(dst_sql "SELECT uid, email, nodeid, generation, keys_changed_at FROM users ORDER BY uid")" "${users_before}" "the accounts as they were"
  client "${DST_PROJECT}_default" http://syncstorage:8000 "${OLD_DOMAIN}" check
  check "$?" 0 "the client reads its data back"
  client "${DST_PROJECT}_default" http://syncstorage:8000 "${OLD_DOMAIN}" new carol refused
  check "$?" 0 "MAX_USERS=2: a third account is refused"
  sed -i 's/^MAX_USERS=.*/MAX_USERS=3/' "${DST}/.env"
  dst up -d > /dev/null 2>&1
  check "$(wait_init)" 0 "init container exit code (MAX_USERS=3)"
  client "${DST_PROJECT}_default" http://syncstorage:8000 "${OLD_DOMAIN}" new carol ok
  check "$?" 0 "MAX_USERS=3 in the .env of before: the third account is let in"
  check "$(dst logs syncstorage 2>&1 | grep -ciE 'panicked|"status":5[0-9][0-9]')" 0 "no panics or 5xx in the Sync server's logs"
}

# that release's Quadlets (Podman, systemd --user; MariaDB, as it had them): podman auto-update
# (AutoUpdate=registry, its timer) when the images of this release are published under its tags,
# then the upgrade of docs/upgrading.md#quadlets: the units stopped, the new files, --upgrade,
# the images pulled, started (docs/upgrading.md#with-quadlets)
scenario_public_quadlets() {
  local qd=${HOME}/.config/containers/systemd ud=${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user
  local client_image=${PUBLIC_IMAGES}:syncstorage-rs-mysql-${PUBLIC_BUILD}
  command -v podman > /dev/null && systemctl --user show-environment > /dev/null 2>&1 || { fail "needs podman and a systemd user session"; exit 1; }
  ls "${qd}"/firefox-sync-* > /dev/null 2>&1 && { fail "Quadlet units of firefox-sync installed in ${qd} already: not here"; exit 1; }
  DST=${WORK}/${DST_PROJECT}
  registry_up mysql
  # the registry over plain HTTP, for Podman too (the test's own file, removed at the end)
  mkdir -p "${HOME}/.config/containers/registries.conf.d"
  printf '[[registry]]\nlocation = "%s"\ninsecure = true\n' "${REG}" > "${HOME}/.config/containers/registries.conf.d/ffs-migrate${SLOT_SUFFIX}.conf"
  cat >> "${SRC}/.teardown" <<TEARDOWN
systemctl --user stop firefox-sync-syncstorage.service firefox-sync-tokenserver-db-init.service firefox-sync-syncstorage-migrate.service firefox-sync-db-bootstrap.service firefox-sync-tokenserver-db.service firefox-sync-syncstorage-db.service firefox-sync-backup.timer
systemctl --user stop firefox-sync-network-network.service firefox-sync-syncstorage-db-volume.service firefox-sync-tokenserver-db-volume.service firefox-sync-backups-volume.service
podman rm -f mig-mock-fxa${SLOT_SUFFIX}
rm -f "${qd}"/firefox-sync-* "${ud}"/firefox-sync-backup.timer
systemctl --user daemon-reload
podman rm -f -a --filter name=firefox-sync
podman volume rm firefox-sync-syncstorage-db firefox-sync-tokenserver-db firefox-sync-backups
podman network rm firefox-sync
podman rmi \$(podman images --format '{{.Repository}}:{{.Tag}}' | grep '^${REG}/') ${client_image}
systemctl --user reset-failed
rm -f "${HOME}/.config/containers/registries.conf.d/ffs-migrate${SLOT_SUFFIX}.conf"
TEARDOWN
  public_tree "${DST}"
  public_setup "${DST}" mariadb quadlets "${REG}/firefox-sync" latest
  podman image exists "${client_image}" || podman pull -q "${client_image}" > /dev/null || { fail "podman pull ${client_image}"; exit 1; }
  qclient() { podman run --rm --network firefox-sync --user root --entrypoint sh -v "${TESTS}:/tests:ro" -v "${STATE}:/state" \
    -e SYNC_SERVER_URL=http://firefox-sync-syncstorage:8000 -e SYNC_PUBLIC_URL="${OLD_DOMAIN}" -e PYTHONPATH=/app:/app/tools:/tests \
    -e PYTHONDONTWRITEBYTECODE=1 "${client_image}" -c "cd /app && python3 /tests/migrate_client.py $*" < /dev/null; }
  qsql() { podman exec firefox-sync-tokenserver-db sh -c 'MYSQL_PWD="$MARIADB_PASSWORD" mariadb -u"$MARIADB_USER" "$MARIADB_DATABASE" -sN -e "$0"' "$1" < /dev/null 2> /dev/null; }
  qimage() { podman inspect -f '{{.Image}}' "$1" 2> /dev/null; }

  echo "== old stack: firefox-sync ${PUBLIC_COMMIT:0:7} (Quadlets)"
  # (restart: a network unit left active by an earlier run would not create its network again)
  systemctl --user restart firefox-sync-network-network.service
  # the mock FxA on the units' network, as FXA_OAUTH_SERVER_URL says (test only)
  podman run -d --name "mig-mock-fxa${SLOT_SUFFIX}" --network firefox-sync --network-alias mock_fxa --entrypoint sh \
    -e MOCK_FXA_SERVER_HOST=0.0.0.0 -e MOCK_FXA_SERVER_PORT=6000 "${client_image}" /app/scripts/start_mock_fxa_server.sh > /dev/null
  timeout 900 systemctl --user start firefox-sync-syncstorage.service
  check "$?" 0 "its units started (systemctl --user start firefox-sync-syncstorage.service)"
  check "$(hb)" 200 "its Sync server answers"
  echo "== writing through the old server"
  qclient write
  check "$?" 0 "alice and bob synced to the old server" || exit 1
  qclient new carol refused
  check "$?" 0 "MAX_USERS=2 on the old stack: a third account is refused"
  local users_before old_app secret
  users_before=$(qsql "SELECT uid, email, nodeid, generation, keys_changed_at FROM users ORDER BY uid")
  old_app=$(qimage firefox-sync-syncstorage)
  secret=$(sed -n 's/^SYNC_MASTER_SECRET=//p' "${DST}/.env")

  echo "== the images of this release under the same tags, podman auto-update"
  registry_push "${REPOSITORY}:syncstorage-rs-mysql-${TAG}" syncstorage-rs-mysql-latest
  registry_push "$(init_under_test mysql)" syncstorage-rs-mysql-init-latest
  podman auto-update > "${WORK}/auto-update.log" 2>&1
  check "$? $(grep -cE 'firefox-sync-syncstorage\.service .* true$' "${WORK}/auto-update.log")" "0 1" "podman auto-update replaced the Sync server" || cat "${WORK}/auto-update.log"
  check "$([ "$(qimage firefox-sync-syncstorage)" != "${old_app}" ] && echo new)" new "the Sync server runs the new image, with the units of before"
  check "$(hb)" 200 "the new Sync server answers"
  check "$(qsql "SELECT uid, email, nodeid, generation, keys_changed_at FROM users ORDER BY uid")" "${users_before}" "the accounts as they were"
  qclient check
  check "$?" 0 "the client reads its data back through the new Sync server"
  qclient new carol refused
  check "$?" 0 "MAX_USERS=2 still counts: a third account is refused"

  echo "== the upgrade of docs/upgrading.md#quadlets"
  cd "${DST}" || exit 1
  guide "systemctl --user stop firefox-sync-syncstorage.service firefox-sync-syncstorage-migrate.service firefox-sync-tokenserver-db-init.service firefox-sync-tokenserver-db.service firefox-sync-syncstorage-db.service" > /dev/null 2>&1
  check "$?" 0 "the units of that release stopped, as docs/upgrading.md#quadlets says"
  public_pull "${DST}"
  ./prepare_environment.sh --upgrade < /dev/null > "${WORK}/upgrade.log" 2>&1
  check "$? $(grep -c 'are of an earlier release of firefox-sync' "${WORK}/upgrade.log") $(grep -c '^Rendering the Quadlet units from' "${WORK}/upgrade.log")" "0 1 1" \
    "--upgrade finds the units of that release (with its SYNC_MASTER_SECRET) and renders them again" || cat "${WORK}/upgrade.log"
  check "$(grep -cE "^($(IFS='|'; echo "${RENAMED_SETTINGS[*]#*=}"))=" .env) $(sed -n 's/^SYNC_MASTER_SECRET=//p' "${qd}/firefox-sync-syncstorage.env" | grep -cxF "${secret}") $(grep -cE '^ADMIN_DB_PASSWORD=[A-Za-z0-9]{32}$' .env) $(ls quadlets.before-*/firefox-sync-syncstorage.container 2> /dev/null | wc -l)" \
    "0 1 1 1" "--upgrade: the new setting names, the secrets kept (in the units' environment files), ADMIN_DB_PASSWORD, the units of before kept" || { cat "${WORK}/upgrade.log"; ls -la; }
  local major
  major=$(podman exec firefox-sync-tokenserver-db mariadb --version 2> /dev/null | sed -nE 's/.* ([0-9]+)\.[0-9]+\.[0-9]+-MariaDB.*/\1/p')
  [ -n "${major}" ] || major=$(podman run --rm --entrypoint mariadb docker.io/library/mariadb:lts --version | sed -nE 's/.* ([0-9]+)\.[0-9]+\.[0-9]+-MariaDB.*/\1/p')
  check "$(sed -n 's/^SYNC_MARIADB_IMAGE=//p' .env) $(sed -n 's/^Image=//p' "${qd}/firefox-sync-tokenserver-db.container")" "mariadb:${major} docker.io/library/mariadb:${major}" \
    "--upgrade pins MariaDB to the major of the data (${major}), in the units too"
  guide "grep -h '^Image=' ~/.config/containers/systemd/firefox-sync-*.container | cut -d= -f2 | sort -u | xargs -n1 podman pull" > "${WORK}/pull.log" 2>&1
  check "$?" 0 "the images of the units pulled" || tail -5 "${WORK}/pull.log"
  local since
  since=$(date '+%Y-%m-%d %H:%M:%S')
  timeout 900 systemctl --user start firefox-sync-syncstorage.service
  check "$?" 0 "systemctl --user start firefox-sync-syncstorage.service"
  cd - > /dev/null || exit 1
  check "$(systemctl --user is-active firefox-sync-syncstorage-migrate.service firefox-sync-tokenserver-db-init.service | paste -sd' ')" "active active" "the migrations and the init container of this release ran"
  check "$(journalctl --user -u firefox-sync-tokenserver-db-init.service --since "${since}" --no-pager 2> /dev/null | grep -q 'Current users: 2$' && echo 2)" 2 "init container: Current users: 2"
  check "$(hb)" 200 "the Sync server answers, upgraded"
  check "$(qsql "SELECT uid, email, nodeid, generation, keys_changed_at FROM users ORDER BY uid")" "${users_before}" "the accounts as they were, on the same volumes"
  qclient check
  check "$?" 0 "the client reads its data back"
  qclient new carol refused
  check "$?" 0 "SYNC_MAX_USERS=2 (MAX_USERS of before): a third account is refused"
}

# ---------- run ----------

docker image inspect "${TEST_IMAGE}" > /dev/null 2>&1 || need "${TEST_IMAGE}" || exit 1
if ! docker image inspect "${ADMIN_IMAGE}" > /dev/null 2>&1; then
  ADMIN_IMAGE=${ADMIN_IMAGE} COMPOSE_BAKE=false one_at_a_time admin-build docker compose -p ffs-admin-build -f "${TESTS}/compose/admin-build.yml" build -q \
    || { fail "admin UI image built from admin/"; exit 1; }
fi
echo "== ${SCENARIO} (firefox-sync: ${REPOSITORY} ${TAG})"
case ${SCENARIO} in
  upstream-mysql) scenario_upstream_mysql mariadb ;;
  upstream-mysql-to-mysql) scenario_upstream_mysql mysql ;;
  upstream-mysql-testsetup) scenario_upstream_mysql_testsetup ;;
  upstream-postgres) scenario_upstream_postgres ;;
  upstream-postgres-2db) scenario_upstream_postgres_2db ;;
  dan-r) scenario_dan_r ;;
  jeena) scenario_jeena ;;
  nixos-mysql) scenario_nixos mysql ;;
  nixos-postgres) scenario_nixos postgres ;;
  yunohost) scenario_yunohost ;;
  firefox-sync-public) scenario_firefox_sync_public mariadb ;;
  firefox-sync-public-postgres) scenario_firefox_sync_public postgres ;;
  watchtower) scenario_watchtower mariadb ;;
  watchtower-postgres) scenario_watchtower postgres ;;
  firefox-sync-public-quadlets) scenario_public_quadlets ;;
  *) echo "unknown scenario ${SCENARIO}"; exit 2 ;;
esac
[ ${FAILED} = 0 ] && echo "RESULT ${SCENARIO}: all checks passed" || echo "RESULT ${SCENARIO}: some checks FAILED"
exit ${FAILED}
