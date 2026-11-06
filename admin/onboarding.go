package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/mail"
	"net/url"
	"strings"
	"time"
)

// Bringing someone in: the allowlist entry of their email, an invitation by email with
// the steps to set up Firefox, and the same steps on the "Connect a device" page.

const (
	invitesPerHour = 20
	invitePath     = "/accounts/invite"
)

// deviceSetup: how to point one kind of Firefox to this server
type deviceSetup struct {
	Device string
	Steps  []string
}

// deviceSteps: the steps of docs/firefox.md#self-hosted-accounts (self-hosted accounts: content is FXA_CONTENT_URL)
// or of docs/firefox.md (Mozilla's accounts, content empty) with this server's values. node is
// the Sync node, pairing FXA_PAIRING_URL (empty: Mozilla's pairing server)
func deviceSteps(content, node, pairing string) []deviceSetup {
	tokenserver := strings.TrimSuffix(node, "/") + "/1.0/sync/1.5"
	if content == "" {
		return []deviceSetup{
			{"Firefox on a computer", []string{
				"Open about:config, search for identity.sync.tokenserver.uri and set it to " + tokenserver + ".",
				"Sign in to Firefox with your Mozilla account and turn on Sync.",
			}},
			{"Firefox for Android", []string{
				"In Settings > About Firefox, tap the Firefox logo 5 times: \"debug menu enabled\".",
				"Back in Settings, tap Sync Debug, then Custom Sync server, and set it to " + tokenserver + ".",
				"Sign in to Firefox and turn on Sync.",
			}},
			{"Firefox for iOS", []string{
				"In Settings, tap the version number 5 times.",
				"In Advanced Sync Settings, turn on Use Custom Sync Token Server and set Custom Sync Token Server URI to " + tokenserver + ".",
				"Sign in to Firefox and turn on Sync.",
			}},
		}
	}
	pairingServer := "Mozilla's pairing server"
	if pairing != "" {
		pairingServer = "this server's pairing server (" + pairing + ")"
	}
	return []deviceSetup{
		{"Firefox on a computer", []string{
			"Open about:config, set identity.fxaccounts.autoconfig.uri to " + content + " and restart Firefox.",
			"Sign in from the account icon of the toolbar (or Settings > Sync) and turn on Sync.",
		}},
		{"Firefox for Android", []string{
			"In Settings > About Firefox, tap the Firefox logo 5 times: \"debug menu enabled\".",
			"Back in Settings, tap Sync Debug and set Custom Mozilla account server to " + content + ". Leave Custom Sync server empty: the accounts server tells Firefox where the Sync server is.",
			"Restart Firefox when it asks, then sign in and turn on Sync.",
		}},
		{"Firefox for iOS", []string{
			"In Settings, tap the version number 5 times.",
			"In Advanced Sync Settings, turn on Use Custom FxA Content Server and set Custom Account Content Server URI to " + content + ".",
			"Sign in and turn on Sync.",
		}},
		{"A phone, from a computer already signed in", []string{
			"Set up Firefox on the phone as above first, then on the computer open Settings > Sync > Connect another device: it shows a QR code.",
			"Scan it with Firefox on the phone. The two pair through " + pairingServer + ".",
		}},
	}
}

// stepsText: the steps as plain text, for the email
func stepsText(setups []deviceSetup) string {
	var b strings.Builder
	for _, s := range setups {
		b.WriteString(s.Device + ":\r\n")
		for i, step := range s.Steps {
			fmt.Fprintf(&b, "  %d. %s\r\n", i+1, step)
		}
		b.WriteString("\r\n")
	}
	return b.String()
}

// signupLink: the accounts pages go on to the sign-up page of that email (?email=, see
// test_fxa_browser.py: shown there, not in a field)
func signupLink(content, email string) string {
	return content + "/?email=" + url.QueryEscape(email)
}

// inviteEmail: plain text, links as they are (no tracking)
func inviteEmail(content, node, pairing, email string, closed bool) (subject, body string) {
	host := content
	if u, err := url.Parse(content); err == nil && u.Host != "" {
		host = u.Host
	}
	subject = "Your Firefox Sync account on " + host
	body = "You are invited to sync Firefox with " + host + ", a Firefox Sync server run by your administrator: your bookmarks, history, passwords and tabs, encrypted by Firefox, on all your devices.\r\n\r\n"
	if closed {
		body += "Sign-ups are closed for now: your administrator will tell you when you can create your account.\r\n\r\n"
	}
	body += "1. Create your account: this link opens the sign-up page with " + email + ", choose a password, then type the code sent to this address:\r\n   " +
		signupLink(content, email) + "\r\n" +
		"   Already have an account there? Sign in with it instead.\r\n\r\n" +
		"2. Point each Firefox to this server, then sign in with that account:\r\n\r\n" + stepsText(deviceSteps(content, node, pairing)) +
		"Your passwords and history are encrypted by Firefox with your account password: if you forget it, a reset keeps your data only with an account recovery key (create one in the account settings: " + content + "/settings).\r\n"
	return subject, body
}

// syncNode: the Sync node Firefox gets (the first one in use), else SYNCSTORAGE_DOMAIN
func (a *App) syncNode(ctx context.Context) string {
	if st, err := a.sync.Status(ctx); err == nil {
		for _, n := range st.Nodes {
			if !n.Downed {
				return n.Node
			}
		}
	}
	return a.syncDomain
}

// connectPage: the steps to set up Firefox with this server
func (a *App) connectPage(w http.ResponseWriter, r *http.Request, s *session) {
	data := a.base(s)
	node := a.syncNode(r.Context())
	content := ""
	if a.fxa != nil {
		content = a.contentURL
	}
	data["Node"], data["Content"], data["Pairing"] = node, content, a.pairingURL
	data["Setups"] = deviceSteps(content, node, a.pairingURL)
	// the addresses to type, apart from the steps
	data["Tokenserver"] = strings.TrimSuffix(node, "/") + "/1.0/sync/1.5"
	if content != "" {
		data["Signup"] = content + "/signup"
	}
	a.render(w, "connect.html", data)
}

// inviteAllowed counts an invitation: at most invitesPerHour, whoever sends them (a
// stolen session must not make this server a spammer)
func (a *App) inviteAllowed(now time.Time) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	kept := a.invites[:0]
	for _, t := range a.invites {
		if now.Sub(t) < time.Hour {
			kept = append(kept, t)
		}
	}
	a.invites = kept
	if len(a.invites) >= invitesPerHour {
		return false
	}
	a.invites = append(a.invites, now)
	return true
}

// invite: the email on the allowlist (with the policy allowlist), and the steps by email
func (a *App) invite(w http.ResponseWriter, r *http.Request, s *session) {
	if a.fxa == nil {
		http.NotFound(w, r)
		return
	}
	ctx := r.Context()
	email := strings.ToLower(strings.TrimSpace(r.PostFormValue("email")))
	// one plain address: it goes into the To header, and the allowlist takes emails only
	if addr, err := mail.ParseAddress(email); err != nil || addr.Address != email || addr.Name != "" || !emailEntry.MatchString(email) || len(email) > 255 {
		a.done(w, r, s, "", fmt.Errorf("not an email: %q", oneLine(email, 100)))
		return
	}
	policy, err := a.fxa.Policy(ctx)
	if err != nil {
		a.done(w, r, s, "", err)
		return
	}
	if !a.inviteAllowed(time.Now()) {
		a.done(w, r, s, "", fmt.Errorf("at most %d invitations an hour: try again later", invitesPerHour))
		return
	}
	message := "Invited " + email
	var notes []string
	switch policy.Mode {
	case SignupsAllowlist:
		if err := a.fxa.AddToAllowlist(ctx, email); err != nil {
			a.done(w, r, s, "", err)
			return
		}
		message += " (added to the sign-up allowlist)"
	case SignupsClosed:
		notes = append(notes, "sign-ups are closed: "+email+" cannot create an account until you open them")
	}
	subject, body := inviteEmail(a.contentURL, a.syncNode(ctx), a.pairingURL, email, policy.Mode == SignupsClosed)
	if err := a.sendMail(email, subject, body); err != nil {
		notes = append(notes, "the email was not sent ("+err.Error()+"): give them the steps of the Connect a device page")
	} else {
		message += ", email sent"
	}
	err = nil
	if len(notes) > 0 {
		err = &partialError{errors.New(strings.Join(notes, "; "))}
	}
	a.done(w, r, s, message, err)
}

// removeFromAllowlist: one entry of the allowlist
func (a *App) removeFromAllowlist(w http.ResponseWriter, r *http.Request, s *session) {
	if a.fxa == nil {
		http.NotFound(w, r)
		return
	}
	entry := strings.ToLower(strings.TrimSpace(r.PostFormValue("entry")))
	found, err := a.fxa.RemoveFromAllowlist(r.Context(), entry)
	if err == nil && !found {
		err = fmt.Errorf("%q is not on the allowlist", oneLine(entry, 100))
	}
	a.doneTo(w, r, s, backTo(r, "/"), "Removed "+oneLine(entry, 255)+" from the sign-up allowlist", err)
}

// allowRow: an email of the allowlist and whether it signed up
type allowRow struct {
	Email    string
	Added    time.Time
	SignedUp time.Time // zero: not yet
	UID      string
}

// allowRows splits the allowlist into its emails, with whether each has an account
// (compared without case, as the sign-up policy does), and its domains
func allowRows(entries []AllowEntry, accounts []FxaAccount) (emails []allowRow, domains []string) {
	byEmail := map[string]*FxaAccount{}
	for i := range accounts {
		byEmail[strings.ToLower(accounts[i].Email)] = &accounts[i]
	}
	for _, e := range entries {
		if strings.HasPrefix(e.Entry, "@") {
			domains = append(domains, e.Entry)
			continue
		}
		row := allowRow{Email: e.Entry, Added: e.Added}
		if acc := byEmail[e.Entry]; acc != nil {
			row.SignedUp, row.UID = acc.CreatedAt, acc.UID
		}
		emails = append(emails, row)
	}
	return emails, domains
}
