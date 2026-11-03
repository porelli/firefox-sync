package main

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"
)

// the startup grace, the fast retries and the transitions (health.go), with a Sync
// server and a public URL that goes through it
type startupStack struct {
	h          *Health
	alerter    *Alerter
	syncUp     bool
	publicErr  error
	publicRuns int
}

func newStartupStack(retry time.Duration) *startupStack {
	st := &startupStack{alerter: &Alerter{}, publicErr: errors.New("example.com/__heartbeat__: status 502 through the reverse proxy")}
	h := newHealthFor(&App{alerter: st.alerter})
	h.grace, h.round = startupGrace, time.Minute
	h.checks = []check{
		{name: "Sync server", health: func(context.Context) error {
			if !st.syncUp {
				return errors.New("connection refused")
			}
			return nil
		}},
		{name: "Public Sync URL", every: time.Hour, retry: retry, after: []string{"Sync server"}, fast: true,
			run: func(context.Context) (string, error) {
				st.publicRuns++
				if st.publicErr != nil {
					return "", st.publicErr
				}
				return "example.com: reachable", nil
			}},
	}
	h.fastOn = map[string]bool{"Public Sync URL": true}
	h.noRuntime = deployment{}.noRuntime()
	st.h = h
	return st
}

func (st *startupStack) component(t *testing.T, name string) Component {
	t.Helper()
	for _, c := range st.h.Components() {
		if c.Name == name {
			return c
		}
	}
	t.Fatalf("no %s in %+v", name, st.h.Components())
	return Component{}
}

// due: the next check of name is now
func (st *startupStack) due(name string) {
	st.h.mu.Lock()
	if st.h.nextRun != nil {
		st.h.nextRun[name] = time.Now().Add(-time.Millisecond)
	}
	st.h.mu.Unlock()
}

func TestStartupGraceWaitsForTheParts(t *testing.T) {
	st := newStartupStack(25 * time.Minute)
	ctx := context.Background()
	// the admin UI first: the Sync server not up yet, the public URL not run
	st.h.checkAll(ctx)
	// no runtime to ask: waiting, saying why, not starting
	sync, public := st.component(t, "Sync server"), st.component(t, "Public Sync URL")
	if !sync.Waiting || sync.Starting || sync.Up || !strings.Contains(sync.Error, "no answer yet since the admin UI started, and the admin UI does not see the Docker containers") ||
		!strings.Contains(sync.Error, "(connection refused): down if still so at ") {
		t.Fatalf("before the Sync server: %+v", sync)
	}
	if !public.Waiting || st.publicRuns != 0 || public.Error != "waiting for Sync server: checked as soon as it is up" {
		t.Fatalf("before the Sync server: %+v, %d runs", public, st.publicRuns)
	}
	// waiting is neither up nor down: not in Needs attention, not counted down
	if s := summarize(st.h.Components()); s.Down != 0 || s.Warn != 0 || s.Waiting != 2 || s.Starting != 0 || s.Up != 0 {
		t.Errorf("summary %+v", s)
	}
	if list := needsAttention(attentionInput{components: st.h.Components(), now: time.Now()}); len(list) != 0 {
		t.Errorf("attention %+v", list)
	}
	// a round of startingRound while a part is starting
	if d, ok := st.h.untilDue(time.Now()); !ok || d > startingRound {
		t.Errorf("next round in %v %v", d, ok)
	}
	// the Sync server up: the public URL at once, in the same round; behind the proxy still 502
	st.syncUp = true
	st.h.checkAll(ctx)
	public = st.component(t, "Public Sync URL")
	if st.publicRuns != 1 || !public.Waiting || public.Up || public.Checked.IsZero() || strings.Contains(public.Error, "Docker") {
		t.Fatalf("with the Sync server up: %+v, %d runs", public, st.publicRuns)
	}
	// fast retries: 30 s, not 25 minutes
	if wait := public.Next.Sub(public.Checked); wait != fastRetries[0] {
		t.Errorf("retry in %v", wait)
	}
	// then up: neither its failure nor its coming up announced
	st.publicErr = nil
	st.due("Public Sync URL")
	st.h.checkAll(ctx)
	if public = st.component(t, "Public Sync URL"); !public.Up || public.pending() || public.Next.Sub(public.Checked) != time.Hour {
		t.Errorf("up: %+v", public)
	}
	if lines := st.alerter.take(); len(lines) != 0 {
		t.Errorf("alerts of the start: %q", lines)
	}
	// once up, a failure in the grace is a real one
	st.syncUp = false
	st.h.checkAll(ctx)
	if sync = st.component(t, "Sync server"); sync.pending() || sync.Up {
		t.Errorf("down after up: %+v", sync)
	}
	if lines := st.alerter.take(); len(lines) != 1 || !strings.Contains(lines[0], "health: Sync server is down: connection refused") {
		t.Errorf("alerts: %q", lines)
	}
}

func TestStartupGraceEnds(t *testing.T) {
	st := newStartupStack(25 * time.Minute)
	ctx := context.Background()
	st.h.checkAll(ctx)
	st.syncUp = true
	st.h.checkAll(ctx)
	if lines := st.alerter.take(); len(lines) != 0 {
		t.Fatalf("alerts in the grace: %q", lines)
	}
	// still failing at the end of the grace: checked at once (not at its retry), announced
	runs := st.publicRuns
	st.h.started = time.Now().Add(-startupGrace - time.Second)
	st.h.checkAll(ctx)
	public := st.component(t, "Public Sync URL")
	if st.publicRuns != runs+1 || public.pending() || public.Up {
		t.Errorf("after the grace: %+v, %d runs", public, st.publicRuns-runs)
	}
	if lines := st.alerter.take(); len(lines) != 1 || !strings.Contains(lines[0], "health: Public Sync URL is down: example.com/__heartbeat__: status 502") {
		t.Errorf("alerts: %q", lines)
	}

	// a part never up: down at the end of the grace, and what goes through it is run
	st = newStartupStack(25 * time.Minute)
	st.h.checkAll(ctx)
	st.h.started = time.Now().Add(-startupGrace - time.Second)
	st.h.checkAll(ctx)
	if sync := st.component(t, "Sync server"); sync.pending() || sync.Up || st.publicRuns != 1 {
		t.Errorf("never up: %+v, %d runs", sync, st.publicRuns)
	}
	lines := st.alerter.take()
	if len(lines) != 2 || !strings.Contains(lines[0], "Sync server is down") || !strings.Contains(lines[1], "Public Sync URL is down") {
		t.Errorf("alerts: %q", lines)
	}
}

func TestFastRetries(t *testing.T) {
	st := newStartupStack(20 * time.Minute)
	st.syncUp = true
	ctx := context.Background()
	var waits []time.Duration
	for range len(fastRetries) + 2 {
		st.due("Public Sync URL")
		st.h.checkAll(ctx)
		c := st.component(t, "Public Sync URL")
		waits = append(waits, c.Next.Sub(c.Checked))
	}
	want := append(append([]time.Duration(nil), fastRetries...), 20*time.Minute, 20*time.Minute)
	for i := range want {
		if waits[i] != want[i] {
			t.Fatalf("retries %v, want %v", waits, want)
		}
	}
	// never longer than its retry (HEALTH_CHECK_SECONDS=5 in the tests: 25 s)
	st = newStartupStack(25 * time.Second)
	st.syncUp = true
	st.h.checkAll(ctx)
	if c := st.component(t, "Public Sync URL"); c.Next.Sub(c.Checked) != 25*time.Second {
		t.Errorf("retry %v", c.Next.Sub(c.Checked))
	}
	// a fast retry before the next round wakes the loop
	if d, ok := st.h.untilDue(time.Now()); !ok || d > 25*time.Second {
		t.Errorf("until due %v %v", d, ok)
	}
}

func TestPartBackUpRunsWhatGoesThroughIt(t *testing.T) {
	st := newStartupStack(25 * time.Minute)
	st.h.grace = 0
	st.syncUp, st.publicErr = true, nil
	ctx := context.Background()
	st.h.checkAll(ctx)
	if c := st.component(t, "Public Sync URL"); !c.Up || st.publicRuns != 1 {
		t.Fatalf("%+v", c)
	}
	// the Sync server down: the public URL not run before its hour
	st.syncUp = false
	st.h.checkAll(ctx)
	if st.publicRuns != 1 {
		t.Errorf("run while the Sync server is down, before its hour")
	}
	// back up: at once, with fast retries while it fails (the proxy not there yet)
	st.syncUp, st.publicErr = true, errors.New("status 502")
	st.h.checkAll(ctx)
	c := st.component(t, "Public Sync URL")
	if st.publicRuns != 2 || c.Up || c.Next.Sub(c.Checked) != fastRetries[0] {
		t.Errorf("after the Sync server came back: %+v, %d runs", c, st.publicRuns)
	}
	lines := st.alerter.take()
	if len(lines) != 3 || !strings.Contains(lines[0], "Sync server is down") || !strings.Contains(lines[1], "Sync server is back up") || !strings.Contains(lines[2], "Public Sync URL is down: status 502") {
		t.Errorf("alerts: %q", lines)
	}
	// any part back up: a failing public check again at once
	dbUp := false
	st.h.checks = append([]check{{name: "Admin UI database", health: func(context.Context) error {
		if !dbUp {
			return errors.New("down")
		}
		return nil
	}}}, st.h.checks...)
	st.h.checkAll(ctx)
	runs := st.publicRuns
	dbUp = true
	st.h.checkAll(ctx)
	if runs != 2 || st.publicRuns != 3 {
		t.Errorf("runs %d then %d", runs, st.publicRuns)
	}
}

func TestPublicChecksGoThroughTheParts(t *testing.T) {
	for k, v := range map[string]string{"ADMIN_PUBLIC_CHECK": "true", "FXA_CONTENT_URL": "https://accounts.example.com", "FXA_AUTH_URL": "https://api.accounts.example.com",
		"FXA_PROFILE_URL": "https://profile.accounts.example.com", "FXA_OAUTH_SERVER_URL": "http://fxa-auth:9000/v1"} {
		t.Setenv(k, v)
	}
	app := &App{fxa: &FxaDB{}}
	after := map[string]string{}
	for _, c := range (&Health{}).publicChecksOf(app) {
		if !c.fast || len(c.after) != 1 {
			t.Errorf("%s: fast %v after %v", c.name, c.fast, c.after)
			continue
		}
		after[c.name] = c.after[0]
	}
	want := map[string]string{"Public Sync URL": "Sync server", "Public accounts pages": "Accounts pages", "Public accounts API": "Accounts API",
		"Public profile server": "Profile server", "Sign-up gate": "Accounts API", oauthKeysCheck: "Accounts API"}
	for name, part := range want {
		if after[name] != part {
			t.Errorf("%s after %q, want %q", name, after[name], part)
		}
	}
	// Mozilla's accounts: the keys go through nothing of the stack
	t.Setenv("FXA_OAUTH_SERVER_URL", "https://oauth.accounts.firefox.com/v1")
	for _, c := range (&Health{}).publicChecksOf(&App{}) {
		if c.name == oauthKeysCheck && len(c.after) != 0 {
			t.Errorf("Mozilla's keys after %v", c.after)
		}
	}
}

func TestStartingSetupCheck(t *testing.T) {
	c := oauthKeysSetupCheck(Component{Name: oauthKeysCheck, Waiting: true, Error: "waiting for Accounts API: checked as soon as it is up"}, deployment{}, "http://fxa-auth:9000/v1")
	if !c.OK || strings.Contains(c.Text, "nobody gets a Sync token") || !strings.Contains(c.Text, "waiting for Accounts API") {
		t.Errorf("waiting: %+v", c)
	}
	if c := oauthKeysSetupCheck(Component{Name: oauthKeysCheck, Error: "connection refused"}, deployment{}, "http://fxa-auth:9000/v1"); c.OK || !strings.Contains(c.Text, "nobody gets a Sync token") {
		t.Errorf("down: %+v", c)
	}
}

func TestClock(t *testing.T) {
	now := time.Date(2026, 11, 3, 18, 40, 0, 0, time.UTC)
	if got := clock(now.Add(-15*time.Minute), now, time.UTC); got != "18:25" {
		t.Errorf("today %q", got)
	}
	if got := clock(now.Add(6*time.Hour), now, time.UTC); got != "Nov 4 00:40" {
		t.Errorf("tomorrow %q", got)
	}
}

// a loop for the Check now tests: answers each ask with a round, counted
func fakeLoop(t *testing.T, h *Health) (*int, func()) {
	rounds := new(int)
	ctx, cancel := context.WithCancel(context.Background())
	stopped := make(chan struct{})
	stop := func() {
		cancel()
		<-stopped
	}
	t.Cleanup(cancel)
	go func() {
		defer close(stopped)
		for {
			select {
			case <-ctx.Done():
				return
			case done := <-h.wake:
				h.checkRound(ctx, true)
				h.mu.Lock()
				*rounds++
				h.mu.Unlock()
				close(done)
			}
		}
	}()
	return rounds, stop
}

func TestCheckNow(t *testing.T) {
	fake := &fakeFxa{}
	app := testApp()
	app.sync, app.alerter = &SyncDB{db: sql.OpenDB(fake)}, &Alerter{}
	app.health = newHealthFor(app)
	app.health.wake = make(chan chan struct{}, 1)
	runs := 0
	app.health.checks = []check{{name: "Public Sync URL", every: time.Hour, retry: time.Hour,
		run: func(context.Context) (string, error) { runs++; return "reachable", nil }}}
	app.health.checkAll(context.Background())
	rounds, stop := fakeLoop(t, app.health)
	h := app.routes()
	c, s := passwordSession(t, app, h)
	app.alerter.take()

	// not signed in, the wrong form token, another origin: nothing checked
	if w := post(h, "/health/check", url.Values{"csrf": {s.csrf}}, nil, nil); w.Code != http.StatusUnauthorized {
		t.Errorf("not signed in: %d", w.Code)
	}
	if w := post(h, "/health/check", url.Values{"csrf": {"wrong"}}, c, nil); w.Code != http.StatusForbidden {
		t.Errorf("wrong token: %d", w.Code)
	}
	if w := post(h, "/health/check", url.Values{"csrf": {s.csrf}}, c, map[string]string{"Origin": "https://evil.example.com"}); w.Code != http.StatusForbidden {
		t.Errorf("other origin: %d", w.Code)
	}
	if w := get(h, "/health/check", "", nil, c); w.Code != http.StatusMethodNotAllowed && w.Code != http.StatusNotFound {
		t.Errorf("GET: %d", w.Code)
	}
	if runs != 1 || *rounds != 0 {
		t.Fatalf("checked without a valid form: %d runs, %d rounds", runs, *rounds)
	}
	// every check at once, its hour not over; back to the Health card
	w := post(h, "/health/check", url.Values{"csrf": {s.csrf}}, c, nil)
	if w.Code != http.StatusSeeOther || w.Header().Get("Location") != "/#health-card" || runs != 2 || s.message != "Checked the health and the setup again." {
		t.Fatalf("check now: %d %q, %d runs, %q %q", w.Code, w.Header().Get("Location"), runs, s.message, s.failed)
	}
	// not a change: not in the audit trail, no alert
	if lines := app.alerter.take(); len(lines) != 0 {
		t.Errorf("alerted: %q", lines)
	}
	// at most every 30 seconds, whoever asks
	w = post(h, "/health/check", url.Values{"csrf": {s.csrf}, "back": {"setup"}}, c, nil)
	if w.Code != http.StatusSeeOther || w.Header().Get("Location") != "/#setup-card" || runs != 2 || !strings.Contains(s.failed, "again in") {
		t.Errorf("rate limit: %d %q, %d runs, %q", w.Code, w.Header().Get("Location"), runs, s.failed)
	}
	app.health.mu.Lock()
	app.health.checkedNow = time.Now().Add(-checkedNowEvery)
	app.health.mu.Unlock()
	if post(h, "/health/check", url.Values{"csrf": {s.csrf}}, c, nil); runs != 3 || s.failed != "" {
		t.Errorf("after 30 seconds: %d runs, %q", runs, s.failed)
	}
	// the loop busy: the overview at once, the round once it is free
	defer func(d time.Duration) { checkNowWait = d }(checkNowWait)
	checkNowWait = 50 * time.Millisecond
	stop()
	app.health.mu.Lock()
	app.health.checkedNow = time.Time{}
	app.health.mu.Unlock()
	if w := post(h, "/health/check", url.Values{"csrf": {s.csrf}}, c, nil); w.Code != http.StatusSeeOther || !strings.Contains(s.message, "show up in a moment") {
		t.Errorf("busy: %d %q", w.Code, s.message)
	}
	select {
	case done := <-app.health.wake:
		close(done)
	default:
		t.Error("the round not waiting for the loop")
	}
}

func TestOverviewFreshnessAndStarting(t *testing.T) {
	fake := &fakeFxa{allDevices: [][]driver.Value{}}
	app := testApp()
	app.sync, app.alerter = &SyncDB{db: sql.OpenDB(fake)}, &Alerter{}
	app.health = newHealthFor(app)
	checked := time.Now().Add(-time.Minute)
	app.health.components = []Component{
		{Name: "Sync server", Up: true, Checked: checked, Next: checked.Add(time.Minute)},
		{Name: "Public Sync URL", Waiting: true, Error: "waiting for Sync server: checked as soon as it is up"},
		{Name: "Accounts API", Starting: true, Since: checked, Error: "connection refused"},
		{Name: oauthKeysCheck, Hidden: true, Waiting: true, Error: "waiting for Accounts API: checked as soon as it is up"},
	}
	h := app.routes()
	c, _ := passwordSession(t, app, h)
	page := getPage(h, "/", c).Body.String()
	for _, want := range []string{`<span class="pill">waiting</span> <span class="hint">waiting for Sync server: checked as soon as it is up</span>`,
		`<span class="pill">starting</span> <span class="hint">since ` + clock(checked, time.Now(), adminZone) + `, 1 min: connection refused</span>`,
		clock(checked, time.Now(), adminZone) + ", next " + clock(checked.Add(time.Minute), time.Now(), adminZone),
		`action="/health/check"`, `name="back" value="setup"`, "1 of 3 parts up, 1 starting, 1 waiting", "of 3 parts working, 1 starting, 1 waiting",
		`<span class="word">Starting</span>`} {
		if !strings.Contains(page, want) {
			t.Errorf("overview: no %q", want)
		}
	}
	for _, not := range []string{"is down", "nobody gets a Sync token", `id="health-problems"`} {
		if strings.Contains(page, not) {
			t.Errorf("overview: %q while starting", not)
		}
	}
	// ffs_up 0 or 1, the state besides
	text := prometheusText(t, app)
	for _, want := range []string{`ffs_up{component="Public Sync URL"} 0`, `ffs_up{component="Sync server"} 1`, `ffs_component_state{component="Sync server",state="up"} 1`,
		`ffs_component_state{component="Public Sync URL",state="waiting"} 1`, `ffs_component_state{component="Accounts API",state="starting"} 1`} {
		if !strings.Contains(text, want) {
			t.Errorf("metrics: no %q", want)
		}
	}
}

// the runtime of the tests: the states it says, or an error
type fakeRuntime struct {
	states map[string]partState
	err    error
}

func (f *fakeRuntime) parts(context.Context) (map[string]partState, error) { return f.states, f.err }

func TestRuntimeStates(t *testing.T) {
	ctx := context.Background()
	newStack := func(state partState) (*startupStack, *fakeRuntime) {
		st := newStartupStack(25 * time.Minute)
		rt := &fakeRuntime{states: map[string]partState{"Sync server": state}}
		st.h.runtime = rt
		return st, rt
	}
	// starting (its pod not Ready, nothing restarted): starting since its pod, what goes
	// through it waits; then up, nothing announced
	since := time.Now().Add(-40 * time.Second)
	st, rt := newStack(partState{state: "starting", since: since})
	st.h.checkAll(ctx)
	sync, public := st.component(t, "Sync server"), st.component(t, "Public Sync URL")
	if !sync.Starting || sync.Waiting || !sync.Since.Equal(since) || !public.Waiting || st.publicRuns != 0 {
		t.Fatalf("starting: %+v %+v", sync, public)
	}
	if s := summarize(st.h.Components()); s.Starting != 1 || s.Waiting != 1 || s.Down != 0 {
		t.Errorf("summary %+v", s)
	}
	st.syncUp, rt.states["Sync server"] = true, partState{state: "running"}
	st.h.checkAll(ctx)
	if sync = st.component(t, "Sync server"); !sync.Up || st.publicRuns != 1 {
		t.Errorf("up: %+v, %d runs", sync, st.publicRuns)
	}
	if lines := st.alerter.take(); len(lines) != 0 {
		t.Errorf("alerts: %q", lines)
	}

	// a crash (restarts, an exit code): down at once, in the grace, with what the runtime says
	for _, crash := range []string{"syncstorage-7f (syncstorage): CrashLoopBackOff, 3 restarts, last exit code 1 (Error)", "syncstorage-7f (syncstorage): exited with code 2"} {
		st, _ = newStack(partState{state: "crashed", reason: crash})
		st.h.checkAll(ctx)
		if sync = st.component(t, "Sync server"); sync.pending() || sync.Up || !strings.HasSuffix(sync.Error, "; "+crash) {
			t.Errorf("crashed: %+v", sync)
		}
		// what goes through it is run, not waiting
		if public := st.component(t, "Public Sync URL"); public.Waiting || st.publicRuns != 1 {
			t.Errorf("through a crashed part: %+v", public)
		}
		// (and what goes through it, down with it)
		if lines := st.alerter.take(); len(lines) != 2 || !strings.Contains(lines[0], "health: Sync server is down: connection refused; "+crash) ||
			!strings.Contains(lines[1], "health: Public Sync URL is down") {
			t.Errorf("crash alerts: %q", lines)
		}
	}
	// a crash loop between two restarts says starting: never reported as such once it restarted
	st, rt = newStack(partState{state: "starting", since: time.Now()})
	st.h.checkAll(ctx)
	rt.states["Sync server"] = partState{state: "crashed", reason: "syncstorage-7f (syncstorage): 1 restart, last exit code 1"}
	st.h.checkAll(ctx)
	if sync = st.component(t, "Sync server"); sync.pending() {
		t.Errorf("restarted: %+v", sync)
	}
	if lines := st.alerter.take(); len(lines) != 2 || !strings.Contains(lines[0], "Sync server is down") {
		t.Errorf("restarted alerts: %q", lines)
	}

	// starting for longer than startupGrace since its pod started: down
	st, _ = newStack(partState{state: "starting", since: time.Now().Add(-startupGrace - time.Minute)})
	st.h.checkAll(ctx)
	if sync = st.component(t, "Sync server"); sync.pending() || !strings.Contains(sync.Error, "still not up 11 minutes after its pod started") {
		t.Errorf("ceiling: %+v", sync)
	}
	// its pod Ready, its check failing: down
	st, _ = newStack(partState{state: "running"})
	st.h.checkAll(ctx)
	if sync = st.component(t, "Sync server"); sync.pending() || sync.Up {
		t.Errorf("Ready and failing: %+v", sync)
	}
	// up once, then its pod starting again (deleted, rescheduled): starting, not alerted,
	// at most startupGrace, even after the grace of the admin UI
	st, rt = newStack(partState{state: "running"})
	st.syncUp = true
	st.h.checkAll(ctx)
	st.h.started = time.Now().Add(-time.Hour)
	st.syncUp, rt.states["Sync server"] = false, partState{state: "starting", since: time.Now()}
	st.h.checkAll(ctx)
	if sync = st.component(t, "Sync server"); !sync.Starting {
		t.Errorf("restarted pod: %+v", sync)
	}
	if lines := st.alerter.take(); len(lines) != 0 {
		t.Errorf("restarted pod alerts: %q", lines)
	}
	// the pods not readable: waiting, saying so
	st, rt = newStack(partState{})
	rt.states, rt.err = nil, errors.New("listing the pods: status 403")
	st.h.checkAll(ctx)
	if sync = st.component(t, "Sync server"); !sync.Waiting || !strings.Contains(sync.Error, "the state of the pods is not readable: listing the pods: status 403") {
		t.Errorf("no pods: %+v", sync)
	}
}

func TestNoRuntime(t *testing.T) {
	for d, want := range map[deployment]string{{}: "Docker", {kind: "quadlets"}: "Podman", {kind: "kubernetes"}: "admin.podStatus is off"} {
		if got := d.noRuntime(); !strings.Contains(got, want) {
			t.Errorf("%+v: %q", d, got)
		}
	}
	t.Setenv("ADMIN_K8S_POD_STATUS", "true")
	if got := (deployment{kind: "kubernetes"}).noRuntime(); got != "" {
		t.Errorf("kubernetes with admin.podStatus: %q", got)
	}
	if got := (deployment{}).noRuntime(); !strings.Contains(got, "Docker") {
		t.Errorf("compose with ADMIN_K8S_POD_STATUS: %q", got)
	}
}
