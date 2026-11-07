package main

import (
	"database/sql"
	"strings"
	"testing"
	"time"
)

// noStackCommands: the commands of compose and the Quadlets, which a Kubernetes install
// has none of
func noStackCommands(t *testing.T, what, text string) {
	t.Helper()
	for _, bad := range []string{"docker compose", "systemctl", "COMPOSE_PROFILES", "prepare_environment.sh", "Quadlets"} {
		if strings.Contains(text, bad) {
			t.Errorf("%s: %q with ADMIN_DEPLOYMENT=kubernetes: %s", what, bad, text)
		}
	}
}

func TestDeploymentKubernetesCommands(t *testing.T) {
	// the chart's names as it passes them: fullnameOverride=sync, existingSecret=my-secret
	t.Setenv("ADMIN_DEPLOYMENT", "kubernetes")
	t.Setenv("ADMIN_K8S_RELEASE", "t")
	t.Setenv("ADMIN_K8S_NAMESPACE", "ffs")
	t.Setenv("ADMIN_K8S_FULLNAME", "sync")
	t.Setenv("ADMIN_K8S_SECRET", "my-secret")
	d, err := loadDeployment()
	if err != nil {
		t.Fatal(err)
	}

	// the backups card of the overview, and its help
	var b strings.Builder
	data := map[string]any{"CSRF": "x", "Health": []Component{{Name: "Sync server", Up: true}},
		"Backup": map[string]any{"Time": "03:00", "Local": "03:00", "Keep": 7, "Quadlets": d.Quadlets(), "Kubernetes": d.Kubernetes()}}
	if err := templates.ExecuteTemplate(&b, "dashboard.html", data); err != nil {
		t.Fatal(err)
	}
	page := b.String()
	card := page[strings.Index(page, `id="backups-card"`):]
	card = card[:strings.Index(card, "</section>")]
	// (a new Job name for every run; html/template writes + as &#43;)
	if got := d.BackupNow(); got != "kubectl -n ffs create job --from=cronjob/sync-backup backup-now-$(date +%s)" {
		t.Errorf("BackupNow: %s", got)
	}
	for _, want := range []string{"<code>kubectl -n ffs create job --from=cronjob/sync-backup backup-now-$(date &#43;%s)</code>",
		"--set backup.enabled=true", "<code>sync-backups</code>", "the Secret <code>my-secret</code>"} {
		if !strings.Contains(card, want) {
			t.Errorf("backups card: no %q", want)
		}
	}
	noStackCommands(t, "backups card", card)

	// the setup checks and the alerts of the overview
	if c := nodeCheck(d, "https://sync.example.com", nil); !strings.Contains(c.Text, "kubectl -n ffs rollout restart deployment/sync-syncstorage") {
		t.Errorf("node check: %s", c.Text)
	} else {
		noStackCommands(t, "node check", c.Text)
	}
	c := ownDBCheck(&SyncDB{db: sql.OpenDB(&fakeFxa{})}, moveState{}, d)
	if !strings.Contains(c.Text, "ADMIN_DB_PASSWORD") || !strings.Contains(c.Text, "helm upgrade t ") {
		t.Errorf("own database check: %s", c.Text)
	}
	noStackCommands(t, "own database check", c.Text)
	noStackCommands(t, "the log line", ownDBHint(d))
	if c := ownDBCheck(&SyncDB{own: sql.OpenDB(&fakeFxa{}), ownName: "ffs_admin", postgres: true}, moveState{Superuser: "syncserver"}, d); !strings.Contains(c.Text, "docs/reference/database-users.md#postgresql") {
		t.Errorf("superuser check: %s", c.Text)
	} else {
		noStackCommands(t, "superuser check", c.Text)
	}
	if got := d.restartSync(); !strings.Contains(got, "kubectl -n ffs rollout restart deployment/sync-syncstorage") {
		t.Errorf("restart: %s", got)
	}
	h := &Health{app: &App{deployment: d}}
	noStackCommands(t, "the metrics alert", h.deployment().restartSync())

	// the activity page, the sign-in page
	for name, data := range map[string]map[string]any{
		"activity.html": {"CSRF": "x", "Range": "24h", "Ranges": []string{"24h"}, "Kinds": eventKinds, "Received": time.Time{}, "Kubernetes": d.Kubernetes()},
		"login.html":    {"Password": true, "Kubernetes": d.Kubernetes()},
	} {
		var b strings.Builder
		if err := templates.ExecuteTemplate(&b, name, data); err != nil {
			t.Fatal(err)
		}
		noStackCommands(t, name, b.String())
		if name == "login.html" && !strings.Contains(b.String(), "kubectl -n ffs get secret my-secret") {
			t.Errorf("login: where the password is: %s", b.String())
		}
		if name == "activity.html" && !strings.Contains(b.String(), "rollout restart deployment/sync-syncstorage") {
			t.Errorf("activity: how to restart the Sync server")
		}
	}

	// the configuration page, with the chart's bundled MariaDB
	t.Setenv("TOKENSERVER_DB_HOST", "sync-tokenserver-db")
	page = configPage(t, false, func(app *App, _ *fakeFxa) { app.deployment = d })
	if got := configRowOf(page, "Runs with"); !strings.Contains(got, "Kubernetes") || !strings.Contains(got, "Helm release t") {
		t.Errorf("runs with: %q", got)
	}
	if got := configRowOf(page, "Published on"); !strings.Contains(got, "sync-admin") {
		t.Errorf("published on: %q", got)
	}
	if got := configRowOf(page, "Last runs"); !strings.Contains(got, "backup.enabled") {
		t.Errorf("backups: %q", got)
	}
	if got := configRowOf(page, "Databases"); !strings.Contains(got, "a container of the stack") {
		t.Errorf("the bundled databases: %q", got)
	}
	noStackCommands(t, "configuration page", page)
}

func TestDeploymentFromEnv(t *testing.T) {
	for _, c := range []struct {
		kind, release, fullname, secret string
		ok, quadlets, kubernetes        bool
	}{
		{kind: "", ok: true}, {kind: "compose", ok: true}, {kind: "quadlets", ok: true, quadlets: true},
		{kind: "kubernetes", release: "t", fullname: "t-firefox-sync", secret: "t-firefox-sync", ok: true, kubernetes: true},
		// the names come from the chart, never derived from the release
		{kind: "kubernetes", release: "t", fullname: "x", secret: "mine", ok: true, kubernetes: true},
		{kind: "kubernetes"}, {kind: "kubernetes", release: "t"}, {kind: "kubernetes", release: "t", fullname: "x"},
		{kind: "Compose"}, {kind: "k8s", release: "t", fullname: "x", secret: "y"},
	} {
		t.Setenv("ADMIN_DEPLOYMENT", c.kind)
		t.Setenv("ADMIN_K8S_RELEASE", c.release)
		t.Setenv("ADMIN_K8S_NAMESPACE", "")
		t.Setenv("ADMIN_K8S_FULLNAME", c.fullname)
		t.Setenv("ADMIN_K8S_SECRET", c.secret)
		d, err := loadDeployment()
		if (err == nil) != c.ok {
			t.Errorf("%+v: %v", c, err)
			continue
		}
		if err != nil {
			continue
		}
		if d.Quadlets() != c.quadlets || d.Kubernetes() != nil != c.kubernetes {
			t.Errorf("%+v: %+v", c, d)
		}
		if c.kubernetes && (d.fullname() != c.fullname || d.Secret() != c.secret) {
			t.Errorf("%+v: fullname %q, secret %q", c, d.fullname(), d.Secret())
		}
	}
	// without a namespace: kubectl's own
	t.Setenv("ADMIN_DEPLOYMENT", "kubernetes")
	t.Setenv("ADMIN_K8S_RELEASE", "t")
	t.Setenv("ADMIN_K8S_FULLNAME", "t-firefox-sync")
	t.Setenv("ADMIN_K8S_SECRET", "t-firefox-sync")
	if d, _ := loadDeployment(); d.restartSync() != "restart it (kubectl rollout restart deployment/t-firefox-sync-syncstorage)" {
		t.Errorf("no namespace: %q", d.restartSync())
	}
	// the bundled databases by the chart's prefix, not your own server of a similar name
	d := deployment{kind: "kubernetes", release: "t", prefix: "sync", secret: "s"}
	if !d.stackHost("sync-tokenserver-db") || !d.stackHost("sync-postgres") || d.stackHost("t-firefox-sync-tokenserver-db") || d.stackHost("tokenserver_db") {
		t.Error("stack hosts of the chart")
	}
}

// no .env with the Helm chart: the values of the chart instead
func TestDeploymentKubernetesNoDotEnv(t *testing.T) {
	d := deployment{kind: "kubernetes", release: "t", namespace: "ffs", prefix: "t-firefox-sync", secret: "t-firefox-sync"}
	for _, editable := range []bool{true, false} {
		var b strings.Builder
		data := map[string]any{"CSRF": "x", "Health": []Component{{Name: "Sync server", Up: true}}, "MaxUsersEditable": editable,
			"Sync":       &SyncStatus{Users: 1, MaxUsers: 5, Nodes: []SyncNode{{Node: "https://sync.example.com", Users: 1}}},
			"Backup":     map[string]any{"Time": "03:00", "Local": "03:00", "Keep": 7, "Quadlets": false, "Kubernetes": d.Kubernetes()},
			"Kubernetes": d.Kubernetes()}
		if err := templates.ExecuteTemplate(&b, "dashboard.html", data); err != nil {
			t.Fatal(err)
		}
		page := b.String()
		if strings.Contains(page, ".env") {
			i := strings.Index(page, ".env")
			t.Errorf("dashboard (max users editable %v): .env: %s", editable, page[max(0, i-200):i+10])
		}
		for _, want := range []string{"<code>admin.alertEmail</code>", "<code>maxUsers"} {
			if !strings.Contains(page, want) {
				t.Errorf("dashboard (max users editable %v): no %q", editable, want)
			}
		}
	}
	if got := d.checkOAuth(); strings.Contains(got, ".env") || !strings.Contains(got, "fxa.oauthServerUrl") {
		t.Errorf("sign-in keys check: %s", got)
	}
	app := &App{deployment: d}
	if err := app.maxUsersReadOnly(); strings.Contains(err.Error(), ".env") || !strings.Contains(err.Error(), "maxUsers") {
		t.Errorf("max users read-only: %v", err)
	}
	// compose's as before
	if err := (&App{}).maxUsersReadOnly(); !strings.Contains(err.Error(), "MAX_USERS in .env") {
		t.Errorf("compose: %v", err)
	}
}

// the chart's address in the helm commands: the one the chart passes (ADMIN_K8S_CHART, where
// it was published), else the public repository's, never another repository's; in the
// release's chart version (ADMIN_K8S_CHART_VERSION): --reuse-values never moves to another one
func TestDeploymentChartAddress(t *testing.T) {
	t.Setenv("ADMIN_DEPLOYMENT", "kubernetes")
	t.Setenv("ADMIN_K8S_RELEASE", "t")
	t.Setenv("ADMIN_K8S_NAMESPACE", "ffs")
	t.Setenv("ADMIN_K8S_FULLNAME", "t-firefox-sync")
	t.Setenv("ADMIN_K8S_SECRET", "t-firefox-sync")
	for _, c := range []struct{ env, version, want string }{
		{"", "", "helm upgrade t oci://ghcr.io/porelli/firefox-sync/charts/firefox-sync -n ffs --reuse-values --set backup.enabled=true"},
		{"", "0.1.0", "helm upgrade t oci://ghcr.io/porelli/firefox-sync/charts/firefox-sync --version 0.1.0 -n ffs --reuse-values --set backup.enabled=true"},
		{"oci://ghcr.io/example/firefox-sync-fork/charts/firefox-sync", "0.1.0-dev.1",
			"helm upgrade t oci://ghcr.io/example/firefox-sync-fork/charts/firefox-sync --version 0.1.0-dev.1 -n ffs --reuse-values --set backup.enabled=true"},
	} {
		t.Setenv("ADMIN_K8S_CHART", c.env)
		t.Setenv("ADMIN_K8S_CHART_VERSION", c.version)
		d, err := loadDeployment()
		if err != nil {
			t.Fatal(err)
		}
		if got := d.BackupsOn(); got != c.want {
			t.Errorf("ADMIN_K8S_CHART=%q ADMIN_K8S_CHART_VERSION=%q: %s", c.env, c.version, got)
		}
	}
}

// the old names of .env: no setup check with the Helm chart (no .env there), also if
// FFS_OLD_ENV_NAMES came from somewhere
func TestDeploymentKubernetesNoOldNamesCheck(t *testing.T) {
	t.Setenv("FFS_OLD_ENV_NAMES", "MAX_USERS SYNCSTORAGE_DOMAIN")
	k8s := &App{deployment: deployment{kind: "kubernetes", release: "t", prefix: "t-firefox-sync", secret: "t-firefox-sync"}}
	for _, c := range k8s.setupChecks(t.Context(), nil, nil) {
		if strings.Contains(c.Name, "Old setting names") {
			t.Errorf("kubernetes: %+v", c)
		}
	}
	found := false
	for _, c := range (&App{}).setupChecks(t.Context(), nil, nil) {
		found = found || strings.Contains(c.Name, "Old setting names")
	}
	if !found {
		t.Error("compose: no check of the old names")
	}
	// the node check names the chart's value
	if c := nodeCheck(k8s.deployment, "https://sync.example.com", nil); !strings.Contains(c.Text, "syncDomain is https://sync.example.com") || strings.Contains(c.Text, "SYNC_PUBLIC_URL") {
		t.Errorf("node check, kubernetes: %s", c.Text)
	}
}

// the chart with the self-hosted accounts (fxa.enabled): their commands are kubectl's on the
// chart's objects (the auth pod runs the migrations and the policy as init containers, one
// backup Job dumps both scopes), their settings the values' names, no compose or Quadlets
func TestDeploymentKubernetesFxA(t *testing.T) {
	d := deployment{kind: "kubernetes", release: "t", prefix: "t-firefox-sync", secret: "t-firefox-sync"}
	bad := []string{"docker compose", "fxa-policy", "backup-fxa", "fxa-migrations", "systemctl", "Quadlets", ".env"}
	noneOf := func(what, page string) {
		t.Helper()
		for _, b := range bad {
			if i := strings.Index(page, b); i >= 0 {
				t.Errorf("%s with ADMIN_DEPLOYMENT=kubernetes and the accounts: %q in %s", what, b, page[max(0, i-200):min(len(page), i+100)])
			}
		}
	}
	const restart, keys = "kubectl rollout restart deployment/t-firefox-sync-fxa-auth", "<code>t-firefox-sync-fxa-keys</code>"

	// the overview: sign-ups, max accounts (managed here or by the values), the backups card
	for _, editable := range []bool{true, false} {
		var b strings.Builder
		data := map[string]any{"CSRF": "x", "FxA": true, "Health": []Component{{Name: "Sync server", Up: true}},
			"Policy": &SignupPolicy{Mode: "allowlist"}, "AccountLimit": Limit{Count: 1, Max: 10}, "MaxAccountsEditable": editable,
			"Backup":     map[string]any{"Time": "03:00", "Local": "03:00", "Keep": 7, "Quadlets": false, "Kubernetes": d.Kubernetes(), "Accounts": true},
			"Kubernetes": d.Kubernetes()}
		if err := templates.ExecuteTemplate(&b, "dashboard.html", data); err != nil {
			t.Fatal(err)
		}
		page := b.String()
		noneOf("dashboard", page)
		for _, want := range []string{restart, keys, "<code>fxa.keys.existingSecret</code>", "<code>fxa.signups</code>", "<code>fxa.signupAllowlist</code>",
			"<code>fxa.maxAccounts", "kubectl logs deploy/t-firefox-sync-fxa-auth -c policy", "both scopes"} {
			if !strings.Contains(page, want) {
				t.Errorf("dashboard (max accounts editable %v): no %q", editable, want)
			}
		}
		card := page[strings.Index(page, `id="backups-card"`):]
		card = card[:strings.Index(card, "</section>")]
		if !strings.Contains(card, keys) || !strings.Contains(card, "create job --from=cronjob/t-firefox-sync-backup") {
			t.Errorf("backups card: %s", card)
		}
	}

	// the account page without the security history: how to turn it on
	var b strings.Builder
	acc := &FxaAccount{UID: fakeUID, Email: fakeEmail, CreatedAt: time.Now()}
	if err := templates.ExecuteTemplate(&b, "user.html", map[string]any{"CSRF": "x", "FxA": true, "UID": fakeUID, "Account": acc,
		"Security": &Security{}, "AccountEvents": false, "Quadlets": false, "Kubernetes": d.Kubernetes()}); err != nil {
		t.Fatal(err)
	}
	user := b.String()
	noneOf("user page", user)
	for _, want := range []string{"<code>fxa.accountEvents: true</code>", "helm upgrade t ", "--set fxa.accountEvents=true"} {
		if !strings.Contains(user, want) {
			t.Errorf("user page: no %q", want)
		}
	}

	// the configuration page, with the chart's bundled accounts database
	t.Setenv("FXA_DB_HOST", "t-firefox-sync-fxa-db")
	t.Setenv("FXA_AUTH_UPSTREAM", "http://t-firefox-sync-fxa-auth:9000")
	t.Setenv("FXA_REDIS", "t-firefox-sync-fxa-redis:6379")
	t.Setenv("FXA_SIGNUPS", "allowlist")
	t.Setenv("FXA_MAX_ACCOUNTS", "initial:unlimited")
	t.Setenv("ADMIN_GATE_EXPORT_PORT", "t-firefox-sync-admin:8081")
	t.Setenv("FXA_CONTENT_URL", "https://accounts.example.com")
	t.Setenv("ADMIN_OIDC_ISSUER", "https://accounts.example.com")
	page := configPage(t, true, func(app *App, _ *fakeFxa) { app.deployment = d })
	noneOf("configuration page", page)
	for _, want := range []string{restart, "PersistentVolumeClaim t-firefox-sync-fxa-keys", "<code>fxa.signups</code>", "<code>fxa.maxAccounts</code>", "<code>fxa.contentUrl</code>"} {
		if !strings.Contains(page, want) {
			t.Errorf("configuration page: no %q", want)
		}
	}
	for _, name := range []string{"FXA_SIGNUPS", "FXA_MAX_ACCOUNTS", "FXA_CONTENT_URL"} {
		if strings.Contains(page, "<code>"+name+"</code>") {
			t.Errorf("configuration page: %s, not the values' name", name)
		}
	}
	if got := configRowOf(page, "Database"); !strings.Contains(got, "a container of the stack") {
		t.Errorf("the bundled accounts database: %q", got)
	}
	if got := configRowOf(page, "Sign-up gate published on"); !strings.Contains(got, "t-firefox-sync-admin") || !strings.Contains(got, "8081") {
		t.Errorf("the gate: %q", got)
	}
	if got := configRowOf(page, "OpenID Connect issuer"); !strings.Contains(got, "admin.fxaSignIn") {
		t.Errorf("sign-in with the accounts: %q", got)
	}
	if !d.stackHost("t-firefox-sync-fxa-db") || d.stackHost("fxa-db") {
		t.Error("the chart's bundled accounts database")
	}

	// the public check of the gate, the read-only max accounts, an error naming fxa-policy
	if got := d.gateHint(); !strings.Contains(got, "fxa.ingress.enabled") || !strings.Contains(got, "admin.enabled") || strings.Contains(got, "ADMIN_GATE_EXPORT_PORT") {
		t.Errorf("gate hint: %s", got)
	}
	if got := (&App{deployment: d}).maxAccountsReadOnly().Error(); strings.Contains(got, ".env") || !strings.Contains(got, "fxa.maxAccounts") {
		t.Errorf("max accounts read-only: %s", got)
	}
	if got := d.translate("deleteAccount_24 is missing from the accounts database: see the log of fxa-policy"); got !=
		"deleteAccount_24 is missing from the accounts database: see kubectl logs deploy/t-firefox-sync-fxa-auth -c policy" {
		t.Errorf("fxa-policy's log: %s", got)
	}
	// compose's as before
	compose := deployment{kind: "compose"}
	if !strings.Contains(compose.gateHint(), "ADMIN_GATE_EXPORT_PORT") || compose.translate("see the log of fxa-policy") != "see the log of fxa-policy" ||
		!strings.Contains((&App{}).maxAccountsReadOnly().Error(), "FXA_MAX_ACCOUNTS in .env") {
		t.Error("compose's texts changed")
	}
}

// the setup check of the accounts' SMTP server names the chart's value
func TestDeploymentKubernetesFxASMTP(t *testing.T) {
	t.Setenv("SMTP_HOST", "")
	app := &App{fxa: (&fakeFxa{}).db(""), deployment: deployment{kind: "kubernetes", release: "t", prefix: "t-firefox-sync", secret: "t-firefox-sync"}}
	for _, c := range app.setupChecks(t.Context(), nil, nil) {
		if strings.HasPrefix(c.Name, "Email of the accounts") {
			if c.Name != "Email of the accounts (smtp.host)" || !strings.Contains(c.Text, "smtp.host is not set in your values") || strings.Contains(c.Text, ".env") {
				t.Errorf("kubernetes: %+v", c)
			}
			return
		}
	}
	t.Error("no check of the accounts' SMTP server")
}

// the Backups card with the accounts on your own server (fxa.database.bundled false, compose's
// FXA_DB_CONTAINERS=0): the backups dump the Sync scope alone, the card says so, not "both
// scopes", no accounts/ in the volume, no backup-fxa; on the stack's own server both
func TestBackupsCardAccountsScope(t *testing.T) {
	k8s := deployment{kind: "kubernetes", release: "t", prefix: "t-firefox-sync", secret: "t-firefox-sync"}
	for _, c := range []struct {
		d    deployment
		host string
		want bool
	}{
		{k8s, "t-firefox-sync-fxa-db", true}, {k8s, "fxadb.example.com", false},
		{deployment{kind: "compose"}, "fxa-db", true}, {deployment{kind: "compose"}, "fxadb.example.com", false},
		{deployment{kind: "quadlets"}, "firefox-sync-fxa-db", true}, {deployment{kind: "quadlets"}, "10.0.0.5", false},
	} {
		if got := c.d.accountsBackedUp(c.host); got != c.want {
			t.Errorf("%s, the accounts on %s: accountsBackedUp %v", c.d.kind, c.host, got)
		}
	}
	// the card's data as the overview builds it: FXA_DB_HOST read there, the accounts on
	for _, c := range []struct {
		d    deployment
		fxa  bool
		host string
		want bool
	}{
		{k8s, true, "t-firefox-sync-fxa-db", true}, {k8s, true, "fxadb.example.com", false}, {k8s, false, "t-firefox-sync-fxa-db", false},
		{deployment{kind: "compose"}, true, "", true}, {deployment{kind: "compose"}, true, "fxadb.example.com", false},
	} {
		t.Setenv("FXA_DB_HOST", c.host)
		a := &App{deployment: c.d, backupTime: "03:00", backupKeep: 7}
		if c.fxa {
			a.fxa = &FxaDB{}
		}
		if got := a.backupHelp(time.Now())["Accounts"]; got != c.want {
			t.Errorf("%s, accounts %v on %q: backupHelp Accounts %v", c.d.kind, c.fxa, c.host, got)
		}
	}
	card := func(d deployment, accounts bool) string {
		t.Helper()
		var b strings.Builder
		data := map[string]any{"CSRF": "x", "FxA": true, "Health": []Component{{Name: "Sync server", Up: true}},
			"Backup":     map[string]any{"Time": "03:00", "Local": "03:00", "Keep": 7, "Quadlets": d.Quadlets(), "Kubernetes": d.Kubernetes(), "Accounts": accounts},
			"Kubernetes": d.Kubernetes()}
		if err := templates.ExecuteTemplate(&b, "dashboard.html", data); err != nil {
			t.Fatal(err)
		}
		page := b.String()
		page = page[strings.Index(page, `id="backups-card"`):]
		return page[:strings.Index(page, "</section>")]
	}
	for _, d := range []deployment{k8s, {kind: "compose"}, {kind: "quadlets"}} {
		own, bundled := card(d, false), card(d, true)
		for _, bad := range []string{"both scopes", "accounts/&lt;UTC time&gt;", "backup-fxa", "the accounts first", "and the accounts databases into"} {
			if strings.Contains(own, bad) {
				t.Errorf("%s, the accounts on your own server: the backups card says %q", d.kind, bad)
			}
		}
		if !strings.Contains(own, "on your own server") {
			t.Errorf("%s, the accounts on your own server: the backups card does not say they are not dumped: %s", d.kind, own)
		}
		for _, want := range []string{"accounts/&lt;UTC time&gt;", "and the accounts databases into"} {
			if !strings.Contains(bundled, want) {
				t.Errorf("%s, the accounts on the stack's server: no %q in the backups card", d.kind, want)
			}
		}
		if strings.Contains(bundled, "on your own server: back them") {
			t.Errorf("%s, the accounts on the stack's server: the card says they are on your own", d.kind)
		}
	}
	if !strings.Contains(card(k8s, true), "both scopes run in one Job, the accounts first") || !strings.Contains(card(k8s, false), "the Sync scope alone") {
		t.Errorf("kubernetes: One now: %s", card(k8s, false))
	}
}
