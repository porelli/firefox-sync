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
echo "Allowed accounts: ${SYNC_ALLOWED_ACCOUNTS:-(everyone)}"
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

# SYNC_ALLOWED_ACCOUNTS (docs/limits.md#sync_allowed_accounts), invite-only Sync: empty is off,
# everyone gets in. uid,uid... or fixed:uid,...: the list, set again on every start (read-only
# in the admin UI). initial:uid,... (admin: initial: with none): those added when the allowlist
# turns on (first start, new database), then managed in the admin UI. A uid is 32 hexadecimal
# characters (lowercased here). Anything else stops here, like SYNC_MAX_USERS
parse_allowed_accounts() {
  local value=${1//[[:space:]]/} list uid parts=()
  ALLOWED_MODE=off ALLOWED_UIDS=() ALLOWED_BAD=""
  case "${value}" in
    "") return 0 ;;
    admin) ALLOWED_MODE=initial; return 0 ;;
    initial:*) ALLOWED_MODE=initial; list=${value#initial:} ;;
    fixed:*) ALLOWED_MODE=fixed; list=${value#fixed:} ;;
    *) ALLOWED_MODE=fixed; list=${value} ;;
  esac
  IFS=, read -r -a parts <<< "${list}"
  for uid in ${parts[@]+"${parts[@]}"}; do
    [ -n "${uid}" ] || continue
    uid=${uid,,}
    [[ "${uid}" =~ ^[0-9a-f]{32}$ ]] || { ALLOWED_BAD=${uid}; return 1; }
    ALLOWED_UIDS+=("${uid}")
  done
  [ "${ALLOWED_MODE}" = initial ] || [ "${#ALLOWED_UIDS[@]}" -gt 0 ]
}

if ! parse_allowed_accounts "${SYNC_ALLOWED_ACCOUNTS:-}"; then
  if [ -n "${ALLOWED_BAD}" ]; then
    echo "✗ ERROR: SYNC_ALLOWED_ACCOUNTS='${SYNC_ALLOWED_ACCOUNTS}' is not valid: '${ALLOWED_BAD}' is not an account id"
    echo "  (32 hexadecimal characters, docs/limits.md#find-the-uid-of-an-account)"
  else
    echo "✗ ERROR: SYNC_ALLOWED_ACCOUNTS='${SYNC_ALLOWED_ACCOUNTS}' lists no account id: give the uids, comma-separated,"
    echo "  admin to approve them in the admin UI, or leave it empty to let everyone in"
  fi
  exit 1
fi

# allowed_sql: the statements of SYNC_ALLOWED_ACCOUNTS, after allowlist.sql. The list and on or
# off in one transaction (sync_allowed_accounts is InnoDB): fixed: exactly these uids; initial:
# these uids once, the first time an initial: list is applied (allowed_accounts_initial records
# it, as max_users' row does for SYNC_MAX_USERS=initial:; admin and fixed: do not set it). The trigger only while it is on (with it off,
# no trigger that could write a non-transactional table), created once and kept (its body only
# calls ffs_check_allowed_account): no start leaves the users table without it. Then the
# nodes' load counted again (every start, the allowlist on or off)
allowed_sql() {
  local uid rows="" now="CAST(UNIX_TIMESTAMP(CURRENT_TIMESTAMP(3)) * 1000 AS SIGNED)" first
  for uid in ${ALLOWED_UIDS[@]+"${ALLOWED_UIDS[@]}"}; do
    rows="${rows:+${rows} UNION ALL }SELECT '${uid}' AS uid"
  done
  first="NOT EXISTS (SELECT 1 FROM config WHERE config_key = 'allowed_accounts_initial')"
  # the trigger first: DDL commits by itself, and an 'on' committed before it would let an
  # unlisted account in, for good (it then has a row). Early it checks nothing: its procedure
  # reads allowed_accounts
  if [ "${ALLOWED_MODE}" != off ] && [ "${ALLOWED_TRIGGER}" = 0 ]; then
    printf '%s\n' "DELIMITER //" "CREATE TRIGGER BeforeInsertAllowedUser BEFORE INSERT ON users FOR EACH ROW PRECEDES BeforeInsertUser" \
      "BEGIN CALL ffs_check_allowed_account(NEW.email); END //" "DELIMITER ;"
  fi
  echo "START TRANSACTION;"
  if [ "${ALLOWED_MODE}" = fixed ]; then
    echo "DELETE FROM sync_allowed_accounts WHERE uid NOT IN ($(printf "'%s'," "${ALLOWED_UIDS[@]}" | sed 's/,$//'));"
    echo "INSERT IGNORE INTO sync_allowed_accounts (uid, note, added_at, added_by) SELECT v.uid, '', ${now}, 'SYNC_ALLOWED_ACCOUNTS' FROM (${rows}) v;"
  elif [ -n "${rows}" ]; then
    echo "INSERT IGNORE INTO sync_allowed_accounts (uid, note, added_at, added_by) SELECT v.uid, '', ${now}, 'SYNC_ALLOWED_ACCOUNTS' FROM (${rows}) v WHERE ${first};"
  fi
  # (initial: with uids; admin is initial: without)
  if [ "${ALLOWED_MODE}" = initial ] && [ -n "${rows}" ]; then
    echo "INSERT IGNORE INTO config (config_key, config_value) VALUES ('allowed_accounts_initial', 'applied');"
  fi
  echo "INSERT INTO config (config_key, config_value) VALUES ('allowed_accounts', '$([ "${ALLOWED_MODE}" = off ] && echo off || echo on)')"
  echo "  ON DUPLICATE KEY UPDATE config_value = VALUES(config_value);"
  echo "COMMIT;"
  if [ "${ALLOWED_MODE}" = off ]; then
    echo "DROP TRIGGER IF EXISTS BeforeInsertAllowedUser;"
  else
    [ -z "${rows}" ] || echo "DELETE FROM sync_refused_accounts WHERE uid IN (SELECT uid FROM sync_allowed_accounts);"
  fi
  echo "CALL ffs_resync_node_load(NULL);"
}

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

# Function to check if database is accessible; DB_ERROR: the first line of the client's error, when not
check_db_connection() {
  DB_ERROR=$(db --connect-timeout=5 -e "SELECT 1;" 2>&1 >/dev/null) && return 0
  DB_ERROR=$(printf '%s\n' "${DB_ERROR}" | head -n 1)
  return 1
}

# Function to check if a table exists
table_exists() {
  local table_name="$1"
  local count
  count=$(db "${MARIADB_DATABASE}" -sN \
                   -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${MARIADB_DATABASE}' AND table_name='${table_name}';" 2>/dev/null || echo "0")
  [ "${count}" = "1" ]
}

# Wait for database connection: MAX_WAIT seconds of the clock (a try that fails slowly, a name
# that does not resolve or an address that does not answer, counts too), the client's error
# each time it changes
echo "Checking database connection..."
SECONDS=0 connected="" last_error=""
while [ "${SECONDS}" -lt "${MAX_WAIT}" ]; do
  if check_db_connection; then
    echo "✓ Database connection established!"
    connected=1
    break
  fi
  [ "${DB_ERROR}" = "${last_error}" ] || echo "  ${DB_ERROR}"
  last_error=${DB_ERROR}
  echo "  Waiting for database... (${SECONDS}/${MAX_WAIT}s)"
  sleep ${SLEEP_INTERVAL}
done

if [ -z "${connected}" ]; then
  echo "✗ ERROR: Timeout waiting for database connection (${MARIADB_SERVER}:${MARIADB_SERVER_PORT}): ${DB_ERROR}"
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
# With your own server (SYNC_DB_CONTAINERS=0) db-bootstrap records them, never this. With the stack's database
# containers, which create the same users and grants themselves, they are recorded here
# (how 'containers'), so that the admin UI shows the version everywhere. A recorded file with
# another checksum: a warning (db-setup.sh stops on it with your own server)
record_setup() {
  local manifest=/scripts/setup-manifest path sum name values="" have
  # (with your own server db-bootstrap records them, from the files it ran: an init image newer
  # than those files must not record what never ran there)
  [ "${SYNC_DB_CONTAINERS:-1}" != 0 ] || return 0
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

# the allowlist (allowlist.sql, then SYNC_ALLOWED_ACCOUNTS). With it on, the refusals are kept
# in a table whose rows outlive the SIGNAL that refuses the account: Aria on MariaDB (crash-safe),
# MyISAM on MySQL when it is safe there, else InnoDB, where the accounts are refused but not
# listed as pending (docs/limits.md#sync_allowed_accounts):
# - MySQL with binary logging and enforce_gtid_consistency (on by default with binary logging
#   in MySQL 9; the stack's MySQL has none) refuses every INSERT into users once a trigger could
#   write MyISAM;
# - MyISAM is not crash-safe: only with myisam_recover_options set (the stack's MySQL has
#   BACKUP,FORCE), and checked and repaired here;
# - a server that gives another engine (enforce_storage_engine, disabled_storage_engines), or
#   any of these that cannot be read: InnoDB.
# Checked on every start: a table of before changes engine.
echo "Applying the allowlist (SYNC_ALLOWED_ACCOUNTS)..."
# a table of before (6356fcd, the allowlist on or off then): its columns since, and its initial:
# uids, if any, added then, not again (it had no allowed_accounts_initial)
column_of() { db "${MARIADB_DATABASE}" -sN -e "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = 'sync_refused_accounts' AND column_name = '$1';"; }
if [ "$(db "${MARIADB_DATABASE}" -sN -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'sync_refused_accounts';")" = 1 ]; then
  if [ "$(column_of reported_at)" = 0 ]; then
    echo "  sync_refused_accounts of before: reported_at added"
    db "${MARIADB_DATABASE}" -e "INSERT IGNORE INTO config (config_key, config_value) SELECT 'allowed_accounts_initial', 'applied' FROM DUAL WHERE EXISTS (SELECT 1 FROM sync_allowed_accounts);
      ALTER TABLE sync_refused_accounts ADD COLUMN reported_at BIGINT NULL;" || { echo "✗ ERROR: Failed to add reported_at to sync_refused_accounts"; exit 1; }
  fi
  if [ "$(column_of id)" = 0 ]; then
    db "${MARIADB_DATABASE}" -e "ALTER TABLE sync_refused_accounts ADD COLUMN id BIGINT NOT NULL AUTO_INCREMENT UNIQUE;" \
      || { echo "✗ ERROR: Failed to add id to sync_refused_accounts"; exit 1; }
  fi
fi
engine_of() { db "${MARIADB_DATABASE}" -sN -e "SELECT engine FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'sync_refused_accounts';" 2> /dev/null; }
ALLOWED_TRIGGER=0
if [ "${ALLOWED_MODE}" != off ]; then
  refused_engine=InnoDB why=""
  if [ "$(db "${MARIADB_DATABASE}" -sN -e "SELECT VERSION() LIKE '%MariaDB%';" 2> /dev/null)" = 1 ]; then
    refused_engine=Aria
  elif [ "$(db "${MARIADB_DATABASE}" -sN -e "SELECT (@@log_bin = 0 OR @@enforce_gtid_consistency = 'OFF') AND @@myisam_recover_options <> 'OFF';" 2> /dev/null)" = 1 ]; then
    refused_engine=MyISAM
  else
    why="MySQL with binary logging and enforce_gtid_consistency, or without myisam_recover_options"
  fi
  refused_table="CREATE TABLE IF NOT EXISTS sync_refused_accounts (uid VARCHAR(64) PRIMARY KEY, first_at BIGINT NOT NULL,
    last_at BIGINT NOT NULL, attempts INT NOT NULL DEFAULT 1, rejected_at BIGINT NULL, rejected_by VARCHAR(255) NULL, reported_at BIGINT NULL,
    id BIGINT NOT NULL AUTO_INCREMENT UNIQUE)"
  db "${MARIADB_DATABASE}" -e "${refused_table} ENGINE=${refused_engine} DEFAULT CHARSET=utf8mb4;" 2> /dev/null \
    || db "${MARIADB_DATABASE}" -e "${refused_table} DEFAULT CHARSET=utf8mb4;" || { echo "✗ ERROR: Failed to create sync_refused_accounts"; exit 1; }
  refused_now=$(engine_of)
  if [ "${refused_now,,}" != "${refused_engine,,}" ]; then
    db "${MARIADB_DATABASE}" -e "ALTER TABLE sync_refused_accounts ENGINE=${refused_engine};" 2> /dev/null || true
    refused_now=$(engine_of)
  fi
  if [ "${refused_now,,}" != "${refused_engine,,}" ]; then
    # (the server substituted another engine, or refused it)
    why="the server gives ${refused_now:-another engine} for ${refused_engine}"
    [ "${refused_now,,}" = innodb ] || db "${MARIADB_DATABASE}" -e "ALTER TABLE sync_refused_accounts ENGINE=InnoDB;" \
      || { echo "✗ ERROR: Failed to move sync_refused_accounts to InnoDB"; exit 1; }
    refused_now=InnoDB
  fi
  if [ "${refused_now,,}" = innodb ]; then
    [ -n "${why}" ] || why="the server has neither Aria nor a safe MyISAM"
    echo "WARNING: ${why}: accounts refused by SYNC_ALLOWED_ACCOUNTS are refused but not listed"
    echo "  as pending in the admin UI (allow them by their uid, docs/limits.md#sync_allowed_accounts)"
  else
    # not crash-safe (MyISAM) or crash-recovered (Aria): checked, repaired, else made again (it
    # only holds refusals)
    if [ "$(db "${MARIADB_DATABASE}" -sN -e "CHECK TABLE sync_refused_accounts;" | awk -F'\t' '$3 == "status" { print $4 }')" != OK ]; then
      echo "WARNING: sync_refused_accounts (${refused_now}) did not pass CHECK TABLE: repairing it"
      db "${MARIADB_DATABASE}" -e "REPAIR TABLE sync_refused_accounts;" > /dev/null || true
      if [ "$(db "${MARIADB_DATABASE}" -sN -e "CHECK TABLE sync_refused_accounts;" | awk -F'\t' '$3 == "status" { print $4 }')" != OK ]; then
        echo "WARNING: sync_refused_accounts could not be repaired: made again, its refusals lost"
        db "${MARIADB_DATABASE}" -e "DROP TABLE sync_refused_accounts; ${refused_table} ENGINE=${refused_now} DEFAULT CHARSET=utf8mb4;" \
          || { echo "✗ ERROR: Failed to create sync_refused_accounts again"; exit 1; }
      fi
    fi
  fi
  echo "  refusals kept in ${refused_now}"
  ALLOWED_TRIGGER=$(db "${MARIADB_DATABASE}" -sN -e "SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_schema = DATABASE() AND trigger_name = 'BeforeInsertAllowedUser';")
fi
if { cat /scripts/allowlist.sql; allowed_sql; } | db "${MARIADB_DATABASE}"; then
  echo "✓ Allowlist applied"
else
  echo "✗ ERROR: Failed to apply the allowlist (SYNC_ALLOWED_ACCOUNTS)"
  exit 1
fi

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
allowed_in_db=$(db "${MARIADB_DATABASE}" -sN -e 'SELECT COUNT(*) FROM sync_allowed_accounts;')
case "${ALLOWED_MODE}" in
  off) echo "SYNC_ALLOWED_ACCOUNTS empty: every account can sync (invite-only Sync is off)" ;;
  fixed) echo "SYNC_ALLOWED_ACCOUNTS: invite-only, the ${allowed_in_db} accounts listed (set on every start, read-only in the admin UI)" ;;
  initial) echo "SYNC_ALLOWED_ACCOUNTS=${SYNC_ALLOWED_ACCOUNTS//[[:space:]]/}: invite-only, ${allowed_in_db} accounts allowed, managed in the admin UI" ;;
esac
echo "=========================================="

exit 0