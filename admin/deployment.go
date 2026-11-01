package main

import (
	"errors"
	"fmt"
	"strings"
)

// deployment: how the stack runs (ADMIN_DEPLOYMENT), for the commands the pages show:
// compose (the default), quadlets, or kubernetes, the Helm chart, which also passes its
// release (ADMIN_K8S_RELEASE) and namespace (ADMIN_K8S_NAMESPACE) for the helm commands,
// the prefix of its objects (ADMIN_K8S_FULLNAME, firefox-sync.fullname), its Secret
// (ADMIN_K8S_SECRET, the chart's or the existingSecret) and where the chart was published
// (ADMIN_K8S_CHART, its Chart.yaml annotation org.firefox-sync/chart) in which version
// (ADMIN_K8S_CHART_VERSION, its .Chart.Version)
type deployment struct {
	// compose, quadlets or kubernetes ("": compose)
	kind string
	// kubernetes: the Helm release and its namespace ("": kubectl's current one)
	release, namespace string
	// kubernetes: the prefix of the chart's objects, its Secret
	prefix, secret string
	// kubernetes: the chart's OCI address and the release's chart version for helm upgrade
	chart, chartVersion string
}

// publicChart: the chart of the public repository, when the chart does not say where it
// was published
const publicChart = "oci://ghcr.io/porelli/firefox-sync/charts/firefox-sync"

// loadDeployment reads ADMIN_DEPLOYMENT: an unknown one stops the start, rather than
// showing the commands of another stack
func loadDeployment() (deployment, error) {
	d := deployment{kind: env("ADMIN_DEPLOYMENT", "compose")}
	switch d.kind {
	case "compose", "quadlets":
	case "kubernetes":
		d.release, d.namespace = env("ADMIN_K8S_RELEASE", ""), env("ADMIN_K8S_NAMESPACE", "")
		d.prefix, d.secret = env("ADMIN_K8S_FULLNAME", ""), env("ADMIN_K8S_SECRET", "")
		d.chart = env("ADMIN_K8S_CHART", publicChart)
		d.chartVersion = env("ADMIN_K8S_CHART_VERSION", "")
		if d.release == "" || d.prefix == "" || d.secret == "" {
			return d, errors.New("ADMIN_DEPLOYMENT=kubernetes needs ADMIN_K8S_RELEASE, ADMIN_K8S_FULLNAME and ADMIN_K8S_SECRET (the chart sets them)")
		}
	default:
		return d, fmt.Errorf("ADMIN_DEPLOYMENT must be compose, quadlets or kubernetes, not %q", d.kind)
	}
	return d, nil
}

// Quadlets: the Podman Quadlets
func (d deployment) Quadlets() bool { return d.kind == "quadlets" }

// Kubernetes: the deployment with the Helm chart, nil otherwise (for {{with}} in the
// templates)
func (d deployment) Kubernetes() *deployment {
	if d.kind != "kubernetes" {
		return nil
	}
	return &d
}

// fullname: the prefix of the chart's objects, as the chart passes it
func (d deployment) fullname() string { return d.prefix }

// Release: the Helm release
func (d deployment) Release() string { return d.release }

// Kubectl: kubectl in the release's namespace
func (d deployment) Kubectl() string {
	if d.namespace == "" {
		return "kubectl"
	}
	return "kubectl -n " + d.namespace
}

// helmUpgrade: helm upgrade of the release with the values it has, plus those given, in
// the chart version it runs: --reuse-values with another version would apply the old
// release's values to the new chart (docs/upgrading.md#helm), and without --version helm takes
// the newest
func (d deployment) helmUpgrade(set string) string {
	ns := ""
	if d.namespace != "" {
		ns = " -n " + d.namespace
	}
	chart := d.chart
	if chart == "" {
		chart = publicChart
	}
	version := ""
	if d.chartVersion != "" {
		version = " --version " + d.chartVersion
	}
	return strings.TrimSpace("helm upgrade " + d.release + " " + chart + version + ns + " --reuse-values " + set)
}

// the chart's objects
func (d deployment) Secret() string         { return d.secret }
func (d deployment) BackupVolume() string   { return d.fullname() + "-backups" }
func (d deployment) AdminService() string   { return d.fullname() + "-admin" }
func (d deployment) syncDeployment() string { return "deployment/" + d.fullname() + "-syncstorage" }

// BackupNow: a run of the backup CronJob now, under a new Job name each time
func (d deployment) BackupNow() string {
	return d.Kubectl() + " create job --from=cronjob/" + d.fullname() + "-backup backup-now-$(date +%s)"
}

// BackupsOn: the chart's backup CronJob turned on
func (d deployment) BackupsOn() string { return d.helmUpgrade("--set backup.enabled=true") }

// RestartSync: a new pod of the Sync server (its init containers first)
func (d deployment) RestartSync() string {
	return d.Kubectl() + " rollout restart " + d.syncDeployment()
}

// restartSync: how to restart the Sync server, for the missing metrics
func (d deployment) restartSync() string {
	if d.Kubernetes() != nil {
		return "restart it (" + d.RestartSync() + ")"
	}
	return "restart it (docker compose restart syncstorage, or systemctl --user restart firefox-sync-syncstorage.service)"
}

// startInit: how the init container runs again (it sets the Sync node)
func (d deployment) startInit() string {
	if d.Kubernetes() != nil {
		return d.RestartSync()
	}
	return "docker compose up -d (or restart the Quadlets)"
}

// name: what the configuration page says it runs with
func (d deployment) name() string {
	switch d.kind {
	case "quadlets":
		return "Podman Quadlets"
	case "kubernetes":
		name := "Kubernetes, Helm release " + d.release
		if d.namespace != "" {
			name += " in the namespace " + d.namespace
		}
		return name
	}
	return "docker compose"
}

// stackHost: a database of the stack, not your own server: the containers of compose and
// the Quadlets, the bundled databases of the chart
func (d deployment) stackHost(host string) bool {
	if d.Kubernetes() != nil {
		full := d.fullname()
		return host == full+"-tokenserver-db" || host == full+"-storage-db" || host == full+"-postgres" || host == full+"-fxa-db"
	}
	return stackHosts[host]
}

// accountsBackedUp: the backup service dumps the accounts too (their scope), with their
// database at host (FXA_DB_HOST): only on the stack's own server, as compose's backup-fxa,
// the Quadlets' and the chart's backup-accounts (only with fxa.database.bundled); with your own
// accounts server the Sync scope alone, its own backups for the accounts
// (docs/backups.md#your-own-database-server)
func (d deployment) accountsBackedUp(host string) bool { return d.stackHost(host) }

// the self-hosted accounts (fxa.enabled): their auth pod runs compose's fxa-migrations and
// fxa-policy as its init containers (migrations, policy), so a new pod of it applies the
// values again; one backup Job dumps the accounts (their bundled database) before the Sync
// databases
func (d deployment) authDeployment() string { return "deployment/" + d.fullname() + "-fxa-auth" }

// FxaKeys: the PVC of the accounts' signing keys
func (d deployment) FxaKeys() string { return d.fullname() + "-fxa-keys" }

// RestartFxa: a new auth pod, which runs the migrations and the policy again first
func (d deployment) RestartFxa() string {
	return d.Kubectl() + " rollout restart " + d.authDeployment()
}

// FxaLogs: the log of one of the auth pod's containers (migrations, policy, auth)
func (d deployment) FxaLogs(container string) string {
	return d.Kubectl() + " logs deploy/" + d.fullname() + "-fxa-auth -c " + container
}

// HelmSet: helm upgrade of the release with one value set
func (d deployment) HelmSet(value string) string { return d.helmUpgrade("--set " + value) }

// translate: a message written for compose (the policy's errors, in the accounts database)
// with this deployment's command
func (d deployment) translate(msg string) string {
	if d.Kubernetes() == nil {
		return msg
	}
	return strings.ReplaceAll(msg, "see the log of fxa-policy", "see "+d.FxaLogs("policy"))
}

// gateHint: where POST /v1/account/create must go, for the public check of the gate
func (d deployment) gateHint() string {
	if d.Kubernetes() != nil {
		return "Send it to the Service " + d.AdminService() + ", port 8081: the chart's Ingress routes it with fxa.ingress.enabled and admin.enabled, your own needs an Exact path /v1/account/create there (docs/reverse-proxy.md#sign-up-gate)"
	}
	return "Send it to ADMIN_GATE_EXPORT_PORT, see docs/reverse-proxy.md#sign-up-gate"
}

// chartValues: the values of the chart that set the accounts' variables (of .env in compose)
var chartValues = map[string]string{
	"FXA_SIGNUPS": "fxa.signups", "FXA_SIGNUP_ALLOWLIST": "fxa.signupAllowlist", "FXA_MAX_ACCOUNTS": "fxa.maxAccounts",
	"FXA_ACCOUNT_EVENTS": "fxa.accountEvents", "FXA_CLIENT_ADDRESS_DEPTH": "fxa.clientAddressDepth",
	"FXA_ACCESS_TOKEN_LIFETIME": "fxa.accessTokenLifetime", "FXA_CONTENT_URL": "fxa.contentUrl", "FXA_AUTH_URL": "fxa.authUrl",
	"FXA_PROFILE_URL": "fxa.profileUrl", "FXA_PAIRING_URL": "fxa.pairing.url", "FXA_DB": "fxa.database.backend",
	"FXA_MYSQL_HOST": "fxa.database.external.host", "FXA_MYSQL_PORT": "fxa.database.external.port",
	"FXA_SMTP_HOST": "smtp.host", "FXA_SMTP_PORT": "smtp.port", "FXA_SMTP_USER": "smtp.user", "FXA_SMTP_PASS": "smtp.password",
	"FXA_SMTP_SECURE": "smtp.secure", "FXA_SMTP_SENDER": "smtp.sender", "ADMIN_SMTP_INSECURE_AUTH": "smtp.insecureAuth",
	// and invite-only Sync's
	"SYNC_ALLOWED_ACCOUNTS": "allowedAccounts",
}

// valueName: a variable of .env as this deployment sets it: with the chart, the accounts'
// as the values' names (FXA_SIGNUPS: fxa.signups), the others as they are
func (d deployment) valueName(name string) string {
	if v, ok := chartValues[name]; ok && d.Kubernetes() != nil {
		return v
	}
	return name
}

// setting: the name of a setting as this deployment has it, of .env (compose and the
// Quadlets) or of the chart's values
func (d deployment) setting(env, values string) string {
	if d.Kubernetes() != nil {
		return values
	}
	return env
}

// checkOAuth: where FXA_OAUTH_SERVER_URL is set, for the setup check of its keys
func (d deployment) checkOAuth() string {
	if d.Kubernetes() != nil {
		return "Check fxa.oauthServerUrl in your values of the chart, then " + d.helmUpgrade("") + "."
	}
	return "Check FXA_OAUTH_SERVER_URL in .env (http://fxa-auth:9000/v1 with self-hosted accounts)."
}
