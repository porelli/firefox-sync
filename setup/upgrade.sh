# shellcheck shell=bash
# prepare_environment.sh --upgrade and --render-units: upgrade_env. Sourced by
# prepare_environment.sh: functions only.

# ./prepare_environment.sh --upgrade: the .env of an install that runs (docker compose), given
# the settings of this release that need a value of their own (docs/upgrading.md#older-firefox-sync-releases), nothing else
# changed: the admin UI's database users (ADMIN_DB_PASSWORD; the event log moves out of the
# Sync server's reach at the next start), the Sync server's own role in the PostgreSQL
# container (SYNC_POSTGRES_APP_USER, SYNC_POSTGRES_APP_PASSWORD), in COMPOSE_FILE the new names
# of the compose files (compose/, docs/upgrading.md#files-that-moved) with COMPOSE_PROJECT_NAME, and with the accounts on
# MariaDB FXA_MARIADB_IMAGE=mariadb:11, the major they run (the compose default is now
# mariadb:lts, 12: written out, they stay on 11; a move is up to the admin, docs/upgrading.md#mariadb), on MySQL
# FXA_MYSQL_IMAGE=mysql:8 and FXA_MYSQL_ARGS with mysql_native_password, Sync on MySQL
# SYNC_MYSQL_IMAGE=mysql:8 (the default is now mysql:lts, 9; docs/upgrading.md#mysql-8-to-9). A value already set is kept; the
# old file is kept as .env.before-upgrade-<UTC time>. With your own database server database-setup.sql
# (and database-setup-fxa.sql) is written again (the one of before kept as
# database-setup.sql.before-upgrade-<UTC time>), to run there first, or the stack applies the
# setup migrations itself at the next start (SYNC_DB_BOOTSTRAP_USER, the choice of the setup). First the settings of RENAMED_SETTINGS get their new
# names, their values as they are.
# The Quadlets (their units installed from this directory, or --render-units): the same, then
# the settings of .env-example that .env lacks added with their defaults (a new secret only
# for a secret that is missing: every password and secret of .env stays), and the units
# rendered again from .env (render_units), with the units of before kept; no question asked.
# Also to apply a setting changed in .env, or an image pinned there. Run again, nothing
# changes (docs/upgrading.md#quadlets)
upgrade_env() {
    local env_file dot_env backup name changed=() quadlets=no here
    SCRIPT_DIR=${FFS_ENTRY_DIR}
    dot_env=${SCRIPT_DIR}/.env
    [ -f "${dot_env}" ] || { echo "ERROR: no ${dot_env} to upgrade: run ./prepare_environment.sh"; exit 1; }
    if [ "${RENDER_UNITS:-}" = yes ]; then
        quadlets=yes
        # a compose install is no Quadlet one: a first render only when asked for
        if ! units_installed && [ "${RENDER_FRESH:-}" != yes ]; then
            echo "ERROR: no Quadlet units in ${QUADLET_DIR}: --render-units renders those of an install again."
            echo "  To install the units of this .env (it then runs with Quadlets): ./prepare_environment.sh --render-units --fresh"
            exit 1
        fi
        if units_installed && ! units_of_here; then
            here=$(units_dir)
            if [ -n "${here}" ]; then
                echo "WARNING: the units in ${QUADLET_DIR} were rendered from ${here}, not ${SCRIPT_DIR}:"
            else
                echo "WARNING: the units in ${QUADLET_DIR} name no checkout (an earlier release of firefox-sync, or none of its):"
            fi
            echo "  rendered again from this .env (the units of before are kept)"
        fi
    elif units_installed; then
        here=$(units_dir)
        if units_of_here; then
            quadlets=yes
        # an earlier release's units, without the checkout in them: this install's when they have
        # its SYNC_MASTER_SECRET, else they are only said (docs/upgrading.md#quadlets)
        elif units_without_dir && units_have_env_secret; then
            quadlets=yes
            echo "NOTE: the Quadlet units in ${QUADLET_DIR} are of an earlier release of firefox-sync (they name no"
            echo "  checkout), with the SYNC_MASTER_SECRET of ${dot_env}: rendered again from it"
            echo ""
        elif units_without_dir; then
            echo "NOTE: found the Quadlet units of an earlier release of firefox-sync in ${QUADLET_DIR} (they name no"
            echo "  checkout), with another SYNC_MASTER_SECRET than ${dot_env}: not rendered again. If they are those of"
            echo "  this install, ./prepare_environment.sh --render-units renders them from this .env (docs/upgrading.md#quadlets)"
            echo ""
        else
            echo "NOTE: the Quadlet units in ${QUADLET_DIR} are those of ${here:-another directory}, not of ${SCRIPT_DIR}:"
            echo "  not rendered again (./prepare_environment.sh --render-units renders them from this .env)"
            echo ""
        fi
    fi
    if [ "${quadlets}" = yes ]; then
        command -v podman > /dev/null 2>&1 || { echo "ERROR: --render-units: the Quadlets need podman, which is not installed"; exit 1; }
        # shellcheck disable=SC2034 # (read by the image checks, setup/images.sh)
        DEPLOY_METHOD=quadlets
    fi
    # the old names of RENAMED_SETTINGS: the line renamed where it is (indented or with
    # export, as compose reads it too), the rest of it as it is written. Both names there:
    # the new one is kept, unless it has no value of its own (empty, a placeholder or the
    # default of .env-example, e.g. added from it: then the old one's value); the old line
    # goes. A WARNING when what compose runs with changes; every value of before stays in
    # .env.before-upgrade-<UTC time>
    rename_settings() {
        local pair new old new_value old_value example effective after kind moved=() notes=() warnings=()
        for pair in "${RENAMED_SETTINGS[@]}"; do
            new=${pair%%=*} old=${pair#*=}
            env_has "${old}" || continue
            old_value=$(env_plain "${old}")
            if env_has "${new}"; then
                new_value=$(env_plain "${new}")
                example=$(grep "^${new}=" "${SCRIPT_DIR}/.env-example" | cut -d= -f2- | tr -d '\r')
                # what compose runs with now: the new name, the old one when it is empty
                effective=${new_value:-${old_value}}
                if [ "${new_value}" = "${old_value}" ]; then
                    # shellcheck disable=SC2153 # (ENV_LEAD: setup/env.sh)
                    apply_sed "${env_file}" "/^${ENV_LEAD}${old}=/d"
                    notes+=("${old}: removed, ${new} has the same value")
                elif [ -z "${new_value}" ] || [[ "${new_value}" == *"<REPLACE_WITH_"* ]] || [ "${new_value}" = "${example}" ]; then
                    apply_sed "${env_file}" "/^${ENV_LEAD}${new}=/d"
                    apply_sed "${env_file}" "s/^\(${ENV_LEAD}\)${old}=/\1${new}=/"
                    if [ -z "${new_value}" ]; then kind="no value"; elif [[ "${new_value}" == *"<REPLACE_WITH_"* ]]; then kind="the placeholder of .env-example"; else kind="the default of .env-example"; fi
                    notes+=("${new}: had ${kind}, now the value of ${old}")
                else
                    apply_sed "${env_file}" "/^${ENV_LEAD}${old}=/d"
                    notes+=("${old}: removed, its value differs from that of ${new}, which is kept")
                fi
                after=$(env_plain "${new}")
                if [ "${effective}" != "${after}" ]; then
                    case "${new}" in
                        *PASSWORD*|*SECRET*) warnings+=("${new}: effective value changed (a secret, not shown): that of ${old}") ;;
                        *) warnings+=("${new}: effective value '${effective}' -> '${after}' (that of ${old})") ;;
                    esac
                fi
            else
                apply_sed "${env_file}" "s/^\(${ENV_LEAD}\)${old}=/\1${new}=/"
            fi
            moved+=("${old} -> ${new}")
            changed+=("${new}")
        done
        [ "${#moved[@]}" = 0 ] && return
        echo "Renamed in .env, the values as they were (docs/upgrading.md#renamed-settings):"
        printf '  %s\n' "${moved[@]}"
        [ "${#notes[@]}" = 0 ] || printf '  NOTE: %s\n' "${notes[@]}"
        if [ "${#warnings[@]}" != 0 ]; then
            printf 'WARNING: %s\n' "${warnings[@]}"
            echo "  Check them before starting: .env.before-upgrade-<UTC time> has the previous file."
        fi
        echo "  Rename them in your own scripts too (docker compose run -e, systemd units...)."
    }
    # old names exported where this runs: docker compose run from here would get both names
    # and refuse to start, which no change of .env clears
    old_names_in_environment() {
        local pair old found=()
        for pair in "${RENAMED_SETTINGS[@]}"; do
            old=${pair#*=}
            [ -n "$(printenv "${old}")" ] && found+=("${old} (${pair%%=*} in .env)")
        done
        [ "${#found[@]}" = 0 ] && return
        echo "WARNING: old setting names in the environment of this shell, which docker compose would also"
        echo "  see next to the new names of .env, and refuse to start: unset them in your shell (and CI):"
        printf '  %s\n' "${found[@]}"
    }
    set_value() {
        if env_has "${1}"; then
            apply_sed "${env_file}" "s|^\(${ENV_LEAD}\)${1}=.*|\1${1}=$(sed_escape "${2}")|"
        else
            printf '%s=%s\n' "${1}" "${2}" >> "${env_file}"
        fi
        changed+=("${1}")
    }
    # every change on a copy (this user only), which replaces .env at the end: a run that stops
    # halfway leaves .env as it was
    # (mktemp in the directory of .env: the rename at the end stays one)
    private_temp "${dot_env}.upgrading" env_file && cat "${dot_env}" > "${env_file}" || exit 1
    # shellcheck disable=SC2034 # (read by env_file_read, setup/env.sh)
    ENV_READ=${env_file}
    rename_settings
    # the names: those of .env-example
    for name in ADMIN_DB_NAME ADMIN_DB_USER ADMIN_DB_SYNC_USER; do
        env_has "${name}" || set_value "${name}" "$(grep "^${name}=" "${SCRIPT_DIR}/.env-example" | cut -d= -f2-)"
    done
    [ -n "$(env_value ADMIN_DB_PASSWORD)" ] || set_value ADMIN_DB_PASSWORD "$(generate_random_string 32)"
    # the compose files moved to compose/ (docs/upgrading.md#files-that-moved): their new names in
    # COMPOSE_FILE, and the project's name written next to it (compose/ first there, compose
    # would name it "compose": other containers, other volumes). No COMPOSE_FILE (docker-compose.yml,
    # which includes those of MariaDB now) with a docker-compose.override.yml, which compose reads
    # only then: left as it is
    local compose_file compose_new
    compose_file=$(env_value COMPOSE_FILE)
    case "${compose_file}" in
        \'*\') compose_file=${compose_file:1:${#compose_file}-2} ;;
        \"*\") compose_file=${compose_file:1:${#compose_file}-2} ;;
    esac
    compose_new=$(compose_files_moved "${compose_file}")
    # (the Quadlets read no COMPOSE_FILE: none stays none)
    [ -z "${compose_file}" ] && [ "${quadlets}" = yes ] && compose_new=""
    if [ -z "${compose_file}" ] && [ -n "${compose_new}" ] && { [ -f "${SCRIPT_DIR}/docker-compose.override.yml" ] || [ -f "${SCRIPT_DIR}/docker-compose.override.yaml" ]; }; then
        echo "COMPOSE_FILE: not set, with a docker-compose.override.yml: left so (docker-compose.yml runs the files of compose/,"
        echo "  docs/upgrading.md#files-that-moved). To set it: ${compose_new} and your file"
    elif [ -n "${compose_new}" ]; then
        set_value COMPOSE_FILE "${compose_new}"
        env_has COMPOSE_PROJECT_NAME || set_value COMPOSE_PROJECT_NAME "$(compose_project)"
        echo "COMPOSE_FILE: the compose files moved to compose/ (docs/upgrading.md#files-that-moved): now ${compose_new}"
        echo "  (before: ${compose_file:-not set, docker-compose.yml}), COMPOSE_PROJECT_NAME=$(env_value COMPOSE_PROJECT_NAME)"
        local part parts=()
        IFS=: read -r -a parts <<< "${compose_new}"
        for part in "${parts[@]}"; do
            case "${part}" in
                compose/*.yml|*/compose/*.yml) ;;
                *) echo "  NOTE: ${part}: relative paths in it (./...) are now relative to compose/, the directory of the first file"; break ;;
            esac
        done
    fi
    # docker compose on the Podman socket: compose/podman.yml in COMPOSE_FILE (the setup of before
    # had it in its -f command only)
    local compose_podman
    if [ "${quadlets}" != yes ] && [ -n "$(env_value COMPOSE_FILE)" ] && compose_on_podman \
        && compose_podman=$(compose_files_podman "$(env_value COMPOSE_FILE)") && [ -n "${compose_podman}" ]; then
        set_value COMPOSE_FILE "${compose_podman}"
        echo "COMPOSE_FILE: docker compose on the Podman socket: compose/podman.yml added (now ${compose_podman})"
    fi
    compose_settings_check
    if [ "$(env_value SYNC_IMAGE)" = "syncstorage-rs-postgres" ] && [ "$(env_value SYNC_DB_CONTAINERS)" != 0 ] && [ -z "$(env_value SYNC_POSTGRES_APP_PASSWORD)" ]; then
        [ -n "$(env_value SYNC_POSTGRES_APP_USER)" ] || set_value SYNC_POSTGRES_APP_USER syncserver_app
        set_value SYNC_POSTGRES_APP_PASSWORD "$(generate_random_string 32)"
    fi
    # Sync on PostgreSQL, from before SYNC_POSTGRES_IMAGE: the major its data is on, read from the
    # stack's volume (PG_VERSION); without a readable volume (your own server, another host)
    # postgres:18, which every release before SYNC_POSTGRES_IMAGE ran (git log --follow --
    # compose/sync-postgres.yml)
    if [ "$(env_value SYNC_IMAGE)" = "syncstorage-rs-postgres" ] && ! env_has SYNC_POSTGRES_IMAGE; then
        local pg_major=18 pg_volume
        if [ "$(env_value SYNC_DB_CONTAINERS)" != 0 ] && pg_volume=$(db_volume postgres-db) \
            && pg_volume=$(postgres_volume_major "${pg_volume}"); then
            pg_major=${pg_volume}
        fi
        set_value SYNC_POSTGRES_IMAGE "postgres:${pg_major}"
        echo "SYNC_POSTGRES_IMAGE=postgres:${pg_major}: the Sync database stays on PostgreSQL ${pg_major}. To move it to"
        echo "  a newer major: a dump and restore or pg_upgrade (docs/upgrading.md#postgresql)"
    fi
    # the accounts on MariaDB, from before FXA_MARIADB_IMAGE: on 11, they stay there (unset
    # it is now mariadb:lts, which would upgrade their data to 12 at the next start)
    if [ "$(env_value FXA_DB)" = mariadb ] && ! env_has FXA_MARIADB_IMAGE; then
        set_value FXA_MARIADB_IMAGE mariadb:11
        echo "FXA_MARIADB_IMAGE=mariadb:11: the accounts database stays on MariaDB 11. To move it to"
        echo "  MariaDB lts, 12 (a backup first, there is no way back): docs/upgrading.md#mariadb"
    fi
    # the accounts on MySQL, from before FXA_MYSQL_IMAGE: on 8 with mysql_native_password, they
    # stay there. Unset it is now mysql:lts (9), which would upgrade their data at the next start
    # (fxa-db refuses, db/mysql/keep-major.sh), and where their users, created with
    # mysql_native_password, could not log in at all. Your own server: the backups' client
    if [ "$(env_value FXA_DB)" != mariadb ] && fxa_installed && ! env_has FXA_MYSQL_IMAGE; then
        set_value FXA_MYSQL_IMAGE mysql:8
        env_has FXA_MYSQL_ARGS || set_value FXA_MYSQL_ARGS "${FXA_MYSQL_NATIVE_ARGS}"
        echo "FXA_MYSQL_IMAGE=mysql:8, FXA_MYSQL_ARGS=${FXA_MYSQL_NATIVE_ARGS}: the accounts database"
        echo "  stays on MySQL 8 with mysql_native_password. To move it to MySQL lts, 9 (its users first, a backup, no"
        echo "  way back): docs/upgrading.md#mysql-8-to-9"
    fi
    # Sync on MariaDB containers, from before SYNC_MARIADB_IMAGE (they ran mariadb:lts): on the
    # major their data holds, they stay there (unset, a pull after the next major would upgrade
    # it; the containers refuse that, db/mysql/keep-major.sh)
    if [ "$(env_value SYNC_DB)" != mysql ] && [ "$(env_value SYNC_IMAGE)" != "syncstorage-rs-postgres" ] \
        && [ "$(env_value SYNC_DB_CONTAINERS)" != 0 ] && ! env_has SYNC_MARIADB_IMAGE; then
        if major=$(sync_mariadb_major); then
            set_value SYNC_MARIADB_IMAGE "mariadb:${major}"
            echo "SYNC_MARIADB_IMAGE=mariadb:${major}: the Sync databases stay on MariaDB ${major}, the major of their data. To follow"
            echo "  MariaDB lts again (a backup first, there is no way back): SYNC_MARIADB_IMAGE=mariadb:lts (docs/upgrading.md#database-majors)"
        else
            echo "WARNING: could not read the MariaDB major of the Sync databases (no volume or running container found):"
            echo "  SYNC_MARIADB_IMAGE is not set; set it to the major they run, SYNC_MARIADB_IMAGE=mariadb:<major>. Until then the"
            echo "  containers refuse data of another major than mariadb:lts's (db/mysql/keep-major.sh)"
        fi
    fi
    # Sync on MySQL containers, from before SYNC_MYSQL_IMAGE: on 8, they stay there (unset it
    # is now mysql:lts, 9)
    if [ "$(env_value SYNC_DB)" = mysql ] && [ "$(env_value SYNC_DB_CONTAINERS)" != 0 ] && ! env_has SYNC_MYSQL_IMAGE; then
        set_value SYNC_MYSQL_IMAGE mysql:8
        echo "SYNC_MYSQL_IMAGE=mysql:8: the Sync databases stay on MySQL 8. To move them to MySQL lts, 9"
        echo "  (a backup first, there is no way back): docs/upgrading.md#mysql-8-to-9"
    fi
    # the Quadlets have no defaults of their own: every setting of .env-example in .env, as a
    # new setup writes it. A secret only when it is not there at all, the accounts' only
    # with the accounts (their placeholders say they are not set up)
    add_missing_settings() {
        local line key fxa=no added=() generated=()
        fxa_installed && fxa=yes
        # (an .env without a line end at its end)
        [ -z "$(tail -c 1 "${env_file}")" ] || echo "" >> "${env_file}"
        while IFS= read -r line || [ -n "${line}" ]; do
            [[ "${line}" =~ ^[A-Z][A-Z0-9_]*= ]] || continue
            key=${line%%=*}
            env_has "${key}" && continue
            case "${key}" in
                # the units of an .env from before it ran the accounts on this host's architecture
                FXA_ARCH) line="FXA_ARCH=$(host_arch)" ;;
            esac
            if [[ "${line}" == *"<REPLACE_WITH_SOMETHING_SECURE>"* ]] && { [[ "${key}" != FXA_* ]] || [ "${fxa}" = yes ]; }; then
                line="${key}=$(generate_random_string 32)"
                generated+=("${key}")
            else
                added+=("${key}")
            fi
            printf '%s\n' "${line}" >> "${env_file}"
            changed+=("${key}")
        done < "${SCRIPT_DIR}/.env-example"
        [ "${#added[@]}" = 0 ] || echo "Added from .env-example, with their defaults: ${added[*]}"
        [ "${#generated[@]}" = 0 ] || echo "Generated, as they were not in .env: ${generated[*]}"
    }
    [ "${quadlets}" = yes ] && add_missing_settings
    old_names_in_environment
    if [ "${#changed[@]}" = 0 ]; then
        rm -f "${env_file}"
        echo "Nothing to add: ${dot_env} has every setting of this release."
    else
        backup=$(backup_name "${dot_env}.before-upgrade")
        private_copy "${dot_env}" "${backup}" || { echo "ERROR: could not keep ${dot_env} as ${backup}: .env not changed"; rm -f "${env_file}"; exit 1; }
        replace_env "${env_file}" "${dot_env}" || exit 1
        echo "Updated ${dot_env} (the old one is $(basename "${backup}")): ${changed[*]}"
    fi
    unset ENV_READ
    # the passwords: this user only
    chmod 600 "${dot_env}"
    # your own database server: the SQL of this release, which the stack applies itself at the
    # next start with SYNC_DB_BOOTSTRAP_USER (FXA_DB_BOOTSTRAP_USER), or checks (the choice of
    # the setup, kept: nothing asked)
    # (the files of before kept as <file>.before-upgrade-<UTC time>, as .env)
    if [ "$(env_value SYNC_DB_CONTAINERS)" = 0 ]; then
        keep_previous_sql "${SCRIPT_DIR}/database-setup.sql" || exit 1
        if [ "$(env_value SYNC_IMAGE)" = "syncstorage-rs-postgres" ]; then render_sync_sql postgres; else render_sync_sql mariadb; fi || exit 1
        if [ -n "$(env_value SYNC_DB_BOOTSTRAP_USER)" ]; then
            echo "Your own database server: the stack applies the setup migrations it lacks itself at the next start, as $(env_value SYNC_DB_BOOTSTRAP_USER) (SYNC_DB_BOOTSTRAP_USER, docs/databases.md#let-the-stack-apply-them)."
        else
            echo "Your own database server: the next start stops at db-bootstrap if it lacks setup migrations of this release, naming them: run database-setup.sql there first, as its administrator (all of them, those it has change nothing; docs/databases.md#when-a-release-needs-new-users-or-grants)."
        fi
    fi
    if fxa_installed && [ "$(env_value FXA_DB_CONTAINERS)" = 0 ]; then
        keep_previous_sql "${SCRIPT_DIR}/database-setup-fxa.sql" || exit 1
        render_fxa_sql "$([ "$(env_value FXA_DB)" = mariadb ] && echo mariadb || echo mysql)" \
            "$([ "$(env_value FXA_DB)" != mariadb ] && [[ "$(env_value FXA_MYSQL_ARGS)" == *mysql_native_password* ]] && echo native)" || exit 1
        if [ -n "$(env_value FXA_DB_BOOTSTRAP_USER)" ]; then
            echo "The accounts on your own database server: the stack applies the setup migrations it lacks itself at the next start, as $(env_value FXA_DB_BOOTSTRAP_USER) (FXA_DB_BOOTSTRAP_USER)."
        else
            echo "The accounts on your own database server: run database-setup-fxa.sql there first, as its administrator, when the next start stops at fxa-db-bootstrap naming setup migrations it lacks (docs/databases.md#when-a-release-needs-new-users-or-grants)."
        fi
    fi
    fxa_mariadb_image_check
    fxa_installed && UPGRADING=yes fxa_mysql_image_check
    if [ "${quadlets}" = yes ]; then
        # the units of this install: the accounts' with them, the admin UI's when it is on
        SELF_HOST_FXA=no ADMIN_UI=no
        # shellcheck disable=SC2034 # (read by render_units, setup/quadlets.sh)
        fxa_installed && SELF_HOST_FXA=yes
        case ",$(env_plain COMPOSE_PROFILES)," in *,admin,*) ADMIN_UI=yes ;; esac
        [ -f "${QUADLET_DIR}/firefox-sync-admin.container" ] && ADMIN_UI=yes
        echo ""
        echo "Rendering the Quadlet units from ${dot_env}..."
        render_units
        echo ""
        echo "Then: the new images (podman does not pull a tag it has),"
        echo "  grep -h '^Image=' ${QUADLET_DIR}/firefox-sync-*.container | cut -d= -f2 | sort -u | xargs -n1 podman pull"
        if [ -n "${UNITS_CHANGED// /}" ]; then
            echo "  and start the units again: stopped, systemctl --user start$([ "${ADMIN_UI}" = yes ] && echo " firefox-sync-admin.service") firefox-sync-syncstorage.service"
            echo "  (running: systemctl --user restart of the units changed above)"
        fi
    else
        echo "Then: docker compose pull && docker compose up -d"
    fi
    exit 0
}
