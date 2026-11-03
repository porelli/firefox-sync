# shellcheck shell=bash
# prepare_environment.sh: the ports of this host the stack publishes for your reverse proxy (the
# *_EXPORT_PORT settings of .env): which of them something else listens on already, and the next
# free one instead. What listens: ss when it is there, else a connection with bash's /dev/tcp
# (to the loopback addresses only, nothing known otherwise: then a port counts as free); what
# this stack's own running containers publish counts as free (an install running, set up again
# or upgraded). Only the host ports: inside the stack the containers reach each other at their
# own ports (fxa-auth:9000...), which never change. Sourced by prepare_environment.sh: functions
# and tables only.

# the published ports, in the order the setup chooses them: <setting>|<id of its question>|<what>
EXPORT_PORTS=(
    "SYNC_EXPORT_PORT|sync_listen|the Sync server"
    "ADMIN_EXPORT_PORT|admin_listen|the admin UI"
    "FXA_CONTENT_EXPORT_PORT|fxa_content_listen|the accounts pages"
    "FXA_AUTH_EXPORT_PORT|fxa_auth_listen|the accounts API"
    "FXA_PROFILE_EXPORT_PORT|fxa_profile_listen|the accounts profile server"
    "FXA_PROFILE_STATIC_EXPORT_PORT|fxa_profile_static_listen|the avatars (the profile's static server)"
    "ADMIN_GATE_EXPORT_PORT|admin_gate_listen|the sign-up gate of the admin UI"
    "FXA_PAIRING_EXPORT_PORT|pairing_listen|the pairing server"
)
# export_port_what <setting>: what listens there
export_port_what() {
    local e
    for e in "${EXPORT_PORTS[@]}"; do [ "${e%%|*}" = "${1}" ] && { e=${e#*|}; printf '%s' "${e#*|}"; return; }; done
}
# export_ports_published <fxa yes|no> <admin yes|no> <pairing yes|no>: the settings of the ports
# the stack publishes with these choices, separated by spaces
export_ports_published() {
    local list="SYNC_EXPORT_PORT"
    [ "${2}" = yes ] && list="${list} ADMIN_EXPORT_PORT"
    [ "${1}" = yes ] && list="${list} FXA_CONTENT_EXPORT_PORT FXA_AUTH_EXPORT_PORT FXA_PROFILE_EXPORT_PORT FXA_PROFILE_STATIC_EXPORT_PORT"
    [ "${1}" = yes ] && [ "${2}" = yes ] && list="${list} ADMIN_GATE_EXPORT_PORT"
    [ "${1}" = yes ] && [ "${3}" = yes ] && list="${list} FXA_PAIRING_EXPORT_PORT"
    printf '%s' "${list}"
}

# port_split <[address:]port>: PORT_ADDR (empty: every interface, as compose takes a port alone)
# and PORT_NUM
port_split() {
    case "${1}" in
        \[*\]:*) PORT_ADDR=${1%:*} PORT_NUM=${1##*:} ;;
        *:*) PORT_ADDR=${1%:*} PORT_NUM=${1##*:} ;;
        *) PORT_ADDR="" PORT_NUM=${1} ;;
    esac
}
# port_join <address> <port>: [address:]port again
port_join() { printf '%s' "${1:+${1}:}${2}"; }

# host_listeners: what listens on TCP here, "<address> <port>" a line (the address without its
# brackets and %interface; * for every interface), in FFS_LISTENERS; FFS_LISTEN_HOW is ss, or
# tcp when only connections can tell (ss missing or failing). Once per run
host_listeners() {
    local out line local_addr addr port
    [ -n "${FFS_LISTEN_HOW:-}" ] && return 0
    FFS_LISTENERS="" FFS_LISTEN_HOW=tcp
    command -v ss > /dev/null 2>&1 && out=$(ss -Hltn 2> /dev/null) || return 0
    FFS_LISTEN_HOW=ss
    while read -r _ _ _ local_addr _; do
        [ -n "${local_addr}" ] || continue
        port=${local_addr##*:} addr=${local_addr%:*}
        addr=${addr#\[} addr=${addr%\]} addr=${addr%%\%*}
        case "${addr}" in 0.0.0.0|::|"*") addr="*" ;; esac
        FFS_LISTENERS="${FFS_LISTENERS}${addr} ${port}"$'\n'
    done <<< "${out}"
}
# own_ports: the host ports this stack's running containers publish (its compose project's,
# docker and podman; the Quadlets' firefox-sync-* containers), separated by spaces, in
# FFS_OWN_PORTS. FFS_OWN_KNOWN: no when a runtime is there that could not be asked (its daemon
# down, no permission). Once per run
own_ports() {
    local runtime out entry ports=" " project first last
    [ -n "${FFS_OWN_KNOWN:-}" ] && return 0
    FFS_OWN_KNOWN=yes FFS_OWN_PORTS=""
    project=$(compose_project)
    for runtime in docker podman; do
        command -v "${runtime}" > /dev/null 2>&1 || continue
        if ! out=$("${runtime}" ps --filter "label=com.docker.compose.project=${project}" --format '{{.Ports}}' 2> /dev/null); then
            FFS_OWN_KNOWN=no
            continue
        fi
        [ "${runtime}" = podman ] && out="${out}"$'\n'$(podman ps --filter name=^firefox-sync- --format '{{.Ports}}' 2> /dev/null)
        # 127.0.0.1:9000->9000/tcp, [::]:5000->8000/tcp, :::5000->8000/tcp, and consecutive
        # ones as a range: 127.0.0.1:8090-8091->8080-8081/tcp
        for entry in $(printf '%s' "${out}" | tr ',' ' '); do
            case "${entry}" in *"->"*) ;; *) continue ;; esac
            entry=${entry%%->*} entry=${entry##*:}
            [[ "${entry}" =~ ^([0-9]+)(-([0-9]+))?$ ]] || continue
            first=${BASH_REMATCH[1]} last=${BASH_REMATCH[3]:-${BASH_REMATCH[1]}}
            [ "$((last - first))" -le 1000 ] || continue
            while [ "${first}" -le "${last}" ]; do
                case "${ports}" in *" ${first} "*) ;; *) ports="${ports}${first} " ;; esac
                first=$((first + 1))
            done
        done
    done
    ports=${ports# }
    FFS_OWN_PORTS=${ports% }
}
# addr_overlap <address> <listener's address>: binding the first fails while the second listens
# (an address empty or * is every interface; [::] also has IPv4, as Linux binds it by default)
addr_overlap() {
    local a=${1#\[} b=${2}
    a=${a%\]}
    case "${a}" in ""|0.0.0.0|::) a="*" ;; esac
    [ "${a}" = "*" ] || [ "${b}" = "*" ] || [ "${a}" = "${b}" ] && return 0
    # 127.0.0.1 and ::ffff:127.0.0.1
    [ "${b#::ffff:}" = "${a}" ]
}
# port_busy <[address:]port>: something that is not this stack listens there already. Not known
# (no ss, an address /dev/tcp is not tried on): free
port_busy() {
    local addr port target line
    port_split "${1}"
    addr=${PORT_ADDR} port=$((10#${PORT_NUM}))
    own_ports
    case " ${FFS_OWN_PORTS} " in *" ${port} "*) return 1 ;; esac
    host_listeners
    if [ "${FFS_LISTEN_HOW}" = ss ]; then
        while IFS= read -r line; do
            [ -n "${line}" ] && [ "${line##* }" = "${port}" ] || continue
            addr_overlap "${addr}" "${line% *}" && return 0
        done <<< "${FFS_LISTENERS}"
        return 1
    fi
    # a connection: to the loopback address of that interface (a connection to another address
    # could wait a long time for an answer)
    case "${addr}" in
        ""|0.0.0.0|"[::]") target=127.0.0.1 ;;
        127.*) target=${addr} ;;
        "[::1]") target=::1 ;;
        *) return 1 ;;
    esac
    (exec 3<> "/dev/tcp/${target}/${port}") 2> /dev/null
}
# port_free_from <[address:]port> <taken ports, separated by spaces>: the first [address:]port
# from it on (its address, the next ports) that is not busy, nor taken by another of the
# stack's; printed (the same when it is free). Fails after 100 ports
port_free_from() {
    local addr port n=0
    port_split "${1}"
    addr=${PORT_ADDR} port=$((10#${PORT_NUM}))
    while [ "${n}" -lt 100 ] && [ "${port}" -le 65535 ]; do
        case " ${2} " in
            *" ${port} "*) ;;
            *) port_busy "$(port_join "${addr}" "${port}")" || { port_join "${addr}" "${port}"; return 0; } ;;
        esac
        port=$((port + 1)) n=$((n + 1))
    done
    return 1
}
# port_moved_note <setting> <wanted> <chosen>: what is said when the wanted port was in use
port_moved_note() {
    port_split "${2}"
    printf '%s is in use on this host: %s listens on %s' "${PORT_NUM}" "$(export_port_what "${1}")" "${3}"
}
