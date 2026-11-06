package main

import (
	"net/http"
	"net/url"
	"path"
	"strings"
)

// Where a sign-in goes on to: the page asked for when there was no session (a
// restart of the admin UI ends them all, sessions are in memory). Carried as
// ?next= of /login, the hidden field of its form and the OIDC state cookie,
// and checked by safeNext wherever it is read.

const maxNext = 1024

// notNext: pages a sign-in never goes on to, they are the sign-in itself or not pages
var notNext = []string{"/login", "/logout", "/auth/", "/static/", "/healthz", "/metrics"}

// safeNext is raw when it is a local page of this server (a path, maybe a query),
// else "": not "/" either, the default. No scheme or host, a single leading
// slash (not // or /\, also escaped), printable ASCII only, a clean path.
func safeNext(raw string) string {
	if raw == "" || raw == "/" || len(raw) > maxNext || raw[0] != '/' || strings.HasPrefix(raw, "//") {
		return ""
	}
	for i := 0; i < len(raw); i++ {
		// no controls (CR, LF), spaces, backslashes, quotes or non-ASCII: none in our URLs
		if c := raw[i]; c <= ' ' || c >= 0x7f || c == '\\' || c == '"' || c == '\'' || c == '<' || c == '>' || c == '`' || c == '#' {
			return ""
		}
	}
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "" || u.Host != "" || u.User != nil || u.Opaque != "" {
		return ""
	}
	// what the escapes hide: /%2F%2Fevil.com, /%5Cevil.com, %0d%0a
	p := u.Path
	if p != path.Clean(p) || strings.HasPrefix(p, "//") || strings.ContainsFunc(p, badNextRune) {
		return ""
	}
	if q, err := url.QueryUnescape(u.RawQuery); err != nil || strings.ContainsFunc(q, badNextRune) {
		return ""
	}
	for _, n := range notNext {
		if n = strings.TrimSuffix(n, "/"); p == n || strings.HasPrefix(p, n+"/") {
			return ""
		}
	}
	return raw
}

func badNextRune(r rune) bool { return r < ' ' || r == 0x7f || r == '\\' }

// loginURL: /login, with the page to go on to when there is one
func loginURL(next string, extra ...string) string {
	v := url.Values{}
	if next = safeNext(next); next != "" {
		v.Set("next", next)
	}
	for i := 0; i+1 < len(extra); i += 2 {
		v.Set(extra[i], extra[i+1])
	}
	if len(v) == 0 {
		return "/login"
	}
	return "/login?" + v.Encode()
}

// orHome: next, or the dashboard
func orHome(next string) string {
	if next = safeNext(next); next != "" {
		return next
	}
	return "/"
}

// formPage: the page a form posted without a session was on. The Referer when it
// is of this server (Referrer-Policy same-origin sends it to us only), else the
// page of the same path or its parent, when there is one (the confirm pages post
// to themselves), else "".
func (a *App) formPage(r *http.Request) string {
	if ref := r.Header.Get("Referer"); ref != "" {
		if u, err := url.Parse(ref); err == nil && (u.Scheme == "https" || u.Scheme == "http") && u.Host == r.Host && u.User == nil {
			if next := safeNext(u.RequestURI()); next != "" || u.Path == "/" {
				return next
			}
		}
	}
	if a.pages == nil {
		return ""
	}
	for p := r.URL.Path; p != "/" && p != "."; p = path.Dir(p) {
		if safeNext(p) == "" {
			continue
		}
		get := &http.Request{Method: http.MethodGet, URL: &url.URL{Path: p}, Host: r.Host, Header: http.Header{}}
		if _, pattern := a.pages.Handler(get); pattern != "" && pattern != "GET /{$}" {
			return p
		}
	}
	return ""
}

// nextTitle: how the login page names the page it goes on to
func nextTitle(next string) string {
	p, _, _ := strings.Cut(next, "?")
	switch {
	case p == "/activity":
		return "Activity"
	case p == "/security":
		return "Security"
	case p == "/config":
		return "Configuration"
	case p == "/connect":
		return "Connect a device"
	case p == "/find":
		return "the search"
	case strings.HasPrefix(p, "/users/") && strings.Count(p, "/") == 2:
		return "the account " + strings.TrimPrefix(p, "/users/")
	}
	if u, err := url.PathUnescape(p); err == nil {
		return u
	}
	return p
}

// browser: a page or a form of a browser, which can follow a redirect to the
// login page; scripts keep the plain status
func browser(r *http.Request) bool {
	return strings.Contains(r.Header.Get("Accept"), "text/html")
}
