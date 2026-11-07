#!/bin/bash
# affected.sh: the test jobs of .github/workflows/syncstorage-rs.yml that a change needs.
#
# Usage: git diff --name-only BASE HEAD | .github/scripts/affected.sh
#
# Reads the changed paths on stdin, one per line. Prints, for GITHUB_OUTPUT:
#   compose=true|false  job test        (tests/e2e.sh, the docker compose stack)
#   podman=true|false   job test-podman (tests/podman.sh, the Quadlets and compose on Podman)
#   fxa=true|false      job test-fxa    (tests/e2e-fxa.sh, the self-hosted accounts)
# and on stderr each path with the jobs it needs. No path at all: every job (an empty diff
# proves nothing). The workflow picks BASE, and runs every job anyway on main, on the
# schedule, by hand, and when an image is built: docs/development/testing.md#which-tests-a-push-runs
#
# THE MAPPING: the case below, first match wins. A path no pattern names needs every job, so a
# new file is tested by all of them until it is given a group here. When a test script starts
# to use a file (sources it, mounts it, reads it, runs a docs page's commands), move that file
# to a group with that job, or to "all". Erring towards a job is fine, leaving one out is not.
# tests/test_affected.sh has a case per group: add yours there too.
set -u

compose=false podman=false fxa=false all=false seen=0
while IFS= read -r path || [ -n "${path}" ]; do
  [ -n "${path}" ] || continue
  seen=1
  case "${path}" in
    # the docs pages whose commands the tests run word for word (docs/development/testing.md#docs-that-tests-read):
    # backups.md and upgrading.md tests/e2e.sh and tests/podman.sh, migrating.md tests/podman.sh
    docs/backups.md | docs/upgrading.md) jobs="compose podman" ;;
    docs/migrating.md) jobs="podman" ;;
    # the other docs, the docs site and the releases (the paths-ignore of the workflow; a push
    # with only these runs no workflow at all): no test of this workflow reads them
    *README.md | docs/* | mkdocs.yml | CHANGELOG.md | LICENSE | .gitignore \
      | .github/workflows/docs.yml | .github/workflows/release.yml | .github/scripts/release.py \
      | tests/check_*.py | tests/test_check_*.py | tests/test_release.py | tests/vm/*) jobs="" ;;
    # other workflows' tests, and the local-only ones: helm.yml (the chart), fxa.yml (the
    # accounts upgrade), docs.yml (the setup's output, its migrations, the proxy's
    # configuration), admin.yml; tests/migrate.sh runs in the local VM only. The unit tests
    # of prepare-env and changes run in those jobs on every push
    charts/* | tests/helm* | tests/fxa-upgrade.sh | tests/test_fxa_upgrade.py \
      | tests/setup_output.sh | tests/setup_tty.py | tests/setup_migrations.sh \
      | tests/proxy_render.sh | tests/proxy/* | tests/migrate.sh | tests/compose/migrate.yml \
      | tests/test_upstream_patches.py | tests/test_syncstorage_rs_build.py | tests/test_affected.sh \
      | .github/workflows/admin.yml | .github/workflows/fxa.yml | .github/workflows/helm.yml \
      | .github/scripts/chart-*.sh | .github/scripts/sync-app-version.sh) jobs="" ;;
    # this workflow and this script: every job
    .github/workflows/syncstorage-rs.yml | .github/scripts/affected.sh) jobs="all" ;;
    # the inputs of the images (the init images' db/<backend>/init/, the app's upstream patches
    # and the scripts that prepare its sources, the workflow's actions), and db/ as a whole
    # (the setup's SQL, db-setup.sh, the manifest every test checks): every job
    db/* | upstream-patches.yml | upstream-patches/* | .github/scripts/upstream-patches.py \
      | .github/scripts/syncstorage-rs-build.py | .github/actions/*) jobs="all" ;;
    # what every test sets up with: prepare_environment.sh and setup/, the settings, the base
    # compose files (Podman's too: tests/e2e-fxa.sh reads it), the admin UI (each test builds its
    # image from admin/), config/ but the Quadlets (setup/images.sh reads config/fxa/fixed-in,
    # setup.sh the systemd example), the helpers every end-to-end script sources: every job
    prepare_environment.sh | setup/* | .env-example | docker-compose*.yml | compose/sync*.yml \
      | compose/podman.yml | admin/* | config/backup/* | config/fxa/* | config/nginx/* \
      | config/systemd/* | tests/healthy.sh | tests/slot.sh) jobs="all" ;;
    # the Quadlets: tests/podman.sh only (and tests/prepare_functions.sh, which it runs, reads
    # every unit); Ubuntu's pasta profile is fixed for its job only
    config/quadlet/* | tests/podman.sh | tests/prepare_functions.sh \
      | .github/scripts/pasta-apparmor.sh) jobs="podman" ;;
    # the accounts' and the bundled Caddy's compose files: tests/e2e-fxa.sh runs them,
    # tests/podman.sh compares its Quadlets with them (prepare_functions.sh reads every
    # compose/*.yml); the check of the accounts images' fixes, sourced by both
    compose/fxa*.yml | compose/caddy.yml | tests/fxa_fix.sh) jobs="podman fxa" ;;
    # tests/e2e.sh only: its helpers, the Python tests it runs in the app container, its
    # compose override (and the Dex and the notification sink that override starts)
    tests/e2e.sh | tests/db_setup.sh | tests/fake_dump_1412.sh | tests/hung_syncserver.sh \
      | tests/migrate_client.py | tests/test_client_flow.py | tests/test_sync_allowlist.py \
      | tests/test_admin_sync.py | tests/test_admin_auth.py | tests/dex.yml \
      | tests/compose/sync.yml) jobs="compose" ;;
    # both docker compose tests, tests/e2e.sh and tests/e2e-fxa.sh: the test overrides both
    # use, the demo's data, pytest's conftest.py, the notification sink of both overrides
    tests/compose/admin-build.yml | tests/compose/demo.yml | tests/compose/external-db.yml \
      | tests/demo_seed.py | tests/conftest.py | tests/notify_sink.py) jobs="compose fxa" ;;
    # tests/e2e-fxa.sh only: its Python tests, the Firefox image, the access-control Caddy
    # snippets, its compose overrides (the accounts, your own server, the proxies)
    tests/e2e-fxa.sh | tests/test_fxa_access.py | tests/test_fxa_admin.py | tests/test_fxa_browser.py \
      | tests/test_fxa_flow.py | tests/test_fxa_pairing.py | tests/browser/* | tests/caddy/* \
      | tests/compose/fxa.yml | tests/compose/external-db-fxa.yml | tests/compose/proxy-*.yml) jobs="fxa" ;;
    # anything else (a new file, one no group names yet): every job
    *) jobs="all" ;;
  esac
  echo "${path}: ${jobs:-no test job}" >&2
  for j in ${jobs}; do
    case "${j}" in
      all) all=true ;;
      compose) compose=true ;;
      podman) podman=true ;;
      fxa) fxa=true ;;
    esac
  done
done
if [ "${seen}" = 0 ]; then
  echo "no changed path: every job" >&2
  all=true
fi
if [ "${all}" = true ]; then
  compose=true podman=true fxa=true
fi
printf 'compose=%s\npodman=%s\nfxa=%s\n' "${compose}" "${podman}" "${fxa}"
