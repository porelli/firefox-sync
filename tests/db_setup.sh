#!/bin/bash
# db/db-setup.sh (db-bootstrap, fxa-db-bootstrap) against database servers of its own, what
# the e2e tests do not reach: what the bootstrap account refuses to touch, and what the
# check reports (docs/databases.md#let-the-stack-apply-them, #when-a-release-needs-new-users-or-grants).
#
# Usage: tests/db_setup.sh <mysql|mariadb|postgres>...   (tests/e2e.sh runs it with EXTERNAL_DB=1)
#   - the bootstrap with the account of db/<engine>/bootstrap.sql: applied, run again, checked;
#   - a reserved name (root, postgres) or the bootstrap's own as a stack user: refused;
#   - a user (role) of a stack name that exists and is not the stack's (another password):
#     refused, its password and grants as they were;
#   - a bootstrap account that is an administrator (MySQL SYSTEM_USER, MariaDB SUPER,
#     PostgreSQL a superuser): refused;
#   - PostgreSQL: a database of the stack's name owned by another role: the bootstrap and
#     database-setup.sql run by hand stop, its owner as it was; the check reports a grant on
#     the stack's database to another role and a table there of another role.
# Environment: SLOT (tests/slot.sh: the names), MYSQL_IMAGE (mysql:lts), MARIADB_IMAGE (mariadb:lts),
#   POSTGRES_IMAGE (postgres:latest)
set -u
TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CODE=$(dirname "${TESTS}")
# shellcheck source=tests/slot.sh
source "${TESTS}/slot.sh"
FAILED=0
check() { if [ "$1" = "$2" ]; then echo "PASS: $3"; else echo "FAIL: $3 (expected '$2', got '$1')"; FAILED=1; fi; }
rnd() { tr -dc '[:alnum:]' < /dev/urandom | head -c 20; }
NAME=ffs-db-setup${SLOT_SUFFIX}
cleanup() { docker rm -f "${NAME}" > /dev/null 2>&1; docker network rm "${NAME}" > /dev/null 2>&1; rm -rf "${WORK:-}"; }
trap cleanup EXIT
WORK=$(mktemp -d)

# the stack's settings, db-setup.sh's environment (a file: no password on a command line)
stack_env() {
  local engine=$1
  {
    echo "SYNC_DB_CONTAINERS=0"
    echo "ADMIN_DB_NAME=ffs_admin"; echo "ADMIN_DB_USER=ffs_admin_ui"; echo "ADMIN_DB_SYNC_USER=ffs_admin_sync"; echo "ADMIN_DB_PASSWORD=${ADMIN_PW}"
    if [ "${engine}" = postgres ]; then
      echo "FFS_DB_ENGINE=postgres"; echo "SYNC_POSTGRES_HOST=${NAME}"; echo "SYNC_POSTGRES_PORT=5432"
      echo "SYNC_POSTGRES_NAME=syncserver"; echo "SYNC_POSTGRES_USER=syncserver"; echo "SYNC_POSTGRES_PASSWORD=${SYNC_PW}"
    else
      echo "SYNC_TOKENSERVER_DB_HOST=${NAME}"; echo "SYNC_TOKENSERVER_DB_PORT=3306"; echo "SYNC_DB_TLS_VERIFY=false"
      echo "SYNC_TOKENSERVER_DB_NAME=tokenserver"; echo "SYNC_TOKENSERVER_DB_USER=tokenserver"; echo "SYNC_TOKENSERVER_DB_PASSWORD=${SYNC_PW}"
      echo "SYNC_STORAGE_DB_NAME=syncstorage"; echo "SYNC_STORAGE_DB_USER=syncstorage"; echo "SYNC_STORAGE_DB_PASSWORD=${STORAGE_PW}"
    fi
  } > "${WORK}/stack.env"
}
# db_setup <image> [VAR=value...]: db-setup.sh sync in a client container on the server's network
db_setup() {
  local image=$1 template
  shift
  template=${CODE}/db/mysql/sync.sql
  [ "${ENGINE}" = postgres ] && template=${CODE}/db/postgres/sync.sql
  cp "${WORK}/stack.env" "${WORK}/run.env"
  printf '%s\n' "$@" >> "${WORK}/run.env"
  docker run --rm --network "${NAME}" --env-file "${WORK}/run.env" -v "${CODE}/db/db-setup.sh:/ffs-db/db-setup.sh:ro" \
    -v "${template}:/ffs-db/sync.sql:ro" --entrypoint bash "${image}" /ffs-db/db-setup.sh sync > "${WORK}/out.log" 2>&1
}
said() { grep -c -- "$1" "${WORK}/out.log"; }

for ENGINE in "$@"; do
  case "${ENGINE}" in
    mysql) IMAGE=${MYSQL_IMAGE:-mysql:lts} CLIENT=mysql ;;
    mariadb) IMAGE=${MARIADB_IMAGE:-mariadb:lts} CLIENT=mariadb ;;
    postgres) IMAGE=${POSTGRES_IMAGE:-postgres:latest} CLIENT=psql ;;
    *) echo "usage: $0 <mysql|mariadb|postgres>..."; exit 2 ;;
  esac
  echo "== db/db-setup.sh on ${IMAGE}"
  cleanup; WORK=$(mktemp -d)
  ROOT_PW=$(rnd) SYNC_PW=$(rnd) STORAGE_PW=$(rnd) ADMIN_PW=$(rnd) BOOT_PW=$(rnd) THEIRS=$(rnd)
  docker network create "${NAME}" > /dev/null || exit 1
  if [ "${ENGINE}" = postgres ]; then
    docker run -d --rm --name "${NAME}" --network "${NAME}" --tmpfs /var/lib/postgresql -e POSTGRES_PASSWORD="${ROOT_PW}" "${IMAGE}" > /dev/null || exit 1
    # SQL as the superuser, on stdin; as <role> <password> [database]
    admin() { docker exec -i -e PGPASSWORD="${ROOT_PW}" "${NAME}" psql -X -h 127.0.0.1 -U postgres -v ON_ERROR_STOP=1 -tA "$@"; }
    as() { docker exec -i -e PGPASSWORD="$2" "${NAME}" psql -X -h 127.0.0.1 -U "$1" -d "${3:-postgres}" -tA -c 'SELECT 1' < /dev/null 2>&1; }
    for _ in $(seq 1 60); do admin -c 'SELECT 1' < /dev/null > /dev/null 2>&1 && break; sleep 2; done
  else
    # (MySQL: binary logging, as docs/databases.md#server-requirements expects)
    server_args=()
    [ "${ENGINE}" = mysql ] && server_args=(--log-bin-trust-function-creators=ON)
    docker run -d --rm --name "${NAME}" --network "${NAME}" --tmpfs /var/lib/mysql -e MYSQL_ROOT_PASSWORD="${ROOT_PW}" "${IMAGE}" \
      ${server_args[@]+"${server_args[@]}"} > /dev/null || exit 1
    admin() { docker exec -i -e MYSQL_PWD="${ROOT_PW}" "${NAME}" "${CLIENT}" -uroot -h 127.0.0.1 --protocol=tcp -sN "$@"; }
    # (MariaDB's client warns that it checks no certificate)
    as() { docker exec -i -e MYSQL_PWD="$2" "${NAME}" "${CLIENT}" -u"$1" -h 127.0.0.1 --protocol=tcp -sN -e 'SELECT 1' < /dev/null 2>&1 | grep -v '^WARNING'; }
    for _ in $(seq 1 90); do admin -e 'SELECT 1' < /dev/null > /dev/null 2>&1 && break; sleep 2; done
  fi
  # the bootstrap account, as docs/databases.md#the-bootstrap-account says (db/<engine>/bootstrap.sql)
  boot_account() { # <name> <password>
    sed -e "s|@BOOTSTRAP_USER@|$1|g" -e "s|@BOOTSTRAP_PASSWORD@|$2|g" -e 's|@SYNC_TOKENSERVER_DATABASE@|tokenserver|g' \
      -e 's|@SYNC_STORAGE_DATABASE@|syncstorage|g' -e 's|@ADMIN_DATABASE@|ffs_admin|g' -e 's|@SYNC_POSTGRES_USER@|syncserver|g' \
      -e 's|@ADMIN_USER@|ffs_admin_ui|g' -e 's|@ADMIN_SYNC_USER@|ffs_admin_sync|g' \
      "${CODE}/db/$([ "${ENGINE}" = postgres ] && echo postgres || echo mysql)/bootstrap.sql" | admin > /dev/null
  }
  boot_account ffs_bootstrap "${BOOT_PW}"
  check "$?" 0 "${ENGINE}: the bootstrap account of db/${ENGINE/mariadb/mysql}/bootstrap.sql"
  BOOT=("SYNC_DB_BOOTSTRAP_USER=ffs_bootstrap" "SYNC_DB_BOOTSTRAP_PASSWORD=${BOOT_PW}")
  stack_env "${ENGINE}"

  if [ "${ENGINE}" = postgres ]; then
    # a database of the stack's name, another role's: never taken over, by the bootstrap nor by hand
    printf '%s\n' "CREATE ROLE other_app LOGIN PASSWORD '${THEIRS}';" "CREATE DATABASE syncserver OWNER other_app;" | admin > /dev/null
    db_setup "${IMAGE}" "${BOOT[@]}"
    check "$? $(said 'the database syncserver exists and is not syncserver.s: database-setup.sql does not take it over') $(admin -c "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = 'syncserver'" < /dev/null) $(admin -c "SELECT COUNT(*) FROM pg_roles WHERE rolname = 'syncserver'" < /dev/null)" \
      "1 1 other_app 0" "postgres: the bootstrap stops on a database of the stack's name another role owns, nothing changed"
    sed -e "s|@SYNC_POSTGRES_DATABASE@|syncserver|g" -e "s|@SYNC_POSTGRES_USER@|syncserver|g" -e "s|@SYNC_POSTGRES_PASSWORD@|${SYNC_PW}|g" \
      -e "s|@ADMIN_DATABASE@|ffs_admin|g" -e "s|@ADMIN_USER@|ffs_admin_ui|g" -e "s|@ADMIN_SYNC_USER@|ffs_admin_sync|g" -e "s|@ADMIN_PASSWORD@|${ADMIN_PW}|g" \
      "${CODE}/db/postgres/sync.sql" > "${WORK}/database-setup.sql"
    # (as an administrator runs it: psql -f, without ON_ERROR_STOP)
    out=$(docker exec -i -e PGPASSWORD="${ROOT_PW}" "${NAME}" psql -X -h 127.0.0.1 -U postgres -q -f - < "${WORK}/database-setup.sql" 2>&1)
    check "$(grep -c 'is not syncserver.s: database-setup.sql does not take it over' <<< "${out}") $(admin -c "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = 'syncserver'" < /dev/null) $(admin -c "SELECT COUNT(*) FROM pg_roles WHERE rolname IN ('syncserver', 'ffs_admin_ui')" < /dev/null)" \
      "1 other_app 0" "postgres: database-setup.sql run by hand as the superuser stops there too, says why, changes nothing"
    printf '%s\n' "DROP DATABASE syncserver;" | admin > /dev/null
    # a role of a stack name that is not the stack's
    admin -c "ALTER ROLE other_app RENAME TO ffs_admin_sync" < /dev/null > /dev/null
    db_setup "${IMAGE}" "${BOOT[@]}"
    check "$? $(said "'ffs_admin_sync' exists on the server and does not sign in with <ADMIN_DB_PASSWORD>") $(as ffs_admin_sync "${THEIRS}")" "1 1 1" \
      "postgres: a role of a stack name that is not the stack's: refused, its password as it was"
    admin -c "DROP ROLE ffs_admin_sync" < /dev/null > /dev/null
    # reserved names, the bootstrap's own, a superuser as the bootstrap
    db_setup "${IMAGE}" "${BOOT[@]}" SYNC_POSTGRES_USER=postgres
    check "$? $(said "SYNC_POSTGRES_USER is 'postgres', a name of the server's own accounts")" "1 1" "postgres: SYNC_POSTGRES_USER=postgres refused"
    db_setup "${IMAGE}" "${BOOT[@]}" ADMIN_DB_SYNC_USER=ffs_bootstrap
    check "$? $(said "ADMIN_DB_SYNC_USER is 'ffs_bootstrap'")" "1 1" "postgres: the bootstrap account's name as a stack user refused"
    db_setup "${IMAGE}" SYNC_DB_BOOTSTRAP_USER=postgres "SYNC_DB_BOOTSTRAP_PASSWORD=${ROOT_PW}"
    check "$? $(said 'is a superuser: the bootstrap account must be a role with CREATEROLE and CREATEDB only')" "1 1" "postgres: a superuser as the bootstrap account refused"
  else
    # a user of a stack name that is not the stack's
    printf '%s\n' "CREATE USER 'syncstorage'@'%' IDENTIFIED BY '${THEIRS}';" | admin > /dev/null
    db_setup "${IMAGE}" "${BOOT[@]}"
    check "$? $(said "'syncstorage' exists on the server and does not sign in with <SYNC_STORAGE_DB_PASSWORD>") $(as syncstorage "${THEIRS}") $(admin -e "SELECT COUNT(*) FROM mysql.db WHERE User = 'syncstorage'" < /dev/null)" \
      "1 1 1 0" "${ENGINE}: a user of a stack name that is not the stack's: refused, its password and grants as they were"
    admin -e "DROP USER 'syncstorage'@'%'" < /dev/null
    # reserved names, the bootstrap's own, an administrator as the bootstrap account
    db_setup "${IMAGE}" "${BOOT[@]}" SYNC_TOKENSERVER_DB_USER=root
    check "$? $(said "SYNC_TOKENSERVER_DB_USER is 'root', a name of the server's own accounts") $(as root "${ROOT_PW}")" "1 1 1" "${ENGINE}: SYNC_TOKENSERVER_DB_USER=root refused, root's password as it was"
    db_setup "${IMAGE}" "${BOOT[@]}" SYNC_STORAGE_DB_USER=ffs_bootstrap
    check "$? $(said "SYNC_STORAGE_DB_USER is 'ffs_bootstrap'")" "1 1" "${ENGINE}: the bootstrap account's name as a stack user refused"
    boot_account ffs_wide "${BOOT_PW}"
    admin -e "GRANT $([ "${ENGINE}" = mysql ] && echo SYSTEM_USER || echo SUPER) ON *.* TO 'ffs_wide'@'%'" < /dev/null
    db_setup "${IMAGE}" SYNC_DB_BOOTSTRAP_USER=ffs_wide "SYNC_DB_BOOTSTRAP_PASSWORD=${BOOT_PW}"
    check "$? $(said "ffs_wide holds .*$([ "${ENGINE}" = mysql ] && echo SYSTEM_USER || echo SUPER).* on the whole server")" "1 1" \
      "${ENGINE}: a bootstrap account with $([ "${ENGINE}" = mysql ] && echo SYSTEM_USER || echo SUPER) refused"
  fi

  # the normal path: applied, applied again, checked
  db_setup "${IMAGE}" "${BOOT[@]}"
  check "$? $(said '✓ database-setup.sql applied as ffs_bootstrap') $(said 'every user, grant and database of database-setup.sql is there')" "0 1 1" "${ENGINE}: the bootstrap applies database-setup.sql, then the check passes"
  [ "${FAILED}" = 0 ] || cat "${WORK}/out.log"
  db_setup "${IMAGE}" "${BOOT[@]}"
  check "$?" 0 "${ENGINE}: applied again, nothing in the way (the users exist, signing in with the stack's passwords)"
  db_setup "${IMAGE}"
  check "$?" 0 "${ENGINE}: the check alone passes"
  if [ "${ENGINE}" = postgres ]; then
    # what another role puts into the stack's database, or may do there: reported
    printf '%s\n' "CREATE ROLE intruder LOGIN;" "GRANT CONNECT ON DATABASE syncserver TO intruder;" "\\connect syncserver" "CREATE TABLE public.planted (id int);" | admin > /dev/null
    db_setup "${IMAGE}"
    check "$? $(said 'the role intruder has grants on the database syncserver, which is the stack.s: REVOKE ALL ON DATABASE syncserver FROM intruder;') $(said 'what its owner syncserver does not own .*table public.planted (postgres)')" \
      "1 1 1" "postgres: the check reports another role's grant on the stack's database, and its table there"
  fi
  cleanup
done
[ "${FAILED}" = 0 ] && echo "RESULT db_setup: all checks passed" || echo "RESULT db_setup: some checks FAILED"
exit "${FAILED}"
