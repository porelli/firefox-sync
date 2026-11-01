package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"net/http"
	"regexp"
	"strings"
	"time"
)

// Invite-only Sync, SYNC_ALLOWED_ACCOUNTS (docs/limits.md#sync_allowed_accounts): with it on,
// the tokenserver's trigger (db/<engine>/init/allowlist.sql) lets a new account in only when
// its uid is in sync_allowed_accounts, and records the others in sync_refused_accounts. The
// overview lists those as pending, with Approve and Reject, the uids allowed with Remove,
// and a form to allow a uid; each through a confirm page, recorded with who did it. The
// admin UI's user changes the lists through the init container's procedures (functions with
// PostgreSQL), as max users.

// allowlistSetting: what SYNC_ALLOWED_ACCOUNTS says, as the init container reads it: on
// unless empty; managed here with admin or initial:..., otherwise read-only (the list is
// set again on every start)
func allowlistSetting(value string) (on, editable bool) {
	value = strings.Join(strings.Fields(value), "")
	return value != "", value == "admin" || strings.HasPrefix(value, "initial:")
}

// allowlistEditableEnv: from SYNC_ALLOWED_ACCOUNTS of the admin UI's environment
func allowlistEditableEnv() bool {
	_, editable := allowlistSetting(env("SYNC_ALLOWED_ACCOUNTS", ""))
	return editable
}

var uidPattern = regexp.MustCompile(`^[0-9a-f]{32}$`)

// accountUID: a uid of Mozilla's accounts, 32 hexadecimal characters, lowercase
func accountUID(s string) (string, error) {
	uid := strings.ToLower(strings.TrimSpace(s))
	if !uidPattern.MatchString(uid) {
		return "", fmt.Errorf("an account id is 32 hexadecimal characters, not %q", oneLine(s, 64))
	}
	return uid, nil
}

type AllowedAccount struct {
	UID, Note, AddedBy string
	AddedAt            time.Time
	// it has tokenserver rows: it synced already
	Syncs bool
}

type RefusedAccount struct {
	UID                string
	FirstAt, LastAt    time.Time
	Attempts           int
	RejectedAt         time.Time // zero: pending
	RejectedBy         string
	ValidUID, Rejected bool
	// its event written (the first refusal's, once); ID: named in that event
	Reported bool
	ID       int64
}

// SyncAllowlist: what the overview shows
type SyncAllowlist struct {
	Editable          bool
	Allowed           []AllowedAccount
	Pending, Rejected []RefusedAccount
}

// AllowlistOn: the init container turned the allowlist on (config allowed_accounts = on)
func (s *SyncDB) AllowlistOn(ctx context.Context) (bool, error) {
	var n int
	err := s.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM config WHERE config_value = 'on' AND config_key = 'allowed_accounts'").Scan(&n)
	return n > 0, err
}

func (s *SyncDB) AllowedAccounts(ctx context.Context) ([]AllowedAccount, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT a.uid, a.note, a.added_at, a.added_by,
		CASE WHEN EXISTS (SELECT 1 FROM users u WHERE u.email LIKE CONCAT(a.uid, '@%')) THEN 1 ELSE 0 END
		FROM sync_allowed_accounts a ORDER BY a.added_at, a.uid`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []AllowedAccount
	for rows.Next() {
		var a AllowedAccount
		var at, syncs int64
		if err := rows.Scan(&a.UID, &a.Note, &at, &a.AddedBy, &syncs); err != nil {
			return nil, err
		}
		a.AddedAt, a.Syncs = ms(at), syncs != 0
		list = append(list, a)
	}
	return list, rows.Err()
}

// RefusedAccounts: newest first
func (s *SyncDB) RefusedAccounts(ctx context.Context) ([]RefusedAccount, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT uid, first_at, last_at, attempts, COALESCE(rejected_at, 0), COALESCE(rejected_by, ''),
		CASE WHEN reported_at IS NULL THEN 0 ELSE 1 END, id
		FROM sync_refused_accounts WHERE uid <> '*dropped*' ORDER BY first_at DESC, uid`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []RefusedAccount
	for rows.Next() {
		var r RefusedAccount
		var first, last, rejected, reported int64
		if err := rows.Scan(&r.UID, &first, &last, &r.Attempts, &rejected, &r.RejectedBy, &reported, &r.ID); err != nil {
			return nil, err
		}
		r.FirstAt, r.LastAt, r.Rejected = ms(first), ms(last), rejected != 0
		if r.Rejected {
			r.RejectedAt = ms(rejected)
		}
		r.ValidUID, r.Reported = uidPattern.MatchString(r.UID), reported != 0
		list = append(list, r)
	}
	return list, rows.Err()
}

// call: a procedure of the init container (a function with PostgreSQL)
func (s *SyncDB) call(ctx context.Context, name string, args ...any) error {
	marks := strings.TrimSuffix(strings.Repeat("?, ", len(args)), ", ")
	query := "CALL " + name + "(" + marks + ")"
	if s.postgres {
		query = s.q("SELECT " + name + "(" + marks + ")")
	}
	_, err := s.db.ExecContext(ctx, query, args...)
	return err
}

func (s *SyncDB) AllowAccount(ctx context.Context, uid, note, by string) error {
	return s.call(ctx, "ffs_allow_account", uid, oneLine(note, 255), oneLine(by, 255))
}

func (s *SyncDB) RemoveAllowedAccount(ctx context.Context, uid string) error {
	return s.call(ctx, "ffs_remove_allowed_account", uid)
}

func (s *SyncDB) RejectAccount(ctx context.Context, uid, by string) error {
	return s.call(ctx, "ffs_reject_account", uid, oneLine(by, 255))
}

// DroppedRefusals: the refusals not recorded because the list was full (1000 accounts, none
// it could let go: rejected, or not reported yet), and the last one
func (s *SyncDB) DroppedRefusals(ctx context.Context) (int, time.Time, error) {
	var n int
	var last int64
	err := s.db.QueryRowContext(ctx, "SELECT attempts, last_at FROM sync_refused_accounts WHERE uid = '*dropped*'").Scan(&n, &last)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, time.Time{}, nil
	}
	return n, ms(last), err
}

// MarkRefusalReported: the event of the refusal is written (its row keeps it: no clock, no
// cursor, the same after a restart)
func (s *SyncDB) MarkRefusalReported(ctx context.Context, uid string) error {
	return s.call(ctx, "ffs_mark_refusal_reported", uid)
}

// syncAllowlist: the lists of the overview, nil when the allowlist is off
func (a *App) syncAllowlist(ctx context.Context) (*SyncAllowlist, error) {
	on, err := a.sync.AllowlistOn(ctx)
	if err != nil || !on {
		return nil, err
	}
	l := &SyncAllowlist{Editable: a.allowlistEditable}
	if l.Allowed, err = a.sync.AllowedAccounts(ctx); err != nil {
		return l, err
	}
	refused, err := a.sync.RefusedAccounts(ctx)
	for _, r := range refused {
		if r.Rejected {
			l.Rejected = append(l.Rejected, r)
		} else {
			l.Pending = append(l.Pending, r)
		}
	}
	return l, err
}

// pendingCount: the accounts waiting for an approval, -1 when the allowlist is off or not read
func (a *App) pendingCount(ctx context.Context) int {
	l, err := a.syncAllowlist(ctx)
	if err != nil || l == nil {
		return -1
	}
	return len(l.Pending)
}

var errAllowlistOff = errors.New("invite-only Sync is off: SYNC_ALLOWED_ACCOUNTS is empty")

// allowlistReadOnly: why the list cannot be changed here, as this deployment sets it
func (a *App) allowlistReadOnly() error {
	if a.deployment.Kubernetes() != nil {
		return errors.New("the allowlist is managed by allowedAccounts in the chart's values: set allowedAccounts: admin (or initial:<uids>) and helm upgrade to manage it here")
	}
	return errors.New("the allowlist is managed by SYNC_ALLOWED_ACCOUNTS in .env: set SYNC_ALLOWED_ACCOUNTS=admin (or initial:<uids>) there to manage it here")
}

const allowlistBack = "/#sync-allowlist"

// allowlistActions: what each action of the allowlist needs (editable: not with a list of
// .env) and its words
var allowlistActions = map[string]struct {
	editable      bool
	title, button string
}{
	"allow":  {true, "Allow", "Allow the account"},
	"reject": {false, "Reject", "Reject the account"},
	"remove": {true, "Remove from the allowlist", "Remove from the list"},
}

// allowlistTarget: the uid of a form or link of the allowlist, and the pending entry
// of it, if any; an error for the page when it cannot be acted on
func (a *App) allowlistTarget(ctx context.Context, action, raw string) (string, *RefusedAccount, *SyncAllowlist, error) {
	act, ok := allowlistActions[action]
	if !ok {
		return "", nil, nil, errNotFound
	}
	l, err := a.syncAllowlist(ctx)
	if err != nil {
		return "", nil, nil, err
	}
	if l == nil {
		return "", nil, nil, errAllowlistOff
	}
	if act.editable && !a.allowlistEditable {
		return "", nil, nil, a.allowlistReadOnly()
	}
	uid, err := accountUID(raw)
	if err != nil {
		// a pending entry that is no uid (a mock FxA's, a self-hosted one of another
		// domain): only rejected
		if action != "reject" {
			return "", nil, nil, err
		}
		uid = strings.ToLower(strings.TrimSpace(raw))
	}
	var refused *RefusedAccount
	for _, r := range append(append([]RefusedAccount{}, l.Pending...), l.Rejected...) {
		if r.UID == uid {
			refused = &r
			break
		}
	}
	listed := false
	for _, al := range l.Allowed {
		listed = listed || al.UID == uid
	}
	switch {
	case action == "reject" && (refused == nil || refused.Rejected):
		return "", nil, nil, errNotFound
	case action == "remove" && !listed:
		return "", nil, nil, errNotFound
	}
	return uid, refused, l, nil
}

var errNotFound = errors.New("not found")

// confirmAllowlist: the confirm page of allow, reject and remove (GET /sync/allowlist/{action}?uid=)
func (a *App) confirmAllowlist(w http.ResponseWriter, r *http.Request, s *session) {
	action := r.PathValue("action")
	q := r.URL.Query()
	uid, refused, _, err := a.allowlistTarget(r.Context(), action, q.Get("uid"))
	switch {
	case errors.Is(err, errNotFound):
		http.NotFound(w, r)
		return
	case err != nil:
		// back to the overview, with why
		a.doneTo(w, r, s, allowlistBack, "", err)
		return
	}
	act := allowlistActions[action]
	var effects []string
	hidden := map[string]string{"uid": uid}
	switch action {
	case "allow":
		effects = append(effects, "This account can start to sync: its next try gets in (Firefox tries again by itself, or with Sync now in its settings).")
		if refused != nil {
			effects = append(effects, fmt.Sprintf("It was refused %s, first on %s, last on %s; it goes from the pending list.",
				plural(refused.Attempts, "time"), formatTime(refused.FirstAt, adminZone), formatTime(refused.LastAt, adminZone)))
		}
		if st, err := a.sync.Status(r.Context()); err == nil && st.Limit().State() == limitFull {
			effects = append(effects, fmt.Sprintf("Max users is full (%d of %d places): it is still refused until there is room.", st.Users, st.MaxUsers))
		}
		if note, err := cleanNote(q.Get("note")); err == nil && note != "" {
			hidden["note"] = oneLine(note, 255)
			effects = append(effects, "Its note on the list: "+hidden["note"])
		}
	case "reject":
		effects = []string{
			"It stays refused, and goes from the pending list: its next tries are counted, without an alert.",
			"You can still allow it later, from the rejected ones or with Allow a uid.",
		}
	case "remove":
		effects = []string{
			"It goes from the allowlist: this account can no longer start to sync here.",
			"If it syncs already, it keeps working (it has its rows in the tokenserver): to stop it, delete its Sync data on its page.",
		}
	}
	data := a.base(s)
	data["Name"], data["Back"], data["MaxReason"], data["Post"], data["Crumb"] = uid, allowlistBack, maxReason, "/sync/allowlist/"+action, "Invite-only Sync"
	data["Action"] = confirmAction{Title: act.title, Button: act.button, Hidden: hidden, Effects: effects}
	a.render(w, "confirm.html", data)
}

// changeAllowlist: the forms of the confirm pages (POST /sync/allowlist/{action}, uid, note)
func (a *App) changeAllowlist(w http.ResponseWriter, r *http.Request, s *session) {
	action := r.PathValue("action")
	uid, refused, _, err := a.allowlistTarget(r.Context(), action, r.PostFormValue("uid"))
	if errors.Is(err, errNotFound) {
		err = fmt.Errorf("no account %s to %s", oneLine(r.PostFormValue("uid"), 64), action)
	}
	if err != nil {
		a.doneTo(w, r, s, allowlistBack, "", err)
		return
	}
	var message string
	switch action {
	case "allow":
		message = "Allowed Sync account " + uid
		if refused != nil {
			message = "Approved Sync account " + uid
		}
		note, _ := cleanNote(r.PostFormValue("note"))
		if note = oneLine(note, 255); note != "" {
			message += " (note: " + note + ")"
		}
		err = a.sync.AllowAccount(r.Context(), uid, note, auditWho(s))
	case "reject":
		message = "Rejected Sync account " + uid
		err = a.sync.RejectAccount(r.Context(), uid, auditWho(s))
	case "remove":
		message = "Removed Sync account " + uid + " from the allowlist"
		err = a.sync.RemoveAllowedAccount(r.Context(), uid)
	}
	a.doneTo(w, r, s, allowlistBack, message, err)
}

// refusalEvent: the event of an account refused by the allowlist (kind sign-up refused, alerted),
// with the id of its row: a second pass knows it is written
func refusalEvent(uid string, id int64) string {
	return fmt.Sprintf("Sync: account %s is not on the allowlist (SYNC_ALLOWED_ACCOUNTS): refused, waiting for your approval (refusal %d)", oneLine(uid, 64), id)
}

// watchRefusals: an event (and its alert) for each account the allowlist refused that has none
// yet: its first refusal, not its retries, nor the rejected ones. The row is marked reported
// (ffs_mark_refusal_reported) only once the event is in the log: one dropped by the limit per
// minute of its kind, or not written, stops the pass, the next round goes on. Dying between the
// event and the mark leaves it unmarked: the next pass finds the event by the row's id, and
// only marks it. At least once in the log, one alert.
func (h *Health) watchRefusals(ctx context.Context) {
	app := h.app
	if app == nil || app.sync == nil {
		return
	}
	on, err := app.sync.AllowlistOn(ctx)
	if err != nil || !on {
		return
	}
	refused, err := app.sync.RefusedAccounts(ctx)
	if err != nil {
		log.Printf("watching the refused Sync accounts: %v", err)
		return
	}
	// oldest first
	for i := len(refused) - 1; i >= 0; i-- {
		r := refused[i]
		if r.Reported || r.Rejected {
			continue
		}
		detail := refusalEvent(r.UID, r.ID)
		written, err := app.refusalLogged(ctx, detail)
		if err != nil {
			log.Printf("watching the refused Sync accounts: %v", err)
			return
		}
		if !written {
			if app.rec != nil {
				if written, err = app.rec.EventWritten("sign-up refused", detail); err != nil || !written {
					// (logged by the recorder) or over its limit: the next round
					return
				}
			}
			app.alert("sign-up refused", detail)
		}
		if err := app.sync.MarkRefusalReported(ctx, r.UID); err != nil {
			log.Printf("watching the refused Sync accounts: %v", err)
			return
		}
	}
}

// refusalLogged: the event of a refusal is in the log already (a pass that died before its mark)
func (a *App) refusalLogged(ctx context.Context, detail string) (bool, error) {
	if a.rec == nil {
		return false, nil
	}
	var n int
	err := a.sync.mine().QueryRowContext(ctx, a.sync.q("SELECT COUNT(*) FROM ffs_events WHERE kind = ? AND detail = ?"), "sign-up refused", oneLine(detail, 509)).Scan(&n)
	return n > 0, err
}

// droppedCheck: the setup check of refusals not recorded, for a week after the last one
func (a *App) droppedCheck(ctx context.Context, now time.Time) (setupCheck, bool) {
	if on, err := a.sync.AllowlistOn(ctx); err != nil || !on {
		return setupCheck{}, false
	}
	n, last, err := a.sync.DroppedRefusals(ctx)
	if err != nil || n == 0 || now.Sub(last) > 7*24*time.Hour {
		return setupCheck{}, false
	}
	return setupCheck{Name: "Pending accounts list", Text: fmt.Sprintf("%s refused without a record since the list was full, the last at %s: it keeps 1000 accounts and lets go only pending ones already alerted, never rejected ones. Approve or reject the pending accounts to make room.",
		plural(n, "account"), formatTime(last, adminZone))}, true
}

// allowlistValue: the allowlist in force, for the configuration page
func (a *App) allowlistValue() string {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	l, err := a.syncAllowlist(ctx)
	switch {
	case err != nil:
		return "not read"
	case l == nil:
		return "off: every account can sync"
	}
	return fmt.Sprintf("on: %s allowed, %d pending", plural(len(l.Allowed), "account"), len(l.Pending))
}

// allowlistNote: where the allowlist comes from, as SYNC_ALLOWED_ACCOUNTS says
func allowlistNote(name, raw string) string {
	on, editable := allowlistSetting(raw)
	switch {
	case !on:
		return name + " not set: off"
	case editable:
		return name + "=" + oneLine(raw, 80) + ": managed on the overview"
	}
	return name + " lists the accounts: set again on every start, read-only on the overview"
}
