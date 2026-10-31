package main

import (
	"context"
	"fmt"
	"log"
	"net/url"
	"sort"
	"strings"
	"time"
)

// Needs attention: one list at the top of the overview, built from what the overview
// loads anyway, each line with a link to where it is fixed. Three thresholds also
// alert, once per change of their state: accounts at 90% of max users, Sync data that
// changed without metrics from the Sync server, alert emails that fail.

const (
	// Sync data written this long after the last statsd packet (or the start) while the
	// Sync server answers: it lost the admin UI. The margin covers the metrics a request
	// leaves in the Sync server's buffer until the next ones fill a datagram
	statsdMargin = 10 * time.Minute
	// the daily prune of the accounts database
	pruneLate = 48 * time.Hour
)

type attention struct {
	Text string
	Href string // where it is fixed
	Link string // the link's text
}

// attentionInput: what the overview loaded
type attentionInput struct {
	now        time.Time
	components []Component
	certs      map[string]time.Time
	status     *SyncStatus
	backups    []BackupStatus
	storage    *StorageReport
	// self-hosted accounts
	fxa             bool
	accounts        []accountRow
	unconfirmed     int
	pruneLastRan    time.Time
	inactiveDevices map[string]int // per account uid
	staleDays       int
	alerts          *SendStatus // nil without ADMIN_ALERT_EMAIL
	// FXA_MAX_ACCOUNTS, nil when not read
	accountLimit *Limit
	// ADMIN_DEPLOYMENT, for the commands
	deployment deployment
	// the setup migrations of the database servers (setupmigrations.go)
	setup []SetupStatus
}

// nearMaxUsers: 90% of max users or more are taken, full too (0: no new account at all,
// not a warning; unlimited: never)
func nearMaxUsers(st *SyncStatus) bool {
	return st != nil && st.Limit().State() != limitOK
}

// statsdSilent: the Sync server answers and the storage database changed more than
// statsdMargin after its last metrics (or after from, when none came since): it resolved
// the admin UI before a new container. syncstorage-rs only sends metrics while it serves
// requests (and buffers them until a datagram fills), so an idle server sends nothing for
// hours: only data written without metrics is silence. No storage database or no write
// yet (lastWrite zero): never
func statsdSilent(syncUp bool, lastWrite, last, from time.Time) bool {
	return syncUp && !lastWrite.IsZero() && lastWrite.After(latest(last, from).Add(statsdMargin))
}

// metricsCheck: the row of the health table while the metrics are missing (see statsdSilent)
const metricsCheck = "Sync metrics"

// metricsRow: the Sync metrics row of the health table, a warning, when they are missing.
// Fine: no row, like the setup checks (hidden when fine, shown and counted when failing)
func metricsRow(syncUp bool, lastWrite, last, from time.Time) (Component, bool) {
	if !statsdSilent(syncUp, lastWrite, last, from) {
		return Component{}, false
	}
	since := "the last ones at " + formatTime(last, adminZone)
	if !last.After(from) {
		since = formatTime(from, adminZone) + " (the start of the admin UI or the Sync server)"
	}
	return Component{Name: metricsCheck, Warn: true, Checked: time.Now(),
		Error: fmt.Sprintf("Sync data changed at %s but no metrics arrived since %s", formatTime(lastWrite, adminZone), since)}, true
}

// deployment: the App's, compose's without one (in the tests)
func (h *Health) deployment() deployment {
	if h.app == nil {
		return deployment{}
	}
	return h.app.deployment
}

// silenceFrom: since when no metrics count as silence, the start of the admin UI or the
// Sync server's last coming up (after an outage the old last packet is no measure)
func (h *Health) silenceFrom() time.Time {
	h.mu.Lock()
	defer h.mu.Unlock()
	return latest(h.started, h.syncUpSince)
}

// alertsFailing: the last alert email could not be sent
func alertsFailing(s *SendStatus) bool {
	return s != nil && s.Err != ""
}

func componentUp(components []Component, name string) bool {
	for _, c := range components {
		if c.Name == name {
			return c.Up
		}
	}
	return false
}

func needsAttention(in attentionInput) []attention {
	var list []attention
	add := func(href, link, format string, args ...any) {
		list = append(list, attention{Text: fmt.Sprintf(format, args...), Href: href, Link: link})
	}
	for _, c := range in.components {
		switch {
		case c.Name == "Email (SMTP)" && !c.Up:
			add("#health", "Health", "The SMTP server does not work (%s): no alerts, invitations or notices go out.", c.Error)
		case c.Name == notifyCheckName && !c.Up:
			add("#notify-status", "Alerts", "Notifications fail (%s): the alerts wait for the next try.", c.Error)
		case c.Name == metricsCheck && c.Warn:
			add("/activity", "Activity", "%s: %s.", c.Error, in.deployment.restartSync())
		case c.Name == errorRateCheck && c.Warn:
			add("/activity#errors", "Activity", "%s: see the errors by kind.", c.Error)
		case c.Name == growthCheck && c.Warn:
			add("/activity", "Activity", "%s.", c.Error)
		case c.Name == "Sign-up gate" && c.Warn:
			add("#health", "Health", "Sign-ups bypass the sign-up gate: refused sign-ups see \"Unexpected error\" instead of why.")
		case c.Hidden && !c.Up:
			add("#setup", "Setup", "%s: %s.", c.Name, c.Error)
		case !c.Up && !c.Warn:
			add("#health", "Health", "%s is down: %s.", c.Name, c.Error)
		}
		if c.Latest != "" {
			add("#health", "Health", "%s %s is out, %s runs here.", c.Name, c.Latest, c.Version)
		}
	}
	hosts := make([]string, 0, len(in.certs))
	for host := range in.certs {
		hosts = append(hosts, host)
	}
	sort.Strings(hosts)
	for _, host := range hosts {
		if left := in.certs[host].Sub(in.now); left < certWarnDays*24*time.Hour {
			add("#health", "Health", "The certificate of %s expires in %d days (%s): is its renewal running?", host, int(left/(24*time.Hour)), formatTime(in.certs[host], adminZone))
		}
	}
	if in.status != nil {
		if line := syncLimit.line(in.status.Limit()); line != "" {
			add(syncLimit.href, syncLimit.link, "%s.", line)
		}
	}
	if in.accountLimit != nil {
		if line := accountsLimit.line(*in.accountLimit); line != "" {
			add(accountsLimit.href, accountsLimit.link, "%s.", line)
		}
	}
	for _, b := range in.backups {
		if p := b.Problem(in.now); p != "" {
			add("#backups", "Backups", "%s.", upperFirst(p))
		}
	}
	if in.storage != nil && in.storage.Orphaned.Bytes > 0 {
		add("/storage/purge", "Purge…", "%s of Sync data nobody reads any more (%d orphans).", humanBytes(in.storage.Orphaned.Bytes), len(in.storage.Orphans))
	}
	if in.fxa {
		var blocked, unconfirmedSignIn []string
		for _, a := range in.accounts {
			if a.Blocked {
				blocked = append(blocked, a.UID)
			}
			if a.Security.UnverifiedSessions > 0 {
				unconfirmedSignIn = append(unconfirmedSignIn, a.UID)
			}
		}
		if len(blocked) > 0 {
			add("/security", "Security", "%s blocked by the rate limits.", plural(len(blocked), "account"))
		}
		if in.unconfirmed > 0 {
			add(filterLink("unconfirmed"), "Accounts", "%s never confirmed their email.", plural(in.unconfirmed, "account"))
		}
		if len(unconfirmedSignIn) > 0 {
			add(accountsLink(unconfirmedSignIn, "unconfirmed-sign-in", ""), "Accounts", "%s with a sign-in that never entered its email code: someone may have the password.",
				plural(len(unconfirmedSignIn), "account"))
		}
		if len(in.inactiveDevices) > 0 {
			devices, uids := 0, make([]string, 0, len(in.inactiveDevices))
			for uid, n := range in.inactiveDevices {
				devices += n
				uids = append(uids, uid)
			}
			sort.Strings(uids)
			add(accountsLink(uids, "inactive-devices", "#devices"), "Devices", "%s of %s not used for %d days (ADMIN_STALE_DAYS): sign them out if they are gone.",
				plural(devices, "device"), plural(len(uids), "account"), in.staleDays)
		}
		if last := in.pruneLastRan; last.IsZero() || in.now.Sub(last) > pruneLate {
			add("/activity#maintenance", "Maintenance", "The accounts database was not pruned for 2 days (last: %s).", whenIn(last, adminZone))
		}
	}
	for _, s := range in.setup {
		if p := s.Problem(); p != "" {
			add("#setup-migrations", "Technical details", "%s.", p)
		}
	}
	if alertsFailing(in.alerts) {
		add("#alert-status", "Alert emails", "The last alert email failed on %s: %s.", formatTime(in.alerts.At, adminZone), in.alerts.Err)
	}
	return list
}

// filterLink: the accounts list showing only those of a badge
func filterLink(show string) string {
	return "/?" + url.Values{"show": {show}}.Encode() + "#accounts"
}

// accountsLink: the account's page when there is one (at anchor), the filtered list otherwise
func accountsLink(uids []string, show, anchor string) string {
	if len(uids) == 1 {
		return "/users/" + url.PathEscape(uids[0]) + anchor
	}
	return filterLink(show)
}

// changed: whether a condition's state differs from the last round (the first round:
// whether it is not ok), for alerts once per change
func (h *Health) changed(key, state string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.states == nil {
		h.states = map[string]string{}
	}
	prev, seen := h.states[key]
	h.states[key] = state
	return (seen && prev != state) || (!seen && state != "ok")
}

// logOnce logs an error of a background check when it is new, not every round
func (h *Health) logOnce(key string, err error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.logged == nil {
		h.logged = map[string]string{}
	}
	msg := ""
	if err != nil {
		msg = err.Error()
	}
	if msg != "" && msg != h.logged[key] {
		log.Printf("%s: %s", key, msg)
	}
	h.logged[key] = msg
}

// thresholdEvents: the events of the thresholds whose state changed. The limits (nil:
// not read, no change) alert at 90% and when full, and when under 90% again
func (h *Health) thresholdEvents(st *SyncStatus, accounts *Limit, syncUp bool, lastWrite, lastStatsd time.Time, alerts *SendStatus) []string {
	var events []string
	limit := func(k limitKind, l Limit) {
		if h.changed(k.key, l.State()) {
			events = append(events, k.event(l))
		}
	}
	if st != nil {
		limit(syncLimit, st.Limit())
	}
	if accounts != nil {
		limit(accountsLimit, *accounts)
	}
	// the Sync server down: its health alerts, the silence keeps its state until it is up
	if row, silent := metricsRow(syncUp, lastWrite, lastStatsd, h.silenceFrom()); syncUp && h.changed("statsd-silent", okState(!silent)) {
		if silent {
			events = append(events, row.Error+": "+h.deployment().restartSync())
		} else {
			events = append(events, "Metrics from the Sync server arrive again")
		}
	}
	if alerts != nil {
		failing := alertsFailing(alerts)
		if h.changed("alerts-failing", okState(!failing)) {
			if failing {
				events = append(events, "Alert emails fail: "+alerts.Err)
			} else {
				events = append(events, "Alert emails go out again")
			}
		}
	}
	return events
}

func okState(ok bool) string {
	if ok {
		return "ok"
	}
	return "problem"
}

// watchThresholds: the thresholds of the overview, as events and alerts, and the rows
// of the limits
func (h *Health) watchThresholds(ctx context.Context) {
	st, err := h.app.sync.Status(ctx)
	if err != nil {
		st = nil
	}
	var syncLimit, accounts *Limit
	if st != nil {
		l := st.Limit()
		syncLimit = &l
	}
	if h.app.fxa != nil {
		if l, err := h.app.fxa.AccountLimit(ctx); err == nil {
			accounts = &l
		} else {
			h.logOnce("max accounts", err)
		}
	}
	h.setLimits(syncLimit, accounts)
	var alerts *SendStatus
	if h.app.alerter.emails() {
		s := h.app.alerter.Status()
		alerts = &s
	}
	var last time.Time
	if h.app.rec != nil {
		last = h.app.rec.LastReceived()
	}
	h.watchLastWrite(ctx)
	h.watchErrorRate(ctx, time.Now())
	for _, e := range h.thresholdEvents(st, accounts, componentUp(h.Components(), "Sync server"), h.LastWrite(), last, alerts) {
		h.app.event("attention", e)
	}
}

// watchLastWrite reads the latest write of the storage database, for the metrics (on an
// error the last one read stays)
func (h *Health) watchLastWrite(ctx context.Context) {
	if h.app.storage == nil {
		return
	}
	at, err := h.app.storage.LastWrite(ctx)
	h.logOnce("latest write of the storage database", err)
	if err != nil {
		return
	}
	h.mu.Lock()
	h.lastWrite = at
	h.mu.Unlock()
}

// LastWrite: the latest write of the storage database at the last round (zero: none, or
// no storage database)
func (h *Health) LastWrite() time.Time {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.lastWrite
}

// metrics: the Sync metrics row while they are missing, from the last round of checks
// and the last packet; the overview, the health light, the activity page and Prometheus
func (a *App) metrics() (Component, bool) {
	if a.health == nil || a.rec == nil {
		return Component{}, false
	}
	return metricsRow(componentUp(a.health.Components(), "Sync server"), a.health.LastWrite(), a.rec.LastReceived(), a.health.silenceFrom())
}

// healthRows: the components of the last round, with the Sync metrics row when they are
// missing and the rows of the limits of accounts
func (a *App) healthRows() []Component {
	components := a.health.Components()
	if row, silent := a.metrics(); silent {
		components = append(components, row)
	}
	components = append(components, a.health.Limits()...)
	return append(components, a.health.thresholdRows()...)
}

// thresholdRows: the rows of the error rate and of the growth of the databases, once
// checked (and on)
func (h *Health) thresholdRows() []Component {
	var rows []Component
	if row, ok := errorRateRow(h.ErrorRate(), h.errorRate); ok {
		rows = append(rows, row)
	}
	h.mu.Lock()
	measured := h.growthMeasured
	h.mu.Unlock()
	if row, ok := growthRow(h.Growth(), h.growth, measured); ok {
		rows = append(rows, row)
	}
	return rows
}

// setLimits: the rows of the limits, read in a round of checks or by the overview
func (h *Health) setLimits(sync, accounts *Limit) {
	rows := limitRows(sync, accounts)
	h.mu.Lock()
	defer h.mu.Unlock()
	h.limits = rows
}

func (h *Health) Limits() []Component {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]Component(nil), h.limits...)
}

// readLimits: the limits of accounts now, nil those that cannot be read (or with
// Mozilla's accounts, the accounts')
func (a *App) readLimits(ctx context.Context) (sync, accounts *Limit) {
	if st, err := a.sync.Status(ctx); err == nil {
		l := st.Limit()
		sync = &l
	}
	if a.fxa != nil {
		if l, err := a.fxa.AccountLimit(ctx); err == nil {
			accounts = &l
		} else {
			a.health.logOnce("max accounts", err)
		}
	}
	return sync, accounts
}

// refreshLimits: after a change of a limit, its row at once (the light of every page)
func (a *App) refreshLimits(ctx context.Context) {
	if a.health != nil {
		a.health.setLimits(a.readLimits(ctx))
	}
}

// matchAccount: whether a row of the list matches the search q (lower case): part of
// its email, its account id or its note; id: the account of q as a tokenserver uid or an
// address (any of its emails)
func matchAccount(q, uid, email, note, id string) bool {
	if q == "" {
		return true
	}
	return uid == id || strings.Contains(strings.ToLower(email), q) || strings.Contains(uid, q) || strings.Contains(strings.ToLower(note), q)
}

const accountsPerPage = 50

// paginate: rows from to of the page (1, the first; out of range: the nearest), of pages
func paginate(total, page, per int) (from, to, current, pages int) {
	pages = (total + per - 1) / per
	if pages < 1 {
		pages = 1
	}
	current = min(max(page, 1), pages)
	from = (current - 1) * per
	to = min(from+per, total)
	return from, to, current, pages
}

// pager: the links of the accounts list, keeping the search
type pager struct {
	Page, Pages, Total, From, To int
	Prev, Next                   string
}

func newPager(total, page int, q, show string) (pager, int, int) {
	from, to, current, pages := paginate(total, page, accountsPerPage)
	p := pager{Page: current, Pages: pages, Total: total, From: from + 1, To: to}
	if total == 0 {
		p.From = 0
	}
	link := func(n int) string {
		v := url.Values{}
		if q != "" {
			v.Set("q", q)
		}
		if show != "" {
			v.Set("show", show)
		}
		if n > 1 {
			v.Set("page", fmt.Sprint(n))
		}
		if len(v) == 0 {
			return "/#accounts"
		}
		return "/?" + v.Encode() + "#accounts"
	}
	if current > 1 {
		p.Prev = link(current - 1)
	}
	if current < pages {
		p.Next = link(current + 1)
	}
	return p, from, to
}
