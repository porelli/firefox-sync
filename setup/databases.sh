# shellcheck shell=bash
# prepare_environment.sh: the SQL for your own database server, and the databases of an
# earlier install: their volumes, the majors of their data, of postgres:latest and of a running
# server. Sourced by prepare_environment.sh: functions only.

# the SQL for your own database server, with the names and passwords of .env
# (docs/databases.md#create-the-databases-and-users): every setup migration of a scope
# (db/<engine>/setup/<scope>/), as db/db-setup.sh fills them in at every start of the stack
# (db-bootstrap), with the INSERTs that record them on the server.
# db_setup_print <scope> <engine> <out> [NAME=value...]: db/db-setup.sh print <scope>, the
# settings of .env in its environment (never on a command line), out this user's only
db_setup_print() {
    local scope=${1} engine=${2} out=${3} kind=fxa name pair tmp
    shift 3
    case "${scope}" in sync*) kind=mysql; [ "${engine}" = postgres ] && kind=postgres ;; esac
    rm -f "${out}"
    tmp=$(mktemp "${out}.XXXXXX") || return 1
    chmod 600 "${tmp}"
    if (
        while read -r _ name; do export "${name}=$(env_value "${name}")"; done < <(bash "${SCRIPT_DIR}/db/db-setup.sh" settings "${kind}")
        for name in SYNC_DB_BOOTSTRAP_USER SYNC_DB_BOOTSTRAP_PASSWORD FXA_DB_BOOTSTRAP_USER FXA_DB_BOOTSTRAP_PASSWORD; do
            export "${name}=$(env_value "${name}")"
        done
        # (nothing of this shell's environment but what is set here)
        export FXA_MYSQL_ARGS="" FFS_BOTH_ENV_NAMES="" FFS_DB_ENGINE="${engine}" FFS_DB_DIR="${SCRIPT_DIR}/db"
        for pair in "$@"; do export "${pair?}"; done
        bash "${SCRIPT_DIR}/db/db-setup.sh" print "${scope}" --passwords
    ) > "${tmp}"; then
        mv "${tmp}" "${out}"
    else
        echo "ERROR: $(basename "${out}") not written: $(grep -m 1 'ERROR' "${tmp}")" >&2
        rm -f "${tmp}"
        return 1
    fi
}
# database-setup.sql of the Sync databases and the admin UI's (postgres, or mariadb and mysql)
render_sync_sql() {
    db_setup_print sync "${1}" "${SCRIPT_DIR}/database-setup.sql"
}
# database-setup-fxa.sql: render_fxa_sql <mysql|mariadb> [native]; native: the accounts' user
# on mysql_native_password (MySQL, an accounts image without mozilla/fxa#21554), the "-- native:"
# lines of db/mysql/setup/fxa-mysql instead of those after them, as db/db-setup.sh takes them
# with mysql_native_password in FXA_MYSQL_ARGS
render_fxa_sql() {
    db_setup_print fxa "${1}" "${SCRIPT_DIR}/database-setup-fxa.sql" "FXA_MYSQL_ARGS=$([ "${2:-}" = native ] && echo mysql_native_password)"
}
# database-bootstrap.sql (database-bootstrap-fxa.sql: fxa <mysql|mariadb>): the account that
# applies the SQL above at every start (SYNC_DB_BOOTSTRAP_USER, FXA_DB_BOOTSTRAP_USER of .env),
# docs/databases.md#the-bootstrap-account; its "-- MySQL: " lines on MySQL only
render_bootstrap_sql() {
    case "${1}" in
        fxa) db_setup_print fxa-bootstrap "${2:-mysql}" "${SCRIPT_DIR}/database-bootstrap-fxa.sql" ;;
        *) db_setup_print sync-bootstrap "${1}" "${SCRIPT_DIR}/database-bootstrap.sql" ;;
    esac
}
# keep_previous_sql <file>: the copy of an earlier database-setup*.sql as
# <file>.before-upgrade-<UTC time> (its passwords: this user's only), as --upgrade keeps .env
keep_previous_sql() {
    local backup
    [ -f "${1}" ] || return 0
    backup=$(backup_name "${1}.before-upgrade")
    private_copy "${1}" "${backup}" || { echo "ERROR: could not keep ${1} as ${backup}"; return 1; }
    echo "The $(basename "${1}") of before: $(basename "${backup}")"
}

# a database volume of an earlier install (the .env gone, or for another database):
# "<runtime> volume <name>", for any of the names given (compose: <project>_<name>, Quadlets:
# firefox-sync-<name>), e.g. db_volume fxa-db-mariadb
db_volume() {
    local project runtime volume name
    project=$(compose_project)
    for runtime in docker podman; do
        command -v "${runtime}" > /dev/null 2>&1 || continue
        for name in "$@"; do
            # (the Quadlets' names only for them: they are the same on every install of this user)
            for volume in "${project}_${name}" $([ "${DEPLOY_METHOD:-}" = quadlets ] && echo "firefox-sync-${name}"); do
                ${runtime} volume inspect "${volume}" > /dev/null 2>&1 && { echo "${runtime} volume ${volume}"; return 0; }
            done
        done
    done
    return 1
}

# the major of postgres:latest, from its own server ("postgres (PostgreSQL) 18.1 (Debian ...)"):
# pulled first (a local copy may be older than latest), with Docker, else Podman (a Docker
# without its daemon fails at once); without a registry, the local copy. The Quadlets: Podman's
# only, the store the units run from (also on a host with Docker), for this host's architecture
postgres_latest_major() {
    local runtime image pull out runtimes="docker podman"
    [ "${DEPLOY_METHOD:-}" = quadlets ] && runtimes=podman
    for pull in always missing; do
        for runtime in ${runtimes}; do
            command -v "${runtime}" > /dev/null 2>&1 || continue
            image=postgres:latest
            [ "${runtime}" = podman ] && image=docker.io/library/postgres:latest
            out=$(${runtime} run --rm --pull="${pull}" --entrypoint postgres "${image}" --version 2> /dev/null) || continue
            out=$(printf '%s' "${out}" | sed -n 's/^postgres (PostgreSQL) \([0-9][0-9]*\)[^0-9].*/\1/p')
            [ -n "${out}" ] && { echo "${out}"; return 0; }
        done
    done
    return 1
}
# the major of the MySQL data in a volume of db_volume ("<runtime> volume <name>"): the last
# version of its mysql_upgrade_history (8.4 and later write it); none, an empty volume or one of
# 8.0: nothing (fails)
mysql_volume_major() {
    # (db_volume's "<runtime> volume <name>": one word or three)
    # shellcheck disable=SC2086,SC2048
    set -- ${*}
    local runtime=${1} volume=${3} image=mysql:lts
    [ "${runtime}" = podman ] && image=docker.io/library/mysql:lts
    ${runtime} run --rm --pull=missing -v "${volume}:/v:ro" --entrypoint sh "${image}" -c 'cat /v/mysql_upgrade_history' 2> /dev/null \
        | grep -o '"version" *: *"[0-9]*' | tail -n 1 | sed 's/.*"//' | grep -x '[0-9][0-9]*'
}
# the major of the PostgreSQL data in a volume of db_volume ("<runtime> volume <name>"): its
# PG_VERSION (at the top or in data/ before 18, in <major>/docker/ since)
postgres_volume_major() {
    # (db_volume's "<runtime> volume <name>": one word or three)
    # shellcheck disable=SC2086,SC2048
    set -- ${*}
    local runtime=${1} volume=${3} image=postgres:latest
    [ "${runtime}" = podman ] && image=docker.io/library/postgres:latest
    # shellcheck disable=SC2016 # (the script of the container's sh)
    ${runtime} run --rm --pull=missing -v "${volume}:/v:ro" --entrypoint sh "${image}" -c \
        'for f in /v/PG_VERSION /v/data/PG_VERSION /v/*/docker/PG_VERSION; do [ -s "$f" ] && { cat "$f"; exit 0; }; done; exit 1' 2> /dev/null \
        | grep -x '[0-9][0-9]*'
}

# the major of the MariaDB data in a volume of db_volume: what mariadb-install-db and
# mariadb-upgrade wrote ("11.8.9-MariaDB"; mysql_upgrade_info before 10.11)
mariadb_volume_major() {
    # (db_volume's "<runtime> volume <name>": one word or three)
    # shellcheck disable=SC2086,SC2048
    set -- ${*}
    local runtime=${1} volume=${3} image=mariadb:lts
    [ "${runtime}" = podman ] && image=docker.io/library/mariadb:lts
    ${runtime} run --rm --pull=missing -v "${volume}:/v:ro" --entrypoint sh "${image}" -c \
        'cat /v/mariadb_upgrade_info /v/mysql_upgrade_info 2> /dev/null | tr -d "\0"' 2> /dev/null \
        | sed -n '1s/^\([0-9][0-9]*\)\..*/\1/p' | grep -x '[0-9][0-9]*'
}
# the major of the MariaDB a running Sync database container runs (compose's tokenserver_db of
# the project, the Quadlets' firefox-sync-tokenserver-db)
mariadb_running_major() {
    local project runtime ctr
    project=$(compose_project)
    for runtime in docker podman; do
        command -v "${runtime}" > /dev/null 2>&1 || continue
        for ctr in $(${runtime} ps -q --filter "label=com.docker.compose.project=${project}" --filter label=com.docker.compose.service=tokenserver_db 2> /dev/null) \
            $([ "${DEPLOY_METHOD:-}" = quadlets ] && echo firefox-sync-tokenserver-db); do
            ${runtime} exec "${ctr}" mariadbd --version 2> /dev/null | sed -n 's/.* Ver \([0-9][0-9]*\)\..*/\1/p' | grep -x '[0-9][0-9]*' && return 0
        done
    done
    return 1
}
# the major of the Sync MariaDB data of this install: its volume, else its running server
sync_mariadb_major() {
    local volume
    volume=$(db_volume tokenserver-db syncstorage-db) && mariadb_volume_major "${volume}" && return 0
    mariadb_running_major
}
