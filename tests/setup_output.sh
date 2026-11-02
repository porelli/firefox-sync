#!/bin/bash
# (the answers are literal: their $ and quotes are typed as they are; the cases' answers are
# read by name, eval)
# shellcheck disable=SC2016,SC2034
# The setup writes the same files for the same choices as the setup of before its questions
# were reworked (BASE): the old one gets its answers on stdin in its fixed order, the new one
# the same choices by name (--answers, docs/install/compose.md#answers-by-name). Compared for a
# matrix of answer sets (Mozilla's or self-hosted accounts; Sync on MariaDB, MySQL, PostgreSQL;
# the admin UI on or off; your own database servers, with and without the bootstrap; docker
# compose, Quadlets, compose on the Podman socket): .env, the nginx and systemd examples,
# database-setup*.sql and database-bootstrap*.sql, the Quadlet units and their environment
# files, every random value masked (@SETTING@). A difference meant is listed in EXPECTED_DIFF;
# the configuration of the reverse proxy is the new setup's only (NEW_ONLY: proxy/, which
# replaces the nginx examples of config/nginx/ of before, OLD_ONLY), its nginx.conf with the
# same host names and upstreams as those examples.
# Then the new setup alone:
# - the interactive flow, its answers on stdin with `<` (back) and a part changed in the
#   review, writes what its answers file writes;
# - the passwords and secrets it generated are listed at the end, the admin UI's password not
#   shown in a log;
# - what the old setup could not do (other host names and ports, the admin UI's sign-in with
#   another provider or a header, the bundled Caddy, the labels for Traefik).
# No container runtime is used: docker, podman, skopeo and systemctl are stubs (no image, no
# volume, postgres:latest is 18), on a PATH without the real ones; HOME and XDG_CONFIG_HOME are
# temporary (the Quadlet units go there).
#
# Usage: tests/setup_output.sh [case...]   (bash 3.2, macOS, too)
#   BASE   the commit of the setup of before (default: the one before the rework); fetched
#          from origin when the checkout does not have it
set -u

TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CODE=$(dirname "${TESTS}")
# (until promotion: then the old setup's files become saved expected files, and BASE goes)
BASE=${BASE:-83970f2b6a6cc484872bda5f1e78044209458904}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ffs-setup-output.XXXXXX")
trap 'chmod -R u+w "${WORK}" 2> /dev/null; rm -rf "${WORK}"' EXIT
FAILED=0
check() { if [ "$1" = "$2" ]; then echo "PASS: $3"; else echo "FAIL: $3 (expected '$2', got '$1')"; FAILED=1; return 1; fi; }

# the setup of before, from git
if ! git -C "${CODE}" cat-file -e "${BASE}^{commit}" 2> /dev/null; then
    git -C "${CODE}" fetch -q --depth=1 origin "${BASE}" 2> /dev/null
fi
mkdir -p "${WORK}/old"
# (and the nginx examples it wrote its config/nginx/*.conf from)
git -C "${CODE}" archive "${BASE}" prepare_environment.sh setup config/nginx | tar -x -C "${WORK}/old" \
    || { echo "FAIL: the setup of ${BASE} (git archive; BASE=<commit> to choose another)"; exit 1; }

# the programs the setup may run, and nothing else (no interpreter, no tool it did not use
# before: a setup that needs another one fails here, "command not found"); docker, podman,
# skopeo and systemctl are stubs, below
SETUP_TOOLS="bash sh sed grep tr cut head tail sort cat cp mv rm mkdir chmod mktemp dirname basename readlink date od printenv uname cmp ls"
mkdir -p "${WORK}/sys" "${WORK}/stubs-docker" "${WORK}/stubs-podman"
for tool in ${SETUP_TOOLS}; do
    prog=$(command -v "${tool}") || { echo "FAIL: no ${tool} here"; exit 1; }
    ln -s "${prog}" "${WORK}/sys/${tool}"
done
# the checksums of db/db-setup.sh print (database-setup.sql): sha256sum, else shasum (macOS)
for tool in sha256sum shasum; do prog=$(command -v "${tool}") && ln -s "${prog}" "${WORK}/sys/${tool}"; done
# the stubs: postgres:latest is PostgreSQL 18, no volume, no image, no container, no timer
cat > "${WORK}/runtime" <<'EOF'
#!/bin/sh
case "$*" in
    *"--entrypoint postgres "*"--version"*) echo "postgres (PostgreSQL) 18.1 (Debian 18.1-1.pgdg13+2)" ;;
    ps*) exit 0 ;;
    *) exit 1 ;;
esac
EOF
printf '#!/bin/sh\ncase "$*" in *is-enabled*) exit 1 ;; esac\nexit 0\n' > "${WORK}/systemctl"
printf '#!/bin/sh\nexit 1\n' > "${WORK}/skopeo"
chmod +x "${WORK}/runtime" "${WORK}/systemctl" "${WORK}/skopeo"
for stubs in stubs-docker stubs-podman; do
    cp "${WORK}/runtime" "${WORK}/${stubs}/docker"
    cp "${WORK}/systemctl" "${WORK}/skopeo" "${WORK}/${stubs}/"
done
cp "${WORK}/runtime" "${WORK}/stubs-podman/podman"

# and in their code (also what the cases below do not run): no interpreter or tool of another kind
check "$(cat "${CODE}/prepare_environment.sh" "${CODE}"/setup/*.sh | grep -v '^[[:space:]]*#' \
    | grep -cE '(^|[^A-Za-z0-9_./-])(python[0-9.]*|perl|ruby|node|nodejs|php|lua|jq|yq|whiptail|dialog|expect|tclsh|awk|gawk|curl|wget|find|fold)([[:space:]]|$)')" 0 \
    "prepare_environment.sh and setup/ run no interpreter (python, perl...) nor jq, yq, awk, curl, find"

# the checkout the setup runs in, the same path for the old and the new one (it is in the units)
W=${WORK}/ffs
reset_checkout() { # <old|new>
    rm -rf "${W:?}" "${WORK:?}/home"
    mkdir -p "${W}" "${WORK}/home"
    (cd "${CODE}" && tar -cf - --exclude=.git --exclude=.env --exclude='.env.*' --exclude='database-*.sql' .) | tar -xf - -C "${W}"
    rm -rf "${W}"/config/nginx/syncstorage-rs.conf "${W}"/config/nginx/fxa.conf "${W}"/config/systemd/syncstorage-rs.service "${W}/proxy"
    if [ "${1}" = old ]; then rm -rf "${W}/setup" && cp -R "${WORK}/old/." "${W}/"; fi
}
# run_setup <docker|podman> <log> <arguments...>: the setup, in the checkout, stdin as it is
run_setup() {
    local runtime=${1} log=${2}
    shift 2
    (cd "${W}" && env -i PATH="${WORK}/stubs-${runtime}:${WORK}/sys" HOME="${WORK}/home" XDG_CONFIG_HOME="${WORK}/home/.config" \
        USER=ffs-test LC_ALL=C TERM=dumb ./prepare_environment.sh "$@") > "${log}" 2>&1
}
# collect <dir>: the files the setup wrote, its random values masked: the values of .env of
# 24 or 32 letters and digits, and the client id of the admin UI (16 hex), as @SETTING@
collect() {
    local out=${1} f key value sed_file
    mkdir -p "${out}"
    for f in .env config/nginx/syncstorage-rs.conf config/nginx/fxa.conf config/systemd/syncstorage-rs.service \
        database-setup.sql database-setup-fxa.sql database-bootstrap.sql database-bootstrap-fxa.sql; do
        [ -f "${W}/${f}" ] && cp "${W}/${f}" "${out}/$(echo "${f#.}" | tr / _)"
    done
    for f in "${WORK}"/home/.config/containers/systemd/* "${WORK}"/home/.config/systemd/user/*; do
        [ -f "${f}" ] && cp "${f}" "${out}/unit_${f##*/}"
    done
    # the configuration of the reverse proxy (not what it keeps of before, proxy/.generated/)
    for f in "${W}"/proxy/*; do
        [ -f "${f}" ] && cp "${f}" "${out}/proxy_${f##*/}"
    done
    [ -f "${W}/.env" ] || return 0
    sed_file=${WORK}/mask.sed
    : > "${sed_file}"
    while IFS='=' read -r key value; do
        case "${value}" in
            ''|*[!A-Za-z0-9]*) continue ;;
        esac
        if [ "${#value}" = 24 ] || [ "${#value}" = 32 ] || { [ "${key}" = ADMIN_FXA_CLIENT_ID ] && [ "${#value}" = 16 ]; }; then
            printf 's/%s/@%s@/g\n' "${value}" "${key}" >> "${sed_file}"
        fi
    done < <(grep -E '^[A-Z_]+=' "${W}/.env" | LC_ALL=C sort)
    for f in "${out}"/*; do sed -f "${sed_file}" "${f}" > "${f}.masked" && mv "${f}.masked" "${f}"; done
}

# the cases: <name> <runtime>; old_<name>: its answers on stdin, in the old order; new_<name>:
# the answers file. Every old answer list: domain, compose dir, port, max users, backend,
# [deploy method], user, image tag, admin UI, accounts, then as each case says
CASES=()
case_add() { CASES+=("${1}:${2}"); }

case_add mozilla-mariadb docker
old_mozilla_mariadb=(sync.example.org "" "" 2 mariadb "" latest "" n n "" "" n)
new_mozilla_mariadb='domain=example.org
sync_url=sync.example.org
sync_max_users=2'

case_add mozilla-mysql-uids docker
# no admin UI, invite-only with the uids, the backups
old_mozilla_mysql_uids=(sync.example.org "" 5001 3 mysql "" latest n n y "0123456789ABCDEF0123456789abcdef, fedcba9876543210fedcba9876543210" n y)
new_mozilla_mysql_uids='domain=example.org
sync_url=https://sync.example.org
sync_listen=5001
sync_max_users=3
sync_db=mysql
admin=no
sync_invite_only=list
sync_allowed_accounts=" 0123456789ABCDEF0123456789abcdef, fedcba9876543210fedcba9876543210"
backups=yes'

case_add mozilla-postgres-invite docker
# the admin UI approves the accounts, an alert destination, the backups
old_mozilla_postgres_invite=(sync.example.org "" 0.0.0.0:5002 unlimited postgres "" 0.19.0 y n y n "ntfy://ntfy.example.org/ffs-topic" y)
new_mozilla_postgres_invite='domain=example.org
sync_url=sync.example.org
sync_listen=0.0.0.0:5002
sync_max_users=unlimited
sync_db=postgres
sync_image_tag=0.19.0
sync_invite_only=admin
admin_notify=ntfy://ntfy.example.org/ffs-topic
backups=yes'

case_add mozilla-own-mariadb docker
# your own MariaDB server for Sync: host, port, tokenserver database and user, storage database and user; no bootstrap
old_mozilla_own_mariadb=(sync.example.org "" "" 1 mariadb "" latest "" n n y db.example.org "" "" "" sync_storage "" "" n n)
new_mozilla_own_mariadb='domain=example.org
sync_url=sync.example.org
sync_db_own=yes
sync_db_host=db.example.org
sync_storage_db_name=sync_storage'

case_add mozilla-own-postgres-bootstrap docker
# your own PostgreSQL server, port 5433, the stack applies the SQL as the default account, a new password
old_mozilla_own_postgres_bootstrap=(sync.example.org "" "" 1 postgres "" latest n n n y pg.example.org 5433 "" "" n y "" "")
new_mozilla_own_postgres_bootstrap='domain=example.org
sync_url=sync.example.org
sync_db=postgres
admin=no
sync_db_own=yes
sync_db_host=pg.example.org
sync_db_port=5433
sync_db_bootstrap=yes'

case_add selfhosted-full docker
# self-hosted accounts on MySQL, the admin UI signing in with them, the alerts (a Slack URL as
# pasted, turned into slack://), the security history, the backups and the pairing server
old_selfhosted_full=(sync.example.org "" "" 2 mariadb "" latest "" y "" smtp.example.org 587 mailer 'p@ss|w&rd\#1 $x' "" "alice@example.org, @example.net" admin@example.org ""
    n n "" 5 y 'ntfy://tk_ffsSECRET@ntfy.example.org/ffs-topic https://hooks.slack.com/services/T0/B0/ffsSECRET2' y y y)
new_selfhosted_full='domain=example.org
sync_url=sync.example.org
sync_max_users=2
accounts=self-hosted
smtp_host=smtp.example.org
smtp_user=mailer
smtp_password='"'"'p@ss|w&rd\#1 $x'"'"'
fxa_signups=alice@example.org, @example.net
fxa_max_accounts=5
fxa_account_events=yes
pairing=yes
admin_signin=accounts
admin_users=admin@example.org
admin_notify="ntfy://tk_ffsSECRET@ntfy.example.org/ffs-topic https://hooks.slack.com/services/T0/B0/ffsSECRET2"
backups=yes'

case_add selfhosted-postgres-mariadb-noadmin docker
# Sync on PostgreSQL, the accounts on MariaDB, SMTP on 465, no admin UI
old_selfhosted_postgres_mariadb_noadmin=(sync.example.net "" "" 1 postgres "" latest n y example.org mail.example.org 465 "" "" "Accounts <accounts@example.org>" "" n n mariadb "" n n n)
new_selfhosted_postgres_mariadb_noadmin='domain=example.org
sync_url=sync.example.net
sync_db=postgres
admin=no
accounts=self-hosted
fxa_db=mariadb
smtp_host=mail.example.org
smtp_port=465
smtp_sender=Accounts <accounts@example.org>'

case_add selfhosted-own-both-bootstrap docker
# your own servers for Sync (MariaDB) and the accounts (MySQL, another port), both applying their SQL
old_selfhosted_own_both_bootstrap=(sync.example.org "" "" 1 mariadb "" latest "" y "" smtp.example.org 587 "" "" "" "" ""
    y db.example.org "" "" "" "" "" y "" 3307 "" "" "" "" "" "" n n y "" "" y fxa_boot "")
new_selfhosted_own_both_bootstrap='domain=example.org
sync_url=sync.example.org
accounts=self-hosted
smtp_host=smtp.example.org
sync_db_own=yes
sync_db_host=db.example.org
sync_db_bootstrap=yes
fxa_db_own=yes
fxa_db_port=3307
fxa_db_bootstrap=yes
fxa_db_bootstrap_user=fxa_boot'

case_add own-mysql-fxa-mariadb docker
# your own MySQL server for Sync, your own MariaDB server for the accounts, the admin UI's password only
old_own_mysql_fxa_mariadb=(sync.example.org "" "" 1 mysql "" latest y y "" smtp.example.org 587 "" "" "" "" ""
    y db.example.org "" ts ts_user st st_user y fxa-db.example.org "" fxa_user policy_user mariadb unlimited n "" n n n n)
new_own_mysql_fxa_mariadb='domain=example.org
sync_url=sync.example.org
sync_db=mysql
accounts=self-hosted
smtp_host=smtp.example.org
sync_db_own=yes
sync_db_host=db.example.org
sync_tokenserver_db_name=ts
sync_tokenserver_db_user=ts_user
sync_storage_db_name=st
sync_storage_db_user=st_user
fxa_db=mariadb
fxa_db_own=yes
fxa_db_host=fxa-db.example.org
fxa_db_user=fxa_user
fxa_db_policy_user=policy_user'

case_add quadlets-mariadb podman
old_quadlets_mariadb=(sync.example.org "" "" 1 mariadb 1 "" latest "" n "" n "" y)
new_quadlets_mariadb='domain=example.org
sync_url=sync.example.org
backups=yes'

case_add quadlets-selfhosted-mysql podman
old_quadlets_selfhosted_mysql=(sync.example.org "" "" 1 mysql 1 "" latest "" y fxa.example.org mail.example.org 587 test 'p%ss|w&rd' "" "@example.org" "me@example.org" "" n n "" "" "" "" n)
new_quadlets_selfhosted_mysql='domain=fxa.example.org
sync_url=sync.example.org
sync_db=mysql
accounts=self-hosted
smtp_host=mail.example.org
smtp_user=test
smtp_password=p%ss|w&rd
fxa_signups=@example.org
admin_signin=accounts
admin_users=me@example.org'

case_add quadlets-own-postgres podman
old_quadlets_own_postgres=(sync.example.org "" "" 1 postgres 1 "" latest "" "" "" y pg.example.org "" "" "" "" n)
new_quadlets_own_postgres='domain=example.org
sync_url=sync.example.org
sync_db=postgres
sync_db_own=yes
sync_db_host=pg.example.org'

case_add podman-compose podman
old_podman_compose=(sync.example.org "" "" 1 mariadb 2 "" latest "" y "" smtp.example.org 587 "" "" "" "" "" n n "" "" "" "" n n)
new_podman_compose='domain=example.org
sync_url=sync.example.org
deploy=compose
accounts=self-hosted
smtp_host=smtp.example.org'

case_add rerun-selfhosted docker
# run again on an install: its .env of before (accounts on MariaDB from before
# FXA_MARIADB_IMAGE, the backups and the pairing server on, the Sync server on port 5003): its
# choices the defaults, its accounts' MariaDB kept on 11
seed_rerun_selfhosted() {
    sed -e 's|^SYNC_EXPORT_PORT=.*|SYNC_EXPORT_PORT=5003|' -e 's|^# COMPOSE_PROFILES=.*|COMPOSE_PROFILES=admin,backup,pairing|' \
        -e 's|^FXA_DB=.*|FXA_DB=mariadb|' -e 's|^FXA_MYSQL_PASSWORD=.*|FXA_MYSQL_PASSWORD=before|' "${W}/.env-example" > "${W}/.env"
}
old_rerun_selfhosted=(sync.example.org "" "" 1 mariadb "" latest "" y "" smtp.example.org 587 "" "" "" "" "" n n mariadb "" "" "" "" "")
new_rerun_selfhosted='existing=new
domain=example.org
sync_url=sync.example.org
accounts=self-hosted
fxa_db=mariadb
smtp_host=smtp.example.org'

# the differences meant, per case: "<case> <file>" (none: the same files for the same choices);
# for every case: the files of proxy/, the new setup's only, which replace the nginx examples
# of before (compared below for their host names and upstreams)
EXPECTED_DIFF=()
NEW_ONLY="proxy_*" OLD_ONLY="config_nginx_syncstorage-rs.conf config_nginx_fxa.conf"
expected() {
    local e
    for e in ${EXPECTED_DIFF[@]+"${EXPECTED_DIFF[@]}"}; do [ "${e}" = "${1} ${2}" ] && return 0; done
    # (a file of one side only)
    # shellcheck disable=SC2254 # (the patterns of NEW_ONLY)
    case "${2}" in ${NEW_ONLY}) [ ! -f "${WORK}/out/old/${1}/${2}" ] && return 0 ;; esac
    case " ${OLD_ONLY} " in *" ${2} "*) [ ! -f "${WORK}/out/new/${1}/${2}" ] && return 0 ;; esac
    return 1
}
# nginx_names <file...>: the host names of their server_name lines and the upstreams of their
# proxy_pass lines, not commented out, one per line, sorted
nginx_names() {
    cat "$@" 2> /dev/null | grep -E '^[[:space:]]*(server_name|proxy_pass)[[:space:]]' \
        | sed -E 's/^[[:space:]]*(server_name|proxy_pass)[[:space:]]+//; s/;[[:space:]]*$//' | tr ' ' '\n' | grep . | LC_ALL=C sort -u
}

only=" $* "
for c in "${CASES[@]}"; do
    name=${c%%:*} runtime=${c#*:} var=$(echo "${name}" | tr - _)
    [ "${only}" = "  " ] || [[ "${only}" == *" ${name} "* ]] || continue
    echo "== ${name} (${runtime})"
    eval "old=(\"\${old_${var}[@]}\")"
    eval "new=\${new_${var}}"
    reset_checkout old
    [ "$(type -t "seed_${var}")" = function ] && "seed_${var}"
    printf '%s\n' "${old[@]}" | run_setup "${runtime}" "${WORK}/${name}-old.log"
    rc=$?
    check "${rc} $([ -f "${W}/.env" ] && echo env)" "0 env" "${name}: the setup of before" || tail -5 "${WORK}/${name}-old.log"
    collect "${WORK}/out/old/${name}"
    reset_checkout new
    [ "$(type -t "seed_${var}")" = function ] && "seed_${var}"
    printf '%s\n' "${new}" > "${WORK}/${name}.answers"
    run_setup "${runtime}" "${WORK}/${name}-new.log" --answers "${WORK}/${name}.answers" < /dev/null
    rc=$?
    check "${rc} $([ -f "${W}/.env" ] && echo env) $(cat "${WORK}/${name}-old.log" "${WORK}/${name}-new.log" | grep -c 'command not found')" "0 env 0" \
        "${name}: the setup with the answers by name (and both with the programs of SETUP_TOOLS only)" \
        || { grep -h 'command not found' "${WORK}/${name}-old.log" "${WORK}/${name}-new.log"; tail -15 "${WORK}/${name}-new.log"; }
    collect "${WORK}/out/new/${name}"
    cp "${WORK}/${name}-new.log" "${WORK}/out/new/${name}.log"
    files=$(cd "${WORK}/out" && { ls old/"${name}"; ls new/"${name}"; } | LC_ALL=C sort -u)
    same=yes
    for f in ${files}; do
        if ! diff -u "${WORK}/out/old/${name}/${f}" "${WORK}/out/new/${name}/${f}" > "${WORK}/diff" 2>&1; then
            if expected "${name}" "${f}"; then
                echo "  (a difference meant: ${f})"
            else
                same=no
                echo "  ${f}:"
                sed 's/^/    /' "${WORK}/diff" | head -40
            fi
        fi
    done
    check "${same} $(echo "${files}" | wc -w | tr -d ' ')" "yes $(echo "${files}" | wc -w | tr -d ' ')" "${name}: the same files ($(echo ${files} | sed 's/ /, /g'))"
    # proxy/nginx.conf proxies the host names of before to the upstreams of before
    nginx_names "${WORK}/out/old/${name}"/config_nginx_*.conf > "${WORK}/names-old"
    nginx_names "${WORK}/out/new/${name}/proxy_nginx.conf" > "${WORK}/names-new"
    check "$(diff "${WORK}/names-old" "${WORK}/names-new" > "${WORK}/diff" && echo same) $(grep -c . "${WORK}/names-new")" "same $(grep -c . "${WORK}/names-old")" \
        "${name}: proxy/nginx.conf has the host names and upstreams of the nginx examples of before" || sed 's/^/    /' "${WORK}/diff"
done

[ "${only}" = "  " ] || { [ "${FAILED}" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"; exit "${FAILED}"; }

echo "== the generated secrets, said at the end"
log=${WORK}/out/new/selfhosted-full.log
pw=$(grep '^ADMIN_PASSWORD=' "${WORK}/out/new/selfhosted-full/env" | cut -d= -f2)
check "$(grep -c '^Passwords and secrets generated for you' "${log}") $(grep -cE '^  (ADMIN_PASSWORD|SYNC_MASTER_SECRET|SYNC_TOKENSERVER_DB_PASSWORD|FXA_MYSQL_PASSWORD|FXA_ADMIN_DB_PASSWORD): ' "${log}") $(grep -c 'SYNC_POSTGRES_PASSWORD\|FXA_SMTP_PASS\|FXA_MYSQL_POLICY_PASSWORD' "${log}")" "1 5 0" \
    "selfhosted-full: the generated secrets listed, none of PostgreSQL, the policy user or typed (the SMTP password)"
check "$(grep -c 'ADMIN_PASSWORD= .env (not shown here)' "${log}") $(grep -c "${pw:-none}" "${log}") $(grep -c 'docs/databases.md#change-a-database-password' "${log}")" "1 0 1" \
    "selfhosted-full: the admin UI's password not shown in a log, how to change the database users' said"
log=${WORK}/out/new/mozilla-own-postgres-bootstrap.log
check "$(grep -cE '^  (SYNC_POSTGRES_PASSWORD|SYNC_DB_BOOTSTRAP_PASSWORD): ' "${log}") $(grep -c '^  ADMIN_PASSWORD' "${log}") $(grep -c 'SYNC_POSTGRES_APP_PASSWORD' "${log}")" "2 0 0" \
    "mozilla-own-postgres-bootstrap: the bootstrap password generated is listed; no admin UI password, no app role"

echo "== the interactive flow, on stdin: < goes back, a part changed in the review"
# as mozilla-mariadb: dir, container user, domain, Sync URL, listen, image tag, engine, own
# server, max users (5, then < from the accounts: 2), accounts, invite-only, admin UI, sign-in,
# alerts, backups, the reverse proxy; in the review < (back to the proxy), then 2 (the Sync server again: its
# answers of before as the defaults, < once more), the parts after it replayed, then write
reset_checkout new
printf '%s\n' "" "" example.org "" "" "" "" "" 5 "<" 2 "" "" "" "" "" "" "" \
    "<" "" sync \
    "" "" "" "" "" "<" "" 2 \
    write | run_setup docker "${WORK}/interactive.log"
rc=$?
collect "${WORK}/out/interactive"
check "${rc} $(diff -r "${WORK}/out/interactive" "${WORK}/out/new/mozilla-mariadb" > "${WORK}/diff" 2>&1 && echo same)" "0 same" \
    "the interactive flow with < and a part changed in the review writes what the answers file writes" || head -30 "${WORK}/diff"
check "$(grep -c '^2/7 The Sync server$' "${WORK}/interactive.log") $(grep -c '^7/7 Review$' "${WORK}/interactive.log") $(grep -c '^Max users of the Sync server, a number or unlimited \[5\] (< back): $' "${WORK}/interactive.log")" "3 3 1" \
    "its parts with their progress, the answer typed before as the default after <"
# the questions of the parts after the one changed are not asked again
check "$(grep -c '^Which accounts people sign in with \[mozilla\]' "${WORK}/interactive.log")" 2 "the parts after the one changed: their answers taken again, not asked"
# an invalid answer on stdin (no terminal): it stops, nothing written
reset_checkout new
printf '%s\n' "" "" example.org "sync.example.org/sync" | run_setup docker "${WORK}/interactive-bad.log"
check "$? $(grep -c "^ERROR: the Sync server's public URL: only https://host or https://host:port, not 'sync.example.org/sync'" "${WORK}/interactive-bad.log") [$(ls "${W}/.env" 2> /dev/null)]" "1 1 []" \
    "a path in a public URL: refused, nothing written"

echo "== on a terminal: the menus, the answers edited in place, the review (tests/setup_tty.py, a pty)"
reset_checkout new
# (python3 itself, not a shim of a version manager, which the environment below would lack)
PYTHON=$(python3 -c 'import sys; print(sys.executable)' 2> /dev/null)
if [ -x "${PYTHON}" ]; then
    (cd "${W}" && env -i PATH="${WORK}/stubs-docker:${WORK}/sys" HOME="${WORK}/home" XDG_CONFIG_HOME="${WORK}/home/.config" USER=ffs-test \
        LANG=C.UTF-8 TERM=xterm-256color "${PYTHON}" -I "${TESTS}/setup_tty.py" "${W}") > "${WORK}/tty.log" 2>&1
    check "$? $(grep -c '^FAIL' "${WORK}/tty.log") $(grep -c '^PASS' "${WORK}/tty.log")" "0 0 4" "the setup on a terminal (tests/setup_tty.py)" || cat "${WORK}/tty.log"
else
    echo "SKIP: no python3 for the setup on a terminal"
fi

echo "== what the setup of before could not do"
reset_checkout new
cat > "${WORK}/custom.answers" <<'EOF'
domain=example.com
sync_url=https://ffs.example.net:8443
accounts=self-hosted
fxa_content_url=id.example.com
fxa_auth_url=https://id-api.example.com:4443/
fxa_profile_url=https://id-profile.example.com
pairing=yes
pairing_url=wss://qr.example.com
smtp_host=smtp.example.com
admin_signin=oidc
admin_url=https://sync-admin.example.com
admin_oidc_issuer=https://auth.example.com/application/o/ffs/
admin_oidc_client_id=ffs-admin
admin_oidc_client_secret='s3cr3t "x"'
admin_oidc_name=Authentik SSO
admin_groups=ffs-admins
EOF
run_setup docker "${WORK}/custom.log" --answers "${WORK}/custom.answers" < /dev/null
rc=$?
ev() { grep "^$1=" "${W}/.env" | cut -d= -f2-; }
check "${rc} $(ev SYNC_PUBLIC_URL) $(ev FXA_CONTENT_URL) $(ev FXA_AUTH_URL) $(ev FXA_EMAIL_DOMAIN) $(ev FXA_PAIRING_URL)" \
    "0 https://ffs.example.net:8443 https://id.example.com https://id-api.example.com:4443 id-api.example.com wss://qr.example.com" "every public URL as given, FXA_EMAIL_DOMAIN the API's host name"
check "$(ev ADMIN_OIDC_ISSUER) $(ev ADMIN_OIDC_CLIENT_ID) $(ev ADMIN_OIDC_CLIENT_SECRET) $(ev ADMIN_OIDC_REDIRECT_URL) $(ev ADMIN_OIDC_NAME) [$(ev ADMIN_ALLOWED_USERS)] $(ev ADMIN_ALLOWED_GROUPS) [$(ev ADMIN_FXA_CLIENT_ID)]" \
    "https://auth.example.com/application/o/ffs/ ffs-admin 's3cr3t \"x\"' https://sync-admin.example.com/auth/callback \"Authentik SSO\" [] ffs-admins []" \
    "the admin UI signs in with another OpenID Connect provider, its groups"
# proxy/: each host its server, on the port of its URL (and the redirect from HTTP to it)
P=${W}/proxy
check "$(grep -cxE '  server_name (ffs\.example\.net|id|id-api|id-profile|qr|sync-admin)(\.example\.com)?;' "${P}/nginx.conf") $(grep -cx '  listen 8443 ssl;' "${P}/nginx.conf") $(grep -cx '  listen 4443 ssl;' "${P}/nginx.conf") $(grep -c 'return 301 https://$host:8443$request_uri;' "${P}/nginx.conf")" \
    "8 1 1 1" "proxy/nginx.conf: every host name, on the ports of the URLs (and the redirects of the two of their own)"
check "$(grep -cxE '(ffs\.example\.net:8443|id\.example\.com|id-api\.example\.com:4443|id-profile\.example\.com|qr\.example\.com|sync-admin\.example\.com) \{' "${P}/Caddyfile") $(grep -c 'rule: "Host(`id-api.example.com`) && Path(`/v1/account/create`)"' "${P}/traefik.yml")" \
    "6 1" "proxy/Caddyfile and traefik.yml: the same hosts and the sign-up gate"
reset_checkout new
printf 'domain=example.com\nadmin_signin=header\nadmin_trusted_proxies=172.18.0.1/32, 10.0.0.0/8\nadmin_users=alice@example.com\n' > "${WORK}/header.answers"
run_setup docker "${WORK}/header.log" --answers "${WORK}/header.answers" < /dev/null
check "$? $(ev ADMIN_AUTH_HEADER) $(ev ADMIN_TRUSTED_PROXIES) $(ev ADMIN_ALLOWED_USERS) [$(ev ADMIN_OIDC_ISSUER)]" "0 Remote-Email 172.18.0.1/32,10.0.0.0/8 alice@example.com []" \
    "the admin UI signs in by a header of your proxy, for the admins given"
# single sign-on only (no password as a fallback), the scopes of another provider: compose and Quadlets
reset_checkout new
printf '%s\n' domain=example.com admin_signin=oidc admin_oidc_issuer=https://auth.example.com admin_oidc_client_id=ffs-admin \
    "admin_oidc_scopes=openid  email profile groups " admin_groups=ffs-admins admin_password=no > "${WORK}/sso.answers"
run_setup docker "${WORK}/sso.log" --answers "${WORK}/sso.answers" --non-interactive < /dev/null
check "$? [$(ev ADMIN_PASSWORD)] $(ev ADMIN_OIDC_SCOPES) $(grep -c '^  ADMIN_PASSWORD' "${WORK}/sso.log") $(grep -c 'no password (single sign-on only)' "${WORK}/sso.log") $(grep -c '^Admin UI: single sign-on only (ADMIN_PASSWORD empty)' "${WORK}/sso.log")" \
    '0 [] "openid email profile groups" 0 1 1' "another provider, single sign-on only: ADMIN_PASSWORD empty and not listed, the scopes given (spaces tidied)"
reset_checkout new
printf '%s\n' domain=example.com deploy=quadlets accounts=self-hosted smtp_host=smtp.example.com admin_signin=accounts admin_users=me@example.com admin_password=no > "${WORK}/sso-q.answers"
run_setup podman "${WORK}/sso-q.log" --answers "${WORK}/sso-q.answers" --non-interactive < /dev/null
check "$? [$(ev ADMIN_PASSWORD)] [$(ev ADMIN_OIDC_SCOPES)] $(grep -c '^ADMIN_PASSWORD=$' "${WORK}/home/.config/containers/systemd/firefox-sync-admin.env" 2> /dev/null) $(grep -c "ADMIN_PASSWORD=." "${WORK}/home/.config/containers/systemd/firefox-sync-admin.container" "${WORK}/home/.config/containers/systemd/firefox-sync-admin.env" 2> /dev/null | cut -d: -f2 | tr '\n' +)" \
    "0 [] [] 1 0+0+" "the self-hosted accounts, single sign-on only, Quadlets: the admin UI's unit without a password"
reset_checkout new
printf '%s\n' domain=example.com admin_signin=oidc admin_oidc_issuer=https://auth.example.com admin_oidc_client_id=x admin_users=a@example.com > "${WORK}/sso-d.answers"
run_setup docker "${WORK}/sso-d.log" --answers "${WORK}/sso-d.answers" --non-interactive < /dev/null
check "$? $(ev ADMIN_PASSWORD | grep -cE '^[A-Za-z0-9]{24}$') [$(ev ADMIN_OIDC_SCOPES)]" "0 1 []" "another provider by default: the password kept, the scopes the admin UI's default (empty)"
reset_checkout new
printf '%s\n' domain=example.com admin_signin=oidc admin_oidc_issuer=https://auth.example.com admin_oidc_client_id=x admin_users=a@example.com "admin_oidc_scopes=email profile" > "${WORK}/sso-bad.answers"
run_setup docker "${WORK}/sso-bad.log" --answers "${WORK}/sso-bad.answers" --non-interactive < /dev/null
check "$? $(grep -c "the scopes need openid" "${WORK}/sso-bad.log") [$(ls "${W}/.env" 2> /dev/null)]" "1 1 []" "scopes without openid: refused"
# an install there already: upgraded by default (its passwords kept, as --upgrade), nothing asked after it
reset_checkout new
sed -e 's|<REPLACE_WITH_SOMETHING_SECURE>|keepme|' -e 's|<REPLACE_WITH_YOUR_DOMAIN>|sync.example.org|' -e 's|^ADMIN_DB_PASSWORD=.*|ADMIN_DB_PASSWORD=|' "${W}/.env-example" > "${W}/.env"
run_setup docker "${WORK}/upgrade.log" --non-interactive < /dev/null
check "$? $(ev SYNC_MASTER_SECRET) $(ev ADMIN_DB_PASSWORD | grep -cE '^[A-Za-z0-9]{32}$') $(ls "${W}"/.env.before-upgrade-* | wc -l | tr -d ' ') $(grep -c 'Max users' "${WORK}/upgrade.log")" "0 keepme 1 1 0" \
    "an .env there: upgraded by default, its secrets kept, what this release needs added, nothing else asked"
# refused before anything is written: a typo of an id, the accounts' sign-in without them, no admin
reset_checkout new
for bad in "sync_ulr=x|answers for no question" "admin_signin=accounts|one of password, oidc, header" "admin_signin=oidc
admin_oidc_issuer=https://id.example.com
admin_oidc_client_id=x|no admin given, nor a group"; do
    printf '%s\n' "${bad%|*}" > "${WORK}/bad.answers"
    run_setup docker "${WORK}/bad.log" --answers "${WORK}/bad.answers" --non-interactive < /dev/null
    check "$? $(grep -c "${bad##*|}" "${WORK}/bad.log") [$(ls "${W}/.env" 2> /dev/null)]" "$([ "${bad%%=*}" = sync_ulr ] && echo 2 || echo 1) 1 []" "refused: ${bad##*|}"
done

echo "== the reverse proxy: proxy/ for each answer, the bundled Caddy, the labels for Traefik"
P=${W}/proxy
# the bundled Caddy with docker compose: on the host's network (the ports of this host), Let's
# Encrypt's staging CA, the admin UI's public address from two networks
reset_checkout new
printf '%s\n' domain=example.com accounts=self-hosted smtp_host=smtp.example.com admin_signin=accounts admin_users=me@example.com \
    proxy=caddy caddy_email=admin@example.com caddy_ca=staging "proxy_admin_allow=192.0.2.0/24, 2001:db8::/32" > "${WORK}/caddy.answers"
run_setup docker "${WORK}/caddy.log" --answers "${WORK}/caddy.answers" --non-interactive < /dev/null
check "$? $(ev PROXY) $(ev CADDY_ACME_CA) $(ev CADDY_ACME_EMAIL) $(ev PROXY_ADMIN_ALLOW) $(ev COMPOSE_FILE | grep -c '^compose/sync.yml:.*:compose/caddy.yml$')" \
    "0 caddy staging admin@example.com 192.0.2.0/24,2001:db8::/32 1" "the bundled Caddy (compose): .env, compose/caddy.yml in COMPOSE_FILE"
check "$(grep -c '^	acme_ca https://acme-staging-v02' "${P}/Caddyfile.bundled") $(grep -c '^	email admin@example.com$' "${P}/Caddyfile.bundled") $(grep -cE '^	(reverse_proxy (@gate 127\.0\.0\.1:8091|127\.0\.0\.1:3030|127\.0\.0\.1:9000|127\.0\.0\.1:5000)|admin unix//config/caddy-admin\.sock)$' "${P}/Caddyfile.bundled") $(grep -c '^	reverse_proxy 127.0.0.1:3030$' "${P}/Caddyfile") $(grep -c '@outside not remote_ip 192.0.2.0/24 2001:db8::/32$' "${P}/Caddyfile" "${P}/Caddyfile.bundled" | grep -c ':1$') $(grep -cx '  allow 2001:db8::/32;' "${P}/nginx.conf")" \
    "1 1 5 1 2 1" "Caddyfile.bundled: its CA, the ports of this host, its admin API on a socket; Caddyfile, nginx.conf too; the admin UI from PROXY_ADMIN_ALLOW"
check "$(grep -c '^NOTE: https://' "${WORK}/caddy.log") $(grep -c "Let's Encrypt needs every host name of proxy/Caddyfile.bundled to resolve to this host" "${WORK}/caddy.log") $(grep -c '^  6 Reverse proxy: the bundled Caddy on ports 80 and 443, certificates of Let.s Encrypt.s staging CA (admin@example.com)$' "${WORK}/caddy.log")" \
    "0 1 1" "the bundled Caddy: in the review, and what Let's Encrypt needs is said"
# again, the proxy/ of before changed by hand: kept; then --render-proxy after a change of .env,
# and --upgrade back to your own proxy (compose/caddy.yml out of COMPOSE_FILE)
echo "# mine" >> "${P}/nginx.conf"
sed -i.bak 's|^SYNC_PUBLIC_URL=.*|SYNC_PUBLIC_URL=https://ffs.example.com|' "${W}/.env" && rm -f "${W}/.env.bak"
run_setup docker "${WORK}/render-proxy.log" --render-proxy < /dev/null
check "$? $(ls "${P}"/nginx.conf.before-render-* 2> /dev/null | wc -l | tr -d ' ') $(grep -c '^# mine$' "${P}"/nginx.conf.before-render-* "${P}/nginx.conf" | grep -c ':1$') $(grep -c '^ffs.example.com {$' "${P}/Caddyfile.bundled") $(grep -c 'kept as nginx.conf.before-render-' "${WORK}/render-proxy.log")" \
    "0 1 1 1 1" "--render-proxy: proxy/ again from .env, a file changed by hand kept as <file>.before-render-<time>"
run_setup docker "${WORK}/render-proxy-again.log" --render-proxy < /dev/null
check "$? $(grep -c 'is that of .env already' "${WORK}/render-proxy-again.log") $(ls "${P}"/*.before-* | wc -l | tr -d ' ')" "0 1 1" "--render-proxy again: nothing changes"
sed -i.bak 's|^PROXY=.*|PROXY=own|' "${W}/.env" && rm -f "${W}/.env.bak"
run_setup docker "${WORK}/upgrade-proxy.log" --upgrade < /dev/null
check "$? $(ev COMPOSE_FILE | grep -c 'caddy') [$(ls "${P}/Caddyfile.bundled" 2> /dev/null)] $(grep -c 'Caddyfile.bundled (removed)' "${WORK}/upgrade-proxy.log")" "0 0 [] 1" \
    "--upgrade with PROXY=own: compose/caddy.yml out of COMPOSE_FILE, Caddyfile.bundled removed"
# the bundled Caddy as a Quadlet: on the host's network, its own CA, ports of its own
reset_checkout new
printf '%s\n' domain=example.com deploy=quadlets proxy=caddy caddy_ca=internal caddy_http_port=8080 caddy_https_port=8443 > "${WORK}/caddy-q.answers"
run_setup podman "${WORK}/caddy-q.log" --answers "${WORK}/caddy-q.answers" --non-interactive < /dev/null
U=${WORK}/home/.config/containers/systemd
check "$? $(grep -cxE "Network=host|Image=docker.io/library/caddy:latest|Volume=/.*/ffs/proxy:/etc/caddy:ro,z|Exec=caddy run --config /etc/caddy/Caddyfile.bundled --adapter caddyfile" "${U}/firefox-sync-caddy.container") $(ls "${U}"/firefox-sync-caddy-*.volume | wc -l | tr -d ' ') $(ev COMPOSE_FILE | grep -c caddy)" \
    "0 4 2 0" "the bundled Caddy (Quadlets): its unit, on the host's network, proxy/ mounted, its volumes"
check "$(grep -cxE '	(http_port 8080|https_port 8443|skip_install_trust|reverse_proxy 127.0.0.1:5000)' "${P}/Caddyfile.bundled") $(grep -c 'systemctl --user start firefox-sync-caddy.service' "${WORK}/caddy-q.log")" \
    "4 1" "its Caddyfile.bundled: its ports, its own CA, the Sync server on this host's port; how to start it"
printf 'PROXY=own\n' >> "${W}/.env"
run_setup podman "${WORK}/caddy-q-off.log" --render-units < /dev/null
check "$? [$(ls "${U}"/firefox-sync-caddy* 2> /dev/null)] $(grep -c 'firefox-sync-caddy.container (removed)' "${WORK}/caddy-q-off.log")" "0 [] 1" "PROXY=own, --render-units: the bundled Caddy's units removed"
# your Traefik's Docker provider: the labels, its network, two entry points, a resolver, no redirect
reset_checkout new
printf '%s\n' domain=example.com accounts=self-hosted smtp_host=smtp.example.com pairing=yes proxy=traefik traefik_network=web-proxy \
    "traefik_entrypoints=https, https6" traefik_http_entrypoint=none traefik_certresolver=le > "${WORK}/traefik.answers"
run_setup docker "${WORK}/traefik.log" --answers "${WORK}/traefik.answers" --non-interactive < /dev/null
L=${P}/traefik-compose.yml
check "$? $(ev TRAEFIK_NETWORK) $(ev TRAEFIK_ENTRYPOINTS) [$(ev TRAEFIK_HTTP_ENTRYPOINT)] $(ev TRAEFIK_CERTRESOLVER) $(ev COMPOSE_FILE | grep -c ':proxy/traefik-compose.yml$')" \
    "0 web-proxy https,https6 [] le 1" "the labels for Traefik: .env, proxy/traefik-compose.yml in COMPOSE_FILE"
check "$(grep -cE '^  (syncstorage|fxa-content|fxa-auth|fxa-profile-static|fxa-profile|fxa-pairing|ffs-admin):$' "${L}") $(grep -c 'traefik.docker.network: web-proxy$' "${L}") $(grep -c '\.entrypoints: https,https6$' "${L}") $(grep -c '\.tls.certresolver: le$' "${L}") $(grep -c 'redirectscheme' "${L}") $(grep -cx '    name: web-proxy' "${L}")" \
    "7 7 7 7 0 1" "proxy/traefik-compose.yml: the public containers on Traefik's network, a router per route, no redirect"
check "$(grep -c 'traefik.http.routers.ffs-gate.priority: "1000"' "${L}") $(grep -c 'traefik.http.middlewares.ffs-img-strip.stripprefix.prefixes: /img$' "${L}") $(grep -c 'buffering.maxrequestbodybytes: "10485760"' "${L}") $(grep -c 'NOTE: no network web-proxy here' "${WORK}/traefik.log") $(grep -c '^WARNING: web-proxy, not a network of this stack.s own' "${WORK}/traefik.log")" \
    "1 1 1 1 1" "the sign-up gate first, the avatars without /img, the request size; the network not found said, a network not of this stack warned of"
# by default a network of this stack's own (<project>-proxy); the admin UI's trusted-header
# sign-in: Traefik's own address there, never a range of it
reset_checkout new
printf '%s\n' domain=example.com proxy=traefik admin_signin=header admin_users=a@example.com "admin_trusted_proxies=172.30.0.5" > "${WORK}/traefik-own.answers"
run_setup docker "${WORK}/traefik-own.log" --answers "${WORK}/traefik-own.answers" --non-interactive < /dev/null
check "$? $(ev TRAEFIK_NETWORK) $(grep -c 'traefik.docker.network: ffs-proxy$' "${P}/traefik-compose.yml") $(grep -c '^WARNING: .*not a network of this stack' "${WORK}/traefik-own.log") $(grep -c 'docker network create ffs-proxy && docker network connect ffs-proxy' "${WORK}/traefik-own.log")" \
    "0 ffs-proxy 1 0 1" "the labels for Traefik: a network of this stack by default, how to make it and attach Traefik said"
reset_checkout new
printf '%s\n' domain=example.com proxy=traefik admin_signin=header admin_users=a@example.com "admin_trusted_proxies=172.30.0.0/16" > "${WORK}/traefik-range.answers"
run_setup docker "${WORK}/traefik-range.log" --answers "${WORK}/traefik-range.answers" --non-interactive < /dev/null
check "$? $(grep -c '^ERROR: ADMIN_TRUSTED_PROXIES: 172.30.0.0/16 is a range: with the labels for Traefik' "${WORK}/traefik-range.log") [$(ls "${W}/.env" 2> /dev/null)]" "1 1 []" \
    "the labels for Traefik and the trusted-header sign-in: a range of trusted proxies refused, nothing written"
# refused: Traefik's labels with the Quadlets, an address list that is none
reset_checkout new
for bad in "deploy=quadlets
proxy=traefik|one of own, caddy, not 'traefik'" "admin_signin=oidc
admin_oidc_issuer=https://id.example.com
admin_oidc_client_id=x
admin_users=a@example.com
proxy_admin_allow=everyone|not a list of addresses or CIDRs"; do
    printf '%s\n' domain=example.com "${bad%|*}" > "${WORK}/bad.answers"
    run_setup podman "${WORK}/bad.log" --answers "${WORK}/bad.answers" --non-interactive < /dev/null
    check "$? $(grep -c "${bad##*|}" "${WORK}/bad.log") [$(ls "${W}/.env" 2> /dev/null)]" "1 1 []" "refused: ${bad##*|}"
done

[ "${FAILED}" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "${FAILED}"
