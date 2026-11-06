package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/go-jose/go-jose/v4"
)

var testPassword = sha256.Sum256([]byte("correct horse battery"))

var authVars = []string{"ADMIN_PASSWORD", "ADMIN_INSECURE_COOKIE", "ADMIN_OIDC_ISSUER", "ADMIN_OIDC_CLIENT_ID", "ADMIN_OIDC_CLIENT_SECRET",
	"ADMIN_OIDC_REDIRECT_URL", "ADMIN_OIDC_SCOPES", "ADMIN_OIDC_NAME", "ADMIN_OIDC_GROUPS_CLAIM", "ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL",
	"ADMIN_AUTH_HEADER", "ADMIN_AUTH_GROUPS_HEADER", "ADMIN_TRUSTED_PROXIES", "ADMIN_ALLOWED_USERS", "ADMIN_ALLOWED_GROUPS", "FXA_CONTENT_URL"}

// setAuthEnv clears every sign-in variable (env treats "" as unset), then sets vars
func setAuthEnv(t *testing.T, vars map[string]string) {
	for _, name := range authVars {
		t.Setenv(name, vars[name])
	}
}

func TestAuthConfig(t *testing.T) {
	oidcVars := map[string]string{"ADMIN_OIDC_ISSUER": "https://accounts.example.com", "ADMIN_OIDC_CLIENT_ID": "abc",
		"ADMIN_OIDC_REDIRECT_URL": "https://admin.example.com/auth/callback", "ADMIN_ALLOWED_USERS": "alice@example.com"}
	with := func(base map[string]string, kv ...string) map[string]string {
		m := map[string]string{}
		for k, v := range base {
			m[k] = v
		}
		for i := 0; i < len(kv); i += 2 {
			m[kv[i]] = kv[i+1]
		}
		return m
	}
	headerVars := map[string]string{"ADMIN_AUTH_HEADER": "Remote-Email", "ADMIN_TRUSTED_PROXIES": "10.0.0.0/8, 192.0.2.1", "ADMIN_ALLOWED_GROUPS": "admins"}
	for _, c := range []struct {
		vars map[string]string
		err  string // "" for a valid configuration
	}{
		{map[string]string{}, "no sign-in method"},
		{map[string]string{"ADMIN_PASSWORD": "short"}, "at least 12"},
		{map[string]string{"ADMIN_PASSWORD": "correct horse battery"}, ""},
		{oidcVars, ""},
		{with(oidcVars, "ADMIN_ALLOWED_USERS", ""), "needs ADMIN_ALLOWED_USERS"},
		{with(oidcVars, "ADMIN_ALLOWED_USERS", "", "ADMIN_ALLOWED_GROUPS", "admins"), ""},
		{with(oidcVars, "ADMIN_ALLOWED_USERS", "not an email!"), "ADMIN_ALLOWED_USERS"},
		{with(oidcVars, "ADMIN_OIDC_REDIRECT_URL", ""), "needs ADMIN_OIDC_REDIRECT_URL"},
		{with(oidcVars, "ADMIN_OIDC_REDIRECT_URL", "https://admin.example.com/callback"), "ADMIN_OIDC_REDIRECT_URL must be"},
		{with(oidcVars, "ADMIN_OIDC_REDIRECT_URL", "https://admin.example.com/auth/callback?next=/"), "ADMIN_OIDC_REDIRECT_URL must be"},
		{with(oidcVars, "ADMIN_OIDC_REDIRECT_URL", "/auth/callback"), "ADMIN_OIDC_REDIRECT_URL must be"},
		{with(oidcVars, "ADMIN_OIDC_REDIRECT_URL", "http://admin.example.com/auth/callback"), "ADMIN_INSECURE_COOKIE"},
		{with(oidcVars, "ADMIN_OIDC_REDIRECT_URL", "http://admin.example.com/auth/callback", "ADMIN_INSECURE_COOKIE", "1"), ""},
		{with(oidcVars, "ADMIN_OIDC_REDIRECT_URL", "http://localhost:8090/auth/callback"), ""},
		{with(oidcVars, "ADMIN_OIDC_CLIENT_ID", ""), "needs ADMIN_OIDC_CLIENT_ID"},
		{with(oidcVars, "ADMIN_OIDC_ISSUER", "accounts.example.com"), "ADMIN_OIDC_ISSUER"},
		{with(oidcVars, "ADMIN_OIDC_ISSUER", ""), "ADMIN_OIDC_ISSUER is not"},
		{with(oidcVars, "ADMIN_OIDC_SCOPES", "email profile"), "openid"},
		{with(oidcVars, "ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL", "yes"), "true or false"},
		{with(oidcVars, "FXA_CONTENT_URL", "https://accounts.example.com"), ""},
		{with(oidcVars, "FXA_CONTENT_URL", "https://accounts.example.com", "ADMIN_OIDC_CLIENT_SECRET", "s3cret"), "needs a public client"},
		{headerVars, ""},
		{with(headerVars, "ADMIN_TRUSTED_PROXIES", ""), "needs ADMIN_TRUSTED_PROXIES"},
		{with(headerVars, "ADMIN_TRUSTED_PROXIES", "10.0.0.0/33"), "not an address or a CIDR"},
		{with(headerVars, "ADMIN_TRUSTED_PROXIES", "proxy.example.com"), "not an address or a CIDR"},
		{with(headerVars, "ADMIN_ALLOWED_GROUPS", ""), "needs ADMIN_ALLOWED_USERS"},
		{with(headerVars, "ADMIN_AUTH_HEADER", "Remote Email"), "not a header name"},
		{with(headerVars, "ADMIN_AUTH_HEADER", ""), "need ADMIN_AUTH_HEADER"},
		{map[string]string{"ADMIN_PASSWORD": "correct horse battery", "ADMIN_AUTH_GROUPS_HEADER": "Remote-Groups"}, "need ADMIN_AUTH_HEADER"},
	} {
		setAuthEnv(t, c.vars)
		_, err := loadAuth()
		if c.err == "" && err != nil || c.err != "" && (err == nil || !strings.Contains(err.Error(), c.err)) {
			t.Errorf("%v: %v, want %q", c.vars, err, c.err)
		}
	}

	setAuthEnv(t, oidcVars)
	a, _ := loadAuth()
	if a.password != nil || a.oidc.name != "single sign-on" || a.oidc.groupsClaim != "groups" || strings.Join(a.oidc.scopes, " ") != "openid email profile" || a.oidc.trustUnverified {
		t.Errorf("defaults: %+v", a.oidc)
	}
	setAuthEnv(t, headerVars)
	a, _ = loadAuth()
	if a.header != "Remote-Email" || len(a.proxies) != 2 || a.proxies[1].String() != "192.0.2.1/32" {
		t.Errorf("header: %q %v", a.header, a.proxies)
	}
}

func TestAllowedUsersAndGroups(t *testing.T) {
	users, _ := ParseAllowlist("alice@example.com, @example.org, kim@kde.org, @kernel.org")
	c := &authConfig{users: users, groups: map[string]bool{"admins": true}}
	for user, want := range map[string]bool{
		"alice@example.com": true, "Alice@Example.COM": true, "bob@example.com": false,
		"bob@example.org": true, "bob@sub.example.org": false, "bob@example.org.evil": false,
		"example.org": false, "@example.org": false, "": false, "a@b@example.org": false,
		// the Kelvin sign, which strings.ToLower folds into k
		"\u212aim@kde.org": false, "kim@\u212ade.org": false, "bob@\u212aernel.org": false, "Kim@KDE.org": true,
	} {
		if got := c.allowed(user, nil); got != want {
			t.Errorf("%q: %v", user, got)
		}
	}
	if !c.allowed("", []string{"devs", "admins"}) || c.allowed("mallory@example.net", []string{"Admins", "devs"}) {
		t.Error("groups")
	}
}

// headerApp signs in with Remote-Email from 10.0.0.0/8, for alice@example.com,
// @example.org and the group admins
func headerApp(t *testing.T) (*App, http.Handler) {
	setAuthEnv(t, map[string]string{"ADMIN_AUTH_HEADER": "remote-email", "ADMIN_AUTH_GROUPS_HEADER": "Remote-Groups", "ADMIN_TRUSTED_PROXIES": "10.0.0.0/8",
		"ADMIN_ALLOWED_USERS": "alice@example.com,@example.org", "ADMIN_ALLOWED_GROUPS": "admins", "ADMIN_PASSWORD": "correct horse battery"})
	auth, err := loadAuth()
	if err != nil {
		t.Fatal(err)
	}
	app := &App{auth: auth, sessions: map[string]*session{}, alerter: &Alerter{}}
	h := http.NewServeMux()
	h.Handle("/", app.routes())
	h.HandleFunc("GET /whoami", app.authenticated(func(w http.ResponseWriter, r *http.Request, s *session) {
		w.Write([]byte(s.user + " " + s.method))
	}))
	return app, h
}

func get(h http.Handler, path, peer string, headers map[string][]string, cookie *http.Cookie) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, "https://admin.example.com"+path, nil)
	req.RemoteAddr = peer
	for k, vs := range headers {
		for _, v := range vs {
			req.Header.Add(k, v)
		}
	}
	if cookie != nil {
		req.AddCookie(cookie)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)
	return w
}

func sessionCookieOf(w *httptest.ResponseRecorder) *http.Cookie {
	for _, c := range w.Result().Cookies() {
		if c.Name == sessionCookie && c.MaxAge > 0 {
			return c
		}
	}
	return nil
}

func TestHeaderAuthTrustedPeersOnly(t *testing.T) {
	app, h := headerApp(t)
	alice := map[string][]string{"Remote-Email": {"Alice@example.com"}}
	for _, peer := range []string{"10.1.2.3:4567", "[::ffff:10.1.2.3]:4567"} {
		if w := get(h, "/whoami", peer, alice, nil); w.Code != 200 || w.Body.String() != "alice@example.com header" {
			t.Errorf("%s: %d %q", peer, w.Code, w.Body)
		}
	}
	// anybody else can send the header, or claim to be the proxy
	for _, peer := range []string{"192.0.2.1:4567", "[2001:db8::1]:443", "11.0.0.1:1"} {
		headers := map[string][]string{"Remote-Email": {"alice@example.com"}, "X-Forwarded-For": {"10.1.2.3"}, "X-Real-Ip": {"10.1.2.3"}}
		if w := get(h, "/whoami", peer, headers, nil); w.Code != http.StatusSeeOther || sessionCookieOf(w) != nil {
			t.Errorf("%s: %d", peer, w.Code)
		}
	}
	for name, headers := range map[string]map[string][]string{
		"not allowed":    {"Remote-Email": {"mallory@example.net"}},
		"other group":    {"Remote-Email": {"mallory@example.net"}, "Remote-Groups": {"devs,Admins"}},
		"two values":     {"Remote-Email": {"mallory@example.net", "alice@example.com"}},
		"comma":          {"Remote-Email": {"mallory@example.net, alice@example.com"}},
		"no header":      {"Remote-Groups": {"admins"}},
		"empty":          {"Remote-Email": {" "}},
		"group, no user": {"Remote-Email": {""}, "Remote-Groups": {"admins"}},
		// a proxy that appends to the groups the client sent
		"two groups headers": {"Remote-Email": {"mallory@example.net"}, "Remote-Groups": {"admins", "devs"}},
		"not ASCII":          {"Remote-Email": {"alice@exa\u212ample.com"}},
		"too long":           {"Remote-Email": {strings.Repeat("a", 250) + "@example.org"}},
	} {
		if w := get(h, "/whoami", "10.0.0.1:1", headers, nil); w.Code != http.StatusSeeOther {
			t.Errorf("%s: %d %q", name, w.Code, w.Body)
		}
	}
	if w := get(h, "/whoami", "10.0.0.1:1", map[string][]string{"Remote-Email": {"mallory@example.net"}, "Remote-Groups": {"devs, admins"}}, nil); w.Code != 200 {
		t.Errorf("group: %d", w.Code)
	}
	lines := strings.Join(app.alerter.take(), "\n")
	for _, want := range []string{"admin: signed in: alice@example.com (header)", "sign-in: failed sign-in: mallory@example.net (header): not allowed"} {
		if !strings.Contains(lines, want) {
			t.Errorf("no %q in %s", want, lines)
		}
	}
	// a refused user is logged once, not on every page
	if strings.Count(lines, "mallory@example.net (header): not allowed") != 1 {
		t.Errorf("logged again: %s", lines)
	}
	// the login page says who the proxy says it is
	if w := get(h, "/login", "10.0.0.1:1", map[string][]string{"Remote-Email": {"mallory@example.net"}}, nil); !strings.Contains(w.Body.String(), "mallory@example.net is not an admin") {
		t.Errorf("login page: %s", w.Body)
	}
}

func TestHeaderSessions(t *testing.T) {
	app, h := headerApp(t)
	peer := "10.0.0.1:1"
	alice := map[string][]string{"Remote-Email": {"alice@example.com"}}
	w := get(h, "/whoami", peer, alice, nil)
	c := sessionCookieOf(w)
	if c == nil || !c.HttpOnly || !c.Secure || c.SameSite != http.SameSiteStrictMode {
		t.Fatalf("cookie %+v", c)
	}
	// reused while the header names the same user
	if w := get(h, "/whoami", peer, alice, c); w.Code != 200 || sessionCookieOf(w) != nil || len(app.sessions) != 1 {
		t.Errorf("not reused: %d %d", w.Code, len(app.sessions))
	}
	// without the cookie (a link from another site): the same session, no new sign-in
	app.alerter.take()
	for i := 0; i < 3; i++ {
		w := get(h, "/whoami", peer, alice, nil)
		if again := sessionCookieOf(w); w.Code != 200 || again == nil || again.Value != c.Value || len(app.sessions) != 1 {
			t.Errorf("no cookie: %d %v %d", w.Code, again, len(app.sessions))
		}
	}
	if lines := app.alerter.take(); len(lines) != 0 {
		t.Errorf("signed in again: %v", lines)
	}
	// another user: a new session, the old one ends
	w = get(h, "/whoami", peer, map[string][]string{"Remote-Email": {"bob@example.org"}}, c)
	bob := sessionCookieOf(w)
	if w.Body.String() != "bob@example.org header" || bob == nil || bob.Value == c.Value || app.sessions[c.Value] != nil {
		t.Errorf("user change: %q", w.Body)
	}
	// the header goes: the session ends, even if it comes back later
	if w := get(h, "/whoami", peer, nil, bob); w.Code != http.StatusSeeOther || app.sessions[bob.Value] != nil {
		t.Errorf("header gone: %d", w.Code)
	}
	// from another peer the header does not count, the session ends too
	w = get(h, "/whoami", peer, alice, nil)
	c = sessionCookieOf(w)
	if w := get(h, "/whoami", "192.0.2.1:1", alice, c); w.Code != http.StatusSeeOther || app.sessions[c.Value] != nil {
		t.Errorf("untrusted peer: %d", w.Code)
	}
	// a user dropped from the allowlist loses the session
	w = get(h, "/whoami", peer, alice, nil)
	c = sessionCookieOf(w)
	app.auth.users = nil
	if w := get(h, "/whoami", peer, alice, c); w.Code != http.StatusSeeOther || app.sessions[c.Value] != nil {
		t.Errorf("no longer allowed: %d", w.Code)
	}

	// a password session does not depend on the header
	w = post(h, "/login", url.Values{"password": {"correct horse battery"}}, nil, nil)
	c = sessionCookieOf(w)
	if w := get(h, "/whoami", "192.0.2.1:1", nil, c); w.Code != 200 || w.Body.String() != " password" {
		t.Errorf("password session: %d %q", w.Code, w.Body)
	}
	// signing in again replaces it: a new id and CSRF token
	for k := range app.sessions {
		if k != c.Value {
			delete(app.sessions, k)
		}
	}
	old := app.sessions[c.Value]
	again := sessionCookieOf(post(h, "/login", url.Values{"password": {"correct horse battery"}}, c, nil))
	if again == nil || app.sessions[c.Value] != nil || len(app.sessions) != 1 || app.sessions[again.Value] == nil || app.sessions[again.Value].csrf == old.csrf {
		t.Errorf("password session not replaced: %v %d", again, len(app.sessions))
	}
}

func TestPasswordOff(t *testing.T) {
	app, h := headerApp(t)
	app.auth.password = nil
	if w := post(h, "/login", url.Values{"password": {"correct horse battery"}}, nil, nil); w.Code != http.StatusForbidden || sessionCookieOf(w) != nil {
		t.Errorf("password accepted: %d", w.Code)
	}
	if w := get(h, "/login", "192.0.2.1:1", nil, nil); strings.Contains(w.Body.String(), `type="password"`) {
		t.Errorf("password form shown: %s", w.Body)
	}
	// and no OIDC
	for _, path := range []string{"/auth/login", "/auth/callback?state=x&code=y"} {
		if w := get(h, path, "192.0.2.1:1", nil, nil); w.Code != http.StatusNotFound {
			t.Errorf("%s: %d", path, w.Code)
		}
	}
}

// fakeProvider is an OpenID provider: discovery, keys, token and userinfo
type fakeProvider struct {
	*httptest.Server
	key      *rsa.PrivateKey
	forged   *rsa.PrivateKey // signs instead of key, with its key id
	clientID string
	// what the next sign-in gets
	claims   map[string]any
	userinfo map[string]any
	// in the discovery document; pkceMethods is S256 unless changed
	authMethods, pkceMethods []string
	public                   bool // no client secret

	mu    sync.Mutex
	codes map[string]fakeCode
	// the client authentication of the last token request
	basicAuth          bool
	formID, formSecret string
}

type fakeCode struct{ challenge, nonce string }

var (
	testKeyOnce sync.Once
	testKey     *rsa.PrivateKey
)

func newFakeProvider(t *testing.T) *fakeProvider {
	testKeyOnce.Do(func() { testKey, _ = rsa.GenerateKey(rand.Reader, 2048) })
	f := &fakeProvider{key: testKey, clientID: "admin-ui", codes: map[string]fakeCode{}, pkceMethods: []string{"S256"}}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /.well-known/openid-configuration", func(w http.ResponseWriter, r *http.Request) {
		d := map[string]any{
			"issuer": f.URL, "authorization_endpoint": f.URL + "/authorize", "token_endpoint": f.URL + "/token",
			"jwks_uri": f.URL + "/jwks", "userinfo_endpoint": f.URL + "/userinfo", "id_token_signing_alg_values_supported": []string{"RS256"},
		}
		if f.authMethods != nil {
			d["token_endpoint_auth_methods_supported"] = f.authMethods
		}
		if f.pkceMethods != nil {
			d["code_challenge_methods_supported"] = f.pkceMethods
		}
		json.NewEncoder(w).Encode(d)
	})
	mux.HandleFunc("GET /jwks", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(jose.JSONWebKeySet{Keys: []jose.JSONWebKey{{Key: &f.key.PublicKey, KeyID: "k1", Algorithm: "RS256", Use: "sig"}}})
	})
	mux.HandleFunc("POST /token", func(w http.ResponseWriter, r *http.Request) {
		id, secret, basic := r.BasicAuth()
		f.mu.Lock()
		f.basicAuth, f.formID, f.formSecret = basic, r.PostFormValue("client_id"), r.PostFormValue("client_secret")
		if !basic {
			id, secret = f.formID, f.formSecret
		}
		code, ok := f.codes[r.PostFormValue("code")]
		delete(f.codes, r.PostFormValue("code"))
		f.mu.Unlock()
		wantSecret := "s3cret"
		if f.public {
			wantSecret = ""
		}
		sum := sha256.Sum256([]byte(r.PostFormValue("code_verifier")))
		if !ok || id != f.clientID || secret != wantSecret || r.PostFormValue("redirect_uri") != "https://admin.example.com/auth/callback" ||
			base64.RawURLEncoding.EncodeToString(sum[:]) != code.challenge {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			w.Write([]byte(`{"error":"invalid_grant"}`))
			return
		}
		claims := map[string]any{"iss": f.URL, "aud": f.clientID, "sub": "123", "iat": time.Now().Unix(), "exp": time.Now().Add(5 * time.Minute).Unix(), "nonce": code.nonce}
		for k, v := range f.claims {
			if v == nil {
				delete(claims, k)
			} else {
				claims[k] = v
			}
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"access_token": "at", "token_type": "Bearer", "expires_in": 300, "id_token": f.sign(t, claims)})
	})
	mux.HandleFunc("GET /userinfo", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer at" || f.userinfo == nil {
			http.Error(w, "no", http.StatusUnauthorized)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(f.userinfo)
	})
	f.Server = httptest.NewServer(mux)
	t.Cleanup(f.Close)
	return f
}

func (f *fakeProvider) sign(t *testing.T, claims map[string]any) string {
	key := f.key
	if f.forged != nil {
		key = f.forged
	}
	signer, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.RS256, Key: jose.JSONWebKey{Key: key, KeyID: "k1"}}, (&jose.SignerOptions{}).WithType("JWT"))
	if err != nil {
		t.Fatal(err)
	}
	payload, _ := json.Marshal(claims)
	obj, err := signer.Sign(payload)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := obj.CompactSerialize()
	return raw
}

func oidcApp(t *testing.T, f *fakeProvider, vars ...string) (*App, http.Handler) {
	m := map[string]string{"ADMIN_OIDC_ISSUER": f.URL, "ADMIN_OIDC_CLIENT_ID": f.clientID, "ADMIN_OIDC_CLIENT_SECRET": "s3cret",
		"ADMIN_OIDC_REDIRECT_URL": "https://admin.example.com/auth/callback", "ADMIN_ALLOWED_USERS": "alice@example.com", "ADMIN_OIDC_NAME": "Example SSO"}
	for i := 0; i < len(vars); i += 2 {
		m[vars[i]] = vars[i+1]
	}
	setAuthEnv(t, m)
	auth, err := loadAuth()
	if err != nil {
		t.Fatal(err)
	}
	app := &App{auth: auth, sessions: map[string]*session{}, alerter: &Alerter{}}
	return app, app.routes()
}

// start begins a sign-in, and has the provider hand out a code for it: the
// callback URL and the state cookie
func (f *fakeProvider) start(t *testing.T, h http.Handler) (string, *http.Cookie) {
	t.Helper()
	return f.startAt(t, h, "/auth/login")
}

// startAt: start from a sign-in link, /auth/login?next= for one
func (f *fakeProvider) startAt(t *testing.T, h http.Handler, login string) (string, *http.Cookie) {
	t.Helper()
	w := get(h, login, "192.0.2.1:1", nil, nil)
	to, err := url.Parse(w.Header().Get("Location"))
	if w.Code != http.StatusSeeOther || err != nil || !strings.HasPrefix(to.String(), f.URL+"/authorize?") {
		t.Fatalf("start: %d %s", w.Code, to)
	}
	q := to.Query()
	if q.Get("client_id") != f.clientID || q.Get("redirect_uri") != "https://admin.example.com/auth/callback" || q.Get("response_type") != "code" ||
		q.Get("code_challenge_method") != "S256" || q.Get("code_challenge") == "" || q.Get("nonce") == "" || len(q.Get("state")) < 32 || !strings.Contains(q.Get("scope"), "openid") {
		t.Fatalf("authorization request %v", q)
	}
	var state *http.Cookie
	for _, c := range w.Result().Cookies() {
		if c.Name == stateCookie {
			state = c
		}
	}
	if state == nil || !(state.Value == q.Get("state") || strings.HasPrefix(state.Value, q.Get("state")+"~")) || !state.HttpOnly || !state.Secure || state.SameSite != http.SameSiteLaxMode || state.MaxAge > 600 {
		t.Fatalf("state cookie %+v", state)
	}
	code := randomToken()
	f.mu.Lock()
	f.codes[code] = fakeCode{q.Get("code_challenge"), q.Get("nonce")}
	f.mu.Unlock()
	return "/auth/callback?" + url.Values{"code": {code}, "state": {q.Get("state")}}.Encode(), state
}

func signedIn(t *testing.T, w *httptest.ResponseRecorder) bool {
	t.Helper()
	if c := sessionCookieOf(w); c != nil && w.Code == 200 && strings.Contains(w.Body.String(), `url=/"`) {
		return true
	}
	if w.Code != http.StatusSeeOther || w.Header().Get("Location") != "/login?error=sso" {
		t.Errorf("failed sign-in: %d %s", w.Code, w.Header().Get("Location"))
	}
	return false
}

func TestOIDCSignIn(t *testing.T) {
	f := newFakeProvider(t)
	f.claims = map[string]any{"email": "Alice@example.com", "email_verified": true}
	app, h := oidcApp(t, f)
	if w := get(h, "/login", "192.0.2.1:1", nil, nil); !strings.Contains(w.Body.String(), `href="/auth/login">Sign in with Example SSO`) || strings.Contains(w.Body.String(), `type="password"`) {
		t.Errorf("login page: %s", w.Body)
	}
	callback, state := f.start(t, h)
	w := get(h, callback, "192.0.2.1:1", nil, state)
	if !signedIn(t, w) {
		t.Fatal("not signed in")
	}
	var s *session
	for _, s = range app.sessions {
	}
	if len(app.sessions) != 1 || s.user != "alice@example.com" || s.method != "oidc" {
		t.Errorf("session %+v", s)
	}
	if !strings.Contains(strings.Join(app.alerter.take(), "\n"), "admin: signed in: alice@example.com (oidc)") {
		t.Error("no event")
	}
	if c := sessionCookieOf(w); !c.HttpOnly || !c.Secure || c.SameSite != http.SameSiteStrictMode || c.Path != "/" {
		t.Errorf("session cookie %+v", c)
	}
	// the state is used once
	if signedIn(t, get(h, callback, "192.0.2.1:1", nil, state)) {
		t.Error("state reused")
	}
	if !strings.Contains(strings.Join(app.alerter.take(), "\n"), "sign-in: failed sign-in: unknown (oidc): bad state") {
		t.Error("no failure event")
	}
	// anybody can call the callback: without the state cookie it is not logged,
	// a bad state every 10 minutes, not enough to push sign-ins out
	for i := 0; i < 50; i++ {
		get(h, "/auth/callback?state=x", "192.0.2.1:1", nil, nil)
		get(h, "/auth/callback?state=x", "192.0.2.1:1", nil, &http.Cookie{Name: stateCookie, Value: "x"})
	}
	if lines := app.alerter.take(); len(lines) != 0 {
		t.Errorf("logged: %v", lines)
	}
}

func TestOIDCClientAuthentication(t *testing.T) {
	f := newFakeProvider(t)
	f.claims = map[string]any{"email": "alice@example.com", "email_verified": true}
	// a public client (Mozilla accounts, PKCE): client_id in the form, no secret
	f.public = true
	_, h := oidcApp(t, f, "ADMIN_OIDC_CLIENT_SECRET", "")
	callback, state := f.start(t, h)
	if !signedIn(t, get(h, callback, "192.0.2.1:1", nil, state)) || f.basicAuth || f.formID != f.clientID || f.formSecret != "" {
		t.Errorf("public client: basic %v, %q %q", f.basicAuth, f.formID, f.formSecret)
	}
	// a provider that takes client_secret_post only
	f.public, f.authMethods = false, []string{"client_secret_post"}
	_, h = oidcApp(t, f)
	callback, state = f.start(t, h)
	if !signedIn(t, get(h, callback, "192.0.2.1:1", nil, state)) || f.basicAuth || f.formSecret != "s3cret" {
		t.Errorf("client_secret_post: basic %v, %q", f.basicAuth, f.formSecret)
	}
	// the default, client_secret_basic
	f.authMethods = nil
	_, h = oidcApp(t, f)
	callback, state = f.start(t, h)
	if !signedIn(t, get(h, callback, "192.0.2.1:1", nil, state)) || !f.basicAuth || f.formSecret != "" {
		t.Errorf("client_secret_basic: basic %v, %q", f.basicAuth, f.formSecret)
	}
}

// discovery is lazy: the provider (the accounts service) may start after us
func TestOIDCProviderStartsLater(t *testing.T) {
	f := newFakeProvider(t)
	f.claims = map[string]any{"email": "alice@example.com", "email_verified": true}
	inner := f.Config.Handler
	var down atomic.Bool
	down.Store(true)
	f.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if down.Load() {
			http.Error(w, "starting", http.StatusServiceUnavailable)
			return
		}
		inner.ServeHTTP(w, r)
	})
	_, h := oidcApp(t, f)
	w := get(h, "/auth/login", "192.0.2.1:1", nil, nil)
	for _, c := range w.Result().Cookies() {
		if c.Name == stateCookie {
			t.Errorf("state cookie while the provider is down: %+v", c)
		}
	}
	if w.Code != http.StatusBadGateway {
		t.Errorf("provider down: %d", w.Code)
	}
	down.Store(false)
	callback, state := f.start(t, h)
	if !signedIn(t, get(h, callback, "192.0.2.1:1", nil, state)) {
		t.Error("not signed in once the provider is up")
	}
}

func TestOIDCRefusals(t *testing.T) {
	f := newFakeProvider(t)
	for name, c := range map[string]struct {
		claims map[string]any
		reason string
	}{
		"not allowed":      {map[string]any{"email": "mallory@example.com", "email_verified": true}, "mallory@example.com (oidc): not allowed"},
		"unverified email": {map[string]any{"email": "alice@example.com", "email_verified": false}, "alice@example.com (oidc): unverified email"},
		"no verified flag": {map[string]any{"email": "alice@example.com"}, "unverified email"},
		"wrong nonce":      {map[string]any{"email": "alice@example.com", "email_verified": true, "nonce": "other"}, "wrong nonce"},
		"wrong audience":   {map[string]any{"email": "alice@example.com", "email_verified": true, "aud": "other-client"}, "invalid ID token"},
		"wrong issuer":     {map[string]any{"email": "alice@example.com", "email_verified": true, "iss": "https://evil.example"}, "invalid ID token"},
		"expired":          {map[string]any{"email": "alice@example.com", "email_verified": true, "exp": time.Now().Add(-time.Hour).Unix()}, "invalid ID token"},
		"no email":         {map[string]any{}, "no email"},
		// without code_challenge_methods_supported, nothing says PKCE is checked
		"no nonce": {map[string]any{"email": "alice@example.com", "email_verified": true, "nonce": nil}, "no nonce"},
	} {
		f.pkceMethods = []string{"S256"}
		if name == "no nonce" {
			f.pkceMethods = nil
		}
		f.claims = c.claims
		app, h := oidcApp(t, f)
		callback, state := f.start(t, h)
		if signedIn(t, get(h, callback, "192.0.2.1:1", nil, state)) || len(app.sessions) != 0 {
			t.Errorf("%s: signed in", name)
		}
		if lines := strings.Join(app.alerter.take(), "\n"); !strings.Contains(lines, c.reason) {
			t.Errorf("%s: %q", name, lines)
		}
	}
	f.pkceMethods = []string{"S256"}

	// a forged signature
	f.claims = map[string]any{"email": "alice@example.com", "email_verified": true}
	f.forged, _ = rsa.GenerateKey(rand.Reader, 2048)
	app, h := oidcApp(t, f)
	callback, state := f.start(t, h)
	if signedIn(t, get(h, callback, "192.0.2.1:1", nil, state)) {
		t.Error("forged signature accepted")
	}
	f.forged = nil

	// the state of another browser, or none
	callback, _ = f.start(t, h)
	_, otherState := f.start(t, h)
	for _, c := range []*http.Cookie{otherState, nil} {
		if signedIn(t, get(h, callback, "192.0.2.1:1", nil, c)) {
			t.Errorf("state cookie %v accepted", c)
		}
	}
	// a state that expired, or that we did not sign
	expired := app.auth.oidc.newState(time.Now().Add(-time.Second))
	forged := expired[:strings.LastIndex(expired, ".")+1] + strings.Repeat("0", 64)
	for _, s := range []string{expired, forged, "x." + expired} {
		f.mu.Lock()
		f.codes["c"] = fakeCode{"", ""}
		f.mu.Unlock()
		if signedIn(t, get(h, "/auth/callback?code=c&state="+url.QueryEscape(s), "192.0.2.1:1", nil, &http.Cookie{Name: stateCookie, Value: s})) {
			t.Errorf("state %s accepted", s)
		}
	}
	// the provider's own error, filtered for the event log
	app, h = oidcApp(t, f)
	_, state = f.start(t, h)
	if signedIn(t, get(h, "/auth/callback?error=access_denied%0AFake&state="+url.QueryEscape(state.Value), "192.0.2.1:1", nil, state)) {
		t.Error("error accepted")
	}
	if lines := strings.Join(app.alerter.take(), "\n"); !strings.Contains(lines, "sign-in: failed sign-in: unknown (oidc): provider error access_deniedake") {
		t.Errorf("provider error: %q", lines)
	}
	// an email with a line break makes no line of its own
	f.claims = map[string]any{"email": "mallory@example.com\nadmin: signed in: x", "email_verified": true}
	callback, state = f.start(t, h)
	if signedIn(t, get(h, callback, "192.0.2.1:1", nil, state)) {
		t.Error("signed in")
	}
	for _, line := range app.alerter.take() {
		if strings.ContainsAny(line, "\n\r") {
			t.Errorf("line break: %q", line)
		}
	}
	// the PKCE verifier stays with us: a code redeemed with another fails at the provider
	callback, state = f.start(t, h)
	f.mu.Lock()
	for code := range f.codes {
		f.codes[code] = fakeCode{"wrong", f.codes[code].nonce}
	}
	f.mu.Unlock()
	if signedIn(t, get(h, callback, "192.0.2.1:1", nil, state)) {
		t.Error("PKCE not checked")
	}
}

func TestOIDCUserinfoAndGroups(t *testing.T) {
	f := newFakeProvider(t)
	// Mozilla accounts: no email in the ID token, no nonce, an email in userinfo
	f.claims = map[string]any{"nonce": nil}
	f.userinfo = map[string]any{"sub": "123", "email": "alice@example.com", "email_verified": true}
	app, h := oidcApp(t, f)
	callback, state := f.start(t, h)
	if !signedIn(t, get(h, callback, "192.0.2.1:1", nil, state)) {
		t.Error("userinfo email refused")
	}
	// the self-hosted accounts list no PKCE methods, but check the verifier
	f.pkceMethods, f.public = nil, true
	_, h = oidcApp(t, f, "FXA_CONTENT_URL", f.URL, "ADMIN_OIDC_CLIENT_SECRET", "")
	callback, state = f.start(t, h)
	if !signedIn(t, get(h, callback, "192.0.2.1:1", nil, state)) {
		t.Error("no nonce from the self-hosted accounts refused")
	}
	f.pkceMethods, f.public = []string{"S256"}, false
	_, h = oidcApp(t, f)
	// without email_verified it counts only with ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL
	f.userinfo = map[string]any{"sub": "123", "email": "alice@example.com"}
	callback, state = f.start(t, h)
	if signedIn(t, get(h, callback, "192.0.2.1:1", nil, state)) {
		t.Error("unverified userinfo email accepted")
	}
	app, h = oidcApp(t, f, "ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL", "true")
	callback, state = f.start(t, h)
	if !signedIn(t, get(h, callback, "192.0.2.1:1", nil, state)) {
		t.Error("trusted unverified email refused")
	}
	// userinfo of somebody else
	f.userinfo = map[string]any{"sub": "456", "email": "alice@example.com", "email_verified": true}
	callback, state = f.start(t, h)
	if signedIn(t, get(h, callback, "192.0.2.1:1", nil, state)) {
		t.Error("userinfo of another subject accepted")
	}

	// groups, from the ID token or userinfo, in the claim of ADMIN_OIDC_GROUPS_CLAIM
	f.userinfo = nil
	app, h = oidcApp(t, f, "ADMIN_ALLOWED_USERS", "", "ADMIN_ALLOWED_GROUPS", "admins", "ADMIN_OIDC_GROUPS_CLAIM", "roles")
	for _, c := range []struct {
		claims   map[string]any
		userinfo map[string]any
		want     bool
	}{
		{map[string]any{"email": "bob@example.com", "email_verified": true, "roles": []string{"devs", "admins"}}, nil, true},
		{map[string]any{"email": "bob@example.com", "email_verified": true, "roles": "admins"}, nil, true},
		{map[string]any{"email": "bob@example.com", "email_verified": true, "groups": []string{"admins"}}, nil, false},
		{map[string]any{"email": "bob@example.com", "email_verified": true}, map[string]any{"sub": "123", "roles": []string{"admins"}}, true},
		{map[string]any{"email": "bob@example.com", "email_verified": true, "roles": []string{"devs"}}, map[string]any{"sub": "123", "roles": []string{"admins"}}, false},
	} {
		f.claims, f.userinfo = c.claims, c.userinfo
		callback, state = f.start(t, h)
		if got := signedIn(t, get(h, callback, "192.0.2.1:1", nil, state)); got != c.want {
			t.Errorf("%v %v: %v", c.claims, c.userinfo, got)
		}
	}

	// allowed by group with no counted email (Entra: no email_verified): bound to the subject
	for _, c := range []struct {
		claims, userinfo map[string]any
	}{
		{map[string]any{"email": "bob@example.com", "email_verified": false, "roles": []string{"admins"}}, nil},
		{map[string]any{"roles": []string{"admins"}}, map[string]any{"sub": "123"}},
	} {
		f.claims, f.userinfo = c.claims, c.userinfo
		app, h = oidcApp(t, f, "ADMIN_ALLOWED_USERS", "", "ADMIN_ALLOWED_GROUPS", "admins", "ADMIN_OIDC_GROUPS_CLAIM", "roles")
		callback, state = f.start(t, h)
		if !signedIn(t, get(h, callback, "192.0.2.1:1", nil, state)) {
			t.Errorf("%v %v: refused", c.claims, c.userinfo)
			continue
		}
		for _, s := range app.sessions {
			if s.user != "subject 123" || s.method != "oidc" {
				t.Errorf("session %+v", s)
			}
		}
		if lines := strings.Join(app.alerter.take(), "\n"); !strings.Contains(lines, "admin: signed in: subject 123 (oidc)") {
			t.Errorf("event: %q", lines)
		}
	}
	// no email and no userinfo: refused, even in an allowed group
	f.claims, f.userinfo = map[string]any{"roles": []string{"admins"}}, nil
	app, h = oidcApp(t, f, "ADMIN_ALLOWED_USERS", "", "ADMIN_ALLOWED_GROUPS", "admins", "ADMIN_OIDC_GROUPS_CLAIM", "roles")
	callback, state = f.start(t, h)
	if signedIn(t, get(h, callback, "192.0.2.1:1", nil, state)) || !strings.Contains(strings.Join(app.alerter.take(), "\n"), "no email") {
		t.Error("no email accepted")
	}
	// an allowed but unverified email, not in an allowed group
	f.claims = map[string]any{"email": "alice@example.com", "email_verified": false, "roles": []string{"devs"}}
	app, h = oidcApp(t, f, "ADMIN_ALLOWED_GROUPS", "admins", "ADMIN_OIDC_GROUPS_CLAIM", "roles")
	callback, state = f.start(t, h)
	if signedIn(t, get(h, callback, "192.0.2.1:1", nil, state)) || !strings.Contains(strings.Join(app.alerter.take(), "\n"), "alice@example.com (oidc): unverified email") {
		t.Error("unverified email accepted")
	}
}

// /auth/login needs no session: a flood of it keeps nothing, nobody's sign-in is pushed out
func TestOIDCLoginFlood(t *testing.T) {
	f := newFakeProvider(t)
	f.claims = map[string]any{"email": "alice@example.com", "email_verified": true}
	app, h := oidcApp(t, f)
	callback, state := f.start(t, h)
	for i := 0; i < 2*maxUsed; i++ {
		get(h, "/auth/login", "192.0.2.1:1", nil, nil)
	}
	if len(app.auth.oidc.used) != 0 {
		t.Errorf("%d states kept", len(app.auth.oidc.used))
	}
	if !signedIn(t, get(h, callback, "192.0.2.1:1", nil, state)) {
		t.Error("sign-in pushed out")
	}
	// used states are bounded
	for i := 0; i < maxUsed+10; i++ {
		s := app.auth.oidc.newState(time.Now().Add(stateLifetime))
		app.auth.oidc.take(s)
	}
	if n := len(app.auth.oidc.used); n != maxUsed {
		t.Errorf("%d used", n)
	}
}
