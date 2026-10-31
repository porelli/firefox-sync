# shellcheck shell=bash
# prepare_environment.sh: the SQL for your own database server, and the databases of an
# earlier install: their volumes, the majors of their data, of postgres:latest and of a running
# server. Sourced by prepare_environment.sh: functions only.

# the SQL for your own database server, with the names and passwords of .env (docs/databases.md#create-the-databases-and-users)
render_sql() {
    local template=${1} out=${2} pair script=""
    shift 2
    for pair in "$@"; do
        script="${script}s|@${pair%%=*}@|$(sed_escape "${pair#*=}")|g
"
    done
    rm -f "${out}"
    (umask 077; sed_script "${script}" "${template}" > "${out}")
}
# the placeholders of a template (mysql, postgres: sync.sql; fxa: fxa-*.sql) filled from .env,
# PLACEHOLDER=value per line: the settings of db/db-setup.sh, which fills them in the same way
# at every start of the stack (db-bootstrap)
sql_pairs() {
    local placeholder setting
    while read -r placeholder setting; do
        printf '%s=%s\n' "${placeholder}" "$(env_value "${setting}")"
    done < <(bash "${SCRIPT_DIR}/db/db-setup.sh" settings "${1}")
}
# render_with <template> <out> <kind> [PLACEHOLDER=value...]: render_sql with the values of sql_pairs
render_with() {
    local template=${1} out=${2} pair pairs=()
    while IFS= read -r pair; do pairs+=("${pair}"); done < <(sql_pairs "${3}")
    shift 3
    render_sql "${template}" "${out}" "${pairs[@]}" "$@"
}
# database-setup.sql of the Sync databases and the admin UI's (postgres, or mariadb and mysql)
render_sync_sql() {
    local kind=mysql
    [ "${1}" = "postgres" ] && kind=postgres
    render_with "${SCRIPT_DIR}/db/${kind}/sync.sql" "${SCRIPT_DIR}/database-setup.sql" "${kind}"
}
# database-setup-fxa.sql: render_fxa_sql <mysql|mariadb> [native]; native: the accounts' user
# on mysql_native_password (MySQL, an accounts image without mozilla/fxa#21554), the commented
# lines of fxa-mysql.sql instead of those after them, as db/db-setup.sh takes them with
# mysql_native_password in FXA_MYSQL_ARGS
render_fxa_sql() {
    local template=${SCRIPT_DIR}/db/mysql/fxa-${1}.sql
    if [ "${2:-}" = native ]; then
        template=${SCRIPT_DIR}/database-setup-fxa.native
        sed -e "/^-- native: /{s/^-- native: //;n;d;}" "${SCRIPT_DIR}/db/mysql/fxa-mysql.sql" > "${template}"
    fi
    render_with "${template}" "${SCRIPT_DIR}/database-setup-fxa.sql" fxa
    [ "${2:-}" != native ] || rm -f "${template}"
}
# database-bootstrap.sql (database-bootstrap-fxa.sql: fxa): the account that applies the SQL
# above at every start (SYNC_DB_BOOTSTRAP_USER, FXA_DB_BOOTSTRAP_USER of .env), docs/databases.md#the-bootstrap-account
render_bootstrap_sql() {
    local kind=${1} template out=${SCRIPT_DIR}/database-bootstrap.sql prefix=SYNC
    case "${kind}" in
        postgres) template=${SCRIPT_DIR}/db/postgres/bootstrap.sql ;;
        fxa) template=${SCRIPT_DIR}/db/mysql/fxa-bootstrap.sql out=${SCRIPT_DIR}/database-bootstrap-fxa.sql prefix=FXA ;;
        *) template=${SCRIPT_DIR}/db/mysql/bootstrap.sql kind=mysql ;;
    esac
    render_with "${template}" "${out}" "${kind}" BOOTSTRAP_USER="$(env_value "${prefix}_DB_BOOTSTRAP_USER")" \
        BOOTSTRAP_PASSWORD="$(env_value "${prefix}_DB_BOOTSTRAP_PASSWORD")"
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
