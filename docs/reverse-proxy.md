# Reverse proxy

The stack serves plain HTTP on ports of the host: your reverse proxy adds HTTPS and the public host names. This page says what to proxy where, and the few rules the proxy must follow. On Kubernetes, see [Kubernetes](#kubernetes).

The examples are nginx configs. `prepare_environment.sh` writes them with your values: `config/nginx/syncstorage-rs.conf` from [syncstorage-rs-example.conf](/config/nginx/syncstorage-rs-example.conf) and, with self-hosted accounts, `config/nginx/fxa.conf` from [fxa-example.conf](/config/nginx/fxa-example.conf). They are the reference for the rules below.

## Host names and ports

| Host name | Setting | Proxy to |
|---|---|---|
| `sync.example.com` | `SYNC_PUBLIC_URL` | `SYNC_EXPORT_PORT` (`127.0.0.1:5000`) |

The admin UI is better reached through an SSH tunnel than published: see [Reach it](admin/README.md#reach-it).

With [self-hosted accounts](accounts.md), three more, and two optional:

| Host name | Setting | Proxy to |
|---|---|---|
| `accounts.example.com` | `FXA_CONTENT_URL` | `127.0.0.1:3030` |
| `api.example.com` | `FXA_AUTH_URL` | `127.0.0.1:9000`, and with the admin UI `POST /v1/account/create` to `127.0.0.1:8091`: see [Sign-up gate](#sign-up-gate) |
| `profile.example.com` | `FXA_PROFILE_URL` | `127.0.0.1:1111`, and `/img/` to `127.0.0.1:1112/` |
| `admin.example.com` (optional) | `ADMIN_OIDC_REDIRECT_URL` | `127.0.0.1:8090`, to [sign in to the admin UI with these accounts](admin/signing-in.md#self-hosted-accounts) |
| `pairing.example.com` (optional) | `FXA_PAIRING_URL` | `127.0.0.1:8058`, a websocket: see [Pairing](#pairing) |

The ports of the accounts are those of `FXA_*_EXPORT_PORT` and `ADMIN_GATE_EXPORT_PORT` in `.env`: see [Settings](reference/settings.md#accounts).

`SYNC_EXPORT_PORT` takes the form of a compose port, `[address:]port`. `127.0.0.1:5000`, the default, keeps it to a proxy on the same host, as the other ports. For a proxy on another host, `0.0.0.0:5000` (or a bare port, such as `5000`; `[::]:5000` with IPv6 too) listens on every address of the host. The setup script asks for it and takes a port alone as `127.0.0.1:<port>`, and keeps with a warning a value of an existing `.env` it does not recognize; `config/nginx/syncstorage-rs.conf` then proxies to `127.0.0.1:<port>`, not `localhost`, which nginx would try on `::1` first.

An install set up before this default has `SYNC_EXPORT_PORT=5000`, on every address, and keeps it (`--upgrade` changes nothing there). To keep it to the proxy on the same host, set `SYNC_EXPORT_PORT=127.0.0.1:5000` in `.env`, then `docker compose up -d`, or with Quadlets `./prepare_environment.sh --render-units` and `systemctl --user restart firefox-sync-syncstorage.service`.

## Request size

Firefox sends batches up to the Sync server's limit, about 2.5 MB a request. nginx refuses more than 1 MB by default, so raise its limit on the Sync server's host:

```nginx
client_max_body_size 10m;
```

Without it, large batches fail with `413 Request Entity Too Large`, which shows in `about:sync-log`. Other proxies and Ingress controllers have their own limit of the request body, if any.

## Sign-up gate

With self-hosted accounts and the admin UI, send `POST /v1/account/create` of the accounts API host name to the admin UI's gate, `ADMIN_GATE_EXPORT_PORT` (`127.0.0.1:8091`). Everything else on that host goes to the accounts service.

```nginx
location = /v1/account/create {
  proxy_pass http://127.0.0.1:8091;
  proxy_set_header Host $http_host;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto $scheme;
}
```

With the Helm chart the gate is the Service `<release>-firefox-sync-admin`, port 8081. The chart's Ingress of the accounts API sends `/v1/account/create` there (`fxa.ingress.enabled` and `admin.enabled`). An Ingress or proxy of your own needs the same rule: path `/v1/account/create`, type `Exact`, to that Service and port.

`prepare_environment.sh` removes this block when you don't enable the admin UI. Without the gate the accounts database still refuses the sign-ups the policy does not allow. What the gate adds: see [Who can sign up](accounts.md#who-can-sign-up).

## Pairing

With self-hosted accounts, a phone pairs with a computer through Mozilla's pairing server, unless you run your own ([Pair a phone](firefox.md#pair-a-phone)). To run your own:

1. In `.env`, add `pairing` to `COMPOSE_PROFILES`, and set `FXA_PAIRING_URL=wss://pairing.example.com`.
1. Proxy that host name to `FXA_PAIRING_EXPORT_PORT` (`127.0.0.1:8058`), as a websocket:

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

The full server block is commented out at the end of [fxa-example.conf](/config/nginx/fxa-example.conf).

## Client IP address

The accounts service limits sign-in attempts per client IP address. It takes the address from `X-Forwarded-For`, at a fixed position from the end: `FXA_CLIENT_ADDRESS_DEPTH` (`2`), for one reverse proxy in front of the stack.

- Your proxy must set `X-Forwarded-For`, as the examples do: `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;`.
- With another proxy in front of yours, such as a CDN or a load balancer, add 1 to `FXA_CLIENT_ADDRESS_DEPTH` for each.

<details><summary>Why not Mozilla's default</summary>

Mozilla's default depth is 3, for their load balancers. Behind a single proxy, it lets any client pick its IP address by sending its own `X-Forwarded-For`, and so get around the limits.

</details>

## The admin UI

The admin UI listens on `ADMIN_EXPORT_PORT` (`127.0.0.1:8090`), and is best reached without publishing it: see [Reach it](admin/README.md#reach-it).

To publish it behind nginx instead, on a host name of its own:

- restrict it to your own addresses;
- keep the `Host` header: the forms check that they are posted from the same site.

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

With the Helm chart, the chart's Ingress publishes the Sync server, and the admin UI on a host of its own: see [Ingress](install/helm.md#ingress) and [Admin UI](install/helm.md#admin-ui). The rules of this page still apply, in the Ingress controller's terms: [Request size](#request-size) is the one that matters for the Sync server.

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
- **The pairing websockets.** ingress-nginx closes a connection that is idle for 60 seconds, its default `proxy-read-timeout`, which can cut a pairing in the middle. Raise it in `fxa.ingress.annotations`, as the nginx example's `proxy_read_timeout 600`. These annotations go on all the accounts' Ingresses, which does no harm:

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
- **The avatars.** Send `/img/` of the profile host either to port 1114 (`img`) with the path as it is, or stripped of `/img` to port 1112 (`static`), as [fxa-example.conf](/config/nginx/fxa-example.conf) does to `127.0.0.1:1112/`.

The pairing server is a websocket, as in [Pairing](#pairing).
