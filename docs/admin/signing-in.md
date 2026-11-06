# Signing in to the admin UI

How admins sign in to the [admin UI](README.md): a password, OpenID Connect, or a header set by your reverse proxy. Turn the admin UI on first, see [Set up](README.md#set-up).

## Set up with the setup script

`prepare_environment.sh` asks in its part about the admin UI ([What the setup script asks](../install/compose.md#what-the-setup-script-asks)):

1. **How admins sign in**: `password` (only the password), `accounts` (the [self-hosted accounts](#self-hosted-accounts), offered only with them), `oidc` ([another provider](#openid-connect)) or `header` ([a header of your proxy](#trusted-header)).
1. **With `accounts` or `oidc`, the public URL of the admin UI**, where the provider sends you back: `ADMIN_OIDC_REDIRECT_URL` is that URL and `/auth/callback`. Over `http` only on `localhost`.
1. **With `oidc`**: the issuer, the client's id and secret (empty: a public client), the name on the button, and the scopes (`ADMIN_OIDC_SCOPES`, default `openid email profile`; Authelia and Dex need `groups` added for admins by group, see [Providers](#providers)). Create the client at your provider first, with that redirect URI.
1. **With `header`**: the header with the email (`Remote-Email` by default), the groups header if your proxy sets one, and your proxy's addresses (`ADMIN_TRUSTED_PROXIES`).
1. **Who is an admin**: emails and @domains (`ADMIN_ALLOWED_USERS`), and with `oidc` or `header` groups too (`ADMIN_ALLOWED_GROUPS`). Only those get in, never every account the provider knows: see [Who is an admin](#who-is-an-admin).
1. **With `accounts`, `oidc` or `header`: keep a password as a fallback?** Yes (the default): `ADMIN_PASSWORD` is generated and works too, over an SSH tunnel when the provider or the proxy is down. No: single sign-on only, `ADMIN_PASSWORD` empty (no password form); set one in `.env` later to have it back. See [Security notes](#security-notes).

By name: `admin_signin`, `admin_url`, `admin_oidc_issuer`, `admin_oidc_client_id`, `admin_oidc_client_secret`, `admin_oidc_name`, `admin_oidc_scopes`, `admin_auth_header`, `admin_auth_groups_header`, `admin_trusted_proxies`, `admin_users`, `admin_groups`, `admin_password` ([Answers by name](../install/compose.md#answers-by-name)). The groups claim keeps its default (`ADMIN_OIDC_GROUPS_CLAIM` in `.env` for another).

## Ways to sign in

Each way is on when it is configured, and any combination works. With none of them the admin UI does not start.

| Way | Settings | What happens |
|---|---|---|
| password | `ADMIN_PASSWORD` | a password form. At least 12 characters; empty: no form |
| OpenID Connect | `ADMIN_OIDC_*` | a "Sign in with ..." button: your identity provider, or the self-hosted accounts, says who you are |
| trusted header | `ADMIN_AUTH_HEADER`, `ADMIN_TRUSTED_PROXIES` | the reverse proxy in front signs you in and passes your email in a header |

With the Helm chart these are `admin.password` (or the Secret's `ADMIN_PASSWORD`), `admin.oidc.*`, `admin.trustedHeader.*` and `admin.allowed.*`, see [Settings](../reference/settings.md#admin-ui-sign-in).

Whatever the way, you get the same [session](README.md#sessions). The [event log](monitoring.md#event-log) and the alerts record who signed in and how:

```text
signed in: alice@example.com (oidc)
signed in: alice@example.com (header)
signed in (password)
```

Refused sign-ins are logged too, as `sign-in` events: a wrong password, not an admin, an email not verified, a sign-in that did not start here. Anybody can cause those, so they have their own share of the event log and the alerts, and cannot push the sign-ins and the changes out. A callback with no state cookie is not logged at all, a bad state at most every 10 minutes.

## When the session ends

Sessions live in the admin UI's memory: a restart of its container (an upgrade, `docker compose up -d` with a changed setting, a new pod) ends them all, and a session lasts 12 hours at most ([Sessions](README.md#sessions)). You then sign in again, and come back to where you were:

- **A page you open or refresh** takes you to the login page, which says "Sign in to continue to" the page. Once signed in, with the password or OpenID Connect, you are on that page again, with its query (the filter of the Activity page, a search).
- **A form you send** (a button that changes something) is not sent: the login page says "Your session ended (the admin UI restarted or you were away): sign in again; the form was not sent." and brings you back to the page of the form. Check it and send it again. The admin UI never replays a form.
- **The trusted header** signs you in on the request itself: the page opens as asked, with no login page in between.

Only pages of the admin UI count, as a path on the same server: any other address, the login page itself or a static file brings you to the overview instead, so a link cannot send you elsewhere after the sign-in. With OpenID Connect the page waits in the admin UI's signed state cookie; the provider never sees it. Scripts that post without a session (no `text/html` in `Accept`) still get `401 Not signed in`.

## Who is an admin

With OpenID Connect or the header, only the users you list are admins. Everybody else the provider knows is refused:

```ini
ADMIN_ALLOWED_USERS=alice@example.com,@example.org   # emails and @domains, like FXA_SIGNUP_ALLOWLIST
ADMIN_ALLOWED_GROUPS=ffs-admins                      # and/or groups of the provider
```

With neither set, the admin UI refuses to start rather than let in anybody the provider knows.

## OpenID Connect

The admin UI is a regular OpenID Connect client: the authorization code flow with PKCE, state and nonce.

1. Create a client ("application") at your provider, with the redirect URI `https://admin.example.com/auth/callback`. It is the public address of the admin UI, exactly.
1. Set the client in `.env`:

   ```ini
   ADMIN_OIDC_ISSUER=https://id.example.com           # the provider's issuer, it serves /.well-known/openid-configuration
   ADMIN_OIDC_CLIENT_ID=...
   ADMIN_OIDC_CLIENT_SECRET=...                       # empty for a public client (PKCE only)
   ADMIN_OIDC_REDIRECT_URL=https://admin.example.com/auth/callback
   ADMIN_OIDC_NAME=Authentik                          # the button: "Sign in with Authentik" (default: single sign-on)
   # optional
   ADMIN_OIDC_SCOPES=openid email profile             # the default; add groups for providers that want it
   ADMIN_OIDC_GROUPS_CLAIM=groups                     # the default, the claim with the groups for ADMIN_ALLOWED_GROUPS
   ```

1. List the admins, see [Who is an admin](#who-is-an-admin), then start the stack again.

The email comes from the ID token, or from the provider's userinfo endpoint when the ID token has none. It counts only when the provider says it is verified (`email_verified: true`).

An ID token without the nonce is accepted from two kinds of provider only:

- one whose discovery lists `S256` in `code_challenge_methods_supported`: it checks the PKCE verifier, which then ties the sign-in to the browser;
- the self-hosted accounts (`ADMIN_OIDC_ISSUER` equal to `FXA_CONTENT_URL`).

The admin UI connects to the provider for discovery, keys, tokens and userinfo, so the container must reach the issuer's URLs. The browser comes back from the provider to the admin UI: publish it on its own host name, see [The admin UI](../reverse-proxy.md#the-admin-ui) on the reverse proxy page. With providers that accept `http://localhost` redirects, `ADMIN_OIDC_REDIRECT_URL=http://localhost:8090/auth/callback` also works through the SSH tunnel.

### Providers

What to set for each provider, and the pitfall that matters here. Each provider's name links its own docs on creating a client.

| Provider | `ADMIN_OIDC_ISSUER` | Groups | Watch out |
|---|---|---|---|
| [Authentik](https://docs.goauthentik.io/add-secure-apps/providers/oauth2/) | `https://authentik.example.com/application/o/<application slug>/`, with the final `/` | the `groups` claim of the default `profile` scope | a confidential client with a signing key (RS256). Since 2025.10 its `email` scope sends `email_verified: false` by default: make it send `true` (its docs say how), or allow by group |
| [Keycloak](https://www.keycloak.org/docs/latest/server_admin/) | `https://keycloak.example.com/realms/<realm>` | a Group Membership mapper on the client's dedicated scope, claim `groups`, full group path off | set PKCE method S256 in the client's Capability config (Settings tab). `email_verified` is the user's "Email verified" switch |
| [Authelia](https://www.authelia.com/configuration/identity-providers/openid-connect/clients/) | `https://auth.example.com` | `ADMIN_OIDC_SCOPES=openid email profile groups` | `ADMIN_OIDC_CLIENT_SECRET` is the secret before hashing. Client config below |
| [Google](https://developers.google.com/identity/openid-connect/openid-connect) | `https://accounts.google.com` | none in its tokens | list the admins in `ADMIN_ALLOWED_USERS`: `@yourcompany.com` for a Google Workspace domain, **never `@gmail.com`**, which is anybody with a Gmail address |
| [Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app) | `https://login.microsoftonline.com/<tenant id>/v2.0`, your tenant, not `common` or `organizations` | add a groups claim (security groups); `ADMIN_ALLOWED_GROUPS=<object id of the group>`, Entra sends ids, not names | Entra sends no `email_verified`, and an account's `email` can be set to any address: **allow by group only** |
| [Dex](https://dexidp.io/docs/connectors/github/), for GitHub | `https://dex.example.com` (Dex's `issuer`) | `ADMIN_OIDC_SCOPES=openid email profile groups`, then `ADMIN_ALLOWED_GROUPS=your-org:ffs-admins` | GitHub is not an OpenID Connect provider: go through Dex, or oauth2-proxy (see [Trusted header](#trusted-header)). Dex marks GitHub's primary email as verified |

<details><summary>Authelia client</summary>

```yaml
identity_providers:
  oidc:
    clients:
      - client_id: ffs-admin
        client_name: Firefox Sync admin
        client_secret: '$pbkdf2-sha512$...'   # authelia crypto hash generate pbkdf2 --random
        public: false
        authorization_policy: two_factor
        require_pkce: true
        pkce_challenge_method: S256
        redirect_uris: [https://admin.example.com/auth/callback]
        scopes: [openid, email, profile, groups]
        token_endpoint_auth_method: client_secret_basic
```

</details>

<details><summary>Dex with GitHub</summary>

```yaml
staticClients:
  - id: ffs-admin
    name: Firefox Sync admin
    secret: <random>
    redirectURIs: [https://admin.example.com/auth/callback]
connectors:
  - type: github
    id: github
    name: GitHub
    config:
      clientID: <GitHub OAuth app>
      clientSecret: <...>
      redirectURI: https://dex.example.com/callback
      orgs: [{name: your-org, teams: [ffs-admins]}]
```

</details>

### Self-hosted accounts

With [self-hosted accounts](../accounts.md), the accounts service is an OpenID Connect provider too. In `prepare_environment.sh`, choose `accounts` for how admins sign in, then give the admins' emails and the public URL of the admin UI (`https://admin.<your domain>`). It then sets it all up, with that host in the configuration of the reverse proxy, `proxy/` ([The admin UI](../reverse-proxy.md#the-admin-ui)).

By hand:

```ini
ADMIN_FXA_CLIENT_ID=<16 random hex characters>     # e.g. openssl rand -hex 8
ADMIN_OIDC_REDIRECT_URL=https://admin.example.com/auth/callback
ADMIN_ALLOWED_USERS=alice@example.com
ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL=true
```

The accounts service registers the admin UI as an OAuth client at every start ([config/fxa/oauth-clients.js](/config/fxa/oauth-clients.js)). The client is trusted (no consent screen) and public (PKCE only), with the scopes `openid profile email`. `ADMIN_FXA_CLIENT_SECRET` stays empty: the accounts service refuses PKCE from clients with a secret.

| Install | The issuer and the client |
|---|---|
| docker compose | the admin UI uses `ADMIN_OIDC_ISSUER=FXA_CONTENT_URL` and this client, named "Mozilla account", unless the `ADMIN_OIDC_*` are set |
| Quadlets | set `ADMIN_OIDC_ISSUER`, `ADMIN_OIDC_CLIENT_ID` and `ADMIN_OIDC_NAME` too; `prepare_environment.sh` writes them all to `.env` |
| Helm | `admin.fxaSignIn: true`: the chart derives the client id and sets the rest, see [Sign in with the accounts](../install/helm.md#sign-in-with-the-accounts) |

The accounts service has no `email_verified` claim: its ID tokens carry no email, and its userinfo endpoint (`FXA_PROFILE_URL/v1/profile`) returns the email alone. Hence `ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL=true`, which is safe here. The stack lists the admin UI's client in the accounts service's `SERVICES_WITH_EMAIL_VERIFICATION`, so it hands out a sign-in only for a confirmed session (the email code of a new account or a new sign-in), never for a password alone.

The admin UI reaches the accounts by their public URLs (`FXA_CONTENT_URL`, `FXA_AUTH_URL`, `FXA_PROFILE_URL`), through your reverse proxy. The server must be able to reach its own public host names. With a sign-in proxy or client certificates in front of the accounts pages, leave their `/.well-known/openid-configuration` open: see [The open paths](../single-sign-on.md#the-open-paths).

## Trusted header

When a reverse proxy already signs people in (forward auth), the admin UI can take the user from a header the proxy sets:

```ini
ADMIN_AUTH_HEADER=Remote-Email           # the header with the user's email
ADMIN_AUTH_GROUPS_HEADER=Remote-Groups   # optional: comma-separated groups, for ADMIN_ALLOWED_GROUPS
ADMIN_TRUSTED_PROXIES=172.18.0.1/32      # required: the proxy's address as the admin UI sees it
```

Anybody who can send a request to the admin UI can send that header. These rules keep it safe.

**The address you trust is everybody's who connects from it.** With the admin UI on `127.0.0.1:8090` and your proxy on the same host, the admin UI sees your proxy's requests coming from the host's loopback or the compose network's gateway: so does every process of the host and, through published ports, containers. Each of them can then sign in as anybody, with a header of its own. So:

- prefer [OpenID Connect](#openid-connect) when the only proxy you have is on the host;
- or a proxy with an address of its own: Traefik on a network of the stack's own, `ADMIN_TRUSTED_PROXIES` its address there, `/32` ([Traefik labels](../reverse-proxy.md#traefik-labels): the setup refuses a range there, and an address of another network);
- not with the bundled Caddy, which reaches the admin UI from `127.0.0.1`: the setup does not offer it with the header, and refuses `proxy=caddy` with `admin_signin=header` ([The bundled Caddy](../reverse-proxy.md#the-bundled-caddy)).

The setup warns when `ADMIN_TRUSTED_PROXIES` has a loopback address, a gateway (`x.x.x.1`) or a range of a private network. The files of `proxy/` drop the headers a client sends on the admin UI's route, when `ADMIN_AUTH_HEADER` is set ([The admin UI](../reverse-proxy.md#the-admin-ui)): that keeps clients of the proxy out, not what reaches the admin UI's port past it.

**Use the header only with `ADMIN_EXPORT_PORT` on a loopback address** (the default `127.0.0.1:8090`), or with the admin UI not published and the proxy a container with a fixed address on the stack's network. Published on another address (`0.0.0.0:8090`, a LAN address), the port forwarders make every client arrive from the same address as your proxy. Trusting it then trusts everybody, who can send `Remote-Email: admin@...` themselves. With the proxy on another machine, use OpenID Connect instead.

The forwarders in question are Podman's rootlessport, Docker's docker-proxy, and the path of IPv6 clients to an IPv4-only container.

**`ADMIN_TRUSTED_PROXIES`**: the header counts only on connections whose own address, not `X-Forwarded-For`, is in this list. From anywhere else it is ignored.

- With a proxy on the host and the admin UI on `127.0.0.1:8090`, the admin UI sees the gateway of the compose network. The project is the directory name unless `COMPOSE_PROJECT_NAME` says otherwise:

  ```bash
  docker network inspect <project>_default -f '{{(index .IPAM.Config 0).Gateway}}'
  ```

- With Podman it depends on the network backend (rootlessport, pasta): check from which address your proxy's requests arrive.
- Any program on the host, and anybody with an SSH tunnel to it, then connects from that address too, and the containers of the host through published ports: each can sign in as anybody. Trust a whole host only if you trust everything on it, and prefer OpenID Connect there.
- A proxy running as a container on the stack's network, with a fixed address and the admin UI not published, narrows it down to that proxy.
- On Kubernetes the admin UI sees the address of the Ingress controller's pod: `admin.trustedHeader.trustedProxies` lists the controller's pod addresses. Every other pod of the cluster can reach the admin UI's Service directly unless a NetworkPolicy of yours allows only the controller. The chart has none.

**The proxy must replace the headers.** It sets them itself on every request and drops what the client sends, the groups header too. A groups header the client can send makes anybody the proxy lets in an admin.

- nginx's `proxy_set_header` replaces the header, and leaves it out when the value is empty. Check your proxy does the same.
- Leave `ADMIN_AUTH_GROUPS_HEADER` empty when your proxy sets no groups header (Tailscale, `cloudflared`).
- A header sent twice, by a proxy that appends instead of replacing, is refused: no user, or no groups.

Also:

- The user must be plain ASCII, since other characters could pass for the letters of an allowed address. It is compared without case.
- The session follows the header: when it names another user, or disappears, the session ends.

### Authelia with nginx

Authelia's [nginx integration](https://www.authelia.com/integration/proxies/nginx/) passes `Remote-Email` and `Remote-Groups`:

```nginx
server {
  server_name admin.example.com;
  listen 443 ssl;
  # ssl_certificate ...

  location /internal/authelia/authz {
    internal;
    proxy_pass http://127.0.0.1:9091/api/authz/auth-request;
    proxy_set_header X-Original-Method $request_method;
    proxy_set_header X-Original-URL $scheme://$http_host$request_uri;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header Content-Length "";
    proxy_set_header Connection "";
    proxy_pass_request_body off;
  }

  location / {
    auth_request /internal/authelia/authz;
    auth_request_set $user_email $upstream_http_remote_email;
    auth_request_set $user_groups $upstream_http_remote_groups;
    auth_request_set $redirection_url $upstream_http_location;
    error_page 401 =302 $redirection_url;
    # replaces whatever the client sent
    proxy_set_header Remote-Email $user_email;
    proxy_set_header Remote-Groups $user_groups;
    proxy_set_header Host $http_host;
    proxy_pass http://127.0.0.1:8090;
  }
}
```

### Authelia with Caddy

Caddy's `forward_auth` copies Authelia's headers to the request, as `tests/e2e-fxa.sh` runs it with `SSO=authelia` ([tests/caddy/authelia](/tests/caddy/authelia)):

```caddyfile
admin.example.com {
	forward_auth 127.0.0.1:9091 {
		uri /api/authz/forward-auth
		copy_headers Remote-Email Remote-Groups
	}
	reverse_proxy 127.0.0.1:8090
}
```

Another host of Caddy's that also reaches the admin UI must drop the headers the client sends, `request_header -Remote-Email` and `request_header -Remote-Groups`: the admin UI trusts every request from Caddy's address.

### Other proxies

| Proxy | `ADMIN_AUTH_HEADER` | Notes |
|---|---|---|
| [oauth2-proxy](https://oauth2-proxy.github.io/oauth2-proxy/configuration/integrations/nginx/) | `X-Auth-Request-Email`, groups in `X-Auth-Request-Groups` | any OAuth provider, GitHub too (`--provider=github --github-org=your-org`). Start it with `--reverse-proxy --set-xauthrequest`, and set both headers with `proxy_set_header` as in the Authelia example |
| [Tailscale](https://tailscale.com/docs/features/tailscale-serve) | `Tailscale-User-Login` | `tailscale serve --bg http://127.0.0.1:8090` publishes the admin UI on your tailnet only, and replaces any header the client sends. `ADMIN_ALLOWED_USERS` takes the logins (an email, or e.g. `alice@github`). The requests come from `tailscaled` on the host. Not with Funnel, which is public and has no user |
| Tailscale behind nginx | the header you pass on | [`tailscale nginx-auth`](https://github.com/tailscale/tailscale/tree/main/cmd/nginx-auth) answers nginx's `auth_request` with the user in `Tailscale-User`: pass it on with `proxy_set_header` |
| [Authentik proxy outpost](https://docs.goauthentik.io/add-secure-apps/providers/proxy/) | `X-authentik-email` | its groups header is separated by `\|`: allow by email |
| [Cloudflare Access](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/saas-apps/generic-oidc-saas/) | prefer OpenID Connect | Access can be an OpenID Connect provider (a SaaS application with OIDC). See below for why the header is risky |

Cloudflare's `Cf-Access-Authenticated-User-Email` header, through `cloudflared`, is only vouched for on the hostnames and paths an Access application covers. The admin UI does not check Cloudflare's signed `Cf-Access-Jwt-Assertion`. So a tunnel ingress rule that reaches the admin UI without Access (another hostname, a catch-all, a bypass policy) lets anybody send the header from `cloudflared`'s address.

## Security notes

- **The trusted header trusts an address, and everything that connects from it.** Not the host's loopback nor a gateway, which every process and container of the host shares: see [Trusted header](#trusted-header).
- **Fail closed.** The admin UI does not start with OpenID Connect or the header but neither `ADMIN_ALLOWED_USERS` nor `ADMIN_ALLOWED_GROUPS`, with the header but no `ADMIN_TRUSTED_PROXIES`, or with no way to sign in at all.
- **Verified emails only.** An email counts only when the provider says it is verified. `ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL=true` turns that off: then whoever can set an address at the provider (their own profile, another tenant) can become that admin. Use it only where users cannot pick their email, such as the [self-hosted accounts](#self-hosted-accounts).
- **`@domain` admits the whole domain.** In `ADMIN_ALLOWED_USERS` it admits every account of that domain at the provider: right for your company's domain, wrong for a public one.
- **Keep the password as a way in** when the provider is down, or empty it to allow single sign-on only. Every sign-in, whatever the way, is in the event log and the alerts.
