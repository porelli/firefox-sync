package main

import (
	"database/sql"
	"database/sql/driver"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"testing"
	"time"
)

// limitsApp: an overview on the fake databases, with the limits given
func limitsApp(t *testing.T, fake *fakeFxa) (*App, http.Handler, *http.Cookie, *session) {
	t.Helper()
	if fake.nodes == nil {
		fake.nodes = [][]driver.Value{}
	}
	redis, _ := fakeRedis(t)
	app := testApp()
	// its own database: the setup checks all pass (owndb.go)
	app.fxa, app.sync, app.alerter = fake.db(redis), &SyncDB{db: sql.OpenDB(fake), own: sql.OpenDB(fake), ownName: "ffs_admin"}, &Alerter{}
	app.health = newHealth(app)
	// the accounts' SMTP server, after newHealth: no SMTP check to run
	t.Setenv("SMTP_HOST", "smtp.example.com")
	h := app.routes()
	c, s := passwordSession(t, app, h)
	app.alerter.take()
	return app, h, c, s
}

func TestLimitsOnTheOverview(t *testing.T) {
	// max users unlimited, the accounts full
	fake := &fakeFxa{maxUsers: "unlimited", syncUsers: 4, maxAccounts: "1", accountCount: 1}
	app, h, c, _ := limitsApp(t, fake)
	app.maxAccountsEditable = true
	page := getPage(h, "/", c).Body.String()
	for _, want := range []string{
		// the tiles
		`<strong id="sync-users">4</strong> <small>accounts, no limit</small>`, `SYNC_MAX_USERS=<span id="sync-max-users">unlimited</span>`,
		`<span class="value">1 <small>of 1 allowed</small></span>`, "full: sign-ups are refused",
		// the Sync card and its form: no number required, the box checked
		"4 accounts use this Sync server, with no limit", `<input id="max_users" name="max_users" type="number" min="0" max="2147483647" disabled>`,
		`<input type="checkbox" name="unlimited" value="1" checked disabled>`,
		// the Sign-ups card: the count, the pill, the form open and editable
		`<span id="fxa-accounts">1</span> of <span id="fxa-max-accounts">1</span> accounts created; sign-ups are refused now. <span class="pill warn">full</span>`,
		`<details class="fold" open>
  <summary>Change the limit</summary>
  <form method="post" action="/accounts/max-accounts"`, `value="1" required aria-describedby="max-accounts-mode">`,
		// Needs attention, with the link to the form
		`1 of 1 accounts are created (FXA_MAX_ACCOUNTS): sign-ups are refused until it is raised. <a href="#signups">Max accounts</a>`,
		// the health rows: the full one counted by the light, the other shown with its count
		`<td>Max accounts</td><td><span class="pill warn">full</span>`, `<td>Max users</td><td><span class="ok">up</span> <span class="hint">4 accounts, no limit</span>`,
		`<span class="n">1</span><span class="word"><span class="part"> part</span> to check</span>`,
	} {
		if !strings.Contains(page, want) {
			t.Errorf("overview: no %q", want)
		}
	}
	// the light of the other pages: the rows the overview read
	if light := getPage(h, "/connect", c).Body.String(); !strings.Contains(light, `<span class="n">1</span><span class="word"><span class="part"> part</span> to check</span>`) {
		t.Error("the light of the other pages")
	}

	// near the limit of max users, the accounts unlimited (not set: no row)
	fake.maxUsers, fake.syncUsers, fake.maxAccounts = "10", 9, ""
	app.maxAccountsEditable = false
	page = getPage(h, "/", c).Body.String()
	for _, want := range []string{
		`of <span id="sync-max-users">10</span> places taken`, `near the limit: 90% or more taken`, `<span class="pill warn">near the limit</span>`,
		`9 of 10 accounts are taken (90% or more): new accounts are refused by the Sync server once all are. <a href="#sync">Max users</a>`,
		`<td>Max users</td><td><span class="pill warn">near the limit</span>`, `<td>Max accounts</td><td><span class="ok">up</span> <span class="hint">1 account, no limit</span>`,
		`<code>FXA_MAX_ACCOUNTS=<span id="fxa-max-accounts">unlimited</span></code>`, "New accounts are refused once all are; accounts already here keep working.",
		// read-only: FXA_MAX_ACCOUNTS=N in .env
		`<input type="checkbox" name="unlimited" value="1" checked disabled>`, "set <code>FXA_MAX_ACCOUNTS=initial:unlimited</code> to manage it here",
	} {
		if !strings.Contains(page, want) {
			t.Errorf("near: no %q", want)
		}
	}
	if strings.Contains(page, "of 1 allowed") || strings.Contains(page, "sign-ups are refused until") {
		t.Error("near: the accounts still full")
	}
	// all fine: no line, the rows up and not counted as parts
	fake.syncUsers = 2
	page = getPage(h, "/", c).Body.String()
	if strings.Contains(page, "90%") || strings.Contains(page, "pill warn") || !strings.Contains(page, `<span class="hint">2 of 10 taken</span>`) {
		t.Errorf("room: %s", page)
	}
	if status := summarize(app.healthRows()); status.Warn != 0 || status.Total != status.Up {
		t.Errorf("room: counted %+v", status)
	}
	// max users full: refused now, not "once all are"
	fake.syncUsers = 10
	page = getPage(h, "/", c).Body.String()
	if !strings.Contains(page, "New accounts are refused now; raise the limit to let more in. Accounts already here keep working.") || strings.Contains(page, "refused once all are") {
		t.Error("max users full: not refused now")
	}
}

func TestLimitRowsCountOnlyWhenNearOrFull(t *testing.T) {
	rows := []Component{{Name: "Sync server", Up: true}}
	rows = append(rows, limitRows(&Limit{Count: 1, Max: 10}, &Limit{Count: 5, Unlimited: true})...)
	if s := summarize(rows); s.Total != 1 || s.Up != 1 || s.Warn != 0 {
		t.Errorf("fine: %+v", s)
	}
	rows = append(rows[:1], limitRows(&Limit{Count: 10, Max: 10}, &Limit{Count: 9, Max: 10})...)
	if s := summarize(rows); s.Total != 3 || s.Up != 1 || s.Warn != 2 || s.FirstWarn != "Max users" {
		t.Errorf("full and near: %+v", s)
	}
	if rows[1].Label != "full" || rows[2].Label != "near the limit" || !strings.Contains(rows[2].Error, "9 of 10 accounts are created (90% or more)") {
		t.Errorf("rows: %+v", rows)
	}
	// max users 0: nobody new on purpose, fine
	if row := syncLimit.row(Limit{Count: 3}); !row.Up || row.Detail != "3 accounts, no new ones (SYNC_MAX_USERS 0)" {
		t.Errorf("0: %+v", row)
	}
}

func TestNeedsAttentionLimits(t *testing.T) {
	now := time.Now()
	for _, c := range []struct {
		name       string
		change     func(*attentionInput)
		href, text string
	}{
		{"max users full", func(in *attentionInput) { in.status.Users = 10 }, "#sync", "10 of 10 accounts are taken (SYNC_MAX_USERS): new accounts are refused by the Sync server until it is raised."},
		{"max accounts near", func(in *attentionInput) { in.accountLimit = &Limit{Count: 45, Max: 50} }, "#signups", "45 of 50 accounts are created (90% or more): sign-ups are refused once all are."},
		{"max accounts full", func(in *attentionInput) { in.accountLimit = &Limit{Count: 50, Max: 50} }, "#signups", "50 of 50 accounts are created (FXA_MAX_ACCOUNTS)"},
	} {
		in := allGood(now)
		c.change(&in)
		got := needsAttention(in)
		if len(got) != 1 || got[0].Href != c.href || !strings.Contains(got[0].Text, c.text) {
			t.Errorf("%s: %+v", c.name, got)
		}
	}
	in := allGood(now)
	in.status, in.accountLimit = &SyncStatus{Users: 1000, Unlimited: true}, &Limit{Count: 1000, Unlimited: true}
	if got := needsAttention(in); len(got) != 0 {
		t.Errorf("unlimited: %+v", got)
	}
}

func TestSetLimitsFromThePage(t *testing.T) {
	fake := &fakeFxa{}
	app, h, c, s := limitsApp(t, fake)
	app.maxUsersEditable, app.maxAccountsEditable = true, true
	// "No limit" wins over the number
	post(h, "/sync/max-users", url.Values{"csrf": {s.csrf}, "max_users": {"5"}, "unlimited": {"1"}}, c, nil)
	if s.message != "Max users set to unlimited" || s.failed != "" {
		t.Errorf("max users: %q %q", s.message, s.failed)
	}
	post(h, "/sync/max-users", url.Values{"csrf": {s.csrf}, "max_users": {"7"}}, c, nil)
	w := post(h, "/accounts/max-accounts", url.Values{"csrf": {s.csrf}, "max_accounts": {"50"}}, c, nil)
	if w.Header().Get("Location") != "/#signups" || s.message != "Max accounts set to 50" {
		t.Errorf("max accounts: %s %q %q", w.Header().Get("Location"), s.message, s.failed)
	}
	// without a number the box must be checked; typed "unlimited" works for scripts
	post(h, "/accounts/max-accounts", url.Values{"csrf": {s.csrf}, "max_accounts": {""}}, c, nil)
	if !strings.Contains(s.failed, "max accounts must be a number from 0 to 2147483647, or no limit") {
		t.Errorf("empty: %q", s.failed)
	}
	post(h, "/accounts/max-accounts", url.Values{"csrf": {s.csrf}, "max_accounts": {"unlimited"}}, c, nil)
	var got []string
	for i, q := range fake.statements() {
		got = append(got, q+" "+fake.args[i][0].(string))
	}
	want := []string{
		"CALL ffs_set_max_users(?) unlimited",
		"CALL ffs_set_max_users(?) 7",
		"INSERT INTO ffs.settings (name, value) VALUES ('max_accounts', ?) ON DUPLICATE KEY UPDATE value = VALUES(value) 50",
		"INSERT INTO ffs.settings (name, value) VALUES ('max_accounts', ?) ON DUPLICATE KEY UPDATE value = VALUES(value) unlimited",
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("statements:\n%s", strings.Join(got, "\n"))
	}
	// (recorded in the background: in any order)
	lines := alerts(t, app.alerter, 4)
	if len(lines) != 4 || !strings.Contains(strings.Join(lines, "\n"), "admin: Max accounts set to 50 by admin (password)\n") &&
		!strings.HasSuffix(strings.Join(lines, "\n"), "admin: Max accounts set to 50 by admin (password)") {
		t.Errorf("alerts: %q", lines)
	}
	// FXA_MAX_ACCOUNTS=N in .env: read-only, nothing changes
	app.maxAccountsEditable = false
	post(h, "/accounts/max-accounts", url.Values{"csrf": {s.csrf}, "max_accounts": {"9"}}, c, nil)
	if !strings.Contains(s.failed, "managed by FXA_MAX_ACCOUNTS in .env") || len(fake.statements()) != 4 {
		t.Errorf("read-only: %q", s.failed)
	}
}

func TestLimitMetrics(t *testing.T) {
	fake := &fakeFxa{nodes: [][]driver.Value{}, maxUsers: "unlimited", syncUsers: 3, maxAccounts: "10", accountCount: 9}
	app := testApp()
	app.sync, app.fxa = &SyncDB{db: sql.OpenDB(fake)}, fake.db("")
	out := prometheusText(t, app)
	for _, want := range []string{"ffs_sync_accounts 3\n", "ffs_sync_near_max_users 0\n", "ffs_sync_full 0\n",
		"ffs_accounts 9\n", "ffs_accounts_max 10\n", "ffs_accounts_near_max 1\n", "ffs_accounts_full 0\n"} {
		if !strings.Contains(out, want) {
			t.Errorf("no %q", want)
		}
	}
	// no limit: nothing to compare with
	if strings.Contains(out, "ffs_sync_max_users") {
		t.Error("ffs_sync_max_users with MAX_USERS=unlimited")
	}
	fake.maxUsers, fake.accountCount = "3", 10
	out = prometheusText(t, app)
	for _, want := range []string{"ffs_sync_max_users 3\n", "ffs_sync_near_max_users 1\n", "ffs_sync_full 1\n", "ffs_accounts_full 1\n"} {
		if !strings.Contains(out, want) {
			t.Errorf("full: no %q", want)
		}
	}
}

func TestGateSaysTheServerIsFull(t *testing.T) {
	events := make(chan string, 1)
	// nothing listens upstream: a refusal never gets there
	u, _ := url.Parse("http://127.0.0.1:1")
	gate := newGate(u, "", &fakeChecker{full: true}, func(kind, detail string) { events <- kind + ": " + detail }, "")
	w := create(gate, "/v1/account/create", `{"email":"carol@example.com"}`)
	if w.Code != http.StatusBadRequest || !strings.Contains(w.Body.String(), `"errno":125`) || !strings.Contains(w.Body.String(), "This server is full") {
		t.Errorf("full: %d %s", w.Code, w.Body)
	}
	if got := <-events; got != "sign-up refused: carol@example.com (the server is full: FXA_MAX_ACCOUNTS)" {
		t.Errorf("event: %q", got)
	}
	// the policy's refusal keeps its words
	w = create(newGate(u, "", &fakeChecker{}, nil, ""), "/v1/account/create", `{"email":"carol@example.com"}`)
	if !strings.Contains(w.Body.String(), "Sign-ups are restricted on this server") {
		t.Errorf("policy: %s", w.Body)
	}
}

func TestApplyEnvMaxAccounts(t *testing.T) {
	for _, c := range []struct{ env, statement, value string }{
		{"fixed:5", "ON DUPLICATE KEY UPDATE", "5"},
		{"5", "ON DUPLICATE KEY UPDATE", "5"},
		{"unlimited", "ON DUPLICATE KEY UPDATE", "unlimited"},
		{"initial:7", "INSERT IGNORE", "7"},
		// not set: no limit unless one was set, then the admin UI manages it
		{"", "INSERT IGNORE", "unlimited"},
	} {
		t.Setenv("FXA_MAX_ACCOUNTS", c.env)
		fake := &fakeFxa{maxAccounts: c.value}
		if err := applyEnvMaxAccounts(t.Context(), sql.OpenDB(fake)); err != nil {
			t.Fatalf("%q: %v", c.env, err)
		}
		got := fake.statements()
		if len(got) != 1 || !strings.Contains(got[0], c.statement) || fake.args[0][0] != c.value {
			t.Errorf("%q: %q %v", c.env, got, fake.args)
		}
	}
	for _, bad := range []string{"lots", "initial:", "-1", "2147483648"} {
		t.Setenv("FXA_MAX_ACCOUNTS", bad)
		fake := &fakeFxa{}
		if err := applyEnvMaxAccounts(t.Context(), sql.OpenDB(fake)); err == nil || !strings.Contains(err.Error(), "FXA_MAX_ACCOUNTS=") || len(fake.statements()) != 0 {
			t.Errorf("%q: %v %q", bad, err, fake.statements())
		}
	}
}

func TestSignupRefusalSQL(t *testing.T) {
	sql := strings.Join(fxaPolicySQL, "\n")
	for _, want := range []string{
		// the gate's question and the trigger's: the same function
		"CREATE FUNCTION ffs.signup_refusal(address VARCHAR(255)) RETURNS VARCHAR(16)",
		"RETURN ffs.signup_refusal(address) IS NULL",
		"SET refusal = ffs.signup_refusal(NEW.normalizedEmail);",
		// the limit, read without a warning when there is none
		"SET max_accounts = (SELECT value FROM ffs.settings WHERE name = 'max_accounts');",
		"max_accounts <> 'unlimited'", ">= CAST(max_accounts AS UNSIGNED)",
		// sign-ups one at a time on its row
		"SELECT value INTO locked FROM ffs.settings WHERE name = 'max_accounts' FOR UPDATE;",
		"'Sign-up refused: the server is full (FXA_MAX_ACCOUNTS)'",
	} {
		if !strings.Contains(sql, want) {
			t.Errorf("no %q", want)
		}
	}
	if !strings.Contains(strings.Join(fxaAdminGrants, "\n"), "GRANT EXECUTE ON FUNCTION ffs.signup_refusal TO 'ffs_admin'@'%'") {
		t.Error("ffs_admin cannot ask ffs.signup_refusal")
	}
	// dropped before what calls it is created again
	drop, create := -1, -1
	for i, s := range fxaPolicySQL {
		if s == "DROP FUNCTION IF EXISTS ffs.signup_refusal" {
			drop = i
		}
		if strings.HasPrefix(s, "CREATE FUNCTION ffs.signup_allowed") {
			create = i
		}
	}
	if drop < 0 || create < drop {
		t.Errorf("order: %d %d", drop, create)
	}
}

func TestConfirmPruneAndAllowlistRemove(t *testing.T) {
	fake := &fakeFxa{answer: func(query string, _ []driver.Value) *fakeRows {
		if strings.Contains(query, "FROM ffs.signup_allowlist ORDER BY created_at") {
			return &fakeRows{cols: []string{"entry", "at"}, rows: [][]driver.Value{{"bob@example.net", int64(1700000000)}, {"@example.com", int64(0)}}}
		}
		return nil
	}}
	_, h, c, s := limitsApp(t, fake)
	for path, wants := range map[string][]string{
		"/maintenance/prune": {"<h1>Prune the accounts database?</h1>", `<form method="post" action="/maintenance/prune" id="confirm">`,
			`href="/activity#maintenance" id="cancel">Cancel</a>`, "older than 30 days", `<a href="/activity" aria-current="page">`},
		"/accounts/allowlist/remove?entry=Bob@example.net": {"<h1>Remove bob@<wbr>example<wbr>.net?</h1>", `<form method="post" action="/accounts/allowlist/remove" id="confirm">`,
			`<input type="hidden" name="entry" value="bob@example.net">`, "An account already created with it stays", `href="/?list=open#invitations" id="cancel">Cancel</a>`, `<input type="hidden" name="back" value="/?list=open#invitations">`, "<span>Invitations</span>"},
		"/accounts/allowlist/remove?entry=@example.com": {"nobody with an email of example.com can create an account any more", `value="@example.com"`, `href="/?list=open#signups" id="cancel">Cancel</a>`, "<span>Sign-ups</span>"},
	} {
		w := getPage(h, path, c)
		page := w.Body.String()
		if w.Code != 200 {
			t.Fatalf("%s: %d %s", path, w.Code, page)
		}
		for _, want := range append(wants, `name="csrf" value="`+s.csrf+`"`, `<label for="reason">`) {
			if !strings.Contains(page, want) {
				t.Errorf("%s: no %q", path, want)
			}
		}
	}
	// pages only: nothing ran
	if got := fake.statements(); len(got) != 0 {
		t.Errorf("a GET changed something: %q", got)
	}
	if w := getPage(h, "/accounts/allowlist/remove?entry=nobody@example.net", c); w.Code != 404 {
		t.Errorf("not on the list: %d", w.Code)
	}
	// the POST does it, back to the page of the confirm page
	w := post(h, "/accounts/allowlist/remove", url.Values{"csrf": {s.csrf}, "entry": {"bob@example.net"}, "back": {"/#signups"}, "reason": {"left"}}, c, nil)
	if w.Header().Get("Location") != "/#signups" || s.message != "Removed bob@example.net from the sign-up allowlist" {
		t.Errorf("remove: %s %q %q", w.Header().Get("Location"), s.message, s.failed)
	}
	// back there, the lists open: the emails and the domains; closed otherwise
	emails, domains := "<details class=\"fold\" open>\n  <summary>Emails on the list", "<details class=\"fold\" open>\n  <summary>Change who can sign up"
	if page := getPage(h, "/?list=open", c).Body.String(); !strings.Contains(page, emails) || !strings.Contains(page, domains) {
		t.Error("?list=open: the lists closed")
	}
	if page := getPage(h, "/", c).Body.String(); strings.Contains(page, emails) || strings.Contains(page, domains) {
		t.Error("the lists open without ?list=open")
	}
}

func TestFormsOfThePages(t *testing.T) {
	p := pages(t)
	// destructive: a link to the confirm page, never a form in the list
	if list := p["dashboard.html"]; strings.Contains(list, `action="/accounts/allowlist/remove"`) ||
		!strings.Contains(list, `href="/accounts/allowlist/remove?entry=bob%40example.net"`) || !strings.Contains(list, `href="/accounts/allowlist/remove?entry=%40example.com"`) {
		t.Error("allowlist: Remove in one click")
	}
	if !strings.Contains(p["dashboard.html"], `action="/alerts/test-notification"`) {
		t.Error("no Send a test notification")
	}
	if activity := p["activity.html"]; strings.Contains(activity, `action="/maintenance/prune"`) || !strings.Contains(activity, `<a href="/maintenance/prune" class="button secondary" id="prune">`) {
		t.Error("prune in one click")
	}
	// every other form posts one of these: not destructive, one click (docs/admin/README.md#confirm-pages)
	oneClick := map[string]bool{"/logout": true, "/login": true, "/accounts/signups": true, "/accounts/invite": true, "/alerts/test": true,
		"/alerts/test-notification": true, "/health/check": true, "/sync/max-users": true, "/accounts/max-accounts": true, "/security/unblock": true, "/x": true}
	action := regexp.MustCompile(`<form method="post" action="([^"]+)"`)
	for name, page := range p {
		for _, m := range action.FindAllStringSubmatch(page, -1) {
			a := m[1]
			if oneClick[a] || strings.HasSuffix(a, "/enable") || strings.HasSuffix(a, "/note") {
				continue
			}
			t.Errorf("%s: a form posts %s: needs a confirm page, or a reason in docs/admin/README.md#confirm-pages", name, a)
		}
	}
}

func TestBackupTimeInTheZoneOfThePages(t *testing.T) {
	rome, _ := time.LoadLocation("Europe/Rome")
	summer := time.Date(2026, 7, 1, 12, 0, 0, 0, time.UTC)
	for _, c := range []struct {
		utc  string
		zone *time.Location
		want string
	}{{"03:00", time.UTC, "03:00"}, {"03:00", rome, "05:00"}, {"23:30", rome, "01:30"}, {"soon", rome, "soon"}} {
		if got := localClock(c.utc, summer, c.zone); got != c.want {
			t.Errorf("%s in %s: %s", c.utc, c.zone, got)
		}
	}
}

func TestNavAndSchemaAndBackups(t *testing.T) {
	p := pages(t)
	page := p["dashboard.html"]
	// Connect a device last, apart: still an item of the list
	nav := page[strings.Index(page, `<nav aria-label="Pages">`):]
	nav = nav[:strings.Index(nav, "</nav>")]
	items := regexp.MustCompile(`<li( class="[^"]+")?><a href="([^"]+)"`).FindAllStringSubmatch(nav, -1)
	if len(items) != 5 || items[4][2] != "/connect" || items[4][1] != ` class="nav-apart"` || items[2][2] != "/security" || items[3][2] != "/config" {
		t.Errorf("nav: %q", items)
	}
	// FxA records no time
	if !strings.Contains(page, `<td>fxa</td><td>201</td><td><span class="quiet-text">not recorded by FxA</span></td>`) {
		t.Error("schema: no 'not recorded by FxA'")
	}
	// what the backups are, when, how many, where
	for _, want := range []string{"Every night at 03:00 UTC (<code>BACKUP_TIME</code>)", "The newest 7 runs are kept (<code>BACKUP_KEEP</code>)",
		"and the accounts databases into the backups volume", "<code>docker compose exec backup sh /ffs-backup/backup.sh now</code>",
		"Add <code>backup</code> to <code>COMPOSE_PROFILES</code>", `href="https://github.com/porelli/firefox-sync/blob/main/docs/backups.md#restore"`, "Leave the Sync storage empty: each Firefox uploads its data again", "<dd>Every night at 03:00",
		"<code>sync/&lt;UTC time&gt;/&lt;database&gt;.sql.gz</code>"} {
		if !strings.Contains(page, want) {
			t.Errorf("backups: no %q", want)
		}
	}
	var b strings.Builder
	data := map[string]any{"CSRF": "x", "Health": []Component{{Name: "Sync server", Up: true}}, "Backup": map[string]any{"Time": "04:30", "Local": "06:30", "Keep": 3, "Quadlets": true}}
	if err := templates.ExecuteTemplate(&b, "dashboard.html", data); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"at 06:30 (<code>BACKUP_TIME=04:30</code>, in UTC)", "The newest 3 runs", "<code>systemctl --user enable --now firefox-sync-backup.timer</code>",
		"The Podman volume <code>firefox-sync-backups</code>", `<details class="fold" id="backup-help" open>`, "No backups recorded yet",
		// nothing recorded: what happens once it is on, not that it runs
		"Once the backup service is on, every night at 06:30", "<dd>Once it is on, every night at 06:30"} {
		if !strings.Contains(b.String(), want) {
			t.Errorf("Quadlets, no runs: no %q", want)
		}
	}
	if strings.Contains(b.String(), "Every night at") {
		t.Error("no runs: says it runs every night")
	}
	if strings.Contains(b.String(), "accounts databases") {
		t.Error("Quadlets without the accounts: the accounts databases")
	}
}
