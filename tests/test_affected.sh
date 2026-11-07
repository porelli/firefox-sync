#!/bin/bash
# Unit tests of .github/scripts/affected.sh: the test jobs of syncstorage-rs.yml a change
# needs, a case per group of its mapping, and every tracked file classified without error.
#
# Usage: bash tests/test_affected.sh
set -u

CODE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
AFFECTED=${CODE}/.github/scripts/affected.sh
FAILED=0

# expect "<compose> <podman> <fxa>" <path>...: the jobs for a change of these paths
expect() {
  local want=$1 got
  shift
  got=$(printf '%s\n' "$@" | bash "${AFFECTED}" 2> /dev/null | sed 's/^[a-z]*=//' | paste -sd' ' -)
  if [ "${got}" = "${want}" ]; then
    echo "PASS: $* -> ${want}"
  else
    echo "FAIL: $* (expected '${want}', got '${got}')"
    FAILED=1
  fi
}
ALL="true true true" NONE="false false false"

# every job: the workflow, this script, the images' inputs, what every test sets up with
expect "${ALL}" .github/workflows/syncstorage-rs.yml
expect "${ALL}" .github/scripts/affected.sh
expect "${ALL}" db/mysql/init/Dockerfile
expect "${ALL}" db/setup-manifest
expect "${ALL}" upstream-patches.yml
expect "${ALL}" upstream-patches/syncstorage-rs/some.patch
expect "${ALL}" .github/scripts/upstream-patches.py
expect "${ALL}" .github/scripts/syncstorage-rs-build.py
expect "${ALL}" .github/actions/find-head/action.yml
expect "${ALL}" prepare_environment.sh
expect "${ALL}" setup/quadlets.sh
expect "${ALL}" .env-example
expect "${ALL}" docker-compose.yml
expect "${ALL}" compose/sync.yml
expect "${ALL}" compose/sync-postgres.yml
expect "${ALL}" compose/podman.yml
expect "${ALL}" admin/main.go
expect "${ALL}" config/fxa/fixed-in
expect "${ALL}" config/backup/backup.sh
expect "${ALL}" config/systemd/syncstorage-rs-example.service
expect "${ALL}" tests/healthy.sh
expect "${ALL}" tests/slot.sh
# a path no group names, and no path at all
expect "${ALL}" some/new/file.sh
expect "${ALL}" tests/test_something_new.py
expect "${ALL}"

# the Quadlets
expect "false true false" config/quadlet/firefox-sync-syncstorage.container
expect "false true false" config/quadlet/fxa/admin/firefox-sync-admin.container
expect "false true false" tests/podman.sh
expect "false true false" tests/prepare_functions.sh
expect "false true false" .github/scripts/pasta-apparmor.sh
expect "false true false" docs/migrating.md
# the accounts' and Caddy's compose files
expect "false true true" compose/fxa.yml
expect "false true true" compose/fxa-mariadb.yml
expect "false true true" compose/caddy.yml
expect "false true true" tests/fxa_fix.sh
# tests/e2e.sh and tests/podman.sh read these pages
expect "true true false" docs/backups.md
expect "true true false" docs/upgrading.md
# tests/e2e.sh only
expect "true false false" tests/e2e.sh
expect "true false false" tests/compose/sync.yml
expect "true false false" tests/db_setup.sh
expect "true false false" tests/test_client_flow.py
expect "true false false" tests/dex.yml
# both docker compose tests
expect "true false true" tests/compose/demo.yml
expect "true false true" tests/compose/admin-build.yml
expect "true false true" tests/conftest.py
expect "true false true" tests/notify_sink.py
# tests/e2e-fxa.sh only
expect "false false true" tests/e2e-fxa.sh
expect "false false true" tests/test_fxa_flow.py
expect "false false true" tests/browser/Dockerfile
expect "false false true" tests/caddy/mtls/admin.caddy
expect "false false true" tests/compose/proxy-traefik.yml
expect "false false true" tests/compose/fxa.yml
# no job: docs, other workflows' tests
expect "${NONE}" README.md
expect "${NONE}" config/quadlet/README.md
expect "${NONE}" docs/development/testing.md
expect "${NONE}" docs/databases.md
expect "${NONE}" CHANGELOG.md
expect "${NONE}" charts/firefox-sync/values.yaml
expect "${NONE}" tests/helm.sh
expect "${NONE}" tests/helm/lib.sh
expect "${NONE}" tests/test_fxa_upgrade.py
expect "${NONE}" tests/proxy/wildcard-one/settings
expect "${NONE}" tests/test_affected.sh
expect "${NONE}" .github/workflows/helm.yml

# the union of the groups
expect "false true false" config/quadlet/firefox-sync-backup.container README.md
expect "true true false" config/quadlet/firefox-sync-backup.container tests/compose/sync.yml
expect "true true true" tests/e2e.sh tests/e2e-fxa.sh tests/podman.sh
expect "${ALL}" tests/e2e.sh charts/firefox-sync/values.yaml prepare_environment.sh
# a last line without a newline still counts
got=$(printf 'README.md\ntests/podman.sh' | bash "${AFFECTED}" 2> /dev/null | paste -sd' ' -)
if [ "${got}" = "compose=false podman=true fxa=false" ]; then echo "PASS: last line without a newline"; else echo "FAIL: last line without a newline (got '${got}')"; FAILED=1; fi

# every tracked file: classified, three lines of output, and each path said on stderr
if files=$(git -C "${CODE}" ls-files 2> /dev/null) && [ -n "${files}" ]; then
  err=$(mktemp)
  out=$(printf '%s\n' "${files}" | bash "${AFFECTED}" 2> "${err}")
  if [ "$(grep -c '^\(compose\|podman\|fxa\)=\(true\|false\)$' <<< "${out}")" = 3 ] \
    && [ "$(wc -l < "${err}" | tr -d ' ')" = "$(wc -l <<< "${files}" | tr -d ' ')" ]; then
    echo "PASS: every tracked file classified"
  else
    echo "FAIL: every tracked file classified"; cat "${err}"; FAILED=1
  fi
  rm -f "${err}"
fi

[ "${FAILED}" = 0 ] && echo "all passed"
exit "${FAILED}"
