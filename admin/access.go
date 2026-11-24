package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/http"
	"os"
	"strings"
)

// Access managed elsewhere, ADMIN_ACCESS_EXTERNAL (docs/admin/accounts.md#access-managed-elsewhere):
// another system decides who may use this server, through rows it writes into
// sync_allowed_accounts and a trigger of its own on users. The admin UI then shows the limits,
// the allowlist and the sign-ups as they are, and changes none of them: every form and confirm
// page that would is refused here, in its handler, whatever the page shows. Monitoring, storage,
// alerts, backups, the event log, the account pages and the reset and deletion of Sync data
// stay. The init container reads the same setting (db/<engine>/init/db_init.sh): it refuses a
// SYNC_ALLOWED_ACCOUNTS, leaves the rows of the allowlist alone, keeps its own invite-only
// trigger off, and writes allowed_accounts = external in the config table, which the setup
// check below compares with the admin UI's own setting.

// accessExternalSetting: the config row the init container writes with ADMIN_ACCESS_EXTERNAL
const accessExternalSetting = "external"

// loadAccessExternal: ADMIN_ACCESS_EXTERNAL, refused with a SYNC_ALLOWED_ACCOUNTS (two sources
// of who may sync), as the init container refuses it
func loadAccessExternal() (bool, error) {
	on, err := envSwitch("ADMIN_ACCESS_EXTERNAL")
	if err != nil || !on {
		return false, err
	}
	if v := strings.TrimSpace(os.Getenv("SYNC_ALLOWED_ACCOUNTS")); v != "" {
		return false, errors.New("ADMIN_ACCESS_EXTERNAL is on, so who may sync is decided outside firefox-sync: leave SYNC_ALLOWED_ACCOUNTS empty (docs/admin/accounts.md#access-managed-elsewhere)")
	}
	return true, nil
}

// accessExternalErr: why a change of who may use the server is refused here
func (a *App) accessExternalErr() error {
	return fmt.Errorf("who may use this server is managed outside the admin UI (%s): nothing changed here, change it in the system that manages it",
		a.deployment.valueName("ADMIN_ACCESS_EXTERNAL"))
}

// refuseAccessChange: true (and the page told why) when access is managed elsewhere
func (a *App) refuseAccessChange(w http.ResponseWriter, r *http.Request, s *session, back string) bool {
	if !a.accessExternal {
		return false
	}
	a.doneTo(w, r, s, back, "", a.accessExternalErr())
	return true
}

// AllowlistMode: the allowed_accounts row of the config table as the init container wrote it
// (on, off, external; "" without one)
func (s *SyncDB) AllowlistMode(ctx context.Context) (string, error) {
	var mode string
	err := s.db.QueryRowContext(ctx, "SELECT config_value FROM config WHERE config_key = 'allowed_accounts' AND config_value IS NOT NULL").Scan(&mode)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return mode, err
}

// externalAllowlist: the allowlist as the other system wrote it, read-only, without the
// refusals (its own trigger records none of firefox-sync's)
func (a *App) externalAllowlist(ctx context.Context) (*SyncAllowlist, error) {
	l := &SyncAllowlist{External: true}
	var err error
	l.Allowed, err = a.sync.AllowedAccounts(ctx)
	return l, err
}

// accessCheck: the setup check of the mode, when the admin UI or the init container has it on:
// both must, or one of them still manages access (the init container a SYNC_ALLOWED_ACCOUNTS
// of its own, the admin UI its forms)
func (a *App) accessCheck(ctx context.Context) (setupCheck, bool) {
	mode, err := a.sync.AllowlistMode(ctx)
	if err != nil {
		if !a.accessExternal {
			return setupCheck{}, false
		}
		return setupCheck{Name: accessCheckName, Text: "Could not read the mode the init container applied: " + err.Error()}, true
	}
	setting := a.deployment.valueName("ADMIN_ACCESS_EXTERNAL")
	switch {
	case a.accessExternal && mode == accessExternalSetting:
		return setupCheck{Name: accessCheckName, OK: true, Text: "Who may use this server is managed outside the admin UI (" + setting + "): the limits, the allowlist and the sign-ups are read-only here, and the init container leaves sync_allowed_accounts to that system."}, true
	case a.accessExternal:
		return setupCheck{Name: accessCheckName, Text: setting + " is on for the admin UI, but the init container did not apply it (allowed_accounts is " + quoteMode(mode) + "): give it the same setting and start it again, or it keeps managing the allowlist itself."}, true
	case mode == accessExternalSetting:
		return setupCheck{Name: accessCheckName, Text: "The init container applied " + setting + ", but the admin UI does not have it: give the admin UI the same setting and restart it, or its forms change who may use the server behind the system that manages it."}, true
	}
	return setupCheck{}, false
}

const accessCheckName = "Access managed elsewhere"

func quoteMode(mode string) string {
	if mode == "" {
		return "not set"
	}
	return "'" + oneLine(mode, 32) + "'"
}
