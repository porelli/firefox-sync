# Access control

Who can reach your server, who can have an account on it, who can sync, and who runs it. Each is its own control, and they add up. This page says which one does what, and links to its page.

## Who can sync

With **Mozilla's accounts**, anybody with a Mozilla account who can reach your Sync server can point Firefox to it. The Sync server is the only place to choose:

- [Invite-only Sync](limits.md#sync_allowed_accounts) (`SYNC_ALLOWED_ACCOUNTS`): only the accounts you approve, by their account id. Off by default.
- [Max users](limits.md#sync_max_users) (`SYNC_MAX_USERS`): how many accounts, whoever they are.

With **self-hosted accounts**, only the accounts of your accounts server can sign in, so choose who gets an account:

- [Who can sign up](accounts.md#who-can-sign-up) (`FXA_SIGNUPS`, `FXA_SIGNUP_ALLOWLIST`): anybody, an allowlist of emails and domains, or nobody.
- [Max accounts](limits.md#fxa_max_accounts) (`FXA_MAX_ACCOUNTS`): how many accounts the accounts server can have.
- [Invitations](admin/accounts.md#invitations), in the admin UI: add an email to the allowlist and send it an invitation.
- [The sign-up gate](reverse-proxy.md#sign-up-gate), with the admin UI: a refused sign-up says why, instead of "Unexpected error". The accounts database refuses those sign-ups with or without it.

Max users and invite-only Sync work there too, to keep some of those accounts off Sync. To take an account off Sync later: [reset its Sync data](admin/accounts.md#reset-the-sync-data) with **also free the max users slot**, so that its next try goes through max users and the allowlist again. With self-hosted accounts you can also [disable the account](admin/accounts.md#sign-out-and-disable).

## Who can reach it

- **A VPN or a firewall**: the whole server, every request included. This is the only way to keep Sync itself off the internet, because Firefox calls the Sync server and the accounts API in the background, without cookies or a client certificate.
- **[Single sign-on and client certificates](single-sign-on.md)**: a sign-in proxy (such as Authelia) or mTLS in front of the accounts' web pages and the admin UI, not the other hosts. It keeps strangers away from the pages, not from the accounts API: keep the sign-up policy on as well.

## Who runs it

The [admin UI](admin/README.md) has its own sign-in: a password, OpenID Connect (your identity provider, or the self-hosted accounts) or a trusted header from your proxy, and a list of who is an admin. See [Signing in](admin/signing-in.md).

## Where each one is set

| Control | `.env` | Helm values | Admin UI |
|---|---|---|---|
| Invite-only Sync | `SYNC_ALLOWED_ACCOUNTS` | `allowedAccounts` | [Invite-only Sync](admin/accounts.md#invite-only-sync), with `admin` or `initial:` |
| Max users | `SYNC_MAX_USERS` | `maxUsers` | [Limits](admin/accounts.md#limits), with `initial:` |
| Who can sign up | `FXA_SIGNUPS`, `FXA_SIGNUP_ALLOWLIST` | `fxa.signups`, `fxa.signupAllowlist` | [Sign-ups](admin/accounts.md#sign-ups) |
| Max accounts | `FXA_MAX_ACCOUNTS` | `fxa.maxAccounts` | [Limits](admin/accounts.md#limits), with `initial:` |
| Admin UI sign-in | `ADMIN_PASSWORD`, `ADMIN_OIDC_*`, `ADMIN_AUTH_HEADER` | `admin.password`, `admin.oidc.*`, `admin.trustedHeader.*` | no |

All the settings: [Settings](reference/settings.md).
