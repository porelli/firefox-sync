# Testing

For contributors: what each test script in [tests/](/tests) covers, which workflow runs it, and how to run it locally. Users only need the one-line "Tested" verdicts of the pages they follow.

## The scripts

Every image build runs the CI tests before the multi-arch tags (for example `syncstorage-rs-mysql-latest`) are published. They can all run locally against any published tag, for example `TAG=latest tests/e2e.sh mysql`.

On a branch, syncstorage-rs.yml tests the images of the branch's inputs: an image whose inputs the branch did not change is main's, reused under the run's tags, and one it changed is built, with main's compiled dependencies when the change leaves them alone. What is in the key: [Releasing](releasing.md#the-images).

| Script | What it covers | Where | Main variables |
|---|---|---|---|
| [tests/e2e.sh](/tests/e2e.sh) `<mysql\|postgres>` | the docker compose stack with Mozilla's accounts: start-up order, max users, domain changes, a Firefox-like sign-in and sync ([test_client_flow.py](/tests/test_client_flow.py), upstream's mock FxA), upstream's storage and tokenserver integration tests, the admin UI, an upgrade from an install before `ADMIN_DB_PASSWORD`, a restore | CI: syncstorage-rs.yml, admin.yml | `TAG`, `SYNC_DB`, `SYNC_MYSQL_IMAGE`, `EXTERNAL_DB`, `DB_BOOTSTRAP`, `UPGRADE_FROM`, `PG_MAJOR_MOVE`, `DEMO` |
| [tests/e2e-fxa.sh](/tests/e2e-fxa.sh) | the stack with self-hosted accounts behind an HTTPS proxy and a mail catcher, see [Accounts](#accounts) | CI: fxa.yml, syncstorage-rs.yml, admin.yml | `FXA_DB`, `FXA_MYSQL_IMAGE`, `FXA_MARIADB_IMAGE`, `EXTERNAL_DB`, `DB_BOOTSTRAP`, `CLIENT_CERT`, `SSO`, `SKIP_SETUP`, `DEMO` |
| [tests/db_setup.sh](/tests/db_setup.sh) `<mysql\|mariadb\|postgres>...` | [db/db-setup.sh](/db/db-setup.sh) on servers of its own: what the bootstrap refuses (reserved names, a user of a stack name that is not the stack's, one on another host, a PostgreSQL role it does not administer, an administrator as the bootstrap account also through a role, a PostgreSQL database another role owns, by hand too), what the check reports (drift, grants through a default role or on a pattern; another role's grants and objects in the stack's PostgreSQL databases: warnings), two bootstraps at once, and the [setup migrations](../databases.md#setup-migrations): a test-only 999 file stopped and printed without the bootstrap, applied and recorded with it, the baseline of the SQL of an earlier release, a by-hand run recorded, a changed checksum, a newer version | `tests/e2e.sh` with `EXTERNAL_DB=1` | `SLOT`, `MYSQL_IMAGE`, `MARIADB_IMAGE`, `POSTGRES_IMAGE`, `UPGRADE_FROM` (the earlier release of the baseline) |
| [tests/setup_migrations.sh](/tests/setup_migrations.sh) | the setup migrations against [db/setup-manifest](/db/setup-manifest): every file with its checksum, the released ones (the manifest of `BASE`, origin/main) unchanged, numbered from 001, the accounts' alike on MySQL and MariaDB, the copies of the manifest and the chart's files identical; `--update` writes the lines of the files not released yet | CI: docs.yml, every push | `BASE` |
| [tests/podman.sh](/tests/podman.sh) | rootless Podman, with Quadlets (also with self-hosted accounts) and with docker compose on the Podman socket, set up with `prepare_environment.sh` and its answers by name | CI: syncstorage-rs.yml, fxa.yml, admin.yml | `SYNC_DB`, `FXA_DB`, `EXTERNAL_DB`, `DB_BOOTSTRAP`, `UPGRADE_FROM` |
| [tests/fxa-upgrade.sh](/tests/fxa-upgrade.sh) | the self-hosted accounts upgraded in place from an older release, see [Accounts](#accounts) | CI: fxa.yml `test-upgrade` | `FXA_FROM`, `FXA_IMAGE`, `FXA_VERSION`, `FXA_SAME_TAG`, `FXA_DB`, `FXA_MARIADB_FROM`, `FXA_MYSQL_TO` |
| [tests/helm.sh](/tests/helm.sh) `<lint\|parity\|e2e>` | the Helm chart, see [Helm chart](#helm-chart) | CI: helm.yml | `EXTERNAL_DB`, `DB_BOOTSTRAP`, `SKIP_BUILD`, `REPOSITORY`, `TAG` |
| [tests/migrate.sh](/tests/migrate.sh) `<scenario>` | the moves of [Migrating](../migrating.md) from other Sync servers (Mozilla's compose files, dan-r, jeena, NixOS, YunoHost) and the upgrade of the earlier firefox-sync release with compose and Quadlets, and with Watchtower and `podman auto-update` on its images ([Upgrading](../upgrading.md#the-earlier-firefox-sync-release)), read back with [migrate_client.py](/tests/migrate_client.py) | local only (the VM: `vm.sh ssh`) | the scenario; `PORT`, `REPOSITORY`, `TAG`, `INIT_TAG` |
| [tests/test_upstream_patches.py](/tests/test_upstream_patches.py) | the decisions of `.github/scripts/upstream-patches.py` on fixtures, no network | CI: the jobs that pick the release | none |
| [tests/test_release.py](/tests/test_release.py) | [release.py](/.github/scripts/release.py), no network: when a release is cut (nothing new, a new syncstorage-rs, FxA or pairing server, other upstream patches, Unreleased entries, a tag), its tag, title and notes, the moving of Unreleased in CHANGELOG.md (empty subsections dropped, idempotent, later entries kept), see [Releases](releasing.md#releases) | CI: docs.yml and release.yml, every push | none |
| [tests/test_syncstorage_rs_build.py](/tests/test_syncstorage_rs_build.py) | the cache mounts `.github/scripts/syncstorage-rs-build.py` drops from upstream's Dockerfile, on fixtures | CI: syncstorage-rs.yml `prepare-env` | none |
| [tests/test_affected.sh](/tests/test_affected.sh) | the test jobs [affected.sh](/.github/scripts/affected.sh) picks for a change, a case per group of its mapping, every tracked file classified, see [Which tests a push runs](#which-tests-a-push-runs) | CI: syncstorage-rs.yml `changes` | none |
| [tests/prepare_functions.sh](/tests/prepare_functions.sh) | the functions of `prepare_environment.sh` ([setup/](/setup)) that need no container, on tables, per file: `.env` read as compose reads it (compared with `docker compose config` when there is one), written through a symlink, no value on `sed`'s command line, the compose files of an install (env.sh); the addresses of `SYNC_EXPORT_PORT`, the limits, names and hosts, `FXA_OAUTH_SERVER_URL` at `fxa-auth:9000` (validate.sh); the ports of this host in use and the next free one, from what `ss` prints (ports.sh); the names one certificate covers (proxy.sh); `database-setup.sql` (databases.sh); the accounts images with a fix of [upstream-patches.yml](/upstream-patches.yml) (images.sh); the checkout of the units (quadlets.sh); `--upgrade` of an `.env` from before (upgrade.sh); `setup/` loaded from the script's real path | `tests/podman.sh` runs it first; anywhere, also macOS's bash 3.2 | `COMPOSE` |
| [tests/setup_output.sh](/tests/setup_output.sh) `[case...]` | the questions of `prepare_environment.sh` ([setup/questions.sh](/setup/questions.sh)): the same files for the same choices as the setup before they were reworked (`BASE`, fetched when missing), its answers on stdin in their old order, the new one's by name ([Answers by name](../install/compose.md#answers-by-name)), for a matrix of answer sets (accounts, databases, your own servers and their bootstrap, the admin UI, Quadlets, compose on the Podman socket, a setup again over an install): `.env`, the systemd and SQL examples, the Quadlet units and their environment files, the random values masked (and the setup of before's nginx examples against the new `proxy/nginx.conf`: the same host names and upstreams; `proxy/` is the new one's only); then the interactive flow on stdin with `<` and a part changed in the review, the generated secrets said at the end, the public URLs, the admin UI's sign-in, the bundled Caddy (compose, Quadlets), the labels for Traefik, `--render-proxy` and `--upgrade` of `proxy/` that the old setup could not write, the ports of this host in use (an `ss` stub: the next free port, said; this stack's own containers' ports free, set up again and `--upgrade`), `FXA_OAUTH_SERVER_URL` at `fxa-auth` on another port warned of, one certificate for all (a wildcard; nginx's include; a host it does not cover warned of) and the nginx examples of an earlier setup moved into `proxy/old/`; on a terminal ([tests/setup_tty.py](/tests/setup_tty.py), a pty) the menus, the answers edited in place and the review. The setup runs with the programs it may use only (`SETUP_TOOLS`: no interpreter, no tool it did not use before), and its code is checked for others. No container runtime: stubs, a temporary `HOME` | CI: docs.yml, every push | `BASE` |
| [tests/proxy_render.sh](/tests/proxy_render.sh) | the configuration of the reverse proxy ([setup/proxy.sh](/setup/proxy.sh), [Reverse proxy](../reverse-proxy.md)) for the answer sets of [tests/proxy/](/tests/proxy) (`<case>/settings`): every file the same as the one kept there (`UPDATE=1` writes them again, to review in the diff); then, with docker, `nginx -t` (`nginx:latest`, a test certificate per host, or where the one for all is, `PROXY_CERTS=one`), `caddy validate` (`caddy:latest`, also with the snippets of `caddy.d/`), Traefik (`traefik:latest`) reading `traefik.yml` with every router, middleware and service enabled, `docker compose config` with `compose/caddy.yml` or `proxy/traefik-compose.yml`, and the bundled Caddy of `compose/caddy.yml` on the host's network: the admin UI's host let through from this host, refused (403) from a container, which Caddy sees at its own address, not the bridge's gateway | CI: docs.yml, every push (`CONTAINERS=1`) | `UPDATE`, `CONTAINERS` |
| [tests/check_markdown_links.py](/tests/check_markdown_links.py) and [its self-test](/tests/test_check_markdown_links.py) | the links of the docs, see [Links](#links) | CI: docs.yml, every push | `--code`, `--settings`; `--external` by hand |
| [tests/check_site_anchors.py](/tests/check_site_anchors.py) | after `mkdocs build`, every anchor of the docs is an id of the site's page, see [Docs site](#docs-site) | CI: docs.yml, every push | `--site` |
| [tests/vm/vm.sh](/tests/vm/vm.sh) | the suites above in a local Ubuntu VM, several at once, see [Local VM](#local-vm) | local only | `REPO`, `REPOSITORY`, `FFS_VM_DIR`, `FFS_GHCR_TOKEN` |
| `cd admin && go test ./...` | the admin UI's unit tests, see [Admin UI](#admin-ui) | CI: admin.yml `unit` | none |

The end-to-end scripts finish with [tests/healthy.sh](/tests/healthy.sh): every container that keeps running is healthy, and the one-shot ones exited with 0. `tests/podman.sh` also checks that each long-running Quadlet has the healthcheck of its compose service (the same command and timings), and that no such service lacks one.

`EXTERNAL_DB=1` runs the same on a database server outside the stack, with only the documented grants ([Database users](../reference/database-users.md)): MySQL (`SYNC_MYSQL_IMAGE`) with binary logging, or PostgreSQL set up by a role that is no superuser, with an owner that is no superuser. `tests/e2e-fxa.sh` takes it too: one MySQL (`FXA_MYSQL_IMAGE`), or MariaDB with `FXA_DB=mariadb`, for Sync and the accounts. `EXTERNAL_DB=fxa` puts only the accounts there. `tests/podman.sh`: a server of `SYNC_DB` for the Quadlets, see [The Sync server and Podman](#the-sync-server-and-podman).

On that server, `db-bootstrap` (`fxa-db-bootstrap`) checks the users and grants at every start. `tests/e2e.sh` drops the admin UI's reader there, and `tests/e2e-fxa.sh` revokes a grant of the policy user: the next start stops, naming the statement, until the SQL runs again ([When a release needs new users or grants](../databases.md#when-a-release-needs-new-users-or-grants)).

`DB_BOOTSTRAP=1`, with `EXTERNAL_DB`, gives that server only the accounts of [The bootstrap account](../databases.md#the-bootstrap-account), from `db/mysql/setup/sync-bootstrap`, `fxa-bootstrap` and `db/postgres/setup/sync-bootstrap`, and their names to the stack: everything else is created by the stack itself, so a passing run proves those grants suffice, on MySQL, MariaDB and PostgreSQL. The dropped reader and the revoked grant come back at the next start (drift, the setup migrations run again). Each suite also checks the record of the [setup migrations](../databases.md#setup-migrations): `containers` with the stack's database containers, `baseline` or `bootstrap` on your own server, the version in the admin UI's metrics, and a grant revoked by hand as drift (its metric and its alert). `tests/podman.sh` creates the account with the `database-bootstrap.sql` that `prepare_environment.sh` writes, and `tests/helm.sh e2e` with `database.external.bootstrap.user`. CI runs both ways: the bootstrap in syncstorage-rs.yml `test` (MySQL `lts`), admin.yml `e2e` (PostgreSQL) and `e2e-fxa` (MySQL `lts`, MariaDB), syncstorage-rs.yml `test-podman` (`external-mariadb`) and helm.yml `e2e` (MySQL); the check only in the other jobs on your own server.

Tests that work around an upstream bug read the image's label: see [Upstream patches](upstream-patches.md#in-the-tests).

## Which tests a push runs

syncstorage-rs.yml does not run at all for a push of only docs and other files no test reads (its `paths-ignore`). Otherwise its job `changes` lists the files the push changed, and [.github/scripts/affected.sh](/.github/scripts/affected.sh) maps them to the three test jobs: `test` (the compose suites of `tests/e2e.sh`), `test-podman` (`tests/podman.sh`) and `test-fxa` (`tests/e2e-fxa.sh`). The other jobs always run: the builds take a minute when they reuse the images.

The changes are those since the commit before the push, when this workflow's run of it passed. When it did not (a new branch, a run cancelled by a newer push, a failed one, or a push that ran nothing), they are those since the merge base with main.

| A change to | `test` | `test-podman` | `test-fxa` |
|---|---|---|---|
| syncstorage-rs.yml, `affected.sh`; the inputs of the images (`db/`, [upstream-patches.yml](/upstream-patches.yml) and `upstream-patches/`, the scripts that prepare the app's sources, `.github/actions/`); `prepare_environment.sh`, `setup/`, `.env-example`, `docker-compose*.yml`, `compose/sync*.yml`, `compose/podman.yml`, `admin/`, `config/` but `config/quadlet/`, `tests/healthy.sh`, `tests/slot.sh` | yes | yes | yes |
| `config/quadlet/`, `tests/podman.sh`, `tests/prepare_functions.sh`, `.github/scripts/pasta-apparmor.sh`, [migrating.md](../migrating.md) | - | yes | - |
| `compose/fxa*.yml`, `compose/caddy.yml`, `tests/fxa_fix.sh` (`tests/podman.sh` compares its Quadlets with the compose files) | - | yes | yes |
| [backups.md](../backups.md), [upgrading.md](../upgrading.md) (see [Docs that tests read](#docs-that-tests-read)) | yes | yes | - |
| `tests/e2e.sh` and what only it uses: `tests/compose/sync.yml`, `tests/db_setup.sh`, the Python tests it runs (`test_client_flow.py`, `test_admin_*.py`, `test_sync_allowlist.py`, `migrate_client.py`), `tests/dex.yml` | yes | - | - |
| `tests/compose/admin-build.yml`, `demo.yml`, `external-db.yml`, `tests/demo_seed.py`, `tests/conftest.py`, `tests/notify_sink.py` | yes | - | yes |
| `tests/e2e-fxa.sh` and what only it uses: `tests/test_fxa_*.py` (but `test_fxa_upgrade.py`), `tests/browser/`, `tests/caddy/`, `tests/compose/fxa.yml`, `external-db-fxa.yml`, `proxy-*.yml` | - | - | yes |
| the docs and the other workflows' tests (the chart's, `tests/helm*`, `tests/fxa-upgrade.sh`, docs.yml's `tests/setup_output.sh`, `tests/proxy_render.sh` and `tests/proxy/`, the local `tests/migrate.sh`) | - | - | - |
| anything else: a file no group names | yes | yes | yes |

Every test job runs anyway on main, on the weekly schedule, for a run by hand, and when the run builds an image instead of reusing one (its inputs changed, for example a new syncstorage-rs release). On main every one of them must pass before the multi-arch tags are published.

When a test starts to use another file, give that file its group in `affected.sh`, where a comment per group says why, and a case in [tests/test_affected.sh](/tests/test_affected.sh): until then a new file runs every test job. To check a mapping locally:

```bash
bash tests/test_affected.sh
git diff --name-only main | .github/scripts/affected.sh
```

## Test matrix

The defaults follow each database's long-term tag (`mariadb:lts`, `mysql:lts`; PostgreSQL has none: `postgres:latest`, pinned per install at setup). The older majors are those the installs from before stay on ([Database majors](../upgrading.md#database-majors)). Which workflow and job runs what:

| Component | Database | Stack's container | Your own server (`EXTERNAL_DB=1`) |
|---|---|---|---|
| Sync | MariaDB `lts` | syncstorage-rs.yml `test`, admin.yml `e2e`, helm.yml `e2e` | admin.yml `e2e-fxa` (`FXA_DB=mariadb EXTERNAL_DB=1`: one MariaDB server for Sync and the accounts) |
| Sync | MySQL `lts` | syncstorage-rs.yml `test` and admin.yml `e2e` (`SYNC_DB=mysql`), helm.yml `e2e` | syncstorage-rs.yml `test`, admin.yml `e2e`, helm.yml `e2e` |
| Sync | MySQL 8 (installs from before) | syncstorage-rs.yml `test` (`SYNC_DB=mysql`, `SYNC_MYSQL_IMAGE=mysql:8`) | syncstorage-rs.yml `test` (`SYNC_MYSQL_IMAGE=mysql:8`), admin.yml `e2e-fxa` (`FXA_MYSQL_IMAGE=mysql:8`: one server for Sync and the accounts) |
| Sync | PostgreSQL `latest` (its major pinned) | syncstorage-rs.yml `test`, admin.yml `e2e`, helm.yml `e2e` (amd64 and arm64), and `e2e-fxa` with the accounts (`SYNC_BACKEND=postgres`) | syncstorage-rs.yml `test`, admin.yml `e2e`, helm.yml `e2e` |
| Sync | PostgreSQL, the major before that of `latest`, moved to `latest` | syncstorage-rs.yml `test` (`PG_MAJOR_MOVE=1`) | - |
| Accounts | MySQL `lts` (images with mozilla/fxa#21709) | fxa.yml `test`, admin.yml `e2e-fxa` and helm.yml `e2e-fxa` (each on amd64 and arm64) | admin.yml `e2e-fxa`, helm.yml `e2e-fxa` |
| Accounts | MySQL 8 with `mysql_native_password` (installs from before, images without it) | fxa.yml `test` (`FXA_MYSQL_IMAGE=mysql:8`), syncstorage-rs.yml `test-fxa` (Mozilla's images), fxa.yml `test-upgrade` (then to `lts`) | admin.yml `e2e-fxa` (`FXA_MYSQL_IMAGE=mysql:8`) |
| Accounts | MariaDB `lts` (needs mozilla/fxa#21494) | fxa.yml `test-mariadb`, admin.yml `e2e-fxa`, helm.yml `e2e-fxa` | admin.yml `e2e-fxa` (`FXA_DB=mariadb EXTERNAL_DB=1`) |
| Accounts | MariaDB 11 (installs from before) | fxa.yml `test-mariadb` (`mariadb:11`) | - |
| Podman, Quadlets | the defaults (MariaDB `lts`, the accounts on MySQL as above) | syncstorage-rs.yml, fxa.yml and admin.yml `test-podman`/`podman` | - |
| Podman, Quadlets | Sync on MySQL `lts` (`SYNC_DB=mysql`) | syncstorage-rs.yml `test-podman` (`sync-mysql`) | - |
| Podman, Quadlets | Sync on PostgreSQL `latest` (its major pinned, `SYNC_DB=postgres`) | syncstorage-rs.yml `test-podman` (`sync-postgres`) | - |
| Podman, Quadlets | the accounts on MariaDB `lts` (`FXA_DB=mariadb`) | syncstorage-rs.yml `test-podman` (`fxa-mariadb`) | - |
| Podman, Quadlets | your own server (`EXTERNAL_DB=1`) | - | syncstorage-rs.yml `test-podman`: `external-mariadb`, `sync-mysql`, `sync-postgres` |

The jobs run on amd64, and these on arm64 too: fxa.yml `test` and `test-podman`, admin.yml `e2e-fxa` (MySQL), helm.yml `e2e` (PostgreSQL) and `e2e-fxa` (MySQL, with Firefox).

Redis (the accounts' cache, no volume) follows `redis:alpine` in every run with the accounts.

Locally, in the [local VM](#local-vm): `REPO=<worktree> tests/vm/vm.sh test e2e-mysql` with `SYNC_DB=mysql` and `SYNC_MYSQL_IMAGE=mysql:8`, `e2e-fxa` with `FXA_MYSQL_IMAGE=mysql:8` or `FXA_DB=mariadb FXA_MARIADB_IMAGE=mariadb:11`, `fxa-upgrade` with `FXA_FROM=<an older accounts image>` (and `FXA_MYSQL_TO`).

### What CI does not test

- Sync with Mozilla's real accounts: the tests sign in through a mock of them (upstream's mock FxA), and upstream's tokenserver test against Mozilla's stage accounts is left out.
- Firefox on Android and iOS: their sync, pairing from the phone's side, client certificates. The real Firefox of the tests is the desktop one, on Linux.
- The self-hosted accounts on PostgreSQL: Mozilla's accounts server does not support it, so neither does this project. Not a gap.

## Local VM

[tests/vm/vm.sh](/tests/vm/vm.sh) runs the end-to-end suites on your machine instead of GitHub, in an Ubuntu VM like CI's runners: the newest Ubuntu LTS, its Docker, compose and Podman, a systemd user session, and the latest kind, helm, kubectl, chart-testing, kubeconform, yamllint and yamale. It has up to three slots, so three commands can run at once, each in its own copy of the checkout with its own ports and names ([tests/slot.sh](/tests/slot.sh)). The header of the script documents every command and variable; `tests/vm/vm.sh help` prints it.

Requirements on the host: `qemu` (`qemu-system-aarch64` or `qemu-system-x86_64`, `qemu-img`) with its UEFI firmware (edk2: Homebrew's `qemu` has it; on Linux the `qemu-efi-aarch64` or `ovmf` package), one of `mkisofs`, `genisoimage` or `xorriso`, `ssh`, `curl`, `rsync` and `git`, hardware virtualization (HVF on macOS, `/dev/kvm` on Linux), and about 50 GB of disk for the VM.

```bash
tests/vm/vm.sh create            # the disk and the cloud-init seed, on the newest Ubuntu LTS
tests/vm/vm.sh start             # boot; the first boot also provisions
tests/vm/vm.sh provision         # later: apt upgrades and the latest tools
tests/vm/vm.sh test e2e-mysql    # or e2e-postgres, e2e-fxa, podman, fxa-upgrade, all, several at once
tests/vm/vm.sh test affected     # the suites the changes since the remote's default branch need
tests/vm/vm.sh test helm-lint helm-fxa-mysql   # the chart: helm-lint, helm-<backend>, helm-fxa-<db>
tests/vm/vm.sh ssh 'cd firefox-sync && tests/helm.sh lint'
tests/vm/vm.sh slots             # who holds which slot, the VM's free disk
tests/vm/vm.sh stop
tests/vm/vm.sh destroy           # the disk, not the base image
```

Every command copies the checkout into its slot first, so uncommitted changes are tested too. The settings:

- `FFS_VM_DIR`: where the VM's files are (disk, base image, seed, UEFI variables, pid, console log), outside the checkout. Default `${XDG_DATA_HOME:-~/.local/share}/firefox-sync-vm`. An existing VM keeps working when `FFS_VM_DIR` points at it; to move it there instead, stop it, move the directory, and for a VM created before the script was in the repository (its disk names the base image by an absolute path) run `qemu-img rebase -u -b <codename>-server-cloudimg-<arch>.img -F qcow2 disk.qcow2` in it. A second VM needs its own `FFS_VM_DIR` and `SSH_PORT` (default 2222) at `create`; both are remembered there.
- `REPO`: the checkout under test, by default the one the script is in. `REPO=<worktree>` tests a worktree with the VM.
- `REPOSITORY`: the images under test (with `TAG`, default `latest`). By default `ghcr.io/<owner>/<repo>` of the checkout's remote named `dev` or ending in `-dev`, else of `origin`, in lowercase (`FFS_VM_REMOTE` picks another remote). The development repository's images are newer than the public repository's, which only get releases.
- `FFS_GHCR_TOKEN`: a token for `docker login ghcr.io` in the VM at `provision`, needed only when `REPOSITORY` is private: a fine-grained or classic token with `read:packages` only. It is stored in the VM's `~/.docker/config.json`. Without it the VM pulls public images only; `FFS_GHCR_GH=1` (or a yes at the prompt) uses `gh auth token` instead, a broader token. No token is printed.
- `FFS_VM_SSH_KEY`: the SSH key, by default `~/.ssh/id_ed25519`, or one `create` makes in `FFS_VM_DIR` when there is none. `CPUS` and `MEM` (MB): by default three quarters of the host's CPUs and half its memory.

`create` also makes the VM's SSH host key and gives it to cloud-init, so every connection checks it against `FFS_VM_DIR/known_hosts` (connections share a master of the script's own, not one of `~/.ssh/config`). A VM created before has its key recorded at the first connection: trust on first use, on the host's loopback. The slots' locks are in `FFS_VM_DIR/slots`; the script refuses a `FFS_VM_DIR` that is not yours or that others can write to. Test logs go to a new private folder in `${TMPDIR:-/tmp}`, or `LOGS`. `provision` sends the token only to the host key it knows, and only when the port's listener is the VM's qemu.

The VM's clock stops while the host sleeps, and its chrony may have no time source it can reach: every command (`test`, `ssh`, `image`...) and `start` set it to the host's when they are more than `CLOCK_SLACK` (5) seconds apart, and say so. qemu's RTC follows the host's clock in UTC; `provision` lets chrony step the clock whenever it is off by a second.

Tested on macOS on Apple silicon (arm64, HVF). macOS on Intel and Linux with KVM, and with them the amd64 VM, are written for (`qemu-system-x86_64`, the OVMF and AAVMF firmware paths, `genisoimage` and `xorriso`) but not tested yet.

## The Sync server and Podman

`tests/e2e.sh`:

- with `SYNC_DB=mysql`, the stack on MySQL (`SYNC_MYSQL_IMAGE`: `mysql:lts`, or `mysql:8` as the installs from before; then it also checks that `lts` refuses their data, that `--upgrade` pins them, and the move to `lts`);
- the upgrade from an install before `ADMIN_DB_PASSWORD` (this tree without it, the admin UI's tables in the tokenserver database, the old setting names), which moves the admin UI's event log out of the Sync server's users' reach;
- the Sync MariaDB containers of an install from before `SYNC_MARIADB_IMAGE`, pinned by `--upgrade` to the major of their data;
- with `PG_MAJOR_MOVE=1` (postgres), the install on the major before that of `postgres:latest` (read at run time) and, at the end, the move of [PostgreSQL](../upgrading.md#postgresql): the backup, the new major refused on the old data (by [keep-major.sh](/db/postgres/keep-major.sh)), the restore into an empty volume, the same accounts and items read back on the new major, also after a restart.

`tests/podman.sh`:

- the Quadlets and docker compose on the Podman socket, both set up with `prepare_environment.sh`;
- the MySQL Quadlets as rendered; with `SYNC_DB=mysql`, the compose phase as an install from before on `mysql:8` (pinned by `--upgrade`) and the Quadlets on `mysql:lts`;
- with `EXTERNAL_DB=1`, the Quadlets on a server of `SYNC_DB` outside them (`mariadb:lts`, `mysql:lts` with binary logging, `postgres:latest`), set up by `database-setup.sql`: the Sync server, the admin UI, a backup, `--upgrade` and `--render-units`;
- the PostgreSQL Quadlets as rendered (also on your own server); with `SYNC_DB=postgres`, the compose phase on PostgreSQL only and the Quadlets on PostgreSQL: pinned to the major of Podman's `postgres:latest` and running it, the Sync server's own role, the backups and the restore of [Restore with Quadlets](../backups.md#restore-with-quadlets), `--upgrade`, `--render-units`, and another major refused by `keep-major.sh`;
- `--upgrade` renaming the old setting names and writing `COMPOSE_FILE` with the files of `compose/` ([Files that moved](../upgrading.md#files-that-moved));
- the commands of the docs for the Quadlets, read from the pages and run as written: the dumps of an install loaded into a new one ([Loading into firefox-sync](../migrating.md#loading-into-firefox-sync), for `SYNC_DB`); with `SYNC_MYSQL_FROM=mysql:8` (and `SYNC_DB=mysql`) the Sync databases started on it and moved to `mysql:lts`, with `FXA_MYSQL_FROM=mysql:8` the accounts' (with `mysql_native_password`, their users moved first) as [MySQL 8 to 9](../upgrading.md#mysql-8-to-9) says, with `FXA_MARIADB_FROM=mariadb:11` (and `FXA_DB=mariadb`) as [MariaDB](../upgrading.md#mariadb) says;
- `--render-units` on the running Quadlets (a setting, an `ADMIN_IMAGE` pin, `ADMIN_INSECURE_COOKIE`), and with the accounts on MariaDB (`FXA_LOG_LEVEL`): only the changed units written, the secrets kept, a second run changing nothing, the stack started again;
- where the Sync server listens: `SYNC_EXPORT_PORT` of a new install on `127.0.0.1` (the answers, nginx, `PublishPort`, `ss`), an upgraded one keeping its value;
- the bundled Caddy as a Quadlet (`PROXY=caddy`, `--render-units`): on the host's network and ports of its own, the Sync server through it with a certificate of Caddy's own CA, HTTP redirected to HTTPS; its units removed with `PROXY=own`.

## Accounts

`tests/e2e-fxa.sh` starts the stack behind a reverse proxy, with the configuration `prepare_environment.sh` writes for its `.env` ([Reverse proxy](../reverse-proxy.md)), and a mail catcher (Mailpit). No Mozilla service is involved. `TEST_PROXY` picks the proxy, each with [tests/compose/proxy-&lt;proxy&gt;.yml](/tests/compose):

- `caddy` (default): the bundled Caddy, [compose/caddy.yml](/compose/caddy.yml) (`CADDY_ACME_CA=internal`: HTTPS with Caddy's own CA), here on the stack's network with its variant that proxies to the containers by name;
- `nginx`: `nginx:latest` with `proxy/nginx.conf`, the containers by name (its variant on the stack's network), the certificates of a test CA made with OpenSSL;
- `traefik`: `traefik:latest` and its Docker provider, reading the labels of `proxy/traefik-compose.yml` on the public containers, on the stack's own network for it (`TRAEFIK_NETWORK`), a test CA's certificate as its default one. With the admin UI's trusted-header sign-in from Traefik's address alone (`/32`): the header counts from Traefik, a client's is dropped by the admin UI's route, another container's on that network is refused.

CI runs the three in the weekly accounts test of [syncstorage-rs.yml](/.github/workflows/syncstorage-rs.yml) (`test-fxa`; `SKIP_SETUP=1` but with Caddy). Locally: `tests/vm/vm.sh test 'TEST_PROXY=nginx SKIP_SETUP=1 e2e-fxa'`.

- [test_fxa_flow.py](/tests/test_fxa_flow.py) does what Firefox does: reads the client configuration, signs up, confirms the email, gets the keys and an OAuth token, gets a sync token and syncs, then signs in again as a second device. It also checks that the Sync server refuses tokens the accounts did not sign: a JWT with the same claims signed by a key made in the test (an unknown `kid`, then the accounts' own `kid`), and a random opaque token. Each gets 401 `invalid-credentials`, and the tokenserver's `users` table is unchanged. [e2e-fxa.sh](/tests/e2e-fxa.sh) then checks in `fxa-auth`'s log that the opaque token went to the stack's own `/v1/verify`, which refused it.
- [test_fxa_admin.py](/tests/test_fxa_admin.py) checks the sign-up policy and the admin UI ([Admin UI](#admin-ui)).
- [test_fxa_browser.py](/tests/test_fxa_browser.py) does the same with a real Firefox (Mozilla's build, in [tests/browser](/tests/browser)): one profile signs up through the accounts web pages and syncs a bookmark, a second profile signs in and must receive it. Every Firefox records every request its pages make (WebDriver BiDi), and each test fails when they asked a host outside the stack, the domain of the test's host names, unless it is in `ALLOWED_HOSTS` (none): a telemetry or error-report host is named as such ([Telemetry](../accounts.md#telemetry)). The log ends with the hosts asked and how many requests each.
  - Its image installs the latest Firefox release, the one users have, and the log starts with its version. A new Firefox or a new accounts release can change the pages: the test finds their fields by their role (email, password, code), not by their exact markup.
  - When it fails, the log shows what each Firefox window showed: the version, the address, the text and the form fields. `tests/e2e-fxa.sh` also keeps their page source and a screenshot, in a new `ffs-browser-artifacts.*` directory under `RUNNER_TEMP` or `/tmp` that it prints. CI uploads it as the `browser-pages-<job>` artifact.
- [test_fxa_pairing.py](/tests/test_fxa_pairing.py) checks the pairing server's websocket channel.
- It runs with the newest Mozilla accounts release every week, and on amd64 and arm64 for the [accounts images](/.github/workflows/fxa.yml).
- The accounts database is MySQL, `FXA_MYSQL_IMAGE`: by default `mysql:lts` for an accounts image with mozilla/fxa#21709 in its label, else `mysql:8` with `FXA_MYSQL_ARGS` (`mysql_native_password`).
- With `FXA_DB=mariadb` it is MariaDB, `FXA_MARIADB_IMAGE`: by default `mariadb:lts`, or `mariadb:11` for an accounts image without mozilla/fxa#21494. `tests/podman.sh` takes `FXA_DB` too, for the Quadlets.
- `db/mysql/keep-major.sh` refuses MariaDB 11 data on `mariadb:lts` without `SYNC_MARIADB_IMAGE`, and says what to set.

`tests/fxa-upgrade.sh` upgrades an install in place with the steps of [Upgrading](../upgrading.md#self-hosted-accounts):

1. It starts the stack on an older release (`FXA_FROM`), where [test_fxa_upgrade.py](/tests/test_fxa_upgrade.py) signs up, registers a device, gets a refresh token and syncs.
1. Then a backup, the new `FXA_VERSION`, `docker compose pull` and `docker compose up -d`. With `FXA_SAME_TAG=1` the older release is installed under the new tag, as an install following `fxa-mono-latest` has it, and `docker compose up -d` without the pull must keep it.
1. After it: the migrations ran up to the levels of the new image's `target-patch.json`; the sign-up policy and the admin UI's procedures are installed again; the old session, device and refresh token still work; the Sync data reads back on the same tokenserver user; a new sign-in and a new sign-up work; the admin UI is all up, shows the new release and recorded each migrated schema as an event.
1. On MySQL the install runs `mysql:8` with `mysql_native_password`, as those from before: the new files without its settings (`fxa-db` refuses to upgrade the data), `--upgrade`, the upgrade, then, with a new image that has mozilla/fxa#21709, the move to `mysql:lts` of [MySQL 8 to 9](../upgrading.md#mysql-8-to-9) (`FXA_MYSQL_TO`).

[fxa.yml](/.github/workflows/fxa.yml) runs it from the published `fxa-mono-latest` to every new release before publishing it (amd64; not for a rebuild of a release older than the published one). It upgrades to `FXA_IMAGE:FXA_VERSION` (default: `IMAGE_REPOSITORY`, `fxa-mono-latest`), reads the release the admin UI must show from that image, and refuses a target older than `FXA_FROM`. Locally, for example:

```bash
# from Mozilla's own image (amd64, emulated on arm64) with older schemas
FXA_FROM=docker.io/mozilla/fxa-mono:v1.345.2 FXA_IMAGE=ghcr.io/<owner>/<repo> FXA_VERSION=fxa-mono-v1.349.0 tests/fxa-upgrade.sh
# from one of our older builds on MariaDB
FXA_FROM=ghcr.io/<owner>/<repo>:fxa-mono-v1.347.1 FXA_IMAGE=ghcr.io/<owner>/<repo> FXA_DB=mariadb tests/fxa-upgrade.sh
# from an older fxa-mono-latest
FXA_FROM=ghcr.io/<owner>/<repo>:fxa-mono-v1.347.1 FXA_IMAGE=ghcr.io/<owner>/<repo> FXA_SAME_TAG=1 tests/fxa-upgrade.sh
# an install on MariaDB 11 moved to lts (12), with the new image that has mozilla/fxa#21494
FXA_FROM=ghcr.io/<owner>/<repo>:fxa-mono-v1.347.3 FXA_IMAGE=ghcr.io/<owner>/<repo> FXA_DB=mariadb FXA_MARIADB_FROM=mariadb:11 FXA_MARIADB_IMAGE=mariadb:lts tests/fxa-upgrade.sh
# on MySQL: mysql:8 with mysql_native_password, --upgrade, then the move to mysql:lts
FXA_FROM=ghcr.io/<owner>/<repo>:fxa-mono-v1.347.3 FXA_IMAGE=ghcr.io/<owner>/<repo> tests/fxa-upgrade.sh
```

Our builds are in the registry of the repository whose fxa.yml built them: `ghcr.io/<owner>/<repo>`, for example `ghcr.io/porelli/firefox-sync`.

### Access control

`CLIENT_CERT=1` or `SSO=authelia` (with `TEST_PROXY=caddy`) put Caddy's access control of [tests/caddy](/tests/caddy), copied into the `caddy.d/` of `proxy/` ([Caddy](../reverse-proxy.md#caddy)), in front of the accounts pages and the admin UI, as [Single sign-on and client certificates](../single-sign-on.md) describes. [test_fxa_access.py](/tests/test_fxa_access.py) runs first, then the usual tests through it ([tests/conftest.py](/tests/conftest.py) gives their requests the certificate or the cookie):

- `CLIENT_CERT=1`: a test client CA (made by the script with OpenSSL), its certificate in each Firefox profile (`pk12util`, `security.default_personal_cert`). The pages answer `403` without it, the admin UI's host refuses the handshake, a certificate of another CA is refused, the open paths and the other hosts answer anybody. A Firefox probe checks that its background requests send no client certificate: when that changes, the page needs to.
- `SSO=authelia`: an Authelia container (`authelia/authelia:latest`, one user), forward auth on the pages but the open paths, every Firefox signs in to Authelia first. The admin UI also signs in with Authelia's header on `admin-sso.fxa.test` (`ADMIN_AUTH_HEADER`, `ADMIN_TRUSTED_PROXIES` the address of Caddy), and ignores a forged one on `admin.fxa.test`.

`SKIP_SETUP=1` leaves out the `prepare_environment.sh` checks, which these variants do not change. [admin.yml](/.github/workflows/admin.yml) runs both in `e2e-fxa`, on amd64 with MySQL. Locally: `tests/vm/vm.sh test 'CLIENT_CERT=1 SKIP_SETUP=1 e2e-fxa'`.

## Admin UI

What each script checks of the admin UI. The pages themselves: [The admin UI](../admin/README.md).

`tests/e2e-fxa.sh`, with [test_fxa_admin.py](/tests/test_fxa_admin.py), against the full stack:

- the SMTP health row and a test email; the public URLs through the HTTPS proxy and the sign-up gate (the probe creates no account with open sign-ups); the schema levels;
- invitations, Connect a device, the Configuration page (the accounts' values, no secret);
- sign-ups refused through the gate and directly, the allowlist, closing and reopening sign-ups;
- the accounts list, disabling an account, max users and max accounts (full: the gate, the database refusal, the line, the health row, the event and Prometheus; room again; no limit);
- `FXA_MAX_ACCOUNTS` like `SYNC_MAX_USERS`: written by `prepare_environment.sh`, refused when not valid, kept from the page with `initial:`, replaced by a plain number, `ffs.signup_refusal` with 0 and unlimited;
- what an account stores, the metrics and the event log, health and database sizes, the badges, rate-limit blocks lifted;
- signing out a session, a device of a session, a device of a refresh token, and everywhere (a new sign-in works at once); disabling also ends a password reset started before; the audit trail names the account and the admin; `ffs_admin` cannot delete FxA's tokens itself;
- the alerts by email (in the mail catcher) and to a webhook (`ADMIN_NOTIFY`, [notify_sink.py](/tests/notify_sink.py)), with the setup check of the accounts' SMTP server;
- Prometheus, the password and form checks, `X-Forwarded-For` spoofing, the confirm pages;
- two-step authentication on through the accounts API and off from the admin UI, recovery keys, secondary emails, an email confirmed from the admin UI;
- the security history (`FXA_ACCOUNT_EVENTS=true`): each kind of event, its alerts and Prometheus, then nothing more recorded once it is off;
- a Sync client after its data was reset, deleting an account (refused while enabled or with a wrong email; then gone everywhere), orphans purged, pruning and deleting old unconfirmed accounts;
- Needs attention, the badge lists, the search by part of an email and by account id;
- the backups of the accounts and of Sync (five dumps passing `gzip -t`, both runs recorded), the dump of `fxa` restored into a scratch database, and that `ffs_admin` reads the views but no secret column; with the accounts on MySQL, MariaDB and your own server.

A real Firefox ([test_fxa_browser.py](/tests/test_fxa_browser.py)) follows an invitation's link, sees the error of a refused sign-up, finds its two devices and bookmarks in the admin UI, checks the pages at 360 pixels wide, and disables the account through the confirm page with the CSP enforced.

`tests/e2e.sh` and `tests/podman.sh`, with [test_admin_sync.py](/tests/test_admin_sync.py):

- `SYNC_MAX_USERS=N`, `initial:N`, `unlimited` and `0`;
- `SYNC_ALLOWED_ACCOUNTS` ([test_sync_allowlist.py](/tests/test_sync_allowlist.py), `e2e.sh`): a listed uid syncs, an unlisted one is refused with its event and pending entry, approved in the admin UI it gets in, a keys change and an account from before the allowlist keep working, Reject, Allow a uid and Remove, with max users full, refused tries taken back from the node's load (by the admin UI, by the init container), the refusals' table engine per server (Aria, MyISAM, InnoDB where they are not recorded), no trigger while off, `initial:` kept and applied once, the cap of 1000 (rejected and unalerted ones kept, the dropped ones counted), a database of the branch's first version upgraded, a plain list read-only, the 5xx of a refusal, settings that are not valid stopping the init container; `podman.sh`: the question of `prepare_environment.sh`, kept by `--upgrade`, and the Quadlets' units with a refusal recorded;
- the admin UI and the gate start with compose and the Quadlets and reach every component (`ffs_up`); the container healthcheck; signing in over `http://localhost`;
- the Sync server's metrics (restarted with a new admin UI container), the pruning of metrics and events, the event filters and pages;
- labels, the tokenserver rows after a key change, resetting Sync data (one collection, all of it, the slot freed), the storage report and its purge, deleting the Sync data of an account id;
- the schema levels, the setup checks, the accounts per node, Connect a device, the Configuration page (no secret);
- no SMTP row without `FXA_SMTP_HOST`, no public checks with `ADMIN_PUBLIC_CHECK=false`, the alerts to a webhook and a Slack-style destination ([the webhook schema](../admin/alerts.md#webhook-schema)), the Sync server going down and back up, no background errors in the logs;
- with `COMPOSE_PROFILES=backup` and `BACKUP_KEEP=1`: two runs (one copy kept, the dumps passing `gzip -t`, mode 0600), a failed run and its alert, `ffs_backup_age_seconds`; the errors by kind and the error-rate and growth rows;
- an install from before `ADMIN_DB_PASSWORD` upgraded: the tables move into `ffs_admin` once, the old ones are dropped, and the Sync server's users cannot read, add to or delete from the event log (`e2e.sh`: MariaDB, MySQL, PostgreSQL and your own servers);
- `ffs_admin_sync` changes the tokenserver only through the init container's procedures, `ffs_admin_ui` cannot read the Sync databases, and a procedure the Sync server's user swaps in with `SQL SECURITY INVOKER` cannot reach the audit trail;
- at the end, a restore as [Restore](../backups.md#restore) says, as on a new host: every table has the same rows, the triggers and procedures are back, and two accounts read back what they stored (MariaDB, MySQL 8 and PostgreSQL). `tests/podman.sh` does the same for the Quadlets ([Restore with Quadlets](../backups.md#restore-with-quadlets)), and checks the backup timer and the admin UI units' variables.

`tests/e2e.sh` also signs in through [Dex](https://dexidp.io) with OpenID Connect and with a trusted header ([test_admin_auth.py](/tests/test_admin_auth.py)): an allowed user or group gets in; anybody else, a replayed callback, a tampered state or code are refused; a header that changes or disappears ends the session; forms need the session token; the event log says who signed in and how.

The unit tests (`cd admin && go test ./...`) cover the backups' age and failures, each line of Needs attention, the thresholds and limits alerting once per state, the errors by kind of real captured statsd packets ([admin/testdata/statsd-packets.jsonl](/admin/testdata/statsd-packets.jsonl)), the error-rate spike and growth rules, the limits' forms, the security history, each `ADMIN_NOTIFY` destination against a local server (escaping, length limits, retries, timeouts, no token in errors, logs or pages), that every POST form is behind a confirm page or a known one-click form, and that every variable the admin UI reads is classified as a secret or not.

## Helm chart

[tests/helm.sh](/tests/helm.sh) needs `helm`, `jq` and PyYAML. `lint` and `parity` also need `docker compose` (for its config only). `e2e` also needs `kind`, `kubectl` and docker, which builds the init and admin images and hands the syncstorage image to the cluster with `docker save`.

- `lint`: `helm lint` with each values file of [charts/firefox-sync/ci/](/charts/firefox-sync/ci), then checks of the renders: probes on every long-running container, the values the schema refuses, the database images and their major checks, the volumes' checks (`checkClaim` on the data a lookup returns), the Secret (generated, read back, `helm.sh/resource-policy: keep`, `existingSecret`), names over Kubernetes' limits, your own database server, the Ingresses, the backups' CronJob, what every pod has (no service account token, seccomp `RuntimeDefault`, nothing PodSecurity `baseline` refuses, the scheduling values, each `resources`), the NOTES, and [chart-version.sh](/.github/scripts/chart-version.sh). Then `parity`.
- `parity [case...]`: [helm_parity.py](/tests/helm_parity.py), the chart against compose: per compose service and chart container the same variables and values (hosts and secrets aside), the same commands, probes with the timings of compose's healthchecks, the same working directories, the copied scripts byte-identical, for each backend, with the admin UI and the backups on and off. The `fxa-*` cases add the self-hosted accounts (compose/fxa.yml): MySQL (lts and an 8 pin), MariaDB, your own server, and the Sync server on PostgreSQL. Every difference the chart has by design is an entry of one of its allowlists, with its reason and the cases it holds for; an entry no render of those cases uses fails.
- `e2e <mariadb|mysql|postgres>`: the chart on a throwaway kind cluster (`ffs-helm-<backend>`, its namespace enforcing PodSecurity `baseline`), with the init and admin images built from the tree (`SKIP_BUILD=1`: the published ones of `REPOSITORY` and `TAG`):
    - `helm install --wait`, the client flow, the database users' grants, a wrong database password stopping the pod in its init containers, `helm upgrade` keeping every secret; another major, backend or volume of the bundled databases (and the backups' PVC grown on a StorageClass without expansion) refused at render time;
    - the admin UI on and off with `helm upgrade`, signed in with the Secret's `ADMIN_PASSWORD` through a port-forward, the overview with the `kubectl` commands, `/metrics` with `admin.metricsToken`; its pod meets PodSecurity `restricted`;
    - a backup with `kubectl create job --from=cronjob/...`, its dumps restored with the commands of [Restore](../backups.md#restore) into empty database servers like the chart's (the MariaDB and PostgreSQL blocks, in that order). The steps of [Restore on Kubernetes](../backups.md#restore-on-kubernetes) as a whole were run by hand on kind, not in CI;
    - `helm uninstall` and `helm install` with the same release name and values: the same Secret and PVCs, and the client's Sync data read back.
- `EXTERNAL_DB=1` (mysql, postgres): on a database server of its own in the cluster, which the chart does not manage (`database.bundled=false`, `existingSecret`). With MySQL on an Ubuntu host with `mysql-server`, it stops first while the host's AppArmor profile for `mysqld` is loaded ([Troubleshooting](../troubleshooting.md#kubernetes)).

[helm.yml](/.github/workflows/helm.yml) runs `ct lint`, kubeconform with each `ci/` values file, `tests/helm.sh lint`, and `e2e` on MariaDB, MySQL and PostgreSQL, on your own MySQL and PostgreSQL server, and PostgreSQL on arm64: on every push that changes the chart, its tests, the compose files, `db/`, the backups, the admin UI or [docs/backups.md](../backups.md), and every week. Publishing the chart: [Releasing](releasing.md#the-helm-chart).

### The accounts in the chart

[tests/helm-fxa.sh](/tests/helm-fxa.sh) tests the chart with the self-hosted accounts (`fxa.enabled`).

- `fxa_lint`, which `tests/helm.sh lint` sources and runs before `parity`:
    - `helm lint` and `kubeconform -strict` of `ci/fxa-values.yaml`, `fxa-mariadb-values.yaml` and `fxa-external-values.yaml`;
    - the values refused, with their messages, and the schema's formats;
    - the generated Secret keys, and those an `existingSecret` must have;
    - every object of the accounts, against compose: env, commands, probes, the order of the init containers, the volumes and the users;
    - the Ingresses, the NetworkPolicies (`fxa.networkPolicy.servers` too), pairing, the backups' init container, the admin UI's accounts block, its derived client id, and the NOTES;
    - with `fxa.enabled=false`, the same objects as chart 0.1.0 at commit `PARITY_BASE` (`2512e9a`), from `git archive`. Without that commit (a copy without `.git`, a shallow clone), set `PARITY_BASE_CHART` to it extracted: `git archive 2512e9a charts/firefox-sync | tar -x -C <dir>`.
- `e2e <mysql|mariadb>`: the chart with the accounts on that backend, on a throwaway kind cluster (`ffs-helm-fxa-<backend>`, its namespace enforcing PodSecurity `baseline`). The Sync server is on the same backend, or on PostgreSQL with `SYNC_BACKEND=postgres`. It needs 15 GB free for docker. Its fixtures: Traefik as the Ingress controller, a test CA and a `*.fxa.test` certificate, CoreDNS sending `*.fxa.test` to Traefik, and Mailpit for the emails. It checks:
    - the install, the init containers in their order, the keys on their volume, the sign-up policy, Redis's password and the NetworkPolicies (kindnet enforces them): the public servers reached through Traefik and by the tests' pods (`extraFrom`), not by another pod;
    - a wrong `FXA_MYSQL_PASSWORD` keeping the auth server out of its Service; a backend switch, a database major and a volume change Kubernetes would refuse, refused at render time;
    - [test_fxa_flow.py](/tests/test_fxa_flow.py) through the Ingresses over HTTPS, the rate limits by client address through the Ingress, an uploaded avatar kept across a restart, and [test_fxa_pairing.py](/tests/test_fxa_pairing.py) in a browser through the pairing server's Ingress;
    - [test_fxa_admin.py](/tests/test_fxa_admin.py): the gate, signing in with the accounts, max accounts, health and the security history; then the admin UI turned off;
    - a backup of both scopes, and the accounts' `fxa` dump restored into a scratch database with the `restore()` and `restore restore-accounts` commands of [Restore on Kubernetes](../backups.md#restore-on-kubernetes), then all of them over the dropped databases; with `SYNC_BACKEND=postgres` also the Sync scope, with that page's PostgreSQL commands;
    - a new install with `fxa.volumeOwnerInit=false`.

    `REPOSITORY`, `TAG`, `FXA_IMAGE` and `FXA_VERSION` choose the images, as in `tests/e2e-fxa.sh`. The accounts database is `mysql:8` or `mariadb:11` when the accounts image lacks the patch for `lts` ([Upstream patches](../reference/images.md#upstream-patches)); `FXA_MYSQL_IMAGE` and `FXA_MARIADB_IMAGE` override that.

    `PART=main` runs the steps after the install up to Firefox, `PART=survival` the ones from `test_fxa_upgrade.py`'s before phase on (the upgrade, the refused policy, a new Redis pod, `helm uninstall` and `install`, the keys in `fxa.keys.existingSecret`, `fxa.volumeOwnerInit=false`, an `existingSecret` without the accounts' keys). Each part sets up its own cluster and install; empty runs both on one cluster.

[helm.yml](/.github/workflows/helm.yml) runs `fxa_lint` through `tests/helm.sh lint`, with the whole history for `git archive`, and the e2e (`e2e-fxa`) on MySQL with Firefox, MariaDB, your own MySQL server, MySQL with the Sync server on PostgreSQL, and MySQL with Firefox on arm64, each as two jobs, `PART=main` and `PART=survival` (your own server has no survival part).

## Docs that tests read

Some tests read commands from the docs and check them word for word, so a page and its commands stay in step. Change such a command only together with its test.

| Test | Page | What it reads |
|---|---|---|
| `tests/e2e.sh` | [backups.md](../backups.md#restore), [upgrading.md](../upgrading.md#postgresql) | the compose restore commands; with `PG_MAJOR_MOVE=1` the three steps of the PostgreSQL move |
| `tests/helm.sh` | [backups.md](../backups.md#restore) | the blocks starting `--entrypoint sh backup -c '` that contain `$TOKENSERVER_DB_NAME.sql.gz`: the first is MariaDB, the second PostgreSQL |
| `tests/helm-fxa.sh` | [backups.md](../backups.md#restore-on-kubernetes) | `restore() {` to its closing `}`, and the `restore restore-accounts 'run=` command to its line ending `backup-accounts`, both indented four spaces, each exactly once; with `SYNC_BACKEND=postgres` also the `for db in postgres; do` loop to its `done`, and the PostgreSQL block from `kubectl get deploy $F-syncstorage -o json | jq` to the `PGPASSWORD="$ADMIN_DB_PASSWORD" psql` line (two `restore restore-` commands) |
| `tests/podman.sh` | [backups.md](../backups.md#restore-with-quadlets), [upgrading.md](../upgrading.md#with-quadlets) | the `set -o pipefail` and `dump sync/$run/ffs_admin.sql.gz` lines, exactly once each; with `SYNC_DB=postgres` the PostgreSQL commands of the Quadlet restore, as written; the Quadlet `systemctl --user stop` line, exactly once; the Quadlet commands of [MariaDB](../upgrading.md#mariadb) and [MySQL 8 to 9](../upgrading.md#mysql-8-to-9) with `*_FROM` |
| `tests/podman.sh` | [migrating.md](../migrating.md#loading-into-firefox-sync) | the Quadlet loading: the `systemctl --user start` and `podman exec -i` commands, and the compose `docker compose exec -T <db>_db sh -c` lines it turns into the Quadlets' |
| `tests/migrate.sh` | [migrating.md](../migrating.md), [upgrading.md](../upgrading.md#the-earlier-firefox-sync-release) | every command it runs, with `grep -qF` in either page |

## Links

[tests/check_markdown_links.py](/tests/check_markdown_links.py) checks every tracked markdown file (but `tests/browser`):

- relative links, resolved from the file's directory, and repository-absolute ones (`/db/...`), resolved from the root;
- `#anchors`, against GitHub's slugs of the headings (outside code fences, from their rendered text, duplicates suffixed `-1`, `-2`) and `<a id>`/`<a name>`;
- absolute `https://github.com/porelli/firefox-sync/blob/main/...` URLs, against the tree.

With `--code` it also checks the doc references of the other tracked text files (`docs/....md#anchor`, or a bare `NAME.md`), such as the admin UI's help links, the scripts' messages and the chart's NOTES. With `--settings` it checks that every setting of [.env-example](/.env-example) and every top-level key of [values.yaml](/charts/firefox-sync/values.yaml) appears in [Settings](../reference/settings.md).

```bash
python3 -I tests/check_markdown_links.py --code --settings
python3 -I tests/test_check_markdown_links.py
```

[docs.yml](/.github/workflows/docs.yml) runs both, with `--code --settings`, on every push.

`--external` also fetches every `http(s)` link of `docs/` and `README.md` and lists those that don't end in a 2xx after redirects; a 401, 403 or 429 is only a warning, since it is often a bot wall. It needs the network, so CI does not run it: run it when you edit the docs' links. It only says that a page answers, not that it still says what the sentence claims.

## Docs coverage

[tests/check_docs_coverage.py](/tests/check_docs_coverage.py) checks that what the stack offers is on the page that documents it:

| What | From | Page |
|---|---|---|
| every Helm value, at every depth | the keys of [values.yaml](/charts/firefox-sync/values.yaml) | [Settings](../reference/settings.md) |
| every Prometheus metric of the admin UI | `# TYPE ffs_...` and `gauge("ffs_...")` in `admin/*.go` | [Prometheus](../admin/monitoring.md#prometheus) |
| every event kind | `eventKinds`, `event("<kind>", ...)` and `Event{Kind: ...}` | [Event log](../admin/monitoring.md#event-log) |
| every alert kind | `alertKinds`, `alert("<kind>", ...)`, `Event{Kind: ...}` and `Alert{Kind: ...}` | [Webhook schema](../admin/alerts.md#webhook-schema) |
| every setup check | `setupCheck{Name: ...}`, its name up to ` (` | [Setup checks](../admin/monitoring.md#setup-checks), in bold |

A Helm value is found by its dotted path in a code span (`` `fxa.signupAllowlist` ``). A span that starts with a dot goes on from the path before it on the same line (`` `database.persistence.size`, `.storageClass` ``), and `` `fxa.resources.*` `` covers everything under it. A map is covered by its keys. A value the chart hands to Kubernetes as it is, such as `resources` or `annotations`, is covered by its own path. The items of a list are not values of their own.

It prints each gap as the file and line of the code, what is missing and the page that should have it:

```text
admin/setup.go:158: setup check Old setting names is not in docs/admin/monitoring.md#setup-checks
```

```bash
python3 -I tests/check_docs_coverage.py
python3 -I tests/test_check_docs_coverage.py
```

[docs.yml](/.github/workflows/docs.yml) runs both on every push.

### Docs with the features

A change to a feature should come with its docs and its entry in [CHANGELOG.md](/CHANGELOG.md). [tests/check_docs_changed.py](/tests/check_docs_changed.py) warns when a branch changes a feature but no file under `docs/` and no `README.md`, and, a warning of its own, when it adds no entry under `## Unreleased` in CHANGELOG.md ([The changelog](releasing.md#the-changelog)). The features are `.env-example`, the chart's `values.yaml`, `admin/templates/`, `admin/*.go` (but the tests), `db/`, `compose/`, `config/quadlet/` and `setup/`.

On a push to another branch than the default one, docs.yml compares the push with the commit before it (with main for a new branch). The warnings are annotations of the run: they never fail it. By hand, it compares with the merge base of main:

```bash
python3 -I tests/check_docs_changed.py
python3 -I tests/check_docs_changed.py --base HEAD~3
python3 -I tests/test_check_docs_changed.py
```

When a change needs no docs (a refactor, a fix that changes nothing anybody sees), say so in a commit message of the push, on a line of its own, with the reason; the same for no changelog entry:

```text
Docs: none (a log line reworded)
Changelog: none (a log line reworded)
```

An entry counts when HEAD's Unreleased has it and the base's has not, as [release.py](/.github/scripts/release.py) reads the file (a list item; HTML comments are not entries), so an entry in a released section does not.

## Docs site

The pages of `docs/` are also a website, built with MkDocs and the Material theme from [mkdocs.yml](/mkdocs.yml). The markdown stays written for GitHub. [docs/hooks/repo_links.py](/docs/hooks/repo_links.py) bridges what MkDocs reads differently: it turns links to the code into GitHub URLs, re-indents the lists to 4 spaces, and renders `<details>` as collapsed blocks.

To preview it, with [docs/requirements.txt](/docs/requirements.txt) (the newest Material for MkDocs, as CI):

```bash
python3 -m venv /tmp/mkdocs-venv
/tmp/mkdocs-venv/bin/pip install -r docs/requirements.txt
/tmp/mkdocs-venv/bin/mkdocs serve      # http://127.0.0.1:8000, rebuilt on every save
```

docs.yml builds it on every push:

```bash
mkdocs build --strict
python3 -I tests/check_site_anchors.py
```

- `--strict` fails on any warning: a link to a missing page, file or `#anchor`, or a page left out of the `nav` of mkdocs.yml.
- [check_site_anchors.py](/tests/check_site_anchors.py) checks that every anchor the link checker computes with GitHub's rules is an id of the built page.

A new page goes into the `nav` too, in the place it has in [the index](../README.md). Pushes to the default branch publish the site on GitHub Pages, at <https://porelli.github.io/firefox-sync/> for this repository; other branches only build it. mkdocs.yml has the public site and repository; docs.yml gives the build those of the repository it runs in (`FFS_SITE_URL`, `FFS_REPO_URL`, `FFS_REPO_NAME`: `https://<owner>.github.io/<repo>/`), so a fork or a development repository publishes and links its own.

## The screenshot demo

The screenshots of the docs come from a demo, not from the leftovers of the tests.

1. Start it, with self-hosted accounts or with Mozilla's:

    ```bash
    DEMO=1 tests/e2e-fxa.sh     # demo_seed.py fxa: alice, bob and carol (two-step authentication on) with devices and Sync data, dave invited, an allowlist, a note, a backup
    DEMO=1 tests/e2e.sh mysql   # demo_seed.py sync: upstream's mock FxA, three account ids with Sync data and notes
    ```

    Instead of the tests, [tests/demo_seed.py](/tests/demo_seed.py) goes through the public flows (sign-ups with the codes from Mailpit, devices, OAuth, the tokenserver, Sync writes, with Firefox's user agents). Both leave the stack running ([tests/compose/demo.yml](/tests/compose/demo.yml) puts back the admin UI's defaults the tests shorten), and print where the admin UI listens. Its password is `ADMIN_PASSWORD` of the env file they name.
1. Take the pages in a browser at 1280×900 (390×844 for the phone; from another machine, through an ssh tunnel to those ports).
1. Quantize each PNG to 128 colours (Pillow) to stay well under 150 KB, and put it in [docs/images/admin/](/docs/images/admin).
1. Run `docker compose -p <project> down -v` with the project they named.
