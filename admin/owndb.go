package main

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"strings"
)

// The admin UI's own database (ADMIN_DB_NAME, ffs_admin): the event log and the audit
// trail, the metrics, the notes, the schema levels seen, the daily jobs and the backup
// runs. Only its own user (ADMIN_DB_USER) reaches it, the Sync server's database users have
// no grant there: a compromised Sync server cannot read or rewrite the audit trail. The
// database containers create it (db/mysql/admin-user.sh, the PostgreSQL init
// container), on your own server database-setup.sql does (docs/reference/database-users.md#the-admin-uis-own-database).
//
// The Sync data is read by another user, ADMIN_DB_SYNC_USER (same password), which has
// nothing on the admin UI's database: SELECT, and the procedures of the init container on
// MariaDB and MySQL. The Sync server's user owns the tokenserver database and can put code
// there (procedures, functions, views over its tables, SQL SECURITY INVOKER): it runs with
// the privileges of whoever calls it. MySQL lets a session reach any database by its name,
// so the user that runs that code must be one that cannot touch ffs_admin.
//
// An install from before ADMIN_DB_PASSWORD has these tables in the tokenserver database.
// With a password, the admin UI copies them into its own database at its first start, in
// one transaction, then has the init container's ffs_drop_admin_tables drop the old ones
// (with the privileges of the tokenserver's user). ffs_meta records it: tables found there
// later (a backup of before restored, or rows the Sync server's user put there) are never
// copied again.

// dbCredentials: who the admin UI connects as to the Sync databases (prefix TOKENSERVER or
// STORAGE), and as whom to its own database. With ADMIN_DB_PASSWORD its own users, whatever
// the <prefix>_DB_USER and _PASSWORD: ADMIN_DB_SYNC_USER for the Sync data, ADMIN_DB_USER
// for its database; without (an install from before it) those, the Sync server's users,
// and no own database ("")
func dbCredentials(prefix string) (user, password, ownUser, own string, err error) {
	password = env("ADMIN_DB_PASSWORD", "")
	if password == "" {
		return env(prefix+"_DB_USER", ""), env(prefix+"_DB_PASSWORD", ""), "", "", nil
	}
	user, ownUser, own = env("ADMIN_DB_SYNC_USER", "ffs_admin_sync"), env("ADMIN_DB_USER", "ffs_admin_ui"), env("ADMIN_DB_NAME", "ffs_admin")
	if own == env("TOKENSERVER_DB_NAME", "") {
		return "", "", "", "", fmt.Errorf("ADMIN_DB_NAME must be a database of its own, not the tokenserver's %s", own)
	}
	// one user for both would run the Sync server's code with the rights on the event log
	if user == ownUser {
		return "", "", "", "", fmt.Errorf("ADMIN_DB_SYNC_USER and ADMIN_DB_USER must be two users, not both %s (docs/reference/database-users.md#the-admin-uis-own-database)", user)
	}
	return user, password, ownUser, own, nil
}

// ownTable: a table of the admin UI, its columns but the generated id; keyed: a primary
// key of its own (a copy keeps the row already in the admin UI's database), otherwise the
// rows are added in the order of their ids
type ownTable struct {
	name, columns string
	keyed         bool
}

var ownTables = []ownTable{
	{"ffs_events", "at, kind, detail", false},
	{"ffs_backups", "scope, started, finished, ok, bytes, error, location", false},
	{"ffs_metrics", "minute, name, count, total", true},
	{"ffs_gauges", "minute, name, value", true},
	{"ffs_account_notes", "uid, note, updated_at, updated_by", true},
	{"ffs_schema_levels", "name, level, updated_at", true},
	{"ffs_jobs", "name, last_run, result, failed", true},
}

const (
	metaSchema = `CREATE TABLE IF NOT EXISTS ffs_meta (name VARCHAR(64) PRIMARY KEY, value VARCHAR(255) NOT NULL)`
	// ffs_meta: what happened to the tables of the tokenserver database
	moveKey = "tokenserver_tables"
	// copied (the old ones still to drop), dropped (or none to copy)
	moveCopied, moveDropped = "copied", "dropped"
	// rows per INSERT of a copy
	copyBatch = 200
)

// moveState: where the admin UI's tables of before are, for its setup check
type moveState struct {
	Copied map[string]int64 // rows copied at this start, per table
	Left   []string         // tables of before still in the tokenserver database
	Err    string           // why they are left there
	// they were copied before: these are newer, not copied (Left)
	Again bool
	// PostgreSQL: the role that owns the Sync tables, when it is a superuser (it reads
	// every database of the server, the admin UI's too)
	Superuser string
	// PostgreSQL: what of the admin UI's database another role owns (foreignObjects), or why
	// it could not be checked
	Foreign    []string
	ForeignErr string
}

// foreignObjects: PostgreSQL, the tables, functions, operators, types and schemas of the
// admin UI's database that its role (ADMIN_DB_USER) does not own, at most 5. Nobody else
// creates anything there: something of another role (a database copied from a template1
// where the Sync server's role left ffs_* tables with triggers, on PostgreSQL 11 to 14)
// would run its code, or keep the audit trail, where the admin UI writes. Not the objects
// of PostgreSQL itself, nor the schemas of temporary tables. With pg_catalog alone in the
// search path: an operator of another role in public (>= of an oid and an integer) would
// be picked over pg_catalog's for the exact types, run its code and hide the rest
func (s *SyncDB) foreignObjects(ctx context.Context) ([]string, error) {
	if s.own == nil || !s.postgres {
		return nil, nil
	}
	tx, err := s.own.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, "SET LOCAL search_path = pg_catalog, pg_temp"); err != nil {
		return nil, err
	}
	rows, err := tx.QueryContext(ctx, `SELECT o.kind || ' ' || o.name || ' of ' || pg_catalog.pg_get_userbyid(o.owner) FROM (
		SELECT 'table' AS kind, pg_catalog.format('%I.%I', n.nspname, c.relname) AS name, c.relowner AS owner, c.oid
			FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
		UNION ALL SELECT 'function', p.oid::pg_catalog.regprocedure::text, p.proowner, p.oid FROM pg_catalog.pg_proc p
		UNION ALL SELECT 'operator', o.oid::pg_catalog.regoperator::text, o.oprowner, o.oid FROM pg_catalog.pg_operator o
		UNION ALL SELECT 'type', pg_catalog.format('%I.%I', n.nspname, t.typname), t.typowner, t.oid
			FROM pg_catalog.pg_type t JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
		UNION ALL SELECT 'schema', n.nspname::text, n.nspowner, n.oid FROM pg_catalog.pg_namespace n
			WHERE n.nspname NOT LIKE 'pg\_temp\_%' AND n.nspname NOT LIKE 'pg\_toast\_temp\_%') o
		WHERE o.oid OPERATOR(pg_catalog.>=) 16384::pg_catalog.oid
			AND o.owner OPERATOR(pg_catalog.<>) (SELECT r.oid FROM pg_catalog.pg_roles r WHERE r.rolname OPERATOR(pg_catalog.=) current_user)
		ORDER BY 1 LIMIT 5`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var found []string
	for rows.Next() {
		var what string
		if err := rows.Scan(&what); err != nil {
			return nil, err
		}
		found = append(found, what)
	}
	return found, rows.Err()
}

// checkOwnDB: at the start, before anything is written there: the admin UI does not start
// on a database that holds what another role owns (foreignObjects)
func (s *SyncDB) checkOwnDB(ctx context.Context) error {
	found, err := s.foreignObjects(ctx)
	if err != nil {
		return fmt.Errorf("the owners in the admin UI's database %s: %w", s.ownName, err)
	}
	if len(found) > 0 {
		return fmt.Errorf("the admin UI's database %s holds what its role ADMIN_DB_USER does not own: %s. Nobody else creates anything there: "+
			"look at it and drop it as a superuser, or create the database again from template0 (docs/reference/database-users.md#the-admin-uis-own-database); the admin UI does not start until then", s.ownName, strings.Join(found, ", "))
	}
	return nil
}

func (s *SyncDB) meta(ctx context.Context, name string) (string, error) {
	var value string
	err := s.own.QueryRowContext(ctx, s.q("SELECT value FROM ffs_meta WHERE name = ?"), name).Scan(&value)
	if err == sql.ErrNoRows {
		return "", nil
	}
	return value, err
}

type execer interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
}

func (s *SyncDB) setMeta(ctx context.Context, db execer, name, value string) error {
	upsert := "INSERT INTO ffs_meta (name, value) VALUES (?, ?) ON DUPLICATE KEY UPDATE value = VALUES(value)"
	if s.postgres {
		upsert = "INSERT INTO ffs_meta (name, value) VALUES ($1, $2) ON CONFLICT (name) DO UPDATE SET value = EXCLUDED.value"
	}
	_, err := db.ExecContext(ctx, upsert, name, value)
	return err
}

// oldTables: the admin UI's tables in the tokenserver database, in the order of ownTables
func (s *SyncDB) oldTables(ctx context.Context) ([]ownTable, error) {
	query := `SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name LIKE 'ffs\_%'`
	if s.postgres {
		query = `SELECT table_name FROM information_schema.tables WHERE table_schema = current_schema() AND table_name LIKE 'ffs\_%'`
	}
	rows, err := s.db.QueryContext(ctx, query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	found := map[string]bool{}
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			return nil, err
		}
		found[strings.ToLower(name)] = true
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	var old []ownTable
	for _, t := range ownTables {
		if found[t.name] {
			old = append(old, t)
		}
	}
	return old, nil
}

func tableNames(tables []ownTable) []string {
	names := make([]string, len(tables))
	for i, t := range tables {
		names[i] = t.name
	}
	return names
}

// copyStatement: the INSERT of n rows of t into the admin UI's database
func (s *SyncDB) copyStatement(t ownTable, n int) string {
	columns := len(strings.Split(t.columns, ","))
	row := "(" + strings.TrimSuffix(strings.Repeat("?, ", columns), ", ") + ")"
	values := strings.TrimSuffix(strings.Repeat(row+", ", n), ", ")
	switch {
	case !t.keyed:
		return s.q("INSERT INTO " + t.name + " (" + t.columns + ") VALUES " + values)
	case s.postgres:
		return s.q("INSERT INTO " + t.name + " (" + t.columns + ") VALUES " + values + " ON CONFLICT DO NOTHING")
	}
	return "INSERT IGNORE INTO " + t.name + " (" + t.columns + ") VALUES " + values
}

// copyTable copies the rows of the old table t into tx, the admin UI's database
func (s *SyncDB) copyTable(ctx context.Context, tx *sql.Tx, t ownTable) (int64, error) {
	query := "SELECT " + t.columns + " FROM " + t.name
	if !t.keyed {
		query += " ORDER BY id"
	}
	rows, err := s.db.QueryContext(ctx, query)
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	columns := len(strings.Split(t.columns, ","))
	var batch []any
	var copied int64
	flush := func() error {
		if len(batch) == 0 {
			return nil
		}
		_, err := tx.ExecContext(ctx, s.copyStatement(t, len(batch)/columns), batch...)
		batch = batch[:0]
		return err
	}
	for rows.Next() {
		row := make([]any, columns)
		ptrs := make([]any, columns)
		for i := range row {
			ptrs[i] = &row[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return copied, err
		}
		batch = append(batch, row...)
		copied++
		if len(batch) >= copyBatch*columns {
			if err := flush(); err != nil {
				return copied, err
			}
		}
	}
	if err := rows.Err(); err != nil {
		return copied, err
	}
	return copied, flush()
}

// dropOldTables: through the init container's procedure, the admin UI cannot drop them
func (s *SyncDB) dropOldTables(ctx context.Context) error {
	query := "CALL ffs_drop_admin_tables()"
	if s.postgres {
		query = "SELECT ffs_drop_admin_tables()"
	}
	_, err := s.db.ExecContext(ctx, query)
	return err
}

// moveOwnTables moves the tables of before from the tokenserver database into the admin
// UI's own (see above), once; nothing without one. Run after newRecorder created the tables.
func (s *SyncDB) moveOwnTables(ctx context.Context) moveState {
	var st moveState
	if s.own == nil {
		return st
	}
	if s.postgres {
		st.Superuser = s.superuserOwner(ctx)
	}
	fail := func(what string, err error) moveState {
		st.Err = what + ": " + err.Error()
		log.Printf("admin UI tables of the tokenserver database: %s", st.Err)
		return st
	}
	if _, err := s.own.ExecContext(ctx, metaSchema); err != nil {
		return fail("creating ffs_meta", err)
	}
	state, err := s.meta(ctx, moveKey)
	if err != nil {
		return fail("reading ffs_meta", err)
	}
	old, err := s.oldTables(ctx)
	if err != nil {
		return fail("listing the tables of the tokenserver database", err)
	}
	if len(old) > 0 {
		st.Left = tableNames(old)
	}
	switch {
	case state == moveDropped && len(old) > 0:
		// copied long ago: these come from a backup of before, or from the Sync server's user
		st.Again = true
		log.Printf("admin UI tables of the tokenserver database: %s are there again, not copied (already moved to %s)", strings.Join(st.Left, ", "), s.ownName)
		return st
	case state == moveDropped:
		return st
	case state == "" && len(old) > 0:
		tx, err := s.own.BeginTx(ctx, nil)
		if err != nil {
			return fail("copying", err)
		}
		st.Copied = map[string]int64{}
		for _, t := range old {
			n, err := s.copyTable(ctx, tx, t)
			if err != nil {
				tx.Rollback()
				st.Copied = nil
				return fail("copying "+t.name+" (nothing copied, it stays where it is)", err)
			}
			st.Copied[t.name] = n
		}
		// with the rows: never twice
		if err := s.setMeta(ctx, tx, moveKey, moveCopied); err != nil {
			tx.Rollback()
			st.Copied = nil
			return fail("copying (nothing copied)", err)
		}
		if err := tx.Commit(); err != nil {
			st.Copied = nil
			return fail("copying (nothing copied)", err)
		}
		log.Printf("admin UI tables of the tokenserver database: copied into %s (%s)", s.ownName, copiedSummary(st.Copied))
	}
	if len(old) > 0 {
		if err := s.dropOldTables(ctx); err != nil {
			return fail("copied into "+s.ownName+", but dropping the old ones", err)
		}
		st.Left = nil
		log.Printf("admin UI tables of the tokenserver database: dropped %s", strings.Join(tableNames(old), ", "))
	}
	if err := s.setMeta(ctx, s.own, moveKey, moveDropped); err != nil {
		return fail("writing ffs_meta", err)
	}
	return st
}

// copiedSummary: "1520 events, 3 notes..." of what a copy moved
func copiedSummary(copied map[string]int64) string {
	words := map[string]string{"ffs_events": "events", "ffs_backups": "backup runs", "ffs_metrics": "metrics",
		"ffs_gauges": "gauges", "ffs_account_notes": "notes", "ffs_schema_levels": "schema levels", "ffs_jobs": "jobs"}
	var parts []string
	for _, t := range ownTables {
		if n, ok := copied[t.name]; ok {
			parts = append(parts, fmt.Sprintf("%d %s", n, words[t.name]))
		}
	}
	return strings.Join(parts, ", ")
}

// superuserSyncRole: the role the Sync server connects as when it is a superuser, "" when it
// is none. pg_stat_activity shows every session's role to any role (not its query): of the
// roles with sessions of more than 2 minutes on the Sync database, the admin UI's own left out,
// the one with the most is the Sync server, whose pool keeps its connections open. Migrations,
// the init and the backups connect for a moment, also as a superuser that owns the tables (an
// integrator's owner role), and a psql session of an administrator is one: neither is taken
// for it. With no such session (the Sync server just started, or not running), the owner of
// the tables decides, as before (superuserOwner).
func (s *SyncDB) superuserSyncRole(ctx context.Context) string {
	var role string
	var super bool
	err := s.db.QueryRowContext(ctx, `SELECT a.usename, bool_or(r.rolsuper)
		FROM pg_stat_activity a JOIN pg_roles r ON r.oid = a.usesysid
		WHERE a.datname = current_database() AND a.backend_type = 'client backend'
			AND a.usename <> current_user AND a.backend_start < now() - interval '2 minutes'
		GROUP BY a.usename ORDER BY count(*) DESC, a.usename LIMIT 1`).Scan(&role, &super)
	if err != nil {
		return s.superuserOwner(ctx)
	}
	if super {
		return role
	}
	return ""
}

// superuserOwner: the owner of the Sync tables when it is a superuser, "" otherwise. The
// PostgreSQL container of the stack makes SYNC_POSTGRES_USER one (the image does); without
// SYNC_POSTGRES_APP_USER it is also the Sync server's role, the owner of the tables, and then
// reaches every database of the server. With it the init container gives the tables to
// that role.
func (s *SyncDB) superuserOwner(ctx context.Context) string {
	var owner string
	err := s.db.QueryRowContext(ctx, `SELECT r.rolname FROM pg_class c JOIN pg_roles r ON r.oid = c.relowner
		JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relname = 'users' AND n.nspname = current_schema() AND r.rolsuper`).Scan(&owner)
	if err != nil {
		return ""
	}
	return owner
}

// upgradeSteps: how an install from before ADMIN_DB_PASSWORD gets it, as docs/upgrading.md#the-admin-uis-own-database says
// for compose, or for the Quadlets (ADMIN_DEPLOYMENT=quadlets), where --upgrade writes no
// unit; with the Helm chart, whose Secret has it (an existingSecret may not)
func upgradeSteps(d deployment) string {
	if k := d.Kubernetes(); k != nil {
		return "Add ADMIN_DB_PASSWORD to your existingSecret (the chart's own Secret " + k.Secret() + " has it; your own database server: run the new " +
			"database-setup.sql there first), then " + k.helmUpgrade("") + ": the databases and the init container create the admin UI's users when they start"
	}
	if d.Quadlets() {
		return "Stop the units (the one-shot ones and the databases too), run ./prepare_environment.sh again with the same answers (it writes ADMIN_DB_PASSWORD " +
			"into .env and the units; --upgrade is for compose only), give the Sync database users their new passwords (your own database server: run the new " +
			"database-setup.sql there) and systemctl --user start firefox-sync-admin.service firefox-sync-syncstorage.service, as docs/upgrading.md#with-quadlets says for the Quadlets"
	}
	return "Run ./prepare_environment.sh --upgrade (it sets ADMIN_DB_PASSWORD in .env) and docker compose up -d"
}

// ownDBHint: the same, short, for the log
func ownDBHint(d deployment) string {
	if d.Kubernetes() != nil {
		return "ADMIN_DB_PASSWORD in the chart's Secret, then helm upgrade"
	}
	if d.Quadlets() {
		return "./prepare_environment.sh run again and the steps of docs/upgrading.md#with-quadlets for the Quadlets"
	}
	return "./prepare_environment.sh --upgrade, docs/upgrading.md#the-admin-uis-own-database"
}

// ownDBCheck: the setup check of where the event log is (d: ADMIN_DEPLOYMENT, the steps to
// get there)
func ownDBCheck(s *SyncDB, st moveState, d deployment) setupCheck {
	c := setupCheck{Name: "Event log (ADMIN_DB_PASSWORD)"}
	switch {
	case s.own == nil:
		c.Text = "The event log, the audit trail and the notes are in the tokenserver database, which the Sync server's database user can read and change. " +
			upgradeSteps(d) + ": they move into a database of their own (docs/upgrading.md#the-admin-uis-own-database)."
	case st.ForeignErr != "":
		c.Text = fmt.Sprintf("Could not check that everything in the admin UI's database %s is its role's: %s.", s.ownName, st.ForeignErr)
	case len(st.Foreign) > 0:
		c.Text = fmt.Sprintf("The admin UI's database %s holds what its role does not own: %s. Nobody else creates anything there: its code runs where the admin UI writes. "+
			"Look at it and drop it as a superuser (docs/reference/database-users.md#the-admin-uis-own-database); the admin UI does not start again until then.", s.ownName, strings.Join(st.Foreign, ", "))
	case st.Err != "" && len(st.Left) > 0:
		c.Text = fmt.Sprintf("The event log is in %s, out of the Sync server's reach, but the admin UI's tables of before are still in the tokenserver database (%s): %s. "+
			"Fix it and restart the admin UI, nothing is lost (docs/admin/monitoring.md#event-log).", s.ownName, strings.Join(st.Left, ", "), st.Err)
	case st.Err != "":
		c.Text = fmt.Sprintf("The event log is in %s, but: %s.", s.ownName, st.Err)
	case st.Again:
		c.Text = fmt.Sprintf("The event log is in %s, out of the Sync server's reach, and the tokenserver database has admin UI tables again (%s), from a backup of before or from the Sync server's user: they were not copied. "+
			"Look at them, then drop them as the tokenserver user.", s.ownName, strings.Join(st.Left, ", "))
	case st.Superuser != "":
		fix := "Run ./prepare_environment.sh --upgrade (it sets SYNC_POSTGRES_APP_USER and SYNC_POSTGRES_APP_PASSWORD) and docker compose up -d: the Sync server gets a role of its own, no superuser (docs/reference/database-users.md#postgresql)."
		if d.Kubernetes() != nil {
			// the chart's bundled PostgreSQL has the Sync server's own role: your own server
			fix = "Give the Sync server a role of its own on your database server, no superuser, owner of the Sync tables, as docs/reference/database-users.md#postgresql says, and the chart its name and password."
		}
		c.Text = fmt.Sprintf("The event log is in its own database %s, but the Sync server connects as %s, a superuser of the PostgreSQL server (the stack's database container makes SYNC_POSTGRES_USER one): it can still read and change the event log. "+
			"%s", s.ownName, st.Superuser, fix)
	default:
		c.OK = true
		c.Text = fmt.Sprintf("The event log, the audit trail and the notes are in %s, which only the admin UI's database user reaches: the Sync server's users cannot read or change them.", s.ownName)
	}
	return c
}
