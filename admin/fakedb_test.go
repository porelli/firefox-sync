package main

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"io"
	"strings"
	"sync"

	"github.com/go-sql-driver/mysql"
)

// fakeFxa answers the accounts database queries of the pages with one account, one
// device and one session, and records every statement, to show what a page changes
type fakeFxa struct {
	mu     sync.Mutex
	execs  []string
	args   [][]driver.Value
	events [][]driver.Value  // the rows of ffs_events (at, kind, detail), as given
	notes  map[string]string // the notes of ffs_account_notes, by uid
	mode   string            // the sign-up policy, allowlist by default
	nodes  [][]driver.Value  // as a tokenserver database: its nodes (id, node, capacity, load, available, downed, backoff)
	// the account is disabled
	disabled bool
	// as a tokenserver database: the users rows (uid, email, client_state, keys_changed_at,
	// nodeid, node, downed, known, created_at, replaced_at)
	users [][]driver.Value
	// accounts that never confirmed their email (uid, email, created_at)
	unconfirmed [][]driver.Value
	// as a tokenserver database: the rows of ffs_backups (scope, started, finished, ok, bytes, error, location)
	backups [][]driver.Value
	// the devices of every account (uid, created, lastUsed, ref)
	allDevices [][]driver.Value
	// execErr, when set, fails the statements it returns an error for (after recording them)
	execErr func(query string, args []driver.Value) error
	// none: the statements that change no row
	none func(query string) bool
	// the queries, and their arguments
	queries []string
	qargs   [][]driver.Value
	// queryErr, when set, fails the queries it returns an error for (after recording them)
	queryErr func(query string) error
	// answer, when set, answers the queries it returns rows for, before the cases below
	answer func(query string, args []driver.Value) *fakeRows
	// the limits: max_users of the tokenserver's config, max_accounts of ffs.settings
	// ("": no row), the count of fxa.accounts
	maxUsers, maxAccounts string
	accountCount          int64
	// as a tokenserver database (with nodes set): the accounts using Sync
	syncUsers int64
}

const (
	fakeUID   = "0123abcd0123abcd0123abcd0123abcd"
	fakeEmail = "alice@example.com"
	// a session token id, and its ref: SHA-256 of its bytes, as ffs.sessions shows it
	fakeToken = "70ce70ce70ce70ce70ce70ce70ce70ce70ce70ce70ce70ce70ce70ce70ce70ce"
	fakeRef   = "2c9c46f00db093851452736d66eaf977453a2301b811a88caa4661cff0cbed99"
)

func (f *fakeFxa) Connect(context.Context) (driver.Conn, error) { return &fakeConn{f}, nil }
func (f *fakeFxa) Driver() driver.Driver                        { return nil }

func (f *fakeFxa) statements() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.execs...)
}

// queried: the arguments of every query that contains part
func (f *fakeFxa) queried(part string) [][]driver.Value {
	f.mu.Lock()
	defer f.mu.Unlock()
	var found [][]driver.Value
	for i, q := range f.queries {
		if strings.Contains(q, part) {
			found = append(found, f.qargs[i])
		}
	}
	return found
}

// db: an FxaDB on the fake, its Redis at redis
func (f *fakeFxa) db(redis string) *FxaDB {
	return &FxaDB{db: sql.OpenDB(f), redis: redis}
}

type fakeConn struct{ f *fakeFxa }

func (c *fakeConn) Prepare(string) (driver.Stmt, error) { return nil, driver.ErrSkip }
func (c *fakeConn) Close() error                        { return nil }
func (c *fakeConn) Begin() (driver.Tx, error)           { c.record("BEGIN"); return &fakeTx{c}, nil }

// fakeTx records the end of a transaction among the statements
type fakeTx struct{ c *fakeConn }

func (t *fakeTx) Commit() error   { t.c.record("COMMIT"); return nil }
func (t *fakeTx) Rollback() error { t.c.record("ROLLBACK"); return nil }

func (c *fakeConn) record(statement string) {
	c.f.mu.Lock()
	defer c.f.mu.Unlock()
	c.f.execs = append(c.f.execs, statement)
	c.f.args = append(c.f.args, nil)
}

func (c *fakeConn) ExecContext(_ context.Context, query string, named []driver.NamedValue) (driver.Result, error) {
	var args []driver.Value
	for _, a := range named {
		args = append(args, a.Value)
	}
	c.f.mu.Lock()
	c.f.execs = append(c.f.execs, query)
	c.f.args = append(c.f.args, args)
	c.f.mu.Unlock()
	if c.f.execErr != nil {
		if err := c.f.execErr(query, args); err != nil {
			return nil, err
		}
	}
	if query == "CALL ffs.delete_account(?)" && !c.f.disabled {
		return nil, &mysql.MySQLError{Number: 1644, SQLState: [5]byte{'4', '5', '0', '0', '0'}, Message: "only a disabled account can be deleted: disable it first"}
	}
	if c.f.none != nil && c.f.none(query) {
		return driver.RowsAffected(0), nil
	}
	return driver.RowsAffected(1), nil
}

func (c *fakeConn) QueryContext(_ context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	var values []driver.Value
	for _, a := range args {
		values = append(values, a.Value)
	}
	c.f.mu.Lock()
	c.f.queries = append(c.f.queries, query)
	c.f.qargs = append(c.f.qargs, values)
	c.f.mu.Unlock()
	if c.f.queryErr != nil {
		if err := c.f.queryErr(query); err != nil {
			return nil, err
		}
	}
	if c.f.answer != nil {
		if rows := c.f.answer(query, values); rows != nil {
			return rows, nil
		}
	}
	switch {
	case strings.Contains(query, "FROM config WHERE config_key"):
		if c.f.maxUsers == "" {
			return &fakeRows{}, nil
		}
		return &fakeRows{cols: []string{"value"}, rows: [][]driver.Value{{c.f.maxUsers}}}, nil
	case strings.Contains(query, "FROM ffs.settings WHERE name = 'max_accounts'"):
		if c.f.maxAccounts == "" {
			return &fakeRows{}, nil
		}
		return &fakeRows{cols: []string{"value"}, rows: [][]driver.Value{{c.f.maxAccounts}}}, nil
	case query == "SELECT COUNT(uid) FROM fxa.accounts":
		return &fakeRows{cols: []string{"n"}, rows: [][]driver.Value{{c.f.accountCount}}}, nil
	case strings.Contains(query, "FROM ffs_backups"):
		c.f.mu.Lock()
		defer c.f.mu.Unlock()
		return &fakeRows{cols: []string{"scope", "started", "finished", "ok", "bytes", "error", "location"}, rows: append([][]driver.Value(nil), c.f.backups...)}, nil
	case strings.HasSuffix(query, "FROM ffs.devices"):
		return &fakeRows{cols: []string{"uid", "created", "used", "ref"}, rows: append([][]driver.Value(nil), c.f.allDevices...)}, nil
	case strings.Contains(query, "FROM ffs_events"):
		c.f.mu.Lock()
		defer c.f.mu.Unlock()
		return &fakeRows{cols: []string{"at", "kind", "detail"}, rows: append([][]driver.Value(nil), c.f.events...)}, nil
	case strings.Contains(query, "FROM ffs_account_notes WHERE uid"):
		c.f.mu.Lock()
		defer c.f.mu.Unlock()
		uid, _ := args[0].Value.(string)
		if note, ok := c.f.notes[uid]; ok {
			return &fakeRows{cols: []string{"note", "at", "by"}, rows: [][]driver.Value{{note, int64(1700000000000), "admin (password)"}}}, nil
		}
		return &fakeRows{}, nil
	case c.f.nodes != nil && strings.HasPrefix(query, "SELECT COUNT(DISTINCT email) FROM users"):
		return &fakeRows{cols: []string{"n"}, rows: [][]driver.Value{{c.f.syncUsers}}}, nil
	case c.f.nodes != nil && strings.Contains(query, "FROM nodes n"):
		c.f.mu.Lock()
		defer c.f.mu.Unlock()
		return &fakeRows{cols: []string{"id", "node", "capacity", "load", "available", "downed", "backoff"}, rows: append([][]driver.Value(nil), c.f.nodes...)}, nil
	case strings.Contains(query, "FROM ffs.settings WHERE name = 'signups'"):
		mode := c.f.mode
		if mode == "" {
			mode = SignupsAllowlist
		}
		return &fakeRows{cols: []string{"value"}, rows: [][]driver.Value{{mode}}}, nil
	case strings.Contains(query, "FROM fxa.accounts a") && strings.Contains(query, "emailVerified = 0"):
		return &fakeRows{cols: []string{"uid", "email", "created"}, rows: append([][]driver.Value(nil), c.f.unconfirmed...)}, nil
	case strings.Contains(query, "FROM fxa.accounts WHERE uid"), strings.Contains(query, "FROM fxa.accounts ORDER BY"):
		disabled := int64(0)
		if c.f.disabled {
			disabled = 1
		}
		return &fakeRows{cols: []string{"uid", "email", "verified", "created", "disabled"},
			rows: [][]driver.Value{{strings.ToUpper(fakeUID), fakeEmail, int64(1), int64(1700000000000), disabled}}}, nil
	case strings.Contains(query, "FROM users u LEFT JOIN nodes n"):
		c.f.mu.Lock()
		defer c.f.mu.Unlock()
		return &fakeRows{cols: []string{"uid", "email", "state", "keys", "nodeid", "node", "downed", "known", "created", "replaced"}, rows: append([][]driver.Value(nil), c.f.users...)}, nil
	case strings.HasPrefix(query, "SELECT COUNT(*), COALESCE(SUM(LENGTH(payload)), 0) FROM bso WHERE"):
		// what a storage user id holds before it is deleted
		return &fakeRows{cols: []string{"n", "bytes"}, rows: [][]driver.Value{{int64(3), int64(300)}}}, nil
	case strings.Contains(query, "FROM ffs.devices WHERE uid"):
		return &fakeRows{cols: []string{"id", "name", "type", "created", "used", "ref"},
			rows: [][]driver.Value{{"d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1", "Firefox on laptop", "desktop", int64(1700000000000), float64(1700000100000), fakeRef}}}, nil
	case strings.Contains(query, "FROM ffs.sessions WHERE uid"):
		return &fakeRows{cols: []string{"ref", "browser", "os", "created", "used", "verified", "method", "ip"},
			rows: [][]driver.Value{{fakeRef, "Firefox", "Linux", int64(1700000000000), int64(1700000200000), int64(0), "", "203.0.113.7"}}}, nil
	case strings.Contains(query, "FROM ffs.account_security"):
		return &fakeRows{cols: []string{"uid", "totp", "key", "codes", "phone", "passkeys", "password", "keys", "locked", "unverified"},
			rows: [][]driver.Value{{fakeUID, int64(1), int64(0), int64(7), int64(0), int64(0), int64(1700000000000), int64(1700000000000), int64(0), int64(1)}}}, nil
	case strings.Contains(query, "FROM ffs.emails"):
		return &fakeRows{cols: []string{"email", "verified", "primary", "created"},
			rows: [][]driver.Value{{fakeEmail, int64(1), int64(1), int64(1700000000000)}, {"alice@example.org", int64(0), int64(0), int64(1700000300000)}}}, nil
	}
	return &fakeRows{}, nil
}

type fakeRows struct {
	cols []string
	rows [][]driver.Value
}

func (r *fakeRows) Columns() []string { return r.cols }
func (r *fakeRows) Close() error      { return nil }
func (r *fakeRows) Next(dest []driver.Value) error {
	if len(r.rows) == 0 {
		return io.EOF
	}
	copy(dest, r.rows[0])
	r.rows = r.rows[1:]
	return nil
}
