package main

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
	"golang.org/x/oauth2"
)

const (
	callbackPath = "/auth/callback"
	// the state of a sign-in in progress, bound to the browser that started it.
	// Lax: the provider sends it back cross-site.
	stateCookie   = "ffs_admin_oidc"
	stateLifetime = 10 * time.Minute
	// states already used, kept until they expire; only callbacks with a valid
	// state add one, a flood of /auth/login keeps nothing in memory
	maxUsed = 1000
)

type oidcAuth struct {
	issuer, clientID, clientSecret, redirectURL string
	scopes                                      []string
	name, groupsClaim                           string
	trustUnverified                             bool
	wantGroups                                  bool // ADMIN_ALLOWED_GROUPS is set
	client                                      *http.Client
	// signs the state; nonce and PKCE verifier derive from it
	key []byte
	// the self-hosted Mozilla accounts: no nonce, but they check the PKCE verifier
	fxa bool

	mu       sync.Mutex
	provider *oidc.Provider // discovered on first use: the provider may start after us
	verifier *oidc.IDTokenVerifier
	config   *oauth2.Config
	pkce     bool // the provider says it checks S256 verifiers
	used     map[string]time.Time
}

type pendingLogin struct {
	nonce, verifier string
}

func loadOIDC(insecureCookie bool) (*oidcAuth, error) {
	issuer := env("ADMIN_OIDC_ISSUER", "")
	if issuer == "" {
		for _, name := range []string{"ADMIN_OIDC_CLIENT_ID", "ADMIN_OIDC_CLIENT_SECRET", "ADMIN_OIDC_REDIRECT_URL"} {
			if env(name, "") != "" {
				return nil, fmt.Errorf("%s is set but ADMIN_OIDC_ISSUER is not", name)
			}
		}
		return nil, nil
	}
	if u, err := url.Parse(issuer); err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" {
		return nil, fmt.Errorf("ADMIN_OIDC_ISSUER: not an http(s) URL: %q", issuer)
	}
	o := &oidcAuth{
		issuer:       issuer,
		clientID:     env("ADMIN_OIDC_CLIENT_ID", ""),
		clientSecret: env("ADMIN_OIDC_CLIENT_SECRET", ""),
		redirectURL:  env("ADMIN_OIDC_REDIRECT_URL", ""),
		scopes:       strings.Fields(env("ADMIN_OIDC_SCOPES", "openid email profile")),
		name:         env("ADMIN_OIDC_NAME", "single sign-on"),
		groupsClaim:  env("ADMIN_OIDC_GROUPS_CLAIM", "groups"),
		client:       &http.Client{Timeout: 10 * time.Second},
		key:          make([]byte, 32),
		fxa:          issuer == env("FXA_CONTENT_URL", ""),
		used:         map[string]time.Time{},
	}
	rand.Read(o.key)
	if o.clientID == "" {
		return nil, errors.New("ADMIN_OIDC_ISSUER needs ADMIN_OIDC_CLIENT_ID")
	}
	if o.redirectURL == "" {
		return nil, errors.New("ADMIN_OIDC_ISSUER needs ADMIN_OIDC_REDIRECT_URL, the public URL of " + callbackPath)
	}
	u, err := url.Parse(o.redirectURL)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" || u.Path != callbackPath || u.RawQuery != "" || u.Fragment != "" || u.User != nil {
		return nil, fmt.Errorf("ADMIN_OIDC_REDIRECT_URL must be like https://admin.example.com%s, not %q", callbackPath, o.redirectURL)
	}
	// browsers drop Secure cookies over http, but on localhost
	if u.Scheme == "http" && !insecureCookie && u.Hostname() != "localhost" && u.Hostname() != "127.0.0.1" && u.Hostname() != "::1" {
		return nil, errors.New("ADMIN_OIDC_REDIRECT_URL is http: use https, or set ADMIN_INSECURE_COOKIE=1")
	}
	// FxA refuses PKCE from clients with a secret, and without a nonce in its ID
	// tokens PKCE is what ties the code to this browser
	if o.fxa && o.clientSecret != "" {
		return nil, errors.New("signing in with the self-hosted Mozilla accounts needs a public client: leave ADMIN_FXA_CLIENT_SECRET and ADMIN_OIDC_CLIENT_SECRET empty")
	}
	if !slices.Contains(o.scopes, oidc.ScopeOpenID) {
		return nil, errors.New("ADMIN_OIDC_SCOPES must include openid")
	}
	switch v := env("ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL", "false"); v {
	case "true", "false":
		o.trustUnverified = v == "true"
	default:
		return nil, fmt.Errorf("ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL must be true or false, not %q", v)
	}
	return o, nil
}

// setup discovers the provider once; a failure is retried at the next sign-in
func (o *oidcAuth) setup() error {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.provider != nil {
		return nil
	}
	p, err := oidc.NewProvider(oidc.ClientContext(context.Background(), o.client), o.issuer)
	if err != nil {
		return err
	}
	var discovery struct {
		AuthMethods []string `json:"token_endpoint_auth_methods_supported"`
		PKCEMethods []string `json:"code_challenge_methods_supported"`
	}
	p.Claims(&discovery)
	endpoint := p.Endpoint()
	// client_secret_basic is the default of the spec; FxA only takes client_secret_post
	if o.clientSecret == "" || len(discovery.AuthMethods) > 0 && !slices.Contains(discovery.AuthMethods, "client_secret_basic") {
		endpoint.AuthStyle = oauth2.AuthStyleInParams
	} else {
		endpoint.AuthStyle = oauth2.AuthStyleInHeader
	}
	o.pkce = slices.Contains(discovery.PKCEMethods, "S256")
	o.provider = p
	o.verifier = p.Verifier(&oidc.Config{ClientID: o.clientID})
	o.config = &oauth2.Config{ClientID: o.clientID, ClientSecret: o.clientSecret, Endpoint: endpoint, RedirectURL: o.redirectURL, Scopes: o.scopes}
	return nil
}

func (o *oidcAuth) mac(purpose, s string) string {
	h := hmac.New(sha256.New, o.key)
	h.Write([]byte(purpose + "\x00" + s))
	return hex.EncodeToString(h.Sum(nil))
}

// newState is random.expiry.mac: the browser keeps it in the state cookie, the
// server nothing, so a flood of /auth/login cannot push out anybody's sign-in
func (o *oidcAuth) newState(expires time.Time) string {
	s := randomToken()[:32] + "." + strconv.FormatInt(expires.Unix(), 10)
	return s + "." + o.mac("state", s)
}

func (o *oidcAuth) pending(state string) *pendingLogin {
	// hex: a valid PKCE verifier (43 to 128 characters)
	return &pendingLogin{nonce: o.mac("nonce", state), verifier: o.mac("verifier", state)}
}

// take returns the sign-in of a state we made, unexpired, at most once
func (o *oidcAuth) take(state string) *pendingLogin {
	body, sum, ok := strings.Cut(state, ".")
	if !ok {
		return nil
	}
	exp, sum, ok := strings.Cut(sum, ".")
	if !ok || !hmac.Equal([]byte(sum), []byte(o.mac("state", body+"."+exp))) {
		return nil
	}
	unix, err := strconv.ParseInt(exp, 10, 64)
	expires := time.Unix(unix, 0)
	if err != nil || time.Now().After(expires) {
		return nil
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	if _, seen := o.used[state]; seen {
		return nil
	}
	var soonest string
	for s, t := range o.used {
		if time.Now().After(t) {
			delete(o.used, s)
		} else if soonest == "" || t.Before(o.used[soonest]) {
			soonest = s
		}
	}
	// full: forget the one closest to expiry, its cookie is gone from that browser
	if len(o.used) >= maxUsed {
		delete(o.used, soonest)
	}
	o.used[state] = expires
	return o.pending(state)
}

// stateCookieValue: the state, and when there is one the page to go on to after
// the sign-in, base64url, with a MAC of both: state~next~mac
func (o *oidcAuth) stateCookieValue(state, next string) string {
	if next == "" {
		return state
	}
	return state + "~" + base64.RawURLEncoding.EncodeToString([]byte(next)) + "~" + o.mac("next", state+"\x00"+next)
}

// readStateCookie: the state and the page to go on to of the cookie; next is ""
// when there is none, or it was not ours or not a safe page
func (o *oidcAuth) readStateCookie(value string) (state, next string) {
	state, rest, found := strings.Cut(value, "~")
	if !found {
		return state, ""
	}
	enc, sum, ok := strings.Cut(rest, "~")
	raw, err := base64.RawURLEncoding.DecodeString(enc)
	if !ok || err != nil || !hmac.Equal([]byte(sum), []byte(o.mac("next", state+"\x00"+string(raw)))) {
		return state, ""
	}
	return state, safeNext(string(raw))
}

func (a *App) oidcLogin(w http.ResponseWriter, r *http.Request) {
	o := a.auth.oidc
	if o == nil {
		http.NotFound(w, r)
		return
	}
	if err := o.setup(); err != nil {
		log.Printf("OIDC discovery of %s: %v", o.issuer, err)
		http.Error(w, "The sign-in provider does not answer, try again later", http.StatusBadGateway)
		return
	}
	state := o.newState(time.Now().Add(stateLifetime))
	p := o.pending(state)
	// the page to go on to stays here, in the cookie, bound to the state: the
	// provider sees the state only
	a.auth.cookie(w, stateCookie, o.stateCookieValue(state, safeNext(r.URL.Query().Get("next"))), "/auth/", int(stateLifetime.Seconds()), http.SameSiteLaxMode)
	http.Redirect(w, r, o.config.AuthCodeURL(state, oidc.Nonce(p.nonce), oauth2.S256ChallengeOption(p.verifier)), http.StatusSeeOther)
}

// identity is what is kept of the provider's answer: nothing else of the tokens
type identity struct {
	email    string
	verified bool
	groups   []string
	subject  string
}

func (a *App) oidcCallback(w http.ResponseWriter, r *http.Request) {
	o := a.auth.oidc
	if o == nil {
		http.NotFound(w, r)
		return
	}
	a.auth.cookie(w, stateCookie, "", "/auth/", -1, http.SameSiteLaxMode)
	q := r.URL.Query()
	state := q.Get("state")
	c, err := r.Cookie(stateCookie)
	// anybody can call this: without a state and its cookie it is not a sign-in
	// from here, and not worth an event
	if state == "" || err != nil {
		http.Redirect(w, r, "/login?error=sso", http.StatusSeeOther)
		return
	}
	cookieState, next := o.readStateCookie(c.Value)
	var p *pendingLogin
	if equal(cookieState, state) {
		p = o.take(state)
	}
	if p == nil {
		// needs no session either: logged every 10 minutes
		if a.auth.refusedOnce("oidc bad state") {
			a.failedSignIn("", "oidc", "bad state")
		}
		http.Redirect(w, r, "/login?error=sso", http.StatusSeeOther)
		return
	}
	// a valid state: the page to go on to is ours, also for another try
	fail := func(who, reason string) {
		a.failedSignIn(who, "oidc", reason)
		http.Redirect(w, r, loginURL(next, "error", "sso"), http.StatusSeeOther)
	}
	if e := q.Get("error"); e != "" {
		fail("", "provider error "+strings.Map(func(r rune) rune {
			if r >= 'a' && r <= 'z' || r == '_' {
				return r
			}
			return -1
		}, e))
		return
	}
	// a guard: a valid state means discovery worked in this process
	if o.setup() != nil {
		fail("", "provider unreachable")
		return
	}
	id, err := o.identify(r.Context(), q.Get("code"), p)
	if err != nil {
		who := ""
		if id != nil {
			who = id.email
		}
		fail(who, err.Error())
		return
	}
	countedEmail := ""
	if id.email != "" && (id.verified || o.trustUnverified) {
		countedEmail = id.email
	}
	if !a.auth.allowed(countedEmail, id.groups) {
		reason := "not allowed"
		if countedEmail == "" && a.auth.allowedUser(id.email) {
			reason = "unverified email"
		}
		fail(id.email, reason)
		return
	}
	who := countedEmail
	if who == "" {
		who = "subject " + id.subject
	}
	a.newSession(w, r, who, "oidc")
	// the session cookie is SameSite=Strict: a redirect from here still counts as
	// coming from the provider, a refresh of our own page does not
	a.render(w, "continue.html", map[string]any{"Next": orHome(next)})
}

// identify redeems the code and checks the ID token; the error is a short reason
// for the event log
func (o *oidcAuth) identify(ctx context.Context, code string, p *pendingLogin) (*identity, error) {
	if code == "" {
		return nil, errors.New("no code")
	}
	ctx, cancel := context.WithTimeout(oidc.ClientContext(ctx, o.client), 20*time.Second)
	defer cancel()
	tok, err := o.config.Exchange(ctx, code, oauth2.VerifierOption(p.verifier))
	if err != nil {
		log.Printf("OIDC token request: %v", err)
		return nil, errors.New("token request failed")
	}
	raw, _ := tok.Extra("id_token").(string)
	if raw == "" {
		return nil, errors.New("no ID token")
	}
	idToken, err := o.verifier.Verify(ctx, raw)
	if err != nil {
		log.Printf("OIDC ID token: %v", err)
		return nil, errors.New("invalid ID token")
	}
	// Mozilla accounts leave the nonce out: then PKCE, always used, has to tie the
	// code to this browser, which only a provider that checks the verifier does
	if idToken.Nonce == "" && !o.pkce && !(o.fxa && o.clientSecret == "") {
		return nil, errors.New("no nonce")
	}
	if idToken.Nonce != "" && !equal(idToken.Nonce, p.nonce) {
		return nil, errors.New("wrong nonce")
	}
	id := &identity{subject: idToken.Subject}
	var claims map[string]json.RawMessage
	if err := idToken.Claims(&claims); err != nil {
		return nil, errors.New("invalid ID token claims")
	}
	id.read(claims, o.groupsClaim)
	_, hasGroups := claims[o.groupsClaim]
	if id.email == "" || o.wantGroups && !hasGroups && o.provider.UserInfoEndpoint() != "" {
		info, err := o.provider.UserInfo(ctx, oauth2.StaticTokenSource(tok))
		if err != nil {
			log.Printf("OIDC userinfo: %v", err)
			if id.email == "" {
				return nil, errors.New("no email")
			}
			return id, nil
		}
		if info.Subject != "" && info.Subject != idToken.Subject {
			return nil, errors.New("userinfo of another subject")
		}
		var more map[string]json.RawMessage
		if info.Claims(&more) == nil {
			byInfo := &identity{}
			byInfo.read(more, o.groupsClaim)
			if id.email == "" {
				id.email, id.verified = byInfo.email, byInfo.verified
			}
			if !hasGroups {
				id.groups = byInfo.groups
			}
		}
	}
	return id, nil
}

// read takes the email, email_verified (a boolean, or a string for some
// providers) and the groups (a list or a single name)
func (id *identity) read(claims map[string]json.RawMessage, groupsClaim string) {
	var email string
	if json.Unmarshal(claims["email"], &email) == nil {
		// not strings.ToLower: see allowedUser
		id.email, _ = lowerASCII(strings.TrimSpace(email))
	}
	var verified any
	if json.Unmarshal(claims["email_verified"], &verified) == nil {
		id.verified = verified == true || verified == "true"
	}
	var groups []string
	if json.Unmarshal(claims[groupsClaim], &groups) != nil {
		var one string
		if json.Unmarshal(claims[groupsClaim], &one) == nil && one != "" {
			groups = []string{one}
		}
	}
	id.groups = groups
}
