package main

import (
	"fmt"
	"math"
	"strconv"
	"strings"
)

// The limits of accounts: max users of the Sync server (MAX_USERS, the config table of
// the tokenserver, enforced by its trigger) and, with self-hosted accounts,
// FXA_MAX_ACCOUNTS (ffs.settings, enforced by ffs.signup_allowed: the trigger and the
// gate). Both take a number or "unlimited"; 0 means no new account at all, on purpose.
// Each shows its count against the limit, a warning at 90% and another when full.

const unlimitedSetting = "unlimited"

// Limit: how many there are, and the limit (Unlimited: none)
type Limit struct {
	Count, Max int
	Unlimited  bool
}

// the states of a limit, for the health rows, Needs attention and the alerts
const (
	limitOK   = "ok"
	limitNear = "near"
	limitFull = "full"
)

// State: near at 90% or more, full when all are taken. Unlimited: never; 0 refuses
// everybody on purpose, not a warning
func (l Limit) State() string {
	switch {
	case l.Unlimited || l.Max <= 0:
		return limitOK
	case l.Count >= l.Max:
		return limitFull
	case l.Count*10 >= l.Max*9:
		return limitNear
	}
	return limitOK
}

// Setting: the value as in .env and the database, "5" or "unlimited"
func (l Limit) Setting() string {
	if l.Unlimited {
		return unlimitedSetting
	}
	return strconv.Itoa(l.Max)
}

// parseLimitValue: a number from 0 to 2^31-1 (the triggers read it into an INT) or unlimited
func parseLimitValue(s string) (n int, unlimited bool, err error) {
	s = strings.TrimSpace(s)
	if strings.EqualFold(s, unlimitedSetting) {
		return 0, true, nil
	}
	// digits only: no sign, no spaces inside
	if s == "" || strings.Trim(s, "0123456789") != "" {
		return 0, false, errLimitValue
	}
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil || v > math.MaxInt32 {
		return 0, false, errLimitValue
	}
	return int(v), false, nil
}

var errLimitValue = fmt.Errorf("a number from 0 to %d, or unlimited", math.MaxInt32)

// parseLimitSetting: a setting of .env (SYNC_MAX_USERS as MAX_USERS, FXA_MAX_ACCOUNTS): N, fixed:N or
// unlimited (set on every start, read-only in the admin UI), initial:N (set when there
// is none yet, then managed in the admin UI). empty: the setting when none is given
func parseLimitSetting(s, empty string) (value string, fixed bool, err error) {
	s = strings.TrimSpace(s)
	if s == "" {
		s = empty
	}
	fixed = true
	if v, ok := strings.CutPrefix(s, "initial:"); ok {
		s, fixed = v, false
	} else if v, ok := strings.CutPrefix(s, "fixed:"); ok {
		s = v
	}
	n, unlimited, err := parseLimitValue(s)
	if err != nil {
		return "", false, err
	}
	return Limit{Max: n, Unlimited: unlimited}.Setting(), fixed, nil
}

// limitEditable: the admin UI manages the limit with initial:N (and for
// FXA_MAX_ACCOUNTS when not given, its default is initial:unlimited)
func limitEditable(setting string, emptyEditable bool) bool {
	setting = strings.TrimSpace(setting)
	return strings.HasPrefix(setting, "initial:") || (emptyEditable && setting == "")
}

// limitForm: the value of the forms, the number or the box "no limit" (unlimited=1);
// "unlimited" typed in the number works too (scripts)
func limitForm(number, noLimit string) (n int, unlimited bool, err error) {
	if noLimit == "1" {
		return 0, true, nil
	}
	return parseLimitValue(number)
}

// limit kinds: the row of the health table, the key of its alerts, the words
type limitKind struct {
	name, key, setting, href, link string
	// "accounts are taken", "accounts are created"
	noun, verb string
	// what a full limit refuses
	refused string
}

var (
	syncLimit = limitKind{name: "Max users", key: "near-max-users", setting: "SYNC_MAX_USERS", href: "#sync", link: "Max users",
		noun: "accounts", verb: "taken", refused: "new accounts are refused by the Sync server"}
	accountsLimit = limitKind{name: "Max accounts", key: "max-accounts", setting: "FXA_MAX_ACCOUNTS", href: "#signups", link: "Max accounts",
		noun: "accounts", verb: "created", refused: "sign-ups are refused"}
)

// line: what the state of the limit means, for Needs attention, the health row and the alerts
func (k limitKind) line(l Limit) string {
	switch l.State() {
	case limitFull:
		return fmt.Sprintf("%d of %d %s are %s (%s): %s until it is raised", l.Count, l.Max, k.noun, k.verb, k.setting, k.refused)
	case limitNear:
		return fmt.Sprintf("%d of %d %s are %s (90%% or more): %s once all are", l.Count, l.Max, k.noun, k.verb, k.refused)
	}
	return ""
}

// detail: the count against the limit when it is fine
func (k limitKind) detail(l Limit) string {
	switch {
	case l.Unlimited:
		return plural(l.Count, "account") + ", no limit"
	case l.Max == 0:
		return fmt.Sprintf("%s, no new ones (%s 0)", plural(l.Count, "account"), k.setting)
	}
	return fmt.Sprintf("%d of %d %s", l.Count, l.Max, k.verb)
}

// row: the limit in the health table, counted by the health light only when near or
// full (it is no part of the server: shown, not counted while fine)
func (k limitKind) row(l Limit) Component {
	c := Component{Name: k.name, Limit: true}
	switch l.State() {
	case limitNear:
		c.Warn, c.Label, c.Error = true, "near the limit", k.line(l)
	case limitFull:
		c.Warn, c.Label, c.Error = true, "full", k.line(l)
	default:
		c.Up, c.Detail = true, k.detail(l)
	}
	return c
}

// event: the alert of a change of the state of the limit, "" for none
func (k limitKind) event(l Limit) string {
	if line := k.line(l); line != "" {
		return line
	}
	if l.Unlimited {
		return fmt.Sprintf("%s: no limit now (%s)", k.name, plural(l.Count, "account"))
	}
	if l.Max == 0 {
		return fmt.Sprintf("%s: 0 now, no new accounts (%s)", k.name, plural(l.Count, "account"))
	}
	return fmt.Sprintf("%d of %d %s are %s, under 90%% again", l.Count, l.Max, k.noun, k.verb)
}

// limitRows: the rows of the limits there are (nil: not read); external (access managed
// elsewhere, ADMIN_ACCESS_EXTERNAL): the count only, never a warning to raise them
func limitRows(sync, accounts *Limit, external bool) []Component {
	var rows []Component
	for _, l := range []struct {
		k limitKind
		l *Limit
	}{{syncLimit, sync}, {accountsLimit, accounts}} {
		switch {
		case l.l == nil:
		case external:
			rows = append(rows, Component{Name: l.k.name, Limit: true, Up: true, Detail: l.k.detail(*l.l) + ", managed elsewhere"})
		default:
			rows = append(rows, l.k.row(*l.l))
		}
	}
	return rows
}
