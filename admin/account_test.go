package main

import (
	"bufio"
	"database/sql"
	"database/sql/driver"
	"encoding/hex"
	"fmt"
	"net"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/go-sql-driver/mysql"
)

// redisWith answers like FxA's Redis: GET with value (the sessions of fakeUID), the
// others with 0; every command on got
func redisWith(t *testing.T, value string) (string, chan string) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	got := make(chan string, 20)
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			buf := make([]byte, 4096)
			n, _ := conn.Read(buf)
			cmd := string(buf[:n])
			got <- cmd
			if strings.Contains(cmd, "\r\nGET\r\n") {
				conn.Write([]byte("$" + strconv.Itoa(len(value)) + "\r\n" + value + "\r\n"))
			} else {
				conn.Write([]byte(":0\r\n"))
			}
			conn.Close()
		}
	}()
	return ln.Addr().String(), got
}

func TestSessionCacheParsing(t *testing.T) {
	other := strings.Repeat("ab", 32)
	used, err := parseSessionCache(`{"` + fakeToken + `":[1700000900000,["Rome"],"Firefox"],"` + other + `":{"lastAccessTime":1700000500000},"not hex":[1],"` + strings.Repeat("cd", 32) + `":[]}`)
	if err != nil {
		t.Fatal(err)
	}
	// by the hash of the token id, never by the id
	if len(used) != 2 || !used[fakeRef].Equal(time.UnixMilli(1700000900000)) {
		t.Errorf("%v", used)
	}
	for ref := range used {
		if ref == fakeToken || ref == other || len(ref) != 64 {
			t.Errorf("not a hash: %s", ref)
		}
	}
	if _, err := parseSessionCache(`{"` + fakeToken + `": broken`); err == nil || strings.Contains(err.Error(), fakeToken) {
		t.Errorf("error %v", err)
	}
}

func TestLastUsedFromRedis(t *testing.T) {
	for _, c := range []struct {
		redis int64
		want  int64
	}{{1700000900000, 1700000900000}, {1700000000001, 1700000200000}} {
		addr, _ := redisWith(t, `{"`+fakeToken+`":[`+strconv.FormatInt(c.redis, 10)+`]}`)
		fake := &fakeFxa{}
		devices, sessions, err := fake.db(addr).Devices(t.Context(), fakeUID)
		if err != nil {
			t.Fatal(err)
		}
		// the newer of MySQL (sessions 1700000200000, devices 1700000100000) and Redis
		if !sessions[0].LastUsed.Equal(time.UnixMilli(c.want)) {
			t.Errorf("Redis %d: session last used %v", c.redis, sessions[0].LastUsed.UnixMilli())
		}
		if want := max(c.redis, 1700000100000); !devices[0].LastUsed.Equal(time.UnixMilli(want)) {
			t.Errorf("Redis %d: device last used %v", c.redis, devices[0].LastUsed.UnixMilli())
		}
		if sessions[0].Verified {
			t.Error("unconfirmed sign-in shown as confirmed")
		}
	}
	// the page: the hash, the badge, never the token id
	addr, _ := redisWith(t, `{"`+fakeToken+`":[1700000900000]}`)
	fake := &fakeFxa{}
	app := testApp()
	app.fxa, app.sync = fake.db(addr), &SyncDB{db: sql.OpenDB(fake)}
	h := app.routes()
	c, _ := passwordSession(t, app, h)
	page := getPage(h, "/users/"+fakeUID, c).Body.String()
	if strings.Contains(page, fakeToken) || !strings.Contains(page, "/sessions/"+fakeRef+"/sign-out") || !strings.Contains(page, `<span class="badge">unconfirmed sign-in</span>`) {
		t.Errorf("page: %s", page)
	}
	for _, want := range []string{`<span class="badge">2-step</span> on, <span id="recovery-codes">7</span> backup codes left`, `<span class="badge">no recovery key</span>`,
		`href="/accounts/` + fakeUID + `/remove-totp"`, "<td>alice@example.org</td><td>secondary</td><td>no</td>", "/reset_password. With a recovery key nothing is lost."} {
		if !strings.Contains(page, want) {
			t.Errorf("no %q", want)
		}
	}
	// confirmed: no button to confirm it
	if strings.Contains(page, "/confirm-email") {
		t.Error("confirm button for a confirmed email")
	}
}

func TestOwnerNotice(t *testing.T) {
	at := time.Date(2026, 10, 13, 9, 30, 0, 0, time.UTC)
	subject, body := ownerNotice("remove-totp", fakeEmail, "", "https://accounts.example.com", at)
	if subject != "Two-step authentication turned off on your account" ||
		!strings.HasPrefix(body, "An administrator turned off two-step authentication on your account alice@example.com on 2026-10-13 09:30 (UTC)") ||
		!strings.Contains(body, "https://accounts.example.com/settings\r\n") || !strings.Contains(body, "If you did not ask for this") {
		t.Errorf("%q\n%s", subject, body)
	}
	if subject, body := ownerNotice("remove-recovery-key", fakeEmail, "", "https://accounts.example.com", at); !strings.Contains(subject, "recovery key") ||
		!strings.Contains(body, "removed the account recovery key of your account alice@example.com") {
		t.Errorf("%q\n%s", subject, body)
	}

	// through the page: the account's email, the change audited and alerted
	server, _ := newFakeSMTP(t, false, false)
	mailer := server.alerter(nil).Mailer
	mailer.user = ""
	redis, got := redisWith(t, "")
	fake := &fakeFxa{}
	app := testApp()
	app.fxa, app.sync, app.alerter, app.mailer, app.contentURL = fake.db(redis), &SyncDB{db: sql.OpenDB(fake)}, &Alerter{}, &mailer, "https://accounts.example.com"
	h := app.routes()
	c, s := passwordSession(t, app, h)
	app.alerter.take()
	page := getPage(h, "/accounts/"+fakeUID+"/remove-totp", c).Body.String()
	if !strings.Contains(page, `<input type="checkbox" name="sign_out" value="1" checked>`) || !strings.Contains(page, "Turn off two-step authentication of alice@example.com?") ||
		strings.Contains(page, "Sessions signed out") {
		t.Errorf("confirm page: %s", page)
	}
	if page := getPage(h, "/accounts/"+fakeUID+"/confirm-email", c).Body.String(); !strings.Contains(page, "skips the proof") || strings.Contains(page, `name="sign_out"`) {
		t.Errorf("confirm page: %s", page)
	}
	w := post(h, "/accounts/"+fakeUID+"/remove-totp", url.Values{"csrf": {s.csrf}, "sign_out": {"1"}, "reason": {"lost phone"}}, c, nil)
	if w.Header().Get("Location") != "/users/"+fakeUID || s.failed != "" ||
		s.message != "Turned off two-step authentication of alice@example.com (uid 0123abcd) (signed out everywhere, owner notified)" {
		t.Errorf("%s %q %q", w.Header().Get("Location"), s.message, s.failed)
	}
	if st := fake.statements(); len(st) != 2 || st[0] != "CALL ffs.remove_totp(?)" || st[1] != "CALL ffs.sign_out_all(?)" {
		t.Errorf("statements %q", st)
	}
	var commands []string
	for len(got) > 0 {
		commands = append(commands, <-got)
	}
	if all := strings.Join(commands, " "); !strings.Contains(all, "fxa-profile:%23profileCache.get:"+fakeUID+"\r\n") || !strings.Contains(all, "at:"+fakeUID) {
		t.Errorf("Redis: %q", commands)
	}
	server.mu.Lock()
	rcpts, data := server.rcpts, server.data
	server.mu.Unlock()
	if len(rcpts) != 1 || rcpts[0] != "TO:<alice@example.com>" || !strings.Contains(data, "To: alice@example.com\r\n") ||
		!strings.Contains(data, "Subject: Two-step authentication turned off on your account\r\n") || !strings.Contains(data, "An administrator turned off two-step authentication") {
		t.Errorf("notice to %q: %s", rcpts, data)
	}
	lines := alerts(t, app.alerter, 1)
	if len(lines) != 1 || !strings.HasSuffix(lines[0], "admin: Turned off two-step authentication of alice@example.com (uid 0123abcd) (signed out everywhere, owner notified) by admin (password): lost phone") {
		t.Errorf("alerts %q", lines)
	}

	// without SMTP: done, and said so
	app.mailer = nil
	post(h, "/accounts/"+fakeUID+"/remove-recovery-key", url.Values{"csrf": {s.csrf}}, c, nil)
	if s.message != "Removed the account recovery key of alice@example.com (uid 0123abcd) (no notice to the owner: no SMTP server (FXA_SMTP_HOST))" {
		t.Errorf("%q %q", s.message, s.failed)
	}
	// an address that would add headers is not written to
	if _, err := app.notifyOwner(&FxaAccount{Email: "a@example.com\r\nBcc: x@example.com"}, "remove-totp", "", at); err == nil {
		t.Error("notice to a forged address")
	}
	app.mailer = &mailer
	if _, err := app.notifyOwner(&FxaAccount{Email: "Mallory <a@example.com>"}, "remove-totp", "", at); err == nil {
		t.Error("notice to a name")
	}
}

// A refused change (a stale or replayed form) signs out nobody, emails nobody and
// records nothing: the owner would get a false notice
func TestRefusedSignInMethodChangesNothing(t *testing.T) {
	for _, c := range []struct{ action, call, refusal string }{
		{"remove-totp", "CALL ffs.remove_totp(?)", "two-step authentication is not on"},
		{"remove-recovery-key", "CALL ffs.remove_recovery_key(?)", "no account recovery key"},
	} {
		server, _ := newFakeSMTP(t, false, false)
		mailer := server.alerter(nil).Mailer
		mailer.user = ""
		redis, _ := redisWith(t, "")
		fake := &fakeFxa{execErr: func(query string, _ []driver.Value) error {
			if query == c.call {
				return &mysql.MySQLError{Number: 1644, SQLState: [5]byte{'4', '5', '0', '0', '0'}, Message: c.refusal}
			}
			return nil
		}}
		app := testApp()
		app.fxa, app.sync, app.alerter, app.mailer, app.contentURL = fake.db(redis), &SyncDB{db: sql.OpenDB(fake)}, &Alerter{}, &mailer, "https://accounts.example.com"
		h := app.routes()
		cookie, s := passwordSession(t, app, h)
		app.alerter.take()
		w := post(h, "/accounts/"+fakeUID+"/"+c.action, url.Values{"csrf": {s.csrf}, "sign_out": {"1"}, "reason": {"lost phone"}}, cookie, nil)
		if w.Header().Get("Location") != "/users/"+fakeUID || s.failed != c.refusal || s.message != "" {
			t.Errorf("%s: %s %q %q", c.action, w.Header().Get("Location"), s.message, s.failed)
		}
		if st := fake.statements(); len(st) != 1 || st[0] != c.call {
			t.Errorf("%s: statements %q", c.action, st)
		}
		// doneTo recorded the event before the redirect: no alert for a refusal
		if lines := app.alerter.take(); len(lines) != 0 {
			t.Errorf("%s: alerts %q", c.action, lines)
		}
		server.mu.Lock()
		rcpts, commands := server.rcpts, server.commands
		server.mu.Unlock()
		if len(rcpts) != 0 || len(commands) != 0 {
			t.Errorf("%s: mail to %q (%q)", c.action, rcpts, commands)
		}
	}
}

func TestNotes(t *testing.T) {
	ok := strings.Repeat("é", maxNote)
	if n, err := cleanNote("  " + ok + "  "); err != nil || n != ok {
		t.Errorf("%d characters refused: %v", maxNote, err)
	}
	if _, err := cleanNote(ok + "x"); err == nil {
		t.Error("over the cap")
	}
	if n, _ := cleanNote("lost\r\nlaptop\x00"); n != "lost  laptop" {
		t.Errorf("%q", n)
	}
	for _, postgres := range []bool{false, true} {
		db := &SyncDB{postgres: postgres}
		schema := strings.Join(db.schema(), "\n")
		if !regexp.MustCompile(`CREATE TABLE IF NOT EXISTS ffs_account_notes \(uid VARCHAR\(64\) PRIMARY KEY, note VARCHAR\(500\) NOT NULL,\s+updated_at BIGINT NOT NULL, updated_by VARCHAR\(255\) NOT NULL\)`).MatchString(schema) {
			t.Errorf("postgres %v: %s", postgres, schema)
		}
		if postgres == strings.Contains(schema, "utf8mb4") {
			t.Errorf("postgres %v: charset", postgres)
		}
		fake := &fakeFxa{}
		db.db = sql.OpenDB(fake)
		if err := db.SetNote(t.Context(), "alice", "friend of Bob", "admin (password)"); err != nil {
			t.Fatal(err)
		}
		db.SetNote(t.Context(), "alice", " ", "admin (password)")
		st := fake.statements()
		if postgres != strings.Contains(st[0], "ON CONFLICT (uid)") || postgres != strings.Contains(st[0], "$4") || fake.args[0][1] != "friend of Bob" {
			t.Errorf("postgres %v: %q %v", postgres, st, fake.args)
		}
		if postgres != (st[1] == "DELETE FROM ffs_account_notes WHERE uid = $1") {
			t.Errorf("postgres %v: %q", postgres, st[1])
		}
	}

	// the reason of disabling goes after the note there is, the oldest cut
	fake := &fakeFxa{notes: map[string]string{fakeUID: strings.Repeat("a", maxNote-3)}}
	app := testApp()
	app.sync = &SyncDB{db: sql.OpenDB(fake)}
	if err := app.addToNote(t.Context(), fakeUID, "lost laptop", &session{method: "password"}); err != nil {
		t.Fatal(err)
	}
	if note := fake.args[0][1].(string); len([]rune(note)) != maxNote || !strings.HasSuffix(note, "a; lost laptop") {
		t.Errorf("%q", note)
	}
}

func TestBlockAlerts(t *testing.T) {
	h, alerter := testHealth("")
	now := h.started.Add(time.Minute)
	member := FxaAccount{UID: fakeUID, Email: "Alice@example.com"}
	block := func(on, value, action string) Block {
		return Block{Key: "rate-limit:block:" + on + "=" + value + ":" + action + ":5-900-900", On: on, Value: value, Action: action,
			Start: now.Add(-10 * time.Second), Until: now.Add(15 * time.Minute)}
	}
	blocks := []Block{
		block("ip_email", "203.0.113.7_alice@example.com", "accountLogin"),
		block("email", "alice@example.com", "accountLogin"), // the same account and action: one alert
		block("uid", fakeUID, "verifyTotpCode"),
		block("ip_email", "203.0.113.7_mallory@example.org", "accountLogin"), // not an account
		block("ip", "203.0.113.7", "accountLogin"),                           // anybody's IP address
	}
	old := block("email", "alice@example.com", "passwordForgotSendOtp")
	old.Start = h.started.Add(-time.Minute) // from before the start
	blocks = append(blocks, old)
	h.blockEvents(blocks, []FxaAccount{member}, now, true)
	lines := alerter.take()
	if len(lines) != 2 || !strings.Contains(lines[0], "blocked: Alice@example.com (uid 0123abcd) blocked until") || !strings.HasSuffix(lines[0], "(accountLogin, on ip_email)") ||
		!strings.HasSuffix(lines[1], "(verifyTotpCode, on uid)") {
		t.Errorf("alerts %q", lines)
	}
	// still blocked a minute later: nothing new
	h.blockEvents(blocks, []FxaAccount{member}, now.Add(time.Minute), true)
	if lines := alerter.take(); len(lines) != 0 {
		t.Errorf("alerted again: %q", lines)
	}
	// lifted, then blocked again: a new alert
	h.blockEvents(blocks[2:], []FxaAccount{member}, now.Add(2*time.Minute), true)
	h.blockEvents(blocks, []FxaAccount{member}, now.Add(3*time.Minute), true)
	if lines := alerter.take(); len(lines) != 1 || !strings.Contains(lines[0], "accountLogin") {
		t.Errorf("after lifting: %q", lines)
	}
	// over: forgotten
	h.blockEvents(nil, []FxaAccount{member}, now.Add(time.Hour), true)
	if len(h.blockAlerted) != 0 {
		t.Errorf("kept %v", h.blockAlerted)
	}
	if !alertKinds["blocked"] {
		t.Error("no alert for blocked")
	}
	// the account page shows its blocks only
	if mine := blocksOf(blocks, &member); len(mine) != 4 {
		t.Errorf("%d blocks of the member", len(mine))
	}
}

func TestSecretsStayInTheDatabase(t *testing.T) {
	for _, view := range []string{"ffs.account_security", "ffs.emails", "ffs.sessions", "ffs.devices", "ffs.security_events"} {
		body := ""
		for _, stmt := range fxaPolicySQL {
			if strings.Contains(stmt, "VIEW "+view+" AS") {
				body = stmt
			}
		}
		if body == "" {
			t.Fatalf("no view %s", view)
		}
		// the IP address of a pending sign-in: its security event found by the verification
		// id, compared in the view, never one of its columns
		body = strings.ReplaceAll(body, "e.tokenVerificationId = u.tokenVerificationId", "")
		for _, secret := range []string{"sharedSecret", "codeHash", "recoveryData", "phoneNumber", "publicKey", "emailCode", "tokenData", "authSalt", "verifyHash", "wrapWrapKb",
			// the security history: its JSON may hold the recovery phone's number
			"additionalInfo", "ipAddrHmac", "tokenVerificationId"} {
			if strings.Contains(body, secret) {
				t.Errorf("%s reads %s", view, secret)
			}
		}
		// SELECT on the view only, never on FxA's tables behind it
		if !strings.Contains(strings.Join(fxaAdminGrants, "\n"), "GRANT SELECT ON "+view+" TO") {
			t.Errorf("no grant on %s", view)
		}
	}
	for _, g := range fxaAdminGrants {
		if regexp.MustCompile(`ON fxa(_oauth)?\.(totp|recoveryCodes|recoveryKeys|recoveryPhones|passkeys|emails|sessionTokens|unverifiedTokens)\b`).MatchString(g) {
			t.Errorf("grant on a table with secrets: %s", g)
		}
	}
	// removing two-step authentication is one transaction
	totp := policyStmt(t, fxaPolicySQL, "ffs.remove_totp")
	if s, c := strings.Index(totp, "START TRANSACTION"), strings.Index(totp, "COMMIT"); s < 0 || c < s ||
		!strings.Contains(totp[s:c], "CALL fxa.deleteTotpToken_4(p_uid)") || !strings.Contains(totp[s:c], "DELETE FROM fxa.recoveryCodes") || !strings.Contains(totp[s:c], "DELETE FROM fxa.recoveryPhones") {
		t.Errorf("remove_totp: %s", totp)
	}
	if !strings.Contains(policyStmt(t, fxaPolicySQL, "ffs.confirm_email"), "CALL fxa.verifyEmail_9(p_uid, v_code)") {
		t.Error("confirm_email")
	}
	// confirming a sign-in: what fxa-shared's SessionToken.verify does, in one transaction,
	// after the refusals (email not confirmed, two-step on, not pending)
	session := policyStmt(t, fxaPolicySQL, "ffs.confirm_session")
	start, commit := strings.Index(session, "START TRANSACTION"), strings.Index(session, "COMMIT")
	if start < 0 || commit < start || !strings.Contains(session[start:commit], "CALL fxa.verifyTokensWithMethod_3(v_token, 1, ") ||
		!strings.Contains(session[start:commit], "CALL fxa.verifyToken_3(v_verification, p_uid)") ||
		strings.Index(session[start:commit], "verifyTokensWithMethod_3") > strings.Index(session[start:commit], "verifyToken_3(") {
		t.Errorf("confirm_session: %s", session)
	}
	for _, refusal := range []string{errEmailNotConfirmed, errTwoStepSignIn, errSignInConfirmed} {
		if i := strings.Index(session, refusal); i < 0 || i > start || len(refusal) > 128 || strings.ContainsAny(refusal, "'\\") {
			t.Errorf("confirm_session: refusal %q", refusal)
		}
	}
	if !strings.Contains(session, "UNHEX(SHA2(tokenId, 256)) = p_ref") || !strings.Contains(session, "fxa.totp WHERE uid = p_uid AND enabled AND verified") {
		t.Errorf("confirm_session: %s", session)
	}
	if !strings.Contains(strings.Join(fxaAdminGrants, "\n"), "GRANT EXECUTE ON PROCEDURE ffs.confirm_session TO 'ffs_admin'@'%'") {
		t.Error("no grant on confirm_session")
	}
}

// confirmable: the fake account without two-step authentication, its sign-in pending
func confirmable(query string, _ []driver.Value) *fakeRows {
	if strings.Contains(query, "FROM ffs.account_security") {
		return &fakeRows{cols: []string{"uid", "totp", "key", "codes", "phone", "passkeys", "password", "keys", "locked", "unverified"},
			rows: [][]driver.Value{{fakeUID, int64(0), int64(1), int64(0), int64(0), int64(0), int64(1700000000000), int64(1700000000000), int64(0), int64(1)}}}
	}
	return nil
}

func TestConfirmEmailConfirmsPendingSignIns(t *testing.T) {
	server, _ := newFakeSMTP(t, false, false)
	mailer := server.alerter(nil).Mailer
	mailer.user = ""
	redis, _ := redisWith(t, "")
	fake := &fakeFxa{}
	app := testApp()
	app.fxa, app.sync, app.alerter, app.mailer, app.contentURL = fake.db(redis), &SyncDB{db: sql.OpenDB(fake)}, &Alerter{}, &mailer, "https://accounts.example.com"
	h := app.routes()
	c, s := passwordSession(t, app, h)
	app.alerter.take()
	signedIn := formatTime(time.UnixMilli(1700000000000), adminZone)

	// the confirm page lists the sign-in waiting for its code, and its form only that one
	page := getPage(h, "/accounts/"+fakeUID+"/confirm-email", c).Body.String()
	for _, want := range []string{"Confirm the email of alice@example.com?", "skips the proof", "The sign-in below, waiting for its code, is confirmed too",
		`<table id="confirm-pending" aria-label="Sign-ins confirmed">`, "<td>Firefox on laptop</td><td>Firefox</td><td>Linux</td><td>203.0.113.7</td>",
		`<input type="hidden" name="sessions" value="` + fakeRef + `">`, "does not notice: the person signs in again there"} {
		if !strings.Contains(page, want) {
			t.Errorf("confirm page: no %q", want)
		}
	}
	if strings.Contains(page, "Sessions signed out") {
		t.Error("confirm page: lists sessions signed out")
	}

	w := post(h, "/accounts/"+fakeUID+"/confirm-email", url.Values{"csrf": {s.csrf}, "sessions": {fakeRef}, "reason": {"code never arrived"}}, c, nil)
	want := "Confirmed the email of alice@example.com (uid 0123abcd) and its 1 pending sign-in (owner notified)"
	if w.Header().Get("Location") != "/users/"+fakeUID || s.failed != "" || s.message != want {
		t.Errorf("%s %q %q", w.Header().Get("Location"), s.message, s.failed)
	}
	var calls []string
	var hash []byte
	for i, st := range fake.statements() {
		if strings.HasPrefix(st, "CALL ") {
			calls = append(calls, st)
		}
		if st == "CALL ffs.confirm_session(?, ?)" {
			hash, _ = fake.args[i][1].([]byte)
		}
	}
	if len(calls) != 2 || calls[0] != "CALL ffs.confirm_email(?)" || calls[1] != "CALL ffs.confirm_session(?, ?)" || hex.EncodeToString(hash) != fakeRef {
		t.Errorf("statements %q, ref %x", calls, hash)
	}
	server.mu.Lock()
	rcpts, data := server.rcpts, server.data
	server.mu.Unlock()
	if len(rcpts) != 1 || !strings.Contains(data, "Subject: Your account's email confirmed by an administrator\r\n") ||
		!strings.Contains(data, "were confirmed too: Firefox on laptop, "+signedIn+", from 203.0.113.7.") {
		t.Errorf("notice to %q: %s", rcpts, data)
	}
	if lines := alerts(t, app.alerter, 1); len(lines) != 1 || !strings.HasSuffix(lines[0], "admin: "+want+" by admin (password): code never arrived") {
		t.Errorf("alerts %q", lines)
	}

	// without the field (a script): the email only
	fake.execs, fake.args = nil, nil
	post(h, "/accounts/"+fakeUID+"/confirm-email", url.Values{"csrf": {s.csrf}}, c, nil)
	if st := fake.statements(); len(st) != 1 || st[0] != "CALL ffs.confirm_email(?)" ||
		s.message != "Confirmed the email of alice@example.com (uid 0123abcd) (owner notified)" {
		t.Errorf("%q %q %q", st, s.message, s.failed)
	}
	// not a ref: nothing done
	fake.execs, fake.args = nil, nil
	post(h, "/accounts/"+fakeUID+"/confirm-email", url.Values{"csrf": {s.csrf}, "sessions": {fakeRef + " x"}}, c, nil)
	if st := fake.statements(); len(st) != 0 || s.failed != "invalid session" {
		t.Errorf("%q %q", st, s.failed)
	}

	// a sign-in confirmed in between (its code entered): the email is, the rest said
	fake.execs, fake.args = nil, nil
	fake.execErr = func(query string, _ []driver.Value) error {
		if query == "CALL ffs.confirm_session(?, ?)" {
			return &mysql.MySQLError{Number: 1644, SQLState: [5]byte{'4', '5', '0', '0', '0'}, Message: errSignInConfirmed}
		}
		return nil
	}
	post(h, "/accounts/"+fakeUID+"/confirm-email", url.Values{"csrf": {s.csrf}, "sessions": {fakeRef}}, c, nil)
	if s.message != "Confirmed the email of alice@example.com (uid 0123abcd) (owner notified)" || s.failed != "a sign-in: "+errSignInConfirmed {
		t.Errorf("%q %q", s.message, s.failed)
	}

	// the email confirmed already (a stale page): no sign-in confirmed, nobody emailed
	server.mu.Lock()
	server.rcpts = nil
	server.mu.Unlock()
	fake.execs, fake.args = nil, nil
	fake.execErr = func(query string, _ []driver.Value) error {
		if query == "CALL ffs.confirm_email(?)" {
			return &mysql.MySQLError{Number: 1644, SQLState: [5]byte{'4', '5', '0', '0', '0'}, Message: "the email is already confirmed"}
		}
		return nil
	}
	app.alerter.take()
	post(h, "/accounts/"+fakeUID+"/confirm-email", url.Values{"csrf": {s.csrf}, "sessions": {fakeRef}}, c, nil)
	server.mu.Lock()
	rcpts = server.rcpts
	server.mu.Unlock()
	if st := fake.statements(); len(st) != 1 || s.failed != "the email is already confirmed" || s.message != "" || len(rcpts) != 0 {
		t.Errorf("%q %q %q %q", st, s.message, s.failed, rcpts)
	}
	if lines := app.alerter.take(); len(lines) != 0 {
		t.Errorf("alerts %q", lines)
	}
}

func TestConfirmASignIn(t *testing.T) {
	server, _ := newFakeSMTP(t, false, false)
	mailer := server.alerter(nil).Mailer
	mailer.user = ""
	redis, _ := redisWith(t, "")
	fake := &fakeFxa{}
	app := testApp()
	app.fxa, app.sync, app.alerter, app.mailer, app.contentURL = fake.db(redis), &SyncDB{db: sql.OpenDB(fake)}, &Alerter{}, &mailer, "https://accounts.example.com"
	h := app.routes()
	c, s := passwordSession(t, app, h)
	app.alerter.take()
	signedIn := formatTime(time.UnixMilli(1700000000000), adminZone)
	link := `<a href="/users/` + fakeUID + `/sessions/` + fakeRef + `/confirm"`

	// two-step authentication on (the fake's): the sign-in waits for the authenticator
	if page := getPage(h, "/users/"+fakeUID, c).Body.String(); strings.Contains(page, link) {
		t.Error("Confirm this sign-in with two-step authentication on")
	}
	fake.answer = confirmable
	if page := getPage(h, "/users/"+fakeUID, c).Body.String(); !strings.Contains(page, link+` aria-label="Confirm the sign-in of Firefox">Confirm this sign-in…</a>`) {
		t.Errorf("no Confirm this sign-in: %s", page)
	}
	page := getPage(h, "/users/"+fakeUID+"/sessions/"+fakeRef+"/confirm", c).Body.String()
	for _, want := range []string{"Confirm a sign-in of alice@example.com?", "Only if you know this sign-in is theirs: whoever has the password gets in",
		"<td>Firefox on laptop</td><td>Firefox</td><td>Linux</td><td>203.0.113.7</td>", `action="/users/` + fakeUID + `/sessions/` + fakeRef + `/confirm" id="confirm"`} {
		if !strings.Contains(page, want) {
			t.Errorf("confirm page: no %q", want)
		}
	}
	if w := getPage(h, "/users/"+fakeUID+"/sessions/"+strings.Repeat("ab", 32)+"/confirm", c); w.Code != 404 {
		t.Errorf("another session: %d", w.Code)
	}

	w := post(h, "/users/"+fakeUID+"/sessions/"+fakeRef+"/confirm", url.Values{"csrf": {s.csrf}, "reason": {"new laptop, called me"}}, c, nil)
	want := "Confirmed a sign-in of alice@example.com (uid 0123abcd) (Firefox on laptop, " + signedIn + ") (owner notified)"
	if w.Header().Get("Location") != "/users/"+fakeUID || s.failed != "" || s.message != want {
		t.Errorf("%s %q %q", w.Header().Get("Location"), s.message, s.failed)
	}
	if st := fake.statements(); len(st) != 1 || st[0] != "CALL ffs.confirm_session(?, ?)" {
		t.Errorf("statements %q", st)
	}
	server.mu.Lock()
	rcpts, data := server.rcpts, server.data
	server.mu.Unlock()
	if len(rcpts) != 1 || !strings.Contains(data, "Subject: A sign-in to your account confirmed by an administrator\r\n") ||
		!strings.Contains(data, "without the code sent to this address: Firefox on laptop, "+signedIn+", from 203.0.113.7.") {
		t.Errorf("notice to %q: %s", rcpts, data)
	}
	if lines := alerts(t, app.alerter, 1); len(lines) != 1 || !strings.HasSuffix(lines[0], "admin: "+want+" by admin (password): new laptop, called me") {
		t.Errorf("alerts %q", lines)
	}

	// refused (two-step turned on in between): nobody emailed, nothing recorded
	server.mu.Lock()
	server.rcpts = nil
	server.mu.Unlock()
	fake.execs, fake.args = nil, nil
	fake.execErr = func(query string, _ []driver.Value) error {
		return &mysql.MySQLError{Number: 1644, SQLState: [5]byte{'4', '5', '0', '0', '0'}, Message: errTwoStepSignIn}
	}
	post(h, "/users/"+fakeUID+"/sessions/"+fakeRef+"/confirm", url.Values{"csrf": {s.csrf}}, c, nil)
	server.mu.Lock()
	rcpts = server.rcpts
	server.mu.Unlock()
	if s.failed != errTwoStepSignIn || s.message != "" || len(rcpts) != 0 {
		t.Errorf("%q %q %q", s.message, s.failed, rcpts)
	}
	if lines := app.alerter.take(); len(lines) != 0 {
		t.Errorf("alerts %q", lines)
	}
	// not a ref
	if err := app.fxa.ConfirmSession(t.Context(), fakeUID, "x"); err == nil {
		t.Error("ref x")
	}
}

func TestSignInLabel(t *testing.T) {
	at := time.UnixMilli(1700000000000)
	when := formatTime(at, adminZone)
	for _, c := range []struct {
		s    Session
		want string
	}{
		{Session{Device: "Firefox on laptop", Browser: "Firefox", OS: "Linux", CreatedAt: at, IP: "203.0.113.7"}, "Firefox on laptop, " + when + ", from 203.0.113.7"},
		{Session{Browser: "Firefox", OS: "Linux", CreatedAt: at}, "Firefox on Linux, " + when},
		{Session{OS: "Linux", CreatedAt: at}, "Linux, " + when},
		{Session{CreatedAt: at}, "an unknown browser, " + when},
	} {
		if got := signInLabel(c.s, true); got != c.want {
			t.Errorf("%q, want %q", got, c.want)
		}
	}
	if got := signInLabel(Session{Browser: "Firefox", CreatedAt: at, IP: "203.0.113.7"}, false); got != "Firefox, "+when {
		t.Errorf("without the IP: %q", got)
	}
	if refs, err := signInRefs(strings.ToUpper(fakeRef) + ", " + fakeRef); err != nil || len(refs) != 1 || refs[0] != fakeRef {
		t.Errorf("%q %v", refs, err)
	}
	var many []string
	for i := range maxConfirmedSignIns + 1 {
		many = append(many, fmt.Sprintf("%064x", i))
	}
	if _, err := signInRefs(strings.Join(many[:maxConfirmedSignIns], " ")); err != nil {
		t.Errorf("at the cap: %v", err)
	}
	if _, err := signInRefs(strings.Join(many, " ")); err == nil {
		t.Error("over the cap")
	}
}

func TestAccountBadges(t *testing.T) {
	var b strings.Builder
	rows := []accountRow{
		{UID: fakeUID, Email: fakeEmail, Verified: true, Note: "<b>friend</b>", Security: Security{TOTP: true, RecoveryKey: true, UnverifiedSessions: 1}, Blocked: true},
		{UID: "ff" + fakeUID[2:], Email: "bob@example.com", Verified: true},
	}
	if err := templates.ExecuteTemplate(&b, "dashboard.html", map[string]any{"CSRF": "x", "FxA": true, "Accounts": rows}); err != nil {
		t.Fatal(err)
	}
	page := b.String()
	alice := page[strings.Index(page, `data-email="alice@example.com"`):strings.Index(page, `data-email="bob@example.com"`)]
	bob := page[strings.Index(page, `data-email="bob@example.com"`):]
	bob = bob[:strings.Index(bob, "</tr>")]
	for _, want := range []string{`<span class="badge">2-step</span>`, `<span class="badge">unconfirmed sign-in</span>`, `<span class="badge">blocked</span>`,
		`<span class="note">&lt;b&gt;friend&lt;/b&gt;</span>`} {
		if !strings.Contains(alice, want) {
			t.Errorf("alice: no %s", want)
		}
	}
	if strings.Contains(alice, "no recovery key") || !strings.Contains(bob, `<span class="badge">no recovery key</span>`) || strings.Contains(bob, "2-step") || strings.Contains(bob, "blocked") {
		t.Errorf("badges: %s", page)
	}
	// unconfirmed: the button to confirm it, through its confirm page
	b.Reset()
	acc := &FxaAccount{UID: fakeUID, Email: fakeEmail}
	if err := templates.ExecuteTemplate(&b, "user.html", map[string]any{"CSRF": "x", "FxA": true, "UID": fakeUID, "Account": acc}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(b.String(), `<a href="/accounts/`+fakeUID+`/confirm-email" class="button" id="confirm-email">`) {
		t.Error("no confirm button")
	}
}

// blockRedis answers SCAN (pages of 100, in key order) and MGET on one connection like
// Redis, over keys; the keys asked for with MGET on got
func blockRedis(t *testing.T, keys []string, values map[string]string) (string, chan []string) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	got := make(chan []string, 100)
	bulk := func(s string) string { return "$" + strconv.Itoa(len(s)) + "\r\n" + s + "\r\n" }
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				r := bufio.NewReader(conn)
				for {
					reply, err := readReply(r)
					if err != nil {
						return
					}
					var args []string
					for _, a := range reply.([]any) {
						args = append(args, a.(string))
					}
					var out strings.Builder
					switch args[0] {
					case "SCAN":
						from, _ := strconv.Atoi(args[1])
						to, next := min(from+100, len(keys)), "0"
						if to < len(keys) {
							next = strconv.Itoa(to)
						}
						var page []string
						for _, k := range keys[from:to] {
							if strings.HasPrefix(k, strings.TrimSuffix(args[3], "*")) {
								page = append(page, k)
							}
						}
						out.WriteString("*2\r\n" + bulk(next) + "*" + strconv.Itoa(len(page)) + "\r\n")
						for _, k := range page {
							out.WriteString(bulk(k))
						}
					case "MGET":
						got <- args[1:]
						out.WriteString("*" + strconv.Itoa(len(args)-1) + "\r\n")
						for _, k := range args[1:] {
							if v, ok := values[k]; ok {
								out.WriteString(bulk(v))
							} else {
								out.WriteString("$-1\r\n")
							}
						}
					default:
						out.WriteString(":0\r\n")
					}
					conn.Write([]byte(out.String()))
				}
			}()
		}
	}()
	return ln.Addr().String(), got
}

// a flood of strangers' blocks hides no member's block, and only those are read
func TestBlocksFlood(t *testing.T) {
	var keys []string
	for i := range 3000 {
		keys = append(keys, "rate-limit:block:email=stranger"+strconv.Itoa(i)+"@example.net:accountLogin:5-900-900")
	}
	member := "rate-limit:block:ip_email=10.0.0.1_" + strings.ToUpper(fakeEmail) + ":accountLogin:5-900-900"
	keys = append(keys, member, "rate-limit:attempts:email=x@example.net:accountLogin:5-900-900")
	addr, got := blockRedis(t, keys, map[string]string{member: `{"startTime":1700000000000,"duration":900,"attempts":5}`})
	fake := &fakeFxa{}
	f := fake.db(addr)
	acc := FxaAccount{UID: fakeUID, Email: fakeEmail}

	blocks, complete, err := f.BlocksOf(t.Context(), []FxaAccount{acc})
	if err != nil || !complete || len(blocks) != 1 || blocks[0].Key != member || blocks[0].Attempts != 5 ||
		!blocks[0].Until.Equal(time.UnixMilli(1700000000000).Add(900*time.Second)) {
		t.Fatalf("%v %v %+v", err, complete, blocks)
	}
	if asked := <-got; len(asked) != 1 || asked[0] != member {
		t.Errorf("read %d blocks", len(asked))
	}

	// the Security page: the member's block, then strangers' up to the cap, the rest counted
	limits, err := f.RateLimits(t.Context())
	if err != nil || !limits.Complete || len(limits.Blocks) != maxListedBlocks || limits.Hidden != 3001-maxListedBlocks {
		t.Fatalf("%v %v %d %d", err, limits.Complete, len(limits.Blocks), limits.Hidden)
	}
	if limits.Blocks[0].Key != member {
		t.Errorf("member's block not first: %s", limits.Blocks[0].Key)
	}

	// past maxBlockKeys the lists say so, and a block not seen is not taken as lifted
	defer func(n int) { maxBlockKeys = n }(maxBlockKeys)
	maxBlockKeys = 500
	if _, complete, err := f.BlocksOf(t.Context(), []FxaAccount{acc}); err != nil || complete {
		t.Errorf("%v %v", err, complete)
	}
	h := &Health{app: testApp(), started: time.UnixMilli(1700000000000).Add(-time.Minute)}
	h.app.alerter = &Alerter{}
	b := Block{Key: member, On: "ip_email", Value: "10.0.0.1_" + fakeEmail, Action: "accountLogin",
		Start: time.UnixMilli(1700000000000), Until: time.UnixMilli(1700000000000).Add(900 * time.Second)}
	now := b.Start.Add(time.Minute)
	h.blockEvents([]Block{b}, []FxaAccount{acc}, now, true)
	h.blockEvents(nil, []FxaAccount{acc}, now.Add(time.Minute), false)
	if len(h.blockAlerted) != 1 {
		t.Errorf("forgot the block on an incomplete list: %v", h.blockAlerted)
	}
}
