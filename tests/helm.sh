#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHART_DIR="${REPO_ROOT}/charts/firefox-sync"

# check, fail, manifests and the e2e's helpers, shared with tests/helm-fxa.sh
# shellcheck source=tests/helm/lib.sh
source "${SCRIPT_DIR}/helm/lib.sh"
# the self-hosted accounts' checks (fxa_lint)
# shellcheck source=tests/helm-fxa.sh
source "${SCRIPT_DIR}/helm-fxa.sh"

lint() {
  echo "=== Running Helm lint checks ==="

  # Check that chart directory exists
  if [[ ! -d "${CHART_DIR}" ]]; then
    fail "Chart directory not found: ${CHART_DIR}"
  fi

  # Lint with each CI values file
  for values_file in "${CHART_DIR}"/ci/*.yaml; do
    if [[ ! -f "${values_file}" ]]; then
      continue
    fi
    echo "Linting with $(basename "${values_file}")..."
    if ! helm lint "${CHART_DIR}" -f "${values_file}"; then
      fail "Helm lint failed with $(basename "${values_file}")"
    fi
    check "Helm lint passed with $(basename "${values_file}")"
  done

  # every long-running container has its readiness and liveness probes (not the init
  # containers, not the pods of Jobs and CronJobs), with every values set of ci/
  for values_file in "${CHART_DIR}"/ci/*.yaml; do
    missing=$(helm template test-release "${CHART_DIR}" -f "${values_file}" | manifests | jq -r '.[]
      | select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet" or .kind == "ReplicaSet")
      | .metadata.name as $w | .spec.template.spec.containers[]
      | select(.readinessProbe == null or .livenessProbe == null) | "\($w)/\(.name)"')
    [[ -z "${missing}" ]] || fail "$(basename "${values_file}"): containers without a readinessProbe or livenessProbe: ${missing}"
  done
  check "every container of the Deployments and StatefulSets has a readinessProbe and a livenessProbe (ci/*.yaml)"

  # maxUsers: a string, or a number rendered as a string, in the db-init container's MAX_USERS
  echo "Testing maxUsers..."
  max_users() {
    helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" "$@" \
      --show-only templates/syncstorage.yaml | grep -A1 'name: MAX_USERS$' | grep 'value:' | sed 's/^ *//'
  }
  [[ "$(max_users --set maxUsers=5)" == 'value: "5"' ]] || fail "--set maxUsers=5: $(max_users --set maxUsers=5)"
  [[ "$(max_users --set-string maxUsers=initial:5)" == 'value: "initial:5"' ]] || fail "maxUsers=initial:5 not rendered as is"
  values=$(mktemp)
  printf 'maxUsers: 5\n' > "${values}"
  [[ "$(max_users -f "${values}")" == 'value: "5"' ]] || fail "unquoted maxUsers: 5 in a values file: $(max_users -f "${values}")"
  printf 'maxUsers: 1000000\n' > "${values}"
  [[ "$(max_users -f "${values}")" == 'value: "1000000"' ]] || fail "maxUsers: 1000000: $(max_users -f "${values}")"
  rm -f "${values}"
  check "maxUsers 5 (--set and unquoted in a values file), initial:5 and 1000000 render as strings"
  for bad in bogus -1 fixed:-1 initial:; do
    if helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set maxUsers="${bad}" > /dev/null 2>&1; then
      fail "maxUsers=${bad} not refused by the schema"
    fi
  done
  check "maxUsers bogus, -1, fixed:-1, initial: refused by the schema"

  # allowedAccounts: SYNC_ALLOWED_ACCOUNTS of the db-init container and of the admin UI, as given
  local uids=0123456789abcdef0123456789abcdef,fedcba9876543210fedcba9876543210 allowed
  allowed=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set admin.enabled=true \
    --set-string allowedAccounts="initial:${uids//,/\\,}" | grep -A1 'name: SYNC_ALLOWED_ACCOUNTS$' | grep -c "value: \"initial:${uids}\"")
  [[ "${allowed}" == 2 ]] || fail "allowedAccounts=initial:<uids> not in the db-init and admin containers (${allowed})"
  [[ "$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set admin.enabled=true | grep -c 'name: SYNC_ALLOWED_ACCOUNTS$')" == 0 ]] \
    || fail "allowedAccounts not set, but SYNC_ALLOWED_ACCOUNTS rendered"
  check "allowedAccounts: not rendered by default (off, the objects of 0.1.0), initial:<uids> as given in the db-init and admin containers"
  for bad in bogus "initial:xyz" "admin:${uids%%,*}"; do
    if helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set-string allowedAccounts="${bad}" > /dev/null 2>&1; then
      fail "allowedAccounts=${bad} not refused by the schema"
    fi
  done
  check "allowedAccounts bogus, initial:xyz, admin:<uid> refused by the schema (the db-init container checks the uids themselves)"

  # wait-db logs in to nothing: no password in that init container
  for backend in mariadb mysql postgres; do
    waitdb=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.backend="${backend}" \
      --show-only templates/syncstorage.yaml | sed -En '/- name: wait-db$/,/- name: (sync-role|migrate)$/p')
    [[ -n "${waitdb}" ]] || fail "${backend}: no wait-db init container"
    if echo "${waitdb}" | grep -qiE 'secretKeyRef|PASSWORD|-p"'; then
      fail "${backend}: wait-db uses a password: ${waitdb}"
    fi
  done
  check "wait-db has no credentials (mariadb, mysql, postgres)"

  # MariaDB and MySQL data in a subdirectory of the volume (lost+found)
  for backend in mariadb mysql; do
    helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.backend="${backend}" \
      --show-only templates/databases.yaml | grep -A1 'mountPath: /var/lib/mysql$' | grep -q 'subPath: data$' \
      || fail "${backend}: /var/lib/mysql not mounted with subPath: data"
  done
  check "MariaDB and MySQL data mounted with subPath: data"

  # Test schema validation - invalid backend should fail
  echo "Testing schema validation with invalid backend..."
  if helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.backend=sqlite >/dev/null 2>&1; then
    fail "Schema validation did not reject invalid database.backend (sqlite)"
  fi
  check "Schema validation correctly rejects invalid database.backend"

  # The database URLs of the syncstorage containers read the right password variables
  echo "Testing the database URLs' password variables..."
  for backend in postgres mysql mariadb; do
    output=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.backend="${backend}")
    urls=$(echo "${output}" | grep -A1 -E 'name: SYNC_(TOKENSERVER|SYNCSTORAGE)__DATABASE_URL$' | grep 'value:')
    [[ $(echo "${urls}" | wc -l) -eq 4 ]] || fail "${backend}: expected 4 database URLs (migrate and syncstorage), got: ${urls}"
    if [[ ${backend} == postgres ]]; then
      # the Sync server's own role, never POSTGRES_USER (the superuser)
      bad=$(echo "${urls}" | grep -v 'postgres://syncserver_app:$(POSTGRES_SYNC_PASSWORD)@' || true)
    else
      bad=$(echo "${output}" | grep -A1 -E 'name: SYNC_TOKENSERVER__DATABASE_URL$' | grep 'value:' | grep -v '$(TOKENSERVER_DB_PASSWORD)@' || true)
      bad+=$(echo "${output}" | grep -A1 -E 'name: SYNC_SYNCSTORAGE__DATABASE_URL$' | grep 'value:' | grep -v '$(STORAGE_DB_PASSWORD)@' || true)
    fi
    [[ -z "${bad}" ]] || fail "${backend}: database URLs with the wrong password variable: ${bad}"
    check "${backend}: database URLs use the backend's password variables"
  done

  # the Sync server and its migrations: never POSTGRES_PASSWORD (the superuser's), no NET_RAW
  output=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/postgres-values.yaml" --show-only templates/syncstorage.yaml)
  for c in migrate syncstorage; do
    block=$(echo "${output}" | awk -v c="${c}" '$0 ~ "^        - name: "c"$" {on=1; print; next} on && /^        - name: / {on=0} on')
    [[ -n "${block}" ]] || fail "postgres: no ${c} container"
    if echo "${block}" | grep -qE 'name: POSTGRES_PASSWORD$|key: POSTGRES_PASSWORD$'; then
      fail "postgres: ${c} gets POSTGRES_PASSWORD"
    fi
    echo "${block}" | grep -A2 'capabilities:' | grep -q 'drop: \["NET_RAW"\]' || fail "postgres: ${c} keeps NET_RAW"
  done
  echo "${output}" | grep -q '^        - name: sync-role$' || fail "postgres: no sync-role init container"
  [[ "$(echo "${output}" | grep -E '^        - name: (wait-db|sync-role|migrate|db-init)$' | awk '{print $3}' | paste -sd' ' -)" == "wait-db sync-role migrate db-init" ]] \
    || fail "postgres: init containers not in compose's order"
  check "postgres: sync-role before migrate; migrate and syncstorage without POSTGRES_PASSWORD and NET_RAW"
  output=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --show-only templates/syncstorage.yaml)
  [[ $(echo "${output}" | grep -c 'drop: \["NET_RAW"\]') -eq 2 ]] || fail "mariadb: NET_RAW not dropped on migrate and syncstorage"
  check "mariadb: migrate and syncstorage without NET_RAW"
  # database.image.<backend>: the database server, wait-db, the backups and the PVC's binding
  # Job (compose's SYNC_POSTGRES_IMAGE: postgres_db and backup), postgres:latest by default
  for backend in mariadb mysql postgres; do
    images() {
      helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.backend="${backend}" --set backup.enabled=true "$@" \
        | manifests | jq -r '[.[] | select(.kind == "StatefulSet" or .kind == "Job" or .kind == "CronJob" or .kind == "Deployment")
          | (.spec.jobTemplate.spec // .spec).template.spec | (.initContainers // [])[], .containers[]
          | select(.name == "db" or .name == "wait-db" or .name == "backup" or .name == "bind") | .image] | unique | join(" ")'
    }
    default=$(sed -n "s/^    ${backend}: //p" "${CHART_DIR}/values.yaml")
    [[ "$(images)" == "${default}" ]] || fail "${backend}: the database images are not ${default}: $(images)"
    [[ "$(images --set database.image."${backend}"=registry.example.test/db:9)" == "registry.example.test/db:9" ]] \
      || fail "${backend}: database.image.${backend} not used everywhere: $(images --set database.image."${backend}"=registry.example.test/db:9)"
    if helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.image."${backend}"= > /dev/null 2>&1; then
      fail "an empty database.image.${backend} not refused by the schema"
    fi
  done
  [[ "$(sed -n 's/^    postgres: //p' "${CHART_DIR}/values.yaml")" == docker.io/library/postgres:latest ]] || fail "database.image.postgres is not docker.io/library/postgres:latest by default"
  check "database.image.<backend> for the server, wait-db, the backups and the binding Job (docker.io/library/ mariadb:lts, mysql:lts, postgres:latest), empty refused"

  # the guard of a database major change (lookup of the running StatefulSet at install and
  # upgrade, which helm template cannot do): included, its comparison on its own in a copy of
  # the chart, allowMajorUpgrade in the schema
  grep -q '^{{- include "firefox-sync.checkDbMajor" . }}$' "${CHART_DIR}/templates/databases.yaml" || fail "databases.yaml does not run checkDbMajor"
  grep -q 'lookup "apps/v1" "StatefulSet"' "${CHART_DIR}/templates/_helpers.tpl" || fail "checkDbMajor does not read the running StatefulSet"
  major_change() {
    local d out
    d=$(mktemp -d)
    cp -r "${CHART_DIR}" "${d}/chart"
    sed -e "s|@OLD@|$1|" -e "s|@NEW@|$2|" > "${d}/chart/templates/zz-major.yaml" <<'TPL'
apiVersion: v1
kind: ConfigMap
metadata: {name: major}
data:
  change: '{{ include "firefox-sync.dbMajorChange" (dict "old" "@OLD@" "new" "@NEW@") }}'
TPL
    out=$(helm template test-release "${d}/chart" -f "${CHART_DIR}/ci/default-values.yaml" --show-only templates/zz-major.yaml 2>&1 | manifests | jq -r '.[0].data.change') || true
    rm -rf "${d}"
    echo "${out}"
  }
  for c in "docker.io/library/mysql:8 docker.io/library/mysql:lts true" "docker.io/library/mysql:8 docker.io/library/mysql:8 -" \
    "mysql:8.4 docker.io/library/mysql:8 -" "docker.io/library/mysql:8 docker.io/library/mysql:9 true" \
    "docker.io/library/mysql:lts docker.io/library/mysql:9 -" "docker.io/library/mysql:lts mysql:lts -" \
    "docker.io/library/mariadb:11 docker.io/library/mariadb:lts true" "docker.io/library/mariadb:lts docker.io/library/mariadb:latest true" \
    "docker.io/library/postgres:latest docker.io/library/postgres:alpine true" "docker.io/library/postgres:18 docker.io/library/postgres:latest true" \
    "docker.io/library/postgres:18 docker.io/library/postgres:18-alpine -" "docker.io/library/mariadb:lts docker.io/library/mysql:lts -" \
    "docker.io/library/mysql:8@sha256:00 docker.io/library/mysql:9 true"; do
    read -r old new want <<< "${c}"
    [[ "$(major_change "${old}" "${new}")" == "${want/-/}" ]] || fail "dbMajorChange ${old} -> ${new}: '$(major_change "${old}" "${new}")', not '${want/-/}'"
  done
  if helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.allowMajorUpgrade=yes > /dev/null 2>&1; then
    fail "database.allowMajorUpgrade=yes not refused by the schema"
  fi
  check "checkDbMajor: run by the databases, reads the running StatefulSet; dbMajorChange on 13 pairs; allowMajorUpgrade a boolean"
  # the guard of a backend switch (MariaDB and MySQL on each other's data, PostgreSQL empty):
  # run before checkDbMajor, reads each StatefulSet the release may have (e2e: the refusal)
  grep -F -x -A1 '{{- include "firefox-sync.checkDbBackend" . }}' "${CHART_DIR}/templates/databases.yaml" | grep -q checkDbMajor \
    || fail "databases.yaml does not run checkDbBackend before checkDbMajor"
  grep -q 'range list "tokenserver-db" "storage-db" "postgres"' "${CHART_DIR}/templates/_helpers.tpl" \
    && grep -q 'firefox-sync: database.backend is %s but the bundled Sync database %s runs %s; switching needs a dump and restore.*docs/migrating.md#moving-the-database' "${CHART_DIR}/templates/_helpers.tpl" \
    || fail "checkDbBackend does not read the three StatefulSets or say where the switch is documented"
  check "checkDbBackend: run by the databases before checkDbMajor, reads the tokenserver-db, storage-db and postgres StatefulSets"
  # the volumes as they are (lookups at install and upgrade, the e2e: the refusals): each
  # StatefulSet's volumeClaimTemplate, each PVC (pvcStorageClass), checkClaim's rules on its
  # own with the data a lookup would return, in a copy of the chart
  grep -qF 'include "firefox-sync.checkStatefulSetClaim" (dict "root" $root "name" (include "firefox-sync.dbHost" (dict "root" $root "db" .db)) "claim" "data"' "${CHART_DIR}/templates/databases.yaml" \
    && grep -qF 'include "firefox-sync.checkStatefulSetClaim" (dict "root" . "name" (include "firefox-sync.fxaDbHost" .) "claim" $new "setting" "fxa.database.persistence"' "${CHART_DIR}/templates/_fxa.tpl" \
    && grep -qF '{{- with lookup "apps/v1" "StatefulSet" .root.Release.Namespace .name }}' "${CHART_DIR}/templates/_helpers.tpl" \
    && grep -qF '{{- $existing := lookup "v1" "PersistentVolumeClaim" .root.Release.Namespace .name }}' "${CHART_DIR}/templates/_helpers.tpl" \
    && grep -qF '{{- $class = lookup "storage.k8s.io/v1" "StorageClass" "" $existing.spec.storageClassName }}' "${CHART_DIR}/templates/_helpers.tpl" \
    || fail "the volumes' checks: not run by the StatefulSets, or no lookup of the StatefulSet, the PVC, the StorageClass"
  local pvc
  for pvc in 'templates/backup.yaml:"%s-backups" $fullname) "setting" "backup.persistence"' 'templates/fxa-auth.yaml:"%s-fxa-keys" $fullname) "setting" "fxa.keys.persistence"' \
    'templates/fxa-profile.yaml:"%s-fxa-profile-images" $fullname) "setting" "fxa.profileImages.persistence"'; do
    grep -qF "{{- with include \"firefox-sync.pvcStorageClass\" (dict \"root\" . \"name\" (printf ${pvc#*:}" "${CHART_DIR}/${pvc%%:*}" || fail "${pvc%%:*}: its PVC without pvcStorageClass"
  done
  [[ "$(grep -c 'storageClassName:' "${CHART_DIR}"/templates/{backup,fxa-auth,fxa-profile}.yaml | awk -F: '{n += $2} END {print n}')" == 3 ]] \
    || fail "a PVC's storageClassName not of pvcStorageClass"
  claim_check() {
    local d out
    d=$(mktemp -d)
    cp -r "${CHART_DIR}" "${d}/chart"
    printf '%s' "$1" > "${d}/chart/files/claim.json"
    printf '%s\n' '{{- $c := fromJson (.Files.Get "files/claim.json") }}' \
      '{{- include "firefox-sync.checkClaim" (dict "setting" "x.persistence" "what" "the volume v" "persistence" $c.persistence "accessModes" (list "ReadWriteOnce") "live" $c.live "template" $c.template "class" $c.class) }}' \
      'apiVersion: v1' 'kind: ConfigMap' 'metadata: {name: claim}' 'data: {bytes: "{{ include "firefox-sync.bytes" $c.persistence.size }}"}' > "${d}/chart/templates/zz-claim.yaml"
    out=$(helm template test-release "${d}/chart" -f "${CHART_DIR}/ci/default-values.yaml" --show-only templates/zz-claim.yaml 2>&1)
    local rc=$?
    rm -rf "${d}"
    echo "${out}"
    return "${rc}"
  }
  claim() { printf '{"persistence":{"size":"%s","storageClass":"%s"},"live":{"accessModes":["%s"],"storageClassName":"%s","resources":{"requests":{"storage":"%s"}}},"template":%s,"class":{"allowVolumeExpansion":%s}}' "$@"; }
  local c want
  # <size> <class> <live access mode> <live class> <live size> <template> <expansion> -> refused with (- passes)
  for c in "8Gi - ReadWriteOnce - 8Gi true false|-" "8192Mi - ReadWriteOnce - 8Gi true false|-" "9Gi - ReadWriteOnce - 8Gi true true|was created with 8Gi: Kubernetes never changes a StatefulSet's volumeClaimTemplates; set it back to 8Gi" \
    "8Gi fast ReadWriteOnce - 8Gi true false|x.persistence.storageClass is \"fast\" but the volume v was created with \"\"" \
    "8Gi - ReadWriteOnce fast 8Gi true false|x.persistence.storageClass is \"\" but the volume v was created with \"fast\"" \
    "1Gi - ReadWriteOnce standard 1Gi false false|-" "1Gi standard ReadWriteOnce standard 1Gi false false|-" \
    "2Gi - ReadWriteOnce standard 1Gi false false|its StorageClass \"standard\" does not allow expansion (allowVolumeExpansion): keep 1Gi" \
    "2Gi - ReadWriteOnce standard 1Gi false true|-" "1.5G - ReadWriteOnce standard 1Gi false true|-" \
    "2Gi - ReadWriteOnce standard 1395864371200m false true|-" "1331Mi - ReadWriteOnce - 1395864371200m true false|was created with 1395864371200m" \
    "512Mi - ReadWriteOnce standard 1Gi false true|x.persistence.size is 512Mi but the volume v is 1Gi: Kubernetes never shrinks a volume; set at least 1Gi" \
    "1Gi - ReadWriteOnce standard 2Gi false true|set at least 2Gi" \
    "1Gi fast ReadWriteOnce standard 1Gi false true|x.persistence.storageClass is \"fast\" but the volume v is on \"standard\": Kubernetes never changes a PVC's class" \
    "1Gi - ReadWriteMany standard 1Gi false true|the volume v has the access modes [\"ReadWriteMany\"], the chart's are [\"ReadWriteOnce\"]"; do
    want=${c#*|}
    read -r -a args <<< "${c%|*}"
    args=("${args[@]/#-/}")
    if out=$(claim_check "$(claim "${args[@]}")"); then
      [[ ${want} == - ]] || fail "checkClaim ${c%|*}: passes, expected refused with '${want}'"
    else
      [[ ${want} != - ]] && grep -qF "firefox-sync: " <<< "${out}" && grep -qF "${want}" <<< "${out}" || fail "checkClaim ${c%|*}: ${out}"
    fi
  done
  # (bytes: rounded up as Kubernetes does; the milli-units it stores a size of no whole bytes in,
  # 1.3Gi of an older chart: 1395864371200m, exactly divided)
  for c in 1.5Gi:1610612736 1395864371200m:1395864372 8589934592000m:8589934592 1.0000000001k:1001 8Gi:8589934592; do
    [[ "$(claim_check "$(claim "${c%%:*}" "" ReadWriteOnce "" 1 false true)" | grep -o 'bytes: "[0-9]*"')" == "bytes: \"${c#*:}\"" ]] \
      || fail "bytes of ${c%%:*}: $(claim_check "$(claim "${c%%:*}" "" ReadWriteOnce "" 1 false true)"), not ${c#*:}"
  done
  for bad in database.persistence.size=8GB database.persistence.size=lots backup.persistence.size=-1Gi fxa.keys.persistence.size=1e9 \
    database.persistence.size=1.5Gi fxa.database.persistence.size=0.1Gi fxa.profileImages.persistence.size=1.3G; do
    out=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set "${bad}" 2>&1) && fail "${bad}: not refused by the schema"
    grep -qi schema <<< "${out}" || fail "${bad}: refused, but not by the schema: ${out}"
  done
  check "the volumes: checkStatefulSetClaim on the Sync and accounts databases' StatefulSets, pvcStorageClass on the backups', keys' and avatars' PVCs (lookups); checkClaim: a StatefulSet's size (8192Mi = 8Gi), class as created, a PVC's class kept, never smaller, larger with allowVolumeExpansion only, the access modes; bytes rounded up, milli-units of a live size read; sizes whole bytes (schema: 1.5Gi refused)"
  # the bundled PostgreSQL: the db-major init container (db/postgres/keep-major.sh) with the
  # server's image and its data, before the server
  pg=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.backend=postgres --show-only templates/databases.yaml | manifests)
  [[ "$(jq -c '.[] | select(.kind == "StatefulSet") | .spec.template.spec | [(.initContainers | map(.name)), .initContainers[0].image == .containers[0].image,
      (.initContainers[0].command | index("/ffs-db/keep-major.sh") != null), (.initContainers[0].volumeMounts | map([.name, .mountPath, .readOnly]))]' <<< "${pg}")" \
    == '[["db-major"],true,true,[["data","/var/lib/postgresql",null],["db-scripts","/ffs-db",true]]]' ]] \
    || fail "postgres: the db-major init container: $(jq -c '.[] | select(.kind == "StatefulSet") | .spec.template.spec.initContainers' <<< "${pg}")"
  [[ "$(jq -r '.[] | select(.kind == "ConfigMap") | .data["keep-major.sh"]' <<< "${pg}")" == "$(cat "${CHART_DIR}/files/postgres-keep-major.sh")" ]] \
    || fail "postgres: the db-scripts ConfigMap is not files/postgres-keep-major.sh"
  check "postgres: the db-major init container runs keep-major.sh with the server's image on its data"

  # db/mysql/admin-user.sh (the chart's copy identical: parity), run by the MariaDB and MySQL containers
  for backend in mariadb mysql; do
    output=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.backend="${backend}" --show-only templates/databases.yaml)
    [[ $(echo "${output}" | grep -c 'args: \[sh, /ffs-db/admin-user.sh, ') -eq 2 ]] || fail "${backend}: admin-user.sh not the command of both databases"
    [[ $(echo "${output}" | grep -c 'name: ADMIN_DB_ROLE$') -eq 2 ]] || fail "${backend}: ADMIN_DB_ROLE missing"
  done
  check "admin-user.sh run by both MariaDB/MySQL databases"
  # a changed admin-user.sh rolls the databases out again (their ConfigMap is read at the start)
  for backend in mariadb mysql; do
    sums=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.backend="${backend}" | manifests \
      | jq -r '.[] | select(.kind == "StatefulSet") | .spec.template.metadata.annotations["checksum/db-scripts"] // "none"' | sort -u)
    [[ "${sums}" == "$(sha256sum < "${CHART_DIR}/files/admin-user.sh" | cut -d' ' -f1)" ]] \
      || fail "${backend}: checksum/db-scripts of the databases is not the sha256 of files/admin-user.sh: ${sums}"
  done
  check "checksum/db-scripts on both MariaDB/MySQL databases: a changed admin-user.sh restarts them"

  # the backups, compose's backup service (COMPOSE_PROFILES=backup): off by default, then a
  # CronJob with compose's image (its variables, backup.sh identical: parity)
  echo "Testing the backups..."
  if helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" | manifests \
    | jq -e '.[] | select(.kind == "CronJob" or (.metadata.name | test("backup")))' > /dev/null; then
    fail "backup.enabled=false: a CronJob or a backup object rendered"
  fi
  check "no backups by default"
  names=""
  for backend in mariadb mysql postgres; do
    image=docker.io/library/mariadb:lts
    [[ ${backend} == mysql ]] && image=docker.io/library/mysql:lts
    [[ ${backend} == postgres ]] && image=docker.io/library/postgres:latest
    docs=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.backend="${backend}" \
      --set backup.enabled=true | manifests)
    cron=$(echo "${docs}" | jq '.[] | select(.kind == "CronJob" and .metadata.name == "test-release-firefox-sync-backup")')
    [[ -n "${cron}" ]] || fail "${backend}: no CronJob test-release-firefox-sync-backup"
    # BACKUP_TIME is UTC: the schedule too, whatever the cluster's time zone
    [[ "$(echo "${cron}" | jq -c '[.spec.schedule, .spec.timeZone, .spec.concurrencyPolicy, .spec.jobTemplate.spec.template.spec.restartPolicy]')" \
      == '["0 3 * * *","Etc/UTC","Forbid","Never"]' ]] || fail "${backend}: the CronJob's schedule, timeZone, concurrencyPolicy, restartPolicy: ${cron}"
    pod=$(echo "${cron}" | jq '.spec.jobTemplate.spec.template.spec')
    [[ "$(echo "${pod}" | jq -c '.containers | map([.image, .command, .args])')" == "[[\"${image}\",[\"sh\",\"/ffs-backup/backup.sh\"],[\"now\"]]]" ]] \
      || fail "${backend}: the backup container is not ${image} running backup.sh now: $(echo "${pod}" | jq -c .containers)"
    # backup.sh from its ConfigMap at /ffs-backup (read-only), the PVC at /backups
    [[ "$(echo "${pod}" | jq -c '.volumes as $v | [.containers[0].volumeMounts[] | .name as $n
      | [.mountPath, (.readOnly // false), ($v[] | select(.name == $n) | (.configMap.name // .persistentVolumeClaim.claimName))]] | sort')" \
      == '[["/backups",false,"test-release-firefox-sync-backups"],["/ffs-backup",true,"test-release-firefox-sync-backup"]]' ]] \
      || fail "${backend}: the backup's mounts: $(echo "${pod}" | jq -c '[.containers[0].volumeMounts, .volumes]')"
    cm=$(echo "${docs}" | jq -r '.[] | select(.kind == "ConfigMap" and .metadata.name == "test-release-firefox-sync-backup") | .data["backup.sh"]')
    [[ "${cm}" == "$(cat "${CHART_DIR}/files/backup.sh")" ]] || fail "${backend}: the backup ConfigMap's backup.sh is not files/backup.sh"
    # the backups PVC, kept on helm uninstall like the databases' volumes
    [[ "$(echo "${docs}" | jq -c '.[] | select(.kind == "PersistentVolumeClaim" and .metadata.name == "test-release-firefox-sync-backups")
      | [.spec.accessModes, .spec.resources.requests.storage, .metadata.annotations["helm.sh/resource-policy"]]')" == '[["ReadWriteOnce"],"10Gi","keep"]' ]] \
      || fail "${backend}: no PVC test-release-firefox-sync-backups of 10Gi, kept on uninstall"
    # a Job of the release binds it at once: with a WaitForFirstConsumer storage class (kind,
    # most clouds) it stays Pending until a pod uses it, which helm install --wait waits for.
    # Named after its pod template (a Job's is immutable: a new one when it changes)
    bind=$(echo "${docs}" | jq '[.[] | select(.kind == "Job" and (.metadata.name | startswith("test-release-firefox-sync-backup-volume-")))]')
    [[ "$(echo "${bind}" | jq -c 'map(.spec.template.spec | [(.volumes[] | .persistentVolumeClaim.claimName // empty), .containers[0].image, .restartPolicy])')" \
      == "[[\"test-release-firefox-sync-backups\",\"${image}\",\"Never\"]]" ]] || fail "${backend}: no Job binding the backups PVC: ${bind}"
    names+=" $(echo "${bind}" | jq -r '.[0].metadata.name | ltrimstr("test-release-firefox-sync-backup-volume-")')"
    check "${backend}: CronJob ${image} backup.sh now at 0 3 * * * UTC (Forbid), the PVC at /backups (bound by a Job)"
  done
  # (one per image: a hash of the pod template)
  [[ "${names}" =~ ^\ [0-9a-f]{8}\ [0-9a-f]{8}\ [0-9a-f]{8}$ && $(tr ' ' '\n' <<< "${names}" | sort -u | wc -l) -eq 4 ]] \
    || fail "the binding Jobs not named after their pod templates: ${names}"
  # a hung dump ends within a day: under Forbid it would block every later run
  deadline() {
    helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set backup.enabled=true "$@" | manifests \
      | jq -r '.[] | select(.kind == "CronJob") | .spec.jobTemplate.spec.activeDeadlineSeconds'
  }
  [[ "$(deadline)" == 82800 && "$(deadline --set backup.activeDeadlineSeconds=3600)" == 3600 ]] \
    || fail "the backup Job's activeDeadlineSeconds: $(deadline), with 3600: $(deadline --set backup.activeDeadlineSeconds=3600)"
  check "the backup Job ends after backup.activeDeadlineSeconds (82800 by default)"
  # the backup and binding pods: root (the dumps are root's, 0600) without capabilities
  for backend in mariadb mysql postgres; do
    sec=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.backend="${backend}" --set backup.enabled=true \
      | manifests | jq -c '[.[] | select(.kind == "CronJob" or (.kind == "Job" and (.metadata.name | contains("backup")))) | (.spec.jobTemplate.spec // .spec).template.spec
      | [.securityContext.seccompProfile.type, (.containers[] | .securityContext | [.allowPrivilegeEscalation, .capabilities.drop])]] | unique')
    [[ "${sec}" == '[["RuntimeDefault",[false,["ALL"]]]]' ]] || fail "${backend}: the backup pods' securityContext: ${sec}"
  done
  check "backup and binding pods: seccomp RuntimeDefault, no privilege escalation, every capability dropped"
  # the binding Job's name (and its job-name label) within 63 characters, with a long fullname
  # too (the CronJob keeps <fullname>-backup, the name the admin UI shows)
  # (45: the longest a CronJob allows)
  long=$(printf 'f%.0s' $(seq 1 45))
  names=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set backup.enabled=true --set fullnameOverride="${long}" \
    --set database.bundled=false --set database.external.host=db.example.test --set existingSecret=mine \
    | manifests | jq -r '.[] | select(.kind == "Job") | .metadata.name')
  [[ -n "${names}" ]] && ! awk 'length($0) > 63 {bad = 1} END {exit !bad}' <<< "${names}" || fail "Job names over 63 characters: ${names}"
  grep -q -- "-backup-volume-[0-9a-f]\{8\}$" <<< "${names}" || fail "the binding Job lost its hash: ${names}"
  check "the binding Job's name within 63 characters (fullnameOverride of 45), with its hash"
  # names within Kubernetes' limits, refused at render time otherwise (none truncated: the
  # admin UI builds them from ADMIN_K8S_FULLNAME): the CronJob 52 (its Jobs get 11 more), the
  # StatefulSets 52 (their pods' controller-revision-hash label, <name>-<hash of 10>), the
  # Services 63
  of() { printf "f%.0s" $(seq 1 "$1"); }
  renders() { helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" "$@" 2>&1; }
  external=(--set database.bundled=false --set database.external.host=db.example.test --set existingSecret=mine)
  out=$(renders "${external[@]}" --set backup.enabled=true --set fullnameOverride="$(of 46)") \
    && fail "a fullname of 46 with the backups renders"
  grep -q "fullnameOverride or a shorter release name: the backup CronJob name $(of 46)-backup is 53 characters, at most 52" <<< "${out}" \
    || fail "a fullname of 46 with the backups: not the message on the CronJob's name: ${out}"
  renders "${external[@]}" --set backup.enabled=true --set fullnameOverride="$(of 45)" > /dev/null || fail "a fullname of 45 with the backups does not render"
  # (component: the longest fullname that renders, its name)
  for limit in "mariadb 37 tokenserver-db StatefulSet" "mysql 37 tokenserver-db StatefulSet" "postgres 43 postgres StatefulSet" \
    "external 51 syncstorage Service" "admin 51 syncstorage Service"; do
    read -r what max name kind <<< "${limit}"
    case ${what} in
      external) args=("${external[@]}") ;;
      admin) args=("${external[@]}" --set admin.enabled=true) ;;
      *) args=(--set database.backend="${what}") ;;
    esac
    renders "${args[@]}" --set fullnameOverride="$(of "${max}")" > /dev/null || fail "${what}: a fullname of ${max} does not render: $(renders "${args[@]}" --set fullnameOverride="$(of "${max}")" | tail -1)"
    out=$(renders "${args[@]}" --set fullnameOverride="$(of $((max + 1)))") && fail "${what}: a fullname of $((max + 1)) renders"
    grep -q "the ${name} ${kind} name $(of $((max + 1)))-${name} is" <<< "${out}" || fail "${what}: a fullname of $((max + 1)): not the message on the ${name} ${kind}: ${out}"
  done
  check "names over Kubernetes' limits refused at render time (CronJob 52, StatefulSets 52, Services 63): backups 45, mariadb/mysql 37, postgres 43, Sync 51"
  # helm install --dry-run renders NOTES: a backup now, under a new name each time
  grep -qF 'create job --from=cronjob/{{ include "firefox-sync.fullname" . }}-backup backup-now-$(date +%s)' "${CHART_DIR}/templates/NOTES.txt" \
    || fail "NOTES.txt: the backup-now command is not one for every run"
  [[ "$(sed -n 's/^kubeVersion: //p' "${CHART_DIR}/Chart.yaml")" == '">=1.27.0-0"' ]] || fail "Chart.yaml: kubeVersion not >=1.27.0-0 (CronJob timeZone)"
  check "NOTES: backup-now-\$(date +%s); kubeVersion >=1.27.0-0 (CronJob timeZone)"
  # BACKUP_TIME (the admin UI's help, backup.sh) from a daily schedule only, BACKUP_KEEP from
  # backup.keep: the same in the CronJob and the admin UI
  # (the admin UI's first: admin.yaml renders before backup.yaml)
  backup_env() {
    helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/admin-values.yaml" --set backup.enabled=true "$@" | manifests | jq -r '[.[]
      | (select(.kind == "CronJob") | .spec.jobTemplate.spec.template.spec), (select(.kind == "Deployment" and .metadata.name == "test-release-firefox-sync-admin") | .spec.template.spec)
      | .containers[0].env | map(select(.name == "BACKUP_TIME" or .name == "BACKUP_KEEP")) | map(.name + "=" + .value) | join(",")] | join(" ")'
  }
  [[ "$(backup_env)" == "BACKUP_TIME=03:00,BACKUP_KEEP=7 BACKUP_KEEP=7,BACKUP_TIME=03:00" ]] || fail "default BACKUP_TIME, BACKUP_KEEP: $(backup_env)"
  [[ "$(backup_env --set backup.schedule='5 23 * * *' --set backup.keep=3)" == "BACKUP_TIME=23:05,BACKUP_KEEP=3 BACKUP_KEEP=3,BACKUP_TIME=23:05" ]] \
    || fail "backup.schedule='5 23 * * *', keep 3: $(backup_env --set backup.schedule='5 23 * * *' --set backup.keep=3)"
  for schedule in '0 */6 * * *' '0 3 * * 1' '@daily' '0 3\,15 * * *'; do
    [[ "$(backup_env --set backup.schedule="${schedule}")" == "BACKUP_KEEP=7 BACKUP_KEEP=7" ]] \
      || fail "backup.schedule='${schedule}' is not daily at one time, yet: $(backup_env --set backup.schedule="${schedule}")"
  done
  [[ "$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/admin-values.yaml" | manifests | jq -r '.[]
    | select(.kind == "Deployment" and .metadata.name == "test-release-firefox-sync-admin") | .spec.template.spec.containers[0].env[]
    | select(.name | startswith("BACKUP_")) | .name + "=" + .value' | paste -sd, -)" == "BACKUP_TIME=03:00,BACKUP_KEEP=7" ]] \
    || fail "the admin UI without the backups: no BACKUP_TIME, BACKUP_KEEP (compose passes them always)"
  check "BACKUP_TIME from a daily backup.schedule (else unset), BACKUP_KEEP from backup.keep, in the CronJob and the admin UI"
  for bad in 'backup.keep=0' 'backup.schedule='; do
    if helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set backup.enabled=true --set "${bad}" > /dev/null 2>&1; then
      fail "${bad} not refused by the schema"
    fi
  done
  check "backup.keep=0 and an empty backup.schedule refused by the schema"

  # existingSecret: no Secret rendered, every secretKeyRef reads that one
  echo "Testing existingSecret..."
  output=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set existingSecret=my-secret)
  if echo "${output}" | grep -q '^kind: Secret'; then
    fail "existingSecret set, but the chart still renders a Secret"
  fi
  refs=$(echo "${output}" | grep -A1 'secretKeyRef:' | grep 'name:' | sort -u)
  [[ "${refs}" =~ ^[[:space:]]*name:\ my-secret$ ]] || fail "secretKeyRefs not all to my-secret: ${refs}"
  check "existingSecret: no Secret rendered, all secretKeyRefs read it"

  # the admin UI: off by default, then a Service (http, statsd) and the Sync server's statsd
  # host only while it is on; compose's variables, its secrets from the Secret
  echo "Testing the admin UI..."
  output=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml")
  if echo "${output}" | grep -qE 'name: test-release-firefox-sync-admin$|SYNC_STATSD_(HOST|PORT)'; then
    fail "admin.enabled=false: an admin UI or SYNC_STATSD_* rendered"
  fi
  check "admin UI off by default, no SYNC_STATSD_* on the Sync server"
  for backend in mariadb mysql postgres; do
    output=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" \
      --set database.backend="${backend}" --set admin.enabled=true)
    docs=$(echo "${output}" | manifests)
    svc=$(echo "${docs}" | jq '.[] | select(.kind == "Service" and .metadata.name == "test-release-firefox-sync-admin")')
    [[ "$(echo "${svc}" | jq -c '[.spec.ports[] | [.name, .port, .protocol]] | sort')" == '[["http",8080,"TCP"],["statsd",8125,"UDP"]]' ]] \
      || fail "${backend}: the admin Service's ports: ${svc}"
    sync=$(echo "${docs}" | jq '.[] | select(.kind == "Deployment" and .metadata.name == "test-release-firefox-sync-syncstorage")
      | .spec.template.spec.containers[] | select(.name == "syncstorage") | .env')
    [[ "$(echo "${sync}" | jq -c 'map(select(.name | startswith("SYNC_STATSD_"))) | map({(.name): .value}) | add')" \
      == '{"SYNC_STATSD_HOST":"test-release-firefox-sync-admin","SYNC_STATSD_PORT":"8125"}' ]] || fail "${backend}: SYNC_STATSD_* of the Sync server"
    admin=$(echo "${docs}" | jq '.[] | select(.kind == "Deployment" and .metadata.name == "test-release-firefox-sync-admin")
      | .spec.template.spec.containers[] | select(.name == "admin") | .env')
    [[ "$(echo "${admin}" | jq -r 'map(select(.name == "ADMIN_DEPLOYMENT" or .name == "ADMIN_K8S_RELEASE"))[].value' | paste -sd' ' -)" == "kubernetes test-release" ]] \
      || fail "${backend}: ADMIN_DEPLOYMENT, ADMIN_K8S_RELEASE"
    # no secret as a plain value
    # (ADMIN_K8S_SECRET: the name of the Secret)
    plain=$(echo "${admin}" | jq -r '.[] | select(.value != null) | .name' | grep -E '(^|_)(PASS|PASSWORD|SECRET|TOKEN)$' | grep -vx ADMIN_K8S_SECRET || true)
    [[ -z "${plain}" ]] || fail "${backend}: secrets of the admin UI as plain values: ${plain}"
    check "${backend}: admin Service http 8080/TCP + statsd 8125/UDP, SYNC_STATSD_HOST, secrets from the Secret"
  done
  # its optional secrets: from the values into the Secret, optional in an existingSecret
  output=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set admin.enabled=true \
    --set admin.metricsToken=tok --set smtp.password=pw --set admin.password=adm)
  data=$(echo "${output}" | manifests | jq '.[] | select(.kind == "Secret") | .data')
  [[ "$(echo "${data}" | jq -r '[.ADMIN_METRICS_TOKEN, .FXA_SMTP_PASS, .ADMIN_PASSWORD, .ADMIN_OIDC_CLIENT_SECRET] | map(@base64d) | join(" ")')" == "tok pw adm " ]] \
    || fail "admin secrets in the Secret: ${data}"
  output=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set admin.enabled=true --set existingSecret=my-secret)
  optional=$(echo "${output}" | manifests | jq -r '.[] | select(.kind == "Deployment" and .metadata.name == "test-release-firefox-sync-admin")
    | .spec.template.spec.containers[0].env[] | select(.valueFrom.secretKeyRef.optional == true) | .valueFrom.secretKeyRef.key' | sort | paste -sd' ' -)
  [[ "${optional}" == "ADMIN_METRICS_TOKEN ADMIN_NOTIFY ADMIN_OIDC_CLIENT_SECRET ADMIN_PASSWORD FXA_SMTP_PASS" ]] || fail "optional keys of an existingSecret: ${optional}"
  refs=$(echo "${output}" | grep -A1 'secretKeyRef:' | grep 'name:' | sort -u)
  [[ "${refs}" =~ ^[[:space:]]*name:\ my-secret$ ]] || fail "admin UI on, secretKeyRefs not all to my-secret: ${refs}"
  check "admin secrets: values into the Secret; FXA_SMTP_PASS, ADMIN_OIDC_CLIENT_SECRET, ADMIN_METRICS_TOKEN, ADMIN_PASSWORD optional in an existingSecret"
  # the three optional ones are the values' alone: an empty value an empty key, never what a
  # lookup of the Secret found (helm template has no cluster: the template must not read them)
  data=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/admin-values.yaml" --set admin.metricsToken= \
    --set smtp.password= --set admin.oidc.clientSecret= --set admin.notify= | manifests | jq -c '.[] | select(.kind == "Secret") | .data
    | [.ADMIN_METRICS_TOKEN, .FXA_SMTP_PASS, .ADMIN_OIDC_CLIENT_SECRET, .ADMIN_NOTIFY]')
  [[ "${data}" == '["","","",""]' ]] || fail "empty admin secrets of the values not empty in the Secret: ${data}"
  for key in FXA_SMTP_PASS ADMIN_OIDC_CLIENT_SECRET ADMIN_METRICS_TOKEN ADMIN_NOTIFY; do
    grep -qE '^\{\{- \$_ := set \$data "'"${key}"'" \((\.Values\.(admin|smtp)\.|include "firefox-sync\.adminNotify")' "${CHART_DIR}/templates/_helpers.tpl" \
      || fail "${key} not set from the values alone in firefox-sync.secretData"
  done
  check "FXA_SMTP_PASS, ADMIN_OIDC_CLIENT_SECRET, ADMIN_METRICS_TOKEN, ADMIN_NOTIFY from the values alone (empty: empty)"
  # admin.notify: a list joined by commas, or a string as it is
  notify() {
    helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/admin-values.yaml" "$@" | manifests \
      | jq -r '.[] | select(.kind == "Secret") | .data.ADMIN_NOTIFY | @base64d'
  }
  [[ "$(notify)" == "ntfy://ntfy.sh/ci-topic,webhook://hooks.example.test/ci" ]] || fail "admin.notify as a list: $(notify)"
  [[ "$(notify --set-string admin.notify='ntfy://a.test/x\,slack://b.test/y')" == "ntfy://a.test/x,slack://b.test/y" ]] || fail "admin.notify as a string"
  check "admin.notify: a list joined by commas, or a string, into ADMIN_NOTIFY"
  # a new admin pod when the chart's Secret changes: the checksum is over all of its data,
  # the generated secrets with it (helm template generates new ones on every render), not
  # over the secrets of the values alone, which the pod spec would give away
  render() { helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/admin-values.yaml" "$@" | manifests; }
  checksum() {
    jq -r '.[] | select(.kind == "Deployment" and .metadata.name == "test-release-firefox-sync-admin")
      | .spec.template.metadata.annotations["checksum/admin-secrets"] // empty'
  }
  docs=$(render --set admin.password=one)
  sum=$(echo "${docs}" | checksum)
  data_sum=$(echo "${docs}" | jq -cS '.[] | select(.kind == "Secret") | .data' | tr -d '\n' | sha256sum | cut -d' ' -f1)
  [[ -n "${sum}" && "${sum}" == "${data_sum}" ]] || fail "checksum/admin-secrets is not the sha256 of the Secret's data: ${sum} ${data_sum}"
  for plain in '[null,"one","ci-smtp","ci-oidc","ci-token"]' '["","one","ci-smtp","ci-oidc","ci-token"]' '["one","ci-smtp","ci-oidc","ci-token"]'; do
    [[ "${sum}" != "$(printf '%s' "${plain}" | sha256sum | cut -d' ' -f1)" ]] || fail "checksum/admin-secrets is the sha256 of the values' secrets alone"
  done
  [[ "$(render --set admin.password=two | checksum)" != "${sum}" ]] || fail "checksum/admin-secrets does not change with admin.password"
  [[ -z "$(render --set admin.password=one --set existingSecret=mine | checksum)" ]] || fail "existingSecret: a checksum of secrets in the pod spec"
  check "checksum/admin-secrets: sha256 of the Secret's whole data (not of the values' secrets alone), none with existingSecret"
  # the names the admin UI shows, as the chart has them
  env_of() {
    helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/admin-values.yaml" "$@" | manifests | jq -cS '[.[]
      | select(.kind == "Deployment") | .spec.template.spec.containers[] | .env[]?
      | select(.name | test("^(ADMIN_K8S_|SYNC_STATSD_HOST)")) | {(.name): .value}] | add'
  }
  [[ "$(env_of --set fullnameOverride=x --set existingSecret=mine)" == \
    '{"ADMIN_K8S_CHART":"oci://ghcr.io/porelli/firefox-sync/charts/firefox-sync","ADMIN_K8S_CHART_VERSION":"'"$(sed -n 's/^version: //p' "${CHART_DIR}/Chart.yaml")"'","ADMIN_K8S_FULLNAME":"x","ADMIN_K8S_NAMESPACE":"default","ADMIN_K8S_RELEASE":"test-release","ADMIN_K8S_SECRET":"mine","SYNC_STATSD_HOST":"x-admin"}' ]] \
    || fail "names with fullnameOverride and existingSecret: $(env_of --set fullnameOverride=x --set existingSecret=mine)"
  [[ "$(env_of | jq -r '.ADMIN_K8S_FULLNAME + " " + .ADMIN_K8S_SECRET')" == "test-release-firefox-sync test-release-firefox-sync" ]] \
    || fail "default names: $(env_of)"
  check "ADMIN_K8S_FULLNAME, ADMIN_K8S_SECRET as the chart names them (fullnameOverride, existingSecret), ADMIN_K8S_CHART_VERSION the chart's version"
  # admin.podStatus (docs/admin/monitoring.md#startup-grace): off, no service account, no token; on, a
  # Role that only gets and lists pods, its token in the admin container alone
  local pods_of
  pods_of() { helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/admin-values.yaml" "$@" | manifests; }
  [[ "$(pods_of | jq -c '[.[] | select(.kind == "ServiceAccount" or .kind == "Role" or .kind == "RoleBinding")] | length')" == 0 ]] \
    && [[ "$(pods_of | jq -c '[.[] | select(.kind == "Deployment") | .spec.template.spec | select(.automountServiceAccountToken != false or .serviceAccountName != null)] | length')" == 0 ]] \
    || fail "admin.podStatus off: a service account or a token"
  [[ "$(pods_of --set admin.podStatus=true | jq -c '[.[] | select(.kind == "Role")][0].rules')" == '[{"apiGroups":[""],"resources":["pods"],"verbs":["get","list"]}]' ]] \
    && [[ "$(pods_of --set admin.podStatus=true | jq -r '.[] | select(.kind == "RoleBinding") | "\(.roleRef.name) \(.subjects[0].name)"')" == "test-release-firefox-sync-admin-pods test-release-firefox-sync-admin" ]] \
    && [[ "$(pods_of --set admin.podStatus=true | jq -r '.[] | select(.kind == "Deployment" and .metadata.name == "test-release-firefox-sync-admin") | .spec.template.spec
      | "\(.automountServiceAccountToken) \(.serviceAccountName) \([.containers[] | select(.volumeMounts[]?.name == "kube-api") | .name] | join(",")) \([.initContainers[]? | select(.volumeMounts[]?.name == "kube-api")] | length)"')" \
      == "false test-release-firefox-sync-admin admin 0" ]] \
    && [[ "$(pods_of --set admin.podStatus=true | jq -r '.[] | select(.kind == "Deployment") | .spec.template.spec.containers[].env[]? | select(.name == "ADMIN_K8S_POD_STATUS") | .value')" == true ]] \
    || fail "admin.podStatus on: the Role, its binding, the token in the admin container alone, ADMIN_K8S_POD_STATUS"
  check "admin.podStatus: off nothing of the Kubernetes API, on a Role to get and list pods and the token in the admin container alone"
  # where the chart was published (the annotation the publish job sets), for helm upgrade
  [[ "$(sed -n 's|^  org.firefox-sync/chart: ||p' "${CHART_DIR}/Chart.yaml")" == oci://ghcr.io/porelli/firefox-sync/charts/firefox-sync ]] \
    || fail "Chart.yaml: the annotation org.firefox-sync/chart is not the public repository's chart"
  check "ADMIN_K8S_CHART: the annotation org.firefox-sync/chart of Chart.yaml (the public repository's chart)"
  # numbers of a values file (float64 there) as integers, never 2e+06
  values=$(mktemp)
  printf 'admin:\n  dbGrowthMb: 2000000\n  retentionDays: 1000000\nsmtp:\n  port: 465\n' > "${values}"
  numbers=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/admin-values.yaml" -f "${values}" | manifests | jq -r '.[]
    | select(.kind == "Deployment" and .metadata.name == "test-release-firefox-sync-admin") | .spec.template.spec.containers[0].env[]
    | select(.name == "ADMIN_DB_GROWTH_MB" or .name == "ADMIN_RETENTION_DAYS" or .name == "SMTP_PORT") | .value' | paste -sd' ' -)
  rm -f "${values}"
  [[ "${numbers}" == "465 1000000 2000000" ]] || fail "numbers of a values file: ${numbers}"
  check "numbers of a values file as integers (dbGrowthMb 2000000, retentionDays 1000000, smtp.port 465)"
  # the switches of compose's .env that are off when empty: rendered only when set (the
  # default render as before them)
  switches() {
    helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/admin-values.yaml" "$@" | manifests | jq -cS '[.[]
      | select(.kind == "Deployment" and .metadata.name == "test-release-firefox-sync-admin") | .spec.template.spec.containers[0].env[]
      | select(.name == "ADMIN_INSECURE_COOKIE" or .name == "SMTP_INSECURE_AUTH") | {(.name): .value}] | add'
  }
  [[ "$(switches)" == null && "$(switches --set admin.insecureCookie=1 --set smtp.insecureAuth=true)" == '{"ADMIN_INSECURE_COOKIE":"1","SMTP_INSECURE_AUTH":"true"}' ]] \
    || fail "admin.insecureCookie, smtp.insecureAuth: $(switches) / $(switches --set admin.insecureCookie=1 --set smtp.insecureAuth=true)"
  check "admin.insecureCookie, smtp.insecureAuth: ADMIN_INSECURE_COOKIE, SMTP_INSECURE_AUTH only when set"

  external_lint
  ingress_lint
  pods_lint
  schema_lint
  publish_lint
  fxa_lint
  # compose's variables, commands, probes and scripts
  parity

  echo ""
  echo "=== All lint checks passed ==="
}

# every pod of the chart (the Deployments', the StatefulSets', the CronJob's, the binding Job's),
# everything on (the admin UI, the backups), each backend: what all of them share
# pod_specs <helm args>...: {w: "<kind>/<name>", s: <pod template>} per workload
pod_specs() {
  helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/backup-values.yaml" "$@" | manifests | jq -c '[.[]
    | select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "CronJob" or .kind == "Job")
    | {w: "\(.kind)/\(.metadata.name)", s: (.spec.jobTemplate.spec // .spec).template}]'
}
pods_lint() {
  echo "Testing what every pod has..."
  local backend pods bad
  for backend in mariadb mysql postgres; do
    pods=$(pod_specs --set database.backend="${backend}")
    [[ "$(jq length <<< "${pods}")" -ge 4 ]] || fail "${backend}: not every workload rendered: ${pods}"
    # no service account token (no pod uses the API), seccomp RuntimeDefault, no privilege
    # escalation in any container (init containers too): PodSecurity baseline, hardened
    bad=$(jq -r '.[] | .w as $w | .s.spec | select(.automountServiceAccountToken != false or .securityContext.seccompProfile.type != "RuntimeDefault"
      or ([(.initContainers // [])[], .containers[] | .securityContext.allowPrivilegeEscalation] | any(. != false))) | $w' <<< "${pods}")
    [[ -z "${bad}" ]] || fail "${backend}: pods without automountServiceAccountToken false, seccomp RuntimeDefault or allowPrivilegeEscalation false: ${bad}"
    # nothing PodSecurity baseline refuses: no host namespaces, ports or paths, no privileged
    # container, no capability added
    bad=$(jq -r '.[] | .w as $w | .s.spec | select(.hostNetwork or .hostPID or .hostIPC
      or ([.volumes[]? | .hostPath] | any(. != null))
      or ([(.initContainers // [])[], .containers[] | (.securityContext.privileged // false), ((.securityContext.capabilities.add // []) | length > 0), ([.ports[]? | .hostPort] | any(. != null))] | any)) | $w' <<< "${pods}")
    [[ -z "${bad}" ]] || fail "${backend}: pods PodSecurity baseline refuses: ${bad}"
    # the admin UI's pod meets restricted
    jq -e '.[] | select(.w | endswith("-admin")) | .s.spec | .securityContext.runAsNonRoot == true
      and ([(.initContainers // [])[], .containers[] | .securityContext.capabilities.drop == ["ALL"]] | all)' <<< "${pods}" > /dev/null \
      || fail "${backend}: the admin UI's pod is not runAsNonRoot with every capability dropped (restricted)"
    # scheduling, pull secrets and annotations of the values on every pod; the chart's own
    # annotations (checksums) kept
    pods=$(pod_specs --set database.backend="${backend}" --set nodeSelector.disk=ssd --set 'tolerations[0].key=dedicated' \
      --set 'tolerations[0].operator=Exists' --set affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key=zone \
      --set affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].operator=Exists \
      --set 'imagePullSecrets[0].name=my-registry' --set podAnnotations.team=sync --set podAnnotations.checksum/db-scripts=mine)
    bad=$(jq -r '.[] | .w as $w | .s | select(.metadata.annotations.team != "sync" or .spec.nodeSelector != {disk: "ssd"}
      or .spec.tolerations != [{key: "dedicated", operator: "Exists"}] or .spec.imagePullSecrets != [{name: "my-registry"}]
      or .spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key != "zone") | $w' <<< "${pods}")
    [[ -z "${bad}" ]] || fail "${backend}: pods without nodeSelector, tolerations, affinity, imagePullSecrets or podAnnotations: ${bad}"
    jq -e '[.[] | select(.w | endswith("-admin")) | .s.metadata.annotations["checksum/admin-secrets"] | test("^[0-9a-f]{64}$")] == [true]' <<< "${pods}" > /dev/null \
      || fail "${backend}: podAnnotations lost the admin UI's checksum/admin-secrets"
    # (PostgreSQL: one server, its keep-major.sh)
    jq -e --argjson n "$([[ ${backend} == postgres ]] && echo 1 || echo 2)" '[.[] | select(.w | startswith("StatefulSet/")) | .s.metadata.annotations["checksum/db-scripts"] | test("^[0-9a-f]{64}$")] == [range($n) | true]' <<< "${pods}" > /dev/null \
      || fail "${backend}: podAnnotations replaced the databases' checksum/db-scripts"
    # resources: each where it belongs (empty by default: none)
    jq -e '[.[] | .s.spec | (.initContainers // [])[], .containers[] | .resources // empty] == []' <<< "$(pod_specs --set database.backend="${backend}")" > /dev/null \
      || fail "${backend}: resources by default"
    pods=$(pod_specs --set database.backend="${backend}" --set syncstorage.resources.requests.cpu=1m --set syncstorage.initResources.requests.cpu=2m \
      --set admin.resources.requests.cpu=3m --set database.resources.requests.cpu=4m --set backup.resources.requests.cpu=5m)
    bad=$(jq -r '.[] | .w as $w | .s.spec | (.initContainers // [])[], .containers[] | "\($w | sub("^[A-Za-z]+/test-release-firefox-sync-"; "") | sub("-[0-9a-f]{8}$"; ""))/\(.name)=\(.resources.requests.cpu // "none")"' <<< "${pods}" | sort | paste -sd' ' -)
    local want="admin/admin=3m admin/wait-sync=3m backup-volume/bind=5m backup/backup=5m"
    if [[ ${backend} == postgres ]]; then
      want+=" postgres/db-major=4m postgres/db=4m syncstorage/db-init=2m syncstorage/migrate=2m syncstorage/sync-role=2m syncstorage/syncstorage=1m syncstorage/wait-db=2m"
    else
      want+=" storage-db/db=4m syncstorage/db-init=2m syncstorage/migrate=2m syncstorage/syncstorage=1m syncstorage/wait-db=2m tokenserver-db/db=4m"
    fi
    [[ "${bad}" == "${want}" ]] || fail "${backend}: the resources of the containers: ${bad}, expected ${want}"
  done
  check "every pod: no service account token, seccomp RuntimeDefault, no privilege escalation, nothing baseline refuses; the admin UI restricted (mariadb, mysql, postgres)"
  check "every pod: nodeSelector, tolerations, affinity, imagePullSecrets, podAnnotations of the values (the chart's checksums kept)"
  check "resources: syncstorage.resources, .initResources (wait-db, sync-role, migrate, db-init), admin.resources (and wait-sync), database.resources, backup.resources (and bind)"

  # with the accounts (ci/fxa-values.yaml, both their backends): the same for their pods; a
  # capability added only to the volume owners' init containers, CHOWN alone; their pods (but
  # their database server's, root at the start as the Sync server's) root only there, and
  # nowhere with fxa.volumeOwnerInit=false
  local fxa_backend owner_init caps roots want_roots r
  for fxa_backend in mysql mariadb; do
    for owner_init in true false; do
      pods=$(pod_specs -f "${CHART_DIR}/ci/fxa-values.yaml" --set fxa.database.backend="${fxa_backend}" --set fxa.volumeOwnerInit="${owner_init}")
      [[ "$(jq '[.[] | select(.w | test("-fxa-"))] | length' <<< "${pods}")" -ge 5 ]] || fail "fxa ${fxa_backend}: not every workload of the accounts rendered"
      bad=$(jq -r '.[] | .w as $w | .s.spec | select(.automountServiceAccountToken != false or .securityContext.seccompProfile.type != "RuntimeDefault"
        or ([(.initContainers // [])[], .containers[] | .securityContext.allowPrivilegeEscalation] | any(. != false))
        or .hostNetwork or .hostPID or .hostIPC or ([.volumes[]? | .hostPath] | any(. != null))
        or ([(.initContainers // [])[], .containers[] | (.securityContext.privileged // false), ([.ports[]? | .hostPort] | any(. != null))] | any)) | $w' <<< "${pods}")
      [[ -z "${bad}" ]] || fail "fxa ${fxa_backend}, volumeOwnerInit=${owner_init}: pods PodSecurity baseline refuses, or without the chart's hardening: ${bad}"
      caps=$(jq -r '.[] | .w as $w | .s.spec | (.initContainers // [])[], .containers[] | select((.securityContext.capabilities.add // []) != [])
        | "\($w | sub("^[A-Za-z]+/test-release-firefox-sync-"; ""))/\(.name)=\(.securityContext.capabilities.add | join(","))"' <<< "${pods}" | sort | paste -sd' ' -)
      roots=$(jq -r '.[] | select((.w | test("-fxa-")) and .w != "StatefulSet/test-release-firefox-sync-fxa-db") | .w as $w | .s.spec | .securityContext as $p
        | (.initContainers // [])[], .containers[] | select((.securityContext.runAsUser // $p.runAsUser // 0) == 0 or (.securityContext.runAsNonRoot // $p.runAsNonRoot) != true)
        | "\($w | sub("^[A-Za-z]+/test-release-firefox-sync-"; ""))/\(.name)"' <<< "${pods}" | sort | paste -sd' ' -)
      if [[ ${owner_init} == true ]]; then
        want_roots="fxa-auth/keys-owner fxa-profile/images-owner"
        jq -e '[.[] | select(.w | test("-fxa-(auth|profile)$")) | .s.spec.securityContext.fsGroup] == [null, null]' <<< "${pods}" > /dev/null \
          || fail "fxa ${fxa_backend}: fsGroup on the auth or profile pod with fxa.volumeOwnerInit"
      else
        want_roots=""
        jq -e '[.[] | select(.w | test("-fxa-(auth|profile)$")) | .s.spec.securityContext.fsGroup] == [10001, 10001]' <<< "${pods}" > /dev/null \
          || fail "fxa ${fxa_backend}: no fsGroup 10001 on the auth and profile pods with fxa.volumeOwnerInit=false"
      fi
      [[ "${caps}" == "$(for r in ${want_roots}; do printf '%s=CHOWN\n' "${r}"; done | paste -sd' ' -)" ]] || fail "fxa ${fxa_backend}, volumeOwnerInit=${owner_init}: capabilities added: ${caps:-none}"
      [[ "${roots}" == "${want_roots}" ]] || fail "fxa ${fxa_backend}, volumeOwnerInit=${owner_init}: the accounts' root containers: ${roots:-none}, expected ${want_roots:-none}"
    done
  done
  check "the accounts' pods: nothing baseline refuses; root only in keys-owner and images-owner, with CHOWN alone, none with fxa.volumeOwnerInit=false (fsGroup 10001 then)"
}

# values.schema.json: no key the chart does not know (a typo fails), where the chart owns
# the keys; the maps of Kubernetes (annotations, resources, scheduling) stay open
schema_lint() {
  echo "Testing the schema's closed objects..."
  local bad
  for bad in admin.enable=true database.bakend=mysql syncstorage.replica=2 backup.persistence.sise=1Gi ingress.tls.secret=x image.tag=x \
    unknownTopLevel=1 database.external.hots=db; do
    if helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set "${bad}" > /dev/null 2>&1; then
      fail "${bad}: an unknown key not refused by the schema"
    fi
  done
  helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set ingress.annotations.a/b=c --set admin.ingress.annotations.x=y \
    --set podAnnotations.p=q --set nodeSelector.n=m --set syncstorage.resources.limits.memory=1Gi --set database.resources.limits.memory=1Gi \
    --set backup.resources.requests.memory=64Mi --set syncstorage.initResources.requests.memory=64Mi --set admin.resources.requests.memory=64Mi \
    --set affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].weight=1 \
    --set affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].podAffinityTerm.topologyKey=kubernetes.io/hostname \
    --set fullnameOverride=x --set nameOverride=y > /dev/null || fail "the open maps (annotations, resources, scheduling) refused"
  if helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set 'imagePullSecrets[0]=my-registry' > /dev/null 2>&1; then
    fail "imagePullSecrets as plain names (not {name: ...}) not refused"
  fi
  check "the schema refuses unknown keys (admin.enable, database.bakend...), keeps annotations, resources, nodeSelector, tolerations, affinity open"
}

# the publish job's tag check (.github/scripts/chart-version.sh): the tag is chart-v<the
# version of Chart.yaml>, a semver; a stable one (no -<pre-release>, +<build> is stable) only
# from a commit of the default branch
publish_lint() {
  echo "Testing the tag check of the publishing..."
  local script="${REPO_ROOT}/.github/scripts/chart-version.sh" d out
  d=$(mktemp -d)
  # a repository: main with a chart, a branch with one more commit
  git -C "${d}" init -q -b main && mkdir -p "${d}/chart"
  publish_at() { printf 'apiVersion: v2\nname: firefox-sync\nversion: %s\n' "$1" > "${d}/chart/Chart.yaml"; git -C "${d}" add -A
    git -C "${d}" -c user.name=t -c user.email=t@example.test commit -qm "$1"; }
  publish_at 1.0.0
  [[ "$(cd "${d}" && "${script}" chart)" == $'version=1.0.0\nprerelease=false' ]] || fail "chart-version.sh without a tag: $(cd "${d}" && "${script}" chart)"
  [[ "$(cd "${d}" && "${script}" chart chart-v1.0.0 main)" == $'version=1.0.0\nprerelease=false' ]] || fail "chart-v1.0.0 on main refused"
  out=$(cd "${d}" && "${script}" chart chart-v1.0.1 main 2>&1) && fail "chart-v1.0.1 for 1.0.0 accepted"
  grep -q 'is not chart-v1.0.0' <<< "${out}" || fail "a tag of another version: not the message: ${out}"
  git -C "${d}" switch -q -c topic
  for v in 1.0.1 1.0.1+build-1; do
    publish_at "${v}"
    out=$(cd "${d}" && "${script}" chart "chart-v${v}" main 2>&1) && fail "stable ${v} accepted off the default branch"
    grep -q 'a commit of main' <<< "${out}" || fail "stable ${v} off main: not the message: ${out}"
  done
  publish_at 1.0.1-dev.1+build-2
  [[ "$(cd "${d}" && "${script}" chart chart-v1.0.1-dev.1+build-2 main)" == $'version=1.0.1-dev.1+build-2\nprerelease=true' ]] \
    || fail "pre-release 1.0.1-dev.1+build-2 refused off the default branch"
  for v in 1.0 v1.0.0 01.0.0 1.0.0-; do
    publish_at "${v}"
    out=$(cd "${d}" && "${script}" chart 2>&1) && fail "version ${v} accepted"
    grep -q 'not a semantic version' <<< "${out}" || fail "version ${v}: not the message: ${out}"
  done
  printf 'apiVersion: v2\nname: firefox-sync\nversion: "2.0.0"\n' > "${d}/chart/Chart.yaml"
  [[ "$(cd "${d}" && "${script}" chart)" == $'version=2.0.0\nprerelease=false' ]] || fail "a quoted version: $(cd "${d}" && "${script}" chart)"
  rm -rf "${d}"
  [[ "$("${script}" "${CHART_DIR}" | head -1)" == "version=$(helm show chart "${CHART_DIR}" | sed -n 's/^version: //p')" ]] \
    || fail "chart-version.sh: not the version helm reads"
  check "the tag check: chart-v<version>, semver, stable (+build too) from the default branch only, pre-releases from anywhere"
}

# the chart against compose (docker compose config, no daemon): tests/helm_parity.py
parity() {
  echo "=== Comparing the chart with compose ==="
  python3 -I -c 'import yaml' 2> /dev/null || fail "parity needs PyYAML for python3 (apt install python3-yaml, pip install pyyaml)"
  docker compose version > /dev/null 2>&1 || fail "parity needs docker compose (config only, no daemon)"
  command -v helm > /dev/null || fail "parity needs helm"
  python3 -I "${SCRIPT_DIR}/helm_parity.py" "$@" || fail "the chart differs from compose"
}

# every env entry of every container (init containers too) of the rendered manifests (a JSON
# array on stdin): {c: container, n: name, v: value, or "secret:<key>"}
ENVS='[.[] | select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "CronJob" or .kind == "Job")
  | (.spec.jobTemplate.spec // .spec).template.spec | ((.initContainers // []) + .containers)[] | .name as $c
  | (.env // [])[] | {c: $c, n: .name, v: (.value // ("secret:" + .valueFrom.secretKeyRef.key))}]'

# the values of an env variable over all containers, sorted, unique: env_values <name> <helm args>...
env_values() {
  local name=$1
  shift
  helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" "$@" | manifests \
    | jq -r --arg n "${name}" "${ENVS} | map(select(.n == \$n) | .v) | unique | join(\" \")"
}

# notes <helm args>...: NOTES.txt as helm install shows it (helm template does not render it, and
# install --dry-run needs a cluster): rendered with tpl in a copy of the chart
notes() {
  local d out
  d=$(mktemp -d)
  cp -r "${CHART_DIR}" "${d}/chart" && cp "${CHART_DIR}/templates/NOTES.txt" "${d}/chart/files/notes.txt"
  printf '%s\n' 'apiVersion: v1' 'kind: ConfigMap' 'metadata: {name: notes}' 'data:' '  notes: {{ tpl (.Files.Get "files/notes.txt") . | toJson }}' \
    > "${d}/chart/templates/zz-notes.yaml"
  out=$(helm template test-release "${d}/chart" -f "${CHART_DIR}/ci/default-values.yaml" "$@" --show-only templates/zz-notes.yaml 2>&1 | manifests | jq -r '.[0].data.notes') || true
  rm -rf "${d}"
  echo "${out}"
}

# the names of the roles and databases (compose's SYNC_POSTGRES_APP_USER, ADMIN_DB_NAME,
# ADMIN_DB_USER, ADMIN_DB_SYNC_USER) and your own database server (database.bundled=false)
external_lint() {
  echo "Testing the names of the roles and databases..."
  local names=(--set database.postgresSyncUser=sync_owner --set database.admin.name=adm_db --set database.admin.user=adm_ui
    --set database.admin.syncUser=adm_sync --set admin.enabled=true --set backup.enabled=true)
  local backend out
  for backend in mariadb mysql postgres; do
    # (but in the scripts of the ConfigMaps, admin-user.sh and backup.sh, compose's defaults)
    out=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.backend="${backend}" "${names[@]}" \
      | manifests | jq -c '.[] | select(.kind != "ConfigMap")')
    ! grep -qE 'ffs_admin|syncserver_app' <<< "${out}" || fail "${backend}: the default names rendered: $(grep -oE '.{60}(ffs_admin|syncserver_app).{20}' <<< "${out}" | sort -u | head -5)"
    for pair in ADMIN_DB_NAME=adm_db ADMIN_DB_USER=adm_ui ADMIN_DB_SYNC_USER=adm_sync; do
      [[ "$(env_values "${pair%%=*}" --set database.backend="${backend}" "${names[@]}")" == "${pair#*=}" ]] \
        || fail "${backend}: ${pair%%=*}: $(env_values "${pair%%=*}" --set database.backend="${backend}" "${names[@]}")"
    done
  done
  [[ "$(env_values POSTGRES_SYNC_USER --set database.backend=postgres "${names[@]}")" == sync_owner ]] || fail "POSTGRES_SYNC_USER not database.postgresSyncUser"
  # the Sync server, its migrations, the backups and the admin UI's reader as that role
  out=$(env_values SYNC_TOKENSERVER__DATABASE_URL --set database.backend=postgres "${names[@]}")
  [[ "${out}" == 'postgres://sync_owner:$(POSTGRES_SYNC_PASSWORD)@test-release-firefox-sync-postgres:5432/syncserver' ]] || fail "the Sync server's URL: ${out}"
  [[ "$(env_values TOKENSERVER_DB_USER --set database.backend=postgres "${names[@]}")" == sync_owner ]] || fail "the backups and the admin UI not as database.postgresSyncUser"
  for bad in database.postgresSyncUser=Bad-Name database.admin.name= database.admin.user='x;drop' database.admin.syncUser=1abc \
    database.admin.name="$(printf 'a%.0s' $(seq 1 33))" database.external.postgresUser="$(printf 'a%.0s' $(seq 1 33))"; do
    if helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set "${bad}" > /dev/null 2>&1; then
      fail "${bad} not refused by the schema"
    fi
  done
  helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.admin.user="$(printf 'a%.0s' $(seq 1 32))" > /dev/null \
    || fail "a name of 32 characters refused"
  check "database.postgresSyncUser, database.admin.name/user/syncUser everywhere (no default name left), names a-z 0-9 _ only, at most 32"

  echo "Testing your own database server..."
  local ext=(--set database.bundled=false --set database.external.host=db.example.test --set existingSecret=mine)
  for backend in mariadb mysql postgres; do
    out=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.backend="${backend}" "${ext[@]}" | manifests)
    [[ "$(jq -r '[.[] | select(.kind == "StatefulSet" or .kind == "PersistentVolumeClaim" or .kind == "Secret" or .kind == "ConfigMap") | .kind + "/" + .metadata.name] | join(" ")' <<< "${out}")" == "ConfigMap/test-release-firefox-sync-db-setup" ]] \
      || fail "${backend}, bundled=false: a database server, volume, Secret or db-scripts rendered: $(jq -c '[.[] | .kind + "/" + .metadata.name]' <<< "${out}")"
    # db-bootstrap's script and setup migrations (compose's db-bootstrap, db/ at /ffs-db), before
    # the Sync role and the migrations
    local kind setup f
    kind=$([[ ${backend} == postgres ]] && echo postgres || echo mysql)
    setup=$(cd "${CHART_DIR}/files/db" && ls -1 "${kind}"/setup/sync/*.sql)
    [[ "$(jq -r '.[] | select(.kind == "ConfigMap") | .data["db-setup.sh"]' <<< "${out}")" == "$(cat "${CHART_DIR}/files/db-setup.sh")" ]] \
      || fail "${backend}, bundled=false: the db-setup ConfigMap's db-setup.sh is not files/db-setup.sh"
    [[ "$(jq -r '.[] | select(.kind == "ConfigMap") | .data | keys | join(" ")' <<< "${out}")" == "db-setup.sh $(tr '/' '_' <<< "${setup}" | paste -sd ' ' -)" ]] \
      || fail "${backend}, bundled=false: the db-setup ConfigMap has $(jq -r '.[] | select(.kind == "ConfigMap") | .data | keys | join(" ")' <<< "${out}"), not db-setup.sh and the setup migrations of ${kind}/setup/sync"
    for f in ${setup}; do
      [[ "$(jq -r --arg k "${f//\//_}" '.[] | select(.kind == "ConfigMap") | .data[$k]' <<< "${out}")" == "$(cat "${CHART_DIR}/files/db/${f}")" ]] || fail "${backend}: the db-setup ConfigMap's ${f} is not files/db/${f}"
      [[ "$(jq -r --arg k "${f//\//_}" '.[] | select(.kind == "Deployment" and .metadata.name == "test-release-firefox-sync-syncstorage") | .spec.template.spec.volumes[] | select(.name == "db-setup") | .configMap.items[] | select(.key == $k) | .path' <<< "${out}")" == "${f}" ]] \
        || fail "${backend}: ${f} not mounted at /ffs-db/${f}"
    done
    [[ "$(jq -r '.[] | select(.kind == "Deployment" and .metadata.name == "test-release-firefox-sync-syncstorage") | [.spec.template.spec.initContainers[].name] | join(" ")' <<< "${out}")" \
      == "wait-db db-bootstrap $([[ ${backend} == postgres ]] && echo "sync-role ")migrate db-init" ]] || fail "${backend}, bundled=false: the init containers are not wait-db db-bootstrap (sync-role) migrate db-init"
    [[ "$(jq -r '[.[] | select(.kind == "Service") | .metadata.name] | join(" ")' <<< "${out}")" == "test-release-firefox-sync-syncstorage" ]] \
      || fail "${backend}, bundled=false: Services other than the Sync server's"
  done
  check "bundled=false: no database server, volume, db-scripts ConfigMap or Secret, the db-setup ConfigMap of db-bootstrap after wait-db (mariadb, mysql, postgres)"
  # database.external.bootstrap.user: db-bootstrap applies the SQL as it, its password from the Secret (never a value)
  out=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" "${ext[@]}" --set database.external.bootstrap.user=ffs_bootstrap \
    --show-only templates/syncstorage.yaml | manifests | jq -c '.[] | select(.kind == "Deployment") | .spec.template.spec.initContainers[] | select(.name == "db-bootstrap") | .env[]
      | select(.name | startswith("SYNC_DB_BOOTSTRAP"))')
  [[ "${out}" == '{"name":"SYNC_DB_BOOTSTRAP_USER","value":"ffs_bootstrap"}'$'\n''{"name":"SYNC_DB_BOOTSTRAP_PASSWORD","valueFrom":{"secretKeyRef":{"name":"mine","key":"SYNC_DB_BOOTSTRAP_PASSWORD"}}}' ]] \
    || fail "database.external.bootstrap.user: db-bootstrap's env is ${out}"
  check "database.external.bootstrap.user: SYNC_DB_BOOTSTRAP_USER, and SYNC_DB_BOOTSTRAP_PASSWORD from existingSecret"
  # for your own server only, its password from existingSecret: the render fails otherwise, and
  # with an existingSecret without SYNC_DB_BOOTSTRAP_PASSWORD (lookup: tested on its data here)
  out=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.external.bootstrap.user=ffs_bootstrap 2>&1) \
    && fail "database.external.bootstrap.user with the bundled database rendered"
  grep -qF "database.external.bootstrap.user is for your own server (database.bundled=false)" <<< "${out}" || fail "bootstrap.user, bundled: not the message: ${out}"
  out=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.bundled=false --set database.external.host=db.example.test \
    --set database.external.bootstrap.user=ffs_bootstrap 2>&1) && fail "database.external.bootstrap.user without existingSecret rendered"
  grep -qF "database.external.bootstrap.user needs existingSecret, with SYNC_DB_BOOTSTRAP_PASSWORD" <<< "${out}" || fail "bootstrap.user without existingSecret: not the message: ${out}"
  local d
  d=$(mktemp -d)
  cp -r "${CHART_DIR}" "${d}/chart"
  printf '%s\n' '{{- include "firefox-sync.checkSecretKeys" (dict "root" . "name" .Values.existingSecret "data" (fromJson (.Files.Get "files/data.json"))) }}' \
    'apiVersion: v1' 'kind: ConfigMap' 'metadata: {name: checked}' > "${d}/chart/templates/zz-check.yaml"
  echo '{"SYNC_MASTER_SECRET":"eA=="}' > "${d}/chart/files/data.json"
  out=$(helm template test-release "${d}/chart" -f "${CHART_DIR}/ci/default-values.yaml" "${ext[@]}" --set database.external.bootstrap.user=ffs_bootstrap --show-only templates/zz-check.yaml 2>&1) \
    && fail "an existingSecret without SYNC_DB_BOOTSTRAP_PASSWORD passes"
  grep -qF "existingSecret mine lacks SYNC_DB_BOOTSTRAP_PASSWORD" <<< "${out}" || fail "an existingSecret without SYNC_DB_BOOTSTRAP_PASSWORD: not the message: ${out}"
  echo '{"SYNC_MASTER_SECRET":"eA==","SYNC_DB_BOOTSTRAP_PASSWORD":"eA=="}' > "${d}/chart/files/data.json"
  helm template test-release "${d}/chart" -f "${CHART_DIR}/ci/default-values.yaml" "${ext[@]}" --set database.external.bootstrap.user=ffs_bootstrap --show-only templates/zz-check.yaml > /dev/null \
    || fail "an existingSecret with SYNC_DB_BOOTSTRAP_PASSWORD refused"
  rm -rf "${d}"
  check "database.external.bootstrap.user: refused with the bundled database and without existingSecret; an existingSecret without SYNC_DB_BOOTSTRAP_PASSWORD refused naming it"
  # MariaDB/MySQL: compose's MARIADB_TOKENSERVER_* and MARIADB_SYNCSTORAGE_*, the storage
  # on another server too; the init container's TLS check from tlsVerify
  out=$(env_values SYNC_SYNCSTORAGE__DATABASE_URL --set database.backend=mysql "${ext[@]}")
  [[ "${out}" == 'mysql://syncstorage:$(STORAGE_DB_PASSWORD)@db.example.test:3306/syncstorage' ]] || fail "mysql, bundled=false: the storage URL: ${out}"
  local other=(--set database.backend=mysql "${ext[@]}" --set database.external.storageHost=st.example.test --set database.external.storagePort=3307
    --set database.external.port=3308 --set database.external.tokenserverDatabase=ts_db --set database.external.tokenserverUser=ts_user
    --set database.external.storageDatabase=st_db --set database.external.storageUser=st_user --set database.external.tlsVerify=false
    --set admin.enabled=true --set backup.enabled=true)
  [[ "$(env_values SYNC_TOKENSERVER__DATABASE_URL "${other[@]}")" == 'mysql://ts_user:$(TOKENSERVER_DB_PASSWORD)@db.example.test:3308/ts_db' ]] \
    || fail "mysql: the tokenserver URL: $(env_values SYNC_TOKENSERVER__DATABASE_URL "${other[@]}")"
  [[ "$(env_values SYNC_SYNCSTORAGE__DATABASE_URL "${other[@]}")" == 'mysql://st_user:$(STORAGE_DB_PASSWORD)@st.example.test:3307/st_db' ]] \
    || fail "mysql: the storage URL: $(env_values SYNC_SYNCSTORAGE__DATABASE_URL "${other[@]}")"
  for pair in "STORAGE_DB_HOST=st.example.test" "STORAGE_DB_PORT=3307" "STORAGE_DB_USER=st_user" "STORAGE_DB_NAME=st_db" \
    "TOKENSERVER_DB_HOST=db.example.test" "TOKENSERVER_DB_PORT=3308" "TOKENSERVER_DB_USER=ts_user" "TOKENSERVER_DB_NAME=ts_db" \
    "MARIADB_SERVER=db.example.test" "MARIADB_SERVER_PORT=3308" "MARIADB_DATABASE=ts_db" "MARIADB_USER=ts_user" "MARIADB_TLS_VERIFY=false"; do
    [[ "$(env_values "${pair%%=*}" "${other[@]}")" == "${pair#*=}" ]] || fail "mysql, your own servers: ${pair%%=*} is '$(env_values "${pair%%=*}" "${other[@]}")', not ${pair#*=}"
  done
  waits=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" "${other[@]}" --show-only templates/syncstorage.yaml \
    | grep -E '^ *wait_db "' | sed 's/^ *//' | paste -sd' ' -)
  [[ "${waits}" == 'wait_db "db.example.test" "3308" wait_db "st.example.test" "3307"' ]] || fail "wait-db does not wait for both servers: ${waits}"
  check "mysql, your own servers: host/port/database/user of each, the storage on another server, tlsVerify, wait-db for both"
  # MARIADB_TLS_VERIFY: false for your own server unless tlsVerify (prepare_environment.sh's),
  # the bundled ones unchanged (MariaDB checked, MySQL's self-signed not)
  for backend in mariadb mysql; do
    [[ "$(env_values MARIADB_TLS_VERIFY --set database.backend="${backend}" "${ext[@]}" --set backup.enabled=true)" == false ]] \
      || fail "${backend}, your own server: MARIADB_TLS_VERIFY not false by default"
    [[ "$(env_values MARIADB_TLS_VERIFY --set database.backend="${backend}" "${ext[@]}" --set backup.enabled=true --set database.external.tlsVerify=true)" == true ]] \
      || fail "${backend}, your own server: tlsVerify=true not MARIADB_TLS_VERIFY=true"
  done
  [[ "$(env_values MARIADB_TLS_VERIFY --set backup.enabled=true) $(env_values MARIADB_TLS_VERIFY --set database.backend=mysql --set backup.enabled=true)" == "true false" ]] \
    || fail "the bundled servers' MARIADB_TLS_VERIFY changed"
  notes --set database.backend=mysql "${ext[@]}" | grep -q 'do not check the server.s certificate (tlsVerify false' || fail "NOTES: nothing on tlsVerify false"
  notes --set database.backend=mysql "${ext[@]}" --set database.external.tlsVerify=true | grep -q 'from a CA the images trust' || fail "NOTES: nothing on tlsVerify true"
  check "your own MariaDB/MySQL: MARIADB_TLS_VERIFY false unless tlsVerify (NOTES says which), the bundled ones unchanged"
  # the bundled PostgreSQL on latest: NOTES says to pin its major (a chart cannot read it)
  notes --set database.backend=postgres | grep -q '^database.image.postgres is docker.io/library/postgres:latest: pin the major' \
    || fail "NOTES: nothing on pinning the bundled PostgreSQL's major"
  ! notes --set database.backend=postgres --set database.image.postgres=docker.io/library/postgres:17 | grep -q 'pin the major' \
    || fail "NOTES: the PostgreSQL pin note with a pinned major"
  check "NOTES: the bundled PostgreSQL on latest, pin its major (not when pinned)"
  # PostgreSQL: compose's SYNC_POSTGRES_* of your own server, POSTGRES_USER the owner (no Sync role)
  out=$(env_values SYNC_TOKENSERVER__DATABASE_URL --set database.backend=postgres "${ext[@]}")
  [[ "${out}" == 'postgres://syncserver:$(POSTGRES_PASSWORD)@db.example.test:5432/syncserver' ]] || fail "postgres, bundled=false: the URL: ${out}"
  local pg=(--set database.backend=postgres "${ext[@]}" --set database.external.port=6432 --set database.external.postgresDatabase=pg_db
    --set database.external.postgresUser=pg_owner --set admin.enabled=true --set backup.enabled=true)
  [[ "$(env_values SYNC_SYNCSTORAGE__DATABASE_URL "${pg[@]}")" == 'postgres://pg_owner:$(POSTGRES_PASSWORD)@db.example.test:6432/pg_db' ]] \
    || fail "postgres: the URL: $(env_values SYNC_SYNCSTORAGE__DATABASE_URL "${pg[@]}")"
  for pair in "POSTGRES_SERVER=db.example.test" "POSTGRES_SERVER_PORT=6432" "POSTGRES_DATABASE=pg_db" "POSTGRES_USER=pg_owner" \
    "POSTGRES_SYNC_USER=" "POSTGRES_SYNC_PASSWORD=" "TOKENSERVER_DB_USER=pg_owner" "TOKENSERVER_DB_PORT=6432" "TOKENSERVER_DB_PASSWORD=secret:ADMIN_DB_PASSWORD secret:POSTGRES_PASSWORD"; do
    [[ "$(env_values "${pair%%=*}" "${pg[@]}")" == "${pair#*=}" ]] || fail "postgres, your own server: ${pair%%=*} is '$(env_values "${pair%%=*}" "${pg[@]}")', not '${pair#*=}'"
  done
  ! helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" "${pg[@]}" | grep -q "key: POSTGRES_SYNC_PASSWORD$" \
    || fail "postgres, your own server: POSTGRES_SYNC_PASSWORD read from the Secret"
  check "postgres, your own server: host/port/database/owner, no Sync role (POSTGRES_SYNC_USER empty), the backups and the admin UI's reader as the owner"
  # fail closed: no server to reach, or generated passwords your server cannot know
  out=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.bundled=false --set existingSecret=mine 2>&1) \
    && fail "bundled=false without database.external.host renders"
  grep -q 'database.external.host' <<< "${out}" || fail "bundled=false without a host: not the message: ${out}"
  out=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.bundled=false --set database.external.host=db.example.test 2>&1) \
    && fail "bundled=false without existingSecret renders"
  grep -q 'existingSecret' <<< "${out}" || fail "bundled=false without existingSecret: not the message: ${out}"
  [[ "$(env_values SYNC_TOKENSERVER__DATABASE_URL --set database.backend=postgres "${ext[@]}" --set-string database.external.port=6432)" == *@db.example.test:6432/* ]] \
    || fail "a quoted database.external.port not taken"
  out=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" "${ext[@]}" --set-string database.external.port=70000 2>&1) \
    && fail "a quoted database.external.port 70000 renders"
  grep -q 'database.external.port 70000 is no port' <<< "${out}" || fail "a quoted port 70000: not the message: ${out}"
  for bad in database.external.port=-1 database.external.port=70000 database.external.port=abc database.external.storagePort=0; do
    if helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" "${ext[@]}" --set "${bad}" > /dev/null 2>&1; then
      fail "${bad} not refused by the schema"
    fi
  done
  check "bundled=false refused without database.external.host or existingSecret; ports 1-65535 only (quoted too, with a message)"
}

# the Ingress of the Sync server (ingress.*) and, apart, of the admin UI (admin.ingress.*):
# never the admin UI by accident
ingress_lint() {
  echo "Testing the Ingresses..."
  ingresses() {
    helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" "$@" | manifests | jq -c '[.[] | select(.kind == "Ingress")
      | {name: .metadata.name, class: .spec.ingressClassName, annotations: .metadata.annotations, tls: .spec.tls,
         rules: [.spec.rules[] | {host, paths: [.http.paths[] | [.path, .pathType, .backend.service.name, .backend.service.port.number]]}]}]'
  }
  [[ "$(ingresses --set admin.enabled=true --set admin.ingress.host=admin.example.test)" == '[]' ]] || fail "an Ingress by default"
  [[ "$(ingresses --set ingress.enabled=true --set ingress.host=sync.example.test)" == \
    '[{"name":"test-release-firefox-sync-syncstorage","class":null,"annotations":null,"tls":null,"rules":[{"host":"sync.example.test","paths":[["/","Prefix","test-release-firefox-sync-syncstorage",8000]]}]}]' ]] \
    || fail "ingress.enabled: $(ingresses --set ingress.enabled=true --set ingress.host=sync.example.test)"
  # the host of syncDomain when ingress.host is empty; class, TLS, annotations
  [[ "$(ingresses --set ingress.enabled=true --set syncDomain=https://ffs.example.test/ --set ingress.className=nginx --set ingress.tls.enabled=true \
    --set ingress.tls.secretName=ffs-tls --set ingress.annotations.a=b --set syncstorage.service.port=8001)" == \
    '[{"name":"test-release-firefox-sync-syncstorage","class":"nginx","annotations":{"a":"b"},"tls":[{"hosts":["ffs.example.test"],"secretName":"ffs-tls"}],"rules":[{"host":"ffs.example.test","paths":[["/","Prefix","test-release-firefox-sync-syncstorage",8001]]}]}]' ]] \
    || fail "ingress with the host of syncDomain, class, TLS, annotations: $(ingresses --set ingress.enabled=true --set syncDomain=https://ffs.example.test/ \
      --set ingress.className=nginx --set ingress.tls.enabled=true --set ingress.tls.secretName=ffs-tls --set ingress.annotations.a=b --set syncstorage.service.port=8001)"
  check "ingress: off by default; <fullname>-syncstorage at / of ingress.host (else syncDomain's), class, TLS, annotations"
  # the admin UI's: only with admin.enabled and admin.ingress.enabled, on a host of its own
  [[ "$(ingresses --set ingress.enabled=true --set admin.enabled=true | jq -r 'map(.name) | join(" ")')" == test-release-firefox-sync-syncstorage ]] \
    || fail "ingress.enabled with the admin UI: an admin Ingress"
  [[ "$(ingresses --set admin.ingress.enabled=true --set admin.ingress.host=admin.example.test)" == '[]' ]] || fail "admin.ingress.enabled without admin.enabled: an Ingress"
  [[ "$(ingresses --set admin.enabled=true --set admin.ingress.enabled=true --set admin.ingress.host=admin.example.test --set admin.ingress.className=internal \
    --set admin.ingress.tls.enabled=true --set admin.ingress.annotations.c=d)" == \
    '[{"name":"test-release-firefox-sync-admin","class":"internal","annotations":{"c":"d"},"tls":[{"hosts":["admin.example.test"]}],"rules":[{"host":"admin.example.test","paths":[["/","Prefix","test-release-firefox-sync-admin",8080]]}]}]' ]] \
    || fail "admin.ingress: $(ingresses --set admin.enabled=true --set admin.ingress.enabled=true --set admin.ingress.host=admin.example.test \
      --set admin.ingress.className=internal --set admin.ingress.tls.enabled=true --set admin.ingress.annotations.c=d)"
  local out
  out=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set admin.enabled=true --set admin.ingress.enabled=true 2>&1) \
    && fail "admin.ingress without a host renders"
  grep -q 'admin.ingress.host' <<< "${out}" || fail "admin.ingress without a host: not the message: ${out}"
  out=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set ingress.enabled=true --set admin.enabled=true \
    --set admin.ingress.enabled=true --set admin.ingress.host=sync.example.test 2>&1) && fail "the admin UI's Ingress on the Sync server's host renders"
  grep -q 'admin.ingress.host' <<< "${out}" || fail "the admin UI's Ingress on the Sync host: not the message: ${out}"
  # (syncDomain's host also without the Sync server's Ingress: your own in front of it)
  out=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set admin.enabled=true \
    --set admin.ingress.enabled=true --set admin.ingress.host=sync.example.test 2>&1) && fail "the admin UI's Ingress on syncDomain's host renders"
  grep -q 'is the Sync server.s host' <<< "${out}" || fail "the admin UI's Ingress on syncDomain's host: not the message: ${out}"
  # host names are case-insensitive (a trailing dot the same host)
  for host in SYNC.Example.TEST sync.example.test.; do
    out=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set admin.enabled=true \
      --set admin.ingress.enabled=true --set admin.ingress.host="${host}" 2>&1) && fail "the admin UI's Ingress on ${host} (syncDomain's host) renders"
    grep -q 'is the Sync server.s host' <<< "${out}" || fail "the admin UI's Ingress on ${host}: not the message: ${out}"
  done
  out=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set ingress.enabled=true --set ingress.host=Sync.Example.Test \
    --set admin.enabled=true --set admin.ingress.enabled=true --set admin.ingress.host=sync.EXAMPLE.test 2>&1) \
    && fail "the admin UI's Ingress on the Sync Ingress's host in other letters renders"
  local admin_on=(--set admin.enabled=true --set admin.ingress.enabled=true --set admin.ingress.host=admin.example.test)
  notes "${admin_on[@]}" | grep -q '^WARNING: admin.ingress.tls.enabled is false' || fail "NOTES: no warning on the admin Ingress without TLS"
  ! notes "${admin_on[@]}" --set admin.ingress.tls.enabled=true | grep -q WARNING || fail "NOTES: a warning on the admin Ingress with TLS"
  out=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set ingress.enabled=true --set syncDomain=https:// 2>&1) \
    && fail "ingress without a host (none in syncDomain either) renders"
  check "admin.ingress: <fullname>-admin:8080 only with admin.enabled and admin.ingress.enabled, a host of its own (required, not the Sync server's nor syncDomain's, in any case), NOTES warns without TLS"
  # valid Kubernetes objects, everything on (kubeconform -strict)
  if command -v kubeconform > /dev/null; then
    helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/backup-values.yaml" --set ingress.enabled=true --set ingress.host=sync.example.test \
      --set ingress.tls.enabled=true --set ingress.tls.secretName=ffs-tls --set admin.ingress.enabled=true --set admin.ingress.host=admin.example.test \
      | kubeconform -strict -summary -kubernetes-version 1.27.0 || fail "kubeconform -strict: invalid objects"
    for backend in mysql postgres; do
      helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.backend="${backend}" \
        --set database.bundled=false --set database.external.host=db.example.test --set existingSecret=mine --set ingress.enabled=true \
        | kubeconform -strict -summary -kubernetes-version 1.27.0 || fail "kubeconform -strict (${backend}, your own server): invalid objects"
    done
    check "kubeconform -strict: the chart with the Ingresses, admin UI and backups; with your own server (mysql, postgres)"
  else
    echo "(kubeconform not installed: the objects not validated)"
  fi
}

# e2e <mariadb|mysql|postgres>: the chart on a throwaway kind cluster, with upstream's mock
# FxA, what a Firefox client does (tests/test_client_flow.py), fail closed, and upgrades.
# EXTERNAL_DB=1 (mysql, postgres): on a database server of its own in the cluster, which the
# chart does not manage (database.bundled=false), as tests/e2e.sh's EXTERNAL_DB=1; with
# DB_BOOTSTRAP=1 that server has only the bootstrap account of db/<engine>/setup/sync-bootstrap, and
# db-bootstrap creates the rest (database.external.bootstrap.user), also the admin UI's reader
# dropped later (docs/databases.md#let-the-stack-apply-them)
e2e() {
  local backend=${1:-}
  local flavor password_key init_dir
  EXTERNAL=${EXTERNAL_DB:-}
  case "${backend}" in
    mariadb|mysql) failing_init='wait-db=0 migrate=[1-9]'; flavor=mysql; password_key=TOKENSERVER_DB_PASSWORD; init_dir=db/mysql/init ;;
    postgres) failing_init='wait-db=0 sync-role=[1-9]'; flavor=postgres; password_key=POSTGRES_PASSWORD; init_dir=db/postgres/init ;;
    *) echo "Usage: $0 e2e <mariadb|mysql|postgres>"; exit 1 ;;
  esac
  if [[ -n "${EXTERNAL}" ]]; then
    [[ ${backend} != mariadb ]] || { echo "EXTERNAL_DB=1: mysql (MySQL 8 with binary logging) or postgres (PostgreSQL 18), as tests/e2e.sh"; exit 1; }
    # (PostgreSQL: POSTGRES_USER is the owner, no Sync role: sync-role does nothing, the
    # migrations are the first to log in)
    # db-bootstrap checks the users first, a refused login stops the start there (with the
    # bootstrap the account's own: it sets the stack's passwords itself)
    failing_init='wait-db=0 db-bootstrap=[1-9]'
    [[ -z "${DB_BOOTSTRAP:-}" ]] || password_key=SYNC_DB_BOOTSTRAP_PASSWORD
  elif [[ -n "${DB_BOOTSTRAP:-}" ]]; then
    echo "DB_BOOTSTRAP=1 is for EXTERNAL_DB=1"; exit 1
  fi
  [[ ${backend} != mysql ]] || mysqld_apparmor_check
  # as tests/e2e.sh: REPOSITORY and TAG of the images; the init image is built from this
  # tree (the published one may be older than the chart), unless SKIP_BUILD=1
  local repository=${REPOSITORY:-ghcr.io/porelli/firefox-sync} tag=${TAG:-latest} init_tag=${TAG:-latest}
  # the admin UI too (ADMIN_DEPLOYMENT=kubernetes is in this tree)
  ADMIN_TAG=${TAG:-latest}
  BACKEND=${backend}
  CLUSTER="ffs-helm-${backend}${EXTERNAL:+-ext}"
  REL=t
  FULL="${REL}-firefox-sync"
  # the Secret the chart reads: its own, or that of existingSecret
  SECRET=${FULL}
  SYNC_IMAGE="${repository}:syncstorage-rs-${flavor}-${tag}"
  SYNCSTORAGE_DOMAIN=https://sync.example.test
  POD_SELECTOR="app.kubernetes.io/instance=${REL},app.kubernetes.io/component=syncstorage"

  echo "=== e2e on kind (${backend}${EXTERNAL:+, your own database server}) ==="
  kind delete cluster --name "${CLUSTER}" > /dev/null 2>&1 || true
  trap 'rc=$?; if ((rc)); then diagnostics; fi; kind_teardown' EXIT
  kind create cluster --name "${CLUSTER}" --wait 120s
  kubectl config use-context "kind-${CLUSTER}" > /dev/null
  # the namespace at PodSecurity baseline (docs/install/helm.md#requirements), enforced: every pod of the
  # chart (and of the tests) is admitted under it, a refused one fails the run
  kubectl label ns default pod-security.kubernetes.io/enforce=baseline pod-security.kubernetes.io/enforce-version=latest > /dev/null
  load_images "${repository}" "${flavor}" "${init_dir}"

  # a syncstorage image of the host's docker (of a private repository, or built there): into
  # the cluster, which would pull it otherwise
  # (not kind load: it imports --all-platforms, which a pulled image's export lacks); pulled
  # with the host's credentials first when it is not there (a private repository)
  docker image inspect "${SYNC_IMAGE}" > /dev/null 2>&1 || docker pull -q "${SYNC_IMAGE}" > /dev/null 2>&1 || true
  if docker image inspect "${SYNC_IMAGE}" > /dev/null 2>&1; then
    docker save "${SYNC_IMAGE}" | docker exec -i "${CLUSTER}-control-plane" \
      ctr --namespace=k8s.io images import --digests --snapshotter=overlayfs - > /dev/null || fail "${SYNC_IMAGE} not loaded"
    check "${SYNC_IMAGE} loaded from the host's docker"
  fi
  sed "s|ghcr.io/porelli/firefox-sync:syncstorage-rs-mysql-latest|${SYNC_IMAGE}|" \
    "${SCRIPT_DIR}/helm/mock-fxa.yaml" | kubectl apply -f -
  kubectl rollout status deploy/mock-fxa --timeout=5m
  check "mock FxA is up"

  local db_args=(--set backup.enabled=true)
  # the bundled MySQL as an install from before mysql:lts: on 8, moved below (checkDbMajor)
  [[ ${backend} == mysql && -z "${EXTERNAL}" ]] && db_args+=(--set database.image.mysql=docker.io/library/mysql:8)
  if [[ -n "${EXTERNAL}" ]]; then
    start_extdb
    # your own server: its names (not the defaults), the passwords in your Secret, the
    # backups; the Ingress on, of a class no controller serves
    SECRET=ffs-own
    db_args=(--set database.bundled=false --set database.external.host=extdb --set existingSecret="${SECRET}"
      --set database.admin.name="${EXT_ADMIN_DB}" --set database.admin.user="${EXT_ADMIN_USER}" --set database.admin.syncUser="${EXT_ADMIN_SYNC}"
      --set ingress.enabled=true --set ingress.className=none --set backup.enabled=true)
    # the chart applies the SQL itself, as the account start_extdb made (its password in ffs-own)
    [[ -z "${DB_BOOTSTRAP:-}" ]] || db_args+=(--set database.external.bootstrap.user=ffs_bootstrap)
    if [[ ${backend} == mysql ]]; then
      # (MySQL's own certificate is self-signed: database.external.tlsVerify false, its default)
      db_args+=(--set database.external.tokenserverDatabase="${EXT_TS_DB}"
        --set database.external.tokenserverUser="${EXT_TS_USER}" --set database.external.storageDatabase="${EXT_ST_DB}"
        --set database.external.storageUser="${EXT_ST_USER}")
    else
      db_args+=(--set database.external.postgresDatabase="${EXT_PG_DB}" --set database.external.postgresUser="${EXT_PG_USER}")
    fi
  fi
  helm install "${REL}" "${CHART_DIR}" \
    --set syncDomain="${SYNCSTORAGE_DOMAIN}" --set maxUsers=1 \
    --set fxa.oauthServerUrl=http://mock-fxa:6000 \
    --set fxa.emailDomain=api-accounts.stage.mozaws.net \
    --set database.backend="${backend}" --set image.repository="${repository}" \
    --set image.syncstorageTag="${tag}" --set image.initTag="${init_tag}" "${db_args[@]}" --wait --timeout 10m \
    || fail "helm install did not get Ready"
  check "helm install (${backend}${EXTERNAL:+, your own server}) Ready, in a namespace enforcing PodSecurity baseline"
  if [[ -n "${EXTERNAL}" ]]; then
    # (the backups' PVC only)
    [[ "$(kubectl get sts,pvc,secret -l "app.kubernetes.io/instance=${REL}" -o name | paste -sd' ' -)" == "persistentvolumeclaim/${FULL}-backups" ]] \
      || fail "bundled=false: the chart made $(kubectl get sts,pvc,secret -l "app.kubernetes.io/instance=${REL}" -o name | paste -sd' ' -)"
    check "no database server, database volume or Secret of the chart (the backups' PVC)"
    ingress_is "${FULL}-syncstorage" none sync.example.test "${FULL}-syncstorage" 8000
    check "Ingress ${FULL}-syncstorage (class none): sync.example.test/ to ${FULL}-syncstorage:8000"
  fi

  kubectl create configmap ffs-tests --from-file="${SCRIPT_DIR}/test_client_flow.py"
  client_flow flow-1 || fail "client flow failed"
  check "client flow passed"
  database_users

  # fail closed: an invalid MAX_USERS never reaches the cluster
  if out=$(helm upgrade "${REL}" "${CHART_DIR}" --reuse-values --set maxUsers=bogus --no-hooks 2>&1); then
    fail "helm upgrade accepted maxUsers=bogus"
  fi
  echo "${out}" | grep -q maxUsers || fail "maxUsers=bogus refused, but not by the schema: ${out}"
  check "maxUsers=bogus refused by the schema"

  # fail closed: a wrong database password stops the pod at migrate (wait-db has no
  # credentials), never Ready, out of the Service
  good=$(kubectl get secret "${SECRET}" -o jsonpath="{.data.${password_key}}")
  kubectl patch secret "${SECRET}" --type merge -p "{\"data\":{\"${password_key}\":\"$(printf wrong | base64)\"}}"
  kubectl delete pod -l "${POD_SELECTOR}" --wait=true
  wait_pod_status 'Init:Error|Init:CrashLoopBackOff' 420 || fail "pod did not stop in its init containers"
  check "wrong ${password_key}: pod is in ${MATCHED_STATUS}"
  inits=$(kubectl get pods -l "${POD_SELECTOR}" -o json | jq -r '.items[0].status.initContainerStatuses[]
    | "\(.name)=\(.state.terminated.exitCode // .lastState.terminated.exitCode // "none")"' | paste -sd' ' -)
  # (PostgreSQL: the superuser's password, the first login is sync-role's; the Sync role's
  # own password is set again by sync-role at every start)
  [[ "${inits}" =~ ${failing_init} ]] || fail "expected wait-db to pass and the next init to fail: ${inits}"
  check "wait-db passed, the next init failed (${inits})"
  ready=$(kubectl get endpointslices -l "kubernetes.io/service-name=${FULL}-syncstorage" -o json \
    | jq '[.items[].endpoints[]? | select(.conditions.ready == true)] | length')
  [[ "${ready}" == 0 ]] || fail "the Service has ${ready} ready endpoints while the init fails"
  [[ "$(kubectl get pods -l "${POD_SELECTOR}" -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}')" != True ]] \
    || fail "the syncstorage pod is Ready while the init fails"
  check "the syncstorage Service has no ready endpoints, the pod is not Ready"
  kubectl patch secret "${SECRET}" --type merge -p "{\"data\":{\"${password_key}\":\"${good}\"}}"
  kubectl delete pod -l "${POD_SELECTOR}" --wait=true
  kubectl wait --for=condition=Ready pod -l "${POD_SELECTOR}" --timeout=10m || fail "pod not Ready after restoring the password"
  check "password restored: Ready again"
  if [[ -n "${EXTERNAL}" && -n "${DB_BOOTSTRAP:-}" ]]; then
    # a release that needs a user your server lacks: the admin UI's reader dropped, a new pod
    # (the next start): db-bootstrap creates it again (docs/databases.md#let-the-stack-apply-them)
    if [[ "${BACKEND}" == mysql ]]; then
      extdb_admin -e "DROP USER '${EXT_ADMIN_SYNC}'@'%';" < /dev/null || fail "${EXT_ADMIN_SYNC} not dropped"
      reader() { extdb_admin -e "SELECT COUNT(*) FROM mysql.user WHERE user = '${EXT_ADMIN_SYNC}'" < /dev/null; }
    else
      printf '%s\n' "\\connect ${EXT_PG_DB}" "DROP OWNED BY ${EXT_ADMIN_SYNC};" "DROP ROLE ${EXT_ADMIN_SYNC};" | extdb_admin > /dev/null || fail "${EXT_ADMIN_SYNC} not dropped"
      reader() { extdb_admin -c "SELECT COUNT(*) FROM pg_roles WHERE rolname = '${EXT_ADMIN_SYNC}'" < /dev/null; }
    fi
    [[ "$(reader)" == 0 ]] || fail "${EXT_ADMIN_SYNC} still there"
    kubectl delete pod -l "${POD_SELECTOR}" --wait=true
    kubectl wait --for=condition=Ready pod -l "${POD_SELECTOR}" --timeout=10m || fail "pod not Ready after the reader was dropped"
    [[ "$(reader)" == 1 ]] || fail "db-bootstrap did not create ${EXT_ADMIN_SYNC} again"
    kubectl logs deploy/"${FULL}"-syncstorage -c db-bootstrap | grep -q 'drift from the setup migrations, run again as ffs_bootstrap' || fail "db-bootstrap did not run the setup migrations again as ffs_bootstrap"
    check "the admin UI's reader dropped: the next pod's db-bootstrap created it again as ffs_bootstrap, Ready"
  fi

  # upgrades keep every secret
  before=$(kubectl get secret "${SECRET}" -o json | jq -S .data)
  helm upgrade "${REL}" "${CHART_DIR}" --reuse-values \
    --set syncstorage.resources.requests.cpu=50m --wait --timeout 10m || fail "helm upgrade failed"
  after=$(kubectl get secret "${SECRET}" -o json | jq -S .data)
  [[ "${before}" == "${after}" ]] || fail "helm upgrade changed the Secret"
  for key in SYNC_MASTER_SECRET METRICS_HASH_SECRET ADMIN_PASSWORD; do
    [[ "$(echo "${after}" | jq -r ".${key} // empty")" != "" ]] || fail "Secret has no ${key}"
  done
  check "helm upgrade kept the Secret data"
  # as tests/e2e.sh: the first run changed alice's keys, a first sign-in needs no users
  sql "DELETE FROM users;" || fail "could not empty the users table"
  client_flow flow-2 "-k first_sign_in" || fail "client flow after the upgrade failed"
  check "client flow after the upgrade passed"

  # invite-only Sync (allowedAccounts): one backend, the bundled MariaDB
  [[ ${backend} == mariadb && -z "${EXTERNAL}" ]] && allowlist_e2e

  # another major of the bundled database: refused at render time, nothing applied; MySQL
  # moves with database.allowMajorUpgrade (8 to lts, its data upgraded in place)
  if [[ -z "${EXTERNAL}" ]]; then
    local revision sts_image other refused
    revision=$(helm history "${REL}" -o json | jq length)
    sts_image() { kubectl get sts "$1" -o jsonpath='{.spec.template.spec.containers[?(@.name=="db")].image}'; }
    case ${backend} in
      mysql) other=docker.io/library/mysql:lts ;;
      mariadb) other=docker.io/library/mariadb:latest ;;
      postgres) other=docker.io/library/postgres:alpine ;;
    esac
    local db_sts=${FULL}-tokenserver-db
    [[ ${backend} == postgres ]] && db_sts=${FULL}-postgres
    local running
    running=$(sts_image "${db_sts}")
    for allow in false true; do
      [[ ${allow} == true && ${backend} != postgres ]] && continue
      if refused=$(helm upgrade "${REL}" "${CHART_DIR}" --reuse-values --set database.image."${backend}"="${other}" \
          --set database.allowMajorUpgrade="${allow}" 2>&1); then
        fail "helm upgrade to ${other} on ${running} (allowMajorUpgrade=${allow}) not refused"
      fi
      grep -q "firefox-sync: database.image.${backend} is ${other} but the bundled .* runs ${running}" <<< "${refused}" \
        || fail "the refusal does not name both images: ${refused}"
    done
    [[ "$(helm history "${REL}" -o json | jq length) $(sts_image "${db_sts}")" == "${revision} ${running}" ]] \
      || fail "the refused upgrade changed the release or the StatefulSet"
    check "helm upgrade from ${running} to ${other} refused at render time (also allowMajorUpgrade=true for PostgreSQL), nothing applied"
    # another server on the same data (MariaDB and MySQL share the StatefulSets), or an empty
    # one (PostgreSQL's own): refused at render time too (checkDbBackend), nothing applied
    local switch=mysql
    [[ ${backend} == mysql ]] && switch=mariadb
    if refused=$(helm upgrade "${REL}" "${CHART_DIR}" --reuse-values --set database.backend="${switch}" 2>&1); then
      fail "helm upgrade to database.backend=${switch} on ${backend} not refused"
    fi
    grep -q "firefox-sync: database.backend is ${switch} but the bundled Sync database ${db_sts} runs ${backend}; switching needs a dump and restore" <<< "${refused}" \
      || fail "the backend refusal does not say what runs: ${refused}"
    [[ "$(helm history "${REL}" -o json | jq length) $(sts_image "${db_sts}")" == "${revision} ${running}" ]] \
      || fail "the refused backend switch changed the release or the StatefulSet"
    check "helm upgrade from database.backend=${backend} to ${switch} refused at render time, nothing applied"
    # the volumes as they are (checkClaim, lookups): a StatefulSet's volumeClaimTemplates never
    # change, the backups' PVC grows only with a StorageClass of allowVolumeExpansion (kind's
    # standard: off for this, then as it was); refused at render time, nothing applied
    local sc_before sts_size
    sc_before=$(kubectl get storageclass standard -o jsonpath='{.allowVolumeExpansion}')
    kubectl patch storageclass standard --type merge -p '{"allowVolumeExpansion": false}' > /dev/null || fail "kind's StorageClass standard not patched"
    sts_size=$(kubectl get sts "${db_sts}" -o jsonpath='{.spec.volumeClaimTemplates[0].spec.resources.requests.storage}')
    for change in "database.persistence.size=9Gi:firefox-sync: database.persistence.size is 9Gi but the StatefulSet ${db_sts} (its volume data) was created with ${sts_size}: Kubernetes never changes a StatefulSet's volumeClaimTemplates; set it back to ${sts_size}" \
      "database.persistence.storageClass=fast:firefox-sync: database.persistence.storageClass is \"fast\" but the StatefulSet ${db_sts} (its volume data) was created with \"\"" \
      "backup.persistence.size=20Gi:firefox-sync: backup.persistence.size is 20Gi but the PVC ${FULL}-backups is 10Gi, and its StorageClass \"standard\" does not allow expansion"; do
      if refused=$(helm upgrade "${REL}" "${CHART_DIR}" --reuse-values --set "${change%%:*}" 2>&1); then
        fail "helm upgrade --set ${change%%:*} not refused"
      fi
      grep -qF "${change#*:}" <<< "${refused}" || fail "helm upgrade --set ${change%%:*}: refused, but not by the chart's check: ${refused}"
    done
    if [[ -n "${sc_before}" ]]; then
      kubectl patch storageclass standard --type merge -p "{\"allowVolumeExpansion\": ${sc_before}}" > /dev/null
    else
      kubectl patch storageclass standard --type json -p '[{"op": "remove", "path": "/allowVolumeExpansion"}]' > /dev/null
    fi
    [[ "$(helm history "${REL}" -o json | jq length) $(sts_image "${db_sts}") $(kubectl get sts "${db_sts}" -o jsonpath='{.spec.volumeClaimTemplates[0].spec.resources.requests.storage}') $(kubectl get pvc "${FULL}-backups" -o jsonpath='{.spec.resources.requests.storage}')" \
      == "${revision} ${running} ${sts_size} 10Gi" ]] || fail "a refused volume change changed the release, the StatefulSet or the backups' PVC"
    check "helm upgrade with database.persistence.size or .storageClass (${db_sts}'s volumeClaimTemplate), backup.persistence.size up on a StorageClass without allowVolumeExpansion: refused at render time saying what to set, nothing applied"
    if [[ ${backend} == postgres ]]; then
      # a pin to another major goes through the render (from latest, not comparable), the
      # db-major init container then refuses the data and says what to pin; back on the
      # running image, it starts again (a StatefulSet does not replace a broken pod by itself)
      helm upgrade "${REL}" "${CHART_DIR}" --reuse-values --set database.image.postgres=docker.io/library/postgres:17 > /dev/null \
        || fail "helm upgrade to postgres:17 not rendered"
      local said="" i
      for i in $(seq 1 90); do
        said=$(kubectl logs "${db_sts}-0" -c db-major 2> /dev/null | grep -c 'keep-major.sh: this database is PostgreSQL 18 (/var/lib/postgresql/18/docker), the image is PostgreSQL 17' || true)
        [[ "${said}" -ge 1 ]] 2> /dev/null && break
        sleep 2
      done
      [[ "${said}" -ge 1 && "$(kubectl get pod "${db_sts}-0" -o jsonpath='{.status.containerStatuses[0].ready}')" != true ]] \
        || fail "postgres:17 on 18's data: the db-major init container did not refuse ($(kubectl logs "${db_sts}-0" -c db-major 2>&1 | tail -3))"
      kubectl logs "${db_sts}-0" -c db-major 2> /dev/null | grep -q 'Set database.image.postgres to the major of the data, postgres:18' \
        || fail "db-major does not say what to pin"
      helm upgrade "${REL}" "${CHART_DIR}" --reuse-values --set database.image.postgres="${running}" > /dev/null || fail "helm upgrade back to ${running}"
      kubectl delete pod "${db_sts}-0" --wait=true > /dev/null
      kubectl rollout status "sts/${db_sts}" --timeout=10m > /dev/null || fail "PostgreSQL not back on ${running}"
      kubectl wait --for=condition=Ready pod -l "${POD_SELECTOR}" --timeout=10m > /dev/null || fail "syncstorage not Ready after PostgreSQL came back"
      check "postgres:17 on 18's data: refused by the db-major init container, which says what to pin; back on ${running}"
    fi
    if [[ ${backend} == mysql ]]; then
      helm upgrade "${REL}" "${CHART_DIR}" --reuse-values --set database.image.mysql="${other}" --set database.allowMajorUpgrade=true \
        --wait --timeout 10m || fail "helm upgrade to ${other} with allowMajorUpgrade did not get Ready"
      kubectl rollout status "sts/${db_sts}" --timeout=10m > /dev/null && kubectl rollout status "sts/${FULL}-storage-db" --timeout=10m > /dev/null \
        || fail "the MySQL StatefulSets did not roll out on ${other}"
      kubectl wait --for=condition=Ready pod -l "${POD_SELECTOR}" --timeout=10m > /dev/null || fail "syncstorage not Ready on ${other}"
      local version
      version=$(sql "SELECT VERSION();" 2> /dev/null | tail -n 1)
      [[ "$(sts_image "${db_sts}") ${version%%.*}" =~ ^${other}\ (9|[1-9][0-9])$ ]] \
        || fail "the bundled MySQL is not on a newer major: $(sts_image "${db_sts}") ${version}"
      sql "DELETE FROM users;" || fail "could not empty the users table"
      client_flow flow-2b "-k first_sign_in" || fail "client flow on ${other} failed"
      check "allowMajorUpgrade: the bundled MySQL moved from 8 to ${other} (${version}), the client flow passes"
    fi
  fi

  admin_toggle
  reinstall

  echo ""
  echo "=== e2e (${backend}) passed ==="
}

# allowedAccounts (SYNC_ALLOWED_ACCOUNTS) on a running release: the db-init container of the new
# pod applies it, a listed uid gets in, another is refused and recorded as pending, an account
# from before (alice, of the client flow) still syncs; then off again
allowlist_e2e() {
  local listed=0123456789abcdef0123456789abcdef other=fedcba9876543210fedcba9876543210 got
  helm upgrade "${REL}" "${CHART_DIR}" --reuse-values --set-string allowedAccounts="initial:${listed}" --wait --timeout 10m \
    || fail "helm upgrade with allowedAccounts did not get Ready"
  kubectl logs -l "${POD_SELECTOR}" -c db-init --tail=-1 | grep -q "SYNC_ALLOWED_ACCOUNTS=initial:${listed}: invite-only, 1 accounts allowed" \
    || fail "the db-init container did not apply allowedAccounts: $(kubectl logs -l "${POD_SELECTOR}" -c db-init --tail=5)"
  got=$(sql "SELECT config_value FROM config WHERE config_key = 'allowed_accounts'; SELECT uid FROM sync_allowed_accounts;" -sN | paste -sd' ' -)
  [[ "${got}" == "on ${listed}" ]] || fail "allowedAccounts: the database has ${got}"
  check "allowedAccounts=initial:<uid> applied by the db-init container (on, the uid listed)"
  client_flow flow-allowlist "-k second_device" || fail "an account from before the allowlist no longer syncs"
  check "an account from before the allowlist still syncs"
  # (maxUsers=1 is full with alice: no limit here, as before for the next ones)
  local max
  max=$(sql "SELECT config_value FROM config WHERE config_key = 'max_users'" -sN)
  sql "UPDATE config SET config_value = 'unlimited' WHERE config_key = 'max_users'" > /dev/null || fail "max users not lifted"
  ins() { sql "INSERT INTO users (service, email, generation, client_state, created_at, nodeid) SELECT s.id, '$1@helm.invalid', 1, 'aa', 1, n.id FROM services s JOIN nodes n ON n.service = s.id WHERE s.service = 'sync-1.5' AND n.downed = 0" > /dev/null 2>&1
    sql "SELECT COUNT(*) FROM users WHERE email = '$1@helm.invalid'" -sN; }
  got="$(ins "${listed}") $(ins "${other}") $(sql "SELECT uid FROM sync_refused_accounts" -sN)"
  [[ "${got}" == "1 0 ${other}" ]] || fail "allowedAccounts: listed, unlisted and pending: ${got}"
  check "a listed uid gets in, another one is refused and pending"
  sql "DELETE FROM users WHERE email LIKE '%@helm.invalid'; DELETE FROM sync_refused_accounts;" > /dev/null || fail "could not clean up"
  helm upgrade "${REL}" "${CHART_DIR}" --reuse-values --set-string allowedAccounts= --wait --timeout 10m || fail "helm upgrade allowedAccounts= did not get Ready"
  sql "UPDATE config SET config_value = 'unlimited' WHERE config_key = 'max_users'" > /dev/null || fail "max users not lifted"
  got="$(sql "SELECT config_value FROM config WHERE config_key = 'allowed_accounts'" -sN) $(ins "${other}")"
  [[ "${got}" == "off 1" ]] || fail "allowedAccounts empty again: ${got}"
  sql "DELETE FROM users WHERE email LIKE '%@helm.invalid'; UPDATE config SET config_value = '${max}' WHERE config_key = 'max_users'" > /dev/null
  check "allowedAccounts empty again: off, every account gets in"
}

# helm uninstall, then helm install with the same release name and values (docs/upgrading.md#helm):
# the Secret (helm.sh/resource-policy: keep) and the PVCs (the databases', the backups') are
# still there, the new install takes them as they are, and alice's Sync data of the client
# flow is read back
reinstall() {
  local values secret_before pvcs_before
  values=$(mktemp)
  helm get values "${REL}" -o yaml > "${values}" || fail "helm get values ${REL}"
  secret_before=$(kubectl get secret "${SECRET}" -o json | jq -cS '[.metadata.uid, .data]')
  pvcs_before=$(kubectl get pvc -o json | jq -c '[.items[] | [.metadata.name, .metadata.uid]] | sort')
  helm uninstall "${REL}" --wait --timeout 5m || fail "helm uninstall failed"
  kubectl wait --for=delete pod -l "app.kubernetes.io/instance=${REL}" --timeout=5m > /dev/null 2>&1 || fail "the pods of ${REL} still there after helm uninstall"
  [[ "$(kubectl get secret "${SECRET}" -o json 2> /dev/null | jq -cS '[.metadata.uid, .data]')" == "${secret_before}" ]] \
    || fail "helm uninstall did not keep the Secret ${SECRET} as it was"
  [[ "$(kubectl get pvc -o json | jq -c '[.items[] | [.metadata.name, .metadata.uid]] | sort')" == "${pvcs_before}" ]] \
    || fail "helm uninstall did not keep the PVCs: $(kubectl get pvc -o name | paste -sd' ' -), before ${pvcs_before}"
  check "helm uninstall: the Secret ${SECRET} and the PVCs kept ($(jq -r 'map(.[0]) | join(" ")' <<< "${pvcs_before}"))"
  helm install "${REL}" "${CHART_DIR}" -f "${values}" --wait --timeout 10m || fail "helm install again (same release name) did not get Ready"
  rm -f "${values}"
  [[ "$(kubectl get secret "${SECRET}" -o json | jq -cS '[.metadata.uid, .data]')" == "${secret_before}" ]] \
    || fail "helm install again changed the Secret ${SECRET}"
  [[ "$(kubectl get pvc -o json | jq -c '[.items[] | [.metadata.name, .metadata.uid]] | sort')" == "${pvcs_before}" ]] \
    || fail "helm install again did not reuse the PVCs: $(kubectl get pvc -o name | paste -sd' ' -)"
  check "helm install again (same release name): the same Secret and PVCs"
  # (alice's 5 bookmarks of flow-2, read by a second device)
  client_flow flow-3 "-k second_device" || fail "the Sync data not there after helm uninstall and install"
  check "alice's Sync data read back after helm uninstall and install"
}

# the admin UI on (signed in with the Secret's ADMIN_PASSWORD, the overview shows the Sync
# server and alice of the client flow), then off: the Sync server Ready both ways, with
# SYNC_STATSD_HOST only while the admin UI's Service exists
admin_toggle() {
  # (your own server: ADMIN_METRICS_TOKEN is in your Secret; the admin UI's Ingress too)
  local admin_args=()
  [[ -z "${EXTERNAL}" ]] || admin_args=(--set admin.ingress.enabled=true --set admin.ingress.className=none --set admin.ingress.host=admin.example.test)
  helm upgrade "${REL}" "${CHART_DIR}" --reuse-values --set admin.enabled=true --set admin.metricsToken=e2e-token \
    --set image.adminTag="${ADMIN_TAG}" "${admin_args[@]}" --wait --timeout 10m || fail "helm upgrade with the admin UI did not get Ready"
  check "admin UI on: Ready"
  # PodSecurity restricted (a dry run of the label: the API server names the pods it would
  # refuse): the admin UI's pod meets it, the others need baseline (docs/install/helm.md#requirements)
  local restricted
  restricted=$(kubectl label --dry-run=server --overwrite ns default pod-security.kubernetes.io/enforce=restricted 2>&1 | grep '^Warning: ' || true)
  echo "${restricted}" | sed -E 's/^/  restricted: /; s/(.{400}).*/\1.../'
  ! grep -qE "^Warning: ${FULL}-admin-[a-z0-9]+-[a-z0-9]+[ :]" <<< "${restricted}" || fail "the admin UI's pod violates PodSecurity restricted: ${restricted}"
  check "PodSecurity restricted: the admin UI's pod meets it (the other pods: baseline, as above)"
  if [[ -n "${EXTERNAL}" ]]; then
    ingress_is "${FULL}-admin" none admin.example.test "${FULL}-admin" 8080
    check "Ingress ${FULL}-admin (class none): admin.example.test/ to ${FULL}-admin:8080"
    # its tables in database.admin.name, as database.admin.user
    local events
    if [[ "${BACKEND}" == mysql ]]; then
      events=$(kubectl exec extdb-0 -- env MYSQL_PWD="$(secret ADMIN_DB_PASSWORD)" mysql -h 127.0.0.1 --protocol=tcp -N -u "${EXT_ADMIN_USER}" "${EXT_ADMIN_DB}" \
        -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '${EXT_ADMIN_DB}' AND table_name = 'ffs_events'") || true
    else
      events=$(kubectl exec extdb-0 -- env PGPASSWORD="$(secret ADMIN_DB_PASSWORD)" psql -X -tA -h 127.0.0.1 -U "${EXT_ADMIN_USER}" -d "${EXT_ADMIN_DB}" \
        -c "SELECT COUNT(*) FROM pg_tables WHERE tablename = 'ffs_events' AND tableowner = '${EXT_ADMIN_USER}'") || true
    fi
    [[ "${events}" == 1 ]] || fail "no ffs_events of ${EXT_ADMIN_USER} in ${EXT_ADMIN_DB}: ${events}"
    check "the admin UI keeps its tables in ${EXT_ADMIN_DB} as ${EXT_ADMIN_USER}"
  fi
  sync_ready "${FULL}-admin"
  check "syncstorage Ready with SYNC_STATSD_HOST=${FULL}-admin"

  kubectl port-forward "svc/${FULL}-admin" 18090:8080 > /dev/null 2>&1 &
  local pf=$! jar page deadline
  jar=$(mktemp)
  deadline=$(( $(date +%s) + 60 ))
  until curl -sf -o /dev/null http://localhost:18090/healthz; do
    [[ $(date +%s) -lt ${deadline} ]] || { kill "${pf}"; fail "port-forward to the admin UI does not answer"; }
    sleep 2
  done
  # a session cookie (Secure: curl keeps it for http://localhost), as test_admin_sync.py signs in
  page=$(curl -s -L -c "${jar}" -b "${jar}" --data-urlencode "password=$(secret ADMIN_PASSWORD)" http://localhost:18090/login)
  if ! grep -q 'Sign out' <<< "${page}"; then
    kill "${pf}"; fail "sign-in with the Secret's ADMIN_PASSWORD refused: $(head -c 500 <<< "${page}")"
  fi
  check "signed in to the admin UI with the Secret's ADMIN_PASSWORD"
  # a backup now, the command of the overview's help; restored as docs/backups.md#restore says
  backup_restore
  # the first health check runs at the start, the version once the Sync server answered
  deadline=$(( $(date +%s) + 180 ))
  while :; do
    page=$(curl -s -b "${jar}" http://localhost:18090/)
    if grep -qE '<td>Sync server</td><td><span class="ok">up</span>.*?</td><td>[0-9]+\.[0-9]+\.[0-9]+' <<< "${page}" \
      && grep -q 'href="/users/alice"' <<< "${page}" && grep -q 'id="sync-users">1<' <<< "${page}"; then
      break
    fi
    if [[ $(date +%s) -ge ${deadline} ]]; then
      kill "${pf}"
      # (the published images before APP_BUILD_REVISION 2 say TBD: REPOSITORY=ghcr.io/porelli/firefox-sync-dev)
      fail "overview without the Sync server's version or alice: $(grep -oE '<td>Sync server</td>.{0,200}' <<< "${page}")"
    fi
    sleep 5
  done
  check "overview: the Sync server up with its version, alice's account"
  # the commands of the Helm chart there
  # (a new Job name for each run; + is &#43; in the page)
  grep -qF "create job --from=cronjob/${FULL}-backup backup-now-\$(date &#43;%s)" <<< "${page}" || { kill "${pf}"; fail "overview: no kubectl backup command"; }
  ! grep -q 'docker compose' <<< "${page}" || { kill "${pf}"; fail "overview: docker compose commands"; }
  check "overview: kubectl commands, no docker compose"
  # the run of backup-now on the Backups card (the admin UI reads ffs_backups, backup.sh
  # writes it), within a minute
  deadline=$(( $(date +%s) + 120 ))
  until grep -qE '<p class="hint" data-scope="sync">Last backup of the Sync databases: [^<]+, [0-9.]+ [KMG]?B, <span class="ok">ok</span>' <<< "${page}"; do
    if [[ $(date +%s) -ge ${deadline} ]]; then
      kill "${pf}"; fail "the Backups card does not show the run: $(grep -oE 'id="backups">.{0,300}' <<< "${page}")"
    fi
    sleep 5
    page=$(curl -s -b "${jar}" http://localhost:18090/)
  done
  grep -q 'id="backup-what">Every night at 03:00 UTC' <<< "${page}" || { kill "${pf}"; fail "the Backups card without BACKUP_TIME 03:00"; }
  check "overview: the Backups card shows the run of backup-now, every night at 03:00 UTC"
  [[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer e2e-token' http://localhost:18090/metrics)" == 200 ]] \
    || { kill "${pf}"; fail "/metrics refuses admin.metricsToken"; }
  check "/metrics with admin.metricsToken"
  kill "${pf}" 2> /dev/null || true
  rm -f "${jar}"

  # an upgrade that changes nothing keeps the admin pod (the Secret read back, the same checksum)
  local before
  before=$(kubectl get pods -l "app.kubernetes.io/instance=${REL},app.kubernetes.io/component=admin" -o jsonpath='{.items[0].metadata.name}')
  helm upgrade "${REL}" "${CHART_DIR}" --reuse-values --wait --timeout 10m || fail "helm upgrade without changes failed"
  [[ "$(kubectl get pods -l "app.kubernetes.io/instance=${REL},app.kubernetes.io/component=admin" -o jsonpath='{.items[*].metadata.name}')" == "${before}" ]] \
    || fail "an upgrade without changes replaced the admin pod"
  check "an upgrade without changes keeps the admin pod"
  # the token taken out of the values: out of the Secret (no lookup keeps it), a new admin pod
  # (existingSecret: the values' are not read)
  [[ -n "${EXTERNAL}" ]] || admin_token_off
  helm upgrade "${REL}" "${CHART_DIR}" --reuse-values --set admin.enabled=false --wait --timeout 10m \
    || fail "helm upgrade without the admin UI did not get Ready"
  ! kubectl get svc "${FULL}-admin" > /dev/null 2>&1 || fail "the admin Service is still there"
  if [[ -n "${EXTERNAL}" ]]; then
    ! kubectl get ingress "${FULL}-admin" > /dev/null 2>&1 || fail "the admin UI's Ingress is still there"
    ingress_is "${FULL}-syncstorage" none sync.example.test "${FULL}-syncstorage" 8000
  fi
  sync_ready ""
  check "admin UI off: syncstorage Ready again, no SYNC_STATSD_HOST${EXTERNAL:+, no admin Ingress}"
}

admin_token_off() {
  helm upgrade "${REL}" "${CHART_DIR}" --reuse-values --set admin.metricsToken= --wait --timeout 10m \
    || fail "helm upgrade without admin.metricsToken did not get Ready"
  [[ -z "$(secret ADMIN_METRICS_TOKEN)" ]] || fail "admin.metricsToken emptied, still in the Secret"
  kubectl wait --for=delete "pod/${before}" --timeout=2m > /dev/null 2>&1 || fail "the admin pod ${before} kept running with the old secret"
  check "admin.metricsToken emptied: empty in the Secret, a new admin pod"
}

# backup_restore: a run of the backup CronJob now (kubectl create job --from=cronjob/...,
# as the admin UI says), then its dumps restored the way docs/backups.md#restore says on a new
# host: into empty database servers like the chart's (pods of the StatefulSets' spec, with
# empty volumes), by pods of the backup's own spec (its variables, its volume: compose's
# `docker compose run --rm --no-deps --entrypoint sh backup -c '...'`), as the stack's users,
# with the commands of docs/backups.md#restore. The same users and Sync items there as in the chart's databases
backup_restore() {
  kubectl create job --from="cronjob/${FULL}-backup" backup-now > /dev/null || fail "kubectl create job --from=cronjob/${FULL}-backup failed"
  wait_job backup-now 300 || fail "the backup-now Job did not complete"
  kubectl logs job/backup-now | grep -q "^backup sync: ok: /backups/sync/" || fail "backup-now: no 'ok' in its log"
  check "kubectl create job --from=cronjob/${FULL}-backup backup-now: complete"

  # 2. the run
  local run
  run=$(backup_pod restore-ls '["ls", "/backups/sync"]' | tail -1)
  [[ "${run}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || fail "no run in the backups volume: ${run}"
  check "a run in the backups volume: ${run}"

  # 1. empty database servers, as on a new host (the chart's spec, empty volumes; your own:
  # one more like it, with the SQL of docs/databases.md#create-the-databases-and-users)
  local servers ts st ts_ip st_ip
  if [[ -n "${EXTERNAL}" ]]; then
    servers=
    extdb_server scratchdb
  elif [[ "${BACKEND}" == postgres ]]; then
    servers="${FULL}-postgres"
  else
    servers="${FULL}-tokenserver-db ${FULL}-storage-db"
  fi
  for s in ${servers}; do
    kubectl get sts "${s}" -o json | jq --arg n "scratch-${s#"${FULL}-"}" '.spec.template.spec as $s | {apiVersion: "v1", kind: "Pod",
      metadata: {name: $n, labels: {"ffs-e2e": "scratch"}}, spec: ($s + {volumes: (($s.volumes // []) + [{name: "data", emptyDir: {}}])})}' \
      | kubectl apply -f - > /dev/null || fail "scratch server of ${s} not created"
  done
  [[ -z "${servers}" ]] || kubectl wait --for=condition=Ready pod -l ffs-e2e=scratch --timeout=5m > /dev/null || fail "the scratch database servers not Ready"
  if [[ -n "${EXTERNAL}" ]]; then
    ts=scratchdb-0 st=scratchdb-0
  elif [[ "${BACKEND}" == postgres ]]; then
    ts=scratch-postgres st=scratch-postgres
  else
    ts=scratch-tokenserver-db st=scratch-storage-db
  fi
  ts_ip=$(kubectl get pod "${ts}" -o jsonpath='{.status.podIP}')
  st_ip=$(kubectl get pod "${st}" -o jsonpath='{.status.podIP}')
  local like="the chart's"
  [[ -z "${EXTERNAL}" ]] || like="your own, with its SQL"
  check "empty database servers like ${like}: ${ts} ${st}"

  # 4. the tokenserver (PostgreSQL: the one database), with the commands of docs/backups.md#restore
  local restore
  restore=$(admin_md_restore "$([[ "${BACKEND}" == postgres ]] && echo 2 || echo 1)")
  [[ -n "${restore}" ]] || fail "no restore command of step 4 in docs/backups.md#restore"
  [[ "${BACKEND}" == mysql ]] && restore=$(sed -e 's/^\( *\)mariadb /\1mysql /' -e 's/^\( *MYSQL_PWD="[^"]*" \)mariadb /\1mysql /' <<< "${restore}")
  if [[ "${BACKEND}" == postgres && -z "${EXTERNAL}" ]]; then
    # into the empty database as the Sync server's role, which sync_role_init creates first:
    # here the sync-role init container of the Sync server's pod, on the new server
    one_shot restore-sync-role "$(kubectl get deploy "${FULL}-syncstorage" -o json | jq --arg ip "${ts_ip}" '{containers: [.spec.template.spec.initContainers[]
      | select(.name == "sync-role") | .env |= map(if .name == "POSTGRES_SERVER" then .value = $ip else . end)]}')" > /dev/null \
      || fail "sync-role on the new server failed"
    check "the Sync server's role on the new server (sync-role)"
  fi
  # a run that is not there (pruned, mistyped) fails, and loads nothing
  if backup_pod restore-missing "$(jq -nc --arg c "${restore//20261013T030000Z/20000101T000000Z}" '["sh", "-c", $c]')" \
    "TOKENSERVER_DB_HOST=${ts_ip}" > /dev/null; then
    fail "the restore of a run that is not there succeeded"
  fi
  ! count "${ts}" users > /dev/null 2>&1 || fail "the restore of a run that is not there loaded a users table"
  check "the restore of a run that is not there fails, loads nothing"
  backup_pod restore-tokenserver "$(jq -nc --arg c "${restore//20261013T030000Z/${run}}" '["sh", "-c", $c]')" "TOKENSERVER_DB_HOST=${ts_ip}" \
    || fail "the restore of the tokenserver (step 4) failed"
  check "the tokenserver restored as its user (docs/backups.md#restore step 4)"
  # 6. the storage, "as in step 4 with $STORAGE_DB_NAME..." (PostgreSQL: in the one dump)
  if [[ "${BACKEND}" != postgres ]]; then
    backup_pod restore-storage "$(jq -nc --arg c "$(sed 's/TOKENSERVER_DB_/STORAGE_DB_/g' <<< "${restore//20261013T030000Z/${run}}")" '["sh", "-c", $c]')" \
      "STORAGE_DB_HOST=${st_ip}" || fail "the restore of the storage (step 6) failed"
    check "the storage restored as its user (docs/backups.md#restore step 6)"
  fi

  local bso=bso users_now items_now
  [[ "${BACKEND}" == postgres ]] && bso=bsos
  if [[ -n "${EXTERNAL}" ]]; then
    users_now=$(count extdb-0 users) items_now=$(count extdb-0 "${bso}")
  elif [[ "${BACKEND}" == postgres ]]; then
    users_now=$(count "${FULL}-postgres-0" users) items_now=$(count "${FULL}-postgres-0" "${bso}")
  else
    users_now=$(count "${FULL}-tokenserver-db-0" users) items_now=$(count "${FULL}-storage-db-0" "${bso}")
  fi
  [[ "${users_now}" =~ ^[1-9][0-9]*$ && "${items_now}" =~ ^[1-9][0-9]*$ ]] || fail "no users or Sync items to back up: ${users_now} ${items_now}"
  [[ "$(count "${ts}" users)" == "${users_now}" ]] || fail "users: $(count "${ts}" users) restored, ${users_now} in the chart's database"
  [[ "$(count "${st}" "${bso}")" == "${items_now}" ]] || fail "${bso}: $(count "${st}" "${bso}") restored, ${items_now} in the chart's database"
  check "the same rows of users (${users_now}) and ${bso} (${items_now}) restored"
  kubectl delete pod -l ffs-e2e --wait=false > /dev/null
  [[ -z "${EXTERNAL}" ]] || kubectl delete sts,svc scratchdb --wait=false > /dev/null
}

# admin_md_restore <n>: the n-th command of docs/backups.md#restore run in the backup container that
# restores $TOKENSERVER_DB_NAME (1: MariaDB, 2: PostgreSQL), as it is there
admin_md_restore() {
  awk -v n="$1" '
    /--entrypoint sh backup -c '"'"'$/ { on = 1; b = ""; next }
    on {
      line = $0; last = (line ~ /'"'"'$/)
      if (last) sub(/'"'"'$/, "", line)
      b = b line "\n"
      if (last) { on = 0; if (b ~ /\$TOKENSERVER_DB_NAME\.sql\.gz/ && ++i == n) printf "%s", b }
    }' "${REPO_ROOT}/docs/backups.md"
}

# backup_pod <name> <command, JSON> [VAR=value...]: a pod of the backup CronJob's spec (its
# variables from the Secret, its volume) running the command, with these variables changed;
# its output, and whether it succeeded
backup_pod() {
  local name=$1 command=$2 spec
  shift 2
  spec=$(kubectl get cronjob "${FULL}-backup" -o json | jq --argjson c "${command}" --args '.spec.jobTemplate.spec.template.spec
    | .containers[0] |= (.command = $c | del(.args)
      | reduce ($ARGS.positional[] | capture("^(?<k>[^=]+)=(?<v>.*)$")) as $e (.; .env |= map(if .name == $e.k then .value = $e.v else . end)))' "$@") || return 1
  one_shot "${name}" "${spec}"
}

# one_shot <name> <pod spec, JSON>: a pod run once; its logs, and whether it succeeded
one_shot() {
  jq --arg n "$1" '{apiVersion: "v1", kind: "Pod", metadata: {name: $n, labels: {"ffs-e2e": "one-shot"}}, spec: (. + {restartPolicy: "Never"})}' <<< "$2" \
    | kubectl apply -f - > /dev/null || return 1
  local deadline=$(( $(date +%s) + 300 )) phase=
  while [[ $(date +%s) -lt ${deadline} ]]; do
    phase=$(kubectl get pod "$1" -o jsonpath='{.status.phase}')
    [[ "${phase}" == Succeeded || "${phase}" == Failed ]] && break
    sleep 2
  done
  kubectl logs "$1" 2> /dev/null
  [[ "${phase}" == Succeeded ]]
}

# count <pod> <table>: its rows, in the pod's database server, as the stack's user
count() {
  if [[ -n "${EXTERNAL}" ]]; then
    case "${BACKEND}" in
      mysql)
        if [[ $2 == users ]]; then
          kubectl exec "$1" -- env MYSQL_PWD="$(secret TOKENSERVER_DB_PASSWORD)" mysql -h 127.0.0.1 --protocol=tcp -N -u "${EXT_TS_USER}" "${EXT_TS_DB}" -e "SELECT COUNT(*) FROM $2"
        else
          kubectl exec "$1" -- env MYSQL_PWD="$(secret STORAGE_DB_PASSWORD)" mysql -h 127.0.0.1 --protocol=tcp -N -u "${EXT_ST_USER}" "${EXT_ST_DB}" -e "SELECT COUNT(*) FROM $2"
        fi ;;
      postgres) kubectl exec "$1" -- env PGPASSWORD="$(secret POSTGRES_PASSWORD)" \
        psql -X -tA -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "${EXT_PG_USER}" -d "${EXT_PG_DB}" -c "SELECT COUNT(*) FROM $2" ;;
    esac
    return
  fi
  case "${BACKEND}" in
    mariadb) kubectl exec "$1" -c db -- sh -c 'MYSQL_PWD="${MARIADB_PASSWORD}" mariadb -N -u"${MARIADB_USER}" "${MARIADB_DATABASE}" -e "SELECT COUNT(*) FROM $1"' sh "$2" ;;
    mysql) kubectl exec "$1" -c db -- sh -c 'MYSQL_PWD="${MYSQL_PASSWORD}" mysql -N -u"${MYSQL_USER}" "${MYSQL_DATABASE}" -e "SELECT COUNT(*) FROM $1" 2> /dev/null' sh "$2" ;;
    postgres) kubectl exec "$1" -c db -- env PGPASSWORD="$(secret POSTGRES_SYNC_PASSWORD)" \
      psql -X -tA -v ON_ERROR_STOP=1 -h 127.0.0.1 -U syncserver_app -d syncserver -c "SELECT COUNT(*) FROM $2" ;;
  esac
}

# sync_ready <statsd host, "" for none>: the one syncstorage pod Ready, SYNC_STATSD_HOST as given
sync_ready() {
  kubectl rollout status "deploy/${FULL}-syncstorage" --timeout=10m || fail "syncstorage not rolled out"
  wait_pod_status Running 300 || fail "syncstorage not a single Running pod"
  kubectl wait --for=condition=Ready pod -l "${POD_SELECTOR}" --timeout=5m || fail "syncstorage not Ready"
  local host
  host=$(kubectl get pods -l "${POD_SELECTOR}" -o json | jq -r '.items[0].spec.containers[]
    | select(.name == "syncstorage") | .env[] | select(.name == "SYNC_STATSD_HOST") | .value')
  [[ "${host}" == "$1" ]] || fail "syncstorage's SYNC_STATSD_HOST is '${host}', expected '$1'"
}

# sql <statement>: on the tokenserver database, as the stack's user, in the database pod
sql() {
  if [[ -n "${EXTERNAL}" ]]; then
    case "${BACKEND}" in
      mysql) kubectl exec extdb-0 -- env MYSQL_PWD="$(secret TOKENSERVER_DB_PASSWORD)" mysql -h 127.0.0.1 --protocol=tcp -u "${EXT_TS_USER}" "${EXT_TS_DB}" -e "$1" "${@:2}" ;;
      postgres) kubectl exec extdb-0 -- env PGPASSWORD="$(secret POSTGRES_PASSWORD)" \
        psql -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "${EXT_PG_USER}" -d "${EXT_PG_DB}" -c "$1" "${@:2}" ;;
    esac
    return
  fi
  case "${BACKEND}" in
    mariadb) kubectl exec "${FULL}-tokenserver-db-0" -- sh -c 'q=$1; shift; MYSQL_PWD="${MARIADB_PASSWORD}" mariadb -u"${MARIADB_USER}" "${MARIADB_DATABASE}" -e "${q}" "$@"' sh "$1" "${@:2}" ;;
    mysql) kubectl exec "${FULL}-tokenserver-db-0" -- sh -c 'q=$1; shift; MYSQL_PWD="${MYSQL_PASSWORD}" mysql -u"${MYSQL_USER}" "${MYSQL_DATABASE}" -e "${q}" "$@"' sh "$1" "${@:2}" ;;
    # as the Sync server's own role: no superuser session on the tables it owns
    postgres) kubectl exec "${FULL}-postgres-0" -- env PGPASSWORD="$(secret POSTGRES_SYNC_PASSWORD)" \
      psql -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -U syncserver_app -d syncserver -c "$1" "${@:2}" ;;
  esac
}

secret() { kubectl get secret "${SECRET}" -o jsonpath="{.data.$1}" | base64 -d; }

# who the Sync server is on its databases, and the admin UI's users that the databases and
# the init container create (db/mysql/admin-user.sh, db/postgres/init)
database_users() {
  local pod_ip env
  pod_ip=$(kubectl get pods -l "${POD_SELECTOR}" -o jsonpath='{.items[0].status.podIP}')
  env=$(kubectl get deploy "${FULL}-syncstorage" -o json)
  if [[ -n "${EXTERNAL}" ]]; then
    external_users "${pod_ip}"
    return
  fi
  if [[ "${BACKEND}" == postgres ]]; then
    for c in migrate syncstorage; do
      names=$(echo "${env}" | jq -r --arg c "${c}" '[.spec.template.spec.initContainers[], .spec.template.spec.containers[]]
        | map(select(.name == $c))[0].env[] | .name, (.valueFrom.secretKeyRef.key // empty)')
      ! echo "${names}" | grep -qx POSTGRES_PASSWORD || fail "${c} gets POSTGRES_PASSWORD"
      urls=$(echo "${env}" | jq -r --arg c "${c}" '[.spec.template.spec.initContainers[], .spec.template.spec.containers[]]
        | map(select(.name == $c))[0].env[] | select(.name | endswith("__DATABASE_URL")) | .value')
      ! echo "${urls}" | grep -qv '^postgres://syncserver_app:' || fail "${c} does not connect as syncserver_app: ${urls}"
    done
    check "migrate and syncstorage: no POSTGRES_PASSWORD, URLs as syncserver_app"
    users=$(kubectl exec "${FULL}-postgres-0" -- sh -c 'psql -X -tA -U "${POSTGRES_USER}" -d postgres -c "$1"' sh \
      "SELECT string_agg(DISTINCT usename, ',') FROM pg_stat_activity WHERE client_addr = '${pod_ip}'")
    [[ "${users}" == syncserver_app ]] || fail "the Sync server connects as '${users}', not syncserver_app"
    super=$(kubectl exec "${FULL}-postgres-0" -- sh -c 'psql -X -tA -U "${POSTGRES_USER}" -d postgres -c "$1"' sh \
      "SELECT rolsuper FROM pg_roles WHERE rolname = 'syncserver_app'")
    [[ "${super}" == f ]] || fail "syncserver_app is a superuser (${super})"
    owners=$(sql "SELECT string_agg(DISTINCT tableowner, ',') FROM pg_tables WHERE schemaname = 'public'" -tA)
    [[ "${owners}" == syncserver_app ]] || fail "the Sync tables are owned by '${owners}'"
    check "the Sync server connects as syncserver_app (no superuser), which owns the Sync tables"
    kubectl exec "${FULL}-postgres-0" -- env PGPASSWORD="$(secret ADMIN_DB_PASSWORD)" \
      psql -X -tA -h 127.0.0.1 -U ffs_admin_ui -d ffs_admin -c 'SELECT 1' > /dev/null || fail "ffs_admin_ui cannot reach ffs_admin"
    check "the admin UI's user ffs_admin_ui reaches ffs_admin"
  else
    local client=mariadb
    [[ "${BACKEND}" == mysql ]] && client=mysql
    for db in tokenserver storage; do
      # (the password on the input, not on kubectl's command line)
      kubectl exec -i "${FULL}-${db}-db-0" -- sh -c 'MYSQL_PWD=$(cat) "$0" -h 127.0.0.1 -u ffs_admin_sync -e "SELECT 1"' "${client}" \
        <<< "$(secret ADMIN_DB_PASSWORD)" > /dev/null || fail "ffs_admin_sync cannot log in to ${db}-db"
    done
    kubectl exec -i "${FULL}-tokenserver-db-0" -- sh -c 'MYSQL_PWD=$(cat) "$0" -h 127.0.0.1 -u ffs_admin_ui ffs_admin -e "SELECT 1"' "${client}" \
      <<< "$(secret ADMIN_DB_PASSWORD)" > /dev/null || fail "ffs_admin_ui cannot reach ffs_admin"
    check "admin-user.sh created ffs_admin_ui (ffs_admin) and ffs_admin_sync (both databases)"
  fi
}

# EXTERNAL_DB=1: who the Sync server is on your own server (the users of its SQL, no
# administrator, no superuser), and the admin UI's users reaching only what docs/reference/database-users.md#the-admin-uis-own-database says
external_users() {
  local pod_ip=$1 users
  if [[ "${BACKEND}" == mysql ]]; then
    users=$(extdb_admin -e "SELECT GROUP_CONCAT(DISTINCT user ORDER BY user) FROM information_schema.processlist WHERE host LIKE '${pod_ip}:%'" < /dev/null)
    [[ "${users}" == "$(printf '%s\n' "${EXT_ST_USER}" "${EXT_TS_USER}" | sort | paste -sd, -)" ]] \
      || fail "the Sync server connects to your server as '${users}', not ${EXT_TS_USER} and ${EXT_ST_USER}"
    [[ "$(sql 'SELECT COUNT(*) FROM users' -N)" =~ ^[0-9]+$ ]] || fail "no users table in ${EXT_TS_DB}"
    check "the Sync server connects as ${EXT_TS_USER} and ${EXT_ST_USER}, its tables in ${EXT_TS_DB}"
    kubectl exec extdb-0 -- env MYSQL_PWD="$(secret ADMIN_DB_PASSWORD)" mysql -h 127.0.0.1 --protocol=tcp -u "${EXT_ADMIN_USER}" "${EXT_ADMIN_DB}" \
      -e 'SELECT 1' > /dev/null || fail "${EXT_ADMIN_USER} cannot reach ${EXT_ADMIN_DB}"
    kubectl exec extdb-0 -- env MYSQL_PWD="$(secret ADMIN_DB_PASSWORD)" mysql -h 127.0.0.1 --protocol=tcp -u "${EXT_ADMIN_SYNC}" "${EXT_TS_DB}" \
      -e 'SELECT COUNT(*) FROM users' > /dev/null || fail "${EXT_ADMIN_SYNC} cannot read ${EXT_TS_DB}"
    ! sql "SHOW TABLES FROM ${EXT_ADMIN_DB}" > /dev/null 2>&1 || fail "${EXT_TS_USER} reaches ${EXT_ADMIN_DB}"
  else
    users=$(extdb_admin -c "SELECT string_agg(DISTINCT usename, ',') FROM pg_stat_activity WHERE client_addr = '${pod_ip}'" < /dev/null)
    [[ "${users}" == "${EXT_PG_USER}" ]] || fail "the Sync server connects to your server as '${users}', not ${EXT_PG_USER}"
    [[ "$(extdb_admin -c "SELECT rolsuper OR rolcreaterole OR rolcreatedb FROM pg_roles WHERE rolname = '${EXT_PG_USER}'" < /dev/null)" == f ]] \
      || fail "${EXT_PG_USER} is a superuser, or creates roles or databases"
    [[ "$(sql "SELECT string_agg(DISTINCT tableowner, ',') FROM pg_tables WHERE schemaname = 'public'" -tA)" == "${EXT_PG_USER}" ]] \
      || fail "the Sync tables are not ${EXT_PG_USER}'s"
    check "the Sync server connects as ${EXT_PG_USER} (no superuser, CREATEROLE or CREATEDB), the owner of its tables"
    kubectl exec extdb-0 -- env PGPASSWORD="$(secret ADMIN_DB_PASSWORD)" psql -X -tA -h 127.0.0.1 -U "${EXT_ADMIN_USER}" -d "${EXT_ADMIN_DB}" \
      -c 'SELECT 1' > /dev/null || fail "${EXT_ADMIN_USER} cannot reach ${EXT_ADMIN_DB}"
    # the reader of the Sync data, given its grants by the init container
    kubectl exec extdb-0 -- env PGPASSWORD="$(secret ADMIN_DB_PASSWORD)" psql -X -tA -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "${EXT_ADMIN_SYNC}" -d "${EXT_PG_DB}" \
      -c 'SELECT COUNT(*) FROM users' > /dev/null || fail "${EXT_ADMIN_SYNC} cannot read the Sync tables"
    ! kubectl exec extdb-0 -- env PGPASSWORD="$(secret POSTGRES_PASSWORD)" psql -X -tA -h 127.0.0.1 -U "${EXT_PG_USER}" -d "${EXT_ADMIN_DB}" \
      -c 'SELECT 1' > /dev/null 2>&1 || fail "${EXT_PG_USER} reaches ${EXT_ADMIN_DB}"
  fi
  check "the admin UI's ${EXT_ADMIN_USER} reaches ${EXT_ADMIN_DB}, ${EXT_ADMIN_SYNC} reads the Sync data, the Sync server's user not ${EXT_ADMIN_DB}"
}

# EXTERNAL_DB=1: SQL as the administrator of your own server (MySQL: root; PostgreSQL: the
# image's superuser, only to create the administrator of extdb_server), on stdin; in the pod
# EXTDB_POD (extdb-0)
extdb_admin() {
  local pod=${EXTDB_POD:-extdb-0}
  if [[ "${BACKEND}" == mysql ]]; then
    kubectl exec -i "${pod}" -- sh -c 'MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" exec mysql -h 127.0.0.1 --protocol=tcp -uroot -sN "$@"' sh "$@"
  else
    kubectl exec -i "${pod}" -- sh -c 'PGPASSWORD="${POSTGRES_PASSWORD}" exec psql -X -h 127.0.0.1 -U postgres -v ON_ERROR_STOP=1 -tA "$@"' sh "$@"
  fi
}

# EXTERNAL_DB=1: a database server the chart does not manage, mirroring tests/e2e.sh's
# start_extdb (a plain StatefulSet and Service extdb, a test fixture: MySQL 8 with binary
# logging, or PostgreSQL 18 administered by a role that is no superuser), the databases and
# users of docs/databases.md#create-the-databases-and-users (db/<engine>/setup/sync with its placeholders filled in) under names
# other than the defaults, and the Secret of existingSecret with the same passwords
start_extdb() {
  EXT_ADMIN_DB=own_admin EXT_ADMIN_USER=own_admin_ui EXT_ADMIN_SYNC=own_admin_sync
  EXT_TS_DB=own_tokenserver EXT_TS_USER=own_ts EXT_ST_DB=own_storage EXT_ST_USER=own_st
  EXT_PG_DB=own_sync EXT_PG_USER=own_sync_owner
  local ts st pg admin
  ts=$(rnd) st=$(rnd) pg=$(rnd) admin=$(rnd)
  EXT_SQL=$(mktemp)
  if [[ "${BACKEND}" == mysql ]]; then
    sed -e "s|@SYNC_TOKENSERVER_DATABASE@|${EXT_TS_DB}|g" -e "s|@SYNC_TOKENSERVER_USER@|${EXT_TS_USER}|g" -e "s|@SYNC_TOKENSERVER_PASSWORD@|${ts}|g" \
      -e "s|@SYNC_STORAGE_DATABASE@|${EXT_ST_DB}|g" -e "s|@SYNC_STORAGE_USER@|${EXT_ST_USER}|g" -e "s|@SYNC_STORAGE_PASSWORD@|${st}|g" \
      -e "s|@ADMIN_DATABASE@|${EXT_ADMIN_DB}|g" -e "s|@ADMIN_USER@|${EXT_ADMIN_USER}|g" -e "s|@ADMIN_SYNC_USER@|${EXT_ADMIN_SYNC}|g" \
      -e "s|@ADMIN_PASSWORD@|${admin}|g" "${REPO_ROOT}"/db/mysql/setup/sync/*.sql > "${EXT_SQL}"
  else
    sed -e "s|@SYNC_POSTGRES_DATABASE@|${EXT_PG_DB}|g" -e "s|@SYNC_POSTGRES_USER@|${EXT_PG_USER}|g" -e "s|@SYNC_POSTGRES_PASSWORD@|${pg}|g" \
      -e "s|@ADMIN_DATABASE@|${EXT_ADMIN_DB}|g" -e "s|@ADMIN_USER@|${EXT_ADMIN_USER}|g" -e "s|@ADMIN_SYNC_USER@|${EXT_ADMIN_SYNC}|g" \
      -e "s|@ADMIN_PASSWORD@|${admin}|g" "${REPO_ROOT}"/db/postgres/setup/sync/*.sql > "${EXT_SQL}"
  fi
  ! grep -q '@[A-Z_]*@' "${EXT_SQL}" || fail "placeholders left in db/${BACKEND}/setup/sync: $(grep -o '@[A-Z_]*@' "${EXT_SQL}" | sort -u | paste -sd' ' -)"
  if [[ -n "${DB_BOOTSTRAP:-}" ]]; then
    # only the account of docs/databases.md#the-bootstrap-account: db-bootstrap does the rest
    EXT_BOOT=$(rnd)
    EXT_BOOT_SQL=$(mktemp)
    sed -e "s|@BOOTSTRAP_USER@|ffs_bootstrap|g" -e "s|@BOOTSTRAP_PASSWORD@|${EXT_BOOT}|g" -e "s|@SYNC_TOKENSERVER_DATABASE@|${EXT_TS_DB}|g" \
      -e "s|@SYNC_STORAGE_DATABASE@|${EXT_ST_DB}|g" -e "s|@ADMIN_DATABASE@|${EXT_ADMIN_DB}|g" -e "s|@SYNC_POSTGRES_USER@|${EXT_PG_USER}|g" \
      -e "s|@ADMIN_USER@|${EXT_ADMIN_USER}|g" -e "s|@ADMIN_SYNC_USER@|${EXT_ADMIN_SYNC}|g" -e "$([[ ${BACKEND} == mysql ]] && echo 's/^-- MySQL: //')" "${REPO_ROOT}"/db/"$([[ ${BACKEND} == postgres ]] && echo postgres || echo mysql)"/setup/sync-bootstrap/*.sql > "${EXT_BOOT_SQL}"
    extdb_server extdb "${EXT_BOOT_SQL}"
    check "your own database server (${EXTDB_IMAGE}, not the chart's) with only the bootstrap account of db/${BACKEND}/setup/sync-bootstrap"
  else
    extdb_server extdb
    check "your own database server (${EXTDB_IMAGE}, not the chart's) with the SQL of docs/databases.md#create-the-databases-and-users (db/${BACKEND}/setup/sync) run as the administrator$([[ ${BACKEND} == postgres ]] && echo ' (CREATEROLE, CREATEDB, no superuser)')"
  fi
  # your Secret: the stack's secrets and the passwords of that SQL
  local keys=(--from-literal=SYNC_MASTER_SECRET="$(rnd)" --from-literal=METRICS_HASH_SECRET="$(rnd)" --from-literal=ADMIN_PASSWORD="$(rnd)"
    --from-literal=ADMIN_DB_PASSWORD="${admin}" --from-literal=ADMIN_METRICS_TOKEN=e2e-token)
  if [[ "${BACKEND}" == mysql ]]; then
    keys+=(--from-literal=TOKENSERVER_DB_PASSWORD="${ts}" --from-literal=STORAGE_DB_PASSWORD="${st}")
  else
    keys+=(--from-literal=POSTGRES_PASSWORD="${pg}")
  fi
  [[ -z "${DB_BOOTSTRAP:-}" ]] || keys+=(--from-literal=SYNC_DB_BOOTSTRAP_PASSWORD="${EXT_BOOT}")
  kubectl create secret generic ffs-own "${keys[@]}" > /dev/null || fail "Secret ffs-own not created"
  check "Secret ffs-own with the passwords of that SQL"
}

# extdb_server <name> [sql]: a server like that (StatefulSet and Service <name>, empty), with EXT_SQL
# (or the SQL file given: as the superuser with PostgreSQL) run there as its administrator (the
# restore check makes a second one, as on a new host)
extdb_server() {
  local name=$1 sql=${2:-} image port data env args probe
  if [[ "${BACKEND}" == mysql ]]; then
    # binary logging on (MySQL's default): the trigger needs log_bin_trust_function_creators
    image=mysql:lts port=3306 data=/var/lib/mysql env=MYSQL_ROOT_PASSWORD args='["--log-bin-trust-function-creators=ON"]'
    probe='MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" mysqladmin ping -h 127.0.0.1 --protocol=tcp -uroot --silent'
  else
    image=postgres:latest port=5432 data=/var/lib/postgresql env=POSTGRES_PASSWORD args='[]'
    probe='pg_isready -h 127.0.0.1 -U postgres'
  fi
  EXTDB_IMAGE=${image}
  # (over TCP in the probe: while the image initializes, a temporary server on the socket only)
  jq -n --arg name "${name}" --arg image "${image}" --argjson port "${port}" --arg data "${data}" --arg env "${env}" --arg root "$(rnd)" \
    --argjson args "${args}" --arg probe "${probe}" '
    {apiVersion: "v1", kind: "List", items: [
      {apiVersion: "v1", kind: "Service", metadata: {name: $name},
       spec: {selector: {app: $name}, ports: [{port: $port, targetPort: $port}]}},
      {apiVersion: "apps/v1", kind: "StatefulSet", metadata: {name: $name},
       spec: {serviceName: $name, replicas: 1, selector: {matchLabels: {app: $name}},
         template: {metadata: {labels: {app: $name}}, spec: {
           containers: [{name: "db", image: $image, args: $args, env: [{name: $env, value: $root}],
             ports: [{containerPort: $port}],
             readinessProbe: {exec: {command: ["sh", "-c", $probe]}, periodSeconds: 5, timeoutSeconds: 5},
             volumeMounts: [{name: "data", mountPath: $data}]}],
           volumes: [{name: "data", emptyDir: {}}]}}}}]}' | kubectl apply -f - > /dev/null || fail "database server ${name} not created"
  kubectl rollout status "sts/${name}" --timeout=5m > /dev/null || fail "database server ${name} (${image}) not Ready"
  if [[ -n "${sql}" ]]; then
    EXTDB_POD=${name}-0 extdb_admin < "${sql}" > /dev/null || fail "${sql} refused by ${name}"
  elif [[ "${BACKEND}" == mysql ]]; then
    EXTDB_POD=${name}-0 extdb_admin < "${EXT_SQL}" > /dev/null || fail "db/mysql/setup/sync refused by ${name}"
  else
    # as a role with CREATEROLE and CREATEDB, no superuser: what managed services give
    local dbadmin
    dbadmin=$(rnd)
    EXTDB_POD=${name}-0 extdb_admin -c "CREATE ROLE dbadmin LOGIN CREATEROLE CREATEDB PASSWORD '${dbadmin}'" < /dev/null > /dev/null || fail "no administrator role on ${name}"
    kubectl exec -i "${name}-0" -- env PGPASSWORD="${dbadmin}" psql -X -h 127.0.0.1 -U dbadmin -d postgres -v ON_ERROR_STOP=1 -q < "${EXT_SQL}" > /dev/null \
      || fail "db/postgres/setup/sync refused by ${name} (as dbadmin)"
  fi
}

# client_flow <job name> [pytest args]: tests/test_client_flow.py in the syncstorage image,
# with the syncstorage container's own env (database URLs and their passwords from the Secret)
client_flow() {
  local name=$1 args=${2:-}
  local env
  env=$(kubectl get deploy "${FULL}-syncstorage" -o json | jq '.spec.template.spec.containers[]
    | select(.name == "syncstorage") | .env
    | map(select(.name != "SYNC_SERVER_URL" and .name != "SYNC_MAX_USERS"))
    + [{name: "SYNC_SERVER_URL", value: "http://'"${FULL}"'-syncstorage:8000"},
       {name: "SYNC_PUBLIC_URL", value: "'"${SYNCSTORAGE_DOMAIN}"'"},
       {name: "SYNC_MAX_USERS", value: "1"},
       {name: "PYTHONPATH", value: "/app:/app/tools"},
       {name: "PYTHONDONTWRITEBYTECODE", value: "1"}]') || return 1
  jq -n --arg name "${name}" --arg image "${SYNC_IMAGE}" --arg args "${args}" --argjson env "${env}" '{
    apiVersion: "batch/v1", kind: "Job", metadata: {name: $name},
    spec: {backoffLimit: 0, template: {spec: {restartPolicy: "Never",
      securityContext: {runAsUser: 0},
      containers: [{name: "pytest", image: $image, workingDir: "/app",
        command: ["/bin/sh", "-c", ("python3 -m pytest -q -p no:cacheprovider /tests/test_client_flow.py " + $args)],
        env: $env, volumeMounts: [{name: "tests", mountPath: "/tests", readOnly: true}]}],
      volumes: [{name: "tests", configMap: {name: "ffs-tests"}}]}}}}' | kubectl apply -f - || return 1
  wait_job "${name}" 600
}

case "${1:-}" in
  lint)
    lint
    ;;
  parity)
    shift
    parity "$@"
    ;;
  e2e)
    e2e "${2:-}"
    ;;
  *)
    echo "Usage: $0 {lint|parity [case...]|e2e <mariadb|mysql|postgres>}"
    echo "  lint                              - helm lint and template checks (parity too)"
    echo "  parity [case...]                  - the chart's env, commands and probes against compose's, the accounts' too (tests/helm_parity.py, its CASES)"
    echo "  e2e <mariadb|mysql|postgres>      - install on a kind cluster and run the client flow"
    exit 1
    ;;
esac
