# Images

Reference: the container images the stack runs, their tags and architectures, and the upstream patches some of them carry. Which database servers they work with: [Supported versions](../databases.md#supported-versions). How to pin and upgrade them: [Upgrading](../upgrading.md).

Every image of this project is in `ghcr.io/porelli/firefox-sync` ([all tags](https://github.com/porelli/firefox-sync/pkgs/container/firefox-sync/versions)). The Sync server and accounts images are rebuilt every week from the newest upstream release, the admin UI on every change of its code. Each is published only after the [tests](../development/testing.md) passed with it.

## Why these images

Mozilla's server components are open source, and Firefox can be pointed to other servers. Mozilla [documents](https://mozilla-services.readthedocs.io/en/latest/index.html) running them, but does not support it, and the documentation is about a developer setup rather than a production service.

Mozilla publishes `syncstorage-rs` images with each [release](https://github.com/mozilla-services/syncstorage-rs/releases): [`syncserver-mysql`](https://github.com/mozilla-services/syncstorage-rs/pkgs/container/syncstorage-rs%2Fsyncserver-mysql) and [`syncserver-postgres`](https://github.com/mozilla-services/syncstorage-rs/pkgs/container/syncstorage-rs%2Fsyncserver-postgres). They are amd64 only, and built and tested for what Mozilla runs: its CI uses MySQL 8.0 and PostgreSQL, never MariaDB.

The images here are built as close to Mozilla's as possible. They add arm64, MariaDB and newer MySQL, the database setup and the user limit, and they are tested with every database they support.

## Sync server

| Image | Tags | What it is |
|---|---|---|
| `syncstorage-rs-mysql` | `syncstorage-rs-mysql-latest`, `-<release>`, `-<release>-<build date>` | Mozilla's syncstorage-rs, built from [its Dockerfile](https://github.com/mozilla-services/syncstorage-rs/blob/master/Dockerfile) with `SYNCSTORAGE_DATABASE_BACKEND=mysql` and `TOKENSERVER_DATABASE_BACKEND=mysql`, for MariaDB and MySQL instead of Google Spanner |
| `syncstorage-rs-postgres` | the same, `syncstorage-rs-postgres-...` | the same, built with both set to `postgres` |
| `syncstorage-rs-mysql-init` | the same, `syncstorage-rs-mysql-init-...` | the init container for MariaDB and MySQL: `mariadb:lts` (for its client) with [db_init.sh](/db/mysql/init/db_init.sh) and [db_init.sql](/db/mysql/init/db_init.sql) added ([Dockerfile](/db/mysql/init/Dockerfile)). It runs after the migrations, and creates what enforces `SYNC_MAX_USERS` |
| `syncstorage-rs-postgres-init` | the same, `syncstorage-rs-postgres-init-...` | the same for PostgreSQL: `postgres:latest` (for its `psql`) with [db_init.sh](/db/postgres/init/db_init.sh) and [db_init.sql](/db/postgres/init/db_init.sql) ([Dockerfile](/db/postgres/init/Dockerfile)) |

- Architectures: amd64 and arm64.
- `<release>` is syncstorage-rs' release tag. `<build date>` is the build's time, `YYYYMMDDTHHMMSS`: a weekly rebuild of the same release gets a new one.
- Source: [mozilla-services/syncstorage-rs](https://github.com/mozilla-services/syncstorage-rs). Code changes: only the [upstream patches](#upstream-patches), in the two Sync server images. The init images change no upstream code.
- The build fills in upstream's `version.json` (served at `/__version__`) and drops the cache mounts of the Dockerfile's cargo steps, so that the compiled dependencies are kept in the build cache ([syncstorage-rs-build.py](/.github/scripts/syncstorage-rs-build.py)). What is compiled and what the image contains stay the same.
- Built by [syncstorage-rs.yml](/.github/workflows/syncstorage-rs.yml) ([runs](https://github.com/porelli/firefox-sync/actions/workflows/syncstorage-rs.yml)).
- Settings: `IMAGE_REPOSITORY`, `SYNC_IMAGE`, `SYNC_IMAGE_TAG`, `SYNC_INIT_IMAGE` and `SYNC_INIT_IMAGE_TAG`, see [Settings](settings.md#images).

## Accounts

| Image | Tags | What it is |
|---|---|---|
| `fxa-mono` | `fxa-mono-latest`, `fxa-mono-<release>` (for example `fxa-mono-v1.349.0`) | Mozilla's accounts service, built from [its Dockerfile](https://github.com/mozilla/fxa/blob/main/_dev/docker/mono/Dockerfile), about 5 GB unpacked |
| `fxa-channelserver` | `fxa-channelserver-latest`, `fxa-channelserver-<release>` | the optional pairing server for QR codes, built the same way from [Mozilla's channelserver](https://github.com/mozilla-services/channelserver) |

- Architectures: amd64 and arm64, both tested before publishing. Mozilla publishes [`mozilla/fxa-mono`](https://hub.docker.com/r/mozilla/fxa-mono) for amd64 only.
- `fxa-mono-latest` is the newest release that passed the tests on both architectures, including a real Firefox signing up and syncing, and an install of the previous release upgraded to it.
- Source: [mozilla/fxa](https://github.com/mozilla/fxa). Code changes: only the [upstream patches](#upstream-patches).
- Built by [fxa.yml](/.github/workflows/fxa.yml).
- Settings: `FXA_IMAGE`, `FXA_VERSION` (`fxa-mono-latest` by default) and `FXA_ARCH`. The pairing server follows `FXA_IMAGE` with the tag `FXA_PAIRING_VERSION` (`fxa-channelserver-latest`), or `FXA_PAIRING_REPOSITORY`, or a full `FXA_PAIRING_IMAGE` ([Settings](settings.md#accounts)).

Mozilla's own image works too, on amd64:

```ini
FXA_IMAGE=docker.io/mozilla/fxa-mono
FXA_VERSION=v1.349.0
FXA_ARCH=amd64
# with the pairing server: Mozilla's, as FXA_IMAGE has none
FXA_PAIRING_IMAGE=docker.io/mozilla/channelserver:latest
```

It has none of the upstream patches, so it needs an older database major: see [Supported versions](../databases.md#supported-versions).

## Admin UI

| Image | Tags | What it is |
|---|---|---|
| `admin` | `admin-latest`, `admin-<commit>` (the first 12 characters of this repository's commit) | the optional [admin UI](../admin/README.md), and `fxa-policy`, which installs the sign-up policy of the self-hosted accounts |

- Architectures: amd64 and arm64.
- Source: [admin/](/admin), a Go program in a distroless image. Built by [admin.yml](/.github/workflows/admin.yml), which tests the candidate `admin-<commit>` against the published Sync and accounts images before tagging it `admin-latest`.
- Setting: `ADMIN_IMAGE`.

## Database images

The stack runs the official images of Docker Hub, unchanged: `mariadb`, `mysql`, `postgres` and, for the accounts' cache, `redis`. Their tags and pins: [Database majors](../upgrading.md#database-majors).

## Upstream patches

The Sync server and accounts images are built from Mozilla's releases, plus the upstream pull requests of [upstream-patches.yml](/upstream-patches.yml) that this project needs before Mozilla releases them. Each is applied as of the commit that was reviewed here. Once a release includes it, it is removed from the list.

Today:

| Pull request | Image | What it fixes |
|---|---|---|
| [mozilla/fxa#21494](https://github.com/mozilla/fxa/pull/21494) | `fxa-mono` | the accounts' migrations on MariaDB 12, see [MariaDB 12](../accounts.md#mariadb-12) |
| [mozilla/fxa#21709](https://github.com/mozilla/fxa/pull/21709) | `fxa-mono` | the accounts on MySQL 9, and on 8.4 without `mysql_native_password`, see [MySQL 9](../accounts.md#mysql-9). Merged, not in a release yet. Our images from before list mozilla/fxa#21554, the same change |
| [mozilla/fxa#21731](https://github.com/mozilla/fxa/pull/21731) | `fxa-mono` | with mysql2, `fxa-migrations` exited without an error when the database refused its user (a wrong `FXA_MYSQL_PASSWORD`), instead of stopping at once with `Access denied`, see [Troubleshooting](../troubleshooting.md#databases) |
| [mozilla-services/syncstorage-rs#2638](https://github.com/mozilla-services/syncstorage-rs/pull/2638) | `syncstorage-rs-mysql`, `syncstorage-rs-postgres` | ties between tokenserver nodes, which on MariaDB made upstream's `test_user_creation` fail |
| [mozilla-services/syncstorage-rs#2671](https://github.com/mozilla-services/syncstorage-rs/pull/2671) | `syncstorage-rs-mysql`, `syncstorage-rs-postgres` | an upstream test that failed when two writes fell in the same millisecond |
| [mozilla-services/syncstorage-rs#2680](https://github.com/mozilla-services/syncstorage-rs/pull/2680) | `syncstorage-rs-mysql`, `syncstorage-rs-postgres` | an upstream test that failed when two writes fell in the same centisecond |

Each image lists what was applied in its label `org.firefox-sync.upstream-patches`:

```bash
docker image inspect -f '{{index .Config.Labels "org.firefox-sync.upstream-patches"}}' ghcr.io/porelli/firefox-sync:fxa-mono-latest
```

The label lists one entry per pull request, separated by spaces, as `<repository>#<number>@<base>..<commit>`: the commit of the pull request applied, which for a release the newest commit does not apply to can be an earlier head of it (for example `mozilla/fxa#21554@3e2cb67..a99361e` on v1.348.5, in our images from before mozilla/fxa#21709). A ported change, made by hand, ends with `+<release>`, the release the port was made for (an older one when a newer release reuses it), for example `mozilla/fxa#21554@3e2cb67..84d71e2+v1.347.3`. The label is `none` when nothing was applied. Images built before the patches, and Mozilla's own images, have no label.

The label decides what works. Once Mozilla releases a pull request, its entry leaves upstream-patches.yml and the label: [config/fxa/fixed-in](/config/fxa/fixed-in) then names the first accounts release with it, and every accounts image of that release or later has it (Mozilla's too), read from its label `org.opencontainers.image.version`, else its tag.

- `prepare_environment.sh` reads them to choose the accounts' database image, and warns when the image does not fit the database. It reads the local image, which is what starts, or the registry's one (with `docker buildx imagetools` or `skopeo`) when there is no local copy or to tell you to pull a newer one.
- `tests/e2e.sh` skips, or retries, the upstream tests that a patch fixes when the image under test does not have it.

How the patches are added, checked and removed: [Upstream patches](../development/upstream-patches.md).

## Helm chart

`oci://ghcr.io/porelli/firefox-sync/charts/firefox-sync`, from [charts/firefox-sync](/charts/firefox-sync). How to install it: [Helm](../install/helm.md).

- It runs the images above. Its values are `image.repository` and `image.syncstorageTag`, `image.initTag` and `image.adminTag` (`latest` by default), and `database.image.*` for the database servers.
- Built and tested by [helm.yml](/.github/workflows/helm.yml): lint, the same settings as compose, and an install on kind per database backend. It is published on a `chart-v<version>` tag after those passed, see [Releasing](../development/releasing.md).
