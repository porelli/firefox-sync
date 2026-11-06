package main

import (
	"context"
	"encoding/json"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

// Nothing leaves the stack (config/fxa/no-telemetry.env, docs/accounts.md#telemetry): the
// accounts pages' own settings, the page config the content server writes into every page
// (its meta tag, which the pages' scripts read), say whether the pages send anything to
// Mozilla. Glean (usage pings, to incoming.telemetry.mozilla.org by default), Sentry (error
// reports) and Nimbus (experiments) must be off, and the Glean endpoint the pages themselves.
// A new release of Mozilla's with a changed default, or a setting that got lost: a setup
// check says so

const telemetryCheck = "Telemetry of the accounts pages"

// the meta tags of the page config: fxa-config (the settings app, React), the older
// fxa-content-server-config
var pageConfigMetas = map[string]bool{"fxa-config": true, "fxa-content-server-config": true}

var (
	metaTag  = regexp.MustCompile(`(?is)<meta\b[^>]*>`)
	metaAttr = regexp.MustCompile(`(?is)\b(name|content)\s*=\s*("[^"]*"|'[^']*')`)
)

// pageConfig: the parts of the page config about what the pages send
type pageConfig struct {
	Glean *struct {
		Enabled        bool   `json:"enabled"`
		UploadEnabled  bool   `json:"uploadEnabled"`
		ServerEndpoint string `json:"serverEndpoint"`
	} `json:"glean"`
	Sentry *struct {
		DSN string `json:"dsn"`
	} `json:"sentry"`
	Nimbus *struct {
		Enabled bool `json:"enabled"`
	} `json:"nimbus"`
}

// parsePageConfig: the page config of an accounts page (its meta tag: URL-encoded JSON)
func parsePageConfig(page string) (*pageConfig, error) {
	for _, tag := range metaTag.FindAllString(page, -1) {
		attrs := map[string]string{}
		for _, m := range metaAttr.FindAllStringSubmatch(tag, -1) {
			attrs[strings.ToLower(m[1])] = html.UnescapeString(m[2][1 : len(m[2])-1])
		}
		if !pageConfigMetas[attrs["name"]] {
			continue
		}
		raw, err := url.PathUnescape(attrs["content"])
		if err != nil {
			return nil, fmt.Errorf("the page config (meta %s) is not URL-encoded: %v", attrs["name"], err)
		}
		var c pageConfig
		if err := json.Unmarshal([]byte(raw), &c); err != nil {
			return nil, fmt.Errorf("the page config (meta %s) is not JSON: %v", attrs["name"], err)
		}
		if c.Glean == nil || c.Sentry == nil {
			return nil, fmt.Errorf("the page config (meta %s) has no glean or sentry settings any more", attrs["name"])
		}
		return &c, nil
	}
	return nil, fmt.Errorf("no page config in the page (meta fxa-config)")
}

// telemetryOn: what the pages would send, and where to, by these settings (content: the
// stack's accounts pages, FXA_CONTENT_URL); none: nothing leaves the stack. The pages turn
// Glean on by themselves whatever glean.enabled says (fxa-settings' App: signed out always,
// signed in with the account's data collection switch on) and send to glean.serverEndpoint,
// Mozilla's incoming.telemetry.mozilla.org when it is empty: it must be the pages themselves
func telemetryOn(c *pageConfig, content string) []string {
	var on []string
	if c.Glean.Enabled {
		on = append(on, "Glean is on (GLEAN_ENABLED)")
	}
	if c.Glean.UploadEnabled {
		on = append(on, "Glean's upload is on (GLEAN_UPLOAD_ENABLED)")
	}
	switch endpoint := c.Glean.ServerEndpoint; {
	case endpoint == "":
		on = append(on, "no Glean endpoint (GLEAN_SERVER_ENDPOINT empty): the pages send their Glean pings to Mozilla's default, incoming.telemetry.mozilla.org")
	case !sameURLOrigin(endpoint, content):
		on = append(on, "the pages send their Glean pings to "+endpoint+" (GLEAN_SERVER_ENDPOINT), not to the accounts pages ("+content+")")
	}
	if dsn := c.Sentry.DSN; dsn != "" {
		host := dsn
		if u, err := url.Parse(dsn); err == nil && u.Host != "" {
			host = u.Host
		}
		on = append(on, "Sentry is on (SENTRY_DSN): the pages report their errors to "+host)
	}
	if c.Nimbus != nil && c.Nimbus.Enabled {
		on = append(on, "Nimbus experiments are on (NIMBUS_ENABLED)")
	}
	return on
}

// sameURLOrigin: a and b have the same scheme and host (and port)
func sameURLOrigin(a, b string) bool {
	ua, err1 := url.Parse(strings.TrimSpace(a))
	ub, err2 := url.Parse(strings.TrimSpace(b))
	return err1 == nil && err2 == nil && ua.Host != "" && strings.EqualFold(ua.Scheme, ub.Scheme) && strings.EqualFold(ua.Host, ub.Host)
}

// accountsTelemetry: the check of the hidden component telemetryCheck, the page config of
// the content server's /settings page (internally, page: FXA_CONTENT_INTERNAL_URL; public:
// FXA_CONTENT_URL)
func (h *Health) accountsTelemetry(ctx context.Context, page, public string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, page, nil)
	if err != nil {
		return "", err
	}
	res, err := h.client.Do(req)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return "", fmt.Errorf("%s: status %d", page, res.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if err != nil {
		return "", err
	}
	c, err := parsePageConfig(string(body))
	if err != nil {
		return "", warning{fmt.Sprintf("%s: %v, so whether the pages send anything to Mozilla is unknown", page, err)}
	}
	if on := telemetryOn(c, public); len(on) > 0 {
		return "", warning{strings.Join(on, "; ")}
	}
	return "Glean, Sentry and Nimbus off, and their Glean pings to themselves (" + c.Glean.ServerEndpoint + ", which answers 404)", nil
}

// telemetrySetupCheck: the setup check of the hidden component telemetryCheck
func telemetrySetupCheck(comp Component, d deployment) setupCheck {
	c := setupCheck{Name: telemetryCheck, OK: comp.Up, Checked: comp.Checked, Next: comp.Next}
	file := "config/fxa/no-telemetry.env, the env_file of the accounts services in compose/fxa.yml,"
	switch {
	case d.Kubernetes() != nil:
		file = "the chart's files/fxa/no-telemetry.env, the first env entries of every accounts container,"
	case d.Quadlets():
		file = "config/fxa/no-telemetry.env, the EnvironmentFile= of the accounts units,"
	}
	switch {
	case comp.pending():
		c.OK, c.Text = true, "The accounts pages' settings are read once they are up."
	case comp.Up:
		c.Text = "The accounts pages run with " + comp.Detail + ": they send nothing to Mozilla (" + strings.TrimSuffix(file, ",") + ", turns it all off: docs/accounts.md#telemetry)."
	case comp.Warn:
		c.Text = "The accounts pages may send data out of this stack: " + comp.Error + ". " + strings.ToUpper(file[:1]) + file[1:] +
			" turns all of it off: check that every accounts service still reads it, and whether a new release renamed a setting (docs/accounts.md#telemetry)."
	default:
		c.Text = "Could not read the accounts pages' settings: " + comp.Error + "."
	}
	return c
}

// telemetryCheckOf: the hidden component of the accounts pages' telemetry, every hour (a
// new release changes it, and only a restart does), after the accounts pages are up
func (h *Health) telemetryCheckOf(content, public string) check {
	page := strings.TrimSuffix(content, "/") + "/settings"
	retry := 5 * time.Duration(envInt("HEALTH_CHECK_SECONDS", 60)) * time.Second
	return check{name: telemetryCheck, run: func(ctx context.Context) (string, error) { return h.accountsTelemetry(ctx, page, public) },
		every: time.Hour, retry: retry, hidden: true, after: []string{"Accounts pages"}}
}
