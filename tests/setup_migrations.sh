#!/bin/bash
# The setup migrations of db/<engine>/setup/<scope>/ (db/db-setup.sh) against db/setup-manifest:
#   - every file has its line there, with its sha256, and every line its file: a released file
#     is never edited nor removed, a new one appends its line;
#   - against the manifest of BASE (default origin/main, else main; none: skipped): each of its
#     lines is still there, unchanged (what a release shipped stays as it was);
#   - the names NNN-name.sql, numbered from 001 without a gap in each scope; the accounts' on
#     MySQL and on MariaDB (fxa-mysql, fxa-mariadb) the same numbers and names;
#   - the copies of the manifest (the init images', the admin UI's) identical to it;
#   - the chart's copies of the files (charts/firefox-sync/files/db/) identical to them.
#
# Usage: tests/setup_migrations.sh            (bash 3.2, macOS, too; no server, seconds)
#        tests/setup_migrations.sh --update   the lines of the files BASE does not have written
#                                             again (a file of this branch, not released yet),
#                                             the copies with them
# Environment: BASE (the git ref of the released manifest)
set -u
TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CODE=$(dirname "${TESTS}")
DB=${CODE}/db
MANIFEST=${DB}/setup-manifest
COPIES="db/mysql/init/setup-manifest db/postgres/init/setup-manifest admin/setup-manifest"
FAILED=0
bad() { echo "FAIL: $*"; FAILED=1; }
sum256() { if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f 1; else shasum -a 256 "$1" | cut -d ' ' -f 1; fi; }
files() { (cd "${DB}" && ls -1 ./*/setup/*/*.sql 2> /dev/null | sed -e 's|^\./||' | sort); }

# the released manifest
BASE=${BASE:-}
if [ -z "${BASE}" ]; then
  for ref in origin/main main; do
    git -C "${CODE}" rev-parse -q --verify "${ref}^{commit}" > /dev/null 2>&1 && { BASE=${ref}; break; }
  done
fi
RELEASED=""
if [ -n "${BASE}" ]; then
  RELEASED=$(git -C "${CODE}" show "${BASE}:db/setup-manifest" 2> /dev/null | grep -v '^#' | grep -v '^$')
fi

if [ "${1:-}" = --update ]; then
  {
    grep '^#' "${MANIFEST}"
    for f in $(files); do
      line=$(grep "^${f} " <<< "${RELEASED}")
      if [ -n "${line}" ]; then echo "${line}"; else echo "${f} $(sum256 "${DB}/${f}")"; fi
    done
  } > "${MANIFEST}.new" && mv "${MANIFEST}.new" "${MANIFEST}"
  for copy in ${COPIES}; do cp "${MANIFEST}" "${CODE}/${copy}"; done
  echo "db/setup-manifest and its copies written again (the lines of ${BASE:-no base}: as they were)"
fi

lines=$(grep -v '^#' "${MANIFEST}" | grep -v '^$')
# every file has its line, with its checksum
for f in $(files); do
  line=$(grep "^${f} " <<< "${lines}")
  if [ -z "${line}" ]; then bad "${f} has no line in db/setup-manifest (tests/setup_migrations.sh --update appends it)"; continue; fi
  [ "${line#* }" = "$(sum256 "${DB}/${f}")" ] || bad "${f} is not the file of db/setup-manifest: a released file never changes, a change is a new file"
done
# every line its file
while read -r f sum; do
  [ -n "${f}" ] || continue
  [ -f "${DB}/${f}" ] || bad "db/setup-manifest has ${f}, which is gone: a released file stays"
  [[ "${sum}" =~ ^[0-9a-f]{64}$ ]] || bad "db/setup-manifest: no sha256 for ${f}"
done <<< "${lines}"
[ "$(cut -d ' ' -f 1 <<< "${lines}" | sort | uniq -d)" = "" ] || bad "db/setup-manifest names a file twice"
# what BASE released is still there, unchanged
if [ -n "${RELEASED}" ]; then
  while IFS= read -r line; do
    grep -qxF "${line}" <<< "${lines}" || bad "db/setup-manifest of ${BASE} has '${line}', which changed or went: a released file never changes"
  done <<< "${RELEASED}"
  echo "checked against the manifest of ${BASE} ($(wc -l <<< "${RELEASED}" | tr -d ' ') released files)"
else
  echo "no released manifest (BASE ${BASE:-not found}): only the files against db/setup-manifest"
fi
# the names and numbers of each scope
for dir in "${DB}"/*/setup/*/; do
  scope=${dir#"${DB}"/} scope=${scope%/}
  expected=1
  for f in "${dir}"*; do
    name=${f##*/}
    [[ "${name}" =~ ^([0-9]{3})-[a-z0-9-]+\.sql$ ]] || { bad "${scope}/${name}: not NNN-name.sql"; continue; }
    [ "$((10#${BASH_REMATCH[1]}))" = "${expected}" ] || bad "${scope}/${name}: number $((10#${BASH_REMATCH[1]})), expected ${expected} (from 001, no gap, none twice)"
    expected=$((10#${BASH_REMATCH[1]} + 1))
    head -n 1 "${f}" | grep -q "^-- Setup migration ${BASH_REMATCH[1]}, scope " || bad "${scope}/${name}: its first line is not '-- Setup migration ${BASH_REMATCH[1]}, scope <scope>: ...' (why, which release, by hand: the header of docs/databases.md#setup-migrations)"
  done
done
[ "$(ls -1 "${DB}/mysql/setup/fxa-mysql")" = "$(ls -1 "${DB}/mysql/setup/fxa-mariadb")" ] \
  || bad "the accounts' setup migrations of MySQL and MariaDB differ in their names: $(diff <(ls -1 "${DB}/mysql/setup/fxa-mysql") <(ls -1 "${DB}/mysql/setup/fxa-mariadb") | tr '\n' ' ')"
# the copies
for copy in ${COPIES}; do
  cmp -s "${MANIFEST}" "${CODE}/${copy}" || bad "${copy} is not db/setup-manifest (cp db/setup-manifest ${copy}, or --update)"
done
for f in $(files); do
  cmp -s "${DB}/${f}" "${CODE}/charts/firefox-sync/files/db/${f}" || bad "charts/firefox-sync/files/db/${f} is not db/${f} (the chart's copy)"
done
for f in $(cd "${CODE}/charts/firefox-sync/files/db" 2> /dev/null && ls -1 ./*/setup/*/*.sql | sed -e 's|^\./||'); do
  [ -f "${DB}/${f}" ] || bad "charts/firefox-sync/files/db/${f} has no db/${f}"
done

if [ "${FAILED}" = 0 ]; then echo "RESULT setup_migrations: all checks passed"; else echo "RESULT setup_migrations: some checks FAILED"; fi
exit "${FAILED}"
