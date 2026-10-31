package main

import (
	"bufio"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"
)

type fakeChecker struct {
	allowed map[string]bool
	// refused as full (FXA_MAX_ACCOUNTS) rather than by the policy
	full  bool
	err   error
	asked []string
}

func (f *fakeChecker) SignupRefusal(ctx context.Context, email string) (string, error) {
	f.asked = append(f.asked, email)
	switch {
	case f.allowed[email]:
		return "", f.err
	case f.full:
		return refusedFull, f.err
	}
	return refusedPolicy, f.err
}

type seen struct {
	path, host, xff, body string
}

func gateWithUpstream(t *testing.T, checker SignupChecker) (http.Handler, *[]seen) {
	var requests []seen
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		requests = append(requests, seen{r.URL.RequestURI(), r.Host, r.Header.Get("X-Forwarded-For"), string(body)})
		w.Write([]byte(`{"uid":"x"}`))
	}))
	t.Cleanup(upstream.Close)
	u, _ := url.Parse(upstream.URL)
	return newGate(u, "https://accounts.example.com", checker, nil, "probe-token"), &requests
}

func create(gate http.Handler, path, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, "http://api.example.com"+path, strings.NewReader(body))
	req.Header.Set("X-Forwarded-For", "203.0.113.7")
	w := httptest.NewRecorder()
	gate.ServeHTTP(w, req)
	return w
}

func TestGateForwardsAllowedSignups(t *testing.T) {
	checker := &fakeChecker{allowed: map[string]bool{"alice@example.com": true}}
	gate, requests := gateWithUpstream(t, checker)
	body := `{"email":"alice@example.com","authPW":"x"}`
	w := create(gate, "/v1/account/create?keys=true", body)
	if w.Code != 200 || len(*requests) != 1 {
		t.Fatalf("not forwarded: %d %v", w.Code, *requests)
	}
	got := (*requests)[0]
	if got.path != "/v1/account/create?keys=true" || got.body != body || got.host != "api.example.com" {
		t.Errorf("changed on the way: %+v", got)
	}
	// the auth server reads the client address at a fixed depth: no extra hop
	if got.xff != "203.0.113.7" {
		t.Errorf("X-Forwarded-For = %q", got.xff)
	}
}

func TestGateRefusesSignups(t *testing.T) {
	checker := &fakeChecker{allowed: map[string]bool{}}
	gate, requests := gateWithUpstream(t, checker)
	for _, path := range []string{"/v1/account/create", "/v1//account/create", "/v1/account/create/", "/v1/account/./create"} {
		w := create(gate, path, `{"email":"mallory@example.org"}`)
		if w.Code != http.StatusBadRequest || !strings.Contains(w.Body.String(), `"errno":125`) {
			t.Errorf("%s: %d %s", path, w.Code, w.Body)
		}
	}
	if len(*requests) != 0 {
		t.Errorf("refused sign-ups reached the auth server: %v", *requests)
	}
}

func TestGateReadsTheEmailAsTheAuthServer(t *testing.T) {
	checker := &fakeChecker{allowed: map[string]bool{"alice@example.com": true}}
	gate, requests := gateWithUpstream(t, checker)
	// encoding/json would take the last key that case-folds to "email", the auth
	// server takes only "email" itself
	for _, body := range []string{
		`{"email":"mallory@example.org","Email":"alice@example.com"}`,
		`{"email":"mallory@example.org","EMAIL":"alice@example.com"}`,
		`{"email":"alice@example.com","email":"mallory@example.org"}`,
	} {
		if w := create(gate, "/v1/account/create", body); w.Code != http.StatusBadRequest {
			t.Errorf("%s: %d, forwarded", body, w.Code)
		}
	}
	if len(*requests) != 0 {
		t.Errorf("reached the auth server: %v", *requests)
	}
	// not the auth server's email: it refuses those itself
	if w := create(gate, "/v1/account/create", `{"Email":"mallory@example.org"}`); w.Code != 200 {
		t.Errorf("no email key: %d", w.Code)
	}
}

func TestGateRefusalReadableByTheAccountsPages(t *testing.T) {
	gate, _ := gateWithUpstream(t, &fakeChecker{})
	for origin, want := range map[string]string{"https://accounts.example.com": "https://accounts.example.com", "https://evil.example": ""} {
		req := httptest.NewRequest(http.MethodPost, "/v1/account/create", strings.NewReader(`{"email":"mallory@example.org"}`))
		req.Header.Set("Origin", origin)
		w := httptest.NewRecorder()
		gate.ServeHTTP(w, req)
		if got := w.Header().Get("Access-Control-Allow-Origin"); got != want {
			t.Errorf("%s: Access-Control-Allow-Origin %q", origin, got)
		}
		// the pages send credentials: without this they cannot read the error either
		if creds := w.Header().Get("Access-Control-Allow-Credentials"); (creds == "true") != (want != "") {
			t.Errorf("%s: Access-Control-Allow-Credentials %q", origin, creds)
		}
	}
}

func TestGateFailsClosed(t *testing.T) {
	gate, requests := gateWithUpstream(t, &fakeChecker{err: errors.New("db down")})
	if w := create(gate, "/v1/account/create", `{"email":"alice@example.com"}`); w.Code != http.StatusServiceUnavailable {
		t.Errorf("status %d", w.Code)
	}
	if len(*requests) != 0 {
		t.Error("forwarded without a policy decision")
	}
}

func TestGatePassesEverythingElse(t *testing.T) {
	checker := &fakeChecker{}
	gate, requests := gateWithUpstream(t, checker)
	create(gate, "/v1/account/login", `{"email":"mallory@example.org"}`)
	req := httptest.NewRequest(http.MethodGet, "/v1/account/create", nil)
	gate.ServeHTTP(httptest.NewRecorder(), req)
	if len(*requests) != 2 || len(checker.asked) != 0 {
		t.Errorf("requests %v, checked %v", *requests, checker.asked)
	}
}

func TestGateBodyLimit(t *testing.T) {
	gate, requests := gateWithUpstream(t, &fakeChecker{})
	w := create(gate, "/v1/account/create", `{"email":"`+strings.Repeat("a", maxCreateBody)+`"}`)
	if w.Code != http.StatusRequestEntityTooLarge || len(*requests) != 0 {
		t.Errorf("status %d, forwarded %d", w.Code, len(*requests))
	}
}

func TestParseAllowlist(t *testing.T) {
	got, err := ParseAllowlist("Alice@Example.com, example.org\n@example.net;alice@example.com")
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"alice@example.com", "@example.org", "@example.net"}
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Errorf("got %v", got)
	}
	for _, bad := range []string{"alice", "@", "alice@", "a@b@example.com", "@localhost", "%' OR 1=1"} {
		if _, err := ParseAllowlist(bad); err == nil {
			t.Errorf("accepted %q", bad)
		}
	}
	if got, _ := ParseAllowlist(" \n "); len(got) != 0 {
		t.Errorf("empty list: %v", got)
	}
}

func TestParseMode(t *testing.T) {
	for _, m := range []string{"open", "Allowlist", " closed "} {
		if _, err := ParseMode(m); err != nil {
			t.Error(err)
		}
	}
	if _, err := ParseMode("invite"); err == nil {
		t.Error("accepted invite")
	}
}

func testApp() *App {
	return &App{auth: &authConfig{password: &testPassword}, sessions: map[string]*session{}}
}

func post(h http.Handler, path string, form url.Values, cookie *http.Cookie, headers map[string]string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, "https://admin.example.com"+path, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	if cookie != nil {
		req.AddCookie(cookie)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)
	return w
}

func TestLogin(t *testing.T) {
	app := testApp()
	h := app.routes()
	w := post(h, "/login", url.Values{"password": {"correct horse battery"}}, nil, nil)
	cookies := w.Result().Cookies()
	if w.Code != http.StatusSeeOther || len(cookies) != 1 {
		t.Fatalf("login failed: %d", w.Code)
	}
	c := cookies[0]
	if !c.HttpOnly || !c.Secure || c.SameSite != http.SameSiteStrictMode {
		t.Errorf("cookie flags: %+v", c)
	}
	var s *session
	for _, s = range app.sessions {
	}

	// form posts need the CSRF token of the session, and the same origin
	logout := func(form url.Values, headers map[string]string) int {
		return post(h, "/logout", form, c, headers).Code
	}
	if code := logout(url.Values{}, nil); code != http.StatusForbidden {
		t.Errorf("no CSRF token: %d", code)
	}
	if code := logout(url.Values{"csrf": {s.csrf}}, map[string]string{"Origin": "https://evil.example"}); code != http.StatusForbidden {
		t.Errorf("cross origin: %d", code)
	}
	if code := logout(url.Values{"csrf": {s.csrf}}, map[string]string{"Sec-Fetch-Site": "cross-site"}); code != http.StatusForbidden {
		t.Errorf("cross site: %d", code)
	}
	if code := logout(url.Values{"csrf": {s.csrf}}, map[string]string{"Origin": "https://admin.example.com"}); code != http.StatusSeeOther {
		t.Errorf("logout: %d", code)
	}
	if len(app.sessions) != 0 {
		t.Error("session kept after logout")
	}
	if code := logout(url.Values{"csrf": {s.csrf}}, nil); code != http.StatusUnauthorized {
		t.Errorf("after logout: %d", code)
	}
}

func TestLoginThrottle(t *testing.T) {
	app := testApp()
	h := app.routes()
	for i := 0; i < loginFailuresPerMinute; i++ {
		if w := post(h, "/login", url.Values{"password": {"guess"}}, nil, nil); len(w.Result().Cookies()) != 0 {
			t.Fatal("wrong password accepted")
		}
	}
	// even the right password waits once the failures add up
	if w := post(h, "/login", url.Values{"password": {"correct horse battery"}}, nil, nil); w.Code != http.StatusTooManyRequests {
		t.Errorf("status %d", w.Code)
	}
}

func TestDashboardNeedsLogin(t *testing.T) {
	h := testApp().routes()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)
	if w.Code != http.StatusSeeOther || w.Header().Get("Location") != "/login" {
		t.Errorf("status %d %s", w.Code, w.Header().Get("Location"))
	}
	if !strings.Contains(w.Header().Get("Content-Security-Policy"), "default-src 'none'") {
		t.Error("no CSP")
	}
}

func TestRedisRevoke(t *testing.T) {
	// a fake Redis that records the command and answers like EVAL
	server, client := net.Pipe()
	defer client.Close()
	got := make(chan string, 1)
	go func() {
		buf := make([]byte, 4096)
		n, _ := server.Read(buf)
		got <- string(buf[:n])
		server.Write([]byte(":2\r\n"))
		server.Close()
	}()
	reply, err := redisCommand(client, "EVAL", revokeScript, "2", "at:abc", "fxa-auth-sessionabc")
	if err != nil || reply != int64(2) {
		t.Fatalf("reply %v, %v", reply, err)
	}
	if cmd := <-got; !strings.HasPrefix(cmd, "*5\r\n$4\r\nEVAL\r\n") || !strings.Contains(cmd, "$6\r\nat:abc\r\n") {
		t.Errorf("command %q", cmd)
	}
	for in, want := range map[string]any{"+OK\r\n": "OK", "$3\r\nabc\r\n": "abc", "*2\r\n:1\r\n$1\r\nx\r\n": []any{int64(1), "x"}} {
		v, err := readReply(bufio.NewReader(strings.NewReader(in)))
		if err != nil || fmt.Sprint(v) != fmt.Sprint(want) {
			t.Errorf("%q: %v %v", in, v, err)
		}
	}
	if _, err := readReply(bufio.NewReader(strings.NewReader("-ERR nope\r\n"))); err == nil {
		t.Error("error reply accepted")
	}
}

func TestStatsd(t *testing.T) {
	r := &Recorder{current: map[string]*metric{}}
	r.parseStatsd("syncstorage.request.get_collections:1|c|#tokenserver_origin:rust\n" +
		"syncstorage.request.get_collections:2|c|@0.5\n" +
		"syncstorage.token_creation:12|ms|#token_type:OAuth\nsyncstorage.token_creation:8|ms\n" +
		"bad name:1|c\nnovalue|c\nsyncstorage.x:abc|c\nsyncstorage.gauge:3|g")
	if m := r.current["syncstorage.request.get_collections"]; m == nil || m.count != 5 {
		t.Errorf("counter %+v", m)
	}
	if m := r.current["syncstorage.token_creation"]; m == nil || m.count != 2 || m.total != 20 {
		t.Errorf("timer %+v", m)
	}
	// and the tokens refused of a datagram of the Sync server's buffer: none
	if m := r.current[tokensRefusedMetric]; len(r.current) != 4 || m == nil || m.count != 0 {
		t.Errorf("kept %v", r.current)
	}
	// a sender cannot make it keep unlimited names
	for i := 0; i < 2*maxMetricNames; i++ {
		r.parseStatsd(fmt.Sprintf("flood.%d:1|c", i))
	}
	if len(r.current) != maxMetricNames {
		t.Errorf("%d names", len(r.current))
	}
}

func TestBarChart(t *testing.T) {
	// no bar for 0, the peak at full height, gridlines and a baseline
	svg := string(barChart([]int64{0, 5, 10}, "peak 10 per hour, from <then> to now"))
	if !strings.HasPrefix(svg, "<svg") || strings.Count(svg, "<rect") != 2 || !strings.Contains(svg, `height="118.0"`) ||
		!strings.Contains(svg, `aria-label="peak 10 per hour, from &lt;then&gt; to now"`) || strings.Count(svg, `class="grid"`) != 2 || !strings.Contains(svg, `class="base"`) {
		t.Errorf("%s", svg)
	}
	// a measure: one line per run of measured points, below the top (headroom)
	line := string(lineChart([]int64{0, 64, 64, 0, 80}, "peak 80 B"))
	if !strings.Contains(line, `aria-label="peak 80 B"`) || strings.Count(line, `class="stroke"`) != 2 || strings.Count(line, `class="area"`) != 2 ||
		!strings.Contains(line, "M180.0 43.5 L300.0 43.5") || !strings.Contains(line, `y1="24.6"`) || peak([]int64{3, 9, 2}) != 9 {
		t.Errorf("%s", line)
	}
	if humanBytes(1536) != "1.5 KB" || humanBytes(10) != "10 B" {
		t.Error(humanBytes(1536))
	}
}

func TestParseRateLimitKey(t *testing.T) {
	kind, on, value, action, max, window, ok := parseRateLimitKey("rate-limit:block:ip_email=172.18.0.16_invited@example.net:accountLogin:5-900-900")
	if !ok || kind != "block" || on != "ip_email" || value != "172.18.0.16_invited@example.net" || action != "accountLogin" || max != 5 || window.Seconds() != 900 {
		t.Errorf("%v %v %v %v %v %v", kind, on, value, action, max, window)
	}
	_, on, value, action, _, _, ok = parseRateLimitKey("rate-limit:attempts:ip=2001:db8::1:accountLogin:100-86400-900")
	if !ok || on != "ip" || value != "2001:db8::1" || action != "accountLogin" {
		t.Errorf("IPv6: %v %v %v", on, value, action)
	}
	for _, bad := range []string{"at:abc", "rate-limit:block:nothing", "rate-limit:block:ip=1:accountLogin:5-900"} {
		if _, _, _, _, _, _, ok := parseRateLimitKey(bad); ok {
			t.Errorf("accepted %q", bad)
		}
	}
	// only blocks can be lifted: Unblock refuses anything else before touching Redis
	if err := (&FxaDB{}).Unblock(context.Background(), "fxa-auth-session123"); err == nil {
		t.Error("unblocked a non-block key")
	}
}

func TestNewerVersion(t *testing.T) {
	for _, c := range []struct {
		a, b string
		want bool
	}{{"0.23.4", "0.23.3", true}, {"0.23.3", "0.23.3", false}, {"v1.348.0", "v1.347.1", true}, {"0.24.0", "0.23.10", true}, {"0.23.3", "0.24.0", false}, {"latest", "0.23.3", false}} {
		if got := newerVersion(c.a, c.b); got != c.want {
			t.Errorf("newerVersion(%q, %q) = %v", c.a, c.b, got)
		}
	}
	if senderAddress(`"Mozilla accounts" <no-reply@example.com>`) != "no-reply@example.com" || senderAddress("a@b.c") != "a@b.c" {
		t.Error("senderAddress")
	}
}

func TestPrometheusNeedsToken(t *testing.T) {
	h := testApp().routes()
	for _, auth := range []string{"", "Bearer wrong"} {
		req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
		if auth != "" {
			req.Header.Set("Authorization", auth)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
		if w.Code != http.StatusNotFound {
			t.Errorf("%q: %d", auth, w.Code)
		}
	}
}

func TestMaxUsersFitsTheTriggers(t *testing.T) {
	app := testApp()
	app.maxUsersEditable = true
	h := app.routes()
	c := post(h, "/login", url.Values{"password": {"correct horse battery"}}, nil, nil).Result().Cookies()[0]
	var s *session
	for _, s = range app.sessions {
	}
	// refused before the database (there is none here)
	for _, n := range []string{"-1", "2147483648", "3000000000", "lots"} {
		if w := post(h, "/sync/max-users", url.Values{"csrf": {s.csrf}, "max_users": {n}}, c, nil); w.Code != http.StatusSeeOther {
			t.Fatalf("%s: status %d", n, w.Code)
		}
		if !strings.Contains(s.failed, "from 0 to 2147483647") {
			t.Errorf("%s: %q", n, s.failed)
		}
	}
	if err := (&SyncDB{}).SetMaxUsers(context.Background(), 1<<31, false); err == nil {
		t.Error("SetMaxUsers accepted 2^31")
	}
}

func TestMaxUsersEditable(t *testing.T) {
	for v, want := range map[string]bool{
		"initial:5": true, " initial:5 ": true, "initial:0": true,
		// set again by the init container on every start
		"5": false, "fixed:5": false,
		// not given: read-only, the safe side
		"": false,
		// the init container refuses these
		"lots": false, "Initial:5": false, "-1": false,
	} {
		if got := maxUsersEditable(v); got != want {
			t.Errorf("%q: %v", v, got)
		}
	}
}

func TestMaxUsersReadOnly(t *testing.T) {
	app := testApp() // MAX_USERS not initial:N
	h := app.routes()
	c := post(h, "/login", url.Values{"password": {"correct horse battery"}}, nil, nil).Result().Cookies()[0]
	var s *session
	for _, s = range app.sessions {
	}
	// refused before the database: there is none here, SetMaxUsers would panic
	w := post(h, "/sync/max-users", url.Values{"csrf": {s.csrf}, "max_users": {"5"}}, c, nil)
	if w.Code != http.StatusSeeOther || !strings.Contains(s.failed, "managed by SYNC_MAX_USERS in .env") || s.message != "" {
		t.Errorf("status %d, failed %q, message %q", w.Code, s.failed, s.message)
	}

	render := func(editable bool) string {
		var b strings.Builder
		data := map[string]any{"CSRF": "x", "Sync": &SyncStatus{Users: 1, MaxUsers: 5}, "MaxUsersEditable": editable}
		if err := templates.ExecuteTemplate(&b, "dashboard.html", data); err != nil {
			t.Fatal(err)
		}
		return b.String()
	}
	page := render(false)
	for _, want := range []string{`value="5" required disabled>`, `<button type="submit" disabled>Save</button>`, "managed by SYNC_MAX_USERS in .env; set SYNC_MAX_USERS=initial:5 to manage it here"} {
		if !strings.Contains(page, want) {
			t.Errorf("read-only page without %q", want)
		}
	}
	page = render(true)
	if strings.Contains(page, "disabled>") || strings.Contains(page, "set SYNC_MAX_USERS=initial:5") {
		t.Error("editable page has a disabled form")
	}
}

func TestServeChecksIntervals(t *testing.T) {
	t.Setenv("ADMIN_PASSWORD", "correct horse battery")
	for _, name := range []string{"HEALTH_CHECK_SECONDS", "METRICS_FLUSH_SECONDS", "ALERT_INTERVAL_SECONDS"} {
		t.Setenv(name, "0")
		// before any database: a ticker of 0 panics in the background
		if err := serve(context.Background()); err == nil || !strings.Contains(err.Error(), name) {
			t.Errorf("%s=0: %v", name, err)
		}
		t.Setenv(name, "5")
	}
	// 0 would delete the accounts of people still waiting for their code
	t.Setenv("ADMIN_DELETE_UNCONFIRMED_DAYS", "0")
	if err := serve(context.Background()); err == nil || !strings.Contains(err.Error(), "ADMIN_DELETE_UNCONFIRMED_DAYS") {
		t.Errorf("ADMIN_DELETE_UNCONFIRMED_DAYS=0: %v", err)
	}
}

func TestUnconfirmedCutoffRange(t *testing.T) {
	fake := &fakeFxa{}
	app := testApp()
	app.fxa, app.sync = fake.db("127.0.0.1:1"), &SyncDB{db: sql.OpenDB(fake)}
	h := app.routes()
	c, s := passwordSession(t, app, h)
	for _, days := range []string{"0", "abc", "-3", "36501"} {
		if w := getPage(h, "/accounts/unconfirmed?days="+days, c); w.Code != http.StatusBadRequest {
			t.Errorf("GET days=%s: %d", days, w.Code)
		}
		post(h, "/accounts/unconfirmed", url.Values{"csrf": {s.csrf}, "days": {days}}, c, nil)
		if s.failed != "days: a number of at least 1" || s.message != "" {
			t.Errorf("POST days=%s: %q %q", days, s.message, s.failed)
		}
	}
	for _, q := range fake.statements() {
		if strings.Contains(q, "ffs.delete_unconfirmed") {
			t.Errorf("deleted: %s", q)
		}
	}
	if w := getPage(h, "/accounts/unconfirmed?days=7", c); w.Code != http.StatusOK {
		t.Errorf("days=7: %d", w.Code)
	}
}

func TestSessionExpiry(t *testing.T) {
	app := testApp()
	h := app.routes()
	c, s := passwordSession(t, app, h)
	app.mu.Lock()
	s.expires = time.Now().Add(-time.Second)
	app.mu.Unlock()
	if w := getPage(h, "/", c); w.Code != http.StatusSeeOther || w.Header().Get("Location") != "/login" {
		t.Errorf("expired GET: %d %q", w.Code, w.Header().Get("Location"))
	}
	if app.sessions[c.Value] != nil {
		t.Error("expired session kept")
	}
	if w := post(h, "/logout", url.Values{"csrf": {s.csrf}}, c, nil); w.Code != http.StatusUnauthorized {
		t.Errorf("expired POST: %d", w.Code)
	}
	// a sign-in sweeps out the sessions that expired without coming back
	app.mu.Lock()
	app.sessions["stale"] = &session{csrf: "x", expires: time.Now().Add(-time.Minute), method: "password"}
	app.mu.Unlock()
	c2, _ := passwordSession(t, app, h)
	app.mu.Lock()
	defer app.mu.Unlock()
	if app.sessions["stale"] != nil || app.sessions[c2.Value] == nil || len(app.sessions) != 1 {
		t.Errorf("sessions after a sign-in: %v", app.sessions)
	}
}

// passwordSession: a password session of app, its cookie and its CSRF token
func passwordSession(t *testing.T, app *App, h http.Handler) (*http.Cookie, *session) {
	t.Helper()
	c := post(h, "/login", url.Values{"password": {"correct horse battery"}}, nil, nil).Result().Cookies()[0]
	for _, s := range app.sessions {
		return c, s
	}
	t.Fatal("no session")
	return nil, nil
}

func getPage(h http.Handler, path string, cookie *http.Cookie) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, "https://admin.example.com"+path, nil)
	req.AddCookie(cookie)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)
	return w
}

// alerts: the alerts of the events, waiting for those recorded in the background (a purge)
func alerts(t *testing.T, al *Alerter, n int) []string {
	t.Helper()
	var lines []string
	for i := 0; i < 100 && len(lines) < n; i++ {
		lines = append(lines, al.take()...)
		time.Sleep(10 * time.Millisecond)
	}
	return lines
}

func TestAuditText(t *testing.T) {
	for _, c := range []struct {
		s      session
		reason string
		want   string
	}{
		{session{method: "password"}, "", "Max users set to 2 by admin (password)"},
		{session{user: "alice@example.com", method: "oidc"}, "", "Max users set to 2 by alice@example.com (oidc)"},
		{session{user: "bob@example.org", method: "header"}, "  lost laptop\r\nBcc: x ", "Max users set to 2 by bob@example.org (header): lost laptopBcc: x"},
		{session{user: "x\nforged", method: "header"}, strings.Repeat("a", 300), "Max users set to 2 by xforged (header): " + strings.Repeat("a", maxReason) + "..."},
	} {
		if got := auditText(&c.s, "Max users set to 2", c.reason); got != c.want {
			t.Errorf("%+v: %q", c.s, got)
		}
	}
	acc := &FxaAccount{UID: fakeUID, Email: fakeEmail}
	if got := accountLabel(acc, fakeUID); got != "alice@example.com (uid 0123abcd)" {
		t.Error(got)
	}
	if got := accountLabel(nil, fakeUID); got != "account "+fakeUID {
		t.Error(got)
	}
}

func TestAdminActionsAlert(t *testing.T) {
	app := testApp()
	app.alerter = &Alerter{}
	h := app.routes()
	c, s := passwordSession(t, app, h)
	app.alerter.take() // the sign-in
	app.maxUsersEditable = true
	// refused before the database: no change, no alert
	post(h, "/sync/max-users", url.Values{"csrf": {s.csrf}, "max_users": {"-1"}}, c, nil)
	if lines := alerts(t, app.alerter, 0); len(lines) != 0 {
		t.Errorf("alert for a refused change: %q", lines)
	}
	for _, kind := range []string{"admin", "sign-in", "sign-up refused", "health", "update"} {
		if !alertKinds[kind] {
			t.Errorf("no alert for %s", kind)
		}
	}
	// changes alert like sign-ins, 20 of them at most
	for i := 0; i < 2*maxAlertsPerKind; i++ {
		app.event("admin", fmt.Sprintf("Disabled alice@example.com (uid 0123abcd) by admin (password) %d", i))
	}
	lines := app.alerter.take()
	if len(lines) != maxAlertsPerKind+1 || !strings.HasSuffix(lines[0], "admin: Disabled alice@example.com (uid 0123abcd) by admin (password) 0") ||
		!strings.HasSuffix(lines[maxAlertsPerKind], "20 more admin") {
		t.Errorf("%d lines: %q", len(lines), lines)
	}
}

func TestPruneKeepsTheAuditTrailLonger(t *testing.T) {
	now := time.Now()
	r := &Recorder{keepDays: 30, auditDays: 365}
	type row struct {
		kind string
		age  int // days
		kept bool
	}
	rows := []row{{"admin", 1, true}, {"admin", 60, true}, {"admin", 400, false}, {"health", 1, true}, {"health", 60, false}, {"sign-in", 60, false}}
	for _, row := range rows {
		at := now.AddDate(0, 0, -row.age).UnixMilli()
		deleted := false
		for _, p := range r.pruneStatements(now) {
			if !strings.HasPrefix(p.query, "DELETE FROM ffs_events ") {
				continue
			}
			admin := strings.Contains(p.query, "kind = 'admin'")
			if !admin && !strings.Contains(p.query, "kind <> 'admin'") {
				t.Fatalf("prunes every kind alike: %s", p.query)
			}
			if admin == (row.kind == "admin") && at < p.cutoff {
				deleted = true
			}
		}
		if deleted == row.kept {
			t.Errorf("%s of %d days: kept %v", row.kind, row.age, !deleted)
		}
	}
	for _, p := range r.pruneStatements(now) {
		if strings.Contains(p.query, "ffs_metrics") && p.cutoff != now.AddDate(0, 0, -30).UnixMilli() {
			t.Errorf("metrics: %s", p.query)
		}
	}
}

func TestLocalTime(t *testing.T) {
	rome, err := time.LoadLocation("Europe/Rome")
	if err != nil {
		t.Fatal(err)
	}
	// the night of 29 March 2026: 2:00 CET becomes 3:00 CEST
	before, after := time.Date(2026, 3, 29, 0, 30, 0, 0, time.UTC), time.Date(2026, 3, 29, 1, 30, 0, 0, time.UTC)
	for _, c := range []struct {
		t    time.Time
		zone *time.Location
		want string
	}{{before, time.UTC, "2026-03-29 00:30"}, {after, time.UTC, "2026-03-29 01:30"}, {before, rome, "2026-03-29 01:30"}, {after, rome, "2026-03-29 03:30"}} {
		if got := formatTime(c.t, c.zone); got != c.want {
			t.Errorf("%v in %v: %s", c.t, c.zone, got)
		}
	}
	if whenIn(time.Time{}, rome) != "never" {
		t.Error("zero time")
	}
	for _, c := range []struct{ adminTZ, tz, want string }{
		{"", "", "UTC"}, {"Europe/Rome", "", "Europe/Rome"}, {"", "Europe/Rome", "Europe/Rome"},
		{"America/New_York", "Europe/Rome", "America/New_York"}, {"Mars/Olympus", "", "UTC"}, {"../../etc/passwd", "", "UTC"},
	} {
		t.Setenv("ADMIN_TZ", c.adminTZ)
		t.Setenv("TZ", c.tz)
		if got := loadZone().String(); got != c.want {
			t.Errorf("ADMIN_TZ=%q TZ=%q: %s", c.adminTZ, c.tz, got)
		}
	}

	// the pages say it once, the alerts too
	defer func(z *time.Location) { adminZone = z }(adminZone)
	adminZone = rome
	var b strings.Builder
	if err := templates.ExecuteTemplate(&b, "user.html", map[string]any{"CSRF": "x", "UID": "alice", "SyncUser": &SyncUser{UID: "alice", CreatedAt: after}}); err != nil {
		t.Fatal(err)
	}
	if page := b.String(); strings.Count(page, "Times in Europe/Rome") != 1 || !strings.Contains(page, "Syncing since 2026-03-29 03:30") || strings.Contains(page, "UTC") {
		t.Errorf("page: %s", page)
	}
	server, _ := newFakeSMTP(t, false, false)
	al := server.alerter(nil)
	al.insecureAuth = true
	al.add("health", "Sync server is down")
	lines := al.take()
	if !strings.HasPrefix(lines[0], formatTime(time.Now(), rome)) {
		t.Errorf("alert time: %q", lines[0])
	}
	if err := al.send(lines); err != nil {
		t.Fatal(err)
	}
	if _, data := server.seen(); strings.Count(data, "Times in Europe/Rome") != 1 {
		t.Errorf("email: %q", data)
	}
}

// pages renders every page with enough data to show its forms
func pages(t *testing.T) map[string]string {
	t.Helper()
	acc := &FxaAccount{UID: fakeUID, Email: fakeEmail, CreatedAt: time.Now()}
	data := map[string]map[string]any{
		"dashboard.html": {"CSRF": "x", "FxA": true, "Sync": &SyncStatus{Users: 1, MaxUsers: 5, Nodes: []SyncNode{{Node: "https://sync.example.com", Users: 1}}}, "MaxUsersEditable": true,
			"Health": []Component{{Name: "Sync server", Up: true}, {Name: "Public Sync URL", Warn: true, Error: "certificate expires in 3 days"}},
			"Schema": []SchemaLevel{{Database: "fxa", Level: "201"}}, "Setup": []setupCheck{{Name: "Sync node", Text: "x"}},
			"SetupMigrations": []SetupStatus{{Scope: "sync", Label: "Sync", Version: 1, Expected: 2, Pending: []string{"002-a-reader"},
				Last: &SetupMigration{Number: 1, Name: "001-sync-and-admin-ui", How: "baseline", At: time.Now()}}, {Scope: "fxa", Label: "accounts", Version: 1, Expected: 1,
				Last: &SetupMigration{Number: 1, How: "containers", At: time.Now()}}},
			"Alerts": map[string]any{"To": "admin@example.com", "Status": SendStatus{}, "Waiting": 0}, "TestEmail": true, "Mailer": true,
			"Notify": []NotifyStatus{{Name: "slack://hooks.slack.com"}},
			"Backup": map[string]any{"Time": "03:00", "Local": "03:00", "Keep": 7, "Quadlets": false, "Accounts": true}, "AccountLimit": Limit{Count: 1, Max: 10}, "MaxAccountsEditable": true,
			"Invited": []allowRow{{Email: "bob@example.net"}}, "Domains": []string{"@example.com"},
			"Policy": &SignupPolicy{Mode: "open"}, "Accounts": []accountRow{{UID: fakeUID, Email: fakeEmail}, {UID: "ff" + fakeUID[2:], Email: "bob@example.com", Disabled: true}},
			"UnconfirmedCount": 1, "PruneLastRan": time.Now(), "Pages": pager{Page: 1, Pages: 2, Total: 60, From: 1, To: 50, Next: "/?page=2#accounts"},
			"Attention": []attention{{Text: "Sync server is down: x.", Href: "#health", Link: "Health"}},
			"Backups": []BackupStatus{{Scope: "sync", Last: BackupRun{OK: true, Finished: time.Now(), Bytes: 2048}, LastOK: BackupRun{OK: true, Finished: time.Now(), Bytes: 2048}},
				{Scope: "accounts", Last: BackupRun{Finished: time.Now(), Error: "access denied"}, LastOK: BackupRun{OK: true, Finished: time.Now().Add(-48 * time.Hour), Bytes: 1024}}},
			"Storage": &StorageReport{Orphans: []Orphan{{Kind: orphanDeleted, Account: "ab", Email: "ab@api.example.com", Storage: []int64{4, 5}}}, Expired: Usage{Items: 1},
				OtherDomains: []OtherDomain{{Email: "cd@old.example.com", Rows: 1}}, Top: []TopAccount{{UID: fakeUID, Email: fakeEmail}}, DataFree: 1 << 20, Accounts: true}},
		"connect.html": {"CSRF": "x", "FxA": true, "Content": "https://accounts.example.com", "Node": "https://sync.example.com", "Signup": "https://accounts.example.com/signup",
			"Setups": deviceSteps("https://accounts.example.com", "https://sync.example.com", "")},
		"user.html": {"CSRF": "x", "FxA": true, "UID": fakeUID, "Account": acc, "Devices": []Device{{ID: "d1", Name: "Firefox"}}, "Sessions": []Session{{Ref: fakeRef}},
			"SyncUser": &SyncUser{UID: fakeUID}, "Collections": []CollectionUsage{{Name: "bookmarks"}}, "Storage": true, "Security": &Security{},
			"Rows": []UserRow{{ID: 4, ClientState: "aa", ReplacedAt: time.Now()}, {ID: 5, ClientState: "bb", Current: true, NodeKnown: true}}, "Flags": []Flag{{"Node retired", "x"}}},
		"activity.html": {"CSRF": "x", "Range": "24h", "Ranges": []string{"24h"}, "Kinds": eventKinds, "Received": time.Time{}, "Since": time.Now(),
			"Events": []Event{{At: time.Now(), Kind: "admin", Detail: "x"}}, "Older": int64(5), "Paged": true, "Q": "x",
			"FxA": true, "Jobs": []jobRow{{Job{Name: "prune", Result: "x"}, true}, {Job{Name: "purge"}, false}}},
		"security.html": {"CSRF": "x", "FxA": true, "Blocks": []Block{{Key: "k"}}},
		"config.html": {"CSRF": "x", "FxA": true, "Hints": []attention{{Text: "x", Href: "#public", Link: "Public URLs"}},
			"Groups": []configGroup{{ID: "public", Title: "Public URLs", Rows: []configRow{{Setting: "Sync server", Value: "https://sync.example.com", Vars: []string{"SYNCSTORAGE_DOMAIN"}}}}}},
		"login.html":    {"Password": true, "OIDC": "Dex"},
		"continue.html": {},
		"error.html":    {"Code": 404, "Text": "404 page not found", "CSRF": "x", "FxA": true},
		"confirm.html": {"CSRF": "x", "FxA": true, "Account": acc, "Name": acc.Email, "Post": "/x", "Back": "/users/x", "MaxReason": maxReason,
			"Action":  confirmAction{Title: "Delete", Button: "Delete", TypeEmail: true, Checks: []confirmCheck{{"free_slot", "x"}}, Hidden: map[string]string{"collection": "tabs"}},
			"Devices": []Device{{ID: "d1", Name: "Firefox"}}, "Rows": []UserRow{{ID: 4}}, "Orphans": []Orphan{{Kind: orphanNoRow, Storage: []int64{9}}},
			"Unconfirmed": []FxaAccount{{Email: "x@example.com"}}},
	}
	out := map[string]string{}
	files, _ := assets.ReadDir("templates")
	for _, f := range files {
		if f.Name() == "layout.html" {
			continue
		}
		d, ok := data[f.Name()]
		if !ok {
			t.Fatalf("no test data for %s", f.Name())
		}
		var b strings.Builder
		if err := templates.ExecuteTemplate(&b, f.Name(), d); err != nil {
			t.Fatalf("%s: %v", f.Name(), err)
		}
		out[f.Name()] = b.String()
	}
	return out
}

func TestPagesForPhonesAndScreenReaders(t *testing.T) {
	controls := regexp.MustCompile(`<(input|select|textarea)\b[^>]*>`)
	id := regexp.MustCompile(`\bid="([^"]+)"`)
	for name, page := range pages(t) {
		if !strings.Contains(page, `<meta name="viewport" content="width=device-width, initial-scale=1">`) {
			t.Errorf("%s: no viewport", name)
		}
		// every control has a label: label for= its id, or around it
		for _, loc := range controls.FindAllStringIndex(page, -1) {
			tag := page[loc[0]:loc[1]]
			if strings.Contains(tag, `type="hidden"`) {
				continue
			}
			before := page[:loc[0]]
			inLabel := strings.LastIndex(before, "<label") > strings.LastIndex(before, "</label>")
			m := id.FindStringSubmatch(tag)
			if !inLabel && (m == nil || !strings.Contains(page, `<label for="`+m[1]+`"`)) {
				t.Errorf("%s: no label for %s", name, tag)
			}
		}
		// tables have a name, and scroll in their box on narrow screens
		for _, table := range regexp.MustCompile(`<table\b[^>]*>`).FindAllString(page, -1) {
			if !strings.Contains(table, "aria-label") {
				t.Errorf("%s: %s without a name", name, table)
			}
		}
		if n := strings.Count(page, "<table"); n != strings.Count(page, `<div class="scroll"><table`) {
			t.Errorf("%s: tables outside a scroll box", name)
		}
		if strings.Contains(page, "<script") || strings.Contains(page, " style=") || strings.Contains(page, " onclick") {
			t.Errorf("%s: inline script or style", name)
		}
	}
}

func TestNoDestructiveFormInTheLists(t *testing.T) {
	p := pages(t)
	list := p["dashboard.html"]
	if strings.Contains(list, `action="/accounts/`+fakeUID+`/disable"`) || !strings.Contains(list, `href="/accounts/`+fakeUID+`/disable"`) {
		t.Errorf("accounts list: %s", list)
	}
	// enabling is not destructive: one click
	if !strings.Contains(list, `action="/accounts/ff`+fakeUID[2:]+`/enable"`) {
		t.Error("no enable form")
	}
	for _, link := range []string{`href="/storage/purge"`, `href="/accounts/unconfirmed"`} {
		if !strings.Contains(list, link) || strings.Contains(list, strings.Replace(link, "href=", "action=", 1)) {
			t.Errorf("overview: %s", link)
		}
	}
	user := p["user.html"]
	for _, form := range []string{"/disable", "/sign-out-all", "/devices/d1/sign-out", "/sessions/" + fakeRef + "/sign-out", "/reset-sync", "/reset-sync?collection=bookmarks"} {
		if strings.Contains(user, `action="/accounts/`+fakeUID+form+`"`) || strings.Contains(user, `action="/users/`+fakeUID+form+`"`) {
			t.Errorf("user page posts %s in one click", form)
		}
		if !strings.Contains(user, form+`"`) {
			t.Errorf("user page without a link to %s", form)
		}
	}
	if !strings.Contains(user, `href="/activity?q=alice%40example.com"`) {
		t.Error("no link to the events of the account")
	}
	if c := p["confirm.html"]; !strings.Contains(c, `<label for="confirm_email">`) || !strings.Contains(c, `href="/users/x" id="cancel">Cancel</a>`) {
		t.Errorf("confirm page: %s", c)
	}
}

// fakeRedis answers one command per connection like FxA's Redis: EVAL with the number
// of access tokens revoked (and on got), GET with no such key, the others with 0
func fakeRedis(t *testing.T) (string, chan string) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	got := make(chan string, 10)
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			buf := make([]byte, 4096)
			n, _ := conn.Read(buf)
			switch cmd := string(buf[:n]); {
			case strings.Contains(cmd, "\r\nEVAL\r\n"):
				got <- cmd
				conn.Write([]byte(":0\r\n"))
			case strings.Contains(cmd, "\r\nGET\r\n"):
				conn.Write([]byte("$-1\r\n"))
			case strings.Contains(cmd, "\r\nMGET\r\n"):
				// no cache for any of the keys (*<1 + keys>)
				n, _ := strconv.Atoi(strings.TrimPrefix(strings.SplitN(cmd, "\r\n", 2)[0], "*"))
				conn.Write([]byte(fmt.Sprintf("*%d\r\n%s", n-1, strings.Repeat("$-1\r\n", n-1))))
			default:
				conn.Write([]byte(":0\r\n"))
			}
			conn.Close()
		}
	}()
	return ln.Addr().String(), got
}

func TestConfirmPages(t *testing.T) {
	fake := &fakeFxa{}
	redis, revoked := fakeRedis(t)
	app := testApp()
	app.fxa, app.alerter, app.sync = fake.db(redis), &Alerter{}, &SyncDB{db: sql.OpenDB(fake)}
	h := app.routes()
	c, s := passwordSession(t, app, h)
	app.alerter.take()

	for _, path := range []string{"/accounts/" + fakeUID + "/disable", "/accounts/" + fakeUID + "/sign-out-all",
		"/users/" + fakeUID + "/devices/d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1/sign-out", "/users/" + fakeUID + "/sessions/" + fakeRef + "/sign-out"} {
		w := getPage(h, path, c)
		page := w.Body.String()
		if w.Code != 200 {
			t.Fatalf("%s: %d %s", path, w.Code, page)
		}
		for _, want := range []string{fakeEmail, `<form method="post" action="` + path + `" id="confirm">`, `name="csrf" value="` + s.csrf + `"`,
			`<label for="reason">`, `href="/users/` + fakeUID + `" id="cancel">Cancel</a>`} {
			if !strings.Contains(page, want) {
				t.Errorf("%s: no %q", path, want)
			}
		}
		if strings.Contains(path, "/sessions/") != !strings.Contains(page, "Firefox on laptop") || !strings.Contains(path, "/devices/") != strings.Contains(page, "<td>Linux</td>") {
			t.Errorf("%s: wrong devices or sessions: %s", path, page)
		}
		if !strings.Contains(w.Header().Get("Content-Security-Policy"), "default-src 'none'") {
			t.Errorf("%s: CSP", path)
		}
	}
	// pages only: nothing changed, no event
	if got := fake.statements(); len(got) != 0 {
		t.Errorf("a GET changed something: %q", got)
	}
	for _, path := range []string{"/accounts/" + fakeUID + "/delete-everything", "/accounts/nothex/disable", "/users/" + fakeUID + "/devices/0000/sign-out"} {
		if w := getPage(h, path, c); w.Code != 404 {
			t.Errorf("%s: %d", path, w.Code)
		}
	}

	// the form needs the session's token
	if w := post(h, "/accounts/"+fakeUID+"/disable", url.Values{"reason": {"x"}}, c, nil); w.Code != http.StatusForbidden {
		t.Errorf("without CSRF: %d", w.Code)
	}
	if got := fake.statements(); len(got) != 0 {
		t.Errorf("changed without the token: %q", got)
	}
	w := post(h, "/accounts/"+fakeUID+"/disable", url.Values{"csrf": {s.csrf}, "reason": {"lost laptop"}, "back": {"/users/" + fakeUID}}, c, nil)
	if w.Code != http.StatusSeeOther || w.Header().Get("Location") != "/users/"+fakeUID || s.message != "Disabled alice@example.com (uid 0123abcd)" {
		t.Errorf("disable: %d %s %q %q", w.Code, w.Header().Get("Location"), s.message, s.failed)
	}
	// and the reason into the note
	if got := fake.statements(); len(got) != 2 || got[0] != "CALL ffs.disable_account(?)" || !strings.HasPrefix(got[1], "INSERT INTO ffs_account_notes") ||
		fake.args[1][1] != "lost laptop" {
		t.Errorf("disable: %q %q", got, fake.args)
	}
	if cmd := <-revoked; !strings.Contains(cmd, "at:"+fakeUID) || !strings.Contains(cmd, "rt:"+fakeUID) || !strings.Contains(cmd, "fxa-auth-session"+fakeUID) {
		t.Errorf("Redis: %q", cmd)
	}
	lines := alerts(t, app.alerter, 1)
	if len(lines) != 1 || !strings.HasSuffix(lines[0], "admin: Disabled alice@example.com (uid 0123abcd) by admin (password): lost laptop") {
		t.Errorf("alerts: %q", lines)
	}
	// a back elsewhere is ignored
	w = post(h, "/accounts/"+fakeUID+"/sign-out-all", url.Values{"csrf": {s.csrf}, "back": {"//evil.example/"}}, c, nil)
	if w.Header().Get("Location") != "/users/"+fakeUID || s.message != "Signed out alice@example.com (uid 0123abcd) everywhere" {
		t.Errorf("sign out everywhere: %s %q %q", w.Header().Get("Location"), s.message, s.failed)
	}
	if got := fake.statements(); len(got) != 3 || got[2] != "CALL ffs.sign_out_all(?)" {
		t.Errorf("sign out everywhere: %q", got)
	}
	w = post(h, "/accounts/"+fakeUID+"/enable", url.Values{"csrf": {s.csrf}, "back": {"/\\evil.example"}}, c, nil)
	if w.Header().Get("Location") != "/" || s.message != "Enabled alice@example.com (uid 0123abcd)" {
		t.Errorf("enable: %s %q", w.Header().Get("Location"), s.message)
	}
}

func TestAdminGrantsChangeNothingDirectly(t *testing.T) {
	// FxA's tables change only through the procedures of fxa-init
	direct := regexp.MustCompile(`(?i)^GRANT .*\b(UPDATE|DELETE|INSERT|ALTER|DROP|ALL)\b.* ON (fxa|fxa_oauth|fxa_profile|pushbox)\.`)
	executes := map[string]bool{}
	for _, g := range fxaAdminGrants[1:] {
		if direct.MatchString(g) {
			t.Errorf("table-level change on FxA: %s", g)
		}
		if m := regexp.MustCompile(`^GRANT EXECUTE ON PROCEDURE (ffs\.\w+) `).FindStringSubmatch(g); m != nil {
			executes[m[1]] = true
		}
	}
	for _, p := range []string{"ffs.disable_account", "ffs.enable_account", "ffs.sign_out_all", "ffs.sign_out_session", "ffs.sign_out_device",
		"ffs.remove_totp", "ffs.remove_recovery_key", "ffs.confirm_email", "ffs.delete_account", "ffs.delete_unconfirmed", "ffs.prune"} {
		if !executes[p] {
			t.Errorf("no EXECUTE on %s", p)
		}
		if !strings.Contains(strings.Join(fxaPolicySQL, "\n"), "CREATE PROCEDURE "+p+"(") {
			t.Errorf("%s not created", p)
		}
	}
	if !strings.HasPrefix(fxaAdminGrants[0], "REVOKE ALL") {
		t.Error("the REVOKE must stay first")
	}
	// every pinned FxA procedure the procedures call is checked at the start
	calls := regexp.MustCompile(`CALL fxa\.(\w+)\(`).FindAllStringSubmatch(strings.Join(fxaPolicySQL, "\n"), -1)
	for _, c := range calls {
		if !strings.Contains(strings.Join(fxaPinnedProcedures, " "), c[1]) {
			t.Errorf("fxa.%s is called but not checked", c[1])
		}
	}
	if len(calls) == 0 {
		t.Error("no FxA procedure called")
	}
}

// FXA_REDIS_PASSWORD (the chart's Redis has one): every connection signs in first, a wrong
// password is an error, without it nothing is sent before the command
func TestRedisPassword(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	got := make(chan string, 10)
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			r := bufio.NewReader(conn)
			for {
				reply, err := readReply(r)
				if err != nil {
					break
				}
				parts, _ := reply.([]any)
				var words []string
				for _, p := range parts {
					s, _ := p.(string)
					words = append(words, s)
				}
				got <- strings.Join(words, " ")
				switch {
				case len(words) == 2 && words[0] == "AUTH" && words[1] == "a b\"c":
					conn.Write([]byte("+OK\r\n"))
				case words[0] == "AUTH":
					conn.Write([]byte("-WRONGPASS invalid username-password pair or user is disabled.\r\n"))
				default:
					conn.Write([]byte("+PONG\r\n"))
				}
			}
			conn.Close()
		}
	}()
	ping := func() error {
		conn, err := dialRedis(context.Background(), ln.Addr().String())
		if err != nil {
			return err
		}
		defer conn.Close()
		_, err = conn.Do("PING")
		return err
	}
	t.Setenv("FXA_REDIS_PASSWORD", "a b\"c")
	if err := ping(); err != nil || <-got != "AUTH a b\"c" || <-got != "PING" {
		t.Errorf("with the password: %v", err)
	}
	t.Setenv("FXA_REDIS_PASSWORD", "wrong")
	if err := ping(); err == nil || !strings.Contains(err.Error(), "WRONGPASS") {
		t.Errorf("a wrong password: %v", err)
	}
	<-got
	t.Setenv("FXA_REDIS_PASSWORD", "")
	if err := ping(); err != nil || <-got != "PING" {
		t.Errorf("without a password: %v", err)
	}
	if !configVars["FXA_REDIS_PASSWORD"] {
		t.Error("FXA_REDIS_PASSWORD is not a secret of the configuration page")
	}
}
