package main

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"slices"
	"strings"
	"testing"
)

func TestDBCredentials(t *testing.T) {
	t.Setenv("TOKENSERVER_DB_USER", "tokenserver")
	t.Setenv("TOKENSERVER_DB_PASSWORD", "sync-secret")
	t.Setenv("TOKENSERVER_DB_NAME", "tokenserver")
	t.Setenv("STORAGE_DB_USER", "syncstorage")
	t.Setenv("STORAGE_DB_PASSWORD", "storage-secret")
	creds := func(prefix string) (string, error) {
		user, password, ownUser, own, err := dbCredentials(prefix)
		return strings.Join([]string{user, password, ownUser, own}, " "), err
	}
	// an install from before ADMIN_DB_PASSWORD: the Sync server's users, no own database
	t.Setenv("ADMIN_DB_PASSWORD", "")
	for prefix, want := range map[string]string{"TOKENSERVER": "tokenserver sync-secret  ", "STORAGE": "syncstorage storage-secret  "} {
		if got, err := creds(prefix); got != want || err != nil {
			t.Errorf("without ADMIN_DB_PASSWORD, %s: %q %v", prefix, got, err)
		}
	}
	// its own users, whatever the Sync users (compose passes the admin password there): the
	// Sync data as ffs_admin_sync, which cannot reach ffs_admin, the event log as ffs_admin_ui
	t.Setenv("ADMIN_DB_PASSWORD", "admin-secret")
	for _, prefix := range []string{"TOKENSERVER", "STORAGE"} {
		if got, err := creds(prefix); got != "ffs_admin_sync admin-secret ffs_admin_ui ffs_admin" || err != nil {
			t.Errorf("with ADMIN_DB_PASSWORD, %s: %q %v", prefix, got, err)
		}
	}
	t.Setenv("ADMIN_DB_USER", "me")
	t.Setenv("ADMIN_DB_SYNC_USER", "my_reader")
	t.Setenv("ADMIN_DB_NAME", "mine")
	if got, _ := creds("TOKENSERVER"); got != "my_reader admin-secret me mine" {
		t.Errorf("ADMIN_DB_USER, ADMIN_DB_SYNC_USER and ADMIN_DB_NAME: %q", got)
	}
	// one user for both: the code the Sync server's user puts in the tokenserver database
	// would run with the rights on the event log
	t.Setenv("ADMIN_DB_SYNC_USER", "me")
	if _, err := creds("STORAGE"); err == nil || !strings.Contains(err.Error(), "must be two users") {
		t.Errorf("ADMIN_DB_SYNC_USER = ADMIN_DB_USER: %v", err)
	}
	t.Setenv("ADMIN_DB_SYNC_USER", "my_reader")
	// its tables in the tokenserver database again: refused
	t.Setenv("ADMIN_DB_NAME", "tokenserver")
	if _, err := creds("TOKENSERVER"); err == nil || !strings.Contains(err.Error(), "a database of its own") {
		t.Errorf("ADMIN_DB_NAME of the tokenserver: %v", err)
	}
}

func TestCopyStatement(t *testing.T) {
	events, notes := ownTables[0], ownTables[4]
	for _, c := range []struct {
		postgres bool
		table    ownTable
		rows     int
		want     string
	}{
		{false, events, 2, "INSERT INTO ffs_events (at, kind, detail) VALUES (?, ?, ?), (?, ?, ?)"},
		{true, events, 2, "INSERT INTO ffs_events (at, kind, detail) VALUES ($1, $2, $3), ($4, $5, $6)"},
		// a row with its own key already in the admin UI's database is kept
		{false, notes, 1, "INSERT IGNORE INTO ffs_account_notes (uid, note, updated_at, updated_by) VALUES (?, ?, ?, ?)"},
		{true, notes, 1, "INSERT INTO ffs_account_notes (uid, note, updated_at, updated_by) VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING"},
	} {
		if got := (&SyncDB{postgres: c.postgres}).copyStatement(c.table, c.rows); got != c.want {
			t.Errorf("postgres %v: %s", c.postgres, got)
		}
	}
}

// movingDBs: the tokenserver database with the old tables given (the events of before
// in it), the admin UI's own database in the state given (ffs_meta)
func movingDBs(old []string, state string) (*SyncDB, *fakeFxa, *fakeFxa) {
	ts, own := &fakeFxa{}, &fakeFxa{}
	ts.answer = func(query string, _ []driver.Value) *fakeRows {
		switch {
		case strings.Contains(query, "FROM information_schema.tables"):
			rows := &fakeRows{cols: []string{"table_name"}}
			for _, name := range old {
				rows.rows = append(rows.rows, []driver.Value{name})
			}
			return rows
		case query == "SELECT at, kind, detail FROM ffs_events ORDER BY id":
			return &fakeRows{cols: []string{"at", "kind", "detail"}, rows: [][]driver.Value{
				{int64(1700000000000), "admin", "Max users set to 3 by admin (password)"}, {int64(1700000001000), "health", "Sync server is back up"}}}
		case query == "SELECT uid, note, updated_at, updated_by FROM ffs_account_notes":
			return &fakeRows{cols: []string{"uid", "note", "at", "by"}, rows: [][]driver.Value{{fakeUID, "the neighbour", int64(1700000000000), "admin (password)"}}}
		}
		return &fakeRows{cols: []string{"x"}}
	}
	own.answer = func(query string, _ []driver.Value) *fakeRows {
		if strings.HasPrefix(query, "SELECT value FROM ffs_meta") && state != "" {
			return &fakeRows{cols: []string{"value"}, rows: [][]driver.Value{{state}}}
		}
		return nil
	}
	return &SyncDB{db: sql.OpenDB(ts), own: sql.OpenDB(own), ownName: "ffs_admin"}, ts, own
}

// metaWrites: the states written into ffs_meta
func metaWrites(own *fakeFxa) []string {
	var states []string
	for i, q := range own.statements() {
		if strings.HasPrefix(q, "INSERT INTO ffs_meta") {
			states = append(states, own.args[i][1].(string))
		}
	}
	return states
}

func TestMoveOwnTables(t *testing.T) {
	ctx := context.Background()

	// an install from before: the events and the notes copied in one transaction, marked
	// copied with them, the old tables dropped by the init container's procedure
	s, ts, own := movingDBs([]string{"ffs_events", "ffs_account_notes", "users", "ffs_unknown"}, "")
	st := s.moveOwnTables(ctx)
	if st.Err != "" || st.Copied["ffs_events"] != 2 || st.Copied["ffs_account_notes"] != 1 || len(st.Copied) != 2 || st.Left != nil {
		t.Errorf("moved: %+v", st)
	}
	want := []string{
		metaSchema,
		"BEGIN",
		"INSERT INTO ffs_events (at, kind, detail) VALUES (?, ?, ?), (?, ?, ?)",
		"INSERT IGNORE INTO ffs_account_notes (uid, note, updated_at, updated_by) VALUES (?, ?, ?, ?)",
		"INSERT INTO ffs_meta (name, value) VALUES (?, ?) ON DUPLICATE KEY UPDATE value = VALUES(value)",
		"COMMIT",
		"INSERT INTO ffs_meta (name, value) VALUES (?, ?) ON DUPLICATE KEY UPDATE value = VALUES(value)",
	}
	if got := own.statements(); !slices.Equal(got, want) {
		t.Errorf("own database:\n%s", strings.Join(got, "\n"))
	}
	if got := metaWrites(own); !slices.Equal(got, []string{moveCopied, moveDropped}) {
		t.Errorf("ffs_meta: %q", got)
	}
	// in their order, the detail as it was
	if args := own.args[2]; len(args) != 6 || args[2] != "Max users set to 3 by admin (password)" || args[5] != "Sync server is back up" {
		t.Errorf("events copied: %v", args)
	}
	if got := ts.statements(); !slices.Equal(got, []string{"CALL ffs_drop_admin_tables()"}) {
		t.Errorf("tokenserver database: %q", got)
	}
	if got := copiedSummary(st.Copied); got != "2 events, 1 notes" {
		t.Errorf("summary: %q", got)
	}
	if c := ownDBCheck(s, st, deployment{}); !c.OK {
		t.Errorf("check after the move: %+v", c)
	}

	// a new install: nothing to copy, marked so that later tables are never copied
	s, ts, own = movingDBs([]string{"users"}, "")
	if st := s.moveOwnTables(ctx); st.Err != "" || st.Copied != nil || st.Left != nil {
		t.Errorf("new install: %+v", st)
	}
	if got := metaWrites(own); !slices.Equal(got, []string{moveDropped}) || len(ts.statements()) != 0 {
		t.Errorf("new install: %q %q", got, ts.statements())
	}

	// moved long ago, tables there again (a backup of before, or the Sync server's user):
	// not copied, not dropped, said by the setup check
	s, ts, own = movingDBs([]string{"ffs_events"}, moveDropped)
	st = s.moveOwnTables(ctx)
	if !st.Again || st.Copied != nil || !slices.Equal(st.Left, []string{"ffs_events"}) || len(ts.statements()) != 0 || len(metaWrites(own)) != 0 {
		t.Errorf("again: %+v %q %q", st, ts.statements(), own.statements())
	}
	if c := ownDBCheck(s, st, deployment{}); c.OK || !strings.Contains(c.Text, "admin UI tables again (ffs_events)") || !strings.Contains(c.Text, "not copied") {
		t.Errorf("check, again: %+v", c)
	}

	// copied, the drop failed last time: dropped now, not copied twice
	s, ts, own = movingDBs([]string{"ffs_events"}, moveCopied)
	if st := s.moveOwnTables(ctx); st.Err != "" || st.Copied != nil || st.Left != nil {
		t.Errorf("copied before: %+v", st)
	}
	if got := own.statements(); slices.Contains(got, "BEGIN") || !slices.Equal(metaWrites(own), []string{moveDropped}) || !slices.Equal(ts.statements(), []string{"CALL ffs_drop_admin_tables()"}) {
		t.Errorf("copied before: %q %q", got, ts.statements())
	}

	// the drop fails (no EXECUTE, an old init container): copied, left there, said
	s, ts, own = movingDBs([]string{"ffs_events"}, "")
	ts.execErr = func(query string, _ []driver.Value) error {
		return errors.New("execute command denied to user 'ffs_admin_ui'@'%' for routine 'tokenserver.ffs_drop_admin_tables'")
	}
	st = s.moveOwnTables(ctx)
	if !strings.HasPrefix(st.Err, "copied into ffs_admin, but dropping the old ones: execute command denied") || !slices.Equal(st.Left, []string{"ffs_events"}) {
		t.Errorf("drop failed: %+v", st)
	}
	if got := metaWrites(own); !slices.Equal(got, []string{moveCopied}) {
		t.Errorf("drop failed, ffs_meta: %q", got)
	}
	if c := ownDBCheck(s, st, deployment{}); c.OK || !strings.Contains(c.Text, "still in the tokenserver database (ffs_events)") || !strings.Contains(c.Text, "nothing is lost") {
		t.Errorf("check, drop failed: %+v", c)
	}

	// the old tables cannot be read (no SELECT): nothing copied, rolled back, tried again
	// at the next start
	s, ts, own = movingDBs([]string{"ffs_events"}, "")
	ts.queryErr = func(query string) error {
		if strings.HasPrefix(query, "SELECT at, kind, detail FROM ffs_events") {
			return errors.New("SELECT command denied to user 'ffs_admin_ui'@'%' for table 'ffs_events'")
		}
		return nil
	}
	st = s.moveOwnTables(ctx)
	if !strings.HasPrefix(st.Err, "copying ffs_events (nothing copied, it stays where it is): SELECT command denied") || st.Copied != nil {
		t.Errorf("not readable: %+v", st)
	}
	if got := own.statements(); !slices.Contains(got, "ROLLBACK") || len(metaWrites(own)) != 0 || len(ts.statements()) != 0 {
		t.Errorf("not readable: %q %q", got, ts.statements())
	}

	// no own database: nothing to do, and the setup check says how to get one
	s = &SyncDB{db: sql.OpenDB(&fakeFxa{})}
	if st := s.moveOwnTables(ctx); st.Err != "" || st.Copied != nil {
		t.Errorf("without ADMIN_DB_PASSWORD: %+v", st)
	}
	if c := ownDBCheck(s, moveState{}, deployment{}); c.OK || !strings.Contains(c.Text, "which the Sync server's database user can read and change") ||
		!strings.Contains(c.Text, "prepare_environment.sh --upgrade (it sets ADMIN_DB_PASSWORD") || !strings.Contains(c.Text, "docker compose up -d") {
		t.Errorf("check without ADMIN_DB_PASSWORD: %+v", c)
	}
	// with the Quadlets (ADMIN_DEPLOYMENT=quadlets): their steps of docs/upgrading.md#with-quadlets, no compose
	if c := ownDBCheck(s, moveState{}, deployment{kind: "quadlets"}); c.OK || strings.Contains(c.Text, "docker compose") || strings.Contains(c.Text, "Run ./prepare_environment.sh --upgrade") ||
		!strings.Contains(c.Text, "run ./prepare_environment.sh again with the same answers") || !strings.Contains(c.Text, "database-setup.sql") ||
		!strings.Contains(c.Text, "systemctl --user start firefox-sync-admin.service firefox-sync-syncstorage.service") {
		t.Errorf("check without ADMIN_DB_PASSWORD, Quadlets: %+v", c)
	}
	if compose, quadlets := ownDBHint(deployment{}), ownDBHint(deployment{kind: "quadlets"}); !strings.Contains(compose, "--upgrade") || strings.Contains(quadlets, "--upgrade") || !strings.Contains(quadlets, "Quadlets") {
		t.Errorf("the line of the log: %q, %q", compose, quadlets)
	}
	// PostgreSQL's container without SYNC_POSTGRES_APP_USER: the Sync server's role is a superuser
	s = &SyncDB{own: sql.OpenDB(&fakeFxa{}), ownName: "ffs_admin", postgres: true}
	if c := ownDBCheck(s, moveState{Superuser: "syncserver"}, deployment{}); c.OK || !strings.Contains(c.Text, "connects as syncserver, a superuser") || !strings.Contains(c.Text, "SYNC_POSTGRES_APP_USER") {
		t.Errorf("check with a superuser: %+v", c)
	}
}

// the procedures of the init container on MariaDB and MySQL, the grants on PostgreSQL
func TestSyncWritesOfTheAdminUser(t *testing.T) {
	ctx := context.Background()
	for _, postgres := range []bool{false, true} {
		fake := &fakeFxa{}
		s := &SyncDB{db: sql.OpenDB(fake), postgres: postgres}
		if err := s.SetMaxUsers(ctx, 5, false); err != nil {
			t.Fatal(err)
		}
		if err := s.DeleteUserRows(ctx, []int64{42}); err != nil {
			t.Fatal(err)
		}
		want := []string{"CALL ffs_set_max_users(?)", "CALL ffs_delete_user_row(?)"}
		if postgres {
			want = []string{"UPDATE config SET config_value = $1 WHERE config_key = $2", "DELETE FROM users WHERE uid = $1"}
		}
		if got := fake.statements(); !slices.Equal(got, want) || fake.args[0][0] != "5" || fake.args[1][0] != int64(42) {
			t.Errorf("postgres %v: %q %v", postgres, got, fake.args)
		}
	}
}

// the admin UI's tables in its own database, the Sync data in the tokenserver's
func TestOwnTablesInOwnDatabase(t *testing.T) {
	ctx := context.Background()
	ts, own := &fakeFxa{}, &fakeFxa{}
	s := &SyncDB{db: sql.OpenDB(ts), own: sql.OpenDB(own), ownName: "ffs_admin"}
	rec, err := newRecorder(ctx, s)
	if err != nil {
		t.Fatal(err)
	}
	rec.Event("admin", "Max users set to 3 by admin (password)")
	if err := s.SetNote(ctx, fakeUID, "the neighbour", "admin (password)"); err != nil {
		t.Fatal(err)
	}
	if err := s.StoreJob(ctx, Job{Name: "purge"}); err != nil {
		t.Fatal(err)
	}
	if err := s.StoreLevel(ctx, SchemaLevel{Database: "Tokenserver", Level: "1"}); err != nil {
		t.Fatal(err)
	}
	s.Backups(ctx)
	if err := s.SetMaxUsers(ctx, 3, false); err != nil {
		t.Fatal(err)
	}
	for _, q := range ts.statements() {
		if strings.Contains(q, "ffs_") && !strings.HasPrefix(q, "CALL ffs_") {
			t.Errorf("in the tokenserver database: %s", q)
		}
	}
	for _, q := range own.statements() {
		if !strings.Contains(q, "ffs_") {
			t.Errorf("in the admin UI's database: %s", q)
		}
	}
	if got := strings.Join(own.statements(), "\n"); !strings.Contains(got, "INSERT INTO ffs_events") || !strings.Contains(got, "INSERT INTO ffs_account_notes") ||
		!strings.Contains(got, "INSERT INTO ffs_jobs") || !strings.Contains(got, "INSERT INTO ffs_schema_levels") || !strings.Contains(got, "CREATE TABLE IF NOT EXISTS ffs_backups") {
		t.Errorf("admin UI's database:\n%s", got)
	}
	if got := own.queried("FROM ffs_backups"); len(got) != 1 {
		t.Errorf("backups read from the admin UI's database: %v", got)
	}
}

// PostgreSQL: the admin UI does not start on a database with what another role owns there
func TestForeignObjectsInTheOwnDatabase(t *testing.T) {
	ctx := context.Background()
	own := &fakeFxa{}
	var foreign [][]driver.Value
	own.answer = func(query string, _ []driver.Value) *fakeRows {
		if strings.Contains(query, "pg_catalog.pg_get_userbyid(o.owner)") {
			return &fakeRows{cols: []string{"what"}, rows: foreign}
		}
		return nil
	}
	s := &SyncDB{db: sql.OpenDB(&fakeFxa{}), own: sql.OpenDB(own), ownName: "ffs_admin", postgres: true}
	if err := s.checkOwnDB(ctx); err != nil {
		t.Errorf("nothing of another role: %v", err)
	}
	// with pg_catalog alone in the search path, in its transaction, before the query
	if got := own.statements(); len(got) < 2 || got[0] != "BEGIN" || got[1] != "SET LOCAL search_path = pg_catalog, pg_temp" {
		t.Errorf("statements %q", got)
	}
	// fails closed: not checked, not started, the setup check says so
	own.queryErr = func(query string) error {
		if strings.Contains(query, "pg_get_userbyid(o.owner)") {
			return errors.New("permission denied for table pg_class")
		}
		return nil
	}
	if err := s.checkOwnDB(ctx); err == nil || !strings.Contains(err.Error(), "permission denied") {
		t.Errorf("an error of the check: %v", err)
	}
	if c := ownDBCheck(s, moveState{ForeignErr: "permission denied"}, deployment{}); c.OK || !strings.Contains(c.Text, "Could not check") {
		t.Errorf("setup check when the check fails: %+v", c)
	}
	own.queryErr = nil
	// an ffs_events of the Sync server's role, in a schema of its own first in the search path
	foreign = [][]driver.Value{{"schema ffs_admin_ui of syncserver_app"}, {"table ffs_admin_ui.ffs_events of syncserver_app"}}
	err := s.checkOwnDB(ctx)
	if err == nil || !strings.Contains(err.Error(), "table ffs_admin_ui.ffs_events of syncserver_app") || !strings.Contains(err.Error(), "does not start") {
		t.Errorf("not refused: %v", err)
	}
	foreign = [][]driver.Value{{"table ffs_admin_ui.ffs_events of syncserver_app"}}
	found, _ := s.foreignObjects(ctx)
	if c := ownDBCheck(s, moveState{Foreign: found}, deployment{}); c.OK || !strings.Contains(c.Text, "holds what its role does not own: table ffs_admin_ui.ffs_events of syncserver_app") {
		t.Errorf("setup check: %+v", c)
	}
	// MariaDB and MySQL have no owners: nothing asked
	my := &fakeFxa{}
	s = &SyncDB{db: sql.OpenDB(&fakeFxa{}), own: sql.OpenDB(my), ownName: "ffs_admin"}
	if err := s.checkOwnDB(ctx); err != nil || len(my.queries) != 0 {
		t.Errorf("MySQL: %v %q", err, my.queries)
	}
}
