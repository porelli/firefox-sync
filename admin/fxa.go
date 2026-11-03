package main

import (
	"context"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"net"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/go-sql-driver/mysql"
)

// Self-hosted Mozilla accounts database (MySQL). The sign-up policy lives in its own
// database (ffs), FxA's migrations never touch it.

const (
	SignupsOpen      = "open"
	SignupsAllowlist = "allowlist"
	SignupsClosed    = "closed"
)

type FxaDB struct {
	db    *sql.DB
	redis string // host:port of FxA's Redis, for the access tokens

	mu     sync.Mutex
	logged string // logOnce
}

// logOnce logs a message of the overview when it differs from the last one, not on every load
func (f *FxaDB) logOnce(msg string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if msg != f.logged {
		log.Print(msg)
		f.logged = msg
	}
}

type FxaAccount struct {
	UID       string
	Email     string
	Verified  bool
	CreatedAt time.Time
	Disabled  bool
	Sync      bool // has used this Sync server
}

type SignupPolicy struct {
	Mode      string
	Allowlist []string
}

func fxaConfig(user, password string) *mysql.Config {
	cfg := mysql.NewConfig()
	cfg.Net = "tcp"
	cfg.Addr = net.JoinHostPort(env("FXA_DB_HOST", "fxa-db"), env("FXA_DB_PORT", "3306"))
	cfg.User, cfg.Passwd = user, password
	cfg.Timeout = 5 * time.Second
	// client side placeholders: CREATE USER and GRANT cannot be prepared
	cfg.InterpolateParams = true
	return cfg
}

func openFxaDB() (*FxaDB, error) {
	if env("FXA_DB_HOST", "") == "" {
		return nil, nil
	}
	db, err := sql.Open("mysql", fxaConfig(env("FXA_DB_USER", "ffs_admin"), env("FXA_DB_PASSWORD", "")).FormatDSN())
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(4)
	db.SetConnMaxLifetime(5 * time.Minute)
	return &FxaDB{db: db, redis: env("FXA_REDIS", "fxa-redis:6379")}, nil
}

// SignupRefusal: why a sign-up with this email is refused, "" when it is allowed:
// refusedPolicy (the sign-up policy) or refusedFull (FXA_MAX_ACCOUNTS reached)
func (f *FxaDB) SignupRefusal(ctx context.Context, email string) (string, error) {
	var refusal string
	err := f.db.QueryRowContext(ctx, "SELECT COALESCE(ffs.signup_refusal(?), '')", email).Scan(&refusal)
	return refusal, err
}

const (
	refusedPolicy = "policy"
	refusedFull   = "full"
)

// MaxAccounts: FXA_MAX_ACCOUNTS as fxa-init or the admin UI set it in ffs.settings; none
// there (before fxa-init set it): no limit, as ffs.signup_refusal reads it
func (f *FxaDB) MaxAccounts(ctx context.Context) (max int, unlimited bool, err error) {
	var value string
	err = f.db.QueryRowContext(ctx, "SELECT value FROM ffs.settings WHERE name = 'max_accounts'").Scan(&value)
	if err == sql.ErrNoRows {
		return 0, true, nil
	}
	if err != nil {
		return 0, false, err
	}
	// anything else counts as 0 there too: CAST of a word
	max, unlimited, _ = parseLimitValue(value)
	return max, unlimited, nil
}

// AccountLimit: the accounts against FXA_MAX_ACCOUNTS, as ffs.signup_refusal counts them
func (f *FxaDB) AccountLimit(ctx context.Context) (Limit, error) {
	max, unlimited, err := f.MaxAccounts(ctx)
	if err != nil {
		return Limit{}, err
	}
	l := Limit{Max: max, Unlimited: unlimited}
	err = f.db.QueryRowContext(ctx, "SELECT COUNT(uid) FROM fxa.accounts").Scan(&l.Count)
	return l, err
}

// SetMaxAccounts: the limit of ffs.signup_refusal, with FXA_MAX_ACCOUNTS=initial:N (or not set)
func (f *FxaDB) SetMaxAccounts(ctx context.Context, max int, unlimited bool) error {
	return setMaxAccounts(ctx, f.db, Limit{Max: max, Unlimited: unlimited}.Setting(), true)
}

// setMaxAccounts: replace, or only when there is none yet (FXA_MAX_ACCOUNTS=initial:N)
func setMaxAccounts(ctx context.Context, db *sql.DB, value string, replace bool) error {
	query := "INSERT INTO ffs.settings (name, value) VALUES ('max_accounts', ?) ON DUPLICATE KEY UPDATE value = VALUES(value)"
	if !replace {
		query = "INSERT IGNORE INTO ffs.settings (name, value) VALUES ('max_accounts', ?)"
	}
	_, err := db.ExecContext(ctx, query, value)
	return err
}

func (f *FxaDB) Policy(ctx context.Context) (*SignupPolicy, error) {
	p := &SignupPolicy{}
	if err := f.db.QueryRowContext(ctx, "SELECT value FROM ffs.settings WHERE name = 'signups'").Scan(&p.Mode); err != nil {
		return nil, err
	}
	rows, err := f.db.QueryContext(ctx, "SELECT entry FROM ffs.signup_allowlist ORDER BY entry")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var e string
		if err := rows.Scan(&e); err != nil {
			return nil, err
		}
		p.Allowlist = append(p.Allowlist, e)
	}
	return p, rows.Err()
}

// SetPolicy sets the mode and the allowlist. loaded is the allowlist the form showed:
// only its entries can be removed, so invitations made since the page was loaded stay.
// nil replaces the whole list.
func (f *FxaDB) SetPolicy(ctx context.Context, p *SignupPolicy, loaded []string) error {
	return setPolicy(ctx, f.db, p, loaded, "")
}

// allowlistRemovals: the entries of current to delete for the submitted list, among
// those of loaded (all of current when loaded is nil)
func allowlistRemovals(current, loaded, submitted []string) []string {
	keep := map[string]bool{}
	for _, e := range submitted {
		keep[e] = true
	}
	var shown map[string]bool
	if loaded != nil {
		shown = map[string]bool{}
		for _, e := range loaded {
			shown[e] = true
		}
	}
	var gone []string
	for _, e := range current {
		if !keep[e] && (shown == nil || shown[e]) {
			gone = append(gone, e)
		}
	}
	return gone
}

// setPolicy sets the sign-up mode and allowlist (see SetPolicy); envSnapshot, when set,
// records the .env values they came from (see applyEnvPolicy)
func setPolicy(ctx context.Context, db *sql.DB, p *SignupPolicy, loaded []string, envSnapshot string) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `INSERT INTO ffs.settings (name, value) VALUES ('signups', ?)
		ON DUPLICATE KEY UPDATE value = VALUES(value)`, p.Mode); err != nil {
		return err
	}
	// only what changes: the entries kept keep their date (invited on...)
	rows, err := tx.QueryContext(ctx, "SELECT entry FROM ffs.signup_allowlist")
	if err != nil {
		return err
	}
	var current []string
	for rows.Next() {
		var e string
		if err := rows.Scan(&e); err != nil {
			rows.Close()
			return err
		}
		current = append(current, e)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	for _, e := range allowlistRemovals(current, loaded, p.Allowlist) {
		if _, err := tx.ExecContext(ctx, "DELETE FROM ffs.signup_allowlist WHERE entry = ?", e); err != nil {
			return err
		}
	}
	for _, e := range p.Allowlist {
		if _, err := tx.ExecContext(ctx, "INSERT IGNORE INTO ffs.signup_allowlist (entry) VALUES (?)", e); err != nil {
			return err
		}
	}
	if envSnapshot != "" {
		if _, err := tx.ExecContext(ctx, `INSERT INTO ffs.settings (name, value) VALUES ('env', ?)
			ON DUPLICATE KEY UPDATE value = VALUES(value)`, envSnapshot); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// AllowEntry: an entry of the allowlist, since when
type AllowEntry struct {
	Entry string
	Added time.Time
}

func (f *FxaDB) AllowlistEntries(ctx context.Context) ([]AllowEntry, error) {
	rows, err := f.db.QueryContext(ctx, "SELECT entry, CAST(COALESCE(UNIX_TIMESTAMP(created_at), 0) AS SIGNED) FROM ffs.signup_allowlist ORDER BY created_at DESC, entry")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var entries []AllowEntry
	for rows.Next() {
		var e AllowEntry
		var at int64
		if err := rows.Scan(&e.Entry, &at); err != nil {
			return nil, err
		}
		if at > 0 {
			e.Added = time.Unix(at, 0)
		}
		entries = append(entries, e)
	}
	return entries, rows.Err()
}

// AddToAllowlist adds an email (or @domain), already parsed by ParseAllowlist
func (f *FxaDB) AddToAllowlist(ctx context.Context, entry string) error {
	_, err := f.db.ExecContext(ctx, "INSERT IGNORE INTO ffs.signup_allowlist (entry) VALUES (?)", entry)
	return err
}

// RemoveFromAllowlist: false when it was not there
func (f *FxaDB) RemoveFromAllowlist(ctx context.Context, entry string) (bool, error) {
	res, err := f.db.ExecContext(ctx, "DELETE FROM ffs.signup_allowlist WHERE entry = ?", entry)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n > 0, err
}

func (f *FxaDB) Accounts(ctx context.Context) ([]FxaAccount, error) {
	rows, err := f.db.QueryContext(ctx, `SELECT HEX(uid), email, emailVerified, createdAt, disabledAt IS NOT NULL
		FROM fxa.accounts ORDER BY createdAt`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var accounts []FxaAccount
	for rows.Next() {
		var a FxaAccount
		var created int64
		if err := rows.Scan(&a.UID, &a.Email, &a.Verified, &created, &a.Disabled); err != nil {
			return nil, err
		}
		a.UID = strings.ToLower(a.UID)
		a.CreatedAt = time.UnixMilli(created)
		accounts = append(accounts, a)
	}
	return accounts, rows.Err()
}

// Account is one account, nil if there is none with that uid
func (f *FxaDB) Account(ctx context.Context, uid string) (*FxaAccount, error) {
	id, err := accountID(uid)
	if err != nil {
		return nil, err
	}
	var a FxaAccount
	var created int64
	err = f.db.QueryRowContext(ctx, `SELECT HEX(uid), email, emailVerified, createdAt, disabledAt IS NOT NULL
		FROM fxa.accounts WHERE uid = ?`, id).Scan(&a.UID, &a.Email, &a.Verified, &created, &a.Disabled)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	a.UID, a.CreatedAt = strings.ToLower(a.UID), time.UnixMilli(created)
	return &a, nil
}

func accountID(uid string) ([]byte, error) {
	id, err := hex.DecodeString(uid)
	if err != nil || len(id) != 16 {
		return nil, fmt.Errorf("invalid account id")
	}
	return id, nil
}

// SetDisabled disables or re-enables an account. FxA refuses sign-ins and sessions of
// disabled accounts, but not the OAuth tokens Firefox already has (Mozilla's own admin
// panel leaves them too): disabling signs out everywhere first (SignOutAll).
func (f *FxaDB) SetDisabled(ctx context.Context, uid string, disabled bool) error {
	id, err := accountID(uid)
	if err != nil {
		return err
	}
	if !disabled {
		_, err = f.db.ExecContext(ctx, "CALL ffs.enable_account(?)", id)
		return procedureError(err)
	}
	if _, err := f.db.ExecContext(ctx, "CALL ffs.disable_account(?)", id); err != nil {
		return procedureError(err)
	}
	if _, err := revokeRedisTokens(ctx, f.redis, strings.ToLower(uid)); err != nil {
		return &partialError{fmt.Errorf("account disabled, but its access tokens are still valid until they expire: %w", err)}
	}
	return nil
}

// SignOutAll ends every session, device and token of an account, which can sign in
// again right away. The tokenserver remembers a verified access token for 5 minutes,
// and the Sync tokens it gave out last up to 1 hour.
func (f *FxaDB) SignOutAll(ctx context.Context, uid string) error {
	id, err := accountID(uid)
	if err != nil {
		return err
	}
	// a procedure of fxa-init: ffs_admin cannot delete FxA's tokens itself
	if _, err := f.db.ExecContext(ctx, "CALL ffs.sign_out_all(?)", id); err != nil {
		return procedureError(err)
	}
	if _, err := revokeRedisTokens(ctx, f.redis, strings.ToLower(uid)); err != nil {
		return &partialError{fmt.Errorf("signed out, but its access tokens are still valid until they expire: %w", err)}
	}
	return nil
}

// partialError: the change was made, but a later step failed. It still belongs in
// the audit trail.
type partialError struct{ err error }

func (e *partialError) Error() string { return e.err.Error() }
func (e *partialError) Unwrap() error { return e.err }

func (f *FxaDB) Ping(ctx context.Context) error {
	return f.db.PingContext(ctx)
}

var (
	emailEntry  = regexp.MustCompile(`^[^@\s,;]+@[a-z0-9-]+(\.[a-z0-9-]+)+$`)
	domainEntry = regexp.MustCompile(`^@?[a-z0-9-]+(\.[a-z0-9-]+)+$`)
)

// ParseAllowlist takes emails (alice@example.com) and domains (@example.com or
// example.com), separated by commas, spaces or new lines
func ParseAllowlist(s string) ([]string, error) {
	seen := map[string]bool{}
	var entries []string
	for _, e := range strings.FieldsFunc(strings.ToLower(s), func(r rune) bool {
		return r == ',' || r == ';' || r == ' ' || r == '\n' || r == '\r' || r == '\t'
	}) {
		switch {
		case emailEntry.MatchString(e):
		case domainEntry.MatchString(e):
			if !strings.HasPrefix(e, "@") {
				e = "@" + e
			}
		default:
			return nil, fmt.Errorf("not an email or a domain: %q", e)
		}
		if len(e) > 255 {
			return nil, fmt.Errorf("too long: %q", e)
		}
		if !seen[e] {
			seen[e] = true
			entries = append(entries, e)
		}
	}
	return entries, nil
}

func ParseMode(s string) (string, error) {
	switch m := strings.ToLower(strings.TrimSpace(s)); m {
	case SignupsOpen, SignupsAllowlist, SignupsClosed:
		return m, nil
	}
	return "", fmt.Errorf("sign-ups must be open, allowlist or closed, not %q", s)
}

type Device struct {
	ID         string
	Name, Type string
	CreatedAt  time.Time
	LastUsed   time.Time
	// not used for ADMIN_STALE_DAYS (the account page sets it)
	Inactive bool
}

type Session struct {
	// SHA-256 of the token id: the id itself signs in (Bearer fxs_<id>), never show it
	Ref         string
	Browser, OS string
	CreatedAt   time.Time
	LastUsed    time.Time
	// the sign-in code (or the second step) was entered, and how: email, totp-2fa...
	Verified bool
	Method   string
	// the device it registered (Firefox names them), and the IP address of a sign-in
	// waiting for its code (with FXA_ACCOUNT_EVENTS only), "" when unknown
	Device, IP string
}

// Devices registered by the browsers of an account (Firefox names them, e.g.
// "Firefox on laptop"), and its sessions, with when they last used it: the accounts
// service writes most uses to Redis only (lastUsed)
func (f *FxaDB) Devices(ctx context.Context, uid string) ([]Device, []Session, error) {
	id, err := accountID(uid)
	if err != nil {
		return nil, nil, err
	}
	used, err := sessionsLastUsed(ctx, f.redis, strings.ToLower(uid))
	if err != nil {
		log.Printf("last use of the sessions (Redis): %v", err)
	}
	rows, err := f.db.QueryContext(ctx, `SELECT LOWER(HEX(id)), name, type, createdAt, lastUsed, COALESCE(ref, '')
		FROM ffs.devices WHERE uid = ? ORDER BY createdAt`, id)
	if err != nil {
		return nil, nil, err
	}
	var devices []Device
	names := map[string]string{} // by session ref
	for rows.Next() {
		var d Device
		var name sql.NullString
		var created int64
		var last float64
		var ref string
		if err := rows.Scan(&d.ID, &name, &d.Type, &created, &last, &ref); err != nil {
			rows.Close()
			return nil, nil, err
		}
		d.Name, d.CreatedAt, d.LastUsed = name.String, ms(created), latest(ms(int64(last)), used[ref])
		devices = append(devices, d)
		if ref != "" {
			names[ref] = d.Name
		}
	}
	rows.Close()
	rows, err = f.db.QueryContext(ctx, `SELECT ref, COALESCE(uaBrowser, ''), COALESCE(uaOS, ''), createdAt, COALESCE(lastAccessTime, 0),
		verified, COALESCE(verificationMethod, ''), COALESCE(ip, '')
		FROM ffs.sessions WHERE uid = ? ORDER BY createdAt DESC`, id)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	var sessions []Session
	for rows.Next() {
		var s Session
		var created, last int64
		if err := rows.Scan(&s.Ref, &s.Browser, &s.OS, &created, &last, &s.Verified, &s.Method, &s.IP); err != nil {
			return nil, nil, err
		}
		s.CreatedAt, s.LastUsed, s.Device = ms(created), latest(ms(last), used[s.Ref]), names[s.Ref]
		sessions = append(sessions, s)
	}
	return devices, sessions, rows.Err()
}

// InactiveDevices: per account, its devices last used (or added) before before. The
// accounts service writes most uses to Redis only: read for the accounts with candidates
func (f *FxaDB) InactiveDevices(ctx context.Context, before time.Time) (map[string]int, error) {
	rows, err := f.db.QueryContext(ctx, "SELECT LOWER(HEX(uid)), createdAt, lastUsed, COALESCE(ref, '') FROM ffs.devices")
	if err != nil {
		return nil, err
	}
	type device struct {
		last time.Time
		ref  string
	}
	candidates := map[string][]device{}
	for rows.Next() {
		var uid, ref string
		var created int64
		var last float64
		if err := rows.Scan(&uid, &created, &last, &ref); err != nil {
			rows.Close()
			return nil, err
		}
		if d := (device{latest(ms(created), ms(int64(last))), ref}); d.last.Before(before) {
			candidates[uid] = append(candidates[uid], d)
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	uids := make([]string, 0, len(candidates))
	for uid := range candidates {
		uids = append(uids, uid)
	}
	used, bad, err := sessionsLastUsedOf(ctx, f.redis, uids)
	if err != nil {
		return nil, fmt.Errorf("last use of the sessions (Redis): %w", err)
	}
	// an unreadable cache: that account is left out, not guessed from the older times
	skip := map[string]bool{}
	for _, uid := range bad {
		skip[uid] = true
	}
	if len(bad) > 0 {
		f.logOnce(fmt.Sprintf("inactive devices: unexpected session cache (Redis) of %d accounts, left out", len(bad)))
	}
	inactive := map[string]int{}
	for uid, devices := range candidates {
		if skip[uid] {
			continue
		}
		for _, d := range devices {
			if latest(d.last, used[uid][d.ref]).Before(before) {
				inactive[uid]++
			}
		}
	}
	return inactive, nil
}

func latest(a, b time.Time) time.Time {
	if b.After(a) {
		return b
	}
	return a
}

// Security is how an account signs in, from ffs.account_security (no secrets)
type Security struct {
	TOTP          bool // two-step authentication (an authenticator app)
	RecoveryKey   bool
	RecoveryCodes int // backup authentication codes left
	RecoveryPhone bool
	Passkeys      int
	PasswordSetAt time.Time
	KeysChangedAt time.Time
	LockedAt      time.Time
	// sessions that never entered their sign-in code (or second step)
	UnverifiedSessions int
}

const securityColumns = `LOWER(HEX(uid)), totp_enabled, recovery_key, recovery_codes_left, recovery_phone, passkeys,
	COALESCE(verifierSetAt, 0), COALESCE(keysChangedAt, 0), COALESCE(lockedAt, 0), unverified_sessions`

func scanSecurity(scan func(...any) error) (string, Security, error) {
	var uid string
	var s Security
	var password, keys, locked int64
	err := scan(&uid, &s.TOTP, &s.RecoveryKey, &s.RecoveryCodes, &s.RecoveryPhone, &s.Passkeys, &password, &keys, &locked, &s.UnverifiedSessions)
	s.PasswordSetAt, s.KeysChangedAt, s.LockedAt = ms(password), ms(keys), ms(locked)
	return uid, s, err
}

// Securities: the security of every account, by uid, for the badges of the list
func (f *FxaDB) Securities(ctx context.Context) (map[string]Security, error) {
	rows, err := f.db.QueryContext(ctx, "SELECT "+securityColumns+" FROM ffs.account_security")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	all := map[string]Security{}
	for rows.Next() {
		uid, s, err := scanSecurity(rows.Scan)
		if err != nil {
			return nil, err
		}
		all[uid] = s
	}
	return all, rows.Err()
}

func (f *FxaDB) Security(ctx context.Context, uid string) (*Security, error) {
	id, err := accountID(uid)
	if err != nil {
		return nil, err
	}
	_, s, err := scanSecurity(f.db.QueryRowContext(ctx, "SELECT "+securityColumns+" FROM ffs.account_security WHERE uid = ?", id).Scan)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &s, nil
}

type Email struct {
	Email             string
	Verified, Primary bool
	CreatedAt         time.Time
}

// Emails of an account, the primary first
func (f *FxaDB) Emails(ctx context.Context, uid string) ([]Email, error) {
	id, err := accountID(uid)
	if err != nil {
		return nil, err
	}
	rows, err := f.db.QueryContext(ctx, `SELECT email, isVerified, isPrimary, createdAt FROM ffs.emails
		WHERE uid = ? ORDER BY isPrimary DESC, createdAt`, id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var emails []Email
	for rows.Next() {
		var e Email
		var created int64
		if err := rows.Scan(&e.Email, &e.Verified, &e.Primary, &created); err != nil {
			return nil, err
		}
		e.CreatedAt = ms(created)
		emails = append(emails, e)
	}
	return emails, rows.Err()
}

// RemoveTOTP turns off two-step authentication (and its backup codes and phone), for
// someone who lost their authenticator: they sign in with the password and an email
// code again
func (f *FxaDB) RemoveTOTP(ctx context.Context, uid string) error {
	return f.change(ctx, "ffs.remove_totp", uid, "two-step authentication turned off")
}

// RemoveRecoveryKey removes the account recovery key
func (f *FxaDB) RemoveRecoveryKey(ctx context.Context, uid string) error {
	return f.change(ctx, "ffs.remove_recovery_key", uid, "recovery key removed")
}

// ConfirmEmail marks the primary email of an account as confirmed, without its code
func (f *FxaDB) ConfirmEmail(ctx context.Context, uid string) error {
	return f.change(ctx, "ffs.confirm_email", uid, "email confirmed")
}

// ConfirmSession confirms a sign-in waiting for its code (ref: SHA-256 of its token id),
// as the code would: for someone the admin vouches for
func (f *FxaDB) ConfirmSession(ctx context.Context, uid, ref string) error {
	account, err := accountID(uid)
	if err != nil {
		return err
	}
	hash, err := hex.DecodeString(ref)
	if err != nil || len(hash) != 32 {
		return fmt.Errorf("invalid session")
	}
	_, err = f.db.ExecContext(ctx, "CALL ffs.confirm_session(?, ?)", account, hash)
	return procedureError(err)
}

// change runs a procedure of fxa-init on an account, then drops the account from the
// profile server's cache, which would show the old state (2-step on...) for a while
func (f *FxaDB) change(ctx context.Context, procedure, uid, done string) error {
	id, err := accountID(uid)
	if err != nil {
		return err
	}
	if _, err := f.db.ExecContext(ctx, "CALL "+procedure+"(?)", id); err != nil {
		return procedureError(err)
	}
	if err := dropProfileCache(ctx, f.redis, strings.ToLower(uid)); err != nil {
		return &partialError{fmt.Errorf("%s, but the profile server may show the old state for a while: %w", done, err)}
	}
	return nil
}

// Recent sign-ups and new devices, for the activity log: created in [since, before)
// (before zero: up to now), newest first, kind "sign-up", "new device" or both (""),
// with q in the email or the device name (any case), at most limit of each kind
func (f *FxaDB) Recent(ctx context.Context, since, before time.Time, kind, q string, limit int) ([]Event, error) {
	if before.IsZero() {
		before = time.Now().Add(time.Minute)
	}
	like := "%" + likeEscape(strings.ToLower(q)) + "%"
	var events []Event
	if kind == "" || kind == "sign-up" {
		rows, err := f.db.QueryContext(ctx, `SELECT email, createdAt FROM fxa.accounts
			WHERE createdAt >= ? AND createdAt < ? AND LOWER(email) LIKE ? ORDER BY createdAt DESC LIMIT ?`,
			since.UnixMilli(), before.UnixMilli(), like, limit)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var email string
			var at int64
			if err := rows.Scan(&email, &at); err != nil {
				rows.Close()
				return nil, err
			}
			events = append(events, Event{At: ms(at), Kind: "sign-up", Detail: email})
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return nil, err
		}
	}
	if kind == "" || kind == "new device" {
		rows, err := f.db.QueryContext(ctx, `SELECT a.email, COALESCE(d.name, ''), d.type, d.createdAt
			FROM ffs.devices d JOIN fxa.accounts a ON a.uid = d.uid
			WHERE d.createdAt >= ? AND d.createdAt < ? AND (LOWER(a.email) LIKE ? OR LOWER(d.name) LIKE ?)
			ORDER BY d.createdAt DESC LIMIT ?`, since.UnixMilli(), before.UnixMilli(), like, like, limit)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		for rows.Next() {
			var email, name, kind string
			var at int64
			if err := rows.Scan(&email, &name, &kind, &at); err != nil {
				return nil, err
			}
			events = append(events, Event{At: ms(at), Kind: "new device", Detail: fmt.Sprintf("%s: %s (%s)", email, name, kind)})
		}
		return events, rows.Err()
	}
	return events, nil
}

// likeEscape: q matches as is, % and _ too (backslash: the escape of LIKE in MySQL,
// MariaDB and PostgreSQL)
func likeEscape(q string) string {
	return strings.NewReplacer(`\`, `\\`, "%", `\%`, "_", `\_`).Replace(q)
}

// SignOutDevice removes a device and the tokens it signed in with, like "sign out"
// in the devices list of the account settings; the account stays usable elsewhere.
// Its access tokens live on until they expire (FXA_ACCESS_TOKEN_LIFETIME).
func (f *FxaDB) SignOutDevice(ctx context.Context, uid, deviceID string) error {
	account, err := accountID(uid)
	if err != nil {
		return err
	}
	device, err := hex.DecodeString(deviceID)
	if err != nil || len(device) != 16 {
		return fmt.Errorf("invalid device id")
	}
	// a procedure of fxa-init: ffs_admin cannot read the token ids
	_, err = f.db.ExecContext(ctx, "CALL ffs.sign_out_device(?, ?)", account, device)
	return procedureError(err)
}

// SignOutSession ends one session (ref: SHA-256 of its token id), and its device
func (f *FxaDB) SignOutSession(ctx context.Context, uid, ref string) error {
	account, err := accountID(uid)
	if err != nil {
		return err
	}
	hash, err := hex.DecodeString(ref)
	if err != nil || len(hash) != 32 {
		return fmt.Errorf("invalid session")
	}
	_, err = f.db.ExecContext(ctx, "CALL ffs.sign_out_session(?, ?)", account, hash)
	return procedureError(err)
}

// procedureError: the message of SIGNAL in the procedures (no such device...) as is
func procedureError(err error) error {
	var e *mysql.MySQLError
	if errors.As(err, &e) && e.SQLState == [5]byte{'4', '5', '0', '0', '0'} {
		return errors.New(e.Message)
	}
	return err
}

// Size of the accounts databases, through a view of fxa-init (ffs_admin cannot see
// the tables themselves), with the sizes of now on MySQL (the view reads them in the
// session of ffs_admin)
func (f *FxaDB) Size(ctx context.Context) (int64, error) {
	var n int64
	err := withFreshStats(ctx, f.db, func(c *sql.Conn) error {
		return c.QueryRowContext(ctx, "SELECT COALESCE(SUM(bytes), 0) FROM ffs.database_sizes").Scan(&n)
	})
	return n, err
}
