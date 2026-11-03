package main

import "fmt"

// The badges of the overview's summary: who may come in, when it is restricted on purpose
// (sign-ups closed or on an allowlist, a limit set, invite-only Sync). In yellow, a notice:
// the limits near or full keep their amber, a part down its red. Nothing when open and
// unlimited

type restriction struct {
	Text string
	// where it is changed: the card of the overview
	Href string
	// where it is set, short ("set here", ".env: SYNC_MAX_USERS"), and in full
	Where, Title string
	// notice (on purpose), near or full (limits.go)
	State string
}

type restrictionInput struct {
	fxa                 bool
	policy              *SignupPolicy
	accountLimit        *Limit
	maxAccountsEditable bool
	sync                *SyncStatus
	maxUsersEditable    bool
	allowlist           *SyncAllowlist
	d                   deployment
}

// limitState: notice for a limit with room, its own state near or full
func limitState(l Limit) string {
	if s := l.State(); s != limitOK {
		return s
	}
	return "notice"
}

func restrictions(in restrictionInput) []restriction {
	var list []restriction
	d := in.d
	// where a setting of .env (the chart's values) is
	fixed := func(env, values string) string {
		if d.Kubernetes() != nil {
			return "values: " + values
		}
		return ".env: " + env
	}
	if in.fxa && in.policy != nil {
		title := "Set in the Sign-ups card; " + d.valueName("FXA_SIGNUPS") + " replaces it when it changes there"
		switch in.policy.Mode {
		case SignupsClosed:
			list = append(list, restriction{Text: "Sign-ups closed", Href: "#signups", Where: "set here", Title: title, State: "notice"})
		case SignupsAllowlist:
			n := len(in.policy.Allowlist)
			what := fmt.Sprintf("%d emails or domains", n)
			if n == 1 {
				what = "1 email or domain"
			}
			list = append(list, restriction{Text: "Sign-ups: allowlist only (" + what + ")", Href: "#signups", Where: "set here", Title: title, State: "notice"})
		}
	}
	if in.fxa && in.accountLimit != nil && !in.accountLimit.Unlimited {
		l := *in.accountLimit
		r := restriction{Text: fmt.Sprintf("Max accounts %d/%d", l.Count, l.Max), Href: "#max-accounts", State: limitState(l)}
		if l.Max == 0 {
			r.Text = "No new accounts (max accounts 0)"
		}
		if in.maxAccountsEditable {
			r.Where, r.Title = "set here", "Set in the Max accounts form ("+d.valueName("FXA_MAX_ACCOUNTS")+"=initial:N)"
		} else {
			r.Where, r.Title = fixed("FXA_MAX_ACCOUNTS", "fxa.maxAccounts"), "Fixed by "+d.valueName("FXA_MAX_ACCOUNTS")+": read-only here"
		}
		list = append(list, r)
	}
	if l := in.allowlist; l != nil {
		r := restriction{Text: fmt.Sprintf("Invite-only Sync (%d pending)", len(l.Pending)), Href: "#sync-allowlist", State: "notice"}
		if l.Editable {
			r.Where, r.Title = "set here", "Managed in the Invite-only Sync card ("+d.valueName("SYNC_ALLOWED_ACCOUNTS")+"=admin)"
		} else {
			r.Where, r.Title = fixed("SYNC_ALLOWED_ACCOUNTS", "allowedAccounts"), "The list of "+d.valueName("SYNC_ALLOWED_ACCOUNTS")+": read-only here"
		}
		list = append(list, r)
	}
	if st := in.sync; st != nil && !st.Unlimited {
		l := st.Limit()
		r := restriction{Text: fmt.Sprintf("Max users %d/%d", l.Count, l.Max), Href: "#sync", State: limitState(l)}
		if l.Max == 0 {
			r.Text = "No new Sync accounts (max users 0)"
		}
		maxUsers := d.setting("SYNC_MAX_USERS", "maxUsers")
		if in.maxUsersEditable {
			r.Where, r.Title = "set here", "Set in the Sync card ("+maxUsers+"=initial:N)"
		} else {
			r.Where, r.Title = fixed("SYNC_MAX_USERS", "maxUsers"), "Fixed by "+maxUsers+": read-only here"
		}
		list = append(list, r)
	}
	return list
}
