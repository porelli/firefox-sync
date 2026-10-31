#!/bin/bash
# shellcheck disable=SC2016,SC2029 # (the single-quoted commands expand in the VM)
# A local Ubuntu VM (qemu) to run the firefox-sync tests without GitHub: the newest Ubuntu LTS
# (as CI's ubuntu-latest and ubuntu-26.04-arm runners), its podman, docker and compose, a
# systemd user session (linger), and the latest kind, helm, kubectl, chart-testing (ct),
# kubeconform, yamllint and yamale. Hosts: macOS (HVF) and Linux (KVM), arm64 or amd64: the
# VM has the host's architecture. See docs/development/testing.md#local-vm.
#
#   vm.sh create            create the disk (DISK_SIZE, default 50G) and the cloud-init seed, on
#                           the newest supported LTS of changelogs.ubuntu.com/meta-release-lts
#                           (its cloud image checked against SHA256SUMS, kept as
#                           <codename>-server-cloudimg-<arch>.img; the release in ./release).
#                           Nothing when the disk exists (vm.sh destroy first for a new one)
#   vm.sh provision         bring an existing VM up to date (start does it on the first boot):
#                           apt packages (APT_PKGS) installed and upgraded, docker group, linger,
#                           REPO's .github/scripts/pasta-apparmor.sh (the Ubuntu 26.04 pasta bug),
#                           the latest releases of the tools above in ~/.local/bin (each checked
#                           against its release's checksums; yamllint and yamale with pipx from
#                           PyPI), ~/.ffs/lib.sh, and docker login to ghcr.io with FFS_GHCR_TOKEN
#                           when it is set (private images only; see below). Not while a slot is
#                           in use
#   vm.sh start | stop      boot (headless) / shut down
#   vm.sh test <what>...    run tests in a slot: e2e-mysql | e2e-postgres | e2e-fxa | podman | all
#                           | fxa-upgrade (not in all; FXA_FROM=<older accounts image:tag>)
#                           | helm-lint | helm-<mariadb|mysql|postgres> | helm-fxa-<mysql|mariadb>
#                           (the chart: tests/helm.sh lint, tests/helm.sh e2e <backend>,
#                           tests/helm-fxa.sh e2e <db>, not in all; their variables in the job,
#                           e.g. 'EXTERNAL_DB=1 helm-mysql', 'PART=main helm-fxa-mysql');
#                           several at once in one slot (all = the first four, in parallel; the
#                           kind ones one after another, next to the others), summary with
#                           durations, logs in LOGS (default: a new private
#                           ${TMPDIR:-/tmp}/ffs-vm-tests-<time>-XXXXXX)
#   vm.sh test affected [base]  the suites the changes since base need (default: the default
#                           branch of the images' remote, <remote>/HEAD, else <remote>/main, else
#                           main; the merge base with HEAD, and the uncommitted changes): the plan,
#                           then run, spread over the free slots (variants of one suite in
#                           different slots; the chart's kind runs in one slot, one by one)
#   vm.sh ssh [cmd]         shell or command in the VM, in a slot: REPO synced into the slot's
#                           checkout first (NOSYNC=1: not), the command runs where `cd firefox-sync`
#                           reaches it, with SLOT set (the tests take their ports and names from it),
#                           e.g. REPO=<worktree> vm.sh ssh 'cd firefox-sync && tests/helm.sh e2e mariadb';
#                           no stdin (STDIN=1: this one's, but then not stopped in the VM with this)
#   vm.sh sync              copy REPO into a slot's checkout (test and ssh do it themselves)
#   vm.sh rerun [only] [pytest args]  Python tests of e2e-fxa.sh against a KEEP=1 stack, in its slot
#                           (only: flow,admin,browser), e.g. vm.sh rerun admin '-k sign_out'
#   vm.sh image <dir> <tag>...  build <dir> of REPO (e.g. db/mysql/init, admin) in the VM's docker
#                           once per content (tag ffs-src-<dir>:<hash of its files>), tag it <tag>;
#                           PODMAN=1: in podman too. In the VM (vm.sh ssh commands have it):
#                           ffs_image [--podman] <dir> <tag>..., or source ~/.ffs/lib.sh first
#   vm.sh slots             who holds which slot, kept stacks, the VM's locks and free disk
#   vm.sh release <slot>    tear down what a KEEP=1 run left in that slot
#   vm.sh phases <log>      how long each "== " phase of a test log took (STAMP_ALL=1 for a
#                           command: the time on every line of its output)
#   vm.sh prune             once no slot is in use: dangling images, build cache, unused anonymous
#                           volumes, older src-* image tags; ALL=1: every image no container uses
#                           (pulled again when needed), but kindest/node and *-helm-e2e
#   vm.sh destroy           stop and delete the VM disk and its host key (the base images stay)
#
# Settings (environment):
#   FFS_VM_DIR      the VM's files: disk, base images, seed, EFI variables, pid, console log
#                   (default ${XDG_DATA_HOME:-~/.local/share}/firefox-sync-vm)
#   REPO            the checkout under test (default: the one this script is in)
#   REPOSITORY      the images under test (default ghcr.io/<owner>/<repo> of REPO's remote named
#                   FFS_VM_REMOTE, else of one named dev or whose URL ends in -dev, else of origin;
#                   lowercase). The public repository's images lag behind the dev one's
#   TAG             their tag (default latest)
#   FFS_GHCR_TOKEN  a token with read:packages only (fine-grained or classic) for docker login
#                   to ghcr.io in the VM, at provision: needed for private images, not for public
#                   ones. Stored in the VM's ~/.docker/config.json. Without it no login, unless
#                   FFS_GHCR_GH=1 (or a yes at the prompt) takes `gh auth token`, which is broader
#   FFS_GHCR_USER   the user name of that login (default: the owner of REPOSITORY)
#   FFS_VM_SSH_KEY  the private key for ssh to the VM (default: the one of create, else
#                   ~/.ssh/id_ed25519, else FFS_VM_DIR/id_ed25519, generated by create)
#   SSH_PORT        the host's port forwarded to the VM's ssh (default: the one of create, else
#                   2222); a second VM needs its own FFS_VM_DIR and SSH_PORT. The VM's host key
#                   is made by create (FFS_VM_DIR/ssh_host_ed25519_key, given to cloud-init) and
#                   checked against FFS_VM_DIR/known_hosts; a VM created without one has its key
#                   recorded on the first connection (trust on first use)
#   CPUS, MEM       at start: CPUs and MB of memory (default 3/4 of the host's CPUs, half its memory)
#   CLOCK_SLACK     seconds the VM's clock may be off the host's before a command sets it to the
#                   host's (default 5): the guest's clock stops while the host sleeps
#   ACCEL           qemu's accelerator (default hvf on macOS, kvm on Linux)
#   FFS_VM_FIRMWARE, FFS_VM_FIRMWARE_VARS  the UEFI code and variables template (default: edk2
#                   of Homebrew's qemu, or of the Linux packages: AAVMF, OVMF, edk2)
#
# Trees of REPO's history in the VM, extracted on demand with `git archive` (no checkout to
# keep by hand) into ~/.ffs/rev/<commit>: UPGRADE_FROM=<a commit or tag of REPO> (podman.sh's
# earlier release, e.g. UPGRADE_FROM=cb8e519 vm.sh test podman) is given to the tests as that
# path (an absolute path is passed as it is); an ssh command running helm.sh or helm-fxa.sh
# gets PARITY_BASE_CHART, the chart of PARITY_BASE of REPO's tests/helm-fxa.sh (the slots'
# checkouts have no .git), unless it is set, and REPOSITORY (as for `vm.sh test`; helm.sh's
# own default is the public repository) unless the command sets it.
#
# Slots: up to SLOTS (3) commands at once, each in its own checkout (~/firefox-sync-slot<N>),
# with its own compose projects, ports and networks (tests/slot.sh, SLOT=N; slot 0 = the names
# CI uses). Every command (test, ssh, sync, rerun, image) takes a free slot for its duration and
# frees it on exit, also on failure or Ctrl-C (which stops what runs in the VM: its teardown
# runs). No lock to take by hand: the slots' locks are in FFS_VM_DIR/slots (private: yours,
# mode 700, else refused). SLOT=<n> asks for one slot (waits for it). Stale
# slots (the holder's pid gone) are taken over. In the VM: at most one kind cluster (an ssh
# command with helm.sh or helm-fxa.sh e2e or kind, or KIND=1) and one podman test at a time
# (Quadlet names are global); a slot starts with >= 8 GB free (10 GB for kind), after pruning
# build cache, dangling images and unused anonymous volumes, else waits. A run removes its
# compose projects and volumes when it ends, unless KEEP=1 (the slot is then kept: not given to
# others until vm.sh release <slot> or a command with SLOT=<slot>, e.g. vm.sh rerun).
#
# Images for `test`: the app images of REPOSITORY/TAG, refreshed (OFFLINE=1: not; PULL=1: the
# tests pull everything published, init images too); the init images (db/<engine>/init) and
# the admin UI (admin/) built from the slot's checkout once per content (vm.sh image), the
# tests get them as INIT_TAG and ADMIN_IMAGE.
# Environment passed to the tests: the variables of PASS_ENV below when set (one list: add
# names there), with SLOT, INIT_TAG, ADMIN_IMAGE and SKIP_PULL=1 (not with PULL=1).
set -u

# run from a copy: bash reads a script while it runs, an edit of this file would break the
# commands running
if [ -z "${FFS_VM_COPY:-}" ]; then
  # (those of commands killed with -9, a day old)
  find /tmp -maxdepth 1 -name 'ffs-vm-sh.*' -user "$(id -u)" -mmin +1440 -delete 2> /dev/null
  copy=$(mktemp /tmp/ffs-vm-sh.XXXXXX) && cp "${BASH_SOURCE[0]}" "${copy}" &&
    FFS_VM_COPY=${copy} FFS_VM_SELF=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}") exec /bin/bash "${copy}" "$@"
fi
say() { echo "vm.sh: $*" >&2; }
die() { say "$*"; exit 1; }
SELF=${FFS_VM_SELF:-${BASH_SOURCE[0]}}
SELF_DIR=$(dirname -- "${SELF}")
VM_DIR=${FFS_VM_DIR:-${XDG_DATA_HOME:-${HOME}/.local/share}/firefox-sync-vm}
case "${VM_DIR}" in /*) ;; *) VM_DIR=${PWD}/${VM_DIR} ;; esac
REPO=${REPO:-$(git -C "${SELF_DIR}" rev-parse --show-toplevel 2> /dev/null || (cd -- "${SELF_DIR}/../.." && pwd))}
DISK_SIZE=${DISK_SIZE:-50G}
RELEASE_FILE=${VM_DIR}/release
DISK=${VM_DIR}/disk.qcow2
SEED=${VM_DIR}/seed.iso
VARS=${VM_DIR}/efi-vars.fd
PIDFILE=${VM_DIR}/qemu.pid
# the port and key of create, kept in FFS_VM_DIR
SSH_PORT=${SSH_PORT:-$(cat "${VM_DIR}/ssh-port" 2> /dev/null)}
SSH_PORT=${SSH_PORT:-2222}
case "${SSH_PORT}" in '' | *[!0-9]*) die "SSH_PORT: a number, not ${SSH_PORT}" ;; esac
KEY=${FFS_VM_SSH_KEY:-$(cat "${VM_DIR}/ssh-key" 2> /dev/null)}
if [ -z "${KEY}" ]; then
  if [ -f "${HOME}/.ssh/id_ed25519" ]; then KEY=${HOME}/.ssh/id_ed25519; else KEY=${VM_DIR}/id_ed25519; fi
fi
HOST_KEY=${VM_DIR}/ssh_host_ed25519_key
KNOWN_HOSTS=${VM_DIR}/known_hosts
# (connections shared through a master of its own, which checked the host key: not one of
# ~/.ssh/config's, which may not have)
SSH_OPTS=(-i "${KEY}" -p "${SSH_PORT}" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${KNOWN_HOSTS}"
  -o GlobalKnownHostsFile=/dev/null -o ControlMaster=auto -o "ControlPath=${VM_DIR}/ssh-mux" -o ControlPersist=10m
  -o LogLevel=ERROR -o ConnectTimeout=5 -o ServerAliveInterval=30)
SLOTS=${SLOTS:-3}
# numbers only, for the settings that reach bash arithmetic or qemu (bash evaluates the
# operands of $(( )), a[$(cmd)] would run cmd): a clear refusal instead
number() { [[ "$2" =~ ^[0-9]+$ ]] || die "$1: a number, not '$2'"; }
number SLOTS "${SLOTS}"
number CLOCK_SLACK "${CLOCK_SLACK:-5}"
[ -z "${CPUS:-}" ] || number CPUS "${CPUS}"
[ -z "${MEM:-}" ] || number MEM "${MEM}"
# the slots of this VM, in its private folder (before: a shared /tmp/ffs-vm-slots, read while
# a holder of it lives, removed then)
LOCKS=${VM_DIR}/slots
OLD_LOCKS=/tmp/ffs-vm-slots
# passed to the tests when set
PASS_ENV=(REPOSITORY TAG KEEP FXA_IMAGE FXA_VERSION FXA_ARCH FXA_PAIRING_IMAGE ADMIN_IMAGE FXA_DB
  FXA_MARIADB_IMAGE FXA_MARIADB_FROM POSTGRES_IMAGE EXTERNAL_DB SYNC_DB FXA_FROM FXA_FROM_ARCH
  FXA_SAME_TAG FXA_ACCOUNT_EVENTS FXA_TEST_IMAGE SKIP_BROWSER SKIP_FXA UPGRADE_FROM PYTEST_ARGS
  FXA_MYSQL_IMAGE FXA_MYSQL_ARGS FXA_MYSQL_TO SYNC_MYSQL_IMAGE FXA_NEW_LOCAL FXA_MYSQL_FROM SYNC_MYSQL_FROM
  DB_BOOTSTRAP SYNC_BACKEND PART)
SUITES_ALL=(e2e-mysql e2e-postgres podman e2e-fxa)

vssh() { known_host && ssh "${SSH_OPTS[@]}" ubuntu@127.0.0.1 "$@"; }
# known_host: FFS_VM_DIR/known_hosts there; for a VM created without a host key of its own, its
# ed25519 key recorded once, from the first connection (trust on first use)
known_host() {
  [ -s "${KNOWN_HOSTS}" ] && return 0
  running || return 1
  local k
  k=$(ssh-keyscan -T 5 -t ed25519 -p "${SSH_PORT}" 127.0.0.1 2> /dev/null | awk '$2 == "ssh-ed25519" { print $2, $3; exit }')
  [ -n "${k}" ] || return 1
  say "recording the VM's host key in ${KNOWN_HOSTS} (first use): $(echo "${k}" | ssh-keygen -lf - 2> /dev/null | awk '{ print $2 }')"
  write_new "${KNOWN_HOSTS}" "[127.0.0.1]:${SSH_PORT} ${k}"
}
# write_new <file> <line>: the file written anew, not through a link put in its place
write_new() { rm -f -- "$1" && (set -C; printf '%s\n' "$2" > "$1"); }
# private_dir <dir>: there, yours, not writable by others, no link; else refused
private_dir() {
  [ -d "$1" ] || (umask 077 && mkdir -p -- "$1") || die "cannot create $1"
  [ ! -L "$1" ] && [ -O "$1" ] || die "$1: not a folder of yours (refused)"
  [ -z "$(find "$1" -maxdepth 0 \( -perm -020 -o -perm -002 \) -print)" ] || die "$1: writable by others (chmod go-w it)"
}
# the pid of this shell, also in a subshell ($$ is the script's; bash 3.2 has no BASHPID)
# (not in $( ): that is a subshell of its own)
set_mypid() { local f; f=$(mktemp); sh -c 'echo $PPID' > "${f}"; MYPID=$(cat "${f}"); rm -f "${f}"; }
running() { [ -f "${PIDFILE}" ] && kill -0 "$(cat "${PIDFILE}")" 2> /dev/null; }

# ---------- the host ----------
# need <command>...: each on PATH, else a clear failure
need() {
  local c missing=""
  for c in "$@"; do command -v "${c}" > /dev/null 2>&1 || missing="${missing} ${c}"; done
  [ -z "${missing}" ] || die "missing on this host:${missing} (requirements: docs/development/testing.md#local-vm)"
}
HOST_OS=$(uname -s)
case "$(uname -m)" in
  arm64 | aarch64) QEMU_ARCH=aarch64 IMG_ARCH=arm64 MACHINE=virt ;;
  x86_64 | amd64) QEMU_ARCH=x86_64 IMG_ARCH=amd64 MACHINE=q35 ;;
  *) QEMU_ARCH="" IMG_ARCH="" MACHINE="" ;;
esac
host_check() {
  [ -n "${QEMU_ARCH}" ] || die "unsupported host architecture $(uname -m) (arm64 or x86_64)"
  case "${HOST_OS}" in
    Darwin) ACCEL=${ACCEL:-hvf} ;;
    Linux)
      ACCEL=${ACCEL:-kvm}
      [ "${ACCEL}" != kvm ] || [ -w /dev/kvm ] || die "no access to /dev/kvm (KVM enabled? your user in the kvm group?)" ;;
    *) die "unsupported host ${HOST_OS} (macOS or Linux)" ;;
  esac
}
# the host's CPUs and memory (MB)
host_cpus() { sysctl -n hw.ncpu 2> /dev/null || nproc 2> /dev/null || getconf _NPROCESSORS_ONLN; }
host_mem_mb() {
  if [ "${HOST_OS}" = Darwin ]; then echo $(($(sysctl -n hw.memsize) / 1048576)); else awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo; fi
}
# FW_CODE and FW_VARS_TEMPLATE (may be empty: zeros of the code's size): the UEFI firmware of
# the host's architecture, in Homebrew's qemu or the Linux packages
find_firmware() {
  FW_CODE=${FFS_VM_FIRMWARE:-} FW_VARS_TEMPLATE=${FFS_VM_FIRMWARE_VARS:-}
  if [ -n "${FW_CODE}" ]; then [ -f "${FW_CODE}" ] || die "FFS_VM_FIRMWARE: no ${FW_CODE}"; return 0; fi
  local p c pairs=""
  for p in ${HOMEBREW_PREFIX:-} /opt/homebrew /usr/local /home/linuxbrew/.linuxbrew; do
    if [ "${QEMU_ARCH}" = aarch64 ]; then pairs="${pairs} ${p}/share/qemu/edk2-aarch64-code.fd:"
    else pairs="${pairs} ${p}/share/qemu/edk2-x86_64-code.fd:${p}/share/qemu/edk2-i386-vars.fd"; fi
  done
  if [ "${QEMU_ARCH}" = aarch64 ]; then
    # Debian and Ubuntu (qemu-efi-aarch64), Fedora (edk2-aarch64), Arch (edk2-aarch64)
    pairs="${pairs} /usr/share/AAVMF/AAVMF_CODE.fd:/usr/share/AAVMF/AAVMF_VARS.fd
      /usr/share/edk2/aarch64/QEMU_EFI-pflash.raw:/usr/share/edk2/aarch64/vars-template-pflash.raw
      /usr/share/qemu/edk2-aarch64-code.fd:"
  else
    # Debian and Ubuntu (ovmf), Fedora (edk2-ovmf), Arch (edk2-ovmf)
    pairs="${pairs} /usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd
      /usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd
      /usr/share/edk2/ovmf/OVMF_CODE.fd:/usr/share/edk2/ovmf/OVMF_VARS.fd
      /usr/share/edk2/x64/OVMF_CODE.4m.fd:/usr/share/edk2/x64/OVMF_VARS.4m.fd
      /usr/share/qemu/edk2-x86_64-code.fd:/usr/share/qemu/edk2-i386-vars.fd"
  fi
  for c in ${pairs}; do
    [ -f "${c%%:*}" ] || continue
    FW_CODE=${c%%:*} FW_VARS_TEMPLATE=${c#*:}
    [ -z "${FW_VARS_TEMPLATE}" ] || [ -f "${FW_VARS_TEMPLATE}" ] || continue
    return 0
  done
  die "no UEFI firmware for ${QEMU_ARCH} (Homebrew's qemu, or qemu-efi-aarch64 / ovmf / edk2 packages; or FFS_VM_FIRMWARE=<code.fd>)"
}
# sha256_ok <sum> <file>
sha256_ok() {
  if command -v sha256sum > /dev/null 2>&1; then echo "$1  $2" | sha256sum -c --status -; else echo "$1  $2" | shasum -a 256 -c -s -; fi
}
# make_iso <out> <volume id> <file>...: mkisofs, genisoimage or xorriso
make_iso() {
  local out=$1 vol=$2 tool; shift 2
  if command -v mkisofs > /dev/null 2>&1; then tool=(mkisofs)
  elif command -v genisoimage > /dev/null 2>&1; then tool=(genisoimage)
  elif command -v xorriso > /dev/null 2>&1; then tool=(xorriso -as mkisofs)
  else die "missing on this host: mkisofs, genisoimage or xorriso (requirements: docs/development/testing.md#local-vm)"; fi
  "${tool[@]}" -quiet -o "${out}" -V "${vol}" -J -R "$@"
}

# ---------- images and remotes of REPO ----------
# the remote of REPO the images come from: FFS_VM_REMOTE, else one named dev or whose URL
# ends in -dev, else origin
images_remote() {
  [ -n "${FFS_VM_REMOTE:-}" ] && { echo "${FFS_VM_REMOTE}"; return; }
  local r remotes
  remotes=$(git -C "${REPO}" remote 2> /dev/null)
  for r in ${remotes}; do [ "${r}" = dev ] && { echo dev; return; }; done
  for r in ${remotes}; do
    case "$(git -C "${REPO}" remote get-url "${r}" 2> /dev/null)" in *-dev | *-dev.git | *-dev/) echo "${r}"; return ;; esac
  done
  for r in ${remotes}; do [ "${r}" = origin ] && { echo origin; return; }; done
}
# ghcr.io/<owner>/<repo> of that remote, lowercase (else the public repository)
default_repository() {
  local r url path
  r=$(images_remote)
  url=$([ -n "${r}" ] && git -C "${REPO}" remote get-url "${r}" 2> /dev/null)
  # git@host:owner/repo.git, https://host/owner/repo(.git), ssh://git@host/owner/repo
  path=$(echo "${url}" | sed -E 's|/+$||; s|\.git$||; s|^[a-z+]+://[^/]+/||; s|^[^@/]+@[^:]+:||' | awk -F/ 'NF >= 2 { print $(NF - 1) "/" $NF }')
  echo "ghcr.io/$(echo "${path:-porelli/firefox-sync}" | tr '[:upper:]' '[:lower:]')"
}
# the base of `test affected`: the default branch of the images' remote, else main
default_base() {
  local r
  r=$(images_remote)
  if [ -n "${r}" ]; then
    # (<remote>/HEAD only when it names a branch of that remote)
    case "$(git -C "${REPO}" symbolic-ref -q "refs/remotes/${r}/HEAD" 2> /dev/null)" in
      "refs/remotes/${r}/"?*) echo "${r}/HEAD"; return ;;
    esac
    git -C "${REPO}" rev-parse -q --verify "refs/remotes/${r}/main" > /dev/null 2>&1 && { echo "${r}/main"; return; }
  fi
  echo main
}
IMAGES_REPO=""
images_repo() { [ -n "${IMAGES_REPO}" ] || IMAGES_REPO=${REPOSITORY:-$(default_repository)}; echo "${IMAGES_REPO}"; }

# the packages the tests need (cloud-init installs them on the first boot, provision again)
APT_PKGS=(docker.io docker-compose-v2 podman uidmap slirp4netns passt catatonit dbus-user-session
  pipx python3-venv python3-yaml binfmt-support curl rsync git jq gawk openssl netcat-openbsd)

# the codename of the newest supported Ubuntu LTS (the last "Supported: 1" entry)
latest_lts() {
  local c
  c=$(curl -fsSL https://changelogs.ubuntu.com/meta-release-lts |
    awk '/^Dist:/ { d = $2 } /^Supported:/ && $2 == 1 { last = d } END { print last }') || return 1
  [[ "${c}" =~ ^[a-z]+$ ]] || { say "no LTS codename in meta-release-lts (${c})"; return 1; }
  echo "${c}"
}

create() {
  [ -f "${DISK}" ] && { echo "already created ($(cat "${RELEASE_FILE}" 2> /dev/null || echo 'release unknown'))"; return; }
  host_check
  need curl qemu-img awk
  find_firmware
  private_dir "${VM_DIR}"
  if [ ! -f "${KEY}" ]; then
    [ "${KEY}" = "${VM_DIR}/id_ed25519" ] || die "no ssh key ${KEY} (FFS_VM_SSH_KEY)"
    need ssh-keygen
    say "generating ${KEY} for the VM"
    ssh-keygen -q -t ed25519 -N '' -C "firefox-sync-vm" -f "${KEY}" || exit 1
  fi
  [ -f "${KEY}.pub" ] || die "no ${KEY}.pub"
  local codename url base sum
  codename=$(latest_lts) || exit 1
  url=https://cloud-images.ubuntu.com/${codename}/current
  base=${VM_DIR}/${codename}-server-cloudimg-${IMG_ARCH}.img
  sum=$(curl -fsSL "${url}/SHA256SUMS" | awk -v f="*$(basename "${base}")" '$2 == f {print $1}')
  [[ "${sum}" =~ ^[0-9a-f]{64}$ ]] || die "no checksum of $(basename "${base}") in ${url}/SHA256SUMS"
  # (a base of this codename already here: kept when it is the current image, else replaced)
  if [ ! -f "${base}" ] || ! sha256_ok "${sum}" "${base}"; then
    say "downloading ${url}/$(basename "${base}")"
    curl -fsSL -o "${base}.part" "${url}/$(basename "${base}")" || { rm -f "${base}.part"; exit 1; }
    sha256_ok "${sum}" "${base}.part" || { rm -f "${base}.part"; die "checksum mismatch"; }
    mv "${base}.part" "${base}"
  fi
  # the UEFI variables: the firmware's template, or zeros of the code's size (AAVMF of Homebrew)
  if [ -n "${FW_VARS_TEMPLATE}" ]; then
    cp "${FW_VARS_TEMPLATE}" "${VARS}" && chmod u+w "${VARS}" || exit 1
  else
    dd if=/dev/zero of="${VARS}" bs=1048576 count=$(($(wc -c < "${FW_CODE}") / 1048576)) 2> /dev/null || exit 1
  fi
  # the VM's own host key, given to cloud-init: ssh checks it (known_hosts) from the first connection
  need ssh-keygen
  rm -f "${HOST_KEY}" "${HOST_KEY}.pub"
  ssh-keygen -q -t ed25519 -N '' -C "firefox-sync-vm-host" -f "${HOST_KEY}" || exit 1
  write_new "${KNOWN_HOSTS}" "[127.0.0.1]:${SSH_PORT} $(cut -d' ' -f1,2 "${HOST_KEY}.pub")"
  local seed_dir; seed_dir=$(mktemp -d)
  cat > "${seed_dir}/meta-data" <<EOF
instance-id: ffs-test-${codename}
local-hostname: ffs-test
EOF
  cat > "${seed_dir}/user-data" <<EOF
#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat "${KEY}.pub")
ssh_deletekeys: true
ssh_genkeytypes: []
ssh_keys:
  ed25519_private: |
$(sed 's/^/    /' "${HOST_KEY}")
  ed25519_public: $(cut -d' ' -f1,2 "${HOST_KEY}.pub")
package_update: true
package_upgrade: true
packages: [$(IFS=,; p="${APT_PKGS[*]}"; echo "${p//,/, }")]
runcmd:
  - [usermod, -aG, docker, ubuntu]
  - [loginctl, enable-linger, ubuntu]
  - [touch, /var/lib/cloud/instance/ffs-ready]
EOF
  (umask 077 && make_iso "${SEED}" cidata "${seed_dir}/user-data" "${seed_dir}/meta-data") || exit 1
  rm -rf "${seed_dir}"
  # (the base by its name, relative to the disk: FFS_VM_DIR can be moved)
  (cd -- "${VM_DIR}" && qemu-img create -q -f qcow2 -b "$(basename "${base}")" -F qcow2 disk.qcow2 "${DISK_SIZE}") || exit 1
  echo "${codename}" > "${RELEASE_FILE}"
  echo "${SSH_PORT}" > "${VM_DIR}/ssh-port"
  echo "${KEY}" > "${VM_DIR}/ssh-key"
  echo "created ${DISK} (${DISK_SIZE}, Ubuntu ${codename} ${IMG_ARCH}, ssh port ${SSH_PORT})"
}

# (from test, ssh...: a VM of FFS_VM_DIR, none made there unasked)
start_existing() {
  [ -f "${DISK}" ] || die "no VM in ${VM_DIR}: vm.sh create, or FFS_VM_DIR=<the folder of yours>"
  start
}
start() {
  running && { echo "already running"; return; }
  [ -f "${DISK}" ] || create
  host_check
  need "qemu-system-${QEMU_ARCH}" ssh
  find_firmware
  local cpus mem
  cpus=${CPUS:-$(($(host_cpus) * 3 / 4))} mem=${MEM:-$(($(host_mem_mb) / 2))}
  [ "${cpus}" -ge 1 ] || cpus=1
  if command -v lsof > /dev/null 2>&1 && lsof -nP -iTCP:"${SSH_PORT}" -sTCP:LISTEN -t > /dev/null 2>&1; then
    die "port ${SSH_PORT} is in use (another VM? a second one needs its own FFS_VM_DIR and SSH_PORT)"
  fi
  # cache=unsafe: a throwaway test VM, I/O speed over crash safety; discard: space freed
  # in the VM (fstrim) goes back to the host. The RTC on the host's clock, in UTC (driftfix,
  # catching up lost ticks, exists on x86 only); sync_clock does the rest
  local rtc=base=utc,clock=host
  [ "${QEMU_ARCH}" != x86_64 ] || rtc=${rtc},driftfix=slew
  "qemu-system-${QEMU_ARCH}" -machine "${MACHINE},accel=${ACCEL}" -cpu host -smp "${cpus}" -m "${mem}" -rtc "${rtc}" \
    -drive if=pflash,format=raw,readonly=on,file="${FW_CODE}" \
    -drive if=pflash,format=raw,file="${VARS}" \
    -drive if=virtio,format=qcow2,file="${DISK}",cache=unsafe,discard=unmap,detect-zeroes=unmap \
    -drive if=virtio,format=raw,file="${SEED}",readonly=on \
    -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" \
    -display none -serial file:"${VM_DIR}/console.log" \
    -daemonize -pidfile "${PIDFILE}" || exit 1
  printf 'booting (%s CPUs, %s MB, ssh port %s)' "${cpus}" "${mem}" "${SSH_PORT}"
  for _ in $(seq 1 120); do vssh true 2> /dev/null && break; printf '.'; sleep 3; done
  printf '\ncloud-init'
  for _ in $(seq 1 400); do vssh test -f /var/lib/cloud/instance/ffs-ready 2> /dev/null && break; printf '.'; sleep 3; done
  echo
  vssh test -f /var/lib/cloud/instance/ffs-ready < /dev/null || die "cloud-init not done: see ${VM_DIR}/console.log, vm.sh ssh 'cloud-init status --long'"
  # the first boot: provisioned once (vm.sh provision again for the latest tools)
  if ! vssh test -f .ffs/provisioned < /dev/null 2> /dev/null; then
    provision first || exit 1
    # (the upgraded kernel of the first boot)
    if vssh test -f /var/run/reboot-required < /dev/null; then say "rebooting (upgrades)"; stop; start; return; fi
  fi
  sync_clock
  vssh 'podman --version; docker --version; docker compose version' < /dev/null 2> /dev/null
}

# ---------- provisioning (in the VM) ----------
# the latest releases of the tools, each checked against its release's checksums, into
# ~/.local/bin (a version file per tool: downloaded again only when a newer one is out)
remote_tools() {
  cat <<'TOOLS'
set -euo pipefail
arch=$(dpkg --print-architecture)
bin=~/.local/bin stamps=~/.local/share/ffs-tools
mkdir -p "${bin}" "${stamps}" ~/.ct
tmp=$(mktemp -d); trap 'rm -rf "${tmp}"' EXIT
cd "${tmp}"
# latest <owner/repo>: the tag of its latest release (the redirect of /releases/latest, no API quota)
latest() {
  local t; t=$(curl -fsSI "https://github.com/$1/releases/latest" | tr -d '\r' | sed -n 's|^[Ll]ocation: .*/releases/tag/||p')
  [[ "${t}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "no latest release of $1 (${t})" >&2; return 1; }
  echo "${t}"
}
get() { curl -fsSL --retry 3 -o "$2" "$1"; }
# verify <file> <sha256>
verify() { [[ "$2" =~ ^[0-9a-f]{64}$ ]] && echo "$2  $1" | sha256sum -c --quiet - || { echo "checksum of $1 does not match" >&2; return 1; }; }
# sum_of <file> <checksums file>: the sum of that file in a "<sha>  [*]<name>" list
sum_of() { awk -v f="$1" '{ n = $2; sub(/^\*/, "", n) } n == f { print $1 }' "$2"; }
current() { cat "${stamps}/$1" 2> /dev/null || true; }
done_tool() { echo "$2" > "${stamps}/$1"; echo "$1 $2 (installed)"; }
same() { [ "$(current "$1")" = "$2" ] && [ -x "${bin}/$1" ] && { echo "$1 $2 (current)"; }; }

v=$(latest kubernetes-sigs/kind)
same kind "${v}" || {
  u=https://github.com/kubernetes-sigs/kind/releases/download/${v}/kind-linux-${arch}
  get "${u}" kind; get "${u}.sha256sum" kind.sha
  verify kind "$(awk '{print $1}' kind.sha)"
  install -m 755 kind "${bin}/kind"; done_tool kind "${v}"; }

v=$(latest helm/helm)
same helm "${v}" || {
  f=helm-${v}-linux-${arch}.tar.gz
  get "https://get.helm.sh/${f}" "${f}"; get "https://get.helm.sh/${f}.sha256sum" helm.sha
  verify "${f}" "$(awk '{print $1}' helm.sha)"
  tar -xzf "${f}" "linux-${arch}/helm"; install -m 755 "linux-${arch}/helm" "${bin}/helm"; done_tool helm "${v}"; }

v=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
[[ "${v}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "no stable kubectl (${v})" >&2; exit 1; }
same kubectl "${v}" || {
  u=https://dl.k8s.io/release/${v}/bin/linux/${arch}/kubectl
  get "${u}" kubectl; get "${u}.sha256" kubectl.sha
  verify kubectl "$(awk '{print $1}' kubectl.sha)"
  install -m 755 kubectl "${bin}/kubectl"; done_tool kubectl "${v}"; }

v=$(latest helm/chart-testing)
same ct "${v}" || {
  f=chart-testing_${v#v}_linux_${arch}.tar.gz
  u=https://github.com/helm/chart-testing/releases/download/${v}
  get "${u}/${f}" "${f}"; get "${u}/checksums.txt" ct.sums
  verify "${f}" "$(sum_of "${f}" ct.sums)"
  mkdir ct && tar -xzf "${f}" -C ct
  install -m 755 ct/ct "${bin}/ct"; cp ct/etc/* ~/.ct/; done_tool ct "${v}"; }

v=$(latest yannh/kubeconform)
same kubeconform "${v}" || {
  f=kubeconform-linux-${arch}.tar.gz
  u=https://github.com/yannh/kubeconform/releases/download/${v}
  get "${u}/${f}" "${f}"; get "${u}/CHECKSUMS" kc.sums
  verify "${f}" "$(sum_of "${f}" kc.sums)"
  tar -xzf "${f}" kubeconform; install -m 755 kubeconform "${bin}/kubeconform"; done_tool kubeconform "${v}"; }

# yamllint and yamale (chart-testing's lint): their latest on PyPI, with pipx (pip checks the
# downloads against the index's hashes)
for p in yamllint yamale; do
  if pipx list --short 2> /dev/null | grep -q "^${p} "; then pipx upgrade -q "${p}" > /dev/null 2>&1; else pipx install -q "${p}" > /dev/null 2>&1; fi
  echo "${p} $(pipx list --short | awk -v p="${p}" '$1 == p {print $2}')"
done
TOOLS
}

# yes_to <question>: a yes on the terminal (none: no)
yes_to() {
  local a
  { [ -t 0 ] && [ -r /dev/tty ]; } || return 1
  printf '%s [y/N] ' "$1" > /dev/tty
  read -r a < /dev/tty || return 1
  case "${a}" in y | Y | yes | YES) return 0 ;; esac
  return 1
}
# docker login to ghcr.io in the VM, for private images: with FFS_GHCR_TOKEN (read:packages
# only), else `gh auth token` with FFS_GHCR_GH=1 or a yes; the token through stdin, never printed
ghcr_login() {
  local token="" user=${FFS_GHCR_USER:-} repo
  repo=$(images_repo)
  if [ -n "${FFS_GHCR_TOKEN:-}" ]; then
    token=${FFS_GHCR_TOKEN}
  elif command -v gh > /dev/null 2>&1 && gh auth token > /dev/null 2>&1 &&
    { [ "${FFS_GHCR_GH:-}" = 1 ] || yes_to "vm.sh: no FFS_GHCR_TOKEN. Log the VM's docker in to ghcr.io with your gh token? It has all of gh's scopes and stays in the VM's ~/.docker/config.json"; }; then
    token=$(gh auth token) user=${user:-$(gh api user --jq .login 2> /dev/null)}
  else
    say "docker not logged in to ghcr.io: public images work without; private ones (such as ${repo}, if it is) need FFS_GHCR_TOKEN=<a token with read:packages only> vm.sh provision"
    return 0
  fi
  [ -n "${user}" ] || user=$(echo "${repo}" | cut -d/ -f2)
  # (ssh checks the VM's host key; and the port is qemu's)
  if command -v lsof > /dev/null 2>&1 && [ "$(lsof -nP -iTCP:"${SSH_PORT}" -sTCP:LISTEN -t 2> /dev/null | sort -u)" != "$(cat "${PIDFILE}")" ]; then
    say "port ${SSH_PORT} is not only qemu's (pid $(cat "${PIDFILE}")): no docker login"
    return 1
  fi
  if printf '%s\n' "${token}" | vssh "docker login ghcr.io -u '${user}' --password-stdin" > /dev/null 2>&1; then
    say "docker logged in to ghcr.io as ${user}"
  else
    say "docker login to ghcr.io failed (private images will not pull)"
  fi
}

provision() { # [first: the first boot, from start (nothing runs in the VM yet)]
  running || { say "VM not running (vm.sh start)"; return 1; }
  if [ -z "${1:-}" ]; then
    locks_dir
    slot_clear_stale
    [ "$(slots_in_use)" = 0 ] || { say "slots in use ($(slots_brief)): provision once they are free"; return 1; }
  fi
  say "provisioning: apt packages"
  vssh "set -e; sudo cloud-init status --wait > /dev/null 2>&1 || true
    apt() { sudo DEBIAN_FRONTEND=noninteractive apt-get -qq \"\$@\"; }
    apt update
    apt install -y ${APT_PKGS[*]} > /dev/null
    apt upgrade -y > /dev/null
    # chrony steps a clock that is off by more than a second whenever it can (not only in
    # its first updates), for when a time source answers after the host slept
    echo 'makestep 1 -1' | sudo tee /etc/chrony/conf.d/ffs-makestep.conf > /dev/null
    sudo systemctl enable --now chrony > /dev/null 2>&1 && sudo systemctl restart chrony || true
    sudo usermod -aG docker ubuntu
    sudo loginctl enable-linger ubuntu
    # ~/.local/bin on PATH for every shell, also the non-interactive ones of ssh (before
    # .bashrc returns for them)
    grep -q 'ffs: ~/.local/bin' ~/.bashrc || sed -i '1i export PATH=\"\$HOME/.local/bin:\$PATH\" # ffs: ~/.local/bin' ~/.bashrc
    lsb_release -ds; uname -r" < /dev/null || { say "apt provisioning failed"; return 1; }
  if [ -f "${REPO}/.github/scripts/pasta-apparmor.sh" ]; then
    say "provisioning: ${REPO}/.github/scripts/pasta-apparmor.sh"
    vssh 'bash -s' < "${REPO}/.github/scripts/pasta-apparmor.sh" || { say "pasta-apparmor.sh failed"; return 1; }
  fi
  say "provisioning: the latest kind, helm, kubectl, ct, kubeconform, yamllint, yamale"
  remote_tools | vssh 'bash -s' || { say "tools not installed"; return 1; }
  install_lib || return 1
  ghcr_login
  vssh 'date "+%F %T" > ~/.ffs/provisioned; [ ! -f /var/run/reboot-required ] || echo "vm.sh: a reboot is pending (vm.sh stop; vm.sh start)"' < /dev/null
  say "provisioned"
}

stop() {
  running || { echo "not running"; return; }
  vssh sudo poweroff 2> /dev/null
  for _ in $(seq 1 30); do running || break; sleep 1; done
  running && kill "$(cat "${PIDFILE}")"
  rm -f "${PIDFILE}"
}

# ---------- in the VM: ~/.ffs/lib.sh, installed by every command ----------
remote_lib() {
  cat <<'LIB'
# firefox-sync test VM helpers (written by vm.sh on the host, do not edit here)
# ffs_hash <dir>: a hash of the files of a folder
ffs_hash() { (cd -- "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -c1-12); }

# ffs_image [--podman] <dir> <tag>...: <dir> built once per content as ffs-src-<dir>:<hash>
# (skipped when that tag is there), then tagged <tag>... (docker; --podman: podman)
ffs_image() {
  local runtime=docker
  [ "${1:-}" = --podman ] && { runtime=podman; shift; }
  local dir=${1:?ffs_image [--podman] <dir> <tag>...}; shift
  [ -d "${dir}" ] || { echo "ffs_image: no ${dir}" >&2; return 1; }
  local abs name hash src t
  abs=$(cd -- "${dir}" && pwd)
  name=ffs-src-$(echo "${dir%/}" | tr '[:upper:]/' '[:lower:]-' | tr -cd 'a-z0-9_.-')
  hash=$(ffs_hash "${abs}")
  src=${name}:${hash}
  [ "${runtime}" = podman ] && src=localhost/${src}
  if ! ${runtime} image inspect "${src}" > /dev/null 2>&1; then
    # one build of it at a time (two of one tag at once fail), then maybe built already
    exec {lk}> "/tmp/ffs-build-${runtime}-${name}.lock"
    flock "${lk}"
    if ! ${runtime} image inspect "${src}" > /dev/null 2>&1; then
      echo "ffs_image: building ${dir} (${src}, ${runtime})" >&2
      if [ "${runtime}" = podman ]; then
        podman build -q --format docker -t "${src}" "${abs}" > /dev/null || { exec {lk}>&-; return 1; }
      else
        # with BuildKit (Dockerfiles with BUILDPLATFORM): compose's builder, no buildx here
        local f; f=$(mktemp --suffix .yml)
        printf 'services:\n  image:\n    image: %s\n    build: %s\n' "${src}" "${abs}" > "${f}"
        COMPOSE_BAKE=false docker compose -p "ffs-src-build-$$" -f "${f}" build -q > /dev/null || { rm -f "${f}"; exec {lk}>&-; return 1; }
        rm -f "${f}"
      fi
    fi
    exec {lk}>&-
  fi
  for t in "$@"; do ${runtime} tag "${src}" "${t}" || return 1; done
  echo "${hash}"
}

# ffs_disk <GB>: at least that much free on /, after pruning what no one uses; else waits
ffs_disk() {
  local need=$1 free waited=0
  free() { df -BG --output=avail / | tail -1 | tr -dc 0-9; }
  [ "$(free)" -ge "${need}" ] && return 0
  echo "== disk: $(free) GB free, ${need} needed: pruning build cache, dangling images, unused anonymous volumes"
  docker builder prune -f > /dev/null 2>&1
  docker image prune -f > /dev/null 2>&1
  docker volume prune -f > /dev/null 2>&1
  podman image prune -f > /dev/null 2>&1
  [ "$(free)" -ge "${need}" ] && return 0
  docker builder prune -af > /dev/null 2>&1
  while [ "$(free)" -lt "${need}" ]; do
    [ $((waited % 300)) = 0 ] && echo "== disk: $(free) GB free, ${need} needed: waiting for other runs (vm.sh prune frees more)"
    [ "${waited}" -ge 7200 ] && { echo "== disk: still not enough after 2 hours"; return 1; }
    sleep 30; waited=$((waited + 30))
  done
}

# ffs_lock <file> <what>: an exclusive lock on fd 9..., saying it waits
ffs_wait_lock() { # fd file what [-s]
  local fd=$1 file=$2 what=$3 mode=${4:--x}
  eval "exec ${fd}> \"\${file}\""
  flock -n "${mode}" "${fd}" && return 0
  echo "== waiting for ${what}"
  flock "${mode}" "${fd}"
}

# the compose projects (and their volumes, networks, database servers) of a slot: 0 those
# without -s<N> at the end
ffs_slot_projects() {
  local slot=$1 re
  if [ "${slot}" = 0 ]; then re='^(ffs-e2e-|ffs-fxa-upgrade|mig-(src|dst)-)'; else re="^(ffs-e2e-|ffs-fxa-upgrade|mig-(src|dst)-).*-s${slot}\$"; fi
  { docker ps -a --format '{{.Label "com.docker.compose.project"}}'
    docker volume ls --format '{{.Label "com.docker.compose.project"}}'
    docker network ls --format '{{.Label "com.docker.compose.project"}}'; } 2> /dev/null |
    grep -E "${re}" | { [ "${slot}" = 0 ] && grep -vE -- '-s[0-9]+$' || cat; } | sort -u
}
ffs_slot_clean() {
  local slot=$1 p c
  for p in $(ffs_slot_projects "${slot}"); do
    echo "== slot ${slot}: removing what is left of ${p}"
    docker ps -aq --filter "label=com.docker.compose.project=${p}" | xargs -r docker rm -f > /dev/null 2>&1
    docker volume ls -q --filter "label=com.docker.compose.project=${p}" | xargs -r docker volume rm -f > /dev/null 2>&1
    docker volume ls -q | grep -E "^${p}_" | xargs -r docker volume rm -f > /dev/null 2>&1
    docker network ls -q --filter "label=com.docker.compose.project=${p}" | xargs -r docker network rm > /dev/null 2>&1
  done
  # the database servers of EXTERNAL_DB=1 (not compose's): <project>-extdb
  for c in $(docker ps -a --format '{{.Names}}' | grep -E -- '-extdb$'); do
    p=${c%-extdb}
    if { [ "${slot}" = 0 ] && ! [[ "${p}" =~ -s[0-9]+$ ]]; } || [[ "${p}" == *-s${slot} ]]; then
      docker rm -f "${c}" > /dev/null 2>&1; docker network rm "${c}" > /dev/null 2>&1
    fi
  done
  return 0
}

# ffs_run <slot> <kind|podman|-> <command>: the command in the slot (shared lock: the next
# command of the slot waits for it), killed with its processes when the connection to the
# host ends (vm.sh gone, Ctrl-C): SIGTERM, their traps tear down, SIGKILL after 3 minutes.
# The "== " lines get the time since the start
ffs_run() {
  local slot=$1 needs=$2 cmd=$3 t0 pidf fifo pid rc watch stamp
  ffs_wait_lock 9 "/tmp/ffs-slot-${slot}.lock" "the end of the last run of slot ${slot}" -s
  case ",${needs}," in *,kind,*) ffs_wait_lock 8 /tmp/ffs-kind.lock "the kind cluster of another slot" ;; esac
  case ",${needs}," in *,podman,*) ffs_wait_lock 7 /tmp/ffs-podman.lock "the podman test of another slot (the Quadlets have one set of names)" ;; esac
  case ",${needs}," in *,kind,*) ffs_disk 10 || return 1 ;; *) ffs_disk 8 || return 1 ;; esac
  exec 6<&0
  t0=$(date +%s) pidf=$(mktemp) fifo=$(mktemp -u)
  mkfifo "${fifo}"
  gawk -v t0="${t0}" -v all="${FFS_STAMP_ALL:-}" 'all != "" { e = systime() - t0; printf "[%02d:%02d] %s\n", e / 60, e % 60, $0; fflush(); next } /^== / { e = systime() - t0; printf "== [%02d:%02d] %s\n", e / 60, e % 60, substr($0, 4); fflush(); next } { print; fflush() }' < "${fifo}" 6<&- &
  stamp=$!
  # (with these helpers, and the tools of ~/.local/bin: kind, helm, kubectl)
  setsid -w bash -c 'echo $$ > "$0"; source ~/.ffs/lib.sh; export PATH=~/.local/bin:${PATH}; eval "$1"' "${pidf}" "${cmd}" < /dev/null > "${fifo}" 2>&1 6<&- &
  pid=$!
  ( cat <&6 > /dev/null
    [ -f "${pidf}" ] || exit 0
    g=$(cat "${pidf}"); [ -n "${g}" ] || exit 0
    kill -TERM -- "-${g}" 2> /dev/null || exit 0
    for _ in $(seq 1 180); do kill -0 -- "-${g}" 2> /dev/null || exit 0; sleep 1; done
    kill -KILL -- "-${g}" 2> /dev/null ) > /dev/null 2>&1 &
  watch=$!
  wait "${pid}"; rc=$?
  rm -f "${pidf}"
  kill "${watch}" 2> /dev/null
  wait "${stamp}"
  rm -f "${fifo}"
  return "${rc}"
}
LIB
}

install_lib() { remote_lib | vssh 'mkdir -p ~/.ffs && t=$(mktemp ~/.ffs/lib.XXXXXX) && cat > "$t" && mv "$t" ~/.ffs/lib.sh'; }

# ---------- slots, on the host ----------
SLOT_HELD=""
slot_owner_alive() { # slot dir
  local pid start
  pid=$(sed -n 's/^pid=//p' "$1/owner" 2> /dev/null) start=$(sed -n 's/^pidstart=//p' "$1/owner" 2> /dev/null)
  [ -n "${pid}" ] || return 1
  kill -0 "${pid}" 2> /dev/null || return 1
  [ -z "${start}" ] || [ "$(ps -o lstart= -p "${pid}" 2> /dev/null)" = "${start}" ]
}
# locks_dir: FFS_VM_DIR and its slots, private
locks_dir() { private_dir "${VM_DIR}"; private_dir "${LOCKS}"; old_locks_cleanup; }
# the old shared /tmp/ffs-vm-slots (SSH_PORT 2222), when it is a folder of yours: a slot held
# there by a live command is busy; with none, its kept slots move here and it is removed
old_locks_mine() { [ "${SSH_PORT}" = 2222 ] && [ -d "${OLD_LOCKS}" ] && [ ! -L "${OLD_LOCKS}" ] && [ -O "${OLD_LOCKS}" ]; }
old_slot_busy() { old_locks_mine && [ -d "${OLD_LOCKS}/$1" ] && slot_owner_alive "${OLD_LOCKS}/$1"; }
old_locks_cleanup() {
  old_locks_mine || return 0
  local d f
  for d in "${OLD_LOCKS}"/[0-9]*; do [ -d "${d}" ] && slot_owner_alive "${d}" && return 0; done
  for f in "${OLD_LOCKS}"/[0-9]*.kept; do
    [ -f "${f}" ] && [ ! -L "${f}" ] && [ ! -e "${LOCKS}/${f##*/}" ] && write_new "${LOCKS}/${f##*/}" "$(cat "${f}")"
  done
  rm -rf "${OLD_LOCKS}"
}
slot_clear_stale() {
  local d
  for d in "${LOCKS}"/[0-9]*; do
    [ -d "${d}" ] || continue
    # (a slot being taken: no owner file yet for a moment)
    [ -f "${d}/owner" ] || { [ -n "$(find "${d}" -maxdepth 0 -mmin +1 2> /dev/null)" ] && rm -rf "${d}"; continue; }
    slot_owner_alive "${d}" || { say "slot ${d##*/}: its holder ($(sed -n 's/^cmd=//p' "${d}/owner")) is gone, freed"; rm -rf "${d}"; }
  done
}
slots_in_use() {
  local n=0 d
  for d in "${LOCKS}"/[0-9]*; do [ -d "${d}" ] && n=$((n + 1)); done
  for d in $(seq 0 $((SLOTS - 1))); do old_slot_busy "${d}" && n=$((n + 1)); done
  echo "${n}"
}
# take_slot <what>: SLOT_HELD, waiting for a free one (SLOT: that one)
take_slot() {
  local what=$1 n candidates waited=0
  locks_dir
  while :; do
    slot_clear_stale
    if [ -n "${SLOT:-}" ]; then
      candidates=${SLOT}
    else
      candidates=""
      for n in $(seq 0 $((SLOTS - 1))); do [ -f "${LOCKS}/${n}.kept" ] || candidates="${candidates} ${n}"; done
    fi
    for n in ${candidates}; do
      old_slot_busy "${n}" && continue
      if mkdir "${LOCKS}/${n}" 2> /dev/null; then
        local me; set_mypid; me=${MYPID}
        (set -C; printf 'pid=%s\npidstart=%s\ncmd=%s\nrepo=%s\nsince=%s\n' "${me}" "$(ps -o lstart= -p "${me}")" "${what}" "${REPO}" "$(date '+%F %T')" > "${LOCKS}/${n}/owner")
        SLOT_HELD=${n}
        return 0
      fi
    done
    [ $((waited % 60)) = 0 ] && say "waiting for a free slot ($(slots_brief))"
    sleep 5; waited=$((waited + 5))
  done
}
release_slot() {
  [ -n "${SLOT_HELD}" ] || return 0
  set_mypid
  [ "$(sed -n 's/^pid=//p' "${LOCKS}/${SLOT_HELD}/owner" 2> /dev/null)" = "${MYPID}" ] && rm -rf "${LOCKS:?}/${SLOT_HELD}"
  SLOT_HELD=""
}
slots_brief() {
  local d out=""
  for d in "${LOCKS}"/[0-9]*; do [ -d "${d}" ] && out="${out}${out:+, }${d##*/}: $(sed -n 's/^cmd=//p' "${d}/owner" 2> /dev/null || true)"; done
  out=$(echo "${out}" | sed 's/: ,/: (being taken),/g; s/: $/: (being taken)/')
  echo "${out:-none in use}"
}
on_exit() {
  local rc=$?
  release_slot
  set_mypid; [ "${MYPID}" = "$$" ] && rm -f "${FFS_VM_COPY:-}"
  exit "${rc}"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# slot_vssh <needs> <command>: the command in the slot through ffs_run, ended in the VM when
# this ends (its stdin: a pipe open as long as this script runs)
slot_vssh() {
  local needs=$1 cmd=$2 me; set_mypid; me=${MYPID}
  vssh "source ~/.ffs/lib.sh && FFS_STAMP_ALL=${STAMP_ALL:-} ffs_run ${SLOT_HELD} ${needs:--} $(printf '%q' "${cmd}")" \
    < <(while kill -0 "${me}" 2> /dev/null; do sleep 2; done)
}
slot_dir() { echo "firefox-sync-slot${SLOT_HELD}"; }

# the slot taken for a command: the VM up, the lib installed, the slot's earlier runs over
# (in the VM too), the slot's checkout synced
enter_slot() { # what [nosync]
  need ssh rsync git
  [ -d "${REPO}" ] || die "REPO: no ${REPO}"
  [ -f "${DISK}" ] || start_existing
  take_slot "$1"
  running || start_existing
  install_lib || { say "VM not reachable"; exit 1; }
  sync_clock
  # the end of what ran in this slot before (a run stopped from the host tears down for a while)
  vssh "source ~/.ffs/lib.sh && ffs_wait_lock 9 /tmp/ffs-slot-${SLOT_HELD}.lock 'the end of the last run of slot ${SLOT_HELD}' && mkdir -p ~/.ffs/cwd/${SLOT_HELD} && ln -sfn ~/$(slot_dir) ~/.ffs/cwd/${SLOT_HELD}/firefox-sync" < /dev/null
  [ -n "${2:-}" ] || sync_slot
}
# the guest's clock set to the host's when they are more than CLOCK_SLACK (5) seconds apart.
# HVF and KVM stop the guest's counter while the host sleeps, and its chrony then has no source
# it can reach in time (or none: NTS through user networking): after a night the guest was
# hours behind, and apt refused the Release files signed "in the future". The host is the
# reference; a step forward is what a real machine does after resuming
sync_clock() {
  local guest host drift
  guest=$(vssh 'date +%s' < /dev/null 2> /dev/null) || return 0
  # (what the guest says is a number, or it is not used: see number above)
  [[ "${guest}" =~ ^[0-9]+$ ]] || return 0
  host=$(date +%s)
  drift=$((host - 10#${guest}))
  [ "${drift#-}" -gt "${CLOCK_SLACK:-5}" ] || return 0
  say "the VM's clock is ${drift} s off the host's: set to the host's"
  vssh "sudo date -u -s @$(date +%s) > /dev/null && (sudo hwclock --systohc 2> /dev/null || true)" < /dev/null ||
    say "could not set the VM's clock"
}
sync_slot() {
  rsync -a --delete --exclude .git -e "ssh ${SSH_OPTS[*]}" "${REPO}/" "ubuntu@127.0.0.1:$(slot_dir)/" ||
    { say "rsync of ${REPO} failed"; exit 1; }
}
# after a command: the slot's projects removed, unless KEEP=1 (then the slot is kept)
leave_slot() {
  if [ -n "${KEEP:-}" ]; then
    write_new "${LOCKS}/${SLOT_HELD}.kept" "$(date '+%F %T')"
    say "slot ${SLOT_HELD} kept (KEEP=1): SLOT=${SLOT_HELD} for commands on it, vm.sh release ${SLOT_HELD} to tear it down"
  else
    # (after what still runs in the slot: a run stopped from here tears down first)
    vssh "source ~/.ffs/lib.sh && ffs_wait_lock 9 /tmp/ffs-slot-${SLOT_HELD}.lock 'the teardown of slot ${SLOT_HELD}' && ffs_slot_clean ${SLOT_HELD}" < /dev/null
    rm -f "${LOCKS}/${SLOT_HELD}.kept"
  fi
}

# ---------- trees of REPO's history ----------
# vm_rev <commit or tag of REPO>: its tree in the VM (~/.ffs/rev/<commit>), extracted with git
# archive when missing (no .git in it, as the slots' checkouts)
vm_rev() {
  local sha d
  sha=$(git -C "${REPO}" rev-parse --verify -q --short=7 "$1^{commit}") || { say "$1: not a commit of ${REPO}"; return 1; }
  d=/home/ubuntu/.ffs/rev/${sha}
  if ! vssh "test -d ${d}" < /dev/null; then
    say "extracting ${sha} of ${REPO} into ${d}"
    git -C "${REPO}" archive "${sha}" |
      vssh "mkdir -p ~/.ffs/rev && t=\$(mktemp -d ${d}.XXXXXX) && tar -x -C \$t && { mv -T \$t ${d} 2> /dev/null || rm -rf \$t; }" ||
      { say "${sha} not extracted"; return 1; }
  fi
  echo "${d}"
}
# UPGRADE_FROM=<commit or tag>: the path of its tree in the VM (an absolute path: as it is)
resolve_upgrade_from() {
  case "${UPGRADE_FROM:-}" in
    "" | /*) ;;
    *) UPGRADE_FROM=$(vm_rev "${UPGRADE_FROM}") || exit 1 ;;
  esac
}

# ---------- images ----------
# what the tests of the slot use: INIT_TAG, ADMIN_IMAGE (built from the checkout once per
# content), the published app images refreshed. $1: podman too
IMG_ENV=""
prepare_images() {
  local podman=${1:-} repo out
  repo=$(images_repo)
  if [ -z "${OFFLINE:-}" ] && [ -z "${PULL:-}" ]; then
    vssh "for t in syncstorage-rs-mysql-latest syncstorage-rs-postgres-latest fxa-mono-latest fxa-channelserver-latest; do docker pull -q '${repo}:'\$t > /dev/null || echo \"could not pull \$t\"; done" < /dev/null
    [ -z "${podman}" ] || vssh "for t in syncstorage-rs-mysql-latest syncstorage-rs-postgres-latest; do podman pull -q '${repo}:'\$t > /dev/null 2>&1 || echo \"podman: could not pull \$t\"; done" < /dev/null
  fi
  # one tag for both init images (tests/podman.sh uses both): the hash of the two
  out=$(vssh "source ~/.ffs/lib.sh && cd $(slot_dir) && set -e
    tag=src-\$( (ffs_hash db/mysql/init; ffs_hash db/postgres/init) | sha256sum | cut -c1-12)
    admin=ffs-admin:src-\$(ffs_hash admin)
    if [ -z '${PULL:-}' ]; then
      for b in mysql postgres; do ffs_image db/\$b/init '${repo}':syncstorage-rs-\$b-init-\$tag > /dev/null; done
      [ -z '${podman}' ] || for b in mysql postgres; do ffs_image --podman db/\$b/init '${repo}':syncstorage-rs-\$b-init-\$tag > /dev/null; done
      echo INIT_TAG=\$tag
    fi
    if [ -z '${ADMIN_IMAGE:-}' ]; then
      ffs_image admin \$admin > /dev/null
      [ -z '${podman}' ] || ffs_image --podman admin \$admin > /dev/null
      echo ADMIN_IMAGE=\$admin
    fi" < /dev/null) || { say "images not built"; return 1; }
  IMG_ENV=$(echo "${out}" | grep -E '^(INIT_TAG|ADMIN_IMAGE)=' | paste -sd' ' -)
}

# ---------- tests ----------
# a job: "[VAR=value ...] suite"; its name for the logs: suite.VAR-value...
job_suite() { echo "${1##* }"; }
job_vars() { local s=$1; [ "${s}" = "${s% *}" ] && return; echo "${s% *}"; }
job_name() { local v; v=$(job_vars "$1"); echo "$(job_suite "$1")${v:+.$(echo "${v}" | tr ' =' '.-')}"; }
# what may not run twice at once in one slot (the same project and ports)
job_identity() {
  local suite vars
  suite=$(job_suite "$1") vars=$(job_vars "$1")
  case "${suite}" in
    e2e-mysql) [[ " ${vars} " == *" SYNC_DB=mysql "* ]] && echo e2e-mysql84 || echo e2e-mysql ;;
    # (one kind cluster at a time in the VM: these run one after another, see run_jobs)
    helm-mariadb|helm-mysql|helm-postgres|helm-fxa-*) echo kind ;;
    *) echo "${suite}" ;;
  esac
}
test_env() { # job vars
  local v e=() extra=$1
  for v in "${PASS_ENV[@]}"; do [ -n "${!v:-}" ] && e+=("${v}=$(printf '%q' "${!v}")"); done
  [ -n "${REPOSITORY:-}" ] || e+=("REPOSITORY=$(images_repo)")
  [ -n "${TAG:-}" ] || e+=(TAG=latest)
  [ -n "${PULL:-}" ] || e+=(SKIP_PULL=1)
  echo "${e[*]} ${IMG_ENV} SLOT=${SLOT_HELD} ${extra}"
}
BINFMT="docker run --privileged --rm tonistiigi/binfmt:latest --install amd64 > /dev/null 2>&1"
run_one() { # job
  local suite vars env needs=-
  suite=$(job_suite "$1") vars=$(job_vars "$1")
  env=$(test_env "${vars}")
  local cd; cd="cd $(slot_dir) && export ${env}"
  case ${suite} in
    e2e-mysql)    slot_vssh - "${cd} && tests/e2e.sh mysql" ;;
    e2e-postgres) slot_vssh - "${cd} && tests/e2e.sh postgres" ;;
    e2e-fxa)      slot_vssh - "${BINFMT}; ${cd} && tests/e2e-fxa.sh" ;;
    fxa-upgrade)  slot_vssh - "${BINFMT}; ${cd} && tests/fxa-upgrade.sh" ;;
    podman)       slot_vssh podman "${BINFMT}; ${cd} && export XDG_RUNTIME_DIR=/run/user/\$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\$(id -u)/bus && tests/podman.sh" ;;
    # (the chart's: chart 0.1.0 of the parity check, as for vm.sh ssh; the kind lock)
    helm-lint)    slot_vssh - "${cd} && $(parity_export)tests/helm.sh lint" ;;
    helm-mariadb|helm-mysql|helm-postgres) slot_vssh kind "${cd} && $(parity_export)tests/helm.sh e2e ${suite#helm-}" ;;
    helm-fxa-mysql|helm-fxa-mariadb) slot_vssh kind "${cd} && $(parity_export)tests/helm-fxa.sh e2e ${suite#helm-fxa-}" ;;
    *) echo "unknown test ${suite}"; return 2 ;;
  esac
}
known_suite() {
  case "$1" in
    e2e-mysql|e2e-postgres|e2e-fxa|fxa-upgrade|podman|helm-lint|helm-mariadb|helm-mysql|helm-postgres|helm-fxa-mysql|helm-fxa-mariadb) return 0 ;;
  esac
  return 1
}

# run_jobs <logs> <job>...: in one slot, at once (one job: in the foreground)
run_jobs() {
  local logs=$1 j podman="" ids="" id; shift
  for j in "$@"; do
    known_suite "$(job_suite "${j}")" || { echo "unknown test $(job_suite "${j}")"; return 2; }
    id=$(job_identity "${j}")
    [ "${id}" != kind ] && [[ " ${ids} " == *" ${id} "* ]] && { echo "${j}: twice the same project in one slot, run it in another command"; return 2; }
    ids="${ids} ${id}"
    [ "$(job_suite "${j}")" = podman ] && podman=1
  done
  enter_slot "test $*"
  resolve_upgrade_from
  say "slot ${SLOT_HELD} (~/$(slot_dir)): $* (images: $(images_repo):${TAG:-latest})"
  prepare_images "${podman}" || return 1
  local rc=0
  if [ $# = 1 ] && [ -z "${logs}" ]; then
    run_one "$1"; rc=$?
  else
    mkdir -p "${logs}"
    local pids=() kind_jobs=()
    run_logged() { # job
      local s r
      s=$(date +%s); run_one "$1" > "${logs}/$(job_name "$1").log" 2>&1; r=$?
      echo "${r} $(( $(date +%s) - s )) ${SLOT_HELD}" > "${logs}/$(job_name "$1").rc"
    }
    for j in "$@"; do
      # (the kind ones: one after another, next to the others)
      [ "$(job_identity "${j}")" = kind ] && { kind_jobs+=("${j}"); continue; }
      run_logged "${j}" &
      pids+=($!)
    done
    if [ ${#kind_jobs[@]} -gt 0 ]; then
      ( for j in "${kind_jobs[@]}"; do run_logged "${j}"; done ) &
      pids+=($!)
    fi
    wait "${pids[@]}"
    for j in "$@"; do [ "$(cut -d' ' -f1 "${logs}/$(job_name "${j}").rc" 2> /dev/null)" = 0 ] || rc=1; done
  fi
  leave_slot
  return "${rc}"
}

summary() { # logs t0 job...
  local logs=$1 t0=$2 failed=0 j rc secs slot; shift 2
  for j in "$@"; do
    rc=1 secs=0 slot='?'
    read -r rc secs slot < "${logs}/$(job_name "${j}").rc" 2> /dev/null
    [[ "${secs}" =~ ^[0-9]+$ ]] || secs=0
    printf '%-34s %s  %dm%02ds  slot %s  %s\n' "$(job_name "${j}")" "$([ "${rc}" = 0 ] && echo PASS || echo FAIL)" $((secs / 60)) $((secs % 60)) "${slot}" "${logs}/$(job_name "${j}").log"
    [ "${rc}" = 0 ] || { failed=1; grep -E '^FAIL|^FAILED|^vm.sh: ' "${logs}/$(job_name "${j}").log" | head -10 | sed 's/^/    /'; }
  done
  local all=$(( $(date +%s) - t0 ))
  echo "total: $((all / 60))m$(printf '%02d' $((all % 60)))s, $([ ${failed} = 0 ] && echo 'all passed' || echo 'some FAILED')"
  return ${failed}
}

new_logs() {
  local t=${TMPDIR:-/tmp}
  if [ -n "${LOGS:-}" ]; then echo "${LOGS}"; else mktemp -d "${t%/}/ffs-vm-tests-$(date +%Y%m%d-%H%M%S)-XXXXXX"; fi
}

run_test() {
  [ $# -ge 1 ] || { echo "vm.sh test <e2e-mysql|e2e-postgres|e2e-fxa|podman|fxa-upgrade|helm-lint|helm-<backend>|helm-fxa-<db>|all|affected> ..."; return 2; }
  case "$1" in
    affected) shift; run_affected "$@"; return ;;
    all) shift; set -- "${SUITES_ALL[@]}" "$@" ;;
  esac
  if [ $# = 1 ]; then
    # one suite: its output here
    run_jobs "" "$1"
    return
  fi
  local logs t0; logs=$(new_logs) t0=$(date +%s)
  run_jobs "${logs}" "$@"
  summary "${logs}" "${t0}" "$@"
}

# ---------- affected ----------
# the jobs the changed files need (unknown: all)
affected_jobs() { # files...
  local f jobs="" all=0
  add() { local j; for j in "$@"; do [[ "|${jobs}|" == *"|${j}|"* ]] || jobs="${jobs}${jobs:+|}${j}"; done; }
  for f in "$@"; do
    # the chart's parity with compose (tests/helm.sh lint) reads these too
    case "${f}" in
      compose/*|docker-compose*.yml|.env-example|config/backup/*|config/fxa/*|db/*) add helm-lint ;;
    esac
    case "${f}" in
      .github/*) ;;
      # the pages tests read commands from (doc contracts): e2e.sh and podman.sh restore
      # from docs/backups.md, podman.sh upgrades from docs/upgrading.md
      docs/backups.md)
        add e2e-mysql e2e-postgres podman
        # (and tests/helm.sh, tests/helm-fxa.sh those of #restore-on-kubernetes)
        if git -C "${REPO}" diff "${BASE_REF}" -- "${f}" 2> /dev/null | grep -q '^[-+].*kubectl'; then add helm-mysql helm-postgres helm-fxa-mysql; fi ;;
      docs/upgrading.md|docs/migrating.md) add podman ;;
      *.md|docs/*|LICENSE|.gitignore) ;;
      admin/*)
        add e2e-mysql e2e-postgres e2e-fxa
        # the admin UI's Quadlet side (its deployment mode, the units it reads)
        if [[ "${f}" == *[Qq]uadlet* ]] || git -C "${REPO}" diff "${BASE_REF}" -- "${f}" 2> /dev/null | grep -qi quadlet; then add podman; fi
        # and its Kubernetes side (ADMIN_DEPLOYMENT=kubernetes, the helm commands)
        if [[ "${f}" == *[Kk]ube* || "${f}" == *k8s* || "${f}" == *[Hh]elm* ]] || git -C "${REPO}" diff "${BASE_REF}" -- "${f}" 2> /dev/null | grep -qiE 'kube|k8s|helm'; then
          add helm-mysql
        fi ;;
      db/postgres/*) add e2e-postgres "EXTERNAL_DB=1 e2e-postgres" "SYNC_DB=postgres podman" ;;
      db/mysql/*) add e2e-mysql "SYNC_DB=mysql e2e-mysql" podman ;;
      config/quadlet/sync-postgres/*) add "SYNC_DB=postgres podman" ;;
      config/quadlet/*|docker-compose.podman.yml|compose/podman.yml) add podman ;;
      tests/healthy.sh) add "${SUITES_ALL[@]}" ;;
      docker-compose.fxa*.yml|compose/fxa*.yml|config/fxa/*) add e2e-fxa "FXA_DB=mariadb e2e-fxa" podman ;;
      docker-compose.sync-postgres.yml|docker-compose.postgres.yml|compose/sync-postgres.yml) add e2e-postgres "EXTERNAL_DB=1 e2e-postgres" podman "SYNC_DB=postgres podman" ;;
      docker-compose.sync-mysql.yml|compose/sync-mysql.yml) add "SYNC_DB=mysql e2e-mysql" podman ;;
      compose/sync-mariadb.yml) add e2e-mysql "EXTERNAL_DB=1 e2e-mysql" e2e-fxa podman ;;
      tests/e2e.sh|tests/docker-compose.test.yml|tests/compose/sync.yml|tests/test_admin_*.py|tests/test_client_flow.py|tests/test_upstream_patches.py|tests/notify_sink.py|tests/hung_syncserver.sh|tests/fake_dump_1412.sh|tests/dex.yml)
        add e2e-mysql e2e-postgres ;;
      tests/docker-compose.external-db-test.yml|tests/compose/external-db.yml) add "EXTERNAL_DB=1 e2e-mysql" "EXTERNAL_DB=1 e2e-postgres" ;;
      tests/docker-compose.external-db-fxa-test.yml|tests/compose/external-db-fxa.yml) add "EXTERNAL_DB=1 e2e-fxa" ;;
      tests/fxa-upgrade.sh|tests/test_fxa_upgrade.py) add fxa-upgrade ;;
      tests/test_fxa_*.py|tests/browser/*) add e2e-fxa helm-fxa-mysql ;;
      tests/e2e-fxa.sh|tests/docker-compose.fxa-test.yml|tests/compose/fxa.yml|tests/Caddyfile.fxa) add e2e-fxa ;;
      tests/docker-compose.admin-build.yml|tests/compose/admin-build.yml) add e2e-mysql e2e-postgres e2e-fxa ;;
      tests/podman.sh) add podman ;;
      # the chart: its lint, and on kind (one cluster at a time: in one slot, one after another)
      charts/firefox-sync/ci/*) add helm-lint ;;
      charts/firefox-sync/templates/fxa-*|charts/firefox-sync/templates/_fxa.tpl) add helm-lint helm-fxa-mysql "SKIP_BROWSER=1 helm-fxa-mariadb" ;;
      charts/*) add helm-lint helm-mysql helm-postgres helm-fxa-mysql ;;
      tests/helm-fxa.sh|tests/helm/fxa-*|tests/helm/traefik.yaml) add helm-lint helm-fxa-mysql ;;
      tests/helm.sh|tests/helm/mock-fxa.yaml) add helm-lint helm-mysql helm-postgres ;;
      tests/helm/lib.sh) add helm-lint helm-mysql helm-fxa-mysql ;;
      tests/helm/*|tests/helm_parity.py) add helm-lint ;;
      tests/slot.sh) all=1 ;;
      prepare_environment.sh) all=1 ;;
      *) all=1 ;;
    esac
  done
  [ "${all}" = 1 ] && add "${SUITES_ALL[@]}"
  echo "${jobs}"
}
run_affected() {
  local base=${1:-$(default_base)} files jobs
  BASE_REF=$(git -C "${REPO}" merge-base "${base}" HEAD) || { echo "no merge base of ${base} and HEAD in ${REPO}"; return 2; }
  files=$( { git -C "${REPO}" diff --name-only "${BASE_REF}" HEAD; git -C "${REPO}" diff --name-only HEAD; git -C "${REPO}" ls-files --others --exclude-standard; } | sort -u)
  # (fxa-upgrade needs FXA_FROM: only with it)
  # shellcheck disable=SC2086 # (one argument per file)
  jobs=$(affected_jobs ${files})
  [ -n "${FXA_FROM:-}" ] || jobs=$(echo "${jobs}" | tr '|' '\n' | grep -vx fxa-upgrade | paste -sd'|' -)
  echo "changed since ${base} ($(git -C "${REPO}" rev-parse --short "${BASE_REF}")): $(echo "${files}" | grep -c .) files"
  echo "${files}" | sed 's/^/  /' | head -40
  if [ -z "${jobs}" ]; then echo "plan: nothing to run here (docs, CI)"; return 0; fi
  # groups: jobs that can share a slot (not the same project twice); each group in its own slot
  local groups=() g j placed i
  IFS='|' read -r -a all_jobs <<< "${jobs}"
  for j in "${all_jobs[@]}"; do
    placed=""
    for i in "${!groups[@]}"; do
      local clash=""
      IFS='|' read -r -a members <<< "${groups[i]}"
      # (the kind ones together: run_jobs runs them one after another)
      for g in "${members[@]}"; do [ "$(job_identity "${g}")" = "$(job_identity "${j}")" ] && [ "$(job_identity "${j}")" != kind ] && clash=1; done
      [ -z "${clash}" ] && { groups[i]="${groups[i]}|${j}"; placed=1; break; }
    done
    [ -n "${placed}" ] || groups+=("${j}")
  done
  echo "plan:"
  local others kinds
  for i in "${!groups[@]}"; do
    others="" kinds=""
    IFS='|' read -r -a members <<< "${groups[i]}"
    for g in "${members[@]}"; do
      if [ "$(job_identity "${g}")" = kind ]; then kinds="${kinds:+${kinds} then }${g}"; else others="${others:+${others}, }${g}"; fi
    done
    echo "  slot $((i + 1)) of ${#groups[@]} (at once): ${others}${others:+${kinds:+, }}${kinds:+(${kinds})}"
  done
  [ -n "${PLAN_ONLY:-}" ] && return 0
  local logs t0 pids=(); logs=$(new_logs) t0=$(date +%s)
  mkdir -p "${logs}"
  running || start_existing
  for i in "${!groups[@]}"; do
    IFS='|' read -r -a members <<< "${groups[i]}"
    # (a subshell: its own slot, freed by its own traps)
    ( trap on_exit EXIT; trap 'exit 130' INT; trap 'exit 143' TERM HUP
      run_jobs "${logs}" "${members[@]}" > "${logs}/vm-${i}.log" 2>&1 ) &
    pids+=($!)
  done
  wait "${pids[@]}"
  summary "${logs}" "${t0}" "${all_jobs[@]}"
}

# the Python tests of e2e-fxa.sh again, against the stack of a KEEP=1 run, in its slot
rerun() {
  if [ -z "${SLOT:-}" ]; then
    local d; for d in "${LOCKS}"/*.kept; do [ -f "${d}" ] && SLOT=$(basename "${d}" .kept); done
    [ -n "${SLOT:-}" ] || { echo "no kept slot: run e2e-fxa with KEEP=1 first, or give SLOT"; return 2; }
  fi
  enter_slot "rerun ${1:-}"
  slot_vssh - "cd $(slot_dir) && SLOT=${SLOT_HELD} RERUN=1 ONLY='${1:-flow,admin,browser}' PYTEST_ARGS=$(printf '%q' "${2:-}") tests/e2e-fxa.sh"
  local rc=$?
  write_new "${LOCKS}/${SLOT_HELD}.kept" "$(date '+%F %T')"
  return "${rc}"
}

# parity_export: "export PARITY_BASE_CHART=<its tree in the VM> && " for a command of the helm
# tests, the chart of PARITY_BASE of REPO's tests/helm-fxa.sh (the slots have no .git); nothing
# when PARITY_BASE_CHART is set (passed as it is) or that tree is not there
parity_export() {
  [ -z "${PARITY_BASE_CHART:-}" ] || return 0
  local pb pd
  pb=$(sed -n 's/^PARITY_BASE=\${PARITY_BASE:-\([0-9A-Za-z._-]*\)}.*/\1/p' "${REPO}/tests/helm-fxa.sh" 2> /dev/null)
  if [ -n "${pb}" ] && pd=$(vm_rev "${pb}"); then echo "export PARITY_BASE_CHART=${pd}/charts/firefox-sync && "; fi
}

ssh_cmd() {
  local needs=-
  if [ $# = 0 ]; then
    enter_slot "ssh (shell)" ${NOSYNC:+nosync}
    say "slot ${SLOT_HELD}: ~/$(slot_dir) (SLOT=${SLOT_HELD})"
    vssh -t "cd ~/$(slot_dir) 2> /dev/null; SLOT=${SLOT_HELD} exec bash -l"
    return
  fi
  local cmd="$*"
  local kind_re='helm(-[a-z]+)?\.sh.*e2e|(^|[^a-z])kind([^a-z]|$)'
  if [ -n "${KIND:-}" ] || [[ "${cmd}" =~ ${kind_re} ]]; then needs=kind; fi
  # the podman suite run by hand takes the Podman lock too, as vm.sh test podman does: the
  # Quadlets have one set of names per VM user
  local podman_re='podman\.sh|(^|[^a-z_-])systemctl --user'
  if [ -n "${PODMAN:-}" ] || [[ "${cmd}" =~ ${podman_re} ]]; then
    if [ "${needs}" = - ]; then needs=podman; else needs="${needs},podman"; fi
  fi
  enter_slot "ssh ${cmd:0:60}" ${NOSYNC:+nosync}
  resolve_upgrade_from
  [ -z "${UPGRADE_FROM:-}" ] || cmd="export UPGRADE_FROM=${UPGRADE_FROM} && ${cmd}"
  # the helm tests' chart 0.1.0 (PARITY_BASE of tests/helm-fxa.sh): the slot has no .git
  if [[ "${cmd}" =~ helm(-fxa)?\.sh ]] && [[ "${cmd}" != *PARITY_BASE_CHART=* ]]; then
    cmd="$(parity_export)${cmd}"
  fi
  # and the images of `vm.sh test` (helm.sh's own default, the public repository, lags behind)
  if [[ "${cmd}" =~ helm(-fxa)?\.sh ]] && [[ "${cmd}" != *REPOSITORY=* ]]; then
    cmd="export REPOSITORY=$(images_repo) && ${cmd}"
  fi
  local rc
  if [ -n "${STDIN:-}" ]; then
    # stdin for the command (not stopped in the VM when this ends)
    vssh "cd ~/.ffs/cwd/${SLOT_HELD} && export SLOT=${SLOT_HELD} && ${cmd}"; rc=$?
  else
    slot_vssh "${needs}" "cd ~/.ffs/cwd/${SLOT_HELD} && export SLOT=${SLOT_HELD} && ${cmd}"; rc=$?
  fi
  [ -n "${KEEP:-}" ] && write_new "${LOCKS}/${SLOT_HELD}.kept" "$(date '+%F %T')"
  return "${rc}"
}

image_cmd() {
  [ $# -ge 2 ] || { echo "vm.sh image <dir> <tag>..."; return 2; }
  enter_slot "image $1"
  slot_vssh - "cd $(slot_dir) && ffs_image $(printf '%q ' "$@") && { [ -z '${PODMAN:-}' ] || ffs_image --podman $(printf '%q ' "$@"); }"
}

show_slots() {
  [ ! -d "${VM_DIR}" ] || locks_dir
  slot_clear_stale 2> /dev/null
  local n d
  for n in $(seq 0 $((SLOTS - 1))); do
    d=${LOCKS}/${n}
    if [ -d "${d}" ]; then
      printf 'slot %s  ~/firefox-sync-slot%s  %s (pid %s, since %s, %s)\n' "${n}" "${n}" "$(sed -n 's/^cmd=//p' "${d}/owner")" \
        "$(sed -n 's/^pid=//p' "${d}/owner")" "$(sed -n 's/^since=//p' "${d}/owner")" "$(sed -n 's/^repo=//p' "${d}/owner")"
    else
      printf 'slot %s  free\n' "${n}"
    fi
    [ -f "${LOCKS}/${n}.kept" ] && printf '        kept since %s (KEEP=1): vm.sh release %s\n' "$(cat "${LOCKS}/${n}.kept")" "${n}"
  done
  running || { echo "VM not running"; return 0; }
  vssh 'for l in /tmp/ffs-slot-*.lock /tmp/ffs-kind.lock /tmp/ffs-podman.lock; do [ -e "$l" ] || continue; flock -n "$l" true 2> /dev/null && continue; echo "in the VM: $(basename "$l" .lock) in use"; done
    echo "VM disk: $(df -BG --output=avail / | tail -1 | tr -d " ") free; load $(cut -d" " -f1-3 /proc/loadavg); kind: $(~/.local/bin/kind get clusters 2> /dev/null | paste -sd" " - | sed "s/^$/none/")"' < /dev/null 2> /dev/null
}

release_kept() {
  local n=${1:?vm.sh release <slot>}
  SLOT=${n} enter_slot "release ${n}" nosync
  vssh "source ~/.ffs/lib.sh && ffs_slot_clean ${n}" < /dev/null
  rm -f "${LOCKS}/${n}.kept"
}

# phases <log>: the time of each "== [mm:ss] ..." phase
phases() {
  awk '/^== \[[0-9][0-9]:[0-9][0-9]\] / {
      split(substr($2, 2, 5), t, ":"); s = t[1] * 60 + t[2]
      if (n) printf "%4ds  %s\n", s - prev, name
      prev = s; name = substr($0, 12); n++
    }
    /^RESULT|^== \[[0-9:]*\] teardown/ { last = 1 }
    END { if (n) printf "%4s   %s (until the end)\n", "", name }' "${1:?vm.sh phases <log>}"
}

prune() {
  # every slot: nothing runs meanwhile
  local n all
  all=$(seq 0 $((SLOTS - 1)))
  PRUNE_HELD=""
  trap 'for n in ${PRUNE_HELD}; do rm -rf "${LOCKS:?}/${n}"; done; rm -f "${FFS_VM_COPY:-}"' EXIT
  for n in ${all}; do SLOT=${n} take_slot prune; PRUNE_HELD="${PRUNE_HELD} ${n}"; SLOT_HELD=""; done
  running || { echo "VM not running"; return 0; }
  install_lib
  vssh 'df -BG --output=avail / | tail -1 | sed "s/^/free before: /"
    docker builder prune -af > /dev/null 2>&1; docker image prune -f > /dev/null; docker volume prune -f > /dev/null
    podman image prune -f > /dev/null 2>&1
    # the src-* tags of the tests (images built from a checkout): those no container uses, but
    # the newest of each name (kindest/node and *-helm-e2e are not src-* tags)
    for rt in docker podman; do
      used=$($rt ps -a --format "{{.Image}}" 2> /dev/null | sort -u)
      $rt images --format "{{.Repository}}:{{.Tag}} {{.CreatedAt}}" 2> /dev/null | grep -E ":(src-[0-9a-f]+|[0-9a-f]{12}) " |
        grep -E "^(localhost/)?ffs-src-|:syncstorage-rs-[a-z]+-init-src-|^(localhost/)?ffs-admin:src-|^(localhost/)?ffs-fxa-browser:src-" |
        sort -k2 -r | awk "{ split(\$1, a, \":\"); k = a[1]; sub(/-init-src-.*/, \"-init\", k); if (seen[k]++) print \$1 }" |
        while read -r img; do grep -qxF "$img" <<< "$used" || $rt rmi "$img" > /dev/null 2>&1; done
    done
    if [ -n "'"${ALL:-}"'" ]; then
      for rt in docker podman; do
        used=$($rt ps -a --format "{{.Image}}" 2> /dev/null | sort -u)
        $rt images --format "{{.Repository}}:{{.Tag}} {{.ID}}" 2> /dev/null | grep -vE "^(docker.io/)?kindest/node|-helm-e2e " |
          while read -r img id; do
            case "$img" in *"<none>"*) img=$id ;; esac
            grep -qxF "$img" <<< "$used" || $rt rmi "$img" > /dev/null 2>&1
          done
        $rt image prune -f > /dev/null 2>&1
      done
    fi
    sudo fstrim / 2> /dev/null
    df -BG --output=avail / | tail -1 | sed "s/^/free after: /"' < /dev/null
}

case ${1:-} in
  create) create ;;
  start) start ;;
  stop) stop ;;
  ssh) shift; ssh_cmd "$@" ;;
  sync) enter_slot sync; say "synced ${REPO} into slot ${SLOT_HELD} (~/$(slot_dir))" ;;
  test) shift; run_test "$@" ;;
  rerun) shift; rerun "$@" ;;
  image) shift; image_cmd "$@" ;;
  slots) show_slots ;;
  release) shift; release_kept "$@" ;;
  phases) shift; phases "$@" ;;
  prune) prune ;;
  provision) provision ;;
  destroy) stop; rm -f "${DISK}" "${SEED}" "${VARS}" "${RELEASE_FILE}" "${VM_DIR}/console.log" "${VM_DIR}/ssh-mux" "${KNOWN_HOSTS}" "${HOST_KEY}" "${HOST_KEY}.pub" ;;
  *) sed -n '3,/^set -u$/p' "${FFS_VM_SELF:-$0}" | sed '$d'; exit 2 ;;
esac
