#!/bin/bash
# What tests/helm.sh and tests/helm-fxa.sh share: check, fail, manifests and the helpers of
# their e2e on kind (sourced; they set SCRIPT_DIR, REPO_ROOT, and for the e2e CLUSTER and
# POD_SELECTOR)

check() {
  echo "✓ $1"
}

# rendered manifests (stdin) as a JSON array, for jq
manifests() {
  python3 -c 'import json, sys, yaml; print(json.dumps([d for d in yaml.safe_load_all(sys.stdin) if d]))'
}

fail() {
  echo "✗ $1"
  exit 1
}

# wait_job <name> <seconds>: the Job succeeded (its logs on the way)
wait_job() {
  local deadline=$(( $(date +%s) + $2 )) succeeded failed
  while [[ $(date +%s) -lt ${deadline} ]]; do
    succeeded=$(kubectl get job "$1" -o jsonpath='{.status.succeeded}')
    failed=$(kubectl get job "$1" -o jsonpath='{.status.failed}')
    if [[ "${succeeded}" == 1 || -n "${failed}" ]]; then
      break
    fi
    sleep 2
  done
  kubectl logs "job/$1" --tail=40 || true
  [[ "${succeeded}" == 1 ]]
}

rnd() { tr -dc A-Za-z0-9 < /dev/urandom | head -c 32 || true; }

# ingress_is <name> <class> <host> <service> <port> [<path> <pathType> <service> <port>]...:
# that Ingress, its only rule: / (Prefix) of the host to the Service, then each other path
ingress_is() {
  local got want name=$1 class=$2 host=$3
  shift 3
  want="[\"${class}\",[\"${host}\",\"/\",\"Prefix\",\"$1\",$2"
  shift 2
  while (($# >= 4)); do
    want+=",\"$1\",\"$2\",\"$3\",$4"
    shift 4
  done
  (($# == 0)) || fail "ingress_is: incomplete path group"
  want+="]]"
  got=$(kubectl get ingress "${name}" -o json 2> /dev/null | jq -c '[.spec.ingressClassName, [.spec.rules[] | .host, (.http.paths[] | .path, .pathType,
    .backend.service.name, .backend.service.port.number)]]') || true
  [[ "${got}" == "${want}" ]] || fail "Ingress ${name}: ${got:-none}, expected ${want}"
}

pod_status() {
  kubectl get pods -l "${POD_SELECTOR}" --no-headers 2>/dev/null | awk '{print $3}' | paste -sd, -
}

# wait_pod_status <regex> <seconds>: the only syncstorage pod has a STATUS matching regex
wait_pod_status() {
  local deadline=$(( $(date +%s) + $2 )) status
  while [[ $(date +%s) -lt ${deadline} ]]; do
    status=$(pod_status)
    if [[ "${status}" != *,* ]] && [[ "${status}" =~ ^($1)$ ]]; then
      # shellcheck disable=SC2034 # (read by the callers)
      MATCHED_STATUS=${status}
      return 0
    fi
    sleep 2
  done
  echo "pod status: ${status}"
  return 1
}

# on a failure, what the pods did: every pod not Ready
# (but those that completed) in full, describe, each container's and init container's log,
# the current one and that of the previous run (a crash loop), and the events
diagnostics() {
  kubectl get pods -o wide 2>/dev/null || return 0
  local pod c
  for pod in $(kubectl get pods -o go-template='{{range .items}}{{if ne .status.phase "Succeeded"}}{{$ready := "False"}}{{range .status.conditions}}{{if eq .type "Ready"}}{{$ready = .status}}{{end}}{{end}}{{if ne $ready "True"}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}{{end}}' 2>/dev/null); do
    echo "=== pod/${pod} not Ready"
    kubectl describe pod "${pod}" 2>/dev/null || true
    for c in $(kubectl get pod "${pod}" -o jsonpath='{range .spec.initContainers[*]}{.name}{"\n"}{end}{range .spec.containers[*]}{.name}{"\n"}{end}' 2>/dev/null); do
      echo "--- pod/${pod} ${c}: log"
      kubectl logs "${pod}" -c "${c}" --tail=200 2>&1 || true
      echo "--- pod/${pod} ${c}: log of the previous run"
      kubectl logs "${pod}" -c "${c}" --previous --tail=200 2>&1 || true
    done
  done
  echo "=== events"
  kubectl get events --sort-by=.lastTimestamp 2>/dev/null || true
  kubectl logs extdb-0 --tail=15 2> /dev/null || true
  # the backup and the restore check
  for pod in $(kubectl get pods -l "ffs-e2e" -o name 2>/dev/null) $(kubectl get pods -l "job-name=backup-now" -o name 2>/dev/null); do
    echo "--- ${pod}"
    kubectl logs "${pod}" --tail=15 2>/dev/null || true
  done
}

# A host with Ubuntu's mysql-server (the GitHub runners) has an AppArmor profile for
# /usr/sbin/mysqld, and kind's pods run unconfined: the profile then takes the mysqld of the
# mysql image too (docker's containers, in docker-default, are not). It denies /etc/my.cnf,
# /usr/share/mysql-8.4 and the init file of admin-user.sh (/run/ffs-admin, errno 13): the
# first start aborts half-way and every next one finds no mysql.user (CrashLoopBackOff)
# (mysqld_apparmor_check: before a kind cluster that runs a MySQL server)
mysqld_apparmor_check() {
  if [[ -e /etc/apparmor.d/usr.sbin.mysqld && ! -e /etc/apparmor.d/disable/usr.sbin.mysqld \
    && "$(cat /sys/module/apparmor/parameters/enabled 2> /dev/null)" == Y ]]; then
    fail "the host's AppArmor profile /usr/sbin/mysqld would confine MySQL in kind; disable it first:
  sudo ln -s /etc/apparmor.d/usr.sbin.mysqld /etc/apparmor.d/disable/ && sudo apparmor_parser -R /etc/apparmor.d/usr.sbin.mysqld"
  fi
}

# image_tags: the caller's init_tag and ADMIN_TAG, those of build_images (helm-e2e), unless
# SKIP_BUILD=1 (then the published ones the caller set)
image_tags() {
  if [[ -z "${SKIP_BUILD:-}" ]]; then
    # shellcheck disable=SC2034 # (the caller's)
    init_tag=helm-e2e ADMIN_TAG=helm-e2e
  fi
}

# build_images <repository> <flavor> <init_dir>: the init image (of init_dir, for the Sync
# server's flavor mysql|postgres) and the admin UI built from this tree, tagged helm-e2e,
# unless SKIP_BUILD=1 (no cluster needed: it may run before the cluster, in the background)
build_images() {
  local repository=$1 flavor=$2 init_dir=$3
  [[ -z "${SKIP_BUILD:-}" ]] || return 0
  # in the test VM its helper (vm.sh: ~/.ffs/lib.sh), which builds a folder once per content
  # and serializes the builds of the slots; elsewhere docker
  if ! declare -F ffs_image > /dev/null && [[ -f "${HOME}/.ffs/lib.sh" ]]; then
    # shellcheck source=/dev/null
    source "${HOME}/.ffs/lib.sh"
  fi
  if declare -F ffs_image > /dev/null; then
    (cd "${REPO_ROOT}" && ffs_image "${init_dir}" "${repository}:syncstorage-rs-${flavor}-init-helm-e2e" > /dev/null) \
      || fail "init image not built"
    (cd "${REPO_ROOT}" && ffs_image admin "${repository}:admin-helm-e2e" > /dev/null) || fail "admin image not built"
  else
    docker build -q -t "${repository}:syncstorage-rs-${flavor}-init-helm-e2e" "${REPO_ROOT}/${init_dir}" > /dev/null \
      || fail "init image not built"
    # with BuildKit (the Dockerfile's BUILDPLATFORM), as tests/e2e.sh builds it
    ADMIN_IMAGE="${repository}:admin-helm-e2e" COMPOSE_BAKE=false docker compose -p ffs-helm-admin-build \
      -f "${SCRIPT_DIR}/compose/admin-build.yml" build -q || fail "admin image not built"
  fi
}

# kind_load_built <repository> <flavor> <init_dir>: what build_images built into the kind
# cluster CLUSTER (nothing with SKIP_BUILD=1)
kind_load_built() {
  local repository=$1 flavor=$2 init_dir=$3
  [[ -z "${SKIP_BUILD:-}" ]] || return 0
  kind load docker-image --name "${CLUSTER}" "${repository}:syncstorage-rs-${flavor}-init-helm-e2e" > /dev/null || fail "init image not loaded"
  check "init image built from ${init_dir}"
  kind load docker-image --name "${CLUSTER}" "${repository}:admin-helm-e2e" > /dev/null || fail "admin image not loaded"
  check "admin image built from admin/"
}

# load_images <repository> <flavor> <init_dir>: build_images, then into the kind cluster
# CLUSTER; sets the caller's init_tag and ADMIN_TAG to their tag
load_images() {
  image_tags
  build_images "$@"
  kind_load_built "$@"
}

# bg_start <name> <command>...: the command (a function of these scripts too) in the
# background, its output kept for bg_wait; bg_wait <name>...: each one's end, its output shown
# and the run failed when it failed (BG_DIR: a temporary folder of the caller's)
declare -A BG_PIDS=()
bg_start() {
  local name=$1
  shift
  : "${BG_DIR:?bg_start needs BG_DIR}"
  ( "$@" ) > "${BG_DIR}/${name}.log" 2>&1 &
  BG_PIDS[${name}]=$!
}
bg_wait() {
  local name rc
  for name in "$@"; do
    [[ -n "${BG_PIDS[${name}]:-}" ]] || continue
    rc=0
    wait "${BG_PIDS[${name}]}" || rc=$?
    unset "BG_PIDS[${name}]"
    if ((rc)); then
      cat "${BG_DIR}/${name}.log"
      fail "${name} failed (exit ${rc})"
    fi
    grep -v '^$' "${BG_DIR}/${name}.log" || true
  done
}
# bg_kill: what bg_start started and still runs (a failure, the trap)
bg_kill() {
  local pid
  for pid in "${BG_PIDS[@]}"; do kill "${pid}" 2> /dev/null || true; done
  wait 2> /dev/null || true
}

# kind_teardown: the e2e's cluster deleted, but on a GitHub runner, which is thrown away
# with it (deleting a node of several GB takes up to a minute there)
kind_teardown() {
  [[ "${GITHUB_ACTIONS:-}" == true ]] && return 0
  kind delete cluster --name "${CLUSTER}"
}
