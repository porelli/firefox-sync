# Install with docker compose

This page installs the Sync server with docker compose. Read [What you need](../README.md#what-you-need) first. With Podman, see [Podman](podman.md) instead.

## Requirements

- Docker with the compose plugin 2.21 or later ([install](https://docs.docker.com/engine/install/)): `docker compose version`.
- A host name with HTTPS, proxied to the port of the Sync server: your reverse proxy, or the bundled Caddy. See [Reverse proxy](../reverse-proxy.md).

## Install

1. Clone the repository:

   ```bash
   git clone https://github.com/porelli/firefox-sync.git
   cd firefox-sync
   ```

1. Run the setup script:

   ```bash
   ./prepare_environment.sh
   ```

   It asks its questions, one component at a time, shows what it will write, then writes `.env` and, in `proxy/`, the configuration of your reverse proxy with your values. See [What the setup script asks](#what-the-setup-script-asks); to answer from a file instead, [Answers by name](#answers-by-name).

1. Set up your reverse proxy: put the file of yours from `proxy/` (`nginx.conf`, `Caddyfile`, `traefik.yml`) into it, see [Your own proxy](../reverse-proxy.md#your-own-proxy). With the bundled Caddy or the labels for Traefik, nothing to do here: `docker compose up -d` runs them ([The bundled Caddy](../reverse-proxy.md#the-bundled-caddy), [Traefik labels](../reverse-proxy.md#traefik-labels)).

1. Check the optional services before the first start: the admin UI, the nightly backups and, with self-hosted accounts, your own pairing server. The script asked for each and listed those you chose in `COMPOSE_PROFILES` of `.env`. Only those start: to add or remove one, see [Optional services](#optional-services).

1. Start the stack:

   ```bash
   docker compose up -d
   ```

   The databases start first, then the migrations, then the init container that sets the limit of users. The Sync server starts last, so that nobody signs in before the limit exists.

1. Check that the init container ran:

   ```bash
   docker compose logs tokenserver_db_init
   ```

   Its last line is `Current users: N`.

1. [Set up Firefox](../firefox.md).

## What the setup script asks

The questions go one component at a time, in seven parts, each with its number (`2/7 The Sync server`), then a review of every answer before anything is written:

1. **Deployment**: the directory of the checkout; with an `.env` there already, upgrade it (keep its passwords, as `--upgrade`) or set it up again; with Podman, Quadlets or docker compose; your domain, which the public addresses below default to (`sync.<domain>`, `accounts.<domain>`...).
1. **The Sync server**: its public URL, where it listens for your reverse proxy, its image tag, its database (the engine; in containers of the stack or on your own server, then its host, names and users), and how many accounts can use it.
1. **The accounts**: Mozilla's or self-hosted. With Mozilla's: invite-only Sync. Self-hosted: the public URLs of the accounts pages, API and profile server, their database, the SMTP server for their emails, who can sign up, the most accounts, the security history and the pairing server.
1. **The admin UI**: on or off, how admins sign in (the password; the self-hosted accounts; another OpenID Connect provider; a header of your reverse proxy), who is an admin, whether a password stays a way in with single sign-on, its public URL when a provider sends you back to it, and where its alerts go.
1. **Backups**: the nightly backups.
1. **Reverse proxy**: whether you run one already (its configuration is in `proxy/` in any case), else the bundled Caddy (its certificates, its ports) or the labels for your Traefik (its network, entry points and certificate resolver); who can open the admin UI's public address.
1. **Review**: what will be written, part by part, with the passwords and secrets the script generates (named, not shown). Write it, change a part (its questions again, the parts after it keep their answers), or quit with nothing written.

At a question:

- Enter takes the default. On a terminal it is ready to edit in place (bash 4 or later; macOS's bash 3.2 shows it in `[brackets]`).
- A choice is a list: ↑ and ↓ then Enter, or the option's number. Without a terminal (a pipe, a log), the list is numbered and its name or number is read.
- `<` (or `back`) goes back to the question before, with your answer as its default.
- An answer that is not valid is said, and asked again. Without a terminal the script stops instead, with nothing written.
- Passwords and the alerts' URLs are not shown as you type.

At the end the script lists the passwords and secrets it generated, and how to change each: see [Generated passwords and secrets](../reference/settings.md#generated-passwords-and-secrets). On a terminal it shows the admin UI's password once: keep it in your password manager. In a log it says where it is instead (`ADMIN_PASSWORD` in `.env`).

| Question | What it changes | More |
|---|---|---|
| the public URL of the Sync server | `SYNC_PUBLIC_URL`, its host in `proxy/` | [Reverse proxy](../reverse-proxy.md#host-names-and-ports) |
| where the Sync server listens, `127.0.0.1:5000` | `SYNC_EXPORT_PORT` | [Reverse proxy](../reverse-proxy.md#host-names-and-ports) |
| the image tag of the Sync server | `SYNC_IMAGE_TAG` (`latest`) | [Upgrading](../upgrading.md#sync-server) |
| the engine of the Sync server's database: `mariadb`, `mysql` or `postgres` | `SYNC_DB`, and its file in `COMPOSE_FILE` | [Databases](../databases.md) |
| the Sync server's database on your own server | `SYNC_DB_CONTAINERS=0`, and a `database-setup.sql` to run there | [Your own server](../databases.md#with-docker-compose) |
| max users of the Sync server | `SYNC_MAX_USERS` (`initial:` with the admin UI) | [Limits](../limits.md) |
| Mozilla's or self-hosted accounts | the accounts' section of `.env`, their hosts in `proxy/` | [Self-hosted accounts](../accounts.md#set-up) |
| invite-only Sync, with Mozilla's accounts | `SYNC_ALLOWED_ACCOUNTS` | [Limits](../limits.md#sync_allowed_accounts) |
| the admin UI | `admin` in `COMPOSE_PROFILES`, `ADMIN_PASSWORD` | [Admin UI](../admin/README.md#set-up) |
| how admins sign in, who is an admin | `ADMIN_OIDC_*`, `ADMIN_FXA_CLIENT_ID`, `ADMIN_AUTH_HEADER`, `ADMIN_TRUSTED_PROXIES`, `ADMIN_ALLOWED_USERS`, `ADMIN_ALLOWED_GROUPS` | [Signing in](../admin/signing-in.md) |
| the nightly backups | `backup` in `COMPOSE_PROFILES` (Quadlets: the backup timer enabled) | [Backups](../backups.md#the-backup-service) |
| with self-hosted accounts, your own pairing server (not with Quadlets) | `pairing` in `COMPOSE_PROFILES`, `FXA_PAIRING_URL`, its host in `proxy/` | [Pairing](../reverse-proxy.md#pairing) |
| your reverse proxy: yours, the bundled Caddy, the labels for Traefik | `PROXY`, `compose/caddy.yml` or `proxy/traefik-compose.yml` in `COMPOSE_FILE`, `CADDY_*`, `TRAEFIK_*` | [Reverse proxy](../reverse-proxy.md) |
| who can open the admin UI's public address | `PROXY_ADMIN_ALLOW` | [The admin UI](../reverse-proxy.md#the-admin-ui) |

Every setting is in [Settings](../reference/settings.md). Coming from another Sync server: read [Migrating](../migrating.md) before you run the script.

`COMPOSE_FILE` in `.env` names the compose files of your choices, so a plain `docker compose` always picks the right ones: see [The compose files](#the-compose-files).

`COMPOSE_PROFILES` gets every optional service you chose, for example `COMPOSE_PROFILES=admin,backup`. Set up again on an install, the script offers what its `.env` has as the answer to each of them.

### The public addresses

Each component that people or Firefox reach has a public URL of its own: the Sync server, and with self-hosted accounts their pages, API, profile server and pairing server, and the admin UI when a provider sends you back to it. Each is asked the same way: `https://host`, with `:port` when it is not 443 (a host alone is `https://`), defaulting to a host name under your domain. None of them can be under a path: each component answers at `/`, so each needs its own host name or port. The Sync server's tokens are bound to the path Firefox asks for, the accounts and the admin UI build their own URLs from the root, and `ADMIN_OIDC_REDIRECT_URL` must end in `/auth/callback` exactly.

| Address | Default | Setting | Schemes |
|---|---|---|---|
| the Sync server | `https://sync.<domain>` | `SYNC_PUBLIC_URL` | `https`, `http` |
| the accounts pages | `https://accounts.<domain>` | `FXA_CONTENT_URL`, also the issuer of their sign-in | `https`, `http` |
| the accounts API | `https://api.<domain>` | `FXA_AUTH_URL`; its host name is `FXA_EMAIL_DOMAIN` | `https`, `http` |
| the accounts profile server | `https://profile.<domain>` | `FXA_PROFILE_URL` | `https`, `http` |
| your own pairing server | `wss://pairing.<domain>` | `FXA_PAIRING_URL` | `wss`, `ws` |
| the admin UI | `https://admin.<domain>` | `ADMIN_OIDC_REDIRECT_URL` (that URL and `/auth/callback`) | `https`; `http` on `localhost` only |

Firefox needs `https` for all but `localhost`. The files of `proxy/` get the host names, and listen on the port of a URL that has one ([Host names and ports](../reverse-proxy.md#host-names-and-ports)).

## Answers by name

Each question has an id. Give answers by id and the script does not ask them; it asks only the others, or with `--non-interactive` gives them their defaults. That is how the tests run it, and how to set up from a script:

```bash
./prepare_environment.sh --answers answers.env                     # asks what the file does not answer
./prepare_environment.sh --answers answers.env --non-interactive   # asks nothing
FFS_SETUP_SYNC_MAX_USERS=5 ./prepare_environment.sh                 # FFS_SETUP_<ID>: the same, in the environment
```

The file has the syntax of `.env`, one `id=value` per line, `#` for comments: quote a value with spaces, `#` or `$` (`smtp_password='p@ss #1'`). An `FFS_SETUP_<ID>` of the environment wins over the file, and an empty answer is the default. An id that is no question stops the script, so a typo is never taken for the default. It has passwords: keep it yours only (`chmod 600`). For example, the self-hosted accounts with the admin UI signing in with them:

```ini
existing=new
domain=example.com
sync_max_users=5
accounts=self-hosted
smtp_host=smtp.example.com
smtp_user=mailer
smtp_password='your SMTP password'
fxa_signups=@example.com
admin_signin=accounts
admin_users=alice@example.com
backups=yes
```

A choice takes its name or its number in the list, yes or no `yes`, `y`, `no` or `n`.

| Id | Question | Answers | Default |
|---|---|---|---|
| `dir` | Directory of the checkout | a path | where the script is |
| `existing` | with an `.env` there: upgrade this install, or set it up again? | `upgrade`, `new` | `upgrade` |
| `runtime_none` | without Docker and Podman: continue anyway? | yes, no | no |
| `deploy` | with Podman: how the stack runs | `quadlets`, `compose` | `quadlets` |
| `container_user` | without Quadlets: the user of `config/systemd/syncstorage-rs.service` | a user name | `$USER` |
| `domain` | your domain, of the default host names | a domain | `example.com` |
| `sync_url` | public URL of the Sync server | see [The public addresses](#the-public-addresses) | `https://sync.<domain>` |
| `sync_listen` | where the Sync server listens | `[address:]port`, a port alone on `127.0.0.1` | `127.0.0.1:5000` (an install's: its own) |
| `sync_image_tag` | image tag of the Sync server | a tag | `latest` |
| `sync_db` | engine of the Sync server's database | `mariadb`, `mysql`, `postgres` | `mariadb` |
| `sync_db_own` | the Sync server's database on your own server? | yes, no | no |
| `sync_db_host`, `sync_db_port` | its host and port | as the containers reach it | none, `3306` (`5432`) |
| `sync_db_name`, `sync_db_user` | PostgreSQL: the database and its user | names | `syncserver` |
| `sync_tokenserver_db_name`, `sync_tokenserver_db_user`, `sync_storage_db_name`, `sync_storage_db_user` | MariaDB, MySQL: the two databases and their users | names | `tokenserver`, `syncstorage` |
| `sync_db_bootstrap` | let the stack apply the Sync server's database changes itself? | yes, no | no |
| `sync_db_bootstrap_user`, `sync_db_bootstrap_password` | the account that does | a name; a password (empty: generated) | `ffs_sync_bootstrap` |
| `sync_max_users` | max users of the Sync server | a number, `unlimited` | `1` |
| `accounts` | which accounts people sign in with | `mozilla`, `self-hosted` | `mozilla` |
| `sync_invite_only` | with Mozilla's accounts: invite-only Sync | `off`, `list`, `admin` (turns the admin UI on) | `off` |
| `sync_allowed_accounts` | with `list`: the uids that can sync | uids, comma-separated | none |
| `fxa_content_url`, `fxa_auth_url`, `fxa_profile_url` | self-hosted: public URLs of the accounts pages, API and profile server | see [The public addresses](#the-public-addresses) | `https://accounts.<domain>`, `https://api.<domain>`, `https://profile.<domain>` |
| `fxa_db` | engine of the accounts' database | `mysql`, `mariadb` | `mysql` |
| `fxa_db_own` | the accounts' database on your own server? | yes, no | no |
| `fxa_db_host`, `fxa_db_port`, `fxa_db_user`, `fxa_db_policy_user` | its host, port, the accounts' user, the sign-up policy's user | | the Sync server's host, `3306`, `fxa`, `ffs_policy` |
| `fxa_db_bootstrap`, `fxa_db_bootstrap_user`, `fxa_db_bootstrap_password` | as `sync_db_bootstrap*`, for the accounts | | no, `ffs_fxa_bootstrap` |
| `smtp_host`, `smtp_port`, `smtp_user`, `smtp_password`, `smtp_sender` | the SMTP server of the accounts' emails | | none, `587`, none, none, `Mozilla accounts <no-reply@<domain>>` |
| `fxa_signups` | who can create an account | emails and @domains, comma-separated; empty: anybody | anybody |
| `fxa_max_accounts` | max accounts of the self-hosted accounts | a number, `unlimited` | `unlimited` |
| `fxa_account_events` | record the security history? | yes, no | no |
| `pairing`, `pairing_url` | without Quadlets: your own pairing server, its public URL | yes, no; a `wss://` URL | no (an install's: its own), `wss://pairing.<domain>` |
| `admin` | run the admin UI? | yes, no | yes |
| `admin_signin` | how admins sign in | `password`, `accounts` (self-hosted only), `oidc`, `header` | `password` |
| `admin_url` | `accounts`, `oidc`: public URL of the admin UI | see [The public addresses](#the-public-addresses) | `https://admin.<domain>` |
| `admin_oidc_scopes` | `oidc`: the scopes to ask for, with `openid` (add `groups` for Authelia, Dex) | scopes, separated by spaces | `openid email profile` (`ADMIN_OIDC_SCOPES` left empty) |
| `admin_oidc_issuer`, `admin_oidc_client_id`, `admin_oidc_client_secret`, `admin_oidc_name` | `oidc`: your provider's issuer, the client, the name on the button | | none (the secret: a public client; the name: single sign-on) |
| `admin_auth_header`, `admin_auth_groups_header`, `admin_trusted_proxies` | `header`: the headers and your proxy's addresses | | `Remote-Email`, none, none |
| `admin_users` | who is an admin | emails and @domains | none (required with `accounts`) |
| `admin_groups` | `oidc`, `header`: groups whose members are admins | group names | none |
| `admin_password` | `accounts`, `oidc`, `header`: keep a password as a fallback? | yes; no: `ADMIN_PASSWORD` empty, single sign-on only | yes |
| `admin_notify` | where the alerts go too | destination URLs | none |
| `backups` | nightly backups? | yes, no | no (an install's: its own) |
| `proxy` | do you already run a reverse proxy? | `own`, `caddy` (the bundled Caddy), `traefik` (labels for your Traefik; not with Quadlets) | `own` (an install's: its own) |
| `proxy_admin_allow` | with the admin UI's public URL: who can open it | addresses and CIDRs, comma-separated; `anybody` | `127.0.0.1,::1` (this host) |
| `caddy_email` | `caddy`: the email for Let's Encrypt | an email; empty: none | none |
| `caddy_ca` | `caddy`: where its certificates come from | `letsencrypt`, `staging`, `internal` | `letsencrypt` |
| `caddy_http_port`, `caddy_https_port` | `caddy`: its ports on this host | ports | `80`, `443` |
| `traefik_network` | `traefik`: the network the public containers join for your Traefik | a network name (another than this stack's own: a warning) | `<project>-proxy` |
| `traefik_entrypoints` | `traefik`: its HTTPS entry points | names, comma-separated | `websecure` |
| `traefik_http_entrypoint` | `traefik`: its HTTP entry point, redirected to HTTPS | a name; `none` | `web` |
| `traefik_certresolver` | `traefik`: its certificate resolver | a name; `none`: its default certificate | none |
| `confirm` | the review: write? | `write`, `quit` | `write` |

## Optional services

They are compose profiles. `COMPOSE_PROFILES` in `.env` is the whole list of the profiles that run, comma-separated, without spaces: `COMPOSE_PROFILES=admin,backup` runs the admin UI and the backups. Commented out or empty, none runs.

| Profile | What it adds | Its services |
|---|---|---|
| `admin` | the [admin UI](../admin/README.md) | `ffs-admin` |
| `backup` | the nightly [backups](../backups.md#the-backup-service) | `backup`, and `backup-fxa` with self-hosted accounts |
| `pairing` | your own pairing server for [self-hosted accounts](../reverse-proxy.md#pairing) | `fxa-pairing` |

`pairing` is a service of `compose/fxa.yml`: it needs that file in `COMPOSE_FILE`, which the script sets when you self-host the accounts. Without it compose has no such service and starts nothing for it.

To turn one on, add it to the list and run `docker compose up -d`.

To turn one off, remove it from the list, then remove its containers: `docker compose up -d` leaves a service of a profile that is off running, and so does `--remove-orphans`. For example, for the backups:

```bash
docker compose rm -sf backup        # with self-hosted accounts: backup backup-fxa
```

## The compose files

They are in [compose/](/compose). An install has `compose/sync.yml`, exactly one file of the Sync database, and with self-hosted accounts `compose/fxa.yml` and exactly one file of their database; with the bundled Caddy or the labels for Traefik, their file last. Each database file adds its containers, volumes and backup client, and what the other services need of it. The files of one database do not build on another's.

| File | What it has |
|---|---|
| [compose/sync.yml](/compose/sync.yml) | the Sync server, its migrations, the init container, the admin UI and the backups, without a database |
| [compose/sync-mariadb.yml](/compose/sync-mariadb.yml) | Sync on MariaDB (`SYNC_DB=mariadb`): `tokenserver_db`, `syncstorage_db` |
| [compose/sync-mysql.yml](/compose/sync-mysql.yml) | Sync on MySQL (`SYNC_DB=mysql`): the same services, MySQL's images and volumes |
| [compose/sync-postgres.yml](/compose/sync-postgres.yml) | Sync on PostgreSQL (the `syncstorage-rs-postgres` images): `postgres_db`, and `sync_role_init`, the Sync server's own role |
| [compose/fxa.yml](/compose/fxa.yml) | the self-hosted accounts, without their database |
| [compose/fxa-mysql.yml](/compose/fxa-mysql.yml) | the accounts on MySQL (`FXA_DB=mysql`): `fxa-db` |
| [compose/fxa-mariadb.yml](/compose/fxa-mariadb.yml) | the accounts on MariaDB (`FXA_DB=mariadb`): `fxa-db` |
| [compose/podman.yml](/compose/podman.yml) | docker compose on the Podman socket, see [Podman](podman.md) |
| [compose/caddy.yml](/compose/caddy.yml) | `PROXY=caddy`: the bundled Caddy, see [The bundled Caddy](../reverse-proxy.md#the-bundled-caddy) |
| `proxy/traefik-compose.yml` | `PROXY=traefik`: the labels for your Traefik, written by the script ([Traefik labels](../reverse-proxy.md#traefik-labels)) |

For example, Sync on PostgreSQL with the accounts on MySQL:

```bash
COMPOSE_FILE=compose/sync.yml:compose/sync-postgres.yml:compose/fxa.yml:compose/fxa-mysql.yml
COMPOSE_PROJECT_NAME=firefox-sync
```

`prepare_environment.sh` writes both lines. With your own database server (`SYNC_DB_CONTAINERS=0`, `FXA_DB_CONTAINERS=0`) the files are the same: the database services then run no container. With your own MySQL server for Sync, the script writes `compose/sync-mariadb.yml`, whose backups use the MariaDB client.

Compose takes the directory of the first file as the project's directory:

- `COMPOSE_PROJECT_NAME` keeps the project, and so the names of the containers and volumes, that of the directory of the checkout. Without it compose would name the project `compose`, and find none of them. A copy of the checkout, or a second stack, needs a name of its own (`COMPOSE_PROJECT_NAME` in [Settings](../reference/settings.md#sync)).
- Relative paths in compose files, also in your own files in `COMPOSE_FILE`, are relative to `compose/`: `../config/` is the checkout's `config/`.
- With `-f` instead of `COMPOSE_FILE`, add `--env-file .env`: compose looks for `.env` in `compose/` otherwise, and stops (`required variable SYNC_MASTER_SECRET is missing a value`).

`docker-compose.yml` at the top is only for the installs from before `compose/` that never set `COMPOSE_FILE`: it runs `compose/sync.yml` and `compose/sync-mariadb.yml` ([Files that moved](../upgrading.md#files-that-moved)).

## Change a setting

1. Edit `.env`.
1. Apply it:

   ```bash
   docker compose up -d
   ```

   Compose recreates the containers whose settings changed. The migrations and the init container run again before the Sync server.

## Start at boot

Every long-running container has `restart: unless-stopped`, so Docker starts the stack again at boot. If you would rather have systemd manage it, the script also writes `config/systemd/syncstorage-rs.service` from [this example](/config/systemd/syncstorage-rs-example.service).

## Next

- [Who can use your server](../limits.md)
- [Backups](../backups.md)
- [Upgrading](../upgrading.md#sync-server)
- Something fails: [Troubleshooting](../troubleshooting.md)
