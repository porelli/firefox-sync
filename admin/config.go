package main

import (
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

// The configuration page: what the stack runs with, read-only, by component, so that
// an admin can check the settings without reading .env. A secret is never shown, only
// whether it is set: the page reads the environment only through configVars, where
// every variable the admin UI reads or is given says whether it is one (a test fails
// on a variable of the code, of compose or of the Quadlets missing there)

// configVars: the variables of the admin UI's environment, true for a secret
var configVars = map[string]bool{
	// secrets: shown as "set" or "not set"
	"ADMIN_PASSWORD":           true,
	"ADMIN_OIDC_CLIENT_SECRET": true,
	"METRICS_TOKEN":            true,
	"SMTP_PASS":                true,
	"TOKENSERVER_DB_PASSWORD":  true,
	"STORAGE_DB_PASSWORD":      true,
	"FXA_DB_PASSWORD":          true,
	"ADMIN_DB_PASSWORD":        true,
	// the destinations of the alerts: URLs with their tokens, shown as scheme://host
	"ADMIN_NOTIFY": true,
	// the password of the accounts' Redis (the Helm chart's)
	"FXA_REDIS_PASSWORD": true,
	// fxa-init (the fxa-policy container)
	"FXA_ADMIN_DB_PASSWORD": true,
	"FXA_DB_ROOT_PASSWORD":  true,
	"FXA_MYSQL_PASSWORD":    true,

	// the Sync server and its databases
	"SYNCSTORAGE_DOMAIN": false, "SYNCSTORAGE_URL": false, "SYNC_DB": false, "MAX_USERS": false,
	// the old names of the Sync settings in .env (compose, setup.go)
	"FFS_OLD_ENV_NAMES":   false,
	"TOKENSERVER_DB_TYPE": false, "TOKENSERVER_DB_HOST": false, "TOKENSERVER_DB_PORT": false, "TOKENSERVER_DB_NAME": false,
	"TOKENSERVER_DB_USER": false, "TOKENSERVER_DB_SSLMODE": false,
	"STORAGE_DB_HOST": false, "STORAGE_DB_PORT": false, "STORAGE_DB_NAME": false, "STORAGE_DB_USER": false,
	"FXA_OAUTH_SERVER_URL": false, "FXA_EMAIL_DOMAIN": false,
	// the admin UI's own users and database (owndb.go)
	"ADMIN_DB_USER": false, "ADMIN_DB_SYNC_USER": false, "ADMIN_DB_NAME": false,
	// your own database server, the account that applies its SQL (its name, the password is not given)
	"SYNC_DB_CONTAINERS": false, "SYNC_DB_BOOTSTRAP_USER": false,
	// the self-hosted accounts
	"FXA_DB": false, "FXA_DB_HOST": false, "FXA_DB_PORT": false, "FXA_DB_USER": false, "FXA_REDIS": false,
	"FXA_CONTENT_URL": false, "FXA_AUTH_URL": false, "FXA_PROFILE_URL": false, "FXA_PAIRING_URL": false,
	"FXA_AUTH_UPSTREAM": false, "FXA_CONTENT_INTERNAL_URL": false, "FXA_PROFILE_INTERNAL_URL": false, "FXA_PAIRING_INTERNAL_URL": false,
	"FXA_MAX_ACCOUNTS": false, "FXA_CLIENT_ADDRESS_DEPTH": false, "FXA_ACCESS_TOKEN_LIFETIME": false, "FXA_ACCOUNT_EVENTS": false,
	// fxa-init
	"FXA_DB_ROOT_USER": false, "FXA_MYSQL_USER": false, "FXA_SIGNUPS": false, "FXA_SIGNUP_ALLOWLIST": false, "FXA_INIT_TIMEOUT": false,
	// signing in to the admin UI
	"ADMIN_OIDC_ISSUER": false, "ADMIN_OIDC_CLIENT_ID": false, "ADMIN_OIDC_REDIRECT_URL": false, "ADMIN_OIDC_SCOPES": false,
	"ADMIN_OIDC_NAME": false, "ADMIN_OIDC_GROUPS_CLAIM": false, "ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL": false,
	"ADMIN_AUTH_HEADER": false, "ADMIN_AUTH_GROUPS_HEADER": false, "ADMIN_TRUSTED_PROXIES": false,
	"ADMIN_ALLOWED_USERS": false, "ADMIN_ALLOWED_GROUPS": false, "ADMIN_INSECURE_COOKIE": false,
	// the admin UI itself
	"ADMIN_LISTEN": false, "GATE_LISTEN": false, "METRICS_LISTEN": false, "ADMIN_EXPORT_PORT": false, "ADMIN_GATE_EXPORT_PORT": false,
	"ADMIN_DEPLOYMENT": false, "ADMIN_K8S_RELEASE": false, "ADMIN_K8S_NAMESPACE": false,
	"ADMIN_K8S_FULLNAME": false, "ADMIN_K8S_SECRET": false, "ADMIN_K8S_CHART": false, "ADMIN_K8S_CHART_VERSION": false, "ADMIN_TZ": false, "TZ": false, "SSL_CERT_FILE": false, "SSL_CERT_DIR": false,
	// email, alerts, metrics and checks
	"SMTP_HOST": false, "SMTP_PORT": false, "SMTP_USER": false, "SMTP_SECURE": false, "SMTP_SENDER": false, "SMTP_INSECURE_AUTH": false,
	"ALERT_EMAIL": false, "ALERT_INTERVAL_SECONDS": false, "HEALTH_CHECK_SECONDS": false, "METRICS_FLUSH_SECONDS": false,
	"ADMIN_PUBLIC_CHECK": false, "ADMIN_UPDATE_CHECK": false,
	"ADMIN_ERROR_RATE_PERCENT": false, "ADMIN_ERROR_RATE_MIN_ERRORS": false, "ADMIN_DB_GROWTH_MB": false, "ADMIN_DB_GROWTH_FACTOR": false,
	// maintenance, retention, backups
	"ADMIN_STALE_DAYS": false, "ADMIN_UNCONFIRMED_HOURS": false, "ADMIN_RETENTION_DAYS": false, "ADMIN_AUDIT_RETENTION_DAYS": false,
	"ADMIN_PURGE": false, "ADMIN_DELETE_UNCONFIRMED_DAYS": false, "ADMIN_SIGNUP_BURST": false, "BACKUP_TIME": false, "BACKUP_KEEP": false,
}

// configLookup: a variable as the page may show it: a secret as "set" (or "" when not
// set), another as it is with the password of a URL hidden; "" for a variable that is
// not in configVars
func configLookup(name string) string {
	secret, known := configVars[name]
	v := os.Getenv(name)
	switch {
	case !known || v == "":
		return ""
	case secret:
		return "set"
	}
	return redactURL(v)
}

// redactURL: a URL with a password (redis://:pw@host) without it
func redactURL(v string) string {
	if !strings.Contains(v, "://") {
		return v
	}
	u, err := url.Parse(v)
	if err != nil {
		// not a URL we can read: nothing after a scheme, in case it holds a password
		scheme, _, _ := strings.Cut(v, "://")
		return scheme + "://…"
	}
	if _, ok := u.User.Password(); ok {
		return u.Redacted()
	}
	return v
}

// configRow: a setting of the page: its value as the admin UI runs with it, the
// variables of .env it comes from, and what it means
type configRow struct {
	Setting string
	Value   string
	// the variables of .env (or of the container, where .env has none)
	Vars []string
	// not set: Value is the default
	Default bool
	Secret  bool
	// what the admin UI found or made of the variables, not one of them as is
	Fact bool
	Note string
}

type configGroup struct {
	ID, Title, Intro string
	Rows             []configRow
}

// setting: the row of the variable name of the container, called dotenv in .env ("":
// the same), fallback when it is not set ("": "not set")
func setting(label, name, dotenv, fallback, note string) configRow {
	if dotenv == "" {
		dotenv = name
	}
	r := configRow{Setting: label, Vars: []string{dotenv}, Note: note, Secret: configVars[name]}
	if r.Value = configLookup(name); r.Value == "" {
		r.Value, r.Default = fallback, true
	}
	return r
}

// dotenvName: the name in .env of a variable of the container (SYNCSTORAGE_DOMAIN is
// SYNC_PUBLIC_URL there, the others have the same name)
func dotenvName(name string) string {
	if name == "SYNCSTORAGE_DOMAIN" {
		return "SYNC_PUBLIC_URL"
	}
	return name
}

// fact: a row of what the admin UI found (the databases, the other settings), from vars
func fact(label, value, note string, vars ...string) configRow {
	return configRow{Setting: label, Value: value, Vars: vars, Note: note, Fact: true}
}

// unset: the row marked as the default when none of its variables is set
func (r configRow) unset() configRow {
	r.Default = true
	for _, name := range r.Vars {
		if configLookup(name) != "" {
			r.Default = false
		}
	}
	return r
}

// shown: a variable that is no secret, fallback when not set
func shown(name, fallback string) string {
	if v := configLookup(name); v != "" && !configVars[name] {
		return v
	}
	return fallback
}

// count: a number of .env in words ("30 days"), as set when it is no number
func count(name, fallback, unit string) string {
	v := shown(name, fallback)
	if n, err := strconv.Atoi(v); err == nil {
		return plural(n, unit)
	}
	return v
}

func days(name, fallback string) string { return count(name, fallback, "day") }

// dbAddress: "user on host:port, database name" of the shown parts
func dbAddress(user, host, port, name string) string {
	s := net.JoinHostPort(host, port)
	if user != "" {
		s = user + " on " + s
	}
	if name != "" {
		s += ", database " + name
	}
	return s
}

// stackHosts: the database containers of compose and the Quadlets
var stackHosts = map[string]bool{"tokenserver_db": true, "syncstorage_db": true, "postgres_db": true, "fxa-db": true,
	"firefox-sync-tokenserver-db": true, "firefox-sync-syncstorage-db": true, "firefox-sync-fxa-db": true}

func (d deployment) whereDB(host string) string {
	if d.stackHost(host) {
		return "a container of the stack"
	}
	return "your own server (docs/databases.md#your-own-server)"
}

// dbServer: the server as the health check read it (MariaDB 11.8.3), otherwise the
// image of the stack's container (stack) or only the kind (your own server: the
// version is not known before the check)
func (d deployment) dbServer(components []Component, check, kind, stack string, host string) string {
	for _, c := range components {
		if c.Name == check && c.Version != "" {
			return c.Version
		}
	}
	if d.stackHost(host) {
		return stack
	}
	return kind
}

// loopbackURL: an http URL Firefox accepts without https (localhost, 127.0.0.1, ::1)
func loopbackURL(raw string) bool {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return false
	}
	if u.Hostname() == "localhost" {
		return true
	}
	addr, err := netip.ParseAddr(u.Hostname())
	return err == nil && addr.IsLoopback()
}

// limitNote: where a limit comes from, SYNC_MAX_USERS or FXA_MAX_ACCOUNTS as in .env
func limitNote(name, raw, empty, managed string) string {
	value, fixed, err := parseLimitSetting(raw, empty)
	shown := strings.TrimSpace(raw)
	if shown == "" {
		shown = "not set, " + empty
	}
	switch {
	case err != nil:
		return fmt.Sprintf("%s=%s is not valid (%v): its init container stops", name, shown, err)
	case fixed:
		return fmt.Sprintf("%s=%s: fixed, set to %s on every start, read-only on the overview", name, shown, value)
	}
	return fmt.Sprintf("%s=%s: set to %s on a new database only, then %s", name, shown, value, managed)
}

// limitValue: the limit in force and its use, from the database
func limitValue(l *Limit) string {
	if l == nil {
		return "not read"
	}
	if l.Unlimited {
		return "unlimited (" + plural(l.Count, "account") + ")"
	}
	return fmt.Sprintf("%d (%d used)", l.Max, l.Count)
}

// loopbackPort: ADMIN_EXPORT_PORT (127.0.0.1:8090, [::1]:8090, 8090: every address)
// publishes on a loopback address only
func loopbackPort(port string) bool {
	host, _, err := net.SplitHostPort(port)
	if err != nil {
		// a port alone: every address of the host
		return false
	}
	if host == "localhost" {
		return true
	}
	addr, err := netip.ParseAddr(host)
	return err == nil && addr.IsLoopback()
}

// configPage: the settings by part, with the hints of what disagrees; nothing changes here
func (a *App) configPage(w http.ResponseWriter, r *http.Request, s *session) {
	ctx := r.Context()
	data := a.base(s)
	var errs []string
	fxa := a.fxa != nil

	var status *SyncStatus
	var syncLimit, accountLimit *Limit
	if a.sync != nil {
		var err error
		if status, err = a.sync.Status(ctx); err != nil {
			errs = append(errs, "Sync database: "+err.Error())
		} else {
			l := status.Limit()
			syncLimit = &l
		}
	}
	var policy *SignupPolicy
	if fxa {
		if l, err := a.fxa.AccountLimit(ctx); err != nil {
			errs = append(errs, "Max accounts: "+err.Error())
		} else {
			accountLimit = &l
		}
		var err error
		if policy, err = a.fxa.Policy(ctx); err != nil {
			errs = append(errs, "Sign-up policy: "+err.Error())
		}
	}
	var components []Component
	var backups []BackupStatus
	if a.health != nil {
		components, _, _ = a.healthTable()
		backups = a.health.Backups()
	}

	onText := map[bool]string{true: "on", false: "off"}

	// public URLs: what Firefox and the people reach
	public := configGroup{ID: "public", Title: "Public URLs", Intro: "What Firefox and the people of this server reach, through your reverse proxy."}
	public.Rows = append(public.Rows, setting("Sync server", "SYNCSTORAGE_DOMAIN", "SYNC_PUBLIC_URL", "", "the Sync node the init container sets in the tokenserver"))
	if status != nil {
		var nodes []string
		for _, n := range status.Nodes {
			if !n.Downed {
				nodes = append(nodes, strings.TrimSuffix(n.Node, "/"))
			}
		}
		node := strings.Join(nodes, ", ")
		if node == "" {
			node = "none"
		}
		public.Rows = append(public.Rows, fact("Sync node handed out", node, "the nodes table of the tokenserver: where Firefox syncs", "SYNC_PUBLIC_URL"))
	}
	if fxa {
		public.Rows = append(public.Rows,
			setting("Accounts pages", "FXA_CONTENT_URL", "", "", "identity.fxaccounts.autoconfig.uri of Firefox, the links of the invitations"),
			setting("Accounts API", "FXA_AUTH_URL", "", "", "POST /v1/account/create goes to the sign-up gate (ADMIN_GATE_EXPORT_PORT)"),
			setting("Profile server", "FXA_PROFILE_URL", "", "", ""),
			setting("Pairing server", "FXA_PAIRING_URL", "", "Mozilla's", "the QR code of a computer for a phone"))
	}
	if v := configLookup("ADMIN_OIDC_REDIRECT_URL"); v != "" {
		public.Rows = append(public.Rows, setting("Admin UI", "ADMIN_OIDC_REDIRECT_URL", "", "", "single sign-on comes back here"))
	}

	// the Sync server and its databases, as dbCredentials connects: with ADMIN_DB_PASSWORD
	// the admin UI's reader ADMIN_DB_SYNC_USER with that password, before it the Sync
	// server's users
	syncGroup := configGroup{ID: "sync", Title: "Sync server and tokenserver"}
	kind := shown("TOKENSERVER_DB_TYPE", "mysql")
	tsHost := configLookup("TOKENSERVER_DB_HOST")
	ownDB := configLookup("ADMIN_DB_PASSWORD") != ""
	reader := shown("ADMIN_DB_SYNC_USER", "ffs_admin_sync")
	syncUser := func(name, dotenv string) (string, string) {
		if ownDB {
			return reader, "ADMIN_DB_SYNC_USER"
		}
		return configLookup(name), dotenv
	}
	syncPassword := func(label, name, dotenv string) configRow {
		if ownDB {
			return setting(label, name, "ADMIN_DB_PASSWORD", "not set", "of "+reader)
		}
		return setting(label, name, dotenv, "not set", "")
	}
	postgresSetting := "COMPOSE_FILE: compose/sync-postgres.yml"
	if a.deployment.Kubernetes() != nil {
		postgresSetting = "database.backend=postgres"
	}
	if kind == "postgres" {
		syncGroup.Rows = append(syncGroup.Rows,
			fact("Database", "PostgreSQL, tokenserver and storage in one database", a.deployment.whereDB(tsHost), postgresSetting),
			func() configRow {
				user, userVar := syncUser("TOKENSERVER_DB_USER", "SYNC_POSTGRES_USER")
				return fact("Server", dbAddress(user, tsHost, shown("TOKENSERVER_DB_PORT", "5432"), configLookup("TOKENSERVER_DB_NAME")), "",
					"SYNC_POSTGRES_HOST", "SYNC_POSTGRES_PORT", userVar, "SYNC_POSTGRES_NAME")
			}(),
			syncPassword("Database password", "TOKENSERVER_DB_PASSWORD", "SYNC_POSTGRES_PASSWORD"),
			setting("TLS", "TOKENSERVER_DB_SSLMODE", "", "disable", "sslmode of the connection"))
	} else {
		name := a.deployment.dbServer(components, "Tokenserver database", "MariaDB", "MariaDB", tsHost)
		if configLookup("SYNC_DB") == "mysql" {
			// the image is SYNC_MYSQL_IMAGE (lts or a pinned major), not known here: the version once checked
			name = a.deployment.dbServer(components, "Tokenserver database", "MySQL", "MySQL", tsHost)
		}
		user, userVar := syncUser("TOKENSERVER_DB_USER", "SYNC_TOKENSERVER_DB_USER")
		syncGroup.Rows = append(syncGroup.Rows,
			fact("Databases", name, "the tokenserver and the storage databases, on "+a.deployment.whereDB(tsHost), "SYNC_DB"),
			fact("Tokenserver database", dbAddress(user, tsHost, shown("TOKENSERVER_DB_PORT", "3306"), configLookup("TOKENSERVER_DB_NAME")), "",
				"SYNC_TOKENSERVER_DB_HOST", "SYNC_TOKENSERVER_DB_PORT", userVar, "SYNC_TOKENSERVER_DB_NAME"),
			syncPassword("Tokenserver password", "TOKENSERVER_DB_PASSWORD", "SYNC_TOKENSERVER_DB_PASSWORD"))
		if host := configLookup("STORAGE_DB_HOST"); host != "" {
			user, userVar := syncUser("STORAGE_DB_USER", "SYNC_STORAGE_DB_USER")
			syncGroup.Rows = append(syncGroup.Rows,
				fact("Storage database", dbAddress(user, host, shown("STORAGE_DB_PORT", "3306"), configLookup("STORAGE_DB_NAME")), "what each account stores (sizes only)",
					"SYNC_STORAGE_DB_HOST", "SYNC_STORAGE_DB_PORT", userVar, "SYNC_STORAGE_DB_NAME"),
				syncPassword("Storage password", "STORAGE_DB_PASSWORD", "SYNC_STORAGE_DB_PASSWORD"))
		} else {
			syncGroup.Rows = append(syncGroup.Rows, fact("Storage database", "not given to the admin UI", "no sizes, no purge", "SYNC_STORAGE_DB_HOST"))
		}
	}
	if ownDB {
		port := shown("TOKENSERVER_DB_PORT", "3306")
		if kind == "postgres" {
			port = shown("TOKENSERVER_DB_PORT", "5432")
		}
		syncGroup.Rows = append(syncGroup.Rows,
			fact("Admin UI database", dbAddress(shown("ADMIN_DB_USER", "ffs_admin_ui"), tsHost, port, shown("ADMIN_DB_NAME", "ffs_admin")),
				"the event log, the audit trail, the notes: out of the Sync server's reach (docs/reference/database-users.md#the-admin-uis-own-database)", "ADMIN_DB_USER", "ADMIN_DB_NAME"),
			setting("Admin UI database password", "ADMIN_DB_PASSWORD", "", "not set", "of "+shown("ADMIN_DB_USER", "ffs_admin_ui")+" and "+reader))
	} else {
		syncGroup.Rows = append(syncGroup.Rows, fact("Admin UI database", "the tokenserver database, as the Sync server's user",
			"an install from before ADMIN_DB_PASSWORD: "+ownDBHint(a.deployment), "ADMIN_DB_PASSWORD"))
	}
	oauthNote := "the Sync server checks the sign-ins of Firefox with its keys (/jwks)"
	if fxa {
		oauthNote += "; with these accounts http://fxa-auth:9000/v1"
	}
	syncGroup.Rows = append(syncGroup.Rows,
		setting("Sign-in keys", "FXA_OAUTH_SERVER_URL", "", "", oauthNote),
		setting("Account emails", "FXA_EMAIL_DOMAIN", "", "", "the tokenserver keeps each account as <uid>@FXA_EMAIL_DOMAIN"),
		setting("Sync server, inside the stack", "SYNCSTORAGE_URL", "", "http://syncstorage:8000", "the health checks and the versions"))

	// the self-hosted accounts
	accounts := configGroup{ID: "accounts", Title: "Accounts"}
	if !fxa {
		accounts.Intro = "Mozilla's accounts: Firefox signs in at accounts.firefox.com, the server only knows the account ids. Self-hosted accounts: compose/fxa.yml, see docs/accounts.md."
	} else {
		fxaHost := shown("FXA_DB_HOST", "fxa-db")
		// the image is FXA_MYSQL_IMAGE (lts or a pinned major), not known here: the version once checked
		dbName := a.deployment.dbServer(components, "Accounts database", "MySQL", "MySQL", fxaHost)
		if configLookup("FXA_DB") == "mariadb" {
			// the image is FXA_MARIADB_IMAGE, not known here: the version once checked
			dbName = a.deployment.dbServer(components, "Accounts database", "MariaDB", "MariaDB", fxaHost)
		}
		accounts.Intro = "The self-hosted Mozilla accounts (compose/fxa.yml)."
		k := a.deployment.Kubernetes()
		if k != nil {
			accounts.Intro = "The self-hosted Mozilla accounts (fxa.enabled of the chart). Their auth pod runs the migrations and the sign-up policy first, as its init containers: " +
				k.RestartFxa() + " runs them again (their logs: " + k.FxaLogs("migrations") + ", -c policy)."
		}
		accounts.Rows = append(accounts.Rows,
			fact("Database", dbName, "fxa, fxa_oauth, fxa_profile, pushbox and ffs, on "+a.deployment.whereDB(fxaHost), "FXA_DB"),
			fact("Server", dbAddress(shown("FXA_DB_USER", "ffs_admin"), fxaHost, shown("FXA_DB_PORT", "3306"), ""),
				"as the accounts' database user ffs_admin, not the admin UI's own database (ADMIN_DB_NAME, its user ADMIN_DB_USER): it reads the accounts through the views of ffs only",
				"FXA_MYSQL_HOST", "FXA_MYSQL_PORT"),
			setting("Password of ffs_admin (accounts)", "FXA_DB_PASSWORD", "FXA_ADMIN_DB_PASSWORD", "not set", "the accounts' database user, not ADMIN_DB_USER"),
			setting("Redis", "FXA_REDIS", "", "fxa-redis:6379", "the sessions' last use, tokens revoked"))
		if policy != nil {
			note := "in the database: from .env when changed there (on the next start), otherwise as set on the overview"
			if k != nil {
				note = "in the database: from your values when changed there (on the next start of the auth pod: helm upgrade, or " + k.RestartFxa() + "), otherwise as set on the overview"
			}
			accounts.Rows = append(accounts.Rows, fact("Sign-ups", describePolicy(policy), note, "FXA_SIGNUPS", "FXA_SIGNUP_ALLOWLIST"))
		}
		accounts.Rows = append(accounts.Rows,
			setting("Client IP address", "FXA_CLIENT_ADDRESS_DEPTH", "", "2", "the position in X-Forwarded-For of the rate limits: 2 for one reverse proxy"),
			setting("Access token lifetime", "FXA_ACCESS_TOKEN_LIFETIME", "", "60 minutes", "of the access tokens of Firefox"),
			fact("Security history", onText[a.accountEvents], "the sign-ins and changes of each account, with their IP addresses (docs/accounts.md#security-history)", "FXA_ACCOUNT_EVENTS").unset(),
			setting("Accounts API, inside the stack", "FXA_AUTH_UPSTREAM", "", "http://fxa-auth:9000", "where the sign-up gate passes the allowed sign-ups"))
		if k != nil {
			// not in the backups (an RWO volume of the auth pod's node): NOTES.txt says how to export them
			accounts.Rows = append(accounts.Rows, fact("Signing keys", "the PersistentVolumeClaim "+k.FxaKeys()+" (or your fxa.keys.existingSecret)",
				"kept on helm uninstall, not in the backups: without them every account signs in again; export them as the chart's NOTES say"))
		}
	}

	// the limits of accounts
	limits := configGroup{ID: "limits", Title: "Limits", Intro: "In force now, as the databases have them."}
	limits.Rows = append(limits.Rows, fact("Max users", limitValue(syncLimit),
		limitNote("SYNC_MAX_USERS", configLookup("MAX_USERS"), "", "on the overview"), "SYNC_MAX_USERS"))
	if fxa {
		limits.Rows = append(limits.Rows, fact("Max accounts", limitValue(accountLimit),
			limitNote(a.deployment.valueName("FXA_MAX_ACCOUNTS"), configLookup("FXA_MAX_ACCOUNTS"), "initial:unlimited", "on the overview"), "FXA_MAX_ACCOUNTS"))
	}

	// signing in to the admin UI
	admin := configGroup{ID: "admin", Title: "Admin UI and signing in"}
	passwordNote := "password sign-in off"
	if configLookup("ADMIN_PASSWORD") != "" {
		passwordNote = "password sign-in on"
	}
	admin.Rows = append(admin.Rows, setting("Password", "ADMIN_PASSWORD", "", "not set", passwordNote))
	issuer := configLookup("ADMIN_OIDC_ISSUER")
	if issuer == "" {
		admin.Rows = append(admin.Rows, setting("OpenID Connect", "ADMIN_OIDC_ISSUER", "", "off", ""))
	} else {
		note := "your identity provider"
		if fxa && strings.TrimSuffix(issuer, "/") == a.contentURL {
			note = "the self-hosted accounts (ADMIN_FXA_CLIENT_ID with docker compose)"
			if a.deployment.Kubernetes() != nil {
				note = "the self-hosted accounts (admin.fxaSignIn of the chart)"
			}
		}
		admin.Rows = append(admin.Rows,
			setting("OpenID Connect issuer", "ADMIN_OIDC_ISSUER", "", "", note),
			setting("Client id", "ADMIN_OIDC_CLIENT_ID", "", "", ""),
			setting("Client secret", "ADMIN_OIDC_CLIENT_SECRET", "", "not set", "not set: a public client (PKCE only)"),
			setting("Button", "ADMIN_OIDC_NAME", "", "single sign-on", "\"Sign in with ...\""),
			setting("Scopes", "ADMIN_OIDC_SCOPES", "", "openid email profile", ""),
			setting("Groups claim", "ADMIN_OIDC_GROUPS_CLAIM", "", "groups", "for ADMIN_ALLOWED_GROUPS"),
			setting("Unverified emails", "ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL", "", "refused", "true: accepted, for the self-hosted accounts only"))
	}
	if header := configLookup("ADMIN_AUTH_HEADER"); header == "" {
		admin.Rows = append(admin.Rows, setting("Trusted header", "ADMIN_AUTH_HEADER", "", "off", ""))
	} else {
		admin.Rows = append(admin.Rows,
			setting("Trusted header", "ADMIN_AUTH_HEADER", "", "", "the email of the user, set by your reverse proxy"),
			setting("Groups header", "ADMIN_AUTH_GROUPS_HEADER", "", "none", ""),
			setting("Trusted proxies", "ADMIN_TRUSTED_PROXIES", "", "", "the header counts only from these addresses"))
	}
	if issuer != "" || configLookup("ADMIN_AUTH_HEADER") != "" {
		admin.Rows = append(admin.Rows,
			setting("Admins", "ADMIN_ALLOWED_USERS", "", "nobody by email", "emails and @domains"),
			setting("Admin groups", "ADMIN_ALLOWED_GROUPS", "", "none", ""))
	}
	cookie := "Secure (HTTPS, or http://localhost)"
	if a.auth.insecureCookie {
		cookie = "also over plain HTTP"
	}
	published := setting("Published on", "ADMIN_EXPORT_PORT", "", "127.0.0.1:8090", "the port of the host; a loopback address: the server only")
	if k := a.deployment.Kubernetes(); k != nil {
		published = fact("Published on", "the Service "+k.AdminService()+", port 8080",
			k.Kubectl()+" port-forward svc/"+k.AdminService()+" 8090:8080, or its own Ingress (admin.ingress)")
	}
	admin.Rows = append(admin.Rows, fact("Session cookie", cookie, "", "ADMIN_INSECURE_COOKIE"), published)
	if fxa {
		gate := setting("Sign-up gate published on", "ADMIN_GATE_EXPORT_PORT", "", "127.0.0.1:8091", "POST /v1/account/create of FXA_AUTH_URL goes there")
		if k := a.deployment.Kubernetes(); k != nil {
			gate = fact("Sign-up gate published on", "the Service "+k.AdminService()+", port 8081",
				"POST /v1/account/create of fxa.authUrl goes there: the Ingress of the accounts' API routes it, with fxa.ingress.enabled and admin.enabled", "ADMIN_GATE_EXPORT_PORT")
		}
		admin.Rows = append(admin.Rows, gate)
	}
	zone := adminZone.String()
	deployVars := []string{"ADMIN_DEPLOYMENT"}
	if a.deployment.Kubernetes() != nil {
		deployVars = append(deployVars, "ADMIN_K8S_RELEASE", "ADMIN_K8S_NAMESPACE", "ADMIN_K8S_FULLNAME", "ADMIN_K8S_SECRET", "ADMIN_K8S_CHART", "ADMIN_K8S_CHART_VERSION")
	}
	admin.Rows = append(admin.Rows,
		fact("Time zone", zone, "of the pages and the alerts", "ADMIN_TZ", "TZ").unset(),
		fact("Runs with", a.deployment.name(), "the commands the pages show", deployVars...),
		fact("Version", version, "of the admin UI"))

	// email
	email := configGroup{ID: "email", Title: "Email (SMTP)", Intro: "The SMTP server of the stack: the accounts' emails (codes, password resets), the admin UI's invitations and notices to account owners, and its alert emails (alerts can go to ADMIN_NOTIFY instead)."}
	smtp := setting("SMTP server", "SMTP_HOST", "FXA_SMTP_HOST", "", "")
	if smtpServer() == nil {
		smtp.Value, smtp.Default, smtp.Note = "", true, "no emails from the admin UI"
		if h := configLookup("SMTP_HOST"); h != "" {
			smtp.Note = "still the placeholder of .env-example: no emails from the admin UI"
		}
	}
	email.Rows = append(email.Rows, smtp)
	if server := smtpServer(); server != nil {
		secure := "STARTTLS (the password only over TLS)"
		if server.implicitTLS {
			secure = "TLS from the start (port 465)"
		}
		sender := setting("Sender", "SMTP_SENDER", "FXA_SMTP_SENDER", "", "From of the invitations and notices")
		if a.mailer != nil && sender.Default {
			// newMailer's fallback, of ADMIN_ALERT_EMAIL
			sender = fact("Sender", a.mailer.from, "FXA_SMTP_SENDER not set: ADMIN_ALERT_EMAIL's, the From of the invitations, notices and alerts", "FXA_SMTP_SENDER", "ADMIN_ALERT_EMAIL")
		}
		email.Rows = append(email.Rows,
			setting("Port", "SMTP_PORT", "FXA_SMTP_PORT", "587", ""),
			fact("TLS", secure, "", "FXA_SMTP_SECURE"),
			setting("User", "SMTP_USER", "FXA_SMTP_USER", "none", ""),
			setting("Password", "SMTP_PASS", "FXA_SMTP_PASS", "not set", ""),
			sender)
		if server.insecureAuth {
			email.Rows = append(email.Rows, setting("Password without TLS", "SMTP_INSECURE_AUTH", "ADMIN_SMTP_INSECURE_AUTH", "", "allowed: in clear to a server that offers no TLS"))
		}
	}
	sends := "yes"
	if a.mailer == nil {
		sends = "no: no SMTP server or no sender"
	}
	email.Rows = append(email.Rows, fact("Invitations and notices sent", sends, "", "FXA_SMTP_HOST", "FXA_SMTP_SENDER"))

	// alerts
	alerts := configGroup{ID: "alerts", Title: "Alerts"}
	to := setting("Alerts to", "ALERT_EMAIL", "ADMIN_ALERT_EMAIL", "nobody", "")
	every := ""
	if a.alerter != nil {
		every = "collected and sent at most every " + plural(int(a.alerter.interval/time.Minute), "minute")
		if a.alerter.interval < time.Minute {
			every = "collected and sent at most every " + a.alerter.interval.String()
		}
	}
	switch {
	case a.alerter.emails():
		to.Note = every
	case configLookup("ALERT_EMAIL") != "":
		to.Note = "not sent: no SMTP server (FXA_SMTP_HOST)"
	default:
		to.Note = "no alert emails"
	}
	alerts.Rows = append(alerts.Rows, to)
	// the destinations as scheme://host: their URLs hold tokens
	if names := a.alerter.NotifyNames(); len(names) > 0 {
		alerts.Rows = append(alerts.Rows, fact("Notifications to", strings.Join(names, ", "), "shown without their paths and tokens; "+every, "ADMIN_NOTIFY"))
	} else {
		alerts.Rows = append(alerts.Rows, configRow{Setting: "Notifications to", Value: "nowhere", Vars: []string{"ADMIN_NOTIFY"}, Default: true, Fact: true,
			Note: "Slack, Discord, Teams, ntfy, Gotify, Telegram, Matrix or a webhook, see docs/admin/alerts.md#destinations"})
	}
	if fxa {
		burst := strconv.Itoa(a.signupBurst) + " accounts in an hour"
		if a.signupBurst == 0 {
			burst = "never"
		}
		alerts.Rows = append(alerts.Rows, fact("Sign-up burst", burst, "an alert when more accounts are created in an hour", "ADMIN_SIGNUP_BURST").unset())
	}

	if a.health != nil {
		spike := "off"
		if e := a.health.errorRate; e.on() {
			spike = fmt.Sprintf("%d%% of the requests in 15 minutes, %s at least", e.percent, plural(int(e.minErrors), "error"))
		}
		growth := "off"
		if g := a.health.growth; g.on() {
			var rules []string
			if g.mb > 0 {
				rules = append(rules, fmt.Sprintf("over %d MB a day", g.mb))
			}
			if g.factor > 0 {
				rules = append(rules, fmt.Sprintf("%d times the usual growth", g.factor))
			}
			growth = strings.Join(rules, ", or ")
		}
		alerts.Rows = append(alerts.Rows,
			fact("Spike of Sync errors", spike, "and 3 times the share of the day before", "ADMIN_ERROR_RATE_PERCENT", "ADMIN_ERROR_RATE_MIN_ERRORS").unset(),
			fact("A database growing fast", growth, "", "ADMIN_DB_GROWTH_MB", "ADMIN_DB_GROWTH_FACTOR").unset())
	}

	// backups
	backupGroup := configGroup{ID: "backups", Title: "Backups"}
	backupAt := a.backupTime + " UTC"
	if adminZone != time.UTC {
		backupAt += " (" + localClock(a.backupTime, time.Now(), adminZone) + " " + zone + ")"
	}
	_, backupText := backupTile(backups, time.Now())
	how := "COMPOSE_PROFILES=backup"
	if a.deployment.Quadlets() {
		how = "firefox-sync-backup.timer"
	} else if a.deployment.Kubernetes() != nil {
		how = "backup.enabled of the chart"
	}
	backupGroup.Rows = append(backupGroup.Rows,
		fact("Last runs", backupText, "as recorded in ffs_backups; on with "+how, ""),
		fact("Every night at", backupAt, "", "BACKUP_TIME").unset(),
		fact("Copies kept", strconv.Itoa(a.backupKeep), "the newest runs, in the backups volume", "BACKUP_KEEP").unset())

	// maintenance and retention
	maintenance := configGroup{ID: "maintenance", Title: "Maintenance and retention"}
	purge := "by hand only (Purge now on the overview)"
	if a.autoPurge {
		purge = "every day"
	}
	maintenance.Rows = append(maintenance.Rows,
		fact("Inactive after", plural(a.staleDays, "day"), "accounts and devices not used, only marked", "ADMIN_STALE_DAYS").unset(),
		fact("Metrics and events kept", days("ADMIN_RETENTION_DAYS", "30"), "", "ADMIN_RETENTION_DAYS").unset(),
		fact("Admin events kept", days("ADMIN_AUDIT_RETENTION_DAYS", "365"), "who did what", "ADMIN_AUDIT_RETENTION_DAYS").unset(),
		fact("Purge of the Sync storage", purge, "expired items, replaced keys, deleted accounts", "ADMIN_PURGE").unset())
	if fxa {
		unconfirmed := "never"
		if a.unconfirmedDays > 0 {
			unconfirmed = "after " + plural(a.unconfirmedDays, "day")
		}
		maintenance.Rows = append(maintenance.Rows,
			fact("Unconfirmed accounts deleted", unconfirmed, "accounts that never confirmed their email", "ADMIN_DELETE_UNCONFIRMED_DAYS").unset(),
			fact("Marked unconfirmed after", plural(a.unconfirmedHours, "hour"), "", "ADMIN_UNCONFIRMED_HOURS").unset())
	}

	// metrics and checks
	metrics := configGroup{ID: "metrics", Title: "Metrics and checks"}
	prometheus := setting("Prometheus", "METRICS_TOKEN", "ADMIN_METRICS_TOKEN", "not set", "/metrics with this bearer token")
	if prometheus.Default {
		prometheus.Note = "/metrics off"
	}
	metrics.Rows = append(metrics.Rows, prometheus,
		setting("Metrics of the Sync server", "METRICS_LISTEN", "", ":8125", "statsd over UDP, inside the stack's network"),
		// (HEALTH_CHECK_SECONDS of the container: the tests' rounds, no setting of .env)
		fact("Health checks every", count("HEALTH_CHECK_SECONDS", "60", "second"), "the components, the blocks, the security history"),
		fact("Public checks", onText[publicChecks()], "every hour the public https URLs, their certificates and the sign-up gate", "ADMIN_PUBLIC_CHECK").unset(),
		fact("New releases", onText[updateChecks()], "every 12 hours on GitHub", "ADMIN_UPDATE_CHECK").unset())

	groups := []configGroup{public, syncGroup, accounts, limits, admin, email, alerts, backupGroup, maintenance, metrics}
	// the chart: the accounts' settings by the names of its values
	for _, g := range groups {
		for _, row := range g.Rows {
			for i, name := range row.Vars {
				row.Vars[i] = a.deployment.valueName(name)
			}
		}
	}
	data["Groups"] = groups
	data["Hints"] = a.configHints(r, status, components, backups)
	data["Errors"], data["Kubernetes"] = errs, a.deployment.Kubernetes()
	a.render(w, "config.html", data)
}

// configHints: what does not agree, found cheaply: the failing setup checks of the
// overview, then the settings against each other
func (a *App) configHints(r *http.Request, status *SyncStatus, components []Component, backups []BackupStatus) []attention {
	var hints []attention
	if a.sync != nil {
		for _, c := range a.setupChecks(r.Context(), status, components) {
			if !c.OK {
				hints = append(hints, attention{Text: c.Name + ": " + c.Text, Href: "/#setup-card", Link: "Setup checks"})
			}
		}
	}
	fxa := a.fxa != nil
	// Firefox wants https, the public checks skip the rest
	urls := []string{"SYNCSTORAGE_DOMAIN"}
	if fxa {
		urls = append(urls, "FXA_CONTENT_URL", "FXA_AUTH_URL", "FXA_PROFILE_URL")
	}
	for _, name := range urls {
		if v := configLookup(name); v != "" && httpsURL(v) == nil && !loopbackURL(v) {
			hints = append(hints, attention{Text: fmt.Sprintf("%s is %s, not an https:// URL: Firefox needs https (other than on localhost), and the public checks skip it.", a.deployment.valueName(dotenvName(name)), v), Href: "#public-settings", Link: "Public URLs"})
		}
	}
	// docs/reverse-proxy.md#host-names-and-ports: one host name each, the proxy sends each of them to another port
	hosts := map[string]string{}
	for _, name := range urls {
		u, err := url.Parse(configLookup(name))
		if err != nil || u.Host == "" {
			continue
		}
		host := strings.ToLower(u.Host)
		if other, ok := hosts[host]; ok {
			hints = append(hints, attention{Text: fmt.Sprintf("%s and %s are both on %s: the Sync server, the accounts pages, the accounts API and the profile server need a host name each, the reverse proxy sends each to another port.", other, a.deployment.valueName(dotenvName(name)), u.Host), Href: "#public-settings", Link: "Public URLs"})
		} else {
			hosts[host] = a.deployment.valueName(dotenvName(name))
		}
	}
	if v := configLookup("FXA_PAIRING_URL"); fxa && v != "" && !strings.HasPrefix(v, "wss://") {
		hints = append(hints, attention{Text: "FXA_PAIRING_URL is " + v + ", not a wss:// URL: Firefox pairs over secure WebSockets.", Href: "#public-settings", Link: "Public URLs"})
	}
	if fxa {
		// docs/reverse-proxy.md#host-names-and-ports: the email domain is the host of the accounts API
		if auth := httpsURL(configLookup("FXA_AUTH_URL")); auth != nil && a.emailDomain != "" && a.emailDomain != strings.ToLower(auth.Hostname()) {
			hints = append(hints, attention{Text: fmt.Sprintf("FXA_EMAIL_DOMAIN is %s, but the accounts API (FXA_AUTH_URL) is %s: it must be its host name.", a.emailDomain, auth.Hostname()), Href: "#sync-settings", Link: "Sync server"})
		}
		// the Sync server must check the sign-ins with these accounts' keys
		if oauth, err := url.Parse(configLookup("FXA_OAUTH_SERVER_URL")); err == nil && oauth.Hostname() != "" {
			host := oauth.Hostname()
			auth := httpsURL(configLookup("FXA_AUTH_URL"))
			if !strings.HasSuffix(host, "fxa-auth") && (auth == nil || host != auth.Hostname()) {
				hints = append(hints, attention{Text: fmt.Sprintf("FXA_OAUTH_SERVER_URL is %s, not the accounts of this server: the Sync server refuses their sign-ins. With self-hosted accounts: http://fxa-auth:9000/v1.", oauth.Redacted()), Href: "#sync-settings", Link: "Sync server"})
			}
		}
	}
	// docs/reverse-proxy.md#the-admin-ui: the header only with the admin UI published on a loopback address
	if configLookup("ADMIN_AUTH_HEADER") != "" {
		if port := shown("ADMIN_EXPORT_PORT", "127.0.0.1:8090"); !loopbackPort(port) {
			hints = append(hints, attention{Text: fmt.Sprintf("Sign-in with a trusted header, and ADMIN_EXPORT_PORT is %s, not a loopback address: through the port forwarders every client can arrive from your proxy's address and send the header itself. Publish on 127.0.0.1, or use OpenID Connect.", port), Href: "#admin-settings", Link: "Admin UI"})
		}
	}
	if a.auth.oidc != nil && a.auth.oidc.trustUnverified && (!fxa || strings.TrimSuffix(configLookup("ADMIN_OIDC_ISSUER"), "/") != a.contentURL) {
		hints = append(hints, attention{Text: "ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL=true with another provider than the self-hosted accounts: whoever can set an address there can become that admin.", Href: "#admin-settings", Link: "Admin UI"})
	}
	if a.auth.insecureCookie {
		hints = append(hints, attention{Text: "ADMIN_INSECURE_COOKIE is set: the session cookie also goes over plain HTTP, where anybody on the way can take it.", Href: "#admin-settings", Link: "Admin UI"})
	}
	if configLookup("ALERT_EMAIL") != "" && !a.alerter.emails() {
		text := "ADMIN_ALERT_EMAIL is set, but there is no SMTP server (FXA_SMTP_HOST): no alert is sent."
		if a.alerter != nil {
			text = "ADMIN_ALERT_EMAIL is set, but there is no SMTP server (FXA_SMTP_HOST): no alert email is sent, the alerts go to ADMIN_NOTIFY only."
		}
		hints = append(hints, attention{Text: text, Href: "#email-settings", Link: "Email"})
	}
	for _, name := range a.alerter.InsecureNames() {
		hints = append(hints, attention{Text: "ADMIN_NOTIFY sends " + name + " its token over plain http (+http) to a host outside the local network: anybody on the way can read it and post there. Use https (the scheme without +http).", Href: "#alerts-settings", Link: "Alerts"})
	}
	if state, text := backupTile(backups, time.Now()); a.health != nil && state != "ok" {
		hints = append(hints, attention{Text: "Backups: " + strings.ToLower(text[:1]) + text[1:] + ".", Href: "/#backups-card", Link: "Backups"})
	}
	return hints
}
