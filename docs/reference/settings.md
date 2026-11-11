# Settings

Every setting of the stack, once: its name in `.env`, its Helm value, its default, what it does, and its old name if it was renamed. The tasks that use them are on the other pages: start from [the docs index](../README.md).

How to read the tables:

- **`.env`**: the setting in the `.env` of docker compose and the Quadlets. `prepare_environment.sh` writes it; [.env-example](/.env-example) has every line with its default. The Quadlets hold their own copy of the values: see [Change a setting](../install/podman.md#change-a-setting).
- **Helm**: the value in the chart's [values.yaml](/charts/firefox-sync/values.yaml). "Secret: `KEY`" is a key of the chart's Secret or of your [existingSecret](../install/helm.md#existingsecret). "–" means the chart has no such value.
- **Default**: the value of `.env-example` (Helm: of `values.yaml`). "generated" means `prepare_environment.sh` (Helm: the chart) generates a random one. "unset" is what compose uses when the line is missing.
- **Old name**: the name before the `SYNC_` prefix. Compose still reads it: see [Renamed settings](../upgrading.md#renamed-settings).

## Sync

| `.env` | Helm | Default | Meaning | Old name |
|---|---|---|---|---|
| `SYNC_PUBLIC_URL` | `syncDomain` | required | the public `https://` URL of the Sync server, which the init container sets as the node of the tokenserver. Firefox uses `<it>/1.0/sync/1.5` | `SYNCSTORAGE_DOMAIN` |
| `SYNC_MAX_USERS` | `maxUsers` | `1` (Helm `"1"`) | how many accounts can use the server: `N`, `fixed:N`, `initial:N` or `unlimited`. The forms: [Limits](../limits.md#sync_max_users) | `MAX_USERS` |
| `SYNC_ALLOWED_ACCOUNTS` | `allowedAccounts` | empty: off | invite-only Sync, the uids that can start to sync: `<uid>,...`, `fixed:<uid>,...`, `admin` or `initial:<uid>,...`. The forms: [Limits](../limits.md#sync_allowed_accounts) | |
| `SYNC_MASTER_SECRET` | Secret: `SYNC_MASTER_SECRET` | generated | signs the Sync tokens. A new one signs every Firefox out | |
| `SYNC_METRICS_HASH_SECRET` | Secret: `METRICS_HASH_SECRET` | generated | the key of the hash of the account ids in the metrics | `METRICS_HASH_SECRET` |
| `SYNC_EXPORT_PORT` | – (the Service, port `syncstorage.service.port`, `8000`) | `127.0.0.1:5000` | where the host publishes the Sync server for your reverse proxy: `[address:]port`. A port alone in `.env` publishes it on every interface: [Host names and ports](../reverse-proxy.md#host-names-and-ports). The setup takes the next free port when something else listens there, as for every `*_EXPORT_PORT` ([Ports in use](../reverse-proxy.md#ports-in-use)) | `CONTAINER_EXPORT_PORT` |
| `FXA_OAUTH_SERVER_URL` | `fxa.oauthServerUrl` | `https://oauth.accounts.firefox.com/v1` | where the tokenserver checks the sign-in tokens. Self-hosted accounts: `http://fxa-auth:9000/v1` always, container-to-container: inside the stack the accounts API listens on 9000, whatever the host port `FXA_AUTH_EXPORT_PORT` is ([Sign-in keys: connection refused](../troubleshooting.md#sign-in-keys-connection-refused); Helm: the chart sets it with `fxa.enabled`) | |
| `FXA_EMAIL_DOMAIN` | `fxa.emailDomain` | `api.accounts.firefox.com` | the tokenserver keeps each account as `<uid>@FXA_EMAIL_DOMAIN`. Self-hosted accounts: the host of `FXA_AUTH_URL` (Helm: set by the chart). A new value makes every account a new one | |
| `COMPOSE_FILE` | – | unset: `docker-compose.yml`, Sync on MariaDB (installs from before `compose/`) | the compose files, separated by `:`: `compose/sync.yml`, the Sync database's, the accounts', the reverse proxy's ([The compose files](../install/compose.md#the-compose-files)) | |
| `COMPOSE_PROJECT_NAME` | – | unset: the directory of the first compose file | the compose project, which names the containers and volumes: `prepare_environment.sh` writes the checkout's directory, as compose names it (lowercase, `a-z 0-9 _ -`, no `_` or `-` first), and keeps a name already there. A copy of the checkout keeps the name of the original, and its `docker compose down -v` removes the original's volumes: a copy, or a second stack, needs a name of its own here. The setup and `--upgrade` warn when the name is not the directory's ([The compose files](../install/compose.md#the-compose-files)) | |
| `COMPOSE_PROFILES` | `admin.enabled`, `backup.enabled` | unset: none | the optional services that run, the whole list comma-separated: `admin`, `backup`, `pairing` (self-hosted accounts), see [Optional services](../install/compose.md#optional-services) | |

## Images

Which tags exist, and what each image is: [Images](images.md). When to pin them: [Upgrading](../upgrading.md#how-the-images-move).

| `.env` | Helm | Default | Meaning | Old name |
|---|---|---|---|---|
| `IMAGE_REPOSITORY` | `image.repository` | `ghcr.io/porelli/firefox-sync` | the registry and repository of the Sync, init and admin UI images | `REPOSITORY` |
| `SYNC_IMAGE` | – (follows `database.backend`) | `syncstorage-rs-mysql` | the Sync server's image: `syncstorage-rs-mysql` (MariaDB, MySQL) or `syncstorage-rs-postgres` | `SYNCSTORAGE_IMAGE` |
| `SYNC_IMAGE_TAG` | `image.syncstorageTag` | `latest` | its tag | `SYNCSTORAGE_IMAGE_TAG` |
| `SYNC_INIT_IMAGE` | – (follows `database.backend`) | `syncstorage-rs-mysql-init` | the init container's image: `syncstorage-rs-mysql-init` or `syncstorage-rs-postgres-init` | `SYNCSTORAGE_INIT_IMAGE` |
| `SYNC_INIT_IMAGE_TAG` | `image.initTag` | `latest` | its tag | `SYNCSTORAGE_INIT_IMAGE_TAG` |
| `ADMIN_IMAGE` | `image.adminTag` (the tag only) | unset: `<IMAGE_REPOSITORY>:admin-latest` | the admin UI's whole image name, also that of `fxa-policy` (compose and the Quadlets) | |
| – | `image.pullPolicy` | `IfNotPresent` | with `IfNotPresent` a node that has `latest` does not pull a newer one: [Helm](../upgrading.md#helm) | |

The accounts' images are under [Accounts](#accounts), the database images under [Databases](#databases).

## Databases

The stack's own database containers. For a server you run yourself, see also [Your own database server](#your-own-database-server). The users and their grants: [Database users](database-users.md).

| `.env` | Helm | Default | Meaning | Old name |
|---|---|---|---|---|
| `SYNC_DB` | `database.backend` | `mariadb` | the Sync database containers: `mariadb` or `mysql` ([MySQL instead of MariaDB](../databases.md#mysql-instead-of-mariadb)). PostgreSQL: `compose/sync-postgres.yml` in `COMPOSE_FILE` (Helm: `postgres`) | |
| `SYNC_MARIADB_IMAGE` | `database.image.mariadb` | unset: `mariadb:lts` (Helm `docker.io/library/mariadb:lts`) | with `SYNC_DB=mariadb`, the MariaDB image of the Sync databases and of their backups. Pins: [Database majors](../upgrading.md#database-majors) | |
| `SYNC_MYSQL_IMAGE` | `database.image.mysql` | unset: `mysql:lts` (Helm `docker.io/library/mysql:lts`) | with `SYNC_DB=mysql`, the MySQL image of the Sync databases and of their backups. Pins: [Database majors](../upgrading.md#database-majors) | |
| `SYNC_POSTGRES_IMAGE` | `database.image.postgres` | unset: `postgres:latest`; `prepare_environment.sh` writes the major it finds | the PostgreSQL image of the Sync database and of its backups, compose's and the Quadlets'. Pin the major: [PostgreSQL](../upgrading.md#postgresql) | |
| `SYNC_TOKENSERVER_DB_PASSWORD` | Secret: `TOKENSERVER_DB_PASSWORD` | generated | the tokenserver user's password (MariaDB, MySQL) | `MARIADB_TOKENSERVER_PASSWORD` |
| `SYNC_STORAGE_DB_PASSWORD` | Secret: `STORAGE_DB_PASSWORD` | generated | the storage user's password (MariaDB, MySQL) | `MARIADB_SYNCSTORAGE_PASSWORD` |
| `SYNC_POSTGRES_PASSWORD` | Secret: `POSTGRES_PASSWORD` | generated | the password of `SYNC_POSTGRES_USER`: the container's superuser; on your own server, the owner of the database | `POSTGRES_PASSWORD` |
| `SYNC_POSTGRES_APP_USER` | `database.postgresSyncUser` | empty (`prepare_environment.sh`: `syncserver_app`; Helm `syncserver_app`) | the Sync server's own role in the PostgreSQL container, no superuser. Empty (an install from before, or your own server): the Sync server connects as `SYNC_POSTGRES_USER` | |
| `SYNC_POSTGRES_APP_PASSWORD` | Secret: `POSTGRES_SYNC_PASSWORD` | generated | its password | |
| `ADMIN_DB_NAME` | `database.admin.name` | `ffs_admin` | the admin UI's own database, on the tokenserver's server | |
| `ADMIN_DB_USER` | `database.admin.user` | `ffs_admin_ui` | the admin UI's user of that database, and only of it | |
| `ADMIN_DB_SYNC_USER` | `database.admin.syncUser` | `ffs_admin_sync` | the admin UI's reader of the Sync data, with nothing on `ffs_admin` | |
| `ADMIN_DB_PASSWORD` | Secret: `ADMIN_DB_PASSWORD` | generated | the password of both admin UI users. Empty: an install from before it, see [The admin UI's own database](../upgrading.md#the-admin-uis-own-database) | |
| – | `database.persistence.size`, `.storageClass` | `8Gi`, the cluster's default | the volumes of the database servers. Set them before the first install: [Volumes](../install/helm.md#volumes) | |
| – | `database.resources` | none | requests and limits of each database server: [Resources](../install/helm.md#resources) | |

## Your own database server

How to set it up: [Your own database server](../databases.md#your-own-server). The accounts' database settings are under [Accounts](#accounts).

| `.env` | Helm | Default | Meaning | Old name |
|---|---|---|---|---|
| `SYNC_DB_CONTAINERS` | `database.bundled` | `1` (Helm `true`) | `0` (Helm `false`): no Sync database containers, use your own server | |
| `SYNC_DB_TLS_VERIFY` | `database.external.tlsVerify` | `true` (Helm `false`) | whether the init container's client (and the chart's backups) checks the server's certificate. `false` for your own MySQL, whose certificate is self-signed. The Sync server itself connects without TLS | |
| `SYNC_DB_BOOTSTRAP_USER` | `database.external.bootstrap.user` | empty | an account that can create users, as which the stack applies the [setup migrations](../databases.md#setup-migrations) your server lacks itself at every start; empty: it only checks them. See [Let the stack apply them](../databases.md#let-the-stack-apply-them) | |
| `SYNC_DB_BOOTSTRAP_PASSWORD` | Secret: `SYNC_DB_BOOTSTRAP_PASSWORD` | empty | its password | |
| `SYNC_TOKENSERVER_DB_HOST` | `database.external.host` | `tokenserver_db` | the tokenserver's server: a host name or IPv4 address the containers reach (Helm: required) | `MARIADB_TOKENSERVER_SERVER` |
| `SYNC_TOKENSERVER_DB_PORT` | `database.external.port` | `3306` (Helm empty: `3306`, or `5432` for `postgres`) | its port | `MARIADB_TOKENSERVER_SERVER_PORT` |
| `SYNC_TOKENSERVER_DB_NAME` | `database.external.tokenserverDatabase` | `tokenserver` | the tokenserver database | `MARIADB_TOKENSERVER_DATABASE` |
| `SYNC_TOKENSERVER_DB_USER` | `database.external.tokenserverUser` | `tokenserver` | its user | `MARIADB_TOKENSERVER_USER` |
| `SYNC_STORAGE_DB_HOST` | `database.external.storageHost` | `syncstorage_db` (Helm empty: `host`) | the storage database's server | `MARIADB_SYNCSTORAGE_SERVER` |
| `SYNC_STORAGE_DB_PORT` | `database.external.storagePort` | `3306` (Helm empty: `port`) | its port | `MARIADB_SYNCSTORAGE_SERVER_PORT` |
| `SYNC_STORAGE_DB_NAME` | `database.external.storageDatabase` | `syncstorage` | the storage database | `MARIADB_SYNCSTORAGE_DATABASE` |
| `SYNC_STORAGE_DB_USER` | `database.external.storageUser` | `syncstorage` | its user | `MARIADB_SYNCSTORAGE_USER` |
| `SYNC_POSTGRES_HOST` | `database.external.host` | `postgres_db` | the PostgreSQL server. With the database container the Quadlets reach it as `firefox-sync-postgres-db`, whatever this says | `POSTGRES_SERVER` |
| `SYNC_POSTGRES_PORT` | `database.external.port` | `5432` | its port | `POSTGRES_SERVER_PORT` |
| `SYNC_POSTGRES_NAME` | `database.external.postgresDatabase` | `syncserver` | the one Sync database | `POSTGRES_DATABASE` |
| `SYNC_POSTGRES_USER` | `database.external.postgresUser` | `syncserver` | in the stack's container its superuser; on your own server the owner of that database, no superuser | `POSTGRES_USER` |

The passwords are under [Databases](#databases). With your own server and the Helm chart, `existingSecret` is required: see [existingSecret](../install/helm.md#existingsecret).

## Backups

How they work: [Backups](../backups.md).

| `.env` | Helm | Default | Meaning | Old name |
|---|---|---|---|---|
| `COMPOSE_PROFILES` with `backup` (Quadlets: `firefox-sync-backup.timer`) | `backup.enabled` | off | the nightly backups | |
| `BACKUP_TIME` | `backup.schedule` (cron, UTC) | `03:00` (Helm `"0 3 * * *"`) | when they run, UTC | |
| `BACKUP_KEEP` | `backup.keep` | `7` | the newest runs kept; older ones are deleted | |
| – | `backup.activeDeadlineSeconds` | `82800` | a run still going after this many seconds is stopped and fails | |
| – | `backup.persistence.size`, `.storageClass` | `10Gi`, the cluster's default | the backups' PVC; it grows with a StorageClass of `allowVolumeExpansion`: [Volumes](../install/helm.md#volumes) | |
| – | `backup.resources` | none | the backup container and the Job that binds its PVC | |

## Admin UI

What it does: [Admin UI](../admin/README.md).

| `.env` | Helm | Default | Meaning | Old name |
|---|---|---|---|---|
| `COMPOSE_PROFILES` with `admin` | `admin.enabled` | off | the admin UI | |
| `ADMIN_PASSWORD` | `admin.password` (Secret: `ADMIN_PASSWORD`) | generated (Helm empty: generated) | the sign-in password. Empty in the Secret: no password sign-in | |
| `ADMIN_EXPORT_PORT` | – (`kubectl port-forward`, or `admin.ingress.*`) | `127.0.0.1:8090` | where the host publishes the admin UI | |
| `ADMIN_TZ` | `admin.tz` | empty: UTC | the time zone of the pages and the alerts, for example `Europe/Rome` | |
| `ADMIN_METRICS_TOKEN` | `admin.metricsToken` (Secret: `ADMIN_METRICS_TOKEN`) | empty: off | the bearer token of the Prometheus metrics at `/metrics`: [Prometheus](../admin/monitoring.md#prometheus) | |
| `ADMIN_UPDATE_CHECK` | `admin.updateCheck` | `true` | compare the running versions with the newest releases on GitHub | |
| `ADMIN_PUBLIC_CHECK` | `admin.publicCheck` | `true` | every hour, check the public `https://` URLs, their certificates and the sign-up gate: [Public checks](../admin/monitoring.md#public-checks) | |
| – | `admin.podStatus` | `false` | the admin UI reads the pods of the release (a Role to get and list pods in its namespace) to tell a part starting from a crashed one right after a start; off: a time-bounded wait, see [Startup grace](../admin/monitoring.md#startup-grace). Docker and Podman: never (their socket would give the admin UI the host) | |
| `ADMIN_STALE_DAYS` | `admin.staleDays` | `90` | accounts not synced for this many days are marked inactive | |
| `ADMIN_RETENTION_DAYS` | `admin.retentionDays` | `30` | days of metrics and events kept: [Maintenance and retention](../admin/storage.md#maintenance-and-retention) | |
| `ADMIN_AUDIT_RETENTION_DAYS` | `admin.auditRetentionDays` | `365` | days the events of the admins (who did what) and the backup runs are kept | |
| `ADMIN_PURGE` | `admin.purge` | empty: only with "Purge now" | `1`: every day, delete the Sync data nobody reads any more: [Storage](../admin/storage.md) | |
| `ADMIN_DELETE_UNCONFIRMED_DAYS` | `admin.deleteUnconfirmedDays` | empty: never | self-hosted accounts: every day, delete the accounts that never confirmed their email after this many days (at least 1) | |
| `ADMIN_UNCONFIRMED_HOURS` | `admin.unconfirmedHours` | empty: `72` | self-hosted accounts: an account that has not confirmed its email this many hours after its sign-up is marked unconfirmed in the accounts list | |
| `ADMIN_SIGNUP_BURST` | `admin.signupBurst` | `10` | self-hosted accounts: an alert when more accounts than this are created in an hour (`0`: never) | |
| `ADMIN_ERROR_RATE_PERCENT` | `admin.errorRatePercent` | `10` | an alert on a spike of Sync errors: this share (%) of the requests in 15 minutes, and 3 times the share of the day before (`0`: never) | |
| `ADMIN_ERROR_RATE_MIN_ERRORS` | `admin.errorRateMinErrors` | `20` | the fewest errors for that alert | |
| `ADMIN_DB_GROWTH_MB` | `admin.dbGrowthMb` | `1024` | an alert when a database grows more than this many MB in a day (`0`: never) | |
| `ADMIN_DB_GROWTH_FACTOR` | `admin.dbGrowthFactor` | `5` | an alert when a database grows more than this many times its usual daily growth, from 100 MB and 3 days of history (`0`: never): [Errors and growth](../admin/monitoring.md#errors-and-growth) | |
| `ADMIN_GATE_EXPORT_PORT` | – (the Service `<release>-firefox-sync-admin`, port 8081) | `127.0.0.1:8091` | self-hosted accounts: where the host publishes the sign-up gate, for `POST /v1/account/create` of `FXA_AUTH_URL`: [Reverse proxy](../reverse-proxy.md#host-names-and-ports) | |
| – | `admin.resources` | none | the admin UI's container and its init container | |
| – | `admin.ingress.enabled`, `.className`, `.host`, `.tls.enabled`, `.tls.secretName`, `.annotations` | off | the admin UI's own Ingress, never on the Sync server's host: [Admin UI](../install/helm.md#admin-ui) | |

## Admin UI sign-in

How each way works: [Signing in](../admin/signing-in.md).

| `.env` | Helm | Default | Meaning | Old name |
|---|---|---|---|---|
| `ADMIN_OIDC_ISSUER` | `admin.oidc.issuer` | empty: off | the OpenID Connect issuer URL. With `ADMIN_FXA_CLIENT_ID` it defaults to `FXA_CONTENT_URL` | |
| `ADMIN_OIDC_CLIENT_ID` | `admin.oidc.clientId` | empty | the client id | |
| `ADMIN_OIDC_CLIENT_SECRET` | `admin.oidc.clientSecret` (Secret: `ADMIN_OIDC_CLIENT_SECRET`) | empty: a public client (PKCE only) | the client secret | |
| `ADMIN_OIDC_REDIRECT_URL` | `admin.oidc.redirectUrl` | empty | the exact public callback URL, `https://<admin host>/auth/callback` | |
| `ADMIN_OIDC_SCOPES` | `admin.oidc.scopes` | empty: `openid email profile` | the scopes asked for | |
| `ADMIN_OIDC_NAME` | `admin.oidc.name` | empty: `single sign-on` | the label of the sign-in button | |
| `ADMIN_OIDC_GROUPS_CLAIM` | `admin.oidc.groupsClaim` | empty: `groups` | the claim with the groups, for `ADMIN_ALLOWED_GROUPS` | |
| `ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL` | `admin.oidc.trustUnverifiedEmail` | empty: refused | `true`: accept emails without `email_verified=true`. Risky; needed with the self-hosted accounts | |
| `ADMIN_AUTH_HEADER` | `admin.trustedHeader.header` | empty: off | the header with the email, set by a forward-auth proxy: [Trusted header](../admin/signing-in.md#trusted-header) | |
| `ADMIN_AUTH_GROUPS_HEADER` | `admin.trustedHeader.groupsHeader` | empty: none | the header with the comma-separated groups | |
| `ADMIN_TRUSTED_PROXIES` | `admin.trustedHeader.trustedProxies` | empty | the CIDRs of the proxy as the admin UI sees it. Required with the header: from other addresses it is ignored | |
| `ADMIN_ALLOWED_USERS` | `admin.allowed.users` | empty: nobody by email | with OpenID Connect or the header, who is an admin: emails and `@domains`, comma-separated | |
| `ADMIN_ALLOWED_GROUPS` | `admin.allowed.groups` | empty: none | the same, by group | |
| `ADMIN_INSECURE_COOKIE` | `admin.insecureCookie` | empty: `Secure` only | `1`, `true` or `yes` (empty, `0`, `false` or `no`: off; anything else stops the admin UI): the session cookie also goes over plain HTTP other than `http://localhost`, where anybody on the way can take it. Needed for an `http://` `ADMIN_OIDC_REDIRECT_URL`; the Configuration page lists it as a setting that disagrees | |
| `ADMIN_FXA_CLIENT_ID` | `fxa.adminClientId`, with `admin.fxaSignIn` | empty (Helm: derived from the namespace and the release, [Sign in with the accounts](../install/helm.md#sign-in-with-the-accounts)) | sign in with the self-hosted accounts: an OAuth client id (16 hex characters), registered at every start with `ADMIN_OIDC_REDIRECT_URL`: [Self-hosted accounts](../admin/signing-in.md#self-hosted-accounts) | |
| `ADMIN_FXA_CLIENT_SECRET` | `fxa.adminClientSecret` (Secret: `ADMIN_FXA_CLIENT_SECRET`) | empty | keep it empty: the accounts service refuses PKCE from clients with a secret, and the admin UI always uses PKCE | |

## Notifications

The alerts and the emails of the admin UI: [Alerts](../admin/alerts.md). The same SMTP server sends the self-hosted accounts' emails, so in the chart it is the top-level `smtp.*`, not under `admin`.

| `.env` | Helm | Default | Meaning | Old name |
|---|---|---|---|---|
| `ADMIN_ALERT_EMAIL` | `admin.alertEmail` | empty: nobody | where the alerts go by email | |
| `ADMIN_NOTIFY` | `admin.notify` (a list; Secret: `ADMIN_NOTIFY`) | empty: nowhere | the other destinations of the alerts, their URLs comma-separated, in single quotes: [Destinations](../admin/alerts.md#destinations). The URLs hold tokens: keep `.env` private | |
| `FXA_SMTP_HOST` | `smtp.host` | a placeholder (Helm empty: no emails) | the SMTP server | |
| `FXA_SMTP_PORT` | `smtp.port` | `587` | its port | |
| `FXA_SMTP_USER` | `smtp.user` | empty: none | its user | |
| `FXA_SMTP_PASS` | `smtp.password` (Secret: `FXA_SMTP_PASS`) | empty | its password | |
| `FXA_SMTP_SECURE` | `smtp.secure` | `false` | `true`: TLS from the start (port 465); `false`: STARTTLS | |
| `FXA_SMTP_SENDER` | `smtp.sender` | `"Mozilla accounts <no-reply@<your domain>>"` | the From of the emails. Empty, the admin UI uses `ADMIN_ALERT_EMAIL` | |
| `ADMIN_SMTP_INSECURE_AUTH` | `smtp.insecureAuth` | empty: refused | `1`, `true` or `yes` (as `ADMIN_INSECURE_COOKIE`): the admin UI sends `FXA_SMTP_PASS` also to an SMTP server that offers no TLS, in clear (a relay on the host or a network you trust only) | |

`admin.password`, `smtp.password`, `admin.oidc.clientSecret`, `admin.metricsToken` and `admin.notify` end up in a Secret: how, with and without `existingSecret`, is in [The Secret](../install/helm.md#the-secret).

## Accounts

The self-hosted Mozilla accounts, with `compose/fxa.yml` in `COMPOSE_FILE`: [Self-hosted accounts](../accounts.md). With the Helm chart, `fxa.enabled: true`: [Self-hosted accounts](../install/helm.md#self-hosted-accounts). The chart's values with no `.env` counterpart are in [Helm only](#helm-only).

| `.env` | Helm | Default | Meaning | Old name |
|---|---|---|---|---|
| `FXA_IMAGE` | `fxa.image.repository` (empty: `image.repository`) | `ghcr.io/porelli/firefox-sync` | the accounts' image. Mozilla's own: `docker.io/mozilla/fxa-mono` (amd64 only) | |
| `FXA_VERSION` | `fxa.image.tag` | `fxa-mono-latest` | its tag: the newest tested release, or a pinned one such as `fxa-mono-v1.349.0`. [Upgrading](../upgrading.md#self-hosted-accounts) | |
| `FXA_ARCH` | – (the node's) | `amd64` | `amd64` or `arm64`, set by `prepare_environment.sh` (`amd64` with Mozilla's images) | |
| `FXA_CONTENT_URL` | `fxa.contentUrl` | required | the public URL of the accounts pages, for example `https://accounts.example.com` | |
| `FXA_AUTH_URL` | `fxa.authUrl` | required | the public URL of the accounts API | |
| `FXA_PROFILE_URL` | `fxa.profileUrl` | required | the public URL of the profile server | |
| `FXA_DB` | `fxa.database.backend` | `mysql` | the accounts database: `mysql` or `mariadb` ([MySQL or MariaDB](../accounts.md#mysql-or-mariadb)). With compose, `mariadb` also needs `compose/fxa-mariadb.yml` in `COMPOSE_FILE`, not `compose/fxa-mysql.yml` | |
| `FXA_MYSQL_IMAGE` | `fxa.database.image.mysql` | unset: `mysql:lts` (Helm `docker.io/library/mysql:lts`) | with `FXA_DB=mysql`, the image of `fxa-db` and of its backups. Pins: [Database majors](../upgrading.md#database-majors) | |
| `FXA_MYSQL_ARGS` | – (from `fxa.database.image.mysql`: the native password options on a MySQL 8 pin, [Database majors](../upgrading.md#database-majors)) | empty | extra options of `fxa-db`'s `mysqld`. On `mysql:8` for accounts images without mozilla/fxa#21709: `--mysql-native-password=ON --authentication-policy=mysql_native_password` | |
| `FXA_MARIADB_IMAGE` | `fxa.database.image.mariadb` | unset: `mariadb:lts` (Helm `docker.io/library/mariadb:lts`) | with `FXA_DB=mariadb`, the image of `fxa-db` and of its backups | |
| `FXA_DB_CONTAINERS` | `fxa.database.bundled` (`0`: `false`) | `1` (Helm `true`) | `0`: no `fxa-db` container, use your own MySQL or MariaDB server | |
| `FXA_MYSQL_HOST` | `fxa.database.external.host` | `fxa-db` (Helm: `<release>-firefox-sync-fxa-db` while bundled) | the accounts' database server | |
| `FXA_MYSQL_PORT` | `fxa.database.external.port` | `3306` (Helm empty: `3306`) | its port | |
| `FXA_MYSQL_USER` | `fxa.database.external.user` | `root` (Helm: `root` while bundled, else `fxa`) | the accounts services' user (on your own server, for example `fxa`) | |
| `FXA_MYSQL_PASSWORD` | Secret: `FXA_MYSQL_PASSWORD` | generated | its password | |
| `FXA_MYSQL_POLICY_USER` | `fxa.database.external.policyUser` | empty: `FXA_MYSQL_USER` (Helm `ffs_policy`) | the user that installs the sign-up policy and grants the admin UI's user | |
| `FXA_MYSQL_POLICY_PASSWORD` | Secret: `FXA_MYSQL_POLICY_PASSWORD` | empty (Helm: never generated) | its password (not used while `FXA_MYSQL_POLICY_USER` is empty) | |
| `FXA_DB_BOOTSTRAP_USER` | `fxa.database.external.bootstrap.user` | empty | as `SYNC_DB_BOOTSTRAP_USER`, for `database-setup-fxa.sql` on your own accounts server | |
| `FXA_DB_BOOTSTRAP_PASSWORD` | Secret: `FXA_DB_BOOTSTRAP_PASSWORD` | empty | its password | |
| `FXA_ADMIN_DB_PASSWORD` | Secret: `FXA_ADMIN_DB_PASSWORD` | generated | the password of the admin UI's user `ffs_admin` of the accounts database (a user, not the database `ADMIN_DB_NAME`) | |
| `FXA_AUTH_SECRET`, `FXA_OAUTH_SECRET`, `FXA_PROFILE_SECRET`, `FXA_FLOW_ID_KEY`, `FXA_SESSION_TOKEN_HANDLE_KEY`, `FXA_CONTENT_SESSION_SECRET` | Secret: the same names | generated | the accounts services' secrets | |
| `FXA_SIGNUPS` | `fxa.signups` | `open` | who can create an account: `open`, `allowlist` or `closed`: [Who can sign up](../accounts.md#who-can-sign-up) | |
| `FXA_SIGNUP_ALLOWLIST` | `fxa.signupAllowlist` (a list, or one string) | empty | with `allowlist`, the emails and `@domains` allowed, comma-separated | |
| `FXA_MAX_ACCOUNTS` | `fxa.maxAccounts` | `initial:unlimited` | the most accounts that can be created: [Limits](../limits.md#fxa_max_accounts) | |
| `FXA_CLIENT_ADDRESS_DEPTH` | `fxa.clientAddressDepth` | `2` | the reverse proxies in front of the accounts API, plus 1: where the rate limits find the client IP address ([Client IP address](../reverse-proxy.md#client-ip-address)) | |
| `FXA_ACCESS_TOKEN_LIFETIME` | `fxa.accessTokenLifetime` | `"60 minutes"` | the lifetime of Firefox's access tokens (Mozilla's default: `"365 minutes"`) | |
| `FXA_ACCOUNT_EVENTS` | `fxa.accountEvents` | `false` | `true`: record the security history of every account, with IP addresses: [Security history](../accounts.md#security-history) | |
| `SYNC_DELETE_DATA` | `syncstorage.deleteData` | `false` | `true`: the admin UI resets Sync data through the Sync server's data deletion endpoint (syncstorage-rs 0.25.0 on), with self-hosted accounts and the admin UI only: [Sync data through the Sync server](../admin/accounts.md#sync-data-through-the-sync-server) | |
| `SYNC_DELETE_DATA_KEY` | Secret: `SYNC_DELETE_DATA_KEY` | generated when `SYNC_DELETE_DATA` is `true` (`--upgrade` too; Helm: once, kept) | the RSA private key the admin UI signs the deletions with, the base64 of its PEM; the Sync server is given its public half | |
| `FXA_PAIRING_URL` | `fxa.pairing.url` | unset: Mozilla's channel server | your own pairing server for the QR code, for example `wss://pairing.example.com`, with `pairing` in `COMPOSE_PROFILES` (Helm: `fxa.pairing.enabled`) | |
| `FXA_PAIRING_REPOSITORY` | `fxa.pairing.repository` | unset: `FXA_IMAGE` (Helm empty: the accounts' repository) | the pairing server's image repository: it follows the accounts' image, a mirror too | |
| `FXA_PAIRING_VERSION` | `fxa.pairing.tag` | `fxa-channelserver-latest` | its tag, or a pinned one such as `fxa-channelserver-<release>` | |
| `FXA_PAIRING_IMAGE` | `fxa.pairing.image` | unset: `<FXA_PAIRING_REPOSITORY>:<FXA_PAIRING_VERSION>` | a full image reference that wins over both, for example Mozilla's own `docker.io/mozilla/channelserver:<tag>` (amd64 only), which Mozilla's accounts image (`FXA_IMAGE=docker.io/mozilla/fxa-mono`) needs: it has no pairing server. | |
| `FXA_PAIRING_TRUSTED_PROXIES` | `fxa.pairing.trustedProxies` | unset: `127.0.0.1,172.16.0.0/12,10.0.0.0/8,192.168.0.0/16` | the proxies the pairing server trusts for the client address (not with the Quadlets: they have no pairing server) | |
| `FXA_LOG_LEVEL` | `fxa.logLevel` | unset: `INFO` | the log level of the auth server: `ERROR`, `WARN`, `INFO`, `DEBUG` or `TRACE` | |
| `FXA_CONTENT_EXPORT_PORT` | – (the Service `<release>-firefox-sync-fxa-content`, port 3030) | `127.0.0.1:3030` | where the host publishes the accounts pages | |
| `FXA_AUTH_EXPORT_PORT` | – (`-fxa-auth`, 9000) | `127.0.0.1:9000` | the accounts API, for your reverse proxy only: a port of the host, never in `FXA_OAUTH_SERVER_URL` | |
| `FXA_PROFILE_EXPORT_PORT` | – (`-fxa-profile`, 1111) | `127.0.0.1:1111` | the profile server | |
| `FXA_PROFILE_STATIC_EXPORT_PORT` | – (`-fxa-profile`, 1112) | `127.0.0.1:1112` | the profile server's static files (avatars) | |
| `FXA_PAIRING_EXPORT_PORT` | – (`-fxa-pairing`, 8000) | `127.0.0.1:8058` | the pairing server | |

Which host name goes to which port: [Host names and ports](../reverse-proxy.md#host-names-and-ports). These are ports of the host: the setup (and `--upgrade`) takes the next free one where something else listens ([Ports in use](../reverse-proxy.md#ports-in-use)); inside the stack the containers keep their own ports.

## Reverse proxy

What `prepare_environment.sh` writes into `proxy/` from `.env`, the configuration of the reverse proxy, takes these too ([Reverse proxy](../reverse-proxy.md)): after a change, `./prepare_environment.sh --render-proxy`. The Helm chart has its Ingresses instead ([Kubernetes](../reverse-proxy.md#kubernetes)).

| `.env` | Helm | Default | Meaning | Old name |
|---|---|---|---|---|
| `PROXY` | – | `own` | which reverse proxy: `own` (yours, with the file of `proxy/`), `caddy` ([the bundled Caddy](../reverse-proxy.md#the-bundled-caddy): `compose/caddy.yml` in `COMPOSE_FILE`, or its Quadlet) or `traefik` ([labels for your Traefik](../reverse-proxy.md#traefik-labels): `proxy/traefik-compose.yml` in `COMPOSE_FILE`). `--upgrade` puts the file of `PROXY` in `COMPOSE_FILE`, and takes out the other's | |
| `PROXY_ADMIN_ALLOW` | – | `127.0.0.1,::1` | who reaches the admin UI's public address (`ADMIN_OIDC_REDIRECT_URL`) through the proxy: addresses and CIDRs, comma-separated; empty: anybody. Not the containers' networks behind published ports ([The admin UI](../reverse-proxy.md#the-admin-ui)) | |
| `PROXY_CERTS` | – | `per-host` | your own proxy's certificates in `proxy/nginx.conf`, `Caddyfile`, `traefik.yml`: `per-host` (certbot's, `/etc/letsencrypt/live/<host>/`; Caddy gets its own) or `one`, one certificate for every host name, such as a wildcard ([Certificates](../reverse-proxy.md#certificates)) | |
| `PROXY_CERT_FILE`, `PROXY_CERT_KEY_FILE` | – | empty | `PROXY_CERTS=one`: the certificate (with its chain) and its key, as your proxy reads them: nginx's `ssl_certificate`, Caddy's `tls`, Traefik's `tls.certificates` | |
| `PROXY_NGINX_SSL_INCLUDE` | – | empty: the two files | `PROXY_CERTS=one`: an nginx file of yours with the `ssl_*` lines, which each server block includes instead | |
| `PROXY_CERT_NAMES` | – | empty | `PROXY_CERTS=one`: the names the certificate is for, comma-separated (`*.example.com,example.com`): the setup, `--upgrade` and `--render-proxy` warn of a host name it does not cover (a wildcard covers one label only) | |
| `CADDY_IMAGE` | – | `caddy:latest` | `PROXY=caddy`: its image | |
| `CADDY_HTTP_PORT`, `CADDY_HTTPS_PORT` | – | `80`, `443` | `PROXY=caddy`: the ports of this host it listens on, on the host's network ([Rootless Podman and ports under 1024](../reverse-proxy.md#rootless-podman-and-ports-under-1024)) | |
| `CADDY_ACME_CA` | – | `letsencrypt` | `PROXY=caddy`: where its certificates come from, `letsencrypt`, `staging` (Let's Encrypt's test CA) or `internal` (Caddy's own CA) | |
| `CADDY_ACME_EMAIL` | – | empty: none | `PROXY=caddy`: the email Let's Encrypt writes to about the certificates | |
| `TRAEFIK_NETWORK` | – | empty: `<COMPOSE_PROJECT_NAME>-proxy` | with `PROXY=traefik` the network the public containers join, for Traefik alone ([Traefik labels](../reverse-proxy.md#traefik-labels)) | |
| `TRAEFIK_ENTRYPOINTS` | – | `websecure` | the routers' HTTPS entry points, comma-separated (also of `proxy/traefik.yml`) | |
| `TRAEFIK_HTTP_ENTRYPOINT` | – | `web` | the HTTP entry point redirected to HTTPS; empty: no redirect | |
| `TRAEFIK_CERTRESOLVER` | – | empty: Traefik's default certificate | the certificate resolver of the routers | |

## Generated passwords and secrets

`prepare_environment.sh` generates every password and secret of the choices you made (letters and digits), writes them to `.env` (this user's only), names them in its review, and lists them at its end with what each is for. Those you typed (the SMTP password, a client secret, a bootstrap password you gave) are not listed. On a terminal it shows the admin UI's password once; in a log it says where it is. Each can be changed later:

| Setting | What for | To change it |
|---|---|---|
| `ADMIN_PASSWORD` | the admin UI's sign-in password, the one you use yourself; empty when you chose single sign-on only ("Keep a password as a fallback?": no) | `.env`, then `docker compose up -d` (Quadlets: `./prepare_environment.sh --render-units`, then restart the units it names). Keep it in your password manager |
| `SYNC_MASTER_SECRET` | signs the Sync tokens | `.env`, then restart. A new one signs every Firefox out of Sync until it signs in again; their data stays |
| `SYNC_METRICS_HASH_SECRET` | the key of the hashed account ids in the metrics | `.env`, then restart. The hashes start over |
| `ADMIN_DB_PASSWORD`, `SYNC_POSTGRES_APP_PASSWORD`, `FXA_ADMIN_DB_PASSWORD` | database users the stack sets again at every start | `.env`, then restart (your own server: [Change a database password](../databases.md#change-a-database-password)) |
| `SYNC_TOKENSERVER_DB_PASSWORD`, `SYNC_STORAGE_DB_PASSWORD`, `SYNC_POSTGRES_PASSWORD`, `FXA_MYSQL_PASSWORD`, `FXA_MYSQL_POLICY_PASSWORD`, `SYNC_DB_BOOTSTRAP_PASSWORD`, `FXA_DB_BOOTSTRAP_PASSWORD` | database users whose password the database has too | in the database first, then `.env`: [Change a database password](../databases.md#change-a-database-password) |
| `FXA_AUTH_SECRET`, `FXA_OAUTH_SECRET`, `FXA_PROFILE_SECRET`, `FXA_FLOW_ID_KEY`, `FXA_SESSION_TOKEN_HANDLE_KEY`, `FXA_CONTENT_SESSION_SECRET` | the self-hosted accounts services' own keys | `.env`, then restart; only if one leaked: the accounts' sessions and tokens signed with it stop working, and people sign in again |

`FXA_OAUTH_SECRET` also gives the key of the accounts' tokens for the password, email and 2-step changes (`mfa.jwt.secretKey`, an HMAC-SHA256 of it, [config/fxa/oauth-clients.js](/config/fxa/oauth-clients.js)): a new one ends those that are open, the person confirms with a code again. `MFA__JWT__KEY` in the environment of `fxa-auth` overrides it.

`ADMIN_FXA_CLIENT_ID`, also generated, is no secret: the id of the admin UI's sign-in client of the self-hosted accounts.

## Helm only

Values of the chart with no `.env` counterpart, besides those in the tables above. Each is described in [values.yaml](/charts/firefox-sync/values.yaml).

| Helm | Default | Meaning |
|---|---|---|
| `nameOverride`, `fullnameOverride` | empty | the names of the chart's objects: [Limits](../install/helm.md#limits) |
| `existingSecret` | empty: the chart generates `<release>-firefox-sync` | a Secret of your own: [existingSecret](../install/helm.md#existingsecret) |
| `database.allowMajorUpgrade` | `false` | `true` lets one `helm upgrade` move the bundled MariaDB or MySQL to another major (never PostgreSQL); set it back to `false` after: [Database majors](../upgrading.md#database-majors) |
| `fxa.database.allowMajorUpgrade` | `false` | the same for the bundled accounts database (`fxa.enabled`) |
| `fxa.enabled` | `false` | the self-hosted accounts: [Self-hosted accounts](../install/helm.md#self-hosted-accounts) |
| `fxa.database.external.*` | | your own accounts database server, with `fxa.database.bundled: false`: in the [Accounts](#accounts) table |
| `fxa.database.persistence.size`, `.storageClass` | `8Gi`, the default class | the bundled accounts database's volume, set before the first install: [Volumes](../install/helm.md#volumes) |
| `fxa.database.resources`, `fxa.redis.resources`, `fxa.resources.*`, `fxa.pairing.resources` | memory requests (pairing: none) | the accounts' containers: [Resources and PodSecurity](../install/helm.md#resources-and-podsecurity) |
| `fxa.redis.image` | `docker.io/library/redis:alpine` | the accounts' Redis: [Database majors](../upgrading.md#database-majors) |
| `fxa.keys.existingSecret` | empty: the PVC `<release>-firefox-sync-fxa-keys` | a Secret with the accounts' signing keys: [The signing keys](../install/helm.md#the-signing-keys) |
| `fxa.keys.persistence.size`, `.storageClass` | `1Gi`, the default class | the keys' PVC; it grows with a StorageClass of `allowVolumeExpansion`: [Volumes](../install/helm.md#volumes) |
| `fxa.profileImages.persistence.size`, `.storageClass` | `1Gi`, the default class | the avatars' PVC, `<release>-firefox-sync-fxa-profile-images`, as the keys' |
| `fxa.pairing.enabled` | `false` | the chart's own pairing server, at `fxa.pairing.url`: [Pairing](../install/helm.md#pairing) |
| `fxa.ingress.enabled`, `.className`, `.annotations`, `.tls.enabled`, `.tls.secretNames.content`, `.auth`, `.profile`, `.pairing` | off | the accounts' Ingresses, one per host: [Kubernetes](../reverse-proxy.md#kubernetes) |
| `fxa.extraCaCerts.configMap`, `.key` | empty, `ca.crt` | a ConfigMap with a CA the accounts and the admin UI trust, for your SMTP server or your own HTTPS hosts |
| `fxa.volumeOwnerInit` | `true` | `false`: no root init container, `fsGroup` instead: [Resources and PodSecurity](../install/helm.md#resources-and-podsecurity) |
| `fxa.networkPolicy.enabled` | `true` | NetworkPolicies for the accounts' Redis and database: [NetworkPolicies](../install/helm.md#networkpolicies) |
| `fxa.networkPolicy.servers.enabled`, `.ingressController.namespaceSelector`, `.podSelector`, `.extraFrom` | off | NetworkPolicies for the accounts' public servers too, from your Ingress controller: [NetworkPolicies](../install/helm.md#networkpolicies) |
| `admin.fxaSignIn` | `false` | sign in to the admin UI with the self-hosted accounts: [Sign in with the accounts](../install/helm.md#sign-in-with-the-accounts) |
| `syncstorage.replicas` | `1` | keep 1: the migrations and the max users init run in its init containers |
| `syncstorage.resources`, `syncstorage.initResources` | none | the Sync server and its init containers: [Resources](../install/helm.md#resources) |
| `syncstorage.service.port` | `8000` | the Sync server's Service port |
| `ingress.enabled`, `.className`, `.host`, `.tls.enabled`, `.tls.secretName`, `.annotations` | off; `host` empty: that of `syncDomain` | the Sync server's Ingress: [Ingress](../install/helm.md#ingress) |
| `imagePullSecrets` | none | pull secrets for every pod |
| `nodeSelector`, `tolerations`, `affinity` | none | where every pod of the chart runs |
| `podAnnotations` | none | annotations on every pod |

## Not in .env

The admin UI and the backup script also read these variables, from their container's environment only. Neither compose nor the Quadlets pass them from `.env`, and the chart does not set them: they are for the tests.

| Variable | Default | Meaning |
|---|---|---|
| `HEALTH_CHECK_SECONDS` | `60` | how often the admin UI checks the components |
| `METRICS_FLUSH_SECONDS` | `60` | how often it writes its metrics |
| `ALERT_INTERVAL_SECONDS` | `600` | the alerts are collected and sent at most this often |
| `FXA_INIT_TIMEOUT` | `120` | seconds the admin UI waits at its start for the accounts' tables, which the migrations create |
| `BACKUP_LOCK_WAIT` | `3600` | seconds a backup run waits for another one to finish |
| `BACKUP_RETRY_PAUSE` | `10` | seconds before a dump is tried again after a table changed or was dropped while it ran (error 1412 or 1146, PostgreSQL's "relation does not exist") |
