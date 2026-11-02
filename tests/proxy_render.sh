#!/bin/bash
# The configuration of the reverse proxy that prepare_environment.sh writes into proxy/
# (setup/proxy.sh, docs/reverse-proxy.md), for the answer sets of tests/proxy/<case>/settings
# (lines of .env over .env-example; deploy=compose|quadlets): each file the same as the one
# kept next to it (tests/proxy/<case>/<file>; UPDATE=1 writes them again, to review in the
# diff). Then, with a container runtime (docker, found or CONTAINERS=1; CONTAINERS=0: not),
# each file as its proxy reads it: nginx -t (nginx:latest, a test certificate for each host,
# and the variant with the containers by name of tests/e2e-fxa.sh), caddy validate
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
cleanup() { docker rm -f "${NAME}-traefik" > /dev/null 2>&1; rm -rf "${WORK}"; }
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
}
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
    files=$(cd "${out}" && ls -p | grep -v /)
    if [ -n "${UPDATE:-}" ]; then
        (cd "${TESTS}/proxy/${c}" && ls | grep -v '^settings$' | while read -r f; do rm -f "${f}"; done)
        for f in ${files}; do cp "${out}/${f}" "${TESTS}/proxy/${c}/${f}"; done
        echo "  written: tests/proxy/${c}/ ($(echo ${files}))"
        continue
    fi
    same=yes
    for f in $(cd "${TESTS}/proxy/${c}" && ls | grep -v '^settings$') ${files}; do
        if ! diff -u "${TESTS}/proxy/${c}/${f}" "${out}/${f}" > "${WORK}/diff" 2>&1; then
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

echo "== nginx -t (nginx:latest)"
# a test certificate where each ssl_certificate says (one for every host)
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj "/CN=ffs proxy test" \
    -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem" 2> /dev/null || { echo "FAIL: openssl"; exit 1; }
for c in ${CASES}; do
    for conf in "${WORK}/${c}/nginx.conf" "${WORK}/${c}-nginx-network.conf"; do
        rm -rf "${WORK}/le" && mkdir -p "${WORK}/le"
        for host in $(sed -n 's|^  ssl_certificate /etc/letsencrypt/live/\(.*\)/fullchain.pem;$|\1|p' "${conf}"); do
            mkdir -p "${WORK}/le/live/${host}" && cp "${WORK}/cert.pem" "${WORK}/le/live/${host}/fullchain.pem" && cp "${WORK}/key.pem" "${WORK}/le/live/${host}/privkey.pem"
        done
        chmod -R a+rX "${WORK}/le" && chmod a+r "${conf}"
        res=$(docker run --rm -v "${conf}:/etc/nginx/conf.d/default.conf:ro" -v "${WORK}/le:/etc/letsencrypt:ro" nginx:latest nginx -t 2>&1)
        check "$? $(printf '%s' "${res}" | grep -c 'test is successful')" "0 1" "${c}: nginx -t, $(basename "${conf}")" || echo "${res}" | tail -5
    done
done

echo "== caddy validate (caddy:latest)"
for c in ${CASES}; do
    for f in Caddyfile Caddyfile.bundled; do
        [ -f "${WORK}/${c}/${f}" ] || continue
        chmod -R a+rX "${WORK}/${c}"
        res=$(docker run --rm -v "${WORK}/${c}:/etc/caddy:ro" caddy:latest caddy validate --config "/etc/caddy/${f}" --adapter caddyfile 2>&1)
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
    docker run -d --name "${NAME}-traefik" -v "${WORK}/${c}/traefik.yml:/dynamic/traefik.yml:ro" traefik:latest "${args[@]}" > /dev/null
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
        traefik) check "${rc} $(printf '%s' "${res}" | grep -c 'traefik.docker.network: web-proxy$') $(printf '%s' "${res}" | grep -c 'name: web-proxy$')" "0 7 1" \
            "${c}: docker compose config with proxy/traefik-compose.yml, the public containers on Traefik's network" || echo "${res}" | tail -5 ;;
    esac
done

[ "${FAILED}" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "${FAILED}"
