package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// What Firefox sees from the internet, checked from the server every hour: the public
// https URLs answer, their certificates, the sign-up gate behind the reverse proxy.
// And the configuration the Sync server depends on: FXA_OAUTH_SERVER_URL.

const (
	// a certificate that expires sooner is a problem (alert): renewals run 30 days ahead
	certWarnDays = 14
	// the gate answers a request with this header and its per-process token itself
	probeHeader = "X-Ffs-Gate-Probe"
)

// publicChecks: ADMIN_PUBLIC_CHECK=0 (or false) turns them all off
func publicChecks() bool {
	v := env("ADMIN_PUBLIC_CHECK", "true")
	return v != "0" && v != "false"
}

// updateChecks: ADMIN_UPDATE_CHECK=false (exactly) turns the release checks off
func updateChecks() bool {
	return env("ADMIN_UPDATE_CHECK", "true") != "false"
}

// httpsURL: u parsed when it is https, nil otherwise (http and unset are not checked)
func httpsURL(raw string) *url.URL {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.Scheme != "https" || u.Hostname() == "" {
		return nil
	}
	return u
}

// unreachable: the server cannot reach its own public name, often split DNS
func unreachable(host string, err error) error {
	return fmt.Errorf("not reachable from the server: %v (with split DNS the server may resolve %s differently from the internet)", err, host)
}

// certificate reads the expiry of the certificate a public URL presents, checked like a browser does
func (h *Health) certificate(ctx context.Context, u *url.URL) (time.Time, error) {
	port := u.Port()
	if port == "" {
		port = "443"
	}
	d := tls.Dialer{NetDialer: &net.Dialer{Timeout: 5 * time.Second}, Config: &tls.Config{ServerName: u.Hostname(), RootCAs: h.rootCAs}}
	conn, err := d.DialContext(ctx, "tcp", net.JoinHostPort(u.Hostname(), port))
	if err != nil {
		var invalid *tls.CertificateVerificationError
		if errors.As(err, &invalid) {
			return time.Time{}, fmt.Errorf("certificate not valid: %v", invalid.Err)
		}
		return time.Time{}, unreachable(u.Hostname(), err)
	}
	defer conn.Close()
	certs := conn.(*tls.Conn).ConnectionState().PeerCertificates
	if len(certs) == 0 {
		return time.Time{}, errors.New("no certificate")
	}
	return certs[0].NotAfter, nil
}

// certProblem: under certWarnDays a warning, expired an error
func certProblem(notAfter, now time.Time) (int, error) {
	days := int(notAfter.Sub(now) / (24 * time.Hour))
	switch {
	case !notAfter.After(now):
		return days, fmt.Errorf("certificate expired on %s", formatTime(notAfter, adminZone))
	case days < certWarnDays:
		return days, warning{fmt.Sprintf("certificate expires in %d days (%s): is its renewal running?", days, formatTime(notAfter, adminZone))}
	}
	return days, nil
}

// publicURL: the certificate of a public URL, then its /__heartbeat__ through the reverse proxy
func (h *Health) publicURL(ctx context.Context, raw string) (string, error) {
	u := httpsURL(raw)
	if u == nil {
		return "", errSkip
	}
	host := u.Hostname()
	notAfter, err := h.certificate(ctx, u)
	if err != nil {
		return "", fmt.Errorf("%s: %w", host, err)
	}
	h.mu.Lock()
	if h.certs == nil {
		h.certs = map[string]time.Time{}
	}
	h.certs[host] = notAfter
	h.mu.Unlock()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimSuffix(u.String(), "/")+"/__heartbeat__", nil)
	if err != nil {
		return "", err
	}
	res, err := h.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("%s: %w", host, unreachable(host, err))
	}
	io.Copy(io.Discard, io.LimitReader(res.Body, 1<<16))
	res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return "", fmt.Errorf("%s/__heartbeat__: status %d through the reverse proxy", host, res.StatusCode)
	}
	days, err := certProblem(notAfter, time.Now())
	if err != nil {
		return "", fmt.Errorf("%s: %w", host, err)
	}
	return fmt.Sprintf("%s: reachable, certificate expires in %d days", host, days), nil
}

// gateProbe asks the sign-up gate through the public accounts API: only the gate
// answers 204 with the token, the accounts service refuses the empty body (no email,
// no password: nothing is ever created, whatever the sign-up policy)
func (h *Health) gateProbe(ctx context.Context, auth string) (string, error) {
	u := httpsURL(auth)
	if u == nil {
		return "", errSkip
	}
	host := u.Hostname()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimSuffix(u.String(), "/")+"/v1/account/create", strings.NewReader("{}"))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set(probeHeader, h.app.gateProbe)
	res, err := h.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("%s: %w", host, unreachable(host, err))
	}
	io.Copy(io.Discard, io.LimitReader(res.Body, 1<<16))
	res.Body.Close()
	if res.StatusCode == http.StatusNoContent && h.app.gateProbe != "" && equal(res.Header.Get(probeHeader), h.app.gateProbe) {
		return "POST " + host + "/v1/account/create goes through the sign-up gate", nil
	}
	// the trigger still refuses what the policy does not allow, without saying why
	return "", warning{fmt.Sprintf("POST %s/v1/account/create does not reach the sign-up gate (status %d): the reverse proxy sends it to the accounts service, and refused sign-ups get \"Unexpected error\" instead of why. %s", host, res.StatusCode, h.app.deployment.gateHint())}
}

// syncNodes: the public URLs the tokenserver hands out (nodes in use)
func (h *Health) syncNodes(ctx context.Context) (string, error) {
	st, err := h.app.sync.Status(ctx)
	if err != nil {
		return "", err
	}
	// a node no longer handed out leaves /metrics: its certificate would count down to
	// an alert for a host nobody uses
	served := map[string]bool{}
	var nodes []string
	for _, n := range st.Nodes {
		if u := httpsURL(n.Node); u != nil && !n.Downed {
			served[u.Hostname()] = true
			nodes = append(nodes, n.Node)
		}
	}
	for _, name := range []string{"FXA_CONTENT_URL", "FXA_AUTH_URL", "FXA_PROFILE_URL"} {
		if u := httpsURL(env(name, "")); u != nil && h.app.fxa != nil {
			served[u.Hostname()] = true
		}
	}
	h.mu.Lock()
	for host := range h.certs {
		if !served[host] {
			delete(h.certs, host)
		}
	}
	h.mu.Unlock()
	var details []string
	for _, node := range nodes {
		detail, err := h.publicURL(ctx, node)
		if err != nil {
			return "", err
		}
		details = append(details, detail)
	}
	if len(details) == 0 {
		return "", errSkip
	}
	return strings.Join(details, "; "), nil
}

// oauthKeys: FXA_OAUTH_SERVER_URL as the Sync server uses it (with /v1, added when
// missing, as PyFxA does), its /jwks: the keys that check the sign-ins of Firefox
func oauthKeysURL(server string) string {
	server = strings.TrimSuffix(strings.TrimSpace(server), "/")
	if server == "" {
		return ""
	}
	if !strings.HasSuffix(server, "/v1") {
		server += "/v1"
	}
	return server + "/jwks"
}

func (h *Health) oauthKeys(ctx context.Context, jwks string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, jwks, nil)
	if err != nil {
		return "", err
	}
	res, err := h.client.Do(req)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return "", fmt.Errorf("%s: status %d", jwks, res.StatusCode)
	}
	var keys struct {
		Keys []json.RawMessage `json:"keys"`
	}
	if err := json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(&keys); err != nil || len(keys.Keys) == 0 {
		return "", fmt.Errorf("%s: no keys", jwks)
	}
	return jwks + " answers", nil
}

// publicChecksOf: the checks of the public URLs, and of FXA_OAUTH_SERVER_URL. Each goes
// through a part of the stack (after): in the startup grace it waits for it, and runs
// again at once when it comes back up, with fast retries while it fails
func (h *Health) publicChecksOf(app *App) []check {
	var checks []check
	// while one fails, a few rounds apart: an unreachable name can hold the health
	// loop for the whole timeout of each check
	every, retry := time.Hour, 5*time.Duration(envInt("HEALTH_CHECK_SECONDS", 60))*time.Second
	if publicChecks() {
		checks = append(checks, check{name: "Public Sync URL", run: h.syncNodes, every: every, retry: retry, after: []string{"Sync server"}, fast: true})
		if app.fxa != nil {
			for _, p := range []struct{ name, url, part string }{
				{"Public accounts pages", env("FXA_CONTENT_URL", ""), "Accounts pages"},
				{"Public accounts API", env("FXA_AUTH_URL", ""), "Accounts API"},
				{"Public profile server", env("FXA_PROFILE_URL", ""), "Profile server"},
			} {
				if httpsURL(p.url) != nil {
					checks = append(checks, check{name: p.name, run: func(ctx context.Context) (string, error) { return h.publicURL(ctx, p.url) }, every: every, retry: retry,
						after: []string{p.part}, fast: true})
				}
			}
			if auth := env("FXA_AUTH_URL", ""); httpsURL(auth) != nil {
				checks = append(checks, check{name: "Sign-up gate", run: func(ctx context.Context) (string, error) { return h.gateProbe(ctx, auth) }, every: every, retry: retry,
					after: []string{"Accounts API"}, fast: true})
			}
		}
	}
	// on the internet (Mozilla's accounts) only with the public checks; the stack's own
	// accounts API answers once it is up
	if jwks := oauthKeysURL(env("FXA_OAUTH_SERVER_URL", "")); jwks != "" && (publicChecks() || !strings.HasPrefix(jwks, "https://")) {
		var after []string
		if app.fxa != nil {
			after = []string{"Accounts API"}
		}
		checks = append(checks, check{name: oauthKeysCheck, run: func(ctx context.Context) (string, error) { return h.oauthKeys(ctx, jwks) }, every: every, retry: retry, hidden: true,
			after: after, fast: true})
	}
	return checks
}

const oauthKeysCheck = "Sign-in keys (FXA_OAUTH_SERVER_URL)"

// Certs: the expiry of the certificates of the public URLs, by host
func (h *Health) Certs() map[string]time.Time {
	h.mu.Lock()
	defer h.mu.Unlock()
	certs := map[string]time.Time{}
	for k, v := range h.certs {
		certs[k] = v
	}
	return certs
}
