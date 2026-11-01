package main

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"strings"
	"time"
)

// The load of the Sync node. The tokenserver adds one to its current_load before it inserts a
// new account (allocate_user: add_user_to_node, then post_user, not in one transaction), and
// nothing takes it back when the database refuses the account (SYNC_ALLOWED_ACCOUNTS,
// SYNC_MAX_USERS): every refused try fills the node a little more, until it takes nobody. The
// init container counts it again at every start; here, every few minutes, the load of the
// node of SYNCSTORAGE_DOMAIN (not the others: upstream's tests steer their own nodes by their
// load) through the init container's ffs_resync_node_load, at once when it is off by
// nodeLoadDrift or more, which the setup checks show for a day.

const (
	nodeLoadEvery = 5 * time.Minute
	nodeLoadDrift = 10
	nodeLoadShown = 24 * time.Hour
)

type loadCorrection struct {
	Node      string
	Counted   int
	Accounts  int
	Corrected time.Time
}

// NodeLoad: the current_load of a node of sync-1.5 and the accounts it really has (emails with
// a row that is not replaced); found false without such a node
func (s *SyncDB) NodeLoad(ctx context.Context, node string) (counted, accounts int, found bool, err error) {
	err = s.db.QueryRowContext(ctx, s.q(`SELECT n.current_load,
		(SELECT COUNT(DISTINCT u.email) FROM users u WHERE u.nodeid = n.id AND u.replaced_at IS NULL)
		FROM nodes n JOIN services s ON n.service = s.id WHERE s.service = 'sync-1.5' AND TRIM(TRAILING '/' FROM n.node) = ?`), strings.TrimSuffix(node, "/")).Scan(&counted, &accounts)
	if err == sql.ErrNoRows {
		return 0, 0, false, nil
	}
	return counted, accounts, err == nil, err
}

func (s *SyncDB) ResyncNodeLoad(ctx context.Context, node string) error {
	return s.call(ctx, "ffs_resync_node_load", node)
}

// watchNodeLoad: the recount, when the load is off: every nodeLoadEvery, at once from
// nodeLoadDrift
func (h *Health) watchNodeLoad(ctx context.Context, now time.Time) {
	app := h.app
	if app == nil || app.sync == nil || app.syncDomain == "" {
		return
	}
	counted, accounts, found, err := app.sync.NodeLoad(ctx, app.syncDomain)
	if err != nil {
		log.Printf("the load of the Sync node: %v", err)
		return
	}
	drift := counted - accounts
	if !found || drift == 0 {
		return
	}
	h.mu.Lock()
	due := now.Sub(h.loadResynced) >= nodeLoadEvery || abs(drift) >= nodeLoadDrift
	h.mu.Unlock()
	if !due {
		return
	}
	if err := app.sync.ResyncNodeLoad(ctx, app.syncDomain); err != nil {
		log.Printf("the load of the Sync node: %v", err)
		return
	}
	log.Printf("the load of the Sync node %s counted again: %d, it was %d", app.syncDomain, accounts, counted)
	h.mu.Lock()
	h.loadResynced = now
	if abs(drift) >= nodeLoadDrift {
		h.loadCorrected = &loadCorrection{Node: app.syncDomain, Counted: counted, Accounts: accounts, Corrected: now}
	}
	h.mu.Unlock()
}

func abs(n int) int {
	if n < 0 {
		return -n
	}
	return n
}

// nodeLoadCheck: the setup check of the node's load, a warning for a day after a drift of
// nodeLoadDrift or more was corrected; false: nothing to show (no recount yet)
func (h *Health) nodeLoadCheck(now time.Time) (setupCheck, bool) {
	h.mu.Lock()
	c, resynced := h.loadCorrected, h.loadResynced
	h.mu.Unlock()
	check := setupCheck{Name: "Sync node load", OK: true}
	switch {
	case c != nil && now.Sub(c.Corrected) < nodeLoadShown:
		check.OK = false
		check.Text = fmt.Sprintf("The tokenserver counted %d accounts on %s, which has %d: refused sign-ups (SYNC_ALLOWED_ACCOUNTS, SYNC_MAX_USERS) count in its load, and a full node takes nobody. Counted again at %s; many refused tries in a short time can be someone trying.",
			c.Counted, c.Node, c.Accounts, formatTime(c.Corrected, adminZone))
	case !resynced.IsZero():
		check.Text = "The load of the Sync node is counted again from its accounts every few minutes (refused sign-ups count in it); last at " + formatTime(resynced, adminZone) + "."
	default:
		return check, false
	}
	return check, true
}
