package main

import (
	"database/sql"
	"database/sql/driver"
	"strings"
	"testing"
)

func TestRestrictions(t *testing.T) {
	compose, k8s := deployment{}, deployment{kind: "kubernetes", release: "ffs", prefix: "ffs", secret: "ffs"}
	open := &SignupPolicy{Mode: SignupsOpen}
	texts := func(list []restriction) string {
		var out []string
		for _, r := range list {
			out = append(out, r.Text+" · "+r.Where+" ["+r.State+"] "+r.Href)
		}
		return strings.Join(out, "; ")
	}
	for _, c := range []struct {
		name string
		in   restrictionInput
		want string
	}{
		{"open and unlimited: nothing", restrictionInput{fxa: true, policy: open, accountLimit: &Limit{Unlimited: true}, sync: &SyncStatus{Unlimited: true, Users: 3}, d: compose}, ""},
		{"Mozilla's accounts: no sign-ups to show", restrictionInput{policy: &SignupPolicy{Mode: SignupsClosed}, sync: &SyncStatus{Unlimited: true}, d: compose}, ""},
		{"sign-ups closed", restrictionInput{fxa: true, policy: &SignupPolicy{Mode: SignupsClosed}, d: compose},
			"Sign-ups closed · set here [notice] #signups"},
		{"an allowlist", restrictionInput{fxa: true, policy: &SignupPolicy{Mode: SignupsAllowlist, Allowlist: []string{"@example.com", "bob@example.net"}}, d: compose},
			"Sign-ups: allowlist only (2 emails or domains) · set here [notice] #signups"},
		{"an allowlist of one", restrictionInput{fxa: true, policy: &SignupPolicy{Mode: SignupsAllowlist, Allowlist: []string{"@example.com"}}, d: compose},
			"Sign-ups: allowlist only (1 email or domain) · set here [notice] #signups"},
		{"max accounts here, room", restrictionInput{fxa: true, accountLimit: &Limit{Count: 3, Max: 10}, maxAccountsEditable: true, d: compose},
			"Max accounts 3/10 · set here [notice] #max-accounts"},
		{"max accounts fixed, near", restrictionInput{fxa: true, accountLimit: &Limit{Count: 9, Max: 10}, d: compose},
			"Max accounts 9/10 · .env: FXA_MAX_ACCOUNTS [near] #max-accounts"},
		{"max accounts full, the chart", restrictionInput{fxa: true, accountLimit: &Limit{Count: 10, Max: 10}, d: k8s},
			"Max accounts 10/10 · values: fxa.maxAccounts [full] #max-accounts"},
		{"no new accounts", restrictionInput{fxa: true, accountLimit: &Limit{Count: 4, Max: 0}, maxAccountsEditable: true, d: compose},
			"No new accounts (max accounts 0) · set here [notice] #max-accounts"},
		{"invite-only Sync here", restrictionInput{allowlist: &SyncAllowlist{Editable: true, Pending: make([]RefusedAccount, 2)}, sync: &SyncStatus{Unlimited: true}, d: compose},
			"Invite-only Sync (2 pending) · set here [notice] #sync-allowlist"},
		{"invite-only Sync of .env", restrictionInput{allowlist: &SyncAllowlist{}, d: compose},
			"Invite-only Sync (0 pending) · .env: SYNC_ALLOWED_ACCOUNTS [notice] #sync-allowlist"},
		{"max users here", restrictionInput{sync: &SyncStatus{Users: 3, MaxUsers: 10}, maxUsersEditable: true, d: compose},
			"Max users 3/10 · set here [notice] #sync"},
		{"max users fixed, full, the chart", restrictionInput{sync: &SyncStatus{Users: 5, MaxUsers: 5}, d: k8s},
			"Max users 5/5 · values: maxUsers [full] #sync"},
		{"no new Sync accounts", restrictionInput{sync: &SyncStatus{Users: 2, MaxUsers: 0}, d: compose},
			"No new Sync accounts (max users 0) · .env: SYNC_MAX_USERS [notice] #sync"},
	} {
		if got := texts(restrictions(c.in)); got != c.want {
			t.Errorf("%s:\n got %q\nwant %q", c.name, got, c.want)
		}
	}
	// where it is set, in full
	r := restrictions(restrictionInput{fxa: true, policy: &SignupPolicy{Mode: SignupsClosed}, d: k8s})
	if len(r) != 1 || r[0].Title != "Set in the Sign-ups card; fxa.signups replaces it when it changes there" {
		t.Errorf("title %+v", r)
	}
	r = restrictions(restrictionInput{sync: &SyncStatus{Users: 1, MaxUsers: 3}, maxUsersEditable: true, d: compose})
	if r[0].Title != "Set in the Sync card (SYNC_MAX_USERS=initial:N)" {
		t.Errorf("title %+v", r)
	}
}

// the badges on the overview: yellow notices, a limit near or full in amber
func TestOverviewRestrictions(t *testing.T) {
	fake := &fakeFxa{maxUsers: "10", syncUsers: 3, nodes: [][]driver.Value{}, mode: SignupsClosed, maxAccounts: "5", accountCount: 5}
	redis, _ := fakeRedis(t)
	app := testApp()
	app.fxa, app.sync, app.alerter = fake.db(redis), &SyncDB{db: sql.OpenDB(fake)}, &Alerter{}
	h := app.routes()
	c, _ := passwordSession(t, app, h)
	page := getPage(h, "/", c).Body.String()
	i := strings.Index(page, `id="restrictions"`)
	if i < 0 {
		t.Fatal("no badges")
	}
	badges := page[i:]
	badges = badges[:strings.Index(badges, "</ul>")]
	for _, want := range []string{`aria-label="Restricted on purpose"`,
		`<a class="pill notice" href="#signups" title="Set in the Sign-ups card; FXA_SIGNUPS replaces it when it changes there">Sign-ups closed <span class="where">· set here</span></a>`,
		`<a class="pill warn" href="#max-accounts" title="Fixed by FXA_MAX_ACCOUNTS: read-only here">Max accounts 5/5 <span class="where">· .env: FXA_MAX_ACCOUNTS</span></a>`,
		`<a class="pill notice" href="#sync" title="Fixed by SYNC_MAX_USERS: read-only here">Max users 3/10 <span class="where">· .env: SYNC_MAX_USERS</span></a>`} {
		if !strings.Contains(badges, want) {
			t.Errorf("no %q in %s", want, badges)
		}
	}
	// open and unlimited: no row
	fake.mode, fake.maxAccounts, fake.maxUsers = SignupsOpen, "unlimited", "unlimited"
	if page := getPage(h, "/", c).Body.String(); strings.Contains(page, `id="restrictions"`) {
		i := strings.Index(page, `id="restrictions"`)
		t.Errorf("badges when open: %s", page[i:min(i+500, len(page))])
	}
}
