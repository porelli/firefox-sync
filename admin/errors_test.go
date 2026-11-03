package main

import (
	"bufio"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"math"
	"os"
	"strings"
	"testing"
	"time"
)

// capturedPackets: datagrams syncstorage-rs 0.23.3 sent to the admin UI (tcpdump in the
// test VM) while a client got tokens refused (an invalid OAuth token, an older
// generation, older keys, a client state that does not fit) and storage errors (a wrong
// Hawk signature, no Hawk header twice, an item that is no JSON object and one too
// large: both bad_bso_body), see errors.go
func capturedPackets(t *testing.T) []string {
	t.Helper()
	f, err := os.Open("testdata/statsd-packets.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	var packets []string
	scan := bufio.NewScanner(f)
	for scan.Scan() {
		var p string
		if err := json.Unmarshal(scan.Bytes(), &p); err != nil {
			t.Fatal(err)
		}
		packets = append(packets, p)
	}
	return packets
}

func TestErrorsOfCapturedPackets(t *testing.T) {
	now := time.Unix(0, 0)
	r := &Recorder{current: map[string]*metric{}, cumulative: map[string]*metric{}, clock: func() time.Time { return now }}
	for _, p := range capturedPackets(t) {
		if len(p) > 512 {
			t.Errorf("a datagram of %d bytes: the Sync server buffers 512", len(p))
		}
		// the tokenserver's buffer sends from a socket of its own
		sender := "sync:1"
		if strings.HasPrefix(p, "syncstorage.tokenserver.") {
			sender = "sync:2"
		}
		now = now.Add(time.Second)
		r.receive(sender, p)
	}
	// the Sync server's next datagram, a minute later: the verifications without their
	// token by then are refused
	now = now.Add(time.Minute)
	r.receive("sync:1", "syncstorage.request.get_collections:0|c")
	tally := newErrorTally()
	for name, m := range r.current {
		tally.add(60000, name, m.count)
	}
	got := map[string]ErrorRow{}
	for _, row := range tally.Rows() {
		got[row.Metric+"|"+row.Kind] = row
	}
	for key, want := range map[string]ErrorRow{
		"syncstorage.request.error.hawk.missing_header|Hawk authentication: missing header": {errorKind: errorKind{storageService, "401", ""}, Count: 2},
		"syncstorage.request.error.hawk.invalid_header|Hawk authentication: invalid header": {errorKind: errorKind{storageService, "401", ""}, Count: 1},
		"syncstorage.request.validate.bad_bso_body|invalid request: bad bso body":           {errorKind: errorKind{storageService, "400", ""}, Count: 2},
		// 19 verified, 15 issued: the four refused
		"|tokens refused": {errorKind: errorKind{tokenService, "401, 500", ""}, Count: 4},
	} {
		row, ok := got[key]
		if !ok || row.Count != want.Count || row.Service != want.Service || row.Status != want.Status || !row.Last.Equal(time.UnixMilli(60000)) {
			t.Errorf("%s: %+v, want %+v", key, row, want)
		}
	}
	if len(got) != 4 {
		t.Errorf("other kinds: %+v", got)
	}
	// the requests: the storage API's, the token requests and the errors before a handler
	tr := tally.Traffic()
	ops := int64(0)
	for name, m := range r.current {
		if isRequest(name) {
			ops += m.count
		}
	}
	if tr.Errors != 9 || tr.Requests != ops+19+5 {
		t.Errorf("traffic %+v (%d served)", tr, ops)
	}
	// Prometheus: the same since the start, by the name without the label
	lines := map[string]int64{}
	for _, row := range errorTotals(r.Cumulative()) {
		lines[row.Service+" "+row.Status+" "+errorLabel(row)] = row.Count
	}
	// not the tokens refused: no counter (it would go down)
	if lines["Sync storage 401 request.error.hawk.missing_header"] != 2 || len(lines) != 3 {
		t.Errorf("totals %v", lines)
	}
}

func TestClassifyError(t *testing.T) {
	for name, want := range map[string]errorKind{
		"syncstorage.request.error.hawk.expired":                 {storageService, "401", "Sync token expired (Firefox gets a new one)"},
		"syncstorage.request.validate.hawk.invalid_uid":          {storageService, "401", "Hawk authentication: invalid uid"},
		"syncstorage.request.validate.payload_too_large":         {storageService, "400", "item too large (payload)"},
		"syncstorage.request.validate.batch.size_exceeded":       {storageService, "400", "batch too large"},
		"syncstorage.request.process.missing_collection":         {storageService, "400", "invalid request: missing collection"},
		"syncstorage.request.error.invalid_content_type":         {storageService, "415", "Content-Type not accepted"},
		"syncstorage.storage.quota.at_limit":                     {storageService, "403", "over quota"},
		"syncstorage.storage.conflict":                           {storageService, "503", "conflicting writes"},
		"syncstorage.tokenserver.storage.pool.timeout":           {tokenService, "503", "database pool timeout"},
		"syncstorage.tokenserver.storage.sql.error.diesel_query": {tokenService, "500", "database: diesel query"},
		"syncstorage.tokenserver.jwt.error.invalid_key":          {tokenService, "401", "OAuth token: invalid key"},
		"syncstorage.tokenserver.request.error.oauth":            {tokenService, "401", "OAuth token refused"},
		"syncstorage.error.rejectua":                             {storageService, "503", "Firefox version refused"},
		"syncstorage.request.error.something_new":                {storageService, "4xx", "something new"},
	} {
		if got, ok := classifyError(name); !ok || got != want {
			t.Errorf("%s: %+v %v", name, got, ok)
		}
	}
	for _, name := range []string{"syncstorage.request.get_collections", "syncstorage.token_creation", "syncstorage.tokenserver.storage.get_pool",
		"syncstorage.tokenserver.storage.allocate_user", "other.request.error.hawk.expired", "syncstorage.request.error"} {
		if k, ok := classifyError(name); ok {
			t.Errorf("%s: an error %+v", name, k)
		}
	}
	if !isRequest("syncstorage.request.post_collection") || isRequest("syncstorage.request.validate.bad_bso_body") || isRequest("syncstorage.request.") {
		t.Error("isRequest")
	}
}

func TestTokensRefusedPerMinute(t *testing.T) {
	tally := newErrorTally()
	// a token verified at the end of a minute, issued in the next: not refused
	tally.add(60000, tokenVerified, 3)
	tally.add(60000, tokenIssued, 2)
	tally.add(120000, tokenVerified, 1)
	tally.add(120000, tokenIssued, 2)
	// one refused, and one verified in the newest minute, its token still in the buffer
	tally.add(180000, tokenVerified, 2)
	tally.add(180000, tokenIssued, 1)
	tally.add(240000, tokenVerified, 1)
	n, last, per := tally.refused()
	if n != 1 || !last.Equal(time.UnixMilli(180000)) || len(per) != 1 || per[180000] != 1 {
		t.Errorf("%d %v %v", n, last, per)
	}
	if tr := tally.Traffic(); tr.Requests != 7 || tr.Errors != 1 {
		t.Errorf("%+v", tr)
	}
	// the token of the verification at 120000 comes in the window: paid off there
	if w, b := tally.TrafficBetween(120000, math.MaxInt64), tally.TrafficBetween(math.MinInt64, 120000); w.Errors != 1 || b.Errors != 0 || w.Requests != 4 || b.Requests != 3 {
		t.Errorf("window %+v baseline %+v", w, b)
	}
	// once something newer came in, the last one is refused
	tally.add(300000, "syncstorage.request.get_collections", 1)
	if n, _, _ := tally.refused(); n != 2 {
		t.Errorf("%d", n)
	}
	// a token issued first (verified before the span) pays off nothing after it
	tally = newErrorTally()
	tally.add(60000, tokenIssued, 1)
	tally.add(120000, tokenVerified, 1)
	tally.add(180000, tokenIssued, 0)
	if n, _, _ := tally.refused(); n != 1 {
		t.Errorf("issued first: %d", n)
	}
}

func TestErrorRateSpike(t *testing.T) {
	c := errorRateConfig{percent: 10, minErrors: 20}
	for _, tc := range []struct {
		name             string
		window, baseline traffic
		was, spike       bool
	}{
		{"quiet", traffic{Requests: 1000, Errors: 5}, traffic{Requests: 100000, Errors: 500}, false, false},
		{"spike", traffic{Requests: 1000, Errors: 300}, traffic{Requests: 100000, Errors: 500}, false, true},
		{"spike, no baseline", traffic{Requests: 200, Errors: 50}, traffic{}, false, true},
		{"a small server: 1 error of 2 requests", traffic{Requests: 2, Errors: 1}, traffic{}, false, false},
		{"19 errors: under the minimum", traffic{Requests: 40, Errors: 19}, traffic{}, false, false},
		{"always that many: not 3 times the day before", traffic{Requests: 1000, Errors: 300}, traffic{Requests: 100000, Errors: 20000}, false, false},
		{"just under the share", traffic{Requests: 1000, Errors: 99}, traffic{}, false, false},
		// a spike ends under half the share or half the errors
		{"still a spike at 6%", traffic{Requests: 1000, Errors: 60}, traffic{Requests: 100000, Errors: 500}, true, true},
		{"over at 4%", traffic{Requests: 1000, Errors: 40}, traffic{Requests: 100000, Errors: 500}, true, false},
		{"over with 9 errors", traffic{Requests: 50, Errors: 9}, traffic{}, true, false},
	} {
		if got := c.spike(tc.window, tc.baseline, tc.was); got != tc.spike {
			t.Errorf("%s: %v", tc.name, got)
		}
	}
	if (errorRateConfig{percent: 0, minErrors: 1}).spike(traffic{Requests: 10, Errors: 10}, traffic{}, false) {
		t.Error("ADMIN_ERROR_RATE_PERCENT=0 alerts")
	}
	t.Setenv("ADMIN_ERROR_RATE_PERCENT", "")
	t.Setenv("ADMIN_ERROR_RATE_MIN_ERRORS", "")
	if got := errorRateSettings(); got != c {
		t.Errorf("defaults %+v", got)
	}
}

// metricRows: the rows of ffs_metrics a query gets, (minute, name, count) or with total
func metricRows(rows [][]driver.Value, total bool) *fakeRows {
	cols := []string{"minute", "name", "count"}
	if total {
		cols = append(cols, "total")
		for i := range rows {
			rows[i] = append(rows[i], float64(0))
		}
	}
	return &fakeRows{cols: cols, rows: rows}
}

func TestWatchErrorRate(t *testing.T) {
	now := time.Now()
	var rows [][]driver.Value
	fake := &fakeFxa{answer: func(query string, _ []driver.Value) *fakeRows {
		if strings.Contains(query, "FROM ffs_metrics WHERE minute >= ?") && strings.Contains(query, "IN ('syncstorage.token_verification', 'syncstorage.token_creation', 'ffs.tokens_refused', 'ffs.health_checks')") && !strings.Contains(query, "token_%") {
			return metricRows(append([][]driver.Value(nil), rows...), false)
		}
		return nil
	}}
	app := testApp()
	app.sync, app.alerter = &SyncDB{db: sql.OpenDB(fake)}, &Alerter{}
	app.rec = &Recorder{db: app.sync}
	h := newHealth(app)
	h.errorRate = errorRateConfig{percent: 10, minErrors: 20}
	app.health = h
	minute := func(ago time.Duration) int64 { return now.Add(-ago).Truncate(time.Minute).UnixMilli() }
	// the day before: 1000 requests, 10 errors
	base := [][]driver.Value{
		{minute(5 * time.Hour), "syncstorage.request.get_collections", int64(990)},
		{minute(5 * time.Hour), "syncstorage.request.error.hawk.missing_header", int64(10)},
	}
	round := func(r ...[]driver.Value) []string {
		rows = append(append([][]driver.Value(nil), base...), r...)
		h.watchErrorRate(t.Context(), now)
		return app.alerter.take()
	}
	if got := round(); len(got) != 0 {
		t.Errorf("quiet: %q", got)
	}
	row, ok := errorRateRow(h.ErrorRate(), h.errorRate)
	if !ok || !row.Up || !row.Limit || !strings.Contains(row.Detail, "0 errors of 0 Sync requests from Firefox in the last 15 minutes, alert") {
		t.Errorf("row %+v", row)
	}
	// the health checks: apart, not requests (syncstorage-rs 0.24's request.duration of
	// /__heartbeat__ counted by the recorder)
	got := round([]driver.Value{minute(3 * time.Minute), "ffs.health_checks", int64(61)},
		[]driver.Value{minute(3 * time.Minute), "syncstorage.request.duration", int64(61)})
	row, _ = errorRateRow(h.ErrorRate(), h.errorRate)
	if len(got) != 0 || !strings.Contains(row.Detail, "0 errors of 0 Sync requests from Firefox in the last 15 minutes, alert from 10% and 20 errors (ADMIN_ERROR_RATE_PERCENT); 61 health checks of the Sync server besides, not counted") {
		t.Errorf("health checks: %q %+v", got, row)
	}
	// 40 tokens refused and 30 storage errors in 200 requests
	spike := [][]driver.Value{
		{minute(2 * time.Minute), "syncstorage.request.get_collections", int64(80)},
		{minute(time.Minute), "syncstorage.request.get_collections", int64(10)},
		{minute(2 * time.Minute), "syncstorage.request.validate.bad_bso_body", int64(30)},
		{minute(2 * time.Minute), "syncstorage.token_verification", int64(80)},
		{minute(2 * time.Minute), "syncstorage.token_creation", int64(40)},
	}
	got = round(spike...)
	if len(got) != 1 || !strings.Contains(got[0], "attention: 70 of 200 Sync requests from Firefox failed in the last 15 minutes (35%, 1.0% the day before)") {
		t.Errorf("spike: %q", got)
	}
	if got := round(spike...); len(got) != 0 {
		t.Errorf("alerted twice: %q", got)
	}
	row, _ = errorRateRow(h.ErrorRate(), h.errorRate)
	if row.Up || !row.Warn || row.Label != "spike" {
		t.Errorf("row %+v", row)
	}
	var b strings.Builder
	thresholdMetrics(&b, h)
	if !strings.Contains(b.String(), "\nffs_sync_error_ratio 0.35\n") || !strings.Contains(b.String(), "\nffs_sync_error_spike 1\n") {
		t.Errorf("prometheus: %s", b.String())
	}
	list := needsAttention(attentionInput{now: now, components: []Component{row}})
	if len(list) != 1 || list[0].Href != "/activity#errors" || !strings.Contains(list[0].Text, "70 of 200 Sync requests from Firefox failed") {
		t.Errorf("needs attention %+v", list)
	}
	if got := round(); len(got) != 1 || !strings.Contains(got[0], "back to normal") {
		t.Errorf("over: %q", got)
	}
	// off: no query, no row
	h.errorRate = errorRateConfig{}
	n := len(fake.queried("FROM ffs_metrics"))
	round(spike...)
	if len(fake.queried("FROM ffs_metrics")) != n {
		t.Error("checked while off")
	}
	if _, ok := errorRateRow(h.ErrorRate(), h.errorRate); ok {
		t.Error("a row while off")
	}
}

func TestActivityErrorsByKind(t *testing.T) {
	now := time.Now().Truncate(time.Minute)
	fake := &fakeFxa{answer: func(query string, _ []driver.Value) *fakeRows {
		if strings.HasPrefix(query, "SELECT minute, name, count, total FROM ffs_metrics") {
			at := now.Add(-time.Hour).UnixMilli()
			return metricRows([][]driver.Value{
				{at, "syncstorage.request.get_collections", int64(5)},
				{at + 60000, "syncstorage.request.get_collections", int64(5)},
				{at, "syncstorage.request.validate.bad_bso_body", int64(2)},
				{at, "syncstorage.request.error.hawk.missing_header", int64(3)},
				{at, "syncstorage.token_verification", int64(5)},
				{at, "syncstorage.token_creation", int64(4)},
			}, true)
		}
		return nil
	}}
	app, h, c, _ := limitsApp(t, fake)
	app.rec = &Recorder{db: app.sync}
	page := getPage(h, "/activity", c).Body.String()
	for _, want := range []string{
		`<section class="card" id="errors" aria-labelledby="errors-title">`,
		`<tr data-metric="syncstorage.request.error.hawk.missing_header"><td>Hawk authentication: missing header</td><td>401</td><td>Sync storage</td><td>3</td>`,
		`<tr data-metric="syncstorage.request.validate.bad_bso_body"><td>invalid request: bad bso body</td><td>400</td><td>Sync storage</td><td>2</td>`,
		`<tr data-metric="tokens refused"><td>tokens refused</td><td>401, 500</td><td>Tokenserver</td><td>1</td>`,
		// the charts: 10 requests served, 6 errors (the token refused with them)
		"Sync requests <strong>10</strong>", "Errors <strong>6</strong>",
		`id="error-rate">Not checked yet. An alert from 10% of the requests and 20 errors in 15 minutes`,
	} {
		if !strings.Contains(page, want) {
			t.Errorf("no %q", want)
		}
	}
}
