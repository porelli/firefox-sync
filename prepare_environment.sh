#!/bin/bash

# Firefox Sync Environment Preparation Script
# Supports both Docker and Podman
#
#   ./prepare_environment.sh                    the setup: questions, then .env and the examples
#   ./prepare_environment.sh --answers FILE     the same, the answers of FILE not asked (docs/install/compose.md#answers-by-name)
#   ./prepare_environment.sh --non-interactive  nothing asked: the answers given (FILE, FFS_SETUP_<ID>), defaults for the rest
#   ./prepare_environment.sh --upgrade          .env (and the Quadlet units) of an install, for this release
#   ./prepare_environment.sh --render-units [--fresh]  the Quadlet units again from .env
#
# The code is in setup/ (env.sh, images.sh, databases.sh, validate.sh, quadlets.sh, upgrade.sh,
# questions.sh, the questions, and setup.sh, what it writes), next to this script's real path
# (a symlink to it works too).
# Sourced (tests/prepare_functions.sh, tests/fxa_fix.sh): the functions only, nothing runs.

# Bytes, not characters (tr of random bytes and of names, on macOS too), and the ranges of
# [a-z] in byte order: with LC_CTYPE=C alone, macOS's regex (bash 3.2's =~) and tr take a-z
# from a UTF-8 LC_COLLATE, where it takes in A-Z (valid_name accepted 'Sync')
export LC_CTYPE=C LC_COLLATE=C
# set by the script itself only (env_file_read): one exported in the shell would redirect every read of .env
unset ENV_READ

# where this script was started from (the default checkout of the setup and of --upgrade), and
# its real path, its symlinks followed (readlink without -f: macOS before 12.3 has none)
FFS_ENTRY_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
FFS_REAL=${BASH_SOURCE[0]} FFS_LINKS=0
while [ -L "${FFS_REAL}" ] && [ "${FFS_LINKS}" -lt 40 ]; do
    FFS_LINK=$(readlink "${FFS_REAL}") || break
    case "${FFS_LINK}" in /*) FFS_REAL=${FFS_LINK} ;; *) FFS_REAL=$(dirname "${FFS_REAL}")/${FFS_LINK} ;; esac
    FFS_LINKS=$((FFS_LINKS + 1))
done
# the checkout of this script (setup/, config/fxa/fixed-in), whatever directory the setup writes into
SELF_DIR=$( cd -- "$( dirname -- "${FFS_REAL}" )" &> /dev/null && pwd )
unset FFS_REAL FFS_LINK FFS_LINKS

# sourced (tests/prepare_functions.sh, tests/fxa_fix.sh): the functions only, below
FFS_SOURCED=""
(return 0 2> /dev/null) && FFS_SOURCED=yes
# the functions; a file missing stops here (sourced: the source fails)
# shellcheck source=setup/env.sh
source "${SELF_DIR}/setup/env.sh" || { [ -n "${FFS_SOURCED}" ] && return 1; exit 1; }
# shellcheck source=setup/images.sh
source "${SELF_DIR}/setup/images.sh" || { [ -n "${FFS_SOURCED}" ] && return 1; exit 1; }
# shellcheck source=setup/databases.sh
source "${SELF_DIR}/setup/databases.sh" || { [ -n "${FFS_SOURCED}" ] && return 1; exit 1; }
# shellcheck source=setup/validate.sh
source "${SELF_DIR}/setup/validate.sh" || { [ -n "${FFS_SOURCED}" ] && return 1; exit 1; }
# shellcheck source=setup/quadlets.sh
source "${SELF_DIR}/setup/quadlets.sh" || { [ -n "${FFS_SOURCED}" ] && return 1; exit 1; }
# shellcheck source=setup/upgrade.sh
source "${SELF_DIR}/setup/upgrade.sh" || { [ -n "${FFS_SOURCED}" ] && return 1; exit 1; }
# shellcheck source=setup/questions.sh
source "${SELF_DIR}/setup/questions.sh" || { [ -n "${FFS_SOURCED}" ] && return 1; exit 1; }
[ -n "${FFS_SOURCED}" ] && return 0

# the temporary files and their traps (setup/env.sh)
ffs_temp_init || exit 1

case "${1:-}" in
    --upgrade) upgrade_env ;;
    --render-units)
        case "${2:-}" in
            "") RENDER_UNITS=yes upgrade_env ;;
            --fresh) RENDER_UNITS=yes RENDER_FRESH=yes upgrade_env ;;
            *) echo "ERROR: --render-units [--fresh], not '${2}'"; exit 2 ;;
        esac ;;
esac

# the setup's options (read by setup/questions.sh)
# shellcheck disable=SC2034
while [ "$#" -gt 0 ]; do
    case "${1}" in
        --answers) [ -n "${2:-}" ] || { echo "ERROR: --answers FILE"; exit 2; }; FFS_ANSWERS=${2}; shift 2 ;;
        --answers=*) FFS_ANSWERS=${1#--answers=}; shift ;;
        --non-interactive) FFS_NONINTERACTIVE=yes; shift ;;
        -h|--help) sed -n '6,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "ERROR: unknown option '${1}' (--answers FILE, --non-interactive, --upgrade, --render-units [--fresh])"; exit 2 ;;
    esac
done
# shellcheck source=setup/setup.sh
source "${SELF_DIR}/setup/setup.sh"
