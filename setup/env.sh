# shellcheck shell=bash
# prepare_environment.sh: .env as compose reads it and written as it needs (atomically, this
# user only, the copies of before), the temporary files and their traps, sed with its script
# in a file, the renamed settings, the compose files and project of an install.
# Sourced by prepare_environment.sh (and the tests that source it): functions and tables only.

generate_random_string() {
  local length="${1}"
  tr -dc '[:alnum:]' < /dev/urandom | head -c "${length}"
}

# The temporary files that hold passwords (sed scripts, the .env being written, the units
# rendered aside) are removed at the exit, also on Ctrl-C (INT) and TERM: those of a subshell
# are in FFS_TMP, a directory of this user only (mktemp -d) that the main shell removes, the
# others listed with ffs_temp. The traps run after those set before (chained, not replaced)
FFS_TMP="" FFS_TEMPS=()
ffs_cleanup() {
    local f
    for f in ${FFS_TEMPS[@]+"${FFS_TEMPS[@]}"}; do rm -rf -- "${f}"; done
    FFS_TEMPS=()
    [ -n "${FFS_TMP}" ] && rm -rf -- "${FFS_TMP}"
    FFS_TMP=""
}
ffs_traps() {
    local sig before end main=yes
    # in a subshell the traps of the main shell are not set (trap -p still shows them): not
    # chained there (bash 3.2 has no BASHPID: the parent of a command of this shell)
    [ "$(exec sh -c 'echo "${PPID}"')" = "$$" ] || main=""
    # (and there the files of the main shell are not its own: at its exit only those it makes,
    # when it set up FFS_TMP itself, e.g. a function of the sourced script in a pipe)
    [ -n "${main}" ] || FFS_TEMPS=()
    for sig in EXIT INT TERM; do
        # (trap -p prints the trap as a command, quoted: its third word is the action)
        before=""
        [ -n "${main}" ] && { eval "set -- $(trap -p "${sig}")"; before=${3:-}; }
        case "${sig}" in INT) end="exit 130" ;; TERM) end="exit 143" ;; *) end="" ;; esac
        # shellcheck disable=SC2064 # (the action of before, as it is now)
        trap "ffs_cleanup${before:+; ${before}}${end:+; ${end}}" "${sig}"
    done
}
# ffs_temp <path>: removed at the exit
ffs_temp() { FFS_TEMPS+=("${1}"); }
# FFS_TMP and the traps, once, in the main shell (run: at the start; sourced: at the first need)
ffs_temp_init() {
    [ -n "${FFS_TMP}" ] && [ -d "${FFS_TMP}" ] && return 0
    FFS_TMP=$(mktemp -d "${TMPDIR:-/tmp}/ffs.XXXXXX") || return 1
    ffs_traps
}

# sed_script <script> <sed arguments...>: sed with its script in a file of this user only
# (in FFS_TMP; mktemp: 0600), never on the command line: the values of .env in it (passwords,
# secrets) would be in the arguments any user sees with ps while it runs
sed_script() {
    local script rc
    ffs_temp_init || return 1
    script=$(mktemp "${FFS_TMP}/sed.XXXXXX") || return 1
    printf '%s\n' "${1}" > "${script}" || { rm -f "${script}"; return 1; }
    shift
    sed -f "${script}" "$@"
    rc=$?
    rm -f "${script}"
    return "${rc}"
}

apply_sed() {
    local file=${1}
    shift
    local expression=${*}

    if [[ "${OSTYPE}" == "darwin"* ]]; then
        # macOS: BSD sed requires an empty string with -i option
        sed_script "${expression}" -i '' "${file}"
    else
        # Linux and other Unix-like systems: GNU sed does not require anything after -i
        sed_script "${expression}" -i "${file}"
    fi
}

# escape a value for the replacement part of `sed s|...|...|`
sed_escape() {
    # (a line break: \ at the end of each line but the last)
    printf '%s' "${1}" | sed -e 's/[\\/&|]/\\&/g' -e '$!s/$/\\/'
}

# The Sync server's settings, renamed to the SYNC_ prefix (docs/upgrading.md#renamed-settings):
# new=old. The old names still work, compose and the Quadlets read them when the new one is
# not set, and will be removed in a later release; --upgrade renames them in .env
RENAMED_SETTINGS=(
    SYNC_TOKENSERVER_DB_NAME=MARIADB_TOKENSERVER_DATABASE
    SYNC_TOKENSERVER_DB_USER=MARIADB_TOKENSERVER_USER
    SYNC_TOKENSERVER_DB_PASSWORD=MARIADB_TOKENSERVER_PASSWORD
    SYNC_TOKENSERVER_DB_HOST=MARIADB_TOKENSERVER_SERVER
    SYNC_TOKENSERVER_DB_PORT=MARIADB_TOKENSERVER_SERVER_PORT
    SYNC_STORAGE_DB_NAME=MARIADB_SYNCSTORAGE_DATABASE
    SYNC_STORAGE_DB_USER=MARIADB_SYNCSTORAGE_USER
    SYNC_STORAGE_DB_PASSWORD=MARIADB_SYNCSTORAGE_PASSWORD
    SYNC_STORAGE_DB_HOST=MARIADB_SYNCSTORAGE_SERVER
    SYNC_STORAGE_DB_PORT=MARIADB_SYNCSTORAGE_SERVER_PORT
    SYNC_POSTGRES_NAME=POSTGRES_DATABASE
    SYNC_POSTGRES_USER=POSTGRES_USER
    SYNC_POSTGRES_PASSWORD=POSTGRES_PASSWORD
    SYNC_POSTGRES_HOST=POSTGRES_SERVER
    SYNC_POSTGRES_PORT=POSTGRES_SERVER_PORT
    SYNC_POSTGRES_APP_USER=POSTGRES_SYNC_USER
    SYNC_POSTGRES_APP_PASSWORD=POSTGRES_SYNC_PASSWORD
    SYNC_POSTGRES_IMAGE=POSTGRES_IMAGE
    SYNC_DB_TLS_VERIFY=MARIADB_TLS_VERIFY
    SYNC_DB_CONTAINERS=DB_CONTAINERS
    SYNC_MAX_USERS=MAX_USERS
    SYNC_EXPORT_PORT=CONTAINER_EXPORT_PORT
    SYNC_PUBLIC_URL=SYNCSTORAGE_DOMAIN
    SYNC_METRICS_HASH_SECRET=METRICS_HASH_SECRET
    IMAGE_REPOSITORY=REPOSITORY
    SYNC_IMAGE=SYNCSTORAGE_IMAGE
    SYNC_IMAGE_TAG=SYNCSTORAGE_IMAGE_TAG
    SYNC_INIT_IMAGE=SYNCSTORAGE_INIT_IMAGE
    SYNC_INIT_IMAGE_TAG=SYNCSTORAGE_INIT_IMAGE_TAG
)
# the old name of a renamed setting ("" for the others)
old_name() {
    local pair
    for pair in "${RENAMED_SETTINGS[@]}"; do
        [ "${pair%%=*}" = "${1}" ] && { printf '%s' "${pair#*=}"; return; }
    done
}

# a value of .env, as compose reads it (not with `source`: it is no shell script); env_value
# of a renamed setting reads the old name when the new one is not set, as compose does
# (a line of compose's .env may be indented or start with export; CRLF line ends). ENV_READ:
# another file to read (the copy --upgrade and the setup edit before it replaces .env)
ENV_LEAD='[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}'
env_file_read() { printf '%s' "${ENV_READ:-${SCRIPT_DIR}/.env}"; }
env_line() { grep "^${ENV_LEAD}${1}=" "$(env_file_read)" | sed -e "s/^[^=]*=//" | tr -d '\r'; }
env_has() { grep -q "^${ENV_LEAD}${1}=" "$(env_file_read)"; }
# the value as compose reads it (its dotenv parser), from the last line:
# - in single quotes: what is between them as written, but \' for a quote;
# - in double quotes: up to the first quote without a backslash, with the escapes \" \\ \n
#   \r \t (\a \b \f \v), \$ and $$ for a $; another backslash stays as it is;
# - otherwise: without a comment (" #..."), the spaces around, and $$ for a $.
# A comment after the quotes is dropped. Not as compose: ${NAME} and $NAME are not replaced
# with other values, and a quoted value goes on to the end of its line only
env_plain() {
    local v q c out="" i=1 esc=""
    v=$(env_line "${1}" | tail -n 1)
    v=${v#"${v%%[![:space:]]*}"}
    case "${v}" in
        \'*|\"*)
            q=${v:0:1}
            while [ "${i}" -lt "${#v}" ]; do
                c=${v:i:1} i=$((i + 1))
                if [ -n "${esc}" ]; then
                    esc=""
                    if [ "${c}" = "${q}" ]; then
                        out=${out}${c}
                    elif [ "${q}" = '"' ]; then
                        case "${c}" in
                            n) out=${out}$'\n' ;; r) out=${out}$'\r' ;; t) out=${out}$'\t' ;;
                            a) out=${out}$'\a' ;; b) out=${out}$'\b' ;; f) out=${out}$'\f' ;; v) out=${out}$'\v' ;;
                            \\|\$) out=${out}${c} ;;
                            *) out=${out}\\${c} ;;
                        esac
                    else
                        out=${out}\\${c}
                    fi
                elif [ "${c}" = \\ ]; then
                    esc=yes
                elif [ "${c}" = "${q}" ]; then
                    printf '%s' "${out}"
                    return
                elif [ "${q}" = '"' ] && [ "${c}" = \$ ] && [ "${v:i:1}" = \$ ]; then
                    out=${out}\$ i=$((i + 1))
                else
                    out=${out}${c}
                fi
            done
            # no closing quote (compose refuses the file): the rest of the line
            printf '%s' "${out}${esc:+\\}" ;;
        *)
            v=${v%% #*}
            v=${v%"${v##*[![:space:]]}"}
            while [[ "${v}" == *'$$'* ]]; do out=${out}${v%%'$$'*}\$ v=${v#*'$$'}; done
            printf '%s' "${out}${v}" ;;
    esac
}
# env_plain, with the old name of a renamed setting when the new one has no value
env_value() {
    local value old
    value=$(env_plain "${1}")
    old=$(old_name "${1}")
    [ -z "${value}" ] && [ -n "${old}" ] && value=$(env_plain "${old}")
    printf '%s\n' "${value}"
}
# a value for double quotes in .env, read back as it is (env_plain, compose): \ " and $ escaped
env_dq() { printf '%s' "${1}" | sed -e 's/[\\"$]/\\&/g'; }
# a backup name that is not taken: <path>-<UTC time>, -2, -3... after it within a second
backup_name() {
    local base n=2
    base=${1}-$(date -u +%Y%m%dT%H%M%SZ)
    [ ! -e "${base}" ] && { printf '%s' "${base}"; return; }
    while [ -e "${base}-${n}" ]; do n=$((n + 1)); done
    printf '%s' "${base}-${n}"
}
# a copy of an .env (passwords): this user only, whatever the mode of the original
private_copy() { rm -f "${2}" && (umask 077; cp "${1}" "${2}"); }
# the file a path names, its symlinks followed (readlink without -f: macOS before 12.3 has none)
resolve_path() {
    local path=${1} link n=0
    while [ -L "${path}" ] && [ "${n}" -lt 40 ]; do
        link=$(readlink "${path}") || break
        case "${link}" in /*) path=${link} ;; *) path=$(dirname "${path}")/${link} ;; esac
        n=$((n + 1))
    done
    printf '%s' "${path}"
}
# private_temp <path> <variable>: a new file of this user only (0600) next to path, named
# after it (mktemp: a name nobody could have put a symlink at), in the variable; removed at
# the exit unless moved (in this shell: not in a $(...))
private_temp() {
    local ffs_new
    ffs_new=$(mktemp "$(dirname "${1}")/.$(basename "${1}").XXXXXX") || return 1
    ffs_temp "${ffs_new}"
    printf -v "${2}" '%s' "${ffs_new}"
}
# replace_env <new> <.env>: the new file (this user only) in place of .env. A symlink stays one:
# its target is replaced, by a rename in the target's own directory, else (that directory not
# writable) by writing the content into it; 0600 in both cases
replace_env() {
    local new=${1} dest=${2} target tmp
    target=$(resolve_path "${dest}")
    [ "${target}" = "${dest}" ] && { mv "${new}" "${dest}"; return; }
    tmp=""
    if private_temp "${target}" tmp 2> /dev/null && cat "${new}" > "${tmp}" && chmod 600 "${tmp}" && mv "${tmp}" "${target}"; then
        rm -f "${new}"
        return 0
    fi
    [ -n "${tmp}" ] && rm -f "${tmp}"
    (umask 077; cat "${new}" > "${target}") && chmod 600 "${target}" && rm -f "${new}"
}

# the accounts of this install self-hosted (prepare_environment.sh wrote their passwords)
fxa_installed() {
    local pw
    pw=$(env_plain FXA_MYSQL_PASSWORD)
    [ -n "${pw}" ] && [[ "${pw}" != *"<REPLACE_WITH_"* ]]
}

# compose's project, which names the containers and the volumes: COMPOSE_PROJECT_NAME (this
# shell's, then .env's), else the directory's name, as compose makes it a project name. Written
# to .env with COMPOSE_FILE: with compose/ first there, compose would take "compose"
compose_project() {
    local project
    project=${COMPOSE_PROJECT_NAME:-$( [ -f "${SCRIPT_DIR}/.env" ] && env_plain COMPOSE_PROJECT_NAME)}
    normalize_project "${project:-$(basename "${SCRIPT_DIR}")}"
}
# a name as compose makes it a project name (compose-go's NormalizeProjectName): lowercase, only
# a-z 0-9 _ -, no _ or - at its start
normalize_project() {
    local name
    name=$(printf '%s' "${1}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')
    while [ -n "${name}" ] && case "${name}" in [_-]*) true ;; *) false ;; esac; do name=${name#?}; done
    printf '%s' "${name}"
}
# COMPOSE_PROJECT_NAME of .env (ENV_READ) against the name of this directory: a WARNING when they
# differ (a copy of another checkout manages that one's containers and volumes,
# docs/reference/settings.md); a NOTE when this shell exports COMPOSE_FILE or
# COMPOSE_PROJECT_NAME with other values than .env's, which compose takes instead
compose_settings_check() {
    local here project file
    here=$(normalize_project "$(basename "${SCRIPT_DIR}")")
    project=$(env_plain COMPOSE_PROJECT_NAME)
    if [ -n "${project}" ] && [ "${project}" != "${here}" ]; then
        echo "WARNING: COMPOSE_PROJECT_NAME=${project} in .env, while this directory would be the project ${here}:"
        echo "  docker compose here runs the containers and volumes of the project ${project}. If this is a copy of"
        echo "  another checkout, \`docker compose down -v\` here removes that one's volumes: give a second stack a name"
        echo "  of its own in .env (docs/reference/settings.md, COMPOSE_PROJECT_NAME)"
    fi
    file=$(env_plain COMPOSE_FILE)
    [ -n "$(printenv COMPOSE_FILE)" ] && [ "$(printenv COMPOSE_FILE)" != "${file}" ] && \
        echo "NOTE: COMPOSE_FILE is exported where this runs ($(printenv COMPOSE_FILE)), which docker compose takes over .env's (${file:-none}): change it there too (your shell, a unit's Environment=)"
    [ -n "$(printenv COMPOSE_PROJECT_NAME)" ] && [ "$(printenv COMPOSE_PROJECT_NAME)" != "${project}" ] && \
        echo "NOTE: COMPOSE_PROJECT_NAME is exported where this runs ($(printenv COMPOSE_PROJECT_NAME)), which docker compose takes over .env's (${project:-none}): change it there too (your shell, a unit's Environment=)"
    # the pairing server follows FXA_IMAGE: Mozilla's accounts image has no pairing server tag
    if [[ "$(env_value FXA_IMAGE)" == */fxa-mono ]] && [[ ",$(env_plain COMPOSE_PROFILES)," == *,pairing,* ]] \
        && [ -z "$(env_plain FXA_PAIRING_IMAGE)" ] && [ -z "$(env_plain FXA_PAIRING_REPOSITORY)" ]; then
        echo "WARNING: the pairing server follows FXA_IMAGE=$(env_value FXA_IMAGE) (Mozilla's accounts image), which has no"
        echo "  pairing server: set FXA_PAIRING_IMAGE (Mozilla's: docker.io/mozilla/channelserver:<tag>) or"
        echo "  FXA_PAIRING_REPOSITORY (ours: ghcr.io/porelli/firefox-sync) in .env (docs/reverse-proxy.md#pairing)"
    fi
    return 0
}
# docker compose on the Podman socket: DOCKER_HOST is Podman's, the project's containers are
# Podman's, or Podman is there without Docker (not the Quadlets: their caller asks)
compose_on_podman() {
    case "${DOCKER_HOST:-}" in *podman*) return 0 ;; esac
    command -v podman > /dev/null 2>&1 || return 1
    command -v docker > /dev/null 2>&1 || return 0
    [ -n "$(podman ps -a -q --filter "label=com.docker.compose.project=$(compose_project)" 2> /dev/null)" ]
}
# COMPOSE_FILE with compose/podman.yml after the last file of compose/ (nothing printed when it has it)
compose_files_podman() {
    local part parts=() new="" done=no last=-1 i=0
    case ":${1}:" in *:compose/podman.yml:*|*/compose/podman.yml:*) return 0 ;; esac
    IFS=: read -r -a parts <<< "${1}"
    for part in "${parts[@]}"; do
        case "${part}" in compose/*.yml|*/compose/*.yml) last=${i} ;; esac
        i=$((i + 1))
    done
    i=0
    for part in "${parts[@]}"; do
        new=${new:+${new}:}${part}
        if [ "${i}" = "${last}" ]; then new="${new}:${part%compose/*}compose/podman.yml"; done=yes; fi
        i=$((i + 1))
    done
    [ "${done}" = yes ] || new=${new:+${new}:}compose/podman.yml
    printf '%s\n' "${new}"
}
# the compose files of an install (COMPOSE_FILE): compose/sync.yml and the Sync database's file,
# with self-hosted accounts compose/fxa.yml and theirs, with docker compose on the Podman socket
# compose/podman.yml (docs/install/compose.md#the-compose-files).
# compose_files <mariadb|mysql|postgres> <"" or the accounts' mysql|mariadb> <podman: yes|no>
compose_files() {
    local files="compose/sync.yml:compose/sync-${1}.yml"
    [ -n "${2}" ] && files="${files}:compose/fxa.yml:compose/fxa-${2}.yml"
    [ "${3}" = yes ] && files="${files}:compose/podman.yml"
    printf '%s\n' "${files}"
}
# COMPOSE_FILE with the files of before compose/ (docs/upgrading.md#files-that-moved) in their
# new names, the others as they are (a directory before a name kept); nothing printed when none
# is there. "" (no COMPOSE_FILE: docker-compose.yml, Sync on MariaDB) is docker-compose.yml.
# docker-compose.yml + docker-compose.sync-mysql.yml -> compose/sync.yml:compose/sync-mysql.yml,
# docker-compose.sync-postgres.yml (and its name before, docker-compose.postgres.yml) ->
# compose/sync.yml:compose/sync-postgres.yml, docker-compose.fxa.yml (+ docker-compose.fxa-mariadb.yml)
# -> compose/fxa.yml:compose/fxa-mysql.yml (fxa-mariadb.yml), docker-compose.podman.yml -> compose/podman.yml
compose_files_moved() {
    local value=${1:-docker-compose.yml} part dir sync_db=mariadb fxa_db=mysql new="" moved=no
    local parts=()
    IFS=: read -r -a parts <<< "${value}"
    for part in "${parts[@]}"; do
        case "${part##*/}" in
            docker-compose.sync-mysql.yml) sync_db=mysql ;;
            docker-compose.sync-postgres.yml|docker-compose.postgres.yml) sync_db=postgres ;;
            docker-compose.fxa-mariadb.yml) fxa_db=mariadb ;;
        esac
    done
    for part in "${parts[@]}"; do
        dir=${part%"${part##*/}"}
        case "${part##*/}" in
            docker-compose.yml|docker-compose.sync-postgres.yml|docker-compose.postgres.yml)
                part="${dir}compose/sync.yml:${dir}compose/sync-${sync_db}.yml" ;;
            docker-compose.fxa.yml) part="${dir}compose/fxa.yml:${dir}compose/fxa-${fxa_db}.yml" ;;
            docker-compose.podman.yml) part="${dir}compose/podman.yml" ;;
            # in the one of compose/sync.yml or compose/fxa.yml
            docker-compose.sync-mysql.yml|docker-compose.fxa-mariadb.yml) moved=yes; continue ;;
            *) new=${new:+${new}:}${part}; continue ;;
        esac
        moved=yes
        case ":${new}:" in *":${part%%:*}:"*) continue ;; esac
        new=${new:+${new}:}${part}
    done
    [ "${moved}" = yes ] && printf '%s\n' "${new}"
    return 0
}
