#!/bin/bash
# Upgrade of the self-hosted Mozilla accounts in place (compose/fxa.yml): the stack
# starts on an older release, an account signs up, registers a device, gets a refresh
# token and syncs; then FXA_VERSION is changed in .env and the stack upgraded as docs/upgrading.md#self-hosted-accounts
# says (a backup, docker compose pull, docker compose up -d). Checked after: the
# migrations ran with the new image (the patch levels of its target-patch.json), the
# sign-up policy and the admin UI's procedures installed again over them, the old
# session, device and refresh token still work, the Sync data reads back, a new sign-in
# and a new sign-up work, the admin UI is all up and shows the new release
# (tests/test_fxa_upgrade.py).
#
# Usage: FXA_FROM=<image:tag> tests/fxa-upgrade.sh
# Environment:
#   FXA_FROM         the older accounts image, e.g.
#                    ghcr.io/porelli/firefox-sync:fxa-mono-v1.347.1 (our builds, amd64 and arm64)
#                    docker.io/mozilla/fxa-mono:v1.345.2 (Mozilla's, amd64 only: emulated elsewhere)
#   FXA_FROM_ARCH    its architecture (default: amd64 for Mozilla's image, this machine otherwise)
#   FXA_IMAGE, FXA_VERSION, FXA_ARCH  the release to upgrade to (default: REPOSITORY,
#                    fxa-mono-latest, this machine), as in tests/e2e-fxa.sh
#   REPOSITORY, TAG  syncstorage images (default: ghcr.io/porelli/firefox-sync, latest)
#   ADMIN_IMAGE      admin UI and sign-up policy image, used as is (default: built from admin/)
#   FXA_DB           mysql (default) or mariadb (FXA_MARIADB_IMAGE) for the accounts. MySQL: the
#                    install runs mysql:8 with mysql_native_password as those from before
#                    FXA_MYSQL_IMAGE did; the new files without these settings in .env: fxa-db
#                    refuses to upgrade its data (db/mysql/keep-major.sh), prepare_environment.sh
#                    --upgrade pins it back on mysql:8, then the accounts are upgraded
#   FXA_MYSQL_TO     with FXA_DB=mysql, after the upgrade of the accounts: the move of
#                    docs/upgrading.md#mysql-8-to-9 to this image (the users on caching_sha2_password,
#                    the native options dropped, a backup, the image); default: mysql:lts when the
#                    new accounts image has mozilla/fxa#21709, else none; keep: none
#   FXA_MARIADB_IMAGE with FXA_DB=mariadb (default: mariadb:11, as the installs from before
#                    MariaDB 12 have it; mariadb:lts (12) needs FXA_FROM with mozilla/fxa#21494)
#   FXA_MARIADB_FROM with FXA_DB=mariadb: the install starts on this MariaDB (e.g. mariadb:11)
#                    and the upgrade also moves it to FXA_MARIADB_IMAGE (default: mariadb:lts) as
#                    docs/upgrading.md#mariadb says: then the data must have been
#                    upgraded (server version, mariadb-upgrade by MARIADB_AUTO_UPGRADE). The new
#                    accounts image needs mozilla/fxa#21494 for MariaDB 12
#   FXA_SAME_TAG     set to 1 to install the older release under the new tag (FXA_FROM pulled and
#                    tagged FXA_IMAGE:FXA_VERSION here), as an install following fxa-mono-latest
#                    has it: then docker compose up -d alone must not upgrade, the pull must
#   SKIP_PULL        set to 1 to use the local images (the FxA images are pulled when missing;
#                    the docker compose pull of the upgrade runs anyway, as docs/upgrading.md#self-hosted-accounts says)
#   FXA_NEW_LOCAL    set to 1 when the new accounts image is a local build in no registry: the
#                    pull of the upgrade leaves it out
#   KEEP             set to 1 to leave the upgraded stack running (project ffs-fxa-upgrade)
#   SLOT             runs next to each other on one host (tests/slot.sh): 1, 2...: -s<SLOT> after
#                    the project, port 28663 + 1000 * SLOT, the others at 28700-28706 + 1000 * SLOT
#                    (FXA_SAME_TAG tags the shared FXA_IMAGE:FXA_VERSION: not next to other runs)
#   INIT_TAG         tag suffix of the init image (default: TAG)
set -u

TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CODE=$(dirname "${TESTS}")
# shellcheck source=tests/slot.sh
source "${TESTS}/slot.sh"
REPOSITORY=${REPOSITORY:-ghcr.io/porelli/firefox-sync}
TAG=${TAG:-latest}
INIT_TAG=${INIT_TAG:-${TAG}}
PROJECT=ffs-fxa-upgrade${SLOT_SUFFIX}
WORK=$(mktemp -d)
ENV_FILE=${WORK}/fxa.env
FXA_DB=${FXA_DB:-mysql}
[ -n "${FXA_FROM:-}" ] || { sed -n '12,28p' "$0"; exit 2; }
case "${FXA_DB}" in mysql|mariadb) ;; *) echo "FXA_DB: mysql or mariadb"; exit 2 ;; esac
# the MariaDB the install runs, and the one it moves to (FXA_MARIADB_FROM only)
MARIADB_TO=""
if [ -n "${FXA_MARIADB_FROM:-}" ]; then
  [ "${FXA_DB}" = mariadb ] || { echo "FXA_MARIADB_FROM is for FXA_DB=mariadb"; exit 2; }
  MARIADB_TO=${FXA_MARIADB_IMAGE:-mariadb:lts}
  [ "${MARIADB_TO}" != "${FXA_MARIADB_FROM}" ] || { echo "FXA_MARIADB_FROM: the same as FXA_MARIADB_IMAGE"; exit 2; }
fi
MARIADB_INSTALLED=${FXA_MARIADB_FROM:-${FXA_MARIADB_IMAGE:-mariadb:11}}
# MySQL: the installs from before (mysql:8, their users on mysql_native_password)
NATIVE_ARGS="--mysql-native-password=ON --authentication-policy=mysql_native_password"
case "$(uname -m)" in aarch64|arm64) native=arm64 ;; *) native=amd64 ;; esac
case "${FXA_FROM}" in
  docker.io/mozilla/*|mozilla/*) from_arch=${FXA_FROM_ARCH:-amd64} ;;
  *) from_arch=${FXA_FROM_ARCH:-${native}} ;;
esac
NEW_IMAGE=${FXA_IMAGE:-${REPOSITORY}} NEW_VERSION=${FXA_VERSION:-fxa-mono-latest} NEW_ARCH=${FXA_ARCH:-${native}}
NEW=${NEW_IMAGE}:${NEW_VERSION}
if [ -n "${FXA_SAME_TAG:-}" ] && [ "${from_arch}" != "${NEW_ARCH}" ]; then
  echo "FXA_SAME_TAG: the older release must be for ${NEW_ARCH} too, not ${from_arch}"; exit 2
fi
# the image the install starts with: the older release, under the new tag with FXA_SAME_TAG
if [ -n "${FXA_SAME_TAG:-}" ]; then INSTALLED=${NEW}; else INSTALLED=${FXA_FROM}; fi

rnd() { tr -dc '[:alnum:]' < /dev/urandom 2> /dev/null | head -c 32; }
# the test stack of tests/e2e-fxa.sh (its proxy, mail catcher and host names), on the
# older release, with the admin UI (its own database users, as prepare_environment.sh
# sets them) and the backups
sed -e "s|<REPLACE_WITH_SOMETHING_SECURE>|RANDOM|" "${CODE}/.env-example" | while IFS= read -r line; do
  case "${line}" in *=RANDOM) echo "${line%RANDOM}$(rnd)" ;; *) echo "${line}" ;; esac
done | sed -e "s|^SYNC_PUBLIC_URL=.*|SYNC_PUBLIC_URL=https://sync.fxa.test|" \
    -e "s|^SYNC_EXPORT_PORT=.*|SYNC_EXPORT_PORT=127.0.0.1:$((28663 + SLOT_PORTS))|" \
    -e "s|^IMAGE_REPOSITORY=.*|IMAGE_REPOSITORY=${REPOSITORY}|" \
    -e "s|^SYNC_IMAGE_TAG=.*|SYNC_IMAGE_TAG=${TAG}|" \
    -e "s|^SYNC_INIT_IMAGE_TAG=.*|SYNC_INIT_IMAGE_TAG=${INIT_TAG}|" \
    -e "s|^FXA_EMAIL_DOMAIN=.*|FXA_EMAIL_DOMAIN=api.fxa.test|" \
    -e "s|^FXA_OAUTH_SERVER_URL=.*|FXA_OAUTH_SERVER_URL=http://fxa-auth:9000/v1|" \
    -e "s|^FXA_CONTENT_URL=.*|FXA_CONTENT_URL=https://accounts.fxa.test|" \
    -e "s|^FXA_AUTH_URL=.*|FXA_AUTH_URL=https://api.fxa.test|" \
    -e "s|^FXA_PROFILE_URL=.*|FXA_PROFILE_URL=https://profile.fxa.test|" \
    -e "s|^FXA_SMTP_HOST=.*|FXA_SMTP_HOST=mailpit|" \
    -e "s|^FXA_SMTP_PORT=.*|FXA_SMTP_PORT=1025|" \
    -e "s|^FXA_SMTP_USER=.*|FXA_SMTP_USER=test|" \
    -e "s|^FXA_SMTP_PASS=.*|FXA_SMTP_PASS=test|" \
    -e "s|^FXA_SMTP_SENDER=.*|FXA_SMTP_SENDER=\"Mozilla accounts <no-reply@fxa.test>\"|" \
    -e "s|^# COMPOSE_PROFILES=.*|COMPOSE_PROFILES=admin,backup|" \
    -e "s|^BACKUP_KEEP=.*|BACKUP_KEEP=1|" \
    -e "s|^ADMIN_DB_PASSWORD=.*|ADMIN_DB_PASSWORD=$(rnd)|" \
    -e "s|^FXA_SIGNUPS=.*|FXA_SIGNUPS=allowlist|" \
    -e "s|^FXA_SIGNUP_ALLOWLIST=.*|FXA_SIGNUP_ALLOWLIST=@example.com|" \
    -e "s|^FXA_DB=.*|FXA_DB=${FXA_DB}|" \
    -e "s|^# FXA_MARIADB_IMAGE=.*|FXA_MARIADB_IMAGE=${MARIADB_INSTALLED}|" \
    -e "s|^# FXA_MYSQL_IMAGE=.*|FXA_MYSQL_IMAGE=mysql:8|" \
    -e "s|^# FXA_MYSQL_ARGS=.*|FXA_MYSQL_ARGS=${NATIVE_ARGS}|" \
    -e "s|^FXA_IMAGE=.*|FXA_IMAGE=${INSTALLED%:*}|" \
    -e "s|^FXA_VERSION=.*|FXA_VERSION=${INSTALLED##*:}|" \
    -e "s|^FXA_ARCH=.*|FXA_ARCH=${from_arch}|" \
    -e "s|^PROXY=.*|PROXY=caddy|" \
    -e "s|^CADDY_ACME_CA=.*|CADDY_ACME_CA=internal|" \
    -e "/^COMPOSE_FILE=/d" > "${ENV_FILE}"
slot_fxa_ports "${ENV_FILE}"
# its proxy: the bundled Caddy (compose/caddy.yml) with the configuration prepare_environment.sh
# writes for this .env (setup/proxy.sh), its own CA, on the stack's network (tests/compose/proxy-caddy.yml)
FFS_PROXY_DIR=${WORK}/proxy
echo "FFS_PROXY_DIR=${FFS_PROXY_DIR}" >> "${ENV_FILE}"
(source "${CODE}/prepare_environment.sh" && SCRIPT_DIR=${CODE} ENV_READ=${ENV_FILE} COMPOSE_PROJECT_NAME=${PROJECT} && ffs_temp_init &&
  write_proxy compose render "${FFS_PROXY_DIR}" > /dev/null && proxy_routes compose && render_caddy network bundled > "${FFS_PROXY_DIR}/Caddyfile.network") &&
  chmod -R a+rX "${FFS_PROXY_DIR}" || { echo "FAIL: the configuration of the bundled Caddy"; exit 1; }
# the admin UI signs in with its password only here: no public address of its own (an install
# reaches it over an SSH tunnel), the tests at https://admin.fxa.test, a site of caddy.d/
printf 'admin.fxa.test {\n\treverse_proxy ffs-admin:8080\n}\n' > "${FFS_PROXY_DIR}/caddy.d/sites-test-admin.caddy" && chmod a+r "${FFS_PROXY_DIR}/caddy.d/sites-test-admin.caddy"
# the database images and options as the env file has them: not empty ones of the caller's
# environment (CI passes its matrix values, empty for the defaults), which compose would
# prefer to the file and which would hide its pins from db/mysql/keep-major.sh
export -n FXA_MYSQL_IMAGE FXA_MYSQL_ARGS FXA_MARIADB_IMAGE SYNC_MYSQL_IMAGE SYNC_POSTGRES_IMAGE 2> /dev/null
load_env "${ENV_FILE}"
if [ "${FXA_DB}" = mariadb ]; then
  DB_CLIENT=mariadb
else
  DB_CLIENT=mysql
fi
ADMIN_GIVEN=${ADMIN_IMAGE:-}
export ADMIN_IMAGE=${ADMIN_IMAGE:-ffs-admin:test}

dc() {
  docker compose -p "${PROJECT}" --env-file "${ENV_FILE}" -f "${CODE}/compose/sync.yml" -f "${CODE}/compose/sync-mariadb.yml" \
    -f "${CODE}/compose/fxa.yml" -f "${CODE}/compose/fxa-${FXA_DB}.yml" -f "${TESTS}/compose/fxa.yml" \
    -f "${CODE}/compose/caddy.yml" -f "${TESTS}/compose/proxy-caddy.yml" "$@"
}
FAILED=0
# compose prefers the environment to --env-file: change both
set_env() { sed -i "s|^$1=.*|$1=$2|" "${ENV_FILE}"; export "$1=$2"; }
check() { if [ "$1" = "$2" ]; then echo "PASS: $3"; else echo "FAIL: $3 (expected '$2', got '$1')"; FAILED=1; return 1; fi; }
state() { docker inspect -f "{{.State.$2}}" "$(dc ps -a -q "$1")" 2> /dev/null; }
image_of() { docker inspect -f '{{.Config.Image}}' "$(dc ps -a -q "$1")" 2> /dev/null; }
image_id_of() { docker inspect -f '{{.Image}}' "$(dc ps -a -q "$1")" 2> /dev/null; }
fxa_sql() { dc exec -T -e MYSQL_PWD="${FXA_MYSQL_PASSWORD}" fxa-db "${DB_CLIENT}" -uroot -sN -e "$1" 2> /dev/null; }
# the schema-patch-level of each accounts database, "fxa=201 fxa_oauth=40 ..."
levels() {
  for db in fxa fxa_oauth fxa_profile pushbox; do
    printf '%s=%s ' "${db}" "$(fxa_sql "SELECT value FROM ${db}.dbMetadata WHERE name = 'schema-patch-level'")"
  done | sed 's/ $//'
}
# the levels a release migrates to, from its own target-patch.json
target_levels() {
  for db in fxa fxa_oauth fxa_profile pushbox; do
    printf '%s=%s ' "${db}" "$(docker run --rm --platform "linux/$2" --entrypoint cat "$1" "/fxa/packages/db-migrations/databases/${db}/target-patch.json" 2> /dev/null |
      sed -n 's/.*"level": *\([0-9]*\).*/\1/p')"
  done | sed 's/ $//'
}
pull_missing() { docker image inspect "$1" > /dev/null 2>&1 || docker pull -q --platform "linux/$2" "$1" > /dev/null; }
pull_image() {
  if [ -n "${SKIP_PULL:-}" ]; then pull_missing "$1" "$2"; else docker pull -q --platform "linux/$2" "$1" > /dev/null; fi
}
# the release of an accounts image as fxa-auth's /__version__ says it, without the v:
# the label our builds set, else the version.json upstream's builds write (Mozilla's)
release_of() {
  local v
  v=$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$1" 2> /dev/null)
  case "${v}" in v[0-9]*|[0-9]*) ;; *)
    v=$(docker run --rm --platform "linux/$2" --entrypoint cat "$1" /fxa/packages/version.json 2> /dev/null |
      sed -n 's/.*"version": *"\([^"]*\)".*/\1/p') ;;
  esac
  echo "${v#v}"
}
# the services of the accounts image, the ones docker compose pull upgrades
FXA_SERVICES=(fxa-keys-owner fxa-migrations fxa-auth fxa-content fxa-profile fxa-profile-worker fxa-profile-static)

teardown() {
  if [ -n "${KEEP:-}" ]; then
    echo "keeping stack ${PROJECT} (env: ${ENV_FILE}): docker compose -p ${PROJECT} down -v"
    return
  fi
  echo "== teardown"
  dc down -v --remove-orphans > /dev/null 2>&1
  # FXA_SAME_TAG: the new release under its tag again, if the run stopped before the pull
  if [ -n "${FXA_SAME_TAG:-}" ] && [ -n "${new_id:-}" ] && [ "$(docker image inspect -f '{{.Id}}' "${NEW}" 2> /dev/null)" != "${new_id}" ]; then
    docker pull -q --platform "linux/${NEW_ARCH}" "${NEW}" > /dev/null
  fi
  rm -rf "${WORK}"
}
trap teardown EXIT

# waits for the accounts and Sync after an up, shows the logs when they do not start
wait_up() {
  for _ in $(seq 1 120); do
    [ "$(state fxa-content Health.Status)" = healthy ] && [ "$(state syncstorage Health.Status)" = healthy ] &&
      [ "$(state ffs-admin Health.Status)" = healthy ] && break
    [ "$(state fxa-migrations ExitCode)" != "" ] && [ "$(state fxa-migrations Status)" = exited ] && [ "$(state fxa-migrations ExitCode)" != 0 ] && break
    sleep 10
  done
  check "$(state fxa-migrations ExitCode)" 0 "$1: FxA database migrations"
  check "$(state fxa-policy ExitCode)" 0 "$1: sign-up policy"
  for s in fxa-auth fxa-content syncstorage ffs-admin; do
    check "$(state "${s}" Health.Status)" healthy "$1: ${s} healthy"
  done
  if [ "${FAILED}" != 0 ]; then
    for s in fxa-migrations fxa-policy fxa-auth fxa-content syncstorage ffs-admin; do echo "---- ${s}"; dc logs --tail 25 "${s}" 2>&1; done
    exit 1
  fi
}

# the Python tests of one phase (before, after; and what is said of it), in the syncstorage-rs
# image (PyFxA), the state kept in WORK
upgrade_tests() {
  mkdir -p "${WORK}/state"
  dc run --rm -T --no-deps --user root \
    -v "${TESTS}:/tests:ro" -v "${PROJECT}_caddy-ca:/caddy-ca:ro" -v "${WORK}/state:/state" \
    -e REQUESTS_CA_BUNDLE=/caddy-ca/root.crt \
    -e FXA_CONTENT_URL -e FXA_AUTH_URL -e FXA_PROFILE_URL -e SYNC_PUBLIC_URL -e MAILPIT_URL=http://mailpit:8025 \
    -e ADMIN_URL=https://admin.fxa.test -e ADMIN_PASSWORD -e FXA_UPGRADE_PHASE="$1" -e UPGRADE_STATE=/state/upgrade.json \
    -e FXA_NEW_VERSION="${new_release}" -e FXA_OLD_LEVELS="${old_levels:-}" -e FXA_NEW_LEVELS="${new_levels:-}" \
    -e FXA_NEW_DB_SERVER="${new_db_server:-}" \
    -e PYTHONPATH=/app:/app/tools:/tests -e PYTHONDONTWRITEBYTECODE=1 \
    --entrypoint /bin/sh syncstorage \
    -c "cd /app && $(pytest_sh /tests/test_fxa_upgrade.py)" < /dev/null
  check "$?" 0 "${2:-$1 the upgrade}: tests/test_fxa_upgrade.py"
}

echo "== ${PROJECT}: accounts ${FXA_FROM} (${from_arch}) -> ${NEW} (${NEW_ARCH}), on ${FXA_DB}${MARIADB_TO:+ ${MARIADB_INSTALLED} -> ${MARIADB_TO}}${FXA_SAME_TAG:+, the older release installed as ${NEW}}"
if [ -z "${ADMIN_GIVEN}" ]; then
  COMPOSE_BAKE=false one_at_a_time admin-build docker compose -p ffs-admin-build -f "${TESTS}/compose/admin-build.yml" build -q || { echo "FAIL: admin UI image built from admin/"; exit 1; }
fi
dc down -v --remove-orphans > /dev/null 2>&1
# both releases first, to know them: the admin UI must show the new one (a tag like
# fxa-mono-latest does not say which), and an older target would be a downgrade
# (with FXA_SAME_TAG pulled anyway: an earlier run may have left the older one under that tag)
if [ -n "${FXA_SAME_TAG:-}" ]; then
  docker pull -q --platform "linux/${NEW_ARCH}" "${NEW}" > /dev/null || { echo "FAIL: pull ${NEW}"; exit 1; }
else
  pull_image "${NEW}" "${NEW_ARCH}" || { echo "FAIL: pull ${NEW}"; exit 1; }
fi
pull_image "${FXA_FROM}" "${from_arch}" || { echo "FAIL: pull ${FXA_FROM}"; exit 1; }
new_release=$(release_of "${NEW}" "${NEW_ARCH}") old_release=$(release_of "${FXA_FROM}" "${from_arch}")
# docs/upgrading.md#mysql-8-to-9 after the upgrade: with an image that has mozilla/fxa#21709
MYSQL_TO=""
if [ "${FXA_DB}" = mysql ]; then
  MYSQL_TO=${FXA_MYSQL_TO:-}
  # shellcheck source=tests/fxa_fix.sh
  source "${TESTS}/fxa_fix.sh"
  if [ -z "${MYSQL_TO}" ] && fxa_image_fixed mozilla/fxa#21709 "${NEW}"; then
    MYSQL_TO=mysql:lts
  fi
  [ "${MYSQL_TO}" != keep ] || MYSQL_TO=""
  echo "accounts database: mysql:8 with mysql_native_password${MYSQL_TO:+, then ${MYSQL_TO} (docs/upgrading.md#mysql-8-to-9)}"
fi
echo "releases: ${old_release:-?} -> ${new_release:-?}"
[ -n "${new_release}" ] || { echo "FAIL: no release in ${NEW} (label org.opencontainers.image.version or /fxa/packages/version.json)"; exit 1; }
if [ -n "${old_release}" ] && [ "${old_release}" != "${new_release}" ] &&
  [ "$(printf '%s\n' "${old_release}" "${new_release}" | sort -V | tail -n 1)" = "${old_release}" ]; then
  echo "FAIL: ${NEW} (${new_release}) is older than ${FXA_FROM} (${old_release}): a downgrade, the migrations cannot be undone"
  exit 2
fi
[ -n "${SKIP_PULL:-}" ] || dc pull -q || exit 1
new_id=$(docker image inspect -f '{{.Id}}' "${NEW}")
old_id=$(docker image inspect -f '{{.Id}}' "${FXA_FROM}")
if [ -n "${FXA_SAME_TAG:-}" ]; then
  [ "${old_id}" != "${new_id}" ] || { echo "FAIL: FXA_SAME_TAG with the same image twice"; exit 2; }
  docker tag "${FXA_FROM}" "${NEW}"
fi
check "$(docker image inspect -f '{{.Architecture}}' "${INSTALLED}" 2> /dev/null)" "${from_arch}" "older release ${FXA_FROM} for ${from_arch}"
dc up -d > "${WORK}/up.log" 2>&1 || { echo "FAIL: compose up"; tail -10 "${WORK}/up.log"; }
echo "== waiting for the older release ${FXA_FROM}"
wait_up "older release"
old_levels=$(levels)
echo "schema levels of ${FXA_FROM}: ${old_levels}"
old_db_version=$(fxa_sql "SELECT VERSION()")
echo "accounts database: ${old_db_version}"
upgrade_tests before

if [ "${FXA_DB}" = mysql ]; then
  echo "== the new files with the .env of before FXA_MYSQL_IMAGE: fxa-db does not upgrade the data, --upgrade pins it"
  sed -i -e '/^FXA_MYSQL_IMAGE=/d' -e '/^FXA_MYSQL_ARGS=/d' "${ENV_FILE}"; unset FXA_MYSQL_IMAGE FXA_MYSQL_ARGS
  dc up -d --no-deps fxa-db > "${WORK}/up-unpinned.log" 2>&1
  for _ in $(seq 1 60); do dc logs fxa-db 2>&1 | grep -q 'keep-major.sh: ' && break; sleep 2; done
  # (said at each of its restarts)
  check "$(image_of fxa-db) $(dc logs fxa-db 2>&1 | grep -q 'keep-major.sh: this database is MySQL 8, the image is MySQL' && echo said)" "mysql:lts said" \
    "without FXA_MYSQL_IMAGE fxa-db on mysql:lts refuses the MySQL 8 data, and says why"
  UP=${WORK}/prepare && mkdir -p "${UP}" && cp -r "${CODE}/prepare_environment.sh" "${CODE}/setup" "${CODE}/.env-example" "${CODE}/db" "${UP}/" && mkdir -p "${UP}/config/fxa" && cp "${CODE}/config/fxa/fixed-in" "${UP}/config/fxa/" && cp "${ENV_FILE}" "${UP}/.env"
  # (the compose project of this test: its running containers publish their ports, not taken by another)
  (cd "${UP}" && COMPOSE_PROJECT_NAME=${PROJECT} ./prepare_environment.sh --upgrade) > "${WORK}/prepare-upgrade.log" 2>&1
  check "$? $(grep '^FXA_MYSQL_IMAGE=' "${UP}/.env") [$(sed -n 's/^FXA_MYSQL_ARGS=//p' "${UP}/.env")] $(grep -c 'stays on MySQL 8 with mysql_native_password' "${WORK}/prepare-upgrade.log")" \
    "0 FXA_MYSQL_IMAGE=mysql:8 [${NATIVE_ARGS}] 1" "prepare_environment.sh --upgrade pins the accounts on MySQL 8 with mysql_native_password"
  cp "${UP}/.env" "${ENV_FILE}"
  load_env "${ENV_FILE}"
  dc up -d --no-deps fxa-db > "${WORK}/up-pinned.log" 2>&1
  for _ in $(seq 1 60); do [ "$(state fxa-db Health.Status)" = healthy ] && break; sleep 2; done
  check "$(state fxa-db Health.Status) $(fxa_sql "SELECT VERSION()")" "healthy ${old_db_version}" "fxa-db back on mysql:8, its data as it was"
fi

echo "== upgrade as docs/upgrading.md#self-hosted-accounts says: a backup, FXA_VERSION in .env, docker compose pull, docker compose up -d"
dc exec -T backup-fxa sh /ffs-backup/backup.sh now > "${WORK}/backup.log" 2>&1
check "$?" 0 "a backup of the accounts before the upgrade"
set_env FXA_IMAGE "${NEW_IMAGE}"
set_env FXA_VERSION "${NEW_VERSION}"
set_env FXA_ARCH "${NEW_ARCH}"
# docs/upgrading.md#mariadb: the backup above, FXA_MARIADB_IMAGE, pull and up
[ -z "${MARIADB_TO}" ] || set_env FXA_MARIADB_IMAGE "${MARIADB_TO}"
if [ -n "${FXA_SAME_TAG:-}" ]; then
  # docs/upgrading.md#self-hosted-accounts: up -d alone keeps the image it has under that tag
  dc up -d > "${WORK}/up-no-pull.log" 2>&1 || { echo "FAIL: compose up without a pull"; tail -10 "${WORK}/up-no-pull.log"; }
  check "$(image_id_of fxa-migrations) $(image_id_of fxa-auth)" "${old_id} ${old_id}" \
    "docker compose up -d without a pull keeps the older release"
fi
migrations_before=$(state fxa-migrations StartedAt)
# the pull of docs/upgrading.md#self-hosted-accounts, also with SKIP_PULL: the accounts image only (the admin UI under test
# may be a local build)
MARIADB_SERVICES=()
[ -z "${MARIADB_TO}" ] || MARIADB_SERVICES=(fxa-db backup-fxa)
# (FXA_NEW_LOCAL: a local build, in no registry: the accounts image as it is)
PULLED=("${FXA_SERVICES[@]}")
[ -z "${FXA_NEW_LOCAL:-}" ] || PULLED=()
[ $((${#PULLED[@]} + ${#MARIADB_SERVICES[@]})) = 0 ] ||
  dc pull -q "${PULLED[@]}" "${MARIADB_SERVICES[@]}" || { echo "FAIL: docker compose pull of ${NEW}"; exit 1; }
dc up -d > "${WORK}/upgrade.log" 2>&1 || { echo "FAIL: compose up with the new release"; tail -10 "${WORK}/upgrade.log"; }
echo "== waiting for the new release"
wait_up "upgraded"
[ -z "${MARIADB_TO}" ] || errors_since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for s in fxa-migrations fxa-auth fxa-content fxa-profile fxa-profile-worker; do
  check "$(image_of "${s}") $(image_id_of "${s}")" "${NEW} ${new_id}" "${s} runs the new release"
done
check "$([ "$(state fxa-migrations StartedAt)" \> "${migrations_before}" ] && echo yes)" yes "the migrations ran again"
check "$([ "$(state fxa-policy StartedAt)" \> "$(state fxa-migrations StartedAt)" ] && echo yes)" yes "the sign-up policy was installed again after them"
new_levels=$(levels)
echo "schema levels of ${NEW_VERSION}: ${new_levels}"
check "${new_levels}" "$(target_levels "${NEW}" "${NEW_ARCH}")" "the patch levels of the new release's target-patch.json"
check "$(fxa_sql "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = 'ffs' AND ROUTINE_DEFINITION LIKE '%missing from the accounts database%'")" 0 \
  "no account procedure of the admin UI replaced by a stand-in after the migrations"
check "$(fxa_sql "SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_name = 'ffs_signup_policy'")" 1 "the sign-up policy trigger after the migrations"
if [ -n "${MARIADB_TO}" ]; then
  new_db_version=$(fxa_sql "SELECT VERSION()")
  echo "accounts database: ${old_db_version} -> ${new_db_version}"
  check "$(image_of fxa-db) $(image_of backup-fxa)" "${MARIADB_TO} ${MARIADB_TO}" "fxa-db (and its backups) on ${MARIADB_TO}"
  check "$([ "${old_db_version%%.*}" != "${new_db_version%%.*}" ] && [ "$(printf '%s\n' "${old_db_version}" "${new_db_version}" | sort -V | tail -n 1)" = "${new_db_version}" ] && echo yes)" yes \
    "the accounts database on a newer major version (${old_db_version%%-*} -> ${new_db_version%%-*})"
  # the entrypoint ran mariadb-upgrade (MARIADB_AUTO_UPGRADE) and recorded the new version
  check "$(dc logs fxa-db 2>&1 | grep -c 'Finished mariadb-upgrade') $(dc exec -T fxa-db cat /var/lib/mysql/mariadb_upgrade_info 2> /dev/null | tr -d '\0' | grep -c "^${new_db_version%%-*}")" "1 1" \
    "mariadb-upgrade ran at the first start on ${MARIADB_TO} (MARIADB_AUTO_UPGRADE)"
  new_db_server="MariaDB ${new_db_version%%-*}"
  new_db_server=${new_db_server//./\\.}
fi
upgrade_tests after
if [ -n "${MYSQL_TO}" ]; then
  echo "== docs/upgrading.md#mysql-8-to-9: 2. the users on caching_sha2_password"
  native_users() { fxa_sql "SELECT CONCAT(user, '@', host) FROM mysql.user WHERE plugin = 'mysql_native_password' ORDER BY 1" | paste -sd' '; }
  # ffs_admin: fxa-policy gives it caching_sha2_password itself
  check "$(native_users)" "root@% root@localhost" "on mysql_native_password: root (FXA_MYSQL_USER) only"
  fxa_sql "ALTER USER 'root'@'%' IDENTIFIED WITH caching_sha2_password BY '${FXA_MYSQL_PASSWORD}';
    ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '${FXA_MYSQL_PASSWORD}'" > /dev/null
  check "$? [$(native_users)]" "0 []" "every user on caching_sha2_password"
  echo "== 3. FXA_MYSQL_ARGS removed, fxa-db restarted on MySQL 8 without mysql_native_password"
  sed -i '/^FXA_MYSQL_ARGS=/d' "${ENV_FILE}"; unset FXA_MYSQL_ARGS
  dc up -d > "${WORK}/up-no-native.log" 2>&1 || { echo "FAIL: compose up without mysql_native_password"; tail -10 "${WORK}/up-no-native.log"; }
  wait_up "without mysql_native_password"
  check "$(fxa_sql "SELECT @@authentication_policy") $(fxa_sql "SELECT COUNT(*) FROM information_schema.plugins WHERE plugin_name = 'mysql_native_password' AND plugin_status = 'ACTIVE'")" "*,, 0" \
    "fxa-db on the server's defaults (caching_sha2_password)"
  upgrade_tests after "after the upgrade, without mysql_native_password"
  echo "== 4. a backup, FXA_MYSQL_IMAGE=${MYSQL_TO}, docker compose pull, docker compose up -d"
  dc exec -T backup-fxa sh /ffs-backup/backup.sh now >> "${WORK}/backup.log" 2>&1
  check "$?" 0 "a backup of the accounts before ${MYSQL_TO}"
  sed -i '/^FXA_MYSQL_IMAGE=/d' "${ENV_FILE}"; printf 'FXA_MYSQL_IMAGE=%s\n' "${MYSQL_TO}" >> "${ENV_FILE}"
  export FXA_MYSQL_IMAGE=${MYSQL_TO}
  dc pull -q fxa-db backup-fxa || { echo "FAIL: docker compose pull of ${MYSQL_TO}"; exit 1; }
  dc up -d > "${WORK}/up-mysql-lts.log" 2>&1 || { echo "FAIL: compose up on ${MYSQL_TO}"; tail -10 "${WORK}/up-mysql-lts.log"; }
  wait_up "on ${MYSQL_TO}"
  errors_since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  new_db_version=$(fxa_sql "SELECT VERSION()")
  echo "accounts database: ${old_db_version} -> ${new_db_version}"
  check "$(image_of fxa-db) $(dc --profile backup config 2> /dev/null | sed -n '/^  backup-fxa:/,/^  [a-z]/p' | sed -n 's/^ *image: //p')" "${MYSQL_TO} ${MYSQL_TO}" "fxa-db (and its backups) on ${MYSQL_TO}"
  check "$([ "${old_db_version%%.*}" != "${new_db_version%%.*}" ] && [ "$(printf '%s\n' "${old_db_version}" "${new_db_version}" | sort -V | tail -n 1)" = "${new_db_version}" ] && echo yes)" yes \
    "the accounts database on a newer major version (${old_db_version} -> ${new_db_version})"
  check "$(dc exec -T fxa-db cat /var/lib/mysql/mysql_upgrade_history 2> /dev/null | grep -o '"version":"[^"]*"' | tail -n 1)" "\"version\":\"${new_db_version}\"" \
    "MySQL upgraded the data in place at the first start on ${MYSQL_TO}"
  check "[$(native_users)] $(fxa_sql "SELECT plugin FROM mysql.user WHERE user = 'ffs_admin'")" "[] caching_sha2_password" "no user on mysql_native_password on ${MYSQL_TO}"
  new_db_server="MySQL ${new_db_version}"
  new_db_server=${new_db_server//./\\.}
  upgrade_tests after "after the upgrade, on ${MYSQL_TO}"
  dc exec -T backup-fxa sh /ffs-backup/backup.sh now >> "${WORK}/backup.log" 2>&1
  check "$?" 0 "a backup of the accounts on ${MYSQL_TO}"
fi
# with FXA_MARIADB_FROM the database restarted on its new version during the up: the admin UI's
# errors of then (the accounts database unreachable) are expected, the ones after it are not
admin_errors() { dc logs ${errors_since:+--since "${errors_since}"} ffs-admin 2>&1 | grep -E '(pruning|metrics|event log|database size|schema levels|rendering [^:]*): '; }
check "$(admin_errors | wc -l)" 0 "no background errors in the admin UI logs"
admin_errors | tail -5
[ "${FAILED}" = 0 ] || for s in fxa-migrations fxa-auth syncstorage; do echo "---- ${s}"; dc logs --tail 30 "${s}" 2>&1; done

[ ${FAILED} = 0 ] && echo "RESULT fxa-upgrade: all checks passed" || echo "RESULT fxa-upgrade: some checks FAILED"
exit ${FAILED}
