package main

import (
	"context"
	"fmt"
	"net"
	"os"
	"sort"
	"strings"
)

// Setup checks of the overview: settings that must agree with each other, with what
// goes wrong when they do not

type setupCheck struct {
	Name string
	OK   bool
	Text string
}

// nodeCheck: the tokenserver hands out its nodes in use, Firefox syncs there; the init
// container sets the node from SYNC_PUBLIC_URL (SYNCSTORAGE_DOMAIN in its environment) on every start
func nodeCheck(d deployment, domain string, nodes []SyncNode) setupCheck {
	c := setupCheck{Name: "Sync node"}
	var inUse []string
	for _, n := range nodes {
		if n.Downed {
			continue
		}
		node := strings.TrimSuffix(n.Node, "/")
		inUse = append(inUse, node)
		if node == domain {
			c.OK = true
		}
	}
	switch {
	case c.OK:
		c.Text = "The tokenserver hands out " + domain + ", the public Sync URL (" + d.setting("SYNC_PUBLIC_URL", "syncDomain") + ")."
	case len(inUse) == 0:
		c.Text = "The tokenserver has no Sync node in use, " + d.setting("SYNC_PUBLIC_URL", "syncDomain") + " is " + domain + ": nobody can sync. The init container adds it when it starts: " + d.startInit() + "."
	default:
		c.Text = fmt.Sprintf("The tokenserver hands out %s, but %s is %s: Firefox syncs with %s. The init container sets the node from it when it starts: %s.",
			strings.Join(inUse, ", "), d.setting("SYNC_PUBLIC_URL", "syncDomain"), domain, inUse[0], d.startInit())
	}
	return c
}

// otherDomains: the accounts of the tokenserver per email domain other than domain
func otherDomains(domain string, counts map[string]int) map[string]int {
	other := map[string]int{}
	for d, n := range counts {
		if d != strings.ToLower(domain) {
			other[d] = n
		}
	}
	return other
}

// domainCheck: the tokenserver names each account <uid>@FXA_EMAIL_DOMAIN. After a change
// of FXA_EMAIL_DOMAIN the same people come back as new accounts: twice against max users
func domainCheck(domain string, counts map[string]int, status *SyncStatus) setupCheck {
	c := setupCheck{Name: "Account emails (FXA_EMAIL_DOMAIN)"}
	other := otherDomains(domain, counts)
	if len(other) == 0 {
		c.OK = true
		c.Text = fmt.Sprintf("The %d accounts of the tokenserver are all <uid>@%s, as FXA_EMAIL_DOMAIN says.", counts[strings.ToLower(domain)], domain)
		return c
	}
	names := make([]string, 0, len(other))
	total := 0
	for d, n := range other {
		names = append(names, fmt.Sprintf("@%s (%d)", d, n))
		total += n
	}
	sort.Strings(names)
	c.Text = fmt.Sprintf("FXA_EMAIL_DOMAIN is %s, but %d accounts of the tokenserver have another domain: %s. The tokenserver names each account <uid>@FXA_EMAIL_DOMAIN: after a change of it everybody comes back as a new account, with empty storage, and counts twice against max users",
		domain, total, strings.Join(names, ", "))
	if status != nil && status.Unlimited {
		c.Text += fmt.Sprintf(" (%d, no limit)", status.Users)
	} else if status != nil {
		c.Text += fmt.Sprintf(" (%d of %d used)", status.Users, status.MaxUsers)
	}
	c.Text += ". Set FXA_EMAIL_DOMAIN back, or remove the old rows from the users table of the tokenserver database."
	return c
}

func (a *App) setupChecks(ctx context.Context, status *SyncStatus, components []Component) []setupCheck {
	var checks []setupCheck
	if a.sync != nil {
		st := a.sync.moved
		// created there since the start, the start refuses the database
		if found, err := a.sync.foreignObjects(ctx); err != nil {
			st.ForeignErr = err.Error()
		} else {
			st.Foreign = found
		}
		checks = append(checks, ownDBCheck(a.sync, st, a.deployment))
	}
	// your own database server: the grants of database-setup.sql (dbsetup.go)
	if c, ok := a.dbSetupCheck(ctx); ok {
		checks = append(checks, c)
	}
	if a.syncDomain != "" && status != nil {
		checks = append(checks, nodeCheck(a.deployment, a.syncDomain, status.Nodes))
	}
	// the old names of .env: none with the Helm chart, which has no .env
	if c, ok := oldNamesCheck(os.Getenv("FFS_OLD_ENV_NAMES")); ok && a.deployment.Kubernetes() == nil {
		checks = append(checks, c)
	}
	for _, comp := range components {
		if comp.Name != oauthKeysCheck {
			continue
		}
		c := setupCheck{Name: oauthKeysCheck, OK: comp.Up, Text: "The Sync server checks every sign-in of Firefox with these keys: " + comp.Detail + "."}
		if !comp.Up {
			c.Text = "The Sync server checks every sign-in of Firefox with the keys of FXA_OAUTH_SERVER_URL, which do not answer (" + comp.Error + "): nobody gets a Sync token. " + a.deployment.checkOAuth()
		}
		checks = append(checks, c)
	}
	if a.fxa != nil {
		c := accountsSMTPCheck(smtpServer())
		if a.deployment.Kubernetes() != nil {
			// the chart's smtp values, no .env
			c.Name = "Email of the accounts (smtp.host)"
			c.Text = strings.Replace(c.Text, "FXA_SMTP_HOST is not set (or still the placeholder of .env-example)", "smtp.host is not set in your values of the chart", 1)
		}
		checks = append(checks, c)
	}
	if a.emailDomain != "" {
		if counts, err := a.sync.EmailDomains(ctx); err != nil {
			checks = append(checks, setupCheck{Name: "Account emails (FXA_EMAIL_DOMAIN)", Text: "Could not read the accounts of the tokenserver: " + err.Error()})
		} else if len(counts) > 0 {
			checks = append(checks, domainCheck(a.emailDomain, counts, status))
		}
	}
	return checks
}

// oldNamesCheck: the Sync settings that .env (or compose's environment) still has under their old names
// (docs/upgrading.md#renamed-settings), from compose (FFS_OLD_ENV_NAMES): they still work, a
// later release removes them. No check without them (the Quadlets have the new names)
func oldNamesCheck(names string) (setupCheck, bool) {
	old := strings.Fields(names)
	if len(old) == 0 {
		return setupCheck{}, false
	}
	return setupCheck{Name: "Old setting names (.env, environment)", Text: "Settings under their old names, in .env or in the environment docker compose runs in, which still work but will be removed in a later release: " +
		strings.Join(old, ", ") + ". Run ./prepare_environment.sh --upgrade, which renames them (docs/upgrading.md#renamed-settings), then docker compose up -d."}, true
}

// accountsSMTPCheck: the self-hosted accounts need an SMTP server whatever the admin UI's
// alerts use (ADMIN_NOTIFY replaces email for the alerts only)
func accountsSMTPCheck(m *Mailer) setupCheck {
	c := setupCheck{Name: "Email of the accounts (FXA_SMTP_HOST)", OK: m != nil}
	if c.OK {
		c.Text = "The accounts service emails the codes of new accounts and new sign-ins, and the password resets, through " + net.JoinHostPort(m.host, m.port) + "."
	} else {
		c.Text = "FXA_SMTP_HOST is not set (or still the placeholder of .env-example): the self-hosted accounts email a code for every new account and every sign-in on a new device, and the password resets, so nobody can sign up or sign in. ADMIN_NOTIFY only replaces email for the admin UI's alerts, not for the accounts."
	}
	return c
}
