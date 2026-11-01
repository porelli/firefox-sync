# Single sign-on and client certificates

Can you put the servers behind a sign-in proxy (single sign-on, such as Authelia) or ask for client certificates (mTLS)? Partly. Firefox calls most of the servers in the background, where it sends neither cookies nor a client certificate. So those hosts must stay open. What you can put behind either one is the accounts' web pages, where people sign up and sign in, and the admin UI.

This page says what works and why, then how to set it up. It applies to the [self-hosted accounts](accounts.md); with Mozilla's accounts, only the admin UI and the Sync server are yours, and the Sync server must stay open.

## What works

Tested with Firefox 158 on Linux, against the stack of `tests/e2e-fxa.sh` (`CLIENT_CERT=1` and `SSO=authelia`, see [Testing](development/testing.md#access-control)):

| Host | Client certificate | Sign-in proxy (forward auth) |
|---|---|---|
| Accounts pages, `FXA_CONTENT_URL` | **yes**, but on [the open paths](#the-open-paths) | **yes**, but on [the open paths](#the-open-paths) |
| Admin UI | **yes**, the whole host | **yes**, with its [trusted header](admin/signing-in.md#trusted-header), or [OpenID Connect](admin/signing-in.md#openid-connect) |
| Accounts API, `FXA_AUTH_URL` | no | no |
| Profile server, `FXA_PROFILE_URL` | no | no |
| Sync server, `SYNC_PUBLIC_URL` | no | no |
| Pairing server, `FXA_PAIRING_URL` | not with phones, see [Mobile](#mobile) | no |

With either one in front of the accounts pages, a new Firefox shows your sign-in page or uses its certificate when it opens the accounts pages, then signs up or signs in, gets its keys and syncs as usual. A second device gets the data, and the admin UI sees both devices. Sync does not depend on the proxy's session afterwards: none of its requests carries the cookie (below).

### What the pages' gate protects

It keeps strangers away from the sign-up and sign-in **pages**. It does not decide who has an account: the accounts API stays open, and a program can sign up or sign in through it without the pages, as Firefox's own code does. Who can sign up is the [sign-up policy](accounts.md#who-can-sign-up)'s job, which the API applies whatever the pages. Keep it on, with an allowlist, and use the gate on the pages as one more layer.

To keep the whole server off the internet, put it behind a VPN or a firewall instead: those apply to every connection, Firefox's background requests too.

## Why not the other hosts

### What Firefox sends

Firefox makes its accounts and Sync requests as anonymous requests: no cookies, no HTTP authentication and no client certificate.

- The accounts API, the profile, the tokenserver and the configuration of the accounts go through [RESTRequest](https://github.com/mozilla-firefox/firefox/blob/main/services/common/rest.sys.mjs), which sets `LOAD_ANONYMOUS` ("Don't send user cookies and such over the wire").
- Firefox's TLS layer gives no client certificate to an anonymous connection ([nsNSSIOLayer.cpp](https://github.com/mozilla-firefox/firefox/blob/main/security/manager/ssl/nsNSSIOLayer.cpp), `ANONYMOUS_CONNECT`).
- The Sync server's requests are a `fetch()` of Firefox's own code ([resource.sys.mjs](https://github.com/mozilla-firefox/firefox/blob/main/services/sync/modules/resource.sys.mjs)), which sends none either.
- The accounts pages call the API with cross-origin requests without credentials: no cookie, and no client certificate unless you set `network.cors_preflight.allow_client_cert` to `true` in `about:config`.

The tests show it. A Firefox with a client certificate, and with Authelia's session cookie for the parent domain:

| Request | Client certificate sent | Cookie sent |
|---|---|---|
| a page in a tab, the accounts pages' own requests to their host | yes | yes |
| the pairing websocket of the computer | yes | not checked |
| the accounts' configuration, `/.well-known/fxa-client-configuration` | no | no |
| the accounts API, the profile, the OAuth tokens, the devices | no | no |
| the tokenserver and the Sync server | no | no |

<details><summary>What breaks, host by host</summary>

- **Client certificates required on all the accounts hosts and the Sync server:** Firefox cannot even read the configuration. The Browser Console says `Failed to get configuration object from "https://accounts.example.com/.well-known/fxa-client-configuration"` with `0x804b0065` (`NS_ERROR_NET_UNCLEAN_SHUTDOWN`: the server closed the connection that came without a certificate), and the Sync preferences never get to the sign-in page. Every other request type of the table above fails the same way, `NetworkError when attempting to fetch resource`.
- **The accounts API behind the sign-in proxy:** the first page, with the email field, shows "Bad Request: System unavailable, try again soon". Its requests to the API start with CORS preflights, which never carry cookies, and get the proxy's redirect to its sign-in page.
- **The Sync server behind the sign-in proxy:** the sign-in finishes ("Sync is turned on"), then Sync fails with `error.sync.reason.no_node_found`: the tokenserver's `GET /1.0/sync/1.5` gets the proxy's `401`, though Firefox has the proxy's cookie for the parent domain.

</details>

### The open paths

Of the accounts pages' host, a few paths are fetched without a browser tab, and must stay open:

| Path | Fetched by |
|---|---|
| `/.well-known/fxa-client-configuration` | Firefox, for `identity.fxaccounts.autoconfig.uri` (anonymous) |
| `/.well-known/openid-configuration` | the admin UI's server, to [sign in with these accounts](admin/signing-in.md#self-hosted-accounts) |
| `/__heartbeat__`, `/__lbheartbeat__` | the admin UI's [public checks](admin/monitoring.md#public-checks), and your monitoring |

They hold no personal data. Everything else of that host is pages, their scripts and styles, and their own requests, which the browser sends with the certificate or the cookie.

### The servers among themselves

The servers call each other at their internal addresses, never through your reverse proxy: the Sync server checks Firefox's tokens at `FXA_OAUTH_SERVER_URL` (`http://fxa-auth:9000/v1`), the auth and profile servers call each other directly. The proxy's log of a whole test run shows no request from them.

The admin UI is the exception: it uses the public URLs, as Firefox would.

- To sign in with the accounts: the discovery on the pages' host (an open path), then the tokens and keys on the API host and the email on the profile host.
- Its [public checks](admin/monitoring.md#public-checks): `/__heartbeat__` of each host, and the [sign-up gate](reverse-proxy.md#sign-up-gate) through the API host.

None of them is behind the gate when you follow this page. The backups connect to the databases only.

## Client certificates

1. Make a CA for your devices, and a client certificate for each person, signed by it. With OpenSSL, for example:

   ```bash
   openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
     -subj "/CN=Firefox Sync devices" -keyout client-ca.key -out client-ca.crt
   openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=alice@example.com" \
     -keyout alice.key -out alice.csr
   printf 'extendedKeyUsage=clientAuth\n' > client.ext
   openssl x509 -req -in alice.csr -CA client-ca.crt -CAkey client-ca.key -CAcreateserial -days 825 \
     -extfile client.ext -out alice.crt
   openssl pkcs12 -export -in alice.crt -inkey alice.key -name "Firefox Sync" -out alice.p12
   ```

   Keep `client-ca.key` offline. The proxy needs `client-ca.crt` only.

1. Ask for them on the accounts pages, in your proxy (below), and on the admin UI's host if you publish it.
1. In Firefox, see [Firefox](#firefox).

### nginx

The first server of [access-control-example.conf](/config/nginx/access-control-example.conf) replaces the accounts pages' server of `config/nginx/fxa.conf`. It asks for the certificate at the handshake (`ssl_verify_client optional`), lets the open paths through, and answers `403` to the rest without one. A certificate of another CA gets `400`.

For the admin UI's host, the whole host, in its server of `fxa.conf`:

```nginx
ssl_client_certificate /etc/nginx/client-ca.crt;
ssl_verify_client on;
```

### Caddy

As [the test's](/tests/caddy/mtls/content.caddy), in the accounts pages' site:

```caddyfile
accounts.example.com {
	tls {
		client_auth {
			mode verify_if_given
			trust_pool file /etc/caddy/client-ca.crt
		}
	}
	@no_certificate {
		not path /.well-known/fxa-client-configuration /.well-known/openid-configuration /__heartbeat__ /__lbheartbeat__
		vars {http.request.tls.client.subject} ""
	}
	respond @no_certificate "a client certificate is required" 403
	reverse_proxy 127.0.0.1:3030
}
```

Match on the subject, not the fingerprint: without a certificate, Caddy's `{http.request.tls.client.fingerprint}` is the hash of nothing, not empty. For the admin UI's host, the whole host: `mode require_and_verify`.

### Firefox

On each computer, once per Firefox profile:

1. Settings, Privacy & Security, Certificates, **View Certificates**, tab **Your Certificates**, **Import**: the `.p12` file and its password.
1. Firefox asks which certificate to send each time a site wants one. To send it without asking, set `security.default_personal_cert` to `Select Automatically` in `about:config`, as the tests do. It then sends the first certificate that fits to any site that asks for one.

No enterprise policy imports a client certificate: `Certificates.Install` installs CAs only ([policy templates](https://mozilla.github.io/policy-templates/#certificates--install)). `SecurityDevices` loads a PKCS #11 module, such as a smart card's.

## Sign-in proxy

With Authelia, as the test runs it ([tests/caddy/authelia](/tests/caddy/authelia)): its session cookie on the parent domain (`example.com`), its pages on a host of their own (`auth.example.com`), a file of users. Other forward-auth proxies work the same way: what matters is to leave the other hosts and [the open paths](#the-open-paths) out.

In Authelia's configuration, a rule for the hosts it guards:

```yaml
access_control:
  default_policy: deny
  rules:
    - domain: [accounts.example.com, admin.example.com]
      policy: two_factor
session:
  cookies:
    - domain: example.com
      authelia_url: https://auth.example.com
```

### nginx

The second server of [access-control-example.conf](/config/nginx/access-control-example.conf), commented out, follows [Authelia's nginx integration](https://www.authelia.com/integration/proxies/nginx/): `auth_request` on every path but the open ones, which go straight to the accounts pages.

### Caddy

```caddyfile
accounts.example.com {
	@sso not path /.well-known/fxa-client-configuration /.well-known/openid-configuration /__heartbeat__ /__lbheartbeat__
	forward_auth @sso 127.0.0.1:9091 {
		uri /api/authz/forward-auth
	}
	reverse_proxy 127.0.0.1:3030
}
```

### The admin UI

Behind the sign-in proxy, the admin UI can take the user from the proxy's header, or sign in with OpenID Connect: [Signing in](admin/signing-in.md#trusted-header). Its Authelia examples are there.

## Mobile

Not tested here: only desktop Firefox is.

- The phones sync the same way, through the same open hosts, so this page's limits apply to them too.
- **Android:** Firefox for Android 138 and later can use client certificates installed in Android ([bug 1813930](https://bugzilla.mozilla.org/show_bug.cgi?id=1813930)), but does not remember the choice across restarts ([bug 2025124](https://bugzilla.mozilla.org/show_bug.cgi?id=2025124), open). Whether the sign-in pages work with one, or with a sign-in proxy, when you set a custom accounts server: untested.
- **iOS:** Firefox for iOS has no client certificates ([firefox-ios#25313](https://github.com/mozilla-mobile/firefox-ios/issues/25313), open). With client certificates on the accounts pages, an iPhone cannot sign in. A sign-in proxy's pages may work there: untested.
- **Pairing:** with a phone, the computer shows a QR code and both connect to the pairing server. The computer's websocket sends the certificate, the phone's is untested: leave the pairing host open.

## On Kubernetes

Notes for the chart's Ingresses: [Access control](install/helm.md#access-control).
