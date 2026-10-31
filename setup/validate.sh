# shellcheck shell=bash
# prepare_environment.sh: the checks of what the setup is given: addresses and ports, limits,
# database names and hosts. Sourced by prepare_environment.sh: functions only.

# an IPv4 address: four numbers up to 255
valid_ipv4() {
    local octet
    [[ "${1}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    for octet in ${1//./ }; do [ "$((10#${octet}))" -le 255 ] || return 1; done
}
# an IPv6 address (without the brackets): eight groups of 1 to 4 hex digits separated by
# colons, or fewer with one :: for the zeros; the last two groups may be an IPv4 address
valid_ipv6() {
    local ip=${1} last group groups=() n=0 max=8
    [[ "${ip}" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
    case "${ip}" in *:*:*) ;; *) return 1 ;; esac
    case "${ip}" in *:::*) return 1 ;; esac
    # a single colon at either end
    case "${ip}" in :[!:]*|*[!:]:) return 1 ;; esac
    if [[ "${ip}" == *::* ]]; then
        [[ "${ip#*::}" == *::* ]] && return 1
        max=7
    fi
    last=${ip##*:}
    if [[ "${last}" == *.* ]]; then
        valid_ipv4 "${last}" || return 1
        ip=${ip%"${last}"}0:0
    fi
    IFS=: read -r -a groups <<< "${ip}"
    for group in "${groups[@]}"; do
        [ -n "${group}" ] || continue
        [[ "${group}" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        n=$((n + 1))
    done
    if [ "${max}" = 8 ]; then [ "${n}" = 8 ]; else [ "${n}" -le 7 ]; fi
}
# [address:]port: an IPv4 address or an IPv6 one in brackets ([::]:5000), a port 1 to 65535
valid_export_port() {
    local port=${1} addr
    case "${1}" in
        \[*\]:*) addr=${1%\]:*} port=${1##*\]:}; valid_ipv6 "${addr#\[}" || return 1 ;;
        *:*) addr=${1%:*} port=${1##*:}; valid_ipv4 "${addr}" || return 1 ;;
    esac
    [[ "${port}" =~ ^[0-9]{1,5}$ ]] && [ "$((10#${port}))" -ge 1 ] && [ "$((10#${port}))" -le 65535 ]
}

# a limit of accounts: a number (0: nobody new) or unlimited
valid_limit() {
    case "${2}" in
        unlimited) ;;
        ''|*[!0-9]*) echo "ERROR: ${1} must be a number or unlimited, got '${2}'"; exit 1 ;;
        *) [ "${#2}" -le 10 ] && [ "${2}" -le 2147483647 ] || { echo "ERROR: ${1} must be at most 2147483647, got '${2}'"; exit 1; } ;;
    esac
}
# names end up unquoted in SQL and in the database URLs
valid_name() { [[ "${1}" =~ ^[a-z_][a-z0-9_]{0,31}$ ]] || { echo "ERROR: not a valid database or user name (a-z, 0-9, _): '${1}'"; exit 1; }; }
# a user of the stack on your own server: a name, none of the server's own accounts or roles
# (db/db-setup.sh refuses them too: its bootstrap creates and changes the stack's users only)
valid_user() {
    valid_name "${1}"
    case "${1}" in
        root|mysql|healthcheck|mariadb_sys|mysql_sys|postgres|public)
            echo "ERROR: '${1}' is a name of the database server's own accounts: choose another user for the stack"; exit 1 ;;
    esac
}
# the containers reach the server over the network: localhost is the container itself
valid_host() {
    case "${1}" in
        "") echo "ERROR: the database host is required"; exit 1 ;;
        localhost|127.*|0.0.0.0)
            echo "ERROR: '${1}' would be the container itself: use an address of this host the containers"
            echo "  can reach (e.g. 172.17.0.1 for Docker, host.containers.internal for Podman), see docs/databases.md#server-requirements"
            exit 1 ;;
        # IPv6 literals would need [ ] in the database URLs, which not every client parses
        *:*) echo "ERROR: '${1}': use a host name or an IPv4 address (no IPv6 address)"; exit 1 ;;
        *[!A-Za-z0-9._-]*) echo "ERROR: not a host name: '${1}'"; exit 1 ;;
    esac
}
valid_port() { case "${1}" in ''|*[!0-9]*) echo "ERROR: not a port: '${1}'"; exit 1 ;; esac; }
