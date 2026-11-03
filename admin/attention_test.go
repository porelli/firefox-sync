package main

import (
	"bufio"
	"context"
	"database/sql"
	"database/sql/driver"
	"fmt"
	"net"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestBackupStatuses(t *testing.T) {
	now := time.Now()
	at := func(h int) time.Time { return now.Add(-time.Duration(h) * time.Hour) }
	runs := []BackupRun{
		{Scope: "accounts", Started: at(1), Finished: at(1), OK: false, Error: "access denied"},
		{Scope: "sync", Started: at(2), Finished: at(2), OK: true, Bytes: 10},
		{Scope: "accounts", Started: at(25), Finished: at(25), OK: true, Bytes: 20},
		{Scope: "sync", Started: at(26), Finished: at(26), OK: true, Bytes: 30},
	}
	got := backupStatuses(runs)
	if len(got) != 2 || got[0].Scope != "sync" || got[1].Scope != "accounts" {
		t.Fatalf("%+v", got)
	}
	if got[0].Last.Bytes != 10 || got[0].LastOK.Bytes != 10 || got[0].state(now) != "ok" || got[0].Problem(now) != "" {
		t.Errorf("sync: %+v", got[0])
	}
	if got[1].Last.OK || got[1].LastOK.Bytes != 20 || got[1].state(now) != "failed" || !strings.Contains(got[1].Problem(now), "failed on") ||
		!strings.HasSuffix(got[1].Problem(now), ": access denied") {
		t.Errorf("accounts: %+v %q", got[1], got[1].Problem(now))
	}
	// 36 hours: still fine; past them, stale
	ok := BackupStatus{Scope: "sync", Last: BackupRun{OK: true, Finished: at(35)}, LastOK: BackupRun{OK: true, Finished: at(35)}}
	if ok.state(now) != "ok" {
		t.Error("35 hours")
	}
	old := BackupStatus{Scope: "sync", Last: BackupRun{OK: true, Finished: at(37)}, LastOK: BackupRun{OK: true, Finished: at(37)}}
	if old.state(now) != "stale" || !strings.Contains(old.Problem(now), "more than 36 hours ago") || !old.Old() {
		t.Errorf("37 hours: %q", old.Problem(now))
	}
	never := backupStatuses([]BackupRun{{Scope: "sync", Started: at(1), Finished: at(1), Error: "x"}})
	if never[0].state(now) != "failed" || !never[0].LastOK.Finished.IsZero() {
		t.Errorf("%+v", never)
	}
}

func TestBackupAlertsOncePerState(t *testing.T) {
	fake := &fakeFxa{}
	app := testApp()
	app.sync, app.alerter = &SyncDB{db: sql.OpenDB(fake)}, &Alerter{}
	h := newHealth(app)
	now := time.Now()
	row := func(ok bool, hoursAgo int) []driver.Value {
		at := now.Add(-time.Duration(hoursAgo) * time.Hour).UnixMilli()
		e := ""
		if !ok {
			e = "storage: access denied"
		}
		v := int64(0)
		if ok {
			v = 1
		}
		return []driver.Value{"sync", at, at, v, int64(1000), e, "/backups/sync/x"}
	}
	round := func(rows ...[]driver.Value) []string {
		fake.mu.Lock()
		fake.backups = rows
		fake.mu.Unlock()
		h.watchBackups(t.Context(), now)
		return app.alerter.take()
	}
	if got := round(); len(got) != 0 {
		t.Errorf("no backups: %q", got)
	}
	if got := round(row(true, 1)); len(got) != 0 {
		t.Errorf("a good one: %q", got)
	}
	got := round(row(false, 0), row(true, 1))
	if len(got) != 1 || !strings.Contains(got[0], "backup: The backup of the Sync databases failed on") || !strings.Contains(got[0], "storage: access denied") {
		t.Errorf("failed: %q", got)
	}
	if got := round(row(false, 0), row(true, 1)); len(got) != 0 {
		t.Errorf("failed again, alerted again: %q", got)
	}
	if got := round(row(true, 0), row(false, 0)); len(got) != 1 || !strings.Contains(got[0], "works again") {
		t.Errorf("back: %q", got)
	}
	if got := round(row(true, 40)); len(got) != 1 || !strings.Contains(got[0], "more than 36 hours ago") {
		t.Errorf("stale: %q", got)
	}
	if b := h.Backups(); len(b) != 1 || b[0].Last.Location != "/backups/sync/x" {
		t.Errorf("%+v", b)
	}
	// a first look at a failed backup alerts too (the admin UI restarted)
	h2 := newHealth(app)
	fake.backups = [][]driver.Value{row(false, 0)}
	h2.watchBackups(t.Context(), now)
	if got := app.alerter.take(); len(got) != 1 {
		t.Errorf("at the start: %q", got)
	}
}

// allGood: an overview with nothing to look at
func allGood(now time.Time) attentionInput {
	return attentionInput{now: now, fxa: true, staleDays: 90,
		components: []Component{{Name: "Admin UI", Up: true}, {Name: "Sync server", Up: true, Version: "0.21.1"}, {Name: "Email (SMTP)", Up: true},
			{Name: "Sign-up gate", Up: true}, {Name: oauthKeysCheck, Up: true, Hidden: true}},
		certs:  map[string]time.Time{"sync.example.com": now.AddDate(0, 0, 60)},
		status: &SyncStatus{Users: 8, MaxUsers: 10},
		backups: []BackupStatus{{Scope: "sync", Last: BackupRun{OK: true, Finished: now.Add(-time.Hour)},
			LastOK: BackupRun{OK: true, Finished: now.Add(-time.Hour)}}},
		storage:      &StorageReport{},
		accounts:     []accountRow{{UID: fakeUID, Email: fakeEmail}},
		pruneLastRan: now.Add(-time.Hour),
		alerts:       &SendStatus{At: now, LastOK: now},
	}
}

func TestNeedsAttention(t *testing.T) {
	now := time.Now()
	if got := needsAttention(allGood(now)); len(got) != 0 {
		t.Fatalf("all good: %+v", got)
	}
	two := []accountRow{{UID: "aa"}, {UID: "bb"}}
	cases := []struct {
		name       string
		change     func(*attentionInput)
		href, text string
	}{
		{"component down", func(in *attentionInput) { in.components[1] = Component{Name: "Sync server", Error: "status 503"} }, "#health", "Sync server is down: status 503."},
		{"update", func(in *attentionInput) { in.components[1].Latest = "0.22.0" }, "#health", "Sync server 0.22.0 is out, 0.21.1 runs here."},
		{"blocked members", func(in *attentionInput) { in.accounts[0].Blocked = true }, "/security", "1 account blocked by the rate limits."},
		{"unconfirmed", func(in *attentionInput) { in.unconfirmed = 3 }, "/?show=unconfirmed#accounts", "3 accounts never confirmed their email."},
		{"one unconfirmed sign-in", func(in *attentionInput) { in.accounts[0].Security.UnverifiedSessions = 1 }, "/users/" + fakeUID + "#sessions-card", "1 account with a sign-in that never entered its email code: someone may have the password. Confirm it if you know it is them, sign it out otherwise."},
		{"unconfirmed sign-ins", func(in *attentionInput) {
			in.accounts = two
			in.accounts[0].Security.UnverifiedSessions, in.accounts[1].Security.UnverifiedSessions = 1, 2
		}, "/?show=unconfirmed-sign-in#accounts", "2 accounts with a sign-in"},
		{"stale backup", func(in *attentionInput) {
			in.backups[0].Last.Finished, in.backups[0].LastOK.Finished = now.Add(-40*time.Hour), now.Add(-40*time.Hour)
		}, "#backups", "more than 36 hours ago"},
		{"failed backup", func(in *attentionInput) { in.backups[0].Last = BackupRun{Finished: now, Error: "disk full"} }, "#backups", "failed on"},
		{"certificate", func(in *attentionInput) { in.certs["sync.example.com"] = now.AddDate(0, 0, 10).Add(time.Hour) }, "#health", "The certificate of sync.example.com expires in 10 days"},
		{"gate bypassed", func(in *attentionInput) { in.components[3] = Component{Name: "Sign-up gate", Warn: true, Error: "x"} }, "#health", "bypass the sign-up gate"},
		{"orphans", func(in *attentionInput) {
			in.storage = &StorageReport{Orphaned: Usage{Bytes: 2048}, Orphans: []Orphan{{}}}
		}, "/storage/purge", "2.0 KB of Sync data nobody reads any more (1 orphans)."},
		{"prune late", func(in *attentionInput) { in.pruneLastRan = now.Add(-49 * time.Hour) }, "/activity#maintenance", "not pruned for 2 days"},
		{"never pruned", func(in *attentionInput) { in.pruneLastRan = time.Time{} }, "/activity#maintenance", "(last: never)"},
		{"SMTP down", func(in *attentionInput) { in.components[2] = Component{Name: "Email (SMTP)", Error: "535 auth failed"} }, "#health", "The SMTP server does not work (535 auth failed)"},
		{"alert send failed", func(in *attentionInput) { in.alerts.Err = "connection refused" }, "#alert-status", "The last alert email failed on"},
		{"90% of max users", func(in *attentionInput) { in.status.Users = 9 }, "#sync", "9 of 10 accounts are taken (90% or more)"},
		{"metrics missing", func(in *attentionInput) {
			row, _ := metricsRow(true, now.Add(-time.Minute), now.Add(-20*time.Minute), now.Add(-time.Hour))
			in.components = append(in.components, row)
		}, "/activity", "Sync data changed at"},
		{"inactive device", func(in *attentionInput) { in.inactiveDevices = map[string]int{fakeUID: 2} }, "/users/" + fakeUID + "#devices", "2 devices of 1 account not used for 90 days"},
		{"inactive devices", func(in *attentionInput) { in.inactiveDevices = map[string]int{"aa": 1, "bb": 1} }, "/?show=inactive-devices#accounts", "2 devices of 2 accounts"},
		{"sign-in keys", func(in *attentionInput) {
			in.components[4] = Component{Name: oauthKeysCheck, Hidden: true, Error: "no keys"}
		}, "#setup", "no keys"},
	}
	for _, c := range cases {
		in := allGood(now)
		c.change(&in)
		got := needsAttention(in)
		if len(got) != 1 || got[0].Href != c.href || !strings.Contains(got[0].Text, c.text) || got[0].Link == "" {
			t.Errorf("%s: %+v", c.name, got)
		}
	}
	// max users 0 refuses everybody on purpose; Mozilla's accounts: no accounts checks
	in := allGood(now)
	in.status, in.fxa, in.pruneLastRan, in.unconfirmed = &SyncStatus{Users: 0, MaxUsers: 0}, false, time.Time{}, 5
	if got := needsAttention(in); len(got) != 0 {
		t.Errorf("max users 0, Mozilla's accounts: %+v", got)
	}
	// the Sync server down: one line for it, no silence on top
	in = allGood(now)
	in.components[1] = Component{Name: "Sync server", Error: "x"}
	if got := needsAttention(in); len(got) != 1 {
		t.Errorf("down: %+v", got)
	}
}

func TestThresholdsAlertOncePerState(t *testing.T) {
	now := time.Now()
	h := &Health{started: now.Add(-time.Hour)}
	full, room := &SyncStatus{Users: 9, MaxUsers: 10}, &SyncStatus{Users: 1, MaxUsers: 10}
	sent, failed := &SendStatus{At: now, LastOK: now}, &SendStatus{At: now, Err: "refused"}
	steps := []struct {
		st     *SyncStatus
		up     bool
		last   time.Time
		alerts *SendStatus
		want   []string
	}{
		{room, true, now, sent, nil},
		{full, true, now, sent, []string{"9 of 10 accounts are taken (90% or more)"}},
		{full, true, now, sent, nil},
		// a failed read: no change
		{nil, true, now, sent, nil},
		{room, true, now, sent, []string{"under 90% again"}},
		{room, true, now.Add(-time.Hour), sent, []string{"Sync data changed at"}},
		{room, true, now.Add(-time.Hour), sent, nil},
		// the Sync server down: its health alerts, the silence stays (no false "again")
		{room, false, now.Add(-time.Hour), sent, nil},
		{room, true, now.Add(-time.Hour), sent, nil},
		{room, true, now, sent, []string{"Metrics from the Sync server arrive again"}},
		{room, false, now.Add(-time.Hour), sent, nil},
		{room, true, now, failed, []string{"Alert emails fail: refused"}},
		{room, true, now, failed, nil},
		{room, true, now, sent, []string{"Alert emails go out again"}},
		{room, true, now, nil, nil},
	}
	for i, s := range steps {
		// the latest write now: silent with metrics from an hour ago
		got := h.thresholdEvents(s.st, nil, s.up, now, s.last, s.alerts)
		if len(got) != len(s.want) {
			t.Fatalf("step %d: %q, want %q", i, got, s.want)
		}
		for j := range got {
			if !strings.Contains(got[j], s.want[j]) {
				t.Errorf("step %d: %q, want %q", i, got[j], s.want[j])
			}
		}
	}
	// up again after an outage, its first metrics not yet in: the silence counts from its
	// coming up
	h.syncUpSince = now.Add(-time.Minute)
	if got := h.thresholdEvents(room, nil, true, now, now.Add(-time.Hour), sent); len(got) != 0 {
		t.Errorf("just up again: %q", got)
	}
	if got := h.thresholdEvents(room, nil, true, now.Add(statsdMargin), now.Add(-time.Hour), sent); len(got) != 1 || !strings.Contains(got[0], "Sync data changed at") ||
		!strings.Contains(got[0], "restart it (docker compose restart syncstorage") {
		t.Errorf("up again, written without metrics: %q", got)
	}
	// the first round alerts what is already wrong
	h = &Health{started: now.Add(-time.Hour)}
	if got := h.thresholdEvents(full, nil, true, now, now, failed); len(got) != 2 {
		t.Errorf("first round: %q", got)
	}
}

func TestLimitsAlertOncePerState(t *testing.T) {
	now := time.Now()
	h := &Health{started: now.Add(-time.Hour)}
	sent := &SendStatus{At: now, LastOK: now}
	sync := func(users, max int) *SyncStatus { return &SyncStatus{Users: users, MaxUsers: max} }
	acc := func(n, max int, unlimited bool) *Limit { return &Limit{Count: n, Max: max, Unlimited: unlimited} }
	steps := []struct {
		st   *SyncStatus
		acc  *Limit
		want []string
	}{
		{sync(1, 10), acc(5, 10, false), nil},
		// near, then full, then raised: one event each
		{sync(9, 10), acc(5, 10, false), []string{"9 of 10 accounts are taken (90% or more): new accounts are refused by the Sync server once all are"}},
		{sync(9, 10), acc(5, 10, false), nil},
		{sync(10, 10), acc(5, 10, false), []string{"10 of 10 accounts are taken (SYNC_MAX_USERS): new accounts are refused by the Sync server until it is raised"}},
		{sync(10, 20), acc(5, 10, false), []string{"10 of 20 accounts are taken, under 90% again"}},
		// the accounts: full, then no limit
		{sync(10, 20), acc(10, 10, false), []string{"10 of 10 accounts are created (FXA_MAX_ACCOUNTS): sign-ups are refused until it is raised"}},
		{sync(10, 20), acc(10, 10, false), nil},
		// not read: no change
		{nil, nil, nil},
		{sync(10, 20), acc(10, 0, true), []string{"Max accounts: no limit now (10 accounts)"}},
		// unlimited and 0 never warn
		{&SyncStatus{Users: 100, Unlimited: true}, acc(10, 0, true), nil},
		{sync(3, 0), acc(10, 0, false), nil},
		// near or full, then set to 0: says so, not "9 of 0 ... under 90% again"
		{sync(9, 10), acc(10, 10, false), []string{"9 of 10 accounts are taken (90% or more): new accounts are refused by the Sync server once all are", "10 of 10 accounts are created (FXA_MAX_ACCOUNTS): sign-ups are refused until it is raised"}},
		{sync(9, 0), acc(10, 0, false), []string{"Max users: 0 now, no new accounts (9 accounts)", "Max accounts: 0 now, no new accounts (10 accounts)"}},
	}
	for i, s := range steps {
		got := h.thresholdEvents(s.st, s.acc, true, now, now, sent)
		if len(got) != len(s.want) {
			t.Fatalf("step %d: %q, want %q", i, got, s.want)
		}
		for j := range got {
			if got[j] != s.want[j] {
				t.Errorf("step %d: %q, want %q", i, got[j], s.want[j])
			}
		}
	}
	// the first round alerts a limit already reached
	h = &Health{started: now.Add(-time.Hour)}
	if got := h.thresholdEvents(sync(5, 5), acc(9, 10, false), true, now, now, sent); len(got) != 2 || !strings.Contains(got[1], "9 of 10 accounts are created (90% or more)") {
		t.Errorf("first round: %q", got)
	}
}

func TestLimitStates(t *testing.T) {
	for _, c := range []struct {
		l     Limit
		state string
	}{
		{Limit{Count: 0, Max: 10}, limitOK}, {Limit{Count: 8, Max: 10}, limitOK}, {Limit{Count: 9, Max: 10}, limitNear},
		{Limit{Count: 10, Max: 10}, limitFull}, {Limit{Count: 12, Max: 10}, limitFull}, {Limit{Count: 1, Max: 1}, limitFull},
		// 0: no new account on purpose; no limit: never
		{Limit{Count: 3, Max: 0}, limitOK}, {Limit{Count: 1 << 30, Unlimited: true}, limitOK},
	} {
		if got := c.l.State(); got != c.state {
			t.Errorf("%+v: %s, want %s", c.l, got, c.state)
		}
	}
	for v, want := range map[string]string{"5": "5", "0": "0", "007": "7", "unlimited": "unlimited", " Unlimited ": "unlimited", "2147483647": "2147483647"} {
		n, unlimited, err := parseLimitValue(v)
		if got := (Limit{Max: n, Unlimited: unlimited}).Setting(); err != nil || got != want {
			t.Errorf("%q: %s %v", v, got, err)
		}
	}
	for _, v := range []string{"", "-1", "2147483648", "lots", "1 2", "+5", "infinite"} {
		if _, _, err := parseLimitValue(v); err == nil {
			t.Errorf("%q accepted", v)
		}
	}
	for _, c := range []struct {
		setting, value string
		fixed          bool
	}{
		{"5", "5", true}, {"fixed:5", "5", true}, {"unlimited", "unlimited", true}, {"fixed:unlimited", "unlimited", true},
		{"initial:5", "5", false}, {"initial:unlimited", "unlimited", false},
		// FXA_MAX_ACCOUNTS not set: initial:unlimited, existing setups unchanged
		{"", "unlimited", false},
	} {
		value, fixed, err := parseLimitSetting(c.setting, "initial:unlimited")
		if err != nil || value != c.value || fixed != c.fixed {
			t.Errorf("%q: %q %v %v", c.setting, value, fixed, err)
		}
	}
	for _, bad := range []string{"initial:", "fixed:-1", "lots", "initial:lots", "Initial:5"} {
		if _, _, err := parseLimitSetting(bad, "initial:unlimited"); err == nil {
			t.Errorf("%q accepted", bad)
		}
	}
	for v, want := range map[string]bool{"": true, "initial:5": true, "initial:unlimited": true, "5": false, "unlimited": false, "fixed:5": false} {
		if got := limitEditable(v, true); got != want {
			t.Errorf("FXA_MAX_ACCOUNTS=%q editable: %v", v, got)
		}
	}
}

func TestStatsdSilent(t *testing.T) {
	now := time.Now()
	start := now.Add(-2 * time.Hour)
	for _, c := range []struct {
		name        string
		up          bool
		write, last time.Time
		silent      bool
	}{
		// the demo: the last packet during the last sync, nobody synced since
		{"idle, no write since the last metrics", true, now.Add(-55 * time.Minute), now.Add(-54 * time.Minute), false},
		{"idle for days", true, now.Add(-72 * time.Hour), now.Add(-72 * time.Hour), false},
		{"written after the last metrics", true, now.Add(-time.Minute), now.Add(-40 * time.Minute), true},
		// the metrics of the last requests wait in the Sync server's buffer
		{"written within the margin", true, now.Add(-time.Minute), now.Add(-5 * time.Minute), false},
		{"no storage database or no write", true, time.Time{}, now.Add(-5 * time.Hour), false},
		{"Sync server down", false, now.Add(-time.Minute), now.Add(-40 * time.Minute), false},
		// none since the start: from the start of the admin UI (or the Sync server)
		{"none since the start, written soon after", true, start.Add(5 * time.Minute), time.Time{}, false},
		{"none since the start, written later", true, start.Add(20 * time.Minute), time.Time{}, true},
		{"written before the start", true, start.Add(-time.Hour), time.Time{}, false},
	} {
		if got := statsdSilent(c.up, c.write, c.last, start); got != c.silent {
			t.Errorf("%s: silent %v", c.name, got)
		}
		if row, silent := metricsRow(c.up, c.write, c.last, start); silent != c.silent || silent && (row.Name != metricsCheck || !row.Warn || row.Up) {
			t.Errorf("%s: row %+v", c.name, row)
		}
	}
	row, _ := metricsRow(true, now.Add(-time.Minute), now.Add(-40*time.Minute), start)
	if !strings.HasPrefix(row.Error, "Sync data changed at "+formatTime(now.Add(-time.Minute), adminZone)+" but no metrics arrived since the last ones at "+formatTime(now.Add(-40*time.Minute), adminZone)) {
		t.Error(row.Error)
	}
	if row, _ = metricsRow(true, now, time.Time{}, start); !strings.Contains(row.Error, "no metrics arrived since "+formatTime(start, adminZone)+" (the start of") {
		t.Error(row.Error)
	}
}

// the health light, the Health tile and the health table count the same rows
func TestHealthTableMatchesSummary(t *testing.T) {
	now := time.Now()
	components := []Component{{Name: "Admin UI", Up: true}, {Name: "Sync server", Up: true}, {Name: "Tokenserver database", Up: true},
		{Name: oauthKeysCheck, Up: true, Hidden: true}}
	for _, c := range []struct {
		name        string
		write, last time.Time
		extra       []Component
		warn        int
	}{
		{"idle", now.Add(-time.Hour), now.Add(-54 * time.Minute), nil, 0},
		{"no storage database", time.Time{}, time.Time{}, nil, 0},
		{"metrics missing", now.Add(-time.Minute), now.Add(-time.Hour), nil, 1},
		{"metrics missing and a warning", now.Add(-time.Minute), now.Add(-time.Hour), []Component{{Name: "Sign-up gate", Warn: true, Error: "x"}}, 2},
	} {
		app := &App{rec: &Recorder{received: c.last}}
		app.health = &Health{app: app, started: now.Add(-2 * time.Hour), lastWrite: c.write, components: append(append([]Component(nil), components...), c.extra...)}
		rows, shown, status := app.healthTable()
		notUp := 0
		for _, r := range shown {
			if !r.Up {
				notUp++
			}
		}
		if status.Warn != c.warn || status.Warn+status.Down != notUp || len(rows) != len(shown)+1 {
			t.Errorf("%s: %+v, %d rows not up in %+v", c.name, status, notUp, shown)
		}
		if light := app.healthSummary(); *light != *status {
			t.Errorf("%s: light %+v, table %+v", c.name, light, status)
		}
		// the row in the table, and Needs attention of the same rows
		in := allGood(now)
		in.components = rows
		var lines int
		for _, a := range needsAttention(in) {
			if a.Href == "/activity" {
				lines++
			}
		}
		if silent := c.warn > 0; silent != (lines == 1) || silent != (shown[len(shown)-1].Name == metricsCheck) {
			t.Errorf("%s: %d lines, rows %+v", c.name, lines, shown)
		}
		var b strings.Builder
		if err := templates.ExecuteTemplate(&b, "light", status); err != nil {
			t.Fatal(err)
		}
		if got := strings.Contains(b.String(), "to check"); got != (c.warn > 0) {
			t.Errorf("%s: light %s", c.name, b.String())
		}
	}
}

func TestPaginate(t *testing.T) {
	for _, c := range []struct{ total, page, from, to, current, pages int }{
		{0, 1, 0, 0, 1, 1},
		{1, 1, 0, 1, 1, 1},
		{50, 1, 0, 50, 1, 1},
		{51, 1, 0, 50, 1, 2},
		{51, 2, 50, 51, 2, 2},
		{120, 3, 100, 120, 3, 3},
		{120, 9, 100, 120, 3, 3},
		{120, -4, 0, 50, 1, 3},
	} {
		from, to, current, pages := paginate(c.total, c.page, 50)
		if from != c.from || to != c.to || current != c.current || pages != c.pages {
			t.Errorf("%d rows, page %d: %d-%d page %d of %d", c.total, c.page, from, to, current, pages)
		}
	}
	p, from, to := newPager(120, 2, "Alice Smith", "blocked")
	if from != 50 || to != 100 || p.From != 51 || p.To != 100 || p.Total != 120 || p.Page != 2 || p.Pages != 3 {
		t.Errorf("%+v", p)
	}
	for _, link := range []string{p.Prev, p.Next} {
		u, err := url.Parse(link)
		if err != nil || u.Path != "/" || u.Query().Get("q") != "Alice Smith" || u.Query().Get("show") != "blocked" || u.Fragment != "accounts" {
			t.Errorf("link %q", link)
		}
	}
	if u, _ := url.Parse(p.Next); u.Query().Get("page") != "3" {
		t.Errorf("next %q", p.Next)
	}
	if u, _ := url.Parse(p.Prev); u.Query().Has("page") {
		t.Errorf("prev of page 2 is the first: %q", p.Prev)
	}
	if p, _, _ := newPager(10, 1, "", ""); p.Prev != "" || p.Next != "" || p.From != 1 || p.To != 10 {
		t.Errorf("one page: %+v", p)
	}
	if p, _, _ := newPager(0, 1, "x", ""); p.From != 0 || p.To != 0 {
		t.Errorf("none: %+v", p)
	}
}

func TestMatchAccount(t *testing.T) {
	for _, c := range []struct {
		q    string
		want bool
	}{
		{"", true}, {"alice", true}, {"example.com", true}, {"0123ab", true}, {"laptop", true}, {"bob", false},
		// the account of the tokenserver uid or another address, found by the caller
		{"42", true}, {"43", false},
	} {
		id := ""
		if c.q == "42" {
			id = fakeUID
		}
		if got := matchAccount(c.q, fakeUID, "Alice@Example.com", "Work Laptop", id); got != c.want {
			t.Errorf("%q: %v", c.q, got)
		}
	}
}

func TestBackupMetrics(t *testing.T) {
	now := time.Now()
	var b strings.Builder
	backupMetrics(&b, []BackupStatus{
		{Scope: "sync", Last: BackupRun{OK: true, Finished: now.Add(-90 * time.Minute)}, LastOK: BackupRun{OK: true, Finished: now.Add(-90 * time.Minute)}},
		{Scope: "accounts", Last: BackupRun{Finished: now}},
	}, now)
	out := b.String()
	for _, want := range []string{"ffs_backup_age_seconds{scope=\"sync\"} 5400\n", "ffs_backup_last_ok{scope=\"sync\"} 1\n", "ffs_backup_last_ok{scope=\"accounts\"} 0\n"} {
		if !strings.Contains(out, want) {
			t.Errorf("no %q in %s", want, out)
		}
	}
	// no good one yet: no age
	if strings.Contains(out, `ffs_backup_age_seconds{scope="accounts"}`) {
		t.Error(out)
	}
	b.Reset()
	backupMetrics(&b, nil, now)
	if b.Len() != 0 {
		t.Error("metrics without backups")
	}
}

func TestOverviewSearchAttentionAndDevices(t *testing.T) {
	fake := &fakeFxa{allDevices: [][]driver.Value{{fakeUID, int64(1700000000000), float64(1700000100000), fakeRef}}}
	redis, _ := fakeRedis(t)
	app := testApp()
	app.fxa, app.sync, app.alerter, app.staleDays = fake.db(redis), &SyncDB{db: sql.OpenDB(fake)}, &Alerter{}, 30
	app.health = newHealth(app)
	h := app.routes()
	c, _ := passwordSession(t, app, h)
	page := getPage(h, "/", c).Body.String()
	// the fake account has an unconfirmed sign-in and an old device
	for _, want := range []string{`<section id="attention">`, `with a sign-in that never entered its email code`, `href="/users/` + fakeUID + `#sessions-card">Sessions</a>`,
		`1 device of 1 account not used for 30 days`, `href="/users/` + fakeUID + `#devices"`, `<span class="badge">1 inactive device</span>`,
		`<tr data-email="` + fakeEmail + `">`, `<span id="accounts-total">1</span>`} {
		if !strings.Contains(page, want) {
			t.Errorf("overview: no %q", want)
		}
	}
	for q, found := range map[string]bool{"ALICE": true, "0123abcd": true, "example.com": true, "bob": false} {
		page := getPage(h, "/?q="+url.QueryEscape(q), c).Body.String()
		if strings.Contains(page, `<tr data-email="`+fakeEmail+`">`) != found || strings.Contains(page, "No account matches.") == found {
			t.Errorf("search %q: found %v", q, !found)
		}
		if !strings.Contains(page, `value="`+q+`"`) || !strings.Contains(page, `id="search-result"`) {
			t.Errorf("search %q: not kept in the form", q)
		}
		// a search is a filter: All accounts is not the current chip
		if strings.Contains(page, `aria-current="true">All accounts`) {
			t.Errorf("search %q: All accounts current", q)
		}
	}
	if page := getPage(h, "/", c).Body.String(); !strings.Contains(page, `<a href="/#accounts" aria-current="true">All accounts</a>`) {
		t.Error("All accounts not current without a filter")
	}
	page = getPage(h, "/?show=blocked", c).Body.String()
	if strings.Contains(page, `<tr data-email=`) || !strings.Contains(page, `<input type="hidden" name="show" value="blocked">`) ||
		!strings.Contains(page, `id="search-result">0 accounts blocked by the rate limits.`) {
		t.Error("filter blocked")
	}
	if page := getPage(h, "/?show=unconfirmed-sign-in", c).Body.String(); !strings.Contains(page, `<tr data-email="`+fakeEmail+`">`) {
		t.Error("filter unconfirmed sign-in")
	}
	user := getPage(h, "/users/"+fakeUID, c).Body.String()
	if !strings.Contains(user, `<span class="badge">inactive</span>`) || !strings.Contains(user, "not used for 30 days (<code>ADMIN_STALE_DAYS</code>)") {
		t.Errorf("device badge: %s", user)
	}
	app.staleDays = 365 * 100
	if user := getPage(h, "/users/"+fakeUID, c).Body.String(); strings.Contains(user, `<span class="badge">inactive</span>`) {
		t.Error("a device used within ADMIN_STALE_DAYS marked inactive")
	}
}

func TestOverviewShowsBackupsAndPages(t *testing.T) {
	page := pages(t)["dashboard.html"]
	for _, want := range []string{`<li>Sync server is down: x. <a href="#health">Health</a></li>`,
		`<p class="hint" data-scope="sync">Last backup of the Sync databases: `, `2.0 KB, <span class="ok">ok</span>.`,
		`<p class="hint" data-scope="accounts">Last backup of the accounts databases: `, `<span class="disabled">failed</span>: access denied (the last good one: `,
		`<span id="accounts-shown">1–50</span> of <span id="accounts-total">60</span>, newest first, page 1 of 2.`, `<a href="/?page=2#accounts" rel="next" id="older">`} {
		if !strings.Contains(page, want) {
			t.Errorf("no %q", want)
		}
	}
	if strings.Contains(page, `id="all-good"`) || strings.Contains(page, `id="newer"`) {
		t.Error("all good, or a link to newer accounts on the first page")
	}
}

// sessionRedis: a Redis that answers MGET from caches by key (others: no key), counting
// its connections
func sessionRedis(t *testing.T, caches map[string]string) (string, *atomic.Int32) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	var conns atomic.Int32
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			conns.Add(1)
			go func() {
				defer conn.Close()
				r := bufio.NewReader(conn)
				for {
					cmd, err := readReply(r)
					args, _ := cmd.([]any)
					if err != nil || len(args) == 0 || args[0] != "MGET" {
						return
					}
					var out strings.Builder
					fmt.Fprintf(&out, "*%d\r\n", len(args)-1)
					for _, k := range args[1:] {
						if v, ok := caches[k.(string)]; ok {
							fmt.Fprintf(&out, "$%d\r\n%s\r\n", len(v), v)
						} else {
							out.WriteString("$-1\r\n")
						}
					}
					conn.Write([]byte(out.String()))
				}
			}()
		}
	}()
	return ln.Addr().String(), &conns
}

func TestInactiveDevicesOneRedisConnection(t *testing.T) {
	used, broken, plain := fakeUID, strings.Repeat("b", 32), strings.Repeat("c", 32)
	recent := time.Now().UnixMilli()
	redis, conns := sessionRedis(t, map[string]string{
		"fxa-auth-session" + used:   fmt.Sprintf(`{"%s":[%d]}`, fakeToken, recent),
		"fxa-auth-session" + broken: `{"x": broken`,
	})
	old := int64(1700000000000)
	fake := &fakeFxa{allDevices: [][]driver.Value{
		{used, old, float64(old), fakeRef},   // used lately, per Redis
		{broken, old, float64(old), fakeRef}, // its cache unreadable: left out
		{plain, old, float64(old), "r1"},     // no cache: the database's times
		{plain, old, float64(old), "r2"},
	}}
	inactive, err := fake.db(redis).InactiveDevices(context.Background(), time.Now().Add(-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if len(inactive) != 1 || inactive[plain] != 2 {
		t.Errorf("inactive %v", inactive)
	}
	if n := conns.Load(); n != 1 {
		t.Errorf("%d Redis connections", n)
	}
	// Redis away: an error, no guess
	if _, err := fake.db("127.0.0.1:1").InactiveDevices(context.Background(), time.Now().Add(-time.Hour)); err == nil {
		t.Error("no error without Redis")
	}
}
