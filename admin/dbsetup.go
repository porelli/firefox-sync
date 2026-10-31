package main

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
)

// The users and grants of database-setup.sql on your own database server (SYNC_DB_CONTAINERS=0,
// docs/databases.md#when-a-release-needs-new-users-or-grants): db-bootstrap applies them at
// every start as SYNC_DB_BOOTSTRAP_USER, or checks them and stops the start (db/db-setup.sh).
// The admin UI checks what it sees itself, as its own two users: the grants of their GRANT
// lines in db/mysql/sync.sql (dbsetup_test.go reads them there), and on PostgreSQL the
// ownership of its database and the databases closed to the other roles. Something missing
// (a grant revoked, a release that needs a new one) is named with its statement.

// the privileges of db/mysql/sync.sql's GRANT lines of the admin UI's users
var (
	// ADMIN_DB_USER on ADMIN_DB_NAME
	ownDBPrivileges = []string{"SELECT", "INSERT", "UPDATE", "DELETE", "CREATE", "ALTER", "INDEX", "DROP", "LOCK TABLES"}
	// ADMIN_DB_SYNC_USER on the tokenserver and the storage databases
	readerTokenserverPrivileges = []string{"SELECT", "EXECUTE"}
	readerStoragePrivileges     = []string{"SELECT", "DELETE"}
)

// mysqlPrivileges: the privileges of the connection's user on its database (and those on
// every database), as it sees them itself
func mysqlPrivileges(ctx context.Context, db *sql.DB) (map[string]bool, string, error) {
	var schema string
	if err := db.QueryRowContext(ctx, "SELECT DATABASE()").Scan(&schema); err != nil {
		return nil, "", err
	}
	rows, err := db.QueryContext(ctx, "SELECT PRIVILEGE_TYPE FROM information_schema.SCHEMA_PRIVILEGES WHERE TABLE_SCHEMA = DATABASE() "+
		"UNION SELECT PRIVILEGE_TYPE FROM information_schema.USER_PRIVILEGES")
	if err != nil {
		return nil, schema, err
	}
	defer rows.Close()
	have := map[string]bool{}
	for rows.Next() {
		var p string
		if err := rows.Scan(&p); err != nil {
			return nil, schema, err
		}
		have[strings.ToUpper(p)] = true
	}
	return have, schema, rows.Err()
}

// missingGrant: the statement of a GRANT line whose privileges the user lacks, "" when it has them all
func missingGrant(have map[string]bool, privileges []string, schema, user string) string {
	var lacks []string
	for _, p := range privileges {
		if !have[p] {
			lacks = append(lacks, p)
		}
	}
	if len(lacks) == 0 {
		return ""
	}
	return fmt.Sprintf("%s lacks %s on %s: GRANT %s ON `%s`.* TO '%s'@'%%';", user, strings.Join(lacks, ", "), schema,
		strings.Join(privileges, ", "), schema, user)
}

// dbSetupProblems: what the admin UI's users lack of database-setup.sql
func (a *App) dbSetupProblems(ctx context.Context) ([]string, error) {
	s := a.sync
	reader, ownUser := env("ADMIN_DB_SYNC_USER", "ffs_admin_sync"), env("ADMIN_DB_USER", "ffs_admin_ui")
	var problems []string
	if s.postgres {
		var owner string
		var syncOpen, ownOpen bool
		if err := s.own.QueryRowContext(ctx, "SELECT pg_catalog.pg_get_userbyid(datdba), pg_catalog.has_database_privilege('public', current_database(), 'CONNECT') "+
			"FROM pg_catalog.pg_database WHERE datname = current_database()").Scan(&owner, &ownOpen); err != nil {
			return nil, err
		}
		if err := s.db.QueryRowContext(ctx, "SELECT pg_catalog.has_database_privilege('public', current_database(), 'CONNECT')").Scan(&syncOpen); err != nil {
			return nil, err
		}
		if owner != ownUser {
			problems = append(problems, fmt.Sprintf("the database %s is %s's, not %s's: ALTER DATABASE %s OWNER TO %s;", s.ownName, owner, ownUser, s.ownName, ownUser))
		}
		if ownOpen {
			problems = append(problems, fmt.Sprintf("every role may connect to %s: REVOKE ALL ON DATABASE %s FROM PUBLIC;", s.ownName, s.ownName))
		}
		if syncOpen {
			db := env("TOKENSERVER_DB_NAME", "")
			problems = append(problems, fmt.Sprintf("every role may connect to %s: REVOKE ALL ON DATABASE %s FROM PUBLIC;", db, db))
		}
		return problems, nil
	}
	for _, c := range []struct {
		db         *sql.DB
		user       string
		privileges []string
	}{{s.own, ownUser, ownDBPrivileges}, {s.db, reader, readerTokenserverPrivileges}} {
		have, schema, err := mysqlPrivileges(ctx, c.db)
		if err != nil {
			return nil, err
		}
		if p := missingGrant(have, c.privileges, schema, c.user); p != "" {
			problems = append(problems, p)
		}
	}
	if a.storage != nil {
		have, schema, err := mysqlPrivileges(ctx, a.storage.db)
		if err != nil {
			return nil, err
		}
		if p := missingGrant(have, readerStoragePrivileges, schema, reader); p != "" {
			problems = append(problems, p)
		}
	}
	return problems, nil
}

// dbSetupCheck: the setup check of database-setup.sql, with your own database server and the
// admin UI's own database only (ok false: no check)
func (a *App) dbSetupCheck(ctx context.Context) (setupCheck, bool) {
	if a.sync == nil || a.sync.own == nil || env("SYNC_DB_CONTAINERS", "1") != "0" {
		return setupCheck{}, false
	}
	d := a.deployment
	c := setupCheck{Name: "Database users and grants (database-setup.sql)"}
	bootstrap := env("SYNC_DB_BOOTSTRAP_USER", "")
	setting := d.setting("SYNC_DB_BOOTSTRAP_USER", "database.external.bootstrap.user")
	problems, err := a.dbSetupProblems(ctx)
	switch {
	case err != nil:
		c.Text = "Could not read the grants of the admin UI's users on your database server: " + err.Error() + "."
	case len(problems) == 0:
		c.OK = true
		if bootstrap != "" {
			c.Text = "The admin UI's users have their grants of database-setup.sql. The stack applies it at every start as " + bootstrap + " (" + setting + ")."
		} else {
			c.Text = "The admin UI's users have their grants of database-setup.sql. The stack checks its users and grants at every start (db-bootstrap): " +
				"when a new release needs others, run database-setup.sql again (docs/databases.md#when-a-release-needs-new-users-or-grants)."
		}
	default:
		c.Text = "Your database server lacks what database-setup.sql gives the admin UI: " + strings.Join(problems, " ")
		if bootstrap != "" {
			c.Text += " The stack applies database-setup.sql at every start as " + bootstrap + " (" + setting + "): " + d.startInit() + "."
		} else {
			c.Text += " Run database-setup.sql again on your server, as its administrator, or let the stack apply it at every start with " + setting +
				" (docs/databases.md#when-a-release-needs-new-users-or-grants)."
		}
	}
	return c, true
}
