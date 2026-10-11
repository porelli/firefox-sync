# firefox-sync

The purpose of this repository is to provide a docker-compose that can be used to self host what otherwise Firefox sync would send to Mozilla's servers. A Mozilla account is required to use this self-hosted setup.

**🐳 Docker and 🦭 Podman supported** - See [PODMAN.md](PODMAN.md) for Podman-specific instructions, including rootless setup and Quadlet integration.

## Disclaimer

- ⚠️ The project is under development
- ⚠️ Expect bugs, breaking changes and headache
- ⚠️ **This is not endorsed or supported by Mozilla in any way or form**
- ⚠️ **Do not solely relay on this project to store your bookmarks, passwords and/or other important items**

## Security considerations

1. ~~- syncstorage-rs does NOT support account allowlisting. This means that ANY person that has network access to your server can use it.~~
    - **This has been implemented with a SQL trigger workaround that prevents the token database to insert more rows when a new user tries to use the server. This is tested and prevents a new account from using your server if the number of MAX_USERS defined in your .env file is already reached.**
    - Possible alternative (better) solutions:
        - implement the feature directly in syncstorage-rs
        - add the entire rest of the Mozilla stack so that authentication is performed and validated locally

## Background

Mozilla's server side components are open source and Firefox allows to easily change the official endpoints.
[Some documentation](https://mozilla-services.readthedocs.io/en/latest/index.html) is provided to install the each component on your own server but this is neither officially supported or very well maintained. Furthermore, there are no official Docker images that can be used to avoid installing everything manually; all the instructions and artifacts provided are focused on setting up a developer environment rather than a production self hosted service. For example, `syncstorage-rs` has a [docker release on docker-hub](https://hub.docker.com/r/mozilla/syncstorage-rs/) but it is targeted to work exclusively with Google Spanner which is what Mozilla uses to provide the service.

## Content and scope of this project
- GitHub workflows to create docker images as vanilla as possible from Mozilla's code
- Docker compose to setup required component to self host Mozilla sync components
- examples to configure other parts of the infrastructure
- instructions to setup your browser to use the self hosted infrastructure
- run [Mozilla accounts (fxa)](https://github.com/mozilla/fxa), is out of scope. You will need to use the Mozilla's servers to authenticate or setup your own ([example](https://github.com/jackyzy823/fxa-selfhosting))

### Docker images currently published
All the images are updated weekly to the latest tag available from Mozilla's official repositories
- [ghcr.io/porelli/firefox-sync:syncstorage-rs-mysql-latest](https://github.com/porelli/firefox-sync/pkgs/container/firefox-sync/versions)
    - GitHub [workflow](/.github/workflows/syncstorage-rs.yml) and [logs](https://github.com/porelli/firefox-sync/actions/workflows/syncstorage-rs.yml)
    - Base image: [Mozilla's](https://github.com/mozilla-services/syncstorage-rs/blob/master/Dockerfile) container
    - Base image differences: image built with `SYNCSTORAGE_DATABASE_BACKEND=mysql` and `TOKENSERVER_DATABASE_BACKEND=mysql` (`DATABASE_BACKEND=mysql` for releases before 0.23) to use the MySQL-compatible interface instead of Google Spanner
    - source code: https://github.com/mozilla-services/syncstorage-rs
        - code changes: none
- [ghcr.io/porelli/firefox-sync:syncstorage-rs-mysql-init-latest](https://github.com/porelli/firefox-sync/pkgs/container/firefox-sync/versions)
    - GitHub [workflow](/.github/workflows/syncstorage-rs.yml) and [logs](https://github.com/porelli/firefox-sync/actions/workflows/syncstorage-rs.yml)
    - Base image: [MariaDB's](https://github.com/MariaDB/mariadb-docker/blob/master/Dockerfile.template) container
    - Purpose: Post-migration database initialization and handling of MAX_USERS
    - Base image differences: [added](/syncstorage-rs-init/Dockerfile) [`db_init.sh`](/syncstorage-rs-init/db_init.sh) and [`db_init.sql`](/syncstorage-rs-init/db_init.sql) scripts
    - source code: https://github.com/MariaDB/server
        - code changes: none
- [ghcr.io/porelli/firefox-sync:syncstorage-rs-postgres-latest](https://github.com/porelli/firefox-sync/pkgs/container/firefox-sync/versions)
    - same as `syncstorage-rs-mysql` but built with `SYNCSTORAGE_DATABASE_BACKEND=postgres` and `TOKENSERVER_DATABASE_BACKEND=postgres` to use PostgreSQL
- [ghcr.io/porelli/firefox-sync:syncstorage-rs-postgres-init-latest](https://github.com/porelli/firefox-sync/pkgs/container/firefox-sync/versions)
    - Base image: [PostgreSQL's](https://github.com/docker-library/postgres) container
    - Purpose: Post-migration database initialization and handling of MAX_USERS
    - Base image differences: [added](/syncstorage-rs-init-postgres/Dockerfile) [`db_init.sh`](/syncstorage-rs-init-postgres/db_init.sh) and [`db_init.sql`](/syncstorage-rs-init-postgres/db_init.sql) scripts
    - source code: https://github.com/postgres/postgres
        - code changes: none

## Server setup

### Docker Compose

1. clone this repository
1. run `./prepare_environment.sh` to automatically prepare your `.env` file and conf examples according with your variables
    - you can choose between MariaDB (default, [docker-compose.yml](/docker-compose.yml)) and PostgreSQL ([docker-compose.postgres.yml](/docker-compose.postgres.yml)) as database backend. For PostgreSQL, the script sets `COMPOSE_FILE` in `.env` so that `docker compose` picks the right file automatically
    - you can pin the syncstorage image to a specific tag (default: `latest`)
1. setup your reverse proxy server
    1. if you use nginx, check the [syncstorage-rs.conf](/config/nginx/syncstorage-rs-example.conf) as example
1. start docker compose:
    ```bash
    docker compose up -d
    ```
    - with Podman, use the Quadlets below or `docker compose` with the Podman socket, see [PODMAN.md](PODMAN.md#method-2-using-docker-compose-with-the-podman-socket). `podman-compose` is not supported because it cannot run the one-shot migration and init containers before the service ([why](PODMAN.md#why-not-podman-compose))
1. OPTIONAL: Install the systemd service
    - **Docker**: See [firefox-sync.service](/config/systemd/syncstorage-rs-example.service)
    - **Podman**: See [PODMAN.md](PODMAN.md#method-1-using-quadlets) for Quadlet setup (recommended)
    - All containers are set to restart automatically

### Podman with Quadlets (Recommended for Podman)

For native systemd integration with Podman, see the comprehensive [Podman Guide](PODMAN.md#method-1-using-quadlets). Quadlets are currently provided for MariaDB only.

Quick start:
```bash
./prepare_environment.sh  # Choose option 1 (Quadlets, the default) when prompted
systemctl --user start firefox-sync-syncstorage.service
```

## Tests

Every image build runs the tests in [tests/](/tests) before the multi-arch tags (e.g. `syncstorage-rs-mysql-latest`) are published:
- [`tests/e2e.sh`](/tests/e2e.sh) `<mysql|postgres>`: starts the docker compose stack and checks start-up order, MAX_USERS, domain changes, a Firefox-like sign-in and sync through the tokenserver ([`test_client_flow.py`](/tests/test_client_flow.py), using upstream's mock FxA server) and runs upstream's storage and tokenserver integration tests
- [`tests/podman.sh`](/tests/podman.sh): rootless Podman, with Quadlets and with `docker compose` on the Podman socket, configured with `prepare_environment.sh`

Both can be run locally against any published tag, e.g. `TAG=latest tests/e2e.sh mysql`.

## Firefox setup

**Pre-requisite**: if you already logged into your Firefox account you need to temporarily disconnect it

The below examples assume your server respond to this domain: `firefox-sync.example.com`

### Desktop

1. point a browser tab to `about:config` and search for `identity.sync.tokenserver.uri`
1. change it from the default to `https://firefox-sync.example.com/1.0/sync/1.5`
1. log in to Firefox and start syncing.

#### Debug
1. check logs pointing a browser tab to `about:sync-log`

### Android

1. go to App Menu `⋮` > `Settings` > `About Firefox` and click the logo 5 times. You should see a `debug menu enabled` notification
1. go back to the main setting menu and you will see `Sync Debug` at the top, just under the `Synchronize and save your data` box. Tap on it
1. tap on `Custom Sync server` and set it to `https://firefox-sync.example.com/1.0/sync/1.5`
1. log in to Firefox and start syncing.

### iOS

1. go to App Menu `≡` > `Settings` and tap 5 times on the version number (i.e.: `Firefox 127.1 (42781)`) towards the bottom
1. go back at the top of the main setting menu and you will see `Advanced Sync Settings` at the top, just under the `Sync and Save Data`. Tap on it
1. activate `Use Custom FxA Content Server` and set `Custom Account Content Server URI` to `https://firefox-sync.example.com/1.0/sync/1.5`
1. log in to Firefox and start syncing.

## Credits
- [Mozilla](https://www.mozilla.org/) for [Firefox](https://www.mozilla.org/firefox) and opensourcing all their software, including the backend
- [jeena](https://github.com/jeena) for [fxsync-docker](https://github.com/jeena/fxsync-docker) which is the inspiration for this project