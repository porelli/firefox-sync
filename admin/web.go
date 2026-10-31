package main

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"embed"
	"encoding/hex"
	"errors"
	"fmt"
	"html/template"
	"log"
	"math"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
	_ "time/tzdata"
)

//go:embed templates/*.html static/*
var assets embed.FS

var templates = template.Must(template.New("").Funcs(template.FuncMap{
	"date":  func(t time.Time) string { return formatTime(t, adminZone) },
	"when":  func(t time.Time) string { return whenIn(t, adminZone) },
	"zone":  func() string { return adminZone.String() },
	"bytes": humanBytes,
	"email": breakEmail,
	// to the millisecond, for <time datetime>: the pages show minutes
	"stamp": func(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05.000Z07:00") },
	// routine: an admin's own sign-in, muted in the event log
	"routine": func(e Event) bool { return e.Kind == "admin" && strings.HasPrefix(e.Detail, adminSignIn) },
	// page: the title and nav entry of a page for the layout, with the page's data
	"page": func(title, current string, data any) map[string]any {
		return map[string]any{"Title": title, "Current": current, "Data": data}
	},
}).ParseFS(assets, "templates/*.html"))

// breakEmail: the email escaped, with line breaks allowed after the @ and before each
// dot, so a long one wraps at its parts and not in the middle of a word. The escaped
// text has no @ or dot of its own (entities are &#34; and the like)
func breakEmail(s string) template.HTML {
	e := template.HTMLEscapeString(s)
	e = strings.ReplaceAll(e, "@", "@<wbr>")
	return template.HTML(strings.ReplaceAll(e, ".", "<wbr>."))
}

// adminZone: the times of the pages and the alerts, ADMIN_TZ (or TZ), UTC by default.
// Set once at the start, before anything is shown or sent
var adminZone = time.UTC

const timeLayout = "2006-01-02 15:04"

func formatTime(t time.Time, zone *time.Location) string {
	return t.In(zone).Format(timeLayout)
}

func whenIn(t time.Time, zone *time.Location) string {
	if t.IsZero() {
		return "never"
	}
	return formatTime(t, zone)
}

// loadZone reads ADMIN_TZ, then TZ: a name of the tz database (Europe/Rome), which
// the program carries itself (time/tzdata, the image has none)
func loadZone() *time.Location {
	name := env("ADMIN_TZ", env("TZ", ""))
	if name == "" {
		return time.UTC
	}
	zone, err := time.LoadLocation(name)
	if err != nil {
		log.Printf("warning: time zone %q: %v, showing times in UTC", name, err)
		return time.UTC
	}
	return zone
}

const (
	sessionCookie   = "ffs_admin"
	sessionLifetime = 12 * time.Hour
	// failed password sign-ins allowed per minute, for everybody: the password is
	// the only secret
	loginFailuresPerMinute = 5
)

type session struct {
	csrf    string
	expires time.Time
	// who signed in (the email, "" with the password) and how: password, oidc, header
	user, method string
	// result of the last change, shown once on the dashboard
	message, failed string
}

type App struct {
	sync    *SyncDB
	storage *StorageDB // nil if the storage database is not configured
	fxa     *FxaDB     // nil without self-hosted accounts
	rec     *Recorder
	health  *Health
	alerter *Alerter // nil without email alerts (ALERT_EMAIL and SMTP_HOST) and ADMIN_NOTIFY
	mailer  *Mailer  // notices to account owners, nil without SMTP_HOST
	// FXA_CONTENT_URL: the accounts pages, for the links shown and sent
	contentURL string
	auth       *authConfig
	// ADMIN_STALE_DAYS, ADMIN_UNCONFIRMED_HOURS
	staleDays, unconfirmedHours int
	// MAX_USERS=initial:N: max users is set on the dashboard, otherwise by .env; the same
	// for FXA_MAX_ACCOUNTS (also when not given: initial:unlimited)
	maxUsersEditable, maxAccountsEditable bool
	// BACKUP_TIME, BACKUP_KEEP of the backup service, for its help on the overview
	backupTime string
	backupKeep int
	// ADMIN_DEPLOYMENT: the commands of compose, the Quadlets or the Helm chart there
	deployment deployment
	// the token of the gate's answer to the public check (public.go), new on every start
	gateProbe string
	// SYNCSTORAGE_DOMAIN, FXA_EMAIL_DOMAIN, FXA_PAIRING_URL: the setup checks and the device steps
	syncDomain, emailDomain, pairingURL string
	// ADMIN_PURGE=1, ADMIN_DELETE_UNCONFIRMED_DAYS (0: off), ADMIN_SIGNUP_BURST (0: off)
	autoPurge                    bool
	unconfirmedDays, signupBurst int
	// FXA_ACCOUNT_EVENTS: the accounts service records the security history (securityevents.go)
	accountEvents bool
	// second passes on the storage of deleted accounts (lifecycle.go)
	passes passes

	mu       sync.Mutex
	sessions map[string]*session
	failures []time.Time
	invites  []time.Time // sent in the last hour
}

func serve(ctx context.Context) error {
	auth, err := loadAuth()
	if err != nil {
		return err
	}
	// checked here, not on the first page load or in a background ticker
	if _, err := envSwitch("SMTP_INSECURE_AUTH"); err != nil {
		return err
	}
	for _, name := range []string{"HEALTH_CHECK_SECONDS", "METRICS_FLUSH_SECONDS", "ALERT_INTERVAL_SECONDS"} {
		if envInt(name, 1) < 1 {
			return fmt.Errorf("%s must be 1 or more", name)
		}
	}
	// the destinations of the alerts besides email: a wrong one stops here, never with its token
	notifyTargets, err := parseNotify(env("ADMIN_NOTIFY", ""))
	if err != nil {
		return err
	}
	staleDays, unconfirmedHours := envInt("ADMIN_STALE_DAYS", 90), envInt("ADMIN_UNCONFIRMED_HOURS", 72)
	unconfirmedDays, signupBurst := 0, envInt("ADMIN_SIGNUP_BURST", 10)
	if env("ADMIN_DELETE_UNCONFIRMED_DAYS", "") != "" {
		// never the accounts of people still waiting for their code: a day at least
		if unconfirmedDays = envInt("ADMIN_DELETE_UNCONFIRMED_DAYS", 0); unconfirmedDays < 1 {
			return fmt.Errorf("ADMIN_DELETE_UNCONFIRMED_DAYS must be 1 or more (empty: off)")
		}
	}
	autoPurge := env("ADMIN_PURGE", "") == "1"
	deploy, err := loadDeployment()
	if err != nil {
		return err
	}
	eventsSetting, eventsSet := os.LookupEnv("FXA_ACCOUNT_EVENTS")
	adminZone = loadZone()
	syncDB, err := openSyncDB()
	if err != nil {
		return err
	}
	fxaDB, err := openFxaDB()
	if err != nil {
		return err
	}
	storageDB, err := openStorageDB(syncDB)
	if err != nil {
		return err
	}
	// before the admin UI writes there (PostgreSQL)
	if err := syncDB.checkOwnDB(ctx); err != nil {
		return err
	}
	rec, err := newRecorder(ctx, syncDB)
	if err != nil {
		if syncDB.own != nil {
			return fmt.Errorf("metrics and event tables in the admin UI's database %s (ADMIN_DB_*, see docs/reference/database-users.md#the-admin-uis-own-database): %w", syncDB.ownName, err)
		}
		return fmt.Errorf("metrics and event tables in the tokenserver database: %w", err)
	}
	// the tables of an install from before ADMIN_DB_PASSWORD, into the admin UI's own database
	syncDB.moved = syncDB.moveOwnTables(ctx)
	if syncDB.moved.Copied != nil {
		rec.Event("update", fmt.Sprintf("Moved the admin UI's tables of the tokenserver database into %s, out of the Sync server's reach: %s",
			syncDB.ownName, copiedSummary(syncDB.moved.Copied)))
	} else if syncDB.own == nil {
		log.Printf("ADMIN_DB_PASSWORD is not set: the event log is in the tokenserver database, which the Sync server's user can change (%s)",
			ownDBHint(deploy))
	}
	go rec.run(ctx)
	go func() {
		if err := rec.listen(ctx, env("METRICS_LISTEN", ":8125")); err != nil {
			log.Printf("metrics: %v", err)
		}
	}()
	app := &App{sync: syncDB, storage: storageDB, fxa: fxaDB, rec: rec, auth: auth, sessions: map[string]*session{},
		staleDays: staleDays, unconfirmedHours: unconfirmedHours, maxUsersEditable: maxUsersEditable(os.Getenv("MAX_USERS")),
		maxAccountsEditable: limitEditable(os.Getenv("FXA_MAX_ACCOUNTS"), true),
		backupTime:          env("BACKUP_TIME", "03:00"), backupKeep: envInt("BACKUP_KEEP", 7), deployment: deploy,
		gateProbe: randomToken(), syncDomain: strings.TrimSuffix(env("SYNCSTORAGE_DOMAIN", ""), "/"),
		emailDomain: strings.ToLower(env("FXA_EMAIL_DOMAIN", "")), pairingURL: env("FXA_PAIRING_URL", ""),
		autoPurge: autoPurge, unconfirmedDays: unconfirmedDays, signupBurst: signupBurst,
		accountEvents: fxaDB != nil && accountEventsOn(eventsSetting, eventsSet)}
	app.alerter = newAlerter(notifyTargets)
	if names := app.alerter.NotifyNames(); len(names) > 0 {
		log.Printf("alerts also to %s (ADMIN_NOTIFY)", strings.Join(names, ", "))
	}
	for _, name := range app.alerter.InsecureNames() {
		log.Printf("ADMIN_NOTIFY: %s sends its token over plain http to a host outside the local network: use https", name)
	}
	fallbackSender := ""
	if to := env("ALERT_EMAIL", ""); to != "" {
		fallbackSender = "firefox-sync admin <" + to + ">"
	}
	app.mailer, app.contentURL = newMailer(fallbackSender), strings.TrimSuffix(env("FXA_CONTENT_URL", ""), "/")
	if app.alerter != nil {
		go app.alerter.run(ctx)
	}
	app.health = newHealth(app)

	servers := []*http.Server{{
		Addr:              env("ADMIN_LISTEN", ":8080"),
		Handler:           app.routes(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
	}}
	if fxaDB != nil {
		upstream, err := url.Parse(env("FXA_AUTH_UPSTREAM", "http://fxa-auth:9000"))
		if err != nil {
			return fmt.Errorf("FXA_AUTH_UPSTREAM: %w", err)
		}
		servers = append(servers, &http.Server{
			Addr:              env("GATE_LISTEN", ":8081"),
			Handler:           newGate(upstream, env("FXA_CONTENT_URL", ""), fxaDB, func(kind, detail string) { app.event(kind, detail) }, app.gateProbe),
			ReadHeaderTimeout: 10 * time.Second,
		})
	}

	// listening before the first health check: it asks the gate through the reverse proxy
	errs := make(chan error, len(servers))
	for _, s := range servers {
		ln, err := net.Listen("tcp", s.Addr)
		if err != nil {
			return err
		}
		log.Printf("listening on %s", s.Addr)
		go func() { errs <- s.Serve(ln) }()
	}
	go app.health.run(ctx)
	go app.maintain(ctx)
	select {
	case err := <-errs:
		return err
	case <-ctx.Done():
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		for _, s := range servers {
			s.Shutdown(shutdown)
		}
		return nil
	}
}

func (a *App) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok\n")) })
	mux.Handle("GET /static/", http.FileServerFS(assets))
	mux.HandleFunc("GET /login", a.loginPage)
	mux.HandleFunc("POST /login", a.login)
	mux.HandleFunc("GET /auth/login", a.oidcLogin)
	mux.HandleFunc("GET "+callbackPath, a.oidcCallback)
	mux.HandleFunc("POST /logout", a.authenticated(a.logout))
	mux.HandleFunc("GET /{$}", a.authenticated(a.dashboard))
	mux.HandleFunc("GET /users/{uid}", a.authenticated(a.userPage))
	mux.HandleFunc("GET /activity", a.authenticated(a.activityPage))
	mux.HandleFunc("GET /security", a.authenticated(a.securityPage))
	mux.HandleFunc("POST /security/unblock", a.authenticated(a.unblock))
	mux.HandleFunc("POST /users/{uid}/devices/{id}/sign-out", a.authenticated(a.signOutDevice))
	mux.HandleFunc("POST /users/{uid}/sessions/{ref}/sign-out", a.authenticated(a.signOutSession))
	mux.HandleFunc("GET /metrics", a.prometheus)
	mux.HandleFunc("POST /sync/max-users", a.authenticated(a.setMaxUsers))
	mux.HandleFunc("POST /accounts/signups", a.authenticated(a.setSignups))
	mux.HandleFunc("POST /accounts/max-accounts", a.authenticated(a.setMaxAccounts))
	mux.HandleFunc("POST /accounts/{uid}/disable", a.authenticated(a.setDisabled(true)))
	mux.HandleFunc("POST /accounts/{uid}/enable", a.authenticated(a.setDisabled(false)))
	mux.HandleFunc("POST /accounts/{uid}/sign-out-all", a.authenticated(a.signOutAll))
	mux.HandleFunc("POST /accounts/{uid}/remove-totp", a.authenticated(a.removeSignInMethod("remove-totp")))
	mux.HandleFunc("POST /accounts/{uid}/remove-recovery-key", a.authenticated(a.removeSignInMethod("remove-recovery-key")))
	mux.HandleFunc("POST /accounts/{uid}/confirm-email", a.authenticated(a.confirmEmail))
	mux.HandleFunc("POST /users/{uid}/note", a.authenticated(a.setNote))
	mux.HandleFunc("POST /alerts/test", a.authenticated(a.testEmail))
	mux.HandleFunc("POST /alerts/test-notification", a.authenticated(a.testNotify))
	mux.HandleFunc("POST "+invitePath, a.authenticated(a.invite))
	mux.HandleFunc("POST /accounts/allowlist/remove", a.authenticated(a.removeFromAllowlist))
	mux.HandleFunc("GET /connect", a.authenticated(a.connectPage))
	mux.HandleFunc("GET /config", a.authenticated(a.configPage))
	mux.HandleFunc("GET /find", a.authenticated(a.find))
	mux.HandleFunc("POST /users/{uid}/reset-sync", a.authenticated(a.resetSync))
	mux.HandleFunc("POST /users/{uid}/delete", a.authenticated(a.deleteAccount))
	mux.HandleFunc("POST /storage/purge", a.authenticated(a.purgeNow))
	mux.HandleFunc("POST /maintenance/prune", a.authenticated(a.pruneNow))
	mux.HandleFunc("POST /accounts/unconfirmed", a.authenticated(a.deleteUnconfirmed))
	// what a destructive action will do, with its form: never one click away (confirm.go)
	mux.HandleFunc("GET /accounts/{uid}/{action}", a.authenticated(a.confirmAccount))
	mux.HandleFunc("GET /users/{uid}/devices/{id}/sign-out", a.authenticated(a.confirmDevice))
	mux.HandleFunc("GET /users/{uid}/sessions/{ref}/sign-out", a.authenticated(a.confirmSession))
	mux.HandleFunc("GET /users/{uid}/reset-sync", a.authenticated(a.confirmSyncAction("reset-sync")))
	mux.HandleFunc("GET /users/{uid}/delete", a.authenticated(a.confirmSyncAction("delete")))
	mux.HandleFunc("GET /storage/purge", a.authenticated(a.confirmPurge))
	mux.HandleFunc("GET /accounts/unconfirmed", a.authenticated(a.confirmUnconfirmed))
	mux.HandleFunc("GET /maintenance/prune", a.authenticated(a.confirmPrune))
	mux.HandleFunc("GET /accounts/allowlist/remove", a.authenticated(a.confirmAllowlistRemove))
	return securityHeaders(a.errorPages(mux))
}

// errorPages: the text errors of http.Error and http.NotFound as a page with the nav and
// a way back, for browsers (text/html in Accept); scripts get the text as before
func (a *App) errorPages(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.Contains(r.Header.Get("Accept"), "text/html") {
			next.ServeHTTP(w, r)
			return
		}
		e := &errorWriter{ResponseWriter: w}
		next.ServeHTTP(e, r)
		if e.code == 0 {
			return
		}
		data := map[string]any{"Code": e.code, "Text": strings.TrimSpace(e.text.String()), "CSRF": ""}
		// the nav for a signed-in admin: nothing is checked or changed here
		if s := a.peekSession(r); s != nil {
			data["CSRF"], data["User"], data["FxA"], data["Status"] = s.csrf, s.user, a.fxa != nil, a.healthSummary()
		}
		h := w.Header()
		h.Set("Content-Type", "text/html; charset=utf-8")
		w.WriteHeader(e.code)
		a.render(w, "error.html", data)
	})
}

// errorWriter keeps a text error (code 400 and up) for errorPages, passes the rest on
type errorWriter struct {
	http.ResponseWriter
	code int
	text strings.Builder
}

func (e *errorWriter) WriteHeader(code int) {
	if e.code == 0 && code >= 400 && strings.HasPrefix(e.Header().Get("Content-Type"), "text/plain") {
		e.code = code
		return
	}
	e.ResponseWriter.WriteHeader(code)
}

func (e *errorWriter) Write(b []byte) (int, error) {
	if e.code != 0 {
		return e.text.Write(b)
	}
	return e.ResponseWriter.Write(b)
}

// peekSession: the password or single sign-on session of the cookie, if live, without
// the checks of a proxy's headers (an error page shows no data of its own)
func (a *App) peekSession(r *http.Request) *session {
	c, err := r.Cookie(sessionCookie)
	if err != nil {
		return nil
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if s := a.sessions[c.Value]; s != nil && s.method != "header" && time.Now().Before(s.expires) {
		return s
	}
	return nil
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy", "default-src 'none'; style-src 'self'; img-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}

func randomToken() string {
	b := make([]byte, 32)
	rand.Read(b)
	return hex.EncodeToString(b)
}

// equal compares secrets in constant time
func equal(a, b string) bool {
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

// sameOrigin refuses cross-site form posts (on top of the CSRF token and the
// SameSite=Strict cookie)
func sameOrigin(r *http.Request) bool {
	if site := r.Header.Get("Sec-Fetch-Site"); site != "" && site != "same-origin" && site != "none" {
		return false
	}
	if origin := r.Header.Get("Origin"); origin != "" && origin != "null" {
		u, err := url.Parse(origin)
		if err != nil || u.Host != r.Host {
			return false
		}
	}
	return true
}

func (a *App) render(w http.ResponseWriter, name string, data any) {
	if err := templates.ExecuteTemplate(w, name, data); err != nil {
		log.Printf("rendering %s: %v", name, err)
	}
}

// event records in the activity log, when there is one (not in the unit tests), and
// sends an alert for what is worth one; the error: not recorded (the alert is sent)
func (a *App) event(kind, detail string) error {
	var err error
	if a.rec != nil {
		err = a.rec.Event(kind, detail)
	}
	if alertKinds[kind] {
		a.alert(kind, detail)
	}
	return err
}

type accountRow struct {
	UID       string
	Email     string
	Verified  bool
	CreatedAt time.Time
	Disabled  bool
	Sync      bool
	Usage     Usage
	// not synced for ADMIN_STALE_DAYS, never confirmed the email after 3 days
	Stale, Unconfirmed bool
	Note               string
	Security           Security
	// blocked by the rate limits now
	Blocked bool
	// devices not used for ADMIN_STALE_DAYS
	InactiveDevices int
}

type syncUserRow struct {
	SyncUser
	Usage Usage
	Stale bool
	Note  string
}

// usage of the current storage of each account (by FxA uid)
func (a *App) usage(ctx context.Context, users []SyncUser) (map[string]Usage, error) {
	usage := map[string]Usage{}
	if a.storage == nil {
		return usage, nil
	}
	totals, err := a.storage.Totals(ctx)
	if err != nil {
		return usage, err
	}
	for _, u := range users {
		usage[u.UID] = totals[u.StorageID]
	}
	return usage, nil
}

// the badges the accounts list can show alone (the links of Needs attention)
var accountFilters = map[string]func(accountRow) bool{
	"unconfirmed":         func(r accountRow) bool { return r.Unconfirmed },
	"unconfirmed-sign-in": func(r accountRow) bool { return r.Security.UnverifiedSessions > 0 },
	"blocked":             func(r accountRow) bool { return r.Blocked },
	"inactive":            func(r accountRow) bool { return r.Stale },
	"inactive-devices":    func(r accountRow) bool { return r.InactiveDevices > 0 },
}

// what the list shows with each filter: "3 accounts <label>" (ADMIN_STALE_DAYS: the days)
var filterLabels = map[string]string{
	"unconfirmed": "that never confirmed their email", "unconfirmed-sign-in": "with an unconfirmed sign-in",
	"blocked": "blocked by the rate limits", "inactive": "not synced for ADMIN_STALE_DAYS", "inactive-devices": "with devices not used for ADMIN_STALE_DAYS",
}

func (a *App) dashboard(w http.ResponseWriter, r *http.Request, s *session) {
	ctx := r.Context()
	data := a.base(s)
	var errs []string
	now := time.Now()

	// the search of the accounts list (?q=, ?show=), its pages (?page=)
	query := r.URL.Query()
	shownQ := oneLine(strings.TrimSpace(query.Get("q")), 255)
	q := strings.ToLower(shownQ)
	show := query.Get("show")
	// (the badges are those of the self-hosted accounts)
	if _, ok := accountFilters[show]; !ok || a.fxa == nil {
		show = ""
	}
	page, _ := strconv.Atoi(query.Get("page"))
	// in plain words: "not synced for 90 days"
	label := strings.ReplaceAll(filterLabels[show], "ADMIN_STALE_DAYS", plural(a.staleDays, "day"))
	data["Q"], data["Show"], data["ShowLabel"] = shownQ, show, label
	// back from removing an entry of the allowlist: its list open
	data["ListOpen"] = query.Get("list") == "open"
	// the account of q as a tokenserver uid, or as any of its emails
	var matchID string
	if q != "" {
		var err error
		if id, e := strconv.ParseInt(q, 10, 64); e == nil && id > 0 {
			matchID, err = a.sync.UserByStorageID(ctx, id)
		}
		if matchID == "" && err == nil && a.fxa != nil && strings.Contains(q, "@") {
			matchID, err = a.fxa.UIDByEmail(ctx, q)
		}
		if err != nil {
			errs = append(errs, "Search: "+err.Error())
		}
	}

	status, err := a.sync.Status(ctx)
	if err != nil {
		errs = append(errs, "Sync database: "+err.Error())
	}
	data["Sync"], data["MaxUsersEditable"] = status, a.maxUsersEditable
	// the limit's form opens by itself once it is close
	data["NearMaxUsers"] = nearMaxUsers(status)
	// FXA_MAX_ACCOUNTS, the accounts against it
	var accountLimit *Limit
	if a.fxa != nil {
		if l, err := a.fxa.AccountLimit(ctx); err != nil {
			errs = append(errs, "Max accounts: "+err.Error())
		} else {
			accountLimit = &l
			data["AccountLimit"] = l
		}
		data["MaxAccountsEditable"] = a.maxAccountsEditable
	}
	var components []Component
	var backups []BackupStatus
	var certs map[string]time.Time
	if a.health != nil {
		// the rows of the limits as read now: the table, the light and Needs attention agree
		var syncLimit *Limit
		if status != nil {
			l := status.Limit()
			syncLimit = &l
		}
		a.health.setLimits(syncLimit, accountLimit)
		// with the Sync metrics row when they are missing: the table, the counters and
		// Needs attention of the same rows
		var shown []Component
		components, shown, data["Status"] = a.healthTable()
		backups, certs = a.health.Backups(), a.health.Certs()
		data["Health"], data["Sizes"], data["Schema"], data["Backups"] = shown, a.health.Sizes(), a.health.Schema(), backups
		data["SetupMigrations"] = a.health.Setup()
		data["BackupState"], data["BackupText"] = backupTile(backups, now)
	}
	var alerts *SendStatus
	if a.alerter.emails() {
		st := a.alerter.Status()
		alerts = &st
		data["Alerts"] = map[string]any{"To": a.alerter.to, "Status": st, "Waiting": a.alerter.Waiting()}
	}
	data["Notify"] = a.alerter.NotifyStatuses()
	// a test email goes to ADMIN_ALERT_EMAIL, or to the admin of single sign-on
	data["TestEmail"] = a.mailer != nil && (a.alerter.emails() || s.method == "oidc")
	setup := a.setupChecks(ctx, status, components)
	// the checks fold to a line while they all pass, open with a failing one
	warnings := 0
	for _, c := range setup {
		if !c.OK {
			warnings++
		}
	}
	data["Setup"], data["SetupWarnings"] = setup, warnings
	staleBefore := now.AddDate(0, 0, -a.staleDays)
	data["StaleDays"] = a.staleDays
	syncUsers, err := a.sync.Users(ctx)
	if err != nil {
		errs = append(errs, "Sync users: "+err.Error())
	}
	inSync := map[string]bool{}
	for _, u := range syncUsers {
		inSync[u.UID] = true
	}
	usage, err := a.usage(ctx, syncUsers)
	if err != nil {
		errs = append(errs, "Sync storage: "+err.Error())
	}
	notes, err := a.sync.Notes(ctx)
	if err != nil {
		errs = append(errs, "Notes: "+err.Error())
	}

	in := attentionInput{now: now, components: components, certs: certs, status: status, backups: backups, fxa: a.fxa != nil,
		staleDays: a.staleDays, alerts: alerts, accountLimit: accountLimit, deployment: a.deployment}
	if a.health != nil {
		in.setup = a.health.Setup()
	}
	data["Backup"] = a.backupHelp(now)
	var pages pager
	if a.fxa != nil {
		if policy, err := a.fxa.Policy(ctx); err != nil {
			errs = append(errs, "Sign-up policy: "+err.Error())
		} else {
			data["Policy"] = policy
			data["Allowlist"] = strings.Join(policy.Allowlist, "\n")
		}
		accounts, err := a.fxa.Accounts(ctx)
		if err != nil {
			errs = append(errs, "Accounts: "+err.Error())
		}
		if entries, err := a.fxa.AllowlistEntries(ctx); err != nil {
			errs = append(errs, "Allowlist: "+err.Error())
		} else {
			data["Invited"], data["Domains"] = allowRows(entries, accounts)
		}
		data["Mailer"] = a.mailer != nil
		security, err := a.fxa.Securities(ctx)
		if err != nil {
			errs = append(errs, "Sign-in security: "+err.Error())
		}
		blocks, complete, err := a.fxa.BlocksOf(ctx, accounts)
		if err != nil {
			errs = append(errs, "Rate limits: "+err.Error())
		} else if !complete {
			errs = append(errs, tooManyBlocks())
		}
		inactive, err := a.fxa.InactiveDevices(ctx, staleBefore)
		if err != nil {
			errs = append(errs, "Devices: "+err.Error())
		}
		rows := make([]accountRow, 0, len(accounts))
		var stale, unconfirmed int
		for _, acc := range accounts {
			row := accountRow{UID: acc.UID, Email: acc.Email, Verified: acc.Verified, CreatedAt: acc.CreatedAt, Disabled: acc.Disabled, Sync: inSync[acc.UID], Usage: usage[acc.UID],
				Note: notes[acc.UID].Text, Security: security[acc.UID], Blocked: len(blocksOf(blocks, &acc)) > 0, InactiveDevices: inactive[acc.UID]}
			row.Stale = row.Sync && row.Usage.LastModified.Before(staleBefore) && row.CreatedAt.Before(staleBefore)
			row.Unconfirmed = !acc.Verified && acc.CreatedAt.Before(now.Add(-time.Duration(a.unconfirmedHours)*time.Hour))
			if row.Stale {
				stale++
			}
			if row.Unconfirmed {
				unconfirmed++
			}
			rows = append(rows, row)
		}
		in.accounts, in.unconfirmed, in.inactiveDevices = rows, unconfirmed, inactive
		// newest first, those of the search
		matched := make([]accountRow, 0, len(rows))
		for i := len(rows) - 1; i >= 0; i-- {
			if row := rows[i]; matchAccount(q, row.UID, row.Email, row.Note, matchID) && (show == "" || accountFilters[show](row)) {
				matched = append(matched, row)
			}
		}
		var from, to int
		pages, from, to = newPager(len(matched), page, shownQ, show)
		data["Accounts"], data["StaleCount"], data["UnconfirmedCount"] = matched[from:to], stale, unconfirmed
		notVerified := 0
		for _, row := range rows {
			if !row.Verified {
				notVerified++
			}
		}
		data["AccountCount"], data["NotVerified"] = len(rows), notVerified
	} else {
		// Mozilla's accounts: the tokenserver only knows the account ids
		rows := make([]syncUserRow, 0, len(syncUsers))
		for i := len(syncUsers) - 1; i >= 0; i-- {
			u := syncUsers[i]
			if !matchAccount(q, u.UID, "", notes[u.UID].Text, matchID) {
				continue
			}
			stale := usage[u.UID].LastModified.Before(staleBefore) && u.CreatedAt.Before(staleBefore)
			rows = append(rows, syncUserRow{u, usage[u.UID], stale, notes[u.UID].Text})
		}
		var from, to int
		pages, from, to = newPager(len(rows), page, shownQ, "")
		data["SyncUsers"], data["AccountCount"] = rows[from:to], len(syncUsers)
	}
	data["Pages"] = pages
	if a.storage != nil {
		var report *StorageReport
		if report, err = a.storageReport(ctx); err != nil {
			errs = append(errs, "Storage report: "+err.Error())
		}
		data["Storage"], in.storage = report, report
	}
	if a.fxa != nil {
		if in.pruneLastRan, err = a.fxa.PruneLastRan(ctx); err != nil {
			errs = append(errs, "Accounts pruning: "+err.Error())
		}
		data["PruneLastRan"], data["UnconfirmedDays"] = in.pruneLastRan, a.unconfirmedDays
	}
	data["Attention"] = needsAttention(in)
	data["Errors"] = errs
	data["Kubernetes"] = a.deployment.Kubernetes()
	a.render(w, "dashboard.html", data)
}

func (a *App) done(w http.ResponseWriter, r *http.Request, s *session, message string, err error) {
	a.doneTo(w, r, s, "/", message, err)
}

// base is the data of every page: the form token, whether there are self-hosted
// accounts, and the result of the last change (shown once)
func (a *App) base(s *session) map[string]any {
	status := a.healthSummary()
	a.mu.Lock()
	defer a.mu.Unlock()
	data := map[string]any{"CSRF": s.csrf, "FxA": a.fxa != nil, "User": s.user, "Message": s.message, "Failed": s.failed, "Status": status}
	s.message, s.failed = "", ""
	return data
}

// healthSummary: the health light of every page and the Health tile of the overview,
// from the last round of checks (nothing is checked here)
type healthSummary struct {
	Total, Up, Down, Warn int
	// what is wrong, the first of each: "Sync server", "Sign-up gate"
	FirstDown, FirstWarn string
}

// healthTable: the rows of the last round (with the Sync metrics row when they are
// missing), those of the health table (not the hidden setup checks) and their counts
func (a *App) healthTable() (rows, shown []Component, status *healthSummary) {
	rows = a.healthRows()
	for _, c := range rows {
		if !c.Hidden {
			shown = append(shown, c)
		}
	}
	return rows, shown, summarize(rows)
}

func (a *App) healthSummary() *healthSummary {
	if a.health == nil {
		return nil
	}
	return summarize(a.healthRows())
}

// summarize: the counts of the rows of the health table (a.healthRows), the hidden setup
// checks only when they fail
func summarize(rows []Component) *healthSummary {
	h := &healthSummary{}
	for _, c := range rows {
		switch {
		case c.Up:
		case c.Warn:
			h.Warn++
			if h.FirstWarn == "" {
				h.FirstWarn = c.Name
			}
		default:
			h.Down++
			if h.FirstDown == "" {
				h.FirstDown = c.Name
			}
		}
		// the hidden ones are setup checks, the limits no parts: in the count only when
		// they fail
		quiet := c.Hidden || c.Limit
		if !quiet || !c.Up {
			h.Total++
		}
		if c.Up && !quiet {
			h.Up++
		}
	}
	return h
}

// backupTile: the Backups tile of the overview, ok, warn (stale or none) or bad (failed)
func backupTile(backups []BackupStatus, now time.Time) (state, text string) {
	if len(backups) == 0 {
		return "warn", "None recorded yet"
	}
	state, text = "ok", "Up to date"
	for _, b := range backups {
		switch b.state(now) {
		case "failed":
			return "bad", "Failed " + ago(now.Sub(b.Last.Finished))
		case "stale":
			state, text = "warn", "Last good one "+ago(now.Sub(b.LastOK.Finished))
		}
	}
	return state, text
}

// ago: "3 hours ago", "2 days ago"
func ago(d time.Duration) string {
	switch {
	case d < time.Hour:
		return "just now"
	case d < 48*time.Hour:
		return plural(int(d/time.Hour), "hour") + " ago"
	}
	return plural(int(d/(24*time.Hour)), "day") + " ago"
}

// doneTo shows the result of a change on the next page, and records it with who made
// it (and the reason given on a confirm page, if any). The record is written before the
// redirect: the audit trail has it when the admin sees the result (a page read right after
// lists it, a restart cannot lose it), and the admin is told when it could not be written.
func (a *App) doneTo(w http.ResponseWriter, r *http.Request, s *session, to, message string, err error) {
	var partial *partialError
	detail, failed := "", ""
	switch {
	case errors.As(err, &partial):
		detail = auditText(s, message+" ("+err.Error()+")", r.PostFormValue("reason"))
		failed = a.deployment.translate(err.Error())
	case err != nil:
		log.Printf("%s: %v", r.URL.Path, err)
		message, failed = "", a.deployment.translate(err.Error())
	default:
		detail = auditText(s, message, r.PostFormValue("reason"))
	}
	if detail != "" {
		log.Printf("%s: %s", r.URL.Path, detail)
		if err := a.event("admin", detail); err != nil {
			failed = strings.TrimSpace(failed + " " + notRecorded(err))
		}
	}
	a.mu.Lock()
	s.message, s.failed = message, failed
	a.mu.Unlock()
	http.Redirect(w, r, to, http.StatusSeeOther)
}

// notRecorded: what the admin is told when the record of a change is not in the event log
func notRecorded(err error) string {
	return "Done, but not recorded in the event log (the audit trail): " + err.Error() + ". The admin UI's log has it."
}

// auditText: "Disabled alice@example.com (uid 3f2a1b2c) by bob@example.com (oidc): lost laptop"
func auditText(s *session, message, reason string) string {
	text := message + " by " + auditWho(s)
	if reason = strings.TrimSpace(reason); reason != "" {
		text += ": " + oneLine(reason, maxReason)
	}
	return text
}

const maxReason = 200

// auditWho: "alice@example.com (oidc)", "admin (password)" with the password: nobody in particular
func auditWho(s *session) string {
	who := "admin"
	if s.user != "" {
		who = eventText(s.user)
	}
	return who + " (" + s.method + ")"
}

// accountLabel names an account in messages and events: its email and the start of
// its uid (emails can change, uids do not), or the whole uid when it has no account
func accountLabel(acc *FxaAccount, uid string) string {
	if acc == nil {
		return "account " + uid
	}
	short := acc.UID
	if len(short) > 8 {
		short = short[:8]
	}
	return fmt.Sprintf("%s (uid %s)", oneLine(acc.Email, 255), short)
}

// account is the account of the path's uid, for messages: nil if it cannot be found
func (a *App) account(r *http.Request, uid string) *FxaAccount {
	acc, err := a.fxa.Account(r.Context(), uid)
	if err != nil {
		log.Printf("%s: %v", r.URL.Path, err)
	}
	return acc
}

var errMaxUsersReadOnly = errors.New("max users is managed by SYNC_MAX_USERS in .env: set SYNC_MAX_USERS=initial:N there to manage it here")

// the same with the Helm chart
var errMaxUsersReadOnlyChart = errors.New("max users is managed by maxUsers in the chart's values: set maxUsers: initial:N there and helm upgrade to manage it here")

// maxUsersReadOnly: why max users cannot be changed here, as this deployment sets it
func (a *App) maxUsersReadOnly() error {
	if a.deployment.Kubernetes() != nil {
		return errMaxUsersReadOnlyChart
	}
	return errMaxUsersReadOnly
}

func (a *App) setMaxUsers(w http.ResponseWriter, r *http.Request, s *session) {
	if !a.maxUsersEditable {
		// the init container sets MAX_USERS again on its next start
		a.done(w, r, s, "", a.maxUsersReadOnly())
		return
	}
	n, unlimited, err := limitForm(r.PostFormValue("max_users"), r.PostFormValue("unlimited"))
	// the tokenserver triggers keep it in an INT
	if err != nil {
		a.done(w, r, s, "", fmt.Errorf("max users must be a number from 0 to %d, or no limit", math.MaxInt32))
		return
	}
	err = a.sync.SetMaxUsers(r.Context(), n, unlimited)
	if err == nil {
		a.refreshLimits(r.Context())
	}
	a.done(w, r, s, "Max users set to "+Limit{Max: n, Unlimited: unlimited}.Setting(), err)
}

var errMaxAccountsReadOnly = errors.New("max accounts is managed by FXA_MAX_ACCOUNTS in .env: set FXA_MAX_ACCOUNTS=initial:N there to manage it here")

// the same with the Helm chart
var errMaxAccountsReadOnlyChart = errors.New("max accounts is managed by fxa.maxAccounts in the chart's values: set fxa.maxAccounts: initial:N there and helm upgrade to manage it here")

// maxAccountsReadOnly: why max accounts cannot be changed here, as this deployment sets it
func (a *App) maxAccountsReadOnly() error {
	if a.deployment.Kubernetes() != nil {
		return errMaxAccountsReadOnlyChart
	}
	return errMaxAccountsReadOnly
}

// setMaxAccounts: FXA_MAX_ACCOUNTS of the self-hosted accounts, from the Sign-ups card
func (a *App) setMaxAccounts(w http.ResponseWriter, r *http.Request, s *session) {
	if a.fxa == nil {
		http.NotFound(w, r)
		return
	}
	if !a.maxAccountsEditable {
		// fxa-policy sets FXA_MAX_ACCOUNTS again on its next start
		a.doneTo(w, r, s, "/#signups", "", a.maxAccountsReadOnly())
		return
	}
	n, unlimited, err := limitForm(r.PostFormValue("max_accounts"), r.PostFormValue("unlimited"))
	if err != nil {
		a.doneTo(w, r, s, "/#signups", "", fmt.Errorf("max accounts must be a number from 0 to %d, or no limit", math.MaxInt32))
		return
	}
	err = a.fxa.SetMaxAccounts(r.Context(), n, unlimited)
	if err == nil {
		a.refreshLimits(r.Context())
	}
	a.doneTo(w, r, s, "/#signups", "Max accounts set to "+Limit{Max: n, Unlimited: unlimited}.Setting(), err)
}

func (a *App) setSignups(w http.ResponseWriter, r *http.Request, s *session) {
	if a.fxa == nil {
		http.NotFound(w, r)
		return
	}
	mode, err := ParseMode(r.PostFormValue("mode"))
	if err != nil {
		a.done(w, r, s, "", err)
		return
	}
	allowlist, err := ParseAllowlist(r.PostFormValue("allowlist"))
	if err != nil {
		a.done(w, r, s, "", err)
		return
	}
	// the list the page showed: an invitation made since then must stay
	var loaded []string
	if _, ok := r.PostForm["loaded"]; ok {
		if loaded, err = ParseAllowlist(r.PostFormValue("loaded")); err != nil {
			a.done(w, r, s, "", err)
			return
		}
		loaded = append([]string{}, loaded...)
	}
	p := &SignupPolicy{Mode: mode, Allowlist: allowlist}
	err = a.fxa.SetPolicy(r.Context(), p, loaded)
	a.done(w, r, s, "Sign-ups: "+describePolicy(p), err)
}

func (a *App) setDisabled(disabled bool) handler {
	return func(w http.ResponseWriter, r *http.Request, s *session) {
		if a.fxa == nil {
			http.NotFound(w, r)
			return
		}
		uid := strings.ToLower(r.PathValue("uid"))
		acc := a.account(r, uid)
		err := a.fxa.SetDisabled(r.Context(), uid, disabled)
		verb := "Enabled"
		if disabled {
			verb = "Disabled"
			var partial *partialError
			if reason := r.PostFormValue("reason"); (err == nil || errors.As(err, &partial)) && strings.TrimSpace(reason) != "" {
				if e := a.addToNote(r.Context(), uid, reason, s); e != nil && err == nil {
					err = &partialError{fmt.Errorf("account disabled, but the reason did not go into its note: %w", e)}
				}
			}
		}
		a.doneTo(w, r, s, backTo(r, "/"), verb+" "+accountLabel(acc, uid), err)
	}
}

func (a *App) signOutAll(w http.ResponseWriter, r *http.Request, s *session) {
	if a.fxa == nil {
		http.NotFound(w, r)
		return
	}
	uid := strings.ToLower(r.PathValue("uid"))
	acc := a.account(r, uid)
	err := a.fxa.SignOutAll(r.Context(), uid)
	a.doneTo(w, r, s, "/users/"+uid, "Signed out "+accountLabel(acc, uid)+" everywhere", err)
}

// backTo: the page a form came from (the field back of the confirm pages), a path of
// this site only
func backTo(r *http.Request, fallback string) string {
	if to := r.PostFormValue("back"); strings.HasPrefix(to, "/") && !strings.HasPrefix(to, "//") && !strings.ContainsAny(to, "\\\r\n") {
		return to
	}
	return fallback
}

// listenPort is the port of an ADMIN_LISTEN like :8080 or 0.0.0.0:8080
func listenPort(addr string) string {
	if _, port, err := net.SplitHostPort(addr); err == nil {
		return port
	}
	return addr
}

// backupHelp: what the backup service does, for the Backups card's help (the admin UI cannot
// see the volume); the accounts' scope only with the self-hosted accounts on their database of
// the stack (FXA_DB_HOST, accountsBackedUp)
func (a *App) backupHelp(now time.Time) map[string]any {
	return map[string]any{"Time": a.backupTime, "Local": localClock(a.backupTime, now, adminZone), "Keep": a.backupKeep,
		"Quadlets": a.deployment.Quadlets(), "Kubernetes": a.deployment.Kubernetes(),
		"Accounts": a.fxa != nil && a.deployment.accountsBackedUp(env("FXA_DB_HOST", "fxa-db"))}
}
