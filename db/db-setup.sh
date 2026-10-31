#!/bin/bash
# The SQL of your own database server (docs/databases.md#your-own-server) at every start of the
# stack, before the migrations: the one-shot db-bootstrap (Sync) and fxa-db-bootstrap (the
# accounts), with the database server's client (the image of the database or of its backups),
# this file and the template mounted in /ffs-db (FFS_DB_DIR):
#
#   db-setup.sh sync    /ffs-db/sync.sql: db/mysql/sync.sql (MariaDB, MySQL: FFS_DB_ENGINE unset)
#                       or db/postgres/sync.sql (FFS_DB_ENGINE=postgres)
#   db-setup.sh fxa     /ffs-db/fxa.sql: db/mysql/fxa-mysql.sql (FFS_DB_ENGINE=mysql) or
#                       fxa-mariadb.sql (mariadb)
#   db-setup.sh settings <mysql|postgres|fxa>   the placeholders of the template and the
#                       settings of .env that fill them (prepare_environment.sh's database-setup.sql)
#
# The template is filled in from the settings of .env in this container's environment, as
# prepare_environment.sh fills in database-setup.sql. Then:
#   - with SYNC_DB_BOOTSTRAP_USER and _PASSWORD (FXA_DB_BOOTSTRAP_*): run as that account, an
#     account that can create users (docs/databases.md#the-bootstrap-account), then checked;
#   - without: only checked, as the stack's own users: each one signs in, has its grants, its
#     databases exist. Something missing stops here, naming the statement (the passwords as
#     <SETTING>) and docs/databases.md#when-a-release-needs-new-users-or-grants;
#   - with the stack's own database containers (SYNC_DB_CONTAINERS, FXA_DB_CONTAINERS not 0):
#     nothing.
# Fails closed: the migrations, the init container and the accounts do not start after a
# failure. The passwords are in the clients' environment (MYSQL_PWD, PGPASSWORD) and in the SQL
# on their input, never in their arguments.
set -u

DOC=docs/databases.md#when-a-release-needs-new-users-or-grants

# the placeholders of a template and the settings that fill them, "PLACEHOLDER SETTING"
# per line (also read by prepare_environment.sh, setup/databases.sh)
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
# the account that runs the SQL: "SETTING_USER SETTING_PASSWORD" of a scope
bootstrap_settings() {
  case "$1" in
    sync) echo "SYNC_DB_BOOTSTRAP_USER SYNC_DB_BOOTSTRAP_PASSWORD" ;;
    fxa) echo "FXA_DB_BOOTSTRAP_USER FXA_DB_BOOTSTRAP_PASSWORD" ;;
  esac
}

if [ "${1:-}" = settings ]; then
  sql_settings "${2:-}" || { echo "usage: $0 settings <mysql|postgres|fxa>" >&2; exit 2; }
  exit 0
fi

SCOPE=${1:-}
case "${SCOPE}" in sync|fxa) ;; *) echo "usage: $0 <sync|fxa>" >&2; exit 2 ;; esac
DIR=${FFS_DB_DIR:-/ffs-db}
fail() { echo "✗ ERROR: $*"; exit 1; }

if [ "${SCOPE}" = sync ]; then
  ENGINE=${FFS_DB_ENGINE:-mariadb} CONTAINERS=${SYNC_DB_CONTAINERS:-1} TEMPLATE=${DIR}/sync.sql
  KIND=$([ "${ENGINE}" = postgres ] && echo postgres || echo mysql)
  WHAT="the Sync databases" FILE=database-setup.sql
else
  ENGINE=${FFS_DB_ENGINE:-mysql} CONTAINERS=${FXA_DB_CONTAINERS:-1} TEMPLATE=${DIR}/fxa.sql KIND=fxa
  WHAT="the accounts' databases" FILE=database-setup-fxa.sql
fi
case "${ENGINE}" in mariadb|mysql|postgres) ;; *) fail "FFS_DB_ENGINE: mariadb, mysql or postgres, not '${ENGINE}'" ;; esac
read -r USER_SETTING PASSWORD_SETTING <<< "$(bootstrap_settings "${SCOPE}")"
BOOT_USER=${!USER_SETTING:-} BOOT_PASSWORD=${!PASSWORD_SETTING:-}

if [ "${CONTAINERS}" != 0 ]; then
  echo "${WHAT}: the stack's own database containers, nothing to do here"
  exit 0
fi
if [ -n "${BOOT_USER}" ] && [ -z "${BOOT_PASSWORD}" ]; then
  fail "${USER_SETTING} is set, ${PASSWORD_SETTING} is empty: set both, or neither (docs/databases.md#let-the-stack-apply-them)"
elif [ -z "${BOOT_USER}" ] && [ -n "${BOOT_PASSWORD}" ]; then
  fail "${PASSWORD_SETTING} is set, ${USER_SETTING} is empty: set both, or neither (docs/databases.md#let-the-stack-apply-them)"
fi
[ -r "${TEMPLATE}" ] || fail "no ${TEMPLATE}: the deployment mounts the SQL of db/ there"
# a setting under both names (FFS_BOTH_ENV_NAMES, compose; the new one wins, often a line added
# from .env-example): refused, as the migrations and the init container refuse it
if [ -n "${FFS_BOTH_ENV_NAMES:-}" ]; then
  for pair in ${FFS_BOTH_ENV_NAMES}; do
    echo "ERROR: ${pair%%/*} and ${pair#*/} are both set (in .env or in the environment docker compose runs in): run ./prepare_environment.sh --upgrade for .env, or unset ${pair#*/} in your shell (docs/upgrading.md#renamed-settings)"
  done
  exit 1
fi

# where each database is: the server of the tokenserver (the Sync and the admin UI's
# databases), the storage's own (SYNC_STORAGE_DB_HOST), PostgreSQL's, the accounts'
if [ "${SCOPE}" = fxa ]; then
  # (the certificate not checked: the accounts connect without TLS, on a trusted network)
  MAIN_HOST=${FXA_MYSQL_HOST:-} MAIN_PORT=${FXA_MYSQL_PORT:-3306} TLS_VERIFY=false
elif [ "${ENGINE}" = postgres ]; then
  MAIN_HOST=${SYNC_POSTGRES_HOST:-} MAIN_PORT=${SYNC_POSTGRES_PORT:-5432}
else
  MAIN_HOST=${SYNC_TOKENSERVER_DB_HOST:-} MAIN_PORT=${SYNC_TOKENSERVER_DB_PORT:-3306} TLS_VERIFY=${SYNC_DB_TLS_VERIFY:-true}
  STORAGE_HOST=${SYNC_STORAGE_DB_HOST:-${MAIN_HOST}} STORAGE_PORT=${SYNC_STORAGE_DB_PORT:-${MAIN_PORT}}
fi
[ -n "${MAIN_HOST}" ] || fail "no host of ${WHAT}: set it in .env"
# the host of a database (mariadb, mysql): "<host> <port>"
db_server() {
  if [ "${SCOPE}" = sync ] && [ "$1" = "${SYNC_STORAGE_DB_NAME:-}" ]; then echo "${STORAGE_HOST} ${STORAGE_PORT}"; else echo "${MAIN_HOST} ${MAIN_PORT}"; fi
}

# the template filled in: RENDERED with the passwords (what runs), SHOWN with <SETTING> for
# them (what the messages say). Names and passwords as docs/databases.md#create-the-databases-and-users
# allows them: they end up in SQL. Without ADMIN_DB_PASSWORD (an install from before it) the
# Sync part only: the admin UI keeps its tables in the tokenserver database
WORK=$(mktemp -d) || exit 1
trap 'rm -rf "${WORK}"' EXIT
chmod 700 "${WORK}"
RENDERED=${WORK}/rendered.sql SHOWN=${WORK}/shown.sql
render() {
  local placeholder setting value exec_script="" show_script="" source=${WORK}/template.sql
  if [ "${SCOPE}" = sync ] && [ -z "${ADMIN_DB_PASSWORD:-}" ]; then
    sed -e '/^-- The admin UI:/,$d' "${TEMPLATE}" > "${source}"
  elif [ "${KIND}" = fxa ] && [ "${ENGINE}" = mysql ] && [[ "${FXA_MYSQL_ARGS:-}" == *mysql_native_password* ]]; then
    # MySQL with mysql_native_password (FXA_MYSQL_ARGS, an accounts image without
    # mozilla/fxa#21554): the commented lines of fxa-mysql.sql instead of those after them
    sed -e "/^-- native: /{s/^-- native: //;n;d;}" "${TEMPLATE}" > "${source}"
  else
    cp "${TEMPLATE}" "${source}"
  fi
  # no policy user (FXA_MYSQL_POLICY_USER empty): FXA_MYSQL_USER installs the policy, with the
  # policy user's grants, as docs/reference/database-users.md#the-accounts says
  if [ "${KIND}" = fxa ] && [ -z "${FXA_MYSQL_POLICY_USER:-}" ]; then
    sed -i -e '/^\(CREATE\|ALTER\) USER .*@FXA_POLICY_USER@/d' -e 's/@FXA_POLICY_USER@/@FXA_USER@/g' "${source}"
  fi
  while read -r placeholder setting; do
    value=${!setting:-}
    if [[ "${setting}" == *PASSWORD ]]; then
      case "${value}" in
        "") grep -q "@${placeholder}@" "${source}" && fail "${setting} is empty: set it in .env" ;;
        *"<REPLACE_WITH_"*) fail "${setting} is still the placeholder of .env-example: set it in .env" ;;
      esac
      [[ -z "${value}" || "${value}" =~ ^[A-Za-z0-9._~-]+$ ]] || fail "${setting}: only A-Z a-z 0-9 . _ ~ - (docs/databases.md#create-the-databases-and-users)"
      show_script="${show_script}s|@${placeholder}@|<${setting}>|g
"
    else
      [ -n "${value}" ] || { grep -q "@${placeholder}@" "${source}" && fail "${setting} is empty: set it in .env"; }
      [[ -z "${value}" || "${value}" =~ ^[a-z_][a-z0-9_]{0,31}$ ]] || fail "${setting} '${value}': a-z, 0-9 and _ only (docs/databases.md#create-the-databases-and-users)"
      show_script="${show_script}s|@${placeholder}@|${value}|g
"
    fi
    exec_script="${exec_script}s|@${placeholder}@|${value}|g
"
  done < <(sql_settings "${KIND}")
  (umask 077; sed -e "${exec_script}" "${source}" > "${RENDERED}") || exit 1
  sed -e "${show_script}" "${source}" > "${SHOWN}" || exit 1
  ! grep -q '@[A-Z_]*@' "${RENDERED}" || fail "${TEMPLATE} has placeholders this script does not know: $(grep -o '@[A-Z_]*@' "${RENDERED}" | sort -u | tr '\n' ' ')"
}
render

# ---- MariaDB and MySQL
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
# the statements of a file, one per line, without the comments (the templates have no ; in a value)
statements() {
  grep -v '^[[:space:]]*--' "$1" | grep -v '^[\]' | tr '\n' ' ' | sed -e 's/;[[:space:]]*/;\n/g' | sed -e 's/^[[:space:]]*//; s/[[:space:]][[:space:]]*/ /g' | grep -v '^$'
}
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
# every database-level privilege of ALL PRIVILEGES on MySQL 8.4+ and MariaDB 10.10+
ALL_PRIVILEGES="SELECT,INSERT,UPDATE,DELETE,CREATE,DROP,REFERENCES,INDEX,ALTER,CREATE TEMPORARY TABLES,LOCK TABLES,EXECUTE,CREATE VIEW,SHOW VIEW,CREATE ROUTINE,ALTER ROUTINE,EVENT,TRIGGER"
PROBLEMS=()
problem() { PROBLEMS+=("$1"); }
mysql_check() {
  local -a run shown
  local i s user password db privs grantable server have priv missing
  local -A passwords=() created=() altered=() signed=() login_error=() checked_db=()
  mapfile -t run < <(statements "${RENDERED}")
  mapfile -t shown < <(statements "${SHOWN}")
  # the users and their passwords
  for i in "${!run[@]}"; do
    s=${run[i]}
    if [[ "${s}" =~ ^CREATE\ USER\ IF\ NOT\ EXISTS\ \'([^\']+)\'@\'[^\']*\'\ IDENTIFIED\ (BY|WITH\ [a-z_]+\ BY)\ \'([^\']*)\'\;$ ]]; then
      passwords[${BASH_REMATCH[1]}]=${BASH_REMATCH[3]} created[${BASH_REMATCH[1]}]=${shown[i]}
    elif [[ "${s}" =~ ^CREATE\ USER\ IF\ NOT\ EXISTS\ \'([^\']+)\'@\'[^\']*\'\ IDENTIFIED\ VIA\ [a-z_]+\ USING\ PASSWORD\(\'([^\']*)\'\)\;$ ]]; then
      passwords[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]} created[${BASH_REMATCH[1]}]=${shown[i]}
    elif [[ "${s}" =~ ^ALTER\ USER\ \'([^\']+)\'@ ]]; then
      altered[${BASH_REMATCH[1]}]=" ${shown[i]}"
    fi
  done
  # signs_in <user> <host> <port>: the user signs in there (once per server)
  signs_in() {
    local key="$1 $2 $3" out
    if [ -z "${signed[${key}]:-}" ]; then
      if out=$(my_sql "$1" "${passwords[$1]}" "$2" "$3" -N -B -e 'SELECT 1' < /dev/null 2>&1); then
        signed[${key}]=yes
      else
        signed[${key}]=no login_error[${key}]=$(printf '%s' "${out}" | grep -v '^WARNING' | head -n 1)
        problem "'$1' cannot sign in on $2:$3 (${login_error[${key}]}): ${created[$1]}${altered[$1]:-}"
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
    [ -n "${passwords[${user}]:-}" ] || { problem "no CREATE USER of '${user}' in ${TEMPLATE}"; continue; }
    read -r -a server <<< "$(db_server "${db}")"
    signs_in "${user}" "${server[0]}" "${server[1]}" || continue
    # its privileges on the database (and those on every database), as it sees them itself
    have=$(my_sql "${user}" "${passwords[${user}]}" "${server[0]}" "${server[1]}" -N -B -e \
      "SELECT PRIVILEGE_TYPE, IS_GRANTABLE FROM information_schema.SCHEMA_PRIVILEGES WHERE TABLE_SCHEMA = '${db}' UNION ALL SELECT PRIVILEGE_TYPE, IS_GRANTABLE FROM information_schema.USER_PRIVILEGES" < /dev/null 2>&1) \
      || { problem "'${user}' cannot read its privileges on ${server[0]}:${server[1]} (${have}): ${shown[i]}"; continue; }
    [ "${privs}" = "ALL PRIVILEGES" ] && privs=${ALL_PRIVILEGES}
    missing=()
    while IFS= read -r priv; do
      priv=${priv# } priv=${priv% }
      [ -n "${priv}" ] || continue
      grep -qx "${priv}"$'\t'"\\(YES\\|NO\\)" <<< "${have}" || missing+=("${priv}")
    done <<< "${privs//,/$'\n'}"
    [ -z "${grantable}" ] || grep -q $'\tYES$' <<< "${have}" || missing+=("GRANT OPTION")
    if [ "${#missing[@]}" != 0 ]; then
      priv=$(printf '%s, ' "${missing[@]}")
      problem "'${user}' lacks ${priv%, } on \`${db}\`: ${shown[i]}"
    elif [ -z "${checked_db[${db}]:-}" ]; then
      # the database itself, where the SQL creates it (the accounts' migrations create theirs)
      checked_db[${db}]=yes
      if printf '%s\n' "${run[@]}" | grep -qx "CREATE DATABASE IF NOT EXISTS \`${db}\`;" \
        && [ "$(my_sql "${user}" "${passwords[${user}]}" "${server[0]}" "${server[1]}" -N -B -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '${db}'" < /dev/null 2> /dev/null)" != 1 ]; then
        problem "no database \`${db}\` on ${server[0]}:${server[1]}: CREATE DATABASE IF NOT EXISTS \`${db}\`;"
      fi
    fi
  done
}

# ---- PostgreSQL: the roles and databases of db/postgres/sync.sql, read from the catalogs
# as the owner of the Sync database (SYNC_POSTGRES_USER), and the admin UI's database as its role
pg_sql() { # user password database query
  PGPASSWORD="$2" PGCONNECT_TIMEOUT=10 psql -X -h "${MAIN_HOST}" -p "${MAIN_PORT}" -U "$1" -d "$3" -v ON_ERROR_STOP=1 -tA -c "$4" < /dev/null 2>&1
}
# pg_foreign <user> <password> <database> <the stack's roles...>: the grants on the database to
# roles but those (PUBLIC: checked apart), and its objects that its owner does not own (the
# code of another role, which the stack's sessions would run), at most 5 of each
pg_foreign() {
  local user=$1 password=$2 db=$3 allowed out
  shift 3
  allowed=$(printf "'%s'," "$@")
  out=$(q "${user}" "${password}" "${db}" "SELECT string_agg(DISTINCT pg_get_userbyid(a.grantee), ' ') FROM pg_database d, aclexplode(d.datacl) a
    WHERE d.datname = current_database() AND a.grantee <> 0 AND pg_get_userbyid(a.grantee) NOT IN (${allowed%,})")
  for role in ${out}; do
    problem "the role ${role} has grants on the database ${db}, which is the stack's: REVOKE ALL ON DATABASE ${db} FROM ${role};"
  done
  out=$(q "${user}" "${password}" "${db}" "SELECT string_agg(o, ', ') FROM (SELECT o FROM (
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
  [ -z "${out}" ] || problem "in the database ${db}, what its owner ${user} does not own (another role's code, which the stack would run): ${out}. ALTER ... OWNER TO ${user}, or drop them"
}
pg_check() {
  local owner=${SYNC_POSTGRES_USER} db=${SYNC_POSTGRES_NAME} out role
  if ! out=$(pg_sql "${owner}" "${SYNC_POSTGRES_PASSWORD}" "${db}" "SELECT 1"); then
    problem "'${owner}' cannot sign in to the database ${db} ($(head -n 1 <<< "${out}")): CREATE ROLE ${owner} LOGIN PASSWORD '<SYNC_POSTGRES_PASSWORD>'; CREATE DATABASE ${db} OWNER ${owner};"
    return
  fi
  # pg_catalog alone in the search path: nothing of the public schema stands in for a name
  q() { pg_sql "$1" "$2" "$3" "SET search_path = pg_catalog, pg_temp; $4" | tail -n 1; }
  pg_foreign "${owner}" "${SYNC_POSTGRES_PASSWORD}" "${db}" "${owner}" "${ADMIN_DB_SYNC_USER:-ffs_admin_sync}"
  [ "$(q "${owner}" "${SYNC_POSTGRES_PASSWORD}" "${db}" "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = current_database()")" = "${owner}" ] \
    || problem "the database ${db} is not ${owner}'s: ALTER DATABASE ${db} OWNER TO ${owner};"
  [ "$(q "${owner}" "${SYNC_POSTGRES_PASSWORD}" "${db}" "SELECT has_database_privilege('public', current_database(), 'CONNECT')")" = f ] \
    || problem "every role may connect to the database ${db}: REVOKE ALL ON DATABASE ${db} FROM PUBLIC;"
  [ -n "${ADMIN_DB_PASSWORD:-}" ] || return 0
  for role in "${ADMIN_DB_USER}" "${ADMIN_DB_SYNC_USER}"; do
    [ "$(q "${owner}" "${SYNC_POSTGRES_PASSWORD}" "${db}" "SELECT rolcanlogin FROM pg_roles WHERE rolname = '${role}'")" = t ] \
      || problem "no role ${role} that can sign in: CREATE ROLE ${role} LOGIN PASSWORD '<ADMIN_DB_PASSWORD>';"
  done
  case "$(q "${owner}" "${SYNC_POSTGRES_PASSWORD}" "${db}" "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '${ADMIN_DB_NAME}'")" in
    "") problem "no database ${ADMIN_DB_NAME}: CREATE DATABASE ${ADMIN_DB_NAME} OWNER ${ADMIN_DB_USER} TEMPLATE template0;"; return ;;
    "${ADMIN_DB_USER}") ;;
    *) problem "the database ${ADMIN_DB_NAME} is not ${ADMIN_DB_USER}'s: ALTER DATABASE ${ADMIN_DB_NAME} OWNER TO ${ADMIN_DB_USER};" ;;
  esac
  [ "$(q "${owner}" "${SYNC_POSTGRES_PASSWORD}" "${db}" "SELECT has_database_privilege('public', '${ADMIN_DB_NAME}', 'CONNECT')")" = f ] \
    || problem "every role may connect to the database ${ADMIN_DB_NAME}: REVOKE ALL ON DATABASE ${ADMIN_DB_NAME} FROM PUBLIC;"
  if ! out=$(pg_sql "${ADMIN_DB_USER}" "${ADMIN_DB_PASSWORD}" "${ADMIN_DB_NAME}" "SELECT 1"); then
    problem "'${ADMIN_DB_USER}' cannot sign in to the database ${ADMIN_DB_NAME} ($(head -n 1 <<< "${out}")): ALTER ROLE ${ADMIN_DB_USER} PASSWORD '<ADMIN_DB_PASSWORD>';"
    return
  fi
  pg_foreign "${ADMIN_DB_USER}" "${ADMIN_DB_PASSWORD}" "${ADMIN_DB_NAME}" "${ADMIN_DB_USER}"
  if [ "$(q "${ADMIN_DB_USER}" "${ADMIN_DB_PASSWORD}" "${ADMIN_DB_NAME}" "SELECT has_schema_privilege('public', 'public', 'CREATE')")" != f ]; then
    # (PostgreSQL 11 to 14: a role that is no superuser cannot revoke it, the admin UI then
    # refuses what another role puts there: a warning)
    echo "WARNING: every role may create tables in the public schema of ${ADMIN_DB_NAME}: as a superuser, \\connect ${ADMIN_DB_NAME} and REVOKE CREATE ON SCHEMA public FROM PUBLIC;"
  fi
}

check() {
  PROBLEMS=()
  wait_server "${MAIN_HOST}" "${MAIN_PORT}"
  if [ "${ENGINE}" = postgres ]; then pg_check; else
    [ "${SCOPE}" = fxa ] || [ "${STORAGE_HOST} ${STORAGE_PORT}" = "${MAIN_HOST} ${MAIN_PORT}" ] || wait_server "${STORAGE_HOST}" "${STORAGE_PORT}"
    mysql_check
  fi
  if [ "${#PROBLEMS[@]}" != 0 ]; then
    echo "✗ ERROR: ${WHAT} on your server lack what this release needs:"
    printf '  - %s\n' "${PROBLEMS[@]}"
    if [ -n "${BOOT_USER}" ]; then
      echo "  after the SQL ran as ${BOOT_USER}: see the statements above (${DOC})"
    else
      echo "  Run ${FILE} again on that server as its administrator (./prepare_environment.sh --upgrade writes it again; Helm: the SQL of db/ filled in), or let the stack do it at every start with ${USER_SETTING} (${DOC})"
    fi
    exit 1
  fi
  echo "✓ ${WHAT} on ${MAIN_HOST}:${MAIN_PORT}: every user, grant and database of ${FILE} is there"
}

if [ -z "${BOOT_USER}" ]; then
  echo "${WHAT}: checking the users, grants and databases of ${FILE} (${USER_SETTING} not set: the stack does not change them)"
  check
  exit 0
fi

# ---- the bootstrap: the SQL as BOOT_USER, then the check. The account can create and change
# users (docs/databases.md#the-bootstrap-account): it is only ever given the stack's own names,
# never a reserved one, never a user of that name it did not create (one that does not sign in
# with the stack's password), and it must not be an administrator of the server itself
[[ "${BOOT_USER}" =~ ^[A-Za-z0-9_]{1,32}$ ]] || fail "${USER_SETTING} '${BOOT_USER}': A-Z, a-z, 0-9 and _ only, at most 32"
echo "${WHAT}: applying ${FILE} as ${BOOT_USER} (${USER_SETTING}) on ${MAIN_HOST}:${MAIN_PORT}"
if [ "${ENGINE}" != postgres ] && [ "${SCOPE}" = sync ] && [ "${STORAGE_HOST} ${STORAGE_PORT}" != "${MAIN_HOST} ${MAIN_PORT}" ]; then
  fail "the storage database is on another server (SYNC_STORAGE_DB_HOST, SYNC_STORAGE_DB_PORT): the bootstrap needs both Sync databases on one server. Unset ${USER_SETTING} and run ${FILE} by hand, as docs/databases.md#create-the-databases-and-users says"
fi
# the names of the server's own accounts and roles (the images' too: MariaDB's mysql and
# healthcheck), and the bootstrap account's: never one of the stack's users
RESERVED="root mysql healthcheck mariadb_sys mysql_sys postgres public ${BOOT_USER}"
while read -r placeholder setting; do
  [[ "${setting}" == *_USER ]] || continue
  value=${!setting:-}
  case " ${RESERVED} " in
    *" ${value} "*) [ -n "${value}" ] && fail "${setting} is '${value}', a name of the server's own accounts or the bootstrap account's: the bootstrap creates and changes the stack's users only, choose another name (docs/databases.md#the-bootstrap-account)" ;;
  esac
done < <(sql_settings "${KIND}")
wait_server "${MAIN_HOST}" "${MAIN_PORT}"
# the clients' messages without a password: each one of the settings as <SETTING> (MariaDB's
# client repeats the failing statement, psql its line)
redact() {
  local line placeholder setting value
  while IFS= read -r line; do
    while read -r placeholder setting; do
      value=${!setting:-}
      [[ "${setting}" == *PASSWORD && -n "${value}" ]] && line=${line//"${value}"/<${setting}>}
    done < <(sql_settings "${KIND}")
    line=${line//"${BOOT_PASSWORD}"/<${PASSWORD_SETTING}>}
    printf '  %s\n' "${line}"
  done
}
failed() {
  echo "✗ ERROR: ${FILE} failed as ${BOOT_USER} on ${MAIN_HOST}:${MAIN_PORT}: $1"
  echo "  The account needs the grants of docs/databases.md#the-bootstrap-account (${DOC})"
  exit 1
}
foreign() { # <user> <its setting>
  failed "'$1' exists on the server and does not sign in with <$2>: it is not one of this stack's users (or one with the passwords of an earlier .env), and the bootstrap does not change it. Give it that password yourself if it is the stack's, or choose another name"
}
if [ "${ENGINE}" = postgres ]; then
  boot_psql() { PGPASSWORD="${BOOT_PASSWORD}" PGCONNECT_TIMEOUT=10 psql -X -h "${MAIN_HOST}" -p "${MAIN_PORT}" -U "${BOOT_USER}" -d postgres -v ON_ERROR_STOP=1 "$@" 2>&1; }
  out=$(boot_psql -tA -c "SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = current_user") \
    || { printf '%s\n' "${out}" | redact; failed "cannot sign in"; }
  [ "${out}" = f ] || failed "${BOOT_USER} is a superuser: the bootstrap account must be a role with CREATEROLE and CREATEDB only (docs/databases.md#the-bootstrap-account)"
  # the stack's roles that exist: theirs if they sign in with the stack's password (a database
  # they may not connect to says so after the password)
  roles=("${SYNC_POSTGRES_USER} SYNC_POSTGRES_PASSWORD")
  [ -z "${ADMIN_DB_PASSWORD:-}" ] || roles+=("${ADMIN_DB_USER} ADMIN_DB_PASSWORD" "${ADMIN_DB_SYNC_USER} ADMIN_DB_PASSWORD")
  for pair in "${roles[@]}"; do
    read -r role setting <<< "${pair}"
    [ "$(boot_psql -tA -c "SELECT COUNT(*) FROM pg_catalog.pg_roles WHERE rolname = '${role}'")" = 1 ] || continue
    if ! out=$(PGPASSWORD="${!setting}" PGCONNECT_TIMEOUT=10 psql -X -h "${MAIN_HOST}" -p "${MAIN_PORT}" -U "${role}" -d postgres -tA -c 'SELECT 1' < /dev/null 2>&1) \
      && ! grep -qE 'permission denied for database|database "[^"]*" does not exist' <<< "${out}"; then
      foreign "${role}" "${setting}"
    fi
  done
  # (a database every role reaches to start from; the SQL connects to the admin UI's itself)
  if ! out=$(boot_psql -q -f "${RENDERED}"); then
    printf '%s\n' "${out}" | grep -v 'NOTICE:' | redact
    # psql:<file>:<line>: ERROR: the statement of that line
    line=$(printf '%s\n' "${out}" | sed -n 's/^psql:[^:]*:\([0-9][0-9]*\): ERROR:.*/\1/p' | head -n 1)
    failed "$([ -n "${line}" ] && sed -n "${line}p" "${SHOWN}" || echo "see the error above")"
  fi
else
  # on the whole server only CREATE USER (and USAGE, no privilege): not an administrator
  # (SYSTEM_USER, SUPER, ALL PRIVILEGES...), docs/databases.md#the-bootstrap-account
  out=$(printf 'SHOW GRANTS;\n' | my_sql "${BOOT_USER}" "${BOOT_PASSWORD}" "${MAIN_HOST}" "${MAIN_PORT}" -N -B 2>&1) \
    || { printf '%s\n' "${out}" | grep -E '^ERROR' | redact; failed "cannot sign in"; }
  wide=""
  while IFS= read -r line; do
    [[ "${line}" == GRANT\ *\ ON\ \*.\*\ TO\ * ]] || continue
    privs=${line#GRANT } privs=${privs%% ON \*.\* TO*}
    [[ "${line}" == *"WITH GRANT OPTION"* ]] && wide="${wide} GRANT OPTION,"
    while IFS= read -r priv; do
      priv=${priv# }
      case "${priv}" in USAGE|"CREATE USER") ;; *) wide="${wide} ${priv}," ;; esac
    done <<< "${privs//,/$'\n'}"
  done <<< "${out}"
  [ -z "${wide}" ] || failed "${BOOT_USER} holds${wide%,} on the whole server (*.*): the bootstrap account must have only CREATE USER there, and ALL PRIVILEGES on the stack's databases (docs/databases.md#the-bootstrap-account)"
  # one statement at a time. CREATE USER of a user that exists: one of the stack's if it signs
  # in with the stack's password (its ALTER USER follows; CREATE USER IF NOT EXISTS of a DEFINER
  # of routines would fail without SET_ANY_DEFINER, ERROR 4006), else not the stack's: refused,
  # nothing changed. Of one that does not: created (CREATE USER, without IF NOT EXISTS)
  mapfile -t run < <(statements "${RENDERED}")
  mapfile -t shown < <(statements "${SHOWN}")
  for i in "${!run[@]}"; do
    statement=${run[i]}
    if [[ "${statement}" =~ ^CREATE\ USER\ IF\ NOT\ EXISTS\ \'([^\']+)\'@\'[^\']*\'\ IDENTIFIED\ (BY|WITH\ [a-z_]+\ BY)\ \'([^\']*)\'\; ]] \
      || [[ "${statement}" =~ ^CREATE\ USER\ IF\ NOT\ EXISTS\ \'([^\']+)\'@\'[^\']*\'\ IDENTIFIED\ VIA\ [a-z_]+\ USING\ PASSWORD\(\'([^\']*)\'\)\; ]]; then
      user=${BASH_REMATCH[1]} password=${BASH_REMATCH[${#BASH_REMATCH[@]}-1]}
      if my_sql "${user}" "${password}" "${MAIN_HOST}" "${MAIN_PORT}" -N -B -e 'SELECT 1' < /dev/null > /dev/null 2>&1; then
        continue
      fi
      statement="CREATE USER ${statement#CREATE USER IF NOT EXISTS }"
      if ! out=$(printf '%s\n' "${statement}" | my_sql "${BOOT_USER}" "${BOOT_PASSWORD}" "${MAIN_HOST}" "${MAIN_PORT}" 2>&1); then
        if [[ "${out}" == *"ERROR 1396 "* || "${out}" == *"ERROR 4006 "* ]]; then
          setting=$(sed -n "s/.*'<\([A-Z_]*\)>'.*/\1/p" <<< "${shown[i]}" | head -n 1)
          foreign "${user}" "${setting}"
        fi
        printf '%s\n' "${out}" | grep -E '^ERROR' | redact
        failed "${shown[i]}"
      fi
      continue
    fi
    if ! out=$(printf '%s\n' "${statement}" | my_sql "${BOOT_USER}" "${BOOT_PASSWORD}" "${MAIN_HOST}" "${MAIN_PORT}" 2>&1); then
      printf '%s\n' "${out}" | grep -E '^ERROR' | redact
      failed "${shown[i]}"
    fi
  done
fi
echo "✓ ${FILE} applied as ${BOOT_USER}"
check
exit 0
