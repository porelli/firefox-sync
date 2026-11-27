package main

import (
	"context"
	"fmt"
	"log"
	"strings"
	"time"
)

// The access tokens of fxa-auth (v1.350.0) live in its Redis only, and /v1/verify, which the
// tokenserver and the profile server ask, reads them there: the database cannot revoke them.
// ffs.sign_out_all (Disable, Sign out everywhere, ffs_access's procedures by email and its
// sweep) and ffs.delete_account queue the account in revocationsTable, in their transaction.
// The admin UI revokes the queued accounts in Redis (revokeRedisTokens: Mozilla's at:<uid> set
// and its at:<token id> keys) every revokeInterval, then deletes the rows it read: a row queued
// meanwhile is the next round's. Without the admin UI the rows wait, and the access tokens live
// until they expire (FXA_ACCESS_TOKEN_LIFETIME), docs/admin/accounts.md#sign-out-and-disable
const (
	revokeInterval = 5 * time.Second
	// rows read per round: the rest the next round
	revokeBatch = 500
)

// pendingRevocations: the row ids queued, by account id (lowercase hex)
func (f *FxaDB) pendingRevocations(ctx context.Context, uid string) (map[string][]int64, []string, error) {
	query, args := "SELECT id, LOWER(HEX(uid)) FROM "+revocationsTable+" ORDER BY id LIMIT ?", []any{revokeBatch}
	if uid != "" {
		id, err := accountID(uid)
		if err != nil {
			return nil, nil, err
		}
		query, args = "SELECT id, LOWER(HEX(uid)) FROM "+revocationsTable+" WHERE uid = ? ORDER BY id", []any{id}
	}
	rows, err := f.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	ids := map[string][]int64{}
	var order []string
	for rows.Next() {
		var id int64
		var u string
		if err := rows.Scan(&id, &u); err != nil {
			return nil, nil, err
		}
		if ids[u] == nil {
			order = append(order, u)
		}
		ids[u] = append(ids[u], id)
	}
	return ids, order, rows.Err()
}

// doneRevocations deletes the rows read before the revoke, not those queued since
func (f *FxaDB) doneRevocations(ctx context.Context, ids []int64) error {
	if len(ids) == 0 {
		return nil
	}
	args := make([]any, len(ids))
	for i, id := range ids {
		args[i] = id
	}
	_, err := f.db.ExecContext(ctx, "DELETE FROM "+revocationsTable+" WHERE id IN (?"+strings.Repeat(", ?", len(ids)-1)+")", args...)
	return err
}

// RevokePending revokes in Redis the access tokens of the accounts queued, oldest first, and
// deletes their rows. Stops at the first Redis error (the next round tries again): the count
// of the accounts done until then
func (f *FxaDB) RevokePending(ctx context.Context) (int, error) {
	ids, order, err := f.pendingRevocations(ctx, "")
	if err != nil {
		return 0, err
	}
	done := 0
	for _, uid := range order {
		if _, err := revokeRedisTokens(ctx, f.redis, uid); err != nil {
			return done, fmt.Errorf("Redis: %w", err)
		}
		if err := f.doneRevocations(ctx, ids[uid]); err != nil {
			return done, err
		}
		done++
	}
	return done, nil
}

// revokeNow: the admin UI's own actions, right after their procedure: the access tokens of
// the account revoked in Redis, then the rows the procedure queued deleted. When the rows
// cannot be read (fxa-policy older than the admin UI: no table), revoked all the same. When
// Redis fails, the rows stay and the next round of revokePending tries again
func (f *FxaDB) revokeNow(ctx context.Context, uid string) error {
	ids, _, qerr := f.pendingRevocations(ctx, uid)
	if _, err := revokeRedisTokens(ctx, f.redis, uid); err != nil {
		return err
	}
	if qerr == nil {
		if err := f.doneRevocations(ctx, ids[uid]); err != nil {
			log.Printf("access tokens revoked, but their rows of %s stay (revoked again in %s): %v", revocationsTable, revokeInterval, err)
		}
	}
	return nil
}

// revokePending runs RevokePending every revokeInterval. It logs a failure once, until a
// round works again
func (a *App) revokePending(ctx context.Context) {
	tick := time.NewTicker(revokeInterval)
	defer tick.Stop()
	failing := ""
	for {
		n, err := a.fxa.RevokePending(ctx)
		switch {
		case ctx.Err() != nil:
			return
		case err != nil && err.Error() != failing:
			failing = err.Error()
			log.Printf("revoking the access tokens of the accounts signed out (%s), retried every %s: %v", revocationsTable, revokeInterval, err)
		case err == nil && failing != "":
			failing = ""
			log.Printf("revoking the access tokens of the accounts signed out works again")
		}
		if n > 0 {
			log.Printf("revoked the access tokens of %d accounts signed out or disabled in the accounts database", n)
		}
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}
