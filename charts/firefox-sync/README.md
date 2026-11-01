# firefox-sync

Self-hosted Firefox Sync: Mozilla's [syncstorage-rs](https://github.com/mozilla-services/syncstorage-rs) with its tokenserver and its databases (MariaDB, MySQL or PostgreSQL, or your own server), and optionally an admin UI, nightly backups and self-hosted Mozilla accounts. Firefox stores its Sync data, encrypted by Firefox, on your cluster. The images are those of [porelli/firefox-sync](https://github.com/porelli/firefox-sync), which also runs with docker compose and Podman.

The full guide: [Install with Helm](https://github.com/porelli/firefox-sync/blob/main/docs/install/helm.md).

## Install

Kubernetes 1.27 or later, Helm 4 (tested; Helm 3.16 or later is known to work, not tested in CI).

```bash
helm install ffs oci://ghcr.io/porelli/firefox-sync/charts/firefox-sync --version 0.1.0 \
  -f my-values.yaml --wait --timeout 10m
```

```yaml
syncDomain: https://sync.example.com
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

Then set up Firefox: [Set up Firefox](https://github.com/porelli/firefox-sync/blob/main/docs/firefox.md).

## Values

Every value is described in [values.yaml](https://github.com/porelli/firefox-sync/blob/main/charts/firefox-sync/values.yaml). The main ones:

| Value | Default | |
|---|---|---|
| `syncDomain` | required | the public URL of the Sync server |
| `maxUsers` | `"1"` | how many accounts can use it: [the forms](https://github.com/porelli/firefox-sync/blob/main/docs/limits.md#the-forms) |
| `allowedAccounts` | `""` (off) | invite-only Sync, the account ids that can start to sync: [SYNC_ALLOWED_ACCOUNTS](https://github.com/porelli/firefox-sync/blob/main/docs/limits.md#sync_allowed_accounts) |
| `database.backend` | `mariadb` | `mariadb`, `mysql` or `postgres` |
| `database.bundled` | `true` | `false`: your own server, `database.external.*` and `existingSecret` |
| `existingSecret` | | a Secret of your own; required with your own server and with `helm template` or GitOps rendering |
| `ingress.*` | off | the Sync server's Ingress |
| `admin.enabled`, `admin.*` | off | the admin UI; `admin.ingress.*` for its own Ingress, behind your own sign-in |
| `backup.enabled`, `backup.*` | off | a CronJob dumping the databases into a PVC |
| `smtp.*` | none | the SMTP server of the admin UI's alerts and of the accounts' emails |
| `fxa.enabled`, `fxa.*` | off | the self-hosted Mozilla accounts, on four hosts of their own: [Self-hosted accounts](https://github.com/porelli/firefox-sync/blob/main/docs/install/helm.md#self-hosted-accounts) |

## Good to know

- The generated Secret (`<release>-firefox-sync`) is read back on upgrades and kept on `helm uninstall`, like the database volumes. Keep a copy off the cluster.
- One Sync server replica, and one of each accounts server: the migrations run in their init containers.
- With the accounts, keep a copy of their signing keys off the cluster: the NOTES give the command.
- Release names have a maximum length, which depends on the components: see [Limits](https://github.com/porelli/firefox-sync/blob/main/docs/install/helm.md#limits). Longer names are refused at render time.
