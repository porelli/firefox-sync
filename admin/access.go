package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/http"
	"os"
	"regexp"
	"strings"
)

// Access managed elsewhere, ADMIN_ACCESS_EXTERNAL (docs/admin/accounts.md#access-managed-elsewhere):
// another system decides who may use this server, through rows it writes into
// sync_allowed_accounts and a trigger of its own on users. The admin UI then shows the limits,
// the allowlist and the sign-ups as they are, and changes none of them: every form and confirm
// page that would is refused here, in its handler, whatever the page shows. Monitoring, storage,
// alerts, backups, the event log, the account pages and the reset and deletion of Sync data
// stay. The init container reads the same setting (db/<engine>/init/db_init.sh): it refuses a
// SYNC_ALLOWED_ACCOUNTS, leaves the rows of the allowlist alone, keeps its own invite-only
// trigger off, and writes allowed_accounts = external in the config table, which the setup
// check below compares with the admin UI's own setting.

// accessExternalSetting: the config row the init container writes with ADMIN_ACCESS_EXTERNAL
const accessExternalSetting = "external"

// loadAccessExternal: ADMIN_ACCESS_EXTERNAL, refused with a SYNC_ALLOWED_ACCOUNTS (two sources
// of who may sync), as the init container refuses it
func loadAccessExternal() (bool, error) {
	on, err := envSwitch("ADMIN_ACCESS_EXTERNAL")
	if err != nil || !on {
		return false, err
	}
	if v := strings.TrimSpace(os.Getenv("SYNC_ALLOWED_ACCOUNTS")); v != "" {
		return false, errors.New("ADMIN_ACCESS_EXTERNAL is on, so who may sync is decided outside firefox-sync: leave SYNC_ALLOWED_ACCOUNTS empty (docs/admin/accounts.md#access-managed-elsewhere)")
	}
	return true, nil
}

// accessExternalErr: why a change of who may use the server is refused here
func (a *App) accessExternalErr() error {
	return fmt.Errorf("who may use this server is managed outside the admin UI (%s): nothing changed here, change it in the system that manages it",
		a.deployment.valueName("ADMIN_ACCESS_EXTERNAL"))
}

// refuseAccessChange: true (and the page told why) when access is managed elsewhere
func (a *App) refuseAccessChange(w http.ResponseWriter, r *http.Request, s *session, back string) bool {
	if !a.accessExternal {
		return false
	}
	a.doneTo(w, r, s, back, "", a.accessExternalErr())
	return true
}

// AllowlistMode: the allowed_accounts row of the config table as the init container wrote it
// (on, off, external; "" without one)
func (s *SyncDB) AllowlistMode(ctx context.Context) (string, error) {
	var mode string
	err := s.db.QueryRowContext(ctx, "SELECT config_value FROM config WHERE config_key = 'allowed_accounts' AND config_value IS NOT NULL").Scan(&mode)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return mode, err
}

// externalAllowlist: the allowlist as the other system wrote it, read-only, without the
// refusals (its own trigger records none of firefox-sync's)
func (a *App) externalAllowlist(ctx context.Context) (*SyncAllowlist, error) {
	l := &SyncAllowlist{External: true}
	var err error
	l.Allowed, err = a.sync.AllowedAccounts(ctx)
	return l, err
}

// accessCheck: the setup check of the mode, when the admin UI or the init container has it on:
// both must, or one of them still manages access (the init container a SYNC_ALLOWED_ACCOUNTS
// of its own, the admin UI its forms)
func (a *App) accessCheck(ctx context.Context) (setupCheck, bool) {
	mode, err := a.sync.AllowlistMode(ctx)
	if err != nil {
		if !a.accessExternal {
			return setupCheck{}, false
		}
		return setupCheck{Name: accessCheckName, Text: "Could not read the mode the init container applied: " + err.Error()}, true
	}
	setting := a.deployment.valueName("ADMIN_ACCESS_EXTERNAL")
	switch {
	case a.accessExternal && mode == accessExternalSetting:
		return setupCheck{Name: accessCheckName, OK: true, Text: "Who may use this server is managed outside the admin UI (" + setting + "): the limits, the allowlist and the sign-ups are read-only here, and the init container leaves sync_allowed_accounts to that system."}, true
	case a.accessExternal:
		return setupCheck{Name: accessCheckName, Text: setting + " is on for the admin UI, but the init container did not apply it (allowed_accounts is " + quoteMode(mode) + "): give it the same setting and start it again, or it keeps managing the allowlist itself."}, true
	case mode == accessExternalSetting:
		return setupCheck{Name: accessCheckName, Text: "The init container applied " + setting + ", but the admin UI does not have it: give the admin UI the same setting and restart it, or its forms change who may use the server behind the system that manages it."}, true
	}
	return setupCheck{}, false
}

const accessCheckName = "Access managed elsewhere"

func quoteMode(mode string) string {
	if mode == "" {
		return "not set"
	}
	return "'" + oneLine(mode, 32) + "'"
}

// The database enforces the mode too (docs/admin/accounts.md#the-database-enforces-it-too): with
// it on, the init container and fxa-policy give the admin UI's users nothing that changes who may
// use the server, and they give it again with it off. Its handlers refuse those changes anyway;
// this is in case one of them would not, or someone signs in to the database as these users.
// accessGrantsCheck reads what the admin UI's users hold, as themselves (SHOW GRANTS,
// has_*_privilege), never what a start recorded.

// accessPrivilege: a privilege of the admin UI's users that the check looks at: Access, one
// that changes who may use the server (none with the mode on; the admin UI's forms need it
// without), or one the admin UI needs in either mode (Reset Sync data with the slot freed,
// Delete, purges, the recount of a node's load)
type accessPrivilege struct {
	Name   string
	Access bool
	Held   bool
}

// the procedures (functions with PostgreSQL) of the init container the admin UI's reader runs,
// db/<engine>/init/db_init.sh gives it EXECUTE on them
var (
	syncDataRoutines   = []string{"ffs_delete_user_row", "ffs_drop_admin_tables", "ffs_resync_node_load"}
	syncAccessRoutines = []string{"ffs_set_max_users", "ffs_allow_account", "ffs_remove_allowed_account", "ffs_reject_account", "ffs_mark_refusal_reported"}
	// PostgreSQL: max users is an UPDATE of config, a row of users a DELETE
	pgDataFunctions   = []string{"ffs_drop_admin_tables()", "ffs_resync_node_load(text)"}
	pgAccessFunctions = []string{"ffs_allow_account(text,text,text)", "ffs_remove_allowed_account(text)", "ffs_reject_account(text,text)", "ffs_mark_refusal_reported(text)"}
	// the accounts' (ffs_admin): the sign-up policy and max accounts, the sign-up allowlist
	fxaAccessTables = []string{"settings", "signup_allowlist"}
)

var tableWrites = []string{"INSERT", "UPDATE", "DELETE"}

// mysqlGrantLines: the lines of SHOW GRANTS of the connection's user (mysqlPrivileges), and its database
func mysqlGrantLines(ctx context.Context, db *sql.DB) ([]string, string, error) {
	var schema, version string
	var role sql.NullString
	if err := db.QueryRowContext(ctx, "SELECT DATABASE(), VERSION(), CURRENT_ROLE()").Scan(&schema, &version, &role); err != nil {
		return nil, "", err
	}
	query := "SHOW GRANTS"
	if !strings.Contains(strings.ToLower(version), "mariadb") && role.Valid && role.String != "" && role.String != "NONE" {
		query = "SHOW GRANTS FOR CURRENT_USER() USING " + role.String
	}
	rows, err := db.QueryContext(ctx, query)
	if err != nil {
		return nil, schema, err
	}
	defer rows.Close()
	var lines []string
	for rows.Next() {
		var line string
		if err := rows.Scan(&line); err != nil {
			return nil, schema, err
		}
		lines = append(lines, line)
	}
	return lines, schema, rows.Err()
}

// a line of SHOW GRANTS on any object: the privileges, PROCEDURE or FUNCTION, then *.*, `db`.* or `db`.`name`
var objectGrantLine = regexp.MustCompile("^(GRANT|REVOKE) (.+?) ON (?:(PROCEDURE|FUNCTION) )?(?:\\*\\.\\*|`((?:[^`]|``)*)`\\.(?:\\*|`((?:[^`]|``)*)`)) (?:TO|FROM) ")

// column lists of a privilege (SELECT (uid, email)): the privilege counts, on its columns
var grantColumns = regexp.MustCompile(`\([^)]*\)`)

// mysqlHolds: the lines of SHOW GRANTS give priv on an object of the database db: kind ""
// with name "" the database itself, kind "" a table, PROCEDURE or FUNCTION a routine. Grants on
// the whole server and on the database (its pattern) count; MySQL's partial revokes of the
// database are taken off
func mysqlHolds(lines []string, db, kind, name, priv string) bool {
	held, revoked := false, false
	for _, line := range lines {
		m := objectGrantLine.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		lineDB, lineName := strings.ReplaceAll(m[4], "``", "`"), strings.ReplaceAll(m[5], "``", "`")
		var applies bool
		switch {
		case m[3] == "" && lineDB == "" && lineName == "":
			// *.*
			applies = true
		case m[3] == "" && lineName == "":
			applies = grantPatternMatches(lineDB, db)
		default:
			applies = m[3] == kind && lineDB == db && strings.EqualFold(lineName, name) && name != ""
		}
		if !applies {
			continue
		}
		for _, p := range strings.Split(grantColumns.ReplaceAllString(m[2], ""), ",") {
			p = strings.ToUpper(strings.TrimSpace(p))
			if p == priv || p == "ALL PRIVILEGES" || p == "ALL" {
				if m[1] == "REVOKE" {
					revoked = true
				} else {
					held = true
				}
			}
		}
	}
	return held && !revoked
}

// mysqlRoutinePrivileges: EXECUTE on each routine of the tokenserver database, from the lines
func mysqlRoutinePrivileges(lines []string, schema string) []accessPrivilege {
	var list []accessPrivilege
	for _, group := range []struct {
		names  []string
		access bool
	}{{syncDataRoutines, false}, {syncAccessRoutines, true}} {
		for _, r := range group.names {
			list = append(list, accessPrivilege{Name: "EXECUTE on " + r, Access: group.access,
				Held: mysqlHolds(lines, schema, "", "", "EXECUTE") || mysqlHolds(lines, schema, "PROCEDURE", r, "EXECUTE")})
		}
	}
	// the lists themselves and the config table (max users, allowed_accounts): never written
	// directly by the admin UI, in either mode
	for _, table := range []string{"sync_allowed_accounts", "sync_refused_accounts", "config"} {
		writes := false
		for _, p := range tableWrites {
			writes = writes || mysqlHolds(lines, schema, "", "", p) || mysqlHolds(lines, schema, "", table, p)
		}
		list = append(list, accessPrivilege{Name: "INSERT, UPDATE or DELETE on " + table, Access: true, Held: writes})
	}
	return list
}

// syncAccessPrivileges: those of the admin UI's reader of the Sync data, as it sees them
func (s *SyncDB) syncAccessPrivileges(ctx context.Context) ([]accessPrivilege, error) {
	if !s.postgres {
		lines, schema, err := mysqlGrantLines(ctx, s.db)
		if err != nil {
			return nil, err
		}
		return mysqlRoutinePrivileges(lines, schema), nil
	}
	// (to_regprocedure, to_regclass: NULL for what is not there, and then not held)
	var list []accessPrivilege
	var exprs []string
	for _, group := range []struct {
		names  []string
		access bool
	}{{pgDataFunctions, false}, {pgAccessFunctions, true}} {
		for _, f := range group.names {
			list = append(list, accessPrivilege{Name: "EXECUTE on " + f, Access: group.access})
			exprs = append(exprs, "COALESCE(pg_catalog.has_function_privilege(pg_catalog.to_regprocedure('public."+f+"'), 'EXECUTE'), false)")
		}
	}
	list = append(list, accessPrivilege{Name: "DELETE on users"}, accessPrivilege{Name: "UPDATE of config (max users)", Access: true})
	exprs = append(exprs, "COALESCE(pg_catalog.has_table_privilege(pg_catalog.to_regclass('public.users'), 'DELETE'), false)",
		"COALESCE(pg_catalog.has_column_privilege(pg_catalog.to_regclass('public.config'), 'config_value', 'UPDATE'), false)")
	for _, table := range []string{"sync_allowed_accounts", "sync_refused_accounts"} {
		list = append(list, accessPrivilege{Name: "INSERT, UPDATE or DELETE on " + table, Access: true})
		exprs = append(exprs, "COALESCE(pg_catalog.has_table_privilege(pg_catalog.to_regclass('public."+table+"'), 'INSERT, UPDATE, DELETE'), false)")
	}
	held := make([]bool, len(list))
	dest := make([]any, len(list))
	for i := range held {
		dest[i] = &held[i]
	}
	if err := s.db.QueryRowContext(ctx, "SELECT "+strings.Join(exprs, ", ")).Scan(dest...); err != nil {
		return nil, err
	}
	for i := range list {
		list[i].Held = held[i]
	}
	return list, nil
}

// fxaAccessPrivileges: those of the accounts' ffs_admin on the sign-up policy and allowlist
func (f *FxaDB) fxaAccessPrivileges(ctx context.Context) ([]accessPrivilege, error) {
	lines, _, err := mysqlGrantLines(ctx, f.db)
	if err != nil {
		return nil, err
	}
	return fxaTablePrivileges(lines), nil
}

func fxaTablePrivileges(lines []string) []accessPrivilege {
	var list []accessPrivilege
	for _, table := range fxaAccessTables {
		for _, p := range tableWrites {
			list = append(list, accessPrivilege{Name: p + " on ffs." + table, Access: true,
				Held: mysqlHolds(lines, "ffs", "", "", p) || mysqlHolds(lines, "ffs", "", table, p)})
		}
	}
	return list
}

// accessGrantProblems: with the mode on, what changes who may use the server and is held; the
// privileges the admin UI calls in either mode and lacks; without the mode, the access ones
// it lacks that its forms need (needed: those of the Sync side; the accounts' only with
// self-hosted accounts, which have no such need of the Sync side's direct writes)
func accessGrantProblems(list []accessPrivilege, external bool, needed func(accessPrivilege) bool) (held, lacking []string) {
	for _, p := range list {
		switch {
		case p.Access && external && p.Held:
			held = append(held, p.Name)
		case p.Access && !external && !p.Held && needed(p):
			lacking = append(lacking, p.Name)
		case !p.Access && !p.Held:
			lacking = append(lacking, p.Name)
		}
	}
	return held, lacking
}

// accessNeeded: of the access privileges, those the admin UI's forms use without the mode (the
// direct writes on the lists and on config are never needed)
func accessNeeded(p accessPrivilege) bool {
	return !strings.HasPrefix(p.Name, "INSERT, UPDATE or DELETE on ")
}

// accessGrantsCheck: the setup check of the database's side of the mode. Shown with the mode
// on (ok or not), and without it only when the admin UI's users lack something; nothing with
// the admin UI on the Sync server's own user (no ADMIN_DB_PASSWORD: the database cannot tell
// the two apart) but a warning with the mode on
func (a *App) accessGrantsCheck(ctx context.Context) (setupCheck, bool) {
	if a.sync == nil {
		return setupCheck{}, false
	}
	setting := a.deployment.valueName("ADMIN_ACCESS_EXTERNAL")
	c := setupCheck{Name: accessGrantsCheckName}
	if a.sync.own == nil {
		if !a.accessExternal {
			return c, false
		}
		c.Text = "The admin UI connects to the Sync database as the Sync server's own user (no ADMIN_DB_PASSWORD): the database cannot refuse it a change of who may sync, only the admin UI does. Give the admin UI users of its own (docs/upgrading.md#the-admin-uis-own-database)."
		return c, true
	}
	var held, lacking []string
	reader := env("ADMIN_DB_SYNC_USER", "ffs_admin_sync")
	list, err := a.sync.syncAccessPrivileges(ctx)
	if err != nil {
		if !a.accessExternal {
			return c, false
		}
		c.Text = "Could not read the grants of " + reader + ": " + err.Error() + "."
		return c, true
	}
	h, l := accessGrantProblems(list, a.accessExternal, accessNeeded)
	for _, p := range h {
		held = append(held, reader+" "+p)
	}
	for _, p := range l {
		lacking = append(lacking, reader+" "+p)
	}
	if a.fxa != nil {
		list, err := a.fxa.fxaAccessPrivileges(ctx)
		if err != nil {
			if a.accessExternal {
				c.Text = "Could not read the grants of ffs_admin on the accounts database: " + err.Error() + "."
				return c, true
			}
		} else {
			h, l := accessGrantProblems(list, a.accessExternal, func(accessPrivilege) bool { return true })
			for _, p := range h {
				held = append(held, "ffs_admin "+p)
			}
			for _, p := range l {
				lacking = append(lacking, "ffs_admin "+p)
			}
		}
	}
	who, take, give := "The init container", "takes", "gives"
	if a.fxa != nil {
		who, take, give = "The init container and fxa-policy", "take", "give"
	}
	restart := "start " + strings.ToLower(who[:1]) + who[1:] + " again (" + a.deployment.startInit() + ")"
	switch {
	case len(held) > 0:
		c.Text = setting + " is on, but the database still lets the admin UI's users change who may use the server: " + strings.Join(held, ", ") + ". " +
			who + " " + take + " these back at every start with the mode on: " + restart + "."
		if !a.sync.postgres {
			c.Text += " With your own MariaDB or MySQL server the tokenserver's user needs GRANT OPTION on its database for that (docs/admin/accounts.md#the-database-enforces-it-too)."
		}
	case len(lacking) > 0 && a.accessExternal:
		c.Text = "The admin UI's users lack what the admin UI needs with " + setting + " too: " + strings.Join(lacking, ", ") + ". " + restart + "."
	case len(lacking) > 0:
		c.Text = "The admin UI's users lack what the admin UI needs: " + strings.Join(lacking, ", ") + ". " +
			who + " " + give + " them at every start without " + setting + ": " + restart + "."
	case a.accessExternal:
		c.OK = true
		c.Text = "The database refuses the admin UI's users every change of who may use the server (" + setting + "): " + reader + " has no EXECUTE on the procedures of max users and the allowlist"
		if a.fxa != nil {
			c.Text += ", ffs_admin only reads ffs.settings and ffs.signup_allowlist"
		}
		c.Text += "."
	default:
		return c, false
	}
	return c, true
}

const accessGrantsCheckName = "Access managed elsewhere: database grants"
