package main

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/go-sql-driver/mysql"
)

// externalFake: the tokenserver of an install whose access another system manages: the init
// container wrote allowed_accounts = mode, the other system one row of sync_allowed_accounts,
// and max users is full (a full limit must not ask to raise it)
func externalFake(mode *string) *fakeFxa {
	on, eventAt := false, int64(0)
	fake := allowlistFake(&on, &eventAt)
	fake.maxUsers, fake.syncUsers = "1", 1
	inner := fake.answer
	fake.answer = func(query string, args []driver.Value) *fakeRows {
		if strings.Contains(query, "SELECT config_value FROM config WHERE config_key = 'allowed_accounts'") {
			if *mode == "" {
				return &fakeRows{cols: []string{"value"}}
			}
			return &fakeRows{cols: []string{"value"}, rows: [][]driver.Value{{*mode}}}
		}
		if strings.Contains(query, "FROM users GROUP BY email") {
			// the accounts of the users rows (one row each here)
			var rows [][]driver.Value
			for _, u := range fake.users {
				rows = append(rows, []driver.Value{u[1], u[8], u[0]})
			}
			return &fakeRows{cols: []string{"email", "created", "id"}, rows: rows}
		}
		if strings.Contains(query, "FROM sync_refused_accounts") {
			panic("the refusals are read with access managed elsewhere")
		}
		return inner(query, args)
	}
	return fake
}

// changes: the statements that change anything but the event log
func changes(fake *fakeFxa) []string {
	var got []string
	for _, q := range fake.statements() {
		if !strings.HasPrefix(q, "INSERT INTO ffs_events") {
			got = append(got, q)
		}
	}
	return got
}

func TestAccessExternalOverviewIsReadOnly(t *testing.T) {
	mode := accessExternalSetting
	fake := externalFake(&mode)
	app, h, c, _ := allowlistApp(t, fake, true)
	app.accessExternal, app.allowlistEditable, app.maxUsersEditable = true, false, false
	page := getPage(h, "/", c).Body.String()
	for _, want := range []string{
		`<h2 id="sync-allowlist-title">Who may sync</h2><span class="pill notice">managed elsewhere</span>`,
		"Managed outside the admin UI (<code>ADMIN_ACCESS_EXTERNAL</code>)",
		`<a href="/users/` + allowedUID + `"><code>` + allowedUID + `</code></a>`,
		`<p class="hint" id="max-users-mode">Read-only: managed outside the admin UI`,
		// one badge, a notice
		`<a class="pill notice" href="#sync-allowlist" title="Who may use this server is decided outside the admin UI (ADMIN_ACCESS_EXTERNAL)`,
		"Access managed elsewhere",
	} {
		if !strings.Contains(page, want) {
			t.Errorf("overview: no %q", want)
		}
	}
	for _, unwanted := range []string{
		"Approve…", "Reject…", "Remove…", `id="allow-uid"`, `action="/sync/max-users"`, "Change the limit",
		// no line or badge that asks to change who may come in
		"waiting for your approval", "until it is raised", "raise the limit", `class="pill warn">full`, "Max users 1/1",
		`class="stat is-warn" href="#sync"`,
	} {
		if strings.Contains(page, unwanted) {
			t.Errorf("overview: %q", unwanted)
		}
	}
	// the health row of the limit: the count, no warning
	app.health.setLimits(&Limit{Count: 1, Max: 1}, nil)
	if rows := app.health.Limits(); len(rows) != 1 || !rows[0].Up || rows[0].Warn || rows[0].Detail != "1 of 1 taken, managed elsewhere" {
		t.Errorf("limit rows: %+v", rows)
	}
	// no alert of the full limit, nor of the refusals
	if events := app.health.thresholdEvents(&SyncStatus{Users: 1, MaxUsers: 1}, &Limit{Count: 5, Max: 5}, true, time.Time{}, time.Time{}, nil); len(events) != 0 {
		t.Errorf("threshold events: %q", events)
	}
	app.health.watchRefusals(context.Background())
	if got := changes(fake); len(got) != 0 {
		t.Errorf("statements: %q", got)
	}
	// no pending gauge (no refusals of firefox-sync's to count)
	if n := app.pendingCount(context.Background()); n != -1 {
		t.Errorf("pending: %d", n)
	}
}

func TestAccessExternalRefusesChanges(t *testing.T) {
	mode := accessExternalSetting
	fake := externalFake(&mode)
	app, h, c, s := allowlistApp(t, fake, true)
	app.accessExternal = true
	// editable by their own settings: refused anyway, in the handler
	app.allowlistEditable, app.maxUsersEditable = true, true
	refused := func(what string) {
		t.Helper()
		if !strings.Contains(s.failed, "managed outside the admin UI (ADMIN_ACCESS_EXTERNAL): nothing changed here") || s.message != "" {
			t.Errorf("%s: failed %q, message %q", what, s.failed, s.message)
		}
		s.failed = ""
	}
	post(h, "/sync/max-users", url.Values{"csrf": {s.csrf}, "max_users": {"5"}}, c, nil)
	refused("max users")
	for _, action := range []string{"allow", "reject", "remove"} {
		uid := map[string]string{"allow": pendingUID, "reject": pendingUID, "remove": allowedUID}[action]
		if w := getPage(h, "/sync/allowlist/"+action+"?uid="+uid, c); w.Code != http.StatusSeeOther {
			t.Errorf("confirm %s: %d", action, w.Code)
		}
		refused("confirm " + action)
		post(h, "/sync/allowlist/"+action, url.Values{"csrf": {s.csrf}, "uid": {uid}}, c, nil)
		refused(action)
	}
	if w := getPage(h, "/sync/allowlist/purge?uid="+pendingUID, c); w.Code != http.StatusNotFound {
		t.Errorf("unknown action: %d", w.Code)
	}
	if got := changes(fake); len(got) != 0 {
		t.Errorf("statements: %q", got)
	}
	// the chart's name for it
	app.deployment = deployment{kind: "kubernetes"}
	post(h, "/sync/max-users", url.Values{"csrf": {s.csrf}, "max_users": {"5"}}, c, nil)
	if !strings.Contains(s.failed, "(admin.accessExternal)") {
		t.Errorf("chart: %q", s.failed)
	}
}

// the self-hosted accounts: sign-ups, max accounts, invitations and the sign-up allowlist read-only
func TestAccessExternalSignupsReadOnly(t *testing.T) {
	fake := &fakeFxa{}
	redis, _ := fakeRedis(t)
	app := testApp()
	app.fxa, app.sync, app.alerter = fake.db(redis), &SyncDB{db: sql.OpenDB(fake)}, &Alerter{}
	app.accessExternal, app.maxAccountsEditable = true, true
	h := app.routes()
	c, s := passwordSession(t, app, h)
	page := getPage(h, "/", c).Body.String()
	for _, want := range []string{`id="signup-mode"`, "the system that decides who may use this server keeps these, read-only here",
		"no invitations from the admin UI", "An account whose email leaves the list stays, and keeps working, until it is disabled."} {
		if !strings.Contains(page, want) {
			t.Errorf("overview: no %q", want)
		}
	}
	for _, unwanted := range []string{`action="/accounts/signups"`, `action="/accounts/invite"`, `action="/accounts/max-accounts"`, "/accounts/allowlist/remove?entry="} {
		if strings.Contains(page, unwanted) {
			t.Errorf("overview: %q", unwanted)
		}
	}
	for path, form := range map[string]url.Values{
		"/accounts/signups":          {"mode": {"open"}, "allowlist": {""}},
		"/accounts/max-accounts":     {"max_accounts": {"5"}},
		"/accounts/invite":           {"email": {"bob@example.com"}},
		"/accounts/allowlist/remove": {"entry": {"@example.com"}},
	} {
		form.Set("csrf", s.csrf)
		post(h, path, form, c, nil)
		if !strings.Contains(s.failed, "managed outside the admin UI") {
			t.Errorf("%s: %q %q", path, s.failed, s.message)
		}
		s.failed = ""
	}
	if w := getPage(h, "/accounts/allowlist/remove?entry=@example.com", c); w.Code != http.StatusSeeOther || !strings.Contains(s.failed, "managed outside the admin UI") {
		t.Errorf("confirm remove: %d %q", w.Code, s.failed)
	}
	for _, q := range changes(fake) {
		if strings.Contains(q, "signup_allowlist") || strings.Contains(q, "ffs.settings") {
			t.Errorf("changed: %q", q)
		}
	}
	// the account stays manageable: disable is no change of who may sign up
	s.failed = ""
	post(h, "/accounts/"+fakeUID+"/disable", url.Values{"csrf": {s.csrf}}, c, nil)
	if !strings.HasPrefix(s.message, "Disabled ") {
		t.Errorf("disable: %q %q", s.message, s.failed)
	}
}

// Reset and Delete of the Sync data work as before, and never touch the allowlist: they delete
// the tokenserver rows and the storage only; the next sign-in is a new INSERT, which the other
// system's trigger checks
func TestAccessExternalKeepsResetAndDelete(t *testing.T) {
	mode := accessExternalSetting
	fake := externalFake(&mode)
	fake.users = [][]driver.Value{{int64(7), allowedUID + "@api.accounts.firefox.com", "aaaa", int64(0), int64(1), "https://sync.example.com", int64(0), int64(1), int64(1700000000000), int64(0)}}
	app, h, c, s := allowlistApp(t, fake, false)
	app.accessExternal, app.storage = true, &StorageDB{db: sql.OpenDB(fake)}
	post(h, "/users/"+allowedUID+"/reset-sync", url.Values{"csrf": {s.csrf}}, c, nil)
	if !strings.HasPrefix(s.message, "Reset the Sync data of") || s.failed != "" {
		t.Errorf("reset: %q %q", s.message, s.failed)
	}
	post(h, "/users/"+allowedUID+"/reset-sync", url.Values{"csrf": {s.csrf}, "free_slot": {"1"}}, c, nil)
	if !strings.Contains(s.message, "freed its max users slot") || s.failed != "" {
		t.Errorf("reset, free the slot: %q %q", s.message, s.failed)
	}
	post(h, "/users/"+allowedUID+"/delete", url.Values{"csrf": {s.csrf}, "confirm_email": {allowedUID}}, c, nil)
	if !strings.HasPrefix(s.message, "Deleted the Sync data of") || s.failed != "" {
		t.Errorf("delete: %q %q", s.message, s.failed)
	}
	all := strings.Join(changes(fake), "\n")
	if !strings.Contains(all, "CALL ffs_delete_user_row(?)") {
		t.Errorf("no tokenserver row deleted: %s", all)
	}
	for _, unwanted := range []string{"sync_allowed_accounts", "ffs_allow_account", "ffs_remove_allowed_account", "ffs_reject_account", "config"} {
		if strings.Contains(all, unwanted) {
			t.Errorf("reset or delete touched %s: %s", unwanted, all)
		}
	}
}

func TestAccessCheck(t *testing.T) {
	mode := ""
	fake := externalFake(&mode)
	app, _, _, _ := allowlistApp(t, fake, false)
	ctx := context.Background()
	for _, c := range []struct {
		external bool
		mode     string
		shown    bool
		ok       bool
		text     string
	}{
		{false, "", false, false, ""},
		{false, "on", false, false, ""},
		{true, accessExternalSetting, true, true, "read-only here"},
		{true, "off", true, false, "the init container did not apply it (allowed_accounts is 'off')"},
		{true, "", true, false, "(allowed_accounts is not set)"},
		{false, accessExternalSetting, true, false, "the admin UI does not have it"},
	} {
		app.accessExternal, mode = c.external, c.mode
		check, shown := app.accessCheck(ctx)
		if shown != c.shown || check.OK != c.ok || !strings.Contains(check.Text, c.text) {
			t.Errorf("external %v, mode %q: %v %+v", c.external, c.mode, shown, check)
		}
	}
}

func TestLoadAccessExternal(t *testing.T) {
	for _, c := range []struct {
		value, allowed string
		on             bool
		err            string
	}{
		{"", "", false, ""}, {"0", "admin", false, ""}, {"1", "", true, ""}, {"yes", "", true, ""},
		{"1", "admin", false, "leave SYNC_ALLOWED_ACCOUNTS empty"}, {"maybe", "", false, "must be 1, true or yes"},
	} {
		t.Setenv("ADMIN_ACCESS_EXTERNAL", c.value)
		t.Setenv("SYNC_ALLOWED_ACCOUNTS", c.allowed)
		on, err := loadAccessExternal()
		if on != c.on || (err == nil) != (c.err == "") || (err != nil && !strings.Contains(err.Error(), c.err)) {
			t.Errorf("%q, %q: %v %v", c.value, c.allowed, on, err)
		}
	}
}

// ffs_access: the rows of the sign-up allowlist and the procedures by email, nothing of fxa.*
// (the procedures, SQL SECURITY DEFINER, reach it for it), not ffs.settings
func TestAccessUserGrants(t *testing.T) {
	if fxaAccessGrants[0] != "REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'ffs_access'@'%'" {
		t.Errorf("first: %q", fxaAccessGrants[0])
	}
	allowed := map[string]bool{
		"GRANT SELECT, INSERT, DELETE ON ffs.signup_allowlist TO 'ffs_access'@'%'":    true,
		"GRANT EXECUTE ON PROCEDURE ffs.disable_account_by_email TO 'ffs_access'@'%'": true,
		"GRANT EXECUTE ON PROCEDURE ffs.enable_account_by_email TO 'ffs_access'@'%'":  true,
		"GRANT EXECUTE ON PROCEDURE ffs.delete_account_by_email TO 'ffs_access'@'%'":  true,
	}
	for _, g := range fxaAccessGrants[1:] {
		if !allowed[g] {
			t.Errorf("grant: %q", g)
		}
		delete(allowed, g)
	}
	if len(allowed) > 0 {
		t.Errorf("missing: %v", allowed)
	}
	// each procedure it runs exists, runs as its definer, and goes through the admin UI's own
	var found int
	for _, stmt := range fxaPolicySQL {
		for name, inner := range map[string]string{"disable_account_by_email": "CALL ffs.disable_account(v_uid)",
			"enable_account_by_email": "UPDATE fxa.accounts SET disabledAt = NULL WHERE uid = v_uid", "delete_account_by_email": "CALL ffs.delete_account(v_uid)"} {
			if strings.HasPrefix(stmt, "CREATE PROCEDURE ffs."+name+"(") {
				found++
				if !strings.Contains(stmt, "SQL SECURITY DEFINER") || !strings.Contains(stmt, inner) || !strings.Contains(stmt, "normalizedEmail = LOWER(TRIM(p_email))") {
					t.Errorf("%s: %s", name, stmt)
				}
			}
		}
	}
	if found != 3 {
		t.Errorf("%d procedures by email", found)
	}
	// with FxA's revokeAccountTokens_1 gone, disable by email refuses too (it calls disable_account)
	for _, stmt := range policySQL(fxaPolicySQL, []string{"fxa.revokeAccountTokens_1"}) {
		if strings.HasPrefix(stmt, "CREATE PROCEDURE ffs.disable_account_by_email(") && !strings.Contains(stmt, "SIGNAL SQLSTATE '45000'") {
			t.Errorf("not a stand-in: %s", stmt)
		}
	}
}

// ADMIN_ACCESS_EXTERNAL: the admin UI's Enable asks the sign-up policy, its Delete leaves the
// allowlist alone; ffs_access's enable never asks; without the mode, the procedures of before
func TestExternalProcedures(t *testing.T) {
	before := strings.Join(fxaPolicySQL, "\x00")
	if got := fxaPolicySQLFor(false); strings.Join(got, "\x00") != before {
		t.Error("without the mode: not fxaPolicySQL")
	}
	if del := policyStmt(t, fxaPolicySQL, "ffs.delete_account"); !strings.Contains(del, "DELETE FROM ffs.signup_allowlist WHERE entry = LOWER(v_email);") {
		t.Errorf("without the mode, delete takes the email off the allowlist: %s", del)
	}
	if enable := policyStmt(t, fxaPolicySQL, "ffs.enable_account"); strings.Contains(enable, "signup_refusal") {
		t.Errorf("without the mode, enable asks the policy: %s", enable)
	}

	ext := fxaPolicySQLFor(true)
	if strings.Join(fxaPolicySQL, "\x00") != before || len(ext) != len(fxaPolicySQL) {
		t.Fatal("fxaPolicySQL changed, or statements added or lost")
	}
	changed := 0
	for i := range ext {
		if ext[i] != fxaPolicySQL[i] {
			changed++
		}
	}
	if changed != 2 {
		t.Errorf("%d statements differ in external mode, want enable_account and delete_account", changed)
	}
	del := policyStmt(t, ext, "ffs.delete_account")
	if strings.Contains(del, "signup_allowlist") || !strings.Contains(del, "CALL fxa.deleteAccount_24(p_uid, 'fxa_admin_requested_account_delete')") {
		t.Errorf("external delete: %s", del)
	}
	enable := policyStmt(t, ext, "ffs.enable_account")
	r, u := strings.Index(enable, "IF ffs.signup_refusal(v_email) <=> 'policy' THEN"), strings.Index(enable, "UPDATE fxa.accounts SET disabledAt = NULL WHERE uid = p_uid")
	if r < 0 || u < r || strings.Contains(enable, "'full'") || !strings.Contains(enable, "SQL SECURITY DEFINER") ||
		!strings.Contains(enable, "MESSAGE_TEXT = '"+errAccessElsewhere+"'") || !strings.Contains(enable, "MESSAGE_TEXT = 'no such account'") {
		t.Errorf("external enable: %s", enable)
	}
	if len(errAccessElsewhere) > 128 || strings.ContainsAny(errAccessElsewhere, "'\\") {
		t.Errorf("not a MESSAGE_TEXT: %q", errAccessElsewhere)
	}
	// ffs_access's enable: the same in both modes, never through the policy
	if a, b := policyStmt(t, ext, "ffs.enable_account_by_email"), policyStmt(t, fxaPolicySQL, "ffs.enable_account_by_email"); a != b || strings.Contains(a, "CALL ffs.enable_account(") {
		t.Errorf("enable by email: %s", a)
	}
	// the stand-ins still apply to the external procedures
	for _, stmt := range policySQL(ext, []string{"fxa.deleteAccount_24"}) {
		if strings.HasPrefix(stmt, "CREATE PROCEDURE ffs.delete_account(") && !strings.Contains(stmt, "is missing from the accounts database") {
			t.Errorf("not a stand-in: %s", stmt)
		}
	}
}

// the admin UI's Enable refused in external mode: the procedure's words, not an SQL error
func TestEnableRefusedElsewhere(t *testing.T) {
	fake := &fakeFxa{disabled: true}
	redis, _ := fakeRedis(t)
	app := testApp()
	app.fxa = fake.db(redis)
	app.accessExternal = true
	h := app.routes()
	c, s := passwordSession(t, app, h)
	fake.execErr = func(query string, _ []driver.Value) error {
		if query == "CALL ffs.enable_account(?)" {
			return &mysql.MySQLError{Number: 1644, SQLState: [5]byte{'4', '5', '0', '0', '0'}, Message: errAccessElsewhere}
		}
		return nil
	}
	w := post(h, "/accounts/"+fakeUID+"/enable", url.Values{"csrf": {s.csrf}, "back": {"/users/" + fakeUID}}, c, nil)
	if w.Header().Get("Location") != "/users/"+fakeUID || s.message != "" || s.failed != errAccessElsewhere {
		t.Errorf("enable: %s %q %q", w.Header().Get("Location"), s.message, s.failed)
	}
	// disabling stays allowed
	fake.execErr = nil
	post(h, "/accounts/"+fakeUID+"/disable", url.Values{"csrf": {s.csrf}, "back": {"/users/" + fakeUID}}, c, nil)
	if s.failed != "" || !strings.HasPrefix(s.message, "Disabled ") {
		t.Errorf("disable: %q %q", s.message, s.failed)
	}
}

// fxa-policy with ADMIN_ACCESS_EXTERNAL: FXA_SIGNUPS every start, the rows of the allowlist left
// alone, a FXA_SIGNUP_ALLOWLIST refused
func TestExternalPolicy(t *testing.T) {
	fake := &fakeFxa{mode: SignupsAllowlist}
	db := sql.OpenDB(fake)
	t.Setenv("ADMIN_ACCESS_EXTERNAL", "1")
	t.Setenv("FXA_SIGNUPS", "allowlist")
	t.Setenv("FXA_SIGNUP_ALLOWLIST", "")
	if _, err := applyEnvPolicy(context.Background(), db); err != nil {
		t.Fatal(err)
	}
	got := strings.Join(fake.statements(), "\n")
	if strings.Contains(got, "signup_allowlist") || !strings.Contains(got, "INSERT INTO ffs.settings (name, value) VALUES ('signups', ?)") {
		t.Errorf("statements: %s", got)
	}
	t.Setenv("FXA_SIGNUP_ALLOWLIST", "alice@example.com")
	if _, err := applyEnvPolicy(context.Background(), db); err == nil || !strings.Contains(err.Error(), "leave FXA_SIGNUP_ALLOWLIST empty") {
		t.Errorf("with a list: %v", err)
	}
}
