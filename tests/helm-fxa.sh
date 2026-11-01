#!/bin/bash
# The chart's self-hosted Mozilla accounts (fxa.enabled), docs/accounts.md under Kubernetes.
#
#   fxa_lint    the template checks of the accounts, run by `tests/helm.sh lint`, which sources
#               this file (it uses check, fail and manifests of tests/helm/lib.sh, and CHART_DIR)
#   tests/helm-fxa.sh e2e <mysql|mariadb>
#               the chart with the accounts on a throwaway kind cluster (fxa_e2e);
#               EXTERNAL_DB=1 (mysql only): on your own server instead of the bundled one;
#               SYNC_BACKEND=postgres: the Sync server on the bundled PostgreSQL (default:
#               the accounts' backend); SKIP_BROWSER=1: without the real Firefox (test_fxa_browser.py);
#               PART=main or PART=survival: one half of it on its own cluster (CI runs the two
#               at once), see fxa_e2e; empty: both, on one cluster
#
# PARITY_BASE_CHART=<dir>: chart 0.1.0 already extracted there (charts/firefox-sync of
# PARITY_BASE, default 2512e9a), for a checkout without that commit (a copy without .git,
# a shallow clone): `git archive 2512e9a charts/firefox-sync | tar -x -C <dir>`

# the commit of chart 0.1.0 (part 1): with fxa.enabled=false the chart renders what it did.
# Not part 1's own commit (e917067) any more: 0.1.0 was never published as a stable release,
# and fxa changed it on purpose since (db-lts: mysql:lts and postgres:latest by default, the
# major guard and the db-major init container, their NOTES; the admin UI's switches, rendered
# only when set). 2512e9a is fxa as merged into helm-fxa, still version 0.1.0: the same
# render as there, nothing else
PARITY_BASE=${PARITY_BASE:-2512e9a}

fxa_lint() {
  echo "=== The self-hosted accounts (fxa.*) ==="
  local fxa="${CHART_DIR}/ci/fxa-values.yaml" out values
  fxa_render() { helm template test-release "${CHART_DIR}" "$@" 2>&1; }

  # the ci values of the accounts render, and are valid Kubernetes objects
  for values in fxa-values fxa-mariadb-values fxa-external-values; do
    out=$(fxa_render -f "${CHART_DIR}/ci/${values}.yaml") || fail "ci/${values}.yaml does not render: ${out}"
    helm lint "${CHART_DIR}" -f "${CHART_DIR}/ci/${values}.yaml" > /dev/null || fail "helm lint fails with ci/${values}.yaml"
    if command -v kubeconform > /dev/null; then
      fxa_render -f "${CHART_DIR}/ci/${values}.yaml" | kubeconform -strict -summary -kubernetes-version 1.27.0 > /dev/null \
        || fail "kubeconform -strict: invalid objects with ci/${values}.yaml"
    fi
  done
  command -v kubeconform > /dev/null || echo "(kubeconform not installed: the objects of ci/fxa-*.yaml not validated)"
  check "ci/fxa-values.yaml, fxa-mariadb-values.yaml, fxa-external-values.yaml: helm lint, kubeconform -strict"

  # what the values must have, or the render fails saying so
  fxa_refused() {
    local want=$1
    shift
    out=$(fxa_render "$@") && fail "$*: renders"
    grep -qF -- "${want}" <<< "${out}" || fail "$*: not the message '${want}': ${out}"
  }
  local default_values=(-f "${CHART_DIR}/ci/default-values.yaml")
  fxa_refused "fxa.enabled needs fxa.contentUrl, fxa.authUrl and fxa.profileUrl" "${default_values[@]}" --set fxa.enabled=true
  fxa_refused "fxa.enabled needs fxa.contentUrl, fxa.authUrl and fxa.profileUrl" -f "${fxa}" --set fxa.profileUrl=
  fxa_refused "fxa.database.bundled=false needs existingSecret" -f "${fxa}" --set fxa.database.bundled=false --set fxa.database.external.host=fxadb.example.test
  fxa_refused "fxa.database.bundled=false needs fxa.database.external.host" -f "${fxa}" --set fxa.database.bundled=false --set existingSecret=mine
  fxa_refused "fxa.database.external.port 70000 is no port" -f "${fxa}" --set fxa.database.bundled=false --set existingSecret=mine \
    --set fxa.database.external.host=fxadb.example.test --set-string fxa.database.external.port=70000
  fxa_refused "fxa.pairing.enabled needs fxa.pairing.url" -f "${fxa}" --set fxa.pairing.url=
  # (your own server: chart 0.1.0's checks first, then the accounts')
  check "fxa.enabled without its URLs, your own accounts server without its host or existingSecret (or a bad port), pairing without its URL: refused, saying so"

  # the schema: closed objects, the formats of the accounts
  for bad in fxa.database.backend=postgres fxa.maxAccounts=lots fxa.maxAccounts=initial: fxa.signups=invite fxa.contentUrl=accounts.example.test \
    fxa.authUrl=ftp://api.example.test fxa.pairing.url=https://pairing.example.test fxa.adminClientId=0123456789ABCDEF fxa.adminClientId=0123 \
    fxa.adminClientSecret=abc fxa.enable=true fxa.database.bakend=mysql fxa.database.external.hots=x fxa.ingress.tls.secretName=x \
    fxa.ingress.tls.secretNames.api=x fxa.resources.worker.requests.memory=1Mi fxa.keys.secret=x fxa.redis.tag=x fxa.pairing.urls=x \
    admin.smtp.host=b smtp.hots=b fxa.database.image.mysql= fxa.clientAddressDepth=-1; do
    out=$(fxa_render -f "${fxa}" --set "${bad}") && fail "${bad}: not refused by the schema"
    grep -qi 'schema' <<< "${out}" || fail "${bad}: refused, but not by the schema: ${out}"
  done
  out=$(fxa_render -f "${fxa}" --set admin.smtp.host=b) || true
  grep -q "smtp" <<< "${out}" || fail "admin.smtp.host: the schema's message does not name smtp: ${out}"
  for good in fxa.maxAccounts=5 fxa.maxAccounts=initial:5 fxa.maxAccounts=fixed:unlimited fxa.maxAccounts=unlimited fxa.signups=closed \
    fxa.signupAllowlist=you@example.test fxa.adminClientSecret="$(printf 'a%.0s' $(seq 1 64))" \
    fxa.pairing.url=ws://pairing.example.test fxa.clientAddressDepth=3 fxa.resources.auth.limits.memory=2Gi fxa.ingress.annotations.a=b \
    fxa.database.resources.limits.memory=1Gi fxa.extraCaCerts.configMap=ca smtp.port=465 smtp.secure=true; do
    fxa_render -f "${fxa}" --set "${good}" > /dev/null || fail "${good}: refused: $(fxa_render -f "${fxa}" --set "${good}" | tail -3)"
  done
  # (fxa.adminClientId: the client of sign-in with the accounts, with it)
  fxa_render -f "${fxa}" --set fxa.adminClientId=0123456789abcdef --set admin.fxaSignIn=true --set admin.allowed.users=@example.test \
    --set admin.ingress.host=admin.example.test > /dev/null || fail "fxa.adminClientId=0123456789abcdef with admin.fxaSignIn: refused"
  check "the schema: postgres, maxAccounts lots, signups invite, URLs without http(s):// (pairing ws(s)://), client id/secret not hex 16/64, admin.smtp and unknown keys refused"

  # names within Kubernetes' limits with the accounts too: <fullname>-fxa-db (StatefulSet, 52)
  # (your own Sync database: its StatefulSets would fail first)
  local sync_external=(--set database.bundled=false --set database.external.host=db.example.test --set existingSecret=mine)
  fxa_refused "the fxa-db StatefulSet name $(printf 'f%.0s' $(seq 1 46))-fxa-db is 53 characters, at most 52" \
    -f "${fxa}" "${sync_external[@]}" --set fullnameOverride="$(printf 'f%.0s' $(seq 1 46))"
  fxa_render -f "${fxa}" "${sync_external[@]}" --set fullnameOverride="$(printf 'f%.0s' $(seq 1 45))" > /dev/null \
    || fail "a fullname of 45 with the accounts does not render"
  # (your own accounts server: no fxa-db, the Sync server's Service and fxa-profile, 63)
  fxa_render -f "${CHART_DIR}/ci/fxa-external-values.yaml" "${sync_external[@]}" --set fullnameOverride="$(printf 'f%.0s' $(seq 1 51))" > /dev/null \
    || fail "a fullname of 51 with your own accounts server does not render"
  fxa_refused "name $(printf 'f%.0s' $(seq 1 52))-" -f "${CHART_DIR}/ci/fxa-external-values.yaml" "${sync_external[@]}" \
    --set fullnameOverride="$(printf 'f%.0s' $(seq 1 52))"
  if ! grep -qF '(list "fxa-db" "StatefulSet" 52)' "${CHART_DIR}/templates/_helpers.tpl" \
    || ! grep -qF '(list "fxa-profile" "Service" 63)' "${CHART_DIR}/templates/_helpers.tpl"; then
    fail "checkNames: no fxa-db StatefulSet 52, fxa-profile Service 63"
  fi
  check "names: fxa-db (StatefulSet 52) refuses a fullname of 46, fxa-profile (Service 63) checked"

  # every public host of its own: the four Ingresses (and the Sync server's, the admin UI's)
  # cannot share one. Case-insensitive, a trailing dot the same host, the port ignored
  fxa_refused "fxa.authUrl has the host accounts.example.test of fxa.contentUrl" -f "${fxa}" \
    --set fxa.contentUrl=https://accounts.example.test --set fxa.authUrl=https://Accounts.example.test.
  fxa_refused "fxa.profileUrl has the host api.example.test of fxa.authUrl" -f "${fxa}" --set fxa.profileUrl=https://API.example.test:8443
  fxa_refused "fxa.contentUrl has the host sync.example.test of syncDomain" -f "${fxa}" --set fxa.contentUrl=https://sync.example.test
  fxa_refused "fxa.pairing.url has the host profile.example.test of fxa.profileUrl" -f "${fxa}" --set fxa.pairing.url=wss://profile.example.test
  fxa_refused "admin.ingress.host has the host pairing.example.test of fxa.pairing.url" -f "${fxa}" --set admin.ingress.enabled=true \
    --set admin.ingress.host=pairing.example.test.
  fxa_refused "fxa.authUrl has the host sync.example.test of ingress.host" -f "${fxa}" --set syncDomain=https://ffs.example.test \
    --set ingress.enabled=true --set ingress.host=sync.example.test --set fxa.authUrl=https://sync.example.test
  # (pairing off: its URL not used, not checked; the Sync server's Ingress on syncDomain's host)
  fxa_render -f "${fxa}" --set fxa.pairing.enabled=false --set fxa.pairing.url=wss://accounts.example.test --set ingress.enabled=true \
    --set ingress.host=sync.example.test --set admin.ingress.enabled=true --set admin.ingress.host=admin.example.test > /dev/null \
    || fail "distinct hosts refused: $(fxa_render -f "${fxa}" --set fxa.pairing.enabled=false --set fxa.pairing.url=wss://accounts.example.test | tail -2)"
  check "the hosts of contentUrl, authUrl, profileUrl, pairing.url, syncDomain (ingress.host) and admin.ingress.host pairwise distinct (case, trailing dot, port)"

  # the Secret: with the accounts, their eight generated secrets (as prepare_environment.sh,
  # 32 letters and digits) and ADMIN_FXA_CLIENT_SECRET of the values; none without them (the
  # generated ones kept by the lookup, ADMIN_FXA_CLIENT_SECRET removed: no old copy)
  # (and FXA_REDIS_PASSWORD, the chart's own: compose's Redis is on a network of its own)
  local generated="FXA_ADMIN_DB_PASSWORD FXA_AUTH_SECRET FXA_CONTENT_SESSION_SECRET FXA_FLOW_ID_KEY FXA_MYSQL_PASSWORD FXA_OAUTH_SECRET FXA_PROFILE_SECRET FXA_REDIS_PASSWORD FXA_SESSION_TOKEN_HANDLE_KEY"
  local prepared
  prepared=$({ sed -n 's/^ *for name in \(FXA_MYSQL_PASSWORD .*\); do$/\1/p' "${REPO_ROOT}"/setup/*.sh | tr ' ' '\n'; echo FXA_REDIS_PASSWORD; } | LC_ALL=C sort | paste -sd' ' -)
  [[ "${prepared}" == "${generated}" ]] || fail "prepare_environment.sh generates ${prepared} (with the chart's FXA_REDIS_PASSWORD), the chart ${generated}"
  secret_data() { helm template test-release "${CHART_DIR}" "$@" --show-only templates/secret.yaml | manifests | jq -c '.[0].data'; }
  local on off added
  on=$(secret_data -f "${fxa}" --set fxa.adminClientSecret="$(printf 'b%.0s' $(seq 1 64))")
  off=$(secret_data -f "${fxa}" --set fxa.enabled=false)
  added=$(jq -r --argjson off "${off}" 'keys - ($off | keys) | join(" ")' <<< "${on}")
  [[ "${added}" == "ADMIN_FXA_CLIENT_SECRET ${generated}" ]] || fail "fxa.enabled adds to the Secret: ${added}"
  jq -e 'has("ADMIN_FXA_CLIENT_SECRET") | not' <<< "$(secret_data -f "${fxa}" --set fxa.enabled=false --set fxa.adminClientSecret="$(printf 'b%.0s' $(seq 1 64))")" > /dev/null \
    || fail "accounts off: ADMIN_FXA_CLIENT_SECRET in the Secret"
  grep -qF '{{- $_ := unset $data "ADMIN_FXA_CLIENT_SECRET" }}' "${CHART_DIR}/templates/_helpers.tpl" \
    || fail "secretData does not remove ADMIN_FXA_CLIENT_SECRET with the accounts off (a lookup would keep an old copy)"
  jq -e --arg g "${generated}" '. as $d | [$g | split(" ")[] | $d[.] | @base64d | test("^[A-Za-z0-9]{32}$")] | all' <<< "${on}" > /dev/null \
    || fail "the generated secrets of the accounts are not 32 letters and digits: ${on}"
  [[ "$(jq -r '.ADMIN_FXA_CLIENT_SECRET | @base64d' <<< "${on}")" == "$(printf 'b%.0s' $(seq 1 64))" ]] || fail "ADMIN_FXA_CLIENT_SECRET is not fxa.adminClientSecret"
  [[ "$(secret_data -f "${fxa}" | jq -r '.ADMIN_FXA_CLIENT_SECRET')" == "" ]] || fail "an empty fxa.adminClientSecret is not an empty ADMIN_FXA_CLIENT_SECRET"
  for values in "${CHART_DIR}"/ci/{default,admin,backup,mysql,postgres}-values.yaml; do
    [[ "$(secret_data -f "${values}" | jq -r 'keys[] | select(test("^(FXA_|ADMIN_FXA_)") and . != "FXA_SMTP_PASS")')" == "" ]] \
      || fail "$(basename "${values}"): keys of the accounts in the Secret without them"
  done
  [[ "$(secret_data -f "${fxa}" --set smtp.password=pw | jq -r '.FXA_SMTP_PASS | @base64d')" == pw ]] || fail "FXA_SMTP_PASS is not smtp.password"
  check "Secret: fxa.enabled adds the eight generated secrets of prepare_environment.sh (32 characters) and ADMIN_FXA_CLIENT_SECRET (fxa.adminClientSecret); none without (ADMIN_FXA_CLIENT_SECRET removed); FXA_SMTP_PASS of smtp.password"

  # an existingSecret without the accounts' keys: the render fails naming them (lookup, so
  # tested here on the data it would return: helm template has no cluster)
  existing_check() {
    local d data=$1
    shift
    d=$(mktemp -d)
    cp -r "${CHART_DIR}" "${d}/chart"
    printf '%s\n' '{{- include "firefox-sync.checkSecretKeys" (dict "root" . "name" .Values.existingSecret "data" (fromJson (.Files.Get "files/data.json"))) }}' \
      'apiVersion: v1' 'kind: ConfigMap' 'metadata: {name: checked}' > "${d}/chart/templates/zz-check.yaml"
    printf '%s' "${data}" > "${d}/chart/files/data.json"
    helm template test-release "${d}/chart" "$@" --show-only templates/zz-check.yaml 2>&1
    local rc=$?
    rm -rf "${d}"
    return "${rc}"
  }
  local full='{"FXA_MYSQL_PASSWORD":"eA==","FXA_ADMIN_DB_PASSWORD":"eA==","FXA_AUTH_SECRET":"eA==","FXA_OAUTH_SECRET":"eA==","FXA_PROFILE_SECRET":"eA==","FXA_FLOW_ID_KEY":"eA==","FXA_SESSION_TOKEN_HANDLE_KEY":"eA==","FXA_CONTENT_SESSION_SECRET":"eA==","FXA_REDIS_PASSWORD":"eA=="}'
  out=$(existing_check '{"SYNC_MASTER_SECRET":"eA==","FXA_MYSQL_PASSWORD":"eA==","FXA_ADMIN_DB_PASSWORD":"eA==","FXA_OAUTH_SECRET":"","FXA_PROFILE_SECRET":"eA=="}' \
    -f "${fxa}" --set existingSecret=ffs-own) && fail "an existingSecret without the accounts' keys passes"
  grep -qF "existingSecret ffs-own lacks FXA_AUTH_SECRET, FXA_CONTENT_SESSION_SECRET, FXA_FLOW_ID_KEY, FXA_OAUTH_SECRET, FXA_REDIS_PASSWORD, FXA_SESSION_TOKEN_HANDLE_KEY" <<< "${out}" \
    || fail "an existingSecret without the accounts' keys: not the message: ${out}"
  existing_check "${full}" -f "${fxa}" --set existingSecret=ffs-own > /dev/null || fail "an existingSecret with the accounts' keys refused"
  existing_check '{}' -f "${fxa}" --set fxa.enabled=false --set existingSecret=ffs-own > /dev/null || fail "accounts off: their keys required"
  # your own accounts server: its policy user's password too (none without a policy user)
  out=$(existing_check "${full}" -f "${CHART_DIR}/ci/fxa-external-values.yaml") && fail "your own accounts server: FXA_MYSQL_POLICY_PASSWORD not required"
  grep -qF "lacks FXA_MYSQL_POLICY_PASSWORD" <<< "${out}" || fail "your own accounts server without FXA_MYSQL_POLICY_PASSWORD: not the message: ${out}"
  existing_check "${full}" -f "${CHART_DIR}/ci/fxa-external-values.yaml" --set fxa.database.external.policyUser= > /dev/null \
    || fail "your own accounts server without a policy user: FXA_MYSQL_POLICY_PASSWORD required"
  grep -qE '^\{\{- \$existing := lookup "v1" "Secret" \.Release\.Namespace \.Values\.existingSecret \}\}$' "${CHART_DIR}/templates/_fxa.tpl" \
    || fail "checkExistingSecret does not look the existingSecret up"
  check "existingSecret without FXA_* keys (or with them empty): the render fails naming them; FXA_MYSQL_POLICY_PASSWORD with your own server's policy user"

  # smtp.*: the server of the accounts and the admin UI (no admin.smtp)
  smtp_env() {
    helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/admin-values.yaml" "$@" | manifests | jq -c '[.[]
      | select(.kind == "Deployment" and .metadata.name == "test-release-firefox-sync-admin") | .spec.template.spec.containers[0].env[]
      | select(.name | startswith("SMTP_")) | {(.name): (.value // .valueFrom.secretKeyRef.key)}] | add'
  }
  [[ "$(smtp_env --set smtp.host=x)" == '{"SMTP_HOST":"x","SMTP_PORT":"587","SMTP_USER":"","SMTP_PASS":"FXA_SMTP_PASS","SMTP_SECURE":"false","SMTP_SENDER":""}' ]] \
    || fail "smtp.host=x: the admin UI's SMTP_*: $(smtp_env --set smtp.host=x)"
  [[ "$(smtp_env --set smtp.port=465 --set smtp.secure=true --set smtp.user=u --set-string smtp.sender='S <s@example.test>')" \
    == '{"SMTP_HOST":"smtp.example.test","SMTP_PORT":"465","SMTP_USER":"u","SMTP_PASS":"FXA_SMTP_PASS","SMTP_SECURE":"true","SMTP_SENDER":"S <s@example.test>"}' ]] \
    || fail "smtp.*: the admin UI's SMTP_*: $(smtp_env --set smtp.port=465 --set smtp.secure=true --set smtp.user=u)"
  ! grep -rn 'admin\.smtp' "${CHART_DIR}" "${REPO_ROOT}"/{HELM,ADMIN}.md "${REPO_ROOT}/tests/helm.sh" "${REPO_ROOT}/tests/helm_parity.py" "${REPO_ROOT}/admin/templates" \
    || fail "admin.smtp still named (now smtp)"
  check "smtp.* (host x) is the admin UI's SMTP_*; admin.smtp named nowhere"

  # the helpers of the accounts (for the templates of the next steps)
  helpers() {
    local d
    d=$(mktemp -d)
    cp -r "${CHART_DIR}" "${d}/chart"
    printf '%s\n' 'apiVersion: v1' 'kind: ConfigMap' 'metadata: {name: helpers}' 'data:' \
      '  fxa: {{ include "firefox-sync.fxaImage" (dict "root" . "name" "fxa") | quote }}' \
      '  pairing: {{ include "firefox-sync.fxaImage" (dict "root" . "name" "pairing") | quote }}' \
      '  db: {{ printf "%s %s %s %s" (include "firefox-sync.fxaDbHost" .) (include "firefox-sync.fxaDbPort" .) (include "firefox-sync.fxaDbUser" .) (include "firefox-sync.fxaDbImage" .) | quote }}' \
      '  host: {{ include "firefox-sync.fxaHost" (dict "root" . "url" .Values.fxa.authUrl) | quote }}' \
      '  oauth: {{ include "firefox-sync.fxaOauthServerUrl" . | quote }}' \
      '  email: {{ include "firefox-sync.fxaEmailDomain" . | quote }}' \
      '  allowlist: {{ include "firefox-sync.fxaAllowlist" . | quote }}' \
      '  mysql: {{ include "firefox-sync.fxaMysqlEnv" (dict "root" . "prefix" "AUTH_") | fromYamlArray | toJson | quote }}' \
      '  smtp: {{ include "firefox-sync.smtp" . | quote }}' \
      '  sec: {{ include "firefox-sync.fxaSecurityContext" . | fromYaml | toJson | quote }}' \
      '  pod: {{ include "firefox-sync.fxaPodSecurityContext" . | fromYaml | toJson | quote }}' \
      > "${d}/chart/templates/zz-helpers.yaml"
    helm template test-release "${d}/chart" "$@" --show-only templates/zz-helpers.yaml | manifests | jq -c '.[0].data'
    rm -rf "${d}"
  }
  out=$(helpers -f "${fxa}")
  [[ "$(jq -r '[.fxa, .pairing, .db, .host, .oauth, .email, .allowlist] | join("|")' <<< "${out}")" == \
    "ghcr.io/porelli/firefox-sync:fxa-mono-latest|ghcr.io/porelli/firefox-sync:fxa-channelserver-latest|test-release-firefox-sync-fxa-db 3306 root docker.io/library/mysql:lts|api.example.test|http://test-release-firefox-sync-fxa-auth:9000/v1|api.example.test|@example.test,you@example.org" ]] \
    || fail "the helpers of the accounts: ${out}"
  [[ "$(jq -r '.mysql' <<< "${out}")" == '[{"name":"AUTH_MYSQL_HOST","value":"test-release-firefox-sync-fxa-db"},{"name":"AUTH_MYSQL_PORT","value":"3306"},{"name":"AUTH_MYSQL_USERNAME","value":"root"},{"name":"AUTH_MYSQL_PASSWORD","valueFrom":{"secretKeyRef":{"key":"FXA_MYSQL_PASSWORD","name":"test-release-firefox-sync"}}}]' ]] \
    || fail "fxaMysqlEnv AUTH_: $(jq -r '.mysql' <<< "${out}")"
  [[ "$(jq -r '.sec' <<< "${out}")" == '{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"runAsGroup":10001,"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}}' ]] \
    || fail "fxaSecurityContext: $(jq -r '.sec' <<< "${out}")"
  [[ "$(jq -r '.pod' <<< "${out}")" == '{"runAsGroup":10001,"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}}' ]] \
    || fail "fxaPodSecurityContext (volumeOwnerInit: the init containers chown, no fsGroup): $(jq -r '.pod' <<< "${out}")"
  [[ "$(helpers -f "${fxa}" --set fxa.volumeOwnerInit=false | jq -r '.pod')" == \
    '{"fsGroup":10001,"fsGroupChangePolicy":"OnRootMismatch","runAsGroup":10001,"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}}' ]] \
    || fail "fxaPodSecurityContext with volumeOwnerInit=false: $(helpers -f "${fxa}" --set fxa.volumeOwnerInit=false | jq -r '.pod')"
  out=$(helpers -f "${CHART_DIR}/ci/fxa-external-values.yaml" --set fxa.image.repository=docker.io/mozilla/fxa-mono --set fxa.image.tag=v1.347.1 \
    --set fxa.pairing.image=docker.io/mozilla/channelserver:v0.9 --set fxa.database.external.port=3307 --set-string fxa.signupAllowlist='a@x.test\,@y.test')
  [[ "$(jq -r '[.fxa, .pairing, .db, .allowlist] | join("|")' <<< "${out}")" == \
    "docker.io/mozilla/fxa-mono:v1.347.1|docker.io/mozilla/channelserver:v0.9|fxadb.example.test 3307 fxa docker.io/library/mariadb:lts|a@x.test,@y.test" ]] \
    || fail "the helpers with your own accounts server: ${out}"
  out=$(helpers -f "${CHART_DIR}/ci/default-values.yaml")
  [[ "$(jq -r '[.oauth, .email] | join("|")' <<< "${out}")" == "https://oauth.accounts.firefox.com/v1|api.accounts.firefox.com" ]] \
    || fail "accounts off: fxaOauthServerUrl, fxaEmailDomain not fxa.oauthServerUrl, fxa.emailDomain: ${out}"
  [[ "$(jq -r '.smtp' <<< "${out}")" == '{"host":"","port":"587","secure":"false","sender":"","user":""}' ]] || fail "firefox-sync.smtp: $(jq -r '.smtp' <<< "${out}")"
  check "helpers: fxaImage, fxaDb*, fxaHost, fxaOauthServerUrl, fxaEmailDomain (derived with the accounts), fxaAllowlist, fxaMysqlEnv, smtp, security contexts"

  fxa_objects_lint
  fxa_ingress_lint
  fxa_pairing_lint
  fxa_backup_lint
  fxa_admin_lint

  # chart 0.1.0's render, with the accounts off: the same objects for every ci/*.yaml it had,
  # but the chart label, ADMIN_K8S_CHART_VERSION and the generated secrets
  fxa_base_parity
}

# the accounts' public hosts: an Ingress each (content, auth, profile with /img/ to img-proxy),
# their class, annotations and certificates; and what NOTES says of them
fxa_ingress_lint() {
  local fxa="${CHART_DIR}/ci/fxa-values.yaml" out want
  # fxa_ingresses <helm args>: the accounts' Ingresses, each its name, class, annotations, tls, rules
  fxa_ingresses() {
    helm template test-release "${CHART_DIR}" -f "${fxa}" "$@" | manifests | jq -c '[.[] | select(.kind == "Ingress" and (.metadata.name | test("-fxa-")))
      | {name: .metadata.name, component: .metadata.labels["app.kubernetes.io/component"], class: .spec.ingressClassName, annotations: .metadata.annotations,
        tls: .spec.tls, rules: [.spec.rules[] | {host, paths: [.http.paths[] | [.path, .pathType, .backend.service.name, .backend.service.port.number]]}]}]'
  }
  local f=test-release-firefox-sync
  want='[{"name":"'${f}'-fxa-content","component":"fxa-content","class":null,"annotations":null,"tls":[{"hosts":["accounts.example.test"]}],"rules":[{"host":"accounts.example.test","paths":[["/","Prefix","'${f}'-fxa-content",3030]]}]},'
  want+='{"name":"'${f}'-fxa-auth","component":"fxa-auth","class":null,"annotations":null,"tls":[{"hosts":["api.example.test"]}],"rules":[{"host":"api.example.test","paths":[["/","Prefix","'${f}'-fxa-auth",9000],["/v1/account/create","Exact","'${f}'-admin",8081]]}]},'
  want+='{"name":"'${f}'-fxa-profile","component":"fxa-profile","class":null,"annotations":null,"tls":[{"hosts":["profile.example.test"]}],"rules":[{"host":"profile.example.test","paths":[["/","Prefix","'${f}'-fxa-profile",1111],["/img/","Prefix","'${f}'-fxa-profile",1114]]}]},'
  want+='{"name":"'${f}'-fxa-pairing","component":"fxa-pairing","class":null,"annotations":null,"tls":[{"hosts":["pairing.example.test"]}],"rules":[{"host":"pairing.example.test","paths":[["/","Prefix","'${f}'-fxa-pairing",8000]]}]}]'
  out=$(fxa_ingresses)
  [[ "${out}" == "${want}" ]] || fail "the accounts' Ingresses of ci/fxa-values.yaml: ${out}"
  if command -v kubeconform > /dev/null; then
    helm template test-release "${CHART_DIR}" -f "${fxa}" --show-only templates/fxa-ingress.yaml | kubeconform -strict -summary -kubernetes-version 1.27.0 > /dev/null \
      || fail "kubeconform -strict: the accounts' Ingresses of ci/fxa-values.yaml"
  fi
  # the services' ports in the Ingresses: those of their Services
  helm template test-release "${CHART_DIR}" -f "${fxa}" | manifests | jq -e '[.[] | select(.kind == "Service") | {key: .metadata.name, value: [.spec.ports[].port]}] | from_entries as $svc
    | [.[] | select(.kind == "Ingress") | .spec.rules[].http.paths[].backend.service | . as $b | $svc[$b.name] // [] | index($b.port.number) != null] | all' > /dev/null \
    || fail "an Ingress of the accounts to a Service port that does not exist"
  # the class and the annotations of all, a certificate each (empty: the controller's default),
  # the host without the URL's port
  out=$(fxa_ingresses --set fxa.ingress.className=nginx --set fxa.ingress.annotations.a=b --set fxa.ingress.tls.secretNames.content=c-tls \
    --set fxa.ingress.tls.secretNames.auth=a-tls --set fxa.ingress.tls.secretNames.profile=p-tls --set fxa.profileUrl=https://profile.example.test:8443/ \
    --set fxa.ingress.tls.secretNames.pairing=w-tls --set fxa.pairing.url=wss://pairing.example.test:8443 \
    | jq -c 'map([.name, .class, .annotations, .tls, .rules[0].host])')
  [[ "${out}" == '[["'${f}'-fxa-content","nginx",{"a":"b"},[{"hosts":["accounts.example.test"],"secretName":"c-tls"}],"accounts.example.test"],["'${f}'-fxa-auth","nginx",{"a":"b"},[{"hosts":["api.example.test"],"secretName":"a-tls"}],"api.example.test"],["'${f}'-fxa-profile","nginx",{"a":"b"},[{"hosts":["profile.example.test"],"secretName":"p-tls"}],"profile.example.test"],["'${f}'-fxa-pairing","nginx",{"a":"b"},[{"hosts":["pairing.example.test"],"secretName":"w-tls"}],"pairing.example.test"]]' ]] \
    || fail "fxa.ingress.className, annotations, tls.secretNames, a host with a port: ${out}"
  [[ "$(fxa_ingresses --set fxa.ingress.tls.enabled=false | jq -c 'map(.tls)')" == '[null,null,null,null]' ]] || fail "fxa.ingress.tls.enabled=false: tls in the Ingresses"
  # (the pairing server's only with it)
  [[ "$(fxa_ingresses --set fxa.pairing.enabled=false | jq -c 'map(.name)')" == '["'${f}'-fxa-content","'${f}'-fxa-auth","'${f}'-fxa-profile"]' ]] \
    || fail "fxa.pairing.enabled=false: the Ingresses $(fxa_ingresses --set fxa.pairing.enabled=false | jq -c 'map(.name)')"
  [[ "$(fxa_ingresses --set fxa.ingress.enabled=false)" == '[]' ]] || fail "fxa.ingress.enabled=false: the accounts' Ingresses rendered"
  # (the sign-up gate only with the admin UI, which serves it)
  [[ "$(fxa_ingresses --set admin.enabled=false | jq -c '.[1].rules[0].paths')" == '[["/","Prefix","'${f}'-fxa-auth",9000]]' ]] \
    || fail "admin.enabled=false: the auth Ingress: $(fxa_ingresses --set admin.enabled=false | jq -c '.[1].rules[0].paths')"
  [[ "$(fxa_ingresses --set fxa.enabled=false --set fxa.ingress.enabled=true)" == '[]' ]] || fail "fxa.enabled=false: the accounts' Ingresses rendered"
  check "Ingresses <fullname>-fxa-content (/ 3030), -fxa-auth (/ 9000, with the admin UI /v1/account/create Exact to -admin 8081), -fxa-profile (/ 1111, /img/ 1114), -fxa-pairing (/ 8000, with it) on their URLs' hosts, kubeconform -strict; fxa.ingress class, annotations, a certificate each; none with fxa.ingress.enabled=false"

  # NOTES: the four URLs, Firefox's setting, the keys' export, the memory, http:// warned of
  out=$(notes -f "${fxa}")
  for want in "  https://accounts.example.test  the pages (${f}-fxa-content:3030)" "  https://api.example.test  the API (${f}-fxa-auth:9000)" \
    "  https://profile.example.test  the profiles (${f}-fxa-profile:1111, /img/ to :1114)" "  wss://pairing.example.test  the pairing server" \
    "identity.fxaccounts.autoconfig.uri = https://accounts.example.test" \
    "kubectl -n default exec deploy/${f}-fxa-auth -c auth -- tar -C /fxa-keys -c secret-key.json public-key.json vapid-keys.json openid-key.json > fxa-keys.tar" \
    "about 3-4 GB of memory"; do
    grep -qF -- "${want}" <<< "${out}" || fail "NOTES with the accounts: no '${want}': ${out}"
  done
  grep -q "^Their URLs, published by the Ingresses ${f}-fxa-content, -fxa-auth, -fxa-profile and -fxa-pairing:$" <<< "${out}" || fail "NOTES: not the accounts' Ingresses: ${out}"
  grep -q "^  wss://pairing.example.test  the pairing server (${f}-fxa-pairing:8000)$" <<< "${out}" || fail "NOTES: not the pairing server's Service: ${out}"
  grep -q "^Their URLs, published by the Ingresses ${f}-fxa-content, -fxa-auth and -fxa-profile:$" <<< "$(notes -f "${fxa}" --set fxa.pairing.enabled=false)" \
    || fail "NOTES without the pairing server: not the three Ingresses: $(notes -f "${fxa}" --set fxa.pairing.enabled=false)"
  ! grep -q '^WARNING: fxa\.' <<< "${out}" || fail "NOTES: a warning on https:// URLs"
  grep -q 'Publish these Services at these URLs' <<< "$(notes -f "${fxa}" --set fxa.ingress.enabled=false)" || fail "NOTES without the accounts' Ingresses: not what to publish"
  ! grep -q 'wss://pairing' <<< "$(notes -f "${fxa}" --set fxa.pairing.enabled=false)" || fail "NOTES: the pairing server's URL with it off"
  out=$(notes -f "${fxa}" --set fxa.contentUrl=http://accounts.example.test --set fxa.profileUrl=http://profile.example.test)
  if ! grep -q '^WARNING: fxa.contentUrl is http://' <<< "${out}" || ! grep -q '^WARNING: fxa.profileUrl is http://' <<< "${out}" \
    || grep -q '^WARNING: fxa.authUrl' <<< "${out}"; then
    fail "NOTES: not a warning for each http:// URL: ${out}"
  fi
  ! grep -q 'fxa-keys.tar' <<< "$(notes -f "${fxa}" --set fxa.keys.existingSecret=mine)" || fail "NOTES: the keys' export with fxa.keys.existingSecret"
  ! grep -qi 'accounts' <<< "$(notes -f "${CHART_DIR}/ci/default-values.yaml")" || fail "NOTES without the accounts: names them"
  # the bundled accounts database: its image and the major guard; on MySQL 8 the native
  # password and the move to 9, on lts the patch it needs; nothing with your own server
  grep -q "^Their database runs docker.io/library/mysql:lts: a helm upgrade that would move it to another major is refused$" <<< "${out}" \
    && grep -q "^unless fxa.database.allowMajorUpgrade=true" <<< "${out}" \
    && grep -q "MySQL lts needs an accounts image with mozilla/fxa#21554 (ours);$" <<< "${out}" || fail "NOTES: the accounts database on mysql:lts: ${out}"
  grep -q "On MySQL 8 with mysql_native_password, for" <<< "$(notes -f "${fxa}" --set fxa.database.image.mysql=docker.io/library/mysql:8)" \
    || fail "NOTES: the accounts database on mysql:8 without its native password note"
  out=$(notes -f "${fxa}" --set fxa.database.backend=mariadb)
  grep -q "^Their database runs docker.io/library/mariadb:lts:" <<< "${out}" && ! grep -q 'mozilla/fxa#21554' <<< "${out}" || fail "NOTES: the accounts database on MariaDB: ${out}"
  ! grep -q '^Their database runs' <<< "$(notes -f "${CHART_DIR}/ci/fxa-external-values.yaml")" || fail "NOTES: the bundled accounts database with your own server"
  # the GitOps hint (without existingSecret): the accounts' keys too, fxaGeneratedKeys (as checkSecretKeys)
  keys=$(sed -n '/define "firefox-sync.fxaGeneratedKeys"/{n;p;}' "${CHART_DIR}/templates/_fxa.tpl")
  [[ $(wc -w <<< "${keys}") -eq 9 && ${keys} == *FXA_REDIS_PASSWORD* ]] || fail "fxaGeneratedKeys not the nine keys with FXA_REDIS_PASSWORD: ${keys}"
  grep -qxF "With the self-hosted accounts, also ${keys// /, }" <<< "$(notes -f "${fxa}")" || fail "NOTES: the existingSecret hint without the accounts' keys: $(notes -f "${fxa}")"
  check "NOTES with the accounts: the four URLs, identity.fxaccounts.autoconfig.uri, the keys' export (not with fxa.keys.existingSecret), the memory, a warning for each http:// URL; the accounts database's image, its major guard, MySQL 8's native password or lts' patch; the existingSecret hint with the accounts' nine keys"
}

# the pairing server (fxa.pairing.enabled), compose's fxa-pairing: its env, its healthcheck as
# the probes, as nobody (65534) on a read-only root (PodSecurity restricted); its URL in content
# and the admin UI
fxa_pairing_lint() {
  local fxa="${CHART_DIR}/ci/fxa-values.yaml" f=test-release-firefox-sync objs pod out
  objs=$(helm template test-release "${CHART_DIR}" -f "${fxa}" | manifests)
  pod=$(jq -c --arg n "${f}-fxa-pairing" '.[] | select(.kind == "Deployment" and .metadata.name == $n) | .spec.template' <<< "${objs}")
  [[ -n "${pod}" ]] || fail "no Deployment ${f}-fxa-pairing with fxa.pairing.enabled"
  # (compose's healthcheck, verbatim)
  local hc='exec 3<>/dev/tcp/127.0.0.1/8000 && printf '"'"'GET /__heartbeat__ HTTP/1.0\r\nHost: localhost\r\n\r\n'"'"' >&3 && head -n 1 <&3 | grep -q '"'"' 200 '"'"
  jq -e --arg hc "${hc}" '.spec.containers | length == 1 and (.[0] | .name == "pairing" and .image == "ghcr.io/porelli/firefox-sync:fxa-channelserver-latest"
    and ([.env[] | "\(.name)=\(.value)"] == ["PAIR_HOSTNAME=0.0.0.0", "PAIR_PORT=8000", "PAIR_HUMAN_LOGS=true", "PAIR_TRUSTED_PROXY_LIST=127.0.0.1,172.16.0.0/12,10.0.0.0/8,192.168.0.0/16"])
    and .ports == [{name: "http", containerPort: 8000}]
    and .startupProbe == {exec: {command: ["bash", "-c", $hc]}, periodSeconds: 10, timeoutSeconds: 5, failureThreshold: 30}
    and .readinessProbe == {exec: {command: ["bash", "-c", $hc]}, periodSeconds: 30, timeoutSeconds: 5, failureThreshold: 3}
    and .livenessProbe == {exec: {command: ["bash", "-c", $hc]}, periodSeconds: 30, timeoutSeconds: 5, failureThreshold: 3}
    and .securityContext == {runAsNonRoot: true, runAsUser: 65534, runAsGroup: 65534, readOnlyRootFilesystem: true, allowPrivilegeEscalation: false,
      capabilities: {drop: ["ALL"]}, seccompProfile: {type: "RuntimeDefault"}})' <<< "${pod}" > /dev/null \
    || fail "the pairing server's container: $(jq -c '.spec.containers' <<< "${pod}")"
  jq -e '.spec.securityContext == {runAsNonRoot: true, runAsUser: 65534, runAsGroup: 65534, seccompProfile: {type: "RuntimeDefault"}}
    and (.spec | has("initContainers") | not) and (.spec | has("volumes") | not) and .metadata.labels["app.kubernetes.io/component"] == "fxa-pairing"' <<< "${pod}" > /dev/null \
    || fail "the pairing server's pod: $(jq -c '[.metadata, .spec.securityContext]' <<< "${pod}")"
  jq -e --arg n "${f}-fxa-pairing" '[.[] | select(.kind == "Service" and .metadata.name == $n) | [.spec.selector["app.kubernetes.io/component"], [.spec.ports[] | [.name, .port, .targetPort]]]]
    == [["fxa-pairing", [["http", 8000, "http"]]]]' <<< "${objs}" > /dev/null || fail "no Service ${f}-fxa-pairing http 8000"
  # (the values: its image, the trusted proxies, the resources)
  pod=$(helm template test-release "${CHART_DIR}" -f "${fxa}" --set fxa.pairing.image=example.test/pairing:1 --set fxa.pairing.trustedProxies=10.0.0.0/8 \
    --set fxa.pairing.resources.requests.memory=16Mi | manifests | jq -c --arg n "${f}-fxa-pairing" '.[] | select(.kind == "Deployment" and .metadata.name == $n) | .spec.template.spec.containers[0]')
  jq -e '.image == "example.test/pairing:1" and (.env[3] | .name == "PAIR_TRUSTED_PROXY_LIST" and .value == "10.0.0.0/8") and .resources == {requests: {memory: "16Mi"}}' <<< "${pod}" > /dev/null \
    || fail "fxa.pairing.image, trustedProxies, resources: $(jq -c '[.image, .env, .resources]' <<< "${pod}")"
  # none without it, or without the accounts
  for args in "--set fxa.pairing.enabled=false" "--set fxa.enabled=false"; do
    # shellcheck disable=SC2086 # (its words)
    [[ "$(helm template test-release "${CHART_DIR}" -f "${fxa}" ${args} | manifests | jq -c '[.[] | select(.metadata.name | contains("pairing")) | .kind]')" == '[]' ]] \
      || fail "${args}: pairing objects rendered"
  done
  # its URL: content's PAIRING_SERVER_BASE_URI (Firefox's QR code), the admin UI's health check
  out=$(jq -r --arg f "${f}" '[.[] | select(.kind == "Deployment" and (.metadata.name == "\($f)-fxa-content" or .metadata.name == "\($f)-admin"))
    | .spec.template.spec.containers[0].env[] | select(.name | test("PAIRING")) | "\(.name)=\(.value)"] | join(" ")' <<< "${objs}")
  [[ "${out}" == *"PAIRING_SERVER_BASE_URI=wss://pairing.example.test"* && "${out}" == *"FXA_PAIRING_URL=wss://pairing.example.test"* \
    && "${out}" == *"FXA_PAIRING_INTERNAL_URL=http://${f}-fxa-pairing:8000"* ]] || fail "the pairing server's URL in content and the admin UI: ${out}"
  check "pairing: Deployment and Service ${f}-fxa-pairing:8000 with compose's env and healthcheck (exec bash /dev/tcp, startup 10/5/30, 30/5/3), 65534 on a read-only root; fxa.pairing.image, trustedProxies, resources; none without it; PAIRING_SERVER_BASE_URI and FXA_PAIRING_URL of fxa.pairing.url"
}

# the backups of the accounts (backup.enabled with fxa.enabled), compose's backup-fxa: an init
# container of the backup CronJob, before the Sync scope (the Quadlets' Before=), in the
# accounts database's image (its client), recorded by the sync scope of the same run
fxa_backup_lint() {
  local fxa="${CHART_DIR}/ci/fxa-values.yaml" f=test-release-firefox-sync pod
  backup_spec() { helm template test-release "${CHART_DIR}" "$@" | manifests | jq -c --arg n "${f}-backup" '.[] | select(.kind == "CronJob" and .metadata.name == $n) | .spec.jobTemplate.spec.template.spec'; }
  pod=$(backup_spec -f "${fxa}" --set backup.enabled=true)
  [[ -n "${pod}" ]] || fail "no CronJob ${f}-backup with ci/fxa-values.yaml and backup.enabled"
  jq -e --arg f "${f}" '(.initContainers | length == 1) and (.initContainers[0] | .name == "backup-accounts" and .image == "docker.io/library/mysql:lts"
    and .command == ["sh", "-c", "sh /ffs-backup/backup.sh now || echo \"the accounts backup failed: recorded\""] and (has("args") | not)
    and ([.env[] | "\(.name)=\(.value // ("secret:" + .valueFrom.secretKeyRef.key))"] == ["BACKUP_SCOPE=accounts", "BACKUP_KEEP=7", "BACKUP_TIME=03:00",
      "FXA_DB_HOST=\($f)-fxa-db", "FXA_DB_PORT=3306", "FXA_DB_USER=root", "FXA_DB_PASSWORD=secret:FXA_MYSQL_PASSWORD"])
    and .volumeMounts == [{name: "scripts", mountPath: "/ffs-backup", readOnly: true}, {name: "backups", mountPath: "/backups"}]
    and .securityContext == {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}})
    and ([.containers[] | .name] == ["backup"]) and (.containers[0].env[0] | .name == "BACKUP_SCOPE" and .value == "sync")' <<< "${pod}" > /dev/null \
    || fail "the backups of the accounts: $(jq -c '[.initContainers, [.containers[].name]]' <<< "${pod}")"
  # (MariaDB's client with MariaDB; the values of the backups)
  jq -e '.initContainers[0].image == "docker.io/library/mariadb:lts"' <<< "$(backup_spec -f "${fxa}" --set backup.enabled=true --set fxa.database.backend=mariadb)" > /dev/null \
    || fail "the accounts' backups on MariaDB: not its image"
  pod=$(backup_spec -f "${fxa}" --set backup.enabled=true --set backup.keep=3 --set backup.schedule='5 23 * * *' --set backup.resources.requests.cpu=5m)
  [[ "$(jq -r '.initContainers[0] | [(.env[] | select(.name | test("^(BACKUP_KEEP|BACKUP_TIME)$")) | "\(.name)=\(.value)"), .resources.requests.cpu] | join(" ")' <<< "${pod}")" \
    == "BACKUP_KEEP=3 BACKUP_TIME=23:05 5m" ]] \
    || fail "the accounts' backups with backup.keep, schedule, resources: $(jq -c '.initContainers[0] | [.env, .resources]' <<< "${pod}")"
  # (none with your own accounts server, as compose's: its accounts' user cannot read ffs; nor
  # without the accounts: chart 0.1.0's CronJob)
  for pod in "-f ${CHART_DIR}/ci/fxa-external-values.yaml" "-f ${fxa} --set fxa.database.bundled=false --set existingSecret=mine --set fxa.database.external.host=db" "-f ${fxa} --set fxa.enabled=false"; do
    # shellcheck disable=SC2086 # (the arguments)
    jq -e '(has("initContainers") | not) and ([.containers[].name] == ["backup"])' <<< "$(backup_spec ${pod} --set backup.enabled=true)" > /dev/null \
      || fail "backup.enabled, ${pod}: not the Sync scope alone"
  done
  check "backups with the accounts: init container backup-accounts (fxaDbImage, compose's backup-fxa env, backup.sh now, a failure recorded) before the Sync scope in ${f}-backup; none with your own accounts server (its user cannot read ffs), nor without the accounts"
}

# the admin UI with the accounts: compose's ffs-admin block of compose/fxa.yml (and the
# chart's own: Redis' password, the servers' Services, the test CA), the sign-up gate's port, its
# wait for auth; sign-in with the accounts (admin.fxaSignIn): the client id given or derived, the
# redirect URL, the client in auth (and content) as compose renders them
fxa_admin_lint() {
  local fxa="${CHART_DIR}/ci/fxa-values.yaml" out want id f=test-release-firefox-sync
  # admin_objs <release> <helm args>: the objects of ci/fxa-values.yaml with them
  admin_objs() { helm template "$1" "${CHART_DIR}" -f "${fxa}" "${@:2}" | manifests; }
  # admin_pod_of <objects> <component>: the pod of the Deployment of that component
  admin_pod_of() { jq -c --arg c "$2" '.[] | select(.kind == "Deployment" and .metadata.labels["app.kubernetes.io/component"] == $c) | .spec.template' <<< "$1"; }
  # admin_env_of <pod> <container> <regex>: those of its variables, NAME=value|... (secret:KEY)
  admin_env_of() { jq -r --arg c "$2" '.spec.containers[] | select(.name == $c) | (.env // [])[] | "\(.name)=\(.value // ("secret:" + .valueFrom.secretKeyRef.key))"' <<< "$1" | grep -E "$3" | paste -sd'|' -; }
  local signin=(--set admin.fxaSignIn=true --set admin.allowed.users=@example.test --set admin.ingress.host=admin.example.test)

  # compose's FxA block of ffs-admin, in its order, then the chart's own
  local objs admin
  objs=$(admin_objs test-release)
  admin=$(admin_pod_of "${objs}" admin)
  want="FXA_OAUTH_SERVER_URL=http://${f}-fxa-auth:9000/v1|FXA_EMAIL_DOMAIN=api.example.test|FXA_DB_HOST=${f}-fxa-db|FXA_DB_PORT=3306"
  want+="|FXA_DB_PASSWORD=secret:FXA_ADMIN_DB_PASSWORD|FXA_MAX_ACCOUNTS=initial:unlimited|FXA_AUTH_UPSTREAM=http://${f}-fxa-auth:9000"
  want+="|FXA_PAIRING_URL=wss://pairing.example.test|FXA_ACCOUNT_EVENTS=false|FXA_CONTENT_URL=https://accounts.example.test|FXA_AUTH_URL=https://api.example.test"
  want+="|FXA_PROFILE_URL=https://profile.example.test|FXA_DB=mysql|ADMIN_GATE_EXPORT_PORT=${f}-admin:8081|FXA_CLIENT_ADDRESS_DEPTH=2|FXA_ACCESS_TOKEN_LIFETIME=60 minutes"
  want+="|FXA_REDIS=${f}-fxa-redis:6379|FXA_REDIS_PASSWORD=secret:FXA_REDIS_PASSWORD|FXA_CONTENT_INTERNAL_URL=http://${f}-fxa-content:3030"
  want+="|FXA_PROFILE_INTERNAL_URL=http://${f}-fxa-profile:1111|FXA_PAIRING_INTERNAL_URL=http://${f}-fxa-pairing:8000"
  out=$(admin_env_of "${admin}" admin '^(FXA_|ADMIN_GATE_|SSL_CERT_)')
  [[ "${out}" == "${want}" ]] || fail "the admin UI's env with the accounts: ${out}"
  # (the other values; MariaDB, no pairing, your own accounts server)
  out=$(admin_env_of "$(admin_pod_of "$(admin_objs test-release --set fxa.database.backend=mariadb --set fxa.pairing.enabled=false --set-string fxa.maxAccounts=5 \
    --set fxa.accountEvents=true --set fxa.clientAddressDepth=3 --set-string fxa.accessTokenLifetime='30 minutes')" admin)" admin '^(FXA_(DB|MAX|PAIRING|ACCOUNT_EVENTS|CLIENT|ACCESS)_?)')
  [[ "${out}" == "FXA_DB_HOST=${f}-fxa-db|FXA_DB_PORT=3306|FXA_DB_PASSWORD=secret:FXA_ADMIN_DB_PASSWORD|FXA_MAX_ACCOUNTS=5|FXA_PAIRING_URL=|FXA_ACCOUNT_EVENTS=true|FXA_DB=mariadb|FXA_CLIENT_ADDRESS_DEPTH=3|FXA_ACCESS_TOKEN_LIFETIME=30 minutes" ]] \
    || fail "the admin UI's env with other values of the accounts: ${out}"
  out=$(admin_env_of "$(admin_pod_of "$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/fxa-external-values.yaml" --set admin.enabled=true | manifests)" admin)" admin '^FXA_DB_(HOST|PORT)=')
  [[ "${out}" == "FXA_DB_HOST=fxadb.example.test|FXA_DB_PORT=3306" ]] || fail "the admin UI with your own accounts server: ${out}"
  # the gate's port on the Service and the container, the wait for auth (compose's depends_on fxa-policy)
  jq -e --arg f "${f}" '[.[] | select(.kind == "Service" and .metadata.name == "\($f)-admin") | .spec.ports[] | [.name, .port, .targetPort, .protocol]]
    == [["http", 8080, "http", "TCP"], ["statsd", 8125, "statsd", "UDP"], ["gate", 8081, "gate", "TCP"]]' <<< "${objs}" > /dev/null \
    || fail "the admin UI's Service: $(jq -c --arg f "${f}" '.[] | select(.kind == "Service" and .metadata.name == "\($f)-admin") | .spec.ports' <<< "${objs}")"
  jq -e --arg f "${f}" '(.spec.containers[0].ports | map("\(.name)/\(.containerPort)/\(.protocol)")) == ["http/8080/TCP", "statsd/8125/UDP", "gate/8081/TCP"]
    and ([.spec.initContainers[].name] == ["wait-sync", "wait-fxa"])
    and (.spec.initContainers[1] | .image == "ghcr.io/porelli/firefox-sync:syncstorage-rs-mysql-latest" and (.args[0] | contains("curl -sf -o /dev/null http://\($f)-fxa-auth:9000/__heartbeat__"))
      and .securityContext == {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}})' <<< "${admin}" > /dev/null \
    || fail "the admin UI's ports and init containers: $(jq -c '[.spec.containers[0].ports, .spec.initContainers]' <<< "${admin}")"
  # (Ready once the gate listens too: the Ingress sends the sign-ups there; started and alive
  # by /healthz, as without the accounts)
  jq -e '.spec.containers[0] | .readinessProbe == {tcpSocket: {port: "gate"}, periodSeconds: 10, timeoutSeconds: 5, failureThreshold: 3}
    and .startupProbe.httpGet == {path: "/healthz", port: "http"} and .livenessProbe.httpGet == {path: "/healthz", port: "http"}' <<< "${admin}" > /dev/null \
    || fail "the admin UI's probes with the accounts: $(jq -c '.spec.containers[0] | [.startupProbe, .readinessProbe, .livenessProbe]' <<< "${admin}")"
  # (the test CA of fxa.extraCaCerts: Go's SSL_CERT_DIR, besides the system's)
  out=$(admin_pod_of "$(admin_objs test-release --set fxa.extraCaCerts.configMap=my-ca --set fxa.extraCaCerts.key=root.pem)" admin)
  jq -e '(.spec.containers[0] | (.env[] | select(.name == "SSL_CERT_DIR") | .value == "/ffs-ca") and .volumeMounts == [{name: "ffs-ca", mountPath: "/ffs-ca", readOnly: true}])
    and .spec.volumes == [{name: "ffs-ca", configMap: {name: "my-ca"}}]' <<< "${out}" > /dev/null || fail "fxa.extraCaCerts: the admin UI without /ffs-ca: $(jq -c '.spec.containers[0].volumeMounts, .spec.volumes' <<< "${out}")"
  jq -e '(.spec.containers[0] | has("volumeMounts") | not) and (.spec | has("volumes") | not)' <<< "${admin}" > /dev/null || fail "no fxa.extraCaCerts: volumes in the admin UI"
  check "admin UI with the accounts: compose's FxA block (FXA_DB_*, FXA_MAX_ACCOUNTS, FXA_AUTH_UPSTREAM, ..., ADMIN_GATE_EXPORT_PORT ${f}-admin:8081), Redis with its password, the servers' Services; gate 8081 on its Service, Ready once it listens (tcpSocket); wait-fxa; SSL_CERT_DIR with fxa.extraCaCerts"

  # without sign-in with the accounts: no client in auth (compose with ADMIN_FXA_CLIENT_ID empty:
  # SERVICES_WITH_EMAIL_VERIFICATION with its trailing comma), the admin UI's OIDC its values
  out=$(admin_env_of "$(admin_pod_of "${objs}" fxa-auth)" auth '^(ADMIN_|SERVICES_)')
  [[ "${out}" == "ADMIN_FXA_CLIENT_ID=|ADMIN_FXA_CLIENT_SECRET=secret:ADMIN_FXA_CLIENT_SECRET|ADMIN_OIDC_REDIRECT_URL=|SERVICES_WITH_EMAIL_VERIFICATION=32aaeb6f1c21316a,98e6508e88680e1a," ]] \
    || fail "auth without admin.fxaSignIn: ${out}"
  out=$(admin_env_of "${admin}" admin '^ADMIN_OIDC_')
  [[ "${out}" == "ADMIN_OIDC_ISSUER=|ADMIN_OIDC_CLIENT_ID=|ADMIN_OIDC_CLIENT_SECRET=secret:ADMIN_OIDC_CLIENT_SECRET|ADMIN_OIDC_REDIRECT_URL=|ADMIN_OIDC_SCOPES=|ADMIN_OIDC_NAME=|ADMIN_OIDC_GROUPS_CLAIM=|ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL=" ]] \
    || fail "the admin UI without admin.fxaSignIn: ${out}"

  # admin.fxaSignIn: the id derived from the namespace and the release (the same on every
  # render, 16 hex, another for another release), the redirect URL of admin.ingress.host
  id=$(printf %s "default/test-release/admin-oidc" | sha256sum | cut -c1-16)
  objs=$(admin_objs test-release "${signin[@]}")
  out=$(admin_env_of "$(admin_pod_of "${objs}" fxa-auth)" auth '^(ADMIN_|SERVICES_)')
  [[ "${out}" == "ADMIN_FXA_CLIENT_ID=${id}|ADMIN_FXA_CLIENT_SECRET=secret:ADMIN_FXA_CLIENT_SECRET|ADMIN_OIDC_REDIRECT_URL=https://admin.example.test/auth/callback|SERVICES_WITH_EMAIL_VERIFICATION=32aaeb6f1c21316a,98e6508e88680e1a,${id}" ]] \
    || fail "auth with admin.fxaSignIn: ${out} (the id: ${id})"
  [[ "${id}" =~ ^[0-9a-f]{16}$ ]] || fail "the derived client id: ${id}"
  [[ "$(admin_env_of "$(admin_pod_of "$(admin_objs test-release "${signin[@]}")" fxa-auth)" auth '^ADMIN_FXA_CLIENT_ID=')" == "ADMIN_FXA_CLIENT_ID=${id}" ]] || fail "the derived client id differs between two renders"
  out=$(admin_env_of "$(admin_pod_of "$(admin_objs other "${signin[@]}")" fxa-auth)" auth '^ADMIN_FXA_CLIENT_ID=')
  [[ "${out}" =~ ^ADMIN_FXA_CLIENT_ID=[0-9a-f]{16}$ && "${out}" != "ADMIN_FXA_CLIENT_ID=${id}" && "${out}" == "ADMIN_FXA_CLIENT_ID=$(printf %s "default/other/admin-oidc" | sha256sum | cut -c1-16)" ]] \
    || fail "another release's derived client id: ${out} (test-release: ${id})"
  [[ "$(admin_env_of "$(admin_pod_of "${objs}" fxa-content)" content '^SERVICES_')" == "SERVICES_WITH_EMAIL_VERIFICATION=32aaeb6f1c21316a,${id}" ]] \
    || fail "content with admin.fxaSignIn: $(admin_env_of "$(admin_pod_of "${objs}" fxa-content)" content '^SERVICES_')"
  out=$(admin_env_of "$(admin_pod_of "${objs}" admin)" admin '^ADMIN_OIDC_')
  [[ "${out}" == "ADMIN_OIDC_ISSUER=https://accounts.example.test|ADMIN_OIDC_CLIENT_ID=${id}|ADMIN_OIDC_CLIENT_SECRET=secret:ADMIN_FXA_CLIENT_SECRET|ADMIN_OIDC_REDIRECT_URL=https://admin.example.test/auth/callback|ADMIN_OIDC_SCOPES=|ADMIN_OIDC_NAME=Mozilla account|ADMIN_OIDC_GROUPS_CLAIM=|ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL=true" ]] \
    || fail "the admin UI with admin.fxaSignIn: ${out}"
  # (fxa.adminClientId and the admin.oidc values over the defaults, as compose's ${...:-...})
  objs=$(admin_objs test-release "${signin[@]}" --set fxa.adminClientId=0123456789abcdef --set admin.oidc.redirectUrl=https://ops.example.test/admin/auth/callback \
    --set admin.oidc.name=Accounts --set admin.oidc.clientSecret=s3cret --set admin.oidc.trustUnverifiedEmail=false)
  [[ "$(admin_env_of "$(admin_pod_of "${objs}" fxa-auth)" auth '^(ADMIN_FXA_CLIENT_ID|ADMIN_OIDC_REDIRECT_URL)=')" == "ADMIN_FXA_CLIENT_ID=0123456789abcdef|ADMIN_OIDC_REDIRECT_URL=https://ops.example.test/admin/auth/callback" ]] \
    || fail "auth with fxa.adminClientId, admin.oidc.redirectUrl: $(admin_env_of "$(admin_pod_of "${objs}" fxa-auth)" auth '^ADMIN_')"
  out=$(admin_env_of "$(admin_pod_of "${objs}" admin)" admin '^ADMIN_OIDC_(CLIENT_ID|CLIENT_SECRET|REDIRECT_URL|NAME|TRUST_UNVERIFIED_EMAIL)=')
  [[ "${out}" == "ADMIN_OIDC_CLIENT_ID=0123456789abcdef|ADMIN_OIDC_CLIENT_SECRET=secret:ADMIN_OIDC_CLIENT_SECRET|ADMIN_OIDC_REDIRECT_URL=https://ops.example.test/admin/auth/callback|ADMIN_OIDC_NAME=Accounts|ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL=false" ]] \
    || fail "the admin UI with fxa.adminClientId and admin.oidc.*: ${out}"
  # (another provider of admin.oidc.issuer: its unverified emails not trusted by default)
  [[ "$(admin_env_of "$(admin_pod_of "$(admin_objs test-release "${signin[@]}" --set admin.oidc.issuer=https://dex.example.test)" admin)" admin '^ADMIN_OIDC_(ISSUER|TRUST_UNVERIFIED_EMAIL)=')" \
    == "ADMIN_OIDC_ISSUER=https://dex.example.test|ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL=" ]] || fail "admin.fxaSignIn with another admin.oidc.issuer: trusts its unverified emails"
  # (no admin UI: no client in auth)
  [[ "$(admin_env_of "$(admin_pod_of "$(admin_objs test-release "${signin[@]}" --set admin.enabled=false)" fxa-auth)" auth '^ADMIN_FXA_CLIENT_ID=')" == "ADMIN_FXA_CLIENT_ID=" ]] \
    || fail "admin.fxaSignIn without the admin UI: a client in auth"
  # what sign-in needs, or the render fails saying so
  out=$(helm template test-release "${CHART_DIR}" -f "${fxa}" --set admin.fxaSignIn=true --set admin.ingress.host=admin.example.test 2>&1) && fail "admin.fxaSignIn without admin.allowed: renders"
  grep -qF "admin.fxaSignIn needs admin.allowed.users or admin.allowed.groups" <<< "${out}" || fail "admin.fxaSignIn without admin.allowed: ${out}"
  out=$(helm template test-release "${CHART_DIR}" -f "${fxa}" --set admin.fxaSignIn=true --set admin.allowed.groups=ops 2>&1) && fail "admin.fxaSignIn without a redirect URL: renders"
  grep -qF "admin.fxaSignIn needs admin.oidc.redirectUrl or admin.ingress.host" <<< "${out}" || fail "admin.fxaSignIn without a redirect URL: ${out}"
  out=$(helm template test-release "${CHART_DIR}" -f "${fxa}" "${signin[@]}" --set admin.oidc.redirectUrl=https://admin.example.test/callback 2>&1) && fail "a redirect URL not of /auth/callback: renders"
  grep -qF "admin.oidc.redirectUrl must be the admin UI's https://<host>/auth/callback" <<< "${out}" || fail "a redirect URL not of /auth/callback: ${out}"
  # (https only: the accounts send the admins' codes there)
  out=$(helm template test-release "${CHART_DIR}" -f "${fxa}" "${signin[@]}" --set admin.oidc.redirectUrl=http://admin.example.test/auth/callback 2>&1) && fail "an http:// redirect URL: renders"
  grep -qF "admin.oidc.redirectUrl must be the admin UI's https://<host>/auth/callback" <<< "${out}" || fail "an http:// redirect URL: ${out}"
  # (fxa.adminClientId without admin.fxaSignIn registers nothing: refused rather than ignored;
  # with it and the admin UI off, as the admin UI's other values: kept for when it is on again)
  for args in "" "--set admin.enabled=false"; do
    # shellcheck disable=SC2086 # (its words)
    out=$(helm template test-release "${CHART_DIR}" -f "${fxa}" --set fxa.adminClientId=0123456789abcdef ${args} 2>&1) && fail "fxa.adminClientId without admin.fxaSignIn (${args}): renders"
    grep -qF "firefox-sync: fxa.adminClientId needs admin.fxaSignIn" <<< "${out}" || fail "fxa.adminClientId without admin.fxaSignIn (${args}): ${out}"
  done
  helm template test-release "${CHART_DIR}" -f "${fxa}" --set fxa.adminClientId=0123456789abcdef --set admin.fxaSignIn=true --set admin.enabled=false > /dev/null \
    || fail "fxa.adminClientId and admin.fxaSignIn with the admin UI off: refused"
  out=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/admin-values.yaml" "${signin[@]}" 2>&1) && fail "admin.fxaSignIn without the accounts: renders"
  grep -qF "admin.fxaSignIn needs fxa.enabled" <<< "${out}" || fail "admin.fxaSignIn without the accounts: ${out}"
  check "admin.fxaSignIn: ADMIN_FXA_CLIENT_ID derived (sha256 of <namespace>/<release>/admin-oidc, 16 hex, the same on every render, another per release) or fxa.adminClientId; the redirect URL of admin.ingress.host; auth's, content's and the admin UI's env as compose's; refused without admin.allowed, a redirect URL (https://), the accounts; fxa.adminClientId refused without it"

  # admin.unconfirmedHours: ADMIN_UNCONFIRMED_HOURS with the accounts, only when set (0 too)
  unconfirmed() { helm template test-release "${CHART_DIR}" "$@" | manifests | jq -r '[.[] | select(.kind == "Deployment" and .metadata.name == "test-release-firefox-sync-admin")
    | .spec.template.spec.containers[0].env[] | select(.name == "ADMIN_UNCONFIRMED_HOURS") | .value] | join(",")'; }
  [[ "$(unconfirmed -f "${fxa}"):$(unconfirmed -f "${fxa}" --set admin.unconfirmedHours=0):$(unconfirmed -f "${fxa}" --set-string admin.unconfirmedHours=48):$(unconfirmed -f "${CHART_DIR}/ci/admin-values.yaml" --set admin.unconfirmedHours=48)" \
    == ":0:48:" ]] || fail "admin.unconfirmedHours: $(unconfirmed -f "${fxa}"):$(unconfirmed -f "${fxa}" --set admin.unconfirmedHours=0):$(unconfirmed -f "${fxa}" --set-string admin.unconfirmedHours=48)"
  for bad in admin.unconfirmedHours=-1 admin.unconfirmedHours=soon admin.unconfirmedHours=1000000; do
    out=$(fxa_render -f "${fxa}" --set "${bad}") && fail "${bad}: not refused by the schema"
    grep -qi 'schema' <<< "${out}" || fail "${bad}: refused, but not by the schema: ${out}"
  done
  check "admin.unconfirmedHours: ADMIN_UNCONFIRMED_HOURS with the accounts only when set (0, 48; none by default or without the accounts), -1, soon and 1000000 refused (the admin UI's hours fit a time.Duration)"
}

# the accounts' objects: the database, Redis, the keys, the auth pod and its init containers,
# the Sync server pointed to them
fxa_objects_lint() {
  local fxa="${CHART_DIR}/ci/fxa-values.yaml" out objs want name
  fxa_objs() { helm template test-release "${CHART_DIR}" -f "${fxa}" "$@" | manifests; }
  # fxa_auth_pod <helm args>: the auth Deployment's pod spec
  fxa_auth_pod() { fxa_objs "$@" | jq -c '.[] | select(.kind == "Deployment" and .metadata.name == "test-release-firefox-sync-fxa-auth") | .spec.template'; }
  fxa_inits() { jq -r '[.spec.initContainers[].name] | join(" ")' <<< "$1"; }

  # compose's order: the keys' owner (or the keys of fxa.keys.existingSecret), the database,
  # the migrations, the policy, Redis; the keys on their PVC (kept) or that Secret's copy
  out=$(fxa_auth_pod)
  [[ "$(fxa_inits "${out}")" == "keys-owner wait-db migrations policy wait-redis" ]] || fail "auth's init containers: $(fxa_inits "${out}")"
  [[ "$(fxa_auth_pod --set fxa.volumeOwnerInit=false | jq -r '[.spec.initContainers[].name] | join(" ")')" == "wait-db migrations policy wait-redis" ]] \
    || fail "fxa.volumeOwnerInit=false: auth's init containers: $(fxa_auth_pod --set fxa.volumeOwnerInit=false | jq -r '[.spec.initContainers[].name] | join(" ")')"
  out=$(fxa_auth_pod --set fxa.keys.existingSecret=my-keys)
  [[ "$(fxa_inits "${out}")" == "keys-copy wait-db migrations policy wait-redis" ]] || fail "fxa.keys.existingSecret: auth's init containers: $(fxa_inits "${out}")"
  jq -e '[.spec.volumes[] | select(.name == "fxa-keys" or .name == "fxa-keys-secret")] == [{name: "fxa-keys", emptyDir: {}}, {name: "fxa-keys-secret", secret: {secretName: "my-keys"}}]
    and (.spec.initContainers[0].securityContext.runAsUser == 10001)' <<< "${out}" > /dev/null || fail "fxa.keys.existingSecret: the keys' volumes: ${out}"
  grep -q 'for f in secret-key.json public-key.json vapid-keys.json openid-key.json; do' <<< "$(jq -r '.spec.initContainers[0].args[2]' <<< "${out}")" \
    || fail "keys-copy does not check the four keys"
  objs=$(fxa_objs)
  jq -e '[.[] | select(.kind == "PersistentVolumeClaim" and .metadata.name == "test-release-firefox-sync-fxa-keys")
    | [.metadata.annotations["helm.sh/resource-policy"], .spec.accessModes[0], .spec.resources.requests.storage]] == [["keep", "ReadWriteOnce", "1Gi"]]' <<< "${objs}" > /dev/null \
    || fail "no PVC test-release-firefox-sync-fxa-keys (keep, RWO, 1Gi)"
  [[ "$(fxa_objs --set fxa.keys.existingSecret=my-keys | jq '[.[] | select(.kind == "PersistentVolumeClaim" and (.metadata.name | endswith("-fxa-keys")))] | length')" == 0 ]] \
    || fail "fxa.keys.existingSecret: the PVC of the keys still rendered"
  check "auth's init containers keys-owner (keys-copy with fxa.keys.existingSecret, none with volumeOwnerInit=false), wait-db, migrations, policy, wait-redis; the keys' PVC kept"

  # wait-db logs in to nothing, as the Sync server's
  out=$(fxa_auth_pod)
  if jq -r '.spec.initContainers[] | select(.name == "wait-db") | tostring' <<< "${out}" | grep -qE 'secretKeyRef|PASSWORD'; then
    fail "auth's wait-db uses a password"
  fi
  jq -e '(.spec.containers[0] | .workingDir == "/fxa/packages/fxa-auth-server/dist/packages/fxa-auth-server" and .startupProbe.httpGet.path == "/__heartbeat__")
    and (.spec.initContainers[] | select(.name == "migrations") | .workingDir == "/fxa/packages/db-migrations")
    and (.spec.initContainers[] | select(.name == "policy") | .args == ["fxa-init"] and .image == "ghcr.io/porelli/firefox-sync:admin-latest")
    and (.metadata.annotations | (.["checksum/fxa-config"] | test("^[0-9a-f]{64}$")) and (.["checksum/secrets"] | test("^[0-9a-f]{64}$")))' <<< "${out}" > /dev/null \
    || fail "auth: working dirs, probe, policy or checksums: ${out}"
  # the migrations' command: compose's and the Quadlet's, verbatim (retried while the server
  # does not answer, not after a refused sign-in)
  local mig
  mig=$(jq -r '.spec.initContainers[] | select(.name == "migrations") | .args[2]' <<< "${out}")
  [[ "${mig}" == *'"Access denied for user"*) '* ]] || fail "auth's migrations retry a refused sign-in: ${mig}"
  grep -qF -- "command: [sh, -c, '${mig}']" "${REPO_ROOT}/compose/fxa.yml" || fail "auth's migrations are not compose's fxa-migrations: ${mig}"
  grep -qF -- "Exec=sh -c 'cd /fxa/packages/db-migrations && ${mig}'" "${REPO_ROOT}/config/quadlet/fxa/firefox-sync-fxa-migrations.container" \
    || fail "auth's migrations are not the Quadlet's firefox-sync-fxa-migrations: ${mig}"
  [[ "$(fxa_auth_pod --set existingSecret=mine | jq -r '.metadata.annotations | has("checksum/secrets")')" == false ]] || fail "existingSecret: checksum/secrets of a Secret the chart does not have"
  # the policy: your own server's policy user and its password, else FxA's user's pair
  fxa_policy_env() { jq -c '[.spec.initContainers[] | select(.name == "policy") | .env[] | select(.name | test("^FXA_(DB_ROOT|SIGNUP|MAX)"))
    | {(.name): (.value // .valueFrom.secretKeyRef.key)}] | add' <<< "$1"; }
  [[ "$(fxa_policy_env "${out}")" == '{"FXA_DB_ROOT_USER":"","FXA_DB_ROOT_PASSWORD":"","FXA_SIGNUPS":"allowlist","FXA_SIGNUP_ALLOWLIST":"@example.test,you@example.org","FXA_MAX_ACCOUNTS":"initial:unlimited"}' ]] \
    || fail "the policy's env: $(fxa_policy_env "${out}")"
  out=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/fxa-external-values.yaml" --set-string fxa.maxAccounts=5 | manifests \
    | jq -c '.[] | select(.kind == "Deployment" and .metadata.name == "test-release-firefox-sync-fxa-auth") | .spec.template')
  [[ "$(fxa_policy_env "${out}")" == '{"FXA_DB_ROOT_USER":"ffs_policy","FXA_DB_ROOT_PASSWORD":"FXA_MYSQL_POLICY_PASSWORD","FXA_SIGNUPS":"open","FXA_SIGNUP_ALLOWLIST":"","FXA_MAX_ACCOUNTS":"5"}' ]] \
    || fail "your own accounts server: the policy's env: $(fxa_policy_env "${out}")"
  jq -e '.spec.initContainers[] | select(.name == "wait-db") | .image == "docker.io/library/mariadb:lts" and (.args[0] | contains("mariadb-admin --connect-timeout=5 -h \"fxadb.example.test\" -P \"3306\" ping"))' <<< "${out}" > /dev/null \
    || fail "your own MariaDB server: wait-db"
  check "auth: wait-db without credentials; working dirs, heartbeat, checksums (checksum/secrets not with existingSecret); the policy's user (your own server's policyUser), signups, allowlist, max accounts"

  # the accounts database: compose's fxa-db for each backend, only bundled
  fxa_db_spec() { fxa_objs "$@" | jq -cS '.[] | select(.kind == "StatefulSet" and .metadata.name == "test-release-firefox-sync-fxa-db")
    | .spec.volumeClaimTemplates[0].metadata.name as $claim | .spec.template.spec.containers[0]
    | {image, args, env: [.env[] | {(.name): (.value // .valueFrom.secretKeyRef.key)}] | add, probe: .startupProbe.exec.command, mount: .volumeMounts[0], $claim}'; }
  # shellcheck disable=SC2016 # (compose's $$, literally)
  [[ "$(fxa_db_spec)" == '{"args":["mysqld","--event-scheduler=ON"],"claim":"data","env":{"MYSQL_ROOT_PASSWORD":"FXA_MYSQL_PASSWORD"},"image":"docker.io/library/mysql:lts","mount":{"mountPath":"/var/lib/mysql","name":"data","subPath":"data"},"probe":["sh","-c","MYSQL_PWD=${MYSQL_ROOT_PASSWORD} mysqladmin ping -h 127.0.0.1 --protocol=tcp -uroot --silent"]}' ]] \
    || fail "fxa-db (mysql): $(fxa_db_spec)"
  # compose's FXA_MYSQL_ARGS: mysql_native_password on a MySQL 8 pin alone (an accounts image
  # without mozilla/fxa#21554), after --event-scheduler=ON as in compose's command; the
  # defaults those of compose's FXA_MYSQL_IMAGE and FXA_MARIADB_IMAGE (mysql:lts, mariadb:lts)
  local native='["mysqld","--event-scheduler=ON","--mysql-native-password=ON","--authentication-policy=mysql_native_password"]' pin want
  for pin in docker.io/library/mysql:8 mysql:8.4 docker.io/library/mysql:8.4.7@sha256:00 docker.io/library/mysql:9 docker.io/library/mysql:9.7 docker.io/library/mysql:latest; do
    want='["mysqld","--event-scheduler=ON"]'
    [[ ${pin} =~ :8 ]] && want=${native}
    [[ "$(fxa_db_spec --set fxa.database.image.mysql="${pin}" | jq -c '.args')" == "${want}" ]] || fail "fxa-db on ${pin}: $(fxa_db_spec --set fxa.database.image.mysql="${pin}" | jq -c '.args'), not ${want}"
  done
  [[ "$(fxa_db_spec --set fxa.database.backend=mariadb --set fxa.database.image.mariadb=docker.io/library/mariadb:11 | jq -c '.args')" == '["mariadbd","--event-scheduler=ON"]' ]] \
    || fail "fxa-db on mariadb:11: not mariadbd --event-scheduler=ON"
  [[ "$(python3 -c 'import sys, yaml; i = yaml.safe_load(open(sys.argv[1]))["fxa"]["database"]["image"]; print(i["mysql"], i["mariadb"])' "${CHART_DIR}/values.yaml")" \
    == "docker.io/library/mysql:$(sed -n 's/^ *image: ${FXA_MYSQL_IMAGE:-mysql:\(.*\)}$/\1/p' "${REPO_ROOT}/compose/fxa-mysql.yml" | sort -u) docker.io/library/mariadb:$(sed -n 's/^ *image: ${FXA_MARIADB_IMAGE:-mariadb:\(.*\)}$/\1/p' "${REPO_ROOT}/compose/fxa-mariadb.yml" | sort -u)" ]] \
    || fail "fxa.database.image: not compose's FXA_MYSQL_IMAGE and FXA_MARIADB_IMAGE defaults"
  check "fxa-db: mysql:lts and mariadb:lts as compose's defaults; mysql_native_password only on a MySQL 8 pin (mysql:8, 8.4, 8.4.7@digest; none on 9, 9.7, latest, lts), as compose's FXA_MYSQL_ARGS"
  [[ "$(fxa_db_spec --set fxa.database.backend=mariadb)" == '{"args":["mariadbd","--event-scheduler=ON"],"claim":"data-mariadb","env":{"MARIADB_AUTO_UPGRADE":"true","MYSQL_ROOT_PASSWORD":"FXA_MYSQL_PASSWORD"},"image":"docker.io/library/mariadb:lts","mount":{"mountPath":"/var/lib/mysql","name":"data-mariadb","subPath":"data"},"probe":["healthcheck.sh","--connect","--innodb_initialized"]}' ]] \
    || fail "fxa-db (mariadb): $(fxa_db_spec --set fxa.database.backend=mariadb)"
  [[ "$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/fxa-external-values.yaml" | manifests | jq '[.[] | select(.metadata.name | test("-fxa-db$"))] | length')" == 0 ]] \
    || fail "your own accounts server: fxa-db rendered"
  # (a switch on a release with the bundled server: refused by checkFxaDbBackend, a lookup,
  # so tested in the e2e; here that it looks the StatefulSet up)
  if ! grep -qE '^\{\{- \$existing := lookup "apps/v1" "StatefulSet" \.Release\.Namespace \(include "firefox-sync\.fxaDbHost" \.\) \}\}$' "${CHART_DIR}/templates/_fxa.tpl" \
    || ! grep -qF '{{- include "firefox-sync.checkFxaDbBackend" . }}' "${CHART_DIR}/templates/_fxa.tpl"; then
    fail "checkFxaDbBackend does not look the accounts database's StatefulSet up"
  fi
  # the major guard of the bundled accounts database: Sync's dbMajorChange (tests/helm.sh lint
  # checks its pairs) on the running db container's image, refused unless
  # fxa.database.allowMajorUpgrade (a boolean); not a copy of its own
  local guard
  guard=$(awk '/define "firefox-sync.checkFxaDbBackend"/ {p = 1; next} p && /^\{\{- define / {p = 0} p' "${CHART_DIR}/templates/_fxa.tpl")
  grep -qF 'include "firefox-sync.dbMajorChange" (dict "old" $running "new" $image)' <<< "${guard}" \
    && grep -qF '(not .Values.fxa.database.allowMajorUpgrade)' <<< "${guard}" \
    && grep -qF 'range $existing.spec.template.spec.containers' <<< "${guard}" \
    || fail "checkFxaDbBackend: no major guard with dbMajorChange and fxa.database.allowMajorUpgrade"
  [[ "$(grep -c 'define "firefox-sync.dbMajorChange"' "${CHART_DIR}"/templates/*.tpl | awk -F: '{n += $2} END {print n}')" == 1 ]] || fail "dbMajorChange defined more than once"
  if helm template test-release "${CHART_DIR}" -f "${fxa}" --set fxa.database.allowMajorUpgrade=yes > /dev/null 2>&1; then
    fail "fxa.database.allowMajorUpgrade=yes not refused by the schema"
  fi
  [[ "$(helm show values "${CHART_DIR}" | python3 -c 'import sys, yaml; print(yaml.safe_load(sys.stdin)["fxa"]["database"]["allowMajorUpgrade"])')" == False ]] \
    || fail "fxa.database.allowMajorUpgrade not false by default"
  check "fxa-db: compose's command, env and healthcheck (mysql, mariadb), a volume each (data, data-mariadb: compose's fxa-db, fxa-db-mariadb), data in subPath data; none with your own server; the major guard (dbMajorChange, fxa.database.allowMajorUpgrade false, a boolean)"

  # Redis: the image's user, its data in memory
  jq -e '.[] | select(.kind == "Deployment" and .metadata.name == "test-release-firefox-sync-fxa-redis") | .spec | .strategy.type == "Recreate"
    and (.template.spec | .securityContext.runAsUser == 999 and .securityContext.runAsGroup == 1000 and .securityContext.fsGroup == 1000
    and .volumes == [{name: "data", emptyDir: {}}] and .containers[0].readinessProbe.exec.command == ["redis-cli", "ping"])' <<< "${objs}" > /dev/null \
    || fail "fxa-redis: not Recreate, uid 999/1000 with /data in an emptyDir and redis-cli ping"
  check "fxa-redis: Recreate, the image's redis (999, 1000), /data an emptyDir, redis-cli ping"
  # a new Redis pod when the chart's Secret (its FXA_REDIS_PASSWORD) changes; none with existingSecret
  redis_annotations() { jq -c '[.[] | select(.kind == "Deployment" and .metadata.name == "test-release-firefox-sync-fxa-redis") | .spec.template.metadata.annotations // {} | keys]'; }
  [[ "$(redis_annotations <<< "${objs}")" == '[["checksum/secrets"]]' ]] || fail "fxa-redis: not checksum/secrets alone: $(redis_annotations <<< "${objs}")"
  [[ "$(fxa_objs --set existingSecret=mine | redis_annotations)" == '[[]]' ]] || fail "fxa-redis: checksum/secrets with existingSecret"
  check "fxa-redis: checksum/secrets (none with existingSecret)"

  # Redis' password (chart-only): read by redis-server from stdin, never in the pod spec;
  # REDISCLI_AUTH of the probes and wait-redis, each <SUBSYSTEM>_REDIS_PASSWORD of auth
  # (each byte \xHH in Redis' quotes: a password with spaces or quotes, tested in the e2e)
  # shellcheck disable=SC2016 # (the script, literally)
  jq -e --arg script $'pass=$(printf %s "$REDISCLI_AUTH" | od -An -v -tx1 | tr -d \' \\n\' | sed \'s/../\\\\x&/g\')\nexec redis-server - <<EOF\nrequirepass "$pass"\nEOF\n' \
    '.[] | select(.kind == "Deployment" and .metadata.name == "test-release-firefox-sync-fxa-redis") | .spec.template.spec.containers[0]
    | .env == [{name: "REDISCLI_AUTH", valueFrom: {secretKeyRef: {name: "test-release-firefox-sync", key: "FXA_REDIS_PASSWORD"}}}]
    and .command == ["/bin/sh", "-c"] and .args == [$script]' <<< "${objs}" > /dev/null \
    || fail "fxa-redis: not started with requirepass from stdin and REDISCLI_AUTH"
  out=$(fxa_auth_pod)
  [[ "$(jq -r '[.spec.initContainers[] | select(.name == "wait-redis") | .env[] | "\(.name)=\(.valueFrom.secretKeyRef.key)"] | join(" ")' <<< "${out}")" == "REDISCLI_AUTH=FXA_REDIS_PASSWORD" ]] \
    || fail "wait-redis without REDISCLI_AUTH"
  [[ "$(jq -r '[.spec.containers[0].env[] | select(.name | endswith("REDIS_HOST") or endswith("REDIS_PASSWORD")) | "\(.name)=\(.value // .valueFrom.secretKeyRef.key)"] | join(" ")' <<< "${out}")" == \
    "$(for v in REDIS ACCESS_TOKEN_REDIS REFRESH_TOKEN_REDIS CUSTOMS_REDIS RATELIMIT_REDIS METRICS_REDIS AUTH_CACHE_REDIS RECOVERY_PHONE_REDIS PASSKEY_REDIS; do
      printf '%s_HOST=test-release-firefox-sync-fxa-redis %s_PASSWORD=FXA_REDIS_PASSWORD\n' "${v}" "${v}"; done | paste -sd' ' -)" ]] \
    || fail "auth's Redis hosts and passwords: $(jq -c '[.spec.containers[0].env[] | select(.name | test("REDIS"))]' <<< "${out}")"
  check "fxa-redis: requirepass FXA_REDIS_PASSWORD (from stdin, not in the spec); auth's nine <SUBSYSTEM>_REDIS_PASSWORD, REDISCLI_AUTH of wait-redis and the probes"

  # fxa.networkPolicy (chart-only): Redis from the accounts' servers, the database from them
  # and the admin UI; none with it off; no fxa-db one with your own server
  fxa_policies() { fxa_objs "$@" | jq -c '[.[] | select(.kind == "NetworkPolicy") | {name: .metadata.name, to: .spec.podSelector.matchLabels["app.kubernetes.io/component"],
    types: .spec.policyTypes, from: .spec.ingress[0].from[0].podSelector | [.matchLabels["app.kubernetes.io/instance"], .matchExpressions[0].values],
    ports: [.spec.ingress[0].ports[] | "\(.protocol)/\(.port)"]}]'; }
  [[ "$(fxa_policies)" == '[{"name":"test-release-firefox-sync-fxa-redis","to":"fxa-redis","types":["Ingress"],"from":["test-release",["fxa-auth","fxa-content","fxa-profile","admin"]],"ports":["TCP/6379"]},{"name":"test-release-firefox-sync-fxa-db","to":"fxa-db","types":["Ingress"],"from":["test-release",["fxa-auth","fxa-profile","admin"]],"ports":["TCP/3306"]}]' ]] \
    || fail "the NetworkPolicies: $(fxa_policies)"
  [[ "$(fxa_policies --set admin.enabled=false | jq -c '[.[].from[1]]')" == '[["fxa-auth","fxa-content","fxa-profile"],["fxa-auth","fxa-profile"]]' ]] \
    || fail "admin.enabled=false: the admin UI still allowed to fxa-redis or fxa-db"
  # (the backups: the accounts' dump, as root, from the backup CronJob's pods)
  [[ "$(fxa_policies --set backup.enabled=true | jq -c '[.[].from[1]]')" == '[["fxa-auth","fxa-content","fxa-profile","admin"],["fxa-auth","fxa-profile","admin","backup"]]' ]] \
    || fail "backup.enabled: the backups not allowed to fxa-db (alone): $(fxa_policies --set backup.enabled=true | jq -c '[.[].from[1]]')"
  [[ "$(fxa_policies --set fxa.networkPolicy.enabled=false)" == '[]' ]] || fail "fxa.networkPolicy.enabled=false: NetworkPolicies rendered"
  [[ "$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/fxa-external-values.yaml" | manifests | jq -r '[.[] | select(.kind == "NetworkPolicy") | .metadata.name] | join(" ")')" == \
    test-release-firefox-sync-fxa-redis ]] || fail "your own accounts server: not the fxa-redis NetworkPolicy alone"
  check "fxa.networkPolicy: fxa-redis from fxa-auth, fxa-content, fxa-profile; fxa-db from fxa-auth, fxa-profile; both from the admin UI (when on), fxa-db from the backups (when on); none with it off, no fxa-db one with your own server"

  # fxa.networkPolicy.servers (off by default): the public servers from the Ingress controller
  # (one peer of its selectors), the release's pods that call them and extraFrom alone
  local ic=(--set fxa.networkPolicy.servers.enabled=true
    --set-json 'fxa.networkPolicy.servers.ingressController={"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"ingress-nginx"}},"podSelector":{"matchLabels":{"app.kubernetes.io/name":"ingress-nginx"}}}')
  server_policies() { fxa_objs "$@" | jq -c '[.[] | select(.kind == "NetworkPolicy" and (.metadata.name | test("-fxa-(redis|db)$") | not))
    | {to: .spec.podSelector.matchLabels["app.kubernetes.io/component"], from: [.spec.ingress[0].from[] | if .podSelector.matchLabels["app.kubernetes.io/instance"] == "test-release" and (has("namespaceSelector") | not)
      then {release: .podSelector.matchExpressions[0].values} else . end], ports: [.spec.ingress[0].ports[] | .port]}]'; }
  [[ "$(server_policies)" == '[]' ]] || fail "fxa.networkPolicy.servers off by default: $(server_policies)"
  local controller='{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"ingress-nginx"}},"podSelector":{"matchLabels":{"app.kubernetes.io/name":"ingress-nginx"}}}'
  [[ "$(server_policies "${ic[@]}")" == "[{\"to\":\"fxa-auth\",\"from\":[{\"release\":[\"fxa-content\",\"fxa-profile\",\"syncstorage\",\"admin\"]},${controller}],\"ports\":[9000]},{\"to\":\"fxa-content\",\"from\":[{\"release\":[\"admin\"]},${controller}],\"ports\":[3030]},{\"to\":\"fxa-profile\",\"from\":[{\"release\":[\"fxa-auth\",\"fxa-content\",\"admin\"]},${controller}],\"ports\":[1111,1112,1114]},{\"to\":\"fxa-pairing\",\"from\":[{\"release\":[\"admin\"]},${controller}],\"ports\":[8000]}]" ]] \
    || fail "fxa.networkPolicy.servers: $(server_policies "${ic[@]}")"
  # (without the admin UI and pairing: content's from the controller alone, no pairing one;
  # podSelector alone: the controller's pods in the release's namespace; extraFrom as given)
  [[ "$(server_policies "${ic[@]}" --set admin.enabled=false --set fxa.pairing.enabled=false --set-json 'fxa.networkPolicy.servers.ingressController.namespaceSelector={}' \
    --set-json 'fxa.networkPolicy.servers.extraFrom=[{"ipBlock":{"cidr":"10.0.0.0/24"}}]' | jq -c '[.[] | [.to, .from]]')" \
    == '[["fxa-auth",[{"release":["fxa-content","fxa-profile","syncstorage"]},{"podSelector":{"matchLabels":{"app.kubernetes.io/name":"ingress-nginx"}}},{"ipBlock":{"cidr":"10.0.0.0/24"}}]],["fxa-content",[{"podSelector":{"matchLabels":{"app.kubernetes.io/name":"ingress-nginx"}}},{"ipBlock":{"cidr":"10.0.0.0/24"}}]],["fxa-profile",[{"release":["fxa-auth","fxa-content"]},{"podSelector":{"matchLabels":{"app.kubernetes.io/name":"ingress-nginx"}}},{"ipBlock":{"cidr":"10.0.0.0/24"}}]]]' ]] \
    || fail "fxa.networkPolicy.servers without the admin UI and pairing, extraFrom: $(server_policies "${ic[@]}" --set admin.enabled=false --set fxa.pairing.enabled=false)"
  # (refused: no selector, or selectors that select everything; fxa.networkPolicy.enabled off)
  fxa_refused "fxa.networkPolicy.servers.enabled needs fxa.networkPolicy.servers.ingressController.namespaceSelector or .podSelector" -f "${fxa}" \
    --set fxa.networkPolicy.servers.enabled=true
  fxa_refused "fxa.networkPolicy.servers.enabled needs fxa.networkPolicy.servers.ingressController.namespaceSelector or .podSelector" -f "${fxa}" \
    --set fxa.networkPolicy.servers.enabled=true --set-json 'fxa.networkPolicy.servers.ingressController={"namespaceSelector":{"matchLabels":{}},"podSelector":{"matchExpressions":[]}}'
  fxa_refused "fxa.networkPolicy.servers.enabled needs fxa.networkPolicy.enabled" -f "${fxa}" "${ic[@]}" --set fxa.networkPolicy.enabled=false
  for bad in fxa.networkPolicy.servers.ingressController.nameSpaceSelector.matchLabels.a=b fxa.networkPolicy.servers.ingressController.podSelector.labels.a=b \
    fxa.networkPolicy.servers.enable=true; do
    out=$(fxa_render -f "${fxa}" --set "${bad}") && fail "${bad}: not refused by the schema"
    grep -qi 'schema' <<< "${out}" || fail "${bad}: refused, but not by the schema: ${out}"
  done
  out=$(fxa_render -f "${fxa}" "${ic[@]}" --set-json 'fxa.networkPolicy.servers.extraFrom=[{}]') && fail "extraFrom [{}] (every pod): not refused by the schema"
  # (matchExpressions as Kubernetes has them: [{}] or another operator refused; one with its key selects)
  for bad in '[{}]' '[{"key":"app","operator":"Is","values":["x"]}]' '[{"operator":"Exists"}]'; do
    out=$(fxa_render -f "${fxa}" --set fxa.networkPolicy.servers.enabled=true --set-json "fxa.networkPolicy.servers.ingressController.podSelector.matchExpressions=${bad}") \
      && fail "ingressController.podSelector.matchExpressions=${bad}: renders"
    grep -qi 'schema' <<< "${out}" || fail "matchExpressions=${bad}: refused, but not by the schema: ${out}"
  done
  [[ "$(server_policies --set fxa.networkPolicy.servers.enabled=true --set-json 'fxa.networkPolicy.servers.ingressController.podSelector.matchExpressions=[{"key":"app","operator":"In","values":["traefik"]}]' \
    | jq -c '.[0].from[1]')" == '{"podSelector":{"matchExpressions":[{"key":"app","operator":"In","values":["traefik"]}]}}' ]] \
    || fail "ingressController.podSelector.matchExpressions with a key: not the controller's peer"
  # (the e2e's values: Traefik in ffs-test-ingress, the tests' pods by their label)
  [[ "$(helm template test-release "${CHART_DIR}" -f "${REPO_ROOT}/tests/helm/fxa-values.yaml" --set fxa.enabled=true | manifests \
    | jq -c '[.[] | select(.kind == "NetworkPolicy") | .metadata.name | sub("test-release-firefox-sync-"; "")]')" == '["fxa-redis","fxa-db","fxa-auth","fxa-content","fxa-profile","fxa-pairing"]' ]] \
    || fail "tests/helm/fxa-values.yaml: not the servers' NetworkPolicies"
  check "fxa.networkPolicy.servers (off by default): auth from content, profile, the Sync server, the admin UI; content, pairing from the admin UI; profile from auth, content, the admin UI; each from the Ingress controller (one peer: namespaceSelector and/or podSelector) and extraFrom; refused without a selector, with selectors of everything, or with fxa.networkPolicy.enabled off"

  # the scripts of config/fxa, byte for byte, in the ConfigMap
  local file
  for file in content-server.js oauth-clients.js; do
    cmp -s "${CHART_DIR}/files/fxa/${file}" "${REPO_ROOT}/config/fxa/${file}" || fail "files/fxa/${file} is not config/fxa/${file}"
    jq -j --arg f "${file}" '.[] | select(.kind == "ConfigMap" and .metadata.name == "test-release-firefox-sync-fxa-config") | .data[$f]' <<< "${objs}" \
      | cmp -s - "${REPO_ROOT}/config/fxa/${file}" || fail "the ConfigMap's ${file} is not config/fxa/${file}"
  done
  check "ConfigMap fxa-config: config/fxa/content-server.js and oauth-clients.js as they are"

  # the Sync server and the admin UI on these accounts
  [[ "$(jq -r '[.[] | select(.kind == "Deployment") | .spec.template.spec | (.initContainers // [])[], .containers[] | .env[]?
    | select(.name | test("FXA_(OAUTH_SERVER_URL|EMAIL_DOMAIN)$")) | "\(.name)=\(.value)"] | unique | join(" ")' <<< "${objs}")" == \
    "FXA_EMAIL_DOMAIN=api.example.test FXA_OAUTH_SERVER_URL=http://test-release-firefox-sync-fxa-auth:9000/v1 SYNC_TOKENSERVER__FXA_EMAIL_DOMAIN=api.example.test SYNC_TOKENSERVER__FXA_OAUTH_SERVER_URL=http://test-release-firefox-sync-fxa-auth:9000/v1" ]] \
    || fail "the Sync server and the admin UI not on the accounts' auth server"
  check "the Sync server (migrate, syncstorage) and the admin UI: FXA_OAUTH_SERVER_URL the chart's auth, FXA_EMAIL_DOMAIN the host of fxa.authUrl"

  # fxa.extraCaCerts (chart-only): the ConfigMap at /ffs-ca, NODE_EXTRA_CA_CERTS
  out=$(fxa_auth_pod --set fxa.extraCaCerts.configMap=my-ca --set fxa.extraCaCerts.key=root.pem)
  jq -e '(.spec.containers[0] | (.env[] | select(.name == "NODE_EXTRA_CA_CERTS") | .value == "/ffs-ca/root.pem")
    and ([.volumeMounts[] | select(.name == "ffs-ca")] == [{name: "ffs-ca", mountPath: "/ffs-ca", readOnly: true}]))
    and ([.spec.volumes[] | select(.name == "ffs-ca")] == [{name: "ffs-ca", configMap: {name: "my-ca"}}])' <<< "${out}" > /dev/null \
    || fail "fxa.extraCaCerts: auth without /ffs-ca or NODE_EXTRA_CA_CERTS"
  [[ "$(fxa_auth_pod | jq '[.. | objects | select(.name? == "ffs-ca" or .name? == "NODE_EXTRA_CA_CERTS")] | length')" == 0 ]] || fail "no fxa.extraCaCerts: /ffs-ca rendered"
  check "fxa.extraCaCerts: auth's NODE_EXTRA_CA_CERTS=/ffs-ca/<key>, the ConfigMap at /ffs-ca; nothing without it"

  # the accounts' pages (compose's fxa-content) and profiles (fxa-profile, -worker, -static,
  # and img-proxy, chart-only) of ci/fxa-values.yaml
  fxa_pod() { fxa_objs "${@:2}" | jq -c --arg n "test-release-firefox-sync-fxa-$1" '.[] | select(.kind == "Deployment" and .metadata.name == $n) | .spec.template'; }
  # fxa_env <pod> <container>: its env, a line each, NAME=value or NAME=secret:KEY
  fxa_env() { jq -r --arg c "$2" '.spec.containers[] | select(.name == $c) | (.env // [])[] | "\(.name)=\(.value // ("secret:" + .valueFrom.secretKeyRef.key))"' <<< "$1"; }
  local content profile heartbeat
  heartbeat='http://test-release-firefox-sync-fxa-auth:9000/__heartbeat__'
  content=$(fxa_pod content)
  [[ "$(fxa_inits "${content}")" == wait-accounts ]] || fail "content's init containers: $(fxa_inits "${content}")"
  jq -e --arg a "${heartbeat}" '.spec.initContainers[0] | .image == "ghcr.io/porelli/firefox-sync:fxa-mono-latest" and (has("env") | not) and .args[0:2] == ["node", "-e"]
    and .args[3:] == [$a, "http://test-release-firefox-sync-fxa-profile:1111/__heartbeat__"] and .securityContext.runAsUser == 10001' <<< "${content}" > /dev/null \
    || fail "content's wait-accounts: $(jq -c '.spec.initContainers[0]' <<< "${content}")"
  jq -e '.spec.containers[0] | .name == "content" and .workingDir == "/fxa/packages/fxa-content-server"
    and .args == ["sh", "-c", "node /fxa-config/content-server.js /tmp/content-server.json && exec node server/bin/fxa-content-server.js"]
    and (.securityContext | has("readOnlyRootFilesystem") | not) and .ports == [{name: "http", containerPort: 3030}]
    and ([.startupProbe, .readinessProbe, .livenessProbe] | map([.httpGet.path, .httpGet.port, .periodSeconds, .timeoutSeconds, .failureThreshold]))
      == [["/__heartbeat__", "http", 15, 10, 40], ["/__heartbeat__", "http", 15, 10, 5], ["/__heartbeat__", "http", 15, 10, 5]]
    and .volumeMounts == [{name: "fxa-config", mountPath: "/fxa-config", readOnly: true}]' <<< "${content}" > /dev/null \
    || fail "content: $(jq -c '.spec.containers[0] | del(.env)' <<< "${content}")"
  want="NODE_ENV=production CONFIG_FILES=/tmp/content-server.json CONTENT_SESSION_SECRET=secret:FXA_CONTENT_SESSION_SECRET PUBLIC_URL=https://accounts.example.test"
  want+=" FXA_URL=https://api.example.test FXA_OAUTH_URL=https://api.example.test FXA_PROFILE_URL=https://profile.example.test FXA_PROFILE_IMAGES_URL=https://profile.example.test/img"
  want+=" SYNC_TOKENSERVER_URL=https://sync.example.test PAIRING_SERVER_BASE_URI=wss://pairing.example.test SERVICES_WITH_EMAIL_VERIFICATION=32aaeb6f1c21316a,"
  want+=" FLOW_ID_KEY=secret:FXA_FLOW_ID_KEY FEATURE_FLAGS_REDIS_HOST=test-release-firefox-sync-fxa-redis REDIS_HOST=test-release-firefox-sync-fxa-redis"
  want+=" REDIS_PASSWORD=secret:FXA_REDIS_PASSWORD GEODB_ENABLED=false"
  [[ "$(fxa_env "${content}" content | paste -sd' ' -)" == "${want}" ]] || fail "content's env: $(fxa_env "${content}" content | paste -sd' ' -)"
  local signin=(--set admin.fxaSignIn=true --set admin.allowed.users=@example.test --set admin.oidc.redirectUrl=https://admin.example.test/auth/callback)
  [[ "$(fxa_env "$(fxa_pod content --set fxa.pairing.enabled=false --set fxa.pairing.url= --set fxa.adminClientId=0123456789abcdef "${signin[@]}")" content | grep -E '^(PAIRING|SERVICES)' | paste -sd' ' -)" == \
    "PAIRING_SERVER_BASE_URI=wss://channelserver.services.mozilla.com SERVICES_WITH_EMAIL_VERIFICATION=32aaeb6f1c21316a,0123456789abcdef" ]] \
    || fail "content without pairing, with admin.fxaSignIn and fxa.adminClientId: $(fxa_env "$(fxa_pod content --set fxa.pairing.enabled=false --set fxa.pairing.url= --set fxa.adminClientId=0123456789abcdef "${signin[@]}")" content | grep -E '^(PAIRING|SERVICES)')"
  jq -e '[.[] | select(.kind == "Service" and .metadata.name == "test-release-firefox-sync-fxa-content") | .spec.ports] == [[{name: "http", port: 3030, targetPort: "http"}]]' <<< "${objs}" > /dev/null \
    || fail "no Service test-release-firefox-sync-fxa-content, http 3030"
  check "content: wait-accounts (auth's and profile's heartbeats, no env), compose's command, env (REDIS_PASSWORD too), workingDir and healthcheck, no readOnlyRootFilesystem; Service http 3030"

  profile=$(fxa_pod profile)
  [[ "$(fxa_inits "${profile}")" == "images-owner images-seed wait-auth" ]] || fail "profile's init containers: $(fxa_inits "${profile}")"
  [[ "$(fxa_inits "$(fxa_pod profile --set fxa.volumeOwnerInit=false)")" == "images-seed wait-auth" ]] \
    || fail "fxa.volumeOwnerInit=false: profile's init containers: $(fxa_inits "$(fxa_pod profile --set fxa.volumeOwnerInit=false)")"
  jq -e --arg a "${heartbeat}" '(.spec.initContainers | map({(.name): .}) | add) as $i
    | ($i["images-owner"] | .args == ["chown", "10001:10001", "/images"] and .securityContext.runAsUser == 0 and .securityContext.capabilities == {drop: ["ALL"], add: ["CHOWN"]})
    and ($i["images-seed"] | .args == ["find", "/fxa/packages/fxa-profile-server/var/public", "-mindepth", "1", "-maxdepth", "1", "-exec", "cp", "-an", "{}", "/images/", ";"] and .securityContext.runAsUser == 10001 and (has("env") | not))
    and ([$i["images-owner"], $i["images-seed"]] | map(.volumeMounts) == [[{name: "images", mountPath: "/images"}], [{name: "images", mountPath: "/images"}]])
    and ($i["wait-auth"] | .args[0:2] == ["node", "-e"] and .args[3:] == [$a] and (has("env") | not))' <<< "${profile}" > /dev/null \
    || fail "profile's init containers: $(jq -c '.spec.initContainers' <<< "${profile}")"
  # name, workingDir, args, ports, probes, mounts
  [[ "$(jq -c '[.spec.containers[] | [.name, .workingDir, .args, [.ports[]? | "\(.name)/\(.containerPort)"],
      ([.startupProbe, .readinessProbe, .livenessProbe] | map((if .httpGet then "\(.httpGet.port)\(.httpGet.path)" elif .tcpSocket then "tcp/\(.tcpSocket.port)" else "exec" end)
        + " \(.periodSeconds),\(.timeoutSeconds),\(.failureThreshold)")),
      [.volumeMounts[] | "\(.name):\(.mountPath)\(if .readOnly then ":ro" else "" end)"]]]' <<< "${profile}")" == \
    '[["profile","/fxa/packages/fxa-profile-server",["node","bin/server.js"],["http/1111"],["http/__heartbeat__ 15,10,40","http/__heartbeat__ 15,10,5","http/__heartbeat__ 15,10,5"],["images:/fxa/packages/fxa-profile-server/var/public"]],["profile-worker","/fxa/packages/fxa-profile-server",["node","bin/worker.js"],[],["exec 15,10,40","exec 15,10,5","exec 15,10,5"],["images:/fxa/packages/fxa-profile-server/var/public"]],["profile-static","/fxa/packages/fxa-profile-server",["node","bin/_static.js"],["static/1112"],["static/a/00000000000000000000000000000000 15,10,40","static/a/00000000000000000000000000000000 15,10,5","static/a/00000000000000000000000000000000 15,10,5"],["images:/fxa/packages/fxa-profile-server/var/public:ro"]],["img-proxy",null,["node","/fxa-config/img-proxy.js"],["img/1114"],["img/img/a/00000000000000000000000000000000 15,10,40","img/img/a/00000000000000000000000000000000 15,10,5","tcp/img 15,10,5"],["fxa-config:/fxa-config:ro"]]]' ]] \
    || fail "profile's containers: $(jq -c '[.spec.containers[] | del(.env)]' <<< "${profile}")"
  # the worker on the pod's loopback alone (chart-only: compose's has a network of its own),
  # its probes compose's healthcheck on 127.0.0.1 (an httpGet goes to the pod's IP)
  jq -e --arg c "fetch('http://127.0.0.1:1113/__heartbeat__').then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))" '.spec.containers[] | select(.name == "profile-worker")
    | [.startupProbe, .readinessProbe, .livenessProbe] | map(.exec.command) == [["node", "-e", $c], ["node", "-e", $c], ["node", "-e", $c]]' <<< "${profile}" > /dev/null \
    || fail "profile-worker's probes: $(jq -c '.spec.containers[] | select(.name == "profile-worker") | [.startupProbe, .readinessProbe, .livenessProbe]' <<< "${profile}")"
  # shellcheck disable=SC2016 # (the regex, literally)
  want='NODE_ENV=production HOST=0.0.0.0 DB=mysql MYSQL_HOST=test-release-firefox-sync-fxa-db MYSQL_PORT=3306 MYSQL_USERNAME=root MYSQL_PASSWORD=secret:FXA_MYSQL_PASSWORD'
  want+=' PUBLIC_URL=https://profile.example.test AUTH_SERVER_URL=http://test-release-firefox-sync-fxa-auth:9000/v1 OAUTH_SERVER_URL=http://test-release-firefox-sync-fxa-auth:9000/v1'
  want+=' AUTH_SECRET_BEARER_TOKEN=secret:FXA_PROFILE_SECRET REDIS_HOST=test-release-firefox-sync-fxa-redis REDIS_PASSWORD=secret:FXA_REDIS_PASSWORD WORKER_URL=http://127.0.0.1:1113'
  want+=' IMG=local IMG_URL=https://profile.example.test/img/a/{id} IMG_PROVIDERS_FXA=^https://profile.example.test/img/a/[0-9a-f]{32}$ EVENTS_ENABLED=false'
  [[ "$(fxa_env "${profile}" profile | paste -sd' ' -)" == "${want}" ]] || fail "profile's env: $(fxa_env "${profile}" profile | paste -sd' ' -)"
  [[ "$(fxa_env "${profile}" profile-worker | paste -sd' ' -)" == "NODE_ENV=production WORKER_HOST=127.0.0.1 IMG=local" ]] || fail "profile-worker's env: $(fxa_env "${profile}" profile-worker | paste -sd' ' -)"
  [[ "$(fxa_env "${profile}" profile-static | paste -sd' ' -)" == "NODE_ENV=production HOST=0.0.0.0 IMG=local" ]] || fail "profile-static's env: $(fxa_env "${profile}" profile-static | paste -sd' ' -)"
  [[ -z "$(fxa_env "${profile}" img-proxy)" ]] || fail "img-proxy has an env"
  jq -e '(.spec.containers[] | select(.name == "img-proxy") | .securityContext.readOnlyRootFilesystem == true)
    and .spec.volumes == [{name: "images", persistentVolumeClaim: {claimName: "test-release-firefox-sync-fxa-profile-images"}}, {name: "fxa-config", configMap: {name: "test-release-firefox-sync-fxa-config"}}]
    and (.metadata.annotations | (.["checksum/fxa-config"] | test("^[0-9a-f]{64}$")) and (.["checksum/secrets"] | test("^[0-9a-f]{64}$")))' <<< "${profile}" > /dev/null \
    || fail "profile: img-proxy's read-only root, the volumes or the checksums: $(jq -c '[.spec.volumes, .metadata.annotations]' <<< "${profile}")"
  jq -e '[.[] | select(.kind != "Ingress") | select(.metadata.name == "test-release-firefox-sync-fxa-profile" or .metadata.name == "test-release-firefox-sync-fxa-profile-images")
    | if .kind == "Service" then .spec.ports elif .kind == "Deployment" then .spec.strategy.type
      else [.metadata.annotations["helm.sh/resource-policy"], .spec.accessModes[0], .spec.resources.requests.storage] end]
    == [["keep", "ReadWriteOnce", "1Gi"], [{name: "http", port: 1111, targetPort: "http"}, {name: "static", port: 1112, targetPort: "static"}, {name: "img", port: 1114, targetPort: "img"}], "Recreate"]' <<< "${objs}" > /dev/null \
    || fail "the profile's PVC (keep, RWO, 1Gi), Service (http 1111, static 1112, img 1114) or Recreate"
  [[ "$(fxa_pod content --set existingSecret=mine | jq -r '.metadata.annotations | has("checksum/secrets")')$(fxa_pod profile --set existingSecret=mine | jq -r '.metadata.annotations | has("checksum/secrets")')" == falsefalse ]] \
    || fail "existingSecret: checksum/secrets on content or profile"
  check "profile: images-owner (not with volumeOwnerInit=false), images-seed, wait-auth; profile, -worker, -static with compose's commands, env (REDIS_PASSWORD too), workingDir and healthchecks, the avatars' PVC (kept, read-only for static); img-proxy without env, read-only, liveness its own port; the worker on 127.0.0.1 alone (exec probes); Service http 1111, static 1112, img 1114"

  # img-proxy.js in the ConfigMap; the memory requests of the values; extraCaCerts
  jq -j '.[] | select(.kind == "ConfigMap" and .metadata.name == "test-release-firefox-sync-fxa-config") | .data["img-proxy.js"]' <<< "${objs}" \
    | cmp -s - "${CHART_DIR}/files/fxa/img-proxy.js" || fail "the ConfigMap's img-proxy.js is not files/fxa/img-proxy.js"
  [[ "$(jq -r '[(.spec.initContainers[], .spec.containers[]) | "\(.name)=\(.resources.requests.memory // "none")"] | join(" ")' <<< "${content}") $(jq -r '[(.spec.initContainers[], .spec.containers[]) | "\(.name)=\(.resources.requests.memory // "none")"] | join(" ")' <<< "${profile}")" == \
    "wait-accounts=none content=512Mi images-owner=none images-seed=none wait-auth=none profile=256Mi profile-worker=128Mi profile-static=64Mi img-proxy=32Mi" ]] \
    || fail "the memory requests of content and profile"
  for name in content profile; do
    out=$(fxa_pod "${name}" --set fxa.extraCaCerts.configMap=my-ca --set fxa.extraCaCerts.key=root.pem)
    jq -e --arg c "${name}" '(.spec.containers[] | select(.name == $c) | (.env[] | select(.name == "NODE_EXTRA_CA_CERTS") | .value == "/ffs-ca/root.pem")
      and ([.volumeMounts[] | select(.name == "ffs-ca")] == [{name: "ffs-ca", mountPath: "/ffs-ca", readOnly: true}]))
      and ([.spec.volumes[] | select(.name == "ffs-ca")] == [{name: "ffs-ca", configMap: {name: "my-ca"}}])' <<< "${out}" > /dev/null \
      || fail "fxa.extraCaCerts: ${name} without /ffs-ca or NODE_EXTRA_CA_CERTS"
  done
  check "img-proxy.js in the ConfigMap; memory requests content 512Mi, profile 256Mi, -worker 128Mi, -static 64Mi, img-proxy 32Mi; fxa.extraCaCerts in content and profile"
}

fxa_base_parity() {
  local base base_dir mask values name diffs old new
  base=$(mktemp -d)
  if [[ -n "${PARITY_BASE_CHART:-}" ]]; then
    base_dir=$(cd "${PARITY_BASE_CHART}" && pwd) || fail "PARITY_BASE_CHART ${PARITY_BASE_CHART}: no such directory"
  elif git -C "${REPO_ROOT}" archive "${PARITY_BASE}" charts/firefox-sync 2> /dev/null | tar -x -C "${base}"; then
    base_dir="${base}/charts/firefox-sync"
  else
    rm -rf "${base}"
    fail "chart 0.1.0 (${PARITY_BASE}) not in this checkout: set PARITY_BASE_CHART to it extracted (git archive ${PARITY_BASE} charts/firefox-sync | tar -x -C <dir>)"
  fi
  [[ "$(sed -n 's/^version: //p' "${base_dir}/Chart.yaml")" == 0.1.0 ]] || fail "${base_dir}: not chart 0.1.0"
  # (the Secret's data masked: its generated values differ on every render, and so does the
  # admin UI's checksum/admin-secrets, the sha256 of that data; its keys are compared. The
  # MySQL probes too: since 0.1.0 their password is in mysqladmin's environment, not its
  # arguments, as compose's healthchecks. And backup.sh's text: the chart ships compose's
  # config/backup/backup.sh as it is, which the parity of tests/helm_parity.py checks, and fixes
  # to it are not a change of the chart's objects; the same for PostgreSQL's keep-major.sh, a
  # copy of db/postgres/keep-major.sh, and the checksum of its ConfigMap, db-scripts; and the
  # bundled MySQL's --myisam-recover-options=BACKUP,FORCE, since 0.2.0: the refusals of allowedAccounts
  # are MyISAM, checked and repaired after a crash)
  mask='walk(if type == "string" and test("^MYSQL_PWD=[$][{]MYSQL_PASSWORD[}] mysqladmin ping |^mysqladmin ping .* -p\"[$][{]MYSQL_PASSWORD[}]\" ") then "mysqladmin ping (masked)"
    elif type == "object" then
      (if has("helm.sh/chart") then .["helm.sh/chart"] = "masked" else . end)
      | del(.["app.kubernetes.io/version"])
      | (if has("checksum/admin-secrets") then .["checksum/admin-secrets"] = "masked" else . end)
      | (if .name? == "ADMIN_K8S_CHART_VERSION" and has("value") then .value = "masked" else . end)
      | (if .kind? == "Secret" and has("data") then .data = (.data | map_values("masked")) else . end)
      | (if .kind? == "ConfigMap" and (.data? | type) == "object" and (.data | has("backup.sh")) then .data["backup.sh"] = "masked" else . end)
      | (if .kind? == "ConfigMap" and (.data? | type) == "object" and (.data | has("keep-major.sh")) then .data["keep-major.sh"] = "masked" else . end)
      | (if has("checksum/db-scripts") then .["checksum/db-scripts"] = "masked" else . end)
    elif type == "array" then map(select(. != "--myisam-recover-options=BACKUP,FORCE"))
    else . end)'
  diffs=""
  for values in "${base_dir}"/ci/*.yaml; do
    name=$(basename "${values}")
    [[ -f "${CHART_DIR}/ci/${name}" ]] || fail "ci/${name} of chart 0.1.0 is gone"
    old=$(helm template test-release "${base_dir}" -f "${values}" 2>&1) || fail "chart 0.1.0 failed to render with ci/${name}: ${old}"
    new=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/${name}" 2>&1) || fail "the chart failed to render with ci/${name}: ${new}"
    if ! diff <(manifests <<< "${old}" | jq -S "${mask}") <(manifests <<< "${new}" | jq -S "${mask}") > "${base}/${name}.diff"; then
      diffs+=" ${name}"
      cut -c1-200 "${base}/${name}.diff" | head -40
    fi
  done
  rm -rf "${base}"
  [[ -z "${diffs}" ]] || fail "with the accounts off, not what chart 0.1.0 renders:${diffs}"
  check "accounts off: the same objects as chart 0.1.0 (${PARITY_BASE}) for every ci/*.yaml it had (but helm.sh/chart, app.kubernetes.io/version (set when published), ADMIN_K8S_CHART_VERSION, the Secret's values and their checksum, backup.sh's and PostgreSQL's keep-major.sh's text and the latter's checksum, MySQL's --myisam-recover-options=BACKUP,FORCE)"
}

# e2e <mysql|mariadb>: the chart with the accounts (their database on that backend, the Sync
# server's too) on a throwaway kind cluster: the auth pod's init containers in compose's
# order, its keys, its heartbeat, the sign-up policy, and fail closed on a wrong password;
# then, through the Ingresses over HTTPS (fxa_fixtures), test_fxa_flow.py, the client's
# address in the rate limits and the avatars on their volume; the admin UI's tests, the
# backups and a restore of the accounts as docs/backups.md says, a real Firefox; then what
# must survive (test_fxa_upgrade.py's sessions, refresh tokens and Sync data, the keys):
# an upgrade (new auth pods migrate first), a refused policy (fail closed), a new Redis pod,
# helm uninstall and install, the keys moved to fxa.keys.existingSecret; and turning the
# accounts on in a release whose existingSecret lacks their keys (refused, nothing applied).
# EXTERNAL_DB=1 (mysql): the accounts on your own server (a plain StatefulSet extdb-fxa, its
# users from db/mysql/setup/fxa-mysql, the Secret ffs-own): install, flow, the admin UI's
# tests, the backups (Sync's alone, as compose's), Firefox; the steps of the bundled server
# and of survival are not rerun.
# SYNC_BACKEND=postgres: the Sync server on the bundled PostgreSQL (database.backend), the
# accounts on <mysql|mariadb>; all of the above, and the Sync scope restored too, as
# docs/backups.md#restore-on-kubernetes says for PostgreSQL (its role, its one database, the
# admin UI's), next to the accounts'.
# SKIP_BROWSER=1: test_fxa_pairing.py alone in Firefox's image, not test_fxa_browser.py.
# PART: the steps after the install in two halves of about the same length, each of which
# needs nothing of the other: main (fxa_e2e_main: from the init containers to Firefox) and
# survival (fxa_e2e_survival: from test_fxa_upgrade.py's before; not with EXTERNAL_DB=1).
# Either one alone still sets up, installs and checks the install as a whole run does.
# REPOSITORY, TAG: the Sync server's images, as tests/helm.sh; FXA_IMAGE (default REPOSITORY),
# FXA_VERSION (default fxa-mono-latest): the accounts'; FXA_MARIADB_IMAGE, FXA_MYSQL_IMAGE:
# their database (as tests/e2e-fxa.sh: the chart's lts when the accounts image has
# mozilla/fxa#21494, mozilla/fxa#21554, else mariadb:11, mysql:8), also your own server's
fxa_e2e() {
  local backend=${1:-} external=${EXTERNAL_DB:-}
  case "${backend}" in
    mysql|mariadb) ;;
    *) echo "Usage: $0 e2e <mysql|mariadb>"; exit 1 ;;
  esac
  [[ -z "${external}" || ${backend} == mysql ]] || { echo "EXTERNAL_DB=1: e2e mysql only (db/mysql/setup/fxa-mysql)"; exit 1; }
  PART=${PART:-}
  case "${PART}" in
    ""|main) ;;
    survival) [[ -z "${external}" ]] || { echo "PART=survival: the bundled server's steps, not with EXTERNAL_DB=1"; exit 1; } ;;
    *) echo "PART=${PART}: main, survival, or empty (both)"; exit 1 ;;
  esac
  # the Sync server's database (database.backend): the accounts' backend, or PostgreSQL
  SYNC_BACKEND=${SYNC_BACKEND:-${backend}}
  local flavor=mysql init_dir=db/mysql/init
  case "${SYNC_BACKEND}" in
    "${backend}") ;;
    postgres) flavor=postgres init_dir=db/postgres/init ;;
    *) echo "SYNC_BACKEND=${SYNC_BACKEND}: postgres, or empty (the accounts' backend, ${backend})"; exit 1 ;;
  esac
  local repository=${REPOSITORY:-ghcr.io/porelli/firefox-sync} tag=${TAG:-latest} init_tag=${TAG:-latest}
  local fxa_image=${FXA_IMAGE:-${repository}}:${FXA_VERSION:-fxa-mono-latest}
  local db_image redis_image
  db_image=$(python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["fxa"]["database"]["image"][sys.argv[2]])' \
    "${CHART_DIR}/values.yaml" "${backend}") || fail "no fxa.database.image.${backend} in values.yaml"
  redis_image=$(python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["fxa"]["redis"]["image"])' "${CHART_DIR}/values.yaml") \
    || fail "no fxa.redis.image in values.yaml"
  # the chart's lts needs a patch in the accounts image (the label of our builds,
  # upstream-patches.yml), as tests/e2e-fxa.sh: MariaDB lts (12) mozilla/fxa#21494, else
  # mariadb:11; MySQL lts (9) mozilla/fxa#21554, else mysql:8 (with mysql_native_password, the
  # chart's for a MySQL 8 pin). FXA_MARIADB_IMAGE, FXA_MYSQL_IMAGE: that one
  local db_args=() pr fallback given
  case "${backend}" in
    mariadb) pr=21494 fallback=docker.io/library/mariadb:11 given=${FXA_MARIADB_IMAGE:-} ;;
    mysql) pr=21554 fallback=docker.io/library/mysql:8 given=${FXA_MYSQL_IMAGE:-} ;;
  esac
  ADMIN_TAG=${TAG:-latest}
  CLUSTER="ffs-helm-fxa-${backend}${external:+-extdb}$([[ ${SYNC_BACKEND} == "${backend}" ]] || echo "-sync-${SYNC_BACKEND}")"
  REL=t
  FULL="${REL}-firefox-sync"
  SECRET=${FULL}
  # (also the image of the tests' pods: python3 with PyFxA, MySQLdb and psycopg2, curl)
  SYNC_IMAGE="${repository}:syncstorage-rs-${flavor}-${tag}"
  # the fixtures' images (tests/helm/traefik.yaml, tests/helm/fxa-fixtures.yaml)
  TRAEFIK_IMAGE=docker.io/library/traefik:latest
  MAILPIT_IMAGE=docker.io/axllent/mailpit:latest
  # the pairing server's (fxa.pairing.image empty: <image.repository>:fxa-channelserver-latest)
  PAIRING_IMAGE="${repository}:fxa-channelserver-latest"
  BROWSER_IMAGE="ffs-fxa-browser:src-$(cd "${SCRIPT_DIR}/browser" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -c1-12)"
  POD_SELECTOR="app.kubernetes.io/instance=${REL},app.kubernetes.io/component=fxa-auth"
  local sync_db_image
  sync_db_image=$(python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["database"]["image"][sys.argv[2]])' \
    "${CHART_DIR}/values.yaml" "${SYNC_BACKEND}") || fail "no database.image.${SYNC_BACKEND} in values.yaml"
  [[ ${backend} != mysql ]] || mysqld_apparmor_check
  # the images go into the node with docker save --platform (Docker 27 and later)
  docker save --help 2> /dev/null | grep -q -- '--platform' \
    || fail "docker $(docker version -f '{{.Server.Version}}' 2> /dev/null) has no docker save --platform: Docker 27 or later is needed"

  echo "=== e2e of the accounts on kind (${backend}${external:+, your own server}, Sync on ${SYNC_BACKEND}${PART:+, part ${PART}}) ==="
  # what does not wait for anything runs at once (bg_start): the cluster's creation; each image
  # of the host's docker pulled when missing there, then into the node as soon as the cluster
  # and the free space allow (the "go" mark); the builds of the init image, the admin UI and
  # Firefox's test image, loaded once built
  local t0=${SECONDS}
  BG_DIR=$(mktemp -d)
  kind delete cluster --name "${CLUSTER}" > /dev/null 2>&1 || true
  trap 'rc=$?; bg_kill; if ((rc)); then diagnostics; fi; kind_teardown; rm -rf "${BG_DIR}"' EXIT
  bg_start cluster kind create cluster --name "${CLUSTER}" --wait 120s
  # the images into the node, as tests/helm.sh loads the Sync server's: the node's platform
  # alone (a pulled image's export lacks the others), the import's layers dropped once
  # unpacked (disk); each in its own import, at once
  local platform
  platform=$(docker version -f 'linux/{{.Server.Arch}}')
  pull_import() {
    local s=${SECONDS}
    docker image inspect "$1" > /dev/null 2>&1 || docker pull -q "$1" > /dev/null || fail "$1 not pulled"
    echo "  $1 pulled: $((SECONDS - s)) s"
    bg_marker go
    s=${SECONDS}
    docker save --platform "${platform}" "$1" | docker exec -i "${CLUSTER}-control-plane" ctr --namespace=k8s.io images import --digests \
      --snapshotter=overlayfs --local --discard-unpacked-layers - > /dev/null || fail "$1 not loaded"
    echo "  $1 into the node: $((SECONDS - s)) s"
  }
  # (the accounts' database image once the accounts image's labels chose it, below; and the
  # test fixtures': the Ingress controller, the mail catcher)
  local image images=("${fxa_image}" "${SYNC_IMAGE}" "${PAIRING_IMAGE}" "${redis_image}" "${sync_db_image}" "${TRAEFIK_IMAGE}" "${MAILPIT_IMAGE}") n
  for n in "${!images[@]}"; do bg_start "image-${n}" pull_import "${images[n]}"; done
  image_tags
  bg_start build build_images "${repository}" "${flavor}" "${init_dir}"
  # the tests in Firefox's image (tests/browser), tagged by its files as tests/e2e-fxa.sh does
  # (not for PART=survival, which runs nothing in it)
  local browser=1
  [[ ${PART} != survival ]] || browser=""
  [[ -z "${browser}" ]] || bg_start browser sh -c 'docker image inspect "$1" > /dev/null 2>&1 || docker build -q -t "$1" "$2" > /dev/null || { echo "the Firefox test image (tests/browser) not built"; exit 1; }' \
    sh "${BROWSER_IMAGE}" "${SCRIPT_DIR}/browser"

  if [[ -n "${given}" ]]; then
    db_image=${given}
  else
    # (the accounts image's labels: its pull)
    until grep -qF ' pulled: ' "${BG_DIR}/image-0.log" 2> /dev/null || ! kill -0 "${BG_PIDS[image-0]}" 2> /dev/null; do sleep 1; done
    grep -qF ' pulled: ' "${BG_DIR}/image-0.log" || bg_wait image-0
    # shellcheck source=tests/fxa_fix.sh
    source "${REPO_ROOT}/tests/fxa_fix.sh"
    if ! fxa_image_fixed "mozilla/fxa#${pr}" "${fxa_image}"; then
      db_image=${fallback}
      echo "== ${fxa_image} without mozilla/fxa#${pr} (its labels, config/fxa/fixed-in): the accounts on ${db_image}"
    fi
  fi
  db_args=(--set fxa.database.image."${backend}"="${db_image}")
  if [[ ${db_image} != "${sync_db_image}" ]]; then
    images+=("${db_image}")
    bg_start "image-$((${#images[@]} - 1))" pull_import "${db_image}"
  fi
  if [[ -n "${browser}" ]]; then
    bg_wait browser
    # (Mozilla's latest release, tests/browser/Dockerfile: the first suspect when only it fails)
    echo "Firefox test image ${BROWSER_IMAGE}: $(docker run --rm "${BROWSER_IMAGE}" firefox --version 2> /dev/null)"
  fi
  # the accounts image is about 5 GB in the node, on top of the Sync server's images; and the
  # Firefox image's copy there (kind load): before anything goes into the node
  local free need
  free=$(df -BG --output=avail "$(docker info -f '{{.DockerRootDir}}')" | tail -1 | tr -dc 0-9)
  need=15
  [[ -z "${browser}" ]] || need=$(( need + ($(docker image inspect -f '{{.Size}}' "${BROWSER_IMAGE}") + 999999999) / 1000000000 ))
  [[ "${free}" -ge "${need}" ]] || fail "${free} GB free for docker, the accounts' kind cluster needs ${need} GB (15, and ${BROWSER_IMAGE} in the node; vm.sh prune, docker system prune)"
  bg_wait cluster
  kubectl config use-context "kind-${CLUSTER}" > /dev/null
  # PodSecurity baseline, enforced, as tests/helm.sh
  kubectl label ns default pod-security.kubernetes.io/enforce=baseline pod-security.kubernetes.io/enforce-version=latest > /dev/null
  bg_mark go
  # (Firefox's, built above)
  [[ -z "${browser}" ]] || bg_start load-browser sh -c 'kind load docker-image --name "$1" "$2" > /dev/null || { echo "$2 not loaded"; exit 1; }' sh "${CLUSTER}" "${BROWSER_IMAGE}"
  bg_wait build
  bg_start load-built kind_load_built "${repository}" "${flavor}" "${init_dir}"
  for n in "${!images[@]}"; do bg_wait "image-${n}"; done
  bg_wait load-built load-browser
  check "loaded from the host's docker: ${images[*]}${browser:+ ${BROWSER_IMAGE}} ($((SECONDS - t0)) s since the cluster's creation began)"
  fxa_fixtures
  # the user of fxa-redis' pod: the image's redis
  [[ "$(docker run --rm "${redis_image}" id redis)" == "uid=999(redis) gid=1000(redis)"* ]] \
    || fail "${redis_image}: redis is $(docker run --rm "${redis_image}" id redis), not uid 999, gid 1000"
  check "${redis_image}: redis is uid 999, gid 1000"
  # fxa-redis' start with a password of an existingSecret: spaces, quotes, a backslash, a $ and
  # a newline are its password as they are (requirepass in Redis' own quoting), on the image
  local script cid weird=$'a b"c\'d\\e $f\ng' got
  script=$(helm template "${REL}" "${CHART_DIR}" -f "${SCRIPT_DIR}/helm/fxa-values.yaml" --set fxa.enabled=true | manifests \
    | jq -r --arg n "${FULL}-fxa-redis" '.[] | select(.kind == "Deployment" and .metadata.name == $n) | .spec.template.spec.containers[0].args[0]')
  cid=$(docker run -d -e REDISCLI_AUTH="${weird}" --entrypoint /bin/sh "${redis_image}" -c "${script}") || fail "fxa-redis' script did not start"
  for _ in $(seq 1 20); do
    got=$(docker exec "${cid}" redis-cli ping 2>&1) || true
    [[ "${got}" == PONG ]] && break
    sleep 1
  done
  if [[ "${got}" != PONG ]]; then
    got="${got}; its log: $(docker logs "${cid}" 2>&1 | tail -5)"
    docker rm -f "${cid}" > /dev/null 2>&1 || true
    fail "fxa-redis with a password of spaces, quotes and a newline: ${got}"
  fi
  got=$(docker exec -e REDISCLI_AUTH='a b' "${cid}" redis-cli ping 2>&1) || true
  docker rm -f "${cid}" > /dev/null 2>&1 || true
  [[ "${got}" == *WRONGPASS* ]] || fail "fxa-redis took the password's first word alone: ${got}"
  check "fxa-redis: a password with spaces, quotes, a backslash, a \$ and a newline is its password as it is"
  # images-seed with fxa.volumeOwnerInit=false, on the image: a new volume as fsGroup leaves it
  # (root's, group 10001, 2775), the seed as 10001 copies into it and leaves it as it is
  local vol="ffs-e2e-images-$$" seed=()
  mapfile -t seed < <(helm template "${REL}" "${CHART_DIR}" -f "${SCRIPT_DIR}/helm/fxa-values.yaml" --set fxa.enabled=true --set fxa.volumeOwnerInit=false | manifests \
    | jq -r --arg n "${FULL}-fxa-profile" '.[] | select(.kind == "Deployment" and .metadata.name == $n) | .spec.template.spec.initContainers[] | select(.name == "images-seed") | .args[]')
  docker volume create "${vol}" > /dev/null
  docker run --rm --user 0 --entrypoint sh -v "${vol}:/images" "${fxa_image}" -c 'chown 0:10001 /images && chmod 2775 /images' > /dev/null
  got=$(docker run --rm --user 10001:10001 -v "${vol}:/images" --entrypoint "${seed[0]}" "${fxa_image}" "${seed[@]:1}" 2>&1 \
    && docker run --rm --user 10001:10001 -v "${vol}:/images" --entrypoint sh "${fxa_image}" -c 'touch /images/w && rm /images/w && stat -c "%u:%g %a" /images && ls -A /images' 2>&1 | paste -sd' ' -) || true
  docker volume rm "${vol}" > /dev/null 2>&1 || true
  [[ "${got}" == "0:10001 2775 .keep" ]] || fail "images-seed (${seed[*]}) on a volume of root's, group 10001: ${got}"
  check "images-seed with fxa.volumeOwnerInit=false: the image's var/public copied into a volume of root's (group 10001, 2775), left as it was, 10001 writes there"

  local install=("${REL}" "${CHART_DIR}" -f "${SCRIPT_DIR}/helm/fxa-values.yaml" --set fxa.enabled=true
    --set database.backend="${SYNC_BACKEND}" --set fxa.database.backend="${backend}"
    --set image.repository="${repository}" --set image.syncstorageTag="${tag}" --set image.initTag="${init_tag}"
    --set image.adminTag="${ADMIN_TAG}" --set fxa.image.repository="${fxa_image%:*}" --set fxa.image.tag="${fxa_image##*:}" "${db_args[@]}")
  # the accounts' databases as root, in their server's pod (the bundled one, or your own)
  DB_POD="${FULL}-fxa-db-0"
  fxa_db_sql() { kubectl exec "${DB_POD}" -- sh -c 'MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" "$(command -v mariadb || command -v mysql)" -uroot -N -B -e "$1"' sh "$1"; }
  if [[ -n "${external}" ]]; then
    DB_POD=extdb-fxa-0 SECRET=ffs-own
    fxa_extdb
    install+=(--set fxa.database.bundled=false --set fxa.database.external.host=extdb-fxa --set existingSecret=ffs-own)
  fi
  helm install "${install[@]}" --wait --timeout 20m || fail "helm install with the accounts did not get Ready"
  check "helm install with the accounts (${backend}$([[ -z ${external} ]] || echo ", your own server extdb-fxa, existingSecret ffs-own"), Sync on ${SYNC_BACKEND}) Ready, in a namespace enforcing PodSecurity baseline"
  admin_test_env

  # (what both parts use)
  local auth="deploy/${FULL}-fxa-auth" redis="deploy/${FULL}-fxa-redis" profile="deploy/${FULL}-fxa-profile"
  local public=/fxa/packages/fxa-profile-server/var/public inits out ready revision name want
  # (the bundled accounts database: the other backend, its volume's name on this one)
  local other=mariadb old_claim=data claim="data-${FULL}-fxa-db-0"
  [[ ${backend} == mysql ]] || { other=mysql; old_claim="data-mariadb"; claim="data-mariadb-${FULL}-fxa-db-0"; }
  [[ ${PART} == survival ]] || fxa_e2e_main
  if [[ -n "${external}" || ${PART} == main ]]; then
    echo ""
    echo "=== e2e of the accounts (${backend}${external:+, your own server}${PART:+, part ${PART}}) passed ==="
    return 0
  fi
  fxa_e2e_survival
  echo ""
  echo "=== e2e of the accounts (${backend}${PART:+, part ${PART}}) passed ==="
}

# fxa_e2e_main: fxa_e2e's checks of the install, fail closed, the flows, the admin UI, the
# backups, Firefox (PART=main; its names: fxa_e2e's, which calls it)
fxa_e2e_main() {
  # the auth server only after its init containers, in compose's order, all succeeded
  inits=$(kubectl get pods -l "${POD_SELECTOR}" -o json | jq -r '.items[0].status.initContainerStatuses[]
    | "\(.name)=\(.state.terminated.exitCode // "none")"' | paste -sd' ' -) || true
  # (your own server: db-bootstrap checks its users and grants before the migrations)
  local boot=""
  [[ -z ${external} ]] || boot="db-bootstrap=0 "
  [[ "${inits}" == "keys-owner=0 wait-db=0 ${boot}migrations=0 policy=0 wait-redis=0" ]] || fail "the auth pod's init containers: ${inits}"
  check "auth's init containers: ${inits}"
  # (oauth_gen_keys.js also writes openid-oldKey.json, FXA_OPENID_OLDKEYFILE)
  [[ "$(kubectl exec "${auth}" -c auth -- ls /fxa-keys | paste -sd' ' -)" == "oauth-clients.json openid-key.json openid-oldKey.json public-key.json secret-key.json vapid-keys.json" ]] \
    || fail "/fxa-keys has $(kubectl exec "${auth}" -c auth -- ls -l /fxa-keys)"
  [[ "$(kubectl exec "${auth}" -c auth -- sh -c 'stat -c %u /fxa-keys /fxa-keys/*' | sort -u)" == 10001 ]] \
    || fail "/fxa-keys not 10001's: $(kubectl exec "${auth}" -c auth -- ls -ln /fxa-keys)"
  check "/fxa-keys: oauth-clients.json, openid-key.json, openid-oldKey.json, public-key.json, secret-key.json, vapid-keys.json, uid 10001's"
  kubectl exec "${auth}" -c auth -- node -e "fetch('http://localhost:9000/__heartbeat__').then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))" \
    || fail "auth's /__heartbeat__ does not answer 200"
  check "auth's /__heartbeat__ answers"
  kubectl logs "${auth}" -c policy | grep -q 'max accounts: unlimited' || fail "the policy's log: $(kubectl logs "${auth}" -c policy | tail -5)"
  check "the sign-up policy installed: max accounts: unlimited"
  if [[ -n "${external}" ]]; then
    # your own server: nothing of the bundled one; the policy as its own user, which may not
    # CREATE USER (the administrator's SQL made ffs_admin); the accounts' user on the server's
    # default authentication, or mysql_native_password for an image without mozilla/fxa#21554
    ! kubectl get sts,svc,pvc -o name | grep -q -- '-fxa-db' || fail "a bundled accounts database with your own server: $(kubectl get sts,svc,pvc -o name | grep -- '-fxa-db')"
    # (the servers' too, tests/helm/fxa-values.yaml: below)
    [[ "$(kubectl get networkpolicy -o name | grep -c -- '-fxa-\(redis\|db\)$')" == 1 ]] && ! kubectl get networkpolicy "${FULL}-fxa-db" > /dev/null 2>&1 \
      || fail "the NetworkPolicies with your own server: $(kubectl get networkpolicy -o name | paste -sd' ' -)"
    out=$(kubectl logs "${auth}" -c policy)
    ! grep -qi 'create user' <<< "${out}" || fail "the policy's log names CREATE USER: ${out}"
    grep -q '^.*ffs_admin: created by the administrator of the database server, granting$' <<< "${out}" || fail "the policy did not find ffs_admin made by the administrator: ${out}"
    [[ "$(fxa_db_sql "SELECT DEFINER FROM information_schema.triggers WHERE trigger_name = 'ffs_signup_policy'")" == "ffs_policy@%" ]] \
      || fail "the sign-up policy's trigger: $(fxa_db_sql "SELECT DEFINER FROM information_schema.triggers WHERE trigger_name = 'ffs_signup_policy'")"
    local fxa_plugin=caching_sha2_password
    [[ ${db_image##*:} == 8* ]] && fxa_plugin=mysql_native_password
    [[ "$(fxa_db_sql "SELECT plugin FROM mysql.user WHERE user = 'fxa'")" == "${fxa_plugin}" ]] || fail "fxa on $(fxa_db_sql "SELECT plugin FROM mysql.user WHERE user = 'fxa'")"
    check "your own server: no ${FULL}-fxa-db, its NetworkPolicy neither (only fxa-redis'); the policy as ffs_policy (its trigger's DEFINER), no CREATE USER, ffs_admin the administrator's; fxa on ${fxa_plugin}"
  fi

  # Redis' password (chart-only): auth's clients authenticate (requests that use its rate
  # limits and caches, then no NOAUTH error in Redis), a client without it is refused
  for _ in 1 2 3; do
    kubectl exec "${auth}" -c auth -- node -e "fetch('http://localhost:9000/v1/account/status', {method: 'POST', headers: {'content-type': 'application/json'},
      body: JSON.stringify({email: 'nobody@example.test'})}).then(r => process.exit(r.status < 500 ? 0 : 1), () => process.exit(1))" \
      || fail "auth's /v1/account/status failed"
  done
  out=$(kubectl exec "${redis}" -- redis-cli INFO errorstats)
  ! grep -q NOAUTH <<< "${out}" || fail "Redis refused unauthenticated commands of the accounts: ${out}"
  [[ "$(kubectl exec "${redis}" -- redis-cli INFO clients | sed -n 's/^connected_clients:\([0-9]*\).*/\1/p')" -ge 2 ]] || fail "no client of the accounts connected to Redis"
  [[ "$(kubectl exec "${redis}" -- sh -c 'env -u REDISCLI_AUTH redis-cli ping' 2>&1)" == *NOAUTH* ]] || fail "Redis answers without its password"
  check "fxa-redis: the accounts authenticate with FXA_REDIS_PASSWORD (no NOAUTH error, $(kubectl exec "${redis}" -- redis-cli INFO clients | sed -n 's/^connected_clients:\([0-9]*\).*/\1/p') clients), no answer without it"

  # fxa.networkPolicy: a pod not of the accounts does not reach Redis (no answer, the
  # connection dropped), one with the accounts' labels does (its NOAUTH)
  np_probe() {
    kubectl delete pod np-probe --ignore-not-found --wait=true > /dev/null
    kubectl run np-probe --image="${redis_image}" --restart=Never --labels="ffs-e2e=np$1" --command -- \
      sh -c "timeout 10 redis-cli -h ${FULL}-fxa-redis ping; echo rc=\$?" > /dev/null
    kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/np-probe --timeout=2m > /dev/null || fail "np-probe did not complete"
    kubectl logs np-probe 2>&1
  }
  out=$(np_probe "")
  ! grep -qE 'NOAUTH|PONG' <<< "${out}" || fail "a pod without the accounts' labels reaches fxa-redis: ${out}"
  out=$(np_probe ",app.kubernetes.io/name=firefox-sync,app.kubernetes.io/instance=${REL},app.kubernetes.io/component=fxa-content")
  grep -q NOAUTH <<< "${out}" || fail "a pod with the accounts' labels does not reach fxa-redis: ${out}"
  kubectl delete pod np-probe --wait=true > /dev/null
  check "fxa.networkPolicy: fxa-redis unreachable from a pod not of the accounts, reached with their labels (the CNI enforces it)"

  # fxa.networkPolicy.servers (tests/helm/fxa-values.yaml: Traefik's pods in ffs-test-ingress,
  # the tests' pods): auth, content, profile and pairing unreachable from another pod, also one
  # with Traefik's label in another namespace (both selectors in one peer); reached by the tests'
  # pods, and through Traefik (every test below goes through it: the flows, the rate limits by
  # the client's address, the admin UI's sign-in)
  server_probe() {
    kubectl delete pod np-servers --ignore-not-found --wait=true > /dev/null
    # (the five at once: each blocked one waits out its 5 s; printed in their order)
    kubectl run np-servers --image="${SYNC_IMAGE}" --image-pull-policy=Never --restart=Never --labels="ffs-e2e=np-servers$1" --command -- sh -c "
      i=0
      for u in fxa-auth:9000/__heartbeat__ fxa-content:3030/__heartbeat__ fxa-profile:1111/__heartbeat__ fxa-profile:1114/img/a/00000000000000000000000000000000 fxa-pairing:8000/__heartbeat__; do
        i=\$((i + 1))
        echo \"\${u%%/*} \$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://${FULL}-\${u})\" > /tmp/np-\${i} &
      done
      wait
      j=0
      while [ \${j} -lt \${i} ]; do j=\$((j + 1)); cat /tmp/np-\${j}; done" > /dev/null
    kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/np-servers --timeout=3m > /dev/null || fail "np-servers did not complete"
    kubectl logs np-servers 2>&1 | paste -sd' ' -
  }
  local blocked="fxa-auth:9000 000 fxa-content:3030 000 fxa-profile:1111 000 fxa-profile:1114 000 fxa-pairing:8000 000"
  got=$(server_probe "")
  [[ "${got}" == "${blocked}" ]] || fail "a pod of no label reaches the accounts' servers: ${got}"
  got=$(server_probe ",app=traefik")
  [[ "${got}" == "${blocked}" ]] || fail "a pod with Traefik's label in the namespace default reaches the accounts' servers: ${got}"
  got=$(server_probe ",ffs-e2e-direct=true")
  [[ "${got}" == "fxa-auth:9000 200 fxa-content:3030 200 fxa-profile:1111 200 fxa-profile:1114 200 fxa-pairing:8000 200" ]] \
    || fail "a pod of extraFrom does not reach the accounts' servers: ${got}"
  kubectl delete pod np-servers --wait=true > /dev/null
  [[ "$(kubectl get networkpolicy -o name | sed 's|.*/||' | LC_ALL=C sort | paste -sd' ' -)" == "$(printf '%s\n' "${FULL}"-fxa-{redis,auth,content,profile,pairing} $([[ -n ${external} ]] || echo "${FULL}-fxa-db") | LC_ALL=C sort | paste -sd' ' -)" ]] \
    || fail "the NetworkPolicies: $(kubectl get networkpolicy -o name | paste -sd' ' -)"
  check "fxa.networkPolicy.servers: auth, content, profile (1111, 1114), pairing unreachable from a pod of no label and from one with Traefik's label in another namespace (the CNI enforces it), reached from extraFrom's; through Traefik in the tests below"

  # fail closed: a wrong password of the accounts' database stops auth at the migrations (your own server: at db-bootstrap)
  # (wait-db has no credentials), never Ready, out of its Service
  local good
  good=$(kubectl get secret "${SECRET}" -o jsonpath='{.data.FXA_MYSQL_PASSWORD}')
  kubectl patch secret "${SECRET}" --type merge -p "{\"data\":{\"FXA_MYSQL_PASSWORD\":\"$(printf wrong | base64)\"}}"
  kubectl delete pod -l "${POD_SELECTOR}" --wait=true
  # (a refused sign-in is not retried: the migrations fail at their first try, Init:Error
  # for a moment, then Init:CrashLoopBackOff as Kubernetes reruns them; your own server:
  # db-bootstrap, which signs in first as the accounts' user, stops it there)
  local failing=migrations t0=${SECONDS}
  [[ -z ${external} ]] || failing="db-bootstrap"
  wait_init_failed "${failing}" 120 || fail "the auth pod's ${failing} did not fail within 120 s (a refused sign-in retried?)"
  if [[ -z ${external} ]]; then
    # (this run's log, or the last one's once Kubernetes reruns them)
    mig_log() { { kubectl logs -l "${POD_SELECTOR}" -c migrations --tail=20; kubectl logs -l "${POD_SELECTOR}" -c migrations --tail=20 --previous; } 2> /dev/null; }
    # (the log in a variable: grep -q would stop reading early, and pipefail fail the pipe)
    local log
    log=$(mig_log)
    [[ "${log}" == *"not retried"* ]] || fail "the migrations' log does not say the refused sign-in is not retried: ${log}"
  fi
  [[ "$(pod_status)" =~ ^Init: ]] || fail "the auth pod is $(pod_status), not in its init containers"
  MATCHED_STATUS=$(pod_status)
  inits=$(kubectl get pods -l "${POD_SELECTOR}" -o json | jq -r '.items[0].status.initContainerStatuses[]
    | "\(.name)=\(.state.terminated.exitCode // .lastState.terminated.exitCode // "none")"' | paste -sd' ' -) || true
  [[ "${inits}" =~ wait-db=0\ ${failing}=[1-9] ]] || fail "expected wait-db to pass and ${failing} to fail: ${inits}"
  # (over 30 s, not a single look)
  for _ in $(seq 1 6); do
    ready=$(kubectl get endpointslices -l "kubernetes.io/service-name=${FULL}-fxa-auth" -o json \
      | jq '[.items[].endpoints[]? | select(.conditions.ready == true)] | length')
    [[ "${ready}" == 0 ]] || fail "${FULL}-fxa-auth has ${ready} ready endpoints while the migrations fail"
    sleep 5
  done
  [[ "$(pod_status)" =~ ^Init: ]] || fail "the auth pod is $(pod_status) 30 s later, not in its init containers"
  check "wrong FXA_MYSQL_PASSWORD: ${failing} stops at the refused sign-in, not retried ($((SECONDS - t0)) s), auth in ${MATCHED_STATUS} (${inits}), no ready endpoint for 30 s"
  kubectl patch secret "${SECRET}" --type merge -p "{\"data\":{\"FXA_MYSQL_PASSWORD\":\"${good}\"}}"
  kubectl delete pod -l "${POD_SELECTOR}" --wait=true
  kubectl wait --for=condition=Ready pod -l "${POD_SELECTOR}" --timeout=15m || fail "auth not Ready after restoring the password"
  check "password restored: auth Ready again"

  # (the bundled server alone)
  if [[ -z "${external}" ]]; then
    # the other backend on this release: refused at render time (checkFxaDbBackend's lookup),
    # before anything is applied: auth's Deployment, fxa-db and its volume as they were
    local auth_before auth_after sts_before
    auth_before=$(kubectl get "${auth}" -o json | jq -cS '[.metadata.generation, .spec]')
    sts_before=$(kubectl get sts "${FULL}-fxa-db" -o json | jq -cS '[.metadata.generation, .spec]')
    if out=$(helm upgrade "${REL}" "${CHART_DIR}" --reuse-values --set fxa.database.backend="${other}" --timeout 2m 2>&1); then
      fail "helm upgrade to fxa.database.backend=${other} accepted"
    fi
    grep -qF "firefox-sync: fxa.database.backend is ${other} but the accounts database was created with ${backend} (its volume ${old_claim}); switching needs a dump and restore, see docs/backups.md#restore-on-kubernetes" <<< "${out}" \
      || fail "helm upgrade to ${other} refused, but not by the chart's check: ${out}"
    auth_after=$(kubectl get "${auth}" -o json | jq -cS '[.metadata.generation, .spec]')
    [[ "${auth_after}" == "${auth_before}" ]] || fail "the refused upgrade changed auth's Deployment: $(diff <(jq . <<< "${auth_before}") <(jq . <<< "${auth_after}") | head -20)"
    [[ "$(kubectl get sts "${FULL}-fxa-db" -o json | jq -cS '[.metadata.generation, .spec]')" == "${sts_before}" ]] || fail "the refused upgrade changed fxa-db's StatefulSet"
    [[ "$(kubectl get pvc -o name | grep -- '-fxa-db-0$')" == "persistentvolumeclaim/${claim}" ]] \
      || fail "the accounts database's claims: $(kubectl get pvc -o name | paste -sd' ' -)"
    [[ "$(kubectl get pod "${FULL}-fxa-db-0" -o jsonpath='{.status.containerStatuses[0].ready}')" == true ]] || fail "fxa-db not running on its data after the refused upgrade"
    check "helm upgrade to fxa.database.backend=${other}: refused at render time (created with ${backend}, ${old_claim}); auth's Deployment (generation, spec), fxa-db and ${claim} unchanged"

    # fxa-db as compose's FXA_MYSQL_IMAGE / FXA_MYSQL_ARGS: mysql_native_password (root on it)
    # only on a MySQL 8 pin; on MySQL lts none, root on caching_sha2_password
    local running_image args plugin
    running_image=$(kubectl get sts "${FULL}-fxa-db" -o jsonpath='{.spec.template.spec.containers[0].image}')
    args=$(kubectl get sts "${FULL}-fxa-db" -o json | jq -c '.spec.template.spec.containers[0].args')
    [[ "${running_image}" == "${db_image}" ]] || fail "fxa-db runs ${running_image}, not ${db_image}"
    if [[ ${backend} == mysql ]]; then
      plugin=$(kubectl exec "${FULL}-fxa-db-0" -- sh -c 'MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" mysql -uroot -N -B -e "SELECT plugin FROM mysql.user WHERE user = \"root\" AND host = \"%\""')
      if [[ ${db_image##*:} == 8* ]]; then
        [[ "${args}" == '["mysqld","--event-scheduler=ON","--mysql-native-password=ON","--authentication-policy=mysql_native_password"]' && "${plugin}" == mysql_native_password ]] \
          || fail "fxa-db on ${db_image}: args ${args}, root on ${plugin}"
      else
        [[ "${args}" == '["mysqld","--event-scheduler=ON"]' && "${plugin}" == caching_sha2_password ]] || fail "fxa-db on ${db_image}: args ${args}, root on ${plugin}"
      fi
      check "fxa-db on ${db_image}: ${args}, root on ${plugin}"
    fi

    # another major on this release: refused at render time (checkFxaDbBackend's lookup and
    # dbMajorChange), nothing applied; fxa.database.allowMajorUpgrade=true renders it (a server
    # dry run: lookup reads the cluster, nothing is changed)
    local major_image=${running_image%:*}:latest
    [[ ${running_image} == *:latest ]] && major_image=${running_image%:*}:lts
    sts_before=$(kubectl get sts "${FULL}-fxa-db" -o json | jq -cS '[.metadata.generation, .spec]')
    revision=$(helm history "${REL}" -o json | jq -r 'last | .revision')
    if out=$(helm upgrade "${REL}" "${CHART_DIR}" --reuse-values --set fxa.database.image."${backend}"="${major_image}" --timeout 2m 2>&1); then
      fail "helm upgrade to fxa.database.image.${backend}=${major_image} accepted"
    fi
    grep -qF "firefox-sync: fxa.database.image.${backend} is ${major_image} but the bundled accounts database ${FULL}-fxa-db runs ${running_image}; another major upgrades its data for good at the next start: set fxa.database.image.${backend} to ${running_image} to stay, or fxa.database.allowMajorUpgrade=true to move (a backup first), see docs/upgrading.md#database-majors" <<< "${out}" \
      || fail "helm upgrade to ${major_image} refused, but not by the major guard: ${out}"
    [[ "$(kubectl get sts "${FULL}-fxa-db" -o json | jq -cS '[.metadata.generation, .spec]')" == "${sts_before}" ]] || fail "the refused upgrade changed fxa-db's StatefulSet"
    [[ "$(helm history "${REL}" -o json | jq -r 'last | "\(.revision) \(.status)"')" == "${revision} deployed" ]] || fail "the refused upgrade left: $(helm history "${REL}" | tail -2)"
    out=$(helm upgrade "${REL}" "${CHART_DIR}" --reuse-values --set fxa.database.image."${backend}"="${major_image}" --set fxa.database.allowMajorUpgrade=true --dry-run=server 2>&1) \
      || fail "helm upgrade --dry-run=server with fxa.database.allowMajorUpgrade=true refused: ${out}"
    [[ "$(kubectl get sts "${FULL}-fxa-db" -o json | jq -cS '[.metadata.generation, .spec]')" == "${sts_before}" ]] || fail "the dry run changed fxa-db's StatefulSet"
    check "helm upgrade to fxa.database.image.${backend}=${major_image} (running ${running_image}): refused at render time naming both, revision ${revision} still deployed, fxa-db unchanged; with fxa.database.allowMajorUpgrade=true it renders (server dry run)"

    # the volumes as they are (checkClaim, lookups): what Kubernetes would refuse partway is
    # refused at render time, nothing applied. fxa-db's volumeClaimTemplate never changes; the
    # PVCs' class never changes, their size never shrinks and grows only with a StorageClass
    # of allowVolumeExpansion (kind's standard: set off, then on, then as it was)
    local sc_before keys_pvc="${FULL}-fxa-keys" images_pvc="${FULL}-fxa-profile-images" sts_claim
    sc_before=$(kubectl get storageclass standard -o jsonpath='{.allowVolumeExpansion}')
    kubectl patch storageclass standard --type merge -p '{"allowVolumeExpansion": false}' > /dev/null || fail "kind's StorageClass standard not patched"
    sts_claim=$(kubectl get sts "${FULL}-fxa-db" -o jsonpath='{.spec.volumeClaimTemplates[0].spec.resources.requests.storage}')
    storage_refused() {
      local want=$1 out
      shift
      sts_before=$(kubectl get sts "${FULL}-fxa-db" -o json | jq -cS '[.metadata.generation, .spec]')
      if out=$(helm upgrade "${REL}" "${CHART_DIR}" --reuse-values "$@" --timeout 2m 2>&1); then
        fail "helm upgrade $* accepted"
      fi
      grep -qF "${want}" <<< "${out}" || fail "helm upgrade $*: refused, but not by the chart's check: ${out}"
      [[ "$(helm history "${REL}" -o json | jq -r 'last | "\(.revision) \(.status)"')" == "${revision} deployed" ]] || fail "the refused upgrade ($*) left: $(helm history "${REL}" | tail -2)"
      [[ "$(kubectl get sts "${FULL}-fxa-db" -o json | jq -cS '[.metadata.generation, .spec]')" == "${sts_before}" ]] || fail "the refused upgrade ($*) changed fxa-db's StatefulSet"
      [[ "$(kubectl get pvc "${keys_pvc}" "${images_pvc}" -o jsonpath='{range .items[*]}{.spec.storageClassName} {.spec.resources.requests.storage} {end}')" == "standard 1Gi standard 1Gi " ]] \
        || fail "the refused upgrade ($*) changed the PVCs: $(kubectl get pvc "${keys_pvc}" "${images_pvc}")"
    }
    storage_refused "firefox-sync: fxa.database.persistence.size is 9Gi but the StatefulSet ${FULL}-fxa-db (its volume ${old_claim}) was created with ${sts_claim}: Kubernetes never changes a StatefulSet's volumeClaimTemplates; set it back to ${sts_claim}" \
      --set fxa.database.persistence.size=9Gi
    storage_refused "firefox-sync: fxa.database.persistence.storageClass is \"fast\" but the StatefulSet ${FULL}-fxa-db (its volume ${old_claim}) was created with \"\"" \
      --set fxa.database.persistence.storageClass=fast
    storage_refused "firefox-sync: fxa.keys.persistence.size is 2Gi but the PVC ${keys_pvc} is 1Gi, and its StorageClass \"standard\" does not allow expansion (allowVolumeExpansion): keep 1Gi" \
      --set fxa.keys.persistence.size=2Gi
    storage_refused "firefox-sync: fxa.profileImages.persistence.size is 512Mi but the PVC ${images_pvc} is 1Gi: Kubernetes never shrinks a volume; set at least 1Gi" \
      --set fxa.profileImages.persistence.size=512Mi
    storage_refused "firefox-sync: fxa.profileImages.persistence.storageClass is \"fast\" but the PVC ${images_pvc} is on \"standard\": Kubernetes never changes a PVC's class" \
      --set fxa.profileImages.persistence.storageClass=fast
    # (with allowVolumeExpansion the growth renders, a server dry run: lookup reads the cluster,
    # nothing changed; an empty storageClass renders the PVC's own)
    kubectl patch storageclass standard --type merge -p '{"allowVolumeExpansion": true}' > /dev/null || fail "kind's StorageClass standard not patched"
    out=$(helm upgrade "${REL}" "${CHART_DIR}" --reuse-values --set fxa.keys.persistence.size=2Gi --dry-run=server 2>&1) \
      || fail "helm upgrade --dry-run=server with fxa.keys.persistence.size=2Gi on a StorageClass of allowVolumeExpansion refused: ${out}"
    got=$(sed -n '/^MANIFEST:/,/^NOTES:/{/^\(MANIFEST\|NOTES\):/d;p}' <<< "${out}" | manifests | jq -c --arg n "${keys_pvc}" '.[] | select(.kind == "PersistentVolumeClaim" and .metadata.name == $n) | [.spec.storageClassName, .spec.resources.requests.storage]')
    [[ "${got}" == '["standard","2Gi"]' ]] || fail "the keys' PVC of the dry run: ${got} (expected its class standard, 2Gi)"
    [[ "$(kubectl get pvc "${keys_pvc}" -o jsonpath='{.spec.resources.requests.storage}')" == 1Gi ]] || fail "the dry run resized ${keys_pvc}"
    if [[ -n "${sc_before}" ]]; then
      kubectl patch storageclass standard --type merge -p "{\"allowVolumeExpansion\": ${sc_before}}" > /dev/null
    else
      kubectl patch storageclass standard --type json -p '[{"op": "remove", "path": "/allowVolumeExpansion"}]' > /dev/null
    fi
    [[ "$(kubectl get storageclass standard -o jsonpath='{.allowVolumeExpansion}')" == "${sc_before}" ]] || fail "kind's StorageClass standard not put back"
    check "the volumes: fxa.database.persistence.size and .storageClass (fxa-db's volumeClaimTemplate), fxa.keys.persistence.size up on a StorageClass without allowVolumeExpansion, fxa.profileImages.persistence.size down and .storageClass: refused at render time saying what to set, revision ${revision} still deployed, nothing changed; with allowVolumeExpansion the keys' 2Gi renders (server dry run, the PVC's class standard kept)"
  fi

  # the accounts' pages and profiles: Ready (helm's --wait), after their init containers; the
  # avatars' volume 10001's, with the image's directory in it; Redis' password in their env
  for name in content profile; do
    [[ "$(kubectl get deploy "${FULL}-fxa-${name}" -o jsonpath='{.status.readyReplicas}' 2> /dev/null)" == 1 ]] || fail "${FULL}-fxa-${name} not Ready"
  done
  for name in "content:wait-accounts=0" "profile:images-owner=0 images-seed=0 wait-auth=0"; do
    got=$(kubectl get pods -l "app.kubernetes.io/instance=${REL},app.kubernetes.io/component=fxa-${name%%:*}" -o json | jq -r '.items[0].status.initContainerStatuses[]
      | "\(.name)=\(.state.terminated.exitCode // "none")"' | paste -sd' ' -) || true
    [[ "${got}" == "${name#*:}" ]] || fail "the ${name%%:*} pod's init containers: ${got}"
  done
  check "content and profile Ready; their init containers: wait-accounts=0; images-owner=0 images-seed=0 wait-auth=0"
  got=$(kubectl exec "${profile}" -c profile -- sh -c "stat -c %u ${public}; ls -A ${public}" | paste -sd' ' -)
  [[ "${got}" == "10001 .keep" ]] || fail "the avatars' volume: ${got} (expected 10001's, with the image's .keep)"
  # shellcheck disable=SC2016 # (the regex, literally)
  [[ "$(kubectl exec "${profile}" -c profile -- printenv IMG_PROVIDERS_FXA)" == '^https://profile.fxa.test/img/a/[0-9a-f]{32}$' ]] \
    || fail "the profile server's IMG_PROVIDERS_FXA: $(kubectl exec "${profile}" -c profile -- printenv IMG_PROVIDERS_FXA)"
  want=$(kubectl get secret "${SECRET}" -o jsonpath='{.data.FXA_REDIS_PASSWORD}' | base64 -d)
  for name in content:content profile:profile; do
    [[ "$(kubectl exec "deploy/${FULL}-fxa-${name%%:*}" -c "${name#*:}" -- printenv REDIS_PASSWORD)" == "${want}" ]] || fail "${name%%:*}: REDIS_PASSWORD is not FXA_REDIS_PASSWORD"
  done
  # (connected: Redis' clients from their pods; the check of no NOAUTH error above ran with
  # them up, before the test's own unauthenticated clients)
  out=$(kubectl exec "${redis}" -- redis-cli CLIENT LIST)
  for name in content profile; do
    got=$(kubectl get pods -l "app.kubernetes.io/instance=${REL},app.kubernetes.io/component=fxa-${name}" -o jsonpath='{.items[0].status.podIP}')
    grep -q " addr=${got}:" <<< "${out}" || fail "no Redis client from the ${name} pod (${got}): ${out}"
  done
  check "the avatars' volume: 10001's, the image's var/public in it; IMG_PROVIDERS_FXA compose's (\$\$ as \$); REDIS_PASSWORD of content and profile FXA_REDIS_PASSWORD, both connected to Redis"

  # from a pod of the cluster, with curl (the Sync server's image): Firefox's configuration
  # on the chart's URLs, the avatars under /img/ (img-proxy) and without it (profile-static)
  # (and the worker, on the pod's loopback alone: not from another pod)
  local profile_ip
  profile_ip=$(kubectl get pods -l "app.kubernetes.io/instance=${REL},app.kubernetes.io/component=fxa-profile" -o jsonpath='{.items[0].status.podIP}')
  kubectl exec "${profile}" -c profile -- node -e "fetch('http://127.0.0.1:1113/__heartbeat__').then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))" \
    || fail "the profile container does not reach its worker at 127.0.0.1:1113"
  kubectl delete pod curl-probe --ignore-not-found --wait=true > /dev/null
  kubectl run curl-probe --image="${SYNC_IMAGE}" --image-pull-policy=Never --restart=Never --labels=ffs-e2e-direct=true --command -- sh -c "
    c=http://${FULL}-fxa-content:3030 p=http://${FULL}-fxa-profile a=/a/00000000000000000000000000000000
    echo \"config \$(curl -fsS --max-time 20 \$c/.well-known/fxa-client-configuration | tr -d '\n')\"
    for u in :1114/img\$a :1114\$a :1112\$a :1114/img/a/0123456789abcdef0123456789abcdef; do echo \"GET\$u \$(curl -s --max-time 20 -o /dev/null -w '%{http_code}' \$p\$u)\"; done
    echo \"HEAD:1114/img\$a \$(curl -s --max-time 20 -I -o /dev/null -w '%{http_code}' \$p:1114/img\$a)\"
    echo \"POST:1114/img\$a \$(curl -s --max-time 20 -X POST -o /dev/null -w '%{http_code}' \$p:1114/img\$a)\"
    echo \"worker \$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' http://${profile_ip}:1113/__heartbeat__)\"" > /dev/null
  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/curl-probe --timeout=3m > /dev/null || fail "curl-probe did not complete: $(kubectl logs curl-probe 2>&1 | tail -5)"
  out=$(kubectl logs curl-probe)
  kubectl delete pod curl-probe --wait=true > /dev/null
  [[ "$(sed -n 's/^config //p' <<< "${out}" | jq -r .auth_server_base_url)" == https://api.fxa.test ]] \
    || fail "content's /.well-known/fxa-client-configuration: $(sed -n 's/^config //p' <<< "${out}")"
  got=$(grep -v '^config ' <<< "${out}" | paste -sd' ' -)
  want="GET:1114/img/a/00000000000000000000000000000000 200 GET:1114/a/00000000000000000000000000000000 404 GET:1112/a/00000000000000000000000000000000 200"
  want+=" GET:1114/img/a/0123456789abcdef0123456789abcdef 404 HEAD:1114/img/a/00000000000000000000000000000000 200 POST:1114/img/a/00000000000000000000000000000000 405 worker 000"
  [[ "${got}" == "${want}" ]] || fail "the avatars: ${got}, expected ${want}"
  check "content's fxa-client-configuration: auth_server_base_url https://api.fxa.test; the default avatar at :1114/img/a/0… (GET, HEAD) and :1112/a/0… 200, :1114/a/0… and a missing one 404, POST 405; the worker reached at 127.0.0.1:1113 in its pod, not from another one"

  # what Firefox does, over HTTPS through the Ingresses (Traefik, the test CA) as through
  # compose's Caddy: test_fxa_flow.py (the configuration, the pages served here, sign-up with
  # the code from the mail catcher, the keys, Sync, a second device, wrong passwords, Sync
  # again after the admin UI's reset)
  fxa_job flow "${SYNC_IMAGE}" /tests/test_fxa_flow.py || fail "test_fxa_flow.py failed"
  got=$(kubectl logs job/fxa-test-flow | tail -1)
  [[ "${got}" =~ ^[0-9]+\ passed(,\ [0-9]+\ warnings?)?\ in ]] || fail "test_fxa_flow.py: not every test passed: ${got}"
  check "test_fxa_flow.py through the Ingresses over HTTPS: ${got}"
  # every rule of the accounts' Ingresses, and their certificates
  ingress_is "${FULL}-fxa-content" traefik accounts.fxa.test "${FULL}-fxa-content" 3030
  ingress_is "${FULL}-fxa-auth" traefik api.fxa.test "${FULL}-fxa-auth" 9000 /v1/account/create Exact "${FULL}-admin" 8081
  ingress_is "${FULL}-fxa-profile" traefik profile.fxa.test "${FULL}-fxa-profile" 1111 /img/ Prefix "${FULL}-fxa-profile" 1114
  for name in content:accounts auth:api profile:profile; do
    got=$(kubectl get ingress "${FULL}-fxa-${name%%:*}" -o json | jq -c '.spec.tls')
    [[ "${got}" == "[{\"hosts\":[\"${name#*:}.fxa.test\"],\"secretName\":\"fxa-test-tls\"}]" ]] || fail "Ingress ${FULL}-fxa-${name%%:*}: tls ${got}"
  done
  check "Ingresses ${FULL}-fxa-content (accounts.fxa.test /: 3030), -fxa-auth (api.fxa.test /: 9000, /v1/account/create Exact: ${FULL}-admin 8081, the sign-up gate), -fxa-profile (profile.fxa.test /: 1111, /img/: 1114), each with fxa-test-tls"

  # the pairing server (fxa.pairing.enabled), as nobody on a read-only root: two devices
  # exchange a message over its websockets through the Ingress (tests/e2e-fxa.sh's
  # test_fxa_pairing.py, in Firefox's test image), content gives its URL to Firefox
  # (test_fxa_flow.py's test_client_configuration above, with FXA_PAIRING_URL)
  local pairing="deploy/${FULL}-fxa-pairing"
  got=$(kubectl exec "${pairing}" -- bash -c 'id -u; id -g; touch /ffs-write-test 2>&1 || true' | paste -sd' ' -)
  [[ "${got}" == "65534 65534 "*"Read-only file system"* ]] || fail "the pairing server's user and root: ${got}"
  ingress_is "${FULL}-fxa-pairing" traefik pairing.fxa.test "${FULL}-fxa-pairing" 8000
  [[ "$(kubectl get ingress "${FULL}-fxa-pairing" -o json | jq -c '.spec.tls')" == '[{"hosts":["pairing.fxa.test"],"secretName":"fxa-test-tls"}]' ]] \
    || fail "Ingress ${FULL}-fxa-pairing: tls $(kubectl get ingress "${FULL}-fxa-pairing" -o json | jq -c '.spec.tls')"
  # (with Firefox, below, test_fxa_pairing.py runs next to test_fxa_browser.py, as in tests/e2e-fxa.sh)
  if [[ -n "${SKIP_BROWSER:-}" ]]; then
    fxa_job pairing "${BROWSER_IMAGE}" /tests/test_fxa_pairing.py || fail "test_fxa_pairing.py failed"
    got=$(kubectl logs job/fxa-test-pairing | tail -1)
    [[ "${got}" =~ ^1\ passed(,\ [0-9]+\ warnings?)?\ in ]] || fail "test_fxa_pairing.py: ${got}"
    got=", test_fxa_pairing.py through it: ${got}"
  else
    got=""
  fi
  check "pairing: ${FULL}-fxa-pairing as 65534 on a read-only root, its Ingress (pairing.fxa.test /: 8000, fxa-test-tls)${got}"

  # the client's own address through the Ingress (Review Focus 3): alice's wrong passwords
  # from one pod block that pod, not alice from another one
  local alice=alice@example.com alice_pw token
  alice_pw=$(rnd)
  fxa_client_pod ip-a
  fxa_client_pod ip-b
  # (alice signs up from ip-b, confirming with the code from the mail catcher; and an
  # OAuth token for her profile, for the avatars below)
  token=$(fxa_py ip-b ALICE="${alice}" ALICE_PASSWORD="${alice_pw}" <<'PY'
import os, sys
from urllib.parse import parse_qs, urlparse
import requests
from fxa._utils import HawkTokenAuth
from fxa.core import Client
from fxa.oauth import Client as OAuthClient
sys.path.insert(0, "/tests")
from test_fxa_flow import FIREFOX_CLIENT_ID, wait_for_code
AUTH = os.environ["FXA_AUTH_URL"]
email = os.environ["ALICE"]
session = Client(server_url=f"{AUTH}/v1").create_account(email, os.environ["ALICE_PASSWORD"], keys=True)
session.verify_email_code(wait_for_code(email))
oauth = OAuthClient(client_id=FIREFOX_CLIENT_ID, server_url=AUTH)
challenge, verifier = oauth.generate_pkce_challenge()
res = requests.post(f"{AUTH}/v1/oauth/authorization",
                    json={"client_id": FIREFOX_CLIENT_ID, "scope": "profile:write", "state": "avatar", **challenge},
                    headers={"Authorization": f"Bearer fxs_{HawkTokenAuth(session.token, 'sessionToken').id}"}, timeout=30)
assert res.status_code == 200, res.text
data = res.json()
code = data.get("code") or parse_qs(urlparse(data["redirect"]).query)["code"][0]
print(oauth.trade_code(code, **verifier)["access_token"])
PY
) || fail "alice's sign-up from ip-b: ${token}"
  got=$(fxa_py ip-a ALICE="${alice}" <<'PY'
import os
import requests
seen = []
for _ in range(6):
    res = requests.post(f"{os.environ['FXA_AUTH_URL']}/v1/account/login", json={"email": os.environ["ALICE"], "authPW": "00" * 32}, timeout=30)
    seen.append(f"{res.status_code}/{res.json().get('errno')}")
print(" ".join(seen))
PY
) || fail "the wrong passwords from ip-a: ${got}"
  [[ "${got}" == "400/103 400/103 400/103 400/103 400/103 429/114" ]] || fail "5 wrong passwords then a 6th from ip-a: ${got} (expected 5 times 400/103, then 429/114)"
  out=$(fxa_py ip-b ALICE="${alice}" ALICE_PASSWORD="${alice_pw}" <<'PY'
import os
from fxa.core import Client
Client(server_url=f"{os.environ['FXA_AUTH_URL']}/v1").login(os.environ["ALICE"], os.environ["ALICE_PASSWORD"])
print(200)
PY
) || fail "alice's right password from ip-b refused: ${out}"
  [[ "${out}" == 200 ]] || fail "alice's right password from ip-b: ${out}"
  check "the client's address through the Ingress: 5 wrong passwords for ${alice} from ip-a, the 6th refused (429, errno 114); from ip-b her password signs in (200)"

  # avatars (Review Focus 5): the default one through the Ingress, and alice's uploaded one,
  # its bytes those of the volume, the same again once profile's pod is new
  # (the worker re-encodes every upload with sharp, as PNG: not the uploaded bytes themselves)
  out=$(fxa_py ip-b TOKEN="${token}" <<'PY'
import hashlib, os, struct, zlib
import requests
PROFILE = os.environ["FXA_PROFILE_URL"]
default = requests.get(f"{PROFILE}/img/a/{'0' * 32}", timeout=30)
def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
rows = b"".join(b"\0" + bytes([200, 40 + 8 * y, 90]) * 16 for y in range(16))
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 16, 16, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")
res = requests.post(f"{PROFILE}/v1/avatar/upload", data=png, headers={"Authorization": f"Bearer {os.environ['TOKEN']}", "Content-Type": "image/png"}, timeout=60)
assert res.status_code == 201, res.text
url, avatar_id = res.json()["url"], res.json()["id"]
got = requests.get(url, timeout=30)
assert got.status_code == 200 and got.content[:8] == png[:8] and got.content[16:24] == png[16:24], (got.status_code, got.content[:32])
print(default.status_code, url, avatar_id, hashlib.sha256(got.content).hexdigest())
PY
) || fail "the avatars through profile.fxa.test: ${out}"
  local avatar_url avatar_id avatar_sha
  read -r got avatar_url avatar_id avatar_sha <<< "${out}"
  [[ "${got}" == 200 ]] || fail "GET https://profile.fxa.test/img/a/0…: ${got}"
  [[ "${avatar_url}" == "https://profile.fxa.test/img/a/${avatar_id}" ]] || fail "the uploaded avatar's url: ${avatar_url}"
  got=$(kubectl exec "${profile}" -c profile -- sha256sum "${public}/${avatar_id}" | cut -d' ' -f1)
  [[ "${got}" == "${avatar_sha}" ]] || fail "the avatar read back (${avatar_sha}) is not the volume's ${public}/${avatar_id} (${got})"
  kubectl rollout restart "${profile}" > /dev/null
  kubectl rollout status "${profile}" --timeout 10m > /dev/null || fail "${profile} not rolled out again"
  got=$(fxa_py ip-b URL="${avatar_url}" <<'PY'
import hashlib, os
import requests
res = requests.get(os.environ["URL"], timeout=30)
print(res.status_code, hashlib.sha256(res.content).hexdigest())
PY
) || fail "the avatar after the restart: ${got}"
  [[ "${got}" == "200 ${avatar_sha}" ]] || fail "the avatar after kubectl rollout restart ${profile}: ${got}, before 200 ${avatar_sha}"
  kubectl delete pod ip-a ip-b --wait=true > /dev/null
  check "avatars: the default one at https://profile.fxa.test/img/a/0… 200; alice's upload (profile:write) read back as the volume's bytes, the same after kubectl rollout restart ${profile}"

  # the admin UI with the accounts, as tests/e2e-fxa.sh's test_fxa_admin.py: the sign-up gate
  # behind the Ingress (refusals readable, the database refusing them without it), sign-in
  # with the accounts (ADMIN_FXA_CLIENT_ID), max accounts, the health of every component
  # (Redis with its password), the public URLs and their certificates, the security history
  # (FXA_DB_SERVER as tests/e2e-fxa.sh sets it: the version the health table shows, a regex)
  local fxa_db_server db_tag=${db_image##*:} admin_db_password fxa_mysql_password server=MySQL
  [[ ${backend} == mariadb ]] && server=MariaDB
  case "${db_tag}" in
    [0-9]*.[0-9]*) fxa_db_server="${server} ${db_tag//./\\.}" ;;
    [0-9]*) fxa_db_server="${server} ${db_tag}\\." ;;
    *) fxa_db_server="${server} [0-9]+\\.[0-9]+" ;;
  esac
  admin_db_password=$(kubectl get secret "${SECRET}" -o jsonpath='{.data.ADMIN_DB_PASSWORD}' | base64 -d)
  fxa_mysql_password=$(kubectl get secret "${SECRET}" -o jsonpath='{.data.FXA_MYSQL_PASSWORD}' | base64 -d)
  # (the databases as the admin UI has them: its env)
  admin_env() { kubectl get "deploy/${FULL}-admin" -o json | jq -r --arg n "$1" '.spec.template.spec.containers[0].env[] | select(.name == $n) | .value'; }
  # (as the accounts' user, tests/e2e-fxa.sh's FXA_MYSQL_USER: root of the bundled server,
  # fxa on your own)
  local fxa_db_url admin_db_url fxa_user=root fxa_host="${FULL}-fxa-db"
  [[ -z "${external}" ]] || fxa_user=fxa fxa_host=extdb-fxa
  # (the admin UI's own database on the Sync server's: PostgreSQL's one server with SYNC_BACKEND=postgres)
  local admin_scheme=mysql admin_server="${FULL}-tokenserver-db:3306"
  [[ ${SYNC_BACKEND} == postgres ]] && admin_scheme=postgresql admin_server="${FULL}-postgres:5432"
  fxa_db_url="mysql://${fxa_user}:${fxa_mysql_password}@$(admin_env FXA_DB_HOST):$(admin_env FXA_DB_PORT)/fxa"
  admin_db_url="${admin_scheme}://$(admin_env ADMIN_DB_USER):${admin_db_password}@$(admin_env TOKENSERVER_DB_HOST):$(admin_env TOKENSERVER_DB_PORT)/$(admin_env ADMIN_DB_NAME)"
  [[ "${fxa_db_url}" == "mysql://${fxa_user}:${fxa_mysql_password}@${fxa_host}:3306/fxa" && "${admin_db_url}" == "${admin_scheme}://ffs_admin_ui:${admin_db_password}@${admin_server}/ffs_admin" ]] \
    || fail "the admin UI's databases: ${fxa_db_url//${fxa_mysql_password}/***} ${admin_db_url//${admin_db_password}/***}"
  # (test-only: the tests look at the accounts database as root, as tests/e2e-fxa.sh on compose's
  # network; the chart's fxa.networkPolicy lets only the accounts' servers and the admin UI in,
  # a second policy adds the test pod)
  jq -n --arg rel "${REL}" '{apiVersion: "networking.k8s.io/v1", kind: "NetworkPolicy", metadata: {name: "ffs-e2e-fxa-db"},
    spec: {podSelector: {matchLabels: {"app.kubernetes.io/instance": $rel, "app.kubernetes.io/component": "fxa-db"}}, policyTypes: ["Ingress"],
      ingress: [{from: [{podSelector: {matchLabels: {"ffs-e2e": "fxa-test-admin"}}}], ports: [{protocol: "TCP", port: 3306}]}]}}' | kubectl apply -f - > /dev/null
  local admin_k="admin_needs_the_password or signup_refused_with_a_readable_error or signup_refused_without_the_gate"
  admin_k+=" or allowlist_matches_emails_and_domains or signups_closed_and_reopened or admin_lists_accounts or admin_sso_client_registered"
  admin_k+=" or admin_sso_with_an_allowed_account or admin_sso_refuses_other_accounts or max_accounts_from_admin"
  admin_k+=" or spoofed_forwarded_for_does_not_bypass_rate_limit or health_and_sizes or public_urls_and_certificates or gate_probe_creates_nothing"
  admin_k+=" or schema_levels or security_history"
  fxa_job admin "${SYNC_IMAGE}" "/tests/test_fxa_admin.py -rs -k \"${admin_k}\"" ADMIN_FXA_CLIENT_ID=ad41a7e5f0c0ffee FXA_ACCOUNT_EVENTS=true \
    FXA_DB_SERVER="${fxa_db_server}" FXA_TEST_DB_URL="${fxa_db_url}" ADMIN_DB_URL="${admin_db_url}" TOKENSERVER_DB_TYPE="$(admin_env TOKENSERVER_DB_TYPE)" \
    || fail "test_fxa_admin.py failed"
  # (16 tests; of -k security_history, test_security_history_off is skipped with the history on)
  got=$(kubectl logs job/fxa-test-admin | tail -1)
  [[ "${got}" =~ ^16\ passed,\ 1\ skipped,\ [0-9]+\ deselected(,\ [0-9]+\ warnings?)?\ in ]] || fail "test_fxa_admin.py: not the 16 tests passed: ${got}"
  kubectl logs job/fxa-test-admin | grep '^SKIPPED' | grep -qv 'FXA_ACCOUNT_EVENTS is true' && fail "test_fxa_admin.py skipped: $(kubectl logs job/fxa-test-admin | grep '^SKIPPED')"
  check "test_fxa_admin.py (the gate, sign-in with the accounts, max accounts, health, certificates, security history): ${got}"

  # the backups with the accounts (backup.enabled): one run of the CronJob, the accounts
  # first (its init container, allowed into fxa-db by fxa.networkPolicy), then Sync, which
  # records both; the five dumps pass gzip -t; fxa's restored as docs/backups.md#restore-on-kubernetes says
  # (its restore(), in the container backup-accounts) into a scratch database, as
  # tests/e2e-fxa.sh: the same accounts and procedures; then all five over the real ones; the
  # run on the admin UI's Backups card. With your own accounts server, Sync's alone
  kubectl create job --from="cronjob/${FULL}-backup" backup-now-1 > /dev/null || fail "kubectl create job --from=cronjob/${FULL}-backup failed"
  wait_job backup-now-1 900 > /dev/null || fail "the backup-now-1 Job did not complete: $(kubectl logs job/backup-now-1 --all-containers 2>&1 | tail -20)"
  if [[ -n "${external}" ]]; then
    # (your own accounts server: the Sync scope alone, as compose's backups,
    # docs/backups.md#your-own-database-server: the accounts' user cannot read ffs there)
    [[ "$(kubectl get cronjob "${FULL}-backup" -o json | jq -c '[.spec.jobTemplate.spec.template.spec | (.initContainers // [])[].name, .containers[].name]')" == '["backup"]' ]] \
      || fail "the backups with your own accounts server: $(kubectl get cronjob "${FULL}-backup" -o json | jq -c '.spec.jobTemplate.spec.template.spec | [(.initContainers // [])[].name, .containers[].name]')"
    kubectl logs job/backup-now-1 -c backup | grep -q "^backup sync: ok: /backups/sync/" || fail "backup-now-1: Sync not dumped: $(kubectl logs job/backup-now-1 -c backup)"
    kubectl delete job backup-now-1 --wait=true > /dev/null
    # (and the admin UI's Backups card says so: FXA_DB_HOST not the chart's fxa-db)
    fxa_client_pod backups-card
    got=$(fxa_py backups-card <<'PY'
import re
import test_fxa_admin as t
card = t.Admin().page().split('id="backups-card"')[1].split("</section>")[0]
print(" ".join(w for w in ("the Sync scope alone", "both scopes", "accounts/&lt;UTC time&gt;", "Not the accounts databases") if w in card))
PY
) || fail "the admin UI's Backups card: ${got}"
    kubectl delete pod backups-card --wait=true > /dev/null
    [[ "${got}" == "the Sync scope alone Not the accounts databases" ]] || fail "the admin UI's Backups card with your own accounts server says: ${got}"
    check "kubectl create job --from=cronjob/${FULL}-backup backup-now-1: the Sync scope alone with your own accounts server (no backup-accounts), complete; the admin UI's Backups card says the Sync scope alone"
  else
    got=$(kubectl logs job/backup-now-1 -c backup-accounts)
    [[ "${got}" =~ backup\ accounts:\ ok:\ /backups/accounts/([0-9]{8}T[0-9]{6}Z), ]] || fail "backup-now-1: the accounts not dumped: ${got}"
    local stamp=${BASH_REMATCH[1]}
    kubectl logs job/backup-now-1 -c backup | grep -q "^backup sync: ok: /backups/sync/" || fail "backup-now-1: Sync not dumped: $(kubectl logs job/backup-now-1 -c backup)"
    check "kubectl create job --from=cronjob/${FULL}-backup backup-now-1: complete, the accounts dumped first (backup-accounts, ${stamp}), then Sync"
    # (docs/backups.md#restore-on-kubernetes's restore() and its command of the accounts, as they are there)
    local backups_md="${REPO_ROOT}/docs/backups.md" restore_fn restore_cmd
    restore_fn=$(sed -n '/^    restore() {/,/^    }$/p' "${backups_md}")
    restore_cmd=$(sed -n "/^    restore restore-accounts 'run=/,/backup-accounts$/p" "${backups_md}")
    [[ -n "${restore_fn}" && -n "${restore_cmd}" ]] || fail "docs/backups.md#restore-on-kubernetes: no restore() or no restore restore-accounts"
    eval "${restore_fn}"
    # shellcheck disable=SC2034 # (the page's restore() reads it)
    local F=${FULL}
    got=$(restore restore-ls "cd /backups/accounts/${stamp} && for f in *.sql.gz; do gzip -t \$f && echo \$f; done" backup-accounts 2>&1 | grep '\.sql\.gz$' | LC_ALL=C sort | paste -sd' ' -)
    [[ "${got}" == "ffs.sql.gz fxa.sql.gz fxa_oauth.sql.gz fxa_profile.sql.gz pushbox.sql.gz" ]] || fail "accounts/${stamp}: ${got}"
    check "accounts/${stamp}: the five databases (ffs fxa fxa_oauth fxa_profile pushbox), each passing gzip -t"
    local accounts
    accounts=$(fxa_db_sql "SELECT COUNT(*) FROM fxa.accounts")
    [[ "${accounts}" =~ ^[1-9][0-9]*$ ]] || fail "no accounts to back up: ${accounts}"
    routines() { fxa_db_sql "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = '$1'"; }
    # (into the scratch database, fxa alone; MariaDB's client with MariaDB, as the page says)
    local full_cmd=${restore_cmd}
    [[ ${backend} == mariadb ]] && full_cmd=${full_cmd//mysql -h/mariadb -h}
    restore_cmd=$(sed -e 's/for db in fxa fxa_oauth fxa_profile pushbox ffs; do/for db in fxa; do/' -e 's/CREATE DATABASE IF NOT EXISTS \$db/CREATE DATABASE IF NOT EXISTS ffs_restore_test/' \
      -e 's/ \$db || exit 1$/ ffs_restore_test || exit 1/' <<< "${full_cmd}")
    [[ "$(grep -c ffs_restore_test <<< "${restore_cmd}")" == 2 ]] || fail "docs/backups.md's restore of the accounts not made a scratch one: ${restore_cmd}"
    # shellcheck disable=SC2034 # (the page's command reads it)
    local accounts_run=${stamp}
    eval "${restore_cmd}" > /dev/null || fail "docs/backups.md's restore of the accounts (into ffs_restore_test) failed: $(kubectl logs job/restore-accounts 2>&1 | tail -10)"
    [[ "$(fxa_db_sql "SELECT COUNT(*) FROM ffs_restore_test.accounts")" == "${accounts}" ]] || fail "ffs_restore_test.accounts: $(fxa_db_sql "SELECT COUNT(*) FROM ffs_restore_test.accounts"), fxa.accounts ${accounts}"
    [[ "$(routines ffs_restore_test)" == "$(routines fxa)" ]] || fail "ffs_restore_test's procedures: $(routines ffs_restore_test), fxa's $(routines fxa)"
    fxa_db_sql "DROP DATABASE ffs_restore_test" > /dev/null
    kubectl delete job restore-ls restore-accounts --wait=true > /dev/null
    check "fxa.sql.gz restored with docs/backups.md#restore-on-kubernetes's restore() (backup-accounts, as root) into ffs_restore_test: the same ${accounts} accounts and $(routines fxa) procedures as fxa; dropped"

    # the whole set once, as the page says, into empty databases: the accounts' servers and the
    # admin UI stopped (its step 1), a run taken while nothing writes (the comparison exact),
    # the five databases dropped, its command as it is (ffs last, its views and procedures with
    # their DEFINER, the dumps' user), the servers started again (auth's init containers
    # install the policy's trigger again)
    local stopped="deploy/${FULL}-fxa-auth deploy/${FULL}-fxa-content deploy/${FULL}-fxa-profile deploy/${FULL}-admin" contents_before contents_after
    local stopped_names="fxa-auth fxa-content fxa-profile admin"
    # (SYNC_BACKEND=postgres: the Sync scope restored too, the Sync server stopped first, the page's step 1)
    if [[ ${SYNC_BACKEND} == postgres ]]; then
      stopped+=" deploy/${FULL}-syncstorage" stopped_names+=" syncstorage"
    fi
    # shellcheck disable=SC2086 # (the list)
    kubectl scale ${stopped} --replicas=0 > /dev/null
    for name in ${stopped_names}; do
      kubectl wait --for=delete pod -l "app.kubernetes.io/instance=${REL},app.kubernetes.io/component=${name}" --timeout=5m > /dev/null || fail "${FULL}-${name} not stopped"
    done
    kubectl create job --from="cronjob/${FULL}-backup" backup-now-2 > /dev/null || fail "kubectl create job --from=cronjob/${FULL}-backup failed"
    wait_job backup-now-2 900 > /dev/null || fail "the backup-now-2 Job did not complete: $(kubectl logs job/backup-now-2 --all-containers 2>&1 | tail -20)"
    [[ "$(kubectl logs job/backup-now-2 -c backup-accounts)" =~ backup\ accounts:\ ok:\ /backups/accounts/([0-9]{8}T[0-9]{6}Z), ]] \
      || fail "backup-now-2: the accounts not dumped: $(kubectl logs job/backup-now-2 -c backup-accounts)"
    accounts_run=${BASH_REMATCH[1]}
    # (what the five hold: rows of a few tables, the views and procedures of ffs with their DEFINER, every routine and event)
    contents() {
      fxa_db_sql "SELECT CONCAT_WS(' ', (SELECT COUNT(*) FROM fxa.accounts), (SELECT COUNT(*) FROM fxa.sessionTokens), (SELECT COUNT(*) FROM fxa.devices),
          (SELECT COUNT(*) FROM fxa_oauth.refreshTokens), (SELECT COUNT(*) FROM ffs.settings), (SELECT COUNT(*) FROM ffs.signup_allowlist));
        SELECT CONCAT('view ', TABLE_NAME, ' ', DEFINER) FROM information_schema.VIEWS WHERE TABLE_SCHEMA = 'ffs' ORDER BY 1;
        SELECT CONCAT(ROUTINE_SCHEMA, ' ', ROUTINE_TYPE, ' ', ROUTINE_NAME, ' ', DEFINER) FROM information_schema.ROUTINES
          WHERE ROUTINE_SCHEMA IN ('fxa', 'fxa_oauth', 'fxa_profile', 'pushbox', 'ffs') ORDER BY 1;
        SELECT CONCAT('event ', EVENT_SCHEMA, ' ', EVENT_NAME) FROM information_schema.EVENTS ORDER BY 1" | sha256sum | cut -c1-16
    }
    local ffs_views
    ffs_views=$(fxa_db_sql "SELECT COUNT(*) FROM information_schema.VIEWS WHERE TABLE_SCHEMA = 'ffs'")
    [[ "${ffs_views}" -gt 0 ]] || fail "ffs has no views to restore"
    contents_before=$(contents)
    fxa_db_sql "DROP DATABASE ffs; DROP DATABASE pushbox; DROP DATABASE fxa_profile; DROP DATABASE fxa_oauth; DROP DATABASE fxa" > /dev/null || fail "the accounts' databases not dropped"
    eval "${full_cmd}" > /dev/null || fail "docs/backups.md's restore of the accounts failed: $(kubectl logs job/restore-accounts 2>&1 | tail -10)"
    contents_after=$(contents)
    [[ "${contents_after}" == "${contents_before}" ]] || fail "the accounts restored are not what was dumped (${contents_after}, before ${contents_before})"
    local sync_restored=""
    if [[ ${SYNC_BACKEND} == postgres ]]; then
      fxa_postgres_restore backup-now-2
      sync_restored="; the Sync scope (PostgreSQL: ${SYNC_RESTORED})"
    fi
    # shellcheck disable=SC2086 # (the list)
    kubectl scale ${stopped} --replicas=1 > /dev/null
    for name in ${stopped_names}; do
      kubectl rollout status "deploy/${FULL}-${name}" --timeout 15m > /dev/null || fail "${FULL}-${name} not back after the restore"
    done
    [[ "$(fxa_db_sql "SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_name = 'ffs_signup_policy'")" == 1 ]] || fail "the sign-up policy's trigger not installed again after the restore"
    # (--ignore-not-found: the Jobs of kubectl create job --from=cronjob are the CronJob's, which
    # keeps the newest 3 that succeeded, successfulJobsHistoryLimit; SYNC_BACKEND=postgres' two
    # more restores make backup-now-2 an older one)
    kubectl delete job backup-now-2 restore-accounts --ignore-not-found --wait=true > /dev/null
    check "the accounts restored whole as docs/backups.md#restore-on-kubernetes says (${accounts_run}, into the five dropped): their rows, ffs' ${ffs_views} views and the procedures with their DEFINER, the events as dumped${sync_restored}; the servers back, the policy's trigger again"
    fxa_client_pod backups-card
    got=$(fxa_py backups-card <<'PY'
import re, time
import test_fxa_admin as t
admin, row = t.Admin(), ""
for _ in range(60):
    found = re.search(r'<p class="hint" data-scope="accounts">(.*?)</p>', admin.page(), re.S)
    row = re.sub(r"<[^>]+>", "", found.group(1)) if found else ""
    if found and '<span class="ok">ok</span>' in found.group(1):
        break
    time.sleep(2)
print(row)
PY
) || fail "the admin UI's Backups card: ${got}"
    [[ "${got}" == "Last backup of the "*", ok." ]] || fail "the admin UI's Backups card, scope accounts: '${got}'"
    kubectl delete pod backups-card --wait=true > /dev/null
    kubectl delete job backup-now-1 --ignore-not-found --wait=true > /dev/null
    check "the admin UI's Backups card: a row of the scope accounts (${got})"
  fi

  # a real Firefox, as tests/e2e-fxa.sh's (Firefox's image, as its own user): sign-up on one
  # profile, Sync to a second one, the admin UI's sign-in with these accounts; the pairing
  # server's websockets
  if [[ -z "${SKIP_BROWSER:-}" ]]; then
    fxa_job browser "${BROWSER_IMAGE}" "/tests/test_fxa_browser.py /tests/test_fxa_pairing.py" ADMIN_FXA_CLIENT_ID=ad41a7e5f0c0ffee \
      || { # what the failed tests' Firefox windows showed (wait_job printed the last lines only)
        kubectl logs job/fxa-test-browser | sed -n '/^==== /,/^=* FAILURES/p' | head -300
        fail "test_fxa_browser.py, test_fxa_pairing.py failed"; }
    got=$(kubectl logs job/fxa-test-browser | tail -1)
    [[ "${got}" =~ ^9\ passed(,\ [0-9]+\ warnings?)?\ in ]] || fail "test_fxa_browser.py, test_fxa_pairing.py: not their 9 tests passed: ${got}"
    check "a real Firefox (test_fxa_browser.py) and the pairing server (test_fxa_pairing.py) through the Ingresses: ${got}"
  fi

}

# fxa_e2e_survival: what must survive (PART=survival; the bundled server alone; its names:
# fxa_e2e's, which calls it)
fxa_e2e_survival() {
  # what must survive what follows (test_fxa_upgrade.py, before): an account with its session
  # and device, an OAuth refresh token, Sync data; FXA_OLD_LEVELS the schema levels now
  # (dbMetadata), which the admin UI shows. Its "after" (upgrade_after) runs after each step
  local old_levels
  old_levels=$(fxa_levels)
  fxa_job upgrade-before "${SYNC_IMAGE}" /tests/test_fxa_upgrade.py FXA_UPGRADE_PHASE=before UPGRADE_STATE=/state/upgrade.json \
    FXA_OLD_LEVELS="${old_levels}" || fail "test_fxa_upgrade.py before failed"
  got=$(kubectl logs job/fxa-test-upgrade-before | tail -1)
  [[ "${got}" =~ ^2\ passed,\ 7\ skipped(,\ [0-9]+\ warnings?)?\ in ]] || fail "test_fxa_upgrade.py before: not its 2 tests passed: ${got}"
  check "test_fxa_upgrade.py before (${old_levels}): ${got}"

  # migrations on every new auth pod: an upgrade that changes its pod, the new one ran the
  # migrations (the patcher to each database's level), the schema at the image's
  # target-patch.json; the Secret and the keys as they were, the sessions still work
  local auth_pod keys_before secret_before db
  auth_pod=$(fxa_auth_pod)
  keys_before=$(fxa_keys_hash)
  secret_before=$(kubectl get secret "${SECRET}" -o json | jq -cS .data)
  helm upgrade "${REL}" "${CHART_DIR}" --reuse-values --set fxa.resources.auth.requests.cpu=50m --wait --timeout 20m > /dev/null \
    || fail "helm upgrade with fxa.resources.auth.requests.cpu=50m failed"
  admin_test_env
  got=$(fxa_auth_pod)
  [[ -n "${got}" && "${got}" != "${auth_pod}" ]] || fail "helm upgrade: the auth pod is ${got:-none}, before ${auth_pod}"
  [[ "$(kubectl get deploy "${FULL}-fxa-auth" -o json | jq -r '.spec.template.spec.containers[] | select(.name == "auth") | .resources.requests.cpu')" == 50m ]] \
    || fail "helm upgrade: auth's cpu request not 50m"
  [[ "$(kubectl get pod "${got}" -o json | jq -r '.status.initContainerStatuses[] | select(.name == "migrations") | .state.terminated.exitCode')" == 0 ]] \
    || fail "the new auth pod's migrations: $(kubectl get pod "${got}" -o json | jq -c '.status.initContainerStatuses[] | select(.name == "migrations") | .state')"
  out=$(kubectl logs "${got}" -c migrations)
  for db in fxa fxa_oauth fxa_profile pushbox; do
    grep -qE "^Successfully patched ${db} to [0-9]+$" <<< "${out}" || fail "the new auth pod's migrations did not patch ${db}: $(tail -5 <<< "${out}")"
  done
  [[ "$(fxa_levels)" == "$(fxa_target_levels)" ]] || fail "the schema levels $(fxa_levels), the image's target-patch.json $(fxa_target_levels)"
  [[ "$(kubectl get secret "${SECRET}" -o json | jq -cS .data)" == "${secret_before}" ]] || fail "helm upgrade changed the Secret ${SECRET}'s data"
  [[ "$(fxa_keys_hash)" == "${keys_before}" ]] || fail "helm upgrade changed the keys: $(fxa_keys_hash), before ${keys_before}"
  upgrade_after "the upgrade"
  check "helm upgrade (auth's cpu request): a new auth pod, its migrations 0 (Successfully patched fxa, fxa_oauth, fxa_profile, pushbox), the levels the image's target-patch.json ($(fxa_levels)); the Secret and the keys unchanged; test_fxa_upgrade.py after: ${UPGRADE_AFTER}"

  # fail closed on the policy: a value it refuses stops the new auth pod at the policy (the
  # old one gone first: Recreate), out of its Service. (Content and profile stay Ready: their
  # probes are their own heartbeats, as compose's healthchecks, which do not ask auth.) The
  # values again with helm upgrade: auth Ready
  auth_pod=$(fxa_auth_pod)
  kubectl set env "${auth}" -c policy FXA_MAX_ACCOUNTS=lots > /dev/null
  kubectl wait --for=delete "pod/${auth_pod}" --timeout=5m > /dev/null || fail "the old auth pod ${auth_pod} still there"
  wait_init_failed policy 600 || fail "the auth pod's policy did not fail on FXA_MAX_ACCOUNTS=lots"
  # (Init:Error a moment, then Init:CrashLoopBackOff; between them its next run, Init:3/5)
  wait_pod_status 'Init:(Error|CrashLoopBackOff)' 300 || fail "the auth pod is $(pod_status), not in Init:Error"
  inits=$(kubectl get pods -l "${POD_SELECTOR}" -o json | jq -r '.items[0].status.initContainerStatuses[]
    | "\(.name)=\(.state.terminated.exitCode // .lastState.terminated.exitCode // "none")"' | paste -sd' ' -) || true
  [[ "${inits}" =~ migrations=0\ policy=[1-9] ]] || fail "expected the migrations to pass and the policy to fail: ${inits}"
  [[ "$(kubectl get pods -l "${POD_SELECTOR}" -o name | wc -l)" == 1 ]] || fail "auth pods: $(kubectl get pods -l "${POD_SELECTOR}" -o name | paste -sd' ' -)"
  for _ in $(seq 1 6); do
    ready=$(kubectl get endpointslices -l "kubernetes.io/service-name=${FULL}-fxa-auth" -o json \
      | jq '[.items[].endpoints[]? | select(.conditions.ready == true)] | length')
    [[ "${ready}" == 0 ]] || fail "${FULL}-fxa-auth has ${ready} ready endpoints while the policy fails"
    sleep 5
  done
  [[ "$(kubectl logs "$(fxa_auth_pod)" -c policy 2>&1; kubectl logs "$(fxa_auth_pod)" -c policy --previous 2>&1)" == *lots* ]] \
    || fail "the policy's log does not name the refused value: $(kubectl logs "$(fxa_auth_pod)" -c policy 2>&1 | tail -3)"
  for name in content profile; do
    [[ "$(kubectl get deploy "${FULL}-fxa-${name}" -o jsonpath='{.status.readyReplicas}')" == 1 ]] || fail "${FULL}-fxa-${name} not Ready while auth is down"
  done
  check "FXA_MAX_ACCOUNTS=lots: the old auth pod gone, the new one in ${MATCHED_STATUS} (${inits}), no ready endpoint for 30 s; content and profile Ready (their own heartbeats)"
  # (Helm 4's server-side apply takes back a field kubectl changed only with --force-conflicts,
  # which Helm 3 has not: its three-way merge does it by itself)
  local take_back=()
  [[ "$(helm version --template '{{.Version}}')" == v3.* ]] || take_back=(--force-conflicts)
  helm upgrade "${REL}" "${CHART_DIR}" --reuse-values "${take_back[@]}" --wait --timeout 20m > /dev/null \
    || fail "helm upgrade${take_back[*]/#/ } did not put the policy's values back"
  admin_test_env
  [[ "$(kubectl get deploy "${FULL}-fxa-auth" -o json | jq -r '.spec.template.spec.initContainers[] | select(.name == "policy") | .env[] | select(.name == "FXA_MAX_ACCOUNTS") | .value')" != lots ]] \
    || fail "helm upgrade --reuse-values left FXA_MAX_ACCOUNTS=lots"
  kubectl wait --for=condition=Ready pod -l "${POD_SELECTOR}" --timeout=10m > /dev/null || fail "auth not Ready after helm upgrade"
  check "helm upgrade --reuse-values: the policy's values back, auth Ready"

  # Redis lost (emptyDir) when its pod moves signs nobody out
  kubectl delete pod -l "app.kubernetes.io/instance=${REL},app.kubernetes.io/component=fxa-redis" --wait=true > /dev/null
  kubectl rollout status "deploy/${FULL}-fxa-redis" --timeout 5m > /dev/null || fail "fxa-redis not back"
  kubectl wait --for=condition=Ready pod -l "app.kubernetes.io/instance=${REL},app.kubernetes.io/component=fxa-redis" --timeout=5m > /dev/null \
    || fail "fxa-redis not Ready"
  upgrade_after "a new Redis pod"
  check "kubectl delete pod of fxa-redis: Ready again, test_fxa_upgrade.py after: ${UPGRADE_AFTER}"

  # the admin UI off: the auth Ingress without the gate, the database still refuses what
  # the policy does not allow (straight to auth, and through the Ingress)
  helm upgrade "${REL}" "${CHART_DIR}" --reuse-values --set admin.enabled=false --wait --timeout 15m > /dev/null || fail "helm upgrade with admin.enabled=false failed"
  admin_test_env
  ingress_is "${FULL}-fxa-auth" traefik api.fxa.test "${FULL}-fxa-auth" 9000
  fxa_client_pod gate-off
  out=$(fxa_py gate-off <<'PY'
import test_fxa_admin as t
t.test_signup_refused_without_the_gate()
address = t.email("example.org")
res = t.create(address)
assert res.status_code >= 400 and not t.exists(address), res.text
print(res.status_code)
PY
) || fail "admin.enabled=false: test_signup_refused_without_the_gate: ${out}"
  kubectl delete pod gate-off --wait=true > /dev/null
  check "admin.enabled=false: the auth Ingress has / alone; test_signup_refused_without_the_gate passes, a refused sign-up through it gets ${out}"

  # the keys across helm uninstall and install: the Secret and the kept volumes stay, the same
  # keys after an install with the values of the first one, the sessions still work. Then in
  # a Secret of yours (fxa.keys.existingSecret), exported as the NOTES say, the keys' volume
  # deleted: the same keys again; that Secret without openid-key.json stops auth at keys-copy
  keys_before=$(fxa_keys_hash)
  secret_before=$(kubectl get secret "${SECRET}" -o json | jq -cS .data)
  helm uninstall "${REL}" --wait --timeout 5m > /dev/null || fail "helm uninstall failed"
  for name in "secret/${SECRET}" "pvc/${FULL}-fxa-keys" "pvc/${FULL}-fxa-profile-images" "pvc/${claim}"; do
    kubectl get "${name}" > /dev/null 2>&1 || fail "${name} gone with helm uninstall"
  done
  check "helm uninstall: secret/${SECRET}, pvc/${FULL}-fxa-keys, pvc/${FULL}-fxa-profile-images and pvc/${claim} kept"
  helm install "${install[@]}" --wait --timeout 20m > /dev/null || fail "helm install again did not get Ready"
  admin_test_env
  [[ "$(fxa_keys_hash)" == "${keys_before}" ]] || fail "helm install again: other keys, $(fxa_keys_hash), before ${keys_before}"
  [[ "$(kubectl get secret "${SECRET}" -o json | jq -cS .data)" == "${secret_before}" ]] || fail "helm install again changed the kept Secret ${SECRET}'s data"
  upgrade_after "helm uninstall and install"
  check "helm install again (the first one's values): the same keys (sha256), the kept Secret's data unchanged, test_fxa_upgrade.py after: ${UPGRADE_AFTER}"
  local keys_dir key_files=(secret-key.json public-key.json vapid-keys.json openid-key.json)
  keys_dir=$(mktemp -d)
  kubectl exec "${auth}" -c auth -- tar -C /fxa-keys -c "${key_files[@]}" | tar -x -C "${keys_dir}" || fail "the keys not exported from ${auth}"
  kubectl create secret generic ffs-fxa-keys --from-file="${keys_dir}" > /dev/null || fail "Secret ffs-fxa-keys not created"
  helm uninstall "${REL}" --wait --timeout 5m > /dev/null || fail "helm uninstall failed"
  kubectl delete pvc "${FULL}-fxa-keys" --wait=true > /dev/null || fail "pvc/${FULL}-fxa-keys not deleted"
  helm install "${install[@]}" --set fxa.keys.existingSecret=ffs-fxa-keys --wait --timeout 20m > /dev/null \
    || fail "helm install with fxa.keys.existingSecret=ffs-fxa-keys did not get Ready"
  admin_test_env
  ! kubectl get pvc "${FULL}-fxa-keys" > /dev/null 2>&1 || fail "pvc/${FULL}-fxa-keys with fxa.keys.existingSecret"
  inits=$(kubectl get pods -l "${POD_SELECTOR}" -o json | jq -r '.items[0].status.initContainerStatuses[]
    | "\(.name)=\(.state.terminated.exitCode // "none")"' | paste -sd' ' -) || true
  [[ "${inits}" == "keys-copy=0 wait-db=0 migrations=0 policy=0 wait-redis=0" ]] || fail "the auth pod's init containers with fxa.keys.existingSecret: ${inits}"
  [[ "$(fxa_keys_hash)" == "${keys_before}" ]] || fail "fxa.keys.existingSecret: other keys, $(fxa_keys_hash), before ${keys_before}"
  upgrade_after "the keys moved to fxa.keys.existingSecret"
  check "the keys exported (the NOTES' tar), their volume deleted, fxa.keys.existingSecret=ffs-fxa-keys: ${inits}, the same keys, test_fxa_upgrade.py after: ${UPGRADE_AFTER}"
  kubectl create secret generic ffs-fxa-keys --from-file="${keys_dir}/secret-key.json" --from-file="${keys_dir}/public-key.json" \
    --from-file="${keys_dir}/vapid-keys.json" --dry-run=client -o json | kubectl replace -f - > /dev/null || fail "Secret ffs-fxa-keys not replaced"
  kubectl delete pod -l "${POD_SELECTOR}" --wait=true > /dev/null
  wait_init_failed keys-copy 300 || fail "keys-copy did not fail without openid-key.json"
  wait_pod_status 'Init:(Error|CrashLoopBackOff)' 300 || fail "the auth pod is $(pod_status), not in Init:Error"
  out=$(kubectl logs "$(fxa_auth_pod)" -c keys-copy 2>&1; kubectl logs "$(fxa_auth_pod)" -c keys-copy --previous 2>&1) || true
  grep -q "fxa.keys.existingSecret ffs-fxa-keys lacks: openid-key.json" <<< "${out}" || fail "keys-copy's log: ${out}"
  check "fxa.keys.existingSecret without openid-key.json: auth in ${MATCHED_STATUS} at keys-copy, its log: $(grep -m1 lacks <<< "${out}")"
  kubectl create secret generic ffs-fxa-keys --from-file="${keys_dir}" --dry-run=client -o json | kubectl replace -f - > /dev/null || fail "Secret ffs-fxa-keys not put back"
  rm -rf "${keys_dir}"
  kubectl delete pod -l "${POD_SELECTOR}" --wait=true > /dev/null
  fxa_auth_ready 15m || fail "auth not Ready with ffs-fxa-keys put back"

  # fxa.volumeOwnerInit=false on new volumes: no root init container; auth writes its keys
  # and profile its avatars. (kind's local-path volumes are hostPath ones, a directory of
  # root's, 0777, where the kubelet applies no fsGroup: the fsGroup case itself is the docker
  # check before the install)
  helm uninstall "${REL}" --wait --timeout 5m > /dev/null || fail "helm uninstall failed"
  # (the release's volumes, not the tests' state; the tests' Jobs first, their completed pods
  # hold that volume)
  fxa_delete_test_jobs
  kubectl get pvc -o name | { grep -vx persistentvolumeclaim/fxa-test-state || true; } | xargs -r kubectl delete --wait=true > /dev/null
  helm install "${install[@]}" --set fxa.volumeOwnerInit=false --wait --timeout 20m > /dev/null \
    || fail "helm install with fxa.volumeOwnerInit=false did not get Ready"
  for name in "auth:wait-db=0 migrations=0 policy=0 wait-redis=0" "profile:images-seed=0 wait-auth=0"; do
    got=$(kubectl get pods -l "app.kubernetes.io/instance=${REL},app.kubernetes.io/component=fxa-${name%%:*}" -o json | jq -r '.items[0].status.initContainerStatuses[]
      | "\(.name)=\(.state.terminated.exitCode // "none")"' | paste -sd' ' -) || true
    [[ "${got}" == "${name#*:}" ]] || fail "fxa.volumeOwnerInit=false: the ${name%%:*} pod's init containers: ${got}"
  done
  [[ "$(kubectl exec "${auth}" -c auth -- ls /fxa-keys | paste -sd' ' -)" == "oauth-clients.json openid-key.json openid-oldKey.json public-key.json secret-key.json vapid-keys.json" ]] \
    || fail "fxa.volumeOwnerInit=false: /fxa-keys has $(kubectl exec "${auth}" -c auth -- ls -l /fxa-keys)"
  got=$(kubectl exec "${profile}" -c profile -- sh -c "touch ${public}/w && rm ${public}/w && stat -c '%u:%g %a' ${public} && ls -A ${public}" | paste -sd' ' -) \
    || fail "fxa.volumeOwnerInit=false: profile cannot write the avatars' volume: ${got}"
  [[ "${got}" == *" .keep" ]] || fail "fxa.volumeOwnerInit=false: the avatars' volume: ${got}"
  check "fxa.volumeOwnerInit=false, new volumes: auth's init containers without keys-owner, its keys written; profile's without images-owner, the avatars' volume (${got% .keep}) seeded and written by 10001"

  # the accounts turned on in a release whose existingSecret has the Sync server's keys alone:
  # refused at render time, naming what it lacks, the release as it was
  helm uninstall "${REL}" --wait --timeout 5m > /dev/null || fail "helm uninstall failed"
  kubectl get secret "${SECRET}" -o json | jq '{apiVersion: "v1", kind: "Secret", metadata: {name: "ffs-own"}, type: "Opaque",
    data: (.data | with_entries(select(.key | test("^(ADMIN_)?FXA_") | not)))}' | kubectl apply -f - > /dev/null || fail "Secret ffs-own not created"
  helm install "${install[@]}" --set fxa.enabled=false --set admin.fxaSignIn=false --set existingSecret=ffs-own --wait --timeout 15m > /dev/null \
    || fail "helm install without the accounts, existingSecret=ffs-own, did not get Ready"
  ! kubectl get deploy,sts -o name | grep -q -- '-fxa-' || fail "the accounts without fxa.enabled: $(kubectl get deploy,sts -o name | grep -- '-fxa-')"
  revision=$(helm history "${REL}" -o json | jq -r 'last | .revision')
  if out=$(helm upgrade "${REL}" "${CHART_DIR}" --reuse-values --set fxa.enabled=true --set admin.fxaSignIn=true --timeout 5m 2>&1); then
    fail "helm upgrade --set fxa.enabled=true accepted with existingSecret ffs-own"
  fi
  want="firefox-sync: existingSecret ffs-own lacks FXA_ADMIN_DB_PASSWORD, FXA_AUTH_SECRET, FXA_CONTENT_SESSION_SECRET, FXA_FLOW_ID_KEY, FXA_MYSQL_PASSWORD, FXA_OAUTH_SECRET, FXA_PROFILE_SECRET, FXA_REDIS_PASSWORD, FXA_SESSION_TOKEN_HANDLE_KEY, which the self-hosted accounts or the bootstrap accounts of your own servers need"
  grep -qF "${want}" <<< "${out}" || fail "helm upgrade --set fxa.enabled=true refused, but not by the existingSecret check: ${out}"
  [[ "$(helm history "${REL}" -o json | jq -r 'last | "\(.revision) \(.status)"')" == "${revision} deployed" ]] || fail "the refused upgrade left: $(helm history "${REL}" | tail -2)"
  ! kubectl get deploy,sts -o name | grep -q -- '-fxa-' || fail "the refused upgrade created: $(kubectl get deploy,sts -o name | grep -- '-fxa-')"
  check "existingSecret ffs-own with the Sync server's keys alone: helm upgrade --set fxa.enabled=true refused (${want#firefox-sync: }), revision ${revision} still deployed, nothing of the accounts"
}

# fxa_postgres_restore <backup Job>: SYNC_BACKEND=postgres, the Sync scope of that Job's run
# restored as docs/backups.md#restore-on-kubernetes says for PostgreSQL, its commands as they
# are there (restore() already defined, F set, the Sync server and the admin UI stopped): the
# database emptied (its PVC deleted), the Sync server's role, its one database as that role, the
# Sync server started, the admin UI's database. The same users, Sync items and rows of the admin
# UI's tables as dumped (but ffs_backups: the run records itself after its dump). SYNC_RESTORED:
# what was compared
fxa_postgres_restore() {
  local backups_md="${REPO_ROOT}/docs/backups.md" run empty_cmd pg_cmd before after
  [[ "$(kubectl logs "job/$1" -c backup)" =~ backup\ sync:\ ok:\ /backups/sync/([0-9]{8}T[0-9]{6}Z), ]] || fail "$1: Sync not dumped: $(kubectl logs "job/$1" -c backup)"
  run=${BASH_REMATCH[1]}
  # (the page's loop, of the PostgreSQL server alone; its commands of PostgreSQL)
  empty_cmd=$(sed -n '/^    for db in postgres; do/,/^    done$/p' "${backups_md}")
  pg_cmd=$(sed -n '/^    kubectl get deploy \$F-syncstorage -o json | jq/,/^        PGPASSWORD="\$ADMIN_DB_PASSWORD" psql/p' "${backups_md}")
  [[ -n "${empty_cmd}" && "$(grep -c '^ *restore restore-' <<< "${pg_cmd}")" == 2 ]] || fail "docs/backups.md#restore-on-kubernetes: not its PostgreSQL commands: ${empty_cmd} ${pg_cmd}"
  pg_sql() {
    kubectl exec "${FULL}-postgres-0" -c db -- env PGPASSWORD="$(kubectl get secret "${SECRET}" -o jsonpath="{.data.$1}" | base64 -d)" \
      psql -X -tA -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$2" -d "$3" -c "$4"
  }
  pg_contents() {
    local tables t
    printf 'users %s bsos %s' "$(pg_sql POSTGRES_SYNC_PASSWORD syncserver_app syncserver 'SELECT COUNT(*) FROM users')" \
      "$(pg_sql POSTGRES_SYNC_PASSWORD syncserver_app syncserver 'SELECT COUNT(*) FROM bsos')"
    tables=$(pg_sql ADMIN_DB_PASSWORD ffs_admin_ui ffs_admin "SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename <> 'ffs_backups' ORDER BY 1")
    for t in ${tables}; do printf ' %s %s' "${t}" "$(pg_sql ADMIN_DB_PASSWORD ffs_admin_ui ffs_admin "SELECT COUNT(*) FROM ${t}")"; done
  }
  before=$(pg_contents)
  [[ "${before}" =~ ^users\ [1-9][0-9]*\ bsos\ [1-9][0-9]*\ .*ffs_ ]] || fail "nothing of Sync or the admin UI to restore: ${before}"
  eval "${empty_cmd}" > /dev/null || fail "docs/backups.md's emptying of the PostgreSQL server failed"
  [[ "$(pg_sql POSTGRES_PASSWORD "$(kubectl exec "${FULL}-postgres-0" -c db -- printenv POSTGRES_USER)" syncserver "SELECT COUNT(*) FROM pg_tables WHERE schemaname = 'public'")" == 0 ]] \
    || fail "the PostgreSQL server not empty after docs/backups.md's loop"
  eval "${pg_cmd}" > /dev/null || fail "docs/backups.md's PostgreSQL restore (${run}) failed: $(kubectl logs job/restore-sync 2>&1 | tail -5; kubectl logs job/restore-admin 2>&1 | tail -5)"
  after=$(pg_contents)
  [[ "${after}" == "${before}" ]] || fail "the Sync scope restored (${run}) is not what was dumped: ${after}, before ${before}"
  kubectl delete job restore-sync restore-admin --ignore-not-found --wait=true > /dev/null
  # shellcheck disable=SC2034 # (read by the caller)
  SYNC_RESTORED="${run}, its role, the Sync database and the admin UI's as the page says: ${after}"
}

# admin_test_env: tests/compose/fxa.yml's test-only settings of the admin UI that
# the chart has no value for (its checks every 5 s, accounts unconfirmed at once), after every
# helm install and upgrade; nothing without the admin UI. (Those the chart has values for are
# in tests/helm/fxa-values.yaml: set here, Helm 4 would refuse the next upgrade.)
admin_test_env() {
  local admin="deploy/${FULL}-admin"
  kubectl get "${admin}" > /dev/null 2>&1 || return 0
  kubectl set env "${admin}" -c admin METRICS_FLUSH_SECONDS=5 HEALTH_CHECK_SECONDS=5 ALERT_INTERVAL_SECONDS=5 \
    ADMIN_UNCONFIRMED_HOURS=0 > /dev/null || fail "kubectl set env ${admin} failed"
  kubectl rollout status "${admin}" --timeout 10m > /dev/null || fail "${admin} not rolled out with the test settings"
}

# fxa_auth_pod: the name of the auth pod (of POD_SELECTOR), the newest one
fxa_auth_pod() {
  kubectl get pods -l "${POD_SELECTOR}" --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}' 2> /dev/null
}

# fxa_auth_ready <timeout>: an auth pod exists (a moment after its pod was deleted) and is Ready
fxa_auth_ready() {
  for _ in $(seq 1 30); do [[ -n "$(fxa_auth_pod)" ]] && break; sleep 2; done
  kubectl wait --for=condition=Ready pod -l "${POD_SELECTOR}" --timeout="$1" > /dev/null
}

# fxa_keys_hash: the sha256 of the auth server's signing keys, the files fxa.keys.existingSecret
# holds (oauth-clients.json is written from the values at every start; openid-oldKey.json is a
# placeholder FxA writes next to a new openid-key.json, verifying nothing of ours)
fxa_keys_hash() {
  kubectl exec "deploy/${FULL}-fxa-auth" -c auth -- sh -c 'cd /fxa-keys && sha256sum secret-key.json public-key.json vapid-keys.json openid-key.json' | paste -sd' ' -
}

# fxa_levels: the schema-patch-level of each accounts database (dbMetadata), "fxa=201 fxa_oauth=..."
# fxa_target_levels: those the auth image migrates to, its target-patch.json
fxa_levels() {
  local db
  for db in fxa fxa_oauth fxa_profile pushbox; do
    printf '%s=%s ' "${db}" "$(fxa_db_sql "SELECT value FROM ${db}.dbMetadata WHERE name = 'schema-patch-level'")"
  done | sed 's/ $//'
}
fxa_target_levels() {
  local db
  for db in fxa fxa_oauth fxa_profile pushbox; do
    printf '%s=%s ' "${db}" "$(kubectl exec "deploy/${FULL}-fxa-auth" -c auth -- cat "/fxa/packages/db-migrations/databases/${db}/target-patch.json" | jq -r .level)"
  done | sed 's/ $//'
}

# upgrade_after <after what>: test_fxa_upgrade.py's after phase on the state of its before
# (UPGRADE_AFTER: its result), but the admin UI's checks of a new release
upgrade_after() {
  fxa_job upgrade-after "${SYNC_IMAGE}" "/tests/test_fxa_upgrade.py -k \"old_session or old_refresh_token or sync_data_reads_back or new_sign_in or new_account\"" \
    FXA_UPGRADE_PHASE=after UPGRADE_STATE=/state/upgrade.json || fail "test_fxa_upgrade.py after $1 failed"
  UPGRADE_AFTER=$(kubectl logs job/fxa-test-upgrade-after | tail -1)
  [[ "${UPGRADE_AFTER}" =~ ^5\ passed,\ 4\ deselected(,\ [0-9]+\ warnings?)?\ in ]] || fail "test_fxa_upgrade.py after $1: not its 5 tests passed: ${UPGRADE_AFTER}"
}

# fxa_delete_test_jobs: the tests' Jobs and pods (label ffs-e2e): their completed pods hold
# fxa-test-state, a PVC deleted under them would wait for ever
fxa_delete_test_jobs() {
  kubectl delete jobs,pods -l ffs-e2e --ignore-not-found --wait=true > /dev/null
}

# fxa_extdb: your own accounts server for EXTERNAL_DB=1, as tests/e2e-fxa.sh's: a plain
# StatefulSet extdb-fxa (the database image of the e2e, its data in an emptyDir), as
# docs/databases.md#server-requirements says (binary logging, on by default on MySQL, with
# log_bin_trust_function_creators; mysql_native_password=ON only on MySQL 8, for an accounts
# image without mozilla/fxa#21554), its users made by its administrator with
# db/mysql/setup/fxa-mysql (user fxa, policy user ffs_policy; on MySQL 8 its "-- native:"
# lines); the Secret ffs-own with the chart's keys as it generates them, the passwords of
# those users and FXA_MYSQL_POLICY_PASSWORD
fxa_extdb() {
  local args='["--log-bin-trust-function-creators=ON"]' native="" data sql
  if [[ ${db_image##*:} == 8* ]]; then
    native=1 args='["--mysql-native-password=ON", "--log-bin-trust-function-creators=ON"]'
  fi
  kubectl create secret generic extdb-fxa-root --from-literal=password="$(rnd)" > /dev/null
  jq -n --arg image "${db_image}" --argjson args "${args}" '{apiVersion: "apps/v1", kind: "StatefulSet", metadata: {name: "extdb-fxa"},
    spec: {serviceName: "extdb-fxa", replicas: 1, selector: {matchLabels: {app: "extdb-fxa"}}, template: {metadata: {labels: {app: "extdb-fxa"}},
      spec: {containers: [{name: "db", image: $image, imagePullPolicy: "IfNotPresent", args: $args,
        env: [{name: "MYSQL_ROOT_PASSWORD", valueFrom: {secretKeyRef: {name: "extdb-fxa-root", key: "password"}}}],
        ports: [{name: "mysql", containerPort: 3306}],
        readinessProbe: {exec: {command: ["sh", "-c", "MYSQL_PWD=\"$MYSQL_ROOT_PASSWORD\" mysql -uroot -h 127.0.0.1 -e \"SELECT 1\""]}, periodSeconds: 5},
        volumeMounts: [{name: "data", mountPath: "/var/lib/mysql"}]}],
        volumes: [{name: "data", emptyDir: {}}]}}}}' | kubectl apply -f - > /dev/null
  jq -n '{apiVersion: "v1", kind: "Service", metadata: {name: "extdb-fxa"},
    spec: {selector: {app: "extdb-fxa"}, ports: [{name: "mysql", port: 3306, targetPort: "mysql"}]}}' | kubectl apply -f - > /dev/null
  kubectl rollout status sts/extdb-fxa --timeout 10m > /dev/null || fail "extdb-fxa (${db_image}) not Ready"
  [[ "$(fxa_db_sql 'SELECT CONCAT(@@log_bin, " ", @@log_bin_trust_function_creators)')" == "1 1" ]] || fail "extdb-fxa: log_bin, log_bin_trust_function_creators $(fxa_db_sql 'SELECT @@log_bin, @@log_bin_trust_function_creators')"
  # (the keys of the chart's own Secret, as a first install would generate them, and the policy user's)
  data=$(helm template "${install[@]}" | manifests | jq -c --arg name "${FULL}" --arg policy "$(rnd | base64)" \
    '.[] | select(.kind == "Secret" and .metadata.name == $name) | .data + {FXA_MYSQL_POLICY_PASSWORD: $policy}')
  [[ -n "${data}" ]] || fail "the chart's Secret not rendered"
  jq -n --argjson data "${data}" '{apiVersion: "v1", kind: "Secret", metadata: {name: "ffs-own"}, type: "Opaque", data: $data}' | kubectl apply -f - > /dev/null
  key() { jq -r --arg k "$1" '.[$k]' <<< "${data}" | base64 -d; }
  sql=$(if [[ -n "${native}" ]]; then sed -e "/^-- native: /{s/^-- native: //;n;d;}" "${REPO_ROOT}"/db/mysql/setup/fxa-mysql/*.sql; else cat "${REPO_ROOT}"/db/mysql/setup/fxa-mysql/*.sql; fi \
    | sed -e "s|@FXA_USER@|fxa|g" -e "s|@FXA_PASSWORD@|$(key FXA_MYSQL_PASSWORD)|g" -e "s|@FXA_POLICY_USER@|ffs_policy|g" \
      -e "s|@FXA_POLICY_PASSWORD@|$(key FXA_MYSQL_POLICY_PASSWORD)|g" -e "s|@FXA_ADMIN_PASSWORD@|$(key FXA_ADMIN_DB_PASSWORD)|g")
  ! grep -q '@[A-Z_]*@' <<< "${sql}" || fail "db/mysql/setup/fxa-mysql: placeholders left: $(grep -o '@[A-Z_]*@' <<< "${sql}" | sort -u | paste -sd' ' -)"
  kubectl exec -i extdb-fxa-0 -- sh -c 'MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" mysql -uroot' <<< "${sql}" || fail "db/mysql/setup/fxa-mysql failed on extdb-fxa"
  check "your own server extdb-fxa (${db_image}, $(jq -r 'join(" ")' <<< "${args}")), binary logging on; db/mysql/setup/fxa-mysql$([[ -z ${native} ]] || echo " (its -- native: lines)") as root (fxa, ffs_policy, ffs_admin); Secret ffs-own"
}

# wait_init_failed <init container> <seconds>: in the only pod of POD_SELECTOR, that init
# container exited with an error (now or in its previous run)
wait_init_failed() {
  local deadline=$(( $(date +%s) + $2 )) code
  while [[ $(date +%s) -lt ${deadline} ]]; do
    code=$(kubectl get pods -l "${POD_SELECTOR}" -o json | jq -r --arg c "$1" '[.items[].status.initContainerStatuses[]? | select(.name == $c)
      | .state.terminated.exitCode // .lastState.terminated.exitCode // 0] | if length == 1 then .[0] else 0 end') || code=0
    [[ "${code}" -gt 0 ]] && return 0
    sleep 2
  done
  echo "pod status: $(pod_status)"
  return 1
}

# fxa_fixtures: what the e2e runs next to the chart, as tests/compose/fxa.yml:
# the Ingress controller (tests/helm/traefik.yaml) with every *.fxa.test resolved to it (as
# compose's network aliases of Caddy), a test CA and its *.fxa.test certificate (Secret
# fxa-test-tls; the CA in the ConfigMap fxa-test-ca, root.crt, as compose's caddy-ca volume),
# the mail catcher and the tests' state (tests/helm/fxa-fixtures.yaml), the tests themselves
# (ConfigMap ffs-fxa-tests)
fxa_fixtures() {
  kubectl apply -f "${SCRIPT_DIR}/helm/traefik.yaml" > /dev/null
  # a CA for 90 days and its certificate of *.fxa.test (30 days) (the extensions Python 3.13's strict
  # verification wants: keyUsage on the CA, the key identifiers)
  local d corefile
  d=$(mktemp -d)
  openssl req -x509 -newkey rsa:2048 -nodes -days 90 -sha256 -subj "/CN=firefox-sync test CA" -keyout "${d}/ca.key" -out "${d}/root.crt" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" -addext "subjectKeyIdentifier=hash" 2> /dev/null \
    || fail "the test CA not created"
  openssl req -newkey rsa:2048 -nodes -subj "/CN=*.fxa.test" -keyout "${d}/tls.key" -out "${d}/tls.csr" 2> /dev/null || fail "the test certificate's request not created"
  printf '%s\n' "subjectAltName=DNS:*.fxa.test" "basicConstraints=critical,CA:FALSE" "keyUsage=critical,digitalSignature,keyEncipherment" \
    "extendedKeyUsage=serverAuth" "subjectKeyIdentifier=hash" "authorityKeyIdentifier=keyid,issuer" > "${d}/ext"
  # (the certificate for 30 days, as Caddy's internal CA's: test_public_urls_and_certificates
  # wants 14 to 30 days left)
  openssl x509 -req -in "${d}/tls.csr" -CA "${d}/root.crt" -CAkey "${d}/ca.key" -CAcreateserial -days 30 -sha256 -extfile "${d}/ext" \
    -out "${d}/tls.crt" 2> /dev/null || fail "the test certificate not signed"
  kubectl create secret tls fxa-test-tls --cert="${d}/tls.crt" --key="${d}/tls.key" > /dev/null
  kubectl create configmap fxa-test-ca --from-file=root.crt="${d}/root.crt" > /dev/null
  rm -rf "${d}"
  # every *.fxa.test to the controller's Service, in CoreDNS (the answers keep the name asked)
  corefile=$(kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')
  grep -qE '^ +ready$' <<< "${corefile}" || fail "CoreDNS' Corefile has no ready line: ${corefile}"
  corefile=$(sed -E 's|^( +)ready$|&\n\1rewrite name regex (.+)\\.fxa\\.test traefik.ffs-test-ingress.svc.cluster.local answer auto|' <<< "${corefile}")
  kubectl -n kube-system patch configmap coredns --type merge -p "$(jq -n --arg c "${corefile}" '{data: {Corefile: $c}}')" > /dev/null
  kubectl -n kube-system rollout restart deploy/coredns > /dev/null
  kubectl -n kube-system rollout status deploy/coredns --timeout 3m > /dev/null || fail "CoreDNS not back with the rewrite of *.fxa.test"
  local files=() f
  for f in "${SCRIPT_DIR}"/test_fxa_*.py; do files+=(--from-file="${f}"); done
  kubectl create configmap ffs-fxa-tests "${files[@]}" > /dev/null
  kubectl apply -f "${SCRIPT_DIR}/helm/fxa-fixtures.yaml" > /dev/null
  kubectl -n ffs-test-ingress rollout status deploy/traefik --timeout 3m > /dev/null || fail "Traefik not Ready"
  kubectl rollout status deploy/mailpit --timeout 3m > /dev/null || fail "Mailpit not Ready"
  check "fixtures: Traefik (IngressClass traefik) with *.fxa.test resolved to it, the test CA (fxa-test-ca) and *.fxa.test's certificate (fxa-test-tls), Mailpit, the tests (${#files[@]} files)"
}

# fxa_test_spec <image> <command (a JSON array)> [NAME=value]...: the pod spec of the tests,
# as tests/e2e-fxa.sh's runs (as root, Firefox's image as its own user tester; /tests, the CA
# at /caddy-ca, the state at /state, their env with this release's hosts, a /dev/shm of
# 1 GiB: Firefox's --shm-size 1g), plus the env given (over the same names)
fxa_test_spec() {
  local image=$1 command=$2 extra
  shift 2
  extra=$( (($#)) && printf '%s\n' "$@" | jq -Rn '[inputs | {name: sub("=.*"; ""), value: sub("^[^=]*="; "")}]' || echo '[]')
  jq -n --arg image "${image}" --argjson command "${command}" --argjson extra "${extra}" --arg full "${FULL}" --arg secret "${SECRET}" --arg browser "${BROWSER_IMAGE}" '
    ([{name: "FXA_CONTENT_URL", value: "https://accounts.fxa.test"}, {name: "FXA_AUTH_URL", value: "https://api.fxa.test"},
      {name: "FXA_PROFILE_URL", value: "https://profile.fxa.test"}, {name: "FXA_PAIRING_URL", value: "wss://pairing.fxa.test"},
      {name: "SYNC_PUBLIC_URL", value: "https://sync.fxa.test"}, {name: "MAILPIT_URL", value: "http://mailpit:8025"},
      {name: "ADMIN_URL", value: "https://admin.fxa.test"},
      {name: "ADMIN_PASSWORD", valueFrom: {secretKeyRef: {name: $secret, key: "ADMIN_PASSWORD"}}},
      {name: "FXA_DIRECT_URL", value: "http://\($full)-fxa-auth:9000"}, {name: "ADMIN_FXA_CLIENT_ID", value: ""},
      {name: "REQUESTS_CA_BUNDLE", value: "/caddy-ca/root.crt"}, {name: "PYTHONPATH", value: "/app:/app/tools:/tests"},
      {name: "PYTHONDONTWRITEBYTECODE", value: "1"}] | map(select(.name as $n | $extra | map(.name) | index($n) | not))) + $extra
    | {restartPolicy: "Never", securityContext: (if $image == $browser then {} else {runAsUser: 0} end),
      containers: [{name: "test", image: $image, imagePullPolicy: "Never", command: $command, workingDir: (if $image == $browser then "/home/tester" else "/app" end), env: .,
        volumeMounts: [{name: "tests", mountPath: "/tests", readOnly: true}, {name: "ca", mountPath: "/caddy-ca", readOnly: true},
          {name: "state", mountPath: "/state"}, {name: "shm", mountPath: "/dev/shm"}]}],
      volumes: [{name: "tests", configMap: {name: "ffs-fxa-tests"}}, {name: "ca", configMap: {name: "fxa-test-ca"}},
        {name: "state", persistentVolumeClaim: {claimName: "fxa-test-state"}},
        {name: "shm", emptyDir: {medium: "Memory", sizeLimit: "1Gi"}}]}'
}

# fxa_job <name> <image> <pytest args> [NAME=value]...: pytest with those arguments (quoted as
# in a shell) in the Job fxa-test-<name>, which must succeed (its log's end shown)
fxa_job() {
  local name=$1 image=$2 args=$3 spec
  shift 3
  # shellcheck disable=SC2016 # (the pod's shell expands it)
  spec=$(fxa_test_spec "${image}" '["sh", "-c", "eval \"set -- ${PYTEST_ARGS}\" && exec python3 -m pytest -q -p no:cacheprovider \"$@\""]' \
    PYTEST_ARGS="${args}" "$@")
  kubectl delete job "fxa-test-${name}" --ignore-not-found --wait=true > /dev/null
  # (ffs-e2e-direct: the servers' NetworkPolicies let the tests' pods in, tests/helm/fxa-values.yaml)
  jq -n --arg name "fxa-test-${name}" --argjson spec "${spec}" '{apiVersion: "batch/v1", kind: "Job", metadata: {name: $name, labels: {"ffs-e2e": $name}},
    spec: {backoffLimit: 0, template: {metadata: {labels: {"ffs-e2e": $name, "ffs-e2e-direct": "true"}}, spec: $spec}}}' | kubectl apply -f - > /dev/null
  wait_job "fxa-test-${name}" 1800
}

# fxa_client_pod <name>: a pod of the tests (the Sync server's image) waiting for kubectl exec
# (its sleep, PID 1, ignores SIGTERM: a grace period of 1 s, not the default 30 s, on delete)
fxa_client_pod() {
  kubectl delete pod "$1" --ignore-not-found --wait=true > /dev/null
  jq -n --arg name "$1" --argjson spec "$(fxa_test_spec "${SYNC_IMAGE}" '["sleep", "3600"]')" \
    '{apiVersion: "v1", kind: "Pod", metadata: {name: $name, labels: {"ffs-e2e": $name, "ffs-e2e-direct": "true"}}, spec: ($spec + {terminationGracePeriodSeconds: 1})}' | kubectl apply -f - > /dev/null
  kubectl wait --for=condition=Ready "pod/$1" --timeout=3m > /dev/null || fail "the test pod $1 not Ready"
}

# fxa_py <pod> [NAME=value]...: the Python script on stdin in that test pod, its output
fxa_py() {
  local pod=$1
  shift
  kubectl exec -i "${pod}" -- env "$@" python3 -
}

# run, not sourced by tests/helm.sh: the e2e
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
  CHART_DIR="${REPO_ROOT}/charts/firefox-sync"
  # shellcheck source=tests/helm/lib.sh
  source "${SCRIPT_DIR}/helm/lib.sh"
  case "${1:-}" in
    e2e) fxa_e2e "${2:-}" ;;
    *)
      echo "Usage: $0 e2e <mysql|mariadb>   (the template checks: tests/helm.sh lint)"
      exit 1
      ;;
  esac
fi
