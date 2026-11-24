package main

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"os"
	"regexp"
	"slices"
	"strings"
	"testing"
)

// SHOW GRANTS of the admin UI's reader on the tokenserver database: before (EXECUTE on the
// whole database, database-setup.sql's), per procedure without the mode, with it
var (
	readerGrantsBefore = []string{"GRANT USAGE ON *.* TO `ffs_admin_sync`@`%`", "GRANT SELECT, EXECUTE ON `tokenserver`.* TO `ffs_admin_sync`@`%`"}
	readerGrantsOff    = []string{"GRANT USAGE ON *.* TO `ffs_admin_sync`@`%`", "GRANT SELECT ON `tokenserver`.* TO `ffs_admin_sync`@`%`",
		"GRANT EXECUTE ON PROCEDURE `tokenserver`.`ffs_delete_user_row` TO `ffs_admin_sync`@`%`",
		"GRANT EXECUTE ON PROCEDURE `tokenserver`.`ffs_drop_admin_tables` TO `ffs_admin_sync`@`%`",
		"GRANT EXECUTE ON PROCEDURE `tokenserver`.`ffs_resync_node_load` TO `ffs_admin_sync`@`%`",
		"GRANT EXECUTE ON PROCEDURE `tokenserver`.`ffs_set_max_users` TO `ffs_admin_sync`@`%`",
		"GRANT EXECUTE ON PROCEDURE `tokenserver`.`ffs_allow_account` TO `ffs_admin_sync`@`%`",
		"GRANT EXECUTE ON PROCEDURE `tokenserver`.`ffs_remove_allowed_account` TO `ffs_admin_sync`@`%`",
		"GRANT EXECUTE ON PROCEDURE `tokenserver`.`ffs_reject_account` TO `ffs_admin_sync`@`%`",
		"GRANT EXECUTE ON PROCEDURE `tokenserver`.`ffs_mark_refusal_reported` TO `ffs_admin_sync`@`%`"}
	readerGrantsExternal = slices.Clip(readerGrantsOff[:5])
)

func held(list []accessPrivilege) (names []string) {
	for _, p := range list {
		if p.Held {
			names = append(names, p.Name)
		}
	}
	return names
}

func TestMysqlHolds(t *testing.T) {
	for _, c := range []struct {
		lines          []string
		db, kind, name string
		priv           string
		want           bool
	}{
		// (the database's grant covers its procedures)
		{readerGrantsBefore, "tokenserver", "PROCEDURE", "ffs_allow_account", "EXECUTE", true},
		{readerGrantsBefore, "tokenserver", "", "", "EXECUTE", true},
		{readerGrantsBefore, "tokenserver2", "", "", "EXECUTE", false},
		{readerGrantsOff, "tokenserver", "PROCEDURE", "ffs_allow_account", "EXECUTE", true},
		{readerGrantsOff, "tokenserver", "PROCEDURE", "FFS_ALLOW_ACCOUNT", "EXECUTE", true},
		{readerGrantsOff, "tokenserver", "FUNCTION", "ffs_allow_account", "EXECUTE", false},
		{readerGrantsOff, "other", "PROCEDURE", "ffs_allow_account", "EXECUTE", false},
		{readerGrantsExternal, "tokenserver", "PROCEDURE", "ffs_allow_account", "EXECUTE", false},
		// the whole server, a pattern, ALL PRIVILEGES, a table, column lists
		{[]string{"GRANT ALL PRIVILEGES ON *.* TO `root`@`%`"}, "tokenserver", "", "sync_allowed_accounts", "INSERT", true},
		{[]string{"GRANT INSERT ON `token%`.* TO `x`@`%`"}, "tokenserver", "", "sync_allowed_accounts", "INSERT", true},
		{[]string{"GRANT INSERT ON `token\\_x`.* TO `x`@`%`"}, "tokenserverx", "", "", "INSERT", false},
		{[]string{"GRANT SELECT, INSERT ON `tokenserver`.`sync_allowed_accounts` TO `x`@`%`"}, "tokenserver", "", "sync_allowed_accounts", "INSERT", true},
		{[]string{"GRANT SELECT, INSERT ON `tokenserver`.`sync_allowed_accounts` TO `x`@`%`"}, "tokenserver", "", "config", "INSERT", false},
		{[]string{"GRANT SELECT (uid, email), UPDATE (note) ON `tokenserver`.`sync_allowed_accounts` TO `x`@`%`"}, "tokenserver", "", "sync_allowed_accounts", "UPDATE", true},
		// MySQL's partial revokes
		{[]string{"GRANT INSERT ON *.* TO `x`@`%`", "REVOKE INSERT ON `tokenserver`.* FROM `x`@`%`"}, "tokenserver", "", "", "INSERT", false},
	} {
		if got := mysqlHolds(c.lines, c.db, c.kind, c.name, c.priv); got != c.want {
			t.Errorf("%v %s %s %s %s: %v", c.lines, c.db, c.kind, c.name, c.priv, got)
		}
	}
}

func TestMysqlRoutinePrivileges(t *testing.T) {
	all := append(append([]string{}, syncDataRoutines...), syncAccessRoutines...)
	for i, r := range all {
		all[i] = "EXECUTE on " + r
	}
	if got := held(mysqlRoutinePrivileges(readerGrantsBefore, "tokenserver")); !slices.Equal(got, all) {
		t.Errorf("before: %v", got)
	}
	if got := held(mysqlRoutinePrivileges(readerGrantsOff, "tokenserver")); !slices.Equal(got, all) {
		t.Errorf("without the mode: %v", got)
	}
	if got := held(mysqlRoutinePrivileges(readerGrantsExternal, "tokenserver")); !slices.Equal(got, all[:3]) {
		t.Errorf("with the mode: %v", got)
	}
	got := held(mysqlRoutinePrivileges(append(readerGrantsExternal, "GRANT INSERT ON `tokenserver`.`sync_allowed_accounts` TO `ffs_admin_sync`@`%`"), "tokenserver"))
	if !slices.Contains(got, "INSERT, UPDATE or DELETE on sync_allowed_accounts") {
		t.Errorf("a write on the list: %v", got)
	}
}

func TestAccessGrantProblems(t *testing.T) {
	before := mysqlRoutinePrivileges(readerGrantsBefore, "tokenserver")
	external := mysqlRoutinePrivileges(readerGrantsExternal, "tokenserver")
	off := mysqlRoutinePrivileges(readerGrantsOff, "tokenserver")
	if h, l := accessGrantProblems(before, true, accessNeeded); len(h) != len(syncAccessRoutines) || len(l) != 0 {
		t.Errorf("the mode on, the grants of before: %v %v", h, l)
	}
	if h, l := accessGrantProblems(external, true, accessNeeded); len(h) != 0 || len(l) != 0 {
		t.Errorf("the mode on, its grants: %v %v", h, l)
	}
	if h, l := accessGrantProblems(external, false, accessNeeded); len(h) != 0 || !slices.Equal(l, []string{"EXECUTE on ffs_set_max_users", "EXECUTE on ffs_allow_account",
		"EXECUTE on ffs_remove_allowed_account", "EXECUTE on ffs_reject_account", "EXECUTE on ffs_mark_refusal_reported"}) {
		t.Errorf("the mode off, the grants of the mode on: %v %v", h, l)
	}
	if h, l := accessGrantProblems(off, false, accessNeeded); len(h) != 0 || len(l) != 0 {
		t.Errorf("the mode off, its grants: %v %v", h, l)
	}
	// what the admin UI needs in either mode
	if _, l := accessGrantProblems(mysqlRoutinePrivileges(readerGrantsExternal[:2], "tokenserver"), true, accessNeeded); !slices.Equal(l,
		[]string{"EXECUTE on ffs_delete_user_row", "EXECUTE on ffs_drop_admin_tables", "EXECUTE on ffs_resync_node_load"}) {
		t.Errorf("no procedure at all: %v", l)
	}
}

// ffs_admin on the accounts database: the sign-up policy and its allowlist written without the
// mode, read only with it; and the other grants alike in both
func TestFxaAdminGrantsFor(t *testing.T) {
	grants, obsolete := fxaAdminGrantsFor(false)
	if !slices.Equal(grants, fxaAdminGrants) || !slices.Equal(obsolete, fxaObsoleteGrants) {
		t.Errorf("without the mode: %v %v", grants, obsolete)
	}
	grants, obsolete = fxaAdminGrantsFor(true)
	if len(grants) != len(fxaAdminGrants) || grants[0] != fxaAdminGrants[0] {
		t.Fatalf("with the mode: %v", grants)
	}
	for i, g := range grants {
		switch g {
		case "GRANT SELECT ON ffs.settings TO 'ffs_admin'@'%'", "GRANT SELECT ON ffs.signup_allowlist TO 'ffs_admin'@'%'":
			continue
		}
		if g != fxaAdminGrants[i] {
			t.Errorf("with the mode, %d: %q, not %q", i, g, fxaAdminGrants[i])
		}
		if regexp.MustCompile(`\b(INSERT|UPDATE|DELETE|ALL)\b.* ON ffs\.(settings|signup_allowlist|\*)`).MatchString(g) {
			t.Errorf("a write on the sign-up policy with the mode: %q", g)
		}
	}
	if !slices.Contains(grants, "GRANT SELECT ON ffs.settings TO 'ffs_admin'@'%'") || !slices.Contains(grants, "GRANT SELECT ON ffs.signup_allowlist TO 'ffs_admin'@'%'") {
		t.Errorf("with the mode, the reads: %v", grants)
	}
	if !slices.Equal(obsolete[len(fxaObsoleteGrants):], fxaAdminExternalRevokes) {
		t.Errorf("with the mode, revoked one by one on your own server: %v", obsolete)
	}
	// every grant replaced is one of fxaAdminGrants (none is left over after a rename)
	for g := range fxaAdminAccessGrants {
		if !slices.Contains(fxaAdminGrants, g) {
			t.Errorf("not a grant of ffs_admin: %q", g)
		}
	}
	// ffs_access keeps exactly its own, whatever the mode (TestAccessUserGrants)
	lines := []string{"GRANT USAGE ON *.* TO `ffs_admin`@`%`", "GRANT SELECT ON `ffs`.`settings` TO `ffs_admin`@`%`", "GRANT SELECT ON `ffs`.`signup_allowlist` TO `ffs_admin`@`%`"}
	if got := held(fxaTablePrivileges(lines)); len(got) != 0 {
		t.Errorf("with the mode, ffs_admin writes: %v", got)
	}
	lines = []string{"GRANT SELECT, INSERT, UPDATE, DELETE ON `ffs`.`settings` TO `ffs_admin`@`%`", "GRANT SELECT, INSERT, UPDATE, DELETE ON `ffs`.`signup_allowlist` TO `ffs_admin`@`%`"}
	if got := held(fxaTablePrivileges(lines)); len(got) != 6 {
		t.Errorf("without the mode, ffs_admin writes: %v", got)
	}
}

// the procedures the check looks at are those the init container grants, and those the admin
// UI calls (db/mysql/init/db_init.sh, db/postgres/init/admin_grants.sql)
func TestAccessRoutinesOfTheInit(t *testing.T) {
	mysqlInit, err := os.ReadFile("../db/mysql/init/db_init.sh")
	if err != nil {
		t.Skip("no ../db (the image's build context is admin/ only)")
	}
	for name, list := range map[string][]string{"ADMIN_SYNC_ROUTINES": syncDataRoutines, "ADMIN_ACCESS_ROUTINES": syncAccessRoutines} {
		m := regexp.MustCompile(`readonly ` + name + `=\(([^)]*)\)`).FindSubmatch(mysqlInit)
		if m == nil || !slices.Equal(strings.Fields(string(m[1])), list) {
			t.Errorf("db_init.sh %s: %q, access.go: %v", name, m, list)
		}
	}
	grants, err := os.ReadFile("../db/postgres/init/admin_grants.sql")
	if err != nil {
		t.Fatal(err)
	}
	text := strings.ToLower(strings.Join(strings.Fields(string(grants)), " "))
	external := text[strings.Index(text, `\if :ffs_external`):strings.Index(text, `\else`)]
	without := text[strings.Index(text, `\else`):strings.Index(text, `\endif`)]
	for _, f := range pgAccessFunctions {
		f = "public." + strings.ReplaceAll(strings.ReplaceAll(f, ",", ", "), "(text", "(text")
		if !strings.Contains(external, f) || !strings.Contains(without, f) {
			t.Errorf("admin_grants.sql: %s not revoked with the mode and granted without", f)
		}
	}
	for _, f := range pgDataFunctions {
		if !strings.Contains(text[:strings.Index(text, `\if :ffs_external`)], "grant execute on function public."+f) {
			t.Errorf("admin_grants.sql: %s not granted in either mode", f)
		}
	}
	if !strings.Contains(external, "revoke update (config_value) on public.config") || !strings.Contains(without, "grant update (config_value) on public.config") {
		t.Error("admin_grants.sql: max users not revoked with the mode and granted without")
	}
	// the admin UI calls each one: a procedure it does not call needs no EXECUTE
	var code []byte
	for _, f := range []string{"allowlist.go", "sync.go", "lifecycle.go", "owndb.go", "nodeload.go"} {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		code = append(code, b...)
	}
	for _, r := range append(append([]string{}, syncDataRoutines...), syncAccessRoutines...) {
		if !strings.Contains(string(code), `"`+r+`"`) && !strings.Contains(string(code), "CALL "+r+"(") {
			t.Errorf("the admin UI does not call %s", r)
		}
	}
}

// grantsFake: SHOW GRANTS of the reader (and of ffs_admin) as given
func grantsFake(fake *fakeFxa, reader, accounts *[]string) {
	inner := fake.answer
	fake.answer = func(query string, args []driver.Value) *fakeRows {
		switch query {
		case "SELECT DATABASE(), VERSION(), CURRENT_ROLE()":
			return &fakeRows{cols: []string{"db", "version", "role"}, rows: [][]driver.Value{{"tokenserver", "11.8.3-MariaDB", nil}}}
		case "SHOW GRANTS":
			var rows [][]driver.Value
			for _, l := range append(append([]string{}, *reader...), *accounts...) {
				rows = append(rows, []driver.Value{l})
			}
			return &fakeRows{cols: []string{"grants"}, rows: rows}
		}
		return inner(query, args)
	}
}

func TestAccessGrantsCheck(t *testing.T) {
	mode := ""
	fake := externalFake(&mode)
	reader, accounts := readerGrantsBefore, []string{}
	grantsFake(fake, &reader, &accounts)
	app, _, _, _ := allowlistApp(t, fake, false)
	ctx := context.Background()
	for _, c := range []struct {
		external bool
		grants   []string
		shown    bool
		ok       bool
		text     string
	}{
		{false, readerGrantsBefore, false, false, ""},
		{false, readerGrantsOff, false, false, ""},
		{false, readerGrantsExternal, true, false, "lack what the admin UI needs: ffs_admin_sync EXECUTE on ffs_set_max_users, ffs_admin_sync EXECUTE on ffs_allow_account"},
		{true, readerGrantsExternal, true, true, "The database refuses the admin UI's users every change of who may use the server"},
		{true, readerGrantsBefore, true, false, "still lets the admin UI's users change who may use the server: ffs_admin_sync EXECUTE on ffs_set_max_users"},
		{true, readerGrantsBefore, true, false, "GRANT OPTION"},
		{true, readerGrantsExternal[:2], true, false, "lack what the admin UI needs with ADMIN_ACCESS_EXTERNAL too: ffs_admin_sync EXECUTE on ffs_delete_user_row"},
	} {
		app.accessExternal, reader = c.external, c.grants
		check, shown := app.accessGrantsCheck(ctx)
		if shown != c.shown || check.OK != c.ok || !strings.Contains(check.Text, c.text) {
			t.Errorf("external %v, %v: %v %+v", c.external, c.grants, shown, check)
		}
	}
	// the accounts: ffs_admin's writes on the sign-up policy, with the mode
	app.fxa, app.accessExternal, reader = &FxaDB{db: sql.OpenDB(fake)}, true, readerGrantsExternal
	accounts = []string{"GRANT SELECT, INSERT, UPDATE, DELETE ON `ffs`.`signup_allowlist` TO `ffs_admin`@`%`"}
	if check, shown := app.accessGrantsCheck(ctx); !shown || check.OK || !strings.Contains(check.Text, "ffs_admin INSERT on ffs.signup_allowlist") || !strings.Contains(check.Text, "and fxa-policy") {
		t.Errorf("ffs_admin writes the allowlist: %v %+v", shown, check)
	}
	accounts = []string{"GRANT SELECT ON `ffs`.`signup_allowlist` TO `ffs_admin`@`%`", "GRANT SELECT ON `ffs`.`settings` TO `ffs_admin`@`%`"}
	if check, shown := app.accessGrantsCheck(ctx); !shown || !check.OK || !strings.Contains(check.Text, "ffs_admin only reads") {
		t.Errorf("ffs_admin reads only: %v %+v", shown, check)
	}
	// no reader of its own: the database cannot tell the admin UI from the Sync server
	app.fxa, app.sync.own = nil, nil
	if check, shown := app.accessGrantsCheck(ctx); !shown || check.OK || !strings.Contains(check.Text, "no ADMIN_DB_PASSWORD") {
		t.Errorf("no reader of its own: %v %+v", shown, check)
	}
	app.accessExternal = false
	if _, shown := app.accessGrantsCheck(ctx); shown {
		t.Error("no reader of its own, the mode off: shown")
	}
}
