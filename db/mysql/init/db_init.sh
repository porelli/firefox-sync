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
not_placeholder "the public Sync URL (SYNC_PUBLIC_URL)" "${DOMAIN:-}"
not_placeholder "the tokenserver database password (SYNC_TOKENSERVER_DB_PASSWORD)" "${MARIADB_PASSWORD:-}"

echo "=========================================="
echo "Firefox Sync Database Initialization"
echo "=========================================="
echo "Domain: ${DOMAIN}"
echo "Max Users: ${MAX_USERS:-}"
echo "Database: ${MARIADB_DATABASE}"
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
[ "${MAX_USERS_MODE}" = fixed ] && MAX_USERS_FIXED=1 || MAX_USERS_FIXED=0

# MARIADB_TLS_VERIFY=false: MySQL's certificate is self-signed, which this client refuses
# by default; syncstorage-rs itself connects without TLS (docs/databases.md#server-requirements)
TLS_ARGS=()
[ "${MARIADB_TLS_VERIFY:-true}" = false ] && TLS_ARGS=(--skip-ssl-verify-server-cert)
# (the password in the client's environment, not in its arguments, which ps shows on the host)
db() {
  MYSQL_PWD="${MARIADB_PASSWORD}" mariadb --host="${MARIADB_SERVER}" \
          --port="${MARIADB_SERVER_PORT}" \
          --user="${MARIADB_USER}" \
          "${TLS_ARGS[@]}" \
          "$@"
}

# Function to check if database is accessible
check_db_connection() {
  db --connect-timeout=5 -e "SELECT 1;" >/dev/null 2>&1
}

# Function to check if a table exists
table_exists() {
  local table_name="$1"
  local count
  count=$(db "${MARIADB_DATABASE}" -sN \
                   -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${MARIADB_DATABASE}' AND table_name='${table_name}';" 2>/dev/null || echo "0")
  [ "${count}" = "1" ]
}

# Wait for database connection
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

# Process SQL template with environment variables
echo ""
echo "Processing SQL template..."
sed -e "s|@DOMAIN@|${DOMAIN}|g" \
    -e "s|@MAX_USERS@|${MAX_USERS_VALUE}|g" \
    -e "s|@MAX_USERS_FIXED@|${MAX_USERS_FIXED}|g" \
    "${SQL_TEMPLATE}" > "${SQL_FILE}"

# Apply SQL initialization
echo "Applying database initialization..."
if db "${MARIADB_DATABASE}" < "${SQL_FILE}"; then
  echo "✓ SQL initialization completed successfully!"
else
  echo "✗ ERROR: Failed to apply SQL initialization"
  exit 1
fi

# ---- the setup migrations (db/setup-manifest, docs/databases.md#the-record-of-the-setup-migrations).
# With your own server db-bootstrap ran them, or checked them, and recorded every one before the
# migrations (the start stops otherwise): nothing is missing here. With the stack's database
# containers, which create the same users and grants themselves, they are recorded here
# (how 'containers'), so that the admin UI shows the version everywhere. A recorded file with
# another checksum: a warning (db-setup.sh stops on it with your own server)
record_setup() {
  local manifest=/scripts/setup-manifest path sum name values="" have
  [ -r "${manifest}" ] || return 0
  while read -r path sum; do
    case "${path}" in mysql/setup/sync/[0-9][0-9][0-9]-*.sql) ;; *) continue ;; esac
    name=${path##*/}
    values="${values}${values:+, }('sync', $((10#${name:0:3})), '${name}', '${sum}', 'containers')"
  done < <(grep -v '^#' "${manifest}")
  [ -n "${values}" ] || return 0
  db "${MARIADB_DATABASE}" <<SQL || return 1
CREATE TABLE IF NOT EXISTS ffs_setup_migrations (scope VARCHAR(32) NOT NULL, number INT NOT NULL, name VARCHAR(128) NOT NULL, checksum CHAR(64) NOT NULL, how VARCHAR(16) NOT NULL, applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (scope, number));
CREATE TABLE IF NOT EXISTS ffs_setup_state (scope VARCHAR(32) PRIMARY KEY, result VARCHAR(16) NOT NULL, expected INT NOT NULL, detail TEXT NOT NULL, checked_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP);
INSERT IGNORE INTO ffs_setup_migrations (scope, number, name, checksum, how) VALUES ${values};
SQL
  have=$(db "${MARIADB_DATABASE}" -sN -e "SELECT CONCAT(m.name, ' ', m.checksum, ' ', m.how) FROM ffs_setup_migrations m WHERE m.scope = 'sync' ORDER BY m.number")
  while read -r name sum how; do
    [ -n "${name}" ] || continue
    grep -q "^mysql/setup/sync/${name} ${sum}$" "${manifest}" || echo "WARNING: setup migration ${name} was recorded (${how}) with another checksum than this release's"
  done <<< "${have}"
  echo "✓ Setup migrations: version $(db "${MARIADB_DATABASE}" -sN -e "SELECT LPAD(MAX(number), 3, '0') FROM ffs_setup_migrations WHERE scope = 'sync'") ($(db "${MARIADB_DATABASE}" -sN -e "SELECT GROUP_CONCAT(DISTINCT how ORDER BY how) FROM ffs_setup_migrations WHERE scope = 'sync'"))"
}
record_setup || { echo "✗ ERROR: Failed to record the setup migrations"; exit 1; }

# Display current status
current_users=$(db "${MARIADB_DATABASE}" -sN -e 'SELECT COUNT(DISTINCT email) FROM users;')

max_users_in_db=$(db "${MARIADB_DATABASE}" -sN -e "SELECT config_value FROM config WHERE config_key='max_users';")

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