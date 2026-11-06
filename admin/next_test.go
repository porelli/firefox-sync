package main

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

var openRedirects = []string{
	"//evil.com", "/\\evil.com", "https://evil.com", "http://evil.com/x", "/%2F%2Fevil.com", "/%2f%2fevil.com", "/%5Cevil.com",
	"/activity\r\nSet-Cookie: x=y", "/activity%0d%0aSet-Cookie:x", "/activity?q=%0d%0a", "evil.com", "javascript:alert(1)", " /activity",
	"/activity#x", "/./activity", "/a/../activity", "/login", "/login?next=/activity", "/logout", "/auth/login", "/auth/callback?state=x",
	"/static/style.css", "/healthz", "/metrics", "/activity\x00", "/actïvity", "/" + strings.Repeat("a", maxNext),
}

func TestSafeNext(t *testing.T) {
	for _, bad := range append(openRedirects, "", "/") {
		if got := safeNext(bad); got != "" {
			t.Errorf("safeNext(%q) = %q", bad, got)
		}
	}
	for _, ok := range []string{"/activity", "/activity?range=7d&kind=admin", "/users/0123abcd", "/users/0123abcd/delete", "/find?q=a%40b.example", "/loginx", "/security"} {
		if got := safeNext(ok); got != ok {
			t.Errorf("safeNext(%q) = %q", ok, got)
		}
	}
}

func location(w *httptest.ResponseRecorder) string { return w.Header().Get("Location") }

func nextOf(t *testing.T, loc string) (string, url.Values) {
	t.Helper()
	u, err := url.Parse(loc)
	if err != nil {
		t.Fatal(err)
	}
	return u.Path, u.Query()
}

func TestNextThroughPasswordSignIn(t *testing.T) {
	app := testApp()
	h := app.routes()
	// a refresh with no session: to the login page, with the page
	w := get(h, "/activity?range=7d&kind=admin", "192.0.2.1:1", nil, nil)
	p, q := nextOf(t, location(w))
	if w.Code != http.StatusSeeOther || p != "/login" || q.Get("next") != "/activity?range=7d&kind=admin" {
		t.Fatalf("GET without a session: %d %s", w.Code, location(w))
	}
	page := get(h, location(w), "192.0.2.1:1", nil, nil).Body.String()
	if !strings.Contains(page, `<input type="hidden" name="next" value="/activity?range=7d&amp;kind=admin">`) || !strings.Contains(page, "Sign in to continue to Activity.") {
		t.Errorf("login page: %s", page)
	}
	// a wrong password keeps the page
	w = post(h, "/login", url.Values{"password": {"wrong"}, "next": {"/activity?range=7d"}}, nil, nil)
	if p, q := nextOf(t, location(w)); p != "/login" || q.Get("error") != "password" || q.Get("next") != "/activity?range=7d" {
		t.Errorf("failed sign-in: %s", location(w))
	}
	w = post(h, "/login", url.Values{"password": {"correct horse battery"}, "next": {"/activity?range=7d"}}, nil, nil)
	if w.Code != http.StatusSeeOther || location(w) != "/activity?range=7d" || sessionCookieOf(w) == nil {
		t.Errorf("sign-in: %d %s", w.Code, location(w))
	}
	// the dashboard needs no next: /login as before
	if w := get(h, "/", "192.0.2.1:1", nil, nil); location(w) != "/login" {
		t.Errorf("GET /: %s", location(w))
	}
	if w := post(h, "/login", url.Values{"password": {"correct horse battery"}}, nil, nil); location(w) != "/" {
		t.Errorf("no next: %s", location(w))
	}
}

func TestNextOpenRedirectsRefused(t *testing.T) {
	app := testApp()
	h := app.routes()
	for _, bad := range openRedirects {
		app.failures = nil
		w := post(h, "/login", url.Values{"password": {"correct horse battery"}, "next": {bad}}, nil, nil)
		if location(w) != "/" {
			t.Errorf("sign-in with next %q: %s", bad, location(w))
		}
		w = post(h, "/login", url.Values{"password": {"wrong"}, "next": {bad}}, nil, nil)
		if location(w) != "/login?error=password" {
			t.Errorf("failed sign-in with next %q: %s", bad, location(w))
		}
		page := get(h, "/login?next="+url.QueryEscape(bad), "192.0.2.1:1", nil, nil).Body.String()
		if strings.Contains(page, `name="next"`) || strings.Contains(page, "continue to") {
			t.Errorf("login page with next %q: %s", bad, page)
		}
	}
}

func TestNextThroughOIDC(t *testing.T) {
	f := newFakeProvider(t)
	f.claims = map[string]any{"email": "alice@example.com", "email_verified": true}
	_, h := oidcApp(t, f)
	page := get(h, "/login?next="+url.QueryEscape("/security?x=1"), "192.0.2.1:1", nil, nil).Body.String()
	if !strings.Contains(page, `href="/auth/login?next=%2fsecurity%3fx%3d1"`) {
		t.Fatalf("login page: %s", page)
	}
	// the provider never sees the page: it is in the cookie, bound to the state
	w := get(h, "/auth/login?next=%2fsecurity%3fx%3d1", "192.0.2.1:1", nil, nil)
	if strings.Contains(strings.ToLower(location(w)), "security") {
		t.Errorf("next sent to the provider: %s", location(w))
	}
	callback, state := f.startAt(t, h, "/auth/login?next=%2fsecurity%3fx%3d1")
	if !strings.Contains(state.Value, "~") || !state.HttpOnly {
		t.Errorf("state cookie %+v", state)
	}
	w = get(h, callback, "192.0.2.1:1", nil, state)
	if sessionCookieOf(w) == nil || !strings.Contains(w.Body.String(), `content="0;url=/security?x=1"`) || !strings.Contains(w.Body.String(), `<a href="/security?x=1">Continue</a>`) {
		t.Errorf("callback: %d %s", w.Code, w.Body)
	}

	// a cookie of another page: its MAC does not match, the dashboard
	callback, state = f.startAt(t, h, "/auth/login?next=%2fsecurity")
	parts := strings.Split(state.Value, "~")
	st, sum := parts[0], parts[2]
	forged := &http.Cookie{Name: stateCookie, Value: st + "~" + "Ly9ldmlsLmNvbQ" + "~" + sum} // //evil.com
	w = get(h, callback, "192.0.2.1:1", nil, forged)
	if !signedIn(t, w) || strings.Contains(w.Body.String(), "evil") {
		t.Errorf("forged next: %s", w.Body)
	}

	// open redirects never make it into the cookie
	for _, bad := range openRedirects {
		w := get(h, "/auth/login?next="+url.QueryEscape(bad), "192.0.2.1:1", nil, nil)
		for _, c := range w.Result().Cookies() {
			if c.Name == stateCookie && strings.Contains(c.Value, "~") {
				t.Errorf("next %q in the state cookie", bad)
			}
		}
	}

	// a refused sign-in keeps the page for another try
	f.claims = map[string]any{"email": "mallory@example.net", "email_verified": true}
	callback, state = f.startAt(t, h, "/auth/login?next=%2fconfig")
	w = get(h, callback, "192.0.2.1:1", nil, state)
	if p, q := nextOf(t, location(w)); p != "/login" || q.Get("error") != "sso" || q.Get("next") != "/config" {
		t.Errorf("refused: %d %s", w.Code, location(w))
	}
}

func TestFormAfterSessionLoss(t *testing.T) {
	app := testApp()
	sent := 0
	h := http.NewServeMux()
	h.Handle("/", app.routes())
	h.HandleFunc("POST /users/{uid}/counted", app.authenticated(func(w http.ResponseWriter, r *http.Request, s *session) { sent++ }))
	c, s := passwordSession(t, app, h)
	// the admin UI restarts: the sessions are gone, the browser still has its cookie
	app.mu.Lock()
	app.sessions = map[string]*session{}
	app.mu.Unlock()
	form := func(path string, headers map[string]string) *httptest.ResponseRecorder {
		hd := map[string]string{"Accept": "text/html,application/xhtml+xml", "Origin": "https://admin.example.com"}
		for k, v := range headers {
			hd[k] = v
		}
		return post(h, path, url.Values{"csrf": {s.csrf}, "note": {"x"}}, c, hd)
	}
	w := form("/users/ab12/counted", map[string]string{"Referer": "https://admin.example.com/users/ab12?tab=devices"})
	p, q := nextOf(t, location(w))
	if w.Code != http.StatusSeeOther || p != "/login" || q.Get("next") != "/users/ab12?tab=devices" || q.Get("ended") != "form" || sent != 0 {
		t.Errorf("form after a restart: %d %s, sent %d", w.Code, location(w), sent)
	}
	page := get(h, location(w), "192.0.2.1:1", nil, nil).Body.String()
	if !strings.Contains(page, "Your session ended (the admin UI restarted or you were away): sign in again; the form was not sent.") ||
		!strings.Contains(page, "Sign in to continue to the account ab12.") {
		t.Errorf("login page: %s", page)
	}
	// signing in goes back to the page, the form is not sent again
	w = post(h, "/login", url.Values{"password": {"correct horse battery"}, "next": {q.Get("next")}}, nil, nil)
	if location(w) != "/users/ab12?tab=devices" || sent != 0 {
		t.Errorf("after the sign-in: %s, sent %d", location(w), sent)
	}
	app.sessions = map[string]*session{}

	// a Referer of another site, a bad one, none: the page of the form when there is one
	for _, tc := range []struct{ path, referer, next string }{
		{"/users/ab12/delete", "https://evil.example/users/x", "/users/ab12/delete"},
		{"/users/ab12/delete", "https://admin.example.com//evil.com", "/users/ab12/delete"},
		{"/users/ab12/note", "", "/users/ab12"},
		{"/security/unblock", "", "/security"},
		{"/health/check", "", ""},
		{"/sync/max-users", "https://admin.example.com/", ""},
	} {
		w := form(tc.path, map[string]string{"Referer": tc.referer})
		if p, q := nextOf(t, location(w)); w.Code != http.StatusSeeOther || p != "/login" || q.Get("next") != tc.next || q.Get("ended") != "form" {
			t.Errorf("%s (Referer %q): %d %s", tc.path, tc.referer, w.Code, location(w))
		}
	}
	// signing out with no session: just the login page
	if w := form("/logout", nil); location(w) != "/login" {
		t.Errorf("logout: %s", location(w))
	}
	// scripts (no text/html) get the status as before
	if w := post(h, "/users/ab12/counted", url.Values{"csrf": {s.csrf}}, c, nil); w.Code != http.StatusUnauthorized || sent != 0 {
		t.Errorf("script: %d", w.Code)
	}
}

func TestHeaderSignInServesThePage(t *testing.T) {
	_, h := headerApp(t)
	// the proxy's header signs in on the request itself: the page, no redirect
	w := get(h, "/whoami", "10.1.2.3:4567", map[string][]string{"Remote-Email": {"alice@example.com"}, "Accept": {"text/html"}}, nil)
	if w.Code != 200 || w.Body.String() != "alice@example.com header" {
		t.Errorf("header: %d %s", w.Code, location(w))
	}
	// and its login page continues to the page
	page := get(h, "/login?next=%2Factivity", "10.1.2.3:4567", map[string][]string{"Remote-Email": {"alice@example.com"}}, nil).Body.String()
	if !strings.Contains(page, `Signed in by your proxy as alice@example.com. <a href="/activity">Continue</a>`) {
		t.Errorf("login page: %s", page)
	}
}
