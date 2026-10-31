package main

import (
	"crypto/subtle"
	"fmt"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"time"
)

func unixOrZero(t time.Time) int64 {
	if t.IsZero() {
		return 0
	}
	return t.Unix()
}

// Prometheus metrics at /metrics, with METRICS_TOKEN as bearer token (no token: off)

var promName = regexp.MustCompile(`[^a-zA-Z0-9_]`)

func promLabel(v string) string {
	return strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`).Replace(v)
}

func (a *App) prometheus(w http.ResponseWriter, r *http.Request) {
	token := env("METRICS_TOKEN", "")
	given := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if token == "" || subtle.ConstantTimeCompare([]byte(given), []byte(token)) != 1 {
		http.NotFound(w, r)
		return
	}
	ctx := r.Context()
	var b strings.Builder
	gauge := func(name, help string, value int64, labels ...string) {
		fmt.Fprintf(&b, "# HELP %s %s\n# TYPE %s gauge\n", name, help, name)
		if len(labels) == 2 {
			fmt.Fprintf(&b, "%s{%s=\"%s\"} %d\n", name, labels[0], promLabel(labels[1]), value)
		} else {
			fmt.Fprintf(&b, "%s %d\n", name, value)
		}
	}
	flag := func(b bool) int64 {
		if b {
			return 1
		}
		return 0
	}
	if st, err := a.sync.Status(ctx); err == nil {
		gauge("ffs_sync_accounts", "Accounts using this Sync server", int64(st.Users))
		// MAX_USERS=unlimited: no limit to compare with
		if !st.Unlimited {
			gauge("ffs_sync_max_users", "Maximum accounts (SYNC_MAX_USERS)", int64(st.MaxUsers))
		}
		gauge("ffs_sync_near_max_users", "1 when 90% of max users or more are taken", flag(nearMaxUsers(st)))
		gauge("ffs_sync_full", "1 when every place of max users is taken: new accounts are refused", flag(st.Limit().State() == limitFull))
	}
	if a.storage != nil {
		if totals, err := a.storage.Totals(ctx); err == nil {
			var items, bytes int64
			for _, u := range totals {
				items += u.Items
				bytes += u.Bytes
			}
			gauge("ffs_sync_stored_items", "Items stored by all accounts", items)
			gauge("ffs_sync_stored_bytes", "Bytes stored by all accounts", bytes)
		}
	}
	if a.fxa != nil {
		if l, err := a.fxa.AccountLimit(ctx); err == nil {
			gauge("ffs_accounts", "Accounts of the self-hosted accounts service", int64(l.Count))
			if !l.Unlimited {
				gauge("ffs_accounts_max", "Maximum accounts of the self-hosted accounts service (FXA_MAX_ACCOUNTS)", int64(l.Max))
			}
			gauge("ffs_accounts_near_max", "1 when 90% of FXA_MAX_ACCOUNTS or more are created", flag(l.State() != limitOK))
			gauge("ffs_accounts_full", "1 when FXA_MAX_ACCOUNTS accounts are created: sign-ups are refused", flag(l.State() == limitFull))
		}
	}
	if a.health != nil {
		b.WriteString("# HELP ffs_up Whether a component answers its health check\n# TYPE ffs_up gauge\n")
		for _, c := range a.health.Components() {
			up := 0
			if c.Up {
				up = 1
			}
			fmt.Fprintf(&b, "ffs_up{component=\"%s\"} %d\n", promLabel(c.Name), up)
		}
		b.WriteString("# HELP ffs_database_bytes Size of a database\n# TYPE ffs_database_bytes gauge\n")
		sizes := a.health.Sizes()
		names := make([]string, 0, len(sizes))
		for n := range sizes {
			names = append(names, n)
		}
		sort.Strings(names)
		for _, n := range names {
			fmt.Fprintf(&b, "ffs_database_bytes{database=\"%s\"} %d\n", promLabel(n), sizes[n])
		}
	}
	if a.health != nil {
		certs := a.health.Certs()
		hosts := make([]string, 0, len(certs))
		for h := range certs {
			hosts = append(hosts, h)
		}
		sort.Strings(hosts)
		if len(hosts) > 0 {
			b.WriteString("# HELP ffs_cert_expiry_seconds Seconds until the certificate of a public host name expires\n# TYPE ffs_cert_expiry_seconds gauge\n")
		}
		for _, h := range hosts {
			fmt.Fprintf(&b, "ffs_cert_expiry_seconds{host=\"%s\"} %d\n", promLabel(h), int64(time.Until(certs[h]).Seconds()))
		}
	}
	if a.alerter.emails() {
		st := a.alerter.Status()
		gauge("ffs_alert_last_success_timestamp_seconds", "When the last alert email was sent (Unix time, 0: none since the start)", unixOrZero(st.LastOK))
		gauge("ffs_alert_send_failing", "1 when the last alert email could not be sent", flag(alertsFailing(&st)))
	}
	if statuses := a.alerter.NotifyStatuses(); len(statuses) > 0 {
		b.WriteString("# HELP ffs_notify_failures_total Alerts to a destination of ADMIN_NOTIFY that could not be sent (after the retry), since the start\n# TYPE ffs_notify_failures_total counter\n")
		for _, st := range statuses {
			fmt.Fprintf(&b, "ffs_notify_failures_total{destination=\"%s\"} %d\n", promLabel(st.Name), st.Failures)
		}
		b.WriteString("# HELP ffs_notify_last_success_timestamp_seconds When the last alert went out to a destination of ADMIN_NOTIFY (Unix time, 0: none since the start)\n# TYPE ffs_notify_last_success_timestamp_seconds gauge\n")
		for _, st := range statuses {
			fmt.Fprintf(&b, "ffs_notify_last_success_timestamp_seconds{destination=\"%s\"} %d\n", promLabel(st.Name), unixOrZero(st.Status.LastOK))
		}
		b.WriteString("# HELP ffs_notify_alerts_lost_total Alerts a destination of ADMIN_NOTIFY refused as they were (400, 413, 422), not sent again\n# TYPE ffs_notify_alerts_lost_total counter\n")
		for _, st := range statuses {
			fmt.Fprintf(&b, "ffs_notify_alerts_lost_total{destination=\"%s\"} %d\n", promLabel(st.Name), st.Lost)
		}
		b.WriteString("# HELP ffs_notify_test_failures_total Test notifications to a destination of ADMIN_NOTIFY that could not be sent, since the start\n# TYPE ffs_notify_test_failures_total counter\n")
		for _, st := range statuses {
			fmt.Fprintf(&b, "ffs_notify_test_failures_total{destination=\"%s\"} %d\n", promLabel(st.Name), st.TestFailures)
		}
		b.WriteString("# HELP ffs_notify_send_failing 1 when the last alert to a destination of ADMIN_NOTIFY could not be sent\n# TYPE ffs_notify_send_failing gauge\n")
		for _, st := range statuses {
			fmt.Fprintf(&b, "ffs_notify_send_failing{destination=\"%s\"} %d\n", promLabel(st.Name), flag(st.Status.Err != ""))
		}
	}
	if a.health != nil {
		_, silent := a.metrics()
		gauge("ffs_statsd_silent", "1 when the Sync server is up and Sync data changed more than 10 minutes after its last metrics", flag(silent))
		backupMetrics(&b, a.health.Backups(), time.Now())
		if a.accountEvents {
			securityMetrics(&b, a.health.SecurityCounts())
		}
	}
	if a.health != nil {
		thresholdMetrics(&b, a.health)
		setupMetrics(&b, a.health.Setup())
	}
	// what the Sync server sent since the admin UI started
	cumulative := a.rec.Cumulative()
	b.WriteString("# HELP ffs_sync_errors_total Errors of the Sync server by kind since the admin UI started (the tokens refused: ffs_statsd_total of syncstorage_token_verification minus syncstorage_token_creation)\n# TYPE ffs_sync_errors_total counter\n")
	for _, r := range errorTotals(cumulative) {
		fmt.Fprintf(&b, "ffs_sync_errors_total{service=\"%s\",status=\"%s\",kind=\"%s\"} %d\n", promLabel(r.Service), promLabel(r.Status), promLabel(errorLabel(r)), r.Count)
	}
	names := make([]string, 0, len(cumulative))
	for n := range cumulative {
		names = append(names, n)
	}
	sort.Strings(names)
	b.WriteString("# HELP ffs_statsd_total statsd metrics of the Sync server (count of events) since the admin UI started\n# TYPE ffs_statsd_total counter\n")
	for _, n := range names {
		fmt.Fprintf(&b, "ffs_statsd_total{name=\"%s\"} %d\n", promLabel(promName.ReplaceAllString(n, "_")), cumulative[n].count)
	}
	b.WriteString("# HELP ffs_statsd_ms_total Sum of the timings of the Sync server since the admin UI started\n# TYPE ffs_statsd_ms_total counter\n")
	for _, n := range names {
		if cumulative[n].total > 0 {
			fmt.Fprintf(&b, "ffs_statsd_ms_total{name=\"%s\"} %g\n", promLabel(promName.ReplaceAllString(n, "_")), cumulative[n].total)
		}
	}
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	w.Write([]byte(b.String()))
}

// thresholdMetrics: the error rate of the last check and the growth of the databases,
// with whether each alerts (only when on, and once checked)
func thresholdMetrics(b *strings.Builder, h *Health) {
	flag := func(v bool) int {
		if v {
			return 1
		}
		return 0
	}
	if e := h.ErrorRate(); e != nil {
		fmt.Fprintf(b, "# HELP ffs_sync_error_ratio Share of the Sync requests that failed in the last 15 minutes\n# TYPE ffs_sync_error_ratio gauge\nffs_sync_error_ratio %g\n", e.Window.Percent()/100)
		fmt.Fprintf(b, "# HELP ffs_sync_error_spike 1 during a spike of errors (ADMIN_ERROR_RATE_PERCENT)\n# TYPE ffs_sync_error_spike gauge\nffs_sync_error_spike %d\n", flag(e.Spike))
	}
	if growth := h.Growth(); len(growth) > 0 {
		b.WriteString("# HELP ffs_database_growth_bytes Growth of a database in the last 24 hours\n# TYPE ffs_database_growth_bytes gauge\n")
		for _, g := range growth {
			fmt.Fprintf(b, "ffs_database_growth_bytes{database=\"%s\"} %d\n", promLabel(g.Database), g.PerDay)
		}
		b.WriteString("# HELP ffs_database_growth_alert 1 when a database grows faster than ADMIN_DB_GROWTH_MB or ADMIN_DB_GROWTH_FACTOR\n# TYPE ffs_database_growth_alert gauge\n")
		for _, g := range growth {
			fmt.Fprintf(b, "ffs_database_growth_alert{database=\"%s\"} %d\n", promLabel(g.Database), flag(g.Alert))
		}
	}
}

// backupMetrics: per scope the age of the last good backup, and whether the last run worked
func backupMetrics(b *strings.Builder, backups []BackupStatus, now time.Time) {
	if len(backups) == 0 {
		return
	}
	b.WriteString("# HELP ffs_backup_age_seconds Seconds since the last good backup finished\n# TYPE ffs_backup_age_seconds gauge\n")
	for _, s := range backups {
		if !s.LastOK.Finished.IsZero() {
			fmt.Fprintf(b, "ffs_backup_age_seconds{scope=\"%s\"} %d\n", promLabel(s.Scope), int64(now.Sub(s.LastOK.Finished).Seconds()))
		}
	}
	b.WriteString("# HELP ffs_backup_last_ok Whether the last backup worked\n# TYPE ffs_backup_last_ok gauge\n")
	for _, s := range backups {
		ok := 0
		if s.Last.OK {
			ok = 1
		}
		fmt.Fprintf(b, "ffs_backup_last_ok{scope=\"%s\"} %d\n", promLabel(s.Scope), ok)
	}
}
