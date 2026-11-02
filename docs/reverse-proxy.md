# Reverse proxy

The stack serves plain HTTP on ports of the host: a reverse proxy adds HTTPS and the public host names. `prepare_environment.sh` writes its configuration for you, from your answers. On Kubernetes, see [Kubernetes](#kubernetes).

The setup asks whether you already run a reverse proxy (its part 6, [answers](install/compose.md#answers-by-name) `proxy` and after):

| Your answer | What runs | See |
|---|---|---|
| `own` (default): you run one already, nginx, Caddy, Traefik, Apache... | your proxy, with the file of `proxy/` for it | [Your own proxy](#your-own-proxy) |
| `caddy`: no proxy yet | the bundled Caddy, which gets its certificates from Let's Encrypt itself | [The bundled Caddy](#the-bundled-caddy) |
| `traefik`: Traefik with its Docker provider (not with Quadlets) | your Traefik, reading labels on the public containers | [Traefik labels](#traefik-labels) |

Whatever the answer, `proxy/` has the configuration of each of them.

## The configuration in proxy/

`prepare_environment.sh` writes `proxy/` next to `.env` (git ignores it, as `.env`), from `.env` alone: the public URLs, the ports the stack listens on, the optional services (the admin UI, the pairing server) and the `PROXY` settings ([Settings](reference/settings.md#reverse-proxy)). Every route below is in each file, with the rules of this page.

| File | For |
|---|---|
| `proxy/nginx.conf` | nginx on this host |
| `proxy/Caddyfile` | Caddy on this host |
| `proxy/traefik.yml` | Traefik on this host, its file provider |
| `proxy/Caddyfile.bundled` | `PROXY=caddy`: the bundled Caddy |
| `proxy/traefik-compose.yml` | `PROXY=traefik`: the labels for your Traefik, a compose file of `COMPOSE_FILE` |
| `proxy/README.md` | where each file goes |
| `proxy/caddy.d/` | snippets of yours for Caddy, which it imports: see [Caddy](#caddy) |

The first three proxy to the ports of this host (`127.0.0.1`): the proxy runs on the same host as the stack. What they look like, for a few answer sets: [tests/proxy/](/tests/proxy) (the test that keeps them so, [tests/proxy_render.sh](/tests/proxy_render.sh), also has nginx, Caddy and Traefik read them).

They are written again by `./prepare_environment.sh --upgrade`, `--render-units` and, alone, `--render-proxy`. After a change of a URL or a port in `.env`:

```bash
./prepare_environment.sh --render-proxy
```

A file you changed since it was written is kept first, as `<file>.before-upgrade-<UTC time>` (`before-render`, `before-setup`), and said: carry your change over into the new file. With Caddy, put your changes in `caddy.d/` instead, which stays.

## Host names and ports

Every route of the stack: the public URL it comes from, and where it goes, on this host (the setting of `.env`, its default) and on the stack's network (the labels for Traefik). Each host has its server block, site or router; on a host with two routes, the more specific one first.

| Host name | Setting | Path | To, on this host | Container |
|---|---|---|---|---|
| `sync.example.com` | `SYNC_PUBLIC_URL` | `/` | `SYNC_EXPORT_PORT` (`127.0.0.1:5000`) | `syncstorage:8000` |
| `accounts.example.com` | `FXA_CONTENT_URL` | `/` | `FXA_CONTENT_EXPORT_PORT` (`127.0.0.1:3030`) | `fxa-content:3030` |
| `api.example.com` | `FXA_AUTH_URL` | `/v1/account/create`, with the admin UI: see [Sign-up gate](#sign-up-gate) | `ADMIN_GATE_EXPORT_PORT` (`127.0.0.1:8091`) | `ffs-admin:8081` |
| | | `/` | `FXA_AUTH_EXPORT_PORT` (`127.0.0.1:9000`) | `fxa-auth:9000` |
| `profile.example.com` | `FXA_PROFILE_URL` | `/img/`, without `/img`: the avatars | `FXA_PROFILE_STATIC_EXPORT_PORT` (`127.0.0.1:1112`) | `fxa-profile-static:1112` |
| | | `/` | `FXA_PROFILE_EXPORT_PORT` (`127.0.0.1:1111`) | `fxa-profile:1111` |
| `pairing.example.com` (optional) | `FXA_PAIRING_URL` | `/`, a websocket: see [Pairing](#pairing) | `FXA_PAIRING_EXPORT_PORT` (`127.0.0.1:8058`) | `fxa-pairing:8000` |
| `admin.example.com` (optional) | `ADMIN_OIDC_REDIRECT_URL` | `/`, from `PROXY_ADMIN_ALLOW` only: see [The admin UI](#the-admin-ui) | `ADMIN_EXPORT_PORT` (`127.0.0.1:8090`) | `ffs-admin:8080` |

The accounts' hosts are there with [self-hosted accounts](accounts.md); the pairing server when you run your own; the admin UI's host when it signs in with the self-hosted accounts or another OpenID Connect provider ([Signing in](admin/signing-in.md#self-hosted-accounts)), which send you back to it. The admin UI is otherwise better reached through an SSH tunnel than published: see [Reach it](admin/README.md#reach-it). With the Quadlets the Sync server's container is `firefox-sync-syncstorage`, and there is no pairing server.

A URL with a port of its own (`https://sync.example.com:8443`) gets a server on that port, and the redirect from HTTP to it; an `http://` URL (on a network of your own: Firefox needs HTTPS but on `localhost`) a plain server, without a redirect.

The ports take the form of a compose port, `[address:]port`. `127.0.0.1:5000`, the default, keeps them to a proxy on the same host. For a proxy on another host, `0.0.0.0:5000` (or a bare port, such as `5000`; `[::]:5000` with IPv6 too) listens on every address of the host: then point the files of `proxy/` at this host's address instead of `127.0.0.1`. The setup script asks for `SYNC_EXPORT_PORT` and takes a port alone as `127.0.0.1:<port>`, and keeps with a warning a value of an existing `.env` it does not recognize; `proxy/` then proxies to `127.0.0.1:<port>` (`[::1]` for `[::]`), not `localhost`, which nginx would try on `::1` first. The other ports: see [Settings](reference/settings.md#accounts).

An install set up before this default has `SYNC_EXPORT_PORT=5000`, on every address, and keeps it (`--upgrade` changes nothing there). To keep it to the proxy on the same host, set `SYNC_EXPORT_PORT=127.0.0.1:5000` in `.env`, then `docker compose up -d`, or with Quadlets `./prepare_environment.sh --render-units` and `systemctl --user restart firefox-sync-syncstorage.service`.

## Your own proxy

Take the file of your proxy from `proxy/`, put it where `proxy/README.md` says, and reload the proxy. The certificates are yours to get, but with Caddy, which gets them itself.

### nginx

`proxy/nginx.conf` has a server block per host, `listen 443 ssl` (or the port of the URL) with the certificates at certbot's paths, `/etc/letsencrypt/live/<host>/`, and one that redirects HTTP to HTTPS:

```bash
sudo cp proxy/nginx.conf /etc/nginx/conf.d/firefox-sync.conf
sudo nginx -t && sudo systemctl reload nginx
```

nginx does not start without the certificates it names: get them first, for example with `certbot certonly --standalone -d sync.example.com` (one `-d` per host, nginx stopped while it runs), or change the `ssl_certificate` lines to yours. `http2 on;` needs nginx 1.25.1 or later: on an older one, remove the line and put `http2` after `ssl` in `listen`.

The Sync server's block, for example:

```nginx
server {
  listen 443 ssl;
  listen [::]:443 ssl;
  http2 on;
  server_name sync.example.com;
  ssl_certificate /etc/letsencrypt/live/sync.example.com/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/sync.example.com/privkey.pem;
  client_max_body_size 10m;
  location / {
    proxy_pass http://127.0.0.1:5000;
    proxy_set_header Host $http_host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_redirect off;
    proxy_read_timeout 120;
    proxy_connect_timeout 10;
    gzip off;
  }
}
```

Client certificates or Authelia in front of the accounts pages: [access-control-example.conf](/config/nginx/access-control-example.conf) replaces their server block ([Single sign-on and client certificates](single-sign-on.md)).

### Caddy

`proxy/Caddyfile` has a site per host. Caddy gets their certificates from Let's Encrypt by itself, and redirects HTTP to HTTPS. Use it as your Caddyfile, or import it from yours (`import /etc/caddy/firefox-sync.caddy`), then `caddy reload` (`systemctl reload caddy`).

Your own additions go in `caddy.d/` next to the file, as snippets that it imports, and that stay when it is written again: `sites*.caddy` beside its sites (sites of your own), `<site>*.caddy` in that site (`sync`, `content`, `api`, `profile`, `pairing`, `admin`), `public*.caddy` in the five Firefox reaches (all but `admin`). A pattern that matches no file imports nothing. For example, the forward auth of Authelia in front of the accounts pages, in `caddy.d/content.caddy`: see [Single sign-on and client certificates](single-sign-on.md).

```caddy
api.example.com {
	import caddy.d/public*.caddy
	import caddy.d/api*.caddy
	# the sign-up gate of the admin UI
	@gate path /v1/account/create
	reverse_proxy @gate 127.0.0.1:8091
	reverse_proxy 127.0.0.1:9000
}
```

### Traefik

`proxy/traefik.yml` is a dynamic configuration of Traefik's [file provider](https://doc.traefik.io/traefik/providers/file/): put it where `providers.file` reads (`filename`, or a file of its `directory`), Traefik reads it again by itself. Its routers are on the entry points `TRAEFIK_ENTRYPOINTS` (`websecure`), with the certificates of `TRAEFIK_CERTRESOLVER` (empty: Traefik's default certificate), the redirect from HTTP on `TRAEFIK_HTTP_ENTRYPOINT` (`web`, empty: none), names of yours in [Settings](reference/settings.md#reverse-proxy) (then `--render-proxy`). Its services are on `127.0.0.1`: Traefik on this host, not in a container (there, see [Traefik labels](#traefik-labels)).

### Another proxy

Apache, HAProxy, a load balancer: proxy each route of [Host names and ports](#host-names-and-ports), with the rules below.

## The bundled Caddy

No reverse proxy yet: the setup's `caddy` runs Caddy with the stack, on ports 80 and 443 of the host. It gets a certificate for each public host from Let's Encrypt, renews them, and redirects HTTP to HTTPS. Its configuration is `proxy/Caddyfile.bundled`, its certificates in its own volume.

- **docker compose:** `compose/caddy.yml` in `COMPOSE_FILE`, the service `caddy`. `docker compose up -d` starts it with the rest.
- **Quadlets:** the unit `firefox-sync-caddy.service` (and its volumes). Start it: `systemctl --user start firefox-sync-caddy.service`.

Both run it on the host's network (`network_mode: host`, `Network=host`): it listens on the host's ports itself, proxies to the ports of the stack on `127.0.0.1`, and sees the clients' own addresses, which the accounts' limits and the admin UI's allowlist count on. Behind published ports it would not always: rootless Podman's port forwarding, and Docker's proxy for IPv6 clients, show it the address of a gateway for them. Docker Desktop: turn on its host networking (Settings, Resources, Network). Its admin API is on a socket of its volume, not on the host's `127.0.0.1:2019`.

What the setup asks: an email Let's Encrypt writes to about the certificates (`CADDY_ACME_EMAIL`, optional), where the certificates come from (`CADDY_ACME_CA`), its two ports (`CADDY_HTTP_PORT`, `CADDY_HTTPS_PORT`). It checks that nothing listens on them yet, and says what Let's Encrypt needs:

- **The host names resolve to this host**, every one of [Host names and ports](#host-names-and-ports) you use (DNS `A`/`AAAA` records), and **ports 80 and 443 are reachable from the internet**: Let's Encrypt checks them before it gives a certificate. On ports of your own (`8080`, `8443`), forward 80 and 443 to them (your router, a firewall rule).
- **`CADDY_ACME_CA`:** `letsencrypt`; `staging`, Let's Encrypt's test CA, to try the setup without hitting its [rate limits](https://letsencrypt.org/docs/rate-limits/) (no browser trusts its certificates: set `letsencrypt` once it works, then `--render-proxy` and restart Caddy); `internal`, Caddy's own CA, without the internet, for a network of your own. Its root certificate must then be trusted where Firefox runs: `docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt .` (Quadlets: `podman cp firefox-sync-caddy:/data/caddy/pki/authorities/local/root.crt .`), then in Firefox's settings, Certificates, Import (or the `Certificates` policy). Its certificates last 30 days, renewed by Caddy.

Not with the admin UI's [trusted-header sign-in](admin/signing-in.md#trusted-header): Caddy reaches the admin UI from the host's `127.0.0.1`, which every process of the host has, and each could sign in with the header. The setup does not offer the bundled Caddy then (and refuses `proxy=caddy` with `admin_signin=header`); a header set by hand later is warned of, and dropped from the clients' requests on the admin UI's route.

After a change of `.env` (a URL, a port, its own ports): `./prepare_environment.sh --render-proxy`, then `docker compose restart caddy` (Quadlets: `systemctl --user restart firefox-sync-caddy.service`). Your own snippets: in `proxy/caddy.d/`, as in [Caddy](#caddy).

### Rootless Podman and ports under 1024

Rootless Podman (and rootless Docker) cannot listen on a port under `net.ipv4.ip_unprivileged_port_start`, 1024 by default: Caddy on 80 and 443 fails to start (`permission denied`). The setup says so when this host's value is above the ports. Either let users have ports from 80 on, as root:

```bash
sysctl net.ipv4.ip_unprivileged_port_start=80
echo 'net.ipv4.ip_unprivileged_port_start=80' > /etc/sysctl.d/90-firefox-sync.conf
```

or give Caddy ports from 1024 on (`CADDY_HTTP_PORT=8080`, `CADDY_HTTPS_PORT=8443`) and forward 80 and 443 to them, on your router or with a firewall rule of the host. The public URLs stay without a port.

## Traefik labels

For your Traefik with its [Docker provider](https://doc.traefik.io/traefik/providers/docker/): the setup's `traefik` writes `proxy/traefik-compose.yml`, a compose file in `COMPOSE_FILE`, which puts the public containers on a network for Traefik too (`TRAEFIK_NETWORK`) with the labels of their routers. `docker compose up -d` applies them, and Traefik picks them up.

That network is by default the stack's own, `<project>-proxy` (`firefox-sync-proxy`), for Traefik and these containers only. Make it and attach your Traefik to it, once:

```bash
docker network create firefox-sync-proxy
docker network connect firefox-sync-proxy traefik   # your Traefik's container
```

or in your Traefik's compose file, `networks: [firefox-sync-proxy]` with `firefox-sync-proxy: {external: true}` under its `networks:`. Don't share it: a container on that network reaches the public containers directly, past Traefik and its rules, and the admin UI's own port with them (its container answers the [sign-up gate](#sign-up-gate) too). Another network, Traefik's own shared one, only by an explicit answer, which the setup warns about. Only the containers Traefik must reach join it: the public ones, and the admin UI's for the gate and its public address.

What the labels have, for each route of [Host names and ports](#host-names-and-ports), named after the compose project (`<project>-sync`, `-gate`...) so that two stacks do not share them:

- a router on `TRAEFIK_ENTRYPOINTS` (`websecure`; comma-separated), TLS with `TRAEFIK_CERTRESOLVER` (empty: Traefik's default certificate), and a service on the container's port;
- the sign-up gate and the avatars: routers of priority 1000, before those of their host; `/img` stripped by a `stripPrefix` middleware;
- the Sync server: a `buffering` middleware of 10 MB ([Request size](#request-size));
- the admin UI: an `ipAllowList` middleware of `PROXY_ADMIN_ALLOW` (Traefik must see the clients' own addresses, see [The admin UI](#the-admin-ui)), and with the trusted-header sign-in a `headers` middleware that drops the header a client sends;
- HTTP to HTTPS: a router on `TRAEFIK_HTTP_ENTRYPOINT` (`web`; empty: none, when Traefik redirects all of it already) with a `redirectScheme` middleware.

Traefik passes websockets (the pairing server) as they are, and sets `X-Forwarded-For` and `X-Forwarded-Proto` itself. It keeps the `X-Forwarded-For` of a client only from the addresses of its entry point's `forwardedHeaders.trustedIPs`: leave them out, but for a proxy in front of Traefik (then add 1 to `FXA_CLIENT_ADDRESS_DEPTH`, [Client IP address](#client-ip-address)).

The admin UI's [trusted-header sign-in](admin/signing-in.md#trusted-header) behind Traefik: `ADMIN_TRUSTED_PROXIES` is Traefik's own address on that network, `/32` (`docker network inspect firefox-sync-proxy`), never its subnet, which would let every container on it sign in with a header of its own: the setup refuses a range there, and an address of another network when it can read the network.

The containers with a label are only those of the stack's public services. With `exposedByDefault=false` in Traefik, they have `traefik.enable=true`. On the Podman socket (docker compose on Podman), Traefik reads the labels from the Podman socket instead: mount `$XDG_RUNTIME_DIR/podman/podman.sock` as its `/var/run/docker.sock`. The Quadlets have no labels: with them, run Traefik on the host with `proxy/traefik.yml` ([Traefik](#traefik)).

## Request size

Firefox sends batches up to the Sync server's limit, about 2.5 MB a request. nginx refuses more than 1 MB by default, so `proxy/nginx.conf` raises its limit on the Sync server's host:

```nginx
client_max_body_size 10m;
```

Without it, large batches fail with `413 Request Entity Too Large`, which shows in `about:sync-log`. The other files cap it at the same 10 MB (Caddy: `request_body`, Traefik: `buffering`). Other proxies and Ingress controllers have their own limit of the request body, if any.

## Sign-up gate

With self-hosted accounts and the admin UI, `/v1/account/create` of the accounts API host goes to the admin UI's gate, `ADMIN_GATE_EXPORT_PORT` (`127.0.0.1:8091`): every method, the gate passes on to the accounts what is not that `POST`. Everything else on that host goes to the accounts service. In `proxy/nginx.conf`:

```nginx
location = /v1/account/create {
  proxy_pass http://127.0.0.1:8091;
  proxy_set_header Host $http_host;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto $scheme;
}
```

With the Helm chart the gate is the Service `<release>-firefox-sync-admin`, port 8081. The chart's Ingress of the accounts API sends `/v1/account/create` there (`fxa.ingress.enabled` and `admin.enabled`). An Ingress or proxy of your own needs the same rule: path `/v1/account/create`, type `Exact`, to that Service and port.

Without the admin UI, `proxy/` has no gate. The accounts database still refuses the sign-ups the policy does not allow. What the gate adds: see [Who can sign up](accounts.md#who-can-sign-up).

## Pairing

With self-hosted accounts, a phone pairs with a computer through Mozilla's pairing server, unless you run your own ([Pair a phone](firefox.md#pair-a-phone)). To run your own, with docker compose (the Quadlets have none):

1. Answer yes to the setup's question of the pairing server, or in `.env` add `pairing` to `COMPOSE_PROFILES`, and set `FXA_PAIRING_URL=wss://pairing.example.com`, then `./prepare_environment.sh --render-proxy`.
1. Its host is in `proxy/`, a websocket to `FXA_PAIRING_EXPORT_PORT` (`127.0.0.1:8058`), which stays open while a pairing waits:

   ```nginx
   location / {
     proxy_pass http://127.0.0.1:8058;
     proxy_http_version 1.1;
     proxy_set_header Upgrade $http_upgrade;
     proxy_set_header Connection "upgrade";
     proxy_read_timeout 600;
     proxy_set_header Host $http_host;
     proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
   }
   ```

1. Start it: `docker compose up -d`.

## Client IP address

The accounts service limits sign-in attempts per client IP address. It takes the address from `X-Forwarded-For`, at a fixed position from the end: `FXA_CLIENT_ADDRESS_DEPTH` (`2`), for one reverse proxy in front of the stack.

- Your proxy must set `X-Forwarded-For`, as the files of `proxy/` do: nginx `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;`, Caddy and Traefik by themselves.
- With another proxy in front of yours, such as a CDN or a load balancer, add 1 to `FXA_CLIENT_ADDRESS_DEPTH` for each, and let your proxy trust its address only (Caddy: `trusted_proxies`, Traefik: `forwardedHeaders.trustedIPs`, nginx: `set_real_ip_from` if you use the real IP module).

<details><summary>Why not Mozilla's default</summary>

Mozilla's default depth is 3, for their load balancers. Behind a single proxy, it lets any client pick its IP address by sending its own `X-Forwarded-For`, and so get around the limits.

</details>

## The admin UI

The admin UI listens on `ADMIN_EXPORT_PORT` (`127.0.0.1:8090`), and is best reached without publishing it: see [Reach it](admin/README.md#reach-it).

When it signs in with the self-hosted accounts or another provider, it needs a host name of its own (`ADMIN_OIDC_REDIRECT_URL`), which `proxy/` publishes:

- only from the addresses of `PROXY_ADMIN_ALLOW`, which the setup asks for (by default this host only, `127.0.0.1,::1`; `anybody`: no restriction, its sign-in only). Add your own network or VPN, then `--render-proxy`;
- with the `Host` header as it came: the forms check that they are posted from the same site;
- without the headers of the [trusted-header sign-in](admin/signing-in.md#trusted-header) a client sends, when `ADMIN_AUTH_HEADER` is set.

The trusted-header sign-in with a proxy on the host trusts what the admin UI sees it from, the host's loopback or a gateway, which every process and container of the host has: prefer OpenID Connect there, or Traefik's own address on a network of the stack ([Traefik labels](#traefik-labels)). See [Trusted header](admin/signing-in.md#trusted-header).

The allowlist counts only where the proxy sees the clients' own addresses: on the host (nginx, Caddy, the bundled Caddy on the host's network), or Traefik that does. A proxy in a container behind published ports can see a gateway's address for every client (rootless Podman, Docker's proxy of IPv6): don't list the networks of the containers then, which would let everybody in.

```nginx
server {
  server_name admin.example.com;
  listen 443 ssl;
  # ssl_certificate ...
  allow 192.0.2.0/24;  # your network
  deny all;
  location / {
    proxy_pass http://127.0.0.1:8090;
    proxy_set_header Host $http_host;
  }
}
```

Sessions, plain HTTP and signing in: see [Admin UI](admin/README.md#set-up) and [Signing in](admin/signing-in.md). A sign-in proxy in front of it: see [Trusted header](admin/signing-in.md#trusted-header).

## Single sign-on and client certificates

A sign-in proxy (such as Authelia) or client certificates fit in front of the accounts pages and the admin UI only: Firefox calls the other hosts in the background, without cookies or a certificate. See [Single sign-on and client certificates](single-sign-on.md).

## Kubernetes

With the Helm chart, the chart's Ingress publishes the Sync server, and the admin UI on a host of its own: see [Ingress](install/helm.md#ingress) and [Admin UI](install/helm.md#admin-ui). The rules of this page still apply, in the Ingress controller's terms: [Request size](#request-size) is the one that matters for the Sync server. `proxy/` is for compose and the Quadlets.

With your own reverse proxy in front of the cluster, proxy the Sync server's host name to the Service `<release>-firefox-sync-syncstorage`, port 8000.

### The accounts' Ingresses

With the [self-hosted accounts](install/helm.md#self-hosted-accounts), `fxa.ingress.enabled` makes one Ingress per host. They share `fxa.ingress.className` and `.annotations`, and each has its certificate in `fxa.ingress.tls.secretNames.<content|auth|profile|pairing>` (empty: the controller's default). With `F=<release>-firefox-sync`:

| Host of | Ingress | Paths |
|---|---|---|
| `fxa.contentUrl` | `$F-fxa-content` | `/` to `$F-fxa-content:3030` |
| `fxa.authUrl` | `$F-fxa-auth` | `/` to `$F-fxa-auth:9000`; with the admin UI, `/v1/account/create` (`Exact`) to the gate, `$F-admin:8081` |
| `fxa.profileUrl` | `$F-fxa-profile` | `/` to `$F-fxa-profile:1111`; `/img/` to its port `img`, 1114, a small proxy that strips `/img` |
| `fxa.pairing.url` (with `fxa.pairing.enabled`) | `$F-fxa-pairing` | `/` to `$F-fxa-pairing:8000` |

The chart leaves these to the controller:

- **HTTP to HTTPS.** The chart sets no redirect. ingress-nginx redirects a host with TLS by default (`ssl-redirect`). Traefik redirects only when its `web` entry point is told to, for example with `--entrypoints.web.http.redirections.entrypoint.to=websecure`.
- **TLS.** With `fxa.ingress.tls.enabled: false` the Ingresses have no `tls`: HTTPS then depends on the controller, its default certificate or a load balancer in front that adds it. The URLs stay `https://`.
- **The pairing websockets.** ingress-nginx closes a connection that is idle for 60 seconds, its default `proxy-read-timeout`, which can cut a pairing in the middle. Raise it in `fxa.ingress.annotations`, as `proxy/nginx.conf`'s `proxy_read_timeout 600`. These annotations go on all the accounts' Ingresses, which does no harm:

  ```yaml
  fxa:
    ingress:
      annotations:
        nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
        nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
  ```

- **The client IP address.** `fxa.clientAddressDepth` (`2`) is for the Ingress controller alone. Add 1 for each proxy in front of it that adds to `X-Forwarded-For`: see [Client IP address](#client-ip-address).
- **Who reaches the servers.** Without a NetworkPolicy, any pod of the cluster reaches the auth server's Service past the controller, with an `X-Forwarded-For` of its own and around the sign-up gate. `fxa.networkPolicy.servers` admits the controller's pods alone, which you name in it: see [NetworkPolicies](install/helm.md#networkpolicies).

### Your own Ingress or proxy

With `fxa.ingress.enabled: false`, publish the Services of the table above yourself, at the accounts' URLs, with HTTPS. The same with a Gateway API controller, which the chart has no routes for. Two rules need care:

- **The sign-up gate**, with the admin UI: see [Sign-up gate](#sign-up-gate).
- **The avatars.** Send `/img/` of the profile host either to port 1114 (`img`) with the path as it is, or stripped of `/img` to port 1112 (`static`), as `proxy/nginx.conf` does to `127.0.0.1:1112/`.

The pairing server is a websocket, as in [Pairing](#pairing).
