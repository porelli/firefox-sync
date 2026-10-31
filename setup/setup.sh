# shellcheck shell=bash
# prepare_environment.sh without an option: the setup, its questions in their order, then .env,
# the nginx, systemd and SQL examples and, with Quadlets, the units. Sourced by
# prepare_environment.sh when it runs (not by the tests that source it): it runs as it is read.

# Detect container runtime
detect_runtime() {
    if command -v podman &> /dev/null; then
        echo "podman"
    elif command -v docker &> /dev/null; then
        echo "docker"
    else
        echo "none"
    fi
}

CONTAINER_RUNTIME=$(detect_runtime)

# domain
DOMAIN_EXAMPLE='firefox-sync.example.com'
read -r -e -p "Enter FQDN for your Firefox sync server [${DOMAIN_EXAMPLE}]: " SYNC_FQDN
SYNC_FQDN=${SYNC_FQDN:-${DOMAIN_EXAMPLE}}

# compose dir
CURRENT_DIR=${FFS_ENTRY_DIR}
read -r -e -p "Enter full path for the docker-compose file [${CURRENT_DIR}]: " SCRIPT_DIR
SCRIPT_DIR=${SCRIPT_DIR:-${CURRENT_DIR}}

# where the Sync server listens for your reverse proxy, [address:]port: on this host only by
# default, as the other ports; a port alone is 127.0.0.1:<port>, 0.0.0.0:<port> (or [::]:<port>)
# every interface. Run again on an install: what its .env has, as it is
DEFAULT_SYNC_EXPORT_PORT=127.0.0.1:5000
if [ -f "${SCRIPT_DIR}/.env" ]; then
    previous=$(env_plain SYNC_EXPORT_PORT); previous=${previous:-$(env_plain CONTAINER_EXPORT_PORT)}
    DEFAULT_SYNC_EXPORT_PORT=${previous:-${DEFAULT_SYNC_EXPORT_PORT}}
fi
read -r -e -p "Listening address and port for syncstorage-rs, a port alone on 127.0.0.1 [${DEFAULT_SYNC_EXPORT_PORT}]: " SYNC_EXPORT_PORT
case "${SYNC_EXPORT_PORT}" in
    "")
        SYNC_EXPORT_PORT=${DEFAULT_SYNC_EXPORT_PORT}
        # what an install has is kept as it is, also a value this check does not know
        if ! valid_export_port "${SYNC_EXPORT_PORT}"; then
            echo "WARNING: SYNC_EXPORT_PORT='${SYNC_EXPORT_PORT}' of .env is not [address:]port as this script knows it: kept"
            SYNC_EXPORT_KEPT=yes
        fi ;;
    *[!0-9]*) ;;
    *) SYNC_EXPORT_PORT=127.0.0.1:${SYNC_EXPORT_PORT} ;;
esac
if [ -z "${SYNC_EXPORT_KEPT:-}" ] && ! valid_export_port "${SYNC_EXPORT_PORT}"; then
    echo "ERROR: not a port or an address and port: '${SYNC_EXPORT_PORT}' (e.g. 5000, 127.0.0.1:5000, 0.0.0.0:5000, [::]:5000)"
    exit 1
fi


# max users
DEFAULT_MAX_USERS=1
read -r -e -p "Max allowed users, a number or unlimited [${DEFAULT_MAX_USERS}]: " SYNC_MAX_USERS
SYNC_MAX_USERS=${SYNC_MAX_USERS:-${DEFAULT_MAX_USERS}}
valid_limit "max users" "${SYNC_MAX_USERS}"

# database backend
DEFAULT_DATABASE_BACKEND=mariadb
read -r -e -p "Database backend [mariadb/mysql/postgres] [${DEFAULT_DATABASE_BACKEND}]: " DATABASE_BACKEND
DATABASE_BACKEND=${DATABASE_BACKEND:-${DEFAULT_DATABASE_BACKEND}}
case "${DATABASE_BACKEND}" in
    mariadb|postgres) SYNC_DB=mariadb ;;
    # MySQL containers (compose/sync-mysql.yml), the same Sync images as MariaDB
    mysql|MySQL) DATABASE_BACKEND=mysql; SYNC_DB=mysql ;;
    *)
        echo "ERROR: unknown database backend '${DATABASE_BACKEND}'"
        exit 1
        ;;
esac

# Container runtime detection
echo ""
echo "Detected container runtime: ${CONTAINER_RUNTIME}"

if [ "${CONTAINER_RUNTIME}" = "none" ]; then
    echo "WARNING: Neither Docker nor Podman detected!"
    echo "Please install Docker or Podman before proceeding."
    read -r -e -p "Continue anyway? (y/N): " CONTINUE
    if [ "${CONTINUE}" != "y" ] && [ "${CONTINUE}" != "Y" ]; then
        exit 1
    fi
fi

# Ask about deployment method
if [ "${CONTAINER_RUNTIME}" = "podman" ]; then
    echo ""
    echo "Podman detected! Choose deployment method:"
    echo "  1) Quadlets (systemd integration, recommended)"
    echo "  2) docker compose with the Podman socket"
    read -r -e -p "Deployment method [1]: " DEPLOY_METHOD
    case "${DEPLOY_METHOD:-1}" in
        1) DEPLOY_METHOD=quadlets ;;
        2) DEPLOY_METHOD=compose ;;
        *) echo "ERROR: unknown deployment method '${DEPLOY_METHOD}'"; exit 1 ;;
    esac
fi

# docker/podman user (for systemd service)
DEFAULT_CONTAINER_USER=${USER}
read -r -e -p "Container user [${DEFAULT_CONTAINER_USER}]: " CONTAINER_USER
CONTAINER_USER=${CONTAINER_USER:-${DEFAULT_CONTAINER_USER}}

# syncstorage image tag
DEFAULT_SYNCSTORAGE_IMAGE_TAG=latest
read -r -e -p "Syncstorage image tag [latest/<tag>] [${DEFAULT_SYNCSTORAGE_IMAGE_TAG}]: " SYNC_IMAGE_TAG
SYNC_IMAGE_TAG=${SYNC_IMAGE_TAG:-${DEFAULT_SYNCSTORAGE_IMAGE_TAG}}

# admin UI
read -r -e -p "Enable the admin UI? Max users, and sign-ups and accounts with self-hosted accounts, see docs/admin/README.md (Y/n): " ADMIN_UI
case "${ADMIN_UI}" in n|N|no) ADMIN_UI=no ;; *) ADMIN_UI=yes ;; esac
# with the admin UI, max users is managed there: SYNC_MAX_USERS=initial:N sets it only on the
# first start. A plain number is set again on every start (read-only in the admin UI)
[ "${ADMIN_UI}" = "yes" ] && SYNC_MAX_USERS=initial:${SYNC_MAX_USERS}

# admin sign-in with the self-hosted accounts, asked below
ADMIN_ALLOWED_USERS=""
ADMIN_HOST=""

# self-hosted Mozilla accounts (docs/accounts.md)
read -r -e -p "Also self-host Mozilla accounts? See docs/accounts.md (y/N): " SELF_HOST_FXA
case "${SELF_HOST_FXA}" in y|Y|yes) SELF_HOST_FXA=yes ;; *) SELF_HOST_FXA=no ;; esac
if [ "${SELF_HOST_FXA}" = "yes" ]; then
    DEFAULT_FXA_DOMAIN=${SYNC_FQDN#*.}
    read -r -e -p "Domain for the accounts host names (accounts., api. and profile. are prepended) [${DEFAULT_FXA_DOMAIN}]: " FXA_DOMAIN
    FXA_DOMAIN=${FXA_DOMAIN:-${DEFAULT_FXA_DOMAIN}}
    read -r -e -p "SMTP server for the confirmation emails: " FXA_SMTP_HOST
    read -r -e -p "SMTP port [587]: " FXA_SMTP_PORT
    FXA_SMTP_PORT=${FXA_SMTP_PORT:-587}
    read -r -e -p "SMTP user: " FXA_SMTP_USER
    case "${FXA_SMTP_USER}" in *"'"*|*\\) echo "ERROR: the SMTP user cannot contain a single quote nor end with a backslash, set FXA_SMTP_USER in .env by hand"; exit 1 ;; esac
    read -r -e -s -p "SMTP password: " FXA_SMTP_PASS
    echo ""
    # (written in single quotes, as typed: compose reads \' there as a quote, so not at the end either)
    case "${FXA_SMTP_PASS}" in
        *"'"*) echo "ERROR: the SMTP password cannot contain a single quote, set FXA_SMTP_PASS in .env by hand"; exit 1 ;;
        *\\) echo "ERROR: the SMTP password cannot end with a backslash, set FXA_SMTP_PASS in .env by hand"; exit 1 ;;
    esac
    DEFAULT_FXA_SMTP_SENDER="Mozilla accounts <no-reply@${FXA_DOMAIN}>"
    read -r -e -p "Sender of the emails [${DEFAULT_FXA_SMTP_SENDER}]: " FXA_SMTP_SENDER
    FXA_SMTP_SENDER=${FXA_SMTP_SENDER:-${DEFAULT_FXA_SMTP_SENDER}}
    [ "${FXA_SMTP_PORT}" = "465" ] && FXA_SMTP_SECURE=true || FXA_SMTP_SECURE=false
    read -r -e -p "Who can create an account? Emails and @domains, comma-separated (empty: anybody): " FXA_SIGNUP_ALLOWLIST
    FXA_SIGNUP_ALLOWLIST=$(printf '%s' "${FXA_SIGNUP_ALLOWLIST}" | tr -d ' ')
    case "${FXA_SIGNUP_ALLOWLIST}" in *[!A-Za-z0-9@._+,-]*) echo "ERROR: not a list of emails and domains: ${FXA_SIGNUP_ALLOWLIST}"; exit 1 ;; esac
    [ -n "${FXA_SIGNUP_ALLOWLIST}" ] && FXA_SIGNUPS=allowlist || FXA_SIGNUPS=open
    # asked last, so that scripted answers for the questions above still line up
    if [ "${ADMIN_UI}" = "yes" ]; then
        read -r -e -p "Sign in to the admin UI with these accounts? Admin emails, comma-separated (empty: password only): " ADMIN_ALLOWED_USERS
        ADMIN_ALLOWED_USERS=$(printf '%s' "${ADMIN_ALLOWED_USERS}" | tr -d ' ')
        case "${ADMIN_ALLOWED_USERS}" in *[!A-Za-z0-9@._+,-]*) echo "ERROR: not a list of emails and domains: ${ADMIN_ALLOWED_USERS}"; exit 1 ;; esac
        if [ -n "${ADMIN_ALLOWED_USERS}" ]; then
            DEFAULT_ADMIN_HOST=admin.${FXA_DOMAIN}
            read -r -e -p "Host name of the admin UI, where the accounts pages send you back [${DEFAULT_ADMIN_HOST}]: " ADMIN_HOST
            ADMIN_HOST=${ADMIN_HOST:-${DEFAULT_ADMIN_HOST}}
            case "${ADMIN_HOST}" in *[!A-Za-z0-9.:-]*|"") echo "ERROR: not a host name: ${ADMIN_HOST}"; exit 1 ;; esac
        fi
    fi
fi

# your own database server (docs/databases.md#your-own-server), asked last so that scripted answers for the
# questions above still line up
EXTERNAL_DB=no
EXTERNAL_FXA_DB=no
FXA_DB=mysql
read -r -e -p "Use an existing database server instead of starting one? See docs/databases.md#your-own-server (y/N): " EXTERNAL_DB
case "${EXTERNAL_DB}" in y|Y|yes) EXTERNAL_DB=yes ;; *) EXTERNAL_DB=no ;; esac
if [ "${EXTERNAL_DB}" = "yes" ]; then
    read -r -e -p "Database server host, as the containers reach it: " DB_HOST
    valid_host "${DB_HOST}"
    [ "${DATABASE_BACKEND}" = "postgres" ] && DEFAULT_DB_PORT=5432 || DEFAULT_DB_PORT=3306
    read -r -e -p "Database server port [${DEFAULT_DB_PORT}]: " DB_PORT
    DB_PORT=${DB_PORT:-${DEFAULT_DB_PORT}}
    valid_port "${DB_PORT}"
    if [ "${DATABASE_BACKEND}" = "postgres" ]; then
        read -r -e -p "Database [syncserver]: " SYNC_POSTGRES_NAME
        SYNC_POSTGRES_NAME=${SYNC_POSTGRES_NAME:-syncserver}
        read -r -e -p "Database user [syncserver]: " SYNC_POSTGRES_USER
        SYNC_POSTGRES_USER=${SYNC_POSTGRES_USER:-syncserver}
        valid_name "${SYNC_POSTGRES_NAME}"; valid_user "${SYNC_POSTGRES_USER}"
    else
        read -r -e -p "Tokenserver database [tokenserver]: " SYNC_TOKENSERVER_DB_NAME
        SYNC_TOKENSERVER_DB_NAME=${SYNC_TOKENSERVER_DB_NAME:-tokenserver}
        read -r -e -p "Tokenserver database user [tokenserver]: " SYNC_TOKENSERVER_DB_USER
        SYNC_TOKENSERVER_DB_USER=${SYNC_TOKENSERVER_DB_USER:-tokenserver}
        read -r -e -p "Storage database [syncstorage]: " SYNC_STORAGE_DB_NAME
        SYNC_STORAGE_DB_NAME=${SYNC_STORAGE_DB_NAME:-syncstorage}
        read -r -e -p "Storage database user [syncstorage]: " SYNC_STORAGE_DB_USER
        SYNC_STORAGE_DB_USER=${SYNC_STORAGE_DB_USER:-syncstorage}
        valid_name "${SYNC_TOKENSERVER_DB_NAME}"; valid_name "${SYNC_STORAGE_DB_NAME}"
        valid_user "${SYNC_TOKENSERVER_DB_USER}"; valid_user "${SYNC_STORAGE_DB_USER}"
        [ "${SYNC_TOKENSERVER_DB_NAME}" != "${SYNC_STORAGE_DB_NAME}" ] || { echo "ERROR: the tokenserver and the storage need two databases"; exit 1; }
    fi
fi
if [ "${SELF_HOST_FXA}" = "yes" ]; then
    read -r -e -p "Use an existing MySQL 8.4/9 or MariaDB 11.4+ server for the accounts$([ "${EXTERNAL_DB}" = "yes" ] && echo " too")? See docs/databases.md#your-own-server (y/N): " EXTERNAL_FXA_DB
    case "${EXTERNAL_FXA_DB}" in y|Y|yes) EXTERNAL_FXA_DB=yes ;; *) EXTERNAL_FXA_DB=no ;; esac
    if [ "${EXTERNAL_FXA_DB}" = "yes" ]; then
        read -r -e -p "Accounts database server host${DB_HOST:+ [${DB_HOST}]}: " FXA_MYSQL_HOST
        FXA_MYSQL_HOST=${FXA_MYSQL_HOST:-${DB_HOST:-}}
        valid_host "${FXA_MYSQL_HOST}"
        read -r -e -p "Accounts database server port [3306]: " FXA_MYSQL_PORT
        FXA_MYSQL_PORT=${FXA_MYSQL_PORT:-3306}
        valid_port "${FXA_MYSQL_PORT}"
        read -r -e -p "Accounts database user [fxa]: " FXA_MYSQL_USER
        FXA_MYSQL_USER=${FXA_MYSQL_USER:-fxa}
        read -r -e -p "User installing the sign-up policy [ffs_policy]: " FXA_MYSQL_POLICY_USER
        FXA_MYSQL_POLICY_USER=${FXA_MYSQL_POLICY_USER:-ffs_policy}
        valid_user "${FXA_MYSQL_USER}"; valid_user "${FXA_MYSQL_POLICY_USER}"
    fi
    # MySQL by default, whatever Sync uses: it is what Mozilla supports and runs
    if [ "${EXTERNAL_FXA_DB}" = "yes" ]; then
        read -r -e -p "Is that server MySQL or MariaDB? (mysql/mariadb) [mysql]: " FXA_DB
    else
        read -r -e -p "Accounts database: mysql (MySQL lts, what Mozilla runs) or mariadb (MariaDB lts, see docs/accounts.md#mysql-or-mariadb) [mysql]: " FXA_DB
    fi
    case "${FXA_DB}" in
        ""|mysql|MySQL) FXA_DB=mysql ;;
        mariadb|MariaDB) FXA_DB=mariadb ;;
        *) echo "ERROR: mysql or mariadb, not '${FXA_DB}'"; exit 1 ;;
    esac
fi

# the most accounts of the self-hosted accounts, asked last so that scripted answers for
# the questions above still line up; with the admin UI it manages them (initial:)
FXA_MAX_ACCOUNTS=initial:unlimited
if [ "${SELF_HOST_FXA}" = "yes" ]; then
    read -r -e -p "Max accounts that can be created on the accounts service, a number or unlimited [unlimited]: " FXA_MAX_ACCOUNTS
    FXA_MAX_ACCOUNTS=${FXA_MAX_ACCOUNTS:-unlimited}
    valid_limit "max accounts" "${FXA_MAX_ACCOUNTS}"
    [ "${ADMIN_UI}" = "yes" ] && FXA_MAX_ACCOUNTS=initial:${FXA_MAX_ACCOUNTS}
fi

# the security history of the accounts (docs/accounts.md#security-history), asked last for the same reason
FXA_ACCOUNT_EVENTS=false
if [ "${SELF_HOST_FXA}" = "yes" ]; then
    echo "Security history: every sign-in, password and 2-step change is kept with its IP address, for the owner and the admin UI to see (docs/accounts.md#security-history)."
    read -r -e -p "Record the security history of the accounts? (y/N): " FXA_ACCOUNT_EVENTS
    case "${FXA_ACCOUNT_EVENTS}" in y|Y|yes) FXA_ACCOUNT_EVENTS=true ;; *) FXA_ACCOUNT_EVENTS=false ;; esac
fi

# the alerts of the admin UI to other destinations than email (docs/admin/alerts.md#destinations), asked last
# for the same reason. Not shown as typed: the URLs hold tokens
ADMIN_NOTIFY=""
if [ "${ADMIN_UI}" = "yes" ]; then
    echo "Alerts of the admin UI: by email (ADMIN_ALERT_EMAIL in .env, with an SMTP server), and/or to Slack, Discord, Teams, ntfy, Gotify, Telegram, Matrix or a webhook (docs/admin/alerts.md#destinations)."
    read -r -s -p "Also send alerts to Slack, Discord, ntfy...? Paste a destination URL (e.g. ntfy://ntfy.sh/<topic>, slack://hooks.slack.com/services/...) or leave empty: " ADMIN_NOTIFY
    echo ""
    # scheme://host of a destination, … for what cannot be named safely (an @ after the
    # host is the end of a user or password with / ? # in it, not the host)
    notify_name() {
        local scheme rest host tail
        scheme=$(printf '%s' "${1%%://*}" | tr '[:upper:]' '[:lower:]'); rest=${1#*://}
        [[ "${scheme}" =~ ^[a-z][a-z0-9+]*$ ]] || { printf '…'; return; }
        case "${scheme}" in telegram*) printf '%s://api.telegram.org' "${scheme}"; return ;; esac
        host=${rest%%[/?#]*}; tail=${rest#"${host}"}
        tail=${tail//\?@/}; tail=${tail//&@/}
        case "${tail}" in *@*) printf '%s://…' "${scheme}"; return ;; esac
        host=${host##*@}
        [[ "${host}" =~ ^[A-Za-z0-9.:-]+$ ]] || { printf '%s://…' "${scheme}"; return; }
        printf '%s://%s' "${scheme}" "${host}"
    }
    notify_in=${ADMIN_NOTIFY}; ADMIN_NOTIFY=""; notify_names=""
    # separated by commas or spaces
    IFS=$', \t\r' read -r -a notify_entries <<< "${notify_in}"
    for notify_entry in "${notify_entries[@]}"; do
        [ -n "${notify_entry}" ] || continue
        case "${notify_entry}" in *"'"*|*\\) echo "ERROR: a destination URL cannot contain a single quote nor end with a backslash, set ADMIN_NOTIFY in .env by hand"; exit 1 ;; esac
        # the webhook URL of Slack or Discord as they give it: their scheme instead of https://
        notify_kind=""
        case "${notify_entry}" in
            https://hooks.slack.com/*) notify_kind=slack ;;
            https://discord.com/api/webhooks/*|https://discordapp.com/api/webhooks/*) notify_kind=discord ;;
        esac
        if [ -n "${notify_kind}" ]; then
            read -r -e -p "That is a ${notify_kind} webhook URL: use it as ${notify_kind}://... (Y/n): " notify_convert
            case "${notify_convert}" in n|N|no) echo "ERROR: https:// is no destination of ADMIN_NOTIFY, see docs/admin/alerts.md#destinations"; exit 1 ;; esac
            notify_entry="${notify_kind}://${notify_entry#https://}"
        fi
        notify_base="" notify_shown="…"
        if [[ "${notify_entry}" == *://* ]]; then
            notify_base=$(printf '%s' "${notify_entry%%://*}" | tr '[:upper:]' '[:lower:]'); notify_base=${notify_base%+http}; notify_base=${notify_base%+https}
            notify_shown=$(notify_name "${notify_entry}")
        fi
        if ! [[ "${notify_base}" =~ ^(slack|discord|teams|ntfy|gotify|telegram|matrix|webhook)$ ]]; then
            echo "ERROR: ${notify_shown} is no destination of ADMIN_NOTIFY: slack://, discord://, teams://, ntfy://, gotify://, telegram://, matrix:// or webhook://, see docs/admin/alerts.md#destinations"
            exit 1
        fi
        if [ "${notify_base}" != telegram ] && [ "${notify_shown}" = "${notify_shown%://…}://…" ]; then
            echo "ERROR: ${notify_shown}: an @ after the host, percent-encode / ? # in the user or password (%2F %3F %23)"
            exit 1
        fi
        ADMIN_NOTIFY="${ADMIN_NOTIFY:+${ADMIN_NOTIFY},}${notify_entry}"
        notify_names="${notify_names:+${notify_names}, }$(notify_name "${notify_entry}")"
    done
    [ -z "${ADMIN_NOTIFY}" ] || echo "Alerts also to ${notify_names} (ADMIN_NOTIFY in .env; more destinations there, separated by commas)"
fi

# the optional services, asked last for the same reason. Run again on an install: what it
# has is the default (COMPOSE_PROFILES of its .env; with Quadlets also the backup timer on)
previous_profile() { [ -f "${SCRIPT_DIR}/.env" ] && case ",$(env_plain COMPOSE_PROFILES)," in *",${1},"*) return 0 ;; esac; return 1; }
# the nightly backups (docs/backups.md#the-backup-service): compose's backup profile, the
# Quadlets' backup timer
BACKUPS=no
previous_profile backup && BACKUPS=yes
[ "${DEPLOY_METHOD:-}" = quadlets ] && systemctl --user is-enabled -q firefox-sync-backup.timer 2> /dev/null && BACKUPS=yes
if [ "${BACKUPS}" = yes ]; then
    read -r -e -p "Enable nightly backups? See docs/backups.md#the-backup-service (Y/n): " BACKUPS
    case "${BACKUPS}" in n|N|no) BACKUPS=no ;; *) BACKUPS=yes ;; esac
else
    read -r -e -p "Enable nightly backups? See docs/backups.md#the-backup-service (y/N): " BACKUPS
    case "${BACKUPS}" in y|Y|yes) BACKUPS=yes ;; *) BACKUPS=no ;; esac
fi
# your own pairing server for the QR code (docs/reverse-proxy.md#pairing), with the accounts:
# compose's pairing profile (the Quadlets have none: not asked)
PAIRING=no
if [ "${SELF_HOST_FXA}" = "yes" ] && [ "${DEPLOY_METHOD:-}" != quadlets ]; then
    if previous_profile pairing; then
        read -r -e -p "Run your own pairing server, at pairing.${FXA_DOMAIN}? See docs/reverse-proxy.md#pairing (Y/n): " PAIRING
        case "${PAIRING}" in n|N|no) PAIRING=no ;; *) PAIRING=yes ;; esac
    else
        read -r -e -p "Run your own pairing server, at pairing.${FXA_DOMAIN}? See docs/reverse-proxy.md#pairing (y/N): " PAIRING
        case "${PAIRING}" in y|Y|yes) PAIRING=yes ;; *) PAIRING=no ;; esac
    fi
fi
# your own database server: the stack applies database-setup.sql (database-setup-fxa.sql) itself at
# every start, as an account that can create users (docs/databases.md#let-the-stack-apply-them);
# default no: it then only checks that they are there. Asked last, so that scripted answers for
# the questions above still line up
SYNC_DB_BOOTSTRAP_USER="" SYNC_DB_BOOTSTRAP_PASSWORD="" FXA_DB_BOOTSTRAP_USER="" FXA_DB_BOOTSTRAP_PASSWORD=""
ask_bootstrap() { # <prefix: SYNC or FXA> <what>
    local answer user password
    read -r -e -p "Let the stack apply database changes itself at start${2} (needs a database account that can create users, see docs/databases.md#let-the-stack-apply-them)? (y/N): " answer
    case "${answer}" in y|Y|yes) ;; *) return 0 ;; esac
    read -r -e -p "That account, which you have or database-bootstrap$([ "${1}" = FXA ] && echo -fxa).sql creates [ffs_bootstrap]: " user
    user=${user:-ffs_bootstrap}
    [[ "${user}" =~ ^[A-Za-z0-9_]{1,32}$ ]] || { echo "ERROR: not a valid user name (A-Z, a-z, 0-9, _): '${user}'"; exit 1; }
    # an account of its own, not one of the stack's users nor the server's administrator
    case " root postgres ${SYNC_TOKENSERVER_DB_USER:-} ${SYNC_STORAGE_DB_USER:-} ${SYNC_POSTGRES_USER:-} ${FXA_MYSQL_USER:-} ${FXA_MYSQL_POLICY_USER:-} ffs_admin ffs_admin_ui ffs_admin_sync " in
        *" ${user} "*) echo "ERROR: '${user}' is the server's administrator or one of the stack's users: the bootstrap needs an account of its own (docs/databases.md#the-bootstrap-account)"; exit 1 ;;
    esac
    read -r -e -s -p "Its password (empty: a new one): " password
    echo ""
    [ -n "${password}" ] || password=$(generate_random_string 32)
    # (in database-bootstrap.sql, and in the database URLs' rules)
    [[ "${password}" =~ ^[A-Za-z0-9._~-]+$ ]] || { echo "ERROR: the password: only A-Z a-z 0-9 . _ ~ -"; exit 1; }
    printf -v "${1}_DB_BOOTSTRAP_USER" '%s' "${user}"
    printf -v "${1}_DB_BOOTSTRAP_PASSWORD" '%s' "${password}"
}
[ "${EXTERNAL_DB}" = "yes" ] && ask_bootstrap SYNC "$([ "${EXTERNAL_FXA_DB}" = "yes" ] && echo " for Sync")"
[ "${EXTERNAL_FXA_DB}" = "yes" ] && ask_bootstrap FXA " for the accounts"

# COMPOSE_PROFILES: the whole list of what was chosen (the Quadlets read admin there too)
COMPOSE_PROFILES_CHOSEN=""
for profile in admin:${ADMIN_UI} backup:${BACKUPS} pairing:${PAIRING}; do
    [ "${profile#*:}" = yes ] && COMPOSE_PROFILES_CHOSEN="${COMPOSE_PROFILES_CHOSEN:+${COMPOSE_PROFILES_CHOSEN},}${profile%%:*}"
done

# SYNC_DB=mysql: the Sync databases in MySQL containers; with your own server there are none,
# SYNC_DB then only says what it is
[ "${SYNC_DB}" = "mysql" ] && [ "${EXTERNAL_DB}" != "yes" ] && SYNC_COMPOSE_MYSQL=yes || SYNC_COMPOSE_MYSQL=no

# random passwords
SYNC_TOKENSERVER_DB_PASSWORD=$(generate_random_string 24)
SYNC_STORAGE_DB_PASSWORD=$(generate_random_string 24)
SYNC_POSTGRES_PASSWORD=$(generate_random_string 24)
SYNC_MASTER_SECRET=$(generate_random_string 24)
SYNC_METRICS_HASH_SECRET=$(generate_random_string 24)
ADMIN_PASSWORD=$(generate_random_string 24)
ADMIN_DB_PASSWORD=$(generate_random_string 32)

# run again on an install: its databases stay on the PostgreSQL, MariaDB or MySQL versions they run
PREVIOUS_SYNCSTORAGE_IMAGE="" PREVIOUS_POSTGRES_IMAGE=""
PREVIOUS_FXA_DB="" PREVIOUS_FXA_MARIADB_IMAGE=""
PREVIOUS_FXA_MYSQL=no PREVIOUS_FXA_MYSQL_IMAGE="" PREVIOUS_FXA_MYSQL_ARGS=""
PREVIOUS_SYNC_MYSQL=no PREVIOUS_SYNC_MYSQL_IMAGE=""
if [ -f "${SCRIPT_DIR}/.env" ]; then
    PREVIOUS_SYNCSTORAGE_IMAGE=$(env_value SYNC_IMAGE)
    PREVIOUS_POSTGRES_IMAGE=$(env_value SYNC_POSTGRES_IMAGE)
    PREVIOUS_FXA_DB=$(env_value FXA_DB)
    PREVIOUS_FXA_MARIADB_IMAGE=$(env_value FXA_MARIADB_IMAGE)
    # the accounts on MySQL (FXA_DB=mysql is also in .env-example: with their passwords)
    if [ "${PREVIOUS_FXA_DB}" != mariadb ] && fxa_installed; then
        PREVIOUS_FXA_MYSQL=yes
        PREVIOUS_FXA_MYSQL_IMAGE=$(env_plain FXA_MYSQL_IMAGE)
        PREVIOUS_FXA_MYSQL_ARGS=$(env_plain FXA_MYSQL_ARGS)
    fi
    if [ "$(env_value SYNC_DB)" = mysql ] && [ "$(env_value SYNC_DB_CONTAINERS)" != 0 ]; then
        PREVIOUS_SYNC_MYSQL=yes
        PREVIOUS_SYNC_MYSQL_IMAGE=$(env_plain SYNC_MYSQL_IMAGE)
    fi
fi

# PostgreSQL has no lts (every major is supported for 5 years) and no major opens another's
# data: the major of the install, decided before .env is written. One that ran PostgreSQL
# before keeps its SYNC_POSTGRES_IMAGE (without one: the major of its volume's data, else 18,
# which every release before it used, git log --follow -- compose/sync-postgres.yml); a new setup over the PostgreSQL volume of an
# earlier install the major of its data; a new install the major postgres:latest is at now, read
# from the image itself. Unset it would be postgres:latest, which a new major leaves unable to
# start: not knowing the major is an error
SYNC_POSTGRES_PIN="" SYNC_POSTGRES_MAJOR="" SYNC_POSTGRES_VOLUME=""
if [ "${DATABASE_BACKEND}" = postgres ]; then
    if [ "${PREVIOUS_SYNCSTORAGE_IMAGE}" = "syncstorage-rs-postgres" ]; then
        SYNC_POSTGRES_PIN=${PREVIOUS_POSTGRES_IMAGE}
        # from before SYNC_POSTGRES_IMAGE: the major of its data, else 18 (every release before it)
        if [ -z "${SYNC_POSTGRES_PIN}" ]; then
            SYNC_POSTGRES_PIN=postgres:18
            [ "${EXTERNAL_DB}" != "yes" ] && SYNC_POSTGRES_VOLUME=$(db_volume postgres-db) \
                && SYNC_POSTGRES_VOLUME_MAJOR=$(postgres_volume_major "${SYNC_POSTGRES_VOLUME}") \
                && SYNC_POSTGRES_PIN=postgres:${SYNC_POSTGRES_VOLUME_MAJOR}
        fi
    elif [ "${EXTERNAL_DB}" != "yes" ] && SYNC_POSTGRES_VOLUME=$(db_volume postgres-db) \
        && SYNC_POSTGRES_VOLUME_MAJOR=$(postgres_volume_major "${SYNC_POSTGRES_VOLUME}"); then
        SYNC_POSTGRES_PIN=postgres:${SYNC_POSTGRES_VOLUME_MAJOR}
    elif SYNC_POSTGRES_MAJOR=$(postgres_latest_major); then
        SYNC_POSTGRES_PIN=postgres:${SYNC_POSTGRES_MAJOR}
        SYNC_POSTGRES_VOLUME=""
    else
        echo "ERROR: could not read the major of postgres:latest, which this install is pinned to (SYNC_POSTGRES_IMAGE):"
        echo "  docker (or podman) run --rm --pull=always --entrypoint postgres postgres:latest --version failed."
        echo "  Check the container runtime and the access to Docker Hub, and run this again; nothing was written."
        exit 1
    fi
fi

# Sync on the MariaDB containers: lts for new installs; one that ran them before keeps its
# SYNC_MARIADB_IMAGE, or without one the major its data holds (its volume, else its running
# server), as a new setup over the MariaDB volumes of an earlier install
SYNC_MARIADB_PIN=mariadb:lts SYNC_MARIADB_FOUND=""
if [ "${DATABASE_BACKEND}" = mariadb ] && [ "${EXTERNAL_DB}" != "yes" ]; then
    if [ -f "${SCRIPT_DIR}/.env" ] && [ "$(env_value SYNC_DB)" != mysql ] && [ "${PREVIOUS_SYNCSTORAGE_IMAGE}" != "syncstorage-rs-postgres" ] \
        && [ "$(env_value SYNC_DB_CONTAINERS)" != 0 ] && [ -n "$(env_plain SYNC_MARIADB_IMAGE)" ]; then
        SYNC_MARIADB_PIN=$(env_plain SYNC_MARIADB_IMAGE)
    elif major=$(sync_mariadb_major); then
        SYNC_MARIADB_PIN=mariadb:${major} SYNC_MARIADB_FOUND=${major}
    fi
fi

# prepare .env file: new passwords and secrets, written into a copy (this user only) that
# replaces .env at the end. Run again on an install, its .env of before is kept as
# .env.before-setup-<UTC time> (the passwords its databases have); ./prepare_environment.sh
# --upgrade keeps them instead
private_temp "${SCRIPT_DIR}/.env.setup" NEW_ENV && cat "${SCRIPT_DIR}/.env-example" > "${NEW_ENV}" || exit 1
# shellcheck disable=SC2034 # (read by env_file_read, setup/env.sh)
ENV_READ=${NEW_ENV}
apply_sed "${NEW_ENV}" "s|^SYNC_TOKENSERVER_DB_PASSWORD=.*|SYNC_TOKENSERVER_DB_PASSWORD=${SYNC_TOKENSERVER_DB_PASSWORD}|"
apply_sed "${NEW_ENV}" "s|^SYNC_STORAGE_DB_PASSWORD=.*|SYNC_STORAGE_DB_PASSWORD=${SYNC_STORAGE_DB_PASSWORD}|"
apply_sed "${NEW_ENV}" "s|^SYNC_POSTGRES_PASSWORD=.*|SYNC_POSTGRES_PASSWORD=${SYNC_POSTGRES_PASSWORD}|"
apply_sed "${NEW_ENV}" "s|SYNC_MASTER_SECRET=.*|SYNC_MASTER_SECRET=${SYNC_MASTER_SECRET}|"
apply_sed "${NEW_ENV}" "s|^SYNC_METRICS_HASH_SECRET=.*|SYNC_METRICS_HASH_SECRET=${SYNC_METRICS_HASH_SECRET}|"
apply_sed "${NEW_ENV}" "s|^SYNC_PUBLIC_URL=.*|SYNC_PUBLIC_URL=https://${SYNC_FQDN}|"
apply_sed "${NEW_ENV}" "s|^SYNC_EXPORT_PORT=.*|SYNC_EXPORT_PORT=${SYNC_EXPORT_PORT}|"
apply_sed "${NEW_ENV}" "s|^SYNC_MAX_USERS=.*|SYNC_MAX_USERS=${SYNC_MAX_USERS}|"
apply_sed "${NEW_ENV}" "s|^SYNC_IMAGE_TAG=.*|SYNC_IMAGE_TAG=${SYNC_IMAGE_TAG}|"
apply_sed "${NEW_ENV}" "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=${ADMIN_PASSWORD}|"
# the admin UI's database user, also for the backups: with or without the admin UI
apply_sed "${NEW_ENV}" "s|^ADMIN_DB_PASSWORD=.*|ADMIN_DB_PASSWORD=${ADMIN_DB_PASSWORD}|"
# the optional services chosen, the whole list (none: the line stays commented out)
[ -n "${COMPOSE_PROFILES_CHOSEN}" ] && apply_sed "${NEW_ENV}" "s|^# COMPOSE_PROFILES=.*|COMPOSE_PROFILES=${COMPOSE_PROFILES_CHOSEN}|"
[ -n "${ADMIN_NOTIFY}" ] && apply_sed "${NEW_ENV}" "s|^ADMIN_NOTIFY=.*|ADMIN_NOTIFY='$(sed_escape "${ADMIN_NOTIFY}")'|"
apply_sed "${NEW_ENV}" "s|^SYNC_DB=.*|SYNC_DB=${SYNC_DB}|"
[ "${DATABASE_BACKEND}" = mariadb ] && [ "${EXTERNAL_DB}" != "yes" ] && \
    apply_sed "${NEW_ENV}" "s|^# SYNC_MARIADB_IMAGE=.*|SYNC_MARIADB_IMAGE=$(sed_escape "${SYNC_MARIADB_PIN}")|"
if [ "${SYNC_COMPOSE_MYSQL}" = "yes" ]; then
    # MySQL's certificate is self-signed: the init container's client does not check it
    # (compose/sync-mysql.yml does the same, this is for the Quadlets)
    apply_sed "${NEW_ENV}" "s|^SYNC_DB_TLS_VERIFY=.*|SYNC_DB_TLS_VERIFY=false|"
    # MySQL lts for new installs (9 today), written out (also the default when unset). One that
    # ran MySQL before SYNC_MYSQL_IMAGE, or whose MySQL volumes are still there, runs 8: pinned,
    # so that its data does not move to 9 by itself
    SYNC_MYSQL_IMAGE=mysql:lts
    if [ "${PREVIOUS_SYNC_MYSQL}" = yes ]; then
        SYNC_MYSQL_IMAGE=${PREVIOUS_SYNC_MYSQL_IMAGE:-mysql:8}
        [ -n "${PREVIOUS_SYNC_MYSQL_IMAGE}" ] || PINNED_SYNC_MYSQL=yes
    elif SYNC_MYSQL_VOLUME=$(db_volume syncstorage-db-mysql tokenserver-db-mysql); then
        # (already on 9 or later: lts, MySQL cannot go back to 8)
        SYNC_MYSQL_VOLUME_MAJOR=$(mysql_volume_major "${SYNC_MYSQL_VOLUME}") || SYNC_MYSQL_VOLUME_MAJOR=8
        [ "${SYNC_MYSQL_VOLUME_MAJOR}" -ge 9 ] || SYNC_MYSQL_IMAGE=mysql:8
    fi
    apply_sed "${NEW_ENV}" "s|^# SYNC_MYSQL_IMAGE=.*|SYNC_MYSQL_IMAGE=$(sed_escape "${SYNC_MYSQL_IMAGE}")|"
fi
if [ "${EXTERNAL_DB}" = "yes" ]; then
    apply_sed "${NEW_ENV}" "s|^SYNC_DB_CONTAINERS=.*|SYNC_DB_CONTAINERS=0|"
    # the account that applies database-setup.sql at every start, when asked for
    if [ -n "${SYNC_DB_BOOTSTRAP_USER}" ]; then
        apply_sed "${NEW_ENV}" "s|^SYNC_DB_BOOTSTRAP_USER=.*|SYNC_DB_BOOTSTRAP_USER=${SYNC_DB_BOOTSTRAP_USER}|"
        apply_sed "${NEW_ENV}" "s|^SYNC_DB_BOOTSTRAP_PASSWORD=.*|SYNC_DB_BOOTSTRAP_PASSWORD=${SYNC_DB_BOOTSTRAP_PASSWORD}|"
    fi
    if [ "${DATABASE_BACKEND}" = "postgres" ]; then
        for name in SYNC_POSTGRES_NAME SYNC_POSTGRES_USER; do
            apply_sed "${NEW_ENV}" "s|^${name}=.*|${name}=${!name}|"
        done
        apply_sed "${NEW_ENV}" "s|^SYNC_POSTGRES_HOST=.*|SYNC_POSTGRES_HOST=${DB_HOST}|"
        apply_sed "${NEW_ENV}" "s|^SYNC_POSTGRES_PORT=.*|SYNC_POSTGRES_PORT=${DB_PORT}|"
    else
        # the init container's client checks the certificate by default, MySQL's is self-signed
        apply_sed "${NEW_ENV}" "s|^SYNC_DB_TLS_VERIFY=.*|SYNC_DB_TLS_VERIFY=false|"
        for name in SYNC_TOKENSERVER_DB_NAME SYNC_TOKENSERVER_DB_USER SYNC_STORAGE_DB_NAME SYNC_STORAGE_DB_USER; do
            apply_sed "${NEW_ENV}" "s|^${name}=.*|${name}=${!name}|"
        done
        for part in TOKENSERVER STORAGE; do
            apply_sed "${NEW_ENV}" "s|^SYNC_${part}_DB_HOST=.*|SYNC_${part}_DB_HOST=${DB_HOST}|"
            apply_sed "${NEW_ENV}" "s|^SYNC_${part}_DB_PORT=.*|SYNC_${part}_DB_PORT=${DB_PORT}|"
        done
    fi
fi
if [ "${SELF_HOST_FXA}" = "yes" ]; then
    for name in FXA_MYSQL_PASSWORD FXA_ADMIN_DB_PASSWORD FXA_AUTH_SECRET FXA_OAUTH_SECRET FXA_PROFILE_SECRET FXA_FLOW_ID_KEY FXA_SESSION_TOKEN_HANDLE_KEY FXA_CONTENT_SESSION_SECRET; do
        apply_sed "${NEW_ENV}" "s|^${name}=.*|${name}=$(generate_random_string 32)|"
    done
    # the accounts images come from the same registry as the sync images, for this host's architecture
    FXA_REGISTRY=$(grep '^IMAGE_REPOSITORY=' "${NEW_ENV}" | cut -d= -f2)
    FXA_ARCH=$(host_arch)
    apply_sed "${NEW_ENV}" "s|^FXA_IMAGE=.*|FXA_IMAGE=${FXA_REGISTRY}|"
    apply_sed "${NEW_ENV}" "s|^FXA_PAIRING_IMAGE=.*|FXA_PAIRING_IMAGE=${FXA_REGISTRY}:fxa-channelserver-latest|"
    apply_sed "${NEW_ENV}" "s|^FXA_ARCH=.*|FXA_ARCH=${FXA_ARCH}|"
    apply_sed "${NEW_ENV}" "s|^FXA_CONTENT_URL=.*|FXA_CONTENT_URL=https://accounts.${FXA_DOMAIN}|"
    apply_sed "${NEW_ENV}" "s|^FXA_AUTH_URL=.*|FXA_AUTH_URL=https://api.${FXA_DOMAIN}|"
    apply_sed "${NEW_ENV}" "s|^FXA_PROFILE_URL=.*|FXA_PROFILE_URL=https://profile.${FXA_DOMAIN}|"
    apply_sed "${NEW_ENV}" "s|^FXA_OAUTH_SERVER_URL=.*|FXA_OAUTH_SERVER_URL=http://fxa-auth:9000/v1|"
    apply_sed "${NEW_ENV}" "s|^FXA_EMAIL_DOMAIN=.*|FXA_EMAIL_DOMAIN=api.${FXA_DOMAIN}|"
    apply_sed "${NEW_ENV}" "s|^FXA_SMTP_HOST=.*|FXA_SMTP_HOST=${FXA_SMTP_HOST}|"
    apply_sed "${NEW_ENV}" "s|^FXA_SMTP_PORT=.*|FXA_SMTP_PORT=${FXA_SMTP_PORT}|"
    apply_sed "${NEW_ENV}" "s|^FXA_SMTP_USER=.*|FXA_SMTP_USER='$(sed_escape "${FXA_SMTP_USER}")'|"
    apply_sed "${NEW_ENV}" "s|^FXA_SMTP_PASS=.*|FXA_SMTP_PASS='$(sed_escape "${FXA_SMTP_PASS}")'|"
    apply_sed "${NEW_ENV}" "s|^FXA_SMTP_SECURE=.*|FXA_SMTP_SECURE=${FXA_SMTP_SECURE}|"
    apply_sed "${NEW_ENV}" "s|^FXA_SMTP_SENDER=.*|FXA_SMTP_SENDER=\"$(sed_escape "$(env_dq "${FXA_SMTP_SENDER}")")\"|"
    apply_sed "${NEW_ENV}" "s|^FXA_SIGNUPS=.*|FXA_SIGNUPS=${FXA_SIGNUPS}|"
    apply_sed "${NEW_ENV}" "s|^FXA_SIGNUP_ALLOWLIST=.*|FXA_SIGNUP_ALLOWLIST=${FXA_SIGNUP_ALLOWLIST}|"
    apply_sed "${NEW_ENV}" "s|^FXA_MAX_ACCOUNTS=.*|FXA_MAX_ACCOUNTS=${FXA_MAX_ACCOUNTS}|"
    apply_sed "${NEW_ENV}" "s|^FXA_ACCOUNT_EVENTS=.*|FXA_ACCOUNT_EVENTS=${FXA_ACCOUNT_EVENTS}|"
    # your own pairing server: Firefox's QR code points to it
    [ "${PAIRING}" = yes ] && apply_sed "${NEW_ENV}" "s|^# FXA_PAIRING_URL=.*|FXA_PAIRING_URL=wss://pairing.${FXA_DOMAIN}|"
    if [ "${EXTERNAL_FXA_DB}" = "yes" ]; then
        apply_sed "${NEW_ENV}" "s|^FXA_DB_CONTAINERS=.*|FXA_DB_CONTAINERS=0|"
        for name in FXA_MYSQL_HOST FXA_MYSQL_PORT FXA_MYSQL_USER FXA_MYSQL_POLICY_USER; do
            apply_sed "${NEW_ENV}" "s|^${name}=.*|${name}=${!name}|"
        done
        apply_sed "${NEW_ENV}" "s|^FXA_MYSQL_POLICY_PASSWORD=.*|FXA_MYSQL_POLICY_PASSWORD=$(generate_random_string 32)|"
        if [ -n "${FXA_DB_BOOTSTRAP_USER}" ]; then
            apply_sed "${NEW_ENV}" "s|^FXA_DB_BOOTSTRAP_USER=.*|FXA_DB_BOOTSTRAP_USER=${FXA_DB_BOOTSTRAP_USER}|"
            apply_sed "${NEW_ENV}" "s|^FXA_DB_BOOTSTRAP_PASSWORD=.*|FXA_DB_BOOTSTRAP_PASSWORD=${FXA_DB_BOOTSTRAP_PASSWORD}|"
        fi
    fi
    apply_sed "${NEW_ENV}" "s|^FXA_DB=.*|FXA_DB=${FXA_DB}|"
    # MariaDB lts for new installs (12 today, with the patched migrations), written out (also
    # the default when unset). One that ran MariaDB before FXA_MARIADB_IMAGE, or whose MariaDB
    # volume is still there, runs 11: pinned, so that its data does not move to 12 by itself
    if [ "${FXA_DB}" = "mariadb" ]; then
        FXA_MARIADB_IMAGE=mariadb:lts
        if [ "${PREVIOUS_FXA_DB}" = "mariadb" ]; then
            FXA_MARIADB_IMAGE=${PREVIOUS_FXA_MARIADB_IMAGE:-mariadb:11}
            [ -n "${PREVIOUS_FXA_MARIADB_IMAGE}" ] || PINNED_FXA_MARIADB=yes
        elif [ "${EXTERNAL_FXA_DB}" != "yes" ] && FXA_MARIADB_VOLUME=$(db_volume fxa-db-mariadb); then
            FXA_MARIADB_IMAGE=mariadb:11
        fi
        apply_sed "${NEW_ENV}" "s|^# FXA_MARIADB_IMAGE=.*|FXA_MARIADB_IMAGE=$(sed_escape "${FXA_MARIADB_IMAGE}")|"
    fi
    # MySQL lts for new installs (9 today), written out (also the default when unset), when the
    # accounts image has mozilla/fxa#21554; else MySQL 8 with mysql_native_password, the only
    # authentication of the images without it (Mozilla's, ours from before). One that ran MySQL
    # before FXA_MYSQL_IMAGE, or whose fxa-db volume is still there, runs 8 like that: pinned,
    # its users are on mysql_native_password (docs/upgrading.md#mysql-8-to-9). Your own server: the
    # image is the backups' client, and without the patch the accounts' user is created with
    # mysql_native_password in database-setup-fxa.sql
    if [ "${FXA_DB}" = "mysql" ]; then
        fxa_image_has mozilla/fxa#21554; FXA_MYSQL2=$?
        # the local copy without it (the registry's has it): it is what would start, so MySQL 8
        # with mysql_native_password, which works with both; 3: said below
        [ "${FXA_MYSQL2}" = 0 ] && [ -n "${FXA_IMAGE_PULL}" ] && FXA_MYSQL2=3
        FXA_MYSQL_IMAGE=mysql:lts FXA_MYSQL_ARGS=""
        if [ "${PREVIOUS_FXA_MYSQL}" = yes ]; then
            if [ -n "${PREVIOUS_FXA_MYSQL_IMAGE}" ]; then
                FXA_MYSQL_IMAGE=${PREVIOUS_FXA_MYSQL_IMAGE} FXA_MYSQL_ARGS=${PREVIOUS_FXA_MYSQL_ARGS}
            else
                FXA_MYSQL_IMAGE=mysql:8 FXA_MYSQL_ARGS=${FXA_MYSQL_NATIVE_ARGS} PINNED_FXA_MYSQL=yes
            fi
        elif [ "${EXTERNAL_FXA_DB}" != "yes" ] && FXA_MYSQL_VOLUME=$(db_volume fxa-db); then
            # (already on 9 or later: lts, its users cannot be on mysql_native_password, and MySQL
            # cannot go back to 8)
            FXA_MYSQL_VOLUME_MAJOR=$(mysql_volume_major "${FXA_MYSQL_VOLUME}") || FXA_MYSQL_VOLUME_MAJOR=8
            [ "${FXA_MYSQL_VOLUME_MAJOR}" -ge 9 ] || FXA_MYSQL_IMAGE=mysql:8 FXA_MYSQL_ARGS=${FXA_MYSQL_NATIVE_ARGS}
        elif [ "${FXA_MYSQL2}" != 0 ]; then
            FXA_MYSQL_IMAGE=mysql:8 FXA_MYSQL_ARGS=${FXA_MYSQL_NATIVE_ARGS}
        fi
        apply_sed "${NEW_ENV}" "s|^# FXA_MYSQL_IMAGE=.*|FXA_MYSQL_IMAGE=$(sed_escape "${FXA_MYSQL_IMAGE}")|"
        [ -z "${FXA_MYSQL_ARGS}" ] || apply_sed "${NEW_ENV}" "s|^# FXA_MYSQL_ARGS=.*|FXA_MYSQL_ARGS=$(sed_escape "${FXA_MYSQL_ARGS}")|"
    fi
    if [ -n "${ADMIN_ALLOWED_USERS:-}" ]; then
        # the admin UI signs in with these accounts: a public OAuth client (PKCE, no secret:
        # the accounts service refuses PKCE from clients with one), registered by fxa-auth
        ADMIN_FXA_CLIENT_ID=$(od -An -tx1 -N8 /dev/urandom | tr -d ' \n')
        apply_sed "${NEW_ENV}" "s|^ADMIN_FXA_CLIENT_ID=.*|ADMIN_FXA_CLIENT_ID=${ADMIN_FXA_CLIENT_ID}|"
        apply_sed "${NEW_ENV}" "s|^ADMIN_ALLOWED_USERS=.*|ADMIN_ALLOWED_USERS=${ADMIN_ALLOWED_USERS}|"
        apply_sed "${NEW_ENV}" "s|^ADMIN_OIDC_REDIRECT_URL=.*|ADMIN_OIDC_REDIRECT_URL=https://${ADMIN_HOST}/auth/callback|"
        # written out for the Quadlets too, which have no defaults like compose/fxa.yml
        apply_sed "${NEW_ENV}" "s|^ADMIN_OIDC_ISSUER=.*|ADMIN_OIDC_ISSUER=https://accounts.${FXA_DOMAIN}|"
        apply_sed "${NEW_ENV}" "s|^ADMIN_OIDC_CLIENT_ID=.*|ADMIN_OIDC_CLIENT_ID=${ADMIN_FXA_CLIENT_ID}|"
        apply_sed "${NEW_ENV}" "s|^ADMIN_OIDC_NAME=.*|ADMIN_OIDC_NAME=\"Mozilla account\"|"
        # the accounts service has no email_verified claim, but only lets confirmed
        # sessions through to the admin UI (SERVICES_WITH_EMAIL_VERIFICATION in fxa-auth)
        apply_sed "${NEW_ENV}" "s|^ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL=.*|ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL=true|"
    fi
    # nginx example for the accounts host names
    cp "${SCRIPT_DIR}/config/nginx/fxa-example.conf" "${SCRIPT_DIR}/config/nginx/fxa.conf"
    apply_sed "${SCRIPT_DIR}/config/nginx/fxa.conf" "s|<ACCOUNTS_HOST>|accounts.${FXA_DOMAIN}|g"
    apply_sed "${SCRIPT_DIR}/config/nginx/fxa.conf" "s|<API_HOST>|api.${FXA_DOMAIN}|g"
    apply_sed "${SCRIPT_DIR}/config/nginx/fxa.conf" "s|<PROFILE_HOST>|profile.${FXA_DOMAIN}|g"
    apply_sed "${SCRIPT_DIR}/config/nginx/fxa.conf" "s|<PAIRING_HOST>|pairing.${FXA_DOMAIN}|g"
    # the pairing server's block, commented out unless it runs here
    [ "${PAIRING}" = yes ] && apply_sed "${SCRIPT_DIR}/config/nginx/fxa.conf" "/^# server {$/,/^# }$/s|^# \{0,1\}||"
    for port in CONTENT AUTH PROFILE PROFILE_STATIC PAIRING; do
        value=$(grep "^FXA_${port}_EXPORT_PORT=" "${NEW_ENV}" | cut -d= -f2)
        apply_sed "${SCRIPT_DIR}/config/nginx/fxa.conf" "s|<${port}_EXPORT_PORT>|${value}|g"
    done
    if [ "${ADMIN_UI}" = "yes" ]; then
        value=$(grep "^ADMIN_GATE_EXPORT_PORT=" "${NEW_ENV}" | cut -d= -f2)
        apply_sed "${SCRIPT_DIR}/config/nginx/fxa.conf" "s|<ADMIN_GATE_EXPORT_PORT>|${value}|g"
    else
        # no sign-up gate without the admin UI
        apply_sed "${SCRIPT_DIR}/config/nginx/fxa.conf" "/# admin UI only/,/^  }$/d"
    fi
    if [ -n "${ADMIN_ALLOWED_USERS:-}" ]; then
        value=$(grep "^ADMIN_EXPORT_PORT=" "${NEW_ENV}" | cut -d= -f2)
        apply_sed "${SCRIPT_DIR}/config/nginx/fxa.conf" "s|<ADMIN_HOST>|${ADMIN_HOST}|g"
        apply_sed "${SCRIPT_DIR}/config/nginx/fxa.conf" "s|<ADMIN_EXPORT_PORT>|${value}|g"
    else
        apply_sed "${SCRIPT_DIR}/config/nginx/fxa.conf" "/# admin UI sign-in only/,/# end of the admin UI sign-in/d"
    fi
fi
if [ "${DATABASE_BACKEND}" = "postgres" ]; then
    apply_sed "${NEW_ENV}" "s|^SYNC_IMAGE=.*|SYNC_IMAGE=syncstorage-rs-postgres|"
    apply_sed "${NEW_ENV}" "s|^SYNC_INIT_IMAGE=.*|SYNC_INIT_IMAGE=syncstorage-rs-postgres-init|"
    # the database container: the Sync server gets a role of its own, SYNC_POSTGRES_USER is the
    # container's superuser (your own server: SYNC_POSTGRES_USER is the plain owner, docs/reference/database-users.md#postgresql)
    if [ "${EXTERNAL_DB}" != "yes" ]; then
        apply_sed "${NEW_ENV}" "s|^SYNC_POSTGRES_APP_USER=.*|SYNC_POSTGRES_APP_USER=syncserver_app|"
        apply_sed "${NEW_ENV}" "s|^SYNC_POSTGRES_APP_PASSWORD=.*|SYNC_POSTGRES_APP_PASSWORD=$(generate_random_string 32)|"
    fi
    # the major of the install, above
    apply_sed "${NEW_ENV}" "s|^# SYNC_POSTGRES_IMAGE=.*|SYNC_POSTGRES_IMAGE=$(sed_escape "${SYNC_POSTGRES_PIN}")|"
fi
# the compose files (also written for the Quadlets, which do not read it): the Sync database's,
# MariaDB's with your own MySQL server too (its client, as before compose/), the accounts', and
# compose/podman.yml for docker compose on the Podman socket; and the project's name, which
# compose would take from compose/ ("compose") otherwise
case "${DATABASE_BACKEND}" in
    postgres) COMPOSE_SYNC_DB=postgres ;;
    *) COMPOSE_SYNC_DB=$([ "${SYNC_COMPOSE_MYSQL}" = yes ] && echo mysql || echo mariadb) ;;
esac
COMPOSE_FILES=$(compose_files "${COMPOSE_SYNC_DB}" "$([ "${SELF_HOST_FXA}" = yes ] && echo "${FXA_DB}")" \
    "$([ "${CONTAINER_RUNTIME}" = podman ] && [ "${DEPLOY_METHOD}" != quadlets ] && echo yes)")
apply_sed "${NEW_ENV}" "s|^# COMPOSE_FILE=.*|COMPOSE_FILE=${COMPOSE_FILES}|"
apply_sed "${NEW_ENV}" "s|^# COMPOSE_PROJECT_NAME=.*|COMPOSE_PROJECT_NAME=$(compose_project)|"
ENV_READ=${NEW_ENV} compose_settings_check
# the new .env in place, the one of before kept
if [ -f "${SCRIPT_DIR}/.env" ]; then
    ENV_BACKUP=$(backup_name "${SCRIPT_DIR}/.env.before-setup")
    private_copy "${SCRIPT_DIR}/.env" "${ENV_BACKUP}" || { echo "ERROR: could not keep ${SCRIPT_DIR}/.env as ${ENV_BACKUP}: nothing written"; rm -f "${NEW_ENV}"; exit 1; }
    echo "NOTE: ${SCRIPT_DIR}/.env written again with new passwords, the one of before is $(basename "${ENV_BACKUP}")"
    echo "  (to keep the passwords of an install: ./prepare_environment.sh --upgrade, Quadlets too)"
fi
replace_env "${NEW_ENV}" "${SCRIPT_DIR}/.env" || exit 1
unset ENV_READ

# the SQL for your own database server, with the names and passwords of .env (docs/databases.md#create-the-databases-and-users)
[ "${EXTERNAL_DB}" = "yes" ] && render_sync_sql "${DATABASE_BACKEND}"
# and the account that applies it at every start (docs/databases.md#the-bootstrap-account); an
# earlier one removed: it holds that account's password
rm -f "${SCRIPT_DIR}/database-bootstrap.sql" "${SCRIPT_DIR}/database-bootstrap-fxa.sql"
[ -n "${SYNC_DB_BOOTSTRAP_USER}" ] && render_bootstrap_sql "${DATABASE_BACKEND}"
[ -n "${FXA_DB_BOOTSTRAP_USER}" ] && render_bootstrap_sql fxa "${FXA_DB}"
if [ "${EXTERNAL_FXA_DB}" = "yes" ]; then
    # MySQL and an accounts image without mozilla/fxa#21554: their user on mysql_native_password
    render_fxa_sql "${FXA_DB}" "$([ "${FXA_DB}" = mysql ] && [ "${FXA_MYSQL2}" != 0 ] && echo native)"
fi

# prepare nginx example
cp "${SCRIPT_DIR}/config/nginx/syncstorage-rs-example.conf" "${SCRIPT_DIR}/config/nginx/syncstorage-rs.conf"
apply_sed "${SCRIPT_DIR}/config/nginx/syncstorage-rs.conf" "s/firefox-sync.example.com/${SYNC_FQDN}/g"
# the Sync server where it listens: its address (127.0.0.1 for every interface, 0.0.0.0, or a
# port alone in an .env of before), not localhost, which nginx tries on ::1 first
# (IPv6: [::] every interface, nginx on [::1])
SYNC_UPSTREAM=${SYNC_EXPORT_PORT}
case "${SYNC_UPSTREAM}" in
    0.0.0.0:*) SYNC_UPSTREAM=127.0.0.1:${SYNC_UPSTREAM##*:} ;;
    "[::]:"*) SYNC_UPSTREAM="[::1]:${SYNC_UPSTREAM##*:}" ;;
    *:*) ;;
    *) SYNC_UPSTREAM=127.0.0.1:${SYNC_UPSTREAM} ;;
esac
apply_sed "${SCRIPT_DIR}/config/nginx/syncstorage-rs.conf" "s|localhost:<SYNC_EXPORT_PORT>|${SYNC_UPSTREAM}|; s|<SYNC_EXPORT_PORT>|${SYNC_UPSTREAM##*:}|"

# prepare systemd example (for docker compose; with Podman, Quadlets start at boot instead)
cp "${SCRIPT_DIR}/config/systemd/syncstorage-rs-example.service" "${SCRIPT_DIR}/config/systemd/syncstorage-rs.service"
apply_sed "${SCRIPT_DIR}/config/systemd/syncstorage-rs.service" "s|<DOCKER_USER>|${CONTAINER_USER}|"
apply_sed "${SCRIPT_DIR}/config/systemd/syncstorage-rs.service" "s|<COMPOSE_DIR>|${SCRIPT_DIR}|"

# Setup Quadlets if requested
if [ "${CONTAINER_RUNTIME}" = "podman" ] && [ "${DEPLOY_METHOD}" = "quadlets" ]; then
    echo ""
    echo "Setting up Podman Quadlets..."
    render_units
    # the nightly backups: the timer on (at the next start of the user's systemd too), or off
    if [ "${BACKUPS}" = yes ]; then
        systemctl --user enable firefox-sync-backup.timer > /dev/null 2>&1 \
            || echo "WARNING: could not enable firefox-sync-backup.timer: systemctl --user enable --now firefox-sync-backup.timer (docs/backups.md#the-backup-service)"
    elif systemctl --user is-enabled -q firefox-sync-backup.timer 2> /dev/null; then
        systemctl --user disable --now firefox-sync-backup.timer > /dev/null 2>&1
        echo "  the nightly backups off: firefox-sync-backup.timer disabled"
    fi
fi

echo ""
echo "=========================================="
echo "Configuration complete!"
echo "=========================================="
echo ""
echo "Container Runtime: ${CONTAINER_RUNTIME}"
echo "Database Backend: ${DATABASE_BACKEND}"
echo "Configuration files created:"
echo "  - .env"
[ "${EXTERNAL_DB}" = "yes" ] && echo "  - database-setup.sql (the databases and users for your server)"
[ -n "${SYNC_DB_BOOTSTRAP_USER}" ] && echo "  - database-bootstrap.sql (the account ${SYNC_DB_BOOTSTRAP_USER}, which applies database-setup.sql at every start)"
[ "${EXTERNAL_FXA_DB}" = "yes" ] && echo "  - database-setup-fxa.sql (the accounts users for your $([ "${FXA_DB}" = "mariadb" ] && echo MariaDB || echo MySQL) server)"
[ -n "${FXA_DB_BOOTSTRAP_USER}" ] && echo "  - database-bootstrap-fxa.sql (the account ${FXA_DB_BOOTSTRAP_USER}, which applies database-setup-fxa.sql at every start)"
echo "  - config/nginx/syncstorage-rs.conf"
echo "  - config/systemd/syncstorage-rs.service"
[ "${SELF_HOST_FXA}" = "yes" ] && echo "  - config/nginx/fxa.conf (accounts.${FXA_DOMAIN}, api.${FXA_DOMAIN}, profile.${FXA_DOMAIN}${ADMIN_HOST:+, ${ADMIN_HOST}}$([ "${PAIRING}" = yes ] && echo ", pairing.${FXA_DOMAIN}"))"

if [ "${CONTAINER_RUNTIME}" = "podman" ] && [ "${DEPLOY_METHOD}" = "quadlets" ]; then
    echo "  - Quadlet files in ${QUADLET_DIR}"
fi
if [ "${ADMIN_UI}" = "yes" ]; then
    echo ""
    echo "Admin UI: http://localhost:8090 on this host (over SSH: ssh -L 8090:127.0.0.1:8090 <host>),"
    echo "  password: ADMIN_PASSWORD in .env. See docs/admin/README.md"
    [ -n "${ADMIN_ALLOWED_USERS:-}" ] && echo "  or https://${ADMIN_HOST}, signed in with the accounts of ${ADMIN_ALLOWED_USERS}"
fi

echo ""

# your own database server: what to run there first
# (with the bootstrap: the file of its account, once; the stack runs database-setup.sql itself)
SYNC_SQL_FILE=database-setup.sql FXA_SQL_FILE=database-setup-fxa.sql
[ -n "${SYNC_DB_BOOTSTRAP_USER}" ] && SYNC_SQL_FILE=database-bootstrap.sql
[ -n "${FXA_DB_BOOTSTRAP_USER}" ] && FXA_SQL_FILE=database-bootstrap-fxa.sql
if [ "${EXTERNAL_DB}" = "yes" ]; then
    echo "First, on your database server (see docs/databases.md#create-the-databases-and-users):"
    [ -n "${SYNC_DB_BOOTSTRAP_USER}" ] && echo "  once, the account ${SYNC_DB_BOOTSTRAP_USER} (it creates it; an account you have: its grants), then the stack applies database-setup.sql at every start:"
    if [ "${DATABASE_BACKEND}" = "postgres" ]; then
        echo "  psql -h ${DB_HOST} -p ${DB_PORT} -U postgres -f ${SYNC_SQL_FILE}"
        echo "  pg_hba.conf: a host line (not hostssl) for the containers' addresses, scram-sha-256"
    else
        echo "  MySQL:   mysql -h ${DB_HOST} -P ${DB_PORT} -u root -p < ${SYNC_SQL_FILE}"
        echo "  MariaDB: mariadb -h ${DB_HOST} -P ${DB_PORT} -u root -p < ${SYNC_SQL_FILE}"
        echo "  with binary logging (MySQL's default): log_bin_trust_function_creators=ON"
        echo "  plain connections allowed (require_secure_transport=OFF): the Sync server has no TLS"
    fi
fi
if [ "${EXTERNAL_FXA_DB}" = "yes" ]; then
    [ "${EXTERNAL_DB}" = "yes" ] || echo "First, on your database server (see docs/databases.md#create-the-databases-and-users):"
    [ -n "${FXA_DB_BOOTSTRAP_USER}" ] && echo "  once, the account ${FXA_DB_BOOTSTRAP_USER} for the accounts, then the stack applies database-setup-fxa.sql at every start:"
    if [ "${FXA_DB}" = "mariadb" ]; then
        echo "  mariadb -h ${FXA_MYSQL_HOST} -P ${FXA_MYSQL_PORT} -u root -p < ${FXA_SQL_FILE}"
        echo "  MariaDB 11.4 or later (12: with our accounts images, docs/accounts.md#mariadb-12), with binary logging: log_bin_trust_function_creators=ON"
    else
        echo "  mysql -h ${FXA_MYSQL_HOST} -P ${FXA_MYSQL_PORT} -u root -p < ${FXA_SQL_FILE}"
        if [ "${FXA_MYSQL2}" = 0 ]; then
            echo "  MySQL 8.4 or 9 with log_bin_trust_function_creators=ON"
        else
            echo "  MySQL 8.4 started with mysql_native_password=ON and log_bin_trust_function_creators=ON: the accounts"
            echo "  image has no mozilla/fxa#21554, its driver speaks mysql_native_password only (docs/accounts.md#mysql-or-mariadb)"
        fi
    fi
fi
[ "${EXTERNAL_DB}" = "yes" ] || [ "${EXTERNAL_FXA_DB}" = "yes" ] && echo ""
if [ "${SELF_HOST_FXA}" = "yes" ]; then
    if [ "${PINNED_FXA_MARIADB:-}" = "yes" ]; then
        echo "FXA_MARIADB_IMAGE=mariadb:11: the accounts database of this install stays on MariaDB 11."
        echo "  To move it to MariaDB lts, 12 (a backup first, there is no way back): docs/upgrading.md#mariadb"
    fi
    if [ -n "${FXA_MARIADB_VOLUME:-}" ]; then
        echo "FXA_MARIADB_IMAGE=mariadb:11: found the accounts database of an earlier install (${FXA_MARIADB_VOLUME}),"
        echo "  its data stays on MariaDB 11. Already on 12: set FXA_MARIADB_IMAGE=mariadb:lts. A new install: remove the volume"
        echo "  (its accounts are lost) and run this again. Moving it to lts: docs/upgrading.md#mariadb"
    fi
    if [ "${PINNED_FXA_MYSQL:-}" = "yes" ]; then
        echo "FXA_MYSQL_IMAGE=mysql:8, FXA_MYSQL_ARGS=${FXA_MYSQL_NATIVE_ARGS}: the accounts database"
        echo "  of this install stays on MySQL 8 with mysql_native_password. To move it to MySQL lts, 9: docs/upgrading.md#mysql-8-to-9"
    fi
    if [ -n "${FXA_MYSQL_VOLUME:-}" ] && [ "${FXA_MYSQL_VOLUME_MAJOR}" -ge 9 ]; then
        echo "FXA_MYSQL_IMAGE=mysql:lts: found the accounts database of an earlier install (${FXA_MYSQL_VOLUME}), on"
        echo "  MySQL ${FXA_MYSQL_VOLUME_MAJOR} already: it stays on lts. A new install: remove the volume (its accounts are lost) and run this again"
    elif [ -n "${FXA_MYSQL_VOLUME:-}" ]; then
        echo "FXA_MYSQL_IMAGE=mysql:8, FXA_MYSQL_ARGS=${FXA_MYSQL_NATIVE_ARGS}: found the accounts database"
        echo "  of an earlier install (${FXA_MYSQL_VOLUME}), its data stays on MySQL 8 with mysql_native_password."
        echo "  A new install: remove the volume"
        echo "  (its accounts are lost) and run this again. Moving it to lts: docs/upgrading.md#mysql-8-to-9"
    elif [ "${FXA_DB}" = mysql ] && [ "${EXTERNAL_FXA_DB}" != yes ] && [ "${PREVIOUS_FXA_MYSQL}" != yes ] && [ "${FXA_MYSQL2}" != 0 ]; then
        if [ "${FXA_MYSQL2}" = 2 ]; then
            echo "NOTE: could not read the labels of $(env_value FXA_IMAGE):$(env_value FXA_VERSION): MySQL lts (9) needs"
        elif [ "${FXA_MYSQL2}" = 3 ]; then
            echo "NOTE: your local $(env_value FXA_IMAGE):$(env_value FXA_VERSION) is older than the registry's: it does not have"
            echo "  mozilla/fxa#21554, the registry's has it. For MySQL lts (9) on this new install: pull it, then before the"
            echo "  first start set FXA_MYSQL_IMAGE=mysql:lts and remove FXA_MYSQL_ARGS in .env. Until then MySQL lts needs"
        else
            echo "NOTE: $(env_value FXA_IMAGE):$(env_value FXA_VERSION) does not have mozilla/fxa#21554 (Mozilla's images, ours"
            echo "  built before it), which MySQL lts (9) needs"
        fi
        echo "  an accounts image with mozilla/fxa#21554 (the mysql2 driver): fxa-db runs MySQL 8 with mysql_native_password"
        echo "  (FXA_MYSQL_IMAGE=mysql:8, FXA_MYSQL_ARGS=${FXA_MYSQL_NATIVE_ARGS}), see docs/accounts.md#mysql-or-mariadb"
    fi
    fxa_mariadb_image_check
    [ "${FXA_DB}" = mysql ] && fxa_mysql_image_check
fi
if [ "${DATABASE_BACKEND}" = postgres ] && [ -n "${SYNC_POSTGRES_MAJOR:-}" ]; then
    echo "SYNC_POSTGRES_IMAGE=postgres:${SYNC_POSTGRES_MAJOR}: PostgreSQL ${SYNC_POSTGRES_MAJOR}, the major of postgres:latest today, pinned: a newer"
    echo "  major cannot open its data. Moving later: docs/upgrading.md#postgresql"
elif [ "${DATABASE_BACKEND}" = postgres ] && [ -n "${SYNC_POSTGRES_VOLUME}" ]; then
    echo "SYNC_POSTGRES_IMAGE=${SYNC_POSTGRES_PIN}: found the Sync database of an earlier install (${SYNC_POSTGRES_VOLUME}),"
    echo "  PostgreSQL ${SYNC_POSTGRES_VOLUME_MAJOR}: it stays on it. A new install: remove the volume (its data is lost) and run this"
    echo "  again. Moving to a newer major: docs/upgrading.md#postgresql"
fi
if [ -n "${SYNC_MARIADB_FOUND}" ]; then
    echo "SYNC_MARIADB_IMAGE=${SYNC_MARIADB_PIN}: found the Sync databases of an earlier install on MariaDB ${SYNC_MARIADB_FOUND}: they stay on it."
    echo "  A new install: remove their volumes (the data is lost) and run this again. To follow lts: SYNC_MARIADB_IMAGE=mariadb:lts"
fi
if [ "${PINNED_SYNC_MYSQL:-}" = "yes" ]; then
    echo "SYNC_MYSQL_IMAGE=mysql:8: the Sync databases of this install stay on MySQL 8. To move them to MySQL lts, 9:"
    echo "  docs/upgrading.md#mysql-8-to-9"
fi
if [ -n "${SYNC_MYSQL_VOLUME:-}" ] && [ "${SYNC_MYSQL_VOLUME_MAJOR}" -ge 9 ]; then
    echo "SYNC_MYSQL_IMAGE=mysql:lts: found the Sync databases of an earlier install (${SYNC_MYSQL_VOLUME}), on MySQL"
    echo "  ${SYNC_MYSQL_VOLUME_MAJOR} already: they stay on lts. A new install: remove the volumes and run this again"
elif [ -n "${SYNC_MYSQL_VOLUME:-}" ]; then
    echo "SYNC_MYSQL_IMAGE=mysql:8: found the Sync databases of an earlier install (${SYNC_MYSQL_VOLUME}), their data"
    echo "  stays on MySQL 8. A new install: remove the volumes and run"
    echo "  this again. Moving them to lts: docs/upgrading.md#mysql-8-to-9"
fi

if [ "${CONTAINER_RUNTIME}" = "podman" ] && [ "${DEPLOY_METHOD}" = "quadlets" ]; then
    echo "Next steps for Quadlet deployment:"
    # the admin UI first: the Sync server sends its metrics only if it runs then
    if [ "${ADMIN_UI}" = "yes" ]; then
        echo "  1. systemctl --user start firefox-sync-admin.service firefox-sync-syncstorage.service"
    else
        echo "  1. systemctl --user start firefox-sync-syncstorage.service"
    fi
    if [ "${SELF_HOST_FXA}" = "yes" ]; then
        echo "     systemctl --user start firefox-sync-fxa-content.service firefox-sync-fxa-profile.service \\"
        echo "       firefox-sync-fxa-profile-worker.service firefox-sync-fxa-profile-static.service"
        echo "     then in Firefox set identity.fxaccounts.autoconfig.uri to https://accounts.${FXA_DOMAIN} (see docs/firefox.md#self-hosted-accounts)"
    fi
    echo "  2. (Optional) loginctl enable-linger \$USER"
    if [ "${BACKUPS}" = yes ]; then
        echo "  3. nightly backups: firefox-sync-backup.timer is enabled, start it with the units: systemctl --user start firefox-sync-backup.timer"
    else
        echo "  3. (Optional) nightly backups: systemctl --user enable --now firefox-sync-backup.timer (docs/backups.md#the-backup-service)"
    fi
    echo ""
    echo "To check status:"
    echo "  systemctl --user status firefox-sync-syncstorage.service"
    echo ""
    echo "See docs/install/podman.md for detailed instructions"
elif [ "${CONTAINER_RUNTIME}" = "podman" ]; then
    echo "Next steps for docker compose with the Podman socket (COMPOSE_FILE of .env has compose/podman.yml):"
    echo "  1. systemctl --user enable --now podman.socket"
    echo "  2. export DOCKER_HOST=unix://\${XDG_RUNTIME_DIR}/podman/podman.sock"
    echo "  3. docker compose up -d"
    [ "${BACKUPS}" = yes ] || echo "  (Optional) nightly backups: add backup to COMPOSE_PROFILES in .env (docs/backups.md#the-backup-service)"
    echo ""
    echo "See docs/install/podman.md for detailed instructions (podman-compose is not supported)"
else
    echo "Next steps:"
    echo "  1. docker compose up -d"
    [ "${SELF_HOST_FXA}" = "yes" ] && echo "     then in Firefox set identity.fxaccounts.autoconfig.uri to https://accounts.${FXA_DOMAIN} (see docs/firefox.md#self-hosted-accounts)"
    [ "${BACKUPS}" = yes ] || echo "  (Optional) nightly backups: add backup to COMPOSE_PROFILES in .env (docs/backups.md#the-backup-service)"
    echo "  2. (Optional) Install systemd service:"
    echo "     sudo cp config/systemd/syncstorage-rs.service /etc/systemd/system/"
    echo "     sudo systemctl enable --now syncstorage-rs.service"
fi

echo "=========================================="
