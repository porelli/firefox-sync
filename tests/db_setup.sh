#!/bin/bash
# db/db-setup.sh (db-bootstrap, fxa-db-bootstrap) against database servers of its own, what
# the e2e tests do not reach: what the bootstrap account refuses to touch, what the check
# reports, and the setup migrations (docs/databases.md#setup-migrations,
# #let-the-stack-apply-them, #when-a-release-needs-new-users-or-grants).
#
# Usage: tests/db_setup.sh <mysql|mariadb|postgres>...   (tests/e2e.sh runs it with EXTERNAL_DB=1)
#   - the bootstrap with the account of db/<engine>/setup/sync-bootstrap (db-setup.sh print):
#     applied, run again, checked; two bootstraps at once on an empty server (the lock);
#   - a reserved name (root, postgres) or the bootstrap's own as a stack user: refused;
#   - a user (role) of a stack name that is not the stack's: refused, as it was. MySQL,
#     MariaDB: one that does not sign in with the stack's password, and one of that name on
#     another host ('u'@'10.%': never widened to '%'); PostgreSQL: one the bootstrap does not
#     administer, even when it signs in with the stack's password (pg_hba.conf may trust it);
#   - a bootstrap account that is an administrator, also through a role: MySQL SYSTEM_USER,
#     MariaDB SUPER, a role with SUPER; PostgreSQL a superuser, pg_read_server_files;
#   - the stack's users with their grants through a default role, or on a pattern
#     (`tokenserve_`): the check passes;
#   - the record: an install from before (the SQL of main, by hand: recorded as baseline), the
#     INSERTs of database-setup.sql (manual), a test-only 999 file: check-only stops naming it
#     with its SQL, `db-setup.sh pending` prints it alone, the bootstrap applies and records
#     it; a file changed after it ran: stopped; a newer number (an older release): a warning;
#     drift (a grant revoked): the check stops, the bootstrap runs the files again;
#   - PostgreSQL: a database of the stack's name owned by another role: the bootstrap and
#     database-setup.sql run by hand stop, its owner as it was; a grant on the stack's
#     database to another role and a table there of another role: warnings.
# Environment: SLOT (tests/slot.sh: the names), MYSQL_IMAGE (mysql:lts), MARIADB_IMAGE (mariadb:lts),
#   POSTGRES_IMAGE (postgres:latest), POSTGRES_OLD_IMAGE (postgres:15-alpine: the bootstrap
#   refused before 16), UPGRADE_FROM (a tree of an earlier release, its
#   db/<engine>/sync.sql for the baseline; else git's BASE, default main; neither: skipped)
set -u
TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CODE=$(dirname "${TESTS}")
# shellcheck source=tests/slot.sh
source "${TESTS}/slot.sh"
FAILED=0
check() { if [ "$1" = "$2" ]; then echo "PASS: $3"; else echo "FAIL: $3 (expected '$2', got '$1')"; FAILED=1; [ -z "${WORK:-}" ] || { echo "---- the last db-setup.sh output:"; sed 's/^/    /' "${WORK}/out.log" 2> /dev/null | tail -40; }; fi; }
rnd() { tr -dc '[:alnum:]' < /dev/urandom | head -c 20; }
NAME=ffs-db-setup${SLOT_SUFFIX}
cleanup() { docker rm -f "${NAME}" "${NAME}-old" > /dev/null 2>&1; docker network rm "${NAME}" > /dev/null 2>&1; rm -rf "${WORK:-}"; }
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
      echo "FFS_DB_ENGINE=${engine}"
      echo "SYNC_TOKENSERVER_DB_HOST=${NAME}"; echo "SYNC_TOKENSERVER_DB_PORT=3306"; echo "SYNC_DB_TLS_VERIFY=false"
      echo "SYNC_TOKENSERVER_DB_NAME=tokenserver"; echo "SYNC_TOKENSERVER_DB_USER=tokenserver"; echo "SYNC_TOKENSERVER_DB_PASSWORD=${SYNC_PW}"
      echo "SYNC_STORAGE_DB_NAME=syncstorage"; echo "SYNC_STORAGE_DB_USER=syncstorage"; echo "SYNC_STORAGE_DB_PASSWORD=${STORAGE_PW}"
    fi
  } > "${WORK}/stack.env"
}
# db_setup [-d <db dir>] [-o <file>] <args of db-setup.sh...> -- [VAR=value...]: db-setup.sh in a
# client container on the server's network, db/ (or the dir given) as /ffs-db; out.log
DB_DIR=${CODE}/db
db_setup() {
  local dir=${DB_DIR} out=${WORK}/out.log args=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -d) dir=$2; shift 2 ;;
      -o) out=$2; shift 2 ;;
      --) shift; break ;;
      *) args+=("$1"); shift ;;
    esac
  done
  cp "${WORK}/stack.env" "${WORK}/run.env"
  [ "$#" = 0 ] || printf '%s\n' "$@" >> "${WORK}/run.env"
  docker run --rm --network "${NAME}" --env-file "${WORK}/run.env" -v "${dir}:/ffs-db:ro" \
    --entrypoint bash "${IMAGE}" /ffs-db/db-setup.sh "${args[@]}" > "${out}" 2>&1
}
said() { grep -c -- "$1" "${WORK}/out.log"; }
saidF() { grep -cF -- "$1" "${WORK}/out.log"; }

for ENGINE in "$@"; do
  case "${ENGINE}" in
    mysql) IMAGE=${MYSQL_IMAGE:-mysql:lts} CLIENT=mysql ;;
    mariadb) IMAGE=${MARIADB_IMAGE:-mariadb:lts} CLIENT=mariadb ;;
    postgres) IMAGE=${POSTGRES_IMAGE:-postgres:latest} CLIENT=psql ;;
    *) echo "usage: $0 <mysql|mariadb|postgres>..."; exit 2 ;;
  esac
  KIND=$([ "${ENGINE}" = postgres ] && echo postgres || echo mysql)
  echo "== db/db-setup.sh on ${IMAGE}"
  cleanup; WORK=$(mktemp -d)
  ROOT_PW=$(rnd) SYNC_PW=$(rnd) STORAGE_PW=$(rnd) ADMIN_PW=$(rnd) BOOT_PW=$(rnd) THEIRS=$(rnd)
  docker network create "${NAME}" > /dev/null || exit 1
  if [ "${ENGINE}" = postgres ]; then
    docker run -d --rm --name "${NAME}" --network "${NAME}" --tmpfs /var/lib/postgresql -e POSTGRES_PASSWORD="${ROOT_PW}" "${IMAGE}" > /dev/null || exit 1
    # SQL as the superuser, on stdin; as <role> <password> [database]
    admin() { docker exec -i -e PGPASSWORD="${ROOT_PW}" "${NAME}" psql -X -h 127.0.0.1 -U postgres -v ON_ERROR_STOP=1 -tA "$@"; }
    as() { docker exec -i -e PGPASSWORD="$2" "${NAME}" psql -X -h 127.0.0.1 -U "$1" -d "${3:-postgres}" -tA -c 'SELECT 1' < /dev/null 2>&1; }
    rec() { admin -d syncserver -c "$1" < /dev/null 2>&1; }
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
    rec() { admin tokenserver -e "$1" < /dev/null 2>&1 | grep -v '^WARNING'; }
    for _ in $(seq 1 90); do admin -e 'SELECT 1' < /dev/null > /dev/null 2>&1 && break; sleep 2; done
  fi
  stack_env "${ENGINE}"
  BOOT=("SYNC_DB_BOOTSTRAP_USER=ffs_bootstrap" "SYNC_DB_BOOTSTRAP_PASSWORD=${BOOT_PW}")
  # the bootstrap account, as docs/databases.md#the-bootstrap-account says: database-bootstrap.sql
  # (db-setup.sh print sync-bootstrap) as the administrator
  boot_account() { # <name> <password>
    db_setup -o "${WORK}/boot.sql" print sync-bootstrap --passwords -- "SYNC_DB_BOOTSTRAP_USER=$1" "SYNC_DB_BOOTSTRAP_PASSWORD=$2" || return 1
    admin < "${WORK}/boot.sql" > /dev/null
  }
  boot_account ffs_bootstrap "${BOOT_PW}"
  check "$?" 0 "${ENGINE}: the bootstrap account of db/${KIND}/setup/sync-bootstrap (db-setup.sh print sync-bootstrap)"
  # the version recorded: "<number> <how>" of each row of scope sync
  versions() {
    if [ "${ENGINE}" = postgres ]; then rec "SELECT number || ' ' || how FROM public.ffs_setup_migrations WHERE scope = 'sync' ORDER BY number" | paste -sd ',' -
    else rec "SELECT CONCAT(number, ' ', how) FROM ffs_setup_migrations WHERE scope = 'sync' ORDER BY number" | paste -sd ',' -; fi
  }
  state() { if [ "${ENGINE}" = postgres ]; then rec "SELECT result FROM public.ffs_setup_state WHERE scope = 'sync'"; else rec "SELECT result FROM ffs_setup_state WHERE scope = 'sync'"; fi; }

  if [ "${ENGINE}" = postgres ]; then
    # a database of the stack's name, another role's: never taken over, by the bootstrap nor by hand
    printf '%s\n' "CREATE ROLE other_app LOGIN PASSWORD '${THEIRS}';" "CREATE DATABASE syncserver OWNER other_app;" | admin > /dev/null
    db_setup sync -- "${BOOT[@]}"
    check "$? $(said 'the database syncserver exists and is not syncserver.s: database-setup.sql does not take it over') $(admin -c "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = 'syncserver'" < /dev/null) $(admin -c "SELECT COUNT(*) FROM pg_roles WHERE rolname = 'syncserver'" < /dev/null)" \
      "1 1 other_app 0" "postgres: the bootstrap stops on a database of the stack's name another role owns, nothing changed"
    db_setup -o "${WORK}/database-setup.sql" print sync --passwords
    # (as an administrator runs it: psql -f, without ON_ERROR_STOP)
    out=$(docker exec -i -e PGPASSWORD="${ROOT_PW}" "${NAME}" psql -X -h 127.0.0.1 -U postgres -q -f - < "${WORK}/database-setup.sql" 2>&1)
    check "$(grep -c 'is not syncserver.s: database-setup.sql does not take it over' <<< "${out}") $(admin -c "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = 'syncserver'" < /dev/null) $(admin -c "SELECT COUNT(*) FROM pg_roles WHERE rolname IN ('syncserver', 'ffs_admin_ui')" < /dev/null)" \
      "1 other_app 0" "postgres: database-setup.sql run by hand as the superuser stops there too, says why, changes nothing"
    printf '%s\n' "DROP DATABASE syncserver;" | admin > /dev/null
    # a role of a stack name the bootstrap does not administer: refused, even with the stack's
    # password (a sign-in proves nothing, pg_hba.conf may trust it); once the superuser gives
    # it to the bootstrap (database-bootstrap.sql does that for the roles that exist): the stack's
    admin -c "ALTER ROLE other_app RENAME TO ffs_admin_sync" < /dev/null > /dev/null
    admin -c "ALTER ROLE ffs_admin_sync PASSWORD '${ADMIN_PW}'" < /dev/null > /dev/null
    db_setup sync -- "${BOOT[@]}"
    check "$? $(said "the role ffs_admin_sync (ADMIN_DB_SYNC_USER) exists and is not the stack's") $(admin -c "SELECT COUNT(*) FROM pg_roles WHERE rolname = 'syncserver'" < /dev/null)" "1 1 0" \
      "postgres: a role of a stack name the bootstrap does not administer: refused before any change, though it signs in with the stack's password"
    admin -c "DROP ROLE ffs_admin_sync" < /dev/null > /dev/null
    # reserved names, the bootstrap's own, an administrator as the bootstrap (also through a role)
    db_setup sync -- "${BOOT[@]}" SYNC_POSTGRES_USER=postgres
    check "$? $(said "SYNC_POSTGRES_USER is 'postgres', a name of the server's own accounts")" "1 1" "postgres: SYNC_POSTGRES_USER=postgres refused"
    db_setup sync -- "${BOOT[@]}" ADMIN_DB_SYNC_USER=ffs_bootstrap
    check "$? $(said "ADMIN_DB_SYNC_USER is 'ffs_bootstrap'")" "1 1" "postgres: the bootstrap account's name as a stack user refused"
    db_setup sync -- SYNC_DB_BOOTSTRAP_USER=postgres "SYNC_DB_BOOTSTRAP_PASSWORD=${ROOT_PW}"
    check "$? $(said 'holds SUPERUSER.*: the bootstrap account must be a role with CREATEROLE and CREATEDB only')" "1 1" "postgres: a superuser as the bootstrap account refused"
    boot_account ffs_wide "${BOOT_PW}" && admin -c "GRANT pg_read_server_files TO ffs_wide" < /dev/null > /dev/null
    db_setup sync -- SYNC_DB_BOOTSTRAP_USER=ffs_wide "SYNC_DB_BOOTSTRAP_PASSWORD=${BOOT_PW}"
    check "$? $(said 'ffs_wide holds membership of pg_read_server_files')" "1 1" "postgres: a bootstrap account that is a member of pg_read_server_files refused"
    admin -c "CREATE ROLE ffs_super SUPERUSER NOLOGIN" < /dev/null > /dev/null && admin -c "REVOKE pg_read_server_files FROM ffs_wide" < /dev/null > /dev/null \
      && admin -c "GRANT ffs_super TO ffs_wide" < /dev/null > /dev/null
    db_setup sync -- SYNC_DB_BOOTSTRAP_USER=ffs_wide "SYNC_DB_BOOTSTRAP_PASSWORD=${BOOT_PW}"
    check "$? $(said 'ffs_wide holds membership of ffs_super')" "1 1" "postgres: a bootstrap account that is a member of a superuser role refused"
  else
    # a user of a stack name that is not the stack's: another password
    printf '%s\n' "CREATE USER 'syncstorage'@'%' IDENTIFIED BY '${THEIRS}';" | admin > /dev/null
    db_setup sync -- "${BOOT[@]}"
    check "$? $(said "'syncstorage'@'%' exists on the server and does not sign in with <SYNC_STORAGE_DB_PASSWORD>") $(as syncstorage "${THEIRS}") $(admin -e "SELECT COUNT(*) FROM mysql.db WHERE User = 'syncstorage'" < /dev/null)" \
      "1 1 1 0" "${ENGINE}: a user of a stack name that is not the stack's: refused, its password and grants as they were"
    admin -e "DROP USER 'syncstorage'@'%'" < /dev/null
    # one of that name on another host, with the stack's password: '%' would widen it
    printf '%s\n' "CREATE USER 'syncstorage'@'10.%' IDENTIFIED BY '${STORAGE_PW}';" | admin > /dev/null
    db_setup sync -- "${BOOT[@]}"
    check "$? $(said "the server has 'syncstorage'@'10.%' (an account or a role): the setup migrations give 'syncstorage'@'%' only") $(admin -e "SELECT COUNT(*) FROM mysql.user WHERE User = 'syncstorage'" < /dev/null)" \
      "1 1 1" "${ENGINE}: 'syncstorage'@'10.%' there: the bootstrap stops naming it, creates no 'syncstorage'@'%'"
    admin -e "DROP USER 'syncstorage'@'10.%'" < /dev/null
    # reserved names, the bootstrap's own, an administrator as the bootstrap account (also through a role)
    db_setup sync -- "${BOOT[@]}" SYNC_TOKENSERVER_DB_USER=root
    check "$? $(said "SYNC_TOKENSERVER_DB_USER is 'root', a name of the server's own accounts") $(as root "${ROOT_PW}")" "1 1 1" "${ENGINE}: SYNC_TOKENSERVER_DB_USER=root refused, root's password as it was"
    db_setup sync -- "${BOOT[@]}" SYNC_STORAGE_DB_USER=ffs_bootstrap
    check "$? $(said "SYNC_STORAGE_DB_USER is 'ffs_bootstrap'")" "1 1" "${ENGINE}: the bootstrap account's name as a stack user refused"
    wide=$([ "${ENGINE}" = mysql ] && echo SYSTEM_USER || echo SUPER)
    boot_account ffs_wide "${BOOT_PW}"
    admin -e "GRANT ${wide} ON *.* TO 'ffs_wide'@'%'" < /dev/null
    db_setup sync -- SYNC_DB_BOOTSTRAP_USER=ffs_wide "SYNC_DB_BOOTSTRAP_PASSWORD=${BOOT_PW}"
    check "$? $(said "ffs_wide holds .*${wide}")" "1 1" "${ENGINE}: a bootstrap account with ${wide} refused"
    # through a role (not its default one): a SET ROLE away
    printf '%s\n' "REVOKE ${wide} ON *.* FROM 'ffs_wide'@'%';" "CREATE ROLE ffs_inner;" "CREATE ROLE ffs_outer;" "GRANT SUPER ON *.* TO ffs_inner;" \
      "GRANT ffs_inner TO ffs_outer;" "GRANT ffs_outer TO 'ffs_wide'@'%';" | admin > /dev/null
    db_setup sync -- SYNC_DB_BOOTSTRAP_USER=ffs_wide "SYNC_DB_BOOTSTRAP_PASSWORD=${BOOT_PW}"
    check "$? $(said 'ffs_wide holds .*SUPER.* (itself or through its roles)')" "1 1" "${ENGINE}: a bootstrap account with SUPER through a role of a role refused"
    # (accounts with CREATE USER or SUPER and no SYSTEM_USER: gone, the check below needs none)
    printf '%s\n' "DROP USER 'ffs_wide'@'%';" "DROP ROLE ffs_outer;" "DROP ROLE ffs_inner;" | admin > /dev/null
    admin -e "GRANT INSERT ON mysql.* TO 'ffs_bootstrap'@'%'" < /dev/null
    db_setup sync -- "${BOOT[@]}"
    check "$? $(said 'ffs_bootstrap holds INSERT on the mysql schema')" "1 1" "${ENGINE}: a bootstrap account with a privilege on the mysql schema refused"
    admin -e "REVOKE INSERT ON mysql.* FROM 'ffs_bootstrap'@'%'" < /dev/null
    # deny by default: a table of the mysql schema beyond the names and hosts of mysql.user
    admin -e "GRANT SELECT ON mysql.user TO 'ffs_bootstrap'@'%'" < /dev/null
    db_setup sync -- "${BOOT[@]}"
    check "$? $(said 'ffs_bootstrap holds SELECT.* on `mysql`.`user`')" "1 1" "${ENGINE}: a bootstrap account with SELECT on all of mysql.user (its password hashes) refused"
    # (MariaDB's REVOKE takes the columns' SELECT with it: the account's SQL again)
    admin -e "REVOKE SELECT ON mysql.user FROM 'ffs_bootstrap'@'%'" < /dev/null && boot_account ffs_bootstrap "${BOOT_PW}"
    admin -e "GRANT USAGE ON *.* TO 'ffs_bootstrap'@'%' WITH GRANT OPTION" < /dev/null
    db_setup sync -- "${BOOT[@]}"
    check "$? $(said 'ffs_bootstrap holds .*WITH GRANT OPTION on the whole server')" "1 1" "${ENGINE}: a bootstrap account with GRANT OPTION on the whole server refused"
    admin -e "REVOKE GRANT OPTION ON *.* FROM 'ffs_bootstrap'@'%'" < /dev/null
    if [ "${ENGINE}" = mysql ]; then
      # MySQL: CREATE USER reaches every account without SYSTEM_USER: every administrator of the
      # server (any privilege on the whole server or on the mysql schema, also through a role)
      # must hold it (root does), or the bootstrap is refused, naming them; an application's
      # account with everything on its own database is no administrator
      admin_case() { # <what> <SQL that makes ffs_dba one>
        printf '%s\n' "CREATE USER 'ffs_dba'@'%' IDENTIFIED BY '${THEIRS}';" "$2" | admin > /dev/null
        db_setup sync -- "${BOOT[@]}"
        check "$? $(saidF "lack SYSTEM_USER: 'ffs_dba'@'%'") $(as ffs_dba "${THEIRS}")" "1 1 1" \
          "mysql: an account with $1 and without SYSTEM_USER: the bootstrap refused, naming it, the account untouched"
        printf '%s\n' "DROP USER 'ffs_dba'@'%';" "DROP ROLE IF EXISTS ffs_super;" | admin > /dev/null
      }
      admin_case "CREATE USER on *.*" "GRANT CREATE USER ON *.* TO 'ffs_dba'@'%';"
      admin_case "a dynamic privilege only (BACKUP_ADMIN)" "GRANT BACKUP_ADMIN ON *.* TO 'ffs_dba'@'%';"
      admin_case "SELECT on mysql.user" "GRANT SELECT ON mysql.user TO 'ffs_dba'@'%';"
      admin_case "a role with SUPER" "CREATE ROLE ffs_super; GRANT SUPER ON *.* TO ffs_super; GRANT ffs_super TO 'ffs_dba'@'%';"
      printf '%s\n' "CREATE USER 'ffs_dba'@'%' IDENTIFIED BY '${THEIRS}';" "GRANT CREATE USER ON *.* TO 'ffs_dba'@'%';" "GRANT SYSTEM_USER ON *.* TO 'ffs_dba'@'%';" \
        "CREATE DATABASE other_app;" "CREATE USER 'other_app'@'%' IDENTIFIED BY '${THEIRS}';" "GRANT ALL PRIVILEGES ON other_app.* TO 'other_app'@'%';" | admin > /dev/null
      db_setup sync -- "${BOOT[@]}"
      check "$? $(said 'lack SYSTEM_USER') $(said 'WARNING: MySQL: ffs_bootstrap (CREATE USER) can change or drop the accounts without SYSTEM_USER')" "0 0 1" \
        "mysql: the administrator with SYSTEM_USER, an application's account with ALL on its database: the bootstrap goes on, with a warning"
      printf '%s\n' "DROP USER 'ffs_dba'@'%';" "DROP USER 'other_app'@'%';" "DROP DATABASE other_app;" | admin > /dev/null
      # (and back to an empty server for the normal path)
      printf '%s\n' "DROP DATABASE tokenserver;" "DROP DATABASE syncstorage;" "DROP DATABASE ffs_admin;" "DROP USER 'tokenserver'@'%', 'syncstorage'@'%', 'ffs_admin_ui'@'%', 'ffs_admin_sync'@'%';" | admin > /dev/null
    fi
  fi

  # the normal path: two at once on an empty server (replicas of the chart: the lock), applied
  # again, checked, recorded
  db_setup -o "${WORK}/a.log" sync -- "${BOOT[@]}" & first=$!
  db_setup -o "${WORK}/b.log" sync -- "${BOOT[@]}"; second=$?
  wait "${first}"; first=$?
  cat "${WORK}/a.log" "${WORK}/b.log" > "${WORK}/out.log"
  check "${first} ${second} $(said '✓ setup migrations 001 applied as ffs_bootstrap') $(said 'every user, grant and database of database-setup.sql is there') $(versions) $(state)" \
    "0 0 1 2 1 bootstrap ok" "${ENGINE}: two bootstraps at once on an empty server: one applies 001 (the lock), the other finds it there; both check it, it is recorded (how bootstrap)"
  [ "${ENGINE}" != mariadb ] || check "$(said 'WARNING: MariaDB has no protection of accounts: ffs_bootstrap (CREATE USER) can change or drop any account')" 2 \
    "mariadb: the bootstrap warns at every start that CREATE USER reaches every account (none protected)"
  db_setup sync -- "${BOOT[@]}"
  check "$? $(said '✓ setup migrations .* applied as')" "0 0" "${ENGINE}: run again, nothing pending, nothing in the way (the users exist, they are the stack's)"
  db_setup sync
  check "$? $(said 'setup version 001 (this release expects 001)')" "0 1" "${ENGINE}: the check alone passes"
  if [ "${ENGINE}" = postgres ]; then
    # what another role puts into the stack's database, or may do there: warnings only (a
    # backup's or monitoring's CONNECT is the owner's to give)
    printf '%s\n' "CREATE ROLE intruder LOGIN;" "GRANT CONNECT ON DATABASE syncserver TO intruder;" "\\connect syncserver" "CREATE TABLE public.planted (id int);" | admin > /dev/null
    db_setup sync
    check "$? $(said 'WARNING: other roles have grants on the database syncserver, which is the stack.s: intruder (CONNECT)') $(said 'what its owner syncserver does not own .*table public.planted (postgres)')" \
      "0 1 1" "postgres: another role's grant on the stack's database, and its table there: warnings, the start goes on"
    printf '%s\n' "\\connect syncserver" "DROP TABLE public.planted;" "REVOKE ALL ON DATABASE syncserver FROM intruder;" | admin > /dev/null
    # drift: every role may connect again (a GRANT by hand): the check stops, the bootstrap runs the file again
    admin -c "GRANT CONNECT ON DATABASE syncserver TO PUBLIC" < /dev/null > /dev/null
    db_setup sync
    check "$? $(saidF 'every role may connect to the database syncserver: REVOKE ALL ON DATABASE syncserver FROM PUBLIC;') $(state)" "1 1 drift" \
      "postgres: CONNECT for every role by hand: the check stops naming the REVOKE, the record says drift"
    db_setup sync -- "${BOOT[@]}"
    check "$? $(said 'drift from the setup migrations, run again as ffs_bootstrap') $(admin -c "SELECT has_database_privilege('public', 'syncserver', 'CONNECT')" < /dev/null) $(state)" "0 1 f ok" \
      "postgres: with the bootstrap: the drift run again, PUBLIC without CONNECT again"
  else
    # the stack's users with their grants through a default role and on a pattern: what they have
    admin -e "REVOKE EXECUTE ON tokenserver.* FROM 'ffs_admin_sync'@'%'" < /dev/null
    db_setup sync
    check "$? $(saidF "'ffs_admin_sync' lacks EXECUTE on \`tokenserver\`: GRANT SELECT, EXECUTE ON \`tokenserver\`.* TO 'ffs_admin_sync'@'%';") $(state)" "1 1 drift" \
      "${ENGINE}: a grant revoked by hand: the check stops naming its GRANT, the record says drift"
    printf '%s\n' "CREATE ROLE ffs_reader;" "GRANT EXECUTE ON \`tokenserve_\`.* TO ffs_reader;" "GRANT ffs_reader TO 'ffs_admin_sync'@'%';" \
      "$([ "${ENGINE}" = mysql ] && echo "SET DEFAULT ROLE ffs_reader TO 'ffs_admin_sync'@'%';" || echo "SET DEFAULT ROLE ffs_reader FOR 'ffs_admin_sync'@'%';")" | admin > /dev/null
    db_setup sync
    check "$? $(state)" "0 ok" "${ENGINE}: that grant through a default role, on a pattern (\`tokenserve_\`): the check finds it"
    printf '%s\n' "$([ "${ENGINE}" = mysql ] && echo "SET DEFAULT ROLE NONE TO 'ffs_admin_sync'@'%';" || echo "SET DEFAULT ROLE NONE FOR 'ffs_admin_sync'@'%';")" \
      "DROP ROLE ffs_reader;" | admin > /dev/null
    db_setup sync -- "${BOOT[@]}"
    check "$? $(said 'drift from the setup migrations, run again as ffs_bootstrap') $(admin -e "SHOW GRANTS FOR 'ffs_admin_sync'@'%'" < /dev/null | grep -c 'GRANT SELECT, EXECUTE ON `tokenserver`')" "0 1 1" \
      "${ENGINE}: with the bootstrap: the drift run again, the grant back"
  fi

  echo "== ${ENGINE}: the record of the setup migrations"
  # a file changed after it ran: stopped (released files never change)
  rec "UPDATE $([ "${ENGINE}" = postgres ] && echo public.)ffs_setup_migrations SET checksum = '$(printf '0%.0s' $(seq 64))' WHERE scope = 'sync' AND number = 1" > /dev/null
  db_setup sync
  check "$? $(said 'were applied as another file than this release.s: 001-sync-and-admin-ui.sql (recorded 000000000000')" "1 1" "${ENGINE}: a recorded checksum that is not the file's: the start stops"
  rec "UPDATE $([ "${ENGINE}" = postgres ] && echo public.)ffs_setup_migrations SET checksum = '$(grep "^${KIND}/setup/sync/001-" "${CODE}/db/setup-manifest" | cut -d ' ' -f 2)' WHERE scope = 'sync' AND number = 1" > /dev/null
  # a newer number (an older release on a newer setup): a warning
  rec "INSERT INTO $([ "${ENGINE}" = postgres ] && echo public.)ffs_setup_migrations (scope, number, name, checksum, how) VALUES ('sync', 1000, '1000-later.sql', '$(printf 'a%.0s' $(seq 64))', 'manual')" > /dev/null
  db_setup sync
  check "$? $(said 'WARNING: the server has setup migrations 1000 of a newer release than this one (it expects 001)')" "0 1" "${ENGINE}: a newer migration recorded: a warning, the start goes on"
  rec "DELETE FROM $([ "${ENGINE}" = postgres ] && echo public.)ffs_setup_migrations WHERE number = 1000" > /dev/null
  # a test-only 999 file (a release that needs a new user): check-only stops naming it, with its
  # SQL; pending prints it alone; the bootstrap applies and records it
  cp -r "${CODE}/db" "${WORK}/db999"
  if [ "${ENGINE}" = postgres ]; then
    printf '%s\n' "-- Setup migration 999, scope sync: test only (tests/db_setup.sh)" \
      "SELECT 'CREATE ROLE ffs_test_999 LOGIN' WHERE NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'ffs_test_999')" '\gexec' \
      "ALTER ROLE ffs_test_999 PASSWORD '@ADMIN_PASSWORD@';" > "${WORK}/db999/postgres/setup/sync/999-test-only.sql"
  else
    printf '%s\n' "-- Setup migration 999, scope sync: test only (tests/db_setup.sh)" \
      "CREATE USER IF NOT EXISTS 'ffs_test_999'@'%' IDENTIFIED BY '@ADMIN_PASSWORD@';" \
      "GRANT SELECT ON \`@SYNC_TOKENSERVER_DATABASE@\`.* TO 'ffs_test_999'@'%';" > "${WORK}/db999/mysql/setup/sync/999-test-only.sql"
  fi
  db_setup -d "${WORK}/db999" sync
  check "$? $(said 'setup migrations 999 not applied (your server has version 001, this release expects 999)') $(saidF "ffs_test_999") $(said "ffs_setup_migrations (scope, number, name, checksum, how) VALUES ('sync', 999, '999-test-only.sql', '[0-9a-f]*', 'manual')") $(state)" \
    "1 1 2 1 pending" "${ENGINE}: check-only with a test-only 999: the start stops naming it, its SQL (passwords as <SETTING>) and the INSERT that records it"
  check "$(saidF "'<ADMIN_DB_PASSWORD>'") $(saidF "${ADMIN_PW}")" "1 0" "${ENGINE}: its SQL without the password"
  db_setup -d "${WORK}/db999" pending sync
  check "$? $(said '^-- ==== setup migration ') $(said '999-test-only.sql (scope sync)') $(saidF "${ADMIN_PW}")" "0 1 1 0" "${ENGINE}: db-setup.sh pending sync: 999 alone, no password"
  db_setup -d "${WORK}/db999" pending sync --passwords
  check "$? $(saidF "${ADMIN_PW}")" "0 1" "${ENGINE}: db-setup.sh pending sync --passwords: filled in"
  db_setup -d "${WORK}/db999" sync -- "${BOOT[@]}"
  check "$? $(said '✓ setup migrations 999 applied as ffs_bootstrap') $(versions) $(as ffs_test_999 "${ADMIN_PW}")" "0 1 1 bootstrap,999 bootstrap 1" \
    "${ENGINE}: the bootstrap applies 999 and records it (how bootstrap): version 999"
  db_setup -d "${WORK}/db999" sync
  check "$? $(said 'setup version 999 (this release expects 999)')" "0 1" "${ENGINE}: then check-only passes"

  echo "== ${ENGINE}: an install from before the setup migrations (the SQL of main, by hand): the baseline"
  cleanup_record() {
    if [ "${ENGINE}" = postgres ]; then rec "DROP TABLE public.ffs_setup_migrations, public.ffs_setup_state" > /dev/null
    else rec "DROP TABLE ffs_setup_migrations, ffs_setup_state" > /dev/null; fi
  }
  cleanup_record
  db_setup sync
  check "$? $(said 'every user, grant and database of the setup migrations 001 is there, recorded as their baseline') $(versions)" "0 1 1 baseline" \
    "${ENGINE}: nothing recorded, the end state there: recorded as the baseline"
  # the SQL of an earlier release on an empty server, run by hand: db/<engine>/sync.sql of
  # UPGRADE_FROM (a tree: vm.sh ssh extracts it), else of git's BASE (default main)
  if base=$(if [ -f "${UPGRADE_FROM:-/nonexistent}/db/${KIND}/sync.sql" ]; then cat "${UPGRADE_FROM}/db/${KIND}/sync.sql"; else git -C "${CODE}" show "${BASE:-main}:db/${KIND}/sync.sql" 2> /dev/null; fi); then
    if [ "${ENGINE}" = postgres ]; then
      printf '%s\n' "DROP DATABASE syncserver;" "DROP DATABASE ffs_admin;" "DROP ROLE syncserver;" "DROP ROLE ffs_admin_ui;" "DROP ROLE ffs_admin_sync;" | admin > /dev/null 2>&1
    else
      printf '%s\n' "DROP DATABASE tokenserver;" "DROP DATABASE syncstorage;" "DROP DATABASE ffs_admin;" "DROP USER 'tokenserver'@'%';" "DROP USER 'syncstorage'@'%';" \
        "DROP USER 'ffs_admin_ui'@'%';" "DROP USER 'ffs_admin_sync'@'%';" "DROP USER IF EXISTS 'ffs_test_999'@'%';" | admin > /dev/null 2>&1
    fi
    sed -e "s|@SYNC_TOKENSERVER_DATABASE@|tokenserver|g" -e "s|@SYNC_TOKENSERVER_USER@|tokenserver|g" -e "s|@SYNC_TOKENSERVER_PASSWORD@|${SYNC_PW}|g" \
      -e "s|@SYNC_STORAGE_DATABASE@|syncstorage|g" -e "s|@SYNC_STORAGE_USER@|syncstorage|g" -e "s|@SYNC_STORAGE_PASSWORD@|${STORAGE_PW}|g" \
      -e "s|@SYNC_POSTGRES_DATABASE@|syncserver|g" -e "s|@SYNC_POSTGRES_USER@|syncserver|g" -e "s|@SYNC_POSTGRES_PASSWORD@|${SYNC_PW}|g" \
      -e "s|@ADMIN_DATABASE@|ffs_admin|g" -e "s|@ADMIN_USER@|ffs_admin_ui|g" -e "s|@ADMIN_SYNC_USER@|ffs_admin_sync|g" -e "s|@ADMIN_PASSWORD@|${ADMIN_PW}|g" <<< "${base}" \
      | admin > /dev/null 2>&1
    db_setup sync
    check "$? $(said 'recorded as their baseline') $(versions)" "0 1 1 baseline" "${ENGINE}: the database-setup.sql of ${UPGRADE_FROM:-${BASE:-main}} run by hand, then this release: the baseline"
  else
    echo "SKIP: ${ENGINE}: no db/${KIND}/sync.sql of an earlier release (UPGRADE_FROM, git ${BASE:-main})"
  fi
  # the INSERTs of database-setup.sql (db-setup.sh print sync): a by-hand run recorded as manual
  cleanup_record
  db_setup -o "${WORK}/database-setup.sql" print sync --passwords
  if [ "${ENGINE}" = postgres ]; then
    docker exec -i -e PGPASSWORD="${ROOT_PW}" "${NAME}" psql -X -h 127.0.0.1 -U postgres -v ON_ERROR_STOP=1 -q -f - < "${WORK}/database-setup.sql" > /dev/null 2>&1
  else
    admin < "${WORK}/database-setup.sql" > /dev/null
  fi
  check "$? $(versions)" "0 1 manual" "${ENGINE}: database-setup.sql (db-setup.sh print sync) run by hand: recorded as manual"
  db_setup sync
  check "$? $(said 'setup version 001')" "0 1" "${ENGINE}: then the start finds it there"
  if [ "${ENGINE}" = postgres ]; then
    echo "== postgres: a server before 16 (${POSTGRES_OLD_IMAGE:-postgres:15-alpine}): no bootstrap, the check alone"
    OLD=${NAME}-old
    docker rm -f "${OLD}" > /dev/null 2>&1
    docker run -d --rm --name "${OLD}" --network "${NAME}" --tmpfs /var/lib/postgresql/data -e POSTGRES_PASSWORD="${ROOT_PW}" "${POSTGRES_OLD_IMAGE:-postgres:15-alpine}" > /dev/null || exit 1
    old_admin() { docker exec -i -e PGPASSWORD="${ROOT_PW}" "${OLD}" psql -X -h 127.0.0.1 -U postgres -v ON_ERROR_STOP=1 -tA "$@"; }
    for _ in $(seq 1 60); do old_admin -c 'SELECT 1' < /dev/null > /dev/null 2>&1 && break; sleep 2; done
    db_setup -o "${WORK}/boot.sql" print sync-bootstrap --passwords -- "${BOOT[@]}" && old_admin < "${WORK}/boot.sql" > /dev/null
    db_setup sync -- "${BOOT[@]}" "SYNC_POSTGRES_HOST=${OLD}"
    check "$? $(said 'the bootstrap needs PostgreSQL 16 or later') $(old_admin -c "SELECT COUNT(*) FROM pg_roles WHERE rolname = 'syncserver'" < /dev/null)" "1 1 0" \
      "postgres before 16: the bootstrap refused (CREATEROLE close to a superuser there), nothing created"
    db_setup -o "${WORK}/database-setup.sql" print sync --passwords && old_admin -q -f - < "${WORK}/database-setup.sql" > /dev/null 2>&1
    db_setup sync -- "SYNC_POSTGRES_HOST=${OLD}"
    check "$? $(said 'setup version 001')" "0 1" "postgres before 16: database-setup.sql by hand, then the check alone passes"
    docker rm -f "${OLD}" > /dev/null 2>&1
  fi
  cleanup
done
[ "${FAILED}" = 0 ] && echo "RESULT db_setup: all checks passed" || echo "RESULT db_setup: some checks FAILED"
exit "${FAILED}"
