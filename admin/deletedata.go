package main

// The Sync server's data deletion endpoint (syncstorage-rs 0.25.0 on): DELETE
// /1.0/users/<account id>/storage empties what the account stores on its current node and
// keeps its tokenserver row, as Reset Sync data does. It takes a short-lived assertion
// signed with a key the Sync server trusts; Mozilla's accounts sign none for a server of
// yours, so the admin UI is the caller: with SYNC_DELETE_DATA=true it signs them with
// SYNC_DELETE_DATA_KEY, the key prepare_environment.sh (or the chart) generated for this
// install, whose public half the Sync server is given as its secondary JWK (compose/sync.yml).
// See docs/admin/accounts.md#sync-data-through-the-sync-server.

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// The claims the Sync server checks: the same in compose/sync.yml, the Quadlet of the Sync
// server and the chart (deletedata_test.go compares them)
const (
	deleteDataAudience = "urn:firefox-sync:sync-data-delete"
	deleteDataIssuer   = "urn:firefox-sync:admin-ui"
	deleteDataKeyID    = "firefox-sync-delete-data"
	// the typ of the assertions (upstream's tools/fxa_delete/make_delete_assertion.py)
	deleteAssertionType = "fxa-sync-delete+jwt"
	// the Sync server takes none valid for more than 120 seconds
	deleteAssertionTTL = 60 * time.Second
	// an account id no account has (theirs are 32 hex digits): the health check's
	deleteProbeUID = "ffs-health-probe"
	// its row on the health page
	deleteCheckName = "Sync data deletion"
)

var (
	// 404 with the tokenserver's "Unknown user": the endpoint is on, took the assertion,
	// and has no row for the account
	errDeleteNoUser = errors.New("the Sync server has no tokenserver row for this account")
	// 404 without it: no such route, the endpoint is off there
	errDeleteOff = errors.New("the Sync server's data deletion endpoint is off: an image before syncstorage-rs 0.25.0, or SYNC_DELETE_DATA_KEY not valid there (its log says)")
	errDeleteKey = errors.New("the Sync server refused the admin UI's assertion: it does not have the public half of SYNC_DELETE_DATA_KEY (restart it after a change of the key)")
)

// syncDeleter signs the assertions and calls the endpoint; nil when SYNC_DELETE_DATA is off
type syncDeleter struct {
	key    *rsa.PrivateKey
	url    string // SYNCSTORAGE_URL
	client *http.Client
	now    func() time.Time
}

// newSyncDeleter: SYNC_DELETE_DATA, SYNC_DELETE_DATA_KEY. Off (nil) without the switch; the
// switch without a key, or a key that is not valid, stops the admin UI
func newSyncDeleter(on bool, key, syncURL string) (*syncDeleter, error) {
	if !on {
		return nil, nil
	}
	if strings.TrimSpace(key) == "" {
		return nil, errors.New("SYNC_DELETE_DATA is true but SYNC_DELETE_DATA_KEY is empty: ./prepare_environment.sh --upgrade generates it (the chart: sync.deleteData)")
	}
	k, err := parseDeleteKey(key)
	if err != nil {
		return nil, fmt.Errorf("SYNC_DELETE_DATA_KEY: %w", err)
	}
	return &syncDeleter{key: k, url: strings.TrimSuffix(syncURL, "/"), client: &http.Client{Timeout: 90 * time.Second}, now: time.Now}, nil
}

// parseDeleteKey: an RSA private key in PEM (PKCS #1 or #8), as is or in base64 (.env holds
// one line)
func parseDeleteKey(value string) (*rsa.PrivateKey, error) {
	value = strings.TrimSpace(value)
	raw := []byte(value)
	if !strings.HasPrefix(value, "-----BEGIN") {
		var err error
		if raw, err = base64.StdEncoding.DecodeString(value); err != nil {
			return nil, errors.New("neither a PEM key nor one in base64")
		}
	}
	block, _ := pem.Decode(raw)
	if block == nil {
		return nil, errors.New("no PEM key in it")
	}
	if k, err := x509.ParsePKCS1PrivateKey(block.Bytes); err == nil {
		return checkDeleteKey(k)
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, errors.New("not an RSA private key")
	}
	k, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		return nil, errors.New("not an RSA key: the Sync server checks RS256 only")
	}
	return checkDeleteKey(k)
}

func checkDeleteKey(k *rsa.PrivateKey) (*rsa.PrivateKey, error) {
	if k.N.BitLen() < 2048 {
		return nil, fmt.Errorf("an RSA key of %d bits: 2048 or more", k.N.BitLen())
	}
	return k, nil
}

// assertion: the signed JWT that lets the Sync server delete the data of this account id,
// valid for a minute
func (d *syncDeleter) assertion(uid string) (string, error) {
	jti := make([]byte, 16)
	if _, err := rand.Read(jti); err != nil {
		return "", err
	}
	now := d.now()
	header, _ := json.Marshal(map[string]string{"alg": "RS256", "typ": deleteAssertionType, "kid": deleteDataKeyID})
	claims, _ := json.Marshal(map[string]any{"sub": uid, "iss": deleteDataIssuer, "aud": deleteDataAudience,
		"iat": now.Unix(), "exp": now.Add(deleteAssertionTTL).Unix(), "jti": hex.EncodeToString(jti)})
	enc := base64.RawURLEncoding
	signed := enc.EncodeToString(header) + "." + enc.EncodeToString(claims)
	sum := sha256.Sum256([]byte(signed))
	sig, err := rsa.SignPKCS1v15(rand.Reader, d.key, crypto.SHA256, sum[:])
	if err != nil {
		return "", err
	}
	return signed + "." + enc.EncodeToString(sig), nil
}

// Delete asks the Sync server to delete the data of the account id's current tokenserver row:
// whether a node had some (false: no node assigned, nothing there)
func (d *syncDeleter) Delete(ctx context.Context, uid string) (bool, error) {
	token, err := d.assertion(uid)
	if err != nil {
		return false, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, d.url+"/1.0/users/"+url.PathEscape(uid)+"/storage", nil)
	if err != nil {
		return false, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	res, err := d.client.Do(req)
	if err != nil {
		return false, fmt.Errorf("the Sync server's data deletion endpoint: %w", err)
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(res.Body, 1<<16))
	return deleteAnswer(res.StatusCode, body)
}

// deleteAnswer: what the Sync server's answer means
func deleteAnswer(status int, body []byte) (bool, error) {
	switch status {
	case http.StatusOK:
		var r struct {
			Deleted *bool `json:"deleted"`
		}
		if err := json.Unmarshal(body, &r); err != nil || r.Deleted == nil {
			return false, fmt.Errorf("the Sync server's data deletion endpoint answered 200 without its result: %s", oneLine(string(body), 200))
		}
		return *r.Deleted, nil
	case http.StatusNotFound:
		var e struct {
			Errors []struct {
				Description string `json:"description"`
			} `json:"errors"`
		}
		if json.Unmarshal(body, &e) == nil && len(e.Errors) > 0 && e.Errors[0].Description == "Unknown user" {
			return false, errDeleteNoUser
		}
		return false, errDeleteOff
	case http.StatusUnauthorized:
		return false, errDeleteKey
	case http.StatusServiceUnavailable:
		// the tokenserver asks the node (SYNC_PUBLIC_URL) to delete, over the network
		return false, errors.New("the Sync server could not reach its own public URL (the node, SYNC_PUBLIC_URL) to delete the data: it must resolve and trust it from inside its container")
	}
	return false, fmt.Errorf("the Sync server's data deletion endpoint answered %d: %s", status, oneLine(string(bytes.TrimSpace(body)), 200))
}

// probe, the health check: an assertion for an account id no account has. The Sync server
// takes it (404 Unknown user) when it is on with this key; nothing is deleted
func (d *syncDeleter) probe(ctx context.Context) (string, error) {
	_, err := d.Delete(ctx, deleteProbeUID)
	switch {
	case errors.Is(err, errDeleteNoUser):
		return "on: the Sync server takes the admin UI's assertions", nil
	case err == nil:
		return "", errors.New("the Sync server has a tokenserver row for " + deleteProbeUID + ", which no account should have")
	}
	return "", err
}
