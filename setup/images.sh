# shellcheck shell=bash
# prepare_environment.sh: the accounts images and the fixes of upstream-patches.yml they have
# (their labels, config/fxa/fixed-in, the version comparison), the checks of FXA_MARIADB_IMAGE
# and FXA_MYSQL_IMAGE against them, this host's architecture. Sourced by prepare_environment.sh:
# functions only.

# Accounts images and the upstream pull requests of upstream-patches.yml they need: MariaDB 12
# and later (FXA_MARIADB_IMAGE=mariadb:lts, the default) need mozilla/fxa#21494, MySQL 9
# (FXA_MYSQL_IMAGE=mysql:lts, the default) and MySQL without mysql_native_password need
# mozilla/fxa#21709 (the mysql2 driver). An image has one when its label
# org.firefox-sync.upstream-patches lists it (ours, while Mozilla has not released it), or when
# it is of the release that has it or a later one (config/fxa/fixed-in, once Mozilla released
# it: every image then, Mozilla's too; its release from the label org.opencontainers.image.version,
# else from the tag). Mozilla's (docker.io/mozilla/fxa-mono) and ours built before have no
# label. The local image first (what starts), then the registry (docker buildx imagetools or
# skopeo). Here and not in the admin UI, which cannot inspect images
# a label of the JSON of an image (docker or podman inspect, buildx imagetools, skopeo)
json_label() { grep -o "\"${1//./\\.}\": *\"[^\"]*\"" | head -n 1 | sed 's/.*: *"//; s/"$//'; }
fxa_image_inspect_local() {
    local image=${1} runtime out runtimes="docker podman"
    # the store of what runs the units: Podman's for the Quadlets (also on a host with Docker)
    [ "${DEPLOY_METHOD:-}" = quadlets ] && runtimes=podman
    for runtime in ${runtimes}; do
        command -v "${runtime}" > /dev/null 2>&1 || continue
        out=$(${runtime} image inspect "${image}" 2> /dev/null) && { printf '%s' "${out}"; return 0; }
    done
    return 1
}
fxa_image_inspect_remote() {
    local image=${1} out
    out=$(docker buildx imagetools inspect "${image}" --format '{{json .Image}}' 2> /dev/null) \
        || out=$(skopeo inspect "docker://${image}" 2> /dev/null) || return 1
    printf '%s' "${out}"
}
# has_fxa_patch <pull request> <label>: e.g. mozilla/fxa#21494 in "mozilla/fxa#21494@517651a..aa0b178 ..."
# Our images built before Mozilla merged the mysql2 switch (mozilla/fxa#21709) list our own pull
# request for it, mozilla/fxa#21554, instead: the same driver
has_fxa_patch() {
    case " ${2} " in *" ${1}@"*) return 0 ;; esac
    [ "${1}" = mozilla/fxa#21709 ] && case " ${2} " in *" mozilla/fxa#21554@"*) return 0 ;; esac
    return 1
}
# fxa_fixed_in <pull request>: the first accounts release with it, once Mozilla released it
# (config/fxa/fixed-in of this checkout), nothing before
fxa_fixed_in() {
    local pr release rest file=${SELF_DIR}/config/fxa/fixed-in
    [ -f "${file}" ] || return 0
    while read -r pr release rest || [ -n "${pr}" ]; do
        [ "${pr}" = "${1}" ] && { printf '%s' "${release}"; return 0; }
    done < "${file}"
    return 0
}
# fxa_release <version or tag>: the release, 1.347.3 of v1.347.3, fxa-mono-v1.347.3 or
# 1.347.3; nothing for another tag (fxa-mono-latest, a digest...)
fxa_release() {
    local v=${1#fxa-mono-}
    v=${v#v}
    [[ "${v}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && printf '%s' "${v}"
    return 0
}
# version_at_least <a> <b>: release a is b or later, part by part (1.350.0 after 1.347.10)
version_at_least() {
    local a=${1} b=${2} x y
    while [ -n "${a}${b}" ]; do
        x=${a%%.*} y=${b%%.*}
        x=$((10#${x:-0})) y=$((10#${y:-0}))
        [ "${x}" -gt "${y}" ] && return 0
        [ "${x}" -lt "${y}" ] && return 1
        [[ "${a}" == *.* ]] && a=${a#*.} || a=""
        [[ "${b}" == *.* ]] && b=${b#*.} || b=""
    done
    return 0
}
# fxa_has_fix <pull request> <patches label> <version label> <tag>: whether an accounts
# image with these has it: 0 yes, 1 no, 2 not known (released, but the image's release is not)
fxa_has_fix() {
    local fixed release
    has_fxa_patch "${1}" "${2}" && return 0
    fixed=$(fxa_release "$(fxa_fixed_in "${1}")")
    [ -n "${fixed}" ] || return 1
    release=$(fxa_release "${3}")
    [ -n "${release}" ] || release=$(fxa_release "${4}")
    [ -n "${release}" ] || return 2
    version_at_least "${release}" "${fixed}"
}
# the same for the JSON of an image <pull request> <json> <tag>
fxa_inspected_has() {
    fxa_has_fix "${1}" "$(printf '%s' "${2}" | json_label org.firefox-sync.upstream-patches)" \
        "$(printf '%s' "${2}" | json_label org.opencontainers.image.version)" "${3}"
}
# fxa_image_has <pull request>: whether the accounts image of .env (FXA_IMAGE:FXA_VERSION) has
# it: 0 yes, 1 no, 2 not known (no local copy and no answer of the registry). An older local
# copy without it while the registry's has it: yes, and FXA_IMAGE_PULL=yes (pull before starting).
# Asked once per image and pull request (FXA_IMAGE_ANSWERS)
FXA_IMAGE_ANSWERS=""
fxa_image_has() {
    local pr=${1} image tag info remote rc answer
    tag=$(env_value FXA_VERSION)
    image=$(env_value FXA_IMAGE):${tag}
    for answer in ${FXA_IMAGE_ANSWERS}; do
        [ "${answer%=*}" = "${image}|${pr}" ] || continue
        rc=${answer##*=}; FXA_IMAGE_PULL=${rc#?}; return "${rc%"${FXA_IMAGE_PULL}"}"
    done
    FXA_IMAGE_PULL=""
    case "${image}" in
        # Mozilla's: without the label, until the release that has it
        mozilla/fxa-mono:*|docker.io/mozilla/fxa-mono:*|index.docker.io/mozilla/fxa-mono:*)
            [ -n "$(fxa_fixed_in "${pr}")" ] || rc=1 ;;
    esac
    if [ -n "${rc}" ]; then
        :
    # Quadlets of another architecture (--arch): the units pull the registry's at every
    # start, so that one is what runs
    elif [ "${DEPLOY_METHOD:-}" = quadlets ] && [ -n "$(env_plain FXA_ARCH)" ] && [ "$(env_plain FXA_ARCH)" != "$(host_arch)" ] \
        && info=$(fxa_image_inspect_remote "${image}"); then
        fxa_inspected_has "${pr}" "${info}" "${tag}"; rc=$?
    elif info=$(fxa_image_inspect_local "${image}"); then
        fxa_inspected_has "${pr}" "${info}" "${tag}"; rc=$?
        # an older local copy: the registry's may have it, then a pull is enough
        if [ "${rc}" != 0 ] && remote=$(fxa_image_inspect_remote "${image}") && fxa_inspected_has "${pr}" "${remote}" "${tag}"; then
            rc=0 FXA_IMAGE_PULL=yes
        fi
    elif info=$(fxa_image_inspect_remote "${image}"); then
        fxa_inspected_has "${pr}" "${info}" "${tag}"; rc=$?
    else
        # nothing to read: once released, the release of its tag says it; else not known
        fxa_has_fix "${pr}" "" "" "${tag}"; rc=$?
        [ "${rc}" = 1 ] && { [ -z "$(fxa_fixed_in "${pr}")" ] || [ -z "$(fxa_release "${tag}")" ]; } && rc=2
    fi
    FXA_IMAGE_ANSWERS="${FXA_IMAGE_ANSWERS} ${image}|${pr}=${rc}${FXA_IMAGE_PULL}"
    return "${rc}"
}
fxa_mariadb_image_check() {
    local db_image image rc
    [ "$(env_value FXA_DB)" = mariadb ] || return 0
    db_image=$(env_value FXA_MARIADB_IMAGE)
    db_image=${db_image:-mariadb:lts}
    # your own server: its version is not known here
    if [ "$(env_value FXA_DB_CONTAINERS)" != 0 ]; then
        case "${db_image##*:}" in 10|10.*|11|11.*) return 0 ;; esac
    fi
    image=$(env_value FXA_IMAGE):$(env_value FXA_VERSION)
    fxa_image_has mozilla/fxa#21494; rc=$?
    if [ "${rc}" = 0 ]; then
        if [ -n "${FXA_IMAGE_PULL}" ]; then
            echo "NOTE: your local ${image} does not have mozilla/fxa#21494, needed on MariaDB 12,"
            echo "  the registry's has it: pull it before starting (docker compose pull, podman pull)"
            echo ""
        fi
        return 0
    fi
    if [ "${rc}" = 2 ]; then
        echo "NOTE: could not read the labels of ${image}: MariaDB 12 needs an accounts image with mozilla/fxa#21494"
        echo "  (label org.firefox-sync.upstream-patches, see docs/accounts.md#mysql-or-mariadb)"
        echo ""
        return 0
    fi
    if [ "$(env_value FXA_DB_CONTAINERS)" = 0 ]; then
        echo "WARNING: if your MariaDB server is 12 or later, the accounts need an image with mozilla/fxa#21494,"
    else
        echo "WARNING: the accounts on MariaDB ${db_image##*:} (FXA_MARIADB_IMAGE=${db_image}) need an image with mozilla/fxa#21494,"
    fi
    echo "  which ${image} does not have (Mozilla's images, or ours built before it): on a new"
    echo "  database Mozilla's migrations stop. Use our images (FXA_IMAGE=ghcr.io/porelli/firefox-sync,"
    echo "  FXA_VERSION=fxa-mono-latest) or MariaDB 11 (FXA_MARIADB_IMAGE=mariadb:11), see docs/accounts.md#mysql-or-mariadb"
    echo ""
}
# the options of fxa-db (FXA_MYSQL_ARGS) for accounts images without mozilla/fxa#21709: their
# driver speaks mysql_native_password only, which MySQL 8.4 has off by default and MySQL 9 not
# at all (mysqld 9 refuses these options and does not start)
FXA_MYSQL_NATIVE_ARGS="--mysql-native-password=ON --authentication-policy=mysql_native_password"
# a MySQL image of major 8 (mysql:8, mysql:8.4, a registry before it)
mysql_8() { case "${1##*:}" in 8|8.*) return 0 ;; esac; return 1; }
# the accounts on MySQL in fxa-db: the image of .env, its options and the accounts image agree
fxa_mysql_image_check() {
    local db_image args image rc native=no
    [ "$(env_value FXA_DB)" != mariadb ] || return 0
    [ "$(env_value FXA_DB_CONTAINERS)" != 0 ] || return 0
    db_image=$(env_plain FXA_MYSQL_IMAGE); db_image=${db_image:-mysql:lts}
    args=$(env_plain FXA_MYSQL_ARGS)
    case " ${args} " in *" --mysql-native-password=ON "*) native=yes ;; esac
    image=$(env_value FXA_IMAGE):$(env_value FXA_VERSION)
    if ! mysql_8 "${db_image}" && [ "${native}" = yes ]; then
        echo "WARNING: FXA_MYSQL_ARGS has --mysql-native-password=ON, which MySQL ${db_image##*:} (FXA_MYSQL_IMAGE=${db_image})"
        echo "  refuses: fxa-db would not start. On MySQL 9 the accounts need an image with mozilla/fxa#21709 and"
        echo "  their users on caching_sha2_password first: docs/upgrading.md#mysql-8-to-9 (or FXA_MYSQL_IMAGE=mysql:8)"
        echo ""
        return 0
    fi
    fxa_image_has mozilla/fxa#21709; rc=$?
    if [ "${rc}" = 0 ]; then
        if [ -n "${FXA_IMAGE_PULL}" ] && ! { mysql_8 "${db_image}" && [ "${native}" = yes ]; }; then
            echo "WARNING: your local ${image} does not have mozilla/fxa#21709, without which the accounts cannot"
            echo "  log in on MySQL ${db_image##*:}; the registry's has it: pull it before starting (docker compose pull, podman pull)"
            echo ""
        elif [ "${native}" = yes ] && [ "${UPGRADING:-}" = yes ]; then
            echo "NOTE: ${image} has mozilla/fxa#21709 (caching_sha2_password): the accounts database can move"
            echo "  from MySQL 8 with mysql_native_password to MySQL lts, when you choose: docs/upgrading.md#mysql-8-to-9"
            echo ""
        elif mysql_8 "${db_image}" && [ "${UPGRADING:-}" = yes ]; then
            # (the users' plugins are not known here)
            echo "NOTE: fxa-db is on MySQL 8 without FXA_MYSQL_ARGS (mysql_native_password off): users created before on"
            echo "  mysql_native_password cannot log in. Moving from the pin: step 2 (the users) before step 3 (the options),"
            echo "  docs/upgrading.md#mysql-8-to-9; SELECT user, host, plugin FROM mysql.user shows them"
            echo ""
        fi
        return 0
    fi
    # without it: only mysql_native_password, on MySQL 8 with the options
    mysql_8 "${db_image}" && [ "${native}" = yes ] && return 0
    if [ "${rc}" = 2 ]; then
        echo "NOTE: could not read the labels of ${image}: MySQL ${db_image##*:} without mysql_native_password"
        echo "  needs an accounts image with mozilla/fxa#21709 (label org.firefox-sync.upstream-patches, docs/accounts.md#mysql-or-mariadb)"
        echo ""
        return 0
    fi
    echo "WARNING: the accounts on MySQL ${db_image##*:} (FXA_MYSQL_IMAGE=${db_image}${args:+, FXA_MYSQL_ARGS=${args}}) need an image"
    echo "  with mozilla/fxa#21709, which ${image} does not have (Mozilla's images, or ours built before it):"
    echo "  they cannot log in. Use our images (FXA_IMAGE=ghcr.io/porelli/firefox-sync, FXA_VERSION=fxa-mono-latest)"
    echo "  or FXA_MYSQL_IMAGE=mysql:8 with FXA_MYSQL_ARGS=${FXA_MYSQL_NATIVE_ARGS}"
    echo "  (on a new database only: MySQL 8 cannot open MySQL 9's data), see docs/accounts.md#mysql-or-mariadb"
    echo ""
}
# this host's architecture as the images name it
host_arch() { case "$(uname -m)" in aarch64|arm64) echo arm64 ;; *) echo amd64 ;; esac; }
