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
}

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
}

// errSkip: a check with nothing to check (no https URL...), left out
var errSkip = errors.New("nothing to check")

// warning: a check that works with a problem, e.g. a certificate that expires soon
type warning struct{ msg string }

func (w warning) Error() string { return w.msg }

func (c Component) state() string {
	switch {
	case c.Up:
		return "up"
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
	// certificates of the public URLs: host -> NotAfter
	certs map[string]time.Time
	// the trust of the public checks, nil: the system's (the tests set their own)
	rootCAs *x509.CertPool
	// schema levels of the databases, see schema.go, and the error logged last
	schema    []SchemaLevel
	schemaErr string
	// the setup migrations of the database servers (setupmigrations.go)
	setup []SetupStatus
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
	sync := strings.TrimSuffix(env("SYNCSTORAGE_URL", "http://syncstorage:8000"), "/")
	h.checks = append(h.checks,
		check{name: "Sync server", health: httpCheck(client, sync+"/__heartbeat__"), version: versionOf(client, sync+"/__version__"), upstream: "mozilla-services/syncstorage-rs"},
		check{name: "Tokenserver database", health: app.sync.Ping, version: app.sync.Version},
	)
	if app.storage != nil && !app.sync.postgres {
		h.checks = append(h.checks, check{name: "Storage database", health: func(ctx context.Context) error { return app.storage.db.PingContext(ctx) }, version: app.storage.Version})
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
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}

func (h *Health) checkAll(ctx context.Context) {
	h.mu.Lock()
	previous := map[string]Component{}
	for _, c := range h.components {
		previous[c.Name] = c
	}
	if h.lastRun == nil {
		h.lastRun = map[string]time.Time{}
	}
	h.mu.Unlock()
	components := make([]Component, 0, len(h.checks))
	for _, c := range h.checks {
		prev, seen := previous[c.name]
		h.mu.Lock()
		last := h.lastRun[c.name]
		h.mu.Unlock()
		if c.every > 0 && !last.IsZero() {
			wait := c.every
			if !seen || !prev.Up {
				wait = c.retry
			}
			if time.Since(last) < wait {
				if seen {
					components = append(components, prev)
				}
				continue
			}
		}
		h.mu.Lock()
		h.lastRun[c.name] = time.Now()
		h.mu.Unlock()
		cctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		comp := Component{Name: c.name, Checked: time.Now(), Hidden: c.hidden}
		var err error
		if c.run != nil {
			comp.Detail, err = c.run(cctx)
		} else {
			err = c.health(cctx)
		}
		if errors.Is(err, errSkip) {
			cancel()
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
		h.mu.Unlock()
		if (seen && prev.state() != comp.state()) || (!seen && !comp.Up) {
			switch comp.state() {
			case "up":
				h.app.event("health", c.name+" is back up")
			case "warn":
				h.app.event("health", c.name+": "+comp.Error)
			default:
				h.app.event("health", c.name+" is down: "+comp.Error)
			}
		}
		if c.name == "Sync server" && comp.Up && (!seen || !prev.Up) {
			h.mu.Lock()
			h.syncUpSince = comp.Checked
			h.mu.Unlock()
		}
		components = append(components, comp)
	}
	h.mu.Lock()
	h.components = components
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
