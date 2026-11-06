package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

// an accounts page as the content server writes it: the page config, encodeURIComponent of
// its JSON, in the meta tag of the settings app's index.html
func accountsPage(meta, config string) string {
	enc := strings.NewReplacer("+", "%20").Replace(url.QueryEscape(config))
	return `<!doctype html><html lang="en"><head><meta charset="utf-8"/>` +
		`<meta name="viewport" content="width=device-width,initial-scale=1"/>` +
		`<meta name="` + meta + `" content="` + enc + `" />` +
		`<link rel="preconnect" href="https://api.example.test"></head><body><div id="root"></div></body></html>`
}

// the page config with these settings (no-telemetry.env's, Mozilla's defaults, ...)
func telemetryConfig(glean, sentry string) string {
	return `{"env":"production","version":"1.350.0","sentry":` + sentry + `,"glean":` + glean +
		`,"nimbus":{"enabled":false,"preview":false},"servers":{"auth":{"url":"https://api.example.test"}}}`
}

const (
	gleanOff      = `{"enabled":false,"applicationId":"accounts_frontend_dev","uploadEnabled":false,"appChannel":"development","serverEndpoint":"https://accounts.example.test","logPings":true,"debugViewTag":"","appDisplayVersion":"1.350.0"}`
	gleanDefaults = `{"enabled":false,"applicationId":"accounts_frontend_dev","uploadEnabled":true,"appChannel":"development","serverEndpoint":"https://incoming.telemetry.mozilla.org","logPings":true,"debugViewTag":""}`
	sentryOff     = `{"dsn":"","env":"local","sampleRate":1,"tracesSampleRate":0,"clientName":"fxa-content-client","serverName":"fxa-content-server"}`
)

// the page config read from the page: no-telemetry.env's settings say nothing is sent;
// Mozilla's defaults (upload on, its endpoint), no endpoint, Glean or Sentry on, Nimbus on: each said
func TestTelemetryPageConfig(t *testing.T) {
	const content = "https://accounts.example.test"
	for _, tc := range []struct {
		name, meta, glean, sentry, nimbus string
		want                              []string
	}{
		{name: "no-telemetry.env", meta: "fxa-config", glean: gleanOff, sentry: sentryOff},
		{name: "the older meta", meta: "fxa-content-server-config", glean: gleanOff, sentry: sentryOff},
		{name: "a trailing slash", meta: "fxa-config", glean: strings.Replace(gleanOff, content, content+"/", 1), sentry: sentryOff},
		{name: "Mozilla's defaults", meta: "fxa-config", glean: gleanDefaults, sentry: sentryOff,
			want: []string{"Glean's upload is on (GLEAN_UPLOAD_ENABLED)",
				"the pages send their Glean pings to https://incoming.telemetry.mozilla.org (GLEAN_SERVER_ENDPOINT), not to the accounts pages (https://accounts.example.test)"}},
		// what an empty GLEAN_SERVER_ENDPOINT does: glean.js takes Mozilla's
		{name: "no endpoint", meta: "fxa-config", glean: strings.Replace(gleanOff, content, "", 1), sentry: sentryOff,
			want: []string{"no Glean endpoint (GLEAN_SERVER_ENDPOINT empty): the pages send their Glean pings to Mozilla's default, incoming.telemetry.mozilla.org"}},
		{name: "another host of the stack", meta: "fxa-config", glean: strings.Replace(gleanOff, content, "https://api.example.test", 1), sentry: sentryOff,
			want: []string{"the pages send their Glean pings to https://api.example.test (GLEAN_SERVER_ENDPOINT), not to the accounts pages (https://accounts.example.test)"}},
		{name: "Glean on", meta: "fxa-config", glean: strings.Replace(gleanOff, `"enabled":false`, `"enabled":true`, 1), sentry: sentryOff,
			want: []string{"Glean is on (GLEAN_ENABLED)"}},
		{name: "Sentry on", meta: "fxa-config", glean: gleanOff, sentry: `{"dsn":"https://abc123@o1.ingest.sentry.io/42","env":"prod"}`,
			want: []string{"Sentry is on (SENTRY_DSN): the pages report their errors to o1.ingest.sentry.io"}},
		{name: "Nimbus on", meta: "fxa-config", glean: gleanOff, sentry: sentryOff, nimbus: `{"enabled":true}`,
			want: []string{"Nimbus experiments are on (NIMBUS_ENABLED)"}},
	} {
		config := telemetryConfig(tc.glean, tc.sentry)
		if tc.nimbus != "" {
			config = strings.Replace(config, `{"enabled":false,"preview":false}`, tc.nimbus, 1)
		}
		c, err := parsePageConfig(accountsPage(tc.meta, config))
		if err != nil {
			t.Fatalf("%s: %v", tc.name, err)
		}
		on := telemetryOn(c, content)
		if strings.Join(on, "|") != strings.Join(tc.want, "|") {
			t.Errorf("%s: %q, want %q", tc.name, on, tc.want)
		}
	}
	// a page without it, or a page config without the settings (a release that moved them):
	// not known, never "nothing sent"
	for name, page := range map[string]string{
		"no meta":        `<html><head><meta name="viewport" content="x"></head></html>`,
		"another meta":   accountsPage("fxa-other", telemetryConfig(gleanOff, sentryOff)),
		"no glean":       accountsPage("fxa-config", `{"sentry":`+sentryOff+`}`),
		"not JSON":       accountsPage("fxa-config", `{"glean":`),
		"not URL-encode": `<meta name="fxa-config" content="%zz">`,
	} {
		if c, err := parsePageConfig(page); err == nil {
			t.Errorf("%s: %+v, want an error", name, c)
		}
	}
	// single quotes, other attribute order, HTML entities
	page := `<meta content='` + url.PathEscape(telemetryConfig(gleanOff, sentryOff)) + `' name='fxa-config'>`
	if c, err := parsePageConfig(page); err != nil || len(telemetryOn(c, content)) != 0 {
		t.Errorf("attributes in another order: %+v %v", c, err)
	}
}

// the hidden component: the content server's /settings page, up with no-telemetry.env's
// settings, a warning with Mozilla's defaults and when the page config is gone
func TestAccountsTelemetryCheck(t *testing.T) {
	page := accountsPage("fxa-config", telemetryConfig(gleanOff, sentryOff))
	status := http.StatusOK
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/settings" {
			http.NotFound(w, r)
			return
		}
		w.WriteHeader(status)
		_, _ = w.Write([]byte(page))
	}))
	defer srv.Close()
	h := &Health{client: srv.Client()}
	c := h.telemetryCheckOf(srv.URL+"/", "https://accounts.example.test")
	if c.name != telemetryCheck || !c.hidden || c.every != time.Hour || len(c.after) != 1 || c.after[0] != "Accounts pages" {
		t.Errorf("the check: %+v", c)
	}
	ctx := context.Background()
	if detail, err := c.run(ctx); err != nil || detail != "Glean, Sentry and Nimbus off, and their Glean pings to themselves (https://accounts.example.test, which answers 404)" {
		t.Errorf("no-telemetry.env: %q %v", detail, err)
	}
	page = accountsPage("fxa-config", telemetryConfig(gleanDefaults, sentryOff))
	var warn warning
	if _, err := c.run(ctx); !errors.As(err, &warn) || !strings.Contains(err.Error(), "the pages send their Glean pings to https://incoming.telemetry.mozilla.org (GLEAN_SERVER_ENDPOINT)") {
		t.Errorf("Mozilla's defaults: %v", err)
	}
	page = `<html><head></head></html>`
	if _, err := c.run(ctx); !errors.As(err, &warn) || !strings.Contains(err.Error(), "/settings: no page config in the page (meta fxa-config), so whether the pages send anything to Mozilla is unknown") {
		t.Errorf("no page config: %v", err)
	}
	status = http.StatusBadGateway
	if _, err := c.run(ctx); err == nil || errors.As(err, &warn) || !strings.Contains(err.Error(), "status 502") {
		t.Errorf("502: %v", err)
	}
}

// the setup check, per deployment: where the settings are
func TestTelemetrySetupCheck(t *testing.T) {
	compose, quadlets := deployment{}, deployment{kind: "quadlets"}
	k8s := deployment{kind: "kubernetes", release: "t", prefix: "t-firefox-sync", secret: "t-firefox-sync"}
	up := Component{Name: telemetryCheck, Up: true, Detail: "Glean, Sentry and Nimbus off, and their Glean pings to themselves (https://accounts.example.test, which answers 404)"}
	c := telemetrySetupCheck(up, compose)
	if !c.OK || c.Name != "Telemetry of the accounts pages" || c.Text != "The accounts pages run with Glean, Sentry and Nimbus off, and their Glean pings to themselves (https://accounts.example.test, which answers 404): they send nothing to Mozilla "+
		"(config/fxa/no-telemetry.env, the env_file of the accounts services in compose/fxa.yml, turns it all off: docs/accounts.md#telemetry)." {
		t.Errorf("up: %+v", c)
	}
	on := Component{Name: telemetryCheck, Warn: true, Error: "Sentry is on (SENTRY_DSN): the pages report their errors to sentry.example"}
	for d, want := range map[*deployment]string{
		&compose:  "Config/fxa/no-telemetry.env, the env_file of the accounts services in compose/fxa.yml, turns all of it off",
		&quadlets: "Config/fxa/no-telemetry.env, the EnvironmentFile= of the accounts units, turns all of it off",
		&k8s:      "The chart's files/fxa/no-telemetry.env, the first env entries of every accounts container, turns all of it off",
	} {
		c = telemetrySetupCheck(on, *d)
		if c.OK || !strings.HasPrefix(c.Text, "The accounts pages may send data out of this stack: Sentry is on (SENTRY_DSN): the pages report their errors to sentry.example. ") ||
			!strings.Contains(c.Text, want) || !strings.HasSuffix(c.Text, "whether a new release renamed a setting (docs/accounts.md#telemetry).") {
			t.Errorf("%s: %+v", d.kind, c)
		}
	}
	if c = telemetrySetupCheck(Component{Name: telemetryCheck, Waiting: true}, compose); !c.OK || c.Text != "The accounts pages' settings are read once they are up." {
		t.Errorf("waiting: %+v", c)
	}
	if c = telemetrySetupCheck(Component{Name: telemetryCheck, Error: "status 502"}, compose); c.OK || c.Text != "Could not read the accounts pages' settings: status 502." {
		t.Errorf("down: %+v", c)
	}
	// among the setup checks of the overview, with its own times (the health check's)
	at := time.Now().Add(-time.Minute)
	up.Checked, up.Next = at, at.Add(time.Hour)
	found := false
	for _, s := range (&App{deployment: k8s}).setupChecks(t.Context(), nil, []Component{up}) {
		if s.Name == telemetryCheck {
			found = s.OK && s.Checked.Equal(at) && s.Next.Equal(at.Add(time.Hour)) && strings.Contains(s.Text, "the chart's files/fxa/no-telemetry.env")
		}
	}
	if !found {
		t.Error("not among the setup checks")
	}
}
