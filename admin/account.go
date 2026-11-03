package main

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"net/mail"
	"strings"
	"time"
)

// Helping the owners of self-hosted accounts: two-step authentication and recovery
// keys they lost, an email confirmation that never arrived, and notes on any account.

// removeSignInMethod turns off two-step authentication (action remove-totp) or removes
// the recovery key (remove-recovery-key), signs out everywhere when asked (sign_out)
// and tells the owner by email
func (a *App) removeSignInMethod(action string) handler {
	return func(w http.ResponseWriter, r *http.Request, s *session) {
		if a.fxa == nil {
			http.NotFound(w, r)
			return
		}
		ctx := r.Context()
		uid := strings.ToLower(r.PathValue("uid"))
		acc := a.account(r, uid)
		var err error
		var message string
		if action == "remove-totp" {
			err = a.fxa.RemoveTOTP(ctx, uid)
			message = "Turned off two-step authentication of " + accountLabel(acc, uid)
		} else {
			err = a.fxa.RemoveRecoveryKey(ctx, uid)
			message = "Removed the account recovery key of " + accountLabel(acc, uid)
		}
		var partial *partialError
		if err != nil && !errors.As(err, &partial) {
			a.doneTo(w, r, s, "/users/"+uid, "", err)
			return
		}
		// what else happened, and what did not (after the change: still audited)
		var done, problems []string
		if err != nil {
			problems = append(problems, err.Error())
		}
		if r.PostFormValue("sign_out") != "" {
			if e := a.fxa.SignOutAll(ctx, uid); e != nil {
				problems = append(problems, "signing out everywhere: "+e.Error())
			} else {
				done = append(done, "signed out everywhere")
			}
		}
		if sent, e := a.notifyOwner(acc, action, "", time.Now()); e != nil {
			problems = append(problems, "the notice to the owner: "+e.Error())
		} else {
			done = append(done, sent)
		}
		if len(done) > 0 {
			message += " (" + strings.Join(done, ", ") + ")"
		}
		err = nil
		if len(problems) > 0 {
			err = &partialError{errors.New(strings.Join(problems, "; "))}
		}
		a.doneTo(w, r, s, "/users/"+uid, message, err)
	}
}

// notifyOwner emails the owner of an account what an admin changed (detail: the sign-ins
// confirmed, of confirm-email and confirm-sign-in): what happened, for the message and the event
func (a *App) notifyOwner(acc *FxaAccount, action, detail string, at time.Time) (string, error) {
	if acc == nil {
		return "", errors.New("account not found")
	}
	// one plain address: it goes into the To header
	if addr, err := mail.ParseAddress(acc.Email); err != nil || addr.Address != acc.Email || addr.Name != "" {
		return "", fmt.Errorf("not an address to write to")
	}
	if a.mailer == nil {
		return "no notice to the owner: no SMTP server (FXA_SMTP_HOST)", nil
	}
	subject, body := ownerNotice(action, acc.Email, detail, a.contentURL, at)
	if err := a.sendMail(acc.Email, subject, body); err != nil {
		return "", err
	}
	return "owner notified", nil
}

// ownerNotice is the email to the owner of an account after an admin turned off two-step
// authentication, removed the recovery key, confirmed the email or a sign-in: someone
// asking for it may not be them
func ownerNotice(action, email, detail, contentURL string, at time.Time) (subject, body string) {
	when := formatTime(at, adminZone) + " (" + adminZone.String() + ")"
	settings := contentURL + "/settings"
	switch action {
	case "confirm-email":
		subject = "Your account's email confirmed by an administrator"
		body = "An administrator confirmed the email address of your account " + email + " on " + when + ", without the code sent to it.\r\n"
		if detail != "" {
			body += "\r\nThese sign-ins, waiting for their code, were confirmed too: " + detail + ".\r\n"
		}
		body += "\r\nYour devices and sessions are in your account settings: " + settings + "\r\n"
	case "confirm-sign-in":
		subject = "A sign-in to your account confirmed by an administrator"
		body = "An administrator confirmed a sign-in to your account " + email + " on " + when + ", without the code sent to this address: " + detail + ".\r\n\r\n" +
			"Whoever made it is signed in. Your devices and sessions are in your account settings, where you can sign it out: " + settings + "\r\n"
	case "remove-totp":
		subject = "Two-step authentication turned off on your account"
		body = "An administrator turned off two-step authentication on your account " + email + " on " + when +
			", with its backup authentication codes and recovery phone.\r\n\r\n" +
			"You now sign in with your password and a code sent to this address. Turn two-step authentication on again in your account settings: " + settings + "\r\n"
	default:
		subject = "Account recovery key removed from your account"
		body = "An administrator removed the account recovery key of your account " + email + " on " + when + ".\r\n\r\n" +
			"Create a new one in your account settings, so that a password reset keeps your synced data: " + settings + "\r\n"
	}
	body += "\r\nIf you did not ask for this, change your password there and tell your administrator.\r\n"
	return subject, body
}

// the refusals of ffs.confirm_session
const (
	errEmailNotConfirmed = "the email is not confirmed: confirming the email confirms its sign-ins too"
	errTwoStepSignIn     = "two-step authentication is on: the sign-in waits for the code of the authenticator app"
	errSignInConfirmed   = "the sign-in is already confirmed"
)

// at most this many sign-ins confirmed with the email (the form lists them)
const maxConfirmedSignIns = 50

// pendingSignIns: the sessions waiting for their code
func pendingSignIns(sessions []Session) []Session {
	var pending []Session
	for _, se := range sessions {
		if !se.Verified {
			pending = append(pending, se)
		}
	}
	return pending
}

// signInLabel: "Firefox on laptop, 2026-11-03 09:30", for the event log (withIP: and
// where from, for the owner's notice)
func signInLabel(se Session, withIP bool) string {
	name := se.Device
	switch {
	case name != "":
	case se.Browser != "" && se.OS != "":
		name = se.Browser + " on " + se.OS
	case se.Browser != "" || se.OS != "":
		name = se.Browser + se.OS
	default:
		name = "an unknown browser"
	}
	label := name + ", " + formatTime(se.CreatedAt, adminZone)
	if withIP && se.IP != "" {
		label += ", from " + se.IP
	}
	return label
}

// signInRefs: the sessions field of the form, the refs of the sign-ins listed on the
// confirm page (and nothing else: one made since is not confirmed)
func signInRefs(field string) ([]string, error) {
	var refs []string
	seen := map[string]bool{}
	for _, ref := range strings.FieldsFunc(strings.ToLower(field), func(r rune) bool { return r == ' ' || r == ',' }) {
		if b, err := hex.DecodeString(ref); err != nil || len(b) != 32 {
			return nil, errors.New("invalid session")
		}
		if !seen[ref] {
			seen[ref] = true
			refs = append(refs, ref)
		}
	}
	if len(refs) > maxConfirmedSignIns {
		return nil, fmt.Errorf("more than %d sign-ins", maxConfirmedSignIns)
	}
	return refs, nil
}

// confirmEmail marks the email of an unconfirmed account as confirmed, then the sign-ins
// its confirm page listed (field sessions) as if their code had been entered, and tells
// the owner by email
func (a *App) confirmEmail(w http.ResponseWriter, r *http.Request, s *session) {
	if a.fxa == nil {
		http.NotFound(w, r)
		return
	}
	ctx := r.Context()
	uid := strings.ToLower(r.PathValue("uid"))
	acc := a.account(r, uid)
	refs, err := signInRefs(r.PostFormValue("sessions"))
	if err != nil {
		a.doneTo(w, r, s, "/users/"+uid, "", err)
		return
	}
	// the labels, read before: a confirmed sign-in is no longer told apart
	byRef := map[string]Session{}
	if len(refs) > 0 {
		if _, sessions, e := a.fxa.Devices(ctx, uid); e == nil {
			for _, se := range sessions {
				byRef[se.Ref] = se
			}
		}
	}
	err = a.fxa.ConfirmEmail(ctx, uid)
	var partial *partialError
	if err != nil && !errors.As(err, &partial) {
		a.doneTo(w, r, s, "/users/"+uid, "", err)
		return
	}
	var problems, confirmed []string
	if err != nil {
		problems = append(problems, err.Error())
	}
	for _, ref := range refs {
		if e := a.fxa.ConfirmSession(ctx, uid, ref); e != nil {
			problems = append(problems, "a sign-in: "+e.Error())
			continue
		}
		label := "a sign-in"
		if se, ok := byRef[ref]; ok {
			label = signInLabel(se, true)
		}
		confirmed = append(confirmed, label)
	}
	message := "Confirmed the email of " + accountLabel(acc, uid)
	if len(confirmed) > 0 {
		message += " and its " + plural(len(confirmed), "pending sign-in")
	}
	if sent, e := a.notifyOwner(acc, "confirm-email", strings.Join(confirmed, "; "), time.Now()); e != nil {
		problems = append(problems, "the notice to the owner: "+e.Error())
	} else {
		message += " (" + sent + ")"
	}
	err = nil
	if len(problems) > 0 {
		err = &partialError{errors.New(strings.Join(problems, "; "))}
	}
	a.doneTo(w, r, s, "/users/"+uid, message, err)
}

// confirmSignIn confirms one sign-in waiting for its code (a new device, after the email
// was confirmed), as if the code had been entered, and tells the owner by email
func (a *App) confirmSignIn(w http.ResponseWriter, r *http.Request, s *session) {
	if a.fxa == nil {
		http.NotFound(w, r)
		return
	}
	ctx := r.Context()
	uid, ref := strings.ToLower(r.PathValue("uid")), strings.ToLower(r.PathValue("ref"))
	acc := a.account(r, uid)
	var found *Session
	if _, sessions, err := a.fxa.Devices(ctx, uid); err == nil {
		for _, se := range sessions {
			if se.Ref == ref {
				found = &se
			}
		}
	}
	if err := a.fxa.ConfirmSession(ctx, uid, ref); err != nil {
		a.doneTo(w, r, s, "/users/"+uid, "", err)
		return
	}
	label, detail := "a sign-in", "a sign-in"
	if found != nil {
		label, detail = signInLabel(*found, false), signInLabel(*found, true)
	}
	message := "Confirmed a sign-in of " + accountLabel(acc, uid) + " (" + label + ")"
	var err error
	if sent, e := a.notifyOwner(acc, "confirm-sign-in", detail, time.Now()); e != nil {
		err = &partialError{errors.New("the notice to the owner: " + e.Error())}
	} else {
		message += " (" + sent + ")"
	}
	a.doneTo(w, r, s, "/users/"+uid, message, err)
}

// setNote saves the note of an account: with self-hosted accounts or Mozilla's, any
// account that has an account page
func (a *App) setNote(w http.ResponseWriter, r *http.Request, s *session) {
	ctx := r.Context()
	uid := strings.ToLower(r.PathValue("uid"))
	label, ok := a.knownAccount(r, uid)
	if !ok {
		http.NotFound(w, r)
		return
	}
	note, err := cleanNote(r.PostFormValue("note"))
	if err != nil {
		a.doneTo(w, r, s, "/users/"+uid, "", err)
		return
	}
	err = a.sync.SetNote(ctx, uid, note, noteAuthor(s))
	message := "Removed the note of " + label
	if note != "" {
		message = fmt.Sprintf("Note of %s set to %q", label, oneLine(note, 200))
	}
	a.doneTo(w, r, s, "/users/"+uid, message, err)
}

// addToNote adds text (the reason of disabling) to the note of an account
func (a *App) addToNote(ctx context.Context, uid, text string, s *session) error {
	old, err := a.sync.Note(ctx, uid)
	if err != nil {
		return err
	}
	// as in the event log (auditText), within maxNote
	text, err = cleanNote(oneLine(strings.TrimSpace(text), maxReason))
	if err != nil {
		return err
	}
	note := text
	if old != nil && old.Text != "" {
		note = old.Text + "; " + text
	}
	// the newest at the end: cut the oldest
	if runes := []rune(note); len(runes) > maxNote {
		note = string(runes[len(runes)-maxNote:])
	}
	return a.sync.SetNote(ctx, uid, note, noteAuthor(s))
}

func noteAuthor(s *session) string {
	return auditWho(s)
}

// knownAccount: the label of an account with that uid, self-hosted or using Sync
func (a *App) knownAccount(r *http.Request, uid string) (string, bool) {
	if len(uid) == 0 || len(uid) > 64 {
		return "", false
	}
	if a.fxa != nil {
		if _, err := accountID(uid); err == nil {
			if acc := a.account(r, uid); acc != nil {
				return accountLabel(acc, uid), true
			}
		}
	}
	user, err := a.sync.User(r.Context(), uid)
	if err != nil || user == nil {
		return "", false
	}
	return accountLabel(nil, uid), true
}
