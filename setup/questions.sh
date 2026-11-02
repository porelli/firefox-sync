# shellcheck shell=bash
# (the variables of the answers are read by setup/setup.sh)
# shellcheck disable=SC2034
# prepare_environment.sh: the questions of the setup, one component at a time, as steps
# (SETUP_STEPS): each asks one question by its id, checks the answer and sets the variables
# setup.sh writes .env from. At any question `<` (or `back`) goes back to the one asked before,
# and the questions after it are asked again. An answer can also be given by its id, in an
# answers file (--answers FILE, the syntax of .env) or as FFS_SETUP_<ID> in the environment:
# then it is not asked. --non-interactive: what is not given takes its default. The ids and
# the answers they take: docs/install/compose.md#answers-by-name. Sourced by
# prepare_environment.sh: functions and tables only.

# the steps in their order; @...: the header of the questions after it
SETUP_STEPS=(
    "@Deployment: where and how the stack runs"
    dir existing runtime_none deploy container_user domain
    "@The Sync server"
    sync_url sync_listen sync_image_tag sync_db sync_db_own sync_db_host sync_db_port
    sync_db_name sync_db_user sync_tokenserver_db_name sync_tokenserver_db_user
    sync_storage_db_name sync_storage_db_user sync_db_bootstrap sync_db_bootstrap_user
    sync_db_bootstrap_password sync_max_users
    "@The accounts people sign in with"
    accounts sync_invite_only sync_allowed_accounts fxa_content_url fxa_auth_url fxa_profile_url
    fxa_db fxa_db_own fxa_db_host fxa_db_port fxa_db_user fxa_db_policy_user fxa_db_bootstrap
    fxa_db_bootstrap_user fxa_db_bootstrap_password smtp_host smtp_port smtp_user smtp_password
    smtp_sender fxa_signups fxa_max_accounts fxa_account_events pairing pairing_url
    "@The admin UI"
    admin admin_signin admin_url admin_oidc_issuer admin_oidc_client_id admin_oidc_client_secret
    admin_oidc_name admin_oidc_scopes admin_auth_header admin_auth_groups_header admin_trusted_proxies
    admin_users admin_groups admin_password admin_notify
    "@Backups"
    backups
    "@Reverse proxy"
    proxy proxy_admin_allow caddy_email caddy_ca caddy_http_port caddy_https_port traefik_network
    traefik_entrypoints traefik_http_entrypoint traefik_certresolver
    "@Review"
    confirm
)
# --answers FILE, --non-interactive (prepare_environment.sh); the terminal's (ui_init)
FFS_ANSWERS="" FFS_NONINTERACTIVE="" FFS_TTY="" UI_BOLD="" UI_DIM="" UI_REV="" UI_RED="" UI_OFF=""
FFS_SECTION="" FFS_SECTION_SHOWN="" FFS_HINT="" FFS_REPLAY_AFTER="" FFS_STEP="" FFS_STEP_INDEX=0

lower() { printf '%s' "${1}" | tr '[:upper:]' '[:lower:]'; }
# the ids of the questions, one per line
setup_ids() {
    local step
    for step in "${SETUP_STEPS[@]}"; do case "${step}" in @*) ;; *) printf '%s\n' "${step}" ;; esac; done
}
# check_answers: the answers file and the FFS_SETUP_* of the environment name questions there
# are (a typo would otherwise be asked, or take its default, without a word)
check_answers() {
    local ids key bad=() line perms
    ids=" $(setup_ids | tr '\n' ' ') "
    if [ -n "${FFS_ANSWERS}" ]; then
        [ -f "${FFS_ANSWERS}" ] && [ -r "${FFS_ANSWERS}" ] || { echo "ERROR: no answers file ${FFS_ANSWERS}"; exit 2; }
        while IFS= read -r line || [ -n "${line}" ]; do
            line=${line%$'\r'}
            [[ "${line}" =~ ^[[:space:]]*(#.*)?$ ]] && continue
            # shellcheck disable=SC2153 # (ENV_LEAD: setup/env.sh)
            key=$(printf '%s\n' "${line}" | sed -n "s/^${ENV_LEAD}\([A-Za-z_][A-Za-z0-9_]*\)=.*/\2/p")
            if [ -z "${key}" ]; then bad+=("not id=value: ${line}"); continue; fi
            case "${ids}" in *" ${key} "*) ;; *) bad+=("${key}") ;; esac
        done < "${FFS_ANSWERS}"
        # the passwords in it: this user's only
        perms=$(ls -ld "${FFS_ANSWERS}" 2> /dev/null)
        if [ "${perms:7:1}" = r ] && grep -qE "^${ENV_LEAD}(smtp_password|[a-z_]*bootstrap_password|admin_oidc_client_secret|admin_notify)=" "${FFS_ANSWERS}"; then
            echo "NOTE: ${FFS_ANSWERS} has passwords and other users can read it: chmod 600 ${FFS_ANSWERS}"
        fi
    fi
    while IFS= read -r key; do
        [ -n "${key}" ] || continue
        case "${ids}" in *" $(lower "${key#FFS_SETUP_}") "*) ;; *) bad+=("${key} (environment)") ;; esac
    done < <(compgen -e | grep '^FFS_SETUP_')
    if [ "${#bad[@]}" != 0 ]; then
        echo "ERROR: answers for no question of the setup (docs/install/compose.md#answers-by-name):"
        printf '  %s\n' "${bad[@]}"
        exit 2
    fi
}
# answer_given <id>: the answer given for it, in ANSWER: FFS_SETUP_<ID> of the environment,
# else the answers file. Fails when neither has one
answer_given() {
    local var
    var=FFS_SETUP_$(printf '%s' "${1}" | tr '[:lower:]' '[:upper:]')
    if printenv "${var}" > /dev/null; then
        ANSWER=$(printenv "${var}")
        return 0
    fi
    [ -n "${FFS_ANSWERS}" ] || return 1
    ENV_READ=${FFS_ANSWERS} env_has "${1}" || return 1
    ANSWER=$(ENV_READ=${FFS_ANSWERS} env_plain "${1}")
}

# --- the terminal: menus with the arrow keys and answers edited in place on a terminal (stdin
# and stdout), plain numbered lists and prompts otherwise (a pipe, a log); bash 3.2 has no
# read -i, there the default is shown in [brackets] instead
ui_init() {
    FFS_TTY="" UI_BOLD="" UI_DIM="" UI_REV="" UI_RED="" UI_OFF=""
    [ -z "${FFS_NONINTERACTIVE}" ] && [ -t 0 ] && [ -t 1 ] && FFS_TTY=yes
    if [ -n "${FFS_TTY}" ] && [ "${TERM:-dumb}" != dumb ]; then
        UI_BOLD=$'\e[1m' UI_DIM=$'\e[2m' UI_REV=$'\e[7m' UI_RED=$'\e[31m' UI_OFF=$'\e[0m'
    fi
}
# an ERROR said in red on a terminal
ui_error() { printf '%sERROR: %s%s\n' "${UI_RED}" "${1}" "${UI_OFF}"; }
# the header of the part of the next question, once, and its hint
ui_header() {
    if [ -z "${FFS_SECTION_SHOWN}" ]; then
        printf '\n%s%s%s\n' "${UI_BOLD}" "${FFS_SECTION}" "${UI_OFF}"
        FFS_SECTION_SHOWN=yes
    fi
    [ -z "${FFS_HINT}" ] || printf '%s\n' "${FFS_HINT}" | sed "s/^/  ${UI_DIM}/; s/\$/${UI_OFF}/"
    # (once: not again when the question is asked again after an invalid answer)
    FFS_HINT=""
}

# hint <text>: what the next question means, said before it (only when it is asked)
hint() { FFS_HINT=${FFS_HINT:+${FFS_HINT}$'\n'}${1}; }
# replayed <id> <default>: after a part was changed in the review, a later question asked before
# takes its answer of before again, without asking (the default when it took the default: one
# that follows from the changed part, a domain's host names); in ANSWER
replayed() {
    local seen=FFS_SEEN_${1} typed=FFS_TYPED_${1}
    [ -n "${FFS_REPLAY_AFTER}" ] && [ "${FFS_STEP_INDEX}" -ge "${FFS_REPLAY_AFTER}" ] && [ -n "${!seen:-}" ] || return 1
    ANSWER=${!typed:-${2}} FFS_REPLAYED_NOW=yes
    [ -n "${!typed:-}" ] || FFS_DEFAULTED=yes
}
# ask <id> <question> <default> [secret|yn]: the answer in ANSWER, the default for an empty
# one (and at the end of the input). Given by its id: that, nothing asked. Typed: `<` or
# `back` returns 2 (run_steps goes back). secret: not shown; yn: the default is yes or no,
# shown as (Y/n) or (y/N)
ask() {
    local id=${1} question=${2} default=${3} kind=${4:-} var shown reply=""
    FFS_ASKED_NOW="" FFS_REPLAYED_NOW="" FFS_DEFAULTED=""
    if answer_given "${id}"; then
        [ -n "${ANSWER}" ] || FFS_DEFAULTED=yes
        ANSWER=${ANSWER:-${default}}
        return 0
    fi
    if [ -n "${FFS_NONINTERACTIVE}" ]; then
        ANSWER=${default} FFS_DEFAULTED=yes
        return 0
    fi
    replayed "${id}" "${default}" && return 0
    # the answer typed before going back to it: the default now
    var=FFS_TYPED_${id}
    [ -n "${!var:-}" ] && default=${!var}
    ui_header
    case "${kind}" in
        yn) [ "${default}" = yes ] && shown=" (Y/n, < back): " || shown=" (y/N, < back): " ;;
        secret) [ -n "${default}" ] && shown=" [as typed before] (< back): " || shown=" (< back): " ;;
        *)
            # (edited in place where read -i is there)
            if [ -n "${FFS_TTY}" ] && [ "${BASH_VERSINFO[0]}" -ge 4 ]; then shown=" (< back): "
            elif [ -n "${default}" ]; then shown=" [${default}] (< back): "
            else shown=" (< back): "; fi ;;
    esac
    # (readline counts the width of its prompt without what is between \001 and \002)
    if [ -n "${UI_BOLD}" ]; then shown=$'\001'"${UI_BOLD}"$'\002'"${question}"$'\001'"${UI_OFF}"$'\002'"${shown}"; else shown="${question}${shown}"; fi
    if [ -n "${FFS_TTY}" ]; then
        if [ "${kind}" = secret ]; then
            read -r -s -p "${shown}" reply; echo ""
        elif [ "${kind}" != yn ] && [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
            read -r -e -i "${default}" -p "${shown}" reply
        else
            read -r -e -p "${shown}" reply
        fi
    else
        printf '%s\n' "${shown}"
        read -r reply
    fi
    FFS_ASKED=yes FFS_ASKED_NOW=yes
    printf -v "FFS_SEEN_${id}" '%s' yes
    reply=${reply%$'\r'}
    case "$(lower "${reply}" | tr -d '[:space:]')" in "<"|back) return 2 ;; esac
    # (edited in place: the default as it was is no answer typed)
    if [ -n "${reply}" ] && [ "${reply}" != "${3}" ]; then printf -v "${var}" '%s' "${reply}"; else unset "${var}"; fi
    # (edited in place, the default unchanged is the default too)
    [ -n "${reply}" ] && [ "${reply}" != "${default}" ] || FFS_DEFAULTED=yes
    ANSWER=${reply:-${default}}
}
# after an invalid answer, its ERROR said: asked again when it was typed at a terminal (or it
# was an answer of before taken again); else (given by its id, or the input is no terminal)
# the setup stops, nothing written
retry() {
    if [ -n "${FFS_REPLAYED_NOW}" ]; then unset "FFS_SEEN_${FFS_STEP}"; return 0; fi
    [ -n "${FFS_ASKED_NOW}" ] && [ -n "${FFS_TTY}" ] && return 0
    exit 1
}
# yes_no <answer> <default yes|no>: yes or no in YN
yes_no() {
    case "$(lower "${1}")" in
        y|yes) YN=yes ;; n|no) YN=no ;; "") YN=${2} ;;
        *) ui_error "yes or no, not '${1}'"; return 1 ;;
    esac
}
# ask_yn <id> <question> <default yes|no>: YN, asked again until it is yes or no
ask_yn() {
    while :; do
        ask "${1}" "${2}" "${3}" yn || return
        yes_no "${ANSWER}" "${3}" && return 0
        retry
    done
}
# choice <answer> <option>...: the option the answer names, by its name, its number or an alias
# of MENU_ALIASES ("alias=option ..."), in CHOICE
choice() {
    local given=${1} answer n=1 option alias
    answer=$(lower "${1}")
    for alias in ${MENU_ALIASES:-}; do [ "${answer}" = "${alias%%=*}" ] && answer=${alias#*=}; done
    shift
    for option in "$@"; do
        if [ "${answer}" = "${option}" ] || [ "${answer}" = "${n}" ]; then CHOICE=${option}; return 0; fi
        n=$((n + 1))
    done
    ui_error "one of $(echo "$@" | sed 's/ /, /g'), not '${given}'"
    return 1
}
# menu_key <key> <selected> <count>: what a key does in a menu, printed: the option selected
# after it (0-based), "pick <n>", "back", or "" for a key it ignores. Keys: up and down (the
# arrows' escape sequences, k j), Enter (empty), a number picks that option, < goes back
menu_key() {
    local key=${1} sel=${2} n=${3}
    case "${key}" in
        $'\e[A'|$'\eOA'|k) [ "${sel}" -gt 0 ] && sel=$((sel - 1)) || sel=$((n - 1)); echo "${sel}" ;;
        $'\e[B'|$'\eOB'|j) [ "${sel}" -lt $((n - 1)) ] && sel=$((sel + 1)) || sel=0; echo "${sel}" ;;
        # (Enter: no key read, or CR where the terminal does not turn it into a line end, bash 3.2)
        ""|$'\r'|$'\n') echo "pick ${sel}" ;;
        "<"|b) echo back ;;
        [1-9]) [ "${key}" -le "${n}" ] && echo "pick $((key - 1))" ;;
    esac
}
# menu_read_key: one key from stdin, an escape sequence whole (the arrows: ESC [ A)
menu_read_key() {
    local key rest
    IFS= read -rsn1 key || { printf 'EOF'; return; }
    if [ "${key}" = $'\e' ]; then
        IFS= read -rsn2 rest
        key=${key}${rest}
    fi
    printf '%s' "${key}"
}
# menu_select <selected> <name|description>...: the menu drawn on stdout, the keys from stdin;
# the option picked (0-based) in MENU_PICK, returns 2 for back. Each option's description is
# shown under the list for the one selected
menu_select() {
    local sel=${1} n i key action names=() descs=() lines
    shift
    for i in "$@"; do names+=("${i%%|*}"); descs+=("${i#*|}"); done
    n=${#names[@]} lines=$((n + 1))
    while :; do
        for ((i = 0; i < n; i++)); do
            if [ "${i}" = "${sel}" ]; then printf '\e[2K %s> %d %s%s\n' "${UI_REV}" "$((i + 1))" "${names[i]}" "${UI_OFF}"
            else printf '\e[2K   %d %s\n' "$((i + 1))" "${names[i]}"; fi
        done
        printf '\e[2K   %s%s%s\n' "${UI_DIM}" "${descs[sel]}" "${UI_OFF}"
        key=$(menu_read_key)
        [ "${key}" = EOF ] && action="pick ${sel}" || action=$(menu_key "${key}" "${sel}" "${n}")
        # the list again, over itself
        printf '\e[%dA' "${lines}"
        case "${action}" in
            "") ;;
            back) printf '\e[J'; return 2 ;;
            pick*) MENU_PICK=${action#pick } ; printf '\e[J'; return 0 ;;
            *) sel=${action} ;;
        esac
    done
}
# ask_menu <id> <question> <default> <name|description>...: the option chosen in CHOICE. On a
# terminal a menu (arrows, Enter, a number; < back); elsewhere a numbered list, then its name
# or number asked; given by its id: that name or number
ask_menu() {
    local id=${1} question=${2} default=${3} opt names=() sel=0 i var
    shift 3
    for opt in "$@"; do names+=("${opt%%|*}"); done
    while :; do
        if answer_given "${id}" || [ -n "${FFS_NONINTERACTIVE}" ] || replayed "${id}" "${default}"; then
            ask "${id}" "${question}" "${default}" || return
        elif [ -z "${FFS_TTY}" ]; then
            # a numbered list, then the name or number asked
            ui_header
            i=1
            for opt in "$@"; do printf '  %d) %s: %s\n' "${i}" "${opt%%|*}" "${opt#*|}"; i=$((i + 1)); done
            FFS_HINT=""
            ask "${id}" "${question}" "${default}" || return
        else
            FFS_ASKED_NOW="" FFS_REPLAYED_NOW=""
            var=FFS_TYPED_${id}
            [ -n "${!var:-}" ] && default=${!var}
            for ((i = 0; i < ${#names[@]}; i++)); do [ "${names[i]}" = "${default}" ] && sel=${i}; done
            ui_header
            printf '%s%s%s %s(↑/↓ Enter, 1-%d, < back)%s\n' "${UI_BOLD}" "${question}" "${UI_OFF}" "${UI_DIM}" "${#names[@]}" "${UI_OFF}"
            FFS_ASKED=yes FFS_ASKED_NOW=yes
            printf -v "FFS_SEEN_${id}" '%s' yes
            if ! menu_select "${sel}" "$@"; then printf '\e[1A\e[2K'; return 2; fi
            ANSWER=${names[MENU_PICK]}
            # the question with its answer, where the menu was
            printf '\e[1A\e[2K%s%s%s: %s\n' "${UI_BOLD}" "${question}" "${UI_OFF}" "${ANSWER}"
            if [ "${ANSWER}" != "${3}" ]; then printf -v "${var}" '%s' "${ANSWER}"; else unset "${var}"; fi
        fi
        # shellcheck disable=SC2068 # (the names, one word each)
        choice "${ANSWER}" ${names[@]} && return 0
        retry
    done
}

# a host name: letters, digits and - in labels separated by dots
valid_hostname() { [[ "${1}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]]; }
# public_url <answer> <default scheme> <schemes> <what>: the answer as scheme://host[:port],
# printed: a host alone gets the default scheme, a / at the end is dropped. Anything else (a
# path, a user, a query, another scheme): an ERROR on stderr, fails. No component of the stack
# answers under a path: each one has its own host name (or port)
public_url() {
    local url=${1} scheme rest host port=""
    case "${url}" in *://*) ;; *) url="${2}://${url}" ;; esac
    scheme=$(lower "${url%%://*}") rest=${url#*://}
    rest=${rest%/}
    case " ${3} " in
        *" ${scheme} "*) ;;
        *) echo "ERROR: the ${4}: ${scheme}:// is not $(printf '%s://' ${3} | sed 's|://\([a-z]\)|:// or \1|g'), in '${1}'" >&2; return 1 ;;
    esac
    case "${rest}" in
        */*|*\?*|*#*|*@*|"")
            echo "ERROR: the ${4}: only ${scheme}://host or ${scheme}://host:port, not '${1}': it answers at /, on a host name (or port) of its own" >&2
            return 1 ;;
    esac
    host=${rest}
    case "${rest}" in *:*) host=${rest%:*} port=${rest##*:} ;; esac
    if ! valid_hostname "${host}"; then
        echo "ERROR: the ${4}: not a host name: '${host}' (in '${1}')" >&2
        return 1
    fi
    if [ -n "${port}" ] || [[ "${rest}" == *: ]]; then
        if ! [[ "${port}" =~ ^[0-9]{1,5}$ ]] || [ "$((10#${port}))" -lt 1 ] || [ "$((10#${port}))" -gt 65535 ]; then
            echo "ERROR: the ${4}: not a port: '${port}' (in '${1}')" >&2
            return 1
        fi
    fi
    printf '%s://%s' "${scheme}" "${rest}"
}
# the host name of a URL of public_url, without its port
url_host() { local rest=${1#*://}; printf '%s' "${rest%:*}"; }
# the port of a URL of public_url, empty without one
url_port() { local rest=${1#*://}; case "${rest}" in *:*) printf '%s' "${rest##*:}" ;; esac; }
# distinct_url <url> <what>: no other public URL of the setup is the same (each needs a server
# of its own in the reverse proxy)
distinct_url() {
    local other name
    for name in SYNC_URL FXA_CONTENT_URL_V FXA_AUTH_URL_V FXA_PROFILE_URL_V FXA_PAIRING_URL_V ADMIN_URL; do
        other=${!name:-}
        [ -n "${other}" ] && [ "${name}" != "${3:-}" ] || continue
        if [ "$(lower "${other#*://}")" = "$(lower "${1#*://}")" ]; then
            echo "ERROR: the ${2}: ${1} is the address of another component already (${other}): each one needs its own host name or port"
            return 1
        fi
    done
}
# ask_url <id> <question> <default> <default scheme> <schemes> <what> <variable>: the URL in
# the variable, asked again until it is one, and not another component's
ask_url() {
    local url
    while :; do
        ask "${1}" "${2}" "${3}" || return
        if url=$(public_url "${ANSWER}" "${4}" "${5}" "${6}") && distinct_url "${url}" "${6}" "${7}"; then
            printf -v "${7}" '%s' "${url}"
            return 0
        fi
        retry
    done
}
# a list of emails and @domains, comma-separated, without spaces (empty: none)
valid_list() {
    case "${1}" in *[!A-Za-z0-9@._+,-]*) echo "ERROR: not a list of emails and domains: ${1}"; return 1 ;; esac
}
# a value written in single quotes in .env, as typed: no quote in it, no backslash at its end
single_quotable() {
    case "${1}" in
        *"'"*) echo "ERROR: ${2} cannot contain a single quote, set ${3} in .env by hand"; return 1 ;;
        *\\) echo "ERROR: ${2} cannot end with a backslash, set ${3} in .env by hand"; return 1 ;;
    esac
}

# section_at <index>: the part of the step at that index, as its header ("2/6 The Sync server")
# in FFS_SECTION, its first step's index in SECTION_START
section_at() {
    local j=${1} k=0 n=0 step
    while [ "${j}" -gt 0 ] && [[ "${SETUP_STEPS[j]}" != @* ]]; do j=$((j - 1)); done
    for step in "${SETUP_STEPS[@]}"; do
        case "${step}" in @*) n=$((n + 1)) ;; esac
    done
    SECTION_NUMBER=0
    for ((k = 0; k <= j; k++)); do case "${SETUP_STEPS[k]}" in @*) SECTION_NUMBER=$((SECTION_NUMBER + 1)) ;; esac; done
    # (its header again when the part changes)
    [ "${FFS_SECTION}" = "${SECTION_NUMBER}/${n} ${SETUP_STEPS[j]#@}" ] || FFS_SECTION_SHOWN=""
    FFS_SECTION="${SECTION_NUMBER}/${n} ${SETUP_STEPS[j]#@}" SECTION_START=${j}
}
# section_index <number>: the index of the header of that part
section_index() {
    local i n=0
    for ((i = 0; i < ${#SETUP_STEPS[@]}; i++)); do
        case "${SETUP_STEPS[i]}" in @*) n=$((n + 1)); [ "${n}" = "${1}" ] && { echo "${i}"; return 0; } ;; esac
    done
    return 1
}
# run_steps: the steps of SETUP_STEPS in their order. A step returns 2 to go back: to the last
# question asked (not those given by id), whose answer is then the default; the steps after it
# run again, with the answers before as their defaults. It returns 3 to change a part (the
# review, FFS_JUMP: the index of its header): its questions are asked again, those after it
# take their answers of before again (replayed) and only new ones are asked. Every step sets
# its variables also when its question does not apply
run_steps() {
    local i=0 n=${#SETUP_STEPS[@]} hist=() step rc
    FFS_SECTION="" FFS_SECTION_SHOWN="" FFS_REPLAY_AFTER=""
    ui_init
    if [ -z "${FFS_NONINTERACTIVE}" ]; then
        echo "${UI_BOLD}Firefox Sync setup${UI_OFF}: the questions go one component at a time, then a review of the answers."
        if [ -n "${FFS_TTY}" ]; then
            echo "  Enter takes the default (shown, or ready to edit); in a list ↑/↓ and Enter, or its number."
        else
            echo "  Enter takes the default in [brackets]; a list takes its name or number."
        fi
        echo "  < (or back) goes back to the question before. Answers can also be given by name, in a file:"
        echo "  docs/install/compose.md#answers-by-name"
    fi
    while [ "${i}" -lt "${n}" ]; do
        step=${SETUP_STEPS[i]}
        case "${step}" in
            @*) section_at "${i}"; i=$((i + 1)); continue ;;
        esac
        FFS_ASKED="" FFS_HINT="" FFS_STEP=${step} FFS_STEP_INDEX=${i}
        "step_${step}"
        rc=$?
        case "${rc}" in
            2)
                if [ "${#hist[@]}" = 0 ]; then
                    echo "  (this is the first question)"
                    continue
                fi
                i=${hist[${#hist[@]}-1]}
                hist=("${hist[@]:0:${#hist[@]}-1}")
                # (the header of its part again)
                section_at "${i}"
                continue ;;
            3)
                # the part chosen in the review, then the review again
                i=${FFS_JUMP}
                FFS_REPLAY_AFTER=$(section_index $((SECTION_NUMBER_OF_JUMP + 1)))
                continue ;;
        esac
        [ -n "${FFS_ASKED}" ] && hist+=("${i}")
        i=$((i + 1))
    done
}

# --- 1) Deployment
step_dir() {
    hint "The checkout of firefox-sync: .env and the examples of config/ are written there"
    while :; do
        ask dir "Directory of the checkout" "${FFS_ENTRY_DIR}" || return
        if [ -f "${ANSWER}/.env-example" ]; then SCRIPT_DIR=${ANSWER}; return 0; fi
        echo "ERROR: ${ANSWER} is no checkout of firefox-sync (no .env-example in it)"
        retry
    done
}
step_existing() {
    EXISTING=new
    [ -f "${SCRIPT_DIR}/.env" ] || return 0
    hint "There is an .env in it already. A setup again writes new passwords, which the databases of an"
    hint "  install that ran do not have (the .env of before is kept as .env.before-setup-<time>)"
    ask_menu existing "Upgrade this install, or set it up again?" upgrade \
        "upgrade|keep its passwords and settings, add what this release needs (as --upgrade; nothing else asked)" \
        "new|answer every question again, with new passwords" || return
    EXISTING=${CHOICE}
    if [ "${EXISTING}" = upgrade ]; then
        FFS_ENTRY_DIR=${SCRIPT_DIR}
        upgrade_env
    fi
}
step_runtime_none() {
    [ "${CONTAINER_RUNTIME}" = none ] || return 0
    hint "Neither Docker nor Podman is installed here: install one before you start the stack"
    ask_yn runtime_none "Continue anyway?" no || return
    [ "${YN}" = yes ] || exit 1
}
step_deploy() {
    DEPLOY_METHOD=""
    [ "${CONTAINER_RUNTIME}" = podman ] || return 0
    hint "Podman found (docs/install/podman.md)"
    ask_menu deploy "How the stack runs" quadlets \
        "quadlets|Podman Quadlets: systemd units of this user, started at boot (recommended)" \
        "compose|docker compose with the Podman socket" || return
    DEPLOY_METHOD=${CHOICE}
}
step_container_user() {
    CONTAINER_USER=${USER}
    [ "${DEPLOY_METHOD}" = quadlets ] && return 0
    hint "In the example of a systemd unit that starts docker compose at boot (config/systemd/syncstorage-rs.service)"
    while :; do
        ask container_user "User that runs docker compose" "${USER}" || return
        # (empty: no USER where it runs, as before)
        [ -z "${ANSWER}" ] || [[ "${ANSWER}" =~ ^[A-Za-z0-9._][A-Za-z0-9._-]*$ ]] && { CONTAINER_USER=${ANSWER}; return 0; }
        echo "ERROR: not a user name: '${ANSWER}'"
        retry
    done
}
step_domain() {
    hint "The public addresses asked below default to host names under it (sync., accounts., api.,"
    hint "  profile., pairing. and admin.<domain>); each can be changed"
    while :; do
        ask domain "Your domain" example.com || return
        valid_hostname "${ANSWER}" && { DOMAIN=${ANSWER}; return 0; }
        echo "ERROR: not a domain: '${ANSWER}'"
        retry
    done
}

# --- 2) The Sync server
step_sync_url() {
    hint "The address Firefox connects to, through your reverse proxy (docs/reverse-proxy.md):"
    hint "  scheme://host, :port after it when not the scheme's own; a host alone is https://. No path:"
    hint "  the Sync server answers at /"
    ask_url sync_url "Public URL of the Sync server" "https://sync.${DOMAIN}" https "https http" "Sync server's public URL" SYNC_URL
}
step_sync_listen() {
    # where the Sync server listens for your reverse proxy, [address:]port: on this host only by
    # default, as the other ports; a port alone is 127.0.0.1:<port>, 0.0.0.0:<port> (or [::]:<port>)
    # every interface. Run again on an install: what its .env has, as it is
    local default=127.0.0.1:5000 previous
    if [ -f "${SCRIPT_DIR}/.env" ]; then
        previous=$(env_plain SYNC_EXPORT_PORT); previous=${previous:-$(env_plain CONTAINER_EXPORT_PORT)}
        default=${previous:-${default}}
    fi
    hint "Where your reverse proxy reaches the Sync server: [address:]port, a port alone is on 127.0.0.1"
    hint "  (this host only); 0.0.0.0:<port> or [::]:<port> is every interface"
    while :; do
        SYNC_EXPORT_KEPT=""
        ask sync_listen "Address and port the Sync server listens on" "${default}" || return
        SYNC_EXPORT_PORT=${ANSWER}
        if [ -n "${FFS_DEFAULTED}" ]; then
            # what an install has is kept as it is, also a value this check does not know
            if ! valid_export_port "${SYNC_EXPORT_PORT}"; then
                echo "WARNING: SYNC_EXPORT_PORT='${SYNC_EXPORT_PORT}' of .env is not [address:]port as this script knows it: kept"
                SYNC_EXPORT_KEPT=yes
            fi
            return 0
        fi
        case "${SYNC_EXPORT_PORT}" in
            *[!0-9]*) ;;
            *) SYNC_EXPORT_PORT=127.0.0.1:${SYNC_EXPORT_PORT} ;;
        esac
        valid_export_port "${SYNC_EXPORT_PORT}" && return 0
        ui_error "not a port or an address and port: '${SYNC_EXPORT_PORT}' (e.g. 5000, 127.0.0.1:5000, 0.0.0.0:5000, [::]:5000)"
        retry
    done
}
step_sync_image_tag() {
    hint "latest follows the newest release (docs/upgrading.md#sync-server); a release's tag pins it"
    while :; do
        ask sync_image_tag "Image tag of the Sync server" latest || return
        [[ "${ANSWER}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] && { SYNC_IMAGE_TAG=${ANSWER}; return 0; }
        echo "ERROR: not an image tag: '${ANSWER}'"
        retry
    done
}
step_sync_db() {
    hint "The database of the Sync server: its tokenserver (the accounts and their nodes) and its storage"
    hint "  (the synced data), see docs/databases.md"
    ask_menu sync_db "Engine of the Sync server's database" mariadb \
        "mariadb|MariaDB lts" "mysql|MySQL lts" "postgres|PostgreSQL" || return
    DATABASE_BACKEND=${CHOICE}
    # MySQL containers (compose/sync-mysql.yml), the same Sync images as MariaDB
    [ "${DATABASE_BACKEND}" = mysql ] && SYNC_DB=mysql || SYNC_DB=mariadb
}
step_sync_db_own() {
    hint "By default the stack runs the Sync server's database (tokenserver + storage) in containers of its"
    hint "  own. Yes: on a database server you run, see docs/databases.md#your-own-server"
    ask_yn sync_db_own "Put the Sync server's database on your own server?" no || return
    EXTERNAL_DB=${YN}
}
step_sync_db_host() {
    DB_HOST=""
    [ "${EXTERNAL_DB}" = yes ] || return 0
    hint "As the containers reach it: localhost is the container itself (docs/databases.md#server-requirements)"
    while :; do
        ask sync_db_host "Host of your server for the Sync server's database" "" || return
        (valid_host "${ANSWER}") && { DB_HOST=${ANSWER}; return 0; }
        retry
    done
}
step_sync_db_port() {
    DB_PORT=""
    [ "${EXTERNAL_DB}" = yes ] || return 0
    local default=3306
    [ "${DATABASE_BACKEND}" = postgres ] && default=5432
    while :; do
        ask sync_db_port "Port of your server for the Sync server's database" "${default}" || return
        (valid_port "${ANSWER}") && { DB_PORT=${ANSWER}; return 0; }
        retry
    done
}
# ask_db_name <id> <question> <default> <variable> <checks>: a database or user name, checked
ask_db_name() {
    while :; do
        ask "${1}" "${2}" "${3}" || return
        ("${5}" "${ANSWER}") && { printf -v "${4}" '%s' "${ANSWER}"; return 0; }
        retry
    done
}
step_sync_db_name() {
    SYNC_POSTGRES_NAME=""
    [ "${EXTERNAL_DB}" = yes ] && [ "${DATABASE_BACKEND}" = postgres ] || return 0
    ask_db_name sync_db_name "The Sync server's database on your server" syncserver SYNC_POSTGRES_NAME stack_name
}
step_sync_db_user() {
    SYNC_POSTGRES_USER=""
    [ "${EXTERNAL_DB}" = yes ] && [ "${DATABASE_BACKEND}" = postgres ] || return 0
    ask_db_name sync_db_user "Its user (database-setup.sql creates it)" syncserver SYNC_POSTGRES_USER valid_user
}
step_sync_tokenserver_db_name() {
    SYNC_TOKENSERVER_DB_NAME=""
    [ "${EXTERNAL_DB}" = yes ] && [ "${DATABASE_BACKEND}" != postgres ] || return 0
    hint "The Sync server has two databases there: the tokenserver's (the accounts and their nodes) and the storage's"
    ask_db_name sync_tokenserver_db_name "The tokenserver's database on your server" tokenserver SYNC_TOKENSERVER_DB_NAME stack_name
}
step_sync_tokenserver_db_user() {
    SYNC_TOKENSERVER_DB_USER=""
    [ "${EXTERNAL_DB}" = yes ] && [ "${DATABASE_BACKEND}" != postgres ] || return 0
    ask_db_name sync_tokenserver_db_user "Its user (database-setup.sql creates it)" tokenserver SYNC_TOKENSERVER_DB_USER valid_user
}
step_sync_storage_db_name() {
    SYNC_STORAGE_DB_NAME=""
    [ "${EXTERNAL_DB}" = yes ] && [ "${DATABASE_BACKEND}" != postgres ] || return 0
    while :; do
        ask_db_name sync_storage_db_name "The storage's database on your server" syncstorage SYNC_STORAGE_DB_NAME stack_name || return
        [ "${SYNC_TOKENSERVER_DB_NAME}" != "${SYNC_STORAGE_DB_NAME}" ] && return 0
        echo "ERROR: the tokenserver and the storage need two databases"
        retry
    done
}
step_sync_storage_db_user() {
    SYNC_STORAGE_DB_USER=""
    [ "${EXTERNAL_DB}" = yes ] && [ "${DATABASE_BACKEND}" != postgres ] || return 0
    ask_db_name sync_storage_db_user "Its user (database-setup.sql creates it)" syncstorage SYNC_STORAGE_DB_USER valid_user
}
# the account that applies database-setup.sql (database-setup-fxa.sql) at every start
# (docs/databases.md#let-the-stack-apply-them); without: the stack only checks that it was applied
bootstrap_hint() {
    hint "By default the stack checks at every start that database-setup${1}.sql (written next to .env) was"
    hint "  applied on your server, and you run it there again when a release needs it. Yes: the stack applies it"
    hint "  itself, as an account of your server that can create users (docs/databases.md#let-the-stack-apply-them)"
}
step_sync_db_bootstrap() {
    SYNC_DB_BOOTSTRAP=no
    [ "${EXTERNAL_DB}" = yes ] || return 0
    bootstrap_hint ""
    ask_yn sync_db_bootstrap "Let the stack apply the Sync server's database changes itself?" no || return
    SYNC_DB_BOOTSTRAP=${YN}
}
# bootstrap_user <user> <SYNC|FXA>: a name of its own, not one of the stack's users nor the
# server's administrator
bootstrap_user() {
    [[ "${1}" =~ ^[A-Za-z0-9_]{1,32}$ ]] || { echo "ERROR: not a valid user name (A-Z, a-z, 0-9, _): '${1}'"; return 1; }
    # (on another server than Sync's the same name is another account)
    [ "${2}" != FXA ] || [ "${1}" != "${SYNC_DB_BOOTSTRAP_USER}" ] \
        || [ "$(lower "${FXA_MYSQL_HOST}:${FXA_MYSQL_PORT}")" != "$(lower "${DB_HOST}:${DB_PORT}")" ] \
        || { echo "ERROR: '${1}' is Sync's bootstrap account already, on the same server: the accounts need one of their own there (one account would get two passwords)"; return 1; }
    case " root postgres ${SYNC_TOKENSERVER_DB_USER:-} ${SYNC_STORAGE_DB_USER:-} ${SYNC_POSTGRES_USER:-} ${FXA_MYSQL_USER:-} ${FXA_MYSQL_POLICY_USER:-} ffs_admin ffs_admin_ui ffs_admin_sync " in
        *" ${1} "*) echo "ERROR: '${1}' is the server's administrator or one of the stack's users: the bootstrap needs an account of its own (docs/databases.md#the-bootstrap-account)"; return 1 ;;
    esac
}
step_sync_db_bootstrap_user() {
    SYNC_DB_BOOTSTRAP_USER=""
    [ "${SYNC_DB_BOOTSTRAP}" = yes ] || return 0
    while :; do
        ask sync_db_bootstrap_user "That account, which you have or database-bootstrap.sql creates" ffs_sync_bootstrap || return
        bootstrap_user "${ANSWER}" SYNC && { SYNC_DB_BOOTSTRAP_USER=${ANSWER}; return 0; }
        retry
    done
}
# bootstrap_password <SYNC|FXA> <id>: the password of the bootstrap account, a new one when empty
bootstrap_password() {
    while :; do
        ask "${2}" "Its password (empty: a new one)" "" secret || return
        printf -v "${1}_DB_BOOTSTRAP_GENERATED" '%s' ""
        [ -n "${ANSWER}" ] || { ANSWER=$(generate_random_string 32); printf -v "${1}_DB_BOOTSTRAP_GENERATED" '%s' yes; }
        # (in database-bootstrap.sql, and in the database URLs' rules)
        if [[ "${ANSWER}" =~ ^[A-Za-z0-9._~-]+$ ]]; then
            printf -v "${1}_DB_BOOTSTRAP_PASSWORD" '%s' "${ANSWER}"
            return 0
        fi
        echo "ERROR: the password: only A-Z a-z 0-9 . _ ~ -"
        retry
    done
}
step_sync_db_bootstrap_password() {
    SYNC_DB_BOOTSTRAP_PASSWORD=""
    [ "${SYNC_DB_BOOTSTRAP}" = yes ] || return 0
    bootstrap_password SYNC sync_db_bootstrap_password
}
step_sync_max_users() {
    hint "How many accounts can use this Sync server: each account that syncs here takes a place, and once"
    hint "  they are all taken new ones are refused (those in keep syncing). A number (0: nobody new), or"
    hint "  unlimited. With the admin UI you can change it there later (docs/limits.md)"
    while :; do
        ask sync_max_users "Max users of the Sync server, a number or unlimited" 1 || return
        (valid_limit "max users" "${ANSWER}") && { SYNC_MAX_USERS=${ANSWER}; return 0; }
        retry
    done
}

# --- 3) The accounts
step_accounts() {
    hint "Firefox signs in to Sync with an account: Mozilla's, or one of accounts you run here (docs/accounts.md)"
    MENU_ALIASES="selfhosted=self-hosted self=self-hosted self-host=self-hosted" ask_menu accounts "Which accounts people sign in with" mozilla \
        "mozilla|Mozilla's accounts (accounts.firefox.com), what Firefox uses by default" \
        "self-hosted|Mozilla's accounts service runs here too: the accounts, their passwords and emails on your server" || return
    [ "${CHOICE}" = self-hosted ] && SELF_HOST_FXA=yes || SELF_HOST_FXA=no
}
step_sync_invite_only() {
    INVITE_ONLY=off
    [ "${SELF_HOST_FXA}" = no ] || return 0
    hint "With Mozilla's accounts, anybody who has one can sync here, up to the max users above: invite-only"
    hint "  Sync lets only the accounts you choose start to sync (docs/limits.md#sync_allowed_accounts). With"
    hint "  self-hosted accounts their sign-up policy decides instead, who can have an account at all"
    ask_menu sync_invite_only "Invite-only Sync" off \
        "off|anybody with a Mozilla account can sync here" \
        "list|only the accounts whose ids (uids) you list next" \
        "admin|only the accounts you approve in the admin UI (which this turns on)" || return
    INVITE_ONLY=${CHOICE}
}
step_sync_allowed_accounts() {
    SYNC_ALLOWED_ACCOUNTS=""
    [ "${INVITE_ONLY}" = admin ] && SYNC_ALLOWED_ACCOUNTS="admin"
    [ "${INVITE_ONLY}" = list ] || return 0
    hint "An account's uid: docs/limits.md#find-the-uid-of-an-account"
    while :; do
        ask sync_allowed_accounts "The account ids (uids) that can sync, comma-separated" "" || return
        SYNC_ALLOWED_ACCOUNTS=$(valid_uids "${ANSWER}") && return 0
        retry
    done
}
step_fxa_content_url() {
    FXA_CONTENT_URL_V=""
    [ "${SELF_HOST_FXA}" = yes ] || return 0
    hint "The accounts have three public addresses, each on a host name (or port) of its own: the pages, the"
    hint "  API and the profile server (docs/reverse-proxy.md#host-names-and-ports). scheme://host[:port], no path"
    hint "The pages: sign-in and sign-up, what Firefox's identity.fxaccounts.autoconfig.uri points to"
    ask_url fxa_content_url "Public URL of the accounts pages" "https://accounts.${DOMAIN}" https "https http" "accounts pages' public URL" FXA_CONTENT_URL_V
}
step_fxa_auth_url() {
    FXA_AUTH_URL_V=""
    [ "${SELF_HOST_FXA}" = yes ] || return 0
    hint "The API: sign-in, OAuth and the sign-up gate of the admin UI"
    ask_url fxa_auth_url "Public URL of the accounts API" "https://api.${DOMAIN}" https "https http" "accounts API's public URL" FXA_AUTH_URL_V
}
step_fxa_profile_url() {
    FXA_PROFILE_URL_V=""
    [ "${SELF_HOST_FXA}" = yes ] || return 0
    hint "The profile server: names and avatars"
    ask_url fxa_profile_url "Public URL of the accounts profile server" "https://profile.${DOMAIN}" https "https http" "profile server's public URL" FXA_PROFILE_URL_V
}
step_fxa_db() {
    FXA_DB=mysql
    [ "${SELF_HOST_FXA}" = yes ] || return 0
    # MySQL by default, whatever Sync uses: it is what Mozilla supports and runs
    hint "The database of the self-hosted Mozilla accounts, whatever the Sync server's is"
    ask_menu fxa_db "Engine of the self-hosted Mozilla accounts' database" mysql \
        "mysql|MySQL lts, what Mozilla runs" \
        "mariadb|MariaDB lts, see docs/accounts.md#mysql-or-mariadb" || return
    FXA_DB=${CHOICE}
}
step_fxa_db_own() {
    EXTERNAL_FXA_DB=no
    [ "${SELF_HOST_FXA}" = yes ] || return 0
    hint "By default the stack runs the self-hosted Mozilla accounts' database in a container of its own. Yes: on your own"
    hint "  $([ "${FXA_DB}" = mariadb ] && echo "MariaDB 11.4 or later" || echo "MySQL 8.4 or 9") server$([ "${EXTERNAL_DB}" = yes ] && echo ", the Sync server's or another"), see docs/databases.md#your-own-server"
    ask_yn fxa_db_own "Put the self-hosted accounts' database on your own server?" no || return
    EXTERNAL_FXA_DB=${YN}
}
step_fxa_db_host() {
    FXA_MYSQL_HOST=""
    [ "${EXTERNAL_FXA_DB}" = yes ] || return 0
    hint "As the containers reach it (docs/databases.md#server-requirements)"
    while :; do
        ask fxa_db_host "Host of your server for the self-hosted accounts' database" "${DB_HOST:-}" || return
        (valid_host "${ANSWER}") && { FXA_MYSQL_HOST=${ANSWER}; return 0; }
        retry
    done
}
step_fxa_db_port() {
    FXA_MYSQL_PORT=""
    [ "${EXTERNAL_FXA_DB}" = yes ] || return 0
    while :; do
        ask fxa_db_port "Port of your server for the self-hosted accounts' database" 3306 || return
        (valid_port "${ANSWER}") && { FXA_MYSQL_PORT=${ANSWER}; return 0; }
        retry
    done
}
# fxa_user <name>: a user of the accounts, not the Sync server's bootstrap account
fxa_user() {
    valid_user "${1}"
    [ -z "${SYNC_DB_BOOTSTRAP_USER}" ] || [ "${1}" != "${SYNC_DB_BOOTSTRAP_USER}" ] || {
        echo "ERROR: '${1}' is the account that applies the Sync server's database changes: the bootstrap needs an account of its own (docs/databases.md#the-bootstrap-account)"; exit 1; }
}
step_fxa_db_user() {
    FXA_MYSQL_USER=""
    [ "${EXTERNAL_FXA_DB}" = yes ] || return 0
    hint "The user the self-hosted accounts connect as (database-setup-fxa.sql creates it)"
    ask_db_name fxa_db_user "The self-hosted accounts' database user" fxa FXA_MYSQL_USER fxa_user
}
step_fxa_db_policy_user() {
    FXA_MYSQL_POLICY_USER=""
    [ "${EXTERNAL_FXA_DB}" = yes ] || return 0
    hint "The user that installs the sign-up policy and the admin UI's grants (database-setup-fxa.sql creates it)"
    ask_db_name fxa_db_policy_user "User installing the sign-up policy" ffs_policy FXA_MYSQL_POLICY_USER fxa_user
}
step_fxa_db_bootstrap() {
    FXA_DB_BOOTSTRAP=no
    [ "${EXTERNAL_FXA_DB}" = yes ] || return 0
    bootstrap_hint -fxa
    ask_yn fxa_db_bootstrap "Let the stack apply the self-hosted accounts' database changes itself?" no || return
    FXA_DB_BOOTSTRAP=${YN}
}
step_fxa_db_bootstrap_user() {
    FXA_DB_BOOTSTRAP_USER=""
    [ "${FXA_DB_BOOTSTRAP}" = yes ] || return 0
    while :; do
        ask fxa_db_bootstrap_user "That account, which you have or database-bootstrap-fxa.sql creates" ffs_fxa_bootstrap || return
        bootstrap_user "${ANSWER}" FXA && { FXA_DB_BOOTSTRAP_USER=${ANSWER}; return 0; }
        retry
    done
}
step_fxa_db_bootstrap_password() {
    FXA_DB_BOOTSTRAP_PASSWORD=""
    [ "${FXA_DB_BOOTSTRAP}" = yes ] || return 0
    bootstrap_password FXA fxa_db_bootstrap_password
}
step_smtp_host() {
    FXA_SMTP_HOST=""
    [ "${SELF_HOST_FXA}" = yes ] || return 0
    hint "The accounts send their emails (the confirmation codes) through an SMTP server of yours"
    while :; do
        ask smtp_host "SMTP server for the accounts' emails" "" || return
        [ -z "${ANSWER}" ] || valid_hostname "${ANSWER}" && { FXA_SMTP_HOST=${ANSWER}; return 0; }
        echo "ERROR: not a host name: '${ANSWER}'"
        retry
    done
}
step_smtp_port() {
    FXA_SMTP_PORT=587
    [ "${SELF_HOST_FXA}" = yes ] || return 0
    hint "587: STARTTLS; 465: TLS from the start"
    while :; do
        ask smtp_port "SMTP port" 587 || return
        (valid_port "${ANSWER}") && { FXA_SMTP_PORT=${ANSWER}; return 0; }
        retry
    done
}
step_smtp_user() {
    FXA_SMTP_USER=""
    [ "${SELF_HOST_FXA}" = yes ] || return 0
    while :; do
        ask smtp_user "SMTP user (empty: none)" "" || return
        case "${ANSWER}" in
            *"'"*|*\\) echo "ERROR: the SMTP user cannot contain a single quote nor end with a backslash, set FXA_SMTP_USER in .env by hand" ;;
            *) FXA_SMTP_USER=${ANSWER}; return 0 ;;
        esac
        retry
    done
}
step_smtp_password() {
    FXA_SMTP_PASS=""
    [ "${SELF_HOST_FXA}" = yes ] || return 0
    while :; do
        ask smtp_password "SMTP password" "" secret || return
        # (written in single quotes, as typed: compose reads \' there as a quote, so not at the end either)
        single_quotable "${ANSWER}" "the SMTP password" FXA_SMTP_PASS && { FXA_SMTP_PASS=${ANSWER}; return 0; }
        retry
    done
}
step_smtp_sender() {
    FXA_SMTP_SENDER=""
    [ "${SELF_HOST_FXA}" = yes ] || return 0
    while :; do
        ask smtp_sender "Sender of the emails" "Mozilla accounts <no-reply@${DOMAIN}>" || return
        case "${ANSWER}" in
            *$'\n'*) echo "ERROR: the sender is one line" ;;
            *) FXA_SMTP_SENDER=${ANSWER}; return 0 ;;
        esac
        retry
    done
}
step_fxa_signups() {
    FXA_SIGNUP_ALLOWLIST="" FXA_SIGNUPS=open
    [ "${SELF_HOST_FXA}" = yes ] || return 0
    hint "The sign-up policy (docs/accounts.md#who-can-sign-up): emails and @domains, comma-separated, are the only"
    hint "  ones that can create an account here; empty: anybody who reaches the accounts pages. The admin UI"
    hint "  changes it later"
    while :; do
        ask fxa_signups "Who can create an account (empty: anybody)" "" || return
        FXA_SIGNUP_ALLOWLIST=$(printf '%s' "${ANSWER}" | tr -d ' ')
        valid_list "${FXA_SIGNUP_ALLOWLIST}" && break
        retry
    done
    [ -n "${FXA_SIGNUP_ALLOWLIST}" ] && FXA_SIGNUPS=allowlist
    return 0
}
step_fxa_max_accounts() {
    FXA_MAX_ACCOUNTS_ANSWER=""
    [ "${SELF_HOST_FXA}" = yes ] || return 0
    hint "How many accounts can be created on the self-hosted accounts, confirmed or not: a number (0: nobody"
    hint "  new) or unlimited. With the admin UI you can change it there later"
    while :; do
        ask fxa_max_accounts "Max accounts of the self-hosted accounts, a number or unlimited" unlimited || return
        (valid_limit "max accounts" "${ANSWER}") && { FXA_MAX_ACCOUNTS_ANSWER=${ANSWER}; return 0; }
        retry
    done
}
step_fxa_account_events() {
    FXA_ACCOUNT_EVENTS=false
    [ "${SELF_HOST_FXA}" = yes ] || return 0
    hint "Security history: every sign-in, password and 2-step change is kept with its IP address, for the"
    hint "  owner and the admin UI to see (docs/accounts.md#security-history)"
    ask_yn fxa_account_events "Record the security history of the accounts?" no || return
    [ "${YN}" = yes ] && FXA_ACCOUNT_EVENTS=true
    return 0
}
# a profile of COMPOSE_PROFILES of the .env of before (run again on an install: its choices
# are the defaults)
previous_profile() { [ -f "${SCRIPT_DIR}/.env" ] && case ",$(env_plain COMPOSE_PROFILES)," in *",${1},"*) return 0 ;; esac; return 1; }
step_pairing() {
    # your own pairing server for the QR code (docs/reverse-proxy.md#pairing), with the accounts:
    # compose's pairing profile (the Quadlets have none: not asked)
    PAIRING=no
    [ "${SELF_HOST_FXA}" = yes ] && [ "${DEPLOY_METHOD}" != quadlets ] || return 0
    local default=no
    previous_profile pairing && default=yes
    hint "Pairing connects a phone by the QR code Firefox shows. no: Mozilla's pairing server; yes: your own"
    hint "  (docs/reverse-proxy.md#pairing)"
    ask_yn pairing "Run your own pairing server?" "${default}" || return
    PAIRING=${YN}
}
step_pairing_url() {
    FXA_PAIRING_URL_V=""
    [ "${PAIRING}" = yes ] || return 0
    hint "wss://host[:port], no path"
    ask_url pairing_url "Public URL of the pairing server" "wss://pairing.${DOMAIN}" wss "wss ws" "pairing server's public URL" FXA_PAIRING_URL_V
}

# --- 4) The admin UI
step_admin() {
    ADMIN_UI=yes
    # invite-only Sync approved in the admin UI: on
    [ "${INVITE_ONLY}" = admin ] && return 0
    hint "The admin UI (docs/admin/README.md) manages the max users and invite-only Sync and, with self-hosted"
    hint "  accounts, the sign-ups and the accounts; it shows the health of the stack and sends alerts"
    ask_yn admin "Run the admin UI?" yes || return
    ADMIN_UI=${YN}
}
step_admin_signin() {
    ADMIN_SIGNIN=""
    [ "${ADMIN_UI}" = yes ] || return 0
    local options=()
    hint "How admins sign in (docs/admin/signing-in.md). The password (ADMIN_PASSWORD in .env, generated) works at"
    hint "  http://localhost:8090 on this host (over SSH: ssh -L 8090:127.0.0.1:8090 <host>); with single sign-on"
    hint "  it is kept as a way in too, unless you say otherwise below"
    options=("password|the password only")
    [ "${SELF_HOST_FXA}" = yes ] && options+=("accounts|with the self-hosted Mozilla accounts (OpenID Connect), on a public address of the admin UI")
    options+=("oidc|with another OpenID Connect provider: Authentik, Keycloak, Authelia, Google, Entra ID, Dex...")
    options+=("header|a header your reverse proxy sets once it signed you in: Authelia, oauth2-proxy, Tailscale...")
    ask_menu admin_signin "How admins sign in" password "${options[@]}" || return
    ADMIN_SIGNIN=${CHOICE}
}
step_admin_url() {
    ADMIN_URL=""
    case "${ADMIN_SIGNIN}" in accounts|oidc) ;; *) return 0 ;; esac
    hint "Where the provider sends you back after signing in: the admin UI on a host name (or port) of its own,"
    hint "  through your reverse proxy (docs/reverse-proxy.md#the-admin-ui). scheme://host[:port], no path"
    while :; do
        ask_url admin_url "Public URL of the admin UI" "https://admin.${DOMAIN}" https "https http" "admin UI's public URL" ADMIN_URL || return
        # browsers drop Secure cookies over http, but on localhost (admin/oidc.go)
        case "${ADMIN_URL}" in
            http://localhost|http://localhost:*|http://127.0.0.1|http://127.0.0.1:*|https://*) return 0 ;;
        esac
        echo "ERROR: the admin UI's public URL: http:// only on localhost; use https:// (or set ADMIN_INSECURE_COOKIE=1 and ADMIN_OIDC_REDIRECT_URL in .env by hand, docs/admin/signing-in.md)"
        ADMIN_URL=""
        retry
    done
}
step_admin_oidc_issuer() {
    ADMIN_OIDC_ISSUER_V=""
    [ "${ADMIN_SIGNIN}" = oidc ] || return 0
    hint "Create a client at your provider first, with the redirect URI ${ADMIN_URL}/auth/callback"
    hint "  (docs/admin/signing-in.md#providers says what to set for each). Its issuer serves"
    hint "  /.well-known/openid-configuration, e.g. https://id.example.com (Authentik: with the / at its end)"
    while :; do
        ask admin_oidc_issuer "Issuer URL of your OpenID Connect provider" "" || return
        [[ "${ANSWER}" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~%/-]*)?$ ]] && { ADMIN_OIDC_ISSUER_V=${ANSWER}; return 0; }
        echo "ERROR: not an issuer URL (https://host[:port][/path]): '${ANSWER}'"
        retry
    done
}
step_admin_oidc_client_id() {
    ADMIN_OIDC_CLIENT_ID_V=""
    [ "${ADMIN_SIGNIN}" = oidc ] || return 0
    while :; do
        ask admin_oidc_client_id "The client's id" "" || return
        [[ "${ANSWER}" =~ ^[A-Za-z0-9._~:@/+=-]+$ ]] && { ADMIN_OIDC_CLIENT_ID_V=${ANSWER}; return 0; }
        echo "ERROR: not a client id: '${ANSWER}'"
        retry
    done
}
step_admin_oidc_client_secret() {
    ADMIN_OIDC_CLIENT_SECRET_V=""
    [ "${ADMIN_SIGNIN}" = oidc ] || return 0
    while :; do
        ask admin_oidc_client_secret "The client's secret (empty: a public client, PKCE only)" "" secret || return
        single_quotable "${ANSWER}" "the client's secret" ADMIN_OIDC_CLIENT_SECRET && { ADMIN_OIDC_CLIENT_SECRET_V=${ANSWER}; return 0; }
        retry
    done
}
step_admin_oidc_name() {
    ADMIN_OIDC_NAME_V=""
    [ "${ADMIN_SIGNIN}" = oidc ] || return 0
    hint "The sign-in button says \"Sign in with <this>\"; empty: \"single sign-on\""
    while :; do
        ask admin_oidc_name "Name of the provider on the button (empty: single sign-on)" "" || return
        [[ "${ANSWER}" =~ ^[^\"\\]*$ ]] && { ADMIN_OIDC_NAME_V=${ANSWER}; return 0; }
        echo "ERROR: the name cannot contain \" or \\"
        retry
    done
}
step_admin_oidc_scopes() {
    ADMIN_OIDC_SCOPES_V=""
    [ "${ADMIN_SIGNIN}" = oidc ] || return 0
    hint "The scopes the admin UI asks for, openid among them. Admins by group (asked below) with Authelia or"
    hint "  Dex: add groups (openid email profile groups); most other providers send the groups without it"
    while :; do
        ask admin_oidc_scopes "Scopes to ask the provider for" "openid email profile" || return
        ANSWER=$(printf '%s' "${ANSWER}" | tr -s ' ')
        ANSWER=${ANSWER# } ANSWER=${ANSWER% }
        if ! [[ "${ANSWER}" =~ ^[A-Za-z0-9_.:/-]+( [A-Za-z0-9_.:/-]+)*$ ]]; then
            ui_error "not a list of scopes, separated by spaces: '${ANSWER}'"
        elif [[ " ${ANSWER} " != *" openid "* ]]; then
            ui_error "the scopes need openid: '${ANSWER}'"
        else
            # (the default: ADMIN_OIDC_SCOPES left empty, as the admin UI's own default)
            [ "${ANSWER}" = "openid email profile" ] || ADMIN_OIDC_SCOPES_V=${ANSWER}
            return 0
        fi
        retry
    done
}
step_admin_auth_header() {
    ADMIN_AUTH_HEADER_V=""
    [ "${ADMIN_SIGNIN}" = header ] || return 0
    hint "Your proxy signs people in and passes their email in a header it sets itself, replacing what the"
    hint "  client sends (docs/admin/signing-in.md#trusted-header): Remote-Email for Authelia, X-Auth-Request-Email"
    hint "  for oauth2-proxy, Tailscale-User-Login for Tailscale"
    while :; do
        ask admin_auth_header "The header with the email" Remote-Email || return
        [[ "${ANSWER}" =~ ^[A-Za-z0-9-]+$ ]] && { ADMIN_AUTH_HEADER_V=${ANSWER}; return 0; }
        echo "ERROR: not a header name: '${ANSWER}'"
        retry
    done
}
step_admin_auth_groups_header() {
    ADMIN_AUTH_GROUPS_HEADER_V=""
    [ "${ADMIN_SIGNIN}" = header ] || return 0
    hint "Comma-separated groups, only when your proxy sets the header itself (e.g. Remote-Groups for Authelia):"
    hint "  a groups header the client can send makes anybody the proxy lets in an admin"
    while :; do
        ask admin_auth_groups_header "The header with the groups (empty: none)" "" || return
        [[ "${ANSWER}" =~ ^[A-Za-z0-9-]*$ ]] && { ADMIN_AUTH_GROUPS_HEADER_V=${ANSWER}; return 0; }
        echo "ERROR: not a header name: '${ANSWER}'"
        retry
    done
}
step_admin_trusted_proxies() {
    ADMIN_TRUSTED_PROXIES_V=""
    [ "${ADMIN_SIGNIN}" = header ] || return 0
    hint "The header counts only on connections from these addresses: your proxy as the admin UI sees it. Whatever"
    hint "  else connects from them signs in as anybody: not 127.0.0.1 nor a network's gateway, which every process"
    hint "  or container of the host has, but an address of your proxy alone, e.g. Traefik's on a network of this"
    hint "  stack (docs/admin/signing-in.md#trusted-header). Without one, prefer OpenID Connect"
    while :; do
        ask admin_trusted_proxies "Addresses of your proxy, CIDRs comma-separated" "" || return
        ANSWER=$(printf '%s' "${ANSWER}" | tr -d ' ')
        [[ "${ANSWER}" =~ ^[0-9A-Fa-f.:/]+(,[0-9A-Fa-f.:/]+)*$ ]] && { ADMIN_TRUSTED_PROXIES_V=${ANSWER}; return 0; }
        echo "ERROR: not a list of addresses or CIDRs (e.g. 172.18.0.1/32): '${ANSWER}'"
        retry
    done
}
step_admin_users() {
    ADMIN_ALLOWED_USERS=""
    case "${ADMIN_SIGNIN}" in accounts|oidc|header) ;; *) return 0 ;; esac
    hint "Only the emails (and @domains) listed here get in: not every account that $([ "${ADMIN_SIGNIN}" = accounts ] && echo "the self-hosted accounts have" || echo "your provider knows"). An @domain admits"
    hint "  every account of that domain (docs/admin/signing-in.md#who-is-an-admin)"
    [ "${ADMIN_SIGNIN}" = accounts ] || hint "  Empty: by groups only, asked next"
    while :; do
        ask admin_users "Who is an admin? Emails and @domains, comma-separated" "" || return
        ADMIN_ALLOWED_USERS=$(printf '%s' "${ANSWER}" | tr -d ' ')
        if valid_list "${ADMIN_ALLOWED_USERS}"; then
            [ -n "${ADMIN_ALLOWED_USERS}" ] || [ "${ADMIN_SIGNIN}" != accounts ] && return 0
            echo "ERROR: no admin given: with the accounts, the emails of the admins (or < back, and sign in with the password only)"
        fi
        retry
    done
}
step_admin_groups() {
    ADMIN_ALLOWED_GROUPS_V=""
    case "${ADMIN_SIGNIN}" in oidc|header) ;; *) return 0 ;; esac
    hint "And/or the members of these groups of your provider (its groups claim, or the groups header),"
    hint "  comma-separated"
    while :; do
        ask admin_groups "Groups whose members are admins (empty: none)" "" || return
        ANSWER=$(printf '%s' "${ANSWER}" | tr -d ' ')
        if ! [[ "${ANSWER}" =~ ^[A-Za-z0-9._:@/+-]*(,[A-Za-z0-9._:@/+-]+)*$ ]]; then
            echo "ERROR: not a list of groups: '${ANSWER}'"
        elif [ -z "${ANSWER}" ] && [ -z "${ADMIN_ALLOWED_USERS}" ]; then
            echo "ERROR: no admin given, nor a group: the admin UI would not start (it lets in nobody the provider knows by default)"
        else
            ADMIN_ALLOWED_GROUPS_V=${ANSWER}
            return 0
        fi
        retry
    done
}
# scheme://host of a destination of the alerts, … for what cannot be named safely (an @ after
# the host is the end of a user or password with / ? # in it, not the host)
notify_name() {
    local scheme rest host tail
    scheme=$(lower "${1%%://*}"); rest=${1#*://}
    [[ "${scheme}" =~ ^[a-z][a-z0-9+]*$ ]] || { printf '…'; return; }
    case "${scheme}" in telegram*) printf '%s://api.telegram.org' "${scheme}"; return ;; esac
    host=${rest%%[/?#]*}; tail=${rest#"${host}"}
    tail=${tail//\?@/}; tail=${tail//&@/}
    case "${tail}" in *@*) printf '%s://…' "${scheme}"; return ;; esac
    host=${host##*@}
    [[ "${host}" =~ ^[A-Za-z0-9.:-]+$ ]] || { printf '%s://…' "${scheme}"; return; }
    printf '%s://%s' "${scheme}" "${host}"
}
# notify_list <answer>: the destinations of ADMIN_NOTIFY, separated by commas or spaces, in
# ADMIN_NOTIFY (comma-separated) and their names in NOTIFY_NAMES; an ERROR for one it does not know
notify_list() {
    local entry kind base shown entries=()
    ADMIN_NOTIFY="" NOTIFY_NAMES=""
    IFS=$', \t\r' read -r -a entries <<< "${1}"
    for entry in ${entries[@]+"${entries[@]}"}; do
        [ -n "${entry}" ] || continue
        case "${entry}" in *"'"*|*\\) echo "ERROR: a destination URL cannot contain a single quote nor end with a backslash, set ADMIN_NOTIFY in .env by hand"; return 1 ;; esac
        # the webhook URL of Slack or Discord as they give it: their scheme instead of https://
        kind=""
        case "${entry}" in
            https://hooks.slack.com/*) kind=slack ;;
            https://discord.com/api/webhooks/*|https://discordapp.com/api/webhooks/*) kind=discord ;;
        esac
        if [ -n "${kind}" ]; then
            entry="${kind}://${entry#https://}"
            echo "  that is a ${kind} webhook URL: used as ${kind}://..."
        fi
        base="" shown="…"
        if [[ "${entry}" == *://* ]]; then
            base=$(lower "${entry%%://*}"); base=${base%+http}; base=${base%+https}
            shown=$(notify_name "${entry}")
        fi
        if ! [[ "${base}" =~ ^(slack|discord|teams|ntfy|gotify|telegram|matrix|webhook)$ ]]; then
            echo "ERROR: ${shown} is no destination of ADMIN_NOTIFY: slack://, discord://, teams://, ntfy://, gotify://, telegram://, matrix:// or webhook://, see docs/admin/alerts.md#destinations"
            return 1
        fi
        if [ "${base}" != telegram ] && [ "${shown}" = "${shown%://…}://…" ]; then
            echo "ERROR: ${shown}: an @ after the host, percent-encode / ? # in the user or password (%2F %3F %23)"
            return 1
        fi
        ADMIN_NOTIFY="${ADMIN_NOTIFY:+${ADMIN_NOTIFY},}${entry}"
        NOTIFY_NAMES="${NOTIFY_NAMES:+${NOTIFY_NAMES}, }$(notify_name "${entry}")"
    done
}
step_admin_password() {
    # single sign-on: the password as a way in too (the default), or not (ADMIN_PASSWORD empty)
    ADMIN_KEEP_PASSWORD=yes
    case "${ADMIN_SIGNIN}" in accounts|oidc|header) ;; *) return 0 ;; esac
    hint "The admin UI's password (ADMIN_PASSWORD, generated) as a way in too: when the provider or the proxy is"
    hint "  down, over an SSH tunnel to http://localhost:8090. No: single sign-on only, ADMIN_PASSWORD empty (set"
    hint "  one in .env later to have it back; docs/admin/signing-in.md#security-notes)"
    ask_yn admin_password "Keep a password as a fallback?" yes || return
    ADMIN_KEEP_PASSWORD=${YN}
}
step_admin_notify() {
    # the alerts of the admin UI to other destinations than email (docs/admin/alerts.md#destinations).
    # Not shown as typed: the URLs hold tokens
    ADMIN_NOTIFY="" NOTIFY_NAMES=""
    [ "${ADMIN_UI}" = yes ] || return 0
    hint "Alerts of the admin UI: by email (ADMIN_ALERT_EMAIL in .env, with an SMTP server), and/or to Slack,"
    hint "  Discord, Teams, ntfy, Gotify, Telegram, Matrix or a webhook (docs/admin/alerts.md#destinations)."
    hint "  E.g. ntfy://ntfy.sh/<topic>, slack://hooks.slack.com/services/... Not shown as you type: the URLs hold"
    hint "  tokens. More than one: separated by commas or spaces"
    while :; do
        ask admin_notify "Destinations of the alerts (empty: none)" "" secret || return
        notify_list "${ANSWER}" && break
        retry
    done
    [ -z "${ADMIN_NOTIFY}" ] || echo "Alerts also to ${NOTIFY_NAMES} (ADMIN_NOTIFY in .env; more destinations there, separated by commas)"
}

# --- 5) Backups
step_backups() {
    # the nightly backups (docs/backups.md#the-backup-service): compose's backup profile, the
    # Quadlets' backup timer. Run again on an install: what it has is the default
    local default=no
    previous_profile backup && default=yes
    [ "${DEPLOY_METHOD}" = quadlets ] && systemctl --user is-enabled -q firefox-sync-backup.timer 2> /dev/null && default=yes
    hint "Every night a dump of the databases into config/backup/, the last 7 kept (docs/backups.md#the-backup-service)"
    ask_yn backups "Enable nightly backups?" "${default}" || return
    BACKUPS=${YN}
}

# --- 6) Reverse proxy (setup/proxy.sh writes proxy/ from the answers in .env)
# previous_setting <name> <default>: the value of the .env of before (run again on an install:
# its choices are the defaults), else the default
previous_setting() {
    if [ -f "${SCRIPT_DIR}/.env" ] && env_has "${1}"; then env_plain "${1}"; else printf '%s' "${2}"; fi
}
step_proxy() {
    local options=() default
    default=$(previous_setting PROXY own)
    [ "${default}" = traefik ] && [ "${DEPLOY_METHOD}" = quadlets ] && default=own
    hint "The stack serves plain HTTP on ports of this host: a reverse proxy adds HTTPS and the public host names."
    hint "  proxy/ gets its configuration in any case, for nginx, Caddy and Traefik (docs/reverse-proxy.md)"
    options=("own|I run a reverse proxy already (nginx, Caddy, Traefik, Apache...): I put the file of proxy/ into it")
    # (not with the admin UI's trusted-header sign-in: the bundled Caddy reaches the admin UI on
    # the host's 127.0.0.1, which every process of the host has, so any of them could send the
    # header: trusted_header_shared)
    if [ "${ADMIN_SIGNIN}" = header ]; then
        [ "${default}" = caddy ] && default=own
        hint "  (no bundled Caddy with the admin UI's trusted-header sign-in: it reaches the admin UI from this host's"
        hint "  127.0.0.1, which any process of the host has, and the header would sign it in; docs/admin/signing-in.md#trusted-header)"
        if answer_given proxy && [ "$(lower "${ANSWER}")" = caddy ]; then
            ui_error "proxy=caddy with admin_signin=header: the bundled Caddy reaches the admin UI from 127.0.0.1, which any process of this host has: each could sign in with the header. Sign in with the password or OpenID Connect, or put the admin UI behind a proxy of your own (docs/admin/signing-in.md#trusted-header)"
            exit 1
        fi
    else
        options+=("caddy|no reverse proxy yet: run the bundled Caddy, HTTPS certificates from Let's Encrypt by itself")
    fi
    [ "${DEPLOY_METHOD}" = quadlets ] || options+=("traefik|my Traefik with its Docker provider: labels on the public containers")
    ask_menu proxy "Do you already run a reverse proxy?" "${default}" "${options[@]}" || return
    PROXY=${CHOICE}
    # your own proxy with the trusted-header sign-in: from an address everything has
    if [ "${PROXY}" = own ] && [ -n "${ADMIN_TRUSTED_PROXIES_V}" ] && [ -z "${FFS_REPLAYED_NOW}" ]; then
        trusted_header_shared "${ADMIN_TRUSTED_PROXIES_V}"
    fi
    return 0
}
step_proxy_admin_allow() {
    PROXY_ADMIN_ALLOW_V=$(previous_setting PROXY_ADMIN_ALLOW "$(ENV_READ="${SCRIPT_DIR}/.env-example" env_plain PROXY_ADMIN_ALLOW)")
    [ -n "${ADMIN_URL}" ] || return 0
    hint "The admin UI's public address (${ADMIN_URL}) only from your own addresses: the proxy refuses the others"
    hint "  (docs/reverse-proxy.md#the-admin-ui); by default this host only. Addresses and CIDRs, comma-separated"
    hint "  (your network, your VPN); anybody: no restriction. Not the networks of the containers: a proxy in a"
    hint "  container behind published ports can see their gateway's address for every client"
    while :; do
        ask proxy_admin_allow "Who can open the admin UI's public address" "${PROXY_ADMIN_ALLOW_V:-anybody}" || return
        ANSWER=$(printf '%s' "${ANSWER}" | tr -d ' ')
        [ "$(lower "${ANSWER}")" = anybody ] && { PROXY_ADMIN_ALLOW_V=""; return 0; }
        [[ "${ANSWER}" =~ ^[0-9A-Fa-f.:/]+(,[0-9A-Fa-f.:/]+)*$ ]] && { PROXY_ADMIN_ALLOW_V=${ANSWER}; return 0; }
        echo "ERROR: not a list of addresses or CIDRs (e.g. 192.0.2.0/24,2001:db8::/32): '${ANSWER}'"
        retry
    done
}
step_caddy_email() {
    CADDY_ACME_EMAIL_V=$(previous_setting CADDY_ACME_EMAIL "")
    [ "${PROXY}" = caddy ] || return 0
    hint "The bundled Caddy (docs/reverse-proxy.md#the-bundled-caddy) gets a certificate for each public host name"
    hint "  from Let's Encrypt: the host names must resolve to this host, and ports 80 and 443 be reachable from"
    hint "  the internet. Let's Encrypt writes to this email about them (expiry, changes); empty: none"
    while :; do
        ask caddy_email "Email for Let's Encrypt (empty: none)" "${CADDY_ACME_EMAIL_V}" || return
        [[ "${ANSWER}" =~ ^([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+)?$ ]] && { CADDY_ACME_EMAIL_V=${ANSWER}; return 0; }
        echo "ERROR: not an email: '${ANSWER}'"
        retry
    done
}
step_caddy_ca() {
    CADDY_ACME_CA_V=$(previous_setting CADDY_ACME_CA letsencrypt)
    [ "${PROXY}" = caddy ] || return 0
    ask_menu caddy_ca "Where its certificates come from" "${CADDY_ACME_CA_V}" \
        "letsencrypt|Let's Encrypt, which browsers trust" \
        "staging|Let's Encrypt's staging CA: no browser trusts them, to try the setup first without its rate limits" \
        "internal|Caddy's own CA, without the internet: a network of your own, its root certificate installed on your devices" || return
    CADDY_ACME_CA_V=${CHOICE}
}
# ask_caddy_port <id> <question> <setting> <default>: a port, in the variable <setting>_V
ask_caddy_port() {
    local value
    value=$(previous_setting "${3}" "${4}")
    while :; do
        ask "${1}" "${2}" "${value}" || return
        if [[ "${ANSWER}" =~ ^[0-9]{1,5}$ ]] && [ "$((10#${ANSWER}))" -ge 1 ] && [ "$((10#${ANSWER}))" -le 65535 ]; then
            printf -v "${3}_V" '%s' "$((10#${ANSWER}))"
            return 0
        fi
        echo "ERROR: not a port: '${ANSWER}'"
        retry
    done
}
step_caddy_http_port() {
    CADDY_HTTP_PORT_V=$(previous_setting CADDY_HTTP_PORT 80)
    [ "${PROXY}" = caddy ] || return 0
    hint "The ports of this host it listens on: 80 and 443 for Let's Encrypt, or others with 80 and 443 forwarded"
    hint "  to them (your router)"
    ask_caddy_port caddy_http_port "Its HTTP port" CADDY_HTTP_PORT 80
}
step_caddy_https_port() {
    CADDY_HTTPS_PORT_V=$(previous_setting CADDY_HTTPS_PORT 443)
    [ "${PROXY}" = caddy ] || return 0
    ask_caddy_port caddy_https_port "Its HTTPS port" CADDY_HTTPS_PORT 443 || return
    [ -n "${FFS_REPLAYED_NOW}" ] || caddy_port_checks "${CADDY_HTTP_PORT_V}" "${CADDY_HTTPS_PORT_V}"
    return 0
}
# ask_traefik_name <id> <question> <default> <variable> <none: ok or not> <what>: names,
# comma-separated; with ok, none (also the default when it is empty) for none
ask_traefik_name() {
    local default=${3}
    [ -z "${default}" ] && [ "${5}" = ok ] && default=none
    while :; do
        ask "${1}" "${2}" "${default}" || return
        ANSWER=$(printf '%s' "${ANSWER}" | tr -d ' ')
        if [ "$(lower "${ANSWER}")" = none ] && [ "${5}" = ok ]; then printf -v "${4}" '%s' ""; return 0; fi
        [[ "${ANSWER}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*(,[A-Za-z0-9][A-Za-z0-9_.-]*)*$ ]] && { printf -v "${4}" '%s' "${ANSWER}"; return 0; }
        echo "ERROR: not ${6}: '${ANSWER}'"
        retry
    done
}
step_traefik_network() {
    local own
    TRAEFIK_NETWORK_V=$(previous_setting TRAEFIK_NETWORK "")
    [ "${PROXY}" = traefik ] || return 0
    # (empty: this stack's own, as the labels take it)
    own=$(compose_project)-proxy
    TRAEFIK_NETWORK_V=${TRAEFIK_NETWORK_V:-${own}}
    hint "Your Traefik reads the labels of the containers on the Docker socket (or the Podman one) and reaches the"
    hint "  public ones on a network they join: by default ${own}, of this stack only, which you attach Traefik to."
    hint "  A network other containers are on (Traefik's own, shared) lets them reach these containers past Traefik"
    hint "  (docs/reverse-proxy.md#traefik-labels)"
    while :; do
        ask_traefik_name traefik_network "The network Traefik reaches the public containers on" "${TRAEFIK_NETWORK_V}" TRAEFIK_NETWORK_V no "a network name" || return
        # the admin UI's trusted-header sign-in: Traefik's own address on it, nothing wider
        [ -z "${ADMIN_TRUSTED_PROXIES_V}" ] || traefik_trusted_check "${TRAEFIK_NETWORK_V}" "${ADMIN_TRUSTED_PROXIES_V}" || {
            echo "  change the admin UI's trusted proxies (< back to them, or the part 4 in the review)"; retry; continue; }
        break
    done
    if [ "${TRAEFIK_NETWORK_V}" != "${own}" ]; then
        echo "WARNING: ${TRAEFIK_NETWORK_V}, not a network of this stack's own: every container on it reaches the public containers"
        echo "  directly, the admin UI's port with them, past Traefik and its rules. Keep only Traefik on it (docs/reverse-proxy.md#traefik-labels)"
    fi
    if [ "${CONTAINER_RUNTIME}" != none ] && ! "${CONTAINER_RUNTIME}" network inspect "${TRAEFIK_NETWORK_V}" > /dev/null 2>&1; then
        echo "NOTE: no network ${TRAEFIK_NETWORK_V} here yet, which docker compose up needs, with your Traefik on it:"
        echo "  docker network create ${TRAEFIK_NETWORK_V} && docker network connect ${TRAEFIK_NETWORK_V} <your Traefik's container>"
    fi
    return 0
}
step_traefik_entrypoints() {
    TRAEFIK_ENTRYPOINTS_V=$(previous_setting TRAEFIK_ENTRYPOINTS websecure)
    [ "${PROXY}" = traefik ] || return 0
    ask_traefik_name traefik_entrypoints "Its HTTPS entry point(s), comma-separated" "${TRAEFIK_ENTRYPOINTS_V}" TRAEFIK_ENTRYPOINTS_V no "entry point names"
}
step_traefik_http_entrypoint() {
    TRAEFIK_HTTP_ENTRYPOINT_V=$(previous_setting TRAEFIK_HTTP_ENTRYPOINT web)
    [ "${PROXY}" = traefik ] || return 0
    hint "HTTP redirected to HTTPS there; none: no redirect (e.g. Traefik redirects all of its HTTP already)"
    ask_traefik_name traefik_http_entrypoint "Its HTTP entry point (none: no redirect)" "${TRAEFIK_HTTP_ENTRYPOINT_V}" TRAEFIK_HTTP_ENTRYPOINT_V ok "an entry point name"
}
step_traefik_certresolver() {
    TRAEFIK_CERTRESOLVER_V=$(previous_setting TRAEFIK_CERTRESOLVER "")
    [ "${PROXY}" = traefik ] || return 0
    hint "The certificate resolver of Traefik's static configuration that gets the certificates (ACME); none:"
    hint "  its default certificate (a wildcard of yours, or a load balancer in front)"
    ask_traefik_name traefik_certresolver "Its certificate resolver (none: its default certificate)" "${TRAEFIK_CERTRESOLVER_V}" TRAEFIK_CERTRESOLVER_V ok "a resolver name"
}

# --- 7) Review
# secrets_planned: the passwords and secrets the setup generates for these answers, one per
# line: <setting>|<what it is for>|<how a change works: env (.env alone), reset (.env, set
# again in the database at the next start), db (the database has it too), key (a key: what a
# new one does is said)>. Not those typed (the SMTP password, a client secret, a bootstrap password)
secrets_planned() {
    local own_sync own_fxa
    [ "${EXTERNAL_DB}" = yes ] && own_sync=db || own_sync=reset
    [ "${EXTERNAL_FXA_DB}" = yes ] && own_fxa=db || own_fxa=reset
    [ "${ADMIN_UI}" = yes ] && [ "${ADMIN_KEEP_PASSWORD}" = yes ] && echo "ADMIN_PASSWORD|the admin UI's sign-in password|env"
    echo "SYNC_MASTER_SECRET|signs the Sync tokens: a new one signs every Firefox out of Sync, until it signs in again|key"
    echo "SYNC_METRICS_HASH_SECRET|the key of the hashed account ids in the metrics: a new one starts them over|key"
    if [ "${DATABASE_BACKEND}" = postgres ]; then
        echo "SYNC_POSTGRES_PASSWORD|the Sync server's database user $([ "${EXTERNAL_DB}" = yes ] && echo "${SYNC_POSTGRES_USER}" || echo "(the container's superuser)")|db"
        [ "${EXTERNAL_DB}" = yes ] || echo "SYNC_POSTGRES_APP_PASSWORD|the Sync server's own role in the PostgreSQL container|reset"
    else
        echo "SYNC_TOKENSERVER_DB_PASSWORD|the tokenserver's database user|db"
        echo "SYNC_STORAGE_DB_PASSWORD|the storage's database user|db"
    fi
    echo "ADMIN_DB_PASSWORD|the admin UI's own database users (also for the backups)|${own_sync}"
    [ "${SYNC_DB_BOOTSTRAP_GENERATED:-}" = yes ] && echo "SYNC_DB_BOOTSTRAP_PASSWORD|the account that applies the Sync server's database changes|db"
    if [ "${SELF_HOST_FXA}" = yes ]; then
        echo "FXA_MYSQL_PASSWORD|the accounts' database user $([ "${EXTERNAL_FXA_DB}" = yes ] && echo "${FXA_MYSQL_USER}" || echo "(root of the container)")|db"
        [ "${EXTERNAL_FXA_DB}" = yes ] && echo "FXA_MYSQL_POLICY_PASSWORD|the user that installs the sign-up policy|db"
        echo "FXA_ADMIN_DB_PASSWORD|the admin UI's user of the accounts database|${own_fxa}"
        [ "${FXA_DB_BOOTSTRAP_GENERATED:-}" = yes ] && echo "FXA_DB_BOOTSTRAP_PASSWORD|the account that applies the accounts' database changes|db"
        echo "FXA_AUTH_SECRET FXA_OAUTH_SECRET FXA_PROFILE_SECRET FXA_FLOW_ID_KEY FXA_SESSION_TOKEN_HANDLE_KEY FXA_CONTENT_SESSION_SECRET|the accounts services' own keys: change one only if it leaked, people may have to sign in again|key"
    fi
}
# the restart that applies a change of .env
restart_hint() {
    if [ "${DEPLOY_METHOD}" = quadlets ]; then
        echo "./prepare_environment.sh --render-units, then systemctl --user restart the units it names"
    else
        echo "docker compose up -d"
    fi
}
# secrets_report <review|end>: the generated secrets, said; at the end with how to change each
# kind, and the admin UI's password shown (on a terminal only; never in a log)
secrets_report() {
    local line name what kind value db="" reset="" keys=""
    if [ "${1}" = review ]; then
        echo "  Generated for you, in .env (not shown; listed again at the end, with how to change them):"
        # (lines of up to 96 characters)
        line="   "
        while IFS='|' read -r name what kind; do
            for name in ${name}; do
                [ "$(( ${#line} + ${#name} ))" -gt 96 ] && { echo "${line}"; line="   "; }
                line="${line} ${name},"
            done
        done < <(secrets_planned)
        echo "${line%,}"
        return 0
    fi
    echo ""
    echo "Passwords and secrets generated for you, in .env (this user only), which you can change:"
    while IFS='|' read -r name what kind; do
        case "${kind}" in
            env)
                if [ -n "${FFS_TTY}" ]; then value=$(env_plain ADMIN_PASSWORD); else value="grep ^ADMIN_PASSWORD= .env (not shown here)"; fi
                printf '  %s: %s: %s\n' "${name}" "${what}" "${value}"
                echo "    you sign in with it: keep it in your password manager. To change it: set it in .env, then $(restart_hint)" ;;
            reset) reset="${reset:+${reset}, }${name}"; printf '  %s: %s\n' "${name}" "${what}" ;;
            db) db="${db:+${db}, }${name}"; printf '  %s: %s\n' "${name}" "${what}" ;;
            key) keys="${keys:+${keys}, }${name}"; printf '  %s: %s\n' "${name// /, }" "${what}" ;;
        esac
    done < <(secrets_planned)
    echo "  To change one: set it in .env, then $(restart_hint)."
    [ -z "${reset}" ] || echo "  - ${reset}: the stack sets them again in the database at the next start."
    [ -z "${db}" ] || echo "  - ${db}: the database has them too, change them there first: docs/databases.md#change-a-database-password."
    [ -z "${keys}" ] || echo "  - the keys: what a new one does is said above."
    echo "  More: docs/reference/settings.md#generated-passwords-and-secrets"
}
# ", or the password", or that there is none (single sign-on only)
password_way() { [ "${ADMIN_KEEP_PASSWORD}" = yes ] && printf ', or the password' || printf '; no password (single sign-on only)'; }
# setup_summary: what the answers set up, part by part, the secrets not shown
setup_summary() {
    local db
    echo ""
    echo "${UI_BOLD}What will be written${UI_OFF}"
    local how="docker compose" invite=${SYNC_ALLOWED_ACCOUNTS}
    # (no case in a $(...): bash 3.2 reads its ) as the end)
    case "${DEPLOY_METHOD}" in quadlets) how="Podman Quadlets" ;; compose) how="docker compose with the Podman socket" ;; esac
    case "${INVITE_ONLY}" in off) invite=off ;; admin) invite="the accounts approved in the admin UI" ;; esac
    echo "  1 Deployment: ${how}, in ${SCRIPT_DIR}"
    [ -f "${SCRIPT_DIR}/.env" ] && echo "     its .env written again with new passwords (the one of before kept as a copy)"
    echo "  2 Sync server: ${SYNC_URL}, listening on ${SYNC_EXPORT_PORT}, image tag ${SYNC_IMAGE_TAG}"
    if [ "${EXTERNAL_DB}" = yes ]; then
        if [ "${DATABASE_BACKEND}" = postgres ]; then db="${SYNC_POSTGRES_NAME} (user ${SYNC_POSTGRES_USER})"
        else db="${SYNC_TOKENSERVER_DB_NAME} (user ${SYNC_TOKENSERVER_DB_USER}) and ${SYNC_STORAGE_DB_NAME} (user ${SYNC_STORAGE_DB_USER})"; fi
        echo "     database: ${DATABASE_BACKEND} on your server ${DB_HOST}:${DB_PORT}, ${db}$([ -n "${SYNC_DB_BOOTSTRAP_USER}" ] && echo ", changes applied by the stack as ${SYNC_DB_BOOTSTRAP_USER}")"
    else
        echo "     database: ${DATABASE_BACKEND}, in containers of the stack"
    fi
    echo "     max users: ${SYNC_MAX_USERS}$([ "${ADMIN_UI}" = yes ] && echo ", then managed in the admin UI")"
    if [ "${SELF_HOST_FXA}" = no ]; then
        echo "  3 Accounts: Mozilla's; invite-only Sync: ${invite}"
    else
        echo "  3 Accounts: self-hosted, pages ${FXA_CONTENT_URL_V}, API ${FXA_AUTH_URL_V}, profile ${FXA_PROFILE_URL_V}"
        if [ "${EXTERNAL_FXA_DB}" = yes ]; then
            echo "     database: ${FXA_DB} on your server ${FXA_MYSQL_HOST}:${FXA_MYSQL_PORT}, users ${FXA_MYSQL_USER} and ${FXA_MYSQL_POLICY_USER}$([ -n "${FXA_DB_BOOTSTRAP_USER}" ] && echo ", changes applied by the stack as ${FXA_DB_BOOTSTRAP_USER}")"
        else
            echo "     database: ${FXA_DB}, in a container of the stack"
        fi
        echo "     emails: ${FXA_SMTP_HOST:-no SMTP server}:${FXA_SMTP_PORT}$([ -n "${FXA_SMTP_USER}" ] && echo " as ${FXA_SMTP_USER}")$([ -n "${FXA_SMTP_PASS}" ] && echo " (password as typed, not shown)"), from ${FXA_SMTP_SENDER}"
        echo "     sign-ups: $([ -n "${FXA_SIGNUP_ALLOWLIST}" ] && echo "only ${FXA_SIGNUP_ALLOWLIST}" || echo anybody); max accounts: ${FXA_MAX_ACCOUNTS_ANSWER}; security history: $([ "${FXA_ACCOUNT_EVENTS}" = true ] && echo on || echo off)"
        echo "     pairing server: $([ "${PAIRING}" = yes ] && echo "your own, ${FXA_PAIRING_URL_V}" || echo "Mozilla's")"
    fi
    if [ "${ADMIN_UI}" = yes ]; then
        case "${ADMIN_SIGNIN}" in
            password) echo "  4 Admin UI: on, sign-in with the password (ADMIN_PASSWORD)" ;;
            accounts) echo "  4 Admin UI: on, at ${ADMIN_URL}: sign-in with the self-hosted accounts of ${ADMIN_ALLOWED_USERS}$(password_way)" ;;
            oidc) echo "  4 Admin UI: on, at ${ADMIN_URL}: sign-in with ${ADMIN_OIDC_NAME_V:-single sign-on} (${ADMIN_OIDC_ISSUER_V}, client ${ADMIN_OIDC_CLIENT_ID_V}$([ -n "${ADMIN_OIDC_CLIENT_SECRET_V}" ] && echo ", its secret as typed")${ADMIN_OIDC_SCOPES_V:+, scopes ${ADMIN_OIDC_SCOPES_V}}) for ${ADMIN_ALLOWED_USERS}${ADMIN_ALLOWED_USERS:+${ADMIN_ALLOWED_GROUPS_V:+ and }}${ADMIN_ALLOWED_GROUPS_V:+the groups ${ADMIN_ALLOWED_GROUPS_V}}$(password_way)" ;;
            header) echo "  4 Admin UI: on, sign-in by the header ${ADMIN_AUTH_HEADER_V} from ${ADMIN_TRUSTED_PROXIES_V} for ${ADMIN_ALLOWED_USERS}${ADMIN_ALLOWED_USERS:+${ADMIN_ALLOWED_GROUPS_V:+ and }}${ADMIN_ALLOWED_GROUPS_V:+the groups ${ADMIN_ALLOWED_GROUPS_V}}$(password_way)" ;;
        esac
        echo "     alerts: $([ -n "${ADMIN_NOTIFY}" ] && echo "${NOTIFY_NAMES}" || echo "by email only, once ADMIN_ALERT_EMAIL is set")"
    else
        echo "  4 Admin UI: off"
    fi
    echo "  5 Nightly backups: $([ "${BACKUPS}" = yes ] && echo on || echo off)"
    local ca="Let's Encrypt"
    case "${CADDY_ACME_CA_V}" in internal) ca="its own CA" ;; staging) ca="Let's Encrypt's staging CA" ;; esac
    case "${PROXY}" in
        own) echo "  6 Reverse proxy: yours, its configuration in proxy/ (nginx, Caddy, Traefik)" ;;
        caddy) echo "  6 Reverse proxy: the bundled Caddy on ports ${CADDY_HTTP_PORT_V} and ${CADDY_HTTPS_PORT_V}, certificates of ${ca}${CADDY_ACME_EMAIL_V:+ (${CADDY_ACME_EMAIL_V})}" ;;
        traefik) echo "  6 Reverse proxy: your Traefik, labels for its network ${TRAEFIK_NETWORK_V}, entry points ${TRAEFIK_ENTRYPOINTS_V}${TRAEFIK_HTTP_ENTRYPOINT_V:+ (HTTP: ${TRAEFIK_HTTP_ENTRYPOINT_V})}, ${TRAEFIK_CERTRESOLVER_V:+certificate resolver ${TRAEFIK_CERTRESOLVER_V}}${TRAEFIK_CERTRESOLVER_V:-its default certificate}" ;;
    esac
    [ -z "${ADMIN_URL}" ] || echo "     the admin UI's public address from: ${PROXY_ADMIN_ALLOW_V:-anybody}"
    secrets_report review
}
step_confirm() {
    local n
    FFS_REPLAY_AFTER="" FFS_SECTION_SHOWN=""
    # (write by default each time, whatever was chosen in the review before)
    unset FFS_TYPED_confirm FFS_SEEN_confirm
    ui_header
    setup_summary
    MENU_ALIASES="yes=write y=write no=quit n=quit" ask_menu confirm "Write .env and the examples with these answers?" write \
        "deployment|change the answers of 1 Deployment" "sync|change the answers of 2 Sync server" \
        "accounts|change the answers of 3 Accounts" "admin|change the answers of 4 Admin UI" \
        "backups|change the answers of 5 Nightly backups" "proxy|change the answers of 6 Reverse proxy" \
        "write|write .env and the examples now" \
        "quit|stop here, nothing written" || return
    case "${CHOICE}" in
        write) return 0 ;;
        quit) echo "Nothing written."; exit 0 ;;
    esac
    # (given by its id: write or quit; a part to change is chosen here)
    if [ -z "${FFS_ASKED_NOW}" ]; then
        ui_error "confirm: write or quit, not '${CHOICE}' (a part is changed in the review)"
        exit 2
    fi
    case "${CHOICE}" in deployment) n=1 ;; sync) n=2 ;; accounts) n=3 ;; admin) n=4 ;; backups) n=5 ;; proxy) n=6 ;; esac
    FFS_JUMP=$(section_index "${n}") SECTION_NUMBER_OF_JUMP=${n}
    return 3
}
