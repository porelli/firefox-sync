#!/bin/bash
# (the tables are .env lines as written: their $ and quotes are literal; the copies of the script
# made here are not there to follow; PATH set for a subshell on purpose; ls of the files made here)
# shellcheck disable=SC2016,SC1003,SC1091,SC2030,SC2031,SC2012
# The functions of prepare_environment.sh (setup/*.sh) that need no container, on tables, per
# file: setup/env.sh (the values of .env as compose reads them, env_plain; .env written through a
# symlink, replace_env; the substitutions without the values on a command line, sed_script and
# sed_escape; the compose files of an install), setup/validate.sh (the addresses of
# SYNC_EXPORT_PORT, the limits, names, hosts and ports), setup/databases.sh (database-setup.sql),
# setup/images.sh (whether an accounts image has a fix of upstream-patches.yml, fxa_has_fix and
# config/fxa/fixed-in), setup/quadlets.sh (the checkout the units were rendered from),
# setup/upgrade.sh (--upgrade of an .env from before), and the script loading setup/ from its
# real path. The script is sourced: its functions only, nothing asked or written. No container runtime needed; with docker compose
# (COMPOSE=1, or found) the .env table is also compared with what `docker compose config` reads.
#
# Usage: tests/prepare_functions.sh   (bash 3.2, macOS, too)
set -u

TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CODE=$(dirname "${TESTS}")
WORK=$(mktemp -d)
trap 'chmod -R u+w "${WORK}" 2> /dev/null; rm -rf "${WORK}"' EXIT
FAILED=0
check() { if [ "$1" = "$2" ]; then echo "PASS: $3"; else echo "FAIL: $3 (expected '$2', got '$1')"; FAILED=1; return 1; fi; }

# sed_script's files there
export TMPDIR=${WORK}/tmp
mkdir -p "${TMPDIR}"
# shellcheck source=prepare_environment.sh
source "${CODE}/prepare_environment.sh" || { echo "FAIL: source prepare_environment.sh"; exit 1; }
check "$(type -t env_plain) $(type -t valid_export_port) $(type -t replace_env) $(type -t fxa_has_fix)" "function function function function" \
  "prepare_environment.sh sourced: its functions, nothing run"

echo "== setup/env.sh: .env values as compose reads them (env_plain)"
# "<line of .env> => <value compose reads>"; no $NAME in them, which compose would replace
# with another value (env_plain does not)
ENV_CASES=(
  'A01=plain => plain'
  'A02=plain # comment => plain'
  'A03=plain#nocomment => plain#nocomment'
  'A04="dq # not comment" # comment => dq # not comment'
  "A05='sq # x' # c => sq # x"
  'A06="a\"b" => a"b'
  'A07="a\\b" => a\b'
  $'A08="a\\nb" => a\nb'
  "A09='a\\'b' => a'b"
  "A10='a\\nb' => a\\nb"
  'A11="a$$b" => a$b'
  'A12="a\$b" => a$b'
  $'A13="x\\ty" => x\ty'
  'A14=  spaced   => spaced'
  "A15=\"a'b\" => a'b"
  "A16='a\"b' => a\"b"
  'A17="a&b|c/d#e" => a&b|c/d#e'
  'A18=a\b => a\b'
  'export A20=exp => exp'
  '  A21=indented => indented'
  'A23= => '
  'A24="" => '
  'A25="a\\" => a\'
  'A26="a\\\"b" => a\"b'
  "A28='a\\\\b' => a\\\\b"
  'A29=a "b" => a "b"'
  'A30=x$$y => x$y'
  "A31='x\$y' => x\$y"
  'A32="x\\\\y" => x\\y'
  "A33=\"q\\'s\" => q\\'s"
  "A34='d\\\"q' => d\\\"q"
  'A35=a\"b => a\"b'
  'A36="  pad  " =>   pad  '
  'A37="a" # c "b" => a'
  'A38=a #c => a'
  $'A39=a\t#tab => a\t#tab'
  "A41='p@ss|w&rd\\#1 \$x' => p@ss|w&rd\\#1 \$x"
  'A42="a&b|c/d\\e" => a&b|c/d\e'
)
: > "${WORK}/.env"
for c in "${ENV_CASES[@]}"; do printf '%s\n' "${c% => *}" >> "${WORK}/.env"; done
# (the line ends of Windows too)
printf 'A43=crlf\r\nA44="crlf"\r\n' >> "${WORK}/.env"
ENV_CASES+=('A43=crlf => crlf' 'A44="crlf" => crlf')
SCRIPT_DIR=${WORK}
compose_json=""
if [ "${COMPOSE:-}" = 1 ] || { [ -z "${COMPOSE:-}" ] && docker compose version > /dev/null 2>&1; }; then
  { echo "services:"; echo "  t:"; echo "    image: busybox"; echo "    environment:"
    for c in "${ENV_CASES[@]}"; do n=${c%%=*}; n=${n##* }; echo "      ${n}: \${${n}}"; done; } > "${WORK}/compose.yml"
  compose_json=$(cd "${WORK}" && env -i PATH="${PATH}" HOME="${HOME}" docker compose -p ffs-env-parse -f compose.yml config --format json 2>&1) \
    || { echo "FAIL: docker compose config of the table: ${compose_json}"; FAILED=1; compose_json=""; }
fi
for c in "${ENV_CASES[@]}"; do
  line=${c% => *} want=${c#* => }
  name=${line%%=*} name=${name##* }
  got=$(env_plain "${name}"; echo x); got=${got%x}
  check "${got}" "${want}" "env_plain: ${line}"
  if [ -n "${compose_json}" ]; then
    # (compose's config writes a $ of a value as $$)
    from_compose=$(printf '%s' "${compose_json}" | python3 -c 'import json, sys; print(json.load(sys.stdin)["services"]["t"]["environment"][sys.argv[1]].replace("$$", "$"), end="")' "${name}"; echo x)
    check "${from_compose%x}" "${want}" "docker compose reads ${line} as the table says"
  fi
done
[ -n "${compose_json}" ] || echo "(no docker compose: the table only)"
# what the setup writes in double quotes reads back as it was (env_dq)
sender='Mozilla "accounts" \ $HOME <no-reply@example.org>'
printf 'S1="%s"\n' "$(env_dq "${sender}")" > "${WORK}/.env"
check "$(env_plain S1)" "${sender}" "a value written with env_dq reads back as it was"

echo "== setup/validate.sh: the address and port of SYNC_EXPORT_PORT (valid_export_port)"
for p in 5000 1 65535 127.0.0.1:5000 0.0.0.0:5000 255.255.255.255:80 '[::]:5000' '[::1]:5000' '[fe80::1]:443' \
  '[2001:db8::8a2e:370:7334]:5000' '[2001:db8:0:0:0:0:2:1]:5000' '[1:2:3:4:5:6:7::]:5000' '[::ffff:192.0.2.1]:5000' '[64:ff9b::192.0.2.33]:80'; do
  check "$(valid_export_port "${p}" && echo valid)" valid "valid_export_port accepts ${p}"
done
for p in "" 0 65536 123456 abc localhost:5000 256.1.1.1:5000 1.2.3:5000 1.2.3.4.5:5000 :5000 '[:]:5000' '[:::]:5000' '[::]' '[]:5000' \
  '[1::2::3]:5000' '[12345::]:5000' '[1:2:3:4:5:6:7:8:9]:5000' '[1:2:3:4:5:6:7]:5000' '[1:2:3:4:5:6:7:8::]:5000' '[:1::]:5000' '[1::2:]:5000' \
  '[::g]:5000' '[::1.2.3]:5000' '[::256.1.1.1]:5000' '[1.2.3.4]:5000' '[::1]:0' '[::1]:70000' '::1:5000' '[::1]5000'; do
  check "$(valid_export_port "${p}" || echo refused)" refused "valid_export_port refuses '${p}'"
done

echo "== setup/env.sh: .env written through a symlink (replace_env)"
mkdir -p "${WORK}/real" "${WORK}/dir" "${WORK}/ro"
mode() { stat -c %a "$1" 2> /dev/null || stat -f %Lp "$1"; }
new_env() { (umask 077; printf 'NEW=%s\n' "$1" > "${WORK}/dir/.env.new"); }
printf 'OLD=1\n' > "${WORK}/real/env"; chmod 644 "${WORK}/real/env"
ln -s ../real/env "${WORK}/dir/.env"
new_env 1; replace_env "${WORK}/dir/.env.new" "${WORK}/dir/.env"
check "$? $([ -L "${WORK}/dir/.env" ] && echo link) $(cat "${WORK}/real/env") $(mode "${WORK}/real/env") $(find "${WORK}/dir/.env.new" "${WORK}/real" -name ".env*" 2> /dev/null | wc -l | tr -d ' ')" \
  "0 link NEW=1 600 0" "a relative symlink stays one, its target replaced, 0600, nothing left aside"
# a symlink to a symlink, absolute
ln -s "${WORK}/dir/.env" "${WORK}/dir/.env2"
new_env 2; replace_env "${WORK}/dir/.env.new" "${WORK}/dir/.env2"
check "$([ -L "${WORK}/dir/.env2" ] && [ -L "${WORK}/dir/.env" ] && echo links) $(cat "${WORK}/real/env")" "links NEW=2" "a chain of symlinks: the file at its end replaced"
# the target's directory not writable: the content written into the file
printf 'OLD=1\n' > "${WORK}/ro/env"; ln -s "${WORK}/ro/env" "${WORK}/dir/.env3"; chmod 555 "${WORK}/ro"
new_env 3; replace_env "${WORK}/dir/.env.new" "${WORK}/dir/.env3"
check "$? $([ -L "${WORK}/dir/.env3" ] && echo link) $(cat "${WORK}/ro/env") $(mode "${WORK}/ro/env")" "0 link NEW=3 600" \
  "the target's directory not writable: its content replaced in place, 0600"
chmod 755 "${WORK}/ro"
# a plain file: renamed over it
printf 'OLD=1\n' > "${WORK}/dir/plain"
new_env 4; replace_env "${WORK}/dir/.env.new" "${WORK}/dir/plain"
check "$([ -L "${WORK}/dir/plain" ] || echo file) $(cat "${WORK}/dir/plain") $(mode "${WORK}/dir/plain")" "file NEW=4 600" "a plain .env: replaced by the new file"

echo "== setup/env.sh, setup/databases.sh: substitutions with the values in a file, not on the command line (sed_script, sed_escape, render_sql)"
tricky='a&b|c/d\e"f'"'"'g$h#i%j'
printf 'X=@V@ %%V%%\n' > "${WORK}/template"
check "$(sed_script "s|@V@|$(sed_escape "${tricky}")|g" "${WORK}/template")" "X=${tricky} %V%" "sed_script with sed_escape: & | / \\ quotes \$ # % as they are"
two_lines=$'one\ntwo'
check "$(sed_script "s|@V@|$(sed_escape "${two_lines}")|g" "${WORK}/template")" "X=one
two %V%" "sed_escape: a line break in the value"
check "$(find "${TMPDIR}" -type f | wc -l | tr -d ' ')" 0 "sed_script leaves no script behind"
# the script's file is this user's only while sed runs
check "$(s=$(mktemp "${TMPDIR}/ffs-sed.XXXXXX"); mode "${s}"; rm -f "${s}")" 600 "mktemp's files (sed_script's): 0600"
# no value on sed's command line: the arguments sed gets, as ps shows them
mkdir -p "${WORK}/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s/argv\nexec %s "$@"\n' "${WORK}" "$(command -v sed)" > "${WORK}/bin/sed"; chmod +x "${WORK}/bin/sed"
secret=ffsSECRETvalue
(PATH=${WORK}/bin:${PATH}; printf 'P=x\n' > "${WORK}/plain"; apply_sed "${WORK}/plain" "s|^P=.*|P=${secret}|"
  render_sql "${WORK}/template" "${WORK}/out.sql" V="${secret}")
check "$(grep -c "${secret}" "${WORK}/argv") $(cat "${WORK}/plain") $(cut -d' ' -f1 "${WORK}/out.sql") $(mode "${WORK}/out.sql")" "0 P=${secret} X=${secret} 600" \
  "apply_sed and render_sql: the value written, never in sed's arguments"

# stopped while sed runs (TERM, INT): its script removed all the same, and a trap of before
# (EXIT) still runs after
printf '#!/bin/sh\nsleep 2\n' > "${WORK}/bin/sed"; chmod +x "${WORK}/bin/sed"
for sig in TERM INT; do
  TMPDIR=${WORK}/stop-${sig}; mkdir -p "${TMPDIR}"
  TMPDIR=${TMPDIR} bash -c 'trap "echo before > \"${TMPDIR}/../before-$1\"" EXIT; source "$0"; PATH=$2:${PATH}; sed_script "s/x/y/" /dev/null' \
    "${CODE}/prepare_environment.sh" "${sig}" "${WORK}/bin" &
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -n "$(find "${TMPDIR}" -type f)" ] && break; sleep 0.2; done
  during=$(find "${TMPDIR}" -type f | wc -l | tr -d ' ')
  kill -s "${sig}" "${pid}"; wait "${pid}"
  check "${during} $(find "${TMPDIR}" -type f | wc -l | tr -d ' ') $(cat "${WORK}/before-${sig}" 2> /dev/null)" "1 0 before" \
    "a ${sig} while sed runs: its script removed, the EXIT trap of before kept"
done
TMPDIR=${WORK}/tmp

echo "== setup/images.sh: accounts images with a fix of upstream-patches.yml (fxa_has_fix, config/fxa/fixed-in)"
has() { fxa_has_fix "$@"; echo $?; }
check "$(fxa_fixed_in mozilla/fxa#21554)|$(fxa_fixed_in mozilla/fxa#21494)" "|" "config/fxa/fixed-in: no release has them yet"
LABEL='mozilla/fxa#21494@3e2cb67..0eaa3a2 mozilla/fxa#21554@3e2cb67..84d71e2+v1.347.3'
# not released: the label only
check "$(has mozilla/fxa#21554 "${LABEL}" v1.347.3 fxa-mono-latest) $(has mozilla/fxa#21494 "${LABEL}" "" fxa-mono-latest)" "0 0" "not released: an image with the patch in its label has it"
check "$(has mozilla/fxa#21554 none v1.400.0 fxa-mono-latest) $(has mozilla/fxa#21554 "" "" v1.400.0) $(has mozilla/fxa#21494 "mozilla/fxa#21554@a..b" "" fxa-mono-v1.400.0)" "1 1 1" \
  "not released: without it in the label, none has it, whatever its release"
check "$(has mozilla/fxa#2155 "${LABEL}" "" "") $(has fxa#21554 "${LABEL}" "" "")" "1 1" "another pull request's number is not it"
# released in v1.352.0 (a fixed-in of a test checkout)
SELF_DIR=${WORK}/checkout
mkdir -p "${SELF_DIR}/config/fxa"
cp "${CODE}/config/fxa/fixed-in" "${SELF_DIR}/config/fxa/fixed-in"
printf 'mozilla/fxa#21554 v1.352.0\n' >> "${SELF_DIR}/config/fxa/fixed-in"
check "$(fxa_fixed_in mozilla/fxa#21554)|$(fxa_fixed_in mozilla/fxa#21494)" "v1.352.0|" "fixed-in: the release of a pull request, the others none"
check "$(has mozilla/fxa#21554 none v1.352.0 fxa-mono-latest) $(has mozilla/fxa#21554 "" v1.360.2 latest) $(has mozilla/fxa#21554 "" "" v1.352.1) $(has mozilla/fxa#21554 "" "" fxa-mono-v1.400.0) $(has mozilla/fxa#21554 "" 1.352.0 "")" \
  "0 0 0 0 0" "released: an image of that release or a later one has it, its version label or its tag (ours, Mozilla's)"
check "$(has mozilla/fxa#21554 none v1.351.9 fxa-mono-latest) $(has mozilla/fxa#21554 "" "" v1.347.3) $(has mozilla/fxa#21554 "" v1.35.0 v1.400.0)" "1 1 1" \
  "released: an older image has not (the version label first, then the tag)"
check "$(has mozilla/fxa#21554 "${LABEL}" v1.347.3 fxa-mono-v1.347.3)" 0 "released: an older image of ours with the patch in its label still has it"
check "$(has mozilla/fxa#21554 "" "" latest) $(has mozilla/fxa#21554 "" "" "sha256:abc")" "2 2" "released: an image of no known release, not known"
check "$(has mozilla/fxa#21494 none v1.400.0 latest)" 1 "released: another pull request still by its label"
check "$(version_at_least 1.352.0 1.352.0 && echo y) $(version_at_least 1.352.10 1.352.9 && echo y) $(version_at_least 1.400 1.352.1 && echo y) $(version_at_least 1.352 1.352.1 || echo n) $(version_at_least 2.0.0 1.999.999 && echo y)" \
  "y y y n y" "version_at_least: part by part, numbers"
check "$(fxa_release v1.347.3) $(fxa_release fxa-mono-v1.347.3) $(fxa_release 1.347.3) [$(fxa_release fxa-mono-latest)] [$(fxa_release v1.347.3-rc1)] [$(fxa_release 1)] [$(fxa_release 20261020)] [$(fxa_release v1.347)] [$(fxa_release 1.2.3.4)]" "1.347.3 1.347.3 1.347.3 [] [] [] [] [] []" \
  "fxa_release: of the version label or the tag"
# the JSON of an image (docker, podman inspect, buildx imagetools)
json='[{"Config":{"Labels":{"org.firefox-sync.upstream-patches":"none","org.opencontainers.image.version":"v1.353.0"}}}]'
check "$(fxa_inspected_has mozilla/fxa#21554 "${json}" fxa-mono-latest; echo $?) $(fxa_inspected_has mozilla/fxa#21494 "${json}" fxa-mono-latest; echo $?)" "0 1" \
  "the labels of an image's JSON: released and newer has it, the other not"

echo "== prepare_environment.sh: setup/ of its real path"
mkdir -p "${WORK}/linked"
ln -s "${CODE}/prepare_environment.sh" "${WORK}/linked/prepare_environment.sh"
check "$(source "${WORK}/linked/prepare_environment.sh" && echo "$(type -t upgrade_env) ${SELF_DIR} ${FFS_ENTRY_DIR}")" \
  "function ${CODE} $(cd "${WORK}/linked" && pwd)" "sourced through a symlink: the functions of setup/ next to its target, the setup's directory where it was started"
cp -r "${CODE}/prepare_environment.sh" "${WORK}/no-setup.sh"
check "$(source "${WORK}/no-setup.sh" 2> /dev/null; echo $?) $(bash "${WORK}/no-setup.sh" --upgrade > /dev/null 2>&1; echo $?)" "1 1" \
  "without setup/ next to it: sourced, the source fails; run, it stops (1)"

echo "== setup/env.sh: the compose files of an install (compose_files, compose_files_moved, compose_project)"
check "$(compose_files mariadb "" no) $(compose_files postgres mysql no) $(compose_files mysql mariadb yes)" \
  "compose/sync.yml:compose/sync-mariadb.yml compose/sync.yml:compose/sync-postgres.yml:compose/fxa.yml:compose/fxa-mysql.yml compose/sync.yml:compose/sync-mysql.yml:compose/fxa.yml:compose/fxa-mariadb.yml:compose/podman.yml" \
  "compose_files: Sync's database, the accounts' and compose/podman.yml"
# "<COMPOSE_FILE of before> => <now>" (docs/upgrading.md#files-that-moved; nothing: no file of before in it)
MOVED_CASES=(
  ' => compose/sync.yml:compose/sync-mariadb.yml'
  'docker-compose.yml => compose/sync.yml:compose/sync-mariadb.yml'
  'docker-compose.yml:docker-compose.sync-mysql.yml => compose/sync.yml:compose/sync-mysql.yml'
  'docker-compose.sync-postgres.yml => compose/sync.yml:compose/sync-postgres.yml'
  'docker-compose.postgres.yml => compose/sync.yml:compose/sync-postgres.yml'
  'docker-compose.yml:docker-compose.fxa.yml => compose/sync.yml:compose/sync-mariadb.yml:compose/fxa.yml:compose/fxa-mysql.yml'
  'docker-compose.yml:docker-compose.fxa.yml:docker-compose.fxa-mariadb.yml => compose/sync.yml:compose/sync-mariadb.yml:compose/fxa.yml:compose/fxa-mariadb.yml'
  'docker-compose.yml:docker-compose.sync-mysql.yml:docker-compose.fxa.yml => compose/sync.yml:compose/sync-mysql.yml:compose/fxa.yml:compose/fxa-mysql.yml'
  'docker-compose.sync-postgres.yml:docker-compose.fxa.yml:docker-compose.fxa-mariadb.yml => compose/sync.yml:compose/sync-postgres.yml:compose/fxa.yml:compose/fxa-mariadb.yml'
  'docker-compose.yml:docker-compose.podman.yml => compose/sync.yml:compose/sync-mariadb.yml:compose/podman.yml'
  'docker-compose.yml:docker-compose.podman.yml:docker-compose.sync-mysql.yml => compose/sync.yml:compose/sync-mysql.yml:compose/podman.yml'
  './docker-compose.yml:my-override.yml => ./compose/sync.yml:./compose/sync-mariadb.yml:my-override.yml'
  '/opt/ffs/docker-compose.sync-postgres.yml:/opt/ffs/docker-compose.fxa.yml => /opt/ffs/compose/sync.yml:/opt/ffs/compose/sync-postgres.yml:/opt/ffs/compose/fxa.yml:/opt/ffs/compose/fxa-mysql.yml'
  'compose/sync.yml:compose/sync-mysql.yml => '
  'compose/sync.yml:compose/sync-postgres.yml:compose/fxa.yml:compose/fxa-mysql.yml:mine.yml => '
)
for c in "${MOVED_CASES[@]}"; do
  check "$(compose_files_moved "${c% => *}")" "${c#* => }" "compose_files_moved: '${c% => *}'"
done
check "$(unset COMPOSE_PROJECT_NAME; SCRIPT_DIR=${WORK}/My_Sync.Dir-2 compose_project) $(COMPOSE_PROJECT_NAME=Other compose_project)" "my_syncdir-2 other" \
  "compose_project: the directory's name as compose makes it a project name, or COMPOSE_PROJECT_NAME"
# as compose-go's NormalizeProjectName: lowercase, a-z 0-9 _ -, no _ or - first
for c in 'firefox-sync => firefox-sync' 'FFS_Prod => ffs_prod' '_-ffs.copy => ffscopy' '--a_b-c => a_b-c' '___ => ' 'Été 2 => t2' 'ffs staging => ffsstaging' '9lives => 9lives'; do
  check "$(normalize_project "${c% => *}")" "${c#* => }" "normalize_project: '${c% => *}'"
done
check "$(unset COMPOSE_PROJECT_NAME; SCRIPT_DIR=${WORK}/-_Lead.Ing compose_project)" leading "compose_project: the directory's name without its leading - and _"
# a copy of a checkout: .env names the original's project, said loudly; an exported value, a NOTE
mkdir -p "${WORK}/ffs-staging" && printf 'COMPOSE_PROJECT_NAME=ffs\nCOMPOSE_FILE=compose/sync.yml:compose/sync-mariadb.yml\n' > "${WORK}/ffs-staging/.env"
said=$(unset COMPOSE_FILE COMPOSE_PROJECT_NAME; SCRIPT_DIR=${WORK}/ffs-staging ENV_READ=${WORK}/ffs-staging/.env compose_settings_check)
check "$(grep -c '^WARNING: COMPOSE_PROJECT_NAME=ffs in .env, while this directory would be the project ffs-staging:' <<< "${said}") $(grep -c 'down -v' <<< "${said}")" "1 1" \
  "compose_settings_check: a copy's .env with the original's project name: a WARNING, and what down -v would do"
said=$(SCRIPT_DIR=${WORK}/ffs-staging ENV_READ=${WORK}/ffs-staging/.env COMPOSE_FILE=docker-compose.yml COMPOSE_PROJECT_NAME=ffs compose_settings_check)
check "$(grep -c '^NOTE: COMPOSE_FILE is exported' <<< "${said}") $(grep -c '^NOTE: COMPOSE_PROJECT_NAME is exported' <<< "${said}")" "1 0" \
  "compose_settings_check: an exported COMPOSE_FILE other than .env's, a NOTE (COMPOSE_PROJECT_NAME the same: none)"
mkdir -p "${WORK}/ffs" && printf 'COMPOSE_PROJECT_NAME=ffs\n' > "${WORK}/ffs/.env"
check "$(unset COMPOSE_FILE COMPOSE_PROJECT_NAME; SCRIPT_DIR=${WORK}/ffs ENV_READ=${WORK}/ffs/.env compose_settings_check | wc -l | tr -d ' ')" 0 "compose_settings_check: the directory's own name, nothing said"
# docker compose on the Podman socket: compose/podman.yml after the files of compose/
for c in 'compose/sync.yml:compose/sync-mariadb.yml => compose/sync.yml:compose/sync-mariadb.yml:compose/podman.yml' \
  'compose/sync.yml:compose/sync-postgres.yml:compose/fxa.yml:compose/fxa-mysql.yml:mine.yml => compose/sync.yml:compose/sync-postgres.yml:compose/fxa.yml:compose/fxa-mysql.yml:compose/podman.yml:mine.yml' \
  '/opt/f/compose/sync.yml:/opt/f/compose/sync-mysql.yml => /opt/f/compose/sync.yml:/opt/f/compose/sync-mysql.yml:/opt/f/compose/podman.yml' \
  'compose/sync.yml:compose/sync-mysql.yml:compose/podman.yml => '; do
  check "$(compose_files_podman "${c% => *}")" "${c#* => }" "compose_files_podman: '${c% => *}'"
done
check "$(DOCKER_HOST=unix:///run/user/1000/podman/podman.sock compose_on_podman && echo podman)" podman "compose_on_podman: DOCKER_HOST is Podman's socket"
mkdir -p "${WORK}/named" && printf 'COMPOSE_PROJECT_NAME=kept\n' > "${WORK}/named/.env"
check "$(unset COMPOSE_PROJECT_NAME; SCRIPT_DIR=${WORK}/named compose_project)" kept "compose_project: COMPOSE_PROJECT_NAME of .env"

echo "== setup/validate.sh: limits, database names, hosts, ports (valid_limit, valid_name, valid_host, valid_port)"
for v in 0 1 2147483647 unlimited; do check "$( (valid_limit "max users" "${v}") && echo ok)" ok "valid_limit accepts ${v}"; done
for v in "" -1 1.5 initial:4 2147483648 99999999999 lots; do
  check "$( (valid_limit "max users" "${v}") > /dev/null; echo $?)" 1 "valid_limit refuses '${v}' (exit 1)"
done
for v in syncstorage _a a1_b2 "$(printf 'a%.0s' $(seq 1 32))"; do check "$( (valid_name "${v}") && echo ok)" ok "valid_name accepts ${v}"; done
for v in "" 1a Sync a-b "a b" "$(printf 'a%.0s' $(seq 1 33))" "a;drop"; do
  check "$( (valid_name "${v}") > /dev/null; echo $?)" 1 "valid_name refuses '${v}'"
done
for v in db.example.org 172.17.0.1 host.containers.internal my_db; do check "$( (valid_host "${v}") && echo ok)" ok "valid_host accepts ${v}"; done
for v in "" localhost 127.0.0.1 0.0.0.0 ::1 fe80::1 "db example" 'db;x'; do
  check "$( (valid_host "${v}") > /dev/null; echo $?)" 1 "valid_host refuses '${v}'"
done
check "$( (valid_port 3306) && echo ok) $( (valid_port "") > /dev/null; echo $?) $( (valid_port 33a) > /dev/null; echo $?)" "ok 1 1" "valid_port: digits only"

echo "== setup/databases.sh: database-setup.sql of your own server (render_sync_sql, db/db-setup.sh print)"
mkdir -p "${WORK}/sql" && cp -r "${CODE}/db" "${WORK}/sql/"
sed -e 's|<REPLACE_WITH_SOMETHING_SECURE>|pw~ord|' "${CODE}/.env-example" > "${WORK}/sql/.env"
for engine in mariadb postgres; do
  (SCRIPT_DIR=${WORK}/sql; ENV_READ=${WORK}/sql/.env; render_sync_sql "${engine}")
  out=${WORK}/sql/database-setup.sql
  check "$(grep -c '@[A-Z_]*@' "${out}") $([ "$(grep -c 'pw~ord' "${out}")" -gt 0 ] && echo values) $(mode "${out}") $(grep -c '^-- ==== setup migration 001-' "${out}") $(grep -c "ffs_setup_migrations (scope, number, name, checksum, how) VALUES ('sync', 1, '001-sync-and-admin-ui.sql', '[0-9a-f]\{64\}', 'manual')" "${out}")" \
    "0 values 600 1 1" "render_sync_sql ${engine}: every setup migration, every placeholder filled from .env, this user's only, the INSERT that records it (manual)"
done
# a password the stack refuses at every start (db/db-setup.sh): refused here too, no file
sed -i.bak -e 's|^SYNC_TOKENSERVER_DB_PASSWORD=.*|SYNC_TOKENSERVER_DB_PASSWORD=pw\&ord|' "${WORK}/sql/.env" && rm -f "${WORK}/sql/.env.bak"
out=$( (SCRIPT_DIR=${WORK}/sql; ENV_READ=${WORK}/sql/.env; render_sync_sql mariadb) 2>&1)
check "$? $(grep -c 'SYNC_TOKENSERVER_DB_PASSWORD: only A-Z a-z 0-9' <<< "${out}") $(ls "${WORK}/sql"/database-setup.sql* 2> /dev/null | wc -l | tr -d ' ')" "1 1 0" \
  "render_sync_sql: a password with & refused (as db-bootstrap refuses it), no database-setup.sql"
sed -i.bak -e 's|^SYNC_TOKENSERVER_DB_PASSWORD=.*|SYNC_TOKENSERVER_DB_PASSWORD=pw~ord|' "${WORK}/sql/.env" && rm -f "${WORK}/sql/.env.bak"
# --upgrade keeps the one of before (keep_previous_sql)
echo "previous" > "${WORK}/sql/database-setup.sql"
(SCRIPT_DIR=${WORK}/sql; keep_previous_sql "${WORK}/sql/database-setup.sql") > /dev/null
check "$(cat "${WORK}/sql"/database-setup.sql.before-upgrade-* 2> /dev/null) $(mode "${WORK}/sql"/database-setup.sql.before-upgrade-*)" "previous 600" \
  "keep_previous_sql: the database-setup.sql of before as database-setup.sql.before-upgrade-<time>, this user's only"
rm -f "${WORK}/sql"/database-setup.sql*
# the bootstrap account's SQL (docs/databases.md#the-bootstrap-account), and the accounts' SQL
sed -i.bak -e 's|^SYNC_DB_BOOTSTRAP_USER=.*|SYNC_DB_BOOTSTRAP_USER=ffs_boot|' -e 's|^SYNC_DB_BOOTSTRAP_PASSWORD=.*|SYNC_DB_BOOTSTRAP_PASSWORD=b00t|' \
  -e 's|^FXA_DB_BOOTSTRAP_USER=.*|FXA_DB_BOOTSTRAP_USER=ffs_fxa_boot|' -e 's|^FXA_DB_BOOTSTRAP_PASSWORD=.*|FXA_DB_BOOTSTRAP_PASSWORD=f00t|' \
  -e 's|^FXA_MYSQL_POLICY_USER=.*|FXA_MYSQL_POLICY_USER=ffs_policy|' "${WORK}/sql/.env" && rm -f "${WORK}/sql/.env.bak"
for engine in mariadb postgres fxa; do
  (SCRIPT_DIR=${WORK}/sql; ENV_READ=${WORK}/sql/.env; render_bootstrap_sql "${engine}")
  out=${WORK}/sql/database-bootstrap$([ "${engine}" = fxa ] && echo -fxa).sql
  check "$(grep -c '@[A-Z_]*@' "${out}") $(grep -c "ffs_$([ "${engine}" = fxa ] && echo fxa_)boot" "${out}") $(grep -c "$([ "${engine}" = fxa ] && echo f00t || echo b00t)" "${out}") $(mode "${out}")" \
    "0 $(case ${engine} in postgres) echo 3 ;; fxa) echo 9 ;; *) echo 7 ;; esac) $([ "${engine}" = postgres ] && echo 1 || echo 2) 600" \
    "render_bootstrap_sql ${engine}: the account of .env and its password, every placeholder filled, this user's only"
done
(SCRIPT_DIR=${WORK}/sql; ENV_READ=${WORK}/sql/.env; render_fxa_sql mysql native)
check "$(grep -c '@[A-Z_]*@' "${WORK}/sql/database-setup-fxa.sql") $(grep -c 'IDENTIFIED WITH mysql_native_password' "${WORK}/sql/database-setup-fxa.sql") $(grep -c '^-- native:' "${WORK}/sql/database-setup-fxa.sql") $(ls "${WORK}/sql/database-setup-fxa.native" 2> /dev/null)" \
  "0 2 0 " "render_fxa_sql mysql native: the accounts' user on mysql_native_password, the template of it removed"
# db/db-setup.sh fills the setup migrations with the same settings: every placeholder of each one is in them
for pair in $(cd "${CODE}" && for f in db/mysql/setup/sync/*.sql; do echo "mysql:${f}"; done; for f in db/postgres/setup/sync/*.sql; do echo "postgres:${f}"; done
    for f in db/mysql/setup/fxa-*/*.sql; do echo "fxa:${f}"; done); do
  check "$(grep -o '@[A-Z_]*@' "${CODE}/${pair#*:}" | tr -d @ | sort -u | grep -vxF -f <(bash "${CODE}/db/db-setup.sh" settings "${pair%%:*}" | cut -d' ' -f1) | paste -sd' ' -)" "" \
    "db/db-setup.sh settings ${pair%%:*}: every placeholder of ${pair#*:}"
done
# its early exits, before any connection: the stack's containers, half an account, both names
dbsetup() { env -i PATH="${PATH}" FFS_DB_DIR="${WORK}/sql/db" "$@" bash "${CODE}/db/db-setup.sh" sync 2>&1; }
check "$(dbsetup SYNC_DB_CONTAINERS=1 | grep -c 'nothing to do'; echo "${PIPESTATUS[0]}")" "1
0" "db/db-setup.sh with the stack's database containers: nothing, exit 0"
check "$(dbsetup SYNC_DB_CONTAINERS=0 SYNC_DB_BOOTSTRAP_USER=x > /dev/null; echo $?) $(dbsetup SYNC_DB_CONTAINERS=0 SYNC_DB_BOOTSTRAP_USER=x | grep -c 'set both, or neither')" \
  "1 1" "db/db-setup.sh: a bootstrap user without its password refused"
check "$(dbsetup SYNC_DB_CONTAINERS=0 FFS_BOTH_ENV_NAMES=SYNC_TOKENSERVER_DB_HOST/MARIADB_TOKENSERVER_SERVER | grep -c 'are both set'; echo "${PIPESTATUS[0]}")" "1
1" "db/db-setup.sh: a setting under both names refused, as the migrations refuse it"

echo "== setup/quadlets.sh: the checkout the installed units are of (units_installed, units_dir, units_of_here, units_without_dir)"
QUADLET_DIR=${WORK}/units && mkdir -p "${QUADLET_DIR}" "${WORK}/here"
check "$(units_installed || echo none)" none "no units: none installed"
printf '[Container]\nContainerName=firefox-sync-syncstorage\nImage=ghcr.io/porelli/firefox-sync:syncstorage-rs-mysql-latest\n' > "${QUADLET_DIR}/firefox-sync-syncstorage.container"
check "$(units_installed && echo yes) [$(units_dir)] $(units_without_dir && echo without-dir)" "yes [] without-dir" "units of an earlier release: no checkout in them"
printf 'Volume=%s/config/backup:/ffs-backup:ro,Z\n' "${WORK}/here" > "${QUADLET_DIR}/firefox-sync-backup.container"
ln -s "${WORK}/here" "${WORK}/here-link"
check "$(units_dir) $(SCRIPT_DIR=${WORK}/here units_of_here && echo here) $(SCRIPT_DIR=${WORK}/here-link units_of_here && echo through-link) $(SCRIPT_DIR=${WORK} units_of_here || echo not-there) $(units_without_dir || echo with-dir)" \
  "${WORK}/here here through-link not-there with-dir" "units rendered from a checkout: that one (also through a symlink), not another"

echo "== setup/quadlets.sh: the secrets in the units' environment files, not in the units (render_units, secret_setting)"
check "$(for k in SYNC_MASTER_SECRET ADMIN_PASSWORD FXA_SMTP_PASS ADMIN_METRICS_TOKEN FXA_FLOW_ID_KEY ADMIN_NOTIFY SYNC_POSTGRES_CONNECT_PASSWORD; do secret_setting "${k}" && printf y; done) $(for k in FXA_ACCESS_TOKEN_LIFETIME SYNC_TOKENSERVER_DB_HOST ADMIN_FXA_CLIENT_ID FXA_SMTP_USER SYNC_PUBLIC_URL; do secret_setting "${k}" || printf n; done)" \
  "yyyyyyy nnnnn" "secret_setting: PASS, PASSWORD, SECRET, TOKEN, KEY parts and ADMIN_NOTIFY; not the tokens' lifetime, TOKENSERVER, an id"
R=${WORK}/render && mkdir -p "${R}/config" && cp -r "${CODE}/config/quadlet" "${R}/config/" && cp "${CODE}/.env-example" "${R}/"
sed -e 's|<REPLACE_WITH_SOMETHING_SECURE>|s3cretValue|' -e 's|<REPLACE_WITH_YOUR_DOMAIN>|sync.example.org|' \
  -e '/^FXA_SMTP_PASS=/d' -e 's|^ADMIN_NOTIFY=.*|ADMIN_NOTIFY=ntfy://tokenTOKEN123@ntfy.example.org/ffs|' "${CODE}/.env-example" > "${R}/.env"
# (as the setup writes a password typed: in single quotes)
printf '%s\n' "FXA_SMTP_PASS='50% p&ss|w \\#1 \"q\"'" >> "${R}/.env"
printf '#!/bin/sh\nexit 0\n' > "${WORK}/bin/systemctl"; printf '#!/bin/sh\nexec %s "$@"\n' "$(command -v sed)" > "${WORK}/bin/sed"; chmod +x "${WORK}/bin/systemctl" "${WORK}/bin/sed"
render() { (PATH=${WORK}/bin:${PATH} SCRIPT_DIR=${R} QUADLET_DIR=${R}/units SYSTEMD_USER_DIR=${R}/timers SELF_HOST_FXA=yes ADMIN_UI=yes render_units) > "${WORK}/render-$1.log" 2>&1; }
render first
smtp=$(SCRIPT_DIR=${R} env_plain FXA_SMTP_PASS)
leaks=$(grep -rlF -e s3cretValue -e tokenTOKEN123 -e "${smtp}" -e "${smtp//%/%%}" "${R}/units"/*.container "${R}/units"/*.volume "${R}/units"/*.network "${R}/timers" 2> /dev/null | wc -l | tr -d ' ')
envs=$(ls "${R}/units"/*.env | wc -l | tr -d ' ')
check "$? ${leaks} $([ "${envs}" -gt 10 ] && echo files) $(for f in "${R}/units"/*.env; do mode "${f}"; done | sort -u | paste -sd' ') $(for f in "${R}/units"/*.env; do grep -cxF "EnvironmentFile=${f}" "${f%.env}.container"; done | sort -u | paste -sd' ')" \
  "0 0 files 600 1" "render_units: no secret in a unit, the timers either; each unit's secrets in its environment file (EnvironmentFile=), 0600"
check "$(grep -cxF "SMTP_PASS=${smtp}" "${R}/units/firefox-sync-fxa-auth.env") $(grep -cxF 'ADMIN_NOTIFY=ntfy://tokenTOKEN123@ntfy.example.org/ffs' "${R}/units/firefox-sync-admin.env") $(grep -c '^SYNC_MASTER_SECRET=s3cretValue$' "${R}/units/firefox-sync-syncstorage.env") $(grep -c 'SYNC_MASTER_SECRET' "${R}/units/firefox-sync-admin.env")" \
  "1 1 1 0" "the environment files: each value as it is (a %, quotes and \\ too: no systemd there), a unit's own secrets only"
chmod 644 "${R}/units/firefox-sync-syncstorage.env"
render again
check "$(grep -c 'nothing changed' "${WORK}/render-again.log") $(mode "${R}/units/firefox-sync-syncstorage.env")" "1 600" "render_units again: nothing changed, an environment file made 0644 back to 0600"
# the units of before, their secrets in them: rendered, the environment files written, the secrets out
sed -i.bak '/^EnvironmentFile=/d' "${R}/units/firefox-sync-syncstorage.container" && printf 'Environment=SYNC_MASTER_SECRET=s3cretValue\n' >> "${R}/units/firefox-sync-syncstorage.container"
rm -f "${R}/units/firefox-sync-syncstorage.env" "${R}/units"/*.bak
render old
check "$(grep -c 's3cretValue' "${R}/units/firefox-sync-syncstorage.container") $(mode "${R}/units/firefox-sync-syncstorage.env") $(grep '^  ✓ firefox-sync-syncstorage\.\(container\|env\)$' "${WORK}/render-old.log" | paste -sd' ')" \
  "0 600   ✓ firefox-sync-syncstorage.env   ✓ firefox-sync-syncstorage.container" \
  "a unit with its secret in it: rendered again, its environment file written first, then the unit without the secret"
# a unit not rendered any more (FXA_DB_CONTAINERS=0): its environment file removed too
printf 'FXA_DB_CONTAINERS=0\n' >> "${R}/.env"
render external
check "$(ls "${R}/units/firefox-sync-fxa-db.container" "${R}/units/firefox-sync-fxa-db.env" 2> /dev/null | wc -l | tr -d ' ') $(grep -c '^  - firefox-sync-fxa-db\.env (removed)$' "${WORK}/render-external.log")" "0 1" \
  "a unit no longer installed: its environment file removed with it"

echo "== setup/upgrade.sh: --upgrade of an .env from before (upgrade_env)"
mkdir -p "${WORK}/up" && cp -r "${CODE}/.env-example" "${CODE}/db" "${WORK}/up/"
sed -e 's|<REPLACE_WITH_SOMETHING_SECURE>|s3cret|' -e 's|<REPLACE_WITH_YOUR_DOMAIN>|sync.example.org|' \
  -e 's|^SYNC_PUBLIC_URL=|SYNCSTORAGE_DOMAIN=|' -e 's|^SYNC_MAX_USERS=|MAX_USERS=|' -e 's|^ADMIN_DB_PASSWORD=.*|ADMIN_DB_PASSWORD=|' \
  -e 's|^# COMPOSE_FILE=.*|COMPOSE_FILE=docker-compose.postgres.yml|' -e 's|^FXA_MYSQL_PASSWORD=.*|FXA_MYSQL_PASSWORD=<REPLACE_WITH_SOMETHING_SECURE>|' \
  -e 's|^SYNC_IMAGE=.*|SYNC_IMAGE=syncstorage-rs-postgres|' -e 's|^SYNC_POSTGRES_APP_PASSWORD=.*|SYNC_POSTGRES_APP_PASSWORD=app|' "${CODE}/.env-example" > "${WORK}/up/.env"
chmod 644 "${WORK}/up/.env"
# (docker compose on Docker here, also on a host with Podman: compose_on_podman is tested above)
(unset COMPOSE_PROJECT_NAME; compose_on_podman() { return 1; }; FFS_ENTRY_DIR=${WORK}/up QUADLET_DIR=${WORK}/no-units upgrade_env) < /dev/null > "${WORK}/upgrade.log" 2>&1
up_rc=$?
upv() { ENV_READ=${WORK}/up/.env SCRIPT_DIR=${WORK}/up env_plain "$1"; }
check "${up_rc} $(upv COMPOSE_FILE) $(upv COMPOSE_PROJECT_NAME) $(upv SYNC_PUBLIC_URL) $(upv SYNC_MAX_USERS) $(grep -c '^\(SYNCSTORAGE_DOMAIN\|MAX_USERS\)=' "${WORK}/up/.env")" \
  "0 compose/sync.yml:compose/sync-postgres.yml up https://sync.example.org 1 0" \
  "upgrade_env: the files of compose/ and the project in COMPOSE_FILE, the old names renamed (their values kept)"
check "$(upv ADMIN_DB_PASSWORD | grep -cE '^[A-Za-z0-9]{32}$') $(upv SYNC_POSTGRES_IMAGE) $(mode "${WORK}/up/.env") $(ls "${WORK}/up"/.env.before-upgrade-* | wc -l | tr -d ' ') $(grep -c '^Then: docker compose pull && docker compose up -d$' "${WORK}/upgrade.log")" \
  "1 postgres:18 600 1 1" "upgrade_env: the missing password, the PostgreSQL major of before, .env this user's only, the old one kept, what to run next" \
  || cat "${WORK}/upgrade.log"
(unset COMPOSE_PROJECT_NAME; compose_on_podman() { return 1; }; FFS_ENTRY_DIR=${WORK}/up QUADLET_DIR=${WORK}/no-units upgrade_env) < /dev/null > "${WORK}/upgrade-again.log" 2>&1
check "$? $(ls "${WORK}/up"/.env.before-upgrade-* | wc -l | tr -d ' ') $(grep -c '^Updated ' "${WORK}/upgrade-again.log")" "0 1 0" "upgrade_env run again: nothing changes"

[ "${FAILED}" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "${FAILED}"
