package main

import (
	"os"
	"regexp"
	"slices"
	"strings"
	"testing"
)

// the privileges of dbsetup.go are those of the admin UI's GRANT lines in db/mysql/sync.sql,
// the SQL that database-setup.sql and db-bootstrap fill in
func TestDBSetupPrivilegesOfTheTemplate(t *testing.T) {
	sqlText, err := os.ReadFile("../db/mysql/sync.sql")
	if err != nil {
		t.Skip("no ../db/mysql/sync.sql (the image's build context is admin/ only):", err)
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
			t.Errorf("%s: db/mysql/sync.sql grants %v, dbsetup.go checks %v", key, got[key], want)
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
