# Install with Helm

This page installs the Sync server on Kubernetes with the Helm chart [charts/firefox-sync](/charts/firefox-sync). The chart runs the same images as docker compose, with the settings of `.env` as values. Read [What you need](../README.md#what-you-need) first.

The chart runs syncstorage-rs with its tokenserver, its migrations and the init container of `maxUsers`, and the databases: MariaDB, MySQL or PostgreSQL, or [your own server](../databases.md#with-helm). The admin UI, the nightly backups and the [self-hosted accounts](#self-hosted-accounts) are optional.

## Requirements

- Kubernetes 1.27 or later, and Helm 4, the one CI tests. Helm 3.16 or later is known to work (it passed the accounts' end-to-end test), but CI does not test it.
- A default StorageClass, or `database.persistence.storageClass` and `backup.persistence.storageClass`. The chart needs one volume per database server and one for the backups, and with the self-hosted accounts one each for their keys and avatars.
- A host name with HTTPS that reaches the Sync server: an Ingress controller ([Ingress](#ingress)), or your own reverse proxy in front of the Service `<release>-firefox-sync-syncstorage`, port 8000.
- A namespace at the [PodSecurity](https://kubernetes.io/docs/concepts/security/pod-security-standards/) level `baseline`, or `privileged` (the default):

  ```bash
  kubectl label ns <namespace> pod-security.kubernetes.io/enforce=baseline
  ```

- In a namespace with a ResourceQuota on `cpu` or `memory`: requests and limits for every container ([Resources](#resources)), or a LimitRange with defaults.

<details><summary>Why not <code>restricted</code></summary>

Only the admin UI's pod meets `restricted`. The database servers start as root and drop to their user (the images' entrypoints, with `gosu`). The backups run as root, because the dumps are root's. So do the Sync server's init containers `sync-role` and `db-init`: their images have no other user.

Every pod has `seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation: false` and no service account token. The tests install the chart into a namespace that enforces `baseline`.

</details>

## Install

1. Write a `my-values.yaml`. A minimal one, with ingress-nginx and cert-manager:

   ```yaml
   syncDomain: https://sync.example.com
   # how many accounts can use the server, see docs/limits.md
   maxUsers: "5"
   ingress:
     enabled: true
     className: nginx
     tls:
       enabled: true
       secretName: sync-example-com-tls
     annotations:
       cert-manager.io/cluster-issuer: letsencrypt-prod
       nginx.ingress.kubernetes.io/proxy-body-size: "10m"
   ```

   `maxUsers` takes the forms of [`SYNC_MAX_USERS`](../limits.md#sync_max_users). The body size is explained in [Ingress](#ingress).

1. Install the chart:

   ```bash
   helm install ffs oci://ghcr.io/porelli/firefox-sync/charts/firefox-sync --version 0.1.0 \
     -f my-values.yaml --wait --timeout 10m
   ```

   `ffs` is the release name: the objects are called `ffs-firefox-sync-*`, as in the commands of this page. For a namespace of its own, add `-n <namespace> --create-namespace`, and `-n <namespace>` to every `kubectl` command.

1. Read what `helm install` prints next (the NOTES). The first start takes a minute or two: the databases are created, then the migrations and the init container run before the Sync server.

1. Check the pods and the init container:

   ```bash
   kubectl get pods -l app.kubernetes.io/instance=ffs
   kubectl logs deploy/ffs-firefox-sync-syncstorage -c db-init   # Current users: N
   ```

1. [Set up Firefox](../firefox.md), with `https://sync.example.com`.

With PostgreSQL, pin its major in your values after the first install: see [Upgrading](../upgrading.md#postgresql). `helm upgrade` refuses a database image of another major than the one running: see [Database majors](../upgrading.md#database-majors).

Every value is in [values.yaml](/charts/firefox-sync/values.yaml), with what it does. Each setting of `.env` and its value are in [Settings](../reference/settings.md), in the Helm column. The chart's schema refuses a key it does not know, so a typo such as `admin.enable` fails the install instead of doing nothing. The maps of Kubernetes (annotations, resources, the scheduling) are not checked.

### Resources

None by default, as compose sets none. What the database servers need grows with the data and the accounts, and a memory limit set too low gets a server killed in the middle of a write. Set them where your cluster wants them, for example with a ResourceQuota or nodes shared with others.

| Values | Containers |
|---|---|
| `syncstorage.resources` | the Sync server |
| `syncstorage.initResources` | its init containers `wait-db`, `sync-role` (PostgreSQL), `migrate` and `db-init`, one at a time before it. `migrate` runs a whole Sync server: give it about what `syncstorage.resources` has |
| `database.resources` | each bundled database server: two with MariaDB and MySQL, one with PostgreSQL |
| `admin.resources` | the admin UI and its init container `wait-sync` |
| `backup.resources` | the backup, and the one-shot Job that binds its PVC at install |

For a few accounts, for example:

```yaml
syncstorage:
  resources:
    requests: {cpu: 50m, memory: 64Mi}
    limits: {memory: 512Mi}
  initResources:
    requests: {cpu: 50m, memory: 64Mi}
    limits: {memory: 512Mi}
database:
  resources:
    requests: {cpu: 100m, memory: 256Mi}
    limits: {memory: 1Gi}
```

### Scheduling and pulling

`nodeSelector`, `tolerations`, `affinity` (as in a pod spec) and `podAnnotations` apply to every pod of the chart: the Sync server, the admin UI, the database servers, the backups and the self-hosted accounts. The chart's own annotations, its checksums, stay.

`imagePullSecrets` (`[{name: my-registry}]`) applies to every pod too, for a registry that needs a login. That is a mirror of `ghcr.io/porelli/firefox-sync`, and of Docker Hub, whose official images the database servers and the backups run. The `database.image.*` values are fully qualified (`docker.io/library/...`) for the nodes whose runtime has another default registry.

### Volumes

`helm upgrade` refuses a change of a volume that Kubernetes would refuse, before anything is applied, with a `firefox-sync: ...` message that says what to set. Kubernetes itself would refuse it only after the objects before it were changed. The chart reads the volumes of the cluster for that, so `helm template` and a GitOps render check nothing.

The database servers' volumes, `database.persistence.*` and `fxa.database.persistence.*`, are those of their StatefulSets (`volumeClaimTemplates`), which Kubernetes never changes: choose their size and storage class before the first install, and keep them as they were. To grow such a volume, keep the values and resize its PVC, with a StorageClass that has `allowVolumeExpansion: true` ([volume expansion](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#expanding-persistent-volumes-claims)):

```bash
kubectl patch pvc data-ffs-firefox-sync-tokenserver-db-0 -p '{"spec": {"resources": {"requests": {"storage": "20Gi"}}}}'
```

The other PVCs are `data-ffs-firefox-sync-storage-db-0` (the storage), `data-ffs-firefox-sync-postgres-0`, and `data-ffs-firefox-sync-fxa-db-0` for the accounts (`data-mariadb-...` on MariaDB). Some storage drivers grow a volume only when its pod restarts: `kubectl delete pod ffs-firefox-sync-storage-db-0`.

The plain PVCs, the backups' (`backup.persistence.*`), the keys' (`fxa.keys.persistence.*`) and the avatars' (`fxa.profileImages.persistence.*`), grow with the values: a larger `size` and `helm upgrade`, when their StorageClass has `allowVolumeExpansion: true`. Without it, or with a smaller size than the PVC has, the upgrade is refused: Kubernetes never shrinks a volume. A PVC grown by hand needs a `size` of at least its own. Checking the StorageClass reads it from the cluster, which a namespace-only Helm user may not do: grow the PVC with `kubectl patch` then, and set its size in the values.

A volume's storage class never changes. An empty `storageClass` is the cluster's default when the volume is made: a plain PVC keeps its class after that, also when the default changes. Another class, or a database server's on another one, needs a new volume, so a backup and a restore into it: see [Restore on Kubernetes](../backups.md#restore-on-kubernetes).

## The Secret

On the first install, the chart generates the secrets of `.env` into the Secret `ffs-firefox-sync`. It reads them back on every `helm upgrade` (Helm's `lookup`), so they never change: `SYNC_MASTER_SECRET`, `METRICS_HASH_SECRET` (`.env`'s `SYNC_METRICS_HASH_SECRET`), `ADMIN_PASSWORD` (unless you set `admin.password`) and the database passwords. A key that a new chart version adds is generated at the upgrade.

The Secret has `helm.sh/resource-policy: keep`: `helm uninstall` leaves it, like the databases' volumes. A new install with the same release name then finds the passwords the databases were created with.

Keep a copy of it, with your values, off the cluster. The backups do not have it.

```bash
kubectl get secret ffs-firefox-sync -o json \
  | jq '{apiVersion, kind, type, data, metadata: (.metadata | {name, labels, annotations})}' > ffs-secret.json
```

The optional secrets of the admin UI come from the values alone: `smtp.password`, `admin.oidc.clientSecret`, `admin.metricsToken` and `admin.notify`. The chart writes them into the Secret on every install and upgrade (`FXA_SMTP_PASS`, `ADMIN_OIDC_CLIENT_SECRET`, `ADMIN_METRICS_TOKEN`, `ADMIN_NOTIFY`). An empty value turns that feature off, whatever was put into the Secret by hand.

### existingSecret

A Secret of your own, which the chart reads and never writes. It is required:

- with your own database server (`database.bundled: false`): the chart cannot generate passwords your server knows;
- when the chart is rendered without the cluster: `helm template`, or a GitOps tool that renders it (Argo CD...). `lookup` finds nothing there, so every render would generate new secrets. Every Firefox would be signed out, and the databases would refuse the new passwords.

Its keys:

| Key | Backend | What it is |
|---|---|---|
| `SYNC_MASTER_SECRET` | all | the Sync server's tokens (`.env`: `SYNC_MASTER_SECRET`) |
| `METRICS_HASH_SECRET` | all | the hash of the account ids in the metrics (`.env`: `SYNC_METRICS_HASH_SECRET`) |
| `ADMIN_DB_PASSWORD` | all, except MariaDB and MySQL on your own server without the admin UI and the backups | the admin UI's two database users ([The admin UI's own database](../reference/database-users.md#the-admin-uis-own-database)) |
| `TOKENSERVER_DB_PASSWORD`, `STORAGE_DB_PASSWORD` | `mariadb`, `mysql` | the tokenserver and storage users |
| `POSTGRES_PASSWORD` | `postgres` | the superuser of the bundled server; on your own server the owner, `database.external.postgresUser` |
| `POSTGRES_SYNC_PASSWORD` | `postgres`, bundled | the Sync server's own role `syncserver_app` (`database.postgresSyncUser`), no superuser |
| `SYNC_DB_BOOTSTRAP_PASSWORD` | your own server, a non-empty `database.external.bootstrap.user` | that account's password, which applies the SQL at every start ([Let the stack apply them](../databases.md#let-the-stack-apply-them)) |
| `ADMIN_PASSWORD` | optional | the admin UI's password. Missing or empty: no password form ([Signing in](../admin/signing-in.md)) |
| `FXA_SMTP_PASS`, `ADMIN_OIDC_CLIENT_SECRET`, `ADMIN_METRICS_TOKEN`, `ADMIN_NOTIFY` | optional | the admin UI's. Missing or empty: that feature is off |
| `FXA_MYSQL_PASSWORD` | `fxa.enabled` | the accounts database's user: `root` of the bundled server, or `fxa.database.external.user` on your own |
| `FXA_ADMIN_DB_PASSWORD` | `fxa.enabled` | the admin UI's user `ffs_admin` of the accounts database |
| `FXA_AUTH_SECRET`, `FXA_OAUTH_SECRET`, `FXA_PROFILE_SECRET`, `FXA_FLOW_ID_KEY`, `FXA_SESSION_TOKEN_HANDLE_KEY`, `FXA_CONTENT_SESSION_SECRET` | `fxa.enabled` | the accounts services' secrets, as in `.env` |
| `FXA_REDIS_PASSWORD` | `fxa.enabled` | the password of the accounts' Redis. The chart's own: `.env` has none |
| `FXA_MYSQL_POLICY_PASSWORD` | `fxa.enabled`, your own accounts database server, a non-empty `fxa.database.external.policyUser` | that user's password. The chart never generates it |
| `FXA_DB_BOOTSTRAP_PASSWORD` | `fxa.enabled`, your own accounts database server, a non-empty `fxa.database.external.bootstrap.user` | that account's password, as `SYNC_DB_BOOTSTRAP_PASSWORD` |
| `ADMIN_FXA_CLIENT_SECRET` | optional | leave it out: see [Sign in with the accounts](#sign-in-with-the-accounts) |

With `existingSecret`, the chart does not read the values of those optional secrets (`smtp.password`, `admin.oidc.clientSecret`, `admin.metricsToken`, `admin.notify`, `fxa.adminClientSecret`), nor `admin.password`. With `fxa.enabled`, an install or upgrade whose `existingSecret` lacks one of the accounts' keys is refused, with the missing keys named.

For MariaDB or MySQL, for example:

```bash
rnd() { LC_ALL=C tr -dc A-Za-z0-9 < /dev/urandom | head -c 32; }
kubectl create secret generic ffs-secrets \
  --from-literal=SYNC_MASTER_SECRET="$(rnd)" --from-literal=METRICS_HASH_SECRET="$(rnd)" \
  --from-literal=ADMIN_PASSWORD="$(rnd)" --from-literal=ADMIN_DB_PASSWORD="$(rnd)" \
  --from-literal=TOKENSERVER_DB_PASSWORD="$(rnd)" --from-literal=STORAGE_DB_PASSWORD="$(rnd)"
```

Then set `existingSecret: ffs-secrets` in your values. With PostgreSQL, use `POSTGRES_PASSWORD` and `POSTGRES_SYNC_PASSWORD` instead of the last two. With the self-hosted accounts, add each of their keys the same way, for example `--from-literal=FXA_REDIS_PASSWORD="$(rnd)"`. With a GitOps tool, create the same keys from your secrets manager (Sealed Secrets, External Secrets...).

A key missing that a pod needs stops it in `CreateContainerConfigError` until the key is there; `kubectl describe pod` names it. A new chart version that needs a new key says so in its release notes.

## Your own database server

`database.bundled: false`, `database.external.*`, and an `existingSecret` with the passwords of the users you created: see [Databases](../databases.md#with-helm).

## Ingress

`ingress.enabled` publishes the Sync server at `/` of `ingress.host` (empty: the host of `syncDomain`), with the controller of `ingress.className`.

- TLS: `ingress.tls.enabled`, with `ingress.tls.secretName`. Empty, the controller's default certificate is used. cert-manager needs a `secretName` to write the certificate into.
- Body size: with ingress-nginx, raise `nginx.ingress.kubernetes.io/proxy-body-size`, `"10m"` in the example above. Why: [Request size](../reverse-proxy.md#request-size). Other controllers: their own limit of the request body, if they have one.

Without the Ingress, publish the Service `ffs-firefox-sync-syncstorage:8000` your own way, at `syncDomain`. The admin UI never shares this Ingress: see [Admin UI](#admin-ui).

## Admin UI

Turn it on in your values, then `helm upgrade`:

```yaml
admin:
  enabled: true
  alertEmail: you@example.com
smtp:
  host: smtp.example.com
  user: sync@example.com
  password: <the SMTP password>
  sender: sync@example.com
```

The values are the settings of `.env` under other names: `admin.alertEmail` is `ADMIN_ALERT_EMAIL`, `admin.oidc.*` is `ADMIN_OIDC_*`, `admin.notify` is `ADMIN_NOTIFY` (a list of URLs), and so on. Email alerts also need the SMTP server, the top-level `smtp.*` (`FXA_SMTP_*`), which the self-hosted accounts share. Each one is in [values.yaml](/charts/firefox-sync/values.yaml) and in the Helm column of [Settings](../reference/settings.md#admin-ui).

The chart tells the admin UI that it runs on Kubernetes (`ADMIN_DEPLOYMENT=kubernetes`). Its pages then give `kubectl` and `helm upgrade` commands and the names of the values, instead of `.env` and docker compose.

The admin UI is not published. Reach it with a port-forward, then open `http://localhost:8090`:

```bash
kubectl port-forward svc/ffs-firefox-sync-admin 8090:8080
kubectl get secret ffs-firefox-sync -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d   # the password
```

Or give it an Ingress of its own, on a host of its own: the chart refuses the Sync server's host. Put it behind your own sign-in, since the admin UI can delete accounts. For example only from your network, with OpenID Connect (`admin.oidc.*`, with `admin.oidc.redirectUrl: https://admin.example.com/auth/callback`) or with a forward-auth proxy (`admin.trustedHeader.*`): see [Signing in](../admin/signing-in.md).

```yaml
admin:
  enabled: true
  ingress:
    enabled: true
    className: nginx
    host: admin.example.com
    tls:
      enabled: true
      secretName: admin-example-com-tls
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-prod
      nginx.ingress.kubernetes.io/whitelist-source-range: 192.0.2.0/24
```

Without `admin.ingress.tls.enabled` the NOTES warn: unless the controller adds TLS, the password and the session cookie cross the network in plain HTTP.

## Self-hosted accounts

`fxa.enabled` runs the [self-hosted Mozilla accounts](../accounts.md) in the cluster, with the same images as compose: their database, Redis, the auth, content and profile servers, and optionally the pairing server. The chart points the Sync server to them. Read their [requirements](../accounts.md#requirements) first: four host names, an SMTP server and about 3-4 GB of memory.

1. Add them to your `my-values.yaml`, next to `syncDomain` and the Sync server's Ingress of [Install](#install):

   ```yaml
   smtp:
     host: smtp.example.com
     user: accounts@example.com
     password: <the SMTP password>
     sender: "Mozilla accounts <no-reply@example.com>"
   fxa:
     enabled: true
     contentUrl: https://accounts.example.com
     authUrl: https://api.example.com
     profileUrl: https://profile.example.com
     signups: allowlist
     signupAllowlist: ["@example.com"]
     ingress:
       enabled: true
       className: nginx
       annotations:
         cert-manager.io/cluster-issuer: letsencrypt-prod
       tls:
         enabled: true
         secretNames:
           content: accounts-example-com-tls
           auth: api-example-com-tls
           profile: profile-example-com-tls
   ```

   Each URL needs a host of its own, none of the Sync server's or the admin UI's: the chart refuses the others. Each `.env` setting and its value are in [Settings](../reference/settings.md#accounts). Who can sign up: [Who can sign up](../accounts.md#who-can-sign-up). The Ingresses, and your own proxy instead: [Kubernetes](../reverse-proxy.md#kubernetes).
1. Install, or upgrade an install, with them. The first start pulls the accounts image (about 5 GB) and creates their databases, hence the longer timeout:

   ```bash
   helm upgrade --install ffs oci://ghcr.io/porelli/firefox-sync/charts/firefox-sync --version <chart version> \
     -f my-values.yaml --wait --timeout 20m
   ```

1. Check the auth server's init containers, in their order: the migrations, then the sign-up policy.

   ```bash
   kubectl get pods -l app.kubernetes.io/instance=ffs
   kubectl logs deploy/ffs-firefox-sync-fxa-auth -c migrations
   kubectl logs deploy/ffs-firefox-sync-fxa-auth -c policy
   ```

1. [Set up Firefox](../firefox.md#self-hosted-accounts). `identity.fxaccounts.autoconfig.uri` alone is enough: the NOTES also print the token server URL of Mozilla's accounts, which Firefox then does not need.

A private CA, for your SMTP server or your own HTTPS hosts: put its PEM file into a ConfigMap, and name it in `fxa.extraCaCerts.configMap` and `.key`.

### The signing keys

The auth server writes its keys at its first start, onto the PVC `ffs-firefox-sync-fxa-keys`, and never again while that volume is there. `helm uninstall` keeps it. Losing it signs everyone out, and the [backups](../backups.md#kubernetes) don't have it. So keep a copy off the cluster, for example as a Secret of yours:

```bash
kubectl exec deploy/ffs-firefox-sync-fxa-auth -c auth -- tar -C /fxa-keys -c secret-key.json public-key.json vapid-keys.json openid-key.json > fxa-keys.tar
mkdir fxa-keys && tar -C fxa-keys -xf fxa-keys.tar
kubectl create secret generic ffs-firefox-sync-fxa-keys --from-file=fxa-keys
```

With `fxa.keys.existingSecret: ffs-firefox-sync-fxa-keys`, the auth pod copies them from that Secret at every start, and stops in its init container `keys-copy` while one of the four files is missing or empty. The chart then creates no keys PVC. One made before stays, and you can delete it.

- `helm template` and GitOps tools need an [existingSecret](#existingsecret) with the accounts' keys too: otherwise each render makes new secrets, and signs everyone out.
- Argo CD does not read `helm.sh/resource-policy: keep`. A pruning sync deletes a PVC that leaves the render: the keys' one when you set `fxa.keys.existingSecret` or turn the accounts off, and the avatars' (`ffs-firefox-sync-fxa-profile-images`). With Argo CD, use `fxa.keys.existingSecret` from the first install, and keep pruning off for the accounts' PVCs.

### Sign in with the accounts

With the admin UI (`admin.enabled`), the chart adds its [sign-up gate](../reverse-proxy.md#sign-up-gate) to the accounts API's Ingress. `admin.fxaSignIn: true` also lets the admins sign in to the admin UI with these accounts ([Self-hosted accounts](../admin/signing-in.md#self-hosted-accounts)):

```yaml
admin:
  enabled: true
  fxaSignIn: true
  allowed:
    users: alice@example.com
  ingress:
    enabled: true
    host: admin.example.com
    # className, tls, annotations as in Admin UI above
```

- `admin.allowed.users` or `.groups` is required: who of the accounts is an admin.
- The accounts send the admins back to `admin.oidc.redirectUrl`, which must be `https://<host>/auth/callback`. Empty, it is `https://<admin.ingress.host>/auth/callback`.
- The `admin.oidc.*` left empty take the accounts': the issuer `fxa.contentUrl`, the name "Mozilla account", and `trustUnverifiedEmail` true.
- The admin UI's OAuth client id is derived from the namespace and the release name: `printf '%s/%s/admin-oidc' <namespace> <release> | sha256sum | cut -c1-16`. It stays the same on every upgrade. A render with another namespace, such as `helm template` without `-n`, gets another id: the accounts register the new client at their next start, and drop the old one. To fix it, set `fxa.adminClientId` (16 hex characters, `openssl rand -hex 8`).
- The admin UI's pod signs in through the accounts' public URLs, so it must resolve and reach them from inside the cluster, with a certificate it trusts (`fxa.extraCaCerts` for a private CA).
- `fxa.adminClientId` needs `admin.fxaSignIn`: the chart refuses it alone. Leave `fxa.adminClientSecret` empty: the accounts refuse PKCE from clients with a secret.

### Pairing

The phones pair through Mozilla's pairing server unless you run your own ([Pair a phone](../firefox.md#pair-a-phone)). For the chart's own, set `fxa.pairing.enabled: true`, `fxa.pairing.url: wss://pairing.example.com` and `fxa.ingress.tls.secretNames.pairing`. Its websockets need a longer timeout at the Ingress controller: see [Kubernetes](../reverse-proxy.md#kubernetes).

A `fxa.pairing.url` without `fxa.pairing.enabled` is still given to Firefox, as with compose, for a pairing server you run elsewhere.

### MySQL or MariaDB

`fxa.database.backend` is `mysql` (the default) or `mariadb`, whatever `database.backend` is ([MySQL or MariaDB](../accounts.md#mysql-or-mariadb)). The images and their majors: [Database majors](../upgrading.md#database-majors). Your own server instead: [With Helm](../databases.md#with-helm).

Choose before the first install. Each backend has its volume: `data-ffs-firefox-sync-fxa-db-0` for MySQL, `data-mariadb-ffs-firefox-sync-fxa-db-0` for MariaDB.

- A `helm upgrade` to the other backend is refused before anything changes: `firefox-sync: fxa.database.backend is mariadb but the accounts database was created with mysql ...`.
- Moving to the other backend takes a dump and a restore ([Restore on Kubernetes](../backups.md#restore-on-kubernetes)). That is not tested here.
- Turning the accounts off and on again with the other backend is not refused: the server starts on a new, empty volume, and the old PVC stays until you delete it.

### Resources and PodSecurity

The accounts' containers have memory requests by default, and no limits. The requests add up to about 2.6 GiB; plan 3-4 GB. Change them with `fxa.resources.*` (`auth`, `content`, `profile`, `profileWorker`, `profileStatic`, `imgProxy`, and `init` for the init containers), `fxa.database.resources`, `fxa.redis.resources` and `fxa.pairing.resources`.

The accounts' images run as the user 10001, and new volumes are root's. By default (`fxa.volumeOwnerInit: true`) two init containers, `keys-owner` and `images-owner`, change the owner of the keys' and the avatars' volumes as root, with the `CHOWN` capability alone. That needs PodSecurity `baseline`, as the database servers do.

With `fxa.volumeOwnerInit: false` there are none, and the accounts' pods get `fsGroup: 10001` instead. Then no accounts container runs as root except the database server's, and the other accounts pods meet `restricted`. It needs a StorageClass whose volumes Kubernetes gives the `fsGroup`. With one that does not (`hostPath`, kind's `local-path`), the auth server cannot write its keys.

### NetworkPolicies

`fxa.networkPolicy.enabled` (`true`) admits only these pods of the release to the accounts' Redis and database:

| Server | Port | From |
|---|---|---|
| Redis, `ffs-firefox-sync-fxa-redis` | 6379 | the auth, content and profile servers, and the admin UI when it is on |
| the bundled database, `ffs-firefox-sync-fxa-db` | 3306 | the auth server (also its migrations and policy), the profile server, the admin UI and the backups when they are on |

Only a network plugin that enforces NetworkPolicies applies them. Redis also has a password, `FXA_REDIS_PASSWORD` of the Secret, which it reads from its standard input: it is in neither the pod's spec nor its arguments. A tool of yours that connects to the accounts' database needs a NetworkPolicy of its own.

Without more, any pod of the cluster reaches the accounts' public servers directly, past the Ingress. For the auth server that matters: such a pod sets `X-Forwarded-For` itself, and `fxa.clientAddressDepth` takes the client's address from its end, so it picks the address the rate limits see. It also creates accounts around the sign-up gate, which is on the Ingress' path only (the database still enforces the sign-up policy). `fxa.networkPolicy.servers.enabled: true` admits only the Ingress controller, these pods of the release, and `fxa.networkPolicy.servers.extraFrom`:

| Server | Ports | From the release |
|---|---|---|
| auth, `ffs-firefox-sync-fxa-auth` | 9000 | the content and profile servers, the Sync server (it checks Firefox's OAuth tokens there), the admin UI (its sign-up gate, its health checks) |
| content, `ffs-firefox-sync-fxa-content` | 3030 | the admin UI |
| profile, `ffs-firefox-sync-fxa-profile` | 1111, 1112 (`static`), 1114 (`img`) | the auth and content servers, the admin UI |
| pairing, `ffs-firefox-sync-fxa-pairing` (with `fxa.pairing.enabled`) | 8000 | the admin UI |

The backups need none of them. It is off by default because the chart cannot know your Ingress controller. Name its pods in `fxa.networkPolicy.servers.ingressController`, as one NetworkPolicy peer: `namespaceSelector` and `podSelector` together select the pods of those labels in the namespaces of those labels, and `podSelector` alone selects them in the release's namespace. `namespaceSelector` alone admits every pod of those namespaces: with the controller in the release's own namespace, set its `podSelector` too. One of them is required: the render refuses an empty one, which would admit every pod. It also needs `fxa.networkPolicy.enabled`. For ingress-nginx, installed with its Helm chart in the namespace `ingress-nginx`:

```yaml
fxa:
  networkPolicy:
    servers:
      enabled: true
      ingressController:
        namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: ingress-nginx
        podSelector:
          matchLabels:
            app.kubernetes.io/name: ingress-nginx
```

For Traefik, its Helm chart labels the pods `app.kubernetes.io/name: traefik`, in the namespace you install it in (`kube-system` for the one of k3s). Check the labels with `kubectl get pods -A -l app.kubernetes.io/name=traefik --show-labels`.

`extraFrom` takes more peers as a NetworkPolicy has them: your own reverse proxy, a tool that reads the heartbeats, or a controller on the host network (`hostNetwork: true`), whose connections come from its node's address: `- ipBlock: {cidr: 192.168.1.0/24}`. How a network plugin treats the nodes' own traffic varies; the kubelet's probes still pass with the policies on kind's kindnet, which the tests use.

### Access control

What can go behind a sign-in proxy or client certificates, and why the rest cannot: [Single sign-on and client certificates](../access-control.md). These notes for ingress-nginx follow its docs and Authelia's ([Authelia with ingress-nginx](https://www.authelia.com/integration/kubernetes/nginx-ingress/)); the chart's e2e does not run them.

- **Not in `fxa.ingress.annotations`.** They go on all the accounts' Ingresses, the API's too, which must stay open.
- **The admin UI** has an Ingress of its own: its `admin.ingress.annotations` can take Authelia's (`nginx.ingress.kubernetes.io/auth-url`, `auth-signin`, `auth-method`, `auth-response-headers`, with `admin.trustedHeader.*`, see [Trusted header](../admin/signing-in.md#trusted-header)), or a client certificate: `nginx.ingress.kubernetes.io/auth-tls-secret: <namespace>/<Secret with ca.crt>` and `auth-tls-verify-client: "on"`.
- **The accounts pages behind Authelia:** set `fxa.ingress.enabled: false` and publish the hosts with Ingresses of your own, as the table of [The accounts' Ingresses](../reverse-proxy.md#the-accounts-ingresses). For the pages' host, two Ingresses: one at `/` with Authelia's annotations, one without them for [the open paths](../access-control.md#the-open-paths), each `Exact`. ingress-nginx merges the Ingresses of one host, and applies the auth annotations to the paths of their own Ingress.
- **The accounts pages with client certificates:** ingress-nginx applies its `auth-tls-*` annotations to a whole host, so it cannot leave the open paths without one. Use another proxy in front for that host, as the [nginx example](/config/nginx/access-control-example.conf).

## Backups and upgrades

- Backups: `backup.enabled`, see [Backups on Kubernetes](../backups.md#kubernetes). With the self-hosted accounts, they dump the accounts too.
- Upgrades, and what `helm uninstall` keeps: see [Upgrading with Helm](../upgrading.md#helm). A new accounts release: see [Self-hosted accounts](../upgrading.md#self-hosted-accounts).
- From docker compose to Kubernetes, with or without the accounts: see [Migrating](../migrating.md#from-docker-compose-to-kubernetes).

## Limits

- **One Sync server.** `syncstorage.replicas` stays 1: the migrations and the `maxUsers` init run in its init containers, and two at once is not tested.
- **One of each accounts server.** The auth server runs the accounts' migrations in its init containers, and its keys' and the avatars' volumes are `ReadWriteOnce`.
- **Ingress only.** The chart has no Gateway API routes. With a Gateway, publish the Services yourself: see [Kubernetes](../reverse-proxy.md#kubernetes).
- **Release names.** The names the admin UI builds from the release are never truncated: the Services, the StatefulSets, the Sync server's Deployment and the backup CronJob. A name over Kubernetes' limits is refused at render time, with the name that is too long. Only the one-shot Job that binds the backups' PVC has a shortened name of its own.

  With the default fullname `<release>-firefox-sync`, the release name is at most:

  | With | Longest name | Release name |
  |---|---|---|
  | the bundled MariaDB or MySQL | `<fullname>-tokenserver-db`, a StatefulSet (52) | 24 characters |
  | the bundled PostgreSQL | `<fullname>-postgres` | 30 characters |
  | the backups | `<fullname>-backup`, a CronJob (52) | 32 characters |
  | the self-hosted accounts' bundled database | `<fullname>-fxa-db`, a StatefulSet (52) | 32 characters |

  The shortest of those that apply wins. A release name that contains `firefox-sync` is the fullname itself, and `fullnameOverride` sets it.
- **Probes.** The database servers have up to 30 minutes for their first start (a new database, a long recovery), and are restarted only after 5 minutes without an answer, so a server that recovers is not killed half-way. The Sync server is ready once its heartbeat answers, as with the healthcheck of compose.

## Troubleshooting

See [Troubleshooting: Kubernetes](../troubleshooting.md#kubernetes).
