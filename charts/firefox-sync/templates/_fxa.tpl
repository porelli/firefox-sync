{{/*
The self-hosted Mozilla accounts (fxa.enabled), compose's compose/fxa.yml (and
compose/fxa-mysql.yml, compose/fxa-mariadb.yml): their images, hosts, env blocks, security contexts and checks
*/}}

{{/*
The image of the accounts (name "fxa": compose's ${FXA_IMAGE}:${FXA_VERSION}, fxa.image.repository
empty: image.repository) or of the pairing server (name "pairing": FXA_PAIRING_IMAGE, empty:
<image.repository>:fxa-channelserver-latest). Accepts a dict with "root" and "name"
*/}}
{{- define "firefox-sync.fxaImage" -}}
{{- $v := .root.Values }}
{{- if eq .name "pairing" }}
{{- $v.fxa.pairing.image | default (printf "%s:fxa-channelserver-latest" $v.image.repository) }}
{{- else }}
{{- printf "%s:%s" ($v.fxa.image.repository | default $v.image.repository) ($v.fxa.image.tag | default "fxa-mono-latest") }}
{{- end }}
{{- end }}

{{/*
The accounts database (compose's FXA_MYSQL_HOST, _PORT, _USER): the bundled server
<fullname>-fxa-db:3306 as root (MYSQL_ROOT_PASSWORD is FXA_MYSQL_PASSWORD, as compose's), or
your own server's fxa.database.external.*
*/}}
{{- define "firefox-sync.fxaDbHost" -}}
{{- if .Values.fxa.database.bundled }}
{{- printf "%s-fxa-db" (include "firefox-sync.fullname" .) }}
{{- else }}
{{- .Values.fxa.database.external.host }}
{{- end }}
{{- end }}

{{- define "firefox-sync.fxaDbPort" -}}
{{- $port := "3306" }}
{{- if not .Values.fxa.database.bundled }}
{{- with include "firefox-sync.number" .Values.fxa.database.external.port }}
{{- $port = . }}
{{- end }}
{{- end }}
{{- $port }}
{{- end }}

{{- define "firefox-sync.fxaDbUser" -}}
{{- if .Values.fxa.database.bundled }}
{{- print "root" }}
{{- else }}
{{- .Values.fxa.database.external.user }}
{{- end }}
{{- end }}

{{/*
The image of the accounts database (fxa.database.image.<backend>), also the client of its
wait and of its backups
*/}}
{{- define "firefox-sync.fxaDbImage" -}}
{{- index .Values.fxa.database.image .Values.fxa.database.backend }}
{{- end }}

{{/*
The bundled accounts database's args (a JSON list), compose's fxa-db command: mysqld
--event-scheduler=ON ${FXA_MYSQL_ARGS}, where prepare_environment.sh writes FXA_MYSQL_ARGS
(mysql_native_password, for an accounts image without mozilla/fxa#21554) only with a MySQL 8
pin: so here, by the image, a MySQL 8 one (mysql:8, mysql:8.4.x) gets them, any other none
(MySQL 9 refuses them). MariaDB: mariadbd --event-scheduler=ON (its default authentication is
already mysql_native_password)
*/}}
{{- define "firefox-sync.fxaDbArgs" -}}
{{- if eq .Values.fxa.database.backend "mariadb" }}
{{- toJson (list "mariadbd" "--event-scheduler=ON") }}
{{- else if eq (include "firefox-sync.imageMajor" (include "firefox-sync.fxaDbImage" .)) "8" }}
{{- toJson (list "mysqld" "--event-scheduler=ON" "--mysql-native-password=ON" "--authentication-policy=mysql_native_password") }}
{{- else }}
{{- toJson (list "mysqld" "--event-scheduler=ON") }}
{{- end }}
{{- end }}

{{/*
The host of a URL, without its port: the host of an Ingress. Accepts a dict with "root" and "url"
*/}}
{{- define "firefox-sync.fxaHost" -}}
{{- regexReplaceAll ":[0-9]+$" (urlParse (.url | default "")).host "" }}
{{- end }}

{{/*
The Sync server's FXA_OAUTH_SERVER_URL and FXA_EMAIL_DOMAIN: with the self-hosted accounts their
auth server and the host of fxa.authUrl (docs/accounts.md: the email domain must be the auth host, so
fxa.oauthServerUrl and fxa.emailDomain are ignored then), else Mozilla's of the values
*/}}
{{- define "firefox-sync.fxaOauthServerUrl" -}}
{{- if .Values.fxa.enabled }}
{{- printf "http://%s-fxa-auth:9000/v1" (include "firefox-sync.fullname" .) }}
{{- else }}
{{- .Values.fxa.oauthServerUrl }}
{{- end }}
{{- end }}

{{- define "firefox-sync.fxaEmailDomain" -}}
{{- if .Values.fxa.enabled }}
{{- include "firefox-sync.fxaHost" (dict "root" . "url" .Values.fxa.authUrl) }}
{{- else }}
{{- .Values.fxa.emailDomain }}
{{- end }}
{{- end }}

{{/*
FXA_SIGNUP_ALLOWLIST: fxa.signupAllowlist, a list joined by commas or a string as it is (the
value of the env var, not an env entry)
*/}}
{{- define "firefox-sync.fxaAllowlist" -}}
{{- $l := .Values.fxa.signupAllowlist }}
{{- if kindIs "slice" $l }}
{{- join "," $l }}
{{- else if $l }}
{{- $l | toString }}
{{- end }}
{{- end }}

{{/*
compose's <prefix>MYSQL_HOST, _PORT, _USERNAME and _PASSWORD (x-fxa-mysql, AUTH_MYSQL_*...):
env entries, the password FXA_MYSQL_PASSWORD of the Secret. Accepts a dict with "root" and
"prefix" ("", "AUTH_", "OAUTH_", "PROFILE_", "PUSHBOX_")
*/}}
{{- define "firefox-sync.fxaMysqlEnv" -}}
- name: {{ .prefix }}MYSQL_HOST
  value: {{ include "firefox-sync.fxaDbHost" .root | quote }}
- name: {{ .prefix }}MYSQL_PORT
  value: {{ include "firefox-sync.fxaDbPort" .root | quote }}
- name: {{ .prefix }}MYSQL_USERNAME
  value: {{ include "firefox-sync.fxaDbUser" .root | quote }}
{{ include "firefox-sync.secretEnv" (dict "root" .root "name" (printf "%sMYSQL_PASSWORD" .prefix) "key" "FXA_MYSQL_PASSWORD") }}
{{- end }}

{{/*
The accounts' containers: the image's user app (10001) by number (runAsNonRoot checks a uid),
no capability, no privilege escalation, seccomp RuntimeDefault (PodSecurity restricted). For
nindent under securityContext:
*/}}
{{- define "firefox-sync.fxaSecurityContext" -}}
runAsNonRoot: true
runAsUser: 10001
runAsGroup: 10001
allowPrivilegeEscalation: false
capabilities:
  drop: ["ALL"]
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{/*
The accounts' pods: 10001. Their volumes are made 10001's by the root init containers
(keys-owner, images-owner) with fxa.volumeOwnerInit, as compose's fxa-keys-owner; without
them (volumeOwnerInit false) by fsGroup 10001, where the StorageClass applies it. For
nindent under the pod's securityContext:
*/}}
{{- define "firefox-sync.fxaPodSecurityContext" -}}
runAsNonRoot: true
runAsUser: 10001
runAsGroup: 10001
{{- if not .Values.fxa.volumeOwnerInit }}
fsGroup: 10001
fsGroupChangePolicy: OnRootMismatch
{{- end }}
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{/*
The secrets of the accounts that the chart generates, as prepare_environment.sh does
(generate_random_string 32): kept in the Secret, also once fxa.enabled is off again. Its list,
and FXA_REDIS_PASSWORD, the chart's own (compose's Redis is on a network of its own)
*/}}
{{- define "firefox-sync.fxaGeneratedKeys" -}}
FXA_MYSQL_PASSWORD FXA_ADMIN_DB_PASSWORD FXA_AUTH_SECRET FXA_OAUTH_SECRET FXA_PROFILE_SECRET FXA_FLOW_ID_KEY FXA_SESSION_TOKEN_HANDLE_KEY FXA_CONTENT_SESSION_SECRET FXA_REDIS_PASSWORD
{{- end }}

{{/*
Sign-in to the admin UI with the accounts (admin.fxaSignIn, with the accounts and the admin UI
on): "true", else empty
*/}}
{{- define "firefox-sync.fxaSignIn" -}}
{{- if and .Values.fxa.enabled .Values.admin.enabled .Values.admin.fxaSignIn }}true{{ end }}
{{- end }}

{{/*
ADMIN_FXA_CLIENT_ID, the admin UI's OAuth client in the accounts (config/fxa/oauth-clients.js):
fxa.adminClientId, else derived from the namespace and the release (the same on every render and
upgrade, no lookup: GitOps renders it too; no secret, a public PKCE client); empty without
sign-in with the accounts, as compose with ADMIN_FXA_CLIENT_ID empty
*/}}
{{- define "firefox-sync.fxaAdminClientId" -}}
{{- if include "firefox-sync.fxaSignIn" . }}
{{- .Values.fxa.adminClientId | default (printf "%s/%s/admin-oidc" .Release.Namespace .Release.Name | sha256sum | trunc 16) }}
{{- end }}
{{- end }}

{{/*
ADMIN_OIDC_REDIRECT_URL: admin.oidc.redirectUrl, else (sign-in with the accounts) /auth/callback
of admin.ingress.host, as prepare_environment.sh writes it
*/}}
{{- define "firefox-sync.adminRedirectUrl" -}}
{{- if and (include "firefox-sync.fxaSignIn" .) (not .Values.admin.oidc.redirectUrl) }}
{{- printf "https://%s/auth/callback" .Values.admin.ingress.host }}
{{- else }}
{{- .Values.admin.oidc.redirectUrl }}
{{- end }}
{{- end }}

{{/*
What the accounts need of the values, or the render fails saying so (fail closed); called by
firefox-sync.checkValues
*/}}
{{- define "firefox-sync.checkFxaValues" -}}
{{- $f := .Values.fxa }}
{{- $a := .Values.admin }}
{{- if and $a.enabled $a.fxaSignIn (not $f.enabled) }}
{{- fail "firefox-sync: admin.fxaSignIn needs fxa.enabled: it signs in with the self-hosted accounts (OpenID Connect of another provider: admin.oidc.*)" }}
{{- end }}
{{- if include "firefox-sync.fxaSignIn" . }}
{{- if not (or $a.allowed.users $a.allowed.groups) }}
{{- fail "firefox-sync: admin.fxaSignIn needs admin.allowed.users or admin.allowed.groups: who of the accounts is an admin (docs/admin/signing-in.md#self-hosted-accounts)" }}
{{- end }}
{{- if not (or $a.oidc.redirectUrl $a.ingress.host) }}
{{- fail "firefox-sync: admin.fxaSignIn needs admin.oidc.redirectUrl or admin.ingress.host: the admin UI's public https://<host>/auth/callback, where the accounts send the admins back" }}
{{- end }}
{{- if and $a.oidc.redirectUrl (not (regexMatch "^https://[^/]+(/.*)?/auth/callback$" $a.oidc.redirectUrl)) }}
{{- fail (printf "firefox-sync: admin.oidc.redirectUrl must be the admin UI's https://<host>/auth/callback (the accounts register exactly that), not %s" $a.oidc.redirectUrl) }}
{{- end }}
{{- end }}
{{- if and $f.enabled $f.adminClientId (not $a.fxaSignIn) }}
{{- fail "firefox-sync: fxa.adminClientId needs admin.fxaSignIn: it is the admin UI's client for signing in with the accounts, registered only with it (without it, leave fxa.adminClientId empty)" }}
{{- end }}
{{- if $f.enabled }}
{{- if not (and $f.contentUrl $f.authUrl $f.profileUrl) }}
{{- fail "firefox-sync: fxa.enabled needs fxa.contentUrl, fxa.authUrl and fxa.profileUrl, the public URLs of the accounts' pages, API and profiles, each on a host of its own (docs/reverse-proxy.md#host-names-and-ports)" }}
{{- end }}
{{- if not $f.database.bundled }}
{{- if not $f.database.external.host }}
{{- fail "firefox-sync: fxa.database.bundled=false needs fxa.database.external.host, your accounts database server (docs/databases.md#your-own-server)" }}
{{- end }}
{{- if not .Values.existingSecret }}
{{- fail "firefox-sync: fxa.database.bundled=false needs existingSecret, with FXA_MYSQL_PASSWORD and FXA_MYSQL_POLICY_PASSWORD, the passwords of fxa.database.external.user and policyUser on your server, and the accounts' secrets: the chart cannot generate passwords your server knows" }}
{{- end }}
{{- end }}
{{- $port := include "firefox-sync.number" $f.database.external.port }}
{{- if and $port (or (lt (atoi $port) 1) (gt (atoi $port) 65535)) }}
{{- fail (printf "firefox-sync: fxa.database.external.port %s is no port: 1 to 65535, or empty for 3306" $port) }}
{{- end }}
{{- if ($f.networkPolicy.servers | default dict).enabled }}
{{- if not $f.networkPolicy.enabled }}
{{- fail "firefox-sync: fxa.networkPolicy.servers.enabled needs fxa.networkPolicy.enabled, the NetworkPolicies of the accounts (docs/install/helm.md#networkpolicies)" }}
{{- end }}
{{- if eq (include "firefox-sync.fxaControllerPeer" .) "{}" }}
{{- fail "firefox-sync: fxa.networkPolicy.servers.enabled needs fxa.networkPolicy.servers.ingressController.namespaceSelector or .podSelector (matchLabels or matchExpressions), your Ingress controller's pods: empty, the policy would let every pod in (docs/install/helm.md#networkpolicies)" }}
{{- end }}
{{- end }}
{{- if and $f.pairing.enabled (not $f.pairing.url) }}
{{- fail "firefox-sync: fxa.pairing.enabled needs fxa.pairing.url, the public wss:// URL of the pairing server" }}
{{- end }}
{{- /* every public host of its own (an Ingress each): host names case-insensitive, a
trailing dot the same host, the port ignored; the Sync server's two (syncDomain's, ingress.host)
may be the same */ -}}
{{- $hosts := list (list "syncDomain" .Values.syncDomain) }}
{{- if and .Values.ingress.enabled .Values.ingress.host }}
{{- $hosts = append $hosts (list "ingress.host" (printf "https://%s" .Values.ingress.host)) }}
{{- end }}
{{- $hosts = concat $hosts (list (list "fxa.contentUrl" $f.contentUrl) (list "fxa.authUrl" $f.authUrl) (list "fxa.profileUrl" $f.profileUrl)) }}
{{- if $f.pairing.enabled }}
{{- $hosts = append $hosts (list "fxa.pairing.url" $f.pairing.url) }}
{{- end }}
{{- if and .Values.admin.enabled .Values.admin.ingress.enabled }}
{{- $hosts = append $hosts (list "admin.ingress.host" (printf "https://%s" .Values.admin.ingress.host)) }}
{{- end }}
{{- $seen := dict }}
{{- $sync := list "syncDomain" "ingress.host" }}
{{- range $hosts }}
{{- $label := index . 0 }}
{{- $host := include "firefox-sync.fxaHost" (dict "root" $ "url" (index . 1)) | lower | trimSuffix "." }}
{{- if $host }}
{{- $other := get $seen $host }}
{{- if and $other (not (and (has $other $sync) (has $label $sync))) }}
{{- fail (printf "firefox-sync: %s has the host %s of %s: the accounts' URLs need a host each (an Ingress each), none of the Sync server's or the admin UI's" $label $host $other) }}
{{- end }}
{{- $_ := set $seen $host $label }}
{{- end }}
{{- end }}
{{- include "firefox-sync.checkExistingSecret" . }}
{{- include "firefox-sync.checkFxaDbBackend" . }}
{{- end }}
{{- end }}

{{/*
fxa.networkPolicy.servers.ingressController as a NetworkPolicy peer (JSON): its
namespaceSelector and podSelector that select something (matchLabels or matchExpressions), in
one peer (both: the pods of those labels in the namespaces of those labels; podSelector alone:
in the release's namespace). "{}" when neither does, which checkFxaValues refuses: an empty
peer would let every pod in
*/}}
{{- define "firefox-sync.fxaControllerPeer" -}}
{{- $ic := ((.Values.fxa.networkPolicy.servers | default dict).ingressController | default dict) }}
{{- $peer := dict }}
{{- range $k := list "namespaceSelector" "podSelector" }}
{{- $sel := get $ic $k | default dict }}
{{- /* (an expression selects only with its key) */}}
{{- $exprs := list }}
{{- range ($sel.matchExpressions | default list) }}
{{- if and (kindIs "map" .) .key }}{{ $exprs = append $exprs . }}{{ end }}
{{- end }}
{{- if or $sel.matchLabels $exprs }}
{{- $_ := set $peer $k $sel }}
{{- end }}
{{- end }}
{{- toJson $peer }}
{{- end }}

{{/*
The volume of the bundled accounts database: data with MySQL, data-mariadb with MariaDB (as
compose's fxa-db and fxa-db-mariadb volumes)
*/}}
{{- define "firefox-sync.fxaDbClaim" -}}
{{- ternary "data-mariadb" "data" (eq .Values.fxa.database.backend "mariadb") }}
{{- end }}

{{/*
fxa.database.backend switched on a release whose bundled accounts database exists: the render
fails before anything is applied (Kubernetes would refuse the StatefulSet's other volume only
after the objects before it were changed). And on the same backend, an image of another major
than the running one (dbMajorChange), unless fxa.database.allowMajorUpgrade. Read with lookup
on install and upgrade; nothing to check where lookup returns nothing (helm template, a GitOps
render)
*/}}
{{- define "firefox-sync.checkFxaDbBackend" -}}
{{- if .Values.fxa.database.bundled }}
{{- $existing := lookup "apps/v1" "StatefulSet" .Release.Namespace (include "firefox-sync.fxaDbHost" .) }}
{{- if $existing }}
{{- $old := "" }}
{{- with $existing.spec.volumeClaimTemplates }}
{{- $old = (first .).metadata.name }}
{{- end }}
{{- $new := include "firefox-sync.fxaDbClaim" . }}
{{- if and $old (ne $old $new) }}
{{- fail (printf "firefox-sync: fxa.database.backend is %s but the accounts database was created with %s (its volume %s); switching needs a dump and restore, see docs/backups.md#restore-on-kubernetes" .Values.fxa.database.backend (ternary "mariadb" "mysql" (eq $old "data-mariadb")) $old) }}
{{- end }}
{{- /* its volume as it was created (fxa.database.persistence), checkClaim */}}
{{- include "firefox-sync.checkStatefulSetClaim" (dict "root" . "name" (include "firefox-sync.fxaDbHost" .) "claim" $new "setting" "fxa.database.persistence" "persistence" .Values.fxa.database.persistence) }}
{{- /* the same server, another image: refused when it moves the data to another major
(firefox-sync.dbMajorChange, as checkDbMajor for the Sync databases), unless
fxa.database.allowMajorUpgrade */}}
{{- $running := "" }}
{{- range $existing.spec.template.spec.containers }}
{{- if eq .name "db" }}{{ $running = .image }}{{ end }}
{{- end }}
{{- $image := include "firefox-sync.fxaDbImage" . }}
{{- $backend := .Values.fxa.database.backend }}
{{- if and (eq $old $new) (not .Values.fxa.database.allowMajorUpgrade) (include "firefox-sync.dbMajorChange" (dict "old" $running "new" $image)) }}
{{- fail (printf "firefox-sync: fxa.database.image.%s is %s but the bundled accounts database %s runs %s; another major upgrades its data for good at the next start: set fxa.database.image.%s to %s to stay, or fxa.database.allowMajorUpgrade=true to move (a backup first), see docs/upgrading.md#database-majors" $backend $image (include "firefox-sync.fxaDbHost" .) $running $backend $running) }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
An existingSecret must have the accounts' keys (and the bootstrap accounts' passwords), or the
pods would end in CreateContainerConfigError: read with lookup on install and upgrade, the
render then fails naming the missing ones (the release stays at its revision). Nothing to check
where lookup returns nothing (helm template, a GitOps render, the Secret not created yet)
*/}}
{{- define "firefox-sync.checkExistingSecret" -}}
{{- if and .Values.existingSecret (or .Values.fxa.enabled (and (not .Values.database.bundled) .Values.database.external.bootstrap.user)) }}
{{- $existing := lookup "v1" "Secret" .Release.Namespace .Values.existingSecret }}
{{- if $existing }}
{{- include "firefox-sync.checkSecretKeys" (dict "root" . "name" .Values.existingSecret "data" ($existing.data | default dict)) }}
{{- end }}
{{- end }}
{{- end }}

{{/*
The keys the accounts need in a Secret's data, missing or empty ones refused: the generated
ones, and with your own accounts server its policy user's password (FXA_MYSQL_POLICY_PASSWORD,
when fxa.database.external.policyUser is set) and the bootstrap account's
(FXA_DB_BOOTSTRAP_PASSWORD, with fxa.database.external.bootstrap.user); with your own Sync server
and database.external.bootstrap.user, SYNC_DB_BOOTSTRAP_PASSWORD. Accepts a dict with "root",
"name" (the Secret) and "data" (its data)
*/}}
{{- define "firefox-sync.checkSecretKeys" -}}
{{- $v := .root.Values }}
{{- $required := list }}
{{- if and (not $v.database.bundled) $v.database.external.bootstrap.user }}
{{- $required = append $required "SYNC_DB_BOOTSTRAP_PASSWORD" }}
{{- end }}
{{- if $v.fxa.enabled }}
{{- $required = concat $required (splitList " " (include "firefox-sync.fxaGeneratedKeys" .root)) }}
{{- if and (not $v.fxa.database.bundled) $v.fxa.database.external.policyUser }}
{{- $required = append $required "FXA_MYSQL_POLICY_PASSWORD" }}
{{- end }}
{{- if and (not $v.fxa.database.bundled) $v.fxa.database.external.bootstrap.user }}
{{- $required = append $required "FXA_DB_BOOTSTRAP_PASSWORD" }}
{{- end }}
{{- end }}
{{- $missing := list }}
{{- range $required }}
{{- if not (get $.data .) }}
{{- $missing = append $missing . }}
{{- end }}
{{- end }}
{{- if $missing }}
{{- fail (printf "firefox-sync: existingSecret %s lacks %s, which the self-hosted accounts or the bootstrap accounts of your own servers need (docs/install/helm.md#existingsecret): add them, then helm upgrade again" .name (sortAlpha $missing | join ", ")) }}
{{- end }}
{{- end }}

{{/*
smtp.*, compose's FXA_SMTP_* of the accounts and the admin UI, as compose's strings (JSON):
host, port, user, secure, sender (the password is FXA_SMTP_PASS of the Secret)
*/}}
{{- define "firefox-sync.smtp" -}}
{{- $s := merge (deepCopy (.Values.smtp | default dict)) (dict "host" "" "port" 587 "user" "" "secure" false "sender" "") }}
{{- toJson (dict "host" ($s.host | default "" | toString) "port" (include "firefox-sync.number" $s.port) "user" ($s.user | default "" | toString) "secure" ($s.secure | toString) "sender" ($s.sender | default "" | toString)) }}
{{- end }}

{{/*
resources: of the accounts' init containers (fxa.resources.init), empty: none
*/}}
{{- define "firefox-sync.fxaInitResources" -}}
{{- with .Values.fxa.resources.init }}
resources:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
The data of the ConfigMap <fullname>-fxa-config: every files/fxa/*.js (compose's ./config/fxa),
also the input of the pods' checksum/fxa-config
*/}}
{{- define "firefox-sync.fxaConfigData" -}}
{{- range $path, $_ := .Files.Glob "files/fxa/*.js" }}
{{ base $path }}: |
  {{- $.Files.Get $path | trimSuffix "\n" | nindent 2 }}
{{- end }}
{{- end }}

{{/*
fxa.extraCaCerts (chart-only, no compose counterpart): the CA of your SMTP server or of your
own HTTPS hosts for the accounts' node servers, the ConfigMap at /ffs-ca. The env entry, the
volumeMount and the volume, each empty without it
*/}}
{{- define "firefox-sync.fxaCaEnv" -}}
{{- with .Values.fxa.extraCaCerts }}
{{- if .configMap }}
- name: NODE_EXTRA_CA_CERTS
  value: /ffs-ca/{{ .key }}
{{- end }}
{{- end }}
{{- end }}

{{- define "firefox-sync.fxaCaVolumeMount" -}}
{{- if .Values.fxa.extraCaCerts.configMap }}
- name: ffs-ca
  mountPath: /ffs-ca
  readOnly: true
{{- end }}
{{- end }}

{{- define "firefox-sync.fxaCaVolume" -}}
{{- with .Values.fxa.extraCaCerts.configMap }}
- name: ffs-ca
  configMap:
    name: {{ . }}
{{- end }}
{{- end }}

{{/*
The env of a Redis client of the accounts: compose's <SUBSYSTEM>_REDIS_HOST and the password
of each (FXA_REDIS_PASSWORD, chart-only). Accepts a dict with "root" and "names" (the host
variables, e.g. REDIS_HOST ACCESS_TOKEN_REDIS_HOST: their _PASSWORD next to each); for
trim | nindent
*/}}
{{- define "firefox-sync.fxaRedisEnv" -}}
{{- $redis := printf "%s-fxa-redis" (include "firefox-sync.fullname" .root) }}
{{- range .names }}
- name: {{ . }}
  value: {{ $redis }}
{{ include "firefox-sync.secretEnv" (dict "root" $.root "name" (printf "%sPASSWORD" (trimSuffix "HOST" .)) "key" "FXA_REDIS_PASSWORD") }}
{{- end }}
{{- end }}

{{/*
An init container of the accounts' image waiting for their servers, compose's depends_on
service_healthy (chart-only, no env): each URL in turn answers 2xx (their /__heartbeat__), up
to 30 minutes (auth's first start: the database's, the migrations), then exit 1 and the
kubelet tries again. Accepts a dict with "root", "name" and "urls"; a list item, for nindent
under initContainers:
*/}}
{{- define "firefox-sync.fxaWaitHttp" -}}
- name: {{ .name }}
  image: {{ include "firefox-sync.fxaImage" (dict "root" .root "name" "fxa") }}
  imagePullPolicy: {{ .root.Values.image.pullPolicy }}
  securityContext:
    {{- include "firefox-sync.fxaSecurityContext" .root | nindent 4 }}
  {{- with include "firefox-sync.fxaInitResources" .root }}{{ . | trim | nindent 2 }}{{ end }}
  args:
    - node
    - -e
    - |
      const deadline = Date.now() + 30 * 60 * 1000;
      const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
      (async () => {
        for (const url of process.argv.slice(1)) {
          let last = '';
          while (!(await fetch(url, { signal: AbortSignal.timeout(5000) }).then((r) => r.ok || ((last = `HTTP ${r.status}`), false), (e) => ((last = e.message), false)))) {
            if (Date.now() > deadline) { console.error(`Timeout waiting for ${url}: ${last}`); process.exit(1); }
            await sleep(2000);
          }
          console.log(`${url} answers`);
        }
      })();
    {{- range .urls }}
    - {{ . | quote }}
    {{- end }}
{{- end }}
