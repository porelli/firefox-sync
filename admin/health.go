package main

import (
	"context"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Health of the components, their versions, the sizes of the databases and the
// newest upstream releases, checked in the background every minute

type Component struct {
	Name    string
	Up      bool
	Warn    bool // not up: it works, with a problem to look at (a certificate about to expire)
	Error   string
	Detail  string // what the check saw, shown next to up
	Version string
	Latest  string // newest upstream release, when newer than Version
	Checked time.Time
	// not in the health table: one of the setup checks of the overview
	Hidden bool
	// a limit of accounts (limits.go): in the table, counted only when near or full
	Limit bool
	// the word of the pill instead of "problem" (near the limit, full)
	Label string
	// not up, and its container is starting (the runtime says so: its pod is not Ready
	// yet, nothing restarted), since Since: neither down nor alerted, until startupGrace
	Starting bool
	Since    time.Time
	// not up yet since the admin UI started, in its startup grace, with nothing to say
	// whether it is starting (no runtime to ask, not a container), or waiting for a part
	// it goes through: neither down nor alerted. Error says what it waits for, and why
	Waiting bool
	// when it is checked next (zero: once the parts it depends on are up, or not known)
	Next time.Time
}

// pending: starting or waiting, neither up nor down
func (c Component) pending() bool { return c.Starting || c.Waiting }

type check struct {
	name   string
	health func(ctx context.Context) error
	// instead of health: what to show next to up. errSkip: no row (nothing to check)
	run     func(ctx context.Context) (string, error)
	version func(ctx context.Context) (string, error)
	// upstream repository (owner/name) whose releases are compared with the version
	upstream string
	// run at most every every, while it fails every retry (0: every round)
	every, retry time.Duration
	hidden       bool
	// the components it goes through (the public URLs through the Sync server, the
	// accounts...): in the startup grace not run before they are up, and run again at
	// once when one of them comes back up
	after []string
	// fastRetries while it fails after the start or after a part came back up
	fast bool
}

// the startup grace: the admin UI starts with the stack, often before the parts it
// checks (docker compose up -d of the whole stack, the pods of the chart in any order).
// For this long a part not up yet since the start is "waiting" (or "starting", when its
// runtime says so: then for this long since its pod started), not down, and not alerted;
// what goes through it waits for it. A crash the runtime sees is down at once
const startupGrace = 10 * time.Minute

// the retries of a fast check while it fails after the start or after a part it
// depends on came back up, then its retry
var fastRetries = []time.Duration{30 * time.Second, time.Minute, 2 * time.Minute, 5 * time.Minute}

// in the startup grace, while a part is starting: a round of the checks this often
const startingRound = 10 * time.Second

// errSkip: a check with nothing to check (no https URL...), left out
var errSkip = errors.New("nothing to check")

// warning: a check that works with a problem, e.g. a certificate that expires soon
type warning struct{ msg string }

func (w warning) Error() string { return w.msg }

func (c Component) state() string {
	switch {
	case c.Up:
		return "up"
	case c.Starting:
		return "starting"
	case c.Waiting:
		return "waiting"
	case c.Warn:
		return "warn"
	}
	return "down"
}

type Health struct {
	app    *App
	checks []check
	client *http.Client

	mu         sync.Mutex
	components []Component
	sizes      map[string]int64
	latest     map[string]string // upstream repository -> newest release
	latestAt   time.Time
	notified   map[string]bool // releases already announced
	lastSignup time.Time
	started    time.Time
	alerted    map[string]time.Time // new accounts and devices already alerted
	// accounts (uid and action) blocked by the rate limits, alerted: until when
	blockAlerted map[string]time.Time
	lastRun      map[string]time.Time // of the checks with every
	// when each check with every is due, and the fast retries of the fast ones: those
	// used, whether on
	nextRun  map[string]time.Time
	fastUsed map[string]int
	fastOn   map[string]bool
	// the startup grace (startupGrace; 0: none), the rounds (HEALTH_CHECK_SECONDS), the
	// components up at least once since the start, the end of the last round
	grace     time.Duration
	round     time.Duration
	everUp    map[string]bool
	lastRound time.Time
	// Check now: a round of every check asked of the loop (closed once done; one waits
	// while the loop is busy), the last ask
	wake       chan chan struct{}
	checkedNow time.Time
	// the container runtime (runtime.go), nil: none, and why not
	runtime     runtimeView
	noRuntime   string
	runtimeRead bool
	// certificates of the public URLs: host -> NotAfter
	certs map[string]time.Time
	// the trust of the public checks, nil: the system's (the tests set their own)
	rootCAs *x509.CertPool
	// schema levels of the databases, see schema.go, and the error logged last
	schema    []SchemaLevel
	schemaErr string
	// the setup migrations of the database servers (setupmigrations.go)
	setup []SetupStatus
	// the load of the Sync node, counted again (nodeload.go): the last recount, the last
	// one that corrected a drift of nodeLoadDrift or more
	loadResynced  time.Time
	loadCorrected *loadCorrection
	// the last alert of a burst of sign-ups (maintenance.go)
	burstAlerted time.Time
	// the runs of the backups (backup.go)
	backups []BackupStatus
	// when the Sync server last came up: its first metrics follow it (attention.go)
	syncUpSince time.Time
	// the latest write of the storage database, read every round: data changed without
	// metrics is their silence (attention.go)
	lastWrite time.Time
	// the state of each condition alerted once per change (attention.go), the errors logged last
	states, logged map[string]string
	// the rows of the limits of accounts (limits.go), from the last round or the overview
	limits []Component
	// the thresholds of the error rate (errors.go) and of the growth of the databases
	// (growth.go), their last rounds
	errorRate      errorRateConfig
	lastErrorRate  *ErrorRate
	growth         growthConfig
	dbGrowth       []DBGrowth
	growthMeasured bool
	// the security history of the accounts (securityevents.go): where the next read starts
	// (the overlap included), the events it can read again, and those seen since the start
	// by name
	lastSecurity   time.Time
	securitySeen   map[string]time.Time
	securityCounts map[string]int64
	// where the admin UI left off before this start (ffs_meta): events older than this are
	// not alerted (zero: the start); whether it was read; the alerted events it can read
	// again kept there, and those to keep or to forget there at the next save
	securityFloor   time.Time
	securityResumed bool
	securityKept    map[string]bool
	securityAdd     map[string]time.Time
	securityForget  []string
}

// GitHub's API, for the release check (the tests use their own)
var githubAPI = "https://api.github.com"

// rows of new accounts and devices can commit a bit after their createdAt: each
// round looks back this much more, alerted ones are skipped
const watchOverlap = time.Minute

func httpCheck(client *http.Client, url string) func(ctx context.Context) error {
	return func(ctx context.Context) error {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return err
		}
		res, err := client.Do(req)
		if err != nil {
			return err
		}
		res.Body.Close()
		if res.StatusCode != http.StatusOK {
			return fmt.Errorf("status %d", res.StatusCode)
		}
		return nil
	}
}

// versionOf reads {"version": "..."} from a /__version__ endpoint
func versionOf(client *http.Client, url string) func(ctx context.Context) (string, error) {
	return func(ctx context.Context) (string, error) {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return "", err
		}
		res, err := client.Do(req)
		if err != nil {
			return "", err
		}
		defer res.Body.Close()
		var v struct {
			Version string `json:"version"`
		}
		if err := json.NewDecoder(io.LimitReader(res.Body, 1<<16)).Decode(&v); err != nil {
			return "", err
		}
		return v.Version, nil
	}
}

func newHealth(app *App) *Health {
	client := &http.Client{Timeout: 10 * time.Second}
	h := &Health{app: app, client: client, latest: map[string]string{}, notified: map[string]bool{}, alerted: map[string]time.Time{},
		errorRate: errorRateSettings(), growth: growthSettings()}
	h.lastSignup, h.started = time.Now(), time.Now()
	h.grace, h.round, h.wake = startupGrace, time.Duration(envInt("HEALTH_CHECK_SECONDS", 60))*time.Second, make(chan chan struct{}, 1)
	h.noRuntime = app.deployment.noRuntime()
	if view, err := newPodView(app.deployment); err != nil {
		log.Printf("the state of the pods: %v", err)
		h.noRuntime = err.Error()
	} else if view != nil {
		h.runtime = view
	}
	sync := strings.TrimSuffix(env("SYNCSTORAGE_URL", "http://syncstorage:8000"), "/")
	h.checks = append(h.checks,
		check{name: "Sync server", health: httpCheck(client, sync+"/__heartbeat__"), version: versionOf(client, sync+"/__version__"), upstream: "mozilla-services/syncstorage-rs"},
		check{name: "Tokenserver database", health: app.sync.Ping, version: app.sync.Version},
	)
	if app.storage != nil && !app.sync.postgres {
		h.checks = append(h.checks, check{name: "Storage database", health: func(ctx context.Context) error { return app.storage.db.PingContext(ctx) }, version: app.storage.Version})
	}
	if app.deleter != nil {
		// the endpoint on, with the public half of the admin UI's key (deletedata.go)
		h.checks = append(h.checks, check{name: deleteCheckName, run: app.deleter.probe})
	}
	if app.sync != nil && app.sync.own != nil {
		own := app.sync.own
		// the event log and the audit trail (owndb.go), on the tokenserver's server
		h.checks = append(h.checks, check{name: "Admin UI database", health: own.PingContext})
	}
	if app.fxa != nil {
		auth := strings.TrimSuffix(env("FXA_AUTH_UPSTREAM", "http://fxa-auth:9000"), "/")
		content := strings.TrimSuffix(env("FXA_CONTENT_INTERNAL_URL", "http://fxa-content:3030"), "/")
		profile := strings.TrimSuffix(env("FXA_PROFILE_INTERNAL_URL", "http://fxa-profile:1111"), "/")
		h.checks = append(h.checks,
			check{name: "Accounts API", health: httpCheck(client, auth+"/__heartbeat__"), version: versionOf(client, auth+"/__version__"), upstream: "mozilla/fxa"},
			check{name: "Accounts pages", health: httpCheck(client, content+"/__heartbeat__"), version: versionOf(client, content+"/__version__")},
			check{name: "Profile server", health: httpCheck(client, profile+"/__heartbeat__"), version: versionOf(client, profile+"/__version__")},
			check{name: "Accounts database", health: app.fxa.Ping, version: app.fxa.Version},
			check{name: "Accounts Redis", version: func(ctx context.Context) (string, error) { return redisVersion(ctx, app.fxa.redis) }, health: func(ctx context.Context) error {
				conn, err := dialRedis(ctx, app.fxa.redis)
				if err != nil {
					return err
				}
				defer conn.Close()
				_, err = conn.Do("PING")
				return err
			}},
		)
		// nothing leaves the stack: the accounts pages' telemetry settings (telemetry.go)
		h.checks = append(h.checks, h.telemetryCheckOf(content, env("FXA_CONTENT_URL", "")))
		// the optional pairing server (COMPOSE_PROFILES=pairing): its version is in the heartbeat,
		// not compared with the releases (the crate version lags behind the tags)
		if env("FXA_PAIRING_URL", "") != "" {
			pairing := strings.TrimSuffix(env("FXA_PAIRING_INTERNAL_URL", "http://fxa-pairing:8000"), "/")
			h.checks = append(h.checks, check{name: "Pairing server", health: httpCheck(client, pairing+"/__heartbeat__"),
				version: func(ctx context.Context) (string, error) {
					// our builds fill /__version__, Mozilla's say TBD there and have the crate version in the heartbeat
					if v, err := versionOf(client, pairing+"/__version__")(ctx); err == nil && v != "" && v != "TBD" {
						return v, nil
					}
					return versionOf(client, pairing+"/__heartbeat__")(ctx)
				}})
		}
	}
	if m := smtpServer(); m != nil {
		detail := net.JoinHostPort(m.host, m.port)
		if m.user != "" {
			detail += ", signs in as " + m.user
		}
		// every hour, and while it fails every 10 minutes: not a sign-in a minute with a wrong password
		h.checks = append(h.checks, check{name: "Email (SMTP)", every: time.Hour, retry: 10 * time.Minute,
			run: func(context.Context) (string, error) { return detail, m.check(10 * time.Second) }})
	}
	if app.alerter != nil && len(app.alerter.notifiers) > 0 {
		h.checks = append(h.checks, check{name: notifyCheckName, run: app.alerter.notifyCheck})
	}
	h.checks = append(h.checks, h.publicChecksOf(app)...)
	// this program, at the top of the list
	h.checks = append([]check{{name: "Admin UI", health: func(context.Context) error { return nil },
		version: func(context.Context) (string, error) { return version, nil }}}, h.checks...)
	h.fastOn = map[string]bool{}
	for _, c := range h.checks {
		h.fastOn[c.name] = c.fast
	}
	return h
}

func (h *Health) run(ctx context.Context) {
	tick := time.NewTicker(time.Duration(envInt("HEALTH_CHECK_SECONDS", 60)) * time.Second)
	defer tick.Stop()
	lastSizes := time.Time{}
	for {
		h.checkAll(ctx)
		h.watchAccounts(ctx)
		h.watchSignupBurst(ctx, time.Now())
		h.watchRefusals(ctx)
		h.watchNodeLoad(ctx, time.Now())
		h.watchBlocks(ctx)
		h.watchSecurityEvents(ctx)
		h.watchSchema(ctx)
		h.watchSetup(ctx)
		h.watchBackups(ctx, time.Now())
		h.watchThresholds(ctx)
		if time.Since(lastSizes) >= time.Hour {
			h.measureSizes(ctx)
			lastSizes = time.Now()
		}
		if h.releasesDue(time.Now()) {
			h.checkReleases(ctx)
		}
		// until the next round: the checks due before it (fast retries, a part starting),
		// and Check now
		for waiting := true; waiting; {
			var due <-chan time.Time
			var timer *time.Timer
			if d, ok := h.untilDue(time.Now()); ok {
				timer = time.NewTimer(d)
				due = timer.C
			}
			select {
			case <-ctx.Done():
				return
			case <-tick.C:
				waiting = false
			case <-due:
				h.checkAll(ctx)
			case done := <-h.wake:
				h.checkRound(ctx, true)
				h.watchSchema(ctx)
				h.watchSetup(ctx)
				close(done)
			}
			if timer != nil {
				timer.Stop()
			}
		}
	}
}

// untilDue: how long until a check is due before the next round: a check with every
// (a fast retry), or a round of startingRound while a part is starting or waiting
func (h *Health) untilDue(now time.Time) (time.Duration, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	var at time.Time
	for _, next := range h.nextRun {
		if at.IsZero() || next.Before(at) {
			at = next
		}
	}
	for _, c := range h.components {
		if c.pending() {
			if soon := h.lastRound.Add(startingRound); at.IsZero() || soon.Before(at) {
				at = soon
			}
			break
		}
	}
	if at.IsZero() || (h.round > 0 && at.Sub(now) >= h.round) {
		return 0, false
	}
	return max(at.Sub(now), time.Second), true
}

// inGrace: in the startup grace (h.mu held)
func (h *Health) inGrace(now time.Time) bool {
	return h.grace > 0 && now.Before(h.started.Add(h.grace))
}

// waitAfter: how long until a check with every runs again after this result, a fast
// retry used when it failed (h.mu held)
func (h *Health) waitAfter(c check, up bool) time.Duration {
	if up {
		delete(h.fastUsed, c.name)
		h.fastOn[c.name] = false
		return c.every
	}
	if h.fastOn[c.name] {
		if n := h.fastUsed[c.name]; n < len(fastRetries) {
			h.fastUsed[c.name] = n + 1
			return min(fastRetries[n], c.retry)
		}
		h.fastOn[c.name] = false
	}
	return c.retry
}

// checkedNowEvery: Check now at most this often (whoever asks)
const checkedNowEvery = 30 * time.Second

// checkNow asks the loop for a round of every check, the setup's too, and waits for it
// until ctx ends: false then, the round still running. At most every checkedNowEvery
func (h *Health) checkNow(ctx context.Context, now time.Time) (bool, error) {
	h.mu.Lock()
	if since := now.Sub(h.checkedNow); !h.checkedNow.IsZero() && since < checkedNowEvery {
		h.mu.Unlock()
		return false, fmt.Errorf("checked %d seconds ago: again in %d seconds", int(since/time.Second), int((checkedNowEvery-since+time.Second-1)/time.Second))
	}
	h.checkedNow = now
	h.mu.Unlock()
	done := make(chan struct{})
	select {
	case h.wake <- done:
	case <-ctx.Done():
		return false, nil
	}
	select {
	case <-done:
		return true, nil
	case <-ctx.Done():
		return false, nil
	}
}

// checkNowWait: how long Check now waits for its round before showing the overview
var checkNowWait = 45 * time.Second

// notUp: a check that failed, its state from what the runtime says of its container
// (parts), else in the grace (h.mu held): a crash is down at once, with what the runtime
// says; starting is starting, for at most startupGrace since its pod started; nothing to
// say (no runtime, why, or not a container), never up since the start, in the grace:
// waiting. Else down
func (h *Health) notUp(comp *Component, parts map[string]partState, why string, grace bool, now time.Time) {
	part, seen := parts[comp.Name]
	switch {
	case seen && part.state == "crashed":
		comp.Error += "; " + part.reason
	case seen && part.state == "starting" && now.Sub(part.since) < startupGrace:
		comp.Starting, comp.Since = true, part.since
	case seen && part.state == "starting":
		comp.Error += fmt.Sprintf("; still not up %d minutes after its pod started", int(now.Sub(part.since)/time.Minute))
	case seen:
		// running (Ready) and failing: down
	case grace && !h.everUp[comp.Name]:
		comp.Waiting = true
		wait := "no answer yet since the admin UI started"
		if containerPart(comp.Name) && why != "" {
			wait += ", and " + why
		}
		comp.Error = wait + " (" + comp.Error + "): down if still so at " + clock(h.started.Add(h.grace), now, adminZone)
	}
}

// checkNow: the Check now button of the overview (POST, the form token): every
// health check and the setup's at once, at most every checkedNowEvery. Not a change:
// not in the audit trail
func (a *App) checkNow(w http.ResponseWriter, r *http.Request, s *session) {
	if a.health == nil {
		http.NotFound(w, r)
		return
	}
	to := "/#health-card"
	if r.PostFormValue("back") == "setup" {
		to = "/#setup-card"
	}
	ctx, cancel := context.WithTimeout(r.Context(), checkNowWait)
	defer cancel()
	done, err := a.health.checkNow(ctx, time.Now())
	message, failed := "Checked the health and the setup again.", ""
	switch {
	case err != nil:
		message, failed = "", "Not checked again: "+err.Error()+"."
	case !done:
		message = "Checking the health and the setup again: the results show up in a moment, reload the page."
	}
	a.mu.Lock()
	s.message, s.failed = message, failed
	a.mu.Unlock()
	http.Redirect(w, r, to, http.StatusSeeOther)
}

func (h *Health) checkAll(ctx context.Context) {
	h.checkRound(ctx, false)
}

// checkRound runs the checks due (force: all of them), in their order: the parts before
// what goes through them
func (h *Health) checkRound(ctx context.Context, force bool) {
	now := time.Now()
	h.mu.Lock()
	previous := map[string]Component{}
	for _, c := range h.components {
		previous[c.Name] = c
	}
	if h.lastRun == nil {
		h.lastRun = map[string]time.Time{}
	}
	if h.nextRun == nil {
		h.nextRun, h.fastUsed, h.everUp = map[string]time.Time{}, map[string]int{}, map[string]bool{}
	}
	if h.fastOn == nil {
		h.fastOn = map[string]bool{}
	}
	grace := h.inGrace(now)
	h.mu.Unlock()
	// what the runtime says of the containers, read once a round
	var parts map[string]partState
	why := h.noRuntime
	if h.runtime != nil {
		var err error
		parts, err = h.runtime.parts(ctx)
		if err != nil {
			why = "the state of the pods is not readable: " + err.Error()
		} else if !h.runtimeRead {
			h.runtimeRead = true
			log.Print("the state of the pods: read through the Kubernetes API (admin.podStatus)")
		}
		h.logOnce("the state of the pods", err)
	}
	components := make([]Component, 0, len(h.checks))
	current, cameUp := map[string]Component{}, map[string]bool{}
	add := func(comp Component) {
		components = append(components, comp)
		current[comp.Name] = comp
	}
	for _, c := range h.checks {
		prev, seen := previous[c.name]
		h.mu.Lock()
		last, next := h.lastRun[c.name], h.nextRun[c.name]
		h.mu.Unlock()
		// what it goes through is starting, or waiting in the grace: checked once it is up
		var waiting []string
		depDown := false
		for _, d := range c.after {
			if dep, ok := current[d]; ok && dep.pending() {
				waiting = append(waiting, d)
			} else if ok && !dep.Up {
				depDown = true
			}
		}
		if len(waiting) > 0 {
			verb := "it is"
			if len(waiting) > 1 {
				verb = "they are"
			}
			h.mu.Lock()
			delete(h.nextRun, c.name)
			h.mu.Unlock()
			add(Component{Name: c.name, Hidden: c.hidden, Waiting: true, Checked: last,
				Error: "waiting for " + strings.Join(waiting, " and ") + ": checked as soon as " + verb + " up"})
			continue
		}
		// a part it goes through came up (or any part, while it fails): at once, with fast retries
		again := false
		for _, d := range c.after {
			again = again || cameUp[d]
		}
		if c.fast && !again && seen && !prev.Up && len(cameUp) > 0 {
			again = true
		}
		if again && c.fast {
			h.mu.Lock()
			h.fastOn[c.name], h.fastUsed[c.name] = true, 0
			h.mu.Unlock()
		}
		// the end of the grace: what is still waiting is checked, and announced
		ended := seen && prev.Waiting && !grace
		if c.every > 0 && !last.IsZero() && !force && !again && !ended && now.Before(next) {
			if seen {
				prev.Next = next
				add(prev)
			}
			continue
		}
		start := time.Now()
		h.mu.Lock()
		h.lastRun[c.name] = start
		h.mu.Unlock()
		cctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		comp := Component{Name: c.name, Checked: start, Hidden: c.hidden}
		var err error
		if c.run != nil {
			comp.Detail, err = c.run(cctx)
		} else {
			err = c.health(cctx)
		}
		if errors.Is(err, errSkip) {
			cancel()
			if c.every > 0 {
				h.mu.Lock()
				h.nextRun[c.name] = start.Add(c.retry)
				h.mu.Unlock()
			}
			continue
		}
		var warn warning
		if err != nil {
			comp.Error, comp.Warn = err.Error(), errors.As(err, &warn)
		} else {
			comp.Up = true
		}
		if c.version != nil && comp.Up {
			comp.Version, _ = c.version(cctx)
			if comp.Version == "TBD" { // syncstorage-rs built without its version
				comp.Version = ""
			}
		}
		cancel()
		h.mu.Lock()
		if latest := h.latest[c.upstream]; latest != "" && comp.Version != "" && newerVersion(latest, comp.Version) {
			comp.Latest = latest
		}
		if comp.Up {
			h.everUp[c.name] = true
		}
		if !comp.Up {
			// (what it goes through down: so is it)
			h.notUp(&comp, parts, why, grace && !depDown, start)
		}
		if c.every > 0 {
			comp.Next = start.Add(h.waitAfter(c, comp.Up))
			h.nextRun[c.name] = comp.Next
		} else if h.round > 0 {
			comp.Next = start.Add(h.round)
		}
		h.mu.Unlock()
		// what was starting or waiting was never announced: its first state is
		known := seen && !prev.pending()
		switch {
		case comp.pending():
		case (known && prev.state() != comp.state()) || (!known && !comp.Up):
			switch comp.state() {
			case "up":
				h.app.event("health", c.name+" is back up")
			case "warn":
				h.app.event("health", c.name+": "+comp.Error)
			default:
				h.app.event("health", c.name+" is down: "+comp.Error)
			}
		}
		if comp.Up && (!seen || !prev.Up) {
			cameUp[c.name] = true
			if c.name == "Sync server" {
				h.mu.Lock()
				h.syncUpSince = comp.Checked
				h.mu.Unlock()
			}
		}
		add(comp)
	}
	h.mu.Lock()
	h.components, h.lastRound = components, time.Now()
	h.mu.Unlock()
}

// watchAccounts turns new accounts and devices into events (and alerts)
func (h *Health) watchAccounts(ctx context.Context) {
	if h.app.fxa == nil {
		return
	}
	now := time.Now()
	events, err := h.app.fxa.Recent(ctx, h.lastSignup.Add(-watchOverlap), time.Time{}, "", "", 1000)
	if err != nil {
		log.Printf("watching new accounts: %v", err)
		return
	}
	h.newAccountEvents(events, now)
}

// newAccountEvents alerts the events not alerted yet, since the start
func (h *Health) newAccountEvents(events []Event, now time.Time) {
	h.lastSignup = now
	for _, e := range events {
		key := e.Kind + "\x00" + e.Detail + "\x00" + strconv.FormatInt(e.At.UnixMilli(), 10)
		if e.At.Before(h.started) || !h.alerted[key].IsZero() {
			continue
		}
		h.alerted[key] = e.At
		h.app.alert(e.Kind, e.Detail)
	}
	// older than the next round looks
	for key, at := range h.alerted {
		if at.Before(now.Add(-watchOverlap)) {
			delete(h.alerted, key)
		}
	}
}

// watchBlocks alerts when the rate limits lock out an account of the accounts service
// (wrong passwords, codes): its owner may need a hand, or someone is guessing
func (h *Health) watchBlocks(ctx context.Context) {
	if h.app.fxa == nil {
		return
	}
	accounts, err := h.app.fxa.Accounts(ctx)
	if err != nil {
		log.Printf("watching the rate limits: %v", err)
		return
	}
	blocks, complete, err := h.app.fxa.BlocksOf(ctx, accounts)
	if err != nil {
		log.Printf("watching the rate limits: %v", err)
		return
	}
	h.blockEvents(blocks, accounts, time.Now(), complete)
}

// blockEvents records (and alerts) the new blocks of accounts that exist, once per
// account and action while blocked (on its email, its email and an IP address...).
// Anybody can get an unknown email or an IP address blocked: those are left to the
// Security page. Not complete: blocks missing from the list may still be on
func (h *Health) blockEvents(blocks []Block, accounts []FxaAccount, now time.Time, complete bool) {
	if h.blockAlerted == nil {
		h.blockAlerted = map[string]time.Time{}
	}
	byEmail, byUID := map[string]*FxaAccount{}, map[string]*FxaAccount{}
	for i := range accounts {
		byEmail[strings.ToLower(accounts[i].Email)], byUID[accounts[i].UID] = &accounts[i], &accounts[i]
	}
	active := map[string]bool{}
	for _, b := range blocks {
		// blocks from before the start were never seen ending: not new
		if !b.Until.After(now) || b.Start.Before(h.started) {
			continue
		}
		email, uid := b.Subject()
		if email == "" && uid == "" {
			continue
		}
		acc := byEmail[email]
		if acc == nil {
			acc = byUID[uid]
		}
		if acc == nil {
			continue
		}
		key := acc.UID + "\x00" + b.Action
		active[key] = true
		if until, seen := h.blockAlerted[key]; seen {
			if b.Until.After(until) {
				h.blockAlerted[key] = b.Until
			}
			continue
		}
		h.blockAlerted[key] = b.Until
		h.app.event("blocked", fmt.Sprintf("%s blocked until %s after too many attempts (%s, on %s)",
			accountLabel(acc, acc.UID), formatTime(b.Until, adminZone), b.Action, b.On))
	}
	// lifted or over: a new block alerts again
	for key, until := range h.blockAlerted {
		if (complete && !active[key]) || !until.After(now) {
			delete(h.blockAlerted, key)
		}
	}
}

func (h *Health) measureSizes(ctx context.Context) {
	sizes := map[string]int64{}
	if n, err := h.app.sync.Size(ctx); err == nil {
		if h.app.sync.postgres {
			sizes["Sync (tokenserver and storage)"] = n
		} else {
			sizes["Tokenserver"] = n
		}
	} else {
		log.Printf("database size: %v", err)
	}
	if h.app.storage != nil && !h.app.sync.postgres {
		if n, err := h.app.storage.Size(ctx); err == nil {
			sizes["Sync storage"] = n
		} else {
			log.Printf("storage database size: %v", err)
		}
	}
	if own := h.app.sync.own; own != nil {
		if n, err := dbSize(ctx, own, h.app.sync.postgres); err == nil {
			sizes["Admin UI"] = n
		} else {
			log.Printf("admin UI database size: %v", err)
		}
	}
	if h.app.fxa != nil {
		if n, err := h.app.fxa.Size(ctx); err == nil {
			sizes["Accounts"] = n
		} else {
			log.Printf("accounts database size: %v", err)
		}
	}
	h.mu.Lock()
	h.sizes = sizes
	h.mu.Unlock()
	for name, n := range sizes {
		h.app.rec.Gauge("db.size."+name, n)
	}
	h.watchGrowth(ctx, time.Now())
}

// releasesDue: time to ask GitHub again, every 12 hours. Never with ADMIN_UPDATE_CHECK=false:
// with ADMIN_PUBLIC_CHECK=false too, nothing connects to the internet (docs/admin/monitoring.md#public-checks)
func (h *Health) releasesDue(now time.Time) bool {
	return updateChecks() && now.Sub(h.latestAt) > 12*time.Hour
}

// checkReleases asks GitHub for the newest releases (ADMIN_UPDATE_CHECK=false: never)
func (h *Health) checkReleases(ctx context.Context) {
	h.latestAt = time.Now()
	for _, c := range h.checks {
		if c.upstream == "" {
			continue
		}
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, githubAPI+"/repos/"+c.upstream+"/releases/latest", nil)
		req.Header.Set("Accept", "application/vnd.github+json")
		res, err := h.client.Do(req)
		if err != nil {
			log.Printf("release check %s: %v", c.upstream, err)
			continue
		}
		var release struct {
			Tag string `json:"tag_name"`
		}
		err = json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(&release)
		res.Body.Close()
		if err != nil || release.Tag == "" {
			continue
		}
		h.mu.Lock()
		h.latest[c.upstream] = release.Tag
		announce := !h.notified[release.Tag]
		h.notified[release.Tag] = true
		h.mu.Unlock()
		if announce {
			for _, comp := range h.Components() {
				if comp.Name == c.name && comp.Version != "" && newerVersion(release.Tag, comp.Version) {
					h.app.event("update", fmt.Sprintf("%s %s is out (running %s)", c.upstream, release.Tag, comp.Version))
				}
			}
		}
	}
}

func (h *Health) Components() []Component {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]Component(nil), h.components...)
}

func (h *Health) Sizes() map[string]int64 {
	h.mu.Lock()
	defer h.mu.Unlock()
	sizes := map[string]int64{}
	for k, v := range h.sizes {
		sizes[k] = v
	}
	return sizes
}

// newerVersion: is a (v1.348.0, 0.23.4) newer than b? Numeric parts, an optional v
func newerVersion(a, b string) bool {
	pa, pb := versionParts(a), versionParts(b)
	if pa == nil || pb == nil {
		return false
	}
	for i := 0; i < len(pa) || i < len(pb); i++ {
		var x, y int
		if i < len(pa) {
			x = pa[i]
		}
		if i < len(pb) {
			y = pb[i]
		}
		if x != y {
			return x > y
		}
	}
	return false
}

func versionParts(v string) []int {
	v = strings.TrimPrefix(strings.TrimSpace(v), "v")
	if i := strings.IndexAny(v, "-+ "); i >= 0 {
		v = v[:i]
	}
	var parts []int
	for _, p := range strings.Split(v, ".") {
		n, err := strconv.Atoi(p)
		if err != nil {
			return nil
		}
		parts = append(parts, n)
	}
	return parts
}
