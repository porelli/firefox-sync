package main

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/netip"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

// Sign-in methods, enabled by their configuration (see docs/admin/signing-in.md): the password,
// OpenID Connect, and a header set by a trusted forward-auth proxy. They all end
// in the same session.
type authConfig struct {
	password *[32]byte // sha256 of ADMIN_PASSWORD, nil when password sign-in is off
	oidc     *oidcAuth // nil when off

	header, groupsHeader string // canonical names, "" when off
	proxies              []netip.Prefix

	// who is an admin with OIDC or the header
	users  []string // emails and @domains, lower case
	groups map[string]bool

	insecureCookie bool

	mu      sync.Mutex
	refused map[string]time.Time // failures logged recently, see refusedOnce
}

var headerName = regexp.MustCompile(`^[A-Za-z0-9-]+$`)

func loadAuth() (*authConfig, error) {
	insecure, err := envSwitch("ADMIN_INSECURE_COOKIE")
	if err != nil {
		return nil, err
	}
	c := &authConfig{insecureCookie: insecure}
	if p := env("ADMIN_PASSWORD", ""); p != "" {
		if len(p) < 12 {
			return nil, errors.New("ADMIN_PASSWORD must be at least 12 characters (or empty to turn password sign-in off)")
		}
		sum := sha256.Sum256([]byte(p))
		c.password = &sum
	}
	if c.oidc, err = loadOIDC(c.insecureCookie); err != nil {
		return nil, err
	}
	if err := c.loadHeader(); err != nil {
		return nil, err
	}
	if c.users, err = ParseAllowlist(env("ADMIN_ALLOWED_USERS", "")); err != nil {
		return nil, fmt.Errorf("ADMIN_ALLOWED_USERS: %w", err)
	}
	c.groups = map[string]bool{}
	for _, g := range strings.Split(env("ADMIN_ALLOWED_GROUPS", ""), ",") {
		if g = strings.TrimSpace(g); g != "" {
			c.groups[g] = true
		}
	}
	if c.oidc != nil {
		c.oidc.wantGroups = len(c.groups) > 0
	}
	if c.password == nil && c.oidc == nil && c.header == "" {
		return nil, errors.New("no sign-in method: set ADMIN_PASSWORD, ADMIN_OIDC_ISSUER or ADMIN_AUTH_HEADER")
	}
	// fail closed: single sign-on without a list would let in anybody the provider knows
	if (c.oidc != nil || c.header != "") && len(c.users) == 0 && len(c.groups) == 0 {
		return nil, errors.New("ADMIN_OIDC_ISSUER or ADMIN_AUTH_HEADER needs ADMIN_ALLOWED_USERS or ADMIN_ALLOWED_GROUPS")
	}
	return c, nil
}

func (c *authConfig) loadHeader() error {
	header, groups, proxies := env("ADMIN_AUTH_HEADER", ""), env("ADMIN_AUTH_GROUPS_HEADER", ""), env("ADMIN_TRUSTED_PROXIES", "")
	if header == "" {
		if groups != "" || proxies != "" {
			return errors.New("ADMIN_AUTH_GROUPS_HEADER and ADMIN_TRUSTED_PROXIES need ADMIN_AUTH_HEADER")
		}
		return nil
	}
	for name, v := range map[string]string{"ADMIN_AUTH_HEADER": header, "ADMIN_AUTH_GROUPS_HEADER": groups} {
		if v != "" && !headerName.MatchString(v) {
			return fmt.Errorf("%s: not a header name: %q", name, v)
		}
	}
	c.header = http.CanonicalHeaderKey(header)
	if groups != "" {
		c.groupsHeader = http.CanonicalHeaderKey(groups)
	}
	for _, p := range strings.Split(proxies, ",") {
		if p = strings.TrimSpace(p); p == "" {
			continue
		}
		prefix, err := netip.ParsePrefix(p)
		if err != nil && !strings.Contains(p, "/") {
			var addr netip.Addr
			if addr, err = netip.ParseAddr(p); err == nil {
				prefix = netip.PrefixFrom(addr, addr.BitLen())
			}
		}
		if err != nil {
			return fmt.Errorf("ADMIN_TRUSTED_PROXIES: not an address or a CIDR: %q", p)
		}
		c.proxies = append(c.proxies, prefix.Masked())
	}
	if len(c.proxies) == 0 {
		return errors.New("ADMIN_AUTH_HEADER needs ADMIN_TRUSTED_PROXIES, the addresses of the proxy (CIDRs)")
	}
	return nil
}

// allowed: an email or its @domain in ADMIN_ALLOWED_USERS, or one of the groups
// in ADMIN_ALLOWED_GROUPS. user is "" when there is no usable identity.
func (c *authConfig) allowed(user string, groups []string) bool {
	return c.allowedUser(user) || c.allowedGroup(groups)
}

func (c *authConfig) allowedUser(user string) bool {
	user, ascii := lowerASCII(user)
	at := strings.Index(user, "@")
	if !ascii || at < 1 || strings.Count(user, "@") != 1 {
		return false
	}
	domain := user[at:]
	for _, e := range c.users {
		if e == user || e == domain {
			return true
		}
	}
	return false
}

// lowerASCII folds ASCII letters only, and says whether s is all ASCII: the
// allowlist is, and strings.ToLower would turn the Kelvin sign into a k
func lowerASCII(s string) (string, bool) {
	ascii := true
	b := []byte(s)
	for i, c := range b {
		if c >= 0x80 {
			ascii = false
		} else if 'A' <= c && c <= 'Z' {
			b[i] = c + 'a' - 'A'
		}
	}
	return string(b), ascii
}

func (c *authConfig) allowedGroup(groups []string) bool {
	for _, g := range groups {
		if c.groups[g] {
			return true
		}
	}
	return false
}

// trustedPeer: only the direct peer counts, never X-Forwarded-For, which the
// client writes
func (c *authConfig) trustedPeer(r *http.Request) bool {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return false
	}
	addr, err := netip.ParseAddr(host)
	if err != nil {
		return false
	}
	addr = addr.Unmap().WithZone("")
	for _, p := range c.proxies {
		if p.Contains(addr) {
			return true
		}
	}
	return false
}

// headerIdentity is the user and groups set by the proxy; present is false when
// header sign-in is off, the peer is not a trusted proxy or there is no header.
// user is "" when the header is unusable (repeated, too long, not ASCII, control
// characters), groups nil when their header is repeated.
func (c *authConfig) headerIdentity(r *http.Request) (user string, groups []string, present bool) {
	if c.header == "" || !c.trustedPeer(r) {
		return "", nil, false
	}
	values := r.Header.Values(c.header)
	if len(values) == 0 {
		return "", nil, false
	}
	// a proxy that appends instead of replacing lets the client add its own
	if len(values) == 1 {
		var ascii bool
		user, ascii = lowerASCII(strings.TrimSpace(values[0]))
		if !ascii || len(user) > 255 || strings.ContainsFunc(user, func(r rune) bool { return r < ' ' || r == 0x7f || r == ',' }) {
			user = ""
		}
	}
	// the same for the groups, which make an admin
	if values := r.Header.Values(c.groupsHeader); c.groupsHeader != "" && len(values) == 1 {
		for _, g := range strings.Split(values[0], ",") {
			if g = strings.TrimSpace(g); g != "" {
				groups = append(groups, g)
			}
		}
	}
	return user, groups, true
}

// refusedOnce: a refused header user retries on every page, and anybody can send
// a bad OIDC state: log each every 10 minutes
func (c *authConfig) refusedOnce(what string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if t, ok := c.refused[what]; ok && time.Since(t) < 10*time.Minute {
		return false
	}
	if c.refused == nil || len(c.refused) >= 1000 {
		c.refused = map[string]time.Time{}
	}
	c.refused[what] = time.Now()
	return true
}

func (c *authConfig) cookie(w http.ResponseWriter, name, value, path string, maxAge int, sameSite http.SameSite) {
	http.SetCookie(w, &http.Cookie{
		Name:     name,
		Value:    value,
		Path:     path,
		MaxAge:   maxAge,
		HttpOnly: true,
		Secure:   !c.insecureCookie,
		SameSite: sameSite,
	})
}

// eventText keeps a name from a provider or a proxy on one short line
func eventText(s string) string {
	if s = oneLine(s, 100); s == "" {
		return "unknown"
	}
	return s
}

// oneLine: without control characters, at most max bytes (and "...")
func oneLine(s string, max int) string {
	s = strings.Map(func(r rune) rune {
		if r < ' ' || r == 0x7f {
			return -1
		}
		return r
	}, s)
	if len(s) > max {
		cut := max
		for cut > 0 && !utf8.RuneStart(s[cut]) {
			cut--
		}
		s = s[:cut] + "..."
	}
	return s
}

// newSession replaces the session of the request, if any (a new id at every
// sign-in), and records who signed in and how
func (a *App) newSession(w http.ResponseWriter, r *http.Request, user, method string) *session {
	token := randomToken()
	s := &session{csrf: randomToken(), expires: time.Now().Add(sessionLifetime), user: user, method: method}
	a.mu.Lock()
	if c, err := r.Cookie(sessionCookie); err == nil {
		delete(a.sessions, c.Value)
	}
	for t, old := range a.sessions {
		if time.Now().After(old.expires) {
			delete(a.sessions, t)
		}
	}
	a.sessions[token] = s
	a.mu.Unlock()
	who := ""
	if user != "" {
		who = ": " + eventText(user)
	}
	log.Printf("admin signed in%s (%s)", who, method)
	a.event("admin", fmt.Sprintf(adminSignIn+"%s (%s)", who, method))
	a.auth.cookie(w, sessionCookie, token, "/", int(sessionLifetime.Seconds()), http.SameSiteStrictMode)
	return s
}

func (a *App) failedSignIn(user, method, reason string) {
	who := ""
	if user != "" || method != "password" {
		who = ": " + eventText(user)
	}
	detail := fmt.Sprintf("failed sign-in%s (%s)", who, method)
	if reason != "" {
		detail += ": " + reason
	}
	log.Printf("admin %s", detail)
	// a kind of its own: failures come from anybody, they cannot push sign-ins and
	// changes out of the event log or the alerts
	a.event("sign-in", detail)
}

func (a *App) endSession(token string) {
	a.mu.Lock()
	delete(a.sessions, token)
	a.mu.Unlock()
}

// currentSession is the session of the cookie, and for header users the one of
// the header: a header session ends when the header goes or names someone else
func (a *App) currentSession(w http.ResponseWriter, r *http.Request) *session {
	var s *session
	token := ""
	if c, err := r.Cookie(sessionCookie); err == nil {
		token = c.Value
		a.mu.Lock()
		s = a.sessions[token]
		if s != nil && time.Now().After(s.expires) {
			delete(a.sessions, token)
			s = nil
		}
		a.mu.Unlock()
	}
	if s != nil && s.method != "header" {
		return s
	}
	user, groups, present := a.auth.headerIdentity(r)
	if !present {
		if s != nil {
			a.endSession(token)
		}
		return nil
	}
	// a group alone does not do: the session is bound to the user
	if user == "" || !a.auth.allowed(user, groups) {
		if s != nil {
			a.endSession(token)
		}
		if a.auth.refusedOnce("header " + user) {
			a.failedSignIn(user, "header", "not allowed")
		}
		return nil
	}
	if s != nil && s.user == user {
		return s
	}
	// without the cookie (a link from another site, SameSite=Strict) the live
	// session of that user, rather than a new sign-in for every such request
	if t, old := a.headerSession(user); old != nil {
		if s != nil {
			a.endSession(token)
		}
		a.auth.cookie(w, sessionCookie, t, "/", int(time.Until(old.expires).Seconds()), http.SameSiteStrictMode)
		return old
	}
	return a.newSession(w, r, user, "header")
}

func (a *App) headerSession(user string) (string, *session) {
	a.mu.Lock()
	defer a.mu.Unlock()
	for t, s := range a.sessions {
		if s.method == "header" && s.user == user && time.Now().Before(s.expires) {
			return t, s
		}
	}
	return "", nil
}

type handler func(w http.ResponseWriter, r *http.Request, s *session)

func (a *App) authenticated(next handler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		s := a.currentSession(w, r)
		if s == nil {
			switch {
			case r.Method == http.MethodGet || r.Method == http.MethodHead:
				// back to this page after the sign-in
				http.Redirect(w, r, loginURL(r.URL.RequestURI()), http.StatusSeeOther)
			case browser(r) && r.URL.Path == "/logout":
				http.Redirect(w, r, "/login", http.StatusSeeOther)
			case browser(r):
				// a form sent after a restart or an expiry: not replayed, the admin
				// signs in and finds the page of the form again
				http.Redirect(w, r, loginURL(a.formPage(r), "ended", "form"), http.StatusSeeOther)
			default:
				http.Error(w, "Not signed in", http.StatusUnauthorized)
			}
			return
		}
		if r.Method == http.MethodPost {
			if !sameOrigin(r) || !equal(r.PostFormValue("csrf"), s.csrf) {
				http.Error(w, "Invalid form, reload the page", http.StatusForbidden)
				return
			}
		}
		next(w, r, s)
	}
}

func (a *App) loginPage(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	next := safeNext(q.Get("next"))
	data := map[string]any{"Password": a.auth.password != nil, "Error": q.Get("error"), "Kubernetes": a.deployment.Kubernetes(),
		"Next": next, "Home": orHome(next), "FormLost": q.Get("ended") == "form"}
	if next != "" {
		data["NextTitle"] = nextTitle(next)
	}
	if a.auth.oidc != nil {
		data["OIDC"] = a.auth.oidc.name
	}
	if a.auth.header != "" {
		data["Header"] = true
		if user, groups, present := a.auth.headerIdentity(r); present {
			if user != "" && a.auth.allowed(user, groups) {
				data["HeaderUser"] = user
			} else {
				data["HeaderRefused"] = eventText(user)
			}
		}
	}
	a.render(w, "login.html", data)
}

func (a *App) login(w http.ResponseWriter, r *http.Request) {
	if a.auth.password == nil {
		http.Error(w, "Password sign-in is off", http.StatusForbidden)
		return
	}
	if !sameOrigin(r) {
		http.Error(w, "Invalid form", http.StatusForbidden)
		return
	}
	a.mu.Lock()
	cutoff := time.Now().Add(-time.Minute)
	recent := a.failures[:0]
	for _, t := range a.failures {
		if t.After(cutoff) {
			recent = append(recent, t)
		}
	}
	a.failures = recent
	throttled := len(a.failures) >= loginFailuresPerMinute
	a.mu.Unlock()
	if throttled {
		http.Error(w, "Too many failed sign-ins, try again in a minute", http.StatusTooManyRequests)
		return
	}

	given := sha256.Sum256([]byte(r.PostFormValue("password")))
	if !equal(string(given[:]), string(a.auth.password[:])) {
		a.mu.Lock()
		a.failures = append(a.failures, time.Now())
		a.mu.Unlock()
		a.failedSignIn("", "password", "")
		http.Redirect(w, r, loginURL(r.PostFormValue("next"), "error", "password"), http.StatusSeeOther)
		return
	}
	a.newSession(w, r, "", "password")
	http.Redirect(w, r, orHome(r.PostFormValue("next")), http.StatusSeeOther)
}

func (a *App) logout(w http.ResponseWriter, r *http.Request, s *session) {
	if c, err := r.Cookie(sessionCookie); err == nil {
		a.endSession(c.Value)
	}
	a.auth.cookie(w, sessionCookie, "", "/", -1, http.SameSiteStrictMode)
	http.Redirect(w, r, "/login", http.StatusSeeOther)
}
