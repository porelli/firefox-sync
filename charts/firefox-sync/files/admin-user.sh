#!/bin/sh
# The admin UI's user in the MariaDB and MySQL containers of the stack (docs/reference/database-users.md#the-admin-uis-own-database), run
# as their command before the image's entrypoint: [sh, /ffs-db/admin-user.sh, mariadbd, ...].
# It writes the statements below into a file the server runs at every start with all
# privileges (--init-file, also on the first start and on the volumes of an install from
# before, whose root password is random and unknown): no administrator password anywhere.
#
#   ADMIN_DB_ROLE=tokenserver  the database ADMIN_DB_NAME (ffs_admin: the event log, the audit
#                              trail, the notes...), only for ADMIN_DB_USER (also DROP and
#                              LOCK TABLES there: a restore of its dump); for ADMIN_DB_SYNC_USER
#                              on the tokenserver database SELECT. Its EXECUTE is per procedure,
#                              given by the init container at every start, as the procedures are
#                              made again there (dropping one drops its grants) and as
#                              ADMIN_ACCESS_EXTERNAL says (db/mysql/init/db_init.sh): for that
#                              the Sync server's user (MARIADB_USER, MYSQL_USER) gets GRANT
#                              OPTION on its database, and the EXECUTE on the whole database of
#                              before is taken back
#   ADMIN_DB_ROLE=storage      for ADMIN_DB_SYNC_USER on the storage database SELECT and DELETE
#                              (sizes, purges, resets)
#
# Two users, with ADMIN_DB_PASSWORD: what the Sync server's user puts in its databases
# (procedures, views, functions with SQL SECURITY INVOKER) runs as the one that reads them,
# which has nothing on ADMIN_DB_NAME. The Sync server's users get nothing here. Without
# ADMIN_DB_PASSWORD (an install from before it) nothing is created: the admin UI keeps its
# tables in the tokenserver database.
set -eu

if [ -n "${ADMIN_DB_PASSWORD:-}" ]; then
  user=${ADMIN_DB_USER:-ffs_admin_ui} reader=${ADMIN_DB_SYNC_USER:-ffs_admin_sync}
  # the images' own setting of the Sync database
  sync_db=${MARIADB_DATABASE:-${MYSQL_DATABASE:-}} owner=${MARIADB_USER:-${MYSQL_USER:-}}
  fail() { echo "admin-user.sh: $*" >&2; exit 1; }
  # they end up in SQL: names and passwords as docs/databases.md#create-the-databases-and-users allows them
  for name in "${user}" "${reader}" "${sync_db}" ${owner:+"${owner}"} ${ADMIN_DB_NAME:+"${ADMIN_DB_NAME}"}; do
    printf '%s' "${name}" | grep -Eqx '[a-z_][a-z0-9_]{0,31}' || fail "not a database or user name (a-z, 0-9, _): '${name}'"
  done
  [ "${user}" != "${reader}" ] || fail "ADMIN_DB_USER and ADMIN_DB_SYNC_USER must be two users"
  case "${ADMIN_DB_PASSWORD}" in *"<REPLACE_WITH_"*) fail "ADMIN_DB_PASSWORD is still the placeholder of .env-example: set it in .env" ;; esac
  printf '%s' "${ADMIN_DB_PASSWORD}" | grep -Eqx '[A-Za-z0-9._~-]+' || fail "ADMIN_DB_PASSWORD: only A-Z a-z 0-9 . _ ~ -"
  # (again with a new password: ADMIN_DB_PASSWORD changed in .env)
  account() {
    printf '%s\n' "CREATE USER IF NOT EXISTS '$1'@'%' IDENTIFIED BY '${ADMIN_DB_PASSWORD}';" "ALTER USER '$1'@'%' IDENTIFIED BY '${ADMIN_DB_PASSWORD}';"
  }
  # when <select> <statement>: the statement only when the select finds a row (MySQL stops at a
  # failing statement of the file, even on its first start: the image's user does not exist yet
  # while its entrypoint's own server runs this file; a REVOKE of what is not granted fails)
  when() {
    printf '%s\n' "SET @ffs_admin_sql = IF(EXISTS ($1), '$(printf '%s' "$2" | sed "s/'/''/g")', 'DO 0');" \
      "PREPARE ffs_admin_stmt FROM @ffs_admin_sql;" "EXECUTE ffs_admin_stmt;" "DEALLOCATE PREPARE ffs_admin_stmt;"
  }
  case "${ADMIN_DB_ROLE:-}" in
    tokenserver)
      db=${ADMIN_DB_NAME:-ffs_admin}
      [ "${db}" != "${sync_db}" ] || fail "ADMIN_DB_NAME must not be the tokenserver database"
      statements="$(account "${user}")
$(account "${reader}")
CREATE DATABASE IF NOT EXISTS \`${db}\`;
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, DROP, LOCK TABLES ON \`${db}\`.* TO '${user}'@'%';
GRANT SELECT ON \`${sync_db}\`.* TO '${reader}'@'%';
$(when "SELECT 1 FROM mysql.db WHERE User = '${reader}' AND Host = '%' AND Db = '${sync_db}' AND Execute_priv = 'Y'" \
  "REVOKE EXECUTE ON \`${sync_db}\`.* FROM '${reader}'@'%'")
${owner:+$(when "SELECT 1 FROM mysql.user WHERE User = '${owner}' AND Host = '%'" \
  "GRANT EXECUTE ON \`${sync_db}\`.* TO '${owner}'@'%' WITH GRANT OPTION")}" ;;
    storage)
      statements="$(account "${reader}")
GRANT SELECT, DELETE ON \`${sync_db}\`.* TO '${reader}'@'%';" ;;
    *) fail "ADMIN_DB_ROLE must be tokenserver or storage" ;;
  esac
  # readable by the server only: it runs as mysql, this as root
  umask 077
  mkdir -p /run/ffs-admin
  printf '%s\n' "${statements}" > /run/ffs-admin/init.sql
  chown -R mysql:mysql /run/ffs-admin
  set -- "$@" --init-file=/run/ffs-admin/init.sql
fi
exec docker-entrypoint.sh "$@"
