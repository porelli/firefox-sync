# shellcheck shell=bash disable=SC2034 # (used by the tests that source it)
# Runs of the tests next to each other on one host, sourced by the tests first.
# SLOT (default 0) gives a run its own compose projects, host ports and networks: 0 keeps
# the names, ports and networks the tests always had; 1, 2... add -s<SLOT> to the project
# names, 1000 * SLOT to the host ports and 10 * SLOT to the third byte of the test
# networks, so that the runs of different slots do not meet. Within one slot each suite
# has its own project, ports and networks already (tests/e2e.sh mysql and postgres, ...).
SLOT=${SLOT:-0}
case "${SLOT}" in '' | *[!0-9]*) echo "SLOT: a number, not ${SLOT}"; exit 2 ;; esac
SLOT_SUFFIX=""
[ "${SLOT}" = 0 ] || SLOT_SUFFIX=-s${SLOT}
SLOT_PORTS=$((SLOT * 1000))
SLOT_NET=$((SLOT * 10))

# RENAMED_SETTINGS of prepare_environment.sh (setup/env.sh): the settings renamed to the SYNC_ prefix, new=old
eval "$(sed -n '/^RENAMED_SETTINGS=(/,/^)/p' "$(dirname -- "${BASH_SOURCE[0]}")/../setup/env.sh")"
# REPOSITORY, given to the tests (the images under test, vm.sh), is also the old name of
# IMAGE_REPOSITORY: kept out of compose's environment, which would take it for a setting of
# .env (and list it as an old name); POSTGRES_IMAGE (tests/db_setup.sh's) out of it too
export -n REPOSITORY POSTGRES_IMAGE

# slot_fxa_ports <env file>: the host ports of the accounts' services, the admin UI and the
# sign-up gate, which the tests with the accounts leave at those of .env-example, of their
# own in slots other than 0 (28700-28706 + SLOT_PORTS)
slot_fxa_ports() {
  [ "${SLOT}" = 0 ] && return
  local p=$((28700 + SLOT_PORTS))
  sed -i -e "s|^ADMIN_EXPORT_PORT=.*|ADMIN_EXPORT_PORT=127.0.0.1:${p}|" \
    -e "s|^ADMIN_GATE_EXPORT_PORT=.*|ADMIN_GATE_EXPORT_PORT=127.0.0.1:$((p + 1))|" \
    -e "s|^FXA_PAIRING_EXPORT_PORT=.*|FXA_PAIRING_EXPORT_PORT=127.0.0.1:$((p + 2))|" \
    -e "s|^FXA_CONTENT_EXPORT_PORT=.*|FXA_CONTENT_EXPORT_PORT=127.0.0.1:$((p + 3))|" \
    -e "s|^FXA_AUTH_EXPORT_PORT=.*|FXA_AUTH_EXPORT_PORT=127.0.0.1:$((p + 4))|" \
    -e "s|^FXA_PROFILE_EXPORT_PORT=.*|FXA_PROFILE_EXPORT_PORT=127.0.0.1:$((p + 5))|" \
    -e "s|^FXA_PROFILE_STATIC_EXPORT_PORT=.*|FXA_PROFILE_STATIC_EXPORT_PORT=127.0.0.1:$((p + 6))|" "$1"
}

# one_at_a_time <name> <command...>: the command, while no other run of the host runs one
# under that name (flock, where there is one): builds of the same image tag at the same
# time fail ("image ... already exists")
one_at_a_time() {
  local name=$1
  shift
  if command -v flock > /dev/null; then
    flock "${TMPDIR:-/tmp}/ffs-test-${name}.lock" "$@"
  else
    "$@"
  fi
}

# src_hash <dir>: a hash of the files of a folder (an image's build context): the same
# files, the same hash
src_hash() {
  (cd -- "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -c1-12)
}

# pytest_sh <pytest arguments> [command on failure]: the sh command that runs pytest in a
# container (from /app), its output in /tmp/pytest.log: the end of it when it passes, all of
# it when it fails, each traceback short (the end alone lost the assertion of the first
# failure), then the command on failure; its exit status that of pytest
pytest_sh() {
  echo "python3 -m pytest -q -p no:cacheprovider --tb=short $1 > /tmp/pytest.log 2>&1; rc=\$?; if [ \$rc = 0 ]; then tail -25 /tmp/pytest.log; else cat /tmp/pytest.log; ${2:-:}; fi; exit \$rc"
}

# load_env <file>: export the settings of a .env as docker compose reads them, not as bash
# would (sourcing it runs an unquoted value with spaces, FXA_MYSQL_ARGS=--a --b, as a command):
# NAME=value lines (optionally indented or after export), the value without a ' #' comment, or
# inside matching single (literal) or double quotes
load_env() {
  local line name value
  while IFS= read -r line || [ -n "${line}" ]; do
    line=${line%$'\r'}
    [[ "${line}" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    name=${BASH_REMATCH[2]} value=${BASH_REMATCH[3]}
    if [[ "${value}" =~ ^\'(.*)\'[[:space:]]*(#.*)?$ ]] || [[ "${value}" =~ ^\"(.*)\"[[:space:]]*(#.*)?$ ]]; then
      value=${BASH_REMATCH[1]}
    else
      value=${value%%[[:space:]]#*}
      value=${value%"${value##*[![:space:]]}"}
    fi
    export "${name}=${value}"
  done < "$1"
}
