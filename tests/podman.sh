#!/bin/bash
# Rootless podman test: docker compose on the Podman socket (MariaDB and PostgreSQL) and
# quadlets (MariaDB), set up with prepare_environment.sh exactly like a user would.
# Needs rootless podman, docker compose (v2, no Docker daemon) and a systemd user session.
#
# Usage: tests/podman.sh
# Environment:
#   REPOSITORY  image repository (default: ghcr.io/porelli/firefox-sync)
#   TAG         tag suffix of both the app and init images (default: latest)
#   PORT        host port (default: 28660)
set -u

TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CODE=$(dirname "${TESTS}")
REPOSITORY=${REPOSITORY:-ghcr.io/porelli/firefox-sync}
TAG=${TAG:-latest}
PORT=${PORT:-28660}
WORK=$(mktemp -d)
export QUADLET_DIR=${WORK}/quadlets-unused  # replaced below for the quadlet phase
FAILED=0

check() { if [ "$1" = "$2" ]; then echo "PASS: $3"; else echo "FAIL: $3 (expected '$2', got '$1')"; FAILED=1; fi; }
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

# a copy of the repository, configured by prepare_environment.sh
cp -r "${CODE}" "${WORK}/ffs" && cd "${WORK}/ffs" || exit 1
rm -f .env
sed -i -e "s|^REPOSITORY=.*|REPOSITORY=${REPOSITORY}|" \
       -e "s|^SYNCSTORAGE_INIT_IMAGE_TAG=.*|SYNCSTORAGE_INIT_IMAGE_TAG=${TAG}|" .env-example
# answers: domain, compose dir, port, max users, backend, deploy method, user, image tag
setup() { printf '%s\n' ffs-e2e.invalid "" "${PORT}" 1 "$1" "$2" "" "${TAG}" | ./prepare_environment.sh > "setup-$1-$2.log" 2>&1; }

compose_test() {
  local backend=$1; shift
  echo "== docker compose on the Podman socket (${backend})"
  setup "${backend}" 2
  check "$?" 0 "prepare_environment.sh (${backend}, compose)"
  check "$(grep -c "docker compose $* up -d" "setup-${backend}-2.log")" 1 "prepare_environment.sh prints the compose command (${backend})"
  timeout 600 docker compose "$@" up -d > "compose-${backend}.log" 2>&1
  check "$?" 0 "docker compose up (${backend})"
  check "$(hb)" 200 "/__heartbeat__ (compose, ${backend})"
  check "$(podman inspect -f '{{.State.ExitCode}}' "$(ctr syncstorage_migrate)")" 0 "migrate container exit code (${backend})"
  check "$(podman inspect -f '{{.State.ExitCode}}' "$(ctr tokenserver_db_init)")" 0 "init container exit code (${backend})"
  check "$([ "$(started "$(ctr syncstorage)" StartedAt)" -gt "$(started "$(ctr tokenserver_db_init)" FinishedAt)" ] && echo yes)" yes \
    "syncstorage started after the init (compose, ${backend})"
  podman logs "$(ctr tokenserver_db_init)" 2>&1 | grep -E "Max users|ERROR"
  [ "${FAILED}" = 0 ] || diagnose "compose-${backend}.log"
  docker compose "$@" down -v > /dev/null 2>&1
}
compose_test mariadb -f docker-compose.yml -f docker-compose.podman.yml
compose_test postgres -f docker-compose.postgres.yml

echo "== quadlets (mariadb)"
export QUADLET_DIR=${HOME}/.config/containers/systemd
setup mariadb 1
check "$?" 0 "prepare_environment.sh (quadlets)"
check "$(grep -l '%[A-Z_]*%' "${QUADLET_DIR}"/firefox-sync-* | wc -l)" 0 "no unreplaced placeholders in quadlets"
QUADLET=$(ls /usr/libexec/podman/quadlet /usr/lib/podman/quadlet 2> /dev/null | head -1)
"${QUADLET}" -dryrun -user > quadlet-dryrun.log 2>&1
check "$?" 0 "quadlet generator accepts the files"
timeout 900 systemctl --user start firefox-sync-syncstorage.service
check "$?" 0 "systemctl --user start firefox-sync-syncstorage.service"
for u in syncstorage-db tokenserver-db syncstorage-migrate tokenserver-db-init syncstorage; do
  printf '  %-22s %s\n' "${u}" "$(systemctl --user is-active "firefox-sync-${u}.service")"
done
check "$(hb)" 200 "/__heartbeat__ (quadlets)"
journalctl --user -u firefox-sync-syncstorage-migrate.service --no-pager 2> /dev/null | grep -m1 "Migrations completed"
journalctl --user -u firefox-sync-tokenserver-db-init.service --no-pager 2> /dev/null | grep -m1 "Max users"
INIT_END=$(systemctl --user show -p ExecMainExitTimestampMonotonic --value firefox-sync-tokenserver-db-init.service)
APP_START=$(systemctl --user show -p ExecMainStartTimestampMonotonic --value firefox-sync-syncstorage.service)
check "$([ "${APP_START}" -gt "${INIT_END}" ] && echo yes)" yes "syncstorage started after the init (quadlets)"
if [ "${FAILED}" != 0 ]; then
  tail -20 quadlet-dryrun.log
  journalctl --user -u 'firefox-sync-*' --no-pager | tail -60
  diagnose
fi

echo "== cleanup"
systemctl --user stop firefox-sync-syncstorage.service firefox-sync-tokenserver-db-init.service \
  firefox-sync-syncstorage-migrate.service firefox-sync-syncstorage-db.service firefox-sync-tokenserver-db.service 2> /dev/null
rm -f "${QUADLET_DIR}"/firefox-sync-*
systemctl --user daemon-reload
podman volume rm -f firefox-sync-syncstorage-db firefox-sync-tokenserver-db > /dev/null 2>&1
rm -rf "${WORK}"

[ ${FAILED} = 0 ] && echo "RESULT podman: all checks passed" || echo "RESULT podman: some checks FAILED"
exit ${FAILED}
