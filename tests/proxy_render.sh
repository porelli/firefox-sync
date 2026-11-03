#!/bin/bash
# The configuration of the reverse proxy that prepare_environment.sh writes into proxy/
# (setup/proxy.sh, docs/reverse-proxy.md), for the answer sets of tests/proxy/<case>/settings
# (lines of .env over .env-example; deploy=compose|quadlets): each file the same as the one
# kept next to it (tests/proxy/<case>/<file>; UPDATE=1 writes them again, to review in the
# diff). Then, with a container runtime (docker, found or CONTAINERS=1; CONTAINERS=0: not),
# each file as its proxy reads it: nginx -t (nginx:latest, a test certificate for each host, or
# where the one for all is, PROXY_CERTS=one, and the variant with the containers by name of
# tests/e2e-fxa.sh), caddy validate
# (caddy:latest, also with the snippets of tests/caddy/authelia in caddy.d/), Traefik
# (traefik:latest) with the file provider: every router, middleware and service enabled, none
# with an error, and docker compose config with compose/caddy.yml or proxy/traefik-compose.yml.
#
# Usage: tests/proxy_render.sh   (bash 3.2, macOS, too; no container: the files only)
set -u

TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CODE=$(dirname "${TESTS}")
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ffs-proxy-render.XXXXXX")
NAME=ffs-proxy-render-$$
cleanup() {
    docker rm -f "${NAME}-traefik" "${NAME}-whoami" "${NAME}-nginx" "${NAME}-admin" > /dev/null 2>&1
    docker network rm "${NAME}-net" > /dev/null 2>&1
    docker compose -p "${NAME}-caddy" down -v > /dev/null 2>&1
    rm -rf "${WORK}"
}
trap cleanup EXIT
FAILED=0
check() { if [ "$1" = "$2" ]; then echo "PASS: $3"; else echo "FAIL: $3 (expected '$2', got '$1')"; FAILED=1; return 1; fi; }

# the functions of prepare_environment.sh, its checkout's .env-example; nothing of this shell
export TMPDIR=${WORK}/tmp
mkdir -p "${TMPDIR}"
unset COMPOSE_PROJECT_NAME COMPOSE_FILE
# shellcheck source=prepare_environment.sh
source "${CODE}/prepare_environment.sh" || { echo "FAIL: source prepare_environment.sh"; exit 1; }
SCRIPT_DIR=${CODE}
ffs_temp_init

# case_env <case>: the .env of the case: .env-example with its settings after it (the last line counts)
case_env() {
    { cat "${CODE}/.env-example"; grep -v '^#\|^deploy=' "${TESTS}/proxy/${1}/settings"; } > "${WORK}/${1}.env"
    # (the time of .env in the first lines of each file: always the same)
    TZ=UTC touch -t 202601010000.00 "${WORK}/${1}.env"
}
# the files as kept: the path of the case's .env without this run's directory
masked() { sed "s|${WORK}/|@WORK@/|g" "${1}"; }
case_deploy() { sed -n 's/^deploy=//p' "${TESTS}/proxy/${1}/settings"; }

CASES=$(cd "${TESTS}/proxy" && ls -d -- */ | tr -d /)
echo "== the files of proxy/ for each case"
for c in ${CASES}; do
    case_env "${c}"
    out=${WORK}/${c}
    mkdir -p "${out}"
    # (QUADLET_DIR: no units of this host)
    log=$(ENV_READ=${WORK}/${c}.env QUADLET_DIR=${WORK}/no-units write_proxy "$(case_deploy "${c}")" render "${out}" 2>&1)
    check "$? $(printf '%s' "${log}" | grep -c 'WARNING\|ERROR')" "0 0" "${c}: written" || echo "${log}"
    # the variant of tests/e2e-fxa.sh: nginx on the stack's network
    (ENV_READ=${WORK}/${c}.env QUADLET_DIR=${WORK}/no-units; proxy_routes "$(case_deploy "${c}")" && render_nginx network) > "${WORK}/${c}-nginx-network.conf"
    # (the files: caddy.d/ is yours)
    # every public host of the routing table has its server, site or router in each file
    hosts=$(ENV_READ=${WORK}/${c}.env QUADLET_DIR=${WORK}/no-units; proxy_routes "$(case_deploy "${c}")" \
        && for r in "${PROXY_ROUTES[@]}"; do proxy_split "${r}"; echo "${R_HOST}"; done | sort -u)
    missing=""
    for h in ${hosts}; do
        hre=${h//./\\.}
        grep -qE "^  server_name ${hre};$" "${out}/nginx.conf" || missing="${missing} nginx.conf:${h}"
        grep -qE "^(http://)?${hre}(:[0-9]+)? \\{$" "${out}/Caddyfile" || missing="${missing} Caddyfile:${h}"
        [ ! -f "${out}/Caddyfile.bundled" ] || grep -qE "^(http://)?${hre}(:[0-9]+)? \\{$" "${out}/Caddyfile.bundled" || missing="${missing} Caddyfile.bundled:${h}"
        grep -qF "Host(\`${h}\`)" "${out}/traefik.yml" || missing="${missing} traefik.yml:${h}"
        [ ! -f "${out}/traefik-compose.yml" ] || grep -qF "rule: \"Host(\`${h}\`)" "${out}/traefik-compose.yml" || missing="${missing} traefik-compose.yml:${h}"
    done
    check "$(echo ${hosts} | wc -w | tr -d ' ') [${missing}]" "$(echo ${hosts} | wc -w | tr -d ' ') []" "${c}: every public host of the routing table in each file ($(echo ${hosts}))"
    files=$(cd "${out}" && ls -p | grep -v /)
    if [ -n "${UPDATE:-}" ]; then
        (cd "${TESTS}/proxy/${c}" && ls | grep -v '^settings$' | while read -r f; do rm -f "${f}"; done)
        for f in ${files}; do masked "${out}/${f}" > "${TESTS}/proxy/${c}/${f}"; done
        echo "  written: tests/proxy/${c}/ ($(echo ${files}))"
        continue
    fi
    same=yes
    for f in $(cd "${TESTS}/proxy/${c}" && ls | grep -v '^settings$') ${files}; do
        if ! masked "${out}/${f}" 2> /dev/null | diff -u "${TESTS}/proxy/${c}/${f}" - > "${WORK}/diff" 2>&1; then
            same=no
            echo "  ${f}:"
            sed 's/^/    /' "${WORK}/diff" | head -40
        fi
    done
    check "${same}" yes "${c}: the files kept in tests/proxy/${c}/ ($(echo ${files} | sed 's/ /, /g'); UPDATE=1 writes them again)"
done

# --- as each proxy reads them
case "${CONTAINERS:-}" in
    0) echo "SKIP: CONTAINERS=0, the files are not given to nginx, Caddy, Traefik"; [ "${FAILED}" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"; exit "${FAILED}" ;;
esac
if ! docker info > /dev/null 2>&1; then
    if [ "${CONTAINERS:-}" = 1 ]; then echo "FAIL: CONTAINERS=1, no docker"; exit 1; fi
    echo "SKIP: no docker here, the files are not given to nginx, Caddy, Traefik (CI and the VM do)"
    [ "${FAILED}" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
    exit "${FAILED}"
fi
for image in nginx:latest caddy:latest traefik:latest; do docker pull -q "${image}" > /dev/null; done

# cert_mounts <file>: one certificate for all (PROXY_CERTS=one): the test certificate where the
# file says (nginx's ssl_certificate and its key, an include with them, Caddy's tls, Traefik's
# certFile and keyFile), as docker run's -v
cert_mounts() {
    local f
    for f in $(sed -n -e 's|^  ssl_certificate \(/.*\);$|\1|p' -e 's|^	tls \(/[^ ]*\) .*$|\1|p' -e 's|^    - certFile: \(/.*\)$|\1|p' "${1}" | grep -v '^/etc/letsencrypt/' | sort -u); do
        printf -- '-v %s:%s:ro ' "${WORK}/cert.pem" "${f}"
    done
    for f in $(sed -n -e 's|^  ssl_certificate_key \(/.*\);$|\1|p' -e 's|^	tls /[^ ]* \(/.*\)$|\1|p' -e 's|^      keyFile: \(/.*\)$|\1|p' "${1}" | grep -v '^/etc/letsencrypt/' | sort -u); do
        printf -- '-v %s:%s:ro ' "${WORK}/key.pem" "${f}"
    done
    for f in $(sed -n 's|^  include \(/.*\);$|\1|p' "${1}" | sort -u); do
        printf -- '-v %s:%s:ro -v %s:/etc/ffs-test/cert.pem:ro -v %s:/etc/ffs-test/key.pem:ro ' "${WORK}/ssl-include.conf" "${f}" "${WORK}/cert.pem" "${WORK}/key.pem"
    done
}

echo "== nginx -t (nginx:latest)"
# a test certificate where each ssl_certificate says (one for every host)
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj "/CN=ffs proxy test" \
    -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem" 2> /dev/null || { echo "FAIL: openssl"; exit 1; }
chmod a+r "${WORK}/key.pem" "${WORK}/cert.pem"
# an include of yours with the ssl_* lines (PROXY_NGINX_SSL_INCLUDE)
printf 'ssl_certificate /etc/ffs-test/cert.pem;\nssl_certificate_key /etc/ffs-test/key.pem;\nssl_protocols TLSv1.2 TLSv1.3;\n' > "${WORK}/ssl-include.conf"
chmod a+r "${WORK}/ssl-include.conf"
for c in ${CASES}; do
    for conf in "${WORK}/${c}/nginx.conf" "${WORK}/${c}-nginx-network.conf"; do
        rm -rf "${WORK}/le" && mkdir -p "${WORK}/le"
        for host in $(sed -n 's|^  ssl_certificate /etc/letsencrypt/live/\(.*\)/fullchain.pem;$|\1|p' "${conf}"); do
            mkdir -p "${WORK}/le/live/${host}" && cp "${WORK}/cert.pem" "${WORK}/le/live/${host}/fullchain.pem" && cp "${WORK}/key.pem" "${WORK}/le/live/${host}/privkey.pem"
        done
        chmod -R a+rX "${WORK}/le" && chmod a+r "${conf}"
        # shellcheck disable=SC2046 # (cert_mounts: -v arguments, one word each)
        res=$(docker run --rm -v "${conf}:/etc/nginx/conf.d/default.conf:ro" -v "${WORK}/le:/etc/letsencrypt:ro" $(cert_mounts "${conf}") nginx:latest nginx -t 2>&1)
        check "$? $(printf '%s' "${res}" | grep -c 'test is successful')" "0 1" "${c}: nginx -t, $(basename "${conf}")" || echo "${res}" | tail -5
    done
done

echo "== caddy validate (caddy:latest)"
for c in ${CASES}; do
    for f in Caddyfile Caddyfile.bundled; do
        [ -f "${WORK}/${c}/${f}" ] || continue
        chmod -R a+rX "${WORK}/${c}"
        # shellcheck disable=SC2046 # (cert_mounts: -v arguments, one word each)
        res=$(docker run --rm -v "${WORK}/${c}:/etc/caddy:ro" $(cert_mounts "${WORK}/${c}/${f}") caddy:latest caddy validate --config "/etc/caddy/${f}" --adapter caddyfile 2>&1)
        check "$? $(printf '%s' "${res}" | grep -c '^Valid configuration')" "0 1" "${c}: caddy validate ${f}" || echo "${res}" | tail -5
    done
done
# your snippets in caddy.d/: those of the Authelia test (tests/caddy/authelia)
cp -R "${WORK}/selfhosted-caddy" "${WORK}/hooks" && cp "${TESTS}"/caddy/authelia/*.caddy "${WORK}/hooks/caddy.d/" && chmod -R a+rX "${WORK}/hooks"
res=$(docker run --rm -v "${WORK}/hooks:/etc/caddy:ro" caddy:latest caddy adapt --config /etc/caddy/Caddyfile.bundled --adapter caddyfile 2>&1)
check "$? $(printf '%s' "${res}" | grep -o '"auth\.fxa\.test"\|/api/authz/forward-auth' | sort -u | wc -l | tr -d ' ')" "0 2" \
    "selfhosted-caddy: the snippets of caddy.d/ imported (a site of their own, forward auth in a site)" || echo "${res}" | tail -5

echo "== Traefik (traefik:latest), its file provider"
# api_status <kind> <name>: enabled, or what the API says of it
api_status() {
    local json
    json=$(docker exec "${NAME}-traefik" wget -qO- "http://127.0.0.1:8080/api/http/${1}/${2}@file" 2> /dev/null)
    if [[ "${json}" == *'"status":"enabled"'* ]] && [[ "${json}" != *'"error"'* ]]; then echo enabled; else echo "${json:-none}"; fi
}
for c in ${CASES}; do
    eps=$(ENV_READ=${WORK}/${c}.env proxy_env TRAEFIK_ENTRYPOINTS),$(ENV_READ=${WORK}/${c}.env proxy_env TRAEFIK_HTTP_ENTRYPOINT)
    resolver=$(ENV_READ=${WORK}/${c}.env proxy_env TRAEFIK_CERTRESOLVER)
    args=(--providers.file.filename=/dynamic/traefik.yml --api.insecure=true --log.level=INFO)
    n=8000
    for ep in $(printf '%s' "${eps}" | tr ',' ' '); do args+=("--entrypoints.${ep}.address=:$((n += 1))"); done
    # (a resolver of the static configuration that never reaches an ACME server)
    [ -z "${resolver}" ] || args+=("--certificatesresolvers.${resolver}.acme.email=admin@example.com" "--certificatesresolvers.${resolver}.acme.storage=/tmp/acme.json"
        "--certificatesresolvers.${resolver}.acme.caserver=https://127.0.0.1:1/directory" "--certificatesresolvers.${resolver}.acme.tlschallenge=true")
    chmod a+r "${WORK}/${c}/traefik.yml"
    docker rm -f "${NAME}-traefik" > /dev/null 2>&1
    # shellcheck disable=SC2046 # (cert_mounts: -v arguments, one word each)
    docker run -d --name "${NAME}-traefik" -v "${WORK}/${c}/traefik.yml:/dynamic/traefik.yml:ro" $(cert_mounts "${WORK}/${c}/traefik.yml") traefik:latest "${args[@]}" > /dev/null
    for _ in $(seq 1 30); do docker exec "${NAME}-traefik" wget -qO- http://127.0.0.1:8080/api/overview > /dev/null 2>&1 && break; sleep 1; done
    sleep 2
    bad=""
    for kind in routers middlewares services; do
        for name in $(sed -n "/^  ${kind}:/,/^  [a-z]*:$/p" "${WORK}/${c}/traefik.yml" | sed -n 's/^    \([a-z0-9-]*\):$/\1/p'); do
            status=$(api_status "${kind}" "${name}")
            [ "${status}" = enabled ] || bad="${bad} ${kind}/${name}: ${status}"
        done
    done
    check "[${bad}]" "[]" "${c}: Traefik reads traefik.yml, every router, middleware and service enabled" || docker logs "${NAME}-traefik" 2>&1 | tail -10
    docker rm -f "${NAME}-traefik" > /dev/null 2>&1
done

echo "== docker compose config, with compose/caddy.yml or proxy/traefik-compose.yml"
for c in ${CASES}; do
    [ "$(case_deploy "${c}")" = compose ] || continue
    files=(-f "${CODE}/compose/sync.yml" -f "${CODE}/compose/sync-mariadb.yml")
    fxa_answer=$(ENV_READ=${WORK}/${c}.env fxa_installed && echo yes)
    [ -n "${fxa_answer}" ] && files+=(-f "${CODE}/compose/fxa.yml" -f "${CODE}/compose/fxa-mysql.yml")
    case "$(ENV_READ=${WORK}/${c}.env proxy_env PROXY)" in
        caddy) files+=(-f "${CODE}/compose/caddy.yml") ;;
        traefik) files+=(-f "${WORK}/${c}/traefik-compose.yml") ;;
        *) continue ;;
    esac
    res=$(env -i PATH="${PATH}" HOME="${HOME}" ${DOCKER_HOST:+DOCKER_HOST="${DOCKER_HOST}"} docker compose -p "${NAME}" --env-file "${WORK}/${c}.env" --profile admin --profile pairing "${files[@]}" config 2>&1)
    rc=$?
    case "$(ENV_READ=${WORK}/${c}.env proxy_env PROXY)" in
        caddy) check "${rc} $(printf '%s' "${res}" | grep -c 'target: /etc/caddy$')" "0 1" "${c}: docker compose config with compose/caddy.yml" || echo "${res}" | tail -5 ;;
        traefik) check "${rc} $(printf '%s' "${res}" | grep -c 'traefik.docker.network: ffs-proxy$') $(printf '%s' "${res}" | grep -c 'name: ffs-proxy$')" "0 7 1" \
            "${c}: docker compose config with proxy/traefik-compose.yml, the public containers on Traefik's network" || echo "${res}" | tail -5 ;;
    esac
done

echo "== the bundled Caddy of compose/caddy.yml, on the host's network: the clients' own addresses"
# selfhosted-caddy with Caddy's own CA on ports of its own, the admin UI's host from this host
# only (PROXY_ADMIN_ALLOW=127.0.0.1,::1) and Caddy's access log (a snippet of caddy.d/), the admin
# UI a whoami (traefik/whoami: the request it gets, headers too) with a trusted header set: from
# this host the admin UI's route is let through, without the header a client sends; from a
# container (the host's address on the bridge network) refused (403), Caddy seeing the
# container's own address, not the bridge's gateway, which published ports could show it instead
HTTP_PORT=28790 HTTPS_PORT=28791 WHOAMI_PORT=28792
B=${WORK}/bundled
{ cat "${WORK}/selfhosted-caddy.env"; printf 'CADDY_ACME_CA=internal\nCADDY_HTTP_PORT=%s\nCADDY_HTTPS_PORT=%s\nPROXY_ADMIN_ALLOW=127.0.0.1,::1\nFFS_PROXY_DIR=%s\nADMIN_EXPORT_PORT=127.0.0.1:%s\nADMIN_AUTH_HEADER=Remote-Email\n' \
    "${HTTP_PORT}" "${HTTPS_PORT}" "${B}" "${WHOAMI_PORT}"; } > "${WORK}/bundled.env"
ENV_READ=${WORK}/bundled.env write_proxy compose render "${B}" > /dev/null || echo "FAIL: write_proxy for the bundled Caddy"
printf 'log {\n\toutput stdout\n\tformat json\n}\n' > "${B}/caddy.d/admin-log.caddy"
printf 'services:\n  caddy:\n    volumes:\n      - ${FFS_PROXY_DIR:?}:/etc/caddy:ro\n' > "${WORK}/bundled-compose.yml"
chmod -R a+rX "${B}" "${WORK}/bundled-compose.yml"
bundled() { env -i PATH="${PATH}" HOME="${HOME}" ${DOCKER_HOST:+DOCKER_HOST="${DOCKER_HOST}"} docker compose -p "${NAME}-caddy" --env-file "${WORK}/bundled.env" \
    -f "${CODE}/compose/caddy.yml" -f "${WORK}/bundled-compose.yml" "$@"; }
docker pull -q traefik/whoami:latest > /dev/null
docker run -d --name "${NAME}-whoami" --network host traefik/whoami:latest --port "${WHOAMI_PORT}" > /dev/null
bundled up -d > "${WORK}/bundled-up.log" 2>&1 || { echo "FAIL: the bundled Caddy started"; cat "${WORK}/bundled-up.log"; }
admin_code() { curl -sk -o /dev/null -w '%{http_code}' --resolve "admin.example.com:${HTTPS_PORT}:127.0.0.1" "https://admin.example.com:${HTTPS_PORT}/"; }
for _ in $(seq 1 30); do [ "$(admin_code)" = 200 ] && break; sleep 1; done
forged=$(curl -sk --resolve "admin.example.com:${HTTPS_PORT}:127.0.0.1" -H 'Remote-Email: admin@example.com' "https://admin.example.com:${HTTPS_PORT}/")
gateway=$(docker network inspect bridge -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}')
from_container=$(docker run --rm --add-host "admin.example.com:host-gateway" --entrypoint wget caddy:latest -q -O /dev/null --no-check-certificate \
    "https://admin.example.com:${HTTPS_PORT}/" 2>&1)
sleep 1
remote=$(bundled logs caddy 2>&1 | grep '"status":403' | grep -o '"remote_ip":"[^"]*"' | tail -n 1 | cut -d'"' -f4)
check "$(admin_code) $(printf '%s' "${forged}" | grep -ci '^Remote-Email:') $(printf '%s' "${forged}" | grep -ci '^X-Forwarded-For: 127.0.0.1') $(printf '%s' "${from_container}" | grep -c '403') $([ -n "${remote}" ] && [ "${remote}" != "${gateway}" ] && echo "its own address")" \
    "200 0 1 1 its own address" \
    "the bundled Caddy on the host's network: the admin UI's host from this host, a client's trusted header dropped; refused (403) from a container, which it sees at its own address (${remote:-none}, the gateway ${gateway})" \
    || { bundled logs caddy 2>&1 | tail -10; echo "${from_container}"; echo "${forged}"; }
bundled down -v > /dev/null 2>&1
docker rm -f "${NAME}-whoami" > /dev/null 2>&1

echo "== nginx, the variant on the stack's network: the trusted headers a client sends dropped"
# selfhosted-traefik (ADMIN_AUTH_HEADER, ADMIN_AUTH_GROUPS_HEADER, its admin UI open to anybody):
# nginx:latest and a whoami as ffs-admin on a network of their own
conf=${WORK}/selfhosted-traefik-nginx-network.conf
rm -rf "${WORK}/le" && mkdir -p "${WORK}/le"
for host in $(sed -n 's|^  ssl_certificate /etc/letsencrypt/live/\(.*\)/fullchain.pem;$|\1|p' "${conf}"); do
    mkdir -p "${WORK}/le/live/${host}" && cp "${WORK}/cert.pem" "${WORK}/le/live/${host}/fullchain.pem" && cp "${WORK}/key.pem" "${WORK}/le/live/${host}/privkey.pem"
done
chmod -R a+rX "${WORK}/le" && chmod a+r "${conf}"
docker network create "${NAME}-net" > /dev/null
docker run -d --name "${NAME}-admin" --network "${NAME}-net" --network-alias ffs-admin traefik/whoami:latest --port 8080 > /dev/null
docker run -d --name "${NAME}-nginx" --network "${NAME}-net" -v "${conf}:/etc/nginx/conf.d/default.conf:ro" -v "${WORK}/le:/etc/letsencrypt:ro" nginx:latest > /dev/null
nginx_get() { docker exec "${NAME}-nginx" curl -sk --resolve admin.example.com:443:127.0.0.1 -H 'Remote-Email: admin@example.com' -H 'Remote-Groups: admins' https://admin.example.com/; }
for _ in $(seq 1 30); do nginx_get 2> /dev/null | grep -qi '^Host: admin.example.com' && break; sleep 1; done
forged=$(nginx_get 2>&1)
check "$(printf '%s' "${forged}" | grep -ci '^Host: admin.example.com') $(printf '%s' "${forged}" | grep -ciE '^Remote-(Email|Groups):')" "1 0" \
    "nginx: the admin UI's route, the trusted headers of a client dropped" || { echo "${forged}"; docker logs "${NAME}-nginx" 2>&1 | tail -5; }
docker rm -f "${NAME}-nginx" "${NAME}-admin" > /dev/null 2>&1
docker network rm "${NAME}-net" > /dev/null 2>&1

[ "${FAILED}" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "${FAILED}"
