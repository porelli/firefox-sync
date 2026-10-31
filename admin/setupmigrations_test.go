package main

import (
	"database/sql"
	"database/sql/driver"
	"os"
	"strings"
	"testing"
	"time"
)

// setup-manifest is db/setup-manifest (tests/setup_migrations.sh checks it too)
func TestSetupManifestIsTheRepositorys(t *testing.T) {
	repo, err := os.ReadFile("../db/setup-manifest")
	if err != nil {
		t.Skip("no ../db/setup-manifest (the image's build context is admin/ only):", err)
	}
	if string(repo) != setupManifestText {
		t.Error("admin/setup-manifest is not db/setup-manifest: cp db/setup-manifest admin/")
	}
}

const testManifest = `# a comment
mysql/setup/sync/001-sync-and-admin-ui.sql 36e7d5054872053487d47918911948c3b11255e826a6209b11bbe86d45b1a533
mysql/setup/sync-bootstrap/001-bootstrap-account.sql 23cae5b8a1ee78058bc57d59043b6baf579669dde326d9572319a9a384e38d69
postgres/setup/sync/001-sync-and-admin-ui.sql 711ba12269598a998633cda17bfb77466045b365112ecd9a4f033c6f85918710
mysql/setup/sync/002-a-reader.sql 0000000000000000000000000000000000000000000000000000000000000000
`

func TestShippedSetup(t *testing.T) {
	files := shippedSetup(testManifest, "mysql/setup/sync")
	if len(files) != 2 || files[0].Number != 1 || files[1].Number != 2 || files[1].Name != "002-a-reader.sql" {
		t.Errorf("mysql/setup/sync: %+v", files)
	}
	if files := shippedSetup(testManifest, "postgres/setup/sync"); len(files) != 1 {
		t.Errorf("postgres/setup/sync: %+v", files)
	}
	// the release's own: every scope the admin UI shows has its files
	for _, dir := range []string{"mysql/setup/sync", "postgres/setup/sync", "mysql/setup/fxa-mysql", "mysql/setup/fxa-mariadb"} {
		if len(shippedSetup(setupManifestText, dir)) == 0 {
			t.Errorf("setup-manifest has no %s", dir)
		}
	}
}

func TestSetupStatus(t *testing.T) {
	shipped := shippedSetup(testManifest, "mysql/setup/sync")
	at := time.Date(2026, 10, 30, 12, 0, 0, 0, time.UTC)
	m1 := SetupMigration{Number: 1, Name: "001-sync-and-admin-ui", How: "baseline", At: at}
	m2 := SetupMigration{Number: 2, Name: "002-a-reader", How: "bootstrap", At: at.Add(time.Hour)}
	ok := &SetupState{Result: "ok", At: at}
	cases := []struct {
		name    string
		s       SetupStatus
		kind    string
		problem string // part of Problem(), "" none
		line    string // part of Line()
		drift   bool
	}{
		{"up to date", setupStatus("sync", "Sync", shipped, []SetupMigration{m1, m2}, true, ok, nil), "ok", "", "version 002 (applied bootstrap on ", false},
		{"pending", setupStatus("sync", "Sync", shipped, []SetupMigration{m1}, true, nil, nil), "pending",
			"version 001, this release expects 002 (002-a-reader not applied)", "version 001 (applied baseline on ", false},
		{"newer (a rollback)", setupStatus("sync", "Sync", shipped[:1], []SetupMigration{m1, m2}, true, ok, nil), "newer",
			"the server has 002-a-reader, newer than this release (it expects 001)", "this release expects 001", false},
		{"drift of the admin UI's check", setupStatus("sync", "Sync", shipped, []SetupMigration{m1, m2}, true, ok, []string{"ffs_admin_sync lacks EXECUTE on tokenserver: GRANT ..."}), "drift",
			"something they give is missing: ffs_admin_sync lacks EXECUTE", "", true},
		{"drift of the last start", setupStatus("sync", "Sync", shipped, []SetupMigration{m1, m2}, true, &SetupState{Result: "drift", Detail: "'tokenserver' lacks TRIGGER on `tokenserver`", At: at}, nil), "drift",
			"'tokenserver' lacks TRIGGER on `tokenserver` (the start of ", "", true},
		{"the last start failed", setupStatus("sync", "Sync", shipped, []SetupMigration{m1, m2}, true, &SetupState{Result: "error", Detail: "setup migration 002 failed", At: at}, nil), "failed",
			"the last start stopped at db-bootstrap (error, ", "", false},
		{"not recorded (an image from before)", setupStatus("sync", "Sync", shipped, nil, false, nil, nil), "unknown", "", "not recorded on the server, this release expects 002", false},
		{"the table without this scope", setupStatus("sync", "Sync", shipped, nil, true, nil, nil), "unknown", "", "not recorded", false},
	}
	for _, c := range cases {
		if got := c.s.Kind(); got != c.kind {
			t.Errorf("%s: kind %s, want %s", c.name, got, c.kind)
		}
		p := c.s.Problem()
		if (c.problem == "") != (p == "") || !strings.Contains(p, c.problem) {
			t.Errorf("%s: problem %q, want %q", c.name, p, c.problem)
		}
		if !strings.Contains(c.s.Line(), c.line) {
			t.Errorf("%s: line %q, want %q", c.name, c.s.Line(), c.line)
		}
		if c.s.DriftFlag() != c.drift {
			t.Errorf("%s: drift %v", c.name, c.s.DriftFlag())
		}
	}
}

// setupFake: a tokenserver (or ffs) database with ffs_setup_migrations holding rows, and the
// last result state ("": no row)
func setupFake(rows [][]driver.Value, state string) *fakeFxa {
	return &fakeFxa{answer: func(query string, _ []driver.Value) *fakeRows {
		switch {
		case strings.Contains(query, "information_schema.TABLES") && strings.Contains(query, "ffs_setup_migrations"):
			n := int64(0)
			if rows != nil {
				n = 1
			}
			return &fakeRows{cols: []string{"n"}, rows: [][]driver.Value{{n}}}
		case strings.Contains(query, "FROM ffs_setup_migrations") || strings.Contains(query, "FROM ffs.ffs_setup_migrations"):
			return &fakeRows{cols: []string{"number", "name", "how", "at"}, rows: rows}
		case strings.Contains(query, "_setup_state"):
			if state == "" {
				return &fakeRows{cols: []string{"result", "detail", "at"}}
			}
			return &fakeRows{cols: []string{"result", "detail", "at"}, rows: [][]driver.Value{{state, "x", int64(1790000000)}}}
		}
		return nil
	}}
}

func TestReadSetupAndWatch(t *testing.T) {
	t.Setenv("SYNC_DB_CONTAINERS", "1")
	fake := setupFake([][]driver.Value{{int64(1), "001-sync-and-admin-ui.sql", "containers", int64(1790000000)}}, "")
	app := &App{alerter: &Alerter{}}
	app.sync = &SyncDB{db: sql.OpenDB(fake)}
	app.rec = &Recorder{db: app.sync, current: map[string]*metric{}, cumulative: map[string]*metric{}}
	statuses := app.setupStatuses(t.Context())
	if len(statuses) != 1 || statuses[0].Version != 1 || statuses[0].Last.How != "containers" || statuses[0].Last.Name != "001-sync-and-admin-ui" || statuses[0].State != nil {
		t.Fatalf("statuses: %+v", statuses)
	}
	if want := shippedSetup(setupManifestText, "mysql/setup/sync"); statuses[0].Expected != want[len(want)-1].Number {
		t.Errorf("expected %d, the release ships %+v", statuses[0].Expected, want)
	}
	// an event (an alert) when the state changes: none while it is in order, one when a
	// migration is pending, none again for the same state, one when it is in order again
	events := func() (n int, last string) {
		for i, s := range fake.statements() {
			if strings.Contains(s, "INSERT INTO ffs_events") && fake.args[i][1] == "attention" {
				n, last = n+1, fake.args[i][2].(string)
			}
		}
		return n, last
	}
	h := &Health{app: app}
	h.watchSetup(t.Context())
	if n, _ := events(); n != 0 || len(h.Setup()) != 1 {
		t.Errorf("in order: %d events, %+v", n, h.Setup())
	}
	shipped := setupManifestText
	setupManifestText = shipped + "mysql/setup/sync/999-test-only.sql 0000000000000000000000000000000000000000000000000000000000000000\n"
	defer func() { setupManifestText = shipped }()
	h.watchSetup(t.Context())
	h.watchSetup(t.Context())
	if n, last := events(); n != 1 || !strings.Contains(last, "this release expects 999 (999-test-only not applied)") {
		t.Errorf("pending: %d events, %q", n, last)
	}
	// Needs attention and the metrics
	list := needsAttention(attentionInput{now: time.Now(), setup: h.Setup()})
	if len(list) != 1 || list[0].Href != "#setup-migrations" || !strings.Contains(list[0].Text, "The setup migrations of the Sync database server: version 001, this release expects 999") {
		t.Errorf("needs attention: %+v", list)
	}
	app.health = h
	metrics := prometheusText(t, app)
	for _, want := range []string{"ffs_db_setup_version{scope=\"sync\"} 1\n", "ffs_db_setup_expected_version{scope=\"sync\"} 999\n", "ffs_db_setup_drift{scope=\"sync\"} 0\n",
		"# TYPE ffs_db_setup_drift gauge\n"} {
		if !strings.Contains(metrics, want) {
			t.Errorf("metrics: no %q", want)
		}
	}
	setupManifestText = shipped
	h.watchSetup(t.Context())
	if n, last := events(); n != 2 || !strings.Contains(last, "in order again: version 001") {
		t.Errorf("in order again: %d events, %q", n, last)
	}
	// db-bootstrap's last result: drift, and the gauge
	fake = setupFake([][]driver.Value{{int64(1), "001-sync-and-admin-ui.sql", "bootstrap", int64(1790000000)}}, "drift")
	app.sync = &SyncDB{db: sql.OpenDB(fake)}
	if s := app.setupStatuses(t.Context()); s[0].Kind() != "drift" || !s[0].DriftFlag() {
		t.Errorf("the last start's drift: %+v", s[0])
	}
	// no table (an init image from before): not recorded, no alert
	fake = setupFake(nil, "")
	app.sync = &SyncDB{db: sql.OpenDB(fake)}
	if s := app.setupStatuses(t.Context()); !s[0].NotRecorded || s[0].Kind() != "unknown" || s[0].Problem() != "" {
		t.Errorf("no table: %+v", s[0])
	}
}

// the accounts' record in ffs, read as ffs_admin
func TestReadSetupOfTheAccounts(t *testing.T) {
	fake := setupFake([][]driver.Value{{int64(1), "001-accounts-and-policy.sql", "manual", int64(1790000000)}}, "ok")
	app := &App{fxa: fake.db("")}
	s := app.setupStatuses(t.Context())
	if len(s) != 1 || s[0].Scope != "fxa" || s[0].Version != 1 || s[0].Kind() != "ok" || s[0].State == nil {
		t.Fatalf("accounts: %+v", s)
	}
	found := false
	for _, q := range fake.queries {
		found = found || strings.Contains(q, "FROM ffs.ffs_setup_migrations WHERE scope = 'fxa'")
	}
	if !found {
		t.Errorf("not read from ffs: %q", fake.queries)
	}
}

// the overview: a row per scope next to the schema levels, the details open when one needs attention
func TestSetupMigrationsOnTheOverview(t *testing.T) {
	page := pages(t)["dashboard.html"]
	for _, want := range []string{`<h3 id="setup-migrations">Setup of the database servers</h3>`, `<details class="tech" open>`,
		"<td>Sync</td><td>version 001 (applied baseline on ", "this release expects 002</td><td><span class=\"pill bad\">needs attention</span> The setup migrations of the Sync database server: version 001, this release expects 002 (002-a-reader not applied)",
		"<td>accounts</td><td>version 001 (applied containers on ", "</td><td>in order</td>"} {
		if !strings.Contains(page, want) {
			t.Errorf("no %q", want)
		}
	}
}

// fxa-policy with the stack's fxa-db: the tables, the files of the release recorded as
// containers (MariaDB's or MySQL's by VERSION()), INSERT IGNORE: none recorded twice
func TestRecordFxaSetup(t *testing.T) {
	for version, dir := range map[string]string{"11.8.2-MariaDB": "mysql/setup/fxa-mariadb", "9.4.0": "mysql/setup/fxa-mysql"} {
		fake := &fakeFxa{answer: func(query string, _ []driver.Value) *fakeRows {
			if query == "SELECT VERSION()" {
				return &fakeRows{cols: []string{"v"}, rows: [][]driver.Value{{version}}}
			}
			return nil
		}}
		if err := recordFxaSetup(t.Context(), sql.OpenDB(fake)); err != nil {
			t.Fatal(err)
		}
		stmts := fake.statements()
		shipped := shippedSetup(setupManifestText, dir)
		if len(stmts) != 2+len(shipped) || !strings.HasPrefix(stmts[0], "CREATE TABLE IF NOT EXISTS ffs.ffs_setup_migrations") ||
			!strings.HasPrefix(stmts[1], "CREATE TABLE IF NOT EXISTS ffs.ffs_setup_state") {
			t.Fatalf("%s: %q", version, stmts)
		}
		for i, f := range shipped {
			args := fake.args[2+i]
			if !strings.Contains(stmts[2+i], "INSERT IGNORE INTO ffs.ffs_setup_migrations") || !strings.Contains(stmts[2+i], "'containers'") ||
				args[0] != int64(f.Number) || args[1] != f.Name || !strings.Contains(setupManifestText, dir+"/"+f.Name+" "+args[2].(string)) {
				t.Errorf("%s: %q %v", version, stmts[2+i], args)
			}
		}
	}
}
