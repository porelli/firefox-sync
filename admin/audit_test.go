package main

import (
	"database/sql"
	"database/sql/driver"
	"errors"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/go-sql-driver/mysql"
)

func fakeRecorder(f *fakeFxa) *Recorder {
	return &Recorder{db: &SyncDB{db: sql.OpenDB(f)}, current: map[string]*metric{}, cumulative: map[string]*metric{}}
}

func inserted(f *fakeFxa, kind string) []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	var details []string
	for i, q := range f.execs {
		if strings.HasPrefix(q, "INSERT INTO ffs_events") && f.args[i][1] == kind {
			details = append(details, f.args[i][2].(string))
		}
	}
	return details
}

func TestAdminEventsAreNeverCapped(t *testing.T) {
	f := &fakeFxa{}
	r := fakeRecorder(f)
	for i := 0; i < 2*maxEventsPerMinute; i++ {
		r.Event("admin", "Enabled alice@example.com")
		r.Event("sign-up refused", "x@example.com")
	}
	if got := len(inserted(f, "admin")); got != 2*maxEventsPerMinute {
		t.Errorf("admin events recorded: %d", got)
	}
	if got := len(inserted(f, "sign-up refused")); got != maxEventsPerMinute {
		t.Errorf("refused sign-ups recorded: %d", got)
	}
}

func TestEventDetailCutOnACharacter(t *testing.T) {
	f := &fakeFxa{}
	r := fakeRecorder(f)
	// 511 bytes, then a character of 3: a byte cut at 512 would split it
	r.Event("admin", strings.Repeat("a", 511)+strings.Repeat("日", 50))
	got := inserted(f, "admin")
	if len(got) != 1 || len(got[0]) > 512 || !utf8.ValidString(got[0]) {
		t.Fatalf("%d bytes, valid %v", len(got[0]), utf8.ValidString(got[0]))
	}
}

func TestPartialChangeIsAudited(t *testing.T) {
	fake := &fakeFxa{}
	app := testApp()
	app.fxa, app.alerter, app.sync = fake.db("127.0.0.1:1"), &Alerter{}, &SyncDB{db: sql.OpenDB(fake)} // Redis down
	h := app.routes()
	c, s := passwordSession(t, app, h)
	app.alerter.take()
	post(h, "/accounts/"+fakeUID+"/disable", url.Values{"csrf": {s.csrf}, "reason": {"lost laptop"}}, c, nil)
	if !strings.Contains(s.failed, "account disabled, but") {
		t.Errorf("failure not shown: %q %q", s.message, s.failed)
	}
	lines := alerts(t, app.alerter, 1)
	if len(lines) != 1 || !strings.Contains(lines[0], "admin: Disabled alice@example.com (uid 0123abcd) (account disabled, but") ||
		!strings.HasSuffix(lines[0], "by admin (password): lost laptop") {
		t.Errorf("alerts: %q", lines)
	}
}

func policyStmt(t *testing.T, stmts []string, name string) string {
	t.Helper()
	for _, s := range stmts {
		if strings.HasPrefix(s, "CREATE PROCEDURE "+name+"(") {
			return s
		}
	}
	t.Fatalf("%s not created", name)
	return ""
}

func TestDisableSetsDisabledAtFirst(t *testing.T) {
	disable := policyStmt(t, fxaPolicySQL, "ffs.disable_account")
	if u, c := strings.Index(disable, "UPDATE fxa.accounts SET disabledAt"), strings.Index(disable, "CALL ffs.sign_out_all"); u < 0 || c < 0 || u > c {
		t.Errorf("disabledAt after signing out: %s", disable)
	}
	out := policyStmt(t, fxaPolicySQL, "ffs.sign_out_all")
	if c, r := strings.Index(out, "DELETE FROM fxa_oauth.codes"), strings.Index(out, "DELETE FROM fxa_oauth.refreshTokens"); c < 0 || r < 0 || c > r {
		t.Errorf("codes deleted after the refresh tokens: %s", out)
	}
}

func TestMissingFxaProcedureLeavesStandIns(t *testing.T) {
	stmts := policySQL([]string{"fxa.revokeAccountTokens_1"})
	if len(stmts) != len(fxaPolicySQL) {
		t.Fatal("statements lost")
	}
	for _, name := range []string{"ffs.sign_out_all", "ffs.disable_account"} {
		s := policyStmt(t, stmts, name)
		if strings.Contains(s, "CALL fxa.") || !strings.Contains(s, "SIGNAL SQLSTATE '45000'") || !strings.Contains(s, "fxa.revokeAccountTokens_1 is missing") {
			t.Errorf("%s: %s", name, s)
		}
	}
	// the rest as is: the sign-up policy keeps working
	for _, name := range []string{"ffs.enable_account", "ffs.remove_totp", "ffs.confirm_email"} {
		if policyStmt(t, stmts, name) != policyStmt(t, fxaPolicySQL, name) {
			t.Errorf("%s changed", name)
		}
	}
	// each pinned procedure stubs only what calls it
	stmts = policySQL([]string{"fxa.verifyEmail_9"})
	for _, stmt := range fxaPolicySQL {
		name, ok := strings.CutPrefix(strings.SplitN(stmt, "(", 2)[0], "CREATE PROCEDURE ")
		if !ok {
			continue
		}
		stubbed := strings.Contains(policyStmt(t, stmts, name), "fxa.verifyEmail_9 is missing")
		if stubbed != (name == "ffs.confirm_email") {
			t.Errorf("%s stubbed: %v", name, stubbed)
		}
		if !strings.HasPrefix(policyStmt(t, stmts, name), strings.SplitN(stmt, "\n", 2)[0]+"\n") {
			t.Errorf("%s: another signature", name)
		}
	}
}

func TestConfirmSessionNeedsItsProcedures(t *testing.T) {
	for _, missing := range []string{"fxa.verifyTokensWithMethod_3", "fxa.verifyToken_3"} {
		stmts := policySQL([]string{missing})
		for _, stmt := range fxaPolicySQL {
			name, ok := strings.CutPrefix(strings.SplitN(stmt, "(", 2)[0], "CREATE PROCEDURE ")
			if !ok {
				continue
			}
			if stubbed := strings.Contains(policyStmt(t, stmts, name), missing+" is missing"); stubbed != (name == "ffs.confirm_session") {
				t.Errorf("%s missing: %s stubbed %v", missing, name, stubbed)
			}
		}
	}
	for _, name := range []string{"verifyTokensWithMethod_3", "verifyToken_3"} {
		if !strings.Contains(strings.Join(fxaPinnedProcedures, " "), name) {
			t.Errorf("%s not checked", name)
		}
	}
}

func TestActivityPagesSplitNoMillisecond(t *testing.T) {
	base := time.Now().Add(-time.Hour).UnixMilli()
	page := func(rows [][]driver.Value) ([]Event, int64) {
		app := testApp()
		app.rec = fakeRecorder(&fakeFxa{events: rows})
		var errs []string
		events, older, _, _, _, _ := app.eventPage(httptest.NewRequest("GET", "/activity", nil), &errs)
		if len(errs) > 0 {
			t.Fatal(errs)
		}
		return events, older
	}
	var rows [][]driver.Value
	for i := 0; i < eventsPerPage; i++ {
		at := base - int64(i)
		if i >= eventsPerPage-3 {
			at = base - int64(eventsPerPage-3) // the last 3 in one ms (more may follow in the database)
		}
		rows = append(rows, []driver.Value{at, "admin", "x"})
	}
	events, older := page(rows)
	if len(events) != eventsPerPage-3 || older != base-int64(eventsPerPage-3)+1 {
		t.Errorf("%d events, next page before %d (want %d)", len(events), older-base, -int64(eventsPerPage-3)+1)
	}
	// a whole page in one ms: shown, no loop
	for i := range rows {
		rows[i] = []driver.Value{base, "admin", "x"}
	}
	if events, older := page(rows); len(events) != eventsPerPage || older != base {
		t.Errorf("one ms: %d events, before %d", len(events), older-base)
	}
}

// an account id that is valid hex but has no account: the procedures refuse it, so
// nothing is recorded as done (no event, no note for a uid nobody has)
func TestUnknownAccountChangesNothing(t *testing.T) {
	fake := &fakeFxa{execErr: func(q string, _ []driver.Value) error {
		if strings.HasPrefix(q, "CALL ffs.") {
			return &mysql.MySQLError{Number: 1644, SQLState: [5]byte{'4', '5', '0', '0', '0'}, Message: "no such account"}
		}
		return nil
	}}
	app := testApp()
	app.fxa, app.alerter, app.sync = fake.db("127.0.0.1:1"), &Alerter{}, &SyncDB{db: sql.OpenDB(fake)}
	h := app.routes()
	c, s := passwordSession(t, app, h)
	app.alerter.take()
	const uid = "fedcba98fedcba98fedcba98fedcba98"
	for _, c2 := range []struct {
		path string
		form url.Values
	}{
		{"disable", url.Values{"reason": {"x"}}},
		{"enable", nil},
		{"sign-out-all", nil},
		{"remove-totp", url.Values{"sign_out": {"1"}}},
		{"confirm-email", nil},
	} {
		form := url.Values{"csrf": {s.csrf}}
		for k, v := range c2.form {
			form[k] = v
		}
		post(h, "/accounts/"+uid+"/"+c2.path, form, c, nil)
		app.mu.Lock()
		failed, message := s.failed, s.message
		app.mu.Unlock()
		if failed != "no such account" || message != "" {
			t.Errorf("%s: message %q, failed %q", c2.path, message, failed)
		}
	}
	signOuts := 0
	for _, q := range fake.statements() {
		if strings.HasPrefix(q, "INSERT INTO ffs_account_notes") {
			t.Errorf("note written: %s", q)
		}
		if q == "CALL ffs.sign_out_all(?)" {
			signOuts++
		}
	}
	// the one of sign-out-all itself, none after the refused remove-totp
	if signOuts != 1 {
		t.Errorf("%d sign-outs", signOuts)
	}
	if lines := alerts(t, app.alerter, 1); len(lines) != 0 {
		t.Errorf("alerts: %q", lines)
	}
}

// the record of a change is in the event log when the admin sees the result: a page read
// right after lists it (the activity page of tests/test_admin_sync.py read before a record
// written in the background), and when it cannot be written the admin is told
func TestChangeRecordedBeforeTheResult(t *testing.T) {
	for _, failing := range []bool{false, true} {
		// a Sync account of Mozilla's accounts
		fake := &fakeFxa{answer: func(query string, _ []driver.Value) *fakeRows {
			if strings.HasPrefix(query, "SELECT email, MIN(created_at)") {
				return &fakeRows{cols: []string{"email", "created", "uid"}, rows: [][]driver.Value{{fakeUID + "@api.accounts.firefox.com", int64(1700000000000), int64(7)}}}
			}
			return nil
		}}
		// a slow database: the record of the note is written 100 ms after it is sent
		var mu sync.Mutex
		written := false
		fake.execErr = func(query string, args []driver.Value) error {
			if !strings.HasPrefix(query, "INSERT INTO ffs_events") || !strings.HasPrefix(args[2].(string), "Note of") {
				return nil
			}
			time.Sleep(100 * time.Millisecond)
			if failing {
				return errors.New("database gone")
			}
			mu.Lock()
			written = true
			mu.Unlock()
			return nil
		}
		app := testApp()
		app.sync, app.alerter = &SyncDB{db: sql.OpenDB(fake)}, &Alerter{}
		app.rec = fakeRecorder(fake)
		h := app.routes()
		c, s := passwordSession(t, app, h)
		app.alerter.take()
		w := post(h, "/users/"+fakeUID+"/note", url.Values{"csrf": {s.csrf}, "note": {"Alice's laptop"}}, c, nil)
		mu.Lock()
		done := written
		mu.Unlock()
		if w.Code != 303 || !strings.HasPrefix(s.message, "Note of ") {
			t.Fatalf("failing %v: %d %q %q", failing, w.Code, s.message, s.failed)
		}
		if done == failing {
			t.Errorf("failing %v: written before the result: %v", failing, done)
		}
		notice := "Done, but not recorded in the event log (the audit trail): database gone."
		if failing != strings.Contains(s.failed, notice) {
			t.Errorf("failing %v: shown %q / %q", failing, s.message, s.failed)
		}
		// the alert goes out either way
		if lines := alerts(t, app.alerter, 1); len(lines) != 1 || !strings.Contains(lines[0], "admin: Note of ") {
			t.Errorf("failing %v: alerts %q", failing, lines)
		}
	}
}
