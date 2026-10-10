#!/bin/bash
# End-to-end test of the firefox-sync stack (docker compose), isolated from anything
# else running on the host: own compose project, loopback-only port, own volumes.
#
# Usage: tests/e2e.sh <mysql|postgres>
# Environment:
#   REPOSITORY      image repository (default: ghcr.io/porelli/firefox-sync)
#   TAG             tag suffix of both the app and init images (default: latest)
#   PORT            host port, bound to 127.0.0.1 (default: 28651 mysql, 28652 postgres)
#   CLEANUP_IMAGES  set to 1 to remove the pulled images at the end
#   KEEP            set to 1 to leave the stack running
set -u

BACKEND=${1:?usage: $0 <mysql|postgres>}
TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CODE=$(dirname "${TESTS}")
REPOSITORY=${REPOSITORY:-ghcr.io/porelli/firefox-sync}
TAG=${TAG:-latest}
PROJECT=ffs-e2e-${BACKEND}
WORK=$(mktemp -d)
ENV_FILE=${WORK}/${BACKEND}.env

case ${BACKEND} in
  mysql)    COMPOSE=${CODE}/docker-compose.yml;          PORT=${PORT:-28651} ;;
  postgres) COMPOSE=${CODE}/docker-compose.postgres.yml; PORT=${PORT:-28652} ;;
  *) echo "unknown backend ${BACKEND}"; exit 2 ;;
esac

rnd() { tr -dc '[:alnum:]' < /dev/urandom | head -c 24; }
MASTER_SECRET=$(rnd)
# upstream's tokenserver tests expect the stage FxA email domain, the mock FxA
# server and the metrics hash secret to be the master secret
sed -e "s|^MARIADB_TOKENSERVER_PASSWORD=.*|MARIADB_TOKENSERVER_PASSWORD=$(rnd)|" \
    -e "s|^MARIADB_SYNCSTORAGE_PASSWORD=.*|MARIADB_SYNCSTORAGE_PASSWORD=$(rnd)|" \
    -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$(rnd)|" \
    -e "s|^SYNC_MASTER_SECRET=.*|SYNC_MASTER_SECRET=${MASTER_SECRET}|" \
    -e "s|^METRICS_HASH_SECRET=.*|METRICS_HASH_SECRET=${MASTER_SECRET}|" \
    -e "s|^SYNCSTORAGE_DOMAIN=.*|SYNCSTORAGE_DOMAIN=https://ffs-e2e.invalid|" \
    -e "s|^CONTAINER_EXPORT_PORT=.*|CONTAINER_EXPORT_PORT=127.0.0.1:${PORT}|" \
    -e "s|^MAX_USERS=.*|MAX_USERS=1|" \
    -e "s|^REPOSITORY=.*|REPOSITORY=${REPOSITORY}|" \
    -e "s|^SYNCSTORAGE_IMAGE=.*|SYNCSTORAGE_IMAGE=syncstorage-rs-${BACKEND}|" \
    -e "s|^SYNCSTORAGE_INIT_IMAGE=.*|SYNCSTORAGE_INIT_IMAGE=syncstorage-rs-${BACKEND}-init|" \
    -e "s|^SYNCSTORAGE_IMAGE_TAG=.*|SYNCSTORAGE_IMAGE_TAG=${TAG}|" \
    -e "s|^SYNCSTORAGE_INIT_IMAGE_TAG=.*|SYNCSTORAGE_INIT_IMAGE_TAG=${TAG}|" \
    -e "s|^FXA_EMAIL_DOMAIN=.*|FXA_EMAIL_DOMAIN=api-accounts.stage.mozaws.net|" \
    -e "s|^FXA_OAUTH_SERVER_URL=.*|FXA_OAUTH_SERVER_URL=http://mock_fxa:6000|" \
    -e "/^COMPOSE_FILE=/d" \
    "${CODE}/.env-example" > "${ENV_FILE}"
set -a; source "${ENV_FILE}"; set +a

dc() { docker compose -p "${PROJECT}" -f "${COMPOSE}" -f "${TESTS}/docker-compose.test.yml" --env-file "${ENV_FILE}" "$@"; }
FAILED=0
check() { if [ "$1" = "$2" ]; then echo "PASS: $3"; else echo "FAIL: $3 (expected '$2', got '$1')"; FAILED=1; fi; }
state() { docker inspect -f "{{.State.$2}}" "$(dc ps -a -q "$1")" 2> /dev/null; }
hb() {
  local c
  for _ in $(seq 1 60); do
    c=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/__heartbeat__")
    [ "${c}" = 200 ] && break
    sleep 1
  done
  echo "${c}"
}
wait_init() { timeout 300 docker wait "$(dc ps -a -q tokenserver_db_init)"; }
# set a value in the env file and in this shell (the shell environment wins over --env-file)
set_env() { sed -i "s|^$1=.*|$1=$2|" "${ENV_FILE}"; export "$1=$2"; }

sql() {
  if [ "${BACKEND}" = mysql ]; then
    dc exec -T tokenserver_db mariadb -u"${MARIADB_TOKENSERVER_USER}" -p"${MARIADB_TOKENSERVER_PASSWORD}" "${MARIADB_TOKENSERVER_DATABASE}" -sN -e "$1" < /dev/null
  else
    dc exec -T postgres_db psql -U "${POSTGRES_USER}" -d "${POSTGRES_DATABASE}" -tA -c "$1" < /dev/null
  fi
}

# run a command in a one-off container of the app image, on the stack network
in_app() {
  dc run --rm -T --no-deps --user root \
    -v "${TESTS}:/tests:ro" \
    -e SYNC_SERVER_URL=http://syncstorage:8000 \
    -e TOKENSERVER_HOST=http://syncstorage:8000 \
    -e SYNC_MASTER_SECRET="${MASTER_SECRET}" \
    -e SYNCSTORAGE_DOMAIN="${SYNCSTORAGE_DOMAIN}" \
    -e MAX_USERS="${MAX_USERS}" \
    -e PYTHONPATH=/app:/app/tools \
    -e PYTHONDONTWRITEBYTECODE=1 \
    --entrypoint /bin/sh syncstorage -c "cd /app && $1" < /dev/null
}
pytest_in_app() { in_app "python3 -m pytest -q -p no:cacheprovider $1 > /tmp/pytest.log 2>&1; rc=\$?; tail -25 /tmp/pytest.log; exit \$rc"; }

teardown() {
  [ -n "${KEEP:-}" ] && { echo "keeping stack ${PROJECT} (env: ${ENV_FILE})"; return; }
  echo "== teardown"
  dc down -v --remove-orphans > /dev/null 2>&1
  if [ -n "${CLEANUP_IMAGES:-}" ]; then
    docker rmi "${REPOSITORY}:syncstorage-rs-${BACKEND}-${TAG}" "${REPOSITORY}:syncstorage-rs-${BACKEND}-init-${TAG}" > /dev/null 2>&1
    [ "${BACKEND}" = mysql ] && ! docker ps -a --format '{{.Image}}' | grep -qx 'mariadb:lts' && docker rmi mariadb:lts > /dev/null 2>&1
  fi
  rm -rf "${WORK}"
}
trap teardown EXIT

echo "== ${PROJECT}: pulling ${REPOSITORY} ${TAG}"
dc pull -q || exit 1

echo "== fail closed: a failing init must keep syncstorage down"
printf 'services:\n  tokenserver_db_init:\n    entrypoint: ["/bin/false"]\n' > "${WORK}/fail-init.yml"
dc -f "${WORK}/fail-init.yml" up -d > /dev/null 2>&1
check "$(state syncstorage_migrate ExitCode)" 0 "migrations completed"
check "$(state syncstorage Running || echo false)" false "syncstorage not started when init fails"
check "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/__heartbeat__")" 000 "port not reachable when init fails"
dc down -v > /dev/null 2>&1

echo "== starting"
dc up -d > /dev/null 2>&1 || { dc logs; exit 1; }
check "$(wait_init)" 0 "init container exit code"
check "$(state syncstorage_migrate ExitCode)" 0 "migrate container exit code"
INIT_END=$(date -d "$(state tokenserver_db_init FinishedAt)" +%s%N)
APP_START=$(date -d "$(state syncstorage StartedAt)" +%s%N)
check "$([ "${APP_START}" -gt "${INIT_END}" ] && echo yes)" yes "syncstorage started only after the init finished"
check "$(hb)" 200 "/__heartbeat__"
dc logs syncstorage 2>&1 | grep -m1 "Server running"

echo "== tokenserver node"
SVC=$(sql "SELECT id FROM services WHERE service='sync-1.5';")
echo "sync-1.5 service id: ${SVC}"
check "$(sql "SELECT COUNT(*) FROM nodes WHERE service=${SVC} AND node='${SYNCSTORAGE_DOMAIN}' AND available>0 AND downed=0;")" 1 "node for ${SYNCSTORAGE_DOMAIN} attached to sync-1.5"
NODE=$(sql "SELECT id FROM nodes WHERE service=${SVC} AND node='${SYNCSTORAGE_DOMAIN}';")

echo "== MAX_USERS=1 trigger (database level)"
ins() { sql "INSERT INTO users (service, email, generation, client_state, created_at, nodeid) VALUES (${SVC}, '$1', $2, '$3', 1, ${NODE});" > /dev/null 2>&1 && echo ok || echo rejected; }
check "$(ins a@ffs-e2e.invalid 1 aa)" ok "first account allowed"
check "$(ins a@ffs-e2e.invalid 2 bb)" ok "same account with new client state allowed"
check "$(ins b@ffs-e2e.invalid 1 aa)" rejected "second account rejected"

echo "== domain change"
OLD_DOMAIN=${SYNCSTORAGE_DOMAIN}
NEW_DOMAIN=https://ffs-e2e-new.invalid
redeploy() { set_env SYNCSTORAGE_DOMAIN "$1"; dc up -d > /dev/null 2>&1; wait_init > /dev/null; }
node_of_user() { sql "SELECT DISTINCT n.node FROM users u JOIN nodes n ON u.nodeid = n.id WHERE u.email = 'a@ffs-e2e.invalid';"; }
active_nodes() { sql "SELECT node FROM nodes WHERE service=${SVC} AND downed=0 AND available>0 ORDER BY node;" | tr '\n' ' '; }
redeploy "${NEW_DOMAIN}"
check "$(active_nodes)" "${NEW_DOMAIN} " "only the new domain is in rotation"
check "$(node_of_user)" "${NEW_DOMAIN}" "users moved to the new domain"
redeploy "${OLD_DOMAIN}"
check "$(active_nodes)" "${OLD_DOMAIN} " "switching back re-enables the old node"
check "$(node_of_user)" "${OLD_DOMAIN}" "users moved back"
check "$(hb)" 200 "/__heartbeat__ after redeploy"
sql "DELETE FROM users;" > /dev/null

echo "== client flow through the tokenserver (mock FxA), MAX_USERS=1"
pytest_in_app /tests/test_client_flow.py
check "$?" 0 "client flow tests"

echo "== upstream storage integration tests"
pytest_in_app tools/integration_tests/test_storage.py
check "$?" 0 "upstream storage tests"

echo "== errors in syncstorage logs"
check "$(dc logs syncstorage 2>&1 | grep -ciE 'panicked|"status":5[0-9][0-9]')" 0 "no panics or 5xx in syncstorage logs"

echo "== upstream tokenserver integration tests (MAX_USERS raised, they create many users)"
set_env MAX_USERS 1000000
dc up -d > /dev/null 2>&1
check "$(wait_init)" 0 "init container exit code (MAX_USERS=1000000)"
hb > /dev/null
# test_e2e.py needs real accounts on Mozilla's FxA stage environment
UPSTREAM_TS="tools/integration_tests/tokenserver --ignore=tools/integration_tests/tokenserver/test_e2e.py"
if [ "${BACKEND}" = mysql ]; then
  # with several empty nodes the tokenserver orders them by LOG(0) (NULL), MySQL 8
  # (upstream CI) returns them in id order, MariaDB does not: this stack has one node
  # (node ids are relative to tools/integration_tests, pytest's rootdir in the image)
  T=test_node_assignment.py::test_user_creation
  UPSTREAM_TS="${UPSTREAM_TS} --deselect tokenserver/${T} --deselect tools/integration_tests/tokenserver/${T}"
fi
pytest_in_app "${UPSTREAM_TS}"
check "$?" 0 "upstream tokenserver tests"

[ ${FAILED} = 0 ] && echo "RESULT ${BACKEND}: all checks passed" || echo "RESULT ${BACKEND}: some checks FAILED"
exit ${FAILED}
