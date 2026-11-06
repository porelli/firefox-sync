package main

import (
	"database/sql"
	"net/url"
	"strings"
	"testing"
	"time"
)

func TestDomainMismatch(t *testing.T) {
	counts := map[string]int{"api.example.com": 3, "api.old.example": 2}
	if other := otherDomains("API.example.com", counts); len(other) != 1 || other["api.old.example"] != 2 {
		t.Errorf("other domains: %v", other)
	}
	c := domainCheck("api.example.com", counts, &SyncStatus{Users: 5, MaxUsers: 5})
	if c.OK || !strings.Contains(c.Text, "FXA_EMAIL_DOMAIN is api.example.com") || !strings.Contains(c.Text, "@api.old.example (2)") ||
		!strings.Contains(c.Text, "counts twice against max users (5 of 5 used)") {
		t.Errorf("mismatch: %+v", c)
	}
	if c := domainCheck("api.example.com", map[string]int{"api.example.com": 3}, nil); !c.OK || !strings.Contains(c.Text, "The 3 accounts") {
		t.Errorf("same domain: %+v", c)
	}
}

func TestNodeMismatch(t *testing.T) {
	nodes := []SyncNode{{Node: "https://old.example.com", Downed: true}, {Node: "https://sync.example.com/"}}
	if c := nodeCheck(deployment{}, "https://sync.example.com", nodes); !c.OK {
		t.Errorf("same node: %+v", c)
	}
	c := nodeCheck(deployment{}, "https://new.example.com", nodes)
	if c.OK || !strings.Contains(c.Text, "hands out https://sync.example.com, but SYNC_PUBLIC_URL is https://new.example.com") {
		t.Errorf("mismatch: %+v", c)
	}
	if c := nodeCheck(deployment{}, "https://sync.example.com", nodes[:1]); c.OK || !strings.Contains(c.Text, "no Sync node in use") {
		t.Errorf("none: %+v", c)
	}
}

// the old setting names compose found in .env (FFS_OLD_ENV_NAMES): a failing setup check
// that names them; none without them
func TestOldNamesCheck(t *testing.T) {
	if _, ok := oldNamesCheck(" "); ok {
		t.Error("a check without old names")
	}
	c, ok := oldNamesCheck("MAX_USERS SYNCSTORAGE_DOMAIN ")
	if !ok || c.OK || !strings.Contains(c.Text, "will be removed in a later release: MAX_USERS, SYNCSTORAGE_DOMAIN.") || !strings.Contains(c.Text, "./prepare_environment.sh --upgrade") {
		t.Errorf("old names: %+v", c)
	}
}

func TestSchemaChanges(t *testing.T) {
	stored := map[string]string{"Tokenserver": "2024-01-01-000000", "fxa": "200"}
	current := []SchemaLevel{{Database: "Tokenserver", Level: "2024-01-01-000000"}, {Database: "fxa", Level: "201"}, {Database: "fxa_oauth", Level: "40"}}
	store, events := schemaChanges(stored, current)
	if len(store) != 2 || store[0].Database != "fxa" || store[1].Database != "fxa_oauth" {
		t.Errorf("store: %+v", store)
	}
	// the first sight of a database is no change: one event
	if len(events) != 1 || events[0] != "Schema of the fxa database changed from 200 to 201" {
		t.Errorf("events: %q", events)
	}
	stored["fxa"], stored["fxa_oauth"] = "201", "40"
	if store, events := schemaChanges(stored, current); len(store)+len(events) != 0 {
		t.Errorf("again: %v %v", store, events)
	}
}

func TestSchemaLevelsView(t *testing.T) {
	view := schemaLevelsSQL([]string{"fxa", "fxa_oauth", "mysql"})
	if !strings.HasPrefix(view, "CREATE OR REPLACE SQL SECURITY DEFINER VIEW ffs.schema_levels AS SELECT 'fxa' AS db") ||
		strings.Count(view, "UNION ALL") != 1 || !strings.Contains(view, "FROM fxa_oauth.dbMetadata") || strings.Contains(view, "mysql") ||
		!strings.Contains(view, "'prune-last-ran'") {
		t.Errorf("view: %s", view)
	}
	// no dbMetadata at all: an empty view, fxa-policy goes on
	if view := schemaLevelsSQL(nil); !strings.Contains(view, "WHERE FALSE") {
		t.Errorf("empty: %s", view)
	}
	found := false
	for _, g := range fxaAdminGrants {
		found = found || g == "GRANT SELECT ON ffs.schema_levels TO 'ffs_admin'@'%'"
	}
	if !found {
		t.Error("no grant on ffs.schema_levels")
	}
}

func TestDeviceSteps(t *testing.T) {
	text := stepsText(deviceSteps("https://accounts.example.com", "https://sync.example.com", "wss://pairing.example.com"))
	for _, want := range []string{
		"set identity.fxaccounts.autoconfig.uri to https://accounts.example.com and restart Firefox",
		"tap the Firefox logo 5 times",
		"Custom Mozilla account server to https://accounts.example.com. Leave Custom Sync server empty",
		"Custom Account Content Server URI to https://accounts.example.com",
		"Connect another device", "wss://pairing.example.com",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("no %q in %s", want, text)
		}
	}
	// Mozilla's accounts: the tokenserver URL only
	text = stepsText(deviceSteps("", "https://sync.example.com", ""))
	if !strings.Contains(text, "identity.sync.tokenserver.uri and set it to https://sync.example.com/1.0/sync/1.5") || strings.Contains(text, "autoconfig") {
		t.Errorf("Mozilla's accounts: %s", text)
	}
	subject, body := inviteEmail("https://accounts.example.com", "https://sync.example.com", "", "bob+x@example.net", true)
	if subject != "Your Firefox Sync account on accounts.example.com" || !strings.Contains(body, "https://accounts.example.com/?email=bob%2Bx%40example.net") ||
		!strings.Contains(body, "Sign-ups are closed") || !strings.Contains(body, text[:0]+"identity.fxaccounts.autoconfig.uri") {
		t.Errorf("%s\n%s", subject, body)
	}
	if strings.Contains(body, "<") {
		t.Errorf("not plain text: %s", body)
	}
}

func TestInviteRateLimit(t *testing.T) {
	app := testApp()
	now := time.Now()
	for i := 0; i < invitesPerHour; i++ {
		if !app.inviteAllowed(now) {
			t.Fatalf("invite %d refused", i)
		}
	}
	if app.inviteAllowed(now) {
		t.Error("over the limit")
	}
	if !app.inviteAllowed(now.Add(time.Hour)) {
		t.Error("still refused an hour later")
	}
}

func TestInvite(t *testing.T) {
	server, _ := newFakeSMTP(t, false, false)
	smtpEnv(t, server)
	fake := &fakeFxa{}
	app := testApp()
	app.fxa, app.sync, app.mailer, app.alerter = fake.db("127.0.0.1:1"), &SyncDB{db: sql.OpenDB(fake)}, newMailer(""), &Alerter{}
	app.contentURL, app.syncDomain = "https://accounts.example.com", "https://sync.example.com"
	h := app.routes()
	c, s := passwordSession(t, app, h)
	app.alerter.take()
	post(h, invitePath, url.Values{"csrf": {s.csrf}, "email": {"Bob@Example.net"}}, c, nil)
	if s.message != "Invited bob@example.net (added to the sign-up allowlist), email sent" || s.failed != "" {
		t.Errorf("%q %q", s.message, s.failed)
	}
	added := false
	for i, stmt := range fake.statements() {
		added = added || strings.Contains(stmt, "INSERT IGNORE INTO ffs.signup_allowlist") && fake.args[i][0] == "bob@example.net"
	}
	if !added {
		t.Errorf("not on the allowlist: %q", fake.statements())
	}
	_, data := server.seen()
	if !strings.Contains(data, "To: bob@example.net\r\n") || !strings.Contains(data, "identity.fxaccounts.autoconfig.uri to https://accounts.example.com") ||
		!strings.Contains(data, "Content-Type: text/plain") {
		t.Errorf("email: %q", data)
	}
	if lines := alerts(t, app.alerter, 1); len(lines) != 1 || !strings.Contains(lines[0], "admin: Invited bob@example.net (added to the sign-up allowlist), email sent by admin (password)") {
		t.Errorf("event: %q", lines)
	}
	// closed: the steps, a warning, the allowlist untouched
	fake.mode = SignupsClosed
	n := len(fake.statements())
	post(h, invitePath, url.Values{"csrf": {s.csrf}, "email": {"carol@example.net"}}, c, nil)
	if !strings.Contains(s.failed, "sign-ups are closed: carol@example.net cannot create an account") || s.message != "Invited carol@example.net, email sent" {
		t.Errorf("closed: %q %q", s.message, s.failed)
	}
	for _, stmt := range fake.statements()[n:] {
		if strings.Contains(stmt, "signup_allowlist") {
			t.Errorf("allowlist changed: %s", stmt)
		}
	}
	// the email not sent: on the allowlist all the same, a partial failure, recorded
	alerts(t, app.alerter, 1) // carol's
	fake.mode = SignupsAllowlist
	t.Setenv("SMTP_PORT", "1")
	app.mailer = newMailer("")
	post(h, invitePath, url.Values{"csrf": {s.csrf}, "email": {"dave@example.net"}}, c, nil)
	added = false
	for i, stmt := range fake.statements() {
		added = added || strings.Contains(stmt, "INSERT IGNORE INTO ffs.signup_allowlist") && fake.args[i][0] == "dave@example.net"
	}
	if !added || s.message != "Invited dave@example.net (added to the sign-up allowlist)" ||
		!strings.Contains(s.failed, "the email was not sent (") || !strings.Contains(s.failed, "give them the steps of the Connect a device page") {
		t.Errorf("not sent: %v %q %q", added, s.message, s.failed)
	}
	if lines := alerts(t, app.alerter, 1); len(lines) != 1 || !strings.Contains(lines[0], "admin: Invited dave@example.net (added to the sign-up allowlist) (the email was not sent") {
		t.Errorf("not sent, event: %q", lines)
	}
	// over the limit: refused before the allowlist
	app.mu.Lock()
	app.invites = nil
	for i := 0; i < invitesPerHour; i++ {
		app.invites = append(app.invites, time.Now())
	}
	app.mu.Unlock()
	n = len(fake.statements())
	post(h, invitePath, url.Values{"csrf": {s.csrf}, "email": {"erin@example.net"}}, c, nil)
	if !strings.HasPrefix(s.failed, "at most") || s.message != "" {
		t.Errorf("over the limit: %q %q", s.message, s.failed)
	}
	for _, stmt := range fake.statements()[n:] {
		if strings.Contains(stmt, "signup_allowlist") {
			t.Errorf("allowlist changed over the limit: %s", stmt)
		}
	}
	// a list of addresses, a header: refused
	for _, bad := range []string{"a@example.net, b@example.net", "Bob <bob@example.net>", "x@y\r\nBcc: z@example.net"} {
		s.message = ""
		post(h, invitePath, url.Values{"csrf": {s.csrf}, "email": {bad}}, c, nil)
		if !strings.HasPrefix(s.failed, "not an email") || s.message != "" {
			t.Errorf("%q: %q %q", bad, s.message, s.failed)
		}
	}
}

func TestAllowRows(t *testing.T) {
	added := time.Unix(1700000000, 0)
	emails, domains := allowRows([]AllowEntry{{"@example.com", added}, {"alice@example.com", added}, {"bob@example.net", added}},
		[]FxaAccount{{UID: fakeUID, Email: "Alice@Example.com", CreatedAt: added.Add(time.Hour)}})
	if len(domains) != 1 || domains[0] != "@example.com" || len(emails) != 2 {
		t.Fatalf("%v %v", emails, domains)
	}
	if emails[0].UID != fakeUID || emails[0].SignedUp.IsZero() || !emails[1].SignedUp.IsZero() {
		t.Errorf("%+v", emails)
	}
}

// a save from a page loaded before an invitation keeps the invitation: only what the
// page showed can be removed
func TestAllowlistRemovals(t *testing.T) {
	current := []string{"@example.com", "alice@example.net", "bob@example.net"}
	for _, c := range []struct {
		loaded, submitted []string
		want              string
	}{
		{[]string{"@example.com", "alice@example.net"}, []string{"@example.com"}, "alice@example.net"},
		{[]string{"@example.com", "alice@example.net"}, nil, "@example.com alice@example.net"},
		{[]string{}, nil, ""},
		{nil, []string{"@example.com"}, "alice@example.net bob@example.net"},
	} {
		if got := strings.Join(allowlistRemovals(current, c.loaded, c.submitted), " "); got != c.want {
			t.Errorf("loaded %q, submitted %q: %q, want %q", c.loaded, c.submitted, got, c.want)
		}
	}
}

func TestRemoveMissingAllowlistEntry(t *testing.T) {
	fake := &fakeFxa{none: func(q string) bool { return strings.HasPrefix(q, "DELETE FROM ffs.signup_allowlist") }}
	app := testApp()
	app.fxa, app.sync, app.alerter = fake.db("127.0.0.1:1"), &SyncDB{db: sql.OpenDB(fake)}, &Alerter{}
	h := app.routes()
	c, s := passwordSession(t, app, h)
	app.alerter.take()
	post(h, "/accounts/allowlist/remove", url.Values{"csrf": {s.csrf}, "entry": {"Nobody@example.net"}}, c, nil)
	if s.failed != `"nobody@example.net" is not on the allowlist` || s.message != "" {
		t.Errorf("%q %q", s.message, s.failed)
	}
	if lines := alerts(t, app.alerter, 1); len(lines) != 0 {
		t.Errorf("recorded: %q", lines)
	}
}
