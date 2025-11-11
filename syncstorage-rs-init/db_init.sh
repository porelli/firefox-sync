#!/bin/bash
set -e  # Exit on error
set -u  # Exit on undefined variable

# Configuration
readonly MAX_WAIT=120  # Wait up to 2 minutes
readonly SLEEP_INTERVAL=2
readonly REQUIRED_TABLES=("users" "services" "nodes")
readonly SQL_TEMPLATE="/scripts/db_init.sql"
readonly SQL_FILE="/tmp/db_init_processed.sql"

echo "=========================================="
echo "Firefox Sync Database Initialization"
echo "=========================================="
echo "Domain: ${DOMAIN}"
echo "Max Users: ${MAX_USERS}"
echo "Database: ${MARIADB_DATABASE}"
echo "=========================================="

# Function to check if database is accessible
check_db_connection() {
  mariadb --host="${MARIADB_SERVER}" \
          --port="${MARIADB_SERVER_PORT}" \
          --user="${MARIADB_USER}" \
          --password="${MARIADB_PASSWORD}" \
          --connect-timeout=5 \
          -e "SELECT 1;" >/dev/null 2>&1
}

# Function to check if a table exists
table_exists() {
  local table_name="$1"
  local count
  count=$(mariadb --host="${MARIADB_SERVER}" \
                   --port="${MARIADB_SERVER_PORT}" \
                   --user="${MARIADB_USER}" \
                   --password="${MARIADB_PASSWORD}" \
                   "${MARIADB_DATABASE}" \
                   -sN \
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
    -e "s|@MAX_USERS@|${MAX_USERS}|g" \
    "${SQL_TEMPLATE}" > "${SQL_FILE}"

# Apply SQL initialization
echo "Applying database initialization..."
if mariadb --host="${MARIADB_SERVER}" \
           --port="${MARIADB_SERVER_PORT}" \
           --user="${MARIADB_USER}" \
           --password="${MARIADB_PASSWORD}" \
           "${MARIADB_DATABASE}" < "${SQL_FILE}"; then
  echo "✓ SQL initialization completed successfully!"
else
  echo "✗ ERROR: Failed to apply SQL initialization"
  exit 1
fi

# Display current status
current_users=$(mariadb --host="${MARIADB_SERVER}" \
                        --port="${MARIADB_SERVER_PORT}" \
                        --user="${MARIADB_USER}" \
                        --password="${MARIADB_PASSWORD}" \
                        "${MARIADB_DATABASE}" \
                        -sN \
                        -e 'SELECT COUNT(*) FROM users;')

max_users_in_db=$(mariadb --host="${MARIADB_SERVER}" \
                           --port="${MARIADB_SERVER_PORT}" \
                           --user="${MARIADB_USER}" \
                           --password="${MARIADB_PASSWORD}" \
                           "${MARIADB_DATABASE}" \
                           -sN \
                           -e "SELECT config_value FROM config WHERE config_key='max_users';")

echo ""
echo "=========================================="
echo "✓ Database initialization completed!"
echo "=========================================="
echo "Current users: ${current_users}"
echo "Max users (configured): ${max_users_in_db}"
echo "Domain: ${DOMAIN}"
echo ""
echo "Note: To change max_users, update MAX_USERS"
echo "in .env and restart the init container:"
echo "  docker compose up tokenserver_db_init"
echo "=========================================="

exit 0