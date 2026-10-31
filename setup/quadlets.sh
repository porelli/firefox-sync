# shellcheck shell=bash
# prepare_environment.sh: the Quadlet units of an install, where they are, which checkout they
# were rendered from, and render_units (setup, --upgrade, --render-units). Sourced by
# prepare_environment.sh: functions only.

# where the Quadlet units go; timers are plain systemd units, not Quadlets
QUADLET_DIR="${QUADLET_DIR:-${HOME}/.config/containers/systemd}"
SYSTEMD_USER_DIR="${SYSTEMD_USER_DIR:-${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user}"
# the units of this install: installed, and rendered from this directory (they mount its
# config/backup and db/), not from another checkout
units_installed() { [ -f "${QUADLET_DIR}/firefox-sync-syncstorage.container" ]; }
# the directory the installed units were rendered from ("": not known)
units_dir() {
    grep -h '^Volume=/.*/config/backup:' "${QUADLET_DIR}"/firefox-sync-backup.container 2> /dev/null \
        | head -n 1 | sed -e 's|^Volume=||; s|/config/backup:.*||'
}
# a directory without its symlinks (cd -P: macOS and Linux), as it is when it is gone
canonical_dir() { (cd -P -- "${1}" 2> /dev/null && pwd -P) || printf '%s' "${1}"; }
units_of_here() {
    local dir
    dir=$(units_dir)
    [ -n "${dir}" ] && [ "$(canonical_dir "${dir}")" = "$(canonical_dir "${SCRIPT_DIR}")" ]
}
# units of this project that name no checkout: those of an earlier release, before the
# units mounted files of it (the releases before the backups, firefox-sync's main branch).
# Ours: the Sync server's unit runs the container firefox-sync-syncstorage of a syncstorage-rs image
units_without_dir() {
    local unit=${QUADLET_DIR}/firefox-sync-syncstorage.container
    units_installed && [ -z "$(units_dir)" ] && grep -qx 'ContainerName=firefox-sync-syncstorage' "${unit}" \
        && grep -q '^Image=.*syncstorage-rs' "${unit}"
}
# whether the installed Sync server's unit has the SYNC_MASTER_SECRET of .env, as a unit
# rendered from it has (compared here, not on a command line; systemd's %% for a %)
units_have_env_secret() {
    local unit env file=${QUADLET_DIR}/firefox-sync-syncstorage.env
    env=$(env_value SYNC_MASTER_SECRET)
    [ -n "${env}" ] && [[ "${env}" != *"<REPLACE_WITH_"* ]] || return 1
    # units of this release: in the unit's environment file, as it is (secret_env_file)
    if [ -f "${file}" ] && grep -q '^SYNC_MASTER_SECRET=' "${file}"; then
        unit=$(sed -n 's/^SYNC_MASTER_SECRET=//p' "${file}" | head -n 1)
        [ "${unit}" = "${env}" ]
        return
    fi
    # those of before, with the secrets in the unit
    unit=$(sed -n 's/^Environment=\("\{0,1\}\)SYNC_MASTER_SECRET=/\1/p' "${QUADLET_DIR}/firefox-sync-syncstorage.container" | head -n 1)
    case "${unit}" in \"*\") unit=${unit:1:${#unit}-2} ;; esac
    [ "${unit}" = "${env}" ] || [ "${unit}" = "${env//\%/%%}" ]
}
# a setting of .env that is a secret: a part of its name PASS, PASSWORD, SECRET, TOKEN or KEY
# (not the lifetime of the access tokens), and ADMIN_NOTIFY (its URLs have the tokens of the
# destinations), as the admin UI tells them (admin/config_test.go: secretName)
secret_setting() {
    case "${1}" in
        FXA_ACCESS_TOKEN_LIFETIME) return 1 ;;
        ADMIN_NOTIFY) return 0 ;;
    esac
    case "_${1}_" in *_PASS_*|*_PASSWORD_*|*_SECRET_*|*_TOKEN_*|*_KEY_*) return 0 ;; esac
    return 1
}
# the environment file of a unit (firefox-sync-<name>.env next to it): the variables of its
# container that hold a secret, out of the unit itself (its EnvironmentFile=), this user's only
secret_env_file() { printf '%s/%s.env' "${QUADLET_DIR}" "${1%.*}"; }

# the Quadlet units of .env, with the units SELF_HOST_FXA and ADMIN_UI say (the answers of
# the setup, or what the install has with --upgrade): rendered aside, then only the units
# that differ installed, the units of before kept first in quadlets.before-<UTC time>/; none
# differ: nothing written (run again, nothing changes)
render_units() {
    local key stage file filename source src target_dir changed=() removed=() backup repository
    local sync_containers sync_db fxa_containers fxa_db sync_overlay=""
    # the values of the units: those of .env (database names, users, FxA endpoints, etc.) as
    # compose reads them (env_plain: quotes, a comment after the value, export, CRLF), and the
    # ones set below; never this shell's environment (a name .env lacks: .env-example's
    # default). Not with `source`: unused sections keep placeholders like <REPLACE_WITH_...>
    RENDER_KEYS=" "
    # (shell variables, not exported: no other process gets the passwords in its environment)
    render_set() { printf -v "${1}" '%s' "${2}"; RENDER_KEYS="${RENDER_KEYS}${1} "; }
    render_set SCRIPT_DIR "${SCRIPT_DIR}"
    while IFS= read -r key; do
        render_set "${key}" "$(env_plain "${key}")"
    done < <(sed -n "s/^${ENV_LEAD}\([A-Za-z_][A-Za-z0-9_]*\)=.*/\2/p" "${SCRIPT_DIR}/.env" | sort -u)
    sync_containers=$(env_plain SYNC_DB_CONTAINERS) sync_db=$(env_plain SYNC_DB)
    # PostgreSQL: the images of .env say it (SYNC_DB is mariadb there, as compose has it)
    [ "$(env_value SYNC_IMAGE)" = "syncstorage-rs-postgres" ] && sync_db=postgres
    fxa_containers=$(env_plain FXA_DB_CONTAINERS) fxa_db=$(env_plain FXA_DB)
    mkdir -p "${QUADLET_DIR}" "${SYSTEMD_USER_DIR}"
    # the images from .env only (not this shell's environment); unset: lts, as the compose
    # files (the admin UI's: IMAGE_REPOSITORY's admin-latest). podman needs the registry in
    # the image name (compose is fine with mariadb:lts): a first part with a dot or a port,
    # or localhost, is one
    podman_image() {
        local image first
        image=$(env_plain "${1}")
        image=${image:-${2}}
        first=${image%%/*}
        if [ "${first}" != "${image}" ] && { [[ "${first}" == *[.:]* ]] || [ "${first}" = localhost ]; }; then
            :
        elif [[ "${image}" == */* ]]; then
            image=docker.io/${image}
        else
            image=docker.io/library/${image}
        fi
        render_set "${1}" "${image}"
    }
    podman_image SYNC_MARIADB_IMAGE mariadb:lts
    podman_image FXA_MARIADB_IMAGE mariadb:lts
    podman_image FXA_MYSQL_IMAGE mysql:lts
    podman_image SYNC_MYSQL_IMAGE mysql:lts
    podman_image SYNC_POSTGRES_IMAGE postgres:latest
    repository=$(env_value IMAGE_REPOSITORY)
    podman_image ADMIN_IMAGE "${repository:-ghcr.io/porelli/firefox-sync}:admin-latest"
    # fxa-db's extra options, none when not set
    render_set FXA_MYSQL_ARGS "$(env_plain FXA_MYSQL_ARGS)"
    # fxa-auth's log level, INFO when not set (as compose)
    FXA_LOG_LEVEL=$(env_plain FXA_LOG_LEVEL)
    render_set FXA_LOG_LEVEL "${FXA_LOG_LEVEL:-INFO}"
    # the accounts' units: --arch only for another architecture than this host's (an emulated
    # image). With it podman 4 pulls the tag from the registry at every start, over the local
    # image: the units would not run the image whose label chose FXA_MYSQL_IMAGE above
    FXA_ARCH_ARGS=""
    # (none in an .env from before FXA_ARCH: the host's)
    [ -z "$(env_plain FXA_ARCH)" ] || [ "$(env_plain FXA_ARCH)" = "$(host_arch)" ] || FXA_ARCH_ARGS="--arch=$(env_plain FXA_ARCH)"
    render_set FXA_ARCH_ARGS "${FXA_ARCH_ARGS}"

    # the database containers: the .env names (syncstorage_db) are compose's, here the
    # containers are reached by their names. Your own server: none of them
    SKIP_UNITS=""
    DROP_DEPS=""
    if [ "${sync_db}" = postgres ]; then
        # one PostgreSQL database (sync-postgres/), none of MariaDB's or MySQL's units (their
        # volumes are kept); the Sync server's own role, the superuser without it (an .env
        # from before SYNC_POSTGRES_APP_USER, your own server), as compose
        SKIP_UNITS='^firefox-sync-(syncstorage|tokenserver)-db(-mysql)?\.(container|volume)$'
        render_set SYNC_POSTGRES_CONNECT_USER "$(env_value SYNC_POSTGRES_APP_USER)"
        render_set SYNC_POSTGRES_CONNECT_PASSWORD "$(env_value SYNC_POSTGRES_APP_PASSWORD)"
        if [ -z "${SYNC_POSTGRES_CONNECT_USER}" ]; then
            render_set SYNC_POSTGRES_CONNECT_USER "$(env_value SYNC_POSTGRES_USER)"
            render_set SYNC_POSTGRES_CONNECT_PASSWORD "$(env_value SYNC_POSTGRES_PASSWORD)"
        fi
        # the renamed settings under their new names, also from an .env with the old ones
        for key in SYNC_POSTGRES_NAME SYNC_POSTGRES_USER SYNC_POSTGRES_PASSWORD SYNC_POSTGRES_APP_USER SYNC_POSTGRES_APP_PASSWORD; do
            render_set "${key}" "$(env_value "${key}")"
        done
        if [ "${sync_containers:-1}" = 0 ]; then
            SKIP_UNITS='^firefox-sync-((syncstorage|tokenserver)-db(-mysql)?|postgres-db)\.(container|volume)$'
            DROP_DEPS='firefox-sync-postgres-db\.service'
            render_set SYNC_POSTGRES_HOST "$(env_value SYNC_POSTGRES_HOST)"; render_set SYNC_POSTGRES_PORT "$(env_value SYNC_POSTGRES_PORT)"
        else
            render_set SYNC_POSTGRES_HOST firefox-sync-postgres-db; render_set SYNC_POSTGRES_PORT 5432
        fi
    elif [ "${sync_containers:-1}" = 0 ]; then
        SKIP_UNITS='^firefox-sync-(syncstorage|tokenserver)-db(-mysql)?\.(container|volume)$'
        DROP_DEPS='firefox-sync-(syncstorage|tokenserver)-db\.service'
    else
        render_set SYNC_STORAGE_DB_HOST firefox-sync-syncstorage-db; render_set SYNC_STORAGE_DB_PORT 3306
        render_set SYNC_TOKENSERVER_DB_HOST firefox-sync-tokenserver-db; render_set SYNC_TOKENSERVER_DB_PORT 3306
        if [ "${sync_db:-mariadb}" = "mysql" ]; then
            # MariaDB's volumes, unused (the volumes themselves are kept); MySQL's certificate
            # is self-signed, the init container's client does not check it
            SKIP_UNITS='^firefox-sync-(syncstorage|tokenserver)-db\.volume$'
            render_set SYNC_DB_TLS_VERIFY false
        fi
    fi
    # the users and grants of database-setup.sql applied or checked at every start
    # (db/db-setup.sh): for your own server only
    if [ "${sync_containers:-1}" != 0 ]; then
        SKIP_UNITS="${SKIP_UNITS:+${SKIP_UNITS}|}^firefox-sync-db-bootstrap\.container$"
        DROP_DEPS="${DROP_DEPS:+${DROP_DEPS}|}firefox-sync-db-bootstrap\.service"
    fi
    if [ "${fxa_containers:-1}" = 0 ]; then
        SKIP_UNITS="${SKIP_UNITS:+${SKIP_UNITS}|}^firefox-sync-fxa-db(-mariadb)?\.(container|volume)$"
        DROP_DEPS="${DROP_DEPS:+${DROP_DEPS}|}firefox-sync-fxa-db\.service"
    else
        SKIP_UNITS="${SKIP_UNITS:+${SKIP_UNITS}|}^firefox-sync-fxa-db-bootstrap\.container$"
        DROP_DEPS="${DROP_DEPS:+${DROP_DEPS}|}firefox-sync-fxa-db-bootstrap\.service"
        # MySQL's volume, unused (the volume itself is kept)
        [ "${fxa_db:-mysql}" = "mariadb" ] && SKIP_UNITS="${SKIP_UNITS}|^firefox-sync-fxa-db\.volume$"
    fi
    # Requires= on a unit that is not installed fails the start: drop those dependencies
    drop_deps() {
        [ -n "${DROP_DEPS}" ] || { cat; return; }
        sed -E -e "/^(After|Requires)=/{s/(=| )(${DROP_DEPS})/\1/g; s/= +/=/; s/ +$//; s/  +/ /g;}" -e '/^Requires=$/d'
    }

    # fill the %NAME% placeholders of a unit from .env (and SCRIPT_DIR); systemd expands %,
    # double it. No secret is left in a unit (split_secrets): one sed script of the other
    # values, its substitutions in the order of the names
    render_quadlet() {
        local file=${1} content name value script=""
        for name in $(grep -o '%[A-Z][A-Z0-9_]*%' "${file}" | sort -u | tr -d '%'); do
            if [[ "${RENDER_KEYS}" == *" ${name} "* ]]; then
                value=${!name}
            elif ENV_READ="${SCRIPT_DIR}/.env-example" env_has "${name}"; then
                value=$(ENV_READ="${SCRIPT_DIR}/.env-example" env_plain "${name}")
            else
                echo "ERROR: ${file} needs ${name}, which is not set in .env" >&2
                return 1
            fi
            value=$(printf '%s' "${value}" | sed -e 's/%/%%/g')
            script="${script}s|%${name}%|$(sed_escape "${value}")|g
"
        done
        content=$(sed_script "${script}" "${file}") || return 1
        printf '%s\n' "${content}"
    }

    # split_secrets <template> <unit> <env>: the Environment= lines of the template with a
    # secret of .env (secret_setting) as KEY=VALUE into env, the other lines into unit, with
    # EnvironmentFile= under [Container] when there are any (none: env empty)
    split_secrets() {
        local line name secret rest unit=() env=()
        while IFS= read -r line || [ -n "${line}" ]; do
            secret=""
            if [[ "${line}" == Environment=* ]]; then
                rest=${line}
                while [[ "${rest}" =~ %([A-Z][A-Z0-9_]*)% ]]; do
                    name=${BASH_REMATCH[1]}
                    secret_setting "${name}" && secret=yes
                    rest=${rest#*%"${name}"%}
                done
            fi
            if [ -n "${secret}" ]; then
                line=${line#Environment=}
                case "${line}" in \"*\") line=${line:1:${#line}-2} ;; esac
                env+=("${line}")
            else
                unit+=("${line}")
            fi
        done < "${1}"
        : > "${3}"
        [ "${#env[@]}" = 0 ] || printf '%s\n' "${env[@]}" > "${3}"
        for line in ${unit[@]+"${unit[@]}"}; do
            printf '%s\n' "${line}"
            # (systemd expands % in the unit: doubled)
            [ "${line}" = "[Container]" ] && [ "${#env[@]}" != 0 ] && printf 'EnvironmentFile=%s\n' "$(secret_env_file "${4}" | sed -e 's/%/%%/g')"
        done > "${2}"
        return 0
    }
    # render_env <env template>: its %NAME% from .env as render_quadlet takes them, as they are
    # (no systemd there: no %% for a %; podman reads each KEY=VALUE line as written), in this
    # shell (no value on a command line)
    render_env() {
        local line name value out
        while IFS= read -r line || [ -n "${line}" ]; do
            out=""
            while [[ "${line}" =~ %([A-Z][A-Z0-9_]*)% ]]; do
                name=${BASH_REMATCH[1]}
                if [[ "${RENDER_KEYS}" == *" ${name} "* ]]; then
                    value=${!name}
                elif ENV_READ="${SCRIPT_DIR}/.env-example" env_has "${name}"; then
                    value=$(ENV_READ="${SCRIPT_DIR}/.env-example" env_plain "${name}")
                else
                    echo "ERROR: ${1} needs ${name}, which is not set in .env" >&2
                    return 1
                fi
                out=${out}${line%%"%${name}%"*}${value}
                line=${line#*"%${name}%"}
            done
            printf '%s\n' "${out}${line}"
        done < "${1}"
    }

    QUADLET_SOURCES=("${SCRIPT_DIR}/config/quadlet")
    # SYNC_DB=mysql: sync-mysql/ replaces the database units of the same name (without the
    # database containers, SKIP_UNITS leaves them out); PostgreSQL: sync-postgres/ replaces
    # the units of the Sync server, its migrations, init and backups, and adds its database
    # and its role's init
    [ "${sync_db:-mariadb}" = "mysql" ] && sync_overlay=sync-mysql
    [ "${sync_db}" = postgres ] && sync_overlay=sync-postgres
    [ -n "${sync_overlay}" ] && QUADLET_SOURCES+=("${SCRIPT_DIR}/config/quadlet/${sync_overlay}")
    [ "${SELF_HOST_FXA}" = "yes" ] && QUADLET_SOURCES+=("${SCRIPT_DIR}/config/quadlet/fxa")
    # FXA_DB=mariadb: fxa/mariadb/ replaces the files of the same name in fxa/
    [ "${SELF_HOST_FXA}" = "yes" ] && [ "${fxa_db:-mysql}" = "mariadb" ] && QUADLET_SOURCES+=("${SCRIPT_DIR}/config/quadlet/fxa/mariadb")
    if [ "${ADMIN_UI}" = "yes" ]; then
        # with the accounts, the admin UI also manages them
        [ "${SELF_HOST_FXA}" = "yes" ] && QUADLET_SOURCES+=("${SCRIPT_DIR}/config/quadlet/fxa/admin") || QUADLET_SOURCES+=("${SCRIPT_DIR}/config/quadlet/admin")
    fi
    echo "Processing quadlet files..."
    stage=$(mktemp -d) || exit 1
    ffs_temp "${stage}"
    for source in "${QUADLET_SOURCES[@]}"; do
        for file in "${source}"/*.{network,volume,container,timer}; do
            [ -f "${file}" ] || continue
            filename=$(basename "${file}")
            [ "${fxa_db:-mysql}" = "mariadb" ] && [ -f "${source}/mariadb/${filename}" ] && continue
            [ -n "${sync_overlay}" ] && [ -f "${source}/${sync_overlay}/${filename}" ] && continue
            if [ -n "${SKIP_UNITS}" ] && [[ "${filename}" =~ ${SKIP_UNITS} ]]; then
                # left from a setup with the database containers (the volume is kept)
                [ -f "${QUADLET_DIR}/${filename}" ] && removed+=("${filename}")
                continue
            fi
            # PostgreSQL: the admin UI's unit (admin/ or fxa/admin/) with the Sync database of
            # compose/sync-postgres.yml's ffs-admin: one database, as the Sync server's
            # role (its reader with ADMIN_DB_PASSWORD), no storage database of its own
            src=${file}
            if [ "${sync_db}" = postgres ] && [ "${filename}" = firefox-sync-admin.container ]; then
                src=${stage}/.${filename}.postgres
                sed -e 's|^Environment="TOKENSERVER_DB_TYPE=mysql"$|Environment="TOKENSERVER_DB_TYPE=postgres"|' \
                    -e 's|%SYNC_TOKENSERVER_DB_HOST%|%SYNC_POSTGRES_HOST%|; s|%SYNC_TOKENSERVER_DB_PORT%|%SYNC_POSTGRES_PORT%|' \
                    -e 's|%SYNC_TOKENSERVER_DB_NAME%|%SYNC_POSTGRES_NAME%|; s|%SYNC_TOKENSERVER_DB_USER%|%SYNC_POSTGRES_CONNECT_USER%|' \
                    -e '/^Environment="STORAGE_DB_[A-Z]*=/d' -e '/^Environment="SYNC_DB=/d' "${file}" > "${src}" || { rm -rf "${stage}"; exit 1; }
            fi
            # the secrets into the unit's environment file (secret_env_file), this user's only
            split_secrets "${src}" "${stage}/.${filename}.unit" "${stage}/.${filename}.env" "${filename}" || { rm -rf "${stage}"; exit 1; }
            if [ -s "${stage}/.${filename}.env" ]; then
                (umask 077; render_env "${stage}/.${filename}.env" > "${stage}/$(basename "$(secret_env_file "${filename}")")") \
                    || { rm -rf "${stage}"; exit 1; }
            fi
            # (an empty PodmanArgs= would reset the ones before it, the network aliases)
            render_quadlet "${stage}/.${filename}.unit" | drop_deps | sed -e '/^PodmanArgs=$/d' > "${stage}/${filename}"
            [ "${PIPESTATUS[0]}" = 0 ] || { rm -rf "${stage}"; exit 1; }
            rm -f "${stage}/.${filename}.unit" "${stage}/.${filename}.env"
            [ "${src}" = "${file}" ] || rm -f "${src}"
        done
    done
    for file in "${QUADLET_DIR}"/firefox-sync-*.env; do
        [ -f "${file}" ] && [ ! -f "${stage}/$(basename "${file}")" ] && removed+=("$(basename "${file}")")
    done
    # (the environment files first: a unit is never there without the file it names)
    for file in "${stage}"/*.env "${stage}"/*; do
        [ -f "${file}" ] || continue
        filename=$(basename "${file}")
        case " ${changed[*]-} " in *" ${filename} "*) continue ;; esac
        target_dir=${QUADLET_DIR}
        [[ "${filename}" == *.timer ]] && target_dir=${SYSTEMD_USER_DIR}
        # (the same content: this user's only all the same)
        if [[ "${filename}" == *.env ]] && [ -f "${target_dir}/${filename}" ]; then chmod 600 "${target_dir}/${filename}"; fi
        cmp -s "${file}" "${target_dir}/${filename}" || changed+=("${filename}")
    done
    if [ "${#changed[@]}" = 0 ] && [ "${#removed[@]}" = 0 ]; then
        rm -rf "${stage}"
        echo "  the units in ${QUADLET_DIR} are those of .env already: nothing changed"
        UNITS_CHANGED=""
        return 0
    fi
    # the units of before and their environment files (the secrets: this user only), all of them
    # (nothing is written when that copy fails)
    if ls "${QUADLET_DIR}"/firefox-sync-* "${SYSTEMD_USER_DIR}"/firefox-sync-*.timer > /dev/null 2>&1; then
        backup=$(backup_name "${SCRIPT_DIR}/quadlets.before")
        if ! (umask 077; mkdir "${backup}" && for file in "${QUADLET_DIR}"/firefox-sync-* "${SYSTEMD_USER_DIR}"/firefox-sync-*.timer; do
                [ -e "${file}" ] || continue; cp "${file}" "${backup}/" || exit 1; done); then
            rm -rf "${stage}" "${backup}"
            echo "ERROR: could not keep the units of before in ${backup}: no unit written" >&2
            exit 1
        fi
        echo "  the units of before: ${backup}"
    fi
    for filename in "${changed[@]}"; do
        target_dir=${QUADLET_DIR}
        [[ "${filename}" == *.timer ]] && target_dir=${SYSTEMD_USER_DIR}
        if [[ "${filename}" == *.env ]]; then
            # (the secrets: this user's only, also over a file of other permissions)
            if ! { rm -f "${target_dir}/${filename}" && (umask 077; cp "${stage}/${filename}" "${target_dir}/${filename}") \
                && chmod 600 "${target_dir}/${filename}"; }; then
                rm -rf "${stage}"; exit 1
            fi
        else
            cp "${stage}/${filename}" "${target_dir}/${filename}" || { rm -rf "${stage}"; exit 1; }
        fi
        echo "  ✓ ${filename}"
    done
    for filename in "${removed[@]}"; do
        rm -f "${QUADLET_DIR}/${filename}"
        echo "  - ${filename} (removed)"
    done
    rm -rf "${stage}"
    # shellcheck disable=SC2034 # (read by upgrade_env)
    UNITS_CHANGED="${changed[*]} ${removed[*]}"

    echo ""
    echo "Reloading systemd daemon..."
    systemctl --user daemon-reload
}
