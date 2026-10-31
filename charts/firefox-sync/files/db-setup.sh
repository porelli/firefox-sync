#!/bin/bash
# The setup migrations of your own database server (docs/databases.md#your-own-server): the
# numbered SQL files of db/<engine>/setup/<scope>/ (the databases, users and grants the stack
# needs there), applied or checked at every start of the stack, before the migrations of
# syncstorage-rs and of the accounts: the one-shot db-bootstrap (Sync) and fxa-db-bootstrap (the
# accounts), with the database server's client (the image of the database or of its backups),
# db/ mounted in /ffs-db (FFS_DB_DIR):
#
#   db-setup.sh sync | fxa          the start (below)
#   db-setup.sh pending <sync|fxa> [--passwords]
#                                   the SQL of the files your server lacks, and the INSERTs that
#                                   record them as run by hand (how 'manual'): the passwords as
#                                   <SETTING>, with --passwords filled in
#   db-setup.sh print <sync|fxa|sync-bootstrap|fxa-bootstrap> [--passwords]
#                                   the SQL of every file of the scope (with the INSERTs of sync
#                                   and fxa): prepare_environment.sh's database-setup.sql,
#                                   database-setup-fxa.sql, database-bootstrap*.sql. No server
#   db-setup.sh settings <mysql|postgres|fxa>   the placeholders and the settings of .env that fill them
#
# Scopes: sync (db/mysql/setup/sync: MariaDB and MySQL, FFS_DB_ENGINE unset or mariadb or
# mysql; db/postgres/setup/sync: FFS_DB_ENGINE=postgres), fxa (db/mysql/setup/fxa-mysql or
# fxa-mariadb, FFS_DB_ENGINE), and the bootstrap accounts' (sync-bootstrap, fxa-bootstrap), which
# their administrator runs. Each file runs once; the server records it in ffs_setup_migrations
# (the tokenserver database, PostgreSQL's Sync database, the accounts' ffs): number, name,
# checksum, when, how (bootstrap, manual, baseline, containers). The version is the highest
# number recorded, the release expects the highest one of its files. At the start:
#   - with SYNC_DB_BOOTSTRAP_USER and _PASSWORD (FXA_DB_BOOTSTRAP_*), an account that can create
#     users (docs/databases.md#the-bootstrap-account): the files not recorded yet are run as it,
#     in order, and recorded;
#   - without: files not recorded stop the start ("setup migrations NNN-MMM not applied"), with
#     their SQL (passwords as <SETTING>) and how to print it again;
#   - then the end state of every file is checked as the stack's own users (each one signs in,
#     has its grants, its databases exist; PostgreSQL: owners, connections): something missing
#     (a grant revoked by hand) is drift. The bootstrap runs the files again, once, and checks
#     again; without it the start stops, naming the statements;
#   - an install from before the setup migrations (nothing recorded): when the end state is
#     there, every file is recorded as it (how 'baseline'); otherwise the missing list;
#   - a file whose recorded checksum is not that of the file: an error (released files never
#     change); recorded numbers above this release's (an older release): a warning;
#   - with the stack's own database containers (SYNC_DB_CONTAINERS, FXA_DB_CONTAINERS not 0):
#     nothing here, the init container records the files (how 'containers').
# The result of each start is kept in ffs_setup_state for the admin UI. One start at a time per
# server (GET_LOCK, pg_advisory_lock: replicas of the chart). Fails closed: the migrations, the
# init container and the accounts do not start after a failure. The passwords are in the
# clients' environment (MYSQL_PWD, PGPASSWORD) and in the SQL on their input, never in their
# arguments.
set -u

DOC=docs/databases.md#when-a-release-needs-new-users-or-grants
DOC_BOOT=docs/databases.md#the-bootstrap-account
DIR=${FFS_DB_DIR:-/ffs-db}
fail() { echo "✗ ERROR: $*"; exit 1; }
warn() { echo "WARNING: $*"; }

# the placeholders of a template and the settings that fill them, "PLACEHOLDER SETTING"
# per line
sql_settings() {
  case "$1" in
    mysql) printf '%s\n' "SYNC_TOKENSERVER_DATABASE SYNC_TOKENSERVER_DB_NAME" "SYNC_TOKENSERVER_USER SYNC_TOKENSERVER_DB_USER" \
             "SYNC_TOKENSERVER_PASSWORD SYNC_TOKENSERVER_DB_PASSWORD" "SYNC_STORAGE_DATABASE SYNC_STORAGE_DB_NAME" \
             "SYNC_STORAGE_USER SYNC_STORAGE_DB_USER" "SYNC_STORAGE_PASSWORD SYNC_STORAGE_DB_PASSWORD" ;;
    postgres) printf '%s\n' "SYNC_POSTGRES_DATABASE SYNC_POSTGRES_NAME" "SYNC_POSTGRES_USER SYNC_POSTGRES_USER" \
                "SYNC_POSTGRES_PASSWORD SYNC_POSTGRES_PASSWORD" ;;
    fxa) printf '%s\n' "FXA_USER FXA_MYSQL_USER" "FXA_PASSWORD FXA_MYSQL_PASSWORD" "FXA_POLICY_USER FXA_MYSQL_POLICY_USER" \
           "FXA_POLICY_PASSWORD FXA_MYSQL_POLICY_PASSWORD" "FXA_ADMIN_PASSWORD FXA_ADMIN_DB_PASSWORD" ;;
    *) return 1 ;;
  esac
  case "$1" in
    mysql|postgres) printf '%s\n' "ADMIN_DATABASE ADMIN_DB_NAME" "ADMIN_USER ADMIN_DB_USER" "ADMIN_SYNC_USER ADMIN_DB_SYNC_USER" \
                      "ADMIN_PASSWORD ADMIN_DB_PASSWORD" ;;
  esac
}

usage() {
  echo "usage: $0 <sync|fxa> | pending <sync|fxa> [--passwords] | print <sync|fxa|sync-bootstrap|fxa-bootstrap> [--passwords] | settings <mysql|postgres|fxa>" >&2
  exit 2
}
ACTION=start PASSWORDS=0
case "${1:-}" in
  settings) sql_settings "${2:-}" || usage; exit 0 ;;
  sync|fxa) SCOPE=$1 ;;
  pending) ACTION=pending SCOPE=${2:-}; case "${SCOPE}" in sync|fxa) ;; *) usage ;; esac ;;
  print) ACTION=print SCOPE=${2:-}; case "${SCOPE}" in sync|fxa|sync-bootstrap|fxa-bootstrap) ;; *) usage ;; esac ;;
  *) usage ;;
esac
if [ "${ACTION}" != start ]; then
  case "${3:-}" in --passwords) PASSWORDS=1 ;; "") ;; *) usage ;; esac
fi
MAIN=${SCOPE%-bootstrap}

if [ "${MAIN}" = sync ]; then
  ENGINE=${FFS_DB_ENGINE:-mariadb} CONTAINERS=${SYNC_DB_CONTAINERS:-1}
  KIND=$([ "${ENGINE}" = postgres ] && echo postgres || echo mysql)
  WHAT="the Sync databases" FILE=database-setup.sql
  SETUP_DIR=${DIR}/${KIND}/setup/${SCOPE}
else
  ENGINE=${FFS_DB_ENGINE:-mysql} CONTAINERS=${FXA_DB_CONTAINERS:-1} KIND=fxa
  WHAT="the accounts' databases" FILE=database-setup-fxa.sql
  SETUP_DIR=${DIR}/mysql/setup/$([ "${SCOPE}" = fxa ] && echo "fxa-${ENGINE}" || echo fxa-bootstrap)
fi
case "${ENGINE}" in mariadb|mysql|postgres) ;; *) fail "FFS_DB_ENGINE: mariadb, mysql or postgres, not '${ENGINE}'" ;; esac
[ "${KIND}" != fxa ] || [ "${ENGINE}" != postgres ] || fail "the accounts run on MySQL or MariaDB only (FFS_DB_ENGINE)"
case "${SCOPE}" in sync-bootstrap) FILE=database-bootstrap.sql ;; fxa-bootstrap) FILE=database-bootstrap-fxa.sql ;; esac
USER_SETTING=$([ "${MAIN}" = sync ] && echo SYNC || echo FXA)_DB_BOOTSTRAP_USER
PASSWORD_SETTING=${USER_SETTING%_USER}_PASSWORD
BOOT_USER=${!USER_SETTING:-} BOOT_PASSWORD=${!PASSWORD_SETTING:-}
# (both end up in SQL and in the clients' messages: checked before any use)
[[ -z "${BOOT_USER}" || "${BOOT_USER}" =~ ^[A-Za-z0-9_]{1,32}$ ]] || fail "${USER_SETTING} '${BOOT_USER}': A-Z, a-z, 0-9 and _ only, at most 32"
[[ -z "${BOOT_PASSWORD}" || "${BOOT_PASSWORD}" =~ ^[A-Za-z0-9._~-]+$ ]] || fail "${PASSWORD_SETTING}: only A-Z a-z 0-9 . _ ~ -"

if [ "${ACTION}" = start ] && [ "${CONTAINERS}" != 0 ]; then
  echo "${WHAT}: the stack's own database containers, nothing to do here (the init container records the setup migrations)"
  exit 0
fi
if [ -n "${BOOT_USER}" ] && [ -z "${BOOT_PASSWORD}" ]; then
  fail "${USER_SETTING} is set, ${PASSWORD_SETTING} is empty: set both, or neither (docs/databases.md#let-the-stack-apply-them)"
elif [ -z "${BOOT_USER}" ] && [ -n "${BOOT_PASSWORD}" ]; then
  fail "${PASSWORD_SETTING} is set, ${USER_SETTING} is empty: set both, or neither (docs/databases.md#let-the-stack-apply-them)"
fi
# a setting under both names (FFS_BOTH_ENV_NAMES, compose; the new one wins, often a line added
# from .env-example): refused, as the migrations and the init container refuse it
if [ -n "${FFS_BOTH_ENV_NAMES:-}" ]; then
  for pair in ${FFS_BOTH_ENV_NAMES}; do
    echo "ERROR: ${pair%%/*} and ${pair#*/} are both set (in .env or in the environment docker compose runs in): run ./prepare_environment.sh --upgrade for .env, or unset ${pair#*/} in your shell (docs/upgrading.md#renamed-settings)"
  done
  exit 1
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ffs-db-setup.XXXXXX") || exit 1
trap 'rm -rf "${WORK}"' EXIT
chmod 700 "${WORK}"

# ---- the files of the scope: NNN-name.sql, in order. The shell of prepare_environment.sh
# runs this part (print) too: bash 3.2 and BSD tools there, nothing newer before the server
# part below
sum256() {
  if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f 1; else shasum -a 256 "$1" | cut -d ' ' -f 1; fi
}
NUMBERS=() NAMES=() SUMS=()
[ -d "${SETUP_DIR}" ] || fail "no ${SETUP_DIR}: the deployment mounts db/ in ${DIR}"
for path in "${SETUP_DIR}"/*.sql; do
  [ -e "${path}" ] || continue
  name=${path##*/}
  [[ "${name}" =~ ^([0-9]{3})-[a-z0-9-]+\.sql$ ]] || fail "${path}: not a setup migration's name (NNN-name.sql)"
  number=$((10#${BASH_REMATCH[1]}))
  [ "${#NUMBERS[@]}" = 0 ] || [ "${number}" -gt "${NUMBERS[${#NUMBERS[@]}-1]}" ] || fail "${path}: two setup migrations numbered ${BASH_REMATCH[1]}"
  NUMBERS+=("${number}") NAMES+=("${name}") SUMS+=("$(sum256 "${path}")")
done
[ "${#NUMBERS[@]}" != 0 ] || fail "no setup migrations in ${SETUP_DIR}"
EXPECTED=${NUMBERS[${#NUMBERS[@]}-1]}
nnn() { printf '%03d' "$1"; }
# "001-003" (or "002") of the numbers given
span() { if [ "$#" = 1 ]; then nnn "$1"; else echo "$(nnn "$1")-$(nnn "${!#}")"; fi; }

# the settings that fill the placeholders: "PLACEHOLDER SETTING" lines, the bootstrap
# account's own of its scope
placeholders() {
  sql_settings "${KIND}"
  case "${SCOPE}" in *-bootstrap) printf '%s\n' "BOOTSTRAP_USER ${USER_SETTING}" "BOOTSTRAP_PASSWORD ${PASSWORD_SETTING}" ;; esac
}
# sed scripts: on the input of sed (a file), never in its arguments
sed_file() { # <script> <file...>
  local script
  script=$(mktemp "${WORK}/sed.XXXXXX") || exit 1
  printf '%s\n' "$1" > "${script}"
  shift
  sed -f "${script}" "$@"
  rm -f "${script}"
}
# the values of the settings, checked once: names and passwords as
# docs/databases.md#create-the-databases-and-users allows them, they end up in SQL
EXEC_SCRIPT="" SHOW_SCRIPT=""
while read -r placeholder setting; do
  value=${!setting:-}
  if [[ "${setting}" == *PASSWORD ]]; then
    case "${value}" in *"<REPLACE_WITH_"*) fail "${setting} is still the placeholder of .env-example: set it in .env" ;; esac
    [[ -z "${value}" || "${value}" =~ ^[A-Za-z0-9._~-]+$ ]] || fail "${setting}: only A-Z a-z 0-9 . _ ~ - (docs/databases.md#create-the-databases-and-users)"
    SHOW_SCRIPT="${SHOW_SCRIPT}s|@${placeholder}@|<${setting}>|g
"
  else
    if [ "${setting}" = "${USER_SETTING}" ]; then
      [[ -z "${value}" || "${value}" =~ ^[A-Za-z0-9_]{1,32}$ ]] || fail "${setting} '${value}': A-Z, a-z, 0-9 and _ only, at most 32"
    else
      [[ -z "${value}" || "${value}" =~ ^[a-z_][a-z0-9_]{0,31}$ ]] || fail "${setting} '${value}': a-z, 0-9 and _ only (docs/databases.md#create-the-databases-and-users)"
    fi
    SHOW_SCRIPT="${SHOW_SCRIPT}s|@${placeholder}@|${value}|g
"
  fi
  EXEC_SCRIPT="${EXEC_SCRIPT}s|@${placeholder}@|${value}|g
"
done < <(placeholders)
# render <file> <run> <shown>: the file filled in, with the passwords (what runs) and with
# <SETTING> for them (what the messages and the logs say). The parts of a file the settings
# leave out: without ADMIN_DB_PASSWORD (an install from before it) what follows "-- The admin
# UI:" (the admin UI keeps its tables in the tokenserver database); the accounts on MySQL with
# mysql_native_password (FXA_MYSQL_ARGS, an accounts image without mozilla/fxa#21554) the
# "-- native:" lines instead of those after them; without a policy user (FXA_MYSQL_POLICY_USER)
# its grants to FXA_MYSQL_USER, as docs/reference/database-users.md#the-accounts says; without
# FXA_ADMIN_DB_PASSWORD (optional, fxa-policy then creates no ffs_admin) its lines; the bootstrap
# accounts' "-- MySQL: " lines on MySQL only
render() {
  local file=$1 run=$2 shown=$3 source=${WORK}/source.sql step=${WORK}/step.sql missing setting
  cp "${file}" "${source}" || exit 1
  if [ "${MAIN}" = sync ] && [ -z "${ADMIN_DB_PASSWORD:-}" ]; then
    # shellcheck disable=SC2016 # (sed's $)
    sed_file '/^-- The admin UI:/,$d' "${source}" > "${step}" && mv "${step}" "${source}"
  fi
  if [ "${SCOPE}" = fxa ]; then
    if [ "${ENGINE}" = mysql ] && [[ "${FXA_MYSQL_ARGS:-}" == *mysql_native_password* ]]; then
      sed_file '/^-- native: /{
s/^-- native: //
n
d
}' "${source}" > "${step}" && mv "${step}" "${source}"
    fi
    if [ -z "${FXA_MYSQL_POLICY_USER:-}" ]; then
      sed_file '/^CREATE USER .*@FXA_POLICY_USER@/d
/^ALTER USER .*@FXA_POLICY_USER@/d
s/@FXA_POLICY_USER@/@FXA_USER@/g' "${source}" > "${step}" && mv "${step}" "${source}"
    fi
    if [ -z "${FXA_ADMIN_DB_PASSWORD:-}" ]; then
      sed_file '/@FXA_ADMIN_PASSWORD@/d' "${source}" > "${step}" && mv "${step}" "${source}"
    fi
  fi
  # the bootstrap accounts on MySQL: the "-- MySQL: " lines (mysql.global_grants, which MariaDB has not)
  case "${SCOPE}" in *-bootstrap)
    [ "${ENGINE}" != mysql ] || { sed_file 's/^-- MySQL: //' "${source}" > "${step}" && mv "${step}" "${source}"; } ;;
  esac
  # a placeholder whose setting is empty
  missing=$(grep -o '@[A-Z_]*@' "${source}" | sort -u | tr -d '@' | while read -r placeholder; do
    setting=$(placeholders | while read -r p s; do [ "${p}" = "${placeholder}" ] && echo "${s}"; done)
    [ -z "${setting}" ] || [ -n "${!setting:-}" ] || echo "${setting}"
  done | head -n 1)
  [ -z "${missing}" ] || fail "${missing} is empty: set it in .env"
  (umask 077; sed_file "${EXEC_SCRIPT}" "${source}" > "${run}") || exit 1
  sed_file "${SHOW_SCRIPT}" "${source}" > "${shown}" || exit 1
  ! grep -q '@[A-Z_]*@' "${run}" || fail "${file} has placeholders this script does not know: $(grep -o '@[A-Z_]*@' "${run}" | sort -u | tr '\n' ' ')"
}
mkdir -p "${WORK}/run" "${WORK}/shown"
for i in "${!NUMBERS[@]}"; do
  render "${SETUP_DIR}/${NAMES[i]}" "${WORK}/run/${NAMES[i]}" "${WORK}/shown/${NAMES[i]}"
done

# ---- where the record is: the tokenserver database (PostgreSQL: the Sync database, its owner's
# tables), the accounts' ffs. Not the admin UI's database: it is optional, and the init
# container (as the Sync server's user) records there with the stack's database containers
if [ "${MAIN}" = fxa ]; then RECORD_DB=ffs
elif [ "${ENGINE}" = postgres ]; then RECORD_DB=${SYNC_POSTGRES_NAME:-}
else RECORD_DB=${SYNC_TOKENSERVER_DB_NAME:-}
fi
# record_sql <how> <numbers...>: the tables (when missing) and an INSERT per file (one
# recorded already stays as it is)
record_sql() {
  local how=$1 n i q=""
  shift
  if [ "${ENGINE}" = postgres ]; then
    echo "CREATE TABLE IF NOT EXISTS public.ffs_setup_migrations (scope VARCHAR(32) NOT NULL, number INTEGER NOT NULL, name VARCHAR(128) NOT NULL, checksum CHAR(64) NOT NULL, how VARCHAR(16) NOT NULL, applied_at TIMESTAMPTZ NOT NULL DEFAULT now(), PRIMARY KEY (scope, number));"
    echo "CREATE TABLE IF NOT EXISTS public.ffs_setup_state (scope VARCHAR(32) PRIMARY KEY, result VARCHAR(16) NOT NULL, expected INTEGER NOT NULL, detail TEXT NOT NULL, checked_at TIMESTAMPTZ NOT NULL DEFAULT now());"
  else
    q="\`${RECORD_DB}\`."
    [ "${MAIN}" = sync ] || echo "CREATE DATABASE IF NOT EXISTS \`ffs\`;"
    echo "CREATE TABLE IF NOT EXISTS ${q}ffs_setup_migrations (scope VARCHAR(32) NOT NULL, number INT NOT NULL, name VARCHAR(128) NOT NULL, checksum CHAR(64) NOT NULL, how VARCHAR(16) NOT NULL, applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (scope, number));"
    echo "CREATE TABLE IF NOT EXISTS ${q}ffs_setup_state (scope VARCHAR(32) PRIMARY KEY, result VARCHAR(16) NOT NULL, expected INT NOT NULL, detail TEXT NOT NULL, checked_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP);"
  fi
  for n in "$@"; do
    for i in "${!NUMBERS[@]}"; do
      [ "${NUMBERS[i]}" = "${n}" ] || continue
      if [ "${ENGINE}" = postgres ]; then
        echo "INSERT INTO public.ffs_setup_migrations (scope, number, name, checksum, how) VALUES ('${SCOPE}', ${n}, '${NAMES[i]}', '${SUMS[i]}', '${how}') ON CONFLICT DO NOTHING;"
      else
        echo "INSERT IGNORE INTO ${q}ffs_setup_migrations (scope, number, name, checksum, how) VALUES ('${SCOPE}', ${n}, '${NAMES[i]}', '${SUMS[i]}', '${how}');"
      fi
    done
  done
}
# sql_of <numbers...>: the SQL of these files as a by-hand run takes it (passwords as <SETTING>,
# with --passwords filled in), then the INSERTs that record them (how 'manual')
sql_of() {
  local dir=shown n i
  [ "${PASSWORDS}" = 1 ] && dir=run
  for n in "$@"; do
    for i in "${!NUMBERS[@]}"; do
      [ "${NUMBERS[i]}" = "${n}" ] || continue
      echo "-- ==== setup migration ${NAMES[i]} (scope ${SCOPE})"
      cat "${WORK}/${dir}/${NAMES[i]}"
    done
  done
  case "${SCOPE}" in *-bootstrap) return 0 ;; esac
  echo "-- ==== the record of the setup migrations above (ffs_setup_migrations, docs/databases.md#the-record-of-the-setup-migrations)"
  if [ "${ENGINE}" = postgres ]; then
    # (in the Sync database, as its owner: the tables are its own)
    echo "\\connect ${SYNC_POSTGRES_NAME}"
    echo "SET ROLE ${SYNC_POSTGRES_USER};"
    record_sql manual "$@"
    echo "RESET ROLE;"
  else
    record_sql manual "$@"
  fi
}

if [ "${ACTION}" = print ]; then
  echo "-- ${FILE}: the setup migrations $(span "${NUMBERS[@]}") of scope ${SCOPE} (db/db-setup.sh print ${SCOPE}),"
  echo "-- filled in from the settings. Run as the server's administrator (docs/databases.md#create-the-databases-and-users)."
  sql_of "${NUMBERS[@]}"
  exit 0
fi

# ==== the server (the containers' bash and clients from here on)
if [ "${MAIN}" = fxa ]; then
  # (the certificate not checked: the accounts connect without TLS, on a trusted network)
  MAIN_HOST=${FXA_MYSQL_HOST:-} MAIN_PORT=${FXA_MYSQL_PORT:-3306} TLS_VERIFY=false
elif [ "${ENGINE}" = postgres ]; then
  MAIN_HOST=${SYNC_POSTGRES_HOST:-} MAIN_PORT=${SYNC_POSTGRES_PORT:-5432}
else
  MAIN_HOST=${SYNC_TOKENSERVER_DB_HOST:-} MAIN_PORT=${SYNC_TOKENSERVER_DB_PORT:-3306} TLS_VERIFY=${SYNC_DB_TLS_VERIFY:-true}
  STORAGE_HOST=${SYNC_STORAGE_DB_HOST:-${MAIN_HOST}} STORAGE_PORT=${SYNC_STORAGE_DB_PORT:-${MAIN_PORT}}
fi
[ -n "${MAIN_HOST}" ] || fail "no host of ${WHAT}: set it in .env"
[ -n "${RECORD_DB}" ] || fail "no database name of ${WHAT}: set it in .env"
# the host of a database (mariadb, mysql): "<host> <port>"
db_server() {
  if [ "${MAIN}" = sync ] && [ "$1" = "${SYNC_STORAGE_DB_NAME:-}" ]; then echo "${STORAGE_HOST} ${STORAGE_PORT}"; else echo "${MAIN_HOST} ${MAIN_PORT}"; fi
}
# the account that reads and writes the record: the bootstrap's, or the stack's own user of
# that database (MySQL: the tokenserver's; the accounts': the policy user, FXA_MYSQL_USER
# without one; PostgreSQL: the owner of the Sync database)
if [ -n "${BOOT_USER}" ]; then
  REC_USER=${BOOT_USER} REC_PASSWORD=${BOOT_PASSWORD}
elif [ "${MAIN}" = fxa ]; then
  REC_USER=${FXA_MYSQL_POLICY_USER:-${FXA_MYSQL_USER:-}} REC_PASSWORD=${FXA_MYSQL_POLICY_USER:+${FXA_MYSQL_POLICY_PASSWORD:-}}
  [ -n "${FXA_MYSQL_POLICY_USER:-}" ] || REC_PASSWORD=${FXA_MYSQL_PASSWORD:-}
elif [ "${ENGINE}" = postgres ]; then
  REC_USER=${SYNC_POSTGRES_USER:-} REC_PASSWORD=${SYNC_POSTGRES_PASSWORD:-}
else
  REC_USER=${SYNC_TOKENSERVER_DB_USER:-} REC_PASSWORD=${SYNC_TOKENSERVER_DB_PASSWORD:-}
fi

# ---- MariaDB and MySQL clients
CLIENT=mariadb ADMIN_CLIENT=mariadb-admin
command -v mariadb > /dev/null 2>&1 || CLIENT=mysql ADMIN_CLIENT=mysqladmin
TLS_ARGS=()
# MariaDB's client checks the server's certificate by default: false with MySQL's
# self-signed one (SYNC_DB_TLS_VERIFY, as the init container). MySQL's client does not check it
[ "${CLIENT}" = mariadb ] && [ "${TLS_VERIFY:-true}" = false ] && TLS_ARGS=(--skip-ssl-verify-server-cert)
# my_sql <user> <password> <host> <port> [client args]: SQL on stdin, the password in the client's environment
my_sql() {
  local user=$1 password=$2 host=$3 port=$4
  shift 4
  MYSQL_PWD="${password}" "${CLIENT}" --protocol=tcp --connect-timeout=10 -h "${host}" -P "${port}" -u "${user}" ${TLS_ARGS[@]+"${TLS_ARGS[@]}"} "$@"
}
# my_q <user> <password> <host> <port> <query>: its rows, raw, tab-separated; failing, the
# client's error (the clients' warnings left out)
my_q() {
  local err=${WORK}/q.err
  my_sql "$1" "$2" "$3" "$4" -N -B -r -e "$5" < /dev/null 2> "${err}" && return 0
  grep -v '^WARNING\|\[Warning\]' "${err}"
  return 1
}
# the statements of a file, one per line, without the comments (the files have no ; in a value)
statements() {
  grep -v '^[[:space:]]*--' "$1" | grep -v '^[\]' | tr '\n' ' ' | sed -e 's/;[[:space:]]*/;\n/g' | sed -e 's/^[[:space:]]*//; s/[[:space:]][[:space:]]*/ /g' | grep -v '^$'
}
# ---- PostgreSQL: pg_q <user> <password> <database> <query>, pg_catalog alone in the search
# path (nothing of the public schema stands in for a name)
pg_sql() {
  local err=${WORK}/q.err
  PGPASSWORD="$2" PGCONNECT_TIMEOUT=10 psql -X -h "${MAIN_HOST}" -p "${MAIN_PORT}" -U "$1" -d "$3" -v ON_ERROR_STOP=1 -tA "${@:4}" < /dev/null 2> "${err}" && return 0
  grep -v '^NOTICE' "${err}"
  return 1
}
pg_q() { pg_sql "$1" "$2" "$3" -c "SET search_path = pg_catalog, pg_temp; $4" | tail -n 1; }

# wait for a server (up to 5 minutes): it answers, the login refused or not
wait_server() {
  local host=$1 port=$2 deadline out
  deadline=$(( $(date +%s) + 300 ))
  if [ "${ENGINE}" = postgres ]; then
    until out=$(pg_isready -h "${host}" -p "${port}" -t 5 2>&1); do
      [ "$(date +%s)" -lt "${deadline}" ] || fail "${host}:${port} does not answer: ${out}"
      sleep 2
    done
  else
    until out=$("${ADMIN_CLIENT}" --connect-timeout=5 --protocol=tcp -h "${host}" -P "${port}" ${TLS_ARGS[@]+"${TLS_ARGS[@]}"} ping 2>&1); do
      [ "$(date +%s)" -lt "${deadline}" ] || fail "${host}:${port} does not answer: ${out}"
      sleep 2
    done
  fi
}
# the clients' messages without a password: each one of the settings as <SETTING> (MariaDB's
# client repeats the failing statement, psql its line)
redact() {
  local line placeholder setting value
  while IFS= read -r line; do
    while read -r placeholder setting; do
      value=${!setting:-}
      [[ "${setting}" == *PASSWORD && -n "${value}" ]] && line=${line//"${value}"/<${setting}>}
    done < <(placeholders)
    [ -z "${BOOT_PASSWORD}" ] || line=${line//"${BOOT_PASSWORD}"/<${PASSWORD_SETTING}>}
    printf '  %s\n' "${line}"
  done
}

# ---- the privileges of a MariaDB or MySQL account, from SHOW GRANTS (role grants expanded:
# what information_schema shows misses them, and names a database by its pattern, fxa\_oauth).
# grants_of <user> <password> <host> <port> [all]: lines of
#   G <priv> <Y|N>           on the whole server (*.*)
#   D <pattern> <priv> <Y|N> on the databases of a pattern (`fxa\_oauth`.*, `fx%`.*)
#   X <pattern> <priv>       a partial revoke (MySQL)
#   T <object> <privileges>  on a table or its columns
#   R <role>                 a role
#   P <line>                 a proxy grant
#   U <line>                 a GRANT or REVOKE line not understood
# with the privileges of the roles a session has at sign-in (the default ones); all: of every
# role granted (any of them a SET ROLE away)
grants_of() {
  local user=$1 password=$2 host=$3 port=$4 every=${5:-} out roles line r using
  local -a lines=() direct=()
  out=$(my_q "${user}" "${password}" "${host}" "${port}" 'SHOW GRANTS') || { printf '%s\n' "${out}" >&2; return 1; }
  mapfile -t lines <<< "${out}"
  for line in "${lines[@]}"; do
    # a role granted: GRANT `r`@`%` TO ... (MySQL), GRANT `r` TO `u`@`%` (MariaDB)
    if [[ "${line}" =~ ^GRANT\ (\`[^\`]+\`(@\`[^\`]*\`)?(,\ \`[^\`]+\`(@\`[^\`]*\`)?)*)\ TO\ \`${user}\`@ ]]; then
      direct+=("${BASH_REMATCH[1]}")
    fi
  done
  if [ "${#direct[@]}" != 0 ]; then
    if [ "${CLIENT}" = mysql ] || ! my_q "${user}" "${password}" "${host}" "${port}" 'SELECT VERSION()' | grep -qi mariadb; then
      # MySQL: USING expands the roles named (theirs too); at sign-in: CURRENT_ROLE()
      if [ -n "${every}" ]; then
        using=$(IFS=,; echo "${direct[*]}")
      else
        using=$(my_q "${user}" "${password}" "${host}" "${port}" 'SELECT CURRENT_ROLE()')
        [ "${using}" != NONE ] || using=""
      fi
      if [ -n "${using}" ]; then
        out=$(my_q "${user}" "${password}" "${host}" "${port}" "SHOW GRANTS FOR CURRENT_USER() USING ${using}") || { printf '%s\n' "${out}" >&2; return 1; }
        mapfile -t lines <<< "${out}"
      fi
    elif [ -n "${every}" ]; then
      # MariaDB: SHOW GRANTS has the default role's (and those it has); every role: SET ROLE
      for roles in "${direct[@]}"; do
        while IFS= read -r r; do
          [ -n "${r}" ] || continue
          out=$(my_q "${user}" "${password}" "${host}" "${port}" "SET ROLE ${r}; SHOW GRANTS FOR CURRENT_ROLE") || { printf '%s\n' "${out}" >&2; return 1; }
          mapfile -t -O "${#lines[@]}" lines <<< "${out}"
        # shellcheck disable=SC2016 # (backticks of the role names, not commands)
        done < <(grep -o '`[^`]*`' <<< "${roles//, /$'\n'}" | grep -v '^``$')
      done
    fi
  fi
  for line in "${lines[@]}"; do
    local privs obj grantable=N p kind=
    if [[ "${line}" =~ ^GRANT\ PROXY\ ON ]]; then echo "P ${line%% TO *}"; continue; fi
    if [[ "${line}" =~ ^(GRANT|REVOKE)\ (.+)\ ON\ (\*\.\*|\`[^\`]*\`\.\*|\`[^\`]*\`\.\`[^\`]*\`|[^ ]+)\ (TO|FROM)\  ]]; then
      kind=${BASH_REMATCH[1]} privs=${BASH_REMATCH[2]} obj=${BASH_REMATCH[3]}
      [[ "${line}" == *" WITH GRANT OPTION"* ]] && grantable=Y
      if [[ "${obj}" == \`*\`.\* ]]; then
        obj=${obj#\`} obj=${obj%\`.\*}
      elif [ "${obj}" != '*.*' ]; then
        echo "T ${obj} ${privs}"; continue
      fi
      while IFS= read -r p; do
        p=${p# } p=${p% }
        [ -n "${p}" ] || continue
        if [ "${kind}" = REVOKE ]; then echo "X ${obj} ${p}"
        elif [ "${obj}" = '*.*' ]; then echo "G ${p} ${grantable}"
        else echo "D ${obj} ${p} ${grantable}"
        fi
      done <<< "${privs//,/$'\n'}"
    elif [[ "${line}" =~ ^GRANT\ (\`[^\`]+\`(@\`[^\`]*\`)?(,\ \`[^\`]+\`(@\`[^\`]*\`)?)*)\ TO\  ]]; then
      echo "R ${BASH_REMATCH[1]}"
    elif [[ "${line}" =~ ^(GRANT|REVOKE)\  ]]; then
      # (not understood: the bootstrap's check counts it as too much; the password's hash cut off)
      echo "U ${line%% IDENTIFIED *}"
    fi
  done
}
# matches <database> <pattern>: the pattern of a database grant names it (_ and % are wildcards,
# \_ and \% the characters)
matches() {
  local db=$1 pattern=$2 glob="" c i
  for ((i = 0; i < ${#pattern}; i++)); do
    c=${pattern:i:1}
    case "${c}" in
      \\) i=$((i + 1)); c=${pattern:i:1}; glob="${glob}[${c}]" ;;
      _) glob="${glob}?" ;;
      %) glob="${glob}*" ;;
      \*|\?|\[|\]) glob="${glob}[${c}]" ;;
      *) glob="${glob}${c}" ;;
    esac
  done
  # shellcheck disable=SC2053 # (a glob, on purpose)
  [[ "${db}" == ${glob} ]]
}
# every database-level privilege of ALL PRIVILEGES on MySQL 8.4+ and MariaDB 10.10+
ALL_PRIVILEGES="SELECT,INSERT,UPDATE,DELETE,CREATE,DROP,REFERENCES,INDEX,ALTER,CREATE TEMPORARY TABLES,LOCK TABLES,EXECUTE,CREATE VIEW,SHOW VIEW,CREATE ROUTINE,ALTER ROUTINE,EVENT,TRIGGER"
# lacks <grants> <database> <privileges, comma-separated> [grant]: those of the privileges
# the grants do not give on the database (GRANT OPTION too with grant), comma-separated
lacks() {
  local grants=$1 db=$2 privs=$3 option=${4:-} priv l d a have
  local -a missing=()
  [ "${privs}" = "ALL PRIVILEGES" ] && privs=${ALL_PRIVILEGES}
  while IFS= read -r priv; do
    priv=${priv# } priv=${priv% }
    [ -n "${priv}" ] || continue
    have=""
    while IFS= read -r l; do
      case "${l}" in
        "G ${priv} "[YN]|"G ALL PRIVILEGES "[YN]) have=1 ;;
        "D "*)
          d=${l#D } a=${d%% *} d=${d#* } d=${d% [YN]}
          if [ "${d}" = "${priv}" ] || [ "${d}" = "ALL PRIVILEGES" ]; then matches "${db}" "${a}" && have=1; fi ;;
      esac
    done <<< "${grants}"
    # (MySQL's partial revokes)
    while IFS= read -r l; do
      case "${l}" in
        "X "*)
          d=${l#X } a=${d%% *} d=${d#* }
          if [ "${a}" = "${db}" ] && { [ "${d}" = "${priv}" ] || [ "${d}" = "ALL PRIVILEGES" ]; }; then have=""; fi ;;
      esac
    done <<< "${grants}"
    [ -n "${have}" ] || missing+=("${priv}")
  done <<< "${privs//,/$'\n'}"
  if [ -n "${option}" ]; then
    have=""
    while IFS= read -r l; do
      case "${l}" in
        "G "*" Y") have=1 ;;
        "D "*" Y") d=${l#D } a=${d%% *}; matches "${db}" "${a}" && have=1 ;;
      esac
    done <<< "${grants}"
    [ -n "${have}" ] || missing+=("GRANT OPTION")
  fi
  [ "${#missing[@]}" = 0 ] || printf '%s\n' "${missing[@]}" | paste -sd ',' - | sed -e 's/,/, /g'
}

# ---- the end state of every file: PROBLEMS (each with the statement that gives it), the
# warnings printed as they come
PROBLEMS=()
problem() { PROBLEMS+=("$1"); }
ALL_RUN=${WORK}/all-run.sql ALL_SHOWN=${WORK}/all-shown.sql
for i in "${!NAMES[@]}"; do cat "${WORK}/run/${NAMES[i]}"; done > "${ALL_RUN}"
for i in "${!NAMES[@]}"; do cat "${WORK}/shown/${NAMES[i]}"; done > "${ALL_SHOWN}"
mysql_check() {
  local -a run shown
  local i s user db privs grantable server lack key out
  local -A passwords=() created=() altered=() signed=() grants=() checked_db=()
  mapfile -t run < <(statements "${ALL_RUN}")
  mapfile -t shown < <(statements "${ALL_SHOWN}")
  # the users and their passwords
  for i in "${!run[@]}"; do
    s=${run[i]}
    if [[ "${s}" =~ ^CREATE\ USER\ IF\ NOT\ EXISTS\ \'([^\']+)\'@\'[^\']*\'\ IDENTIFIED\ (BY|WITH\ [a-z_]+\ BY)\ \'([^\']*)\'\;$ ]]; then
      passwords[${BASH_REMATCH[1]}]=${BASH_REMATCH[3]} created[${BASH_REMATCH[1]}]=${shown[i]}
    elif [[ "${s}" =~ ^CREATE\ USER\ IF\ NOT\ EXISTS\ \'([^\']+)\'@\'[^\']*\'\ IDENTIFIED\ VIA\ [a-z_]+\ USING\ PASSWORD\(\'([^\']*)\'\)\;$ ]]; then
      passwords[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]} created[${BASH_REMATCH[1]}]=${shown[i]}
    elif [[ "${s}" =~ ^ALTER\ USER\ \'([^\']+)\'@ ]]; then
      altered[${BASH_REMATCH[1]}]=" ${shown[i]}"
    elif [[ "${s}" =~ ^(GRANT|CREATE\ DATABASE\ IF\ NOT\ EXISTS)\  ]]; then
      :
    else
      # a statement of a later file this check does not know (REVOKE, DROP USER...): teach it
      # here, the end state would be wrong without it
      problem "the check of db/db-setup.sh does not know this statement of the setup migrations: ${shown[i]}"
    fi
  done
  # signs_in <user> <host> <port>: the user signs in there, its grants read (once per server)
  signs_in() {
    local key="$1 $2 $3" out
    if [ -z "${signed[${key}]:-}" ]; then
      if out=$(grants_of "$1" "${passwords[$1]}" "$2" "$3" 2>&1); then
        signed[${key}]=yes grants[${key}]=${out}
      else
        signed[${key}]=no
        problem "'$1' cannot sign in on $2:$3 ($(printf '%s' "${out}" | grep -v '^WARNING' | head -n 1)): ${created[$1]}${altered[$1]:-}"
      fi
    fi
    [ "${signed[${key}]}" = yes ]
  }
  for user in "${!passwords[@]}"; do
    # (the ones with a grant: on the server of its database, below)
    printf '%s\n' "${run[@]}" | grep -q " TO '${user}'@" || signs_in "${user}" "${MAIN_HOST}" "${MAIN_PORT}"
  done
  for i in "${!run[@]}"; do
    s=${run[i]}
    [[ "${s}" =~ ^GRANT\ (.+)\ ON\ \`([^\`]+)\`\.\*\ TO\ \'([^\']+)\'@\'[^\']*\'(\ WITH\ GRANT\ OPTION)?\;$ ]] || continue
    privs=${BASH_REMATCH[1]} db=${BASH_REMATCH[2]} user=${BASH_REMATCH[3]} grantable=${BASH_REMATCH[4]}
    [ -n "${passwords[${user}]:-}" ] || { problem "no CREATE USER of '${user}' in the setup migrations"; continue; }
    read -r -a server <<< "$(db_server "${db}")"
    signs_in "${user}" "${server[0]}" "${server[1]}" || continue
    key="${user} ${server[0]} ${server[1]}"
    lack=$(lacks "${grants[${key}]}" "${db}" "${privs}" "${grantable}")
    if [ -n "${lack}" ]; then
      problem "'${user}' lacks ${lack} on \`${db}\`: ${shown[i]}"
    elif [ -z "${checked_db[${db}]:-}" ]; then
      # the database itself, where the SQL creates it (the accounts' migrations create theirs)
      checked_db[${db}]=yes
      if printf '%s\n' "${run[@]}" | grep -qx "CREATE DATABASE IF NOT EXISTS \`${db}\`;" \
        && [ "$(my_q "${user}" "${passwords[${user}]}" "${server[0]}" "${server[1]}" "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '${db}'")" != 1 ]; then
        problem "no database \`${db}\` on ${server[0]}:${server[1]}: CREATE DATABASE IF NOT EXISTS \`${db}\`;"
      fi
    fi
  done
}

# PostgreSQL: the roles and databases of db/postgres/setup/sync/, read from the catalogs as the
# owner of the Sync database (SYNC_POSTGRES_USER), and the admin UI's database as its role.
# pg_foreign <user> <password> <database> <the stack's roles...>: the grants on the database to
# roles but those (PUBLIC: checked apart; a backup's or monitoring's CONNECT is yours to give),
# and its objects that its owner does not own (the code of another role, which the stack's
# sessions could run), at most 5 of each: warnings
pg_foreign() {
  local user=$1 password=$2 db=$3 allowed out role
  shift 3
  allowed=$(printf "'%s'," "$@")
  out=$(pg_q "${user}" "${password}" "${db}" "SELECT string_agg(DISTINCT pg_get_userbyid(a.grantee) || ' (' || a.privilege_type || ')', ', ') FROM pg_database d, aclexplode(d.datacl) a
    WHERE d.datname = current_database() AND a.grantee <> 0 AND pg_get_userbyid(a.grantee) NOT IN (${allowed%,})")
  [ -z "${out}" ] || warn "other roles have grants on the database ${db}, which is the stack's: ${out}. Yours to give (a backup, monitoring)? Otherwise REVOKE ALL ON DATABASE ${db} FROM <role>;"
  out=$(pg_q "${user}" "${password}" "${db}" "SELECT string_agg(o, ', ') FROM (SELECT o FROM (
      SELECT format('%s %s (%s)', CASE c.relkind WHEN 'v' THEN 'view' WHEN 'S' THEN 'sequence' ELSE 'table' END, c.oid::regclass, pg_get_userbyid(c.relowner)) AS o
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relowner <> (SELECT datdba FROM pg_database WHERE datname = current_database()) AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
          AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg\_%'
          AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e')
      UNION ALL
      SELECT format('function %s (%s)', p.oid::regprocedure, pg_get_userbyid(p.proowner))
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE p.proowner <> (SELECT datdba FROM pg_database WHERE datname = current_database())
          AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg\_%'
          AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
      UNION ALL
      SELECT format('schema %s (%s)', n.nspname, pg_get_userbyid(n.nspowner))
        FROM pg_namespace n
        WHERE n.nspowner NOT IN ((SELECT datdba FROM pg_database WHERE datname = current_database()), 10,
            COALESCE((SELECT oid FROM pg_roles WHERE rolname = 'pg_database_owner'), 0))
          AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'public') AND n.nspname NOT LIKE 'pg\_%'
    ) x ORDER BY o LIMIT 5) y")
  [ -z "${out}" ] || warn "in the database ${db}, what its owner ${user} does not own (another role's, which the stack's sessions could run): ${out}. Yours? Otherwise ALTER ... OWNER TO ${user}, or drop them"
}
pg_check() {
  local owner=${SYNC_POSTGRES_USER} db=${SYNC_POSTGRES_NAME} out role
  if ! out=$(pg_sql "${owner}" "${SYNC_POSTGRES_PASSWORD}" "${db}" -c "SELECT 1"); then
    problem "'${owner}' cannot sign in to the database ${db} ($(head -n 1 <<< "${out}")): CREATE ROLE ${owner} LOGIN PASSWORD '<SYNC_POSTGRES_PASSWORD>'; CREATE DATABASE ${db} OWNER ${owner};"
    return
  fi
  pg_foreign "${owner}" "${SYNC_POSTGRES_PASSWORD}" "${db}" "${owner}" "${ADMIN_DB_SYNC_USER:-ffs_admin_sync}"
  [ "$(pg_q "${owner}" "${SYNC_POSTGRES_PASSWORD}" "${db}" "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = current_database()")" = "${owner}" ] \
    || problem "the database ${db} is not ${owner}'s: ALTER DATABASE ${db} OWNER TO ${owner};"
  [ "$(pg_q "${owner}" "${SYNC_POSTGRES_PASSWORD}" "${db}" "SELECT has_database_privilege('public', current_database(), 'CONNECT')")" = f ] \
    || problem "every role may connect to the database ${db}: REVOKE ALL ON DATABASE ${db} FROM PUBLIC;"
  [ -n "${ADMIN_DB_PASSWORD:-}" ] || return 0
  for role in "${ADMIN_DB_USER}" "${ADMIN_DB_SYNC_USER}"; do
    [ "$(pg_q "${owner}" "${SYNC_POSTGRES_PASSWORD}" "${db}" "SELECT rolcanlogin FROM pg_roles WHERE rolname = '${role}'")" = t ] \
      || problem "no role ${role} that can sign in: CREATE ROLE ${role} LOGIN PASSWORD '<ADMIN_DB_PASSWORD>';"
  done
  case "$(pg_q "${owner}" "${SYNC_POSTGRES_PASSWORD}" "${db}" "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '${ADMIN_DB_NAME}'")" in
    "") problem "no database ${ADMIN_DB_NAME}: CREATE DATABASE ${ADMIN_DB_NAME} OWNER ${ADMIN_DB_USER} TEMPLATE template0;"; return ;;
    "${ADMIN_DB_USER}") ;;
    *) problem "the database ${ADMIN_DB_NAME} is not ${ADMIN_DB_USER}'s: ALTER DATABASE ${ADMIN_DB_NAME} OWNER TO ${ADMIN_DB_USER};" ;;
  esac
  [ "$(pg_q "${owner}" "${SYNC_POSTGRES_PASSWORD}" "${db}" "SELECT has_database_privilege('public', '${ADMIN_DB_NAME}', 'CONNECT')")" = f ] \
    || problem "every role may connect to the database ${ADMIN_DB_NAME}: REVOKE ALL ON DATABASE ${ADMIN_DB_NAME} FROM PUBLIC;"
  if ! out=$(pg_sql "${ADMIN_DB_USER}" "${ADMIN_DB_PASSWORD}" "${ADMIN_DB_NAME}" -c "SELECT 1"); then
    problem "'${ADMIN_DB_USER}' cannot sign in to the database ${ADMIN_DB_NAME} ($(head -n 1 <<< "${out}")): ALTER ROLE ${ADMIN_DB_USER} PASSWORD '<ADMIN_DB_PASSWORD>';"
    return
  fi
  pg_foreign "${ADMIN_DB_USER}" "${ADMIN_DB_PASSWORD}" "${ADMIN_DB_NAME}" "${ADMIN_DB_USER}"
  if [ "$(pg_q "${ADMIN_DB_USER}" "${ADMIN_DB_PASSWORD}" "${ADMIN_DB_NAME}" "SELECT has_schema_privilege('public', 'public', 'CREATE')")" != f ]; then
    # (PostgreSQL 11 to 14: a role that is no superuser cannot revoke it, the admin UI then
    # refuses what another role puts there: a warning)
    warn "every role may create tables in the public schema of ${ADMIN_DB_NAME}: as a superuser, \\connect ${ADMIN_DB_NAME} and REVOKE CREATE ON SCHEMA public FROM PUBLIC;"
  fi
}
# end_state: PROBLEMS of the end state of every file, the server's
end_state() {
  PROBLEMS=()
  if [ "${ENGINE}" = postgres ]; then pg_check; else
    [ "${MAIN}" = fxa ] || [ "${STORAGE_HOST} ${STORAGE_PORT}" = "${MAIN_HOST} ${MAIN_PORT}" ] || wait_server "${STORAGE_HOST}" "${STORAGE_PORT}"
    mysql_check
  fi
}

# ---- the record: rec <sql> as REC_USER in RECORD_DB (PostgreSQL: as the owner of the Sync
# database, the tables are its own; the bootstrap is a member of it)
rec() {
  if [ "${ENGINE}" = postgres ]; then
    local role=""
    [ -z "${BOOT_USER}" ] || role="SET ROLE ${SYNC_POSTGRES_USER}; "
    PGPASSWORD="${REC_PASSWORD}" PGCONNECT_TIMEOUT=10 psql -X -h "${MAIN_HOST}" -p "${MAIN_PORT}" -U "${REC_USER}" -d "${RECORD_DB}" -v ON_ERROR_STOP=1 -tA -q \
      -c "SET search_path = pg_catalog, pg_temp; ${role}$1" < /dev/null 2> "${WORK}/rec.err" && return 0
  else
    my_sql "${REC_USER}" "${REC_PASSWORD}" "${MAIN_HOST}" "${MAIN_PORT}" -N -B -r <<< "$1" 2> "${WORK}/rec.err" && return 0
  fi
  grep -v '^WARNING\|\[Warning\]\|^NOTICE' "${WORK}/rec.err"
  return 1
}
# read_record: REC_NUMBERS, REC_NAMES, REC_SUMS, REC_HOW, REC_AT (epoch) of the scope; empty
# when the table is not there (yet)
REC_NUMBERS=() REC_NAMES=() REC_SUMS=() REC_HOW=() REC_AT=() UNREADABLE=""
read_record() {
  local out exists n name sum how at
  REC_NUMBERS=() REC_NAMES=() REC_SUMS=() REC_HOW=() REC_AT=() UNREADABLE=""
  if [ "${ENGINE}" = postgres ]; then
    exists=$(rec "SELECT to_regclass('public.ffs_setup_migrations') IS NOT NULL;") || { UNREADABLE=$(head -n 1 <<< "${exists}"); return 0; }
    [ "${exists}" = t ] || return 0
    out=$(rec "SELECT number, name, checksum, how, CAST(EXTRACT(EPOCH FROM applied_at) AS BIGINT) FROM public.ffs_setup_migrations WHERE scope = '${SCOPE}' ORDER BY number;" | tr '|' '\t') \
      || fail "cannot read the record of the setup migrations in ${RECORD_DB}: $(head -n 1 <<< "${out}")"
  else
    exists=$(rec "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '${RECORD_DB}' AND TABLE_NAME = 'ffs_setup_migrations';") || { UNREADABLE=$(head -n 1 <<< "${exists}"); return 0; }
    [ "${exists}" = 1 ] || return 0
    out=$(rec "SELECT number, name, checksum, how, UNIX_TIMESTAMP(applied_at) FROM \`${RECORD_DB}\`.ffs_setup_migrations WHERE scope = '${SCOPE}' ORDER BY number;") \
      || fail "cannot read the record of the setup migrations in ${RECORD_DB}: $(head -n 1 <<< "${out}")"
  fi
  while IFS=$'\t' read -r n name sum how at; do
    [ -n "${n}" ] || continue
    REC_NUMBERS+=("${n}") REC_NAMES+=("${name}") REC_SUMS+=("${sum}") REC_HOW+=("${how}") REC_AT+=("${at}")
  done <<< "${out}"
}
recorded() { local n; for n in "${REC_NUMBERS[@]}"; do [ "${n}" = "$1" ] && return 0; done; return 1; }
# write_record <how> <numbers...>
write_record() {
  local out
  [ "$#" -gt 1 ] || return 0
  out=$(rec "$(record_sql "$@")") || fail "cannot record the setup migrations $(span "${@:2}") in ${RECORD_DB} as ${REC_USER}: $(head -n 1 <<< "${out}" | redact)"
}
# write_state <result> <detail>: this start's result, for the admin UI (as far as it goes: the
# account may not sign in)
write_state() {
  local detail=${2//\'/\'\'} sql
  detail=${detail//\\/\\\\}
  if [ "${ENGINE}" = postgres ]; then
    detail=${2//\'/\'\'}
    sql="INSERT INTO public.ffs_setup_state (scope, result, expected, detail) VALUES ('${SCOPE}', '$1', ${EXPECTED}, '${detail}') ON CONFLICT (scope) DO UPDATE SET result = EXCLUDED.result, expected = EXCLUDED.expected, detail = EXCLUDED.detail, checked_at = now();"
  else
    sql="REPLACE INTO \`${RECORD_DB}\`.ffs_setup_state (scope, result, expected, detail) VALUES ('${SCOPE}', '$1', ${EXPECTED}, '${detail}');"
  fi
  rec "$(record_sql state)
${sql}" > /dev/null 2>&1 || true
}

# ---- one start at a time on the server (replicas of the chart start together): a session
# that holds the lock until this script ends
LOCK_PID=""
take_lock() {
  local reply="" deadline in out
  if [ "${ENGINE}" = postgres ]; then
    local db=${RECORD_DB}
    [ -z "${BOOT_USER}" ] || db=postgres
    coproc LOCK { PGPASSWORD="${REC_PASSWORD}" PGCONNECT_TIMEOUT=10 psql -X -h "${MAIN_HOST}" -p "${MAIN_PORT}" -U "${REC_USER}" -d "${db}" -tA -v ON_ERROR_STOP=1 2>&1; }
  else
    coproc LOCK { MYSQL_PWD="${REC_PASSWORD}" "${CLIENT}" --protocol=tcp --connect-timeout=10 -h "${MAIN_HOST}" -P "${MAIN_PORT}" -u "${REC_USER}" ${TLS_ARGS[@]+"${TLS_ARGS[@]}"} -N -B --unbuffered 2>&1; }
  fi
  in=${LOCK[1]} out=${LOCK[0]}
  trap 'rm -rf "${WORK}"; [ -z "${LOCK_PID}" ] || kill "${LOCK_PID}" 2> /dev/null' EXIT
  if [ "${ENGINE}" = postgres ]; then
    echo "SELECT pg_advisory_lock(hashtext('ffs_setup:${SCOPE}')), 'locked';" >&"${in}"
  else
    echo "SELECT GET_LOCK('ffs_setup:${SCOPE}:${RECORD_DB}', 600), 'locked';" >&"${in}"
  fi
  deadline=$(( $(date +%s) + 620 ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    if ! IFS= read -r -t 30 reply <&"${out}"; then
      # (the client gone: its sign-in refused)
      kill -0 "${LOCK_PID}" 2> /dev/null || return 1
      continue
    fi
    case "${reply}" in
      0*locked) return 1 ;;
      *locked) return 0 ;;
      ""|*WARNING*|*Warning*) ;;
      *) echo "${reply}" >&2; return 1 ;;
    esac
  done
  return 1
}

# ---- pending: the SQL of the files the server lacks (nothing changed there)
if [ "${ACTION}" = pending ]; then
  wait_server "${MAIN_HOST}" "${MAIN_PORT}"
  read_record
  PENDING=() VERSION=0
  for n in "${NUMBERS[@]}"; do recorded "${n}" || PENDING+=("${n}"); done
  for n in ${REC_NUMBERS[@]+"${REC_NUMBERS[@]}"}; do [ "${n}" -le "${VERSION}" ] || VERSION=${n}; done
  if [ -n "${UNREADABLE}" ]; then
    echo "-- ${REC_USER} cannot read the record of the setup migrations in ${RECORD_DB} (${UNREADABLE}): every file of scope ${SCOPE}"
  elif [ "${#REC_NUMBERS[@]}" = 0 ]; then
    echo "-- nothing recorded in ${RECORD_DB} yet (an install from before the setup migrations, or a new one): every file of scope ${SCOPE}"
  fi
  if [ "${#PENDING[@]}" = 0 ]; then
    echo "-- ${WHAT}: nothing pending, setup version $(nnn "${VERSION}") (this release expects $(nnn "${EXPECTED}"))"
    exit 0
  fi
  echo "-- ${WHAT}: setup migrations $(span "${PENDING[@]}") not applied (version $(nnn "${VERSION}"), this release expects $(nnn "${EXPECTED}")); as the server's administrator:"
  sql_of "${PENDING[@]}"
  exit 0
fi

# ==== the start
wait_server "${MAIN_HOST}" "${MAIN_PORT}"
if [ -n "${BOOT_USER}" ]; then
  # ---- the bootstrap account: only ever given the stack's own names, never a reserved one,
  # never a user (role) of that name that is not the stack's, and no administrator of the server
  echo "${WHAT}: the setup migrations of this release applied as ${BOOT_USER} (${USER_SETTING}) on ${MAIN_HOST}:${MAIN_PORT}"
  if [ "${ENGINE}" != postgres ] && [ "${MAIN}" = sync ] && [ "${STORAGE_HOST} ${STORAGE_PORT}" != "${MAIN_HOST} ${MAIN_PORT}" ]; then
    fail "the storage database is on another server (SYNC_STORAGE_DB_HOST, SYNC_STORAGE_DB_PORT): the bootstrap needs both Sync databases on one server. Unset ${USER_SETTING} and run ${FILE} by hand, as docs/databases.md#create-the-databases-and-users says"
  fi
  # the names of the server's own accounts and roles (the images' too: MariaDB's mysql and
  # healthcheck), and the bootstrap account's: never one of the stack's users
  RESERVED="root mysql healthcheck mariadb_sys mysql_sys postgres public ${BOOT_USER}"
  while read -r placeholder setting; do
    [[ "${setting}" == *_USER ]] || continue
    value=${!setting:-}
    case " ${RESERVED} " in
      *" ${value} "*) [ -n "${value}" ] && fail "${setting} is '${value}', a name of the server's own accounts or the bootstrap account's: the bootstrap creates and changes the stack's users only, choose another name (${DOC_BOOT})" ;;
    esac
  done < <(sql_settings "${KIND}")
fi
failed() {
  echo "✗ ERROR: setup migration $1 failed as ${BOOT_USER} on ${MAIN_HOST}:${MAIN_PORT}: $2"
  echo "  The account needs the grants of ${DOC_BOOT} (${DOC})"
  write_state error "setup migration $1 failed as ${BOOT_USER}: $2"
  exit 1
}
if [ -n "${BOOT_USER}" ] && [ "${ENGINE}" = postgres ]; then
  boot_q() { pg_q "${BOOT_USER}" "${BOOT_PASSWORD}" postgres "$1"; }
  out=$(pg_sql "${BOOT_USER}" "${BOOT_PASSWORD}" postgres -c "SELECT 1") || { printf '%s\n' "${out}" | redact; fail "${BOOT_USER} cannot sign in on ${MAIN_HOST}:${MAIN_PORT}"; }
  # PostgreSQL 16 or later: before 16 CREATEROLE reaches every role but the superusers, the
  # predefined ones (pg_read_server_files...) too: close to a superuser
  version=$(boot_q "SHOW server_version_num")
  [[ "${version}" =~ ^[0-9]+$ ]] && [ "${version}" -ge 160000 ] \
    || fail "PostgreSQL ${version} on ${MAIN_HOST}:${MAIN_PORT}: the bootstrap needs PostgreSQL 16 or later (before 16 CREATEROLE can make itself almost a superuser). Unset ${USER_SETTING} and ${PASSWORD_SETTING}: the stack then checks the setup migrations at every start, and you run them by hand (${FILE}, ${DOC})"
  # no superuser, nor what makes one (the files of the server, its programs, all the data)
  # through a role it is a member of (a SET ROLE away)
  wide=$(boot_q "SELECT string_agg(x, ', ') FROM (
      SELECT 'SUPERUSER' AS x FROM pg_roles WHERE rolname = current_user AND rolsuper
      UNION ALL SELECT 'BYPASSRLS' FROM pg_roles WHERE rolname = current_user AND rolbypassrls
      UNION ALL SELECT 'REPLICATION' FROM pg_roles WHERE rolname = current_user AND rolreplication
      UNION ALL SELECT format('membership of %s', rolname) FROM pg_roles r WHERE rolname <> current_user
        AND (rolsuper OR rolbypassrls OR rolreplication OR rolname IN ('pg_execute_server_program', 'pg_read_server_files',
          'pg_write_server_files', 'pg_read_all_data', 'pg_write_all_data'))
        AND pg_has_role(current_user, r.oid, 'MEMBER')) y")
  [ -z "${wide}" ] || fail "${BOOT_USER} holds ${wide}: the bootstrap account must be a role with CREATEROLE and CREATEDB only, a member of no administrator's role (${DOC_BOOT})"
  # the stack's roles that exist: the stack's when the bootstrap administers them (the ones it
  # created, those database-bootstrap.sql gives it), from the catalog; never from a sign-in
  # (pg_hba.conf may trust it, a password may be someone else's too)
  PG_ROLES=("${SYNC_POSTGRES_USER} SYNC_POSTGRES_USER")
  [ -z "${ADMIN_DB_PASSWORD:-}" ] || PG_ROLES+=("${ADMIN_DB_USER} ADMIN_DB_USER" "${ADMIN_DB_SYNC_USER} ADMIN_DB_SYNC_USER")
  pg_owned() {
    local pair role setting
    for pair in "${PG_ROLES[@]}"; do
      read -r role setting <<< "${pair}"
      case "$(boot_q "SELECT CASE WHEN NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${role}') THEN 'none'
          WHEN EXISTS (SELECT FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.roleid JOIN pg_roles b ON b.oid = m.member
            WHERE r.rolname = '${role}' AND b.rolname = current_user AND m.admin_option) THEN 'ours'
          ELSE 'theirs' END")" in
        none|ours) ;;
        theirs) failed "$(span "${NUMBERS[@]}")" "the role ${role} (${setting}) exists and is not the stack's: ${BOOT_USER} does not administer it. The bootstrap does not change it: if it is the stack's, GRANT ${role} TO ${BOOT_USER} WITH ADMIN OPTION as a superuser (database-bootstrap.sql does), or choose another name" ;;
        *) failed "$(span "${NUMBERS[@]}")" "cannot read the roles as ${BOOT_USER}" ;;
      esac
    done
  }
  # apply <number>: a file as the bootstrap account, after the check of the stack's roles (the
  # roles it creates it administers: PostgreSQL 16+)
  apply() {
    local name=$1 out line
    pg_owned
    if ! out=$(PGPASSWORD="${BOOT_PASSWORD}" PGCONNECT_TIMEOUT=10 psql -X -h "${MAIN_HOST}" -p "${MAIN_PORT}" -U "${BOOT_USER}" -d postgres -v ON_ERROR_STOP=1 -q -f "${WORK}/run/${name}" 2>&1); then
      printf '%s\n' "${out}" | grep -v 'NOTICE:' | redact
      # psql:<file>:<line>: ERROR: the statement of that line
      line=$(printf '%s\n' "${out}" | sed -n 's/^psql:[^:]*:\([0-9][0-9]*\): ERROR:.*/\1/p' | head -n 1)
      failed "${name%.sql}" "$([ -n "${line}" ] && sed -n "${line}p" "${WORK}/shown/${name}" || echo "see the error above")"
    fi
  }
elif [ -n "${BOOT_USER}" ]; then
  out=$(grants_of "${BOOT_USER}" "${BOOT_PASSWORD}" "${MAIN_HOST}" "${MAIN_PORT}" all 2>&1) \
    || { printf '%s\n' "${out}" | grep -E '^ERROR' | redact; fail "${BOOT_USER} cannot sign in on ${MAIN_HOST}:${MAIN_PORT}, or read its grants"; }
  BOOT_GRANTS=${out}
  # what it may hold, nothing else (deny by default: a line of SHOW GRANTS not of these forms is
  # too much): on the whole server only CREATE USER (and USAGE, no privilege), the names and
  # hosts of mysql.user, privileges on databases but the mysql schema, its roles (expanded
  # above). Not an administrator (SYSTEM_USER, SUPER, ALL PRIVILEGES, a table of the mysql
  # schema, a proxy...), also through its roles (docs/databases.md#the-bootstrap-account)
  wide=""
  while IFS= read -r line; do
    case "${line}" in
      "") ;;
      "G USAGE N"|"G CREATE USER N") ;;
      "G "*" Y") p=${line#G } wide="${wide} ${p% Y} WITH GRANT OPTION on the whole server," ;;
      "G "*) p=${line#G } wide="${wide} ${p% [YN]} on the whole server," ;;
      "D "*)
        d=${line#D } a=${d%% *}
        if matches mysql "${a}"; then d=${d#* }; wide="${wide} ${d% [YN]} on the mysql schema (\`${a}\`.*),"; fi ;;
      # (what setup migration 001 of its account gives: the names, hosts and privilege columns of
      # mysql.user, nothing else of it; the privilege tables, which hold no secret)
      "T \`mysql\`.\`user\` SELECT ("*")")
        p=${line#T \`mysql\`.\`user\` SELECT (} p=${p%)} p=${p//\`/}
        while IFS= read -r a; do
          case "${a# }" in User|Host|*_priv) ;; *) wide="${wide} SELECT (${a# }) on \`mysql\`.\`user\`," ;; esac
        done <<< "${p//,/$'\n'}" ;;
      "T \`mysql\`.\`global_grants\` SELECT"|"T \`mysql\`.\`role_edges\` SELECT"|"T \`mysql\`.\`db\` SELECT"|"T \`mysql\`.\`tables_priv\` SELECT") ;;
      "T \`mysql\`.\`columns_priv\` SELECT"|"T \`mysql\`.\`procs_priv\` SELECT") ;;
      "R "*|"X "*) ;;
      "T "*) p=${line#T } wide="${wide} ${p#* } on ${p%% *}," ;;
      # (a proxy, a line not understood)
      *) wide="${wide} ${line#[A-Z] }," ;;
    esac
  done <<< "${BOOT_GRANTS}"
  [ -z "${wide}" ] || fail "${BOOT_USER} holds${wide%,} (itself or through its roles): the bootstrap account must have only CREATE USER on the whole server, SELECT of the names and hosts of mysql.user (MySQL: of its privilege columns and privilege tables), and ALL PRIVILEGES on the stack's databases (${DOC_BOOT})"
  # CREATE USER reaches every account of the server: MariaDB has nothing that protects one
  # (opt-in: a warning at every start); MySQL 8.0.16 and later spare the accounts with
  # SYSTEM_USER, which every administrator of the server must then hold (the bootstrap account
  # must not: refused above), the others it reaches (a warning)
  version=$(my_q "${BOOT_USER}" "${BOOT_PASSWORD}" "${MAIN_HOST}" "${MAIN_PORT}" 'SELECT VERSION()')
  if [[ "${version}" == *[Mm]aria[Dd][Bb]* ]]; then
    warn "MariaDB has no protection of accounts: ${BOOT_USER} (CREATE USER) can change or drop any account of ${MAIN_HOST}:${MAIN_PORT}, root too. Keep it for a server the stack has to itself, or unset ${USER_SETTING} after this start (${DOC_BOOT})"
  else
    IFS=. read -r major minor patch <<< "${version%%-*}"
    patch=${patch%%[!0-9]*}
    if ! [[ "${major}.${minor}.${patch}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [ $((major * 10000 + minor * 100 + patch)) -lt 80016 ]; then
      fail "MySQL ${version} on ${MAIN_HOST}:${MAIN_PORT}: the bootstrap needs MySQL 8.0.16 or later (SYSTEM_USER: before it CREATE USER can change root). Unset ${USER_SETTING} and run the setup by hand (${FILE}, ${DOC})"
    fi
    # an administrator: any privilege on the whole server beyond USAGE (the *_priv columns of
    # mysql.user, a dynamic privilege of mysql.global_grants), any grant on the mysql schema
    # (mysql.db, tables_priv, columns_priv, procs_priv), itself or through its roles, recursively
    # (mysql.role_edges); the bootstrap account and the stack's own users aside
    privs=$(my_q "${BOOT_USER}" "${BOOT_PASSWORD}" "${MAIN_HOST}" "${MAIN_PORT}" "SELECT GROUP_CONCAT(CONCAT('u.', COLUMN_NAME, ' = ''Y''') SEPARATOR ' OR ')
        FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = 'mysql' AND TABLE_NAME = 'user' AND COLUMN_NAME LIKE '%\_priv'") || privs=""
    stack_users=$(sql_settings "${KIND}" | while read -r placeholder setting; do [[ "${setting}" == *_USER ]] && [ -n "${!setting:-}" ] && printf "'%s'," "${!setting}"; done)
    [ "${KIND}" != fxa ] || stack_users="${stack_users}'ffs_admin',"
    if [ -z "${privs}" ] || ! admins=$(my_q "${BOOT_USER}" "${BOOT_PASSWORD}" "${MAIN_HOST}" "${MAIN_PORT}" "WITH RECURSIVE reach (u, h, ru, rh) AS (
          SELECT User, Host, User, Host FROM mysql.user
          UNION SELECT r.u, r.h, e.FROM_USER, e.FROM_HOST FROM reach r JOIN mysql.role_edges e ON e.TO_USER = r.ru AND e.TO_HOST = r.rh),
        admin (u, h) AS (
          SELECT u.User, u.Host FROM mysql.user u WHERE ${privs}
          UNION SELECT USER, HOST FROM mysql.global_grants
          UNION SELECT User, Host FROM mysql.db WHERE 'mysql' LIKE Db
          UNION SELECT User, Host FROM mysql.tables_priv WHERE Db = 'mysql'
          UNION SELECT User, Host FROM mysql.columns_priv WHERE Db = 'mysql'
          UNION SELECT User, Host FROM mysql.procs_priv WHERE Db = 'mysql')
        SELECT DISTINCT CONCAT('''', r.u, '''@''', r.h, '''') FROM reach r JOIN admin a ON a.u = r.ru AND a.h = r.rh
        WHERE NOT (r.u = '${BOOT_USER}' AND r.h = '%') AND r.u NOT IN (${stack_users%,})
          AND NOT EXISTS (SELECT 1 FROM mysql.global_grants g WHERE g.USER = r.u AND g.HOST = r.h AND g.PRIV = 'SYSTEM_USER') ORDER BY 1"); then
      fail "${BOOT_USER} cannot read the administrators of ${MAIN_HOST}:${MAIN_PORT} ($(head -n 1 <<< "${admins:-the columns of mysql.user}")): run its setup migrations again as the server's administrator, they give it SELECT on the privilege tables of the mysql schema (never the passwords' hashes; db-setup.sh print ${MAIN}-bootstrap, database-bootstrap$([ "${MAIN}" = fxa ] && echo -fxa).sql; ${DOC_BOOT})"
    fi
    [ -z "${admins}" ] || fail "accounts of ${MAIN_HOST}:${MAIN_PORT} with administrator privileges (any privilege on the whole server, or on the mysql schema, also through a role) lack SYSTEM_USER: $(paste -sd ',' - <<< "${admins}" | sed -e 's/,/, /g'). ${BOOT_USER} could change or drop them (CREATE USER). As the server's administrator: GRANT SYSTEM_USER ON *.* TO each of them, or unset ${USER_SETTING} and run the setup by hand (${DOC_BOOT})"
    warn "MySQL: ${BOOT_USER} (CREATE USER) can change or drop the accounts without SYSTEM_USER of ${MAIN_HOST}:${MAIN_PORT}, those of other applications too; the administrators hold SYSTEM_USER. Unset ${USER_SETTING} after this start to hold no such password (${DOC_BOOT})"
  fi
  # the accounts of a name: "<host>" per line (mysql.user's names and hosts, setup migration
  # 001 of the bootstrap account)
  hosts_of() {
    local out
    out=$(my_q "${BOOT_USER}" "${BOOT_PASSWORD}" "${MAIN_HOST}" "${MAIN_PORT}" "SELECT CONCAT('[', Host, ']') FROM mysql.user WHERE User = '$1' ORDER BY Host") \
      || { echo >&2 "✗ ERROR: ${BOOT_USER} cannot read the names and hosts of mysql.user ($(head -n 1 <<< "${out}")): run the setup migrations of its account again as the server's administrator, they now give it GRANT SELECT (User, Host) ON mysql.user TO '${BOOT_USER}'@'%'; (db-setup.sh print ${MAIN}-bootstrap, database-bootstrap$([ "${MAIN}" = fxa ] && echo -fxa).sql; ${DOC_BOOT})"; write_state error "${BOOT_USER} cannot read mysql.user (User, Host)"; exit 1; }
    printf '%s\n' "${out}"
  }
  # one statement at a time. A user of the stack is the stack's when the only account of its
  # name is the one of the file ('u'@'%') and it signs in there with the stack's password
  # (CURRENT_USER() that account): then CREATE USER is left out (IF NOT EXISTS of a DEFINER of
  # routines fails without SET_ANY_DEFINER, ERROR 4006). None of that name: created (CREATE
  # USER, without IF NOT EXISTS). Another account of that name (another host: '%' would widen
  # where it signs in from), or one that does not sign in with the stack's password: not the
  # stack's, refused before any change; its ALTER USER and GRANTs too
  declare -A OURS=() PASSWORD_OF=()
  ours() { # <user> <host of the file> <setting of its password>
    local user=$1 host=$2 setting=$3 hosts me
    [ -z "${OURS[${user}]:-}" ] || return 0
    hosts=$(hosts_of "${user}") || exit 1
    case "${hosts}" in
      "") return 1 ;;
      "[${host}]") ;;
      # shellcheck disable=SC2001 # (a line per account)
      *) failed "${NAME}" "the server has $(sed -e "s/^\[\(.*\)\]$/'${user}'@'\1'/" <<< "${hosts}" | paste -sd ',' - | sed -e 's/,/, /g') (an account or a role): the setup migrations give '${user}'@'${host}' only, the bootstrap does not create or change it beside another (it would widen where ${user} signs in from). Drop or rename the other one if it is not the stack's, or choose another name" ;;
    esac
    if me=$(my_q "${user}" "${PASSWORD_OF[${user}]}" "${MAIN_HOST}" "${MAIN_PORT}" 'SELECT CURRENT_USER()') && [ "${me}" = "${user}@${host}" ]; then
      OURS[${user}]=1
      return 0
    fi
    failed "${NAME}" "'${user}'@'${host}' exists on the server and does not sign in with <${setting}>: it is not one of this stack's users (or one with the passwords of an earlier .env), and the bootstrap does not change it. Give it that password yourself if it is the stack's, or choose another name"
  }
  apply() {
    local name=$1 i statement user host password setting out
    local -a run shown
    NAME=${name%.sql}
    mapfile -t run < <(statements "${WORK}/run/${name}")
    mapfile -t shown < <(statements "${WORK}/shown/${name}")
    # first the users of the file, before any change: each one the stack's, or none of its name
    for i in "${!run[@]}"; do
      if [[ "${run[i]}" =~ ^CREATE\ USER\ IF\ NOT\ EXISTS\ \'([^\']+)\'@\'([^\']*)\' ]]; then
        ours "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$(sed -n "s/.*'<\([A-Z_]*\)>'.*/\1/p" <<< "${shown[i]}" | head -n 1)" || true
      fi
    done
    for i in "${!run[@]}"; do
      statement=${run[i]}
      setting=$(sed -n "s/.*'<\([A-Z_]*\)>'.*/\1/p" <<< "${shown[i]}" | head -n 1)
      if [[ "${statement}" =~ ^CREATE\ USER\ IF\ NOT\ EXISTS\ \'([^\']+)\'@\'([^\']*)\'\ IDENTIFIED\ (BY|WITH\ [a-z_]+\ BY)\ \'([^\']*)\'\; ]] \
        || [[ "${statement}" =~ ^CREATE\ USER\ IF\ NOT\ EXISTS\ \'([^\']+)\'@\'([^\']*)\'\ IDENTIFIED\ VIA\ [a-z_]+\ USING\ PASSWORD\(\'([^\']*)\'\)\; ]]; then
        user=${BASH_REMATCH[1]} host=${BASH_REMATCH[2]} password=${BASH_REMATCH[${#BASH_REMATCH[@]}-1]}
        PASSWORD_OF[${user}]=${password}
        ours "${user}" "${host}" "${setting}" && continue
        statement="CREATE USER ${statement#CREATE USER IF NOT EXISTS }"
        if ! out=$(my_sql "${BOOT_USER}" "${BOOT_PASSWORD}" "${MAIN_HOST}" "${MAIN_PORT}" <<< "${statement}" 2>&1); then
          printf '%s\n' "${out}" | grep -E '^ERROR' | redact
          failed "${NAME}" "${shown[i]}"
        fi
        OURS[${user}]=1
        continue
      fi
      # ALTER USER, GRANT: of a user of the stack only
      if [[ "${statement}" =~ ^(ALTER\ USER\ |GRANT\ .*\ TO\ )\'([^\']+)\'@\'([^\']*)\' ]]; then
        user=${BASH_REMATCH[2]} host=${BASH_REMATCH[3]}
        if [ -z "${OURS[${user}]:-}" ]; then
          [ -n "${PASSWORD_OF[${user}]:-}" ] || failed "${NAME}" "'${user}' is not created by the setup migrations before: ${shown[i]}"
          ours "${user}" "${host}" "${setting}" || failed "${NAME}" "no user '${user}'@'${host}' on the server: ${shown[i]}"
        fi
      fi
      if ! out=$(my_sql "${BOOT_USER}" "${BOOT_PASSWORD}" "${MAIN_HOST}" "${MAIN_PORT}" <<< "${statement}" 2>&1); then
        printf '%s\n' "${out}" | grep -E '^ERROR' | redact
        failed "${NAME}" "${shown[i]}"
      fi
    done
  }
  # (the passwords of every user of the files: an ALTER USER or GRANT of a later file names a
  # user an earlier one created)
  while IFS= read -r statement; do
    if [[ "${statement}" =~ ^CREATE\ USER\ IF\ NOT\ EXISTS\ \'([^\']+)\'@\'[^\']*\'\ IDENTIFIED\ (BY|WITH\ [a-z_]+\ BY)\ \'([^\']*)\'\; ]]; then
      PASSWORD_OF[${BASH_REMATCH[1]}]=${BASH_REMATCH[3]}
    elif [[ "${statement}" =~ ^CREATE\ USER\ IF\ NOT\ EXISTS\ \'([^\']+)\'@\'[^\']*\'\ IDENTIFIED\ VIA\ [a-z_]+\ USING\ PASSWORD\(\'([^\']*)\'\)\; ]]; then
      PASSWORD_OF[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
    fi
  done < <(statements "${ALL_RUN}")
fi

# ---- the lock, then the record
if ! take_lock 2> "${WORK}/lock.err"; then
  [ -z "${BOOT_USER}" ] && [ ! -s "${WORK}/lock.err" ] && fail "no lock on ${MAIN_HOST}:${MAIN_PORT} after 10 minutes: another start of the stack holds it"
  # (without the bootstrap: the check below says why the stack's user does not sign in)
  [ -z "${BOOT_USER}" ] || fail "${REC_USER} cannot take the lock of the setup migrations on ${MAIN_HOST}:${MAIN_PORT}: $(redact < "${WORK}/lock.err" | head -n 1)"
fi
read_record
# a file of this release recorded with another checksum: it changed after its release
bad=()
for i in "${!REC_NUMBERS[@]}"; do
  for j in "${!NUMBERS[@]}"; do
    [ "${NUMBERS[j]}" = "${REC_NUMBERS[i]}" ] || continue
    [ "${SUMS[j]}" = "${REC_SUMS[i]}" ] || bad+=("${REC_NAMES[i]} (recorded ${REC_SUMS[i]:0:12}, this release ${SUMS[j]:0:12}: ${NAMES[j]})")
  done
done
if [ "${#bad[@]}" != 0 ]; then
  write_state error "setup migrations changed after they were applied: ${bad[*]}"
  fail "setup migrations of ${RECORD_DB} were applied as another file than this release's: ${bad[*]}. Released files never change: an image or checkout with edited files of db/*/setup? Use this release's files, or delete those rows of ffs_setup_migrations if you know they are right (${DOC})"
fi
newer=()
for n in ${REC_NUMBERS[@]+"${REC_NUMBERS[@]}"}; do [ "${n}" -le "${EXPECTED}" ] || newer+=("${n}"); done
[ "${#newer[@]}" = 0 ] || warn "the server has setup migrations $(span "${newer[@]}") of a newer release than this one (it expects $(nnn "${EXPECTED}")): an older release runs on a newer setup"
PENDING=()
for n in "${NUMBERS[@]}"; do recorded "${n}" || PENDING+=("${n}"); done
VERSION=0
for n in ${REC_NUMBERS[@]+"${REC_NUMBERS[@]}"}; do [ "${n}" -le "${VERSION}" ] || VERSION=${n}; done

# the command that prints the pending SQL again
again() { echo "${FFS_SETUP_PENDING:-db-setup.sh pending ${SCOPE}}"; }
show_problems() { printf '  - %s\n' "${PROBLEMS[@]}"; }

if [ "${#REC_NUMBERS[@]}" = 0 ]; then
  # an install from before the setup migrations, or a new one: its end state is the baseline
  end_state
  if [ "${#PROBLEMS[@]}" = 0 ]; then
    write_record baseline "${NUMBERS[@]}"
    echo "✓ ${WHAT} on ${MAIN_HOST}:${MAIN_PORT}: every user, grant and database of the setup migrations $(span "${NUMBERS[@]}") is there, recorded as their baseline"
    PENDING=() VERSION=${EXPECTED}
  elif [ -z "${BOOT_USER}" ]; then
    echo "✗ ERROR: ${WHAT} on your server lack what this release needs (setup migrations $(span "${NUMBERS[@]}"), $([ -n "${UNREADABLE}" ] && echo "their record unreadable as ${REC_USER}: ${UNREADABLE}" || echo "nothing recorded yet")):"
    show_problems
    echo "  Run ${FILE} on that server as its administrator (./prepare_environment.sh --upgrade writes it again; Helm: the SQL of db/ filled in, $(again)), or let the stack do it at every start with ${USER_SETTING} (${DOC})"
    write_state missing "$(printf '%s; ' "${PROBLEMS[@]}")"
    exit 1
  fi
fi
if [ "${#PENDING[@]}" != 0 ] && [ -z "${BOOT_USER}" ]; then
  echo "✗ ERROR: ${WHAT}: setup migrations $(span "${PENDING[@]}") not applied (your server has version $(nnn "${VERSION}"), this release expects $(nnn "${EXPECTED}")). Their SQL, to run as the server's administrator (the passwords as <SETTING>, those of .env):"
  sql_of "${PENDING[@]}" | sed -e 's/^/    /'
  echo "  Print it again: $(again)$([ -z "${FFS_SETUP_PENDING:-}" ] || echo " (--passwords: filled in)"); or run ${FILE} again (./prepare_environment.sh --upgrade writes it); or let the stack apply them at every start with ${USER_SETTING} (${DOC})"
  write_state pending "setup migrations $(span "${PENDING[@]}") not applied"
  exit 1
fi
if [ "${#PENDING[@]}" != 0 ]; then
  for n in "${PENDING[@]}"; do
    for i in "${!NUMBERS[@]}"; do
      [ "${NUMBERS[i]}" = "${n}" ] || continue
      apply "${NAMES[i]}"
      write_record bootstrap "${n}"
    done
  done
  echo "✓ setup migrations $(span "${PENDING[@]}") applied as ${BOOT_USER}"
  VERSION=${EXPECTED}
fi

# ---- the end state: drift (what was revoked or dropped by hand) is run again with the bootstrap
end_state
if [ "${#PROBLEMS[@]}" != 0 ] && [ -n "${BOOT_USER}" ]; then
  echo "${WHAT}: drift from the setup migrations, run again as ${BOOT_USER}:"
  show_problems
  for i in "${!NAMES[@]}"; do apply "${NAMES[i]}"; done
  end_state
fi
if [ "${#PROBLEMS[@]}" != 0 ]; then
  echo "✗ ERROR: ${WHAT} on your server lack what this release needs (setup migrations $(span "${NUMBERS[@]}"), version $(nnn "${VERSION}")):"
  show_problems
  if [ -n "${BOOT_USER}" ]; then
    echo "  after the setup migrations ran again as ${BOOT_USER}: see the statements above (${DOC})"
  else
    echo "  Run ${FILE} again on that server as its administrator (./prepare_environment.sh --upgrade writes it again; Helm: the SQL of db/ filled in, $(again)), or let the stack do it at every start with ${USER_SETTING} (${DOC})"
  fi
  write_state drift "$(printf '%s; ' "${PROBLEMS[@]}")"
  exit 1
fi
write_state ok ""
echo "✓ ${WHAT} on ${MAIN_HOST}:${MAIN_PORT}: setup version $(nnn "${VERSION}") (this release expects $(nnn "${EXPECTED}")), every user, grant and database of ${FILE} is there"
exit 0
