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
# files, every random value masked (@SETTING@). A difference meant is listed in EXPECTED_DIFF.
# Then the new setup alone:
# - the interactive flow, its answers on stdin with `<` (back) and a part changed in the
#   review, writes what its answers file writes;
# - the passwords and secrets it generated are listed at the end, the admin UI's password not
#   shown in a log;
# - what the old setup could not do (other host names and ports, the admin UI's sign-in with
#   another provider or a header).
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
git -C "${CODE}" archive "${BASE}" prepare_environment.sh setup | tar -x -C "${WORK}/old" \
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
    rm -f "${W}"/config/nginx/syncstorage-rs.conf "${W}"/config/nginx/fxa.conf "${W}"/config/systemd/syncstorage-rs.service
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

# the differences meant, per case: "<case> <file>" (none: the same files for the same choices)
EXPECTED_DIFF=()
expected() { local e; for e in ${EXPECTED_DIFF[@]+"${EXPECTED_DIFF[@]}"}; do [ "${e}" = "${1} ${2}" ] && return 0; done; return 1; }

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
# alerts, backups; in the review < (back to the backups), then 2 (the Sync server again: its
# answers of before as the defaults, < once more), the parts after it replayed, then write
reset_checkout new
printf '%s\n' "" "" example.org "" "" "" "" "" 5 "<" 2 "" "" "" "" "" "" \
    "<" "" sync \
    "" "" "" "" "" "<" "" 2 \
    write | run_setup docker "${WORK}/interactive.log"
rc=$?
collect "${WORK}/out/interactive"
check "${rc} $(diff -r "${WORK}/out/interactive" "${WORK}/out/new/mozilla-mariadb" > "${WORK}/diff" 2>&1 && echo same)" "0 same" \
    "the interactive flow with < and a part changed in the review writes what the answers file writes" || head -30 "${WORK}/diff"
check "$(grep -c '^2/6 The Sync server$' "${WORK}/interactive.log") $(grep -c '^6/6 Review$' "${WORK}/interactive.log") $(grep -c '^Max users of the Sync server, a number or unlimited \[5\] (< back): $' "${WORK}/interactive.log")" "3 3 1" \
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
check "$(grep -cxE '  server_name (id|id-api|id-profile|qr|sync-admin)\.example\.com;|  server_name id\.example\.com id-api\.example\.com id-profile\.example\.com;' "${W}/config/nginx/fxa.conf") $(grep -c 'server_name ffs.example.net;' "${W}/config/nginx/syncstorage-rs.conf") $(grep -c '^NOTE: https://.* has a port of its own' "${WORK}/custom.log")" \
    "$(grep -c 'server_name <' "${CODE}/config/nginx/fxa-example.conf") 2 2" "the nginx examples with the host names (without the ports, which are said)"
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

[ "${FAILED}" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "${FAILED}"
