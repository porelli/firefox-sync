#!/bin/bash
set -e  # Exit on error
set -u  # Exit on undefined variable

# Configuration
readonly MAX_WAIT=120  # Wait up to 2 minutes
readonly SLEEP_INTERVAL=2
readonly REQUIRED_TABLES=("users" "services" "nodes")
readonly SQL_TEMPLATE="/scripts/db_init.sql"
readonly SQL_FILE="/tmp/db_init_processed.sql"

# fail closed (the Sync server does not start without this container): a setting under both
# names (FFS_BOTH_ENV_NAMES, compose; the new one wins, often a line added from
# .env-example), and placeholders or empty values where the stack needs real ones
if [ -n "${FFS_BOTH_ENV_NAMES:-}" ]; then
  for pair in ${FFS_BOTH_ENV_NAMES}; do
    echo "✗ ERROR: ${pair%%/*} and ${pair#*/} are both set (in .env or in the environment docker compose runs in): run ./prepare_environment.sh --upgrade for .env, or unset ${pair#*/} in your shell (docs/upgrading.md#renamed-settings)"
  done
  exit 1
fi
# not_placeholder <what> <value>: not empty, no <REPLACE_WITH_...> of .env-example
not_placeholder() {
  case "$2" in
    "") echo "✗ ERROR: $1 is empty: set it in .env"; exit 1 ;;
    *"<REPLACE_WITH_"*) echo "✗ ERROR: $1 is still the placeholder of .env-example ($2): set it in .env"; exit 1 ;;
  esac
}
not_placeholder "the PostgreSQL password (SYNC_POSTGRES_PASSWORD)" "${POSTGRES_PASSWORD:-}"
[ -z "${POSTGRES_SYNC_USER:-}" ] || not_placeholder "the Sync server's role password (SYNC_POSTGRES_APP_PASSWORD)" "${POSTGRES_SYNC_PASSWORD:-}"
case "${ADMIN_DB_PASSWORD:-}" in *"<REPLACE_WITH_"*) not_placeholder "the admin UI's database password (ADMIN_DB_PASSWORD)" "${ADMIN_DB_PASSWORD}" ;; esac
[ "${1:-}" = sync-role ] || not_placeholder "the public Sync URL (SYNC_PUBLIC_URL)" "${DOMAIN:-}"

export PGHOST="${POSTGRES_SERVER}"
export PGPORT="${POSTGRES_SERVER_PORT}"
export PGDATABASE="${POSTGRES_DATABASE}"
export PGCONNECT_TIMEOUT=5

# Two sessions. As POSTGRES_USER (a superuser in the stack's PostgreSQL container) only what
# runs no code of the Sync tables' owner: roles, databases, grants, the hand-over of the
# Sync tables, with pg_catalog alone in the search path (no operator or function of the
# public schema can stand in for one of pg_catalog). Everything that reads or writes the
# Sync tables (db_init.sql, the counts) as the Sync server's own role (POSTGRES_SYNC_USER),
# which owns them: a trigger, rule, view or function that role put there runs with its
# rights, not a superuser's. A login of its own, not SET ROLE: code run after SET ROLE can
# RESET ROLE back to the superuser. Without POSTGRES_SYNC_USER both are POSTGRES_USER.
admin_psql() {
  PGUSER="${POSTGRES_USER}" PGPASSWORD="${POSTGRES_PASSWORD}" PGOPTIONS="-c search_path=pg_catalog,pg_temp" psql -X "$@"
}
sync_psql() {
  PGUSER="${POSTGRES_SYNC_USER:-${POSTGRES_USER}}" PGPASSWORD="${POSTGRES_SYNC_PASSWORD:-${POSTGRES_PASSWORD}}" psql -X "$@"
}

# Function to check if database is accessible
check_db_connection() {
  admin_psql -tA -c "SELECT 1;" >/dev/null 2>&1
}

wait_for_db() {
  echo "Checking database connection..."
  WAIT_COUNT=0
  while [ ${WAIT_COUNT} -lt ${MAX_WAIT} ]; do
    if check_db_connection; then
      echo "✓ Database connection established!"
      break
    fi
    echo "  Waiting for database... (${WAIT_COUNT}/${MAX_WAIT}s)"
    sleep ${SLEEP_INTERVAL}
    ((WAIT_COUNT+=SLEEP_INTERVAL))
  done

  if [ ${WAIT_COUNT} -ge ${MAX_WAIT} ]; then
    echo "✗ ERROR: Timeout waiting for database connection"
    exit 1
  fi
}

is_superuser() { [ "$(admin_psql -tA -c 'SELECT rolsuper FROM pg_roles WHERE rolname = current_user;')" = t ]; }
role_exists() { [ "$(admin_psql -tA -c "SELECT COUNT(*) FROM pg_roles WHERE rolname = '$1';")" = 1 ]; }
valid_name() {
  [[ "$1" =~ ^[a-z_][a-z0-9_]{0,31}$ ]] || { echo "✗ ERROR: not a database or role name (a-z, 0-9, _): '$1'"; exit 1; }
}
valid_password() {
  [[ "$2" =~ ^[A-Za-z0-9._~-]+$ ]] || { echo "✗ ERROR: $1: only A-Z a-z 0-9 . _ ~ - (and not empty)"; exit 1; }
}

# The Sync server's own role (POSTGRES_SYNC_USER, docs/reference/database-users.md#postgresql): the image makes
# POSTGRES_USER a superuser, which reaches every database of the server, the admin UI's
# too. The Sync server connects as this role instead, which is no superuser, and so do the
# migrations (syncstorage_migrate) and the rest of this script: it gets the Sync tables
# here, at every start (those of a database created before it too). On your own server
# POSTGRES_USER is the plain owner already: leave it empty there.
sync_role() {
  [ -n "${POSTGRES_SYNC_USER:-}" ] || return 0
  echo ""
  valid_name "${POSTGRES_SYNC_USER}"
  valid_password SYNC_POSTGRES_APP_PASSWORD "${POSTGRES_SYNC_PASSWORD:-}"
  [ "${POSTGRES_SYNC_USER}" != "${POSTGRES_USER}" ] || { echo "✗ ERROR: SYNC_POSTGRES_APP_USER must not be SYNC_POSTGRES_USER"; exit 1; }
  if ! is_superuser; then
    echo "✗ ERROR: SYNC_POSTGRES_APP_USER is for the stack's PostgreSQL container, where SYNC_POSTGRES_USER is a"
    echo "  superuser. On your own server leave it empty: SYNC_POSTGRES_USER is the owner there (docs/reference/database-users.md#postgresql)"
    exit 1
  fi
  role_exists "${POSTGRES_SYNC_USER}" || admin_psql -v ON_ERROR_STOP=1 -q -c "CREATE ROLE ${POSTGRES_SYNC_USER} LOGIN;" || exit 1
  # (again with a new password: SYNC_POSTGRES_APP_PASSWORD changed in .env)
  # (the statements with a password on psql's input, not in its arguments, which ps shows on the host)
  printf '%s\n' "ALTER ROLE ${POSTGRES_SYNC_USER} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD '${POSTGRES_SYNC_PASSWORD}';" \
    | admin_psql -v ON_ERROR_STOP=1 -q || exit 1
  sed -e "s|@SYNC_USER@|${POSTGRES_SYNC_USER}|g" -e "s|@POSTGRES_DATABASE@|${POSTGRES_DATABASE}|g" \
      /scripts/sync_owner.sql > /tmp/sync_owner.sql
  if admin_psql -v ON_ERROR_STOP=1 -q --single-transaction -f /tmp/sync_owner.sql; then
    echo "✓ The Sync server's role ${POSTGRES_SYNC_USER} owns the Sync tables (no superuser)"
  else
    echo "✗ ERROR: Failed to give the Sync tables to ${POSTGRES_SYNC_USER}"
    exit 1
  fi
}

# sync-role: only the Sync server's role, before the migrations (syncstorage_migrate runs
# them as it). Nothing to do without POSTGRES_SYNC_USER (not even a connection: your own
# server may be on a network this container is not on)
if [ "${1:-}" = sync-role ]; then
  if [ -n "${POSTGRES_SYNC_USER:-}" ]; then
    wait_for_db
    sync_role
  else
    echo "No SYNC_POSTGRES_APP_USER: the Sync server connects as SYNC_POSTGRES_USER, nothing to do"
  fi
  exit 0
fi

echo "=========================================="
echo "Firefox Sync Database Initialization"
echo "=========================================="
echo "Domain: ${DOMAIN}"
echo "Max Users: ${MAX_USERS:-}"
echo "Database: ${POSTGRES_DATABASE}"
echo "=========================================="

# the old names of the settings (docs/upgrading.md#renamed-settings) compose found in .env or in
# its environment (FFS_OLD_ENV_NAMES): they still work, a later release removes them
if [ -n "${FFS_OLD_ENV_NAMES:-}" ]; then
  read -r -a old_names <<< "${FFS_OLD_ENV_NAMES}"
  echo "WARNING: settings under their old names, in .env or in the environment docker compose runs in,"
  echo "  which still work but will be removed in a later release: ${old_names[*]}"
  echo "  ./prepare_environment.sh --upgrade renames them (docs/upgrading.md#renamed-settings)"
  echo "=========================================="
fi

# MAX_USERS: N or fixed:N is applied on every start (the admin UI shows it read-only),
# initial:N only when there is no limit yet (first start), then it is managed in the
# admin UI. N is a number, or unlimited (no limit; 0: no new account at all). Anything
# else stops here: the stack must not start with a broken limit.
parse_max_users() {
  local value=$1 number
  case "${value}" in
    initial:*) MAX_USERS_MODE=initial; number=${value#initial:} ;;
    fixed:*)   MAX_USERS_MODE=fixed;   number=${value#fixed:} ;;
    *)         MAX_USERS_MODE=fixed;   number=${value} ;;
  esac
  if [ "${number}" = unlimited ]; then
    MAX_USERS_VALUE=unlimited
    return 0
  fi
  case "${number}" in ''|*[!0-9]*) return 1 ;; esac
  # no leading zeros, and it must fit the INT the triggers read it into
  number=${number#"${number%%[!0]*}"}
  number=${number:-0}
  [ "${#number}" -le 10 ] && [ "${number}" -le 2147483647 ] || return 1
  MAX_USERS_VALUE=${number}
}

if ! parse_max_users "${MAX_USERS:-}"; then
  echo "✗ ERROR: SYNC_MAX_USERS='${MAX_USERS:-}' is not valid: use a number from 0 to 2147483647"
  echo "  or unlimited, optionally prefixed with fixed: (the default, applied on every start) or"
  echo "  initial: (applied on the first start only, then managed in the admin UI)"
  exit 1
fi
[ "${MAX_USERS_MODE}" = fixed ] && MAX_USERS_FIXED=TRUE || MAX_USERS_FIXED=FALSE

# Function to check if a table exists (in public, where the migrations create them)
table_exists() {
  local table_name="$1"
  local count
  count=$(admin_psql -tA \
               -c "SELECT COUNT(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relname = '${table_name}' AND c.relkind IN ('r', 'p');" 2>/dev/null || echo "0")
  [ "${count}" = "1" ]
}

# Wait for database connection
wait_for_db

# Wait for required tables to be created by syncstorage migrations
echo ""
echo "Waiting for syncstorage migrations to create tables..."
WAIT_COUNT=0

while [ ${WAIT_COUNT} -lt ${MAX_WAIT} ]; do
  all_tables_exist=true
  missing_tables=""

  for table in "${REQUIRED_TABLES[@]}"; do
    if ! table_exists "${table}"; then
      all_tables_exist=false
      missing_tables="${missing_tables} ${table}"
    fi
  done

  if [ "${all_tables_exist}" = true ]; then
    echo "✓ All required tables found!"
    break
  fi

  echo "  Missing tables:${missing_tables} (${WAIT_COUNT}/${MAX_WAIT}s)"
  sleep ${SLEEP_INTERVAL}
  ((WAIT_COUNT+=SLEEP_INTERVAL))
done

if [ ${WAIT_COUNT} -ge ${MAX_WAIT} ]; then
  echo "✗ ERROR: Timeout waiting for tables to be created"
  echo "  Missing tables:${missing_tables}"
  exit 1
fi

# the Sync tables to the Sync server's role (its own already, but those of a database
# from before it, or of migrations run as POSTGRES_USER), before anything reads them
sync_role

# Process SQL template with environment variables
echo ""
echo "Processing SQL template..."
sed -e "s|@DOMAIN@|${DOMAIN}|g" \
    -e "s|@MAX_USERS@|${MAX_USERS_VALUE}|g" \
    -e "s|@MAX_USERS_FIXED@|${MAX_USERS_FIXED}|g" \
    "${SQL_TEMPLATE}" > "${SQL_FILE}"

# Apply SQL initialization
# as the Sync server's role (POSTGRES_SYNC_USER), the owner of the tables
echo "Applying database initialization..."
if sync_psql -v ON_ERROR_STOP=1 --single-transaction -f "${SQL_FILE}"; then
  echo "✓ SQL initialization completed successfully!"
else
  echo "✗ ERROR: Failed to apply SQL initialization"
  exit 1
fi

# ---- the setup migrations (db/setup-manifest, docs/databases.md#the-record-of-the-setup-migrations).
# With your own server db-bootstrap ran them, or checked them, and recorded every one before the
# migrations (the start stops otherwise): nothing is missing here. With the stack's database
# container, which creates the same roles and databases here, they are recorded (how
# 'containers'), so that the admin UI shows the version everywhere: as the owner of the Sync
# tables, whose tables they are (the admin UI's reader reads them, admin_grants.sql)
record_setup() {
  local manifest=/scripts/setup-manifest path sum name values="" have how
  [ -r "${manifest}" ] || return 0
  while read -r path sum; do
    case "${path}" in postgres/setup/sync/[0-9][0-9][0-9]-*.sql) ;; *) continue ;; esac
    name=${path##*/}
    values="${values}${values:+, }('sync', $((10#${name:0:3})), '${name}', '${sum}', 'containers')"
  done < <(grep -v '^#' "${manifest}")
  [ -n "${values}" ] || return 0
  sync_psql -v ON_ERROR_STOP=1 -q <<SQL || return 1
CREATE TABLE IF NOT EXISTS public.ffs_setup_migrations (scope VARCHAR(32) NOT NULL, number INTEGER NOT NULL, name VARCHAR(128) NOT NULL, checksum CHAR(64) NOT NULL, how VARCHAR(16) NOT NULL, applied_at TIMESTAMPTZ NOT NULL DEFAULT now(), PRIMARY KEY (scope, number));
CREATE TABLE IF NOT EXISTS public.ffs_setup_state (scope VARCHAR(32) PRIMARY KEY, result VARCHAR(16) NOT NULL, expected INTEGER NOT NULL, detail TEXT NOT NULL, checked_at TIMESTAMPTZ NOT NULL DEFAULT now());
INSERT INTO public.ffs_setup_migrations (scope, number, name, checksum, how) VALUES ${values} ON CONFLICT DO NOTHING;
SQL
  have=$(sync_psql -tA -F ' ' -c "SELECT name, checksum, how FROM public.ffs_setup_migrations WHERE scope = 'sync' ORDER BY number")
  while read -r name sum how; do
    [ -n "${name}" ] || continue
    grep -q "^postgres/setup/sync/${name} ${sum}$" "${manifest}" || echo "WARNING: setup migration ${name} was recorded (${how}) with another checksum than this release's"
  done <<< "${have}"
  echo "✓ Setup migrations: version $(sync_psql -tA -c "SELECT lpad(max(number)::text, 3, '0') FROM public.ffs_setup_migrations WHERE scope = 'sync'") ($(sync_psql -tA -c "SELECT string_agg(DISTINCT how, ',') FROM public.ffs_setup_migrations WHERE scope = 'sync'"))"
}
record_setup || { echo "✗ ERROR: Failed to record the setup migrations"; exit 1; }

# The admin UI's roles and database (ADMIN_DB_*, docs/reference/database-users.md#the-admin-uis-own-database): its event log and audit
# trail out of the Sync server's reach. ADMIN_DB_USER owns the database ADMIN_DB_NAME and
# has nothing here; ADMIN_DB_SYNC_USER reads the Sync tables and has nothing there (the code
# the Sync server's role can put in this database runs as it). Created here when
# POSTGRES_USER is a superuser (the database container of the stack), by database-setup.sql
# on your own server; here only the grants on the Sync tables, which their owner gives.
# Without ADMIN_DB_PASSWORD (an install from before it) the admin UI keeps its tables in
# this database.
if [ -n "${ADMIN_DB_PASSWORD:-}" ]; then
  echo ""
  ADMIN_USER=${ADMIN_DB_USER:-ffs_admin_ui}
  ADMIN_SYNC_USER=${ADMIN_DB_SYNC_USER:-ffs_admin_sync}
  ADMIN_DB=${ADMIN_DB_NAME:-ffs_admin}
  for name in "${ADMIN_USER}" "${ADMIN_SYNC_USER}" "${ADMIN_DB}"; do
    valid_name "${name}"
  done
  valid_password ADMIN_DB_PASSWORD "${ADMIN_DB_PASSWORD}"
  [ "${ADMIN_DB}" != "${POSTGRES_DATABASE}" ] || { echo "✗ ERROR: ADMIN_DB_NAME must not be the Sync database"; exit 1; }
  [ "${ADMIN_USER}" != "${ADMIN_SYNC_USER}" ] || { echo "✗ ERROR: ADMIN_DB_USER and ADMIN_DB_SYNC_USER must be two roles"; exit 1; }
  if is_superuser; then
    for role in "${ADMIN_USER}" "${ADMIN_SYNC_USER}"; do
      role_exists "${role}" || admin_psql -v ON_ERROR_STOP=1 -q -c "CREATE ROLE ${role} LOGIN;" || exit 1
      # (again with a new password: ADMIN_DB_PASSWORD changed in .env)
      printf '%s\n' "ALTER ROLE ${role} LOGIN PASSWORD '${ADMIN_DB_PASSWORD}';" | admin_psql -v ON_ERROR_STOP=1 -q || exit 1
    done
    # nobody else connects there, the Sync server's role neither (POSTGRES_USER, a
    # superuser, still could: hence POSTGRES_SYNC_USER). A new one is a copy of template0,
    # not of template1, where every role may create tables on PostgreSQL 11 to 14 (the Sync
    # server's role could leave ffs_* tables of its own, with their triggers, to be copied);
    # closed to connections until PUBLIC lost them, and its public schema to PUBLIC
    if [ "$(admin_psql -tA -c "SELECT COUNT(*) FROM pg_database WHERE datname = '${ADMIN_DB}';")" = 0 ]; then
      admin_psql -v ON_ERROR_STOP=1 -q -c "CREATE DATABASE ${ADMIN_DB} OWNER ${ADMIN_USER} TEMPLATE template0 ALLOW_CONNECTIONS false;" || exit 1
      admin_psql -v ON_ERROR_STOP=1 -q -c "REVOKE ALL ON DATABASE ${ADMIN_DB} FROM PUBLIC;" || exit 1
      admin_psql -v ON_ERROR_STOP=1 -q -c "ALTER DATABASE ${ADMIN_DB} ALLOW_CONNECTIONS true;" || exit 1
      admin_psql -v ON_ERROR_STOP=1 -q -d "${ADMIN_DB}" -c "REVOKE CREATE ON SCHEMA public FROM PUBLIC;" || exit 1
    fi
    admin_psql -v ON_ERROR_STOP=1 -q -c "REVOKE ALL ON DATABASE ${ADMIN_DB} FROM PUBLIC;" || exit 1
    echo "✓ Admin UI roles ${ADMIN_USER} and ${ADMIN_SYNC_USER}, database ${ADMIN_DB}"
  fi
  if role_exists "${ADMIN_SYNC_USER}"; then
    sed -e "s|@ADMIN_SYNC_USER@|${ADMIN_SYNC_USER}|g" -e "s|@POSTGRES_DATABASE@|${POSTGRES_DATABASE}|g" \
        /scripts/admin_grants.sql > /tmp/admin_grants.sql
    if admin_psql -v ON_ERROR_STOP=1 -q --single-transaction -f /tmp/admin_grants.sql; then
      echo "✓ Admin UI grants on the Sync tables (${ADMIN_SYNC_USER})"
    else
      echo "✗ ERROR: Failed to grant the admin UI's role ${ADMIN_SYNC_USER} its access to the Sync tables"
      exit 1
    fi
  else
    # your own server, without the roles of database-setup.sql: the admin UI cannot connect
    echo "WARNING: no role ${ADMIN_SYNC_USER} for the admin UI (ADMIN_DB_PASSWORD is set): create it,"
    echo "  ${ADMIN_USER} and its database ${ADMIN_DB} with the SQL of docs/databases.md#create-the-databases-and-users, then start this again"
  fi
fi

# Display current status (as the owner of the tables, like db_init.sql)
current_users=$(sync_psql -tA -c 'SELECT COUNT(DISTINCT email) FROM users;')
max_users_in_db=$(sync_psql -tA -c "SELECT config_value FROM config WHERE config_key='max_users';")

echo ""
echo "=========================================="
echo "✓ Database initialization completed!"
echo "=========================================="
echo "Current users: ${current_users}"
echo "Max users (configured): ${max_users_in_db}"
echo "Domain: ${DOMAIN}"
echo ""
if [ "${MAX_USERS_MODE}" = fixed ]; then
  echo "SYNC_MAX_USERS=${MAX_USERS}: applied on every start, read-only in the admin UI."
  echo "  To manage it in the admin UI (docs/limits.md#sync_max_users) set SYNC_MAX_USERS=initial:${MAX_USERS_VALUE} in .env."
else
  echo "SYNC_MAX_USERS=${MAX_USERS}: applied only when there was no limit yet (first start),"
  echo "  change it in the admin UI (docs/limits.md#sync_max_users). A plain SYNC_MAX_USERS=N in .env sets it on every start."
fi
[ "${max_users_in_db}" = "${MAX_USERS_VALUE}" ] || echo "  Kept the value in the database, set in the admin UI."
echo "After changing SYNC_MAX_USERS in .env:"
echo "  docker compose up -d   (the init container and the admin UI)"
echo "  (Quadlets: systemctl --user restart firefox-sync-tokenserver-db-init.service firefox-sync-admin.service)"
echo "=========================================="

exit 0
