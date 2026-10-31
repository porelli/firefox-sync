{{/*
Expand the name of the chart.
*/}}
{{- define "firefox-sync.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "firefox-sync.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "firefox-sync.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "firefox-sync.labels" -}}
helm.sh/chart: {{ include "firefox-sync.chart" .root }}
{{ include "firefox-sync.selectorLabels" . }}
{{- if .root.Chart.AppVersion }}
app.kubernetes.io/version: {{ .root.Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
{{- end }}

{{/*
Selector labels
Accepts a dict with "root" (the root context) and optional "component"
*/}}
{{- define "firefox-sync.selectorLabels" -}}
app.kubernetes.io/name: {{ include "firefox-sync.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- if .component }}
app.kubernetes.io/component: {{ .component }}
{{- end }}
{{- end }}

{{/*
Return the proper image name based on backend and component
Accepts a dict with "root" (the root context) and "name" (syncstorage|init|admin)
*/}}
{{- define "firefox-sync.image" -}}
{{- $root := .root }}
{{- $name := .name }}
{{- $backend := $root.Values.database.backend }}
{{- $repository := $root.Values.image.repository }}
{{- if eq $name "admin" }}
{{- printf "%s:admin-%s" $repository $root.Values.image.adminTag }}
{{- else if eq $name "syncstorage" }}
{{- if eq $backend "postgres" }}
{{- printf "%s:syncstorage-rs-postgres-%s" $repository $root.Values.image.syncstorageTag }}
{{- else }}
{{- printf "%s:syncstorage-rs-mysql-%s" $repository $root.Values.image.syncstorageTag }}
{{- end }}
{{- else if eq $name "init" }}
{{- if eq $backend "postgres" }}
{{- printf "%s:syncstorage-rs-postgres-init-%s" $repository $root.Values.image.initTag }}
{{- else }}
{{- printf "%s:syncstorage-rs-mysql-init-%s" $repository $root.Values.image.initTag }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Return the database host for tokenserver or storage
Accepts a dict with "root" (the root context) and "db" (tokenserver|storage)
For bundled databases (the Services of databases.yaml):
  - mariadb/mysql: <fullname>-tokenserver-db and <fullname>-storage-db (separate databases)
  - postgres: <fullname>-postgres (shared database)
For your own server: database.external.host (mariadb/mysql storage: storageHost, else host)
*/}}
{{- define "firefox-sync.dbHost" -}}
{{- $root := .root }}
{{- $db := .db }}
{{- $backend := $root.Values.database.backend }}
{{- if $root.Values.database.bundled }}
{{- $fullname := include "firefox-sync.fullname" $root }}
{{- if eq $backend "postgres" }}
{{- printf "%s-postgres" $fullname }}
{{- else }}
{{- if eq $db "tokenserver" }}
{{- printf "%s-tokenserver-db" $fullname }}
{{- else }}
{{- printf "%s-storage-db" $fullname }}
{{- end }}
{{- end }}
{{- else }}
{{- $e := $root.Values.database.external }}
{{- if and (eq $db "storage") (ne $backend "postgres") $e.storageHost }}
{{- $e.storageHost }}
{{- else }}
{{- $e.host }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Return the database port
Accepts a dict with "root" and "db" (tokenserver|storage): 3306 or 5432; your own server's
database.external.port (mariadb/mysql storage: storagePort, else port), empty for those
*/}}
{{- define "firefox-sync.dbPort" -}}
{{- $root := .root }}
{{- $backend := $root.Values.database.backend }}
{{- $port := ternary "5432" "3306" (eq $backend "postgres") }}
{{- if not $root.Values.database.bundled }}
{{- $e := $root.Values.database.external }}
{{- $own := $e.port }}
{{- if and (eq (.db | default "") "storage") (ne $backend "postgres") $e.storagePort }}
{{- $own = $e.storagePort }}
{{- end }}
{{- with include "firefox-sync.number" $own }}
{{- $port = . }}
{{- end }}
{{- end }}
{{- $port }}
{{- end }}

{{/*
Return the database name for tokenserver or storage
Accepts a dict with "root" (the root context) and "db" (tokenserver|storage)
*/}}
{{- define "firefox-sync.dbName" -}}
{{- $root := .root }}
{{- $db := .db }}
{{- $backend := $root.Values.database.backend }}
{{- if $root.Values.database.bundled }}
{{- if eq $backend "postgres" }}
{{- print "syncserver" }}
{{- else }}
{{- if eq $db "tokenserver" }}
{{- print "tokenserver" }}
{{- else }}
{{- print "syncstorage" }}
{{- end }}
{{- end }}
{{- else }}
{{- if eq $backend "postgres" }}
{{- $root.Values.database.external.postgresDatabase }}
{{- else if eq $db "tokenserver" }}
{{- $root.Values.database.external.tokenserverDatabase }}
{{- else }}
{{- $root.Values.database.external.storageDatabase }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Return the database user for tokenserver or storage
*/}}
{{- define "firefox-sync.dbUser" -}}
{{- $root := .root }}
{{- $db := .db }}
{{- $backend := $root.Values.database.backend }}
{{- if $root.Values.database.bundled }}
{{- if eq $backend "postgres" }}
{{- print "syncserver" }}
{{- else }}
{{- if eq $db "tokenserver" }}
{{- print "tokenserver" }}
{{- else }}
{{- print "syncstorage" }}
{{- end }}
{{- end }}
{{- else }}
{{- if eq $backend "postgres" }}
{{- $root.Values.database.external.postgresUser }}
{{- else if eq $db "tokenserver" }}
{{- $root.Values.database.external.tokenserverUser }}
{{- else }}
{{- $root.Values.database.external.storageUser }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Return the database URL for tokenserver or storage
Accepts a dict with "root" (the root context) and "db" (tokenserver|storage)
The password is read from the environment variable via Kubernetes dependent env, not inlined here:
- Postgres: the Sync server's own role, $(POSTGRES_SYNC_PASSWORD), for both tokenserver and storage
  (single database); without one (firefox-sync.postgresSyncUser empty) POSTGRES_USER, $(POSTGRES_PASSWORD)
- MySQL/MariaDB: $(TOKENSERVER_DB_PASSWORD) or $(STORAGE_DB_PASSWORD) (separate databases)
*/}}
{{- define "firefox-sync.dbUrl" -}}
{{- $root := .root }}
{{- $db := .db }}
{{- $backend := $root.Values.database.backend }}
{{- $host := include "firefox-sync.dbHost" (dict "root" $root "db" $db) }}
{{- $port := include "firefox-sync.dbPort" (dict "root" $root "db" $db) }}
{{- $name := include "firefox-sync.dbName" (dict "root" $root "db" $db) }}
{{- $user := include "firefox-sync.dbUser" (dict "root" $root "db" $db) }}
{{- if eq $backend "postgres" }}
{{- $syncUser := include "firefox-sync.postgresSyncUser" $root }}
{{- if $syncUser }}
{{- printf "postgres://%s:$(POSTGRES_SYNC_PASSWORD)@%s:%s/%s" $syncUser $host $port $name }}
{{- else }}
{{- printf "postgres://%s:$(POSTGRES_PASSWORD)@%s:%s/%s" $user $host $port $name }}
{{- end }}
{{- else }}
{{- if eq $db "tokenserver" }}
{{- printf "mysql://%s:$(TOKENSERVER_DB_PASSWORD)@%s:%s/%s" $user $host $port $name }}
{{- else }}
{{- printf "mysql://%s:$(STORAGE_DB_PASSWORD)@%s:%s/%s" $user $host $port $name }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Return the name of the secret containing database passwords
*/}}
{{- define "firefox-sync.secretName" -}}
{{- if .Values.existingSecret }}
{{- .Values.existingSecret }}
{{- else }}
{{- include "firefox-sync.fullname" . }}
{{- end }}
{{- end }}

{{/*
maxUsers as SYNC_MAX_USERS of .env (MAX_USERS of the init container): a string, also when given as a number (maxUsers: 5,
--set maxUsers=5); int64 first, so that a large number is not printed as a float (1e+06)
*/}}
{{- define "firefox-sync.maxUsers" -}}
{{- include "firefox-sync.number" .Values.maxUsers }}
{{- end }}

{{/*
A value as compose's string: a string as it is, a number of a values file (a float64 there)
as an integer, never 2e+06; empty for nil
*/}}
{{- define "firefox-sync.number" -}}
{{- if kindIs "string" . }}
{{- . }}
{{- else if not (kindIs "invalid" .) }}
{{- . | int64 | toString }}
{{- end }}
{{- end }}

{{/*
PostgreSQL: the Sync server's own role (SYNC_POSTGRES_APP_USER of .env, database.postgresSyncUser,
syncserver_app as prepare_environment.sh names it), no superuser, created by the sync-role init
container before the migrations. Empty with your own server (compose: also an install from
before it): the Sync server is POSTGRES_USER, the owner there
*/}}
{{- define "firefox-sync.postgresSyncUser" -}}
{{- if and (eq .Values.database.backend "postgres") .Values.database.bundled }}
{{- .Values.database.postgresSyncUser }}
{{- end }}
{{- end }}

{{/*
The admin UI's own database and users (compose's ADMIN_DB_NAME, ADMIN_DB_USER,
ADMIN_DB_SYNC_USER: database.admin.*), password ADMIN_DB_PASSWORD in the Secret
*/}}
{{- define "firefox-sync.adminDbName" -}}{{ .Values.database.admin.name }}{{- end }}
{{- define "firefox-sync.adminDbUser" -}}{{ .Values.database.admin.user }}{{- end }}
{{- define "firefox-sync.adminDbSyncUser" -}}{{ .Values.database.admin.syncUser }}{{- end }}

{{/*
The Secret key holding the password of the tokenserver or storage database user
(PostgreSQL: POSTGRES_USER, the superuser of the bundled server, the owner on your own)
Accepts a dict with "root" and "db" (tokenserver|storage)
*/}}
{{- define "firefox-sync.dbPasswordKey" -}}
{{- if eq .root.Values.database.backend "postgres" }}
{{- print "POSTGRES_PASSWORD" }}
{{- else if eq .db "tokenserver" }}
{{- print "TOKENSERVER_DB_PASSWORD" }}
{{- else }}
{{- print "STORAGE_DB_PASSWORD" }}
{{- end }}
{{- end }}

{{/*
An env entry read from the chart's Secret
Accepts a dict with "root", "name" (the env var), "key" (the Secret key) and optional
"optional" (true: the key may be missing from an existingSecret, the variable is then unset)
*/}}
{{- define "firefox-sync.secretEnv" -}}
- name: {{ .name }}
  valueFrom:
    secretKeyRef:
      name: {{ include "firefox-sync.secretName" .root }}
      key: {{ .key }}
      {{- if .optional }}
      optional: true
      {{- end }}
{{- end }}

{{/*
The env vars named like the Secret keys of the database passwords, referenced as $(VAR)
by firefox-sync.dbUrl: they must come before the URLs in every container
*/}}
{{- define "firefox-sync.dbPasswordEnv" -}}
{{- if include "firefox-sync.postgresSyncUser" . }}
{{- /* never POSTGRES_PASSWORD, the superuser's (compose: the Sync server never gets it) */ -}}
{{- include "firefox-sync.secretEnv" (dict "root" . "name" "POSTGRES_SYNC_PASSWORD" "key" "POSTGRES_SYNC_PASSWORD") }}
{{- else if eq .Values.database.backend "postgres" }}
{{- include "firefox-sync.secretEnv" (dict "root" . "name" "POSTGRES_PASSWORD" "key" "POSTGRES_PASSWORD") }}
{{- else }}
{{- include "firefox-sync.secretEnv" (dict "root" . "name" "TOKENSERVER_DB_PASSWORD" "key" "TOKENSERVER_DB_PASSWORD") }}
{{ include "firefox-sync.secretEnv" (dict "root" . "name" "STORAGE_DB_PASSWORD" "key" "STORAGE_DB_PASSWORD") }}
{{- end }}
{{- end }}

{{/*
The env of syncstorage-rs, as compose's x-syncstorage (compose/sync.yml, the URLs
of compose/sync-<db>.yml), for the migrate init container and the server
*/}}
{{- define "firefox-sync.syncstorageEnv" -}}
{{- include "firefox-sync.dbPasswordEnv" . }}
- name: SYNC_HOST
  value: 0.0.0.0
- name: SYNC_HUMAN_LOGS
  value: "1"
{{ include "firefox-sync.secretEnv" (dict "root" . "name" "SYNC_MASTER_SECRET" "key" "SYNC_MASTER_SECRET") }}
- name: SYNC_SYNCSTORAGE__DATABASE_URL
  value: {{ include "firefox-sync.dbUrl" (dict "root" . "db" "storage") | quote }}
- name: SYNC_TOKENSERVER__ENABLED
  value: "true"
- name: SYNC_TOKENSERVER__RUN_MIGRATIONS
  value: "true"
- name: SYNC_TOKENSERVER__NODE_TYPE
  value: {{ ternary "postgres" "mysql" (eq .Values.database.backend "postgres") }}
- name: SYNC_TOKENSERVER__DATABASE_URL
  value: {{ include "firefox-sync.dbUrl" (dict "root" . "db" "tokenserver") | quote }}
- name: SYNC_TOKENSERVER__INIT_NODE_URL
  value: {{ .Values.syncDomain | quote }}
- name: SYNC_TOKENSERVER__FXA_EMAIL_DOMAIN
  value: {{ include "firefox-sync.fxaEmailDomain" . | quote }}
- name: SYNC_TOKENSERVER__FXA_OAUTH_SERVER_URL
  value: {{ include "firefox-sync.fxaOauthServerUrl" . | quote }}
{{ include "firefox-sync.secretEnv" (dict "root" . "name" "SYNC_TOKENSERVER__FXA_METRICS_HASH_SECRET" "key" "METRICS_HASH_SECRET") }}
- name: SYNC_TOKENSERVER__ADDITIONAL_BLOCKING_THREADS_FOR_FXA_REQUESTS
  value: "2"
- name: RUST_LOG
  value: info
{{- end }}

{{/*
The image of the bundled database, also the client of wait-db and of the backups: as compose
(database.image.<backend>, compose's SYNC_POSTGRES_IMAGE for PostgreSQL)
*/}}
{{- define "firefox-sync.dbImage" -}}
{{- index .Values.database.image .Values.database.backend }}
{{- end }}

{{/*
The major of an image's tag ("9" of docker.io/library/mysql:9.7, "" of :lts or :latest), and
its name and tag without the registry ("mysql:lts"), for checkDbMajor
*/}}
{{- define "firefox-sync.imageMajor" -}}
{{- $tag := regexReplaceAll "^.*:" (regexReplaceAll "@.*$" (last (splitList "/" .)) "") "" }}
{{- regexFind "^[0-9]+" $tag }}
{{- end }}
{{- define "firefox-sync.imageNameTag" -}}
{{- regexReplaceAll "@.*$" (last (splitList "/" .)) "" }}
{{- end }}

{{/*
"true" when the image old -> new moves the data to another major (dict "old" "new"): two
numbered majors that differ, a numbered major to a tag without one (lts, latest), or one tag
without a major to another; to a numbered major from lts or latest is the pin of
docs/upgrading.md#database-majors. Another server (a backend switch) is not a major change of this one
*/}}
{{- define "firefox-sync.dbMajorChange" -}}
{{- $oldNameTag := include "firefox-sync.imageNameTag" .old }}
{{- $newNameTag := include "firefox-sync.imageNameTag" .new }}
{{- if and .old (eq (first (splitList ":" $oldNameTag)) (first (splitList ":" $newNameTag))) }}
{{- $om := include "firefox-sync.imageMajor" .old }}
{{- $nm := include "firefox-sync.imageMajor" .new }}
{{- if and $om $nm }}{{ if ne $om $nm }}true{{ end }}
{{- else if $om }}true
{{- else if not $nm }}{{ if ne $oldNameTag $newNameTag }}true{{ end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
database.backend switched on a release whose bundled Sync database exists: the render fails
before anything is applied. MariaDB and MySQL share the StatefulSets and their data claim
(the other server would start on the data), PostgreSQL has its own (it would start empty, and
the old ones would go). Each StatefulSet the release may have is read with lookup (nothing
where it returns nothing: a fresh install, helm template, a GitOps render); its server is the
one its db container's env is for (MARIADB_*, MYSQL_*, POSTGRES_*), else its image's name
*/}}
{{- define "firefox-sync.checkDbBackend" -}}
{{- if .Values.database.bundled }}
{{- $root := . }}
{{- $backend := .Values.database.backend }}
{{- $fullname := include "firefox-sync.fullname" . }}
{{- range list "tokenserver-db" "storage-db" "postgres" }}
{{- $name := printf "%s-%s" $fullname . }}
{{- with lookup "apps/v1" "StatefulSet" $root.Release.Namespace $name }}
{{- $running := "" }}
{{- range .spec.template.spec.containers }}
{{- if eq .name "db" }}
{{- range .env | default list }}
{{- if eq .name "MARIADB_DATABASE" }}{{ $running = "mariadb" }}
{{- else if eq .name "MYSQL_DATABASE" }}{{ $running = "mysql" }}
{{- else if eq .name "POSTGRES_DB" }}{{ $running = "postgres" }}
{{- end }}
{{- end }}
{{- if not $running }}
{{- $running = first (splitList ":" (include "firefox-sync.imageNameTag" (.image | default ""))) }}
{{- end }}
{{- end }}
{{- end }}
{{- if and (has $running (list "mariadb" "mysql" "postgres")) (ne $running $backend) }}
{{- fail (printf "firefox-sync: database.backend is %s but the bundled Sync database %s runs %s; switching needs a dump and restore (MariaDB or MySQL to PostgreSQL, or back: start fresh), see docs/migrating.md#moving-the-database" $backend $name $running) }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
A new database.image.<backend> on a release whose bundled database runs: the render fails
before anything is applied when it would move the data to another major. MariaDB and MySQL
upgrade their data in place at the first start on a newer major, with no way back but a
backup; PostgreSQL cannot open another major's data at all. The running image is read with
lookup (install and upgrade; nothing to check where lookup returns nothing: helm template, a
GitOps render), the change as dbMajorChange says (a pin from lts goes through: the server
refuses one older than its data). database.allowMajorUpgrade lets MariaDB and MySQL move (lts to lts), never PostgreSQL;
a PostgreSQL whose server is not up (its db-major init container refused a wrong pin) may change
*/}}
{{- define "firefox-sync.checkDbMajor" -}}
{{- if .Values.database.bundled }}
{{- $root := . }}
{{- $backend := .Values.database.backend }}
{{- $new := include "firefox-sync.dbImage" . }}
{{- $dbs := ternary (list "tokenserver") (list "tokenserver" "storage") (eq $backend "postgres") }}
{{- range $dbs }}
{{- $name := include "firefox-sync.dbHost" (dict "root" $root "db" .) }}
{{- $existing := lookup "apps/v1" "StatefulSet" $root.Release.Namespace $name }}
{{- if $existing }}
{{- $old := "" }}
{{- range $existing.spec.template.spec.containers }}
{{- if eq .name "db" }}{{ $old = .image }}{{ end }}
{{- end }}
{{- /* PostgreSQL not up on that image (e.g. refused by db-major after a wrong pin): nothing
of its data changed, going back to its major must stay possible */}}
{{- $up := true }}
{{- if eq $backend "postgres" }}
{{- $up = false }}
{{- with lookup "v1" "Pod" $root.Release.Namespace (printf "%s-0" $name) }}
{{- range (.status.containerStatuses | default list) }}
{{- if and (eq .name "db") .ready }}{{ $up = true }}{{ end }}
{{- end }}
{{- end }}
{{- end }}
{{- if and $up (include "firefox-sync.dbMajorChange" (dict "old" $old "new" $new)) }}
{{- if eq $backend "postgres" }}
{{- fail (printf "firefox-sync: database.image.postgres is %s but the bundled PostgreSQL (%s) runs %s, and PostgreSQL cannot open another major's data; set database.image.postgres to %s, a newer major needs a dump and restore or pg_upgrade, see docs/upgrading.md#database-majors" $new $name $old $old) }}
{{- else if not $root.Values.database.allowMajorUpgrade }}
{{- fail (printf "firefox-sync: database.image.%s is %s but the bundled database %s runs %s; another major upgrades its data for good at the next start: set database.image.%s to %s to stay, or database.allowMajorUpgrade=true to move (a backup first), see docs/upgrading.md#database-majors" $backend $new $name $old $backend $old) }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
The host of the Sync server's Ingress: ingress.host, else the host of syncDomain (without a port)
*/}}
{{- define "firefox-sync.ingressHost" -}}
{{- .Values.ingress.host | default (regexReplaceAll ":[0-9]+$" (urlParse .Values.syncDomain).host "") }}
{{- end }}

{{/*
What the values must have, or the render fails saying so (fail closed): your own server needs
its host and existingSecret (the chart cannot generate passwords your server knows); the admin
UI's Ingress a host of its own; the self-hosted accounts', firefox-sync.checkFxaValues (_fxa.tpl)
*/}}
{{- define "firefox-sync.checkValues" -}}
{{- if not .Values.database.bundled }}
{{- if not .Values.database.external.host }}
{{- fail "firefox-sync: database.bundled=false needs database.external.host, your database server (docs/databases.md#your-own-server)" }}
{{- end }}
{{- if not .Values.existingSecret }}
{{- fail "firefox-sync: database.bundled=false needs existingSecret, a Secret with the passwords of the users that the SQL of docs/databases.md#create-the-databases-and-users created on your server (and the stack's secrets): the chart cannot generate passwords your server knows" }}
{{- end }}
{{- end }}
{{- range $key := list "port" "storagePort" }}
{{- $port := include "firefox-sync.number" (index $.Values.database.external $key) }}
{{- if and $port (or (lt (atoi $port) 1) (gt (atoi $port) 65535)) }}
{{- fail (printf "firefox-sync: database.external.%s %s is no port: 1 to 65535, or empty for the backend's default" $key $port) }}
{{- end }}
{{- end }}
{{- if and .Values.ingress.enabled (not (include "firefox-sync.ingressHost" .)) }}
{{- fail "firefox-sync: ingress.enabled needs ingress.host, or a syncDomain with a host" }}
{{- end }}
{{- if and .Values.admin.enabled .Values.admin.ingress.enabled }}
{{- if not .Values.admin.ingress.host }}
{{- fail "firefox-sync: admin.ingress.enabled needs admin.ingress.host, a host of its own for the admin UI" }}
{{- end }}
{{- /* the Sync server's host, with or without its Ingress (yours, a reverse proxy); host
names are case-insensitive (and a trailing dot the same host) */ -}}
{{- $syncHosts := list }}
{{- range list (regexReplaceAll ":[0-9]+$" (urlParse .Values.syncDomain).host "") (include "firefox-sync.ingressHost" .) }}
{{- $syncHosts = append $syncHosts (lower . | trimSuffix ".") }}
{{- end }}
{{- if has (lower .Values.admin.ingress.host | trimSuffix ".") $syncHosts }}
{{- fail (printf "firefox-sync: admin.ingress.host %s is the Sync server's host: give the admin UI a host of its own" .Values.admin.ingress.host) }}
{{- end }}
{{- end }}
{{- include "firefox-sync.checkFxaValues" . }}
{{- end }}

{{/*
MARIADB_TLS_VERIFY of the init container: the bundled MySQL's certificate is self-signed
(compose/sync-mysql.yml sets false), the bundled MariaDB's is checked; your own
server: database.external.tlsVerify
*/}}
{{- define "firefox-sync.tlsVerify" -}}
{{- if not .Values.database.bundled }}
{{- .Values.database.external.tlsVerify | toString }}
{{- else if eq .Values.database.backend "mysql" }}
{{- print "false" }}
{{- else }}
{{- print "true" }}
{{- end }}
{{- end }}

{{/*
The env of db/mysql/admin-user.sh in the MariaDB and MySQL containers, as compose's
tokenserver_db and syncstorage_db. Accepts a dict with "root" and "role" (tokenserver|storage)
*/}}
{{- define "firefox-sync.adminUserEnv" -}}
- name: ADMIN_DB_ROLE
  value: {{ .role }}
{{- if eq .role "tokenserver" }}
- name: ADMIN_DB_USER
  value: {{ include "firefox-sync.adminDbUser" .root }}
{{- end }}
- name: ADMIN_DB_SYNC_USER
  value: {{ include "firefox-sync.adminDbSyncUser" .root }}
{{ include "firefox-sync.secretEnv" (dict "root" .root "name" "ADMIN_DB_PASSWORD" "key" "ADMIN_DB_PASSWORD") }}
{{- if eq .role "tokenserver" }}
- name: ADMIN_DB_NAME
  value: {{ include "firefox-sync.adminDbName" .root }}
{{- end }}
{{- end }}

{{/*
compose's POSTGRES_SYNC_USER and POSTGRES_SYNC_PASSWORD of sync_role_init and the init
container (empty without the Sync server's own role, as compose's ${...:-})
*/}}
{{- define "firefox-sync.postgresSyncEnv" -}}
{{- $syncUser := include "firefox-sync.postgresSyncUser" . }}
- name: POSTGRES_SYNC_USER
  value: {{ $syncUser | quote }}
{{- if $syncUser }}
{{ include "firefox-sync.secretEnv" (dict "root" . "name" "POSTGRES_SYNC_PASSWORD" "key" "POSTGRES_SYNC_PASSWORD") }}
{{- else }}
- name: POSTGRES_SYNC_PASSWORD
  value: ""
{{- end }}
{{- end }}

{{/*
compose's cap_drop: [NET_RAW] of the Sync server and its migrations: no raw sockets; no
privilege escalation
*/}}
{{- define "firefox-sync.syncstorageSecurityContext" -}}
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["NET_RAW"]
{{- end }}

{{/*
The admin UI's Service: its http port and the statsd port the Sync server sends to
*/}}
{{- define "firefox-sync.adminService" -}}
{{- printf "%s-admin" (include "firefox-sync.fullname" .) }}
{{- end }}

{{/*
The data of the chart's Secret (see secret.yaml) as JSON: read back from the cluster, the
missing secrets generated (the self-hosted accounts' too), the optional ones of the values.
Computed once per render and kept on the root context, so that secret.yaml and the checksum
of admin.yaml see the same generated values
*/}}
{{- define "firefox-sync.secretData" -}}
{{- if not (hasKey $ "ffsSecretData") }}
{{- $name := include "firefox-sync.fullname" . }}
{{- $existing := lookup "v1" "Secret" .Release.Namespace $name }}
{{- $data := dict }}
{{- if $existing }}
{{- $data = deepCopy ($existing.data | default dict) }}
{{- end }}
{{- /* ADMIN_DB_PASSWORD: the admin UI's own database users, also created by the bundled
databases and the init container (compose's ADMIN_DB_PASSWORD, prepare_environment.sh
generates it); POSTGRES_SYNC_PASSWORD: the Sync server's own role, POSTGRES_PASSWORD
the superuser's */ -}}
{{- $keys := list "SYNC_MASTER_SECRET" "METRICS_HASH_SECRET" "ADMIN_PASSWORD" "ADMIN_DB_PASSWORD" }}
{{- if eq .Values.database.backend "postgres" }}
{{- $keys = concat $keys (list "POSTGRES_PASSWORD" "POSTGRES_SYNC_PASSWORD") }}
{{- else }}
{{- $keys = concat $keys (list "TOKENSERVER_DB_PASSWORD" "STORAGE_DB_PASSWORD") }}
{{- end }}
{{- /* the self-hosted accounts' (prepare_environment.sh's list), kept once they are off
again: turned on again, they find the passwords the kept fxa-db volume has */ -}}
{{- if .Values.fxa.enabled }}
{{- $keys = concat $keys (splitList " " (include "firefox-sync.fxaGeneratedKeys" .)) }}
{{- end }}
{{- range $keys }}
{{- if not (hasKey $data .) }}
{{- $_ := set $data . (randAlphaNum 32 | b64enc) }}
{{- end }}
{{- end }}
{{- /* the admin UI's password when given (otherwise the generated one, kept) */ -}}
{{- with .Values.admin.password }}
{{- $_ := set $data "ADMIN_PASSWORD" (. | toString | b64enc) }}
{{- end }}
{{- /* its optional secrets (.env's names) are the values', never the cluster's: empty
there is empty here, the feature off (existingSecret to manage them out of band) */ -}}
{{- $_ := set $data "FXA_SMTP_PASS" (.Values.smtp.password | default "" | toString | b64enc) }}
{{- $_ := set $data "ADMIN_OIDC_CLIENT_SECRET" (.Values.admin.oidc.clientSecret | toString | b64enc) }}
{{- $_ := set $data "ADMIN_METRICS_TOKEN" (.Values.admin.metricsToken | toString | b64enc) }}
{{- $_ := set $data "ADMIN_NOTIFY" (include "firefox-sync.adminNotify" . | b64enc) }}
{{- /* the values' with the accounts; without them none, also not an old copy the lookup found */ -}}
{{- if .Values.fxa.enabled }}
{{- $_ := set $data "ADMIN_FXA_CLIENT_SECRET" (.Values.fxa.adminClientSecret | default "" | toString | b64enc) }}
{{- else }}
{{- $_ := unset $data "ADMIN_FXA_CLIENT_SECRET" }}
{{- end }}
{{- $_ := set $ "ffsSecretData" $data }}
{{- end }}
{{- toJson (get $ "ffsSecretData") }}
{{- end }}

{{/*
admin.notify as compose's ADMIN_NOTIFY: a list of URLs joined by commas, or a string as it is
*/}}
{{- define "firefox-sync.adminNotify" -}}
{{- $n := .Values.admin.notify }}
{{- if kindIs "slice" $n }}
{{- join "," $n }}
{{- else if $n }}
{{- $n | toString }}
{{- end }}
{{- end }}

{{/*
compose's BACKUP_TIME (HH:MM, UTC) of backup.schedule when it is a daily "M H * * *" (the
CronJob runs in UTC), for the admin UI's help and backup.sh; empty for any other schedule:
the admin UI then says its default, 03:00
*/}}
{{- define "firefox-sync.backupTime" -}}
{{- $s := .Values.backup.schedule | toString | trim }}
{{- if regexMatch "^([0-5]?[0-9]) ([01]?[0-9]|2[0-3]) \\* \\* \\*$" $s }}
{{- $f := splitList " " $s }}
{{- printf "%02d:%02d" (index $f 1 | atoi) (index $f 0 | atoi) }}
{{- end }}
{{- end }}

{{/*
The backup's pods (the CronJob's and the PVC's binding Job): root, as compose (the dumps are
root's, 0600), without any capability: root owns what it writes into the PVC and /tmp, the
dumps and their clients need none (the e2e dumps and restores so)
*/}}
{{- define "firefox-sync.backupPodSecurityContext" -}}
seccompProfile:
  type: RuntimeDefault
{{- end }}
{{- define "firefox-sync.backupSecurityContext" -}}
allowPrivilegeEscalation: false
capabilities:
  drop: ["ALL"]
{{- end }}

{{/*
The names of the chart's objects within Kubernetes' limits, or the render fails saying so:
none is truncated, the admin UI builds them from ADMIN_K8S_FULLNAME (the CronJob, the Sync
server's Deployment, the databases' hosts). A CronJob at most 52 (its Jobs get 11 more), a
StatefulSet 52 (its pods' controller-revision-hash label is <name>-<hash of up to 10>), a
Service 63 (a DNS label)
*/}}
{{- define "firefox-sync.checkNames" -}}
{{- $fullname := include "firefox-sync.fullname" . }}
{{- $names := list (list "syncstorage" "Service" 63) }}
{{- if .Values.admin.enabled }}
{{- $names = append $names (list "admin" "Service" 63) }}
{{- end }}
{{- if .Values.backup.enabled }}
{{- $names = append $names (list "backup" "CronJob" 52) }}
{{- end }}
{{- if .Values.database.bundled }}
{{- if eq .Values.database.backend "postgres" }}
{{- $names = append $names (list "postgres" "StatefulSet" 52) }}
{{- else }}
{{- $names = concat $names (list (list "tokenserver-db" "StatefulSet" 52) (list "storage-db" "StatefulSet" 52)) }}
{{- end }}
{{- end }}
{{- if .Values.fxa.enabled }}
{{- $names = append $names (list "fxa-profile" "Service" 63) }}
{{- if .Values.fxa.database.bundled }}
{{- $names = append $names (list "fxa-db" "StatefulSet" 52) }}
{{- end }}
{{- end }}
{{- range $names }}
{{- $name := printf "%s-%s" $fullname (index . 0) }}
{{- if gt (len $name) (index . 2) }}
{{- fail (printf "firefox-sync: set a shorter fullnameOverride or a shorter release name: the %s %s name %s is %d characters, at most %d (the fullname %s is %d)" (index . 0) (index . 1) $name (len $name) (index . 2) $fullname (len $fullname)) }}
{{- end }}
{{- end }}
{{- end }}

{{/*
What every pod of the chart has in its spec: no service account token (no pod uses the
Kubernetes API), the pull secrets and the scheduling of the values (imagePullSecrets,
nodeSelector, tolerations, affinity), for nindent at the level of the pod's spec
*/}}
{{- define "firefox-sync.podSpec" -}}
automountServiceAccountToken: false
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
The annotations of a pod: podAnnotations of the values, then the chart's own (dict "root"
and "annotations"), which win; empty: nothing, for nindent at the level of the pod's metadata
*/}}
{{- define "firefox-sync.podAnnotations" -}}
{{- $annotations := merge (deepCopy (.annotations | default dict)) (deepCopy (.root.Values.podAnnotations | default dict)) }}
{{- with $annotations }}
annotations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
The container securityContext of the Sync server's init containers and of the database
servers: no privilege escalation (no setuid binary gains anything; the database images'
entrypoints drop root with gosu, a setuid() of root, which this does not stop). Capabilities
as the images need them (the database servers chown their data as root)
*/}}
{{- define "firefox-sync.noEscalation" -}}
securityContext:
  allowPrivilegeEscalation: false
{{- end }}

{{/*
resources: of the Sync server's init containers (syncstorage.initResources), empty: none
*/}}
{{- define "firefox-sync.initResources" -}}
{{- with .Values.syncstorage.initResources }}
resources:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
A Kubernetes quantity (8Gi, 500M, 1073741824) in bytes, for comparing the sizes of volumes,
rounded up as Kubernetes does; also milli-units (1395864371200m), how Kubernetes stores a size
that is no whole number of bytes (1.3Gi, which the schema now refuses, an older chart did not)
*/}}
{{- define "firefox-sync.bytes" -}}
{{- $q := toString . | trim }}
{{- $n := regexFind "^[0-9]+(\\.[0-9]+)?" $q }}
{{- $units := dict "" 1.0 "Ki" 1024.0 "Mi" 1048576.0 "Gi" 1073741824.0 "Ti" 1099511627776.0 "Pi" 1125899906842624.0 "Ei" 1152921504606846976.0
  "k" 1000.0 "M" 1000000.0 "G" 1000000000.0 "T" 1000000000000.0 "P" 1000000000000000.0 "E" 1000000000000000000.0 "m" 1.0 }}
{{- $unit := trimPrefix $n $q }}
{{- if or (not $n) (not (hasKey $units $unit)) }}
{{- fail (printf "firefox-sync: %q is no size of a volume (e.g. 8Gi, 500Mi)" $q) }}
{{- end }}
{{- if eq $unit "m" }}
{{- /* (divided: an exact quotient stays exact) */}}
{{- printf "%.0f" (ceil (divf (float64 $n) 1000.0)) }}
{{- else }}
{{- printf "%.0f" (ceil (mulf (float64 $n) (get $units $unit))) }}
{{- end }}
{{- end }}

{{/*
A volume's persistence values (size, storageClass) against the volume the cluster has, or the
render fails before anything is applied, saying what to set: Kubernetes refuses those changes
only once the objects before it were changed (docs/install/helm.md#volumes). Accepts a dict
with "setting" (the values' name, e.g. database.persistence), "what" (the object, for the
message), "persistence" (the values), "accessModes" (the chart's), "live" (the spec of the
existing PVC, or of the StatefulSet's volumeClaimTemplate), "template" (true: a
StatefulSet's) and "class" (the StorageClass of the PVC when the size grows: its
allowVolumeExpansion).
- a StatefulSet's volumeClaimTemplates never change: the size, the class and the access modes
  as they were (to grow, resize its PVC itself);
- a PVC: its class and access modes never change (an empty storageClass keeps the PVC's,
  pvcStorageClass); its size never shrinks (at least the PVC's, also one grown by hand); it
  grows only with a StorageClass of allowVolumeExpansion
*/}}
{{- define "firefox-sync.checkClaim" -}}
{{- $p := .persistence }}
{{- $live := .live | default dict }}
{{- $help := "docs/install/helm.md#volumes (another class or access mode: a new volume, a backup and a restore)" }}
{{- $liveClass := $live.storageClassName | default "" }}
{{- $liveModes := $live.accessModes | default list }}
{{- $liveSize := ((($live.resources | default dict).requests | default dict).storage | default "") | toString }}
{{- if .template }}
{{- if ne ($p.storageClass | default "") $liveClass }}
{{- fail (printf "firefox-sync: %s.storageClass is %q but %s was created with %q (empty: the cluster's default): Kubernetes never changes a StatefulSet's volumeClaimTemplates; set it back to %q, see %s" .setting ($p.storageClass | default "") .what $liveClass $liveClass $help) }}
{{- end }}
{{- if and $liveSize (ne (include "firefox-sync.bytes" $p.size) (include "firefox-sync.bytes" $liveSize)) }}
{{- fail (printf "firefox-sync: %s.size is %s but %s was created with %s: Kubernetes never changes a StatefulSet's volumeClaimTemplates; set it back to %s, and to grow the volume resize its PVC itself (a StorageClass with allowVolumeExpansion), see docs/install/helm.md#volumes" .setting $p.size .what $liveSize $liveSize) }}
{{- end }}
{{- else }}
{{- if and $p.storageClass (ne $p.storageClass $liveClass) }}
{{- fail (printf "firefox-sync: %s.storageClass is %q but %s is on %q: Kubernetes never changes a PVC's class; set it back to %q (or empty: the PVC's), see %s" .setting $p.storageClass .what $liveClass $liveClass $help) }}
{{- end }}
{{- if $liveSize }}
{{- $new := include "firefox-sync.bytes" $p.size | float64 }}
{{- $old := include "firefox-sync.bytes" $liveSize | float64 }}
{{- if lt $new $old }}
{{- fail (printf "firefox-sync: %s.size is %s but %s is %s: Kubernetes never shrinks a volume; set at least %s, see docs/install/helm.md#volumes" .setting $p.size .what $liveSize $liveSize) }}
{{- end }}
{{- if and (gt $new $old) (not (.class | default dict).allowVolumeExpansion) }}
{{- fail (printf "firefox-sync: %s.size is %s but %s is %s, and its StorageClass %q does not allow expansion (allowVolumeExpansion): keep %s, see docs/install/helm.md#volumes" .setting $p.size .what $liveSize $liveClass $liveSize) }}
{{- end }}
{{- end }}
{{- end }}
{{- if and $liveModes (ne (toJson $liveModes) (toJson .accessModes)) }}
{{- fail (printf "firefox-sync: %s has the access modes %s, the chart's are %s: Kubernetes never changes them; see %s" .what (toJson $liveModes) (toJson .accessModes) $help) }}
{{- end }}
{{- end }}

{{/*
The storageClassName of one of the chart's PVCs (empty: none rendered), after checkClaim on
the PVC the cluster has (lookup on install and upgrade; nothing to check where it returns
nothing: helm template, a GitOps render, a new PVC): the values' storageClass, else the PVC's
own (an empty storageClass is the cluster's default when the PVC is made, kept after: no
change to apply when the default class changes, or when a class set before is emptied).
Accepts a dict with "root", "name" (the PVC), "setting" and "persistence"
*/}}
{{- define "firefox-sync.pvcStorageClass" -}}
{{- $p := .persistence }}
{{- $existing := lookup "v1" "PersistentVolumeClaim" .root.Release.Namespace .name }}
{{- if $existing }}
{{- $class := dict }}
{{- $liveSize := ((($existing.spec.resources | default dict).requests | default dict).storage | default "") | toString }}
{{- if and $liveSize $existing.spec.storageClassName (gt (include "firefox-sync.bytes" $p.size | float64) (include "firefox-sync.bytes" $liveSize | float64)) }}
{{- /* (a cluster-scoped read, only when the size grows) */}}
{{- $class = lookup "storage.k8s.io/v1" "StorageClass" "" $existing.spec.storageClassName }}
{{- end }}
{{- include "firefox-sync.checkClaim" (dict "setting" .setting "what" (printf "the PVC %s" .name) "persistence" $p "accessModes" (list "ReadWriteOnce")
  "live" $existing.spec "class" $class) }}
{{- $p.storageClass | default $existing.spec.storageClassName | default "" }}
{{- else }}
{{- $p.storageClass | default "" }}
{{- end }}
{{- end }}

{{/*
checkClaim on a StatefulSet's volumeClaimTemplate the cluster has (lookup on install and
upgrade; nothing where it returns nothing). Accepts a dict with "root", "name" (the
StatefulSet), "claim" (its template's name), "setting" and "persistence"
*/}}
{{- define "firefox-sync.checkStatefulSetClaim" -}}
{{- with lookup "apps/v1" "StatefulSet" .root.Release.Namespace .name }}
{{- range (.spec.volumeClaimTemplates | default list) }}
{{- if eq .metadata.name $.claim }}
{{- include "firefox-sync.checkClaim" (dict "setting" $.setting "what" (printf "the StatefulSet %s (its volume %s)" $.name $.claim) "persistence" $.persistence
  "accessModes" (list "ReadWriteOnce") "live" .spec "template" true) }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
The data of the db-setup ConfigMap (db-setup.yaml): db-setup.sh, with your own Sync server
sync.sql (db/mysql/sync.sql, db/postgres/sync.sql), with your own accounts server fxa.sql
(db/mysql/fxa-<backend>.sql); empty with the bundled servers. Also the checksum of the pods
that mount it
*/}}
{{- define "firefox-sync.dbSetupData" -}}
{{- $sync := not .Values.database.bundled }}
{{- $fxa := and .Values.fxa.enabled (not .Values.fxa.database.bundled) }}
{{- if or $sync $fxa }}
db-setup.sh: |
  {{- .Files.Get "files/db-setup.sh" | trimSuffix "\n" | nindent 2 }}
{{- if $sync }}
sync.sql: |
  {{- .Files.Get (printf "files/sync-%s.sql" (ternary "postgres" "mysql" (eq .Values.database.backend "postgres"))) | trimSuffix "\n" | nindent 2 }}
{{- end }}
{{- if $fxa }}
fxa.sql: |
  {{- .Files.Get (printf "files/fxa-%s.sql" .Values.fxa.database.backend) | trimSuffix "\n" | nindent 2 }}
{{- end }}
{{- end }}
{{- end }}

{{/*
The volume of the db-setup ConfigMap for a db-bootstrap init container: db-setup.sh and the
SQL of the scope ("root", "scope": sync or fxa) at /ffs-db, as compose mounts them
*/}}
{{- define "firefox-sync.dbSetupVolume" -}}
- name: db-setup
  configMap:
    name: {{ include "firefox-sync.fullname" .root }}-db-setup
    items:
      - key: db-setup.sh
        path: db-setup.sh
      - key: {{ .scope }}.sql
        path: {{ .scope }}.sql
{{- end }}
