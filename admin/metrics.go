package main

import (
	"context"
	"log"
	"net"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Metrics and the event log, kept in the admin UI's own database (ffs_metrics,
// ffs_events, see owndb.go) for ADMIN_RETENTION_DAYS, what admins did (kind admin) for
// ADMIN_AUDIT_RETENTION_DAYS. syncstorage-rs (and its tokenserver) send
// statsd metrics over UDP when the admin UI runs, see compose/sync.yml.

const (
	// distinct metric names kept per minute: the UDP port is only reachable from
	// the stack's network, this bounds what a misbehaving sender can store
	maxMetricNames     = 500
	maxEventsPerMinute = 30
)

var metricName = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,190}$`)

type metric struct {
	count int64
	total float64 // sum of the values of timers, in ms
}

type Recorder struct {
	db       *SyncDB
	keepDays int
	// for the events of kind admin: who did what
	auditDays int

	// events per kind and minute, at most maxEventsPerMinute (refused sign-ups come
	// from anybody)
	eventsMinute int64
	eventsCount  map[string]int

	mu       sync.Mutex
	current  map[string]*metric
	received time.Time // last statsd packet
	// the verifications without a token yet, per sender (tokens.go), and the tokens
	// refused of minutes already written
	tokens    map[string]*tokenStream
	refusedAt map[int64]int64
	// the time (the tests set it)
	clock func() time.Time
	// since the start, for Prometheus (counters only grow)
	cumulative map[string]*metric
}

func (r *Recorder) Cumulative() map[string]metric {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make(map[string]metric, len(r.cumulative))
	for k, v := range r.cumulative {
		out[k] = *v
	}
	return out
}

func (r *Recorder) LastReceived() time.Time {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.received
}

func (s *SyncDB) schema() []string {
	if s.postgres {
		return []string{
			`CREATE TABLE IF NOT EXISTS ffs_metrics (minute BIGINT NOT NULL, name VARCHAR(191) NOT NULL,
				count BIGINT NOT NULL, total DOUBLE PRECISION NOT NULL, PRIMARY KEY (minute, name))`,
			`CREATE TABLE IF NOT EXISTS ffs_events (id BIGSERIAL PRIMARY KEY, at BIGINT NOT NULL,
				kind VARCHAR(32) NOT NULL, detail VARCHAR(512) NOT NULL)`,
			`CREATE INDEX IF NOT EXISTS ffs_events_at ON ffs_events (at)`,
			`CREATE TABLE IF NOT EXISTS ffs_gauges (minute BIGINT NOT NULL, name VARCHAR(191) NOT NULL,
				value BIGINT NOT NULL, PRIMARY KEY (minute, name))`,
			`CREATE TABLE IF NOT EXISTS ffs_account_notes (uid VARCHAR(64) PRIMARY KEY, note VARCHAR(500) NOT NULL,
				updated_at BIGINT NOT NULL, updated_by VARCHAR(255) NOT NULL)`,
			`CREATE TABLE IF NOT EXISTS ffs_schema_levels (name VARCHAR(64) PRIMARY KEY, level VARCHAR(255) NOT NULL,
				updated_at BIGINT NOT NULL)`,
			`CREATE TABLE IF NOT EXISTS ffs_jobs (name VARCHAR(64) PRIMARY KEY, last_run BIGINT NOT NULL, result VARCHAR(512) NOT NULL,
			failed SMALLINT NOT NULL DEFAULT 0)`,
			s.backupsSchema(),
		}
	}
	return []string{
		`CREATE TABLE IF NOT EXISTS ffs_metrics (minute BIGINT NOT NULL, name VARCHAR(191) NOT NULL,
			count BIGINT NOT NULL, total DOUBLE PRECISION NOT NULL, PRIMARY KEY (minute, name))`,
		`CREATE TABLE IF NOT EXISTS ffs_events (id BIGINT AUTO_INCREMENT PRIMARY KEY, at BIGINT NOT NULL,
			kind VARCHAR(32) NOT NULL, detail VARCHAR(512) NOT NULL, KEY ffs_events_at (at))`,
		`CREATE TABLE IF NOT EXISTS ffs_gauges (minute BIGINT NOT NULL, name VARCHAR(191) NOT NULL,
			value BIGINT NOT NULL, PRIMARY KEY (minute, name))`,
		// utf8mb4: notes in any language, whatever the database's default
		`CREATE TABLE IF NOT EXISTS ffs_account_notes (uid VARCHAR(64) PRIMARY KEY, note VARCHAR(500) NOT NULL,
			updated_at BIGINT NOT NULL, updated_by VARCHAR(255) NOT NULL) DEFAULT CHARSET=utf8mb4`,
		// the schema levels seen last, see schema.go
		`CREATE TABLE IF NOT EXISTS ffs_schema_levels (name VARCHAR(64) PRIMARY KEY, level VARCHAR(255) NOT NULL,
			updated_at BIGINT NOT NULL)`,
		// the daily jobs: when they last ran, what they did (maintenance.go)
		`CREATE TABLE IF NOT EXISTS ffs_jobs (name VARCHAR(64) PRIMARY KEY, last_run BIGINT NOT NULL, result VARCHAR(512) NOT NULL,
			failed SMALLINT NOT NULL DEFAULT 0)
			DEFAULT CHARSET=utf8mb4`,
		// the runs of the backups (backup.go)
		s.backupsSchema(),
	}
}

func newRecorder(ctx context.Context, db *SyncDB) (*Recorder, error) {
	for _, stmt := range db.schema() {
		if _, err := db.mine().ExecContext(ctx, stmt); err != nil {
			return nil, err
		}
	}
	return &Recorder{db: db, keepDays: envInt("ADMIN_RETENTION_DAYS", 30), auditDays: envInt("ADMIN_AUDIT_RETENTION_DAYS", 365), current: map[string]*metric{}, cumulative: map[string]*metric{}}, nil
}

// Event records something worth showing in the activity log; the error: not recorded (also
// logged as "event log: ...")
func (r *Recorder) Event(kind, detail string) error {
	_, err := r.EventWritten(kind, detail)
	return err
}

// EventWritten: Event, and whether it is in the log: false without an error when the kind is
// over maxEventsPerMinute (dropped)
func (r *Recorder) EventWritten(kind, detail string) (bool, error) {
	// rune-safe: a cut inside a character is invalid UTF-8 and the INSERT fails
	detail = oneLine(detail, 509)
	r.mu.Lock()
	if minute := time.Now().Unix() / 60; minute != r.eventsMinute {
		r.eventsMinute, r.eventsCount = minute, map[string]int{}
	}
	r.eventsCount[kind]++
	// admin events need a session and are the audit trail: never dropped
	over := kind != "admin" && r.eventsCount[kind] > maxEventsPerMinute
	r.mu.Unlock()
	if over {
		return false, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, err := r.db.mine().ExecContext(ctx, r.db.q("INSERT INTO ffs_events (at, kind, detail) VALUES (?, ?, ?)"),
		time.Now().UnixMilli(), kind, detail)
	if err != nil {
		log.Printf("event log: %v", err)
	}
	return err == nil, err
}

func (r *Recorder) now() time.Time {
	if r.clock != nil {
		return r.clock()
	}
	return time.Now()
}

// parseStatsd adds the lines of a statsd packet: name:value|type[|@rate][|#tags]
func (r *Recorder) parseStatsd(packet string) { r.receive("", packet) }

// receive: a packet of a sender (its address)
func (r *Recorder) receive(sender, packet string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	now := r.now()
	r.received = now
	tokens := r.tokenStream(sender, now)
	own := false
	for _, line := range strings.Split(packet, "\n") {
		name, rest, ok := strings.Cut(strings.TrimSpace(line), ":")
		// tokensRefusedMetric is the admin UI's own, never a sender's
		if !ok || !metricName.MatchString(name) || name == tokensRefusedMetric {
			continue
		}
		if service, _, ok := statsdLabel(name); ok && service == storageService {
			own = true
		}
		fields := strings.Split(rest, "|")
		if len(fields) < 2 {
			continue
		}
		value, err := strconv.ParseFloat(fields[0], 64)
		if err != nil {
			continue
		}
		r.tokenLine(tokens, name, now)
		rate := 1.0
		for _, f := range fields[2:] {
			if strings.HasPrefix(f, "@") {
				if v, err := strconv.ParseFloat(f[1:], 64); err == nil && v > 0 && v <= 1 {
					rate = v
				}
			}
		}
		m := r.current[name]
		if m == nil {
			if len(r.current) >= maxMetricNames {
				continue
			}
			m = &metric{}
			r.current[name] = m
		}
		c := r.cumulative[name]
		if c == nil && len(r.cumulative) < maxMetricNames && r.cumulative != nil {
			c = &metric{}
			r.cumulative[name] = c
		}
		if c == nil {
			c = &metric{}
		}
		switch fields[1] {
		case "c":
			m.count += int64(value / rate)
			c.count += int64(value / rate)
		case "ms", "h", "d":
			m.count++
			m.total += value
			c.count++
			c.total += value
		}
	}
	// a row every minute the Sync server's own buffer (not the tokenserver's,
	// syncstorage.tokenserver.) sent something, 0 too: the minutes of the tokens refused
	// counted here (errorTally.refused)
	if own {
		r.currentMetric(tokensRefusedMetric)
	}
	r.tokenDatagram(tokens, now)
}

func (r *Recorder) listen(ctx context.Context, addr string) error {
	conn, err := net.ListenPacket("udp", addr)
	if err != nil {
		return err
	}
	go func() {
		<-ctx.Done()
		conn.Close()
	}()
	log.Printf("metrics (statsd) on udp %s", addr)
	buf := make([]byte, 65535)
	for {
		n, from, err := conn.ReadFrom(buf)
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		r.receive(from.String(), string(buf[:n]))
	}
}

// run writes the counters of every minute, and drops what is older than the retention
func (r *Recorder) run(ctx context.Context) {
	// how often the counters are written (the tests shorten it)
	tick := time.NewTicker(time.Duration(envInt("METRICS_FLUSH_SECONDS", 60)) * time.Second)
	defer tick.Stop()
	lastPrune := time.Time{}
	for {
		select {
		case <-ctx.Done():
			r.flush()
			return
		case <-tick.C:
			r.flush()
			if time.Since(lastPrune) > time.Hour {
				r.prune()
				lastPrune = time.Now()
			}
		}
	}
}

// drain: what to write, the counters of this minute and the tokens refused of minutes
// written before
func (r *Recorder) drain() (minute int64, current map[string]*metric, refusedAt map[int64]int64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	now := r.now()
	minute = now.Unix() / 60 * 60 * 1000
	current, refusedAt = r.current, r.refusedAt
	r.current, r.refusedAt = map[string]*metric{}, nil
	r.tokensWritten(minute, now)
	return minute, current, refusedAt
}

func (r *Recorder) flush() {
	minute, current, refusedAt := r.drain()
	type row struct {
		minute int64
		name   string
		m      metric
	}
	rows := make([]row, 0, len(current)+len(refusedAt))
	for name, m := range current {
		rows = append(rows, row{minute, name, *m})
	}
	// the tokens refused of the minutes their verifications were written in
	for at, n := range refusedAt {
		rows = append(rows, row{at, tokensRefusedMetric, metric{count: n}})
	}
	if len(rows) == 0 {
		return
	}
	upsert := `INSERT INTO ffs_metrics (minute, name, count, total) VALUES (?, ?, ?, ?)
		ON DUPLICATE KEY UPDATE count = count + VALUES(count), total = total + VALUES(total)`
	if r.db.postgres {
		upsert = `INSERT INTO ffs_metrics (minute, name, count, total) VALUES ($1, $2, $3, $4)
		ON CONFLICT (minute, name) DO UPDATE SET count = ffs_metrics.count + EXCLUDED.count, total = ffs_metrics.total + EXCLUDED.total`
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	for _, w := range rows {
		if _, err := r.db.mine().ExecContext(ctx, upsert, w.minute, w.name, w.m.count, w.m.total); err != nil {
			log.Printf("metrics: %v", err)
			return
		}
	}
}

type pruneStatement struct {
	query  string
	cutoff int64
}

// pruneStatements: what is older than the retention, the audit trail kept longer
func (r *Recorder) pruneStatements(now time.Time) []pruneStatement {
	keep := now.AddDate(0, 0, -r.keepDays).UnixMilli()
	audit := now.AddDate(0, 0, -r.auditDays).UnixMilli()
	return []pruneStatement{
		{"DELETE FROM ffs_metrics WHERE minute < ?", keep},
		{"DELETE FROM ffs_events WHERE kind <> 'admin' AND at < ?", keep},
		{"DELETE FROM ffs_events WHERE kind = 'admin' AND at < ?", audit},
		{"DELETE FROM ffs_gauges WHERE minute < ?", keep},
		// the backups: a row a night, kept like the audit trail
		{"DELETE FROM ffs_backups WHERE started < ?", audit},
	}
}

func (r *Recorder) prune() {
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	for _, p := range r.pruneStatements(time.Now()) {
		if _, err := r.db.mine().ExecContext(ctx, r.db.q(p.query), p.cutoff); err != nil {
			log.Printf("pruning: %v", err)
		}
	}
}

type Event struct {
	At     time.Time
	Kind   string
	Detail string
}

// Events of the log before a time, newest first: of a kind ("": all), with q in the
// detail (any case, "": all)
func (r *Recorder) Events(ctx context.Context, before time.Time, kind, q string, hideSignIns bool, limit int) ([]Event, error) {
	query, args := "SELECT at, kind, detail FROM ffs_events WHERE at < ?", []any{before.UnixMilli()}
	if kind != "" {
		query, args = query+" AND kind = ?", append(args, kind)
	}
	// the admins' own sign-ins, routine: in the query, so a page is still full
	if hideSignIns {
		query, args = query+" AND NOT (kind = ? AND detail LIKE ?)", append(args, "admin", adminSignIn+"%")
	}
	if q != "" {
		query, args = query+" AND LOWER(detail) LIKE ?", append(args, "%"+likeEscape(strings.ToLower(q))+"%")
	}
	rows, err := r.db.mine().QueryContext(ctx, r.db.q(query+" ORDER BY at DESC, id DESC LIMIT ?"), append(args, limit)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var events []Event
	for rows.Next() {
		var e Event
		var at int64
		if err := rows.Scan(&at, &e.Kind, &e.Detail); err != nil {
			return nil, err
		}
		e.At = time.UnixMilli(at)
		events = append(events, e)
	}
	return events, rows.Err()
}

// A series of the activity page: metrics whose name matches, per bucket
type Series struct {
	Title  string
	Total  int64
	Points []int64
}

type MetricTotal struct {
	Name  string
	Count int64
	AvgMs float64
}

// series of the activity charts: which metrics each sums. The errors are those of
// errors.go, with the tokens refused of each minute
var chartSeries = []struct {
	title string
	match func(name string) bool
}{
	{"Sync requests", isRequest},
	{"Sync tokens issued", func(name string) bool { return name == tokenIssued }},
	{"Errors", func(name string) bool { _, ok := classifyError(name); return ok }},
}

// errorSeries: the chart the tokens refused are added to
const errorSeries = 2

// Activity: the charts, the totals of each metric and the errors by kind since
func (r *Recorder) Activity(ctx context.Context, since time.Time, bucket time.Duration) ([]Series, []MetricTotal, []ErrorRow, error) {
	rows, err := r.db.mine().QueryContext(ctx, r.db.q("SELECT minute, name, count, total FROM ffs_metrics WHERE minute >= ?"), since.UnixMilli())
	if err != nil {
		return nil, nil, nil, err
	}
	defer rows.Close()
	n := int(time.Since(since)/bucket) + 1
	series := make([]Series, len(chartSeries))
	for i, c := range chartSeries {
		series[i] = Series{Title: c.title, Points: make([]int64, n)}
	}
	totals := map[string]*MetricTotal{}
	timers := map[string]float64{}
	tally := newErrorTally()
	for rows.Next() {
		var minute, count int64
		var name string
		var total float64
		if err := rows.Scan(&minute, &name, &count, &total); err != nil {
			return nil, nil, nil, err
		}
		i := int(time.UnixMilli(minute).Sub(since) / bucket)
		if i < 0 || i >= n {
			continue
		}
		for s, c := range chartSeries {
			if c.match(name) {
				series[s].Points[i] += count
				series[s].Total += count
			}
		}
		tally.add(minute, name, count)
		// the admin UI's own: in the errors (the tokens refused), not a statsd metric
		if name == tokensRefusedMetric {
			continue
		}
		t := totals[name]
		if t == nil {
			t = &MetricTotal{Name: name}
			totals[name] = t
		}
		t.Count += count
		timers[name] += total
	}
	if err := rows.Err(); err != nil {
		return nil, nil, nil, err
	}
	_, _, refused := tally.refused()
	for minute, count := range refused {
		if i := int(time.UnixMilli(minute).Sub(since) / bucket); i >= 0 && i < n {
			series[errorSeries].Points[i] += count
			series[errorSeries].Total += count
		}
	}
	list := make([]MetricTotal, 0, len(totals))
	for name, t := range totals {
		if timers[name] > 0 && t.Count > 0 {
			t.AvgMs = timers[name] / float64(t.Count)
		}
		list = append(list, *t)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].Count > list[j].Count })
	return series, list, tally.Rows(), nil
}

// Gauge records a value now (e.g. the size of a database), replacing one of the same minute
func (r *Recorder) Gauge(name string, value int64) {
	minute := time.Now().Unix() / 60 * 60 * 1000
	upsert := "INSERT INTO ffs_gauges (minute, name, value) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE value = VALUES(value)"
	if r.db.postgres {
		upsert = "INSERT INTO ffs_gauges (minute, name, value) VALUES ($1, $2, $3) ON CONFLICT (minute, name) DO UPDATE SET value = EXCLUDED.value"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, err := r.db.mine().ExecContext(ctx, upsert, minute, name, value); err != nil {
		log.Printf("gauge %s: %v", name, err)
	}
}

type GaugeSeries struct {
	Name   string
	Last   int64
	Points []int64 // last value of each bucket, 0 without one
}

func (r *Recorder) Gauges(ctx context.Context, since time.Time, bucket time.Duration) ([]GaugeSeries, error) {
	rows, err := r.db.mine().QueryContext(ctx, r.db.q("SELECT minute, name, value FROM ffs_gauges WHERE minute >= ? ORDER BY minute"), since.UnixMilli())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	n := int(time.Since(since)/bucket) + 1
	byName := map[string]*GaugeSeries{}
	var names []string
	for rows.Next() {
		var minute, value int64
		var name string
		if err := rows.Scan(&minute, &name, &value); err != nil {
			return nil, err
		}
		i := int(time.UnixMilli(minute).Sub(since) / bucket)
		if i < 0 || i >= n {
			continue
		}
		g := byName[name]
		if g == nil {
			g = &GaugeSeries{Name: name, Points: make([]int64, n)}
			byName[name] = g
			names = append(names, name)
		}
		g.Points[i], g.Last = value, value
	}
	sort.Strings(names)
	series := make([]GaugeSeries, 0, len(names))
	for _, name := range names {
		series = append(series, *byName[name])
	}
	return series, rows.Err()
}
