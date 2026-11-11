package main

import (
	"crypto/rand"
	"database/sql"
	"database/sql/driver"
	"encoding/hex"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

// the environment of ffs-admin in the compose files, the Quadlets and the Helm chart of the repository:
// its variables, each with the variables of .env its value takes (${X}, %X%). Empty
// when the tests run without the repository (the image's build has admin/ only)
func adminEnvironments(t *testing.T) (map[string][]string, []string) {
	t.Helper()
	vars := map[string][]string{}
	var files []string
	ref := regexp.MustCompile(`\$\{([A-Z][A-Z0-9_]*)|%([A-Z][A-Z0-9_]*)%`)
	add := func(name, value string) {
		if _, ok := vars[name]; !ok {
			vars[name] = nil
		}
		for _, m := range ref.FindAllStringSubmatch(value, -1) {
			vars[name] = append(vars[name], m[1]+m[2])
		}
	}
	composes, _ := filepath.Glob("../compose/*.yml")
	tests, _ := filepath.Glob("../tests/compose/*.yml")
	key := regexp.MustCompile(`^      ([A-Z][A-Z0-9_]*):(.*)$`)
	for _, f := range append(composes, tests...) {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		files = append(files, f)
		service, environment := false, false
		for _, line := range strings.Split(string(b), "\n") {
			switch {
			case strings.HasPrefix(line, "  ") && !strings.HasPrefix(line, "   ") && strings.HasSuffix(line, ":"):
				service, environment = line == "  ffs-admin:", false
			case !service || strings.TrimSpace(line) == "" || strings.HasPrefix(strings.TrimSpace(line), "#"):
			case line == "    environment:":
				environment = true
			case !strings.HasPrefix(line, "      "):
				environment = false
			case environment:
				if m := key.FindStringSubmatch(line); m != nil {
					add(m[1], m[2])
				}
			}
		}
	}
	quadlets, _ := filepath.Glob("../config/quadlet/*/firefox-sync-admin.container")
	more, _ := filepath.Glob("../config/quadlet/*/*/firefox-sync-admin.container")
	env := regexp.MustCompile(`^Environment="?([A-Z][A-Z0-9_]*)=(.*)$`)
	for _, f := range append(quadlets, more...) {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		files = append(files, f)
		for _, line := range strings.Split(string(b), "\n") {
			if m := env.FindStringSubmatch(line); m != nil {
				add(m[1], m[2])
			}
		}
	}
	// and the Helm chart's admin container
	if b, err := os.ReadFile("../charts/firefox-sync/templates/admin.yaml"); err == nil {
		files = append(files, "../charts/firefox-sync/templates/admin.yaml")
		// the variables of its container, a secretKeyRef as the .env name of its key
		name := regexp.MustCompile(`^ {12}- name: ([A-Z][A-Z0-9_]*)$`)
		key := regexp.MustCompile(`^ +key: ([A-Z][A-Z0-9_]*)$`)
		include := regexp.MustCompile(`"name" "([A-Z][A-Z0-9_]*)" "key" "([A-Z][A-Z0-9_]*)"`)
		last := ""
		for _, line := range strings.Split(string(b), "\n") {
			if m := include.FindStringSubmatch(line); m != nil {
				add(m[1], "${"+m[2]+"}")
			} else if m := name.FindStringSubmatch(line); m != nil {
				last = m[1]
				add(last, "")
			} else if m := key.FindStringSubmatch(line); m != nil && last != "" {
				add(last, "${"+m[1]+"}")
			}
		}
	}
	return vars, files
}

// secretName: a name that says it is a secret (TOKENSERVER_DB_HOST is not: TOKENSERVER;
// the lifetime of the access tokens is a duration, ADMIN_K8S_SECRET the name of the chart's Secret)
func secretName(name string) bool {
	if name == "FXA_ACCESS_TOKEN_LIFETIME" || name == "ADMIN_K8S_SECRET" {
		return false
	}
	for _, part := range strings.Split(name, "_") {
		switch part {
		case "PASS", "PASSWORD", "SECRET", "TOKEN", "KEY":
			return true
		}
	}
	return false
}

// the secrets of .env the admin UI needs, and nothing else: no SYNC_MASTER_SECRET, no
// keys of the accounts service
var adminSecrets = map[string]bool{"ADMIN_PASSWORD": true, "ADMIN_OIDC_CLIENT_SECRET": true, "ADMIN_FXA_CLIENT_SECRET": true, "ADMIN_METRICS_TOKEN": true,
	"FXA_SMTP_PASS": true, "ADMIN_DB_PASSWORD": true, "FXA_ADMIN_DB_PASSWORD": true,
	// the Helm chart's Redis of the accounts has one (compose's is on a network of its own)
	"FXA_REDIS_PASSWORD":           true,
	"SYNC_TOKENSERVER_DB_PASSWORD": true, "SYNC_STORAGE_DB_PASSWORD": true, "SYNC_POSTGRES_PASSWORD": true, "SYNC_POSTGRES_APP_PASSWORD": true,
	// their old names, still read when the new ones are not set (docs/upgrading.md#renamed-settings)
	"MARIADB_TOKENSERVER_PASSWORD": true, "MARIADB_SYNCSTORAGE_PASSWORD": true, "POSTGRES_PASSWORD": true, "POSTGRES_SYNC_PASSWORD": true}

func TestConfigVarsClassified(t *testing.T) {
	// what the code reads
	read := regexp.MustCompile(`\b(?:env|envInt|os\.Getenv|os\.LookupEnv)\("([A-Z][A-Z0-9_]*)"`)
	names := regexp.MustCompile(`range \[\]string\{([^}]*)\}`)
	name := regexp.MustCompile(`"([A-Z][A-Z0-9]*_[A-Z0-9_]+)"`)
	sources, _ := filepath.Glob("*.go")
	used := map[string]string{}
	for _, f := range sources {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		for _, m := range read.FindAllStringSubmatch(string(b), -1) {
			used[m[1]] = f
		}
		// and those read in a loop over their names (range []string{"HEALTH_CHECK_SECONDS", ...})
		for _, list := range names.FindAllStringSubmatch(string(b), -1) {
			for _, m := range name.FindAllStringSubmatch(list[1], -1) {
				used[m[1]] = f
			}
		}
	}
	if len(used) < 50 {
		t.Fatalf("only %d variables found in the code", len(used))
	}
	// what compose, the Quadlets and the chart give it
	given, files := adminEnvironments(t)
	if len(files) == 0 {
		t.Log("not in the repository: the compose files and the Quadlets are not checked")
	} else if len(given) < 50 || len(files) < 8 {
		t.Fatalf("only %d variables in %v", len(given), files)
	}
	for name := range given {
		used[name] = "compose, the Quadlets or the chart"
	}
	for name, where := range used {
		secret, known := configVars[name]
		if !known {
			t.Errorf("%s (%s) is not in configVars: say whether the configuration page may show it", name, where)
		}
		if secretName(name) && !secret {
			t.Errorf("%s looks like a secret: classified as shown", name)
		}
	}
	for name, refs := range given {
		for _, ref := range refs {
			if secretName(ref) && !configVars[name] {
				t.Errorf("%s takes the secret %s of .env, and is shown", name, ref)
			}
			if secretName(ref) && !adminSecrets[ref] {
				t.Errorf("%s passes %s to the admin UI, which does not need it", name, ref)
			}
		}
	}
	// a secret of the table nobody gives or reads: a renamed variable, the old name left behind
	for name := range configVars {
		if _, ok := used[name]; !ok && len(files) > 0 {
			t.Errorf("%s is in configVars, but nothing reads or passes it", name)
		}
	}
}

func randomHex(t *testing.T) string {
	b := make([]byte, 12)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return hex.EncodeToString(b)
}

// configPage: an app on the fakes, with the accounts or not, and the page it shows
func configPage(t *testing.T, fxa bool, setup func(*App, *fakeFxa)) string {
	t.Helper()
	app := testApp()
	fake := &fakeFxa{maxUsers: "5", syncUsers: 1, nodes: [][]driver.Value{{int64(1), "https://sync.example.com", int64(0), int64(0), int64(0), int64(0), int64(0)}}}
	// the event log in the admin UI's own database (owndb.go), as with ADMIN_DB_PASSWORD
	app.sync = &SyncDB{db: sql.OpenDB(fake), own: sql.OpenDB(fake), ownName: "ffs_admin"}
	// the thresholds as newHealth reads them, ADMIN_DB_GROWTH_FACTOR=0
	app.health = &Health{started: time.Now(), errorRate: errorRateConfig{percent: 10, minErrors: 20}, growth: growthConfig{mb: 1024}}
	app.syncDomain, app.staleDays, app.unconfirmedHours, app.signupBurst, app.backupTime, app.backupKeep = "https://sync.example.com", 90, 72, 10, "03:00", 7
	if fxa {
		fake.mode, fake.maxAccounts, fake.accountCount = "open", "unlimited", 3
		app.fxa, app.contentURL, app.emailDomain = fake.db(""), "https://accounts.example.com", "api.example.com"
	}
	if setup != nil {
		setup(app, fake)
	}
	h := app.routes()
	c, _ := passwordSession(t, app, h)
	w := getPage(h, "/config", c)
	if w.Code != 200 {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
	return w.Body.String()
}

func TestConfigPageShowsNoSecret(t *testing.T) {
	given, _ := adminEnvironments(t)
	names := map[string]bool{}
	for name := range configVars {
		names[name] = true
	}
	for name := range given {
		names[name] = true
	}
	for _, fxa := range []bool{false, true} {
		// a value of its own in every variable: none of the secrets may appear
		values := map[string]string{}
		for name := range names {
			values[name] = "Zq" + randomHex(t)
			t.Setenv(name, values[name])
		}
		// some that switch parts of the page on, and a URL with a password
		redisPassword := "Zq" + randomHex(t)
		t.Setenv("FXA_REDIS", "redis://:"+redisPassword+"@fxa-redis:6379")
		t.Setenv("SMTP_INSECURE_AUTH", "1")
		page := configPage(t, fxa, func(app *App, _ *fakeFxa) {
			app.mailer = newMailer("")
			app.alerter = &Alerter{Mailer: *app.mailer, to: values["ALERT_EMAIL"], interval: 10 * time.Minute}
		})
		// (what the table says, and what the name says: a secret classified as shown fails too)
		for name := range names {
			if !configVars[name] && !secretName(name) {
				continue
			}
			if strings.Contains(page, values[name]) {
				t.Errorf("fxa %v: the value of %s is on the page", fxa, name)
			} else if strings.Contains(page, values[name][:8]) {
				t.Errorf("fxa %v: the start of %s is on the page", fxa, name)
			}
		}
		for name, v := range values {
			if !configVars[name] && name != "FXA_REDIS" && strings.Contains(page, v) {
				delete(values, name)
			}
		}
		if strings.Contains(page, redisPassword) {
			t.Errorf("fxa %v: the password of FXA_REDIS", fxa)
		}
		// it shows something: the values of these (the others are checked below)
		for _, name := range []string{"SYNCSTORAGE_DOMAIN", "TOKENSERVER_DB_HOST", "ADMIN_OIDC_ISSUER", "SMTP_HOST", "ALERT_EMAIL"} {
			if _, left := values[name]; left {
				t.Errorf("fxa %v: %s not shown", fxa, name)
			}
		}
		if fxa {
			if _, left := values["FXA_CONTENT_URL"]; left {
				t.Error("FXA_CONTENT_URL not shown")
			}
		}
		if !strings.Contains(page, `<td>Password</td>
      <td><span class="ok">set</span></td>`) {
			t.Errorf("fxa %v: ADMIN_PASSWORD not said to be set", fxa)
		}
	}
}

// row: the cells of the row of a setting on the page, tags removed
func configRowOf(page, setting string) string {
	m := regexp.MustCompile(`(?s)<tr><td>` + regexp.QuoteMeta(setting) + `</td>(.*?)</tr>`).FindStringSubmatch(page)
	if m == nil {
		return ""
	}
	return strings.Join(strings.Fields(regexp.MustCompile(`<[^>]+>`).ReplaceAllString(m[1], " ")), " ")
}

func TestConfigPage(t *testing.T) {
	t.Setenv("SYNCSTORAGE_DOMAIN", "https://sync.example.com")
	t.Setenv("MAX_USERS", "initial:3")
	t.Setenv("TOKENSERVER_DB_HOST", "tokenserver_db")
	t.Setenv("TOKENSERVER_DB_USER", "tokenserver")
	t.Setenv("TOKENSERVER_DB_NAME", "tokenserver")
	t.Setenv("TOKENSERVER_DB_PASSWORD", "hunter2hunter2")
	t.Setenv("SYNC_DB", "mysql")
	t.Setenv("FXA_OAUTH_SERVER_URL", "https://oauth.accounts.firefox.com/v1")
	t.Setenv("ADMIN_DB_PASSWORD", "hunter2hunter3")
	page := configPage(t, false, func(app *App, _ *fakeFxa) {
		app.health.backups = []BackupStatus{{Scope: "sync", Last: BackupRun{OK: true, Finished: time.Now()}, LastOK: BackupRun{OK: true, Finished: time.Now()}}}
	})
	for setting, want := range map[string]string{
		"Max users":                  "5 (1 used) SYNC_MAX_USERS SYNC_MAX_USERS=initial:3: set to 3 on a new database only, then on the overview",
		"Databases":                  "MySQL SYNC_DB the tokenserver and the storage databases, on a container of the stack",
		"Tokenserver database":       "ffs_admin_sync on tokenserver_db:3306, database tokenserver",
		"Tokenserver password":       "set ADMIN_DB_PASSWORD of ffs_admin_sync",
		"Admin UI database":          "ffs_admin_ui on tokenserver_db:3306, database ffs_admin ADMIN_DB_USER , ADMIN_DB_NAME the event log",
		"Admin UI database password": "set ADMIN_DB_PASSWORD of ffs_admin_ui and ffs_admin_sync",
		"Spike of Sync errors":       "10% of the requests in 15 minutes, 20 errors at least (default)",
		"A database growing fast":    "over 1024 MB a day (default) ADMIN_DB_GROWTH_MB , ADMIN_DB_GROWTH_FACTOR",
		"Sync node handed out":       "https://sync.example.com SYNC_PUBLIC_URL",
		"Inactive after":             "90 days (default) ADMIN_STALE_DAYS",
		"Password":                   "not set ADMIN_PASSWORD password sign-in off",
		"Trusted header":             "off (default) ADMIN_AUTH_HEADER",
		"Prometheus":                 "not set ADMIN_METRICS_TOKEN /metrics off",
		"Time zone":                  "UTC (default) ADMIN_TZ , TZ",
	} {
		if got := configRowOf(page, setting); !strings.HasPrefix(got, want) {
			t.Errorf("%s: %q, want %q", setting, got, want)
		}
	}
	// Mozilla's accounts: no rows of the accounts, nothing to check
	if !strings.Contains(page, "accounts: Firefox signs in at accounts.firefox.com") || strings.Contains(page, `id="accounts-settings-table"`) {
		t.Error("the accounts group with Mozilla's accounts")
	}
	if !strings.Contains(page, `<h2 id="hints-title">The settings agree</h2>`) {
		t.Errorf("hints: %s", page[strings.Index(page, `<section id="hints">`):strings.Index(page, `<nav class="chips"`)])
	}
	if strings.Contains(page, "hunter2") {
		t.Error("the password")
	}

	// an install from before ADMIN_DB_PASSWORD: the Sync server's users, the tokenserver
	// database, and the setup check's hint
	t.Setenv("ADMIN_DB_PASSWORD", "")
	page = configPage(t, false, func(app *App, _ *fakeFxa) { app.sync.own = nil })
	for setting, want := range map[string]string{
		"Tokenserver database": "tokenserver on tokenserver_db:3306, database tokenserver",
		"Tokenserver password": "set SYNC_TOKENSERVER_DB_PASSWORD",
		"Admin UI database":    "the tokenserver database, as the Sync server&#39;s user ADMIN_DB_PASSWORD an install from before",
	} {
		if got := configRowOf(page, setting); !strings.HasPrefix(got, want) {
			t.Errorf("before ADMIN_DB_PASSWORD, %s: %q, want %q", setting, got, want)
		}
	}
	if !strings.Contains(page, "Event log (ADMIN_DB_PASSWORD): ") {
		t.Error("before ADMIN_DB_PASSWORD: no hint of the setup check")
	}
	if got := configRowOf(page, "Admin UI database"); !strings.Contains(got, "./prepare_environment.sh --upgrade") {
		t.Errorf("before ADMIN_DB_PASSWORD, compose: %q", got)
	}
	// with the Quadlets their steps, --upgrade writes no unit
	page = configPage(t, false, func(app *App, _ *fakeFxa) { app.sync.own, app.deployment = nil, deployment{kind: "quadlets"} })
	if got := configRowOf(page, "Admin UI database"); !strings.Contains(got, "the steps of docs/upgrading.md#with-quadlets for the Quadlets") || strings.Contains(got, "--upgrade") {
		t.Errorf("before ADMIN_DB_PASSWORD, Quadlets: %q", got)
	}
	t.Setenv("ADMIN_DB_PASSWORD", "hunter2hunter3")

	// with the accounts, and a few settings that disagree
	t.Setenv("FXA_AUTH_URL", "https://api.example.com")
	t.Setenv("FXA_CONTENT_URL", "http://accounts.example.com")
	t.Setenv("FXA_PAIRING_URL", "https://pairing.example.com")
	t.Setenv("FXA_MAX_ACCOUNTS", "")
	t.Setenv("FXA_DB", "mariadb")
	t.Setenv("FXA_DB_HOST", "db.example.com")
	t.Setenv("ADMIN_AUTH_HEADER", "Remote-Email")
	t.Setenv("ADMIN_TRUSTED_PROXIES", "172.18.0.1")
	t.Setenv("ADMIN_EXPORT_PORT", "0.0.0.0:8090")
	t.Setenv("ALERT_EMAIL", "admin@example.com")
	page = configPage(t, true, func(app *App, _ *fakeFxa) { app.emailDomain = "accounts.example.com" })
	for setting, want := range map[string]string{
		"Max accounts":          "unlimited (3 accounts) FXA_MAX_ACCOUNTS FXA_MAX_ACCOUNTS=not set, initial:unlimited: set to unlimited on a new database only",
		"Database":              "MariaDB FXA_DB fxa, fxa_oauth, fxa_profile, pushbox and ffs, on your own server (docs/databases.md#your-own-server)",
		"Sign-ups":              "open FXA_SIGNUPS , FXA_SIGNUP_ALLOWLIST",
		"Pairing server":        "https://pairing.example.com FXA_PAIRING_URL",
		"Trusted proxies":       "172.18.0.1 ADMIN_TRUSTED_PROXIES",
		"Alerts to":             "admin@example.com ADMIN_ALERT_EMAIL not sent: no SMTP server (FXA_SMTP_HOST)",
		"Access token lifetime": "60 minutes (default) FXA_ACCESS_TOKEN_LIFETIME",
		"Security history":      "off (default) FXA_ACCOUNT_EVENTS",
		// ffs_admin, the accounts' user, is not the admin UI's database of that name
		"Server":                           "ffs_admin on db.example.com:3306 FXA_MYSQL_HOST , FXA_MYSQL_PORT as the accounts&#39; database user ffs_admin, not the admin UI&#39;s own database (ADMIN_DB_NAME",
		"Password of ffs_admin (accounts)": "not set FXA_ADMIN_DB_PASSWORD the accounts&#39; database user, not ADMIN_DB_USER",
	} {
		if got := configRowOf(page, setting); !strings.HasPrefix(got, want) {
			t.Errorf("%s: %q, want %q", setting, got, want)
		}
	}
	hints := page[strings.Index(page, `<section id="hints">`):strings.Index(page, `<nav class="chips"`)]
	for _, want := range []string{"8 settings to check",
		// the accounts need their SMTP server, whatever the alerts use
		"Email of the accounts (FXA_SMTP_HOST): FXA_SMTP_HOST is not set",
		"FXA_CONTENT_URL is http://accounts.example.com, not an https:// URL",
		"FXA_PAIRING_URL is https://pairing.example.com, not a wss:// URL",
		"FXA_EMAIL_DOMAIN is accounts.example.com, but the accounts API (FXA_AUTH_URL) is api.example.com",
		"FXA_OAUTH_SERVER_URL is https://oauth.accounts.firefox.com/v1, not the accounts of this server",
		"ADMIN_EXPORT_PORT is 0.0.0.0:8090, not a loopback address",
		"ADMIN_ALERT_EMAIL is set, but there is no SMTP server",
		// no backups recorded: the hint of the overview's tile
		"Backups: none recorded yet."} {
		if !strings.Contains(hints, want) {
			t.Errorf("hints: no %q in %s", want, hints)
		}
	}
	// the groups of the page, Connect a device still last in the nav
	ids := regexp.MustCompile(`<section class="card" aria-labelledby="[a-z]+-settings-title" id="([a-z]+)-settings">`).FindAllStringSubmatch(page, -1)
	var got []string
	for _, m := range ids {
		got = append(got, m[1])
	}
	if strings.Join(got, " ") != "public sync accounts limits admin email alerts backups maintenance metrics" {
		t.Errorf("groups: %v", got)
	}
}

func TestLoopbackPort(t *testing.T) {
	for port, want := range map[string]bool{"127.0.0.1:8090": true, "[::1]:8090": true, "localhost:8090": true,
		"8090": false, "0.0.0.0:8090": false, "192.168.1.5:8090": false, "[::]:8090": false} {
		if loopbackPort(port) != want {
			t.Errorf("%s: %v", port, !want)
		}
	}
}

func TestRedactURL(t *testing.T) {
	for in, want := range map[string]string{"fxa-redis:6379": "fxa-redis:6379", "redis://:pw@fxa-redis:6379": "redis://:xxxxx@fxa-redis:6379",
		"https://accounts.example.com": "https://accounts.example.com", "redis://u:p w@%zz": "redis://…"} {
		if got := redactURL(in); got != want {
			t.Errorf("%s: %s", in, got)
		}
	}
}

// the page says what the program does with a variable, read with the program's own
// rules, not parsed again its own way
func TestConfigPageReadsLikeTheProgram(t *testing.T) {
	// what the admin UI makes of them: insecure with 1, true or yes (envSwitch), the release
	// checks off with false only, implicit TLS with true only
	t.Setenv("ADMIN_INSECURE_COOKIE", "Yes")
	t.Setenv("ADMIN_UPDATE_CHECK", "0")
	t.Setenv("SMTP_HOST", "smtp.example.com")
	t.Setenv("SMTP_SECURE", "1")
	t.Setenv("ALERT_EMAIL", "admin@example.com")
	t.Setenv("SYNCSTORAGE_DOMAIN", "http://localhost:8000")
	t.Setenv("FXA_AUTH_URL", "https://api.example.com")
	t.Setenv("FXA_PROFILE_URL", "https://API.example.com")
	t.Setenv("TOKENSERVER_DB_HOST", "db.example.com")
	t.Setenv("SYNC_DB", "mysql")
	t.Setenv("FXA_DB", "mariadb")
	t.Setenv("FXA_DB_HOST", "fxa-db")
	t.Setenv("ADMIN_PASSWORD", "correct-horse-battery")
	auth, err := loadAuth()
	if err != nil {
		t.Fatal(err)
	}
	page := configPage(t, true, func(app *App, _ *fakeFxa) {
		app.auth.insecureCookie = auth.insecureCookie
		app.mailer = newMailer("firefox-sync admin <admin@example.com>")
		// the version the health check read from the server
		app.health.components = []Component{{Name: "Tokenserver database", Up: true, Version: "MySQL 8.0.39"}}
	})
	for setting, want := range map[string]string{
		"Session cookie": "also over plain HTTP ADMIN_INSECURE_COOKIE",
		"New releases":   "on ADMIN_UPDATE_CHECK",
		"TLS":            "STARTTLS (the password only over TLS) FXA_SMTP_SECURE",
		"Sender":         "firefox-sync admin &lt;admin@example.com&gt; FXA_SMTP_SENDER , ADMIN_ALERT_EMAIL FXA_SMTP_SENDER not set",
		"Databases":      "MySQL 8.0.39 SYNC_DB the tokenserver and the storage databases, on your own server",
		// not checked yet: the image of the stack's container
		"Database": "MariaDB FXA_DB fxa, fxa_oauth, fxa_profile, pushbox and ffs, on a container of the stack",
	} {
		if got := configRowOf(page, setting); !strings.HasPrefix(got, want) {
			t.Errorf("%s: %q, want %q", setting, got, want)
		}
	}
	hints := page[strings.Index(page, `<section id="hints">`):strings.Index(page, `<nav class="chips"`)]
	if !strings.Contains(hints, "ADMIN_INSECURE_COOKIE is set") {
		t.Errorf("no hint of ADMIN_INSECURE_COOKIE=Yes: %s", hints)
	}
	// http://localhost is fine for Firefox; two parts on one host name are not
	if strings.Contains(hints, "SYNC_PUBLIC_URL is http://localhost:8000") {
		t.Errorf("a hint of http://localhost: %s", hints)
	}
	if !strings.Contains(hints, "FXA_AUTH_URL and FXA_PROFILE_URL are both on API.example.com") {
		t.Errorf("no hint of one host name for two: %s", hints)
	}

	// with true only: implicit TLS, the release checks off; no hint without the variable
	t.Setenv("SMTP_SECURE", "true")
	t.Setenv("ADMIN_UPDATE_CHECK", "false")
	t.Setenv("ADMIN_INSECURE_COOKIE", "false")
	t.Setenv("FXA_PROFILE_URL", "https://profile.example.com")
	if auth, err = loadAuth(); err != nil || auth.insecureCookie {
		t.Fatalf("ADMIN_INSECURE_COOKIE=false: %v, %v", auth, err)
	}
	page = configPage(t, true, func(app *App, _ *fakeFxa) { app.mailer = newMailer("") })
	for setting, want := range map[string]string{
		"Session cookie": "Secure (HTTPS, or http://localhost)",
		"New releases":   "off ADMIN_UPDATE_CHECK",
		"TLS":            "TLS from the start (port 465)",
		// an own server, not checked yet: no version
		"Databases": "MySQL SYNC_DB",
	} {
		if got := configRowOf(page, setting); !strings.HasPrefix(got, want) {
			t.Errorf("%s: %q, want %q", setting, got, want)
		}
	}
	hints = page[strings.Index(page, `<section id="hints">`):strings.Index(page, `<nav class="chips"`)]
	if strings.Contains(hints, "ADMIN_INSECURE_COOKIE") || strings.Contains(hints, "both on") {
		t.Errorf("hints: %s", hints)
	}
}

func TestLoopbackURL(t *testing.T) {
	for raw, want := range map[string]bool{"http://localhost:8000": true, "http://127.0.0.1:8000": true, "http://[::1]:8000": true,
		"http://sync.example.com": false, "http://10.0.0.1": false, "localhost": false} {
		if loopbackURL(raw) != want {
			t.Errorf("%s: %v", raw, !want)
		}
	}
}

// the switches of .env that are off unless asked for: never on with false or 0, an error
// for what is neither
func TestEnvSwitch(t *testing.T) {
	t.Setenv("ADMIN_PASSWORD", "correct-horse-battery")
	for value, want := range map[string]bool{"": false, "0": false, "false": false, "FALSE": false, "no": false, "off": false,
		"1": true, "true": true, "True": true, "yes": true, "on": true, " 1 ": true} {
		t.Setenv("ADMIN_INSECURE_COOKIE", value)
		t.Setenv("SMTP_INSECURE_AUTH", value)
		on, err := envSwitch("ADMIN_INSECURE_COOKIE")
		if err != nil || on != want {
			t.Errorf("%q: %v, %v", value, on, err)
		}
		auth, err := loadAuth()
		if err != nil || auth.insecureCookie != want {
			t.Errorf("loadAuth with %q: %v", value, err)
		}
		t.Setenv("SMTP_HOST", "smtp.example.com")
		if m := smtpServer(); m == nil || m.insecureAuth != want {
			t.Errorf("SMTP_INSECURE_AUTH=%q: %+v", value, m)
		}
	}
	for _, value := range []string{"maybe", "2", "enable"} {
		t.Setenv("ADMIN_INSECURE_COOKIE", value)
		if _, err := loadAuth(); err == nil || !strings.Contains(err.Error(), "ADMIN_INSECURE_COOKIE must be 1, true or yes") {
			t.Errorf("ADMIN_INSECURE_COOKIE=%q: %v", value, err)
		}
	}
}
