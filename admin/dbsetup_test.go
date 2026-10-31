package main

import (
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
)

// the privileges of dbsetup.go are those of the admin UI's GRANT lines in the setup migrations
// of db/mysql/setup/sync, the SQL that database-setup.sql and db-bootstrap fill in (a later
// file's GRANT adds to them)
func TestDBSetupPrivilegesOfTheTemplate(t *testing.T) {
	files, _ := filepath.Glob("../db/mysql/setup/sync/*.sql")
	if len(files) == 0 {
		t.Skip("no ../db/mysql/setup/sync (the image's build context is admin/ only)")
	}
	var sqlText []byte
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		sqlText = append(sqlText, b...)
	}
	var statements []string
	for _, line := range strings.Split(string(sqlText), "\n") {
		if !strings.HasPrefix(strings.TrimSpace(line), "--") {
			statements = append(statements, strings.TrimSpace(line))
		}
	}
	grant := regexp.MustCompile("GRANT (.+?) ON `@([A-Z_]+)@`\\.\\* TO '@([A-Z_]+)@'@'%';")
	got := map[string][]string{}
	for _, m := range grant.FindAllStringSubmatch(strings.Join(statements, " "), -1) {
		got[m[3]+" "+m[2]] = strings.Split(m[1], ", ")
	}
	for key, want := range map[string][]string{
		"ADMIN_USER ADMIN_DATABASE":                 ownDBPrivileges,
		"ADMIN_SYNC_USER SYNC_TOKENSERVER_DATABASE": readerTokenserverPrivileges,
		"ADMIN_SYNC_USER SYNC_STORAGE_DATABASE":     readerStoragePrivileges,
	} {
		if !slices.Equal(got[key], want) {
			t.Errorf("%s: db/mysql/setup/sync grants %v, dbsetup.go checks %v", key, got[key], want)
		}
	}
}

func TestMissingGrant(t *testing.T) {
	have := map[string]bool{"SELECT": true, "USAGE": true}
	if got := missingGrant(have, readerTokenserverPrivileges, "tokenserver", "ffs_admin_sync"); got !=
		"ffs_admin_sync lacks EXECUTE on tokenserver: GRANT SELECT, EXECUTE ON `tokenserver`.* TO 'ffs_admin_sync'@'%';" {
		t.Errorf("missingGrant: %q", got)
	}
	have["EXECUTE"] = true
	if got := missingGrant(have, readerTokenserverPrivileges, "tokenserver", "ffs_admin_sync"); got != "" {
		t.Errorf("every privilege there: %q", got)
	}
}

// no check with the stack's database containers, nor without the admin UI's own database
func TestDBSetupCheckOnlyWithYourOwnServer(t *testing.T) {
	t.Setenv("SYNC_DB_CONTAINERS", "1")
	if _, ok := (&App{sync: &SyncDB{}}).dbSetupCheck(t.Context()); ok {
		t.Error("a check with the database containers")
	}
	t.Setenv("SYNC_DB_CONTAINERS", "0")
	if _, ok := (&App{sync: &SyncDB{}}).dbSetupCheck(t.Context()); ok {
		t.Error("a check without the admin UI's own database")
	}
}

// SHOW GRANTS as MySQL and MariaDB print it: the database of a grant's pattern (escaped
// underscores, wildcards), ALL PRIVILEGES, every database, the partial revokes, and the
// privileges of the roles (USING, or MariaDB's default role) as the lines they add
func TestGrantedOn(t *testing.T) {
	lines := []string{
		"GRANT USAGE ON *.* TO `ffs_admin_sync`@`%` IDENTIFIED BY PASSWORD '*58C5812E52ADD8210200214595DA96707DF510BA'",
		"GRANT SELECT ON `tokenserver`.* TO `ffs_admin_sync`@`%`",
		"GRANT `r_reader`@`%` TO `ffs_admin_sync`@`%`",
		"GRANT EXECUTE ON `token%`.* TO `r_reader`@`%`",
		"GRANT DELETE ON `fxa\\_oauth`.* TO `ffs_admin_sync`@`%`",
		"GRANT SELECT (`Host`, `User`) ON `mysql`.`user` TO `ffs_admin_sync`@`%`",
	}
	have := grantedOn(lines, "tokenserver")
	if !have["SELECT"] || !have["EXECUTE"] || have["DELETE"] {
		t.Errorf("tokenserver: %v", have)
	}
	if have := grantedOn(lines, "fxa_oauth"); !have["DELETE"] || have["SELECT"] {
		t.Errorf("fxa_oauth (fxa\\_oauth): %v", have)
	}
	if have := grantedOn(lines, "fxaXoauth"); have["DELETE"] {
		t.Errorf("fxa\\_oauth is no wildcard: %v", have)
	}
	if have := grantedOn([]string{"GRANT ALL PRIVILEGES ON `ffs_admin`.* TO `u`@`%`"}, "ffs_admin"); !have["LOCK TABLES"] || !have["CREATE ROUTINE"] {
		t.Errorf("ALL PRIVILEGES: %v", have)
	}
	if have := grantedOn([]string{"GRANT SELECT, DELETE ON *.* TO `u`@`%`", "REVOKE DELETE ON `syncstorage`.* FROM `u`@`%`"}, "syncstorage"); !have["SELECT"] || have["DELETE"] {
		t.Errorf("*.* with a partial revoke: %v", have)
	}
	for pattern, db := range map[string]string{"fx%": "fxa", "tok_nserver": "tokenserver", "a\\%b": "a%b"} {
		if !grantPatternMatches(pattern, db) {
			t.Errorf("%s does not match %s", pattern, db)
		}
	}
	for pattern, db := range map[string]string{"fx": "fxa", "a\\%b": "axxb", "tokenserver": "tokenserver2"} {
		if grantPatternMatches(pattern, db) {
			t.Errorf("%s matches %s", pattern, db)
		}
	}
}
