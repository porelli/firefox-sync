package main

import (
	"context"
	"fmt"
	"math"
	"sort"
	"strings"
	"time"
)

// The errors of the Sync server by kind, from its statsd metrics, and the alert on a
// spike of them. What syncstorage-rs 0.23 sends (captured in the tests, see
// testdata/statsd-packets.jsonl):
//
//   - a counter per client error of the storage API that it does not report to Sentry,
//     named after the error: syncstorage.request.error.hawk.missing_header,
//     syncstorage.request.validate.bad_bso_body... No tags, no endpoint, no status
//   - nothing for its 5xx (a database down: the health checks see that), for 404 and
//     412 (answers, not errors), nor for the errors of the tokenserver: the Sentry
//     middleware of the combined server only counts the storage API's errors
//   - since 0.24 a timer per request, whatever it is (syncstorage.request.duration, tagged
//     route, method, status): the health checks too (/__heartbeat__ of Docker's
//     healthcheck every 30 s, of the admin UI every round, /__lbheartbeat__, /__version__).
//     Not a request of its own (the handler's counter is): the recorder counts those of the
//     health checks apart (healthChecksMetric), so the requests are Firefox's
//   - a timer per token request with an OAuth token (syncstorage.token_verification) and
//     one per token issued (syncstorage.token_creation): the difference is the tokens
//     refused (a bad or old token, an old generation or keys, a client state that does
//     not fit, max users full, a database error). The recorder pairs them in the order
//     they came (tokens.go) and keeps the refused ones (tokensRefusedMetric)

const (
	storageService = "Sync storage"
	tokenService   = "Tokenserver"
	// the kind of the tokens refused, counted as verification minus creation
	tokensRefused = "tokens refused"
)

// errorKind: what the client got, as far as the metric's name says
type errorKind struct {
	Service string
	Status  string
	Kind    string
}

// the error metrics of syncstorage-rs, by the start of their name after the statsd
// label (syncstorage. or syncstorage.tokenserver.); the first that fits. Kind "": the
// rest of the name. Service "": the label's
var errorRules = []struct {
	prefix          string
	service, status string
	kind            string
}{
	{"request.error.hawk.expired", storageService, "401", "Sync token expired (Firefox gets a new one)"},
	{"request.error.hawk.", storageService, "401", "Hawk authentication: "},
	{"request.validate.hawk.", storageService, "401", "Hawk authentication: "},
	{"request.error.invalid_content_type", storageService, "415", "Content-Type not accepted"},
	{"request.validate.invalid_accept_header", storageService, "406", "Accept header not accepted"},
	{"request.validate.payload_too_large", storageService, "400", "item too large (payload)"},
	{"request.validate.batch.size_exceeded", storageService, "400", "batch too large"},
	{"request.validate.", storageService, "400", "invalid request: "},
	{"request.process.", storageService, "400", "invalid request: "},
	{"request.store.", storageService, "400", "invalid request: "},
	// the tokenserver's own labels: sent only by a tokenserver running alone
	{"request.error.oauth", tokenService, "401", "OAuth token refused"},
	{"request.error.invalid_client_state", tokenService, "401", "client state does not fit"},
	{"request.error.resource_unavailable", tokenService, "503", "unavailable"},
	{"request.error.", "", "4xx", ""},
	{"jwt.error.", tokenService, "401", "OAuth token: "},
	{"storage.quota.at_limit", storageService, "403", "over quota"},
	{"storage.conflict", storageService, "503", "conflicting writes"},
	{"storage.pool.timeout", "", "503", "database pool timeout"},
	{"storage.sql.error.", "", "500", "database: "},
	{"error.rejectua", storageService, "503", "Firefox version refused"},
	{"sync.error.", storageService, "400", ""},
}

// statsdLabel: the label of a metric of syncstorage-rs and the rest of its name
func statsdLabel(name string) (service, rest string, ok bool) {
	if rest, ok := strings.CutPrefix(name, "syncstorage.tokenserver."); ok {
		return tokenService, rest, true
	}
	if rest, ok := strings.CutPrefix(name, "syncstorage."); ok {
		return storageService, rest, true
	}
	return "", "", false
}

// classifyError: the kind of an error metric, false for the other metrics
func classifyError(name string) (errorKind, bool) {
	service, rest, ok := statsdLabel(name)
	if !ok {
		return errorKind{}, false
	}
	for _, r := range errorRules {
		if !strings.HasPrefix(rest, r.prefix) {
			continue
		}
		k := errorKind{Service: r.service, Status: r.status, Kind: r.kind}
		if k.Service == "" {
			k.Service = service
		}
		if k.Kind == "" || strings.HasSuffix(k.Kind, ": ") {
			k.Kind += strings.NewReplacer("_", " ", ".", " ").Replace(strings.TrimPrefix(rest, r.prefix))
		}
		return k, true
	}
	return errorKind{}, false
}

// isRequest: a request the storage API served (syncstorage.request.get_collections...,
// counted when it reaches its handler), not one of its errors
func isRequest(name string) bool {
	op, ok := strings.CutPrefix(name, "syncstorage.request.")
	return ok && op != "" && !strings.Contains(op, ".") && "request."+op != requestDuration
}

const (
	tokenVerified = "syncstorage.token_verification"
	tokenIssued   = "syncstorage.token_creation"
	// the tokens refused per minute, counted by the recorder (no statsd metric, no
	// sender's line of this name is taken)
	tokensRefusedMetric = "ffs.tokens_refused"
	// the health checks the Sync server answered per minute, counted by the recorder from
	// syncstorage.request.duration (route /__heartbeat__...): not Firefox's requests
	healthChecksMetric = "ffs.health_checks"
	// the timer of every request (syncstorage-rs 0.24), not a request of its own
	requestDuration = "request.duration"
)

// the routes of the health checks of syncstorage-rs (its DOCKER_FLOW_ENDPOINTS)
var healthRoutes = map[string]bool{"/__heartbeat__": true, "/__lbheartbeat__": true, "/__version__": true, "/__error__": true}

// ErrorRow: a kind of error over a time span, for the activity page
type ErrorRow struct {
	errorKind
	Metric string // its statsd name, "" for the tokens refused
	Count  int64
	Last   time.Time
}

// errorTally adds up the metrics of a time span, per minute: the errors by kind and
// the traffic, for the activity page, the alerts and Prometheus
type errorTally struct {
	rows map[string]*ErrorRow
	// per minute (ms): the token requests verified and the tokens issued
	verified, issued map[int64]int64
	// per minute: the tokens refused the recorder counted (tokensRefusedMetric)
	counted map[int64]int64
	// per minute: the requests and the errors, without the tokens refused
	minutes map[int64]traffic
	// the newest minute of a metric, of any
	newest int64
}

func newErrorTally() *errorTally {
	return &errorTally{rows: map[string]*ErrorRow{}, verified: map[int64]int64{}, issued: map[int64]int64{}, counted: map[int64]int64{}, minutes: map[int64]traffic{}}
}

// add counts a metric of a minute (milliseconds), whatever it is
func (t *errorTally) add(minute int64, name string, count int64) {
	if minute > t.newest {
		t.newest = minute
	}
	tr := t.minutes[minute]
	switch {
	case name == tokenVerified:
		t.verified[minute] += count
		tr.Requests += count
	case name == tokenIssued:
		t.issued[minute] += count
	case name == tokensRefusedMetric:
		// their verifications are in the requests
		t.counted[minute] += count
	case name == healthChecksMetric:
		tr.Health += count
	case isRequest(name):
		tr.Requests += count
	default:
		k, ok := classifyError(name)
		if !ok {
			return
		}
		r := t.rows[name]
		if r == nil {
			r = &ErrorRow{errorKind: k, Metric: name}
			t.rows[name] = r
		}
		r.Count += count
		if at := time.UnixMilli(minute); at.After(r.Last) {
			r.Last = at
		}
		// they failed before a handler: not in the requests yet
		tr.Requests += count
		tr.Errors += count
	}
	t.minutes[minute] = tr
}

// refused: the tokens refused, per minute: those the recorder counted
// (tokensRefusedMetric), from its first minute on. Before it (the metrics of an admin UI
// from before it) verified minus issued of each minute: syncstorage-rs sends its metrics
// when 512 bytes are buffered, so a verification often comes in a datagram (a minute)
// before the token it issued: the tokens issued of a minute first pay off the
// verifications left over of the minutes before, the latest first (the split ones are
// next to each other). Those of the newest minute are not counted yet: their tokens may
// still be in the buffer of the Sync server. A guess, which the minutes alone cannot
// settle: a minute that brings the token of the one before and ends on a verification
// of its own pays off nothing, the one before looks refused until the next datagram
func (t *errorTally) refused() (total int64, last time.Time, perMinute map[int64]int64) {
	from := int64(math.MaxInt64)
	for m := range t.counted {
		from = min(from, m)
	}
	perMinute = map[int64]int64{}
	count := func(minute, n int64) {
		perMinute[minute] += n
		total += n
		if at := time.UnixMilli(minute); at.After(last) {
			last = at
		}
	}
	for m, n := range t.counted {
		if n > 0 {
			count(m, n)
		}
	}
	minutes := make([]int64, 0, len(t.verified)+len(t.issued))
	for m := range t.verified {
		if m < from {
			minutes = append(minutes, m)
		}
	}
	for m := range t.issued {
		if _, ok := t.verified[m]; !ok && m < from {
			minutes = append(minutes, m)
		}
	}
	sort.Slice(minutes, func(i, j int) bool { return minutes[i] < minutes[j] })
	type left struct{ minute, n int64 }
	var open []left
	for _, m := range minutes {
		n := t.verified[m] - t.issued[m]
		for n < 0 && len(open) > 0 {
			top := &open[len(open)-1]
			paid := min(-n, top.n)
			top.n -= paid
			n += paid
			if top.n == 0 {
				open = open[:len(open)-1]
			}
		}
		// more issued than verified and none left over: verified before the span
		if n > 0 {
			open = append(open, left{m, n})
		}
	}
	for _, l := range open {
		if l.minute != t.newest {
			count(l.minute, l.n)
		}
	}
	return total, last, perMinute
}

// Rows: the kinds of errors, most first
func (t *errorTally) Rows() []ErrorRow {
	list := make([]ErrorRow, 0, len(t.rows)+1)
	for _, r := range t.rows {
		list = append(list, *r)
	}
	if n, last, _ := t.refused(); n > 0 {
		list = append(list, ErrorRow{errorKind: errorKind{Service: tokenService, Status: "401, 500", Kind: tokensRefused}, Count: n, Last: last})
	}
	sort.Slice(list, func(i, j int) bool {
		if list[i].Count != list[j].Count {
			return list[i].Count > list[j].Count
		}
		return list[i].Kind < list[j].Kind
	})
	return list
}

// Traffic: the requests and errors of the span, the tokens refused included
func (t *errorTally) Traffic() traffic {
	return t.TrafficBetween(math.MinInt64, math.MaxInt64)
}

// TrafficBetween: the requests and errors of the minutes from (included) to (not),
// with the tokens refused of the whole span: a token issued after from pays off a
// verification before it
func (t *errorTally) TrafficBetween(from, to int64) traffic {
	var sum traffic
	for m, tr := range t.minutes {
		if m >= from && m < to {
			sum.Requests += tr.Requests
			sum.Errors += tr.Errors
			sum.Health += tr.Health
		}
	}
	_, _, refused := t.refused()
	for m, n := range refused {
		if m >= from && m < to {
			sum.Errors += n
		}
	}
	return sum
}

// traffic: requests of Firefox (served, failed or refused) and errors among them, and the
// health checks the Sync server answered besides (not in the requests)
type traffic struct{ Requests, Errors, Health int64 }

// healthNote: the health checks besides the requests, "" without
func (t traffic) healthNote() string {
	if t.Health <= 0 {
		return ""
	}
	return fmt.Sprintf(" (and %s, not counted)", plural(int(t.Health), "health check"))
}

// Percent: the share of errors, 0 without requests
func (t traffic) Percent() float64 {
	if t.Requests <= 0 {
		return 0
	}
	return 100 * float64(t.Errors) / float64(t.Requests)
}

// The error-rate alert: errors in the last errorWindow, against the errorBaseline
// before it. A spike is ADMIN_ERROR_RATE_PERCENT or more of the requests with at least
// ADMIN_ERROR_RATE_MIN_ERRORS errors (a small server does not alert on one), and
// errorFactor times the share of the baseline: a server that always refuses an old
// Firefox is not alerting all day. It ends under half the share, or half the errors
const (
	errorWindow   = 15 * time.Minute
	errorBaseline = 24 * time.Hour
	errorFactor   = 3
)

type errorRateConfig struct {
	percent   int   // 0: off
	minErrors int64 // in the window
}

func errorRateSettings() errorRateConfig {
	return errorRateConfig{percent: envInt("ADMIN_ERROR_RATE_PERCENT", 10), minErrors: int64(envInt("ADMIN_ERROR_RATE_MIN_ERRORS", 20))}
}

func (c errorRateConfig) on() bool { return c.percent > 0 }

// spike: whether the window is a spike; was: whether the last round was one
func (c errorRateConfig) spike(window, baseline traffic, was bool) bool {
	if !c.on() {
		return false
	}
	if was {
		return window.Errors*2 >= c.minErrors && window.Percent()*2 >= float64(c.percent)
	}
	return window.Errors >= c.minErrors && window.Percent() >= float64(c.percent) &&
		window.Percent() >= errorFactor*baseline.Percent()
}

// ErrorRate: the last round of the error-rate check
type ErrorRate struct {
	Checked          time.Time
	Window, Baseline traffic
	Spike            bool
}

// line: what a spike means, for Needs attention, the health row and the alert
func (e ErrorRate) line() string {
	usual := "none the day before"
	if e.Baseline.Requests > 0 {
		usual = fmt.Sprintf("%.1f%% the day before", e.Baseline.Percent())
	}
	return fmt.Sprintf("%d of %d Sync requests from Firefox failed in the last %d minutes (%.0f%%, %s)",
		e.Window.Errors, e.Window.Requests, int(errorWindow/time.Minute), e.Window.Percent(), usual)
}

// errorRateCheck: the row of the health table
const errorRateCheck = "Sync error rate"

// errorRateRow: the row of the health table, counted only during a spike
func errorRateRow(e *ErrorRate, c errorRateConfig) (Component, bool) {
	if e == nil || !c.on() {
		return Component{}, false
	}
	row := Component{Name: errorRateCheck, Limit: true, Checked: e.Checked}
	if e.Spike {
		row.Warn, row.Label, row.Error = true, "spike", e.line()
		return row, true
	}
	row.Up = true
	row.Detail = fmt.Sprintf("%s of %s from Firefox in the last %d minutes%s, alert from %d%% and %d errors (ADMIN_ERROR_RATE_PERCENT)",
		plural(int(e.Window.Errors), "error"), plural(int(e.Window.Requests), "Sync request"), int(errorWindow/time.Minute), e.Window.healthNote(), c.percent, c.minErrors)
	return row, true
}

// errorTraffic: the traffic of the window and of the baseline before it, from the totals
// per minute of both, in one tally: the tokens refused need the minutes, and a
// verification of the baseline can be paid off by a token issued in the window
func (r *Recorder) errorTraffic(ctx context.Context, now time.Time) (window, baseline traffic, err error) {
	split := now.Add(-errorWindow)
	rows, err := r.db.mine().QueryContext(ctx, r.db.q(`SELECT minute, name, count FROM ffs_metrics WHERE minute >= ?
		AND (name LIKE 'syncstorage.request.%' OR name IN ('`+tokenVerified+`', '`+tokenIssued+`', '`+tokensRefusedMetric+`', '`+healthChecksMetric+`') OR name LIKE 'syncstorage.%error%'
		OR name LIKE 'syncstorage.%storage.quota.at_limit' OR name LIKE 'syncstorage.%storage.conflict' OR name LIKE 'syncstorage.%storage.pool.timeout')`),
		split.Add(-errorBaseline).UnixMilli())
	if err != nil {
		return traffic{}, traffic{}, err
	}
	defer rows.Close()
	t := newErrorTally()
	for rows.Next() {
		var minute, count int64
		var name string
		if err := rows.Scan(&minute, &name, &count); err != nil {
			return traffic{}, traffic{}, err
		}
		t.add(minute, name, count)
	}
	if err := rows.Err(); err != nil {
		return traffic{}, traffic{}, err
	}
	return t.TrafficBetween(split.UnixMilli(), math.MaxInt64), t.TrafficBetween(math.MinInt64, split.UnixMilli()), nil
}

// watchErrorRate: the error rate of this round, its event (and alert) when a spike
// starts and ends
func (h *Health) watchErrorRate(ctx context.Context, now time.Time) {
	c := h.errorRate
	if !c.on() || h.app.rec == nil {
		return
	}
	window, baseline, err := h.app.rec.errorTraffic(ctx, now)
	// "metrics: ...", like the other errors of the metrics (tests/e2e.sh looks for them)
	h.logOnce("metrics", err)
	if err != nil {
		return
	}
	h.mu.Lock()
	was := h.lastErrorRate != nil && h.lastErrorRate.Spike
	e := ErrorRate{Checked: now, Window: window, Baseline: baseline, Spike: c.spike(window, baseline, was)}
	h.lastErrorRate = &e
	h.mu.Unlock()
	if h.changed("error-rate", okState(!e.Spike)) {
		if e.Spike {
			h.app.event("attention", e.line())
		} else {
			h.app.event("attention", fmt.Sprintf("The Sync error rate is back to normal: %s", e.line()))
		}
	}
}

// ErrorRate: the last round of the error-rate check, nil: none (or off)
func (h *Health) ErrorRate() *ErrorRate {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.lastErrorRate == nil {
		return nil
	}
	e := *h.lastErrorRate
	return &e
}

// errorTotals: the errors since the start of the admin UI by kind, for Prometheus: the
// statsd counters. Not the tokens refused: verified minus issued goes down when the
// token of a verification comes in the next datagram, which a counter must not (a
// reset for rate()); Prometheus subtracts the two ffs_statsd_total itself
func errorTotals(cumulative map[string]metric) []ErrorRow {
	t := newErrorTally()
	for name, m := range cumulative {
		t.add(0, name, m.count)
	}
	list := make([]ErrorRow, 0, len(t.rows))
	for _, r := range t.Rows() {
		if r.Metric != "" {
			list = append(list, r)
		}
	}
	return list
}

// errorLabel: the kind of a row for Prometheus, its statsd name without the label
func errorLabel(r ErrorRow) string {
	_, rest, _ := statsdLabel(r.Metric)
	return rest
}
