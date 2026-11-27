package main

import (
	"context"
	"database/sql/driver"
	"errors"
	"net"
	"slices"
	"strings"
	"testing"
	"time"
)

const otherUID = "fedcba98fedcba98fedcba98fedcba98"

// queued: a fake accounts database whose revocationsTable holds rows (id, uid)
func queued(rows ...[]driver.Value) *fakeFxa {
	return &fakeFxa{answer: func(query string, args []driver.Value) *fakeRows {
		if !strings.Contains(query, "FROM "+revocationsTable) {
			return nil
		}
		found := &fakeRows{cols: []string{"id", "uid"}}
		for _, r := range rows {
			if len(args) == 1 && strings.Contains(query, "WHERE uid = ?") {
				if id, _ := args[0].([]byte); r[1] != strings.ToLower(hexOf(id)) {
					continue
				}
			}
			found.rows = append(found.rows, r)
		}
		return found
	}}
}

func hexOf(b []byte) string {
	const digits = "0123456789abcdef"
	out := make([]byte, 0, 2*len(b))
	for _, c := range b {
		out = append(out, digits[c>>4], digits[c&15])
	}
	return string(out)
}

// deletes: the DELETE statements of revocationsTable, with their ids
func deletes(f *fakeFxa) [][]driver.Value {
	f.mu.Lock()
	defer f.mu.Unlock()
	var found [][]driver.Value
	for i, q := range f.execs {
		if strings.HasPrefix(q, "DELETE FROM "+revocationsTable) {
			found = append(found, f.args[i])
		}
	}
	return found
}

// downRedis: an address where nothing listens
func downRedis(t *testing.T) string {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	ln.Close()
	return addr
}

func evalKeys(t *testing.T, revoked chan string) []string {
	t.Helper()
	var keys []string
	for {
		select {
		case cmd := <-revoked:
			for _, uid := range []string{fakeUID, otherUID} {
				if strings.Contains(cmd, "$35\r\nat:"+uid+"\r\n") && strings.Contains(cmd, "fxa-auth-session"+uid) && strings.Contains(cmd, "rt:"+uid) {
					keys = append(keys, uid)
				}
			}
		case <-time.After(200 * time.Millisecond):
			return keys
		}
	}
}

func TestRevokePendingRevokesThenDeletesTheRowsRead(t *testing.T) {
	// two requests for one account, one for another: one revoke each, oldest first, and the
	// rows read deleted after their revoke
	fake := queued([]driver.Value{int64(3), fakeUID}, []driver.Value{int64(4), otherUID}, []driver.Value{int64(7), fakeUID})
	redis, revoked := fakeRedis(t)
	n, err := fake.db(redis).RevokePending(context.Background())
	if err != nil || n != 2 {
		t.Fatalf("%d, %v", n, err)
	}
	if keys := evalKeys(t, revoked); !slices.Equal(keys, []string{fakeUID, otherUID}) {
		t.Errorf("revoked %v", keys)
	}
	got := deletes(fake)
	if len(got) != 2 || !slices.Equal(got[0], []driver.Value{int64(3), int64(7)}) || !slices.Equal(got[1], []driver.Value{int64(4)}) {
		t.Errorf("deleted %v", got)
	}
	// by id, not by uid: a request queued during the revoke stays for the next round
	for _, q := range fake.statements() {
		if strings.HasPrefix(q, "DELETE FROM "+revocationsTable) && q != "DELETE FROM "+revocationsTable+" WHERE id IN (?, ?)" && q != "DELETE FROM "+revocationsTable+" WHERE id IN (?)" {
			t.Errorf("delete %q", q)
		}
	}
	if q := fake.queried("FROM " + revocationsTable); len(q) != 1 || q[0][0] != int64(revokeBatch) {
		t.Errorf("read %v", q)
	}
}

func TestRevokePendingKeepsTheRowsWhenRedisFails(t *testing.T) {
	fake := queued([]driver.Value{int64(1), fakeUID})
	n, err := fake.db(downRedis(t)).RevokePending(context.Background())
	if err == nil || n != 0 || !strings.HasPrefix(err.Error(), "Redis: ") {
		t.Fatalf("%d, %v", n, err)
	}
	if got := deletes(fake); len(got) != 0 {
		t.Errorf("deleted %v without a revoke", got)
	}
	// nothing queued: nothing asked of Redis
	empty := queued()
	if n, err := empty.db(downRedis(t)).RevokePending(context.Background()); n != 0 || err != nil {
		t.Errorf("empty queue: %d, %v", n, err)
	}
}

func TestRevokePendingWithoutTheTable(t *testing.T) {
	// fxa-policy older than the admin UI: the error, nothing revoked or deleted
	fake := &fakeFxa{queryErr: func(q string) error {
		if strings.Contains(q, revocationsTable) {
			return errors.New("Error 1146: Table 'ffs.pending_revocations' doesn't exist")
		}
		return nil
	}}
	redis, revoked := fakeRedis(t)
	if n, err := fake.db(redis).RevokePending(context.Background()); n != 0 || err == nil {
		t.Errorf("%d, %v", n, err)
	}
	if keys := evalKeys(t, revoked); len(keys) != 0 {
		t.Errorf("revoked %v", keys)
	}
	// the admin UI's own actions still revoke right away
	if err := fake.db(redis).SignOutAll(context.Background(), fakeUID); err != nil {
		t.Fatal(err)
	}
	if keys := evalKeys(t, revoked); !slices.Equal(keys, []string{fakeUID}) {
		t.Errorf("revoked %v", keys)
	}
}

func TestAdminActionsRevokeAndDeleteTheirRows(t *testing.T) {
	for name, act := range map[string]func(*FxaDB) error{
		"disable":      func(f *FxaDB) error { return f.SetDisabled(context.Background(), strings.ToUpper(fakeUID), true) },
		"sign out all": func(f *FxaDB) error { return f.SignOutAll(context.Background(), fakeUID) },
		"delete":       func(f *FxaDB) error { return f.DeleteAccount(context.Background(), fakeUID) },
	} {
		fake := queued([]driver.Value{int64(5), fakeUID}, []driver.Value{int64(6), otherUID})
		fake.disabled = true
		redis, revoked := fakeRedis(t)
		if err := act(fake.db(redis)); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if keys := evalKeys(t, revoked); !slices.Equal(keys, []string{fakeUID}) {
			t.Errorf("%s: revoked %v", name, keys)
		}
		// the account's rows only: another's stays for revokePending
		if got := deletes(fake); len(got) != 1 || !slices.Equal(got[0], []driver.Value{int64(5)}) {
			t.Errorf("%s: deleted %v", name, got)
		}

		// Redis down: done in the database, the rows kept for the next round, and said so
		fake = queued([]driver.Value{int64(5), fakeUID})
		fake.disabled = true
		err := act(fake.db(downRedis(t)))
		var partial *partialError
		if !errors.As(err, &partial) || !strings.Contains(err.Error(), "retried every 5s") {
			t.Errorf("%s with Redis down: %v", name, err)
		}
		if got := deletes(fake); len(got) != 0 {
			t.Errorf("%s with Redis down: deleted %v", name, got)
		}
	}
}

func TestRevocationsQueuedWithTheSignOut(t *testing.T) {
	for _, external := range []bool{false, true} {
		stmts := fxaPolicySQLFor(external)
		table := slices.IndexFunc(stmts, func(s string) bool { return strings.HasPrefix(s, "CREATE TABLE IF NOT EXISTS "+revocationsTable+" (") })
		first := slices.IndexFunc(stmts, func(s string) bool { return strings.HasPrefix(s, "CREATE PROCEDURE ") })
		if table < 0 || table > first {
			t.Errorf("external %v: the table at %d, the first procedure at %d", external, table, first)
		}
		// in the transaction of the sign-out and of the deletion: committed with them, never alone
		for _, name := range []string{"ffs.sign_out_all", "ffs.delete_account"} {
			proc := policyStmt(t, stmts, name)
			start, insert := strings.LastIndex(proc, "START TRANSACTION;"), strings.Index(proc, queueRevocation)
			commit := strings.LastIndex(proc, "COMMIT;")
			if start < 0 || insert < start || commit < insert || strings.Count(proc, queueRevocation) != 1 {
				t.Errorf("external %v, %s: %s", external, name, proc)
			}
		}
		// Disable, the procedures by email and the sweep go through ffs.sign_out_all
		disable := policyStmt(t, stmts, "ffs.disable_account")
		if !strings.Contains(disable, "CALL ffs.sign_out_all(p_uid)") {
			t.Errorf("external %v: %s", external, disable)
		}
		for _, name := range []string{"ffs.disable_account_by_email", "ffs.delete_account_by_email"} {
			if !strings.Contains(policyStmt(t, stmts, name), "CALL ffs.") {
				t.Errorf("%s calls none of ffs", name)
			}
		}
		// ffs_access: nothing on the table, in both modes
		for _, g := range fxaAccessGrantsFor(external) {
			if strings.Contains(g, revocationsTable) {
				t.Errorf("ffs_access: %s", g)
			}
		}
		grants, _ := fxaAdminGrantsFor(external)
		if !slices.Contains(grants, "GRANT SELECT, DELETE ON "+revocationsTable+" TO 'ffs_admin'@'%'") {
			t.Errorf("external %v: ffs_admin cannot read and delete the queue", external)
		}
	}
	sweep := externalOnlySQL["DROP PROCEDURE IF EXISTS "+sweepProcedure]
	if !strings.Contains(sweep, "CALL ffs.disable_account(v_uid)") {
		t.Errorf("the sweep: %s", sweep)
	}
}

func TestRevokeLoopRunsAtOnceAndStops(t *testing.T) {
	// a round at the start (rows queued while the admin UI was down), then every revokeInterval
	fake := queued([]driver.Value{int64(1), fakeUID})
	redis, revoked := fakeRedis(t)
	app := testApp()
	app.fxa = fake.db(redis)
	ctx, cancel := context.WithCancel(context.Background())
	stopped := make(chan struct{})
	go func() { app.revokePending(ctx); close(stopped) }()
	select {
	case <-revoked:
	case <-time.After(2 * time.Second):
		t.Fatal("no revoke at the start")
	}
	cancel()
	select {
	case <-stopped:
	case <-time.After(2 * time.Second):
		t.Fatal("still running after the context ended")
	}
}
