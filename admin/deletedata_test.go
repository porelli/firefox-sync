package main

import (
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"database/sql"
	"database/sql/driver"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

// testDeleteKey: a 2048-bit key, its PEM in PKCS #1 and #8
func testDeleteKey(t *testing.T) (*rsa.PrivateKey, string, string) {
	t.Helper()
	k, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	pkcs8, err := x509.MarshalPKCS8PrivateKey(k)
	if err != nil {
		t.Fatal(err)
	}
	return k, string(pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(k)})),
		string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: pkcs8}))
}

func TestParseDeleteKey(t *testing.T) {
	k, pkcs1, pkcs8 := testDeleteKey(t)
	b64 := base64.StdEncoding.EncodeToString
	// openssl genpkey (prepare_environment.sh: base64 of PKCS #8), genPrivateKey of the chart (PKCS #1)
	for name, v := range map[string]string{"pkcs1": pkcs1, "pkcs8": pkcs8, "pkcs1 base64": b64([]byte(pkcs1)), "pkcs8 base64": b64([]byte(pkcs8)) + "\n"} {
		got, err := parseDeleteKey(v)
		if err != nil || !got.Equal(k) {
			t.Errorf("%s: %v", name, err)
		}
	}
	small, _ := rsa.GenerateKey(rand.Reader, 1024)
	ec, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	ecDER, _ := x509.MarshalPKCS8PrivateKey(ec)
	for name, v := range map[string]string{
		"garbage":  "not a key",
		"empty":    " ",
		"no PEM":   b64([]byte("hello")),
		"1024":     string(pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(small)})),
		"ec":       string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: ecDER})),
		"pem junk": "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n",
	} {
		if _, err := parseDeleteKey(v); err == nil {
			t.Errorf("%s: taken", name)
		} else if strings.Contains(err.Error(), v) && len(v) > 8 {
			t.Errorf("%s: the value in the error: %v", name, err)
		}
	}
}

func TestNewSyncDeleter(t *testing.T) {
	_, pkcs1, _ := testDeleteKey(t)
	if d, err := newSyncDeleter(false, "", ""); d != nil || err != nil {
		t.Errorf("off: %v %v", d, err)
	}
	// off: the key is not read
	if d, err := newSyncDeleter(false, "not a key", ""); d != nil || err != nil {
		t.Errorf("off with a key: %v %v", d, err)
	}
	if _, err := newSyncDeleter(true, "", "http://syncstorage:8000"); err == nil || !strings.Contains(err.Error(), "--upgrade") {
		t.Errorf("on without a key: %v", err)
	}
	if _, err := newSyncDeleter(true, "AAAA", "http://syncstorage:8000"); err == nil || !strings.Contains(err.Error(), "SYNC_DELETE_DATA_KEY") {
		t.Errorf("on with a wrong key: %v", err)
	}
	d, err := newSyncDeleter(true, pkcs1, "http://syncstorage:8000/")
	if err != nil || d.url != "http://syncstorage:8000" {
		t.Fatalf("%v %+v", err, d)
	}
}

// verifyAssertion checks an assertion as the Sync server does (tokenserver-auth's
// FxaDeleteAssertionVerifier): RS256 with the key, typ, aud, iss, sub, exp within 120 s, a jti
func verifyAssertion(t *testing.T, pub *rsa.PublicKey, token string, now time.Time) map[string]any {
	t.Helper()
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("not a JWT: %q", token)
	}
	enc := base64.RawURLEncoding
	sig, err := enc.DecodeString(parts[2])
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if err := rsa.VerifyPKCS1v15(pub, crypto.SHA256, sum[:], sig); err != nil {
		t.Fatalf("signature: %v", err)
	}
	var header map[string]string
	var claims map[string]any
	h, _ := enc.DecodeString(parts[0])
	c, _ := enc.DecodeString(parts[1])
	if json.Unmarshal(h, &header) != nil || json.Unmarshal(c, &claims) != nil {
		t.Fatalf("header %s claims %s", h, c)
	}
	if header["alg"] != "RS256" || header["typ"] != "fxa-sync-delete+jwt" || header["kid"] != deleteDataKeyID {
		t.Errorf("header %v", header)
	}
	if claims["aud"] != deleteDataAudience || claims["iss"] != deleteDataIssuer || claims["jti"] == "" || claims["jti"] == nil {
		t.Errorf("claims %v", claims)
	}
	if exp := int64(claims["exp"].(float64)); exp <= now.Unix() || exp-now.Unix() > 120 {
		t.Errorf("exp %d, now %d", exp, now.Unix())
	}
	return claims
}

func TestDeleteAssertion(t *testing.T) {
	k, pkcs1, _ := testDeleteKey(t)
	d, err := newSyncDeleter(true, pkcs1, "http://x")
	if err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1_800_000_000, 0)
	d.now = func() time.Time { return now }
	a, _ := d.assertion("0123456789abcdef0123456789abcdef")
	b, _ := d.assertion("0123456789abcdef0123456789abcdef")
	claims := verifyAssertion(t, &k.PublicKey, a, now)
	if claims["sub"] != "0123456789abcdef0123456789abcdef" {
		t.Errorf("sub %v", claims["sub"])
	}
	if verifyAssertion(t, &k.PublicKey, b, now)["jti"] == claims["jti"] {
		t.Error("the same jti twice")
	}
}

func TestDeleteAnswers(t *testing.T) {
	k, pkcs1, _ := testDeleteKey(t)
	const uid = "0123456789abcdef0123456789abcdef"
	unknown := `{"status":"error","errors":[{"location":"url","name":"","description":"Unknown user"}]}`
	cases := []struct {
		name    string
		status  int
		body    string
		deleted bool
		err     error
		text    string
	}{
		{"deleted", 200, `{"deleted":true}`, true, nil, ""},
		{"no node", 200, `{"deleted":false}`, false, nil, ""},
		{"200 without the result", 200, `{}`, false, nil, "without its result"},
		{"no tokenserver row", 404, unknown, false, errDeleteNoUser, ""},
		// actix's 404 of a route that is not registered: the endpoint off (or before 0.25.0)
		{"no route", 404, ``, false, errDeleteOff, ""},
		{"no route, JSON", 404, `{"status":"error","errors":[{"location":"url","name":"","description":"Not Found"}]}`, false, errDeleteOff, ""},
		{"key refused", 401, `{"status":"error"}`, false, errDeleteKey, ""},
		{"node unreachable", 503, `{"status":"error"}`, false, nil, "public URL"},
		{"other", 500, "boom", false, nil, "answered 500: boom"},
	}
	for _, c := range cases {
		var seen *http.Request
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			seen = r
			w.WriteHeader(c.status)
			_, _ = w.Write([]byte(c.body))
		}))
		d, _ := newSyncDeleter(true, pkcs1, srv.URL)
		deleted, err := d.Delete(context.Background(), uid)
		srv.Close()
		if deleted != c.deleted {
			t.Errorf("%s: deleted %v", c.name, deleted)
		}
		switch {
		case c.err != nil && !errors.Is(err, c.err):
			t.Errorf("%s: %v, not %v", c.name, err, c.err)
		case c.text != "" && (err == nil || !strings.Contains(err.Error(), c.text)):
			t.Errorf("%s: %v", c.name, err)
		case c.err == nil && c.text == "" && err != nil:
			t.Errorf("%s: %v", c.name, err)
		}
		if seen == nil || seen.Method != http.MethodDelete || seen.URL.Path != "/1.0/users/"+uid+"/storage" {
			t.Fatalf("%s: request %+v", c.name, seen)
		}
		token, ok := strings.CutPrefix(seen.Header.Get("Authorization"), "Bearer ")
		if !ok {
			t.Fatalf("%s: Authorization %q", c.name, seen.Header.Get("Authorization"))
		}
		if verifyAssertion(t, &k.PublicKey, token, time.Now())["sub"] != uid {
			t.Errorf("%s: sub", c.name)
		}
	}
}

func TestDeleteProbe(t *testing.T) {
	_, pkcs1, _ := testDeleteKey(t)
	for status, want := range map[int]string{404: "", 401: "refused", 200: "should have"} {
		var path string
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			path = r.URL.Path
			w.WriteHeader(status)
			if status == 404 {
				_, _ = w.Write([]byte(`{"status":"error","errors":[{"location":"url","name":"","description":"Unknown user"}]}`))
			} else {
				_, _ = w.Write([]byte(`{"deleted":true}`))
			}
		}))
		d, _ := newSyncDeleter(true, pkcs1, srv.URL)
		detail, err := d.probe(context.Background())
		srv.Close()
		// never an account id: theirs are hex
		if path != "/1.0/users/"+deleteProbeUID+"/storage" {
			t.Errorf("%d: probed %s", status, path)
		}
		if want == "" && (err != nil || !strings.HasPrefix(detail, "on")) || want != "" && (err == nil || !strings.Contains(err.Error(), want)) {
			t.Errorf("%d: %q %v", status, detail, err)
		}
	}
	if _, err := accountID(deleteProbeUID); err == nil {
		t.Error("the probe's uid is an account id")
	}
}

// the claims the Sync server is configured with (config/sync/delete-data.sh, the chart's copy)
// are those the admin UI signs
func TestDeleteDataClaimsOfTheSyncServer(t *testing.T) {
	files := []string{"../config/sync/delete-data.sh", "../charts/firefox-sync/files/sync-delete-data.sh"}
	for _, f := range files {
		b, err := os.ReadFile(f)
		if os.IsNotExist(err) {
			t.Skip("not in the repository")
		}
		if err != nil {
			t.Fatal(err)
		}
		for _, want := range []string{
			"SYNC_TOKENSERVER__FXA_DELETE_DATA_AUDIENCE=" + deleteDataAudience + " ",
			"SYNC_TOKENSERVER__FXA_DELETE_DATA_ISSUER=" + deleteDataIssuer + " ",
			"SYNC_TOKENSERVER__FXA_OAUTH_SECONDARY_JWK__KID=" + deleteDataKeyID + " ",
		} {
			if !strings.Contains(string(b), want) {
				t.Errorf("%s: no %s", f, want)
			}
		}
	}
	// and every Sync server sources it
	for _, f := range []string{"../compose/sync.yml", "../config/quadlet/firefox-sync-syncstorage.container", "../config/quadlet/sync-postgres/firefox-sync-syncstorage.container", "../charts/firefox-sync/templates/syncstorage.yaml"} {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(string(b), ". /ffs-sync/delete-data.sh") || !strings.Contains(string(b), "SYNC_DELETE_DATA") && !strings.Contains(string(b), "deleteDataEnv") {
			t.Errorf("%s does not source /ffs-sync/delete-data.sh with SYNC_DELETE_DATA", f)
		}
	}
}

// Reset Sync data (all of it) through the Sync server, in the storage database when the
// endpoint fails; one collection in the storage database; an account deleted asks the Sync
// server first, then empties every row in the storage database
func TestResetAndDeleteThroughTheSyncServer(t *testing.T) {
	_, pkcs1, _ := testDeleteKey(t)
	var mu sync.Mutex
	var calls []string
	status := 200
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		calls = append(calls, r.Method+" "+r.URL.Path)
		code := status
		mu.Unlock()
		w.WriteHeader(code)
		_, _ = w.Write([]byte(`{"deleted":true}`))
	}))
	defer srv.Close()
	taken := func() []string {
		mu.Lock()
		defer mu.Unlock()
		c := calls
		calls = nil
		return c
	}
	storageDeletes := func(fake *fakeFxa) int {
		n := 0
		for _, q := range fake.statements() {
			if strings.HasPrefix(q, "DELETE FROM bso") {
				n++
			}
		}
		return n
	}
	row := [][]driver.Value{{int64(7), fakeUID + "@api.example.com", "aaaa", int64(0), int64(1), "https://sync.example.com", int64(0), int64(1), int64(1700000000000), int64(0)}}
	setup := func() (*fakeFxa, http.Handler, *http.Cookie, *session) {
		fake := &fakeFxa{disabled: true, users: row, answer: storageAnswers(1)}
		redis, _ := fakeRedis(t)
		app := testApp()
		app.fxa, app.sync, app.storage, app.rec = fake.db(redis), &SyncDB{db: sql.OpenDB(fake)}, &StorageDB{db: sql.OpenDB(fake)}, fakeRecorder(fake)
		app.deleter, _ = newSyncDeleter(true, pkcs1, srv.URL)
		h := app.routes()
		c, s := passwordSession(t, app, h)
		return fake, h, c, s
	}
	endpoint := "DELETE /1.0/users/" + fakeUID + "/storage"

	fake, h, c, s := setup()
	post(h, "/users/"+fakeUID+"/reset-sync", url.Values{"csrf": {s.csrf}}, c, nil)
	if got := taken(); len(got) != 1 || got[0] != endpoint || storageDeletes(fake) != 0 {
		t.Errorf("reset: %q, %d deletes in the storage database", got, storageDeletes(fake))
	}
	if !strings.Contains(s.message, "through the Sync server's data deletion endpoint (storage uid 7)") || s.failed != "" {
		t.Errorf("reset: %q / %q", s.message, s.failed)
	}
	if ev := inserted(fake, "admin"); len(ev) == 0 || !strings.Contains(ev[len(ev)-1], "through the Sync server's data deletion endpoint") {
		t.Errorf("reset: not in the event log: %q", ev)
	}

	// the endpoint fails (the Sync server cannot reach its public URL): the storage database
	mu.Lock()
	status = 503
	mu.Unlock()
	fake, h, c, s = setup()
	post(h, "/users/"+fakeUID+"/reset-sync", url.Values{"csrf": {s.csrf}}, c, nil)
	if got := taken(); len(got) != 1 || storageDeletes(fake) == 0 {
		t.Errorf("fallback: %q, %d deletes", got, storageDeletes(fake))
	}
	if !strings.Contains(s.message, "deleted in the storage database instead") || !strings.Contains(s.message, "public URL") {
		t.Errorf("fallback: %q / %q", s.message, s.failed)
	}

	// one collection: the endpoint deletes all or nothing, so not it
	mu.Lock()
	status = 200
	mu.Unlock()
	fake, h, c, s = setup()
	post(h, "/users/"+fakeUID+"/reset-sync", url.Values{"csrf": {s.csrf}, "collection": {"bookmarks"}}, c, nil)
	if got := taken(); len(got) != 0 {
		t.Errorf("one collection: %q", got)
	}

	// deleting the account: the Sync server first, then the storage database and the rows
	fake, h, c, s = setup()
	post(h, "/users/"+fakeUID+"/delete", url.Values{"csrf": {s.csrf}, "confirm_email": {fakeEmail}}, c, nil)
	if got := taken(); len(got) != 1 || got[0] != endpoint || storageDeletes(fake) == 0 {
		t.Errorf("delete: %q, %d deletes", got, storageDeletes(fake))
	}
	if !strings.HasPrefix(s.message, "Deleted alice@example.com") || s.failed != "" {
		t.Errorf("delete: %q / %q", s.message, s.failed)
	}
}
