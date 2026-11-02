# shellcheck shell=bash
# prepare_environment.sh: the configuration of the reverse proxy in proxy/ (git-ignored, as
# .env), from .env alone: the public URLs, the ports the stack listens on, the optional services
# and the PROXY_* (CADDY_*, TRAEFIK_*) settings (docs/reverse-proxy.md). One routing table
# (proxy_routes), which each flavour renders: nginx, Caddy and Traefik's file provider for a
# proxy of your own on this host, the bundled Caddy (PROXY=caddy) and the labels of Traefik's
# Docker provider (PROXY=traefik). Written by the setup, again by --upgrade, --render-units and
# --render-proxy (write_proxy): a file changed by hand since it was written is kept aside as
# <file>.before-<setup|upgrade|render>-<UTC time>. Sourced by prepare_environment.sh (and the
# tests): functions only, nothing but bash and the tools of the setup (sed, cmp, cp...).

# the request size the proxies let through (a request of the Sync server is up to about 2.5 MB)
PROXY_BODY_NGINX=10m PROXY_BODY_CADDY=10MB PROXY_BODY_BYTES=10485760

# proxy_env <name>: the value of .env (ENV_READ), the old name of a renamed setting too; a
# setting .env does not have: the default of .env-example (an empty value is a value)
proxy_env() {
    local old
    old=$(old_name "${1}")
    if env_has "${1}" || { [ -n "${old}" ] && env_has "${old}"; }; then
        env_value "${1}"
        return
    fi
    ENV_READ="${SCRIPT_DIR}/.env-example" env_plain "${1}"
}
# proxy_local <[address:]port>: where a proxy on this host reaches a port the stack publishes:
# its address, 127.0.0.1 for every interface (0.0.0.0, or a port alone) and [::1] for [::]
# (not localhost, which nginx tries on ::1 first)
proxy_local() {
    local p=${1}
    case "${p}" in
        0.0.0.0:*) p=127.0.0.1:${p##*:} ;;
        "[::]:"*) p="[::1]:${p##*:}" ;;
        *:*) ;;
        *) p=127.0.0.1:${p} ;;
    esac
    printf '%s' "${p}"
}

# The routing table, PROXY_ROUTES: one line per route,
#   <name>|<site>|<scheme>|<host>|<port>|<path>|<on this host>|<on the containers' network>
# name: sync, content, gate, api, img, profile, pairing, admin. site: the host's own name
# (the gate and the API share api, the avatars and the profile server profile), in the order of
# the server blocks; the routes of a site most specific first. path: / (everything), =<path>
# (that path only, every method), <prefix>/ (that prefix, stripped). port: the public URL's,
# empty for its scheme's. Each flavour gives a route what its name says:
#   sync     the request size (Firefox's batches, docs/reverse-proxy.md#request-size)
#   gate     POST /v1/account/create of the API to the admin UI's sign-up gate (docs/reverse-proxy.md#sign-up-gate)
#   img      the avatars: /img/ to the profile's static server without /img
#   pairing  a websocket, which stays open (docs/reverse-proxy.md#pairing)
#   admin    only from PROXY_ADMIN_ALLOW (docs/reverse-proxy.md#the-admin-ui)
# Every route: the Host header as it came, X-Forwarded-For (the client's address, appended:
# FXA_CLIENT_ADDRESS_DEPTH counts from its end, docs/reverse-proxy.md#client-ip-address),
# X-Forwarded-Proto. proxy_routes <compose|quadlets>: the containers' names of that deployment
proxy_routes() {
    local deploy=${1} admin=no pairing=no sync_net=syncstorage:8000 url
    PROXY_ROUTES=()
    case ",$(proxy_env COMPOSE_PROFILES)," in *,admin,*) admin=yes ;; esac
    case ",$(proxy_env COMPOSE_PROFILES)," in *,pairing,*) pairing=yes ;; esac
    if [ "${deploy}" = quadlets ]; then
        # (the Quadlets have no pairing server; the admin UI: its unit, as --upgrade reads it)
        pairing=no sync_net=firefox-sync-syncstorage:8000
        [ -f "${QUADLET_DIR}/firefox-sync-admin.container" ] && admin=yes
    fi
    proxy_route sync sync "$(proxy_env SYNC_PUBLIC_URL)" / SYNC_EXPORT_PORT "${sync_net}" SYNC_PUBLIC_URL
    if fxa_installed; then
        proxy_route content content "$(proxy_env FXA_CONTENT_URL)" / FXA_CONTENT_EXPORT_PORT fxa-content:3030 FXA_CONTENT_URL
        [ "${admin}" = yes ] && proxy_route gate api "$(proxy_env FXA_AUTH_URL)" =/v1/account/create ADMIN_GATE_EXPORT_PORT ffs-admin:8081 FXA_AUTH_URL
        proxy_route api api "$(proxy_env FXA_AUTH_URL)" / FXA_AUTH_EXPORT_PORT fxa-auth:9000 FXA_AUTH_URL
        proxy_route img profile "$(proxy_env FXA_PROFILE_URL)" /img/ FXA_PROFILE_STATIC_EXPORT_PORT fxa-profile-static:1112 FXA_PROFILE_URL
        proxy_route profile profile "$(proxy_env FXA_PROFILE_URL)" / FXA_PROFILE_EXPORT_PORT fxa-profile:1111 FXA_PROFILE_URL
        url=$(proxy_env FXA_PAIRING_URL)
        [ "${pairing}" = yes ] && [ -n "${url}" ] && proxy_route pairing pairing "${url}" / FXA_PAIRING_EXPORT_PORT fxa-pairing:8000 FXA_PAIRING_URL
    fi
    # the admin UI on a host of its own, where a sign-in sends you back (the accounts', another provider's)
    url=$(proxy_env ADMIN_OIDC_REDIRECT_URL)
    if [ "${admin}" = yes ] && [ -n "${url}" ]; then
        proxy_route admin admin "${url%/auth/callback}" / ADMIN_EXPORT_PORT ffs-admin:8080 ADMIN_OIDC_REDIRECT_URL
    fi
    return 0
}
# proxy_route <name> <site> <url> <path> <port setting> <container:port> <url setting>
proxy_route() {
    local u
    if ! u=$(public_url "${3}" https "https http wss ws" "${7}" 2> /dev/null); then
        echo "WARNING: ${7}='${3}' of .env is no scheme://host[:port]: no route for it in proxy/ (docs/reverse-proxy.md#host-names-and-ports)" >&2
        return 0
    fi
    PROXY_ROUTES+=("${1}|${2}|${u%%://*}|$(url_host "${u}")|$(url_port "${u}")|${4}|$(proxy_local "$(proxy_env "${5}")")|${6}")
}
# proxy_split <route>: its fields in R_NAME R_SITE R_SCHEME R_HOST R_PORT R_PATH R_LOCAL R_NET
proxy_split() { IFS='|' read -r R_NAME R_SITE R_SCHEME R_HOST R_PORT R_PATH R_LOCAL R_NET <<< "${1}"; }
# the route over TLS (https, wss)
proxy_tls() { case "${R_SCHEME}" in https|wss) return 0 ;; esac; return 1; }
# the public port of the route: its URL's, else its scheme's
proxy_public_port() { [ -n "${R_PORT}" ] && printf '%s' "${R_PORT}" || { proxy_tls && printf 443 || printf 80; }; }
# what a route is, in a comment
proxy_what() {
    case "${1}" in
        sync) echo "the Sync server (SYNC_PUBLIC_URL), to SYNC_EXPORT_PORT" ;;
        content) echo "the accounts pages (FXA_CONTENT_URL), to FXA_CONTENT_EXPORT_PORT" ;;
        gate) echo "the sign-up gate of the admin UI: /v1/account/create to ADMIN_GATE_EXPORT_PORT (docs/reverse-proxy.md#sign-up-gate)" ;;
        api) echo "the accounts API (FXA_AUTH_URL), to FXA_AUTH_EXPORT_PORT" ;;
        img) echo "the avatars: /img/ to FXA_PROFILE_STATIC_EXPORT_PORT, without /img" ;;
        profile) echo "the accounts profile server (FXA_PROFILE_URL), to FXA_PROFILE_EXPORT_PORT" ;;
        pairing) echo "your own pairing server (FXA_PAIRING_URL), a websocket, to FXA_PAIRING_EXPORT_PORT (docs/reverse-proxy.md#pairing)" ;;
        admin) echo "the admin UI (ADMIN_OIDC_REDIRECT_URL), to ADMIN_EXPORT_PORT, only from PROXY_ADMIN_ALLOW (docs/reverse-proxy.md#the-admin-ui)" ;;
    esac
}
# the addresses of PROXY_ADMIN_ALLOW, separated by spaces (empty: anybody)
proxy_allow() { proxy_env PROXY_ADMIN_ALLOW | tr ',' ' ' | tr -s ' '; }
# the headers of the admin UI's trusted-header sign-in (ADMIN_AUTH_HEADER, ADMIN_AUTH_GROUPS_HEADER),
# separated by spaces: the admin UI's route drops those a client sends (they would sign it in
# through the proxy, a trusted peer; docs/admin/signing-in.md#trusted-header)
proxy_auth_headers() {
    local h g
    h=$(proxy_env ADMIN_AUTH_HEADER) g=$(proxy_env ADMIN_AUTH_GROUPS_HEADER)
    printf '%s' "${h}${h:+${g:+ }}${g}"
}
# the hosts of the routes over TLS on that public port, once each, separated by spaces
proxy_tls_hosts() {
    local r seen=" " port=${1:-}
    for r in ${PROXY_ROUTES[@]+"${PROXY_ROUTES[@]}"}; do
        proxy_split "${r}"
        proxy_tls || continue
        [ -z "${port}" ] || [ "$(proxy_public_port)" = "${port}" ] || continue
        case "${seen}" in *" ${R_HOST} "*) continue ;; esac
        seen="${seen}${R_HOST} "
    done
    seen=${seen# }
    printf '%s' "${seen% }"
}
# proxy_header <comment lines...>: the first lines of a file, with # (both nginx and Caddy, YAML)
proxy_header() {
    local line
    for line in "$@"; do printf '# %s\n' "${line}"; done
    printf '# Written by prepare_environment.sh from .env (docs/reverse-proxy.md), again by --upgrade and\n'
    printf '# --render-proxy: a change of yours is then kept aside, as <file>.before-<...>-<time>.\n'
}

# --- nginx: render_nginx <local|network>. network: the containers by name (Docker's DNS,
# looked up again while it runs), for an nginx on the stack's network (the tests)
render_nginx() {
    local mode=${1} r site="" port ports=" " hosts allow a
    proxy_header "Firefox Sync behind nginx: put this file into nginx's configuration (/etc/nginx/conf.d/ or" \
        "sites-enabled/), with the certificates where ssl_certificate says first (nginx does not start" \
        "without them: certbot certonly --standalone -d <host> for each host below, nginx stopped, or" \
        "certbot --nginx on a server of its own), then: nginx -t && systemctl reload nginx"
    [ "${mode}" = network ] && printf '\n# the containers by name, looked up again while nginx runs (a new container has a new address)\nresolver 127.0.0.11 valid=10s ipv6=off;\n'
    # HTTP to HTTPS, per public port of the hosts over TLS
    for r in ${PROXY_ROUTES[@]+"${PROXY_ROUTES[@]}"}; do
        proxy_split "${r}"; proxy_tls || continue
        port=$(proxy_public_port)
        case "${ports}" in *" ${port} "*) continue ;; esac
        ports="${ports}${port} "
        hosts=$(proxy_tls_hosts "${port}")
        printf '\n# HTTP to HTTPS\nserver {\n  listen 80;\n'
        [ "${mode}" = network ] || printf '  listen [::]:80;\n'
        printf '  server_name %s;\n' "${hosts}"
        if [ "${port}" = 443 ]; then printf '  return 301 https://$host$request_uri;\n}\n'
        else printf '  return 301 https://$host:%s$request_uri;\n}\n' "${port}"; fi
    done
    for r in ${PROXY_ROUTES[@]+"${PROXY_ROUTES[@]}"}; do
        proxy_split "${r}"
        if [ "${R_SITE}" != "${site}" ]; then
            [ -z "${site}" ] || printf '}\n'
            site=${R_SITE}
            printf '\n# %s\nserver {\n' "$(proxy_what "${R_SITE}")"
            port=$(proxy_public_port)
            # (network: a container, IPv4 only)
            if proxy_tls; then
                printf '  listen %s ssl;\n' "${port}"
                [ "${mode}" = network ] || printf '  listen [::]:%s ssl;\n' "${port}"
                printf '  http2 on;\n  server_name %s;\n' "${R_HOST}"
                printf '  ssl_certificate /etc/letsencrypt/live/%s/fullchain.pem;\n  ssl_certificate_key /etc/letsencrypt/live/%s/privkey.pem;\n' "${R_HOST}" "${R_HOST}"
            else
                printf '  listen %s;\n' "${port}"
                [ "${mode}" = network ] || printf '  listen [::]:%s;\n' "${port}"
                printf '  server_name %s;\n' "${R_HOST}"
            fi
            case "${R_SITE}" in
                sync)
                    printf '  # a Sync request can be up to 2.5 MB, more than nginx'"'"'s 1 MB default: without this,\n'
                    printf '  # large batches fail with 413 (docs/reverse-proxy.md#request-size)\n'
                    printf '  client_max_body_size %s;\n' "${PROXY_BODY_NGINX}" ;;
                admin)
                    allow=$(proxy_allow)
                    if [ -n "${allow}" ]; then
                        printf '  # only from PROXY_ADMIN_ALLOW\n'
                        for a in ${allow}; do printf '  allow %s;\n' "${a}"; done
                        printf '  deny all;\n'
                    fi ;;
            esac
        fi
        [ "${R_NAME}" = "${R_SITE}" ] || printf '  # %s\n' "$(proxy_what "${R_NAME}")"
        case "${R_PATH}" in
            =*) printf '  location = %s {\n' "${R_PATH#=}" ;;
            *) printf '  location %s {\n' "${R_PATH}" ;;
        esac
        if [ "${mode}" = network ]; then
            printf '    set $ffs_upstream %s;\n' "${R_NET}"
            case "${R_PATH}" in /?*/) printf '    rewrite ^%s(.*)$ /$1 break;\n' "${R_PATH}" ;; esac
            printf '    proxy_pass http://$ffs_upstream;\n'
        else
            case "${R_PATH}" in
                /?*/) printf '    proxy_pass http://%s/;\n' "${R_LOCAL}" ;;
                *) printf '    proxy_pass http://%s;\n' "${R_LOCAL}" ;;
            esac
        fi
        printf '    proxy_set_header Host $http_host;\n    proxy_set_header X-Real-IP $remote_addr;\n'
        printf '    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n    proxy_set_header X-Forwarded-Proto $scheme;\n'
        printf '    proxy_redirect off;\n'
        case "${R_NAME}" in
            admin)
                for a in $(proxy_auth_headers); do printf '    # the header of the trusted-header sign-in: never the client'"'"'s\n    proxy_set_header %s "";\n' "${a}"; done ;;
            sync) printf '    proxy_read_timeout 120;\n    proxy_connect_timeout 10;\n    gzip off;\n' ;;
            pairing)
                printf '    proxy_http_version 1.1;\n    proxy_set_header Upgrade $http_upgrade;\n    proxy_set_header Connection "upgrade";\n'
                printf '    # a pairing waits for the other device: not closed after 60 s\n    proxy_read_timeout 600;\n' ;;
        esac
        printf '  }\n'
    done
    [ -z "${site}" ] || printf '}\n'
}

# --- Caddy: render_caddy <local|network> [bundled]. bundled: the bundled Caddy's global options
# (its certificates, CADDY_ACME_*; its admin API on a socket; on the host's network, local, its
# ports). network: the containers by name, for a Caddy on the stack's network (the tests). caddy.d/ next to the file: snippets of yours, imported (none: nothing), which stay when
# the file is written again: sites*.caddy beside the sites, <site>*.caddy in that site (sync,
# content, api, profile, pairing, admin), public*.caddy in the five Firefox reaches
render_caddy() {
    local mode=${1} bundled=${2:-} r site="" up allow email ca http https global=""
    proxy_header "Firefox Sync behind Caddy: put this file as your Caddyfile (or import it from yours), then:" \
        "caddy reload. Caddy gets the certificates itself (Let's Encrypt), and redirects HTTP to HTTPS." \
        "Snippets of yours in caddy.d/ next to it are imported: sites*.caddy beside these sites, <site>*.caddy" \
        "(sync, content, api, profile, pairing, admin) in that site, public*.caddy in the five Firefox reaches"
    if [ -n "${bundled}" ]; then
        email=$(proxy_env CADDY_ACME_EMAIL) ca=$(proxy_env CADDY_ACME_CA)
        http=$(proxy_env CADDY_HTTP_PORT) https=$(proxy_env CADDY_HTTPS_PORT)
        [ -z "${email}" ] || global=$'\t'"email ${email}"$'\n'
        case "${ca}" in
            staging) global+=$'\t'"# Let's Encrypt's staging CA: certificates no browser trusts, for a first try"$'\n'
                global+=$'\tacme_ca https://acme-staging-v02.api.letsencrypt.org/directory\n' ;;
            internal)
                global+=$'\t'"# Caddy's own CA (its root: /data/caddy/pki/authorities/local/root.crt, to install where"$'\n'
                global+=$'\t# the certificates must be trusted), certificates of 30 days: the admin UI warns under 14\n'
                global+=$'\tskip_install_trust\n\tcert_issuer internal {\n\t\tlifetime 30d\n\t}\n'
                global+=$'\tpki {\n\t\tca local {\n\t\t\tintermediate_lifetime 60d\n\t\t}\n\t}\n' ;;
        esac
        # (on the host's network: Caddy listens on the host's ports itself)
        if [ "${mode}" = local ]; then
            [ "${http}" = 80 ] || global+=$'\t'"http_port ${http}"$'\n'
            [ "${https}" = 443 ] || global+=$'\t'"https_port ${https}"$'\n'
        fi
        # (its admin API: on a socket of its volume, not on the host's 127.0.0.1:2019)
        global+=$'\tadmin unix//config/caddy-admin.sock\n'
        printf '\n# the bundled Caddy (PROXY=caddy, docs/reverse-proxy.md#the-bundled-caddy): CADDY_ACME_CA=%s\n' "${ca}"
        [ -z "${global}" ] || printf '{\n%s}\n' "${global}"
    fi
    printf '\nimport caddy.d/sites*.caddy\n'
    for r in ${PROXY_ROUTES[@]+"${PROXY_ROUTES[@]}"}; do
        proxy_split "${r}"
        up=${R_LOCAL}; [ "${mode}" = network ] && up=${R_NET}
        if [ "${R_SITE}" != "${site}" ]; then
            [ -z "${site}" ] || printf '}\n'
            site=${R_SITE}
            printf '\n# %s\n' "$(proxy_what "${R_SITE}")"
            proxy_tls || printf 'http://'
            printf '%s%s {\n' "${R_HOST}" "${R_PORT:+:${R_PORT}}"
            [ "${R_SITE}" = admin ] || printf '\timport caddy.d/public*.caddy\n'
            printf '\timport caddy.d/%s*.caddy\n' "${R_SITE}"
            case "${R_SITE}" in
                sync) printf '\t# (docs/reverse-proxy.md#request-size)\n\trequest_body {\n\t\tmax_size %s\n\t}\n' "${PROXY_BODY_CADDY}" ;;
                admin)
                    allow=$(proxy_allow)
                    [ -z "${allow}" ] || printf '\t# only from PROXY_ADMIN_ALLOW\n\t@outside not remote_ip %s\n\trespond @outside 403\n' "${allow}"
                    for a in $(proxy_auth_headers); do printf '\t# the header of the trusted-header sign-in: never the client'"'"'s\n\trequest_header -%s\n' "${a}"; done ;;
            esac
        fi
        [ "${R_NAME}" = "${R_SITE}" ] || printf '\t# %s\n' "$(proxy_what "${R_NAME}")"
        case "${R_PATH}" in
            /) printf '\treverse_proxy %s\n' "${up}" ;;
            =*) printf '\t@%s path %s\n\treverse_proxy @%s %s\n' "${R_NAME}" "${R_PATH#=}" "${R_NAME}" "${up}" ;;
            *) printf '\thandle_path %s* {\n\t\treverse_proxy %s\n\t}\n' "${R_PATH}" "${up}" ;;
        esac
    done
    [ -z "${site}" ] || printf '}\n'
}

# --- Traefik: the names of its routers, middlewares and services: <prefix>-<route>, the compose
# project's (firefox-sync with the Quadlets), so that two stacks do not share them
# (COMPOSE_PROJECT_NAME of this shell, as compose takes it, else of .env, else the directory's)
proxy_prefix() {
    local p
    [ "${1}" = quadlets ] && { printf firefox-sync; return; }
    p=${COMPOSE_PROJECT_NAME:-$(proxy_env COMPOSE_PROJECT_NAME)}
    if [ -n "${p}" ]; then normalize_project "${p}"; else compose_project; fi
}
# the network Traefik reaches the public containers on: TRAEFIK_NETWORK, empty: <project>-proxy,
# this stack's own (on it only Traefik and those containers: none other reaches them past it)
traefik_network() {
    local net
    net=$(proxy_env TRAEFIK_NETWORK)
    printf '%s' "${net:-$(proxy_prefix compose)-proxy}"
}
# the entry points of a route: TRAEFIK_ENTRYPOINTS over TLS, TRAEFIK_HTTP_ENTRYPOINT otherwise
traefik_entrypoints() {
    if proxy_tls; then proxy_env TRAEFIK_ENTRYPOINTS; else
        local http; http=$(proxy_env TRAEFIK_HTTP_ENTRYPOINT); printf '%s' "${http:-$(proxy_env TRAEFIK_ENTRYPOINTS)}"; fi
}
# the rule of a route
traefik_rule() {
    case "${R_PATH}" in
        /) printf 'Host(`%s`)' "${R_HOST}" ;;
        =*) printf 'Host(`%s`) && Path(`%s`)' "${R_HOST}" "${R_PATH#=}" ;;
        *) printf 'Host(`%s`) && PathPrefix(`%s`)' "${R_HOST}" "${R_PATH}" ;;
    esac
}
# the middlewares of a route, comma-separated
traefik_middlewares() {
    local p=${1}
    case "${R_NAME}" in
        sync) printf '%s-sync-body' "${p}" ;;
        img) printf '%s-img-strip' "${p}" ;;
        admin)
            local mws=""
            [ -n "$(proxy_allow)" ] && mws="${p}-admin-allow"
            [ -n "$(proxy_auth_headers)" ] && mws="${mws:+${mws},}${p}-admin-headers"
            printf '%s' "${mws}" ;;
    esac
}
# the hosts redirected from HTTP to HTTPS, as a rule
traefik_redirect_rule() {
    local h rule=""
    for h in $(proxy_tls_hosts); do rule="${rule:+${rule} || }Host(\`${h}\`)"; done
    printf '%s' "${rule}"
}
# render_traefik_file: the dynamic configuration of the file provider, the stack on this host
render_traefik_file() {
    local p r mw ep resolver http rule
    p=$(proxy_prefix "${1}") resolver=$(proxy_env TRAEFIK_CERTRESOLVER) http=$(proxy_env TRAEFIK_HTTP_ENTRYPOINT)
    proxy_header "Firefox Sync behind Traefik: a dynamic configuration of its file provider (providers.file," \
        "filename or directory): put this file there, Traefik reads it again by itself. Traefik on this host" \
        "(the stack's ports are on 127.0.0.1); in a container, see the labels (PROXY=traefik). Entry points:" \
        "TRAEFIK_ENTRYPOINTS, TRAEFIK_HTTP_ENTRYPOINT; certificates: TRAEFIK_CERTRESOLVER (empty: the default)"
    printf 'http:\n  routers:\n'
    for r in ${PROXY_ROUTES[@]+"${PROXY_ROUTES[@]}"}; do
        proxy_split "${r}"
        printf '    # %s\n    %s-%s:\n' "$(proxy_what "${R_NAME}")" "${p}" "${R_NAME}"
        printf '      rule: "%s"\n' "$(traefik_rule)"
        case "${R_PATH}" in /) ;; *) printf '      priority: 1000\n' ;; esac
        ep=$(traefik_entrypoints)
        printf '      entryPoints: [%s]\n' "$(printf '%s' "${ep}" | sed 's/,/, /g')"
        printf '      service: %s-%s\n' "${p}" "${R_NAME}"
        mw=$(traefik_middlewares "${p}")
        [ -z "${mw}" ] || printf '      middlewares: [%s]\n' "${mw//,/, }"
        if proxy_tls; then
            if [ -n "${resolver}" ]; then printf '      tls:\n        certResolver: %s\n' "${resolver}"; else printf '      tls: {}\n'; fi
        fi
    done
    rule=$(traefik_redirect_rule)
    if [ -n "${http}" ] && [ -n "${rule}" ]; then
        printf '    # HTTP to HTTPS\n    %s-https:\n      rule: "%s"\n      entryPoints: [%s]\n      middlewares: [%s-https]\n      service: noop@internal\n' \
            "${p}" "${rule}" "${http}" "${p}"
    fi
    printf '  middlewares:\n'
    printf '    %s-https:\n      redirectScheme:\n        scheme: https\n        permanent: true\n' "${p}"
    for r in ${PROXY_ROUTES[@]+"${PROXY_ROUTES[@]}"}; do
        proxy_split "${r}"
        case "${R_NAME}" in
            sync) printf '    # (docs/reverse-proxy.md#request-size)\n    %s-sync-body:\n      buffering:\n        maxRequestBodyBytes: %s\n' "${p}" "${PROXY_BODY_BYTES}" ;;
            img) printf '    %s-img-strip:\n      stripPrefix:\n        prefixes: ["/img"]\n' "${p}" ;;
            admin)
                [ -z "$(proxy_allow)" ] || printf '    %s-admin-allow:\n      ipAllowList:\n        sourceRange: ["%s"]\n' "${p}" "$(proxy_allow | sed 's/ /", "/g')"
                if [ -n "$(proxy_auth_headers)" ]; then
                    printf '    # the headers of the trusted-header sign-in: never the client'"'"'s\n    %s-admin-headers:\n      headers:\n        customRequestHeaders:\n' "${p}"
                    for a in $(proxy_auth_headers); do printf '          %s: ""\n' "${a}"; done
                fi ;;
        esac
    done
    printf '  services:\n'
    for r in ${PROXY_ROUTES[@]+"${PROXY_ROUTES[@]}"}; do
        proxy_split "${r}"
        printf '    %s-%s:\n      loadBalancer:\n        servers:\n          - url: "http://%s"\n' "${p}" "${R_NAME}" "${R_LOCAL}"
    done
}
# render_traefik_labels: a compose file (COMPOSE_FILE, PROXY=traefik) that puts the public
# containers on TRAEFIK_NETWORK too, with the labels of Traefik's Docker provider for them
render_traefik_labels() {
    local p r svc services="" net resolver http mw rule port
    p=$(proxy_prefix compose) net=$(traefik_network) resolver=$(proxy_env TRAEFIK_CERTRESOLVER) http=$(proxy_env TRAEFIK_HTTP_ENTRYPOINT)
    proxy_header "Firefox Sync behind your Traefik, its Docker provider (PROXY=traefik): a compose file of" \
        "COMPOSE_FILE, which puts the public containers on ${net} (TRAEFIK_NETWORK) with the labels of" \
        "their routers. That network must exist, with Traefik on it and nothing else: docker network create" \
        "${net}, docker network connect ${net} <your Traefik> (docs/reverse-proxy.md#traefik-labels)." \
        "Applied by docker compose up -d; also on the Podman socket"
    printf 'services:\n'
    # the containers in the order of their first route
    for r in ${PROXY_ROUTES[@]+"${PROXY_ROUTES[@]}"}; do
        proxy_split "${r}"; svc=${R_NET%%:*}
        case " ${services} " in *" ${svc} "*) ;; *) services="${services:+${services} }${svc}" ;; esac
    done
    for svc in ${services}; do
        printf '  %s:\n    networks:\n      default: {}\n      traefik: {}\n    labels:\n' "${svc}"
        printf '      traefik.enable: "true"\n      traefik.docker.network: %s\n' "${net}"
        for r in ${PROXY_ROUTES[@]+"${PROXY_ROUTES[@]}"}; do
            proxy_split "${r}"
            [ "${R_NET%%:*}" = "${svc}" ] || continue
            port=${R_NET##*:}
            printf '      # %s\n' "$(proxy_what "${R_NAME}")"
            printf '      traefik.http.routers.%s-%s.rule: "%s"\n' "${p}" "${R_NAME}" "$(traefik_rule)"
            case "${R_PATH}" in /) ;; *) printf '      traefik.http.routers.%s-%s.priority: "1000"\n' "${p}" "${R_NAME}" ;; esac
            printf '      traefik.http.routers.%s-%s.entrypoints: %s\n' "${p}" "${R_NAME}" "$(traefik_entrypoints)"
            printf '      traefik.http.routers.%s-%s.service: %s-%s\n' "${p}" "${R_NAME}" "${p}" "${R_NAME}"
            if proxy_tls; then
                if [ -n "${resolver}" ]; then printf '      traefik.http.routers.%s-%s.tls.certresolver: %s\n' "${p}" "${R_NAME}" "${resolver}"
                else printf '      traefik.http.routers.%s-%s.tls: "true"\n' "${p}" "${R_NAME}"; fi
            fi
            mw=$(traefik_middlewares "${p}")
            [ -z "${mw}" ] || printf '      traefik.http.routers.%s-%s.middlewares: %s\n' "${p}" "${R_NAME}" "${mw}"
            printf '      traefik.http.services.%s-%s.loadbalancer.server.port: "%s"\n' "${p}" "${R_NAME}" "${port}"
            case "${R_NAME}" in
                sync)
                    printf '      traefik.http.middlewares.%s-sync-body.buffering.maxrequestbodybytes: "%s"\n' "${p}" "${PROXY_BODY_BYTES}"
                    rule=$(traefik_redirect_rule)
                    if [ -n "${http}" ] && [ -n "${rule}" ]; then
                        printf '      # HTTP to HTTPS\n      traefik.http.routers.%s-https.rule: "%s"\n' "${p}" "${rule}"
                        printf '      traefik.http.routers.%s-https.entrypoints: %s\n      traefik.http.routers.%s-https.middlewares: %s-https\n' "${p}" "${http}" "${p}" "${p}"
                        printf '      traefik.http.routers.%s-https.service: noop@internal\n' "${p}"
                        printf '      traefik.http.middlewares.%s-https.redirectscheme.scheme: https\n      traefik.http.middlewares.%s-https.redirectscheme.permanent: "true"\n' "${p}" "${p}"
                    fi ;;
                img) printf '      traefik.http.middlewares.%s-img-strip.stripprefix.prefixes: /img\n' "${p}" ;;
                admin)
                    [ -z "$(proxy_allow)" ] || printf '      traefik.http.middlewares.%s-admin-allow.ipallowlist.sourcerange: "%s"\n' "${p}" "$(proxy_allow | tr ' ' ',')"
                    for a in $(proxy_auth_headers); do printf '      traefik.http.middlewares.%s-admin-headers.headers.customrequestheaders.%s: ""\n' "${p}" "${a}"; done ;;
            esac
        done
    done
    printf 'networks:\n  traefik:\n    name: %s\n    external: true\n' "${net}"
}

# --- the README of proxy/
render_proxy_readme() {
    local proxy=${1} deploy=${2}
    printf '# The configuration of your reverse proxy\n\n'
    printf 'Written by `prepare_environment.sh` from `.env`: the public URLs, the ports the stack listens on and the `PROXY` settings. Again by `./prepare_environment.sh --upgrade` (and `--render-units`, `--render-proxy`): a file you changed is then kept as `<file>.before-<...>-<time>`. See docs/reverse-proxy.md.\n\n'
    printf 'Pick the file of your proxy, put it where it says, reload:\n\n'
    printf -- '- `nginx.conf`: nginx. Into `/etc/nginx/conf.d/` (or `sites-enabled/`), with the certificates where `ssl_certificate` says first (`certbot certonly --standalone -d <host>`, nginx stopped), then `nginx -t && systemctl reload nginx`.\n'
    printf -- '- `Caddyfile`: Caddy. As your Caddyfile, or `import` it from yours, then `caddy reload`. Your own snippets go in `caddy.d/` next to it (see its first lines): they stay when it is written again.\n'
    printf -- '- `traefik.yml`: Traefik, its file provider (`providers.file`). Into its directory, Traefik reads it by itself.\n'
    printf '\nThese three proxy to the ports of this host (127.0.0.1): your proxy runs on this host.\n'
    case "${proxy}" in
        caddy)
            printf '\n`PROXY=caddy`: the bundled Caddy runs `Caddyfile.bundled`, on the host'"'"'s network, '
            if [ "${deploy}" = quadlets ]; then printf 'its Quadlet: `systemctl --user restart firefox-sync-caddy.service` after a change.\n'
            else printf 'compose/caddy.yml of `COMPOSE_FILE`: `docker compose restart caddy` after a change.\n'; fi ;;
        traefik)
            printf '\n`PROXY=traefik`: `traefik-compose.yml` is in `COMPOSE_FILE`: the labels of your Traefik'"'"'s Docker provider on the public containers, which it puts on `%s` (`TRAEFIK_NETWORK`), a network of this stack with Traefik on it and nothing else. `docker compose up -d` applies them.\n' "$(traefik_network)" ;;
    esac
}

# render_proxy <dir> <compose|quadlets>: every file of proxy/ for .env, into dir
render_proxy() {
    local dir=${1} deploy=${2} proxy
    proxy=$(proxy_env PROXY)
    proxy_routes "${deploy}"
    render_nginx local > "${dir}/nginx.conf" || return 1
    render_caddy local > "${dir}/Caddyfile" || return 1
    render_traefik_file "${deploy}" > "${dir}/traefik.yml" || return 1
    case "${proxy}" in
        # (compose and the Quadlet: on the host's network, which gives Caddy the clients' own
        # addresses, PROXY_ADMIN_ALLOW's; the ports of this host)
        caddy) render_caddy local bundled > "${dir}/Caddyfile.bundled" || return 1 ;;
        traefik) render_traefik_labels > "${dir}/traefik-compose.yml" || return 1 ;;
    esac
    render_proxy_readme "${proxy}" "${deploy}" > "${dir}/README.md"
}

# write_proxy <compose|quadlets> <setup|upgrade|render> [dir]: proxy/ (or dir) written from .env.
# A file there that differs from what was written last (proxy/.generated/ has that) is kept as
# <file>.before-<why>-<UTC time> first; a file no longer written (another PROXY) goes, kept so
# when it was changed. caddy.d/ is yours: made, never written
write_proxy() {
    local deploy=${1} why=${2} dir=${3:-${SCRIPT_DIR}/proxy} stage f name kept=() written=()
    mkdir -p "${dir}/.generated" "${dir}/caddy.d" || { echo "ERROR: could not make ${dir}"; return 1; }
    stage=$(mktemp -d "${dir}/.stage.XXXXXX") || return 1
    ffs_temp "${stage}"
    if ! render_proxy "${stage}" "${deploy}"; then
        rm -rf "${stage}"; echo "ERROR: could not write the configuration of the reverse proxy into ${dir}"; return 1
    fi
    # a file changed by hand: kept aside
    keep_edited() {
        local file=${dir}/${1} backup
        [ -f "${file}" ] || return 0
        if [ -f "${dir}/.generated/${1}" ]; then cmp -s "${file}" "${dir}/.generated/${1}" && return 0
        elif [ -f "${stage}/${1}" ]; then cmp -s "${file}" "${stage}/${1}" && return 0; fi
        backup=$(backup_name "${file}.before-${why}")
        cp -p "${file}" "${backup}" && kept+=("$(basename "${backup}")")
    }
    for f in "${stage}"/*; do
        name=$(basename "${f}")
        keep_edited "${name}" || { rm -rf "${stage}"; return 1; }
        cmp -s "${f}" "${dir}/${name}" || written+=("${name}")
        cp "${f}" "${dir}/${name}" && cp "${f}" "${dir}/.generated/${name}" || { rm -rf "${stage}"; return 1; }
    done
    # those of another PROXY
    for f in "${dir}"/.generated/*; do
        [ -f "${f}" ] || continue
        name=$(basename "${f}")
        [ -f "${stage}/${name}" ] && continue
        keep_edited "${name}"
        rm -f "${dir}/${name}" "${f}"
        written+=("${name} (removed)")
    done
    rm -rf "${stage}"
    if [ "${#written[@]}" = 0 ]; then
        echo "  proxy/: the configuration of the reverse proxy is that of .env already"
    else
        echo "  proxy/: ${written[*]}"
    fi
    [ "${#kept[@]}" = 0 ] || echo "NOTE: proxy/ had changes of yours, kept as ${kept[*]}: carry them over into the new files (or use caddy.d/ with Caddy)"
    return 0
}

# --render-proxy: proxy/ again from .env, nothing else (after a change of .env)
render_proxy_cli() {
    SCRIPT_DIR=${FFS_ENTRY_DIR}
    [ -f "${SCRIPT_DIR}/.env" ] || { echo "ERROR: no ${SCRIPT_DIR}/.env: run ./prepare_environment.sh"; exit 1; }
    local deploy=compose
    units_installed && units_of_here && deploy=quadlets
    echo "Writing the configuration of the reverse proxy from ${SCRIPT_DIR}/.env (${deploy})..."
    write_proxy "${deploy}" render || exit 1
    # (the compose file of PROXY in COMPOSE_FILE: --upgrade puts it there)
    if [ "${deploy}" = compose ] && [ -n "$(env_value COMPOSE_FILE)" ] \
        && [ "$(compose_files_proxy "$(env_value COMPOSE_FILE)" "$(proxy_env PROXY)")" != "$(env_value COMPOSE_FILE)" ]; then
        echo "NOTE: COMPOSE_FILE of .env is not that of PROXY=$(proxy_env PROXY): ./prepare_environment.sh --upgrade sets it"
    fi
    case "$(proxy_env PROXY)" in
        caddy) [ "${deploy}" = quadlets ] && echo "Then: systemctl --user restart firefox-sync-caddy.service" \
            || echo "Then: docker compose up -d && docker compose restart caddy" ;;
        traefik) echo "Then: docker compose up -d (the labels of proxy/traefik-compose.yml)" ;;
        *) echo "Then: the file of your proxy into its configuration, and reload it (the README of proxy/)" ;;
    esac
    exit 0
}

# COMPOSE_FILE with the file of PROXY (compose/caddy.yml, proxy/traefik-compose.yml) and not the
# other's: compose_files_proxy <COMPOSE_FILE> <own|caddy|traefik>
compose_files_proxy() {
    local part parts=() new=""
    IFS=: read -r -a parts <<< "${1}"
    for part in ${parts[@]+"${parts[@]}"}; do
        case "${part}" in compose/caddy.yml|*/compose/caddy.yml|proxy/traefik-compose.yml|*/proxy/traefik-compose.yml) continue ;; esac
        new=${new:+${new}:}${part}
    done
    case "${2}" in
        caddy) new=${new:+${new}:}compose/caddy.yml ;;
        traefik) new=${new:+${new}:}proxy/traefik-compose.yml ;;
    esac
    printf '%s\n' "${new}"
}

# --- the checks of the bundled Caddy's ports (the setup): something there already (ss, else a
# connection to it with bash's /dev/tcp; nothing known: nothing said)
port_in_use() {
    if command -v ss > /dev/null 2>&1; then
        [ -n "$(ss -Hltn "sport = :${1}" 2> /dev/null)" ]
        return
    fi
    (exec 3<> "/dev/tcp/127.0.0.1/${1}") 2> /dev/null
}
# the lowest port rootless Podman (or rootless Docker) can publish: net.ipv4.ip_unprivileged_port_start
# (Linux), empty when not known
unprivileged_port_start() { cat /proc/sys/net/ipv4/ip_unprivileged_port_start 2> /dev/null; }
# caddy_port_checks <http> <https>: what is said about them (warnings, nothing stops)
caddy_port_checks() {
    local port start
    for port in "$@"; do
        port_in_use "${port}" && echo "WARNING: something listens on port ${port} of this host already (another proxy, or the bundled Caddy of a run before): the bundled Caddy needs it"
    done
    start=$(unprivileged_port_start)
    if [ "${CONTAINER_RUNTIME}" = podman ] && [ "${EUID:-0}" != 0 ] && [ -n "${start}" ]; then
        for port in "$@"; do
            [ "${port}" -lt "${start}" ] || continue
            echo "WARNING: rootless Podman cannot publish port ${port}: this host lets users have ports from ${start} on"
            echo "  (net.ipv4.ip_unprivileged_port_start). Either, as root (docs/reverse-proxy.md#rootless-podman-and-ports-under-1024):"
            echo "    sysctl net.ipv4.ip_unprivileged_port_start=80"
            echo "    echo 'net.ipv4.ip_unprivileged_port_start=80' > /etc/sysctl.d/90-firefox-sync.conf"
            echo "  or ports from ${start} on (CADDY_HTTP_PORT, CADDY_HTTPS_PORT), and 80 and 443 forwarded to them (your router, a firewall rule)"
            break
        done
    fi
}

# --- the checks of the labels for Traefik (the setup)
# network_subnets <network>: its IPv4 and IPv6 subnets as the container runtime has them,
# separated by spaces (empty: no such network, or no runtime to ask)
network_subnets() {
    case "${CONTAINER_RUNTIME:-none}" in
        podman) podman network inspect -f '{{range .Subnets}}{{.Subnet}} {{end}}' "${1}" 2> /dev/null ;;
        docker) docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "${1}" 2> /dev/null ;;
    esac
}
# ipv4_int <a.b.c.d>: the address as a number (fails for anything else)
ipv4_int() {
    local a b c d rest
    IFS=. read -r a b c d rest <<< "${1}"
    [ -z "${rest}" ] && [[ "${a}.${b}.${c}.${d}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    [ "${a}" -le 255 ] && [ "${b}" -le 255 ] && [ "${c}" -le 255 ] && [ "${d}" -le 255 ] || return 1
    printf '%s' "$(( (a << 24) + (b << 16) + (c << 8) + d ))"
}
# ipv4_in <address> <subnet a.b.c.d/n>: the address is in the subnet
ipv4_in() {
    local ip net bits
    ip=$(ipv4_int "${1}") && net=$(ipv4_int "${2%/*}") || return 1
    bits=${2##*/}
    [[ "${bits}" =~ ^[0-9]{1,2}$ ]] && [ "${bits}" -le 32 ] || return 1
    [ "${bits}" = 0 ] && return 0
    [ $(( (ip ^ net) >> (32 - bits) )) = 0 ]
}
# traefik_trusted_check <network> <ADMIN_TRUSTED_PROXIES>: with the labels for Traefik and the
# admin UI's trusted-header sign-in, the header counts from Traefik's own address on its network
# alone: an address each (a range there lets every container on that network sign in with the
# header), of that network when the runtime knows it. An ERROR otherwise, fails
traefik_trusted_check() {
    local net=${1} entry subnets subnet entries=() inside
    IFS=, read -r -a entries <<< "${2}"
    for entry in ${entries[@]+"${entries[@]}"}; do
        case "${entry}" in
            */32|*/128) ;;
            */*) echo "ERROR: ADMIN_TRUSTED_PROXIES: ${entry} is a range: with the labels for Traefik, only Traefik's own address on ${net} (docker network inspect ${net}): any container on that network would sign in with the header (docs/reverse-proxy.md#traefik-labels)"
                return 1 ;;
        esac
    done
    subnets=$(network_subnets "${net}")
    [ -n "${subnets// /}" ] || return 0
    for entry in ${entries[@]+"${entries[@]}"}; do
        inside=""
        for subnet in ${subnets}; do
            case "${subnet}" in *:*) [[ "${entry}" == *:* ]] && inside=unknown ;; *) ipv4_in "${entry%/32}" "${subnet}" && inside=yes ;; esac
        done
        [ -n "${inside}" ] && continue
        echo "ERROR: ADMIN_TRUSTED_PROXIES: ${entry} is no address of ${net} (${subnets% }): Traefik's own address there (docker network inspect ${net})"
        return 1
    done
    return 0
}
