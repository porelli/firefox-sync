package main

import (
	"strings"
	"testing"
)

// FXA_OAUTH_SERVER_URL at the stack's accounts API on another port than its own: the host
// port of FXA_AUTH_EXPORT_PORT copied over (fxa-auth:9010), which never answers inside the stack
func TestOauthInternalPort(t *testing.T) {
	for raw, wrong := range map[string]bool{
		"http://fxa-auth:9000/v1":                  false,
		"http://fxa-auth:9000":                     false,
		" http://FXA-AUTH:9000/v1/ ":               false,
		"http://ffs-firefox-sync-fxa-auth:9000/v1": false,
		"https://oauth.accounts.firefox.com/v1":    false,
		"https://api.example.com/v1":               false,
		"":                                         false,
		"http://fxa-auth:9010/v1":                  true,
		"http://fxa-auth/v1":                       true,
		"http://fxa-auth:443/v1":                   true,
		"http://ffs-firefox-sync-fxa-auth:9001/v1": true,
	} {
		got := oauthInternalPort(raw)
		if (got != "") != wrong {
			t.Errorf("%q: %q, want wrong %v", raw, got, wrong)
		}
		if wrong && !strings.Contains(got, "FXA_OAUTH_SERVER_URL is container-to-container: inside the stack the accounts API is always fxa-auth:9000; FXA_AUTH_EXPORT_PORT is the host port for your reverse proxy") {
			t.Errorf("%q: %q", raw, got)
		}
	}
}

// the setup check "Sign-in keys": the keys answering, not answering, and the port of the host
// in FXA_OAUTH_SERVER_URL said as such (compose and the Quadlets; the chart sets its own URL)
func TestOauthKeysSetupCheck(t *testing.T) {
	up := Component{Name: oauthKeysCheck, Up: true, Detail: "http://fxa-auth:9000/v1/jwks answers"}
	down := Component{Name: oauthKeysCheck, Error: "Get \"http://fxa-auth:9010/v1/jwks\": dial tcp 172.18.0.5:9010: connect: connection refused"}

	c := oauthKeysSetupCheck(up, deployment{}, "http://fxa-auth:9000/v1", true)
	if !c.OK || c.Name != "Sign-in keys (FXA_OAUTH_SERVER_URL)" || !strings.Contains(c.Text, "http://fxa-auth:9000/v1/jwks answers") {
		t.Errorf("answering: %+v", c)
	}
	c = oauthKeysSetupCheck(Component{Name: oauthKeysCheck, Error: "no keys"}, deployment{}, "http://fxa-auth:9000/v1", true)
	if c.OK || !strings.Contains(c.Text, "which do not answer (no keys)") || strings.Contains(c.Text, "container-to-container") {
		t.Errorf("not answering, the right URL: %+v", c)
	}
	for _, d := range []deployment{{}, {kind: "quadlets"}} {
		c = oauthKeysSetupCheck(down, d, "http://fxa-auth:9010/v1", true)
		for _, want := range []string{
			"FXA_OAUTH_SERVER_URL is http://fxa-auth:9010/v1: ",
			"FXA_OAUTH_SERVER_URL is container-to-container: inside the stack the accounts API is always fxa-auth:9000; FXA_AUTH_EXPORT_PORT is the host port for your reverse proxy.",
			"Set FXA_OAUTH_SERVER_URL=http://fxa-auth:9000/v1 in .env",
			"connection refused",
		} {
			if c.OK || !strings.Contains(c.Text, want) {
				t.Errorf("%s, fxa-auth:9010: no %q in %+v", d.kind, want, c)
			}
		}
	}
	// (even should something answer there)
	if c = oauthKeysSetupCheck(up, deployment{}, "http://fxa-auth:9010/v1", true); c.OK || !strings.Contains(c.Text, "container-to-container") || strings.Contains(c.Text, "()") {
		t.Errorf("fxa-auth:9010 answering: %+v", c)
	}
	// whose accounts get in: the self-hosted ones only, Mozilla's only (said once the keys answer)
	own := "The Sync server accepts only accounts of this accounts server (FXA_OAUTH_SERVER_URL): Mozilla's accounts are refused."
	mozilla := "The Sync server accepts Mozilla's accounts (FXA_OAUTH_SERVER_URL)"
	if c = oauthKeysSetupCheck(up, deployment{}, "http://fxa-auth:9000/v1", true); !c.OK || !strings.Contains(c.Text, own) || strings.Contains(c.Text, mozilla) {
		t.Errorf("self-hosted accounts: %+v", c)
	}
	moz := Component{Name: oauthKeysCheck, Up: true, Detail: "https://oauth.accounts.firefox.com/v1/jwks answers"}
	if c = oauthKeysSetupCheck(moz, deployment{}, "https://oauth.accounts.firefox.com/v1", false); !c.OK || !strings.Contains(c.Text, mozilla+", and only those: accounts of a self-hosted accounts server are refused.") || strings.Contains(c.Text, own) {
		t.Errorf("Mozilla's accounts: %+v", c)
	}
	if c = oauthKeysSetupCheck(Component{Name: oauthKeysCheck, Error: "no keys"}, deployment{}, "http://fxa-auth:9000/v1", true); strings.Contains(c.Text, "accepts") {
		t.Errorf("not answering, nothing said of whose accounts: %+v", c)
	}
	// the chart: its own URL, never the host's ports
	k8s := deployment{kind: "kubernetes", prefix: "ffs-firefox-sync", release: "ffs", secret: "s"}
	if c = oauthKeysSetupCheck(down, k8s, "http://ffs-firefox-sync-fxa-auth:9010/v1", true); strings.Contains(c.Text, "FXA_AUTH_EXPORT_PORT") || !strings.Contains(c.Text, "fxa.oauthServerUrl") {
		t.Errorf("kubernetes: %+v", c)
	}
}

// the settings page: the same, among the settings to check
func TestConfigPageOauthPort(t *testing.T) {
	t.Setenv("SYNCSTORAGE_DOMAIN", "https://sync.example.com")
	t.Setenv("FXA_AUTH_URL", "https://api.example.com")
	t.Setenv("FXA_CONTENT_URL", "https://accounts.example.com")
	t.Setenv("FXA_OAUTH_SERVER_URL", "http://fxa-auth:9010/v1")
	page := configPage(t, true, func(app *App, _ *fakeFxa) { app.emailDomain = "api.example.com" })
	hints := page[strings.Index(page, `<section id="hints">`):strings.Index(page, `<nav class="chips"`)]
	if !strings.Contains(hints, "FXA_OAUTH_SERVER_URL is http://fxa-auth:9010/v1: FXA_OAUTH_SERVER_URL is container-to-container: inside the stack the accounts API is always fxa-auth:9000; FXA_AUTH_EXPORT_PORT is the host port for your reverse proxy.") {
		t.Errorf("hints: %s", hints)
	}
	t.Setenv("FXA_OAUTH_SERVER_URL", "http://fxa-auth:9000/v1")
	page = configPage(t, true, func(app *App, _ *fakeFxa) { app.emailDomain = "api.example.com" })
	if strings.Contains(page, "container-to-container") {
		t.Error("fxa-auth:9000: a hint")
	}
}
