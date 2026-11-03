package main

import (
	"fmt"
	"net/http"
	"strings"
)

// Destructive actions are never one click away: their links lead to a page that says
// what will happen, with the form that does it (POST, with the session's token). The
// POST routes stay as they are, for scripts and the tests. Without JavaScript: the
// CSP has default-src 'none'.

type confirmAction struct {
	Title   string   // "Disable alice@example.com?" is Title + email
	Button  string   // the submit button
	Effects []string // what happens
	// for deleting: the admin types the account's email too (field confirm_email), or
	// with TypeUID its id (no email: Mozilla's accounts)
	TypeEmail, TypeUID bool
	// checkboxes, off by default
	Checks []confirmCheck
	// hidden fields of the form (a collection...)
	Hidden map[string]string
	// the devices and sessions signed out are listed
	Lists bool
	// the sign-ins waiting for their code (data Pending) are listed, as confirmed by it
	Pending bool
	// the reason also goes into the account's note
	ReasonToNote bool
	// a checkbox "also sign out everywhere" (field sign_out), on by default: after a
	// takeover the attacker's sessions go too
	SignOut bool
}

type confirmCheck struct{ Name, Label string }

var accountActions = map[string]confirmAction{
	"disable": {
		Title:  "Disable",
		Button: "Disable the account",
		Effects: []string{
			"Every device and session below is signed out, and the account's OAuth tokens are revoked.",
			"Nobody can sign in to the account until you enable it again; its data stays.",
			"Firefox may sync for up to 1 hour more with the Sync token it has (the Sync server also remembers a checked access token for 5 minutes).",
		},
		Lists:        true,
		ReasonToNote: true,
	},
	"sign-out-all": {
		Title:  "Sign out everywhere",
		Button: "Sign out everywhere",
		Effects: []string{
			"Every device and session below is signed out, and the account's OAuth tokens are revoked: each Firefox asks to sign in again.",
			"The account stays active: its owner can sign in again right away, e.g. after changing the password.",
			"Firefox may sync for up to 1 hour more with the Sync token it has (the Sync server also remembers a checked access token for 5 minutes).",
		},
		Lists: true,
	},
	"remove-totp": {
		Title:  "Turn off two-step authentication of",
		Button: "Turn off two-step authentication",
		Effects: []string{
			"The authenticator app, the backup authentication codes and the recovery phone of the account stop working: its owner signs in with the password and a code sent by email.",
			"Make sure who is asking first: from now on the password and the mailbox are enough to get in.",
			"The owner gets an email saying that an administrator turned it off. They can turn it on again in the account settings.",
		},
		SignOut: true,
	},
	"remove-recovery-key": {
		Title:  "Remove the account recovery key of",
		Button: "Remove the recovery key",
		Effects: []string{
			"The recovery key stops working: a password reset without it loses the Sync data, unless a Firefox that still has the data uploads it again.",
			"The owner gets an email saying that an administrator removed it. They can create a new one in the account settings.",
		},
		SignOut: true,
	},
	"confirm-email": {
		Title:  "Confirm the email of",
		Button: "Confirm the email",
		Effects: []string{
			"The email is marked as confirmed without the code sent to it: this skips the proof that whoever signed up owns the address. Do it only when you know who they are.",
		},
		Pending: true,
	},
}

// the owner's notice, on both confirm pages
const noticeEffect = "The owner gets an email saying that an administrator confirmed it."

// confirmPage is the data of confirm.html
func (a *App) confirmPage(w http.ResponseWriter, r *http.Request, s *session, act confirmAction, post string) (map[string]any, *FxaAccount) {
	if a.fxa == nil {
		http.NotFound(w, r)
		return nil, nil
	}
	uid := strings.ToLower(r.PathValue("uid"))
	if _, err := accountID(uid); err != nil {
		http.NotFound(w, r)
		return nil, nil
	}
	acc, err := a.fxa.Account(r.Context(), uid)
	if err != nil {
		http.Error(w, "Accounts: "+err.Error(), http.StatusInternalServerError)
		return nil, nil
	}
	if acc == nil {
		http.NotFound(w, r)
		return nil, nil
	}
	data := a.base(s)
	data["Account"], data["Name"], data["Action"], data["Post"], data["Back"], data["MaxReason"] = acc, acc.Email, act, post, "/users/"+uid, maxReason
	devices, sessions, err := a.fxa.Devices(r.Context(), uid)
	if err != nil {
		data["Errors"] = []string{"Devices: " + err.Error()}
	}
	data["Devices"], data["Sessions"] = devices, sessions
	return data, acc
}

func (a *App) confirmAccount(w http.ResponseWriter, r *http.Request, s *session) {
	act, ok := accountActions[r.PathValue("action")]
	if !ok {
		http.NotFound(w, r)
		return
	}
	uid := strings.ToLower(r.PathValue("uid"))
	data, _ := a.confirmPage(w, r, s, act, "/accounts/"+uid+"/"+r.PathValue("action"))
	if data == nil {
		return
	}
	if act.Pending {
		// the sign-ins waiting now, and only those: one made after this page is not
		// confirmed by its form
		sessions, _ := data["Sessions"].([]Session)
		pending := pendingSignIns(sessions)
		if len(pending) > maxConfirmedSignIns {
			pending = pending[:maxConfirmedSignIns]
		}
		refs := make([]string, len(pending))
		for i, se := range pending {
			refs[i] = se.Ref
		}
		act.Effects = append([]string(nil), act.Effects...)
		if len(pending) > 0 {
			these := "The sign-in below, waiting for its code, is confirmed too, as if the code had been entered: whoever made it gets in."
			if len(pending) > 1 {
				these = fmt.Sprintf("The %d sign-ins below, waiting for their code, are confirmed too, as if the code had been entered: whoever made them gets in.", len(pending))
			}
			act.Effects = append(act.Effects, these+" A sign-in made after this page is not.",
				"A browser still showing the code prompt does not notice: the person signs in again there. Within 48 hours of the sign-up that sign-in asks for no code; later, a new sign-in asks for one (Confirm this sign-in… on the account page).")
		} else {
			act.Effects = append(act.Effects, "No sign-in is waiting for its code now: the next one asks for it, unless the account is less than 48 hours old (Confirm this sign-in… on the account page).")
		}
		act.Effects = append(act.Effects, noticeEffect)
		act.Hidden = map[string]string{"sessions": strings.Join(refs, " ")}
		data["Action"], data["Pending"] = act, pending
	}
	a.render(w, "confirm.html", data)
}

// confirmSignInPage: confirming one sign-in waiting for its code
func (a *App) confirmSignInPage(w http.ResponseWriter, r *http.Request, s *session) {
	act := confirmAction{Title: "Confirm a sign-in of", Button: "Confirm the sign-in", Pending: true,
		Effects: []string{
			"Only if you know this sign-in is theirs: whoever has the password gets in. It is confirmed without the code sent to the address, as if it had been entered.",
			"A browser still showing the code prompt does not notice, and signing in again there asks for a new code once the account is 48 hours old: the confirmed session serves a browser that kept it, such as the account settings once reloaded.",
			noticeEffect,
		}}
	uid, ref := strings.ToLower(r.PathValue("uid")), strings.ToLower(r.PathValue("ref"))
	data, _ := a.confirmPage(w, r, s, act, "/users/"+uid+"/sessions/"+ref+"/confirm")
	if data == nil {
		return
	}
	sessions, _ := data["Sessions"].([]Session)
	var only []Session
	for _, se := range pendingSignIns(sessions) {
		if se.Ref == ref {
			only = append(only, se)
		}
	}
	if len(only) == 0 && data["Errors"] == nil {
		http.NotFound(w, r)
		return
	}
	data["Devices"], data["Sessions"], data["Pending"] = nil, nil, only
	a.render(w, "confirm.html", data)
}

func (a *App) confirmDevice(w http.ResponseWriter, r *http.Request, s *session) {
	act := confirmAction{Title: "Sign out a device of", Button: "Sign out the device", Lists: true,
		Effects: []string{
			"The device below is removed with the session or token it signed in with: Firefox there asks to sign in again.",
			"Its access tokens work until they expire (FXA_ACCESS_TOKEN_LIFETIME); the account keeps working everywhere else.",
		}}
	uid, id := strings.ToLower(r.PathValue("uid")), strings.ToLower(r.PathValue("id"))
	data, _ := a.confirmPage(w, r, s, act, "/users/"+uid+"/devices/"+id+"/sign-out")
	if data == nil {
		return
	}
	devices, _ := data["Devices"].([]Device)
	var only []Device
	for _, d := range devices {
		if d.ID == id {
			only = append(only, d)
		}
	}
	if len(only) == 0 && data["Errors"] == nil {
		http.NotFound(w, r)
		return
	}
	data["Devices"], data["Sessions"] = only, nil
	a.render(w, "confirm.html", data)
}

func (a *App) confirmSession(w http.ResponseWriter, r *http.Request, s *session) {
	act := confirmAction{Title: "Sign out a session of", Button: "Sign out the session", Lists: true,
		Effects: []string{
			"The session below ends, and the device it registered: the browser there asks to sign in again.",
			"The account keeps working everywhere else.",
		}}
	uid, ref := strings.ToLower(r.PathValue("uid")), strings.ToLower(r.PathValue("ref"))
	data, _ := a.confirmPage(w, r, s, act, "/users/"+uid+"/sessions/"+ref+"/sign-out")
	if data == nil {
		return
	}
	sessions, _ := data["Sessions"].([]Session)
	var only []Session
	for _, se := range sessions {
		if se.Ref == ref {
			only = append(only, se)
		}
	}
	if len(only) == 0 && data["Errors"] == nil {
		http.NotFound(w, r)
		return
	}
	data["Devices"], data["Sessions"] = nil, only
	a.render(w, "confirm.html", data)
}

// confirmPrune: what "Prune the accounts database now" removes (the Activity page)
func (a *App) confirmPrune(w http.ResponseWriter, r *http.Request, s *session) {
	if a.fxa == nil {
		http.NotFound(w, r)
		return
	}
	data := a.base(s)
	data["Name"], data["Back"], data["MaxReason"], data["Post"] = "the accounts database", "/activity#maintenance", maxReason, "/maintenance/prune"
	data["Crumb"], data["Nav"] = "Activity", "activity"
	data["Action"] = confirmAction{Title: "Prune", Button: "Prune now", Effects: []string{
		"Deletes for good what has expired: unblock and sign-in codes older than 30 days, password reset and change tokens and sessions without a device older than 4 weeks (the session of a Firefox has its device and stays), OAuth codes older than 15 minutes.",
		fmt.Sprintf("Also the security events of the account settings older than %s (ADMIN_RETENTION_DAYS): the account owners no longer see them.", plural(a.retentionDays(), "day")),
		"The accounts, their devices and their Sync data stay. It runs by itself every day anyway: this only runs it now.",
	}}
	a.render(w, "confirm.html", data)
}

// confirmAllowlistRemove: removing an email or a domain from the sign-up allowlist
func (a *App) confirmAllowlistRemove(w http.ResponseWriter, r *http.Request, s *session) {
	if a.fxa == nil {
		http.NotFound(w, r)
		return
	}
	entry := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("entry")))
	entries, err := a.fxa.AllowlistEntries(r.Context())
	if err != nil {
		http.Error(w, "Allowlist: "+err.Error(), http.StatusInternalServerError)
		return
	}
	found := false
	for _, e := range entries {
		found = found || e.Entry == entry
	}
	if !found {
		http.NotFound(w, r)
		return
	}
	policy, err := a.fxa.Policy(r.Context())
	if err != nil {
		http.Error(w, "Sign-up policy: "+err.Error(), http.StatusInternalServerError)
		return
	}
	effects := []string{"It goes from the sign-up allowlist: whoever has this email can no longer create an account here. An account already created with it stays, and keeps working."}
	if strings.HasPrefix(entry, "@") {
		effects = []string{"The domain goes from the sign-up allowlist: nobody with an email of " + entry[1:] + " can create an account any more, unless their own email is on the list. Accounts already created stay, and keep working."}
	}
	if policy.Mode != SignupsAllowlist {
		effects = append(effects, fmt.Sprintf("Sign-ups are %s now: the list only applies with \"Only people I list\".", map[string]string{SignupsOpen: "open to anybody", SignupsClosed: "closed"}[policy.Mode]))
	}
	if strings.HasPrefix(entry, "@") {
		effects = append(effects, "To undo it, add it again to the list under Sign-ups.")
	} else {
		effects = append(effects, "To undo it, invite the email again or add it to the list under Sign-ups: it then counts as invited today.")
	}
	data := a.base(s)
	// back to where it is listed, its fold open (?list=open): the domains under Sign-ups,
	// the emails under Invitations
	data["Name"], data["Back"], data["MaxReason"], data["Post"], data["Crumb"] = entry, "/?list=open#invitations", maxReason, "/accounts/allowlist/remove", "Invitations"
	if strings.HasPrefix(entry, "@") {
		data["Back"], data["Crumb"] = "/?list=open#signups", "Sign-ups"
	}
	data["Action"] = confirmAction{Title: "Remove", Button: "Remove from the list", Hidden: map[string]string{"entry": entry}, Effects: effects}
	a.render(w, "confirm.html", data)
}
