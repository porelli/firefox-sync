package main

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

func TestSMTPCheckNeverSendsMail(t *testing.T) {
	for _, c := range []struct {
		name               string
		starttls, implicit bool
		want               string
	}{{"STARTTLS", true, false, "EHLO STARTTLS EHLO AUTH QUIT"}, {"implicit TLS", false, true, "EHLO AUTH QUIT"}} {
		server, pool := newFakeSMTP(t, c.starttls, c.implicit)
		m := server.alerter(pool).Mailer
		m.implicitTLS = c.implicit
		if err := m.check(5 * time.Second); err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		if commands, data := server.seen(); strings.Join(commands, " ") != c.want || data != "" {
			t.Errorf("%s: %v %q", c.name, commands, data)
		}
	}
}

func TestSMTPCheckWrongPassword(t *testing.T) {
	server, pool := newFakeSMTP(t, true, false)
	server.authFail = true
	m := server.alerter(pool).Mailer
	err := m.check(5 * time.Second)
	if err == nil || !strings.Contains(err.Error(), "535") {
		t.Fatalf("wrong password: %v", err)
	}
	if commands, _ := server.seen(); strings.Contains(strings.Join(commands, " "), "MAIL") {
		t.Errorf("MAIL sent: %v", commands)
	}
	// and an email does not go out either
	if err := m.send("admin@example.com", "x", "x", 5*time.Second); err == nil {
		t.Error("sent with a wrong password")
	}
	if commands, _ := server.seen(); strings.Contains(strings.Join(commands, " "), "MAIL") {
		t.Errorf("MAIL after a failed AUTH: %v", commands)
	}
}

// smtpEnv points SMTP_* to the fake server (plain text, the password allowed in clear)
func smtpEnv(t *testing.T, server *fakeSMTP) {
	_, port, _ := net.SplitHostPort(server.ln.Addr().String())
	for k, v := range map[string]string{"SMTP_HOST": "127.0.0.1", "SMTP_PORT": port, "SMTP_USER": "mailer", "SMTP_PASS": "secret",
		"SMTP_INSECURE_AUTH": "1", "SMTP_SENDER": "ffs <ffs@example.com>", "ADMIN_PUBLIC_CHECK": "0", "FXA_OAUTH_SERVER_URL": ""} {
		t.Setenv(k, v)
	}
}

func TestSMTPHealthRow(t *testing.T) {
	server, _ := newFakeSMTP(t, false, false)
	server.authFail = true
	smtpEnv(t, server)
	alerter := &Alerter{}
	h := newHealth(&App{alerter: alerter})
	var smtp *check
	for i := range h.checks {
		if h.checks[i].name == "Email (SMTP)" {
			smtp = &h.checks[i]
		}
	}
	if smtp == nil || smtp.every != time.Hour {
		t.Fatalf("no hourly SMTP check: %+v", h.checks)
	}
	// past the startup grace: the failure is a failure (startup_test.go has the grace)
	h.checks, h.grace = []check{*smtp}, 0
	h.checkAll(context.Background())
	comps := h.Components()
	if len(comps) != 1 || comps[0].Up || !strings.Contains(comps[0].Error, "535") {
		t.Fatalf("wrong password: %+v", comps)
	}
	if lines := alerter.take(); len(lines) != 1 || !strings.Contains(lines[0], "health: Email (SMTP) is down: 535") {
		t.Errorf("alerts: %q", lines)
	}
	// not again before the retry, then up
	server.authFail = false
	h.checkAll(context.Background())
	if h.Components()[0].Up {
		t.Error("checked again before the retry")
	}
	if next := h.nextRun["Email (SMTP)"]; next.Sub(time.Now()) < 9*time.Minute {
		t.Errorf("SMTP again at %v, not in 10 minutes", next)
	}
	h.nextRun["Email (SMTP)"] = time.Now().Add(-time.Second)
	h.checkAll(context.Background())
	if c := h.Components()[0]; !c.Up || c.Detail != "127.0.0.1:"+smtpPort(server)+", signs in as mailer" {
		t.Errorf("back up: %+v", c)
	}
	if commands, _ := server.seen(); strings.Contains(strings.Join(commands, " "), "MAIL") {
		t.Errorf("MAIL sent by the health check: %v", commands)
	}
	// without SMTP_HOST, or with the placeholder of .env-example: no row
	for _, host := range []string{"", "<REPLACE_WITH_YOUR_SMTP_SERVER>"} {
		t.Setenv("SMTP_HOST", host)
		for _, c := range newHealth(&App{}).checks {
			if c.name == "Email (SMTP)" {
				t.Errorf("SMTP check with SMTP_HOST=%q", host)
			}
		}
	}
}

func smtpPort(s *fakeSMTP) string {
	_, port, _ := net.SplitHostPort(s.ln.Addr().String())
	return port
}

func TestAlertsWaitForTheSMTPServer(t *testing.T) {
	al := &Alerter{}
	al.add("health", "Email (SMTP) is down: 535")
	al.take()
	al.record(context.DeadlineExceeded)
	al.requeue()
	al.add("health", "Sync server is down")
	if st := al.Status(); st.Err == "" || !st.LastOK.IsZero() || al.Waiting() != 2 {
		t.Errorf("status %+v, %d waiting", st, al.Waiting())
	}
	again := al.take()
	if len(again) != 2 || !strings.HasSuffix(again[0], "Email (SMTP) is down: 535") {
		t.Errorf("requeued: %q", again)
	}
	al.record(nil)
	if st := al.Status(); st.Err != "" || st.LastOK.IsZero() {
		t.Errorf("sent: %+v", st)
	}
}

// while the SMTP server fails, refused sign-ups (from anybody) cannot fill the queue:
// each kind keeps its newest lines, and what is left out is counted by kind
func TestRequeueKeepsEveryKind(t *testing.T) {
	al := &Alerter{}
	for round := 0; round < 20; round++ {
		for i := 0; i < 2*maxAlertsPerKind; i++ {
			al.add("sign-up refused", fmt.Sprintf("round %d mallory%d@example.org", round, i))
		}
		if round == 5 {
			al.add("health", "Sync server is down")
		}
		if round == 15 {
			al.add("health", "Sync server is back up")
		}
		al.take()
		al.requeue()
	}
	lines := al.take()
	text := strings.Join(lines, "\n")
	refused := strings.Count(text, "sign-up refused: round")
	if refused != maxAlertsPerKind || !strings.Contains(text, "sign-up refused: round 19 mallory19@") || strings.Contains(text, "round 18 ") {
		t.Errorf("%d refused sign-ups kept, not the newest: %s", refused, text)
	}
	if !strings.Contains(text, "health: Sync server is down") || !strings.Contains(text, "health: Sync server is back up") {
		t.Errorf("health lost: %s", text)
	}
	// 20 rounds of 40, 20 kept
	if want := fmt.Sprintf("%d more sign-up refused", 20*2*maxAlertsPerKind-maxAlertsPerKind); !strings.Contains(text, want) || strings.Contains(text, "unsent") {
		t.Errorf("want %q: %s", want, text)
	}
	// sent: nothing comes back
	al.add("health", "x")
	if lines := al.take(); len(lines) != 1 {
		t.Errorf("%q", lines)
	}
}

func TestTestEmail(t *testing.T) {
	server, _ := newFakeSMTP(t, false, false)
	smtpEnv(t, server)
	app := testApp()
	app.mailer = newMailer("")
	app.alerter = &Alerter{to: "alerts@example.com"}
	h := app.routes()
	c, s := passwordSession(t, app, h)
	app.alerter.take()
	// the address of the form is never used
	w := post(h, "/alerts/test", url.Values{"csrf": {s.csrf}, "to": {"victim@example.org"}}, c, nil)
	if w.Code != http.StatusSeeOther || !strings.HasPrefix(s.message, "Sent a test email to alerts@example.com") {
		t.Fatalf("%d %q %q", w.Code, s.message, s.failed)
	}
	server.mu.Lock()
	rcpts := strings.Join(server.rcpts, " ")
	server.mu.Unlock()
	if rcpts != "TO:<alerts@example.com>" {
		t.Errorf("sent to %s", rcpts)
	}
	if st := app.alerter.Status(); st.LastOK.IsZero() {
		t.Error("last send not recorded")
	}
	if lines := alerts(t, app.alerter, 1); len(lines) != 1 || !strings.Contains(lines[0], "admin: Sent a test email to alerts@example.com by admin (password)") {
		t.Errorf("event: %q", lines)
	}
	// the SMTP server's error in the flash, and in the audit trail
	server.authFail = true
	post(h, "/alerts/test", url.Values{"csrf": {s.csrf}}, c, nil)
	if !strings.Contains(s.failed, "535") || !strings.Contains(s.failed, "authentication failed") {
		t.Errorf("flash: %q", s.failed)
	}
	if lines := alerts(t, app.alerter, 1); len(lines) != 1 || !strings.Contains(lines[0], "Tried a test email to alerts@example.com") {
		t.Errorf("event: %q", lines)
	}
	if !strings.Contains(prometheusText(t, app), "ffs_alert_last_success_timestamp_seconds 1") {
		t.Error("no ffs_alert_last_success_timestamp_seconds")
	}
	// without ADMIN_ALERT_EMAIL: the admin of single sign-on, nobody with the password
	server.authFail = false
	app.alerter = nil
	post(h, "/alerts/test", url.Values{"csrf": {s.csrf}}, c, nil)
	if !strings.Contains(s.failed, "no address for a test email") {
		t.Errorf("password: %q", s.failed)
	}
	s.method, s.user = "oidc", "bob@example.com"
	post(h, "/alerts/test", url.Values{"csrf": {s.csrf}}, c, nil)
	if !strings.HasPrefix(s.message, "Sent a test email to bob@example.com") {
		t.Errorf("oidc: %q %q", s.message, s.failed)
	}
}

func prometheusText(t *testing.T, app *App) string {
	t.Helper()
	t.Setenv("METRICS_TOKEN", "token")
	if app.sync == nil {
		app.sync = &SyncDB{db: (&fakeFxa{}).db("").db}
	}
	if app.rec == nil {
		app.rec = &Recorder{db: app.sync, current: map[string]*metric{}, cumulative: map[string]*metric{}}
	}
	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	req.Header.Set("Authorization", "Bearer token")
	w := httptest.NewRecorder()
	app.prometheus(w, req)
	return w.Body.String()
}
