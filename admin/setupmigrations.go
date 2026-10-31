package main

import (
	"context"
	"database/sql"
	_ "embed"
	"fmt"
	"log"
	"sort"
	"strconv"
	"strings"
	"time"
)

// The setup migrations of the database servers (db/db-setup.sh, docs/databases.md#setup-migrations):
// the numbered SQL files of db/<engine>/setup/<scope>/ that create the stack's users, grants
// and databases, recorded on the server in ffs_setup_migrations (the tokenserver database,
// PostgreSQL's Sync database, the accounts' ffs) as they run: by db-bootstrap (how bootstrap),
// by hand (manual), as the end state of an install from before them (baseline), or by the init
// containers with the stack's own database containers (containers). db-bootstrap keeps the
// result of each start in ffs_setup_state. Shown next to the schema levels: the version (the
// highest number recorded) against the one this release expects (the highest it ships,
// setup-manifest, a copy of db/setup-manifest), and the drift (a user or a grant missing).

//go:embed setup-manifest
var setupManifestText string

// shippedFile: a setup migration of this release
type shippedFile struct {
	Dir    string // mysql/setup/sync...
	Name   string // 001-sync-and-admin-ui.sql
	Number int
}

// shippedSetup: the setup migrations of a directory of db/ in a manifest, in order
func shippedSetup(manifest, dir string) []shippedFile {
	var files []shippedFile
	for _, line := range strings.Split(manifest, "\n") {
		fields := strings.Fields(line)
		if len(fields) != 2 || strings.HasPrefix(fields[0], "#") {
			continue
		}
		path := fields[0]
		i := strings.LastIndex(path, "/")
		if i < 0 || path[:i] != dir || len(path)-i < 5 {
			continue
		}
		name := path[i+1:]
		n, err := strconv.Atoi(name[:3])
		if err != nil {
			continue
		}
		files = append(files, shippedFile{Dir: dir, Name: name, Number: n})
	}
	sort.Slice(files, func(i, j int) bool { return files[i].Number < files[j].Number })
	return files
}

// SetupMigration: a row of ffs_setup_migrations
type SetupMigration struct {
	Number int
	Name   string
	How    string // bootstrap, manual, baseline, containers
	At     time.Time
}

// SetupState: db-bootstrap's result at the last start (ffs_setup_state)
type SetupState struct {
	Result string // ok, pending, drift, missing, error
	Detail string
	At     time.Time
}

// SetupStatus: the setup migrations of a scope against this release
type SetupStatus struct {
	Scope    string // sync, fxa
	Label    string // Sync, Accounts
	Version  int    // the highest number recorded, 0: none
	Expected int    // the highest number this release ships
	Last     *SetupMigration
	Pending  []string // this release's files the server has not recorded
	Newer    []string // recorded files above Expected (an older release on a newer setup)
	// the admin UI's own check of its users (dbsetup.go), and the last start's result
	Drift []string
	State *SetupState
	// no record on the server (the table not there: an init image or db-bootstrap from before them)
	NotRecorded bool
	Err         string // the record could not be read
}

func nnn(n int) string { return fmt.Sprintf("%03d", n) }

// Kind: the state of the scope, for the alerts (once per change): ok, unknown, pending,
// newer, drift, failed
func (s SetupStatus) Kind() string {
	switch {
	case s.Err != "" || s.NotRecorded:
		return "unknown"
	case len(s.Pending) > 0:
		return "pending"
	case len(s.Drift) > 0 || (s.State != nil && s.State.Result == "drift"):
		return "drift"
	case s.State != nil && s.State.Result != "ok":
		return "failed"
	case len(s.Newer) > 0:
		return "newer"
	}
	return "ok"
}

// DriftFlag: 1 for ffs_db_setup_drift, a user or grant missing (the admin UI's check, or the
// last start's)
func (s SetupStatus) DriftFlag() bool {
	return len(s.Drift) > 0 || (s.State != nil && (s.State.Result == "drift" || s.State.Result == "missing"))
}

// Line: "version 002 (applied bootstrap on ...), this release expects 002"
func (s SetupStatus) Line() string {
	switch {
	case s.Err != "":
		return "could not be read: " + s.Err
	case s.NotRecorded:
		return fmt.Sprintf("not recorded on the server, this release expects %s", nnn(s.Expected))
	}
	line := "version " + nnn(s.Version)
	if s.Last != nil {
		line += fmt.Sprintf(" (applied %s on %s)", s.Last.How, formatTime(s.Last.At, adminZone))
	}
	return line + ", this release expects " + nnn(s.Expected)
}

// Problem: what needs attention ("" when nothing does)
func (s SetupStatus) Problem() string {
	what := "The setup migrations of the " + s.Label + " database server"
	switch s.Kind() {
	case "pending":
		return fmt.Sprintf("%s: version %s, this release expects %s (%s not applied); db-bootstrap applies them at the next start with the bootstrap account, otherwise run them as the server's administrator",
			what, nnn(s.Version), nnn(s.Expected), strings.Join(s.Pending, ", "))
	case "drift":
		detail := strings.Join(s.Drift, " ")
		if detail == "" && s.State != nil {
			detail = s.State.Detail + " (the start of " + formatTime(s.State.At, adminZone) + ")"
		}
		return fmt.Sprintf("%s: something they give is missing: %s", what, detail)
	case "failed":
		return fmt.Sprintf("%s: the last start stopped at db-bootstrap (%s, %s): %s", what, s.State.Result, formatTime(s.State.At, adminZone), s.State.Detail)
	case "newer":
		return fmt.Sprintf("%s: the server has %s, newer than this release (it expects %s): an older release runs on a newer setup",
			what, strings.Join(s.Newer, ", "), nnn(s.Expected))
	}
	return ""
}

// setupStatus: the record of a scope against the files this release ships
func setupStatus(scope, label string, shipped []shippedFile, record []SetupMigration, found bool, state *SetupState, drift []string) SetupStatus {
	s := SetupStatus{Scope: scope, Label: label, State: state, Drift: drift, NotRecorded: !found}
	for _, f := range shipped {
		s.Expected = max(s.Expected, f.Number)
	}
	recorded := map[int]bool{}
	for i, m := range record {
		recorded[m.Number] = true
		if m.Number >= s.Version {
			s.Version, s.Last = m.Number, &record[i]
		}
		if m.Number > s.Expected {
			s.Newer = append(s.Newer, m.Name)
		}
	}
	if found {
		for _, f := range shipped {
			if !recorded[f.Number] {
				s.Pending = append(s.Pending, strings.TrimSuffix(f.Name, ".sql"))
			}
		}
	}
	if found && len(record) == 0 {
		// the table there, nothing of this scope in it
		s.NotRecorded = true
	}
	return s
}

// readSetup: the record of a scope in the tables at prefix (ffs_, ffs.ffs_, public.ffs_);
// found false: no ffs_setup_migrations there
func readSetup(ctx context.Context, db *sql.DB, postgres bool, schema, scope string) (record []SetupMigration, state *SetupState, found bool, err error) {
	table := "ffs_setup_migrations"
	if postgres {
		if err := db.QueryRowContext(ctx, "SELECT to_regclass('public.ffs_setup_migrations') IS NOT NULL").Scan(&found); err != nil {
			return nil, nil, false, err
		}
		table = "public." + table
	} else {
		where := "DATABASE()"
		if schema != "" {
			where, table = "'"+schema+"'", schema+"."+table
		}
		var n int
		if err := db.QueryRowContext(ctx, "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = "+where+" AND TABLE_NAME = 'ffs_setup_migrations'").Scan(&n); err != nil {
			return nil, nil, false, err
		}
		found = n > 0
	}
	if !found {
		return nil, nil, false, nil
	}
	epoch := func(col string) string {
		if postgres {
			return "CAST(EXTRACT(EPOCH FROM " + col + ") AS BIGINT)"
		}
		return "CAST(UNIX_TIMESTAMP(" + col + ") AS SIGNED)"
	}
	rows, err := db.QueryContext(ctx, "SELECT number, name, how, "+epoch("applied_at")+" FROM "+table+" WHERE scope = '"+scope+"' ORDER BY number")
	if err != nil {
		return nil, nil, true, err
	}
	defer rows.Close()
	for rows.Next() {
		var m SetupMigration
		var at int64
		if err := rows.Scan(&m.Number, &m.Name, &m.How, &at); err != nil {
			return nil, nil, true, err
		}
		m.Name, m.At = strings.TrimSuffix(m.Name, ".sql"), time.Unix(at, 0)
		record = append(record, m)
	}
	if err := rows.Err(); err != nil {
		return nil, nil, true, err
	}
	// db-bootstrap's last result (none with the stack's database containers)
	var st SetupState
	var at int64
	err = db.QueryRowContext(ctx, "SELECT result, detail, "+epoch("checked_at")+" FROM "+strings.Replace(table, "ffs_setup_migrations", "ffs_setup_state", 1)+
		" WHERE scope = '"+scope+"'").Scan(&st.Result, &st.Detail, &at)
	switch {
	case err == nil:
		st.At = time.Unix(at, 0)
		state = &st
	case err == sql.ErrNoRows:
	default:
		// (a table of an older db-setup.sh, or no grant on it: the record alone)
		log.Printf("setup migrations: the last result of %s: %v", scope, err)
	}
	return record, state, true, nil
}

// setupStatuses: the scopes of this stack: Sync (with any database server), the
// self-hosted accounts
func (a *App) setupStatuses(ctx context.Context) []SetupStatus {
	var statuses []SetupStatus
	if a.sync != nil && a.sync.db != nil {
		dir := "mysql/setup/sync"
		if a.sync.postgres {
			dir = "postgres/setup/sync"
		}
		var drift []string
		// your own server: the admin UI's users have their grants (dbsetup.go)
		if env("SYNC_DB_CONTAINERS", "1") == "0" && a.sync.own != nil {
			if problems, err := a.dbSetupProblems(ctx); err == nil {
				drift = problems
			}
		}
		record, state, found, err := readSetup(ctx, a.sync.db, a.sync.postgres, "", "sync")
		s := setupStatus("sync", "Sync", shippedSetup(setupManifestText, dir), record, found, state, drift)
		if err != nil {
			s.Err = err.Error()
		}
		statuses = append(statuses, s)
	}
	if a.fxa != nil && a.fxa.db != nil {
		// (MySQL's and MariaDB's are numbered alike, tests/setup_migrations.sh)
		record, state, found, err := readSetup(ctx, a.fxa.db, false, "ffs", "fxa")
		s := setupStatus("fxa", "accounts", shippedSetup(setupManifestText, "mysql/setup/fxa-mysql"), record, found, state, nil)
		if err != nil {
			s.Err = err.Error()
		}
		statuses = append(statuses, s)
	}
	return statuses
}

// watchSetup: the setup migrations every round, an event (and an alert) when a scope's state
// changes (attention.go's changed: the first round only when it is not ok)
func (h *Health) watchSetup(ctx context.Context) {
	statuses := h.app.setupStatuses(ctx)
	for _, s := range statuses {
		state := s.Kind()
		if state == "unknown" {
			// not read, or not recorded (an image from before them): no alert either way
			h.logOnce("setup migrations of "+s.Scope, func() error {
				if s.Err != "" {
					return fmt.Errorf("%s", s.Err)
				}
				return nil
			}())
			continue
		}
		if h.changed("db-setup-"+s.Scope, state) {
			if p := s.Problem(); p != "" {
				h.app.event("attention", p)
			} else {
				h.app.event("attention", fmt.Sprintf("The setup migrations of the %s database server are in order again: %s", s.Label, s.Line()))
			}
		}
	}
	h.mu.Lock()
	h.setup = statuses
	h.mu.Unlock()
}

func (h *Health) Setup() []SetupStatus {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]SetupStatus(nil), h.setup...)
}

// setupMetrics: ffs_db_setup_version, ffs_db_setup_expected_version and ffs_db_setup_drift per scope
func setupMetrics(b *strings.Builder, statuses []SetupStatus) {
	if len(statuses) == 0 {
		return
	}
	b.WriteString("# HELP ffs_db_setup_version The highest setup migration recorded on the database server (0: none)\n# TYPE ffs_db_setup_version gauge\n")
	for _, s := range statuses {
		fmt.Fprintf(b, "ffs_db_setup_version{scope=\"%s\"} %d\n", s.Scope, s.Version)
	}
	b.WriteString("# HELP ffs_db_setup_expected_version The highest setup migration of this release\n# TYPE ffs_db_setup_expected_version gauge\n")
	for _, s := range statuses {
		fmt.Fprintf(b, "ffs_db_setup_expected_version{scope=\"%s\"} %d\n", s.Scope, s.Expected)
	}
	b.WriteString("# HELP ffs_db_setup_drift 1 when a user, grant or database of the setup migrations is missing (the admin UI's check, or the last start's)\n# TYPE ffs_db_setup_drift gauge\n")
	for _, s := range statuses {
		d := 0
		if s.DriftFlag() {
			d = 1
		}
		fmt.Fprintf(b, "ffs_db_setup_drift{scope=\"%s\"} %d\n", s.Scope, d)
	}
}
