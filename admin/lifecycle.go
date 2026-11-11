package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// The life of an account's Sync data: what the tokenserver knows of it (diagnosis),
// starting its Sync data over, and deleting the account for good.

// UserRow is a row of the tokenserver's users table: syncstorage-rs adds one each time
// the keys of an account change, with a new uid, which is its user id in the storage
type UserRow struct {
	ID          int64
	Email       string
	ClientState string
	// as Firefox sent it in X-KeyID: milliseconds with the self-hosted and Mozilla's
	// accounts (seconds in some tests), 0: none
	KeysChangedAt int64
	NodeID        int64
	Node          string
	NodeKnown     bool
	Downed        bool
	CreatedAt     time.Time
	ReplacedAt    time.Time // zero: not replaced
	Current       bool      // the one the tokenserver uses
	Usage         Usage     // what its storage holds (all items, expired too)
}

func (r UserRow) Replaced() bool { return !r.ReplacedAt.IsZero() }

// KeysChanged: KeysChangedAt as a time, zero without one
func (r UserRow) KeysChanged() time.Time {
	switch {
	case r.KeysChangedAt <= 0:
		return time.Time{}
	case r.KeysChangedAt < 1e11: // seconds: before 1973 in milliseconds
		return time.Unix(r.KeysChangedAt, 0)
	}
	return time.UnixMilli(r.KeysChangedAt)
}

// localPart: the account of a tokenserver email, its uid (FxA's, or the id Mozilla's
// accounts give)
func localPart(email string) string {
	uid, _, _ := strings.Cut(email, "@")
	return strings.ToLower(uid)
}

const userRowColumns = `u.uid, u.email, u.client_state, COALESCE(u.keys_changed_at, 0), u.nodeid, COALESCE(n.node, ''),
	COALESCE(n.downed, 0), CASE WHEN n.id IS NULL THEN 0 ELSE 1 END, u.created_at, COALESCE(u.replaced_at, 0)
	FROM users u LEFT JOIN nodes n ON n.id = u.nodeid`

func scanUserRows(rows *sql.Rows) ([]UserRow, error) {
	defer rows.Close()
	var all []UserRow
	for rows.Next() {
		var r UserRow
		var downed, known int
		var created, replaced int64
		if err := rows.Scan(&r.ID, &r.Email, &r.ClientState, &r.KeysChangedAt, &r.NodeID, &r.Node, &downed, &known, &created, &replaced); err != nil {
			return nil, err
		}
		r.Downed, r.NodeKnown, r.CreatedAt, r.ReplacedAt = downed != 0, known != 0, ms(created), ms(replaced)
		all = append(all, r)
	}
	return all, rows.Err()
}

// UserRows: every row of the account uid (any email domain), oldest first, the current
// one marked
func (s *SyncDB) UserRows(ctx context.Context, uid string) ([]UserRow, error) {
	rows, err := s.db.QueryContext(ctx, s.q("SELECT "+userRowColumns+" WHERE LOWER(u.email) LIKE ? ORDER BY u.created_at, u.uid"),
		likeEscape(strings.ToLower(uid))+"@%")
	if err != nil {
		return nil, err
	}
	all, err := scanUserRows(rows)
	if err != nil {
		return nil, err
	}
	var mine []UserRow
	for _, r := range all {
		if localPart(r.Email) == uid {
			mine = append(mine, r)
		}
	}
	markCurrent(mine)
	return mine, nil
}

// AllUserRows: the whole users table, the current row of each email marked
func (s *SyncDB) AllUserRows(ctx context.Context) ([]UserRow, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT "+userRowColumns+" ORDER BY u.created_at, u.uid")
	if err != nil {
		return nil, err
	}
	all, err := scanUserRows(rows)
	if err != nil {
		return nil, err
	}
	markCurrent(all)
	return all, nil
}

// markCurrent marks the row the tokenserver uses for each email: the newest not
// replaced, or the newest (as Users)
func markCurrent(rows []UserRow) {
	best := map[string]int{}
	for i, r := range rows {
		email := strings.ToLower(r.Email)
		j, seen := best[email]
		if !seen || (rows[j].Replaced() && !r.Replaced()) || (rows[j].Replaced() == r.Replaced() && r.ID > rows[j].ID) {
			best[email] = i
		}
	}
	for i := range rows {
		rows[i].Current = false
	}
	for _, i := range best {
		rows[i].Current = true
	}
}

// DeleteUserRows deletes rows of the users table: the account starts again as a new one
// on its next Sync token, through max users
func (s *SyncDB) DeleteUserRows(ctx context.Context, ids []int64) error {
	// MariaDB and MySQL: a procedure of the init container (see SetMaxUsers)
	query := "CALL ffs_delete_user_row(?)"
	if s.postgres {
		query = "DELETE FROM users WHERE uid = $1"
	}
	for _, id := range ids {
		if _, err := s.db.ExecContext(ctx, query, id); err != nil {
			return err
		}
	}
	return nil
}

// UserByStorageID: the account (local part of the email) of a tokenserver uid, "" if none
func (s *SyncDB) UserByStorageID(ctx context.Context, id int64) (string, error) {
	var email string
	err := s.db.QueryRowContext(ctx, s.q("SELECT email FROM users WHERE uid = ?"), id).Scan(&email)
	if err == sql.ErrNoRows {
		return "", nil
	}
	return localPart(email), err
}

// A Flag is something odd in an account's rows, with what it means
type Flag struct {
	Name, Text string
}

// diagnose: what looks wrong in the rows of one account (oldest first, Usage filled)
func diagnose(rows []UserRow) []Flag {
	var flags []Flag
	var open int
	var current *UserRow
	for i := range rows {
		if !rows[i].Replaced() {
			open++
		}
		if rows[i].Current {
			current = &rows[i]
		}
	}
	if open > 1 {
		flags = append(flags, Flag{"Several current rows", fmt.Sprintf("%d rows are not replaced: the tokenserver uses the newest, what the others store is never read.", open)})
	}
	for i := 1; i < len(rows); i++ {
		prev, r := rows[i-1], rows[i]
		if prev.KeysChangedAt > 0 && r.KeysChangedAt > 0 && r.KeysChangedAt < prev.KeysChangedAt {
			flags = append(flags, Flag{"Keys went back in time", fmt.Sprintf("Row %d has an older keys_changed_at than row %d before it: a device with old keys, or the accounts database restored from a backup.", r.ID, prev.ID)})
		}
		if r.ClientState != prev.ClientState && r.KeysChangedAt == prev.KeysChangedAt {
			flags = append(flags, Flag{"Keys changed without a date", fmt.Sprintf("Row %d has new keys (client state) but the same keys_changed_at as row %d: the accounts service did not record the change, devices may disagree on the keys.", r.ID, prev.ID)})
		}
	}
	if current != nil {
		switch {
		case !current.NodeKnown:
			flags = append(flags, Flag{"Unknown node", fmt.Sprintf("The current row points to node %d, which the tokenserver does not have: Sync tokens fail until the account gets a new row.", current.NodeID)})
		case current.Downed:
			flags = append(flags, Flag{"Node retired", "The current row is on " + current.Node + ", which is retired (downed): the tokenserver moves the account on its next sign-in, to empty storage."})
		}
		if current.Usage.Items == 0 {
			for _, r := range rows {
				if r.Replaced() && r.Usage.Items > 0 {
					flags = append(flags, Flag{"Data left on old keys", fmt.Sprintf("The current storage is empty, row %d (replaced) still holds %d items: encrypted with the old keys, Firefox cannot read them; a device that still has the data uploads it again.", r.ID, r.Usage.Items)})
					break
				}
			}
		}
	}
	return flags
}

// syncRows: the rows of an account with what each stores, and the flags
func (a *App) syncRows(ctx context.Context, uid string) ([]UserRow, []Flag, error) {
	rows, err := a.sync.UserRows(ctx, uid)
	if err != nil || len(rows) == 0 {
		return rows, nil, err
	}
	if a.storage != nil {
		ids := make([]int64, len(rows))
		for i := range rows {
			ids[i] = rows[i].ID
		}
		all, err := a.storage.UsageOf(ctx, ids)
		if err != nil {
			return rows, nil, err
		}
		for i := range rows {
			rows[i].Usage = all[rows[i].ID].total()
		}
	}
	return rows, diagnose(rows), nil
}

// find: the account search of the overview, by email (self-hosted accounts), account
// id or tokenserver uid (a number): straight to its page when there is one
func (a *App) find(w http.ResponseWriter, r *http.Request, s *session) {
	ctx := r.Context()
	q := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("q")))
	if q == "" || len(q) > 255 {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	var uid string
	var err error
	if id, e := strconv.ParseInt(q, 10, 64); e == nil && id > 0 {
		uid, err = a.sync.UserByStorageID(ctx, id)
	}
	if uid == "" && err == nil && a.fxa != nil && strings.Contains(q, "@") {
		uid, err = a.fxa.UIDByEmail(ctx, q)
	}
	if uid == "" && err == nil {
		if label, ok := a.knownAccount(r, q); ok && label != "" {
			uid = q
		}
	}
	if err != nil {
		a.doneTo(w, r, s, "/", "", err)
		return
	}
	if uid == "" {
		a.mu.Lock()
		s.failed = fmt.Sprintf("No account %q: search an email, an account id or a tokenserver uid.", oneLine(q, 100))
		a.mu.Unlock()
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	http.Redirect(w, r, "/users/"+url.PathEscape(uid), http.StatusSeeOther)
}

// UIDByEmail: the account with this email (any of its addresses), "" if none
func (f *FxaDB) UIDByEmail(ctx context.Context, email string) (string, error) {
	var uid string
	err := f.db.QueryRowContext(ctx, `SELECT LOWER(HEX(uid)) FROM ffs.emails WHERE LOWER(email) = ? ORDER BY isPrimary DESC LIMIT 1`, email).Scan(&uid)
	if err == sql.ErrNoRows {
		return "", nil
	}
	return uid, err
}

// Starting Sync data over

// resetSync deletes the storage of the account's current uid (or of one collection),
// and with free_slot all its rows and their storage
func (a *App) resetSync(w http.ResponseWriter, r *http.Request, s *session) {
	uid := strings.ToLower(r.PathValue("uid"))
	label, ok := a.knownAccount(r, uid)
	if !ok || a.storage == nil {
		http.NotFound(w, r)
		return
	}
	// past the end of the request: half a reset would be worse
	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 10*time.Minute)
	defer cancel()
	rows, err := a.sync.UserRows(ctx, uid)
	if err != nil {
		a.doneTo(w, r, s, "/users/"+uid, "", err)
		return
	}
	var current *UserRow
	for i := range rows {
		if rows[i].Current {
			current = &rows[i]
		}
	}
	if current == nil {
		a.doneTo(w, r, s, "/users/"+uid, "", errors.New("this account does not use this Sync server"))
		return
	}
	collection := r.PostFormValue("collection")
	freeSlot := r.PostFormValue("free_slot") != "" && collection == ""
	if freeSlot {
		removed, emptied, err := a.deleteSyncRows(ctx, rows, label)
		// no page left without an account elsewhere
		to := "/"
		if err != nil || a.fxa != nil {
			to = "/users/" + uid
		}
		message := fmt.Sprintf("Reset the Sync data of %s (%s) and freed its max users slot (%d tokenserver rows)", label, removed, len(rows))
		if err != nil {
			message = fmt.Sprintf("Reset part of the Sync data of %s (%s, %d of %d storage uids emptied), its max users slot not freed", label, removed, emptied, len(rows))
			err = syncPartial(err, emptied, removed)
		}
		a.doneTo(w, r, s, to, message, err)
		return
	}
	removed, err := a.storage.DeleteStorage(ctx, current.ID, collection)
	what := "the Sync data"
	if collection != "" {
		what = "the " + oneLine(collection, 64) + " collection"
	}
	if err != nil {
		err = syncPartial(err, 0, removed)
	}
	a.doneTo(w, r, s, "/users/"+uid, fmt.Sprintf("Reset %s of %s (%s, storage uid %d)", what, label, removed, current.ID), err)
}

// syncPartial: a failure after some Sync data went is a change made, for the event log
func syncPartial(err error, emptied int, removed Removed) error {
	if emptied > 0 || removed.Items > 0 {
		return &partialError{fmt.Errorf("stopped partway, try again: %w", err)}
	}
	return err
}

// joinPartial: the problems after a change that was made, as one partialError (nil without any)
func joinPartial(errs ...error) error {
	var texts []string
	for _, err := range errs {
		if err != nil {
			texts = append(texts, err.Error())
		}
	}
	if len(texts) == 0 {
		return nil
	}
	return &partialError{errors.New(strings.Join(texts, "; "))}
}

// Deleting for good

// The second pass: Firefox can write with the Sync token it has for up to an hour
// after its rows are gone (and the Sync server trusts a checked access token for 5
// minutes more)
const secondPassAfter = 65 * time.Minute

type secondPass struct {
	due   time.Time
	ids   []int64
	label string
}

type passes struct {
	mu      sync.Mutex
	pending []secondPass
}

func (a *App) scheduleSecondPass(ids []int64, label string, now time.Time) {
	if len(ids) == 0 || a.storage == nil {
		return
	}
	a.passes.mu.Lock()
	defer a.passes.mu.Unlock()
	a.passes.pending = append(a.passes.pending, secondPass{now.Add(secondPassAfter), append([]int64(nil), ids...), label})
}

// duePasses takes the passes due at now
func (a *App) duePasses(now time.Time) []secondPass {
	a.passes.mu.Lock()
	defer a.passes.mu.Unlock()
	var due, later []secondPass
	for _, p := range a.passes.pending {
		if !now.Before(p.due) {
			due = append(due, p)
		} else {
			later = append(later, p)
		}
	}
	a.passes.pending = later
	return due
}

// runSecondPasses deletes again the storage of deleted rows (a restart forgets them:
// the purge finds what is left, storage with no tokenserver row)
func (a *App) runSecondPasses(ctx context.Context, now time.Time) {
	for _, p := range a.duePasses(now) {
		var removed Removed
		var failed error
		for _, id := range p.ids {
			// a row with this uid again: not ours to delete
			if owner, err := a.sync.UserByStorageID(ctx, id); err != nil || owner != "" {
				if err != nil {
					failed = err
				}
				continue
			}
			n, err := a.storage.DeleteStorage(ctx, id, "")
			removed.add(n)
			if err != nil {
				failed = err
			}
		}
		if failed != nil {
			log.Printf("second pass of %s: %v", p.label, failed)
		}
		if removed.Items > 0 || failed != nil {
			detail := fmt.Sprintf("Second pass on the Sync storage of %s: %s written after the deletion removed", p.label, removed)
			if failed != nil {
				detail += " (" + failed.Error() + ")"
			}
			a.event("maintenance", detail)
		}
	}
}

// deleteAccount deletes a disabled self-hosted account and its Sync data, or with
// Mozilla's accounts (or no account left) the Sync data and rows of the uid
func (a *App) deleteAccount(w http.ResponseWriter, r *http.Request, s *session) {
	uid := strings.ToLower(r.PathValue("uid"))
	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 10*time.Minute)
	defer cancel()
	back := "/users/" + uid
	var acc *FxaAccount
	if a.fxa != nil {
		if _, err := accountID(uid); err == nil {
			var err error
			if acc, err = a.fxa.Account(ctx, uid); err != nil {
				a.doneTo(w, r, s, back, "", err)
				return
			}
		}
	}
	rows, err := a.sync.UserRows(ctx, uid)
	if err != nil {
		a.doneTo(w, r, s, back, "", err)
		return
	}
	if acc == nil && len(rows) == 0 {
		http.NotFound(w, r)
		return
	}
	typed := strings.ToLower(strings.TrimSpace(r.PostFormValue("confirm_email")))
	if acc != nil {
		// enabled: ffs.delete_account refuses it, in the same statement as the deletion
		if typed != strings.ToLower(acc.Email) {
			a.doneTo(w, r, s, "/users/"+uid+"/delete", "", errors.New("the email typed is not the account's: nothing deleted"))
			return
		}
	} else if typed != uid {
		a.doneTo(w, r, s, "/users/"+uid+"/delete", "", errors.New("the account id typed is not this one: nothing deleted"))
		return
	}
	label := accountLabel(acc, uid)
	// once the account is gone from the accounts service, every later failure is part
	// of a change made: in the event log
	var warn error
	if acc != nil {
		// the email stays in the event: who was deleted, for the audit trail
		label = fmt.Sprintf("%s (uid %s)", oneLine(acc.Email, 255), uid)
		if err := a.fxa.DeleteAccount(ctx, uid); err != nil {
			var partial *partialError
			if !errors.As(err, &partial) {
				a.doneTo(w, r, s, back, "", err)
				return
			}
			warn = err
		}
	}
	removed, emptied, err := a.deleteSyncRows(ctx, rows, label)
	if err == nil {
		// personal data (docs/admin/accounts.md), and no page left to remove it from
		if e := a.sync.SetNote(ctx, uid, "", noteAuthor(s)); e != nil {
			warn = joinPartial(warn, fmt.Errorf("its note was not removed: %w", e))
		}
	}
	to := "/"
	var message string
	switch {
	case err != nil && acc != nil:
		to = back
		message = fmt.Sprintf("Deleted %s, but only part of its Sync data (%s, %d of %d storage uids emptied)", label, removed, emptied, len(rows))
		err = joinPartial(warn, fmt.Errorf("the Sync data was not all deleted, delete it from the account's page: %w", err))
	case err != nil:
		to = back
		message = fmt.Sprintf("Deleted part of the Sync data of %s (%s, %d of %d storage uids emptied)", label, removed, emptied, len(rows))
		err = syncPartial(err, emptied, removed)
	case acc != nil:
		message = fmt.Sprintf("Deleted %s and its Sync data (%s, %d tokenserver rows)", label, removed, len(rows))
		err = warn
	default:
		message = fmt.Sprintf("Deleted the Sync data of %s (%s, %d tokenserver rows)", label, removed, len(rows))
		err = warn
	}
	a.doneTo(w, r, s, to, message, err)
}

// deleteSyncRows empties the storage of every row, then deletes the rows; how many it
// emptied. The second pass goes for those emptied even when a later step fails: it
// leaves the uids that still have a row
func (a *App) deleteSyncRows(ctx context.Context, rows []UserRow, label string) (Removed, int, error) {
	var removed Removed
	ids := make([]int64, 0, len(rows))
	defer func() { a.scheduleSecondPass(ids, label, time.Now()) }()
	for _, row := range rows {
		if a.storage != nil {
			n, err := a.storage.DeleteStorage(ctx, row.ID, "")
			removed.add(n)
			if err != nil {
				return removed, len(ids), err
			}
		}
		ids = append(ids, row.ID)
	}
	return removed, len(ids), a.sync.DeleteUserRows(ctx, ids)
}

// DeleteAccount deletes a disabled account (ffs.delete_account refuses the others),
// then what Redis keeps of it: its access tokens, its sessions' cache, its profile
func (f *FxaDB) DeleteAccount(ctx context.Context, uid string) error {
	id, err := accountID(uid)
	if err != nil {
		return err
	}
	if _, err := f.db.ExecContext(ctx, "CALL ffs.delete_account(?)", id); err != nil {
		return procedureError(err)
	}
	if _, err := revokeRedisTokens(ctx, f.redis, uid); err != nil {
		return &partialError{fmt.Errorf("account deleted, but its access tokens are still valid until they expire: %w", err)}
	}
	if err := dropProfileCache(ctx, f.redis, uid); err != nil {
		return &partialError{fmt.Errorf("account deleted, but the profile server may show it for a while: %w", err)}
	}
	return nil
}

// the confirm pages of the Sync data: reset and delete, for any account with a page
func (a *App) confirmSyncAction(action string) handler {
	return func(w http.ResponseWriter, r *http.Request, s *session) {
		ctx := r.Context()
		uid := strings.ToLower(r.PathValue("uid"))
		var acc *FxaAccount
		if a.fxa != nil {
			if _, err := accountID(uid); err == nil {
				var err error
				if acc, err = a.fxa.Account(ctx, uid); err != nil {
					http.Error(w, "Accounts: "+err.Error(), http.StatusInternalServerError)
					return
				}
			}
		}
		rows, flags, err := a.syncRows(ctx, uid)
		if err != nil {
			http.Error(w, "Sync: "+err.Error(), http.StatusInternalServerError)
			return
		}
		if acc == nil && len(rows) == 0 {
			http.NotFound(w, r)
			return
		}
		data := a.base(s)
		data["Account"], data["Name"], data["Back"], data["MaxReason"] = acc, accountName(acc, uid), "/users/"+uid, maxReason
		data["Rows"], data["Flags"] = rows, flags
		var current *UserRow
		for i := range rows {
			if rows[i].Current {
				current = &rows[i]
			}
		}
		var act confirmAction
		switch action {
		case "reset-sync":
			if current == nil || a.storage == nil {
				http.NotFound(w, r)
				return
			}
			collection := r.URL.Query().Get("collection")
			act = confirmAction{Title: "Reset the Sync data of", Button: "Reset the Sync data", Effects: []string{
				fmt.Sprintf("Deletes what the Sync server stores for the current keys (storage uid %d: %d items, %s); the account and its tokenserver row stay.", current.ID, current.Usage.Items, humanBytes(current.Usage.Bytes)),
				"Data that is only on the server is lost. Each Firefox finds the server empty on its next sync and uploads what it has again.",
			}, Checks: []confirmCheck{{Name: "free_slot", Label: "Also free the max users slot: deletes its tokenserver rows and the storage of all of them (" + strconv.Itoa(len(rows)) + "); its next Sync token goes through max users again, and is refused when the server is full"}}}
			if collection != "" {
				collections, err := a.storage.Collections(ctx, current.ID)
				if err != nil {
					http.Error(w, "Sync storage: "+err.Error(), http.StatusInternalServerError)
					return
				}
				var found *CollectionUsage
				for i := range collections {
					if collections[i].Name == collection {
						found = &collections[i]
					}
				}
				if found == nil {
					http.NotFound(w, r)
					return
				}
				act = confirmAction{Title: "Reset the " + collection + " collection of", Button: "Reset the collection", Effects: []string{
					fmt.Sprintf("Deletes the %s collection of the current keys (%d items, %s), nothing else.", collection, found.Items, humanBytes(found.Bytes)),
					"Data that is only on the server is lost. Firefox does not notice by itself: it sends again what changes on a device, or everything after Sync is reset there (Disconnect, then sign in again).",
				}, Hidden: map[string]string{"collection": collection}}
			}
		case "delete":
			if acc != nil {
				if !acc.Disabled {
					// offered for disabled accounts only (ffs.delete_account refuses the others too)
					http.NotFound(w, r)
					return
				}
				act = confirmAction{Title: "Delete", Button: "Delete the account for good", TypeEmail: true, Effects: []string{
					"The account is deleted from the accounts service: its sessions, devices, keys, two-step authentication, recovery key and phone, emails, OAuth tokens and consents, profile and push messages. It cannot be undone.",
					"Its Sync data and tokenserver rows are deleted, which frees its max users slot; once more in 65 minutes, for what Firefox writes meanwhile with the Sync token it has.",
					"Its email is removed from the allowlist: with sign-ups on an allowlist it cannot sign up again unless invited. Its note is removed. The event log keeps the email.",
					"Its avatar image, if it uploaded one, stays in the fxa-profile-images volume.",
				}}
			} else {
				act = confirmAction{Title: "Delete the Sync data of", Button: "Delete the Sync data", TypeEmail: true, TypeUID: true, Effects: []string{
					fmt.Sprintf("Deletes its %d tokenserver rows and the Sync data of each, which frees its max users slot; once more in 65 minutes, for what Firefox writes meanwhile with the Sync token it has.", len(rows)),
					"The account itself is elsewhere (Mozilla's accounts): it can sync here again, as a new account through max users. Its note is removed.",
				}}
			}
		default:
			http.NotFound(w, r)
			return
		}
		data["Action"], data["Post"] = act, "/users/"+uid+"/"+action
		a.render(w, "confirm.html", data)
	}
}

// accountName: the email of an account, or its id
func accountName(acc *FxaAccount, uid string) string {
	if acc != nil {
		return acc.Email
	}
	return "account " + uid
}

// Removed counts what a deletion took out of the storage
type Removed struct{ Items, Bytes int64 }

func (r *Removed) add(o Removed) { r.Items += o.Items; r.Bytes += o.Bytes }

func (r Removed) String() string {
	return fmt.Sprintf("%d items, %s", r.Items, humanBytes(r.Bytes))
}

// sortedIDs, for stable messages and tests
func sortedIDs(ids map[int64]bool) []int64 {
	out := make([]int64, 0, len(ids))
	for id := range ids {
		out = append(out, id)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}
