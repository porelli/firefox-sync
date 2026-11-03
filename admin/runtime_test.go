package main

import (
	"context"
	"encoding/json"
	"encoding/pem"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// a pod of the chart as the Kubernetes API lists it
func testPod(t *testing.T, component, name, status string) pod {
	t.Helper()
	var p pod
	if err := json.Unmarshal([]byte(`{"metadata": {"name": "`+name+`", "creationTimestamp": "2026-11-03T18:00:00Z",
		"labels": {"app.kubernetes.io/instance": "ffs", "app.kubernetes.io/component": "`+component+`"}}, "status": `+status+`}`), &p); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestPartsOfPods(t *testing.T) {
	ready := `{"phase": "Running", "startTime": "2026-11-03T18:00:05Z", "conditions": [{"type": "Ready", "status": "True"}],
		"containerStatuses": [{"name": "syncstorage", "restartCount": 2, "state": {"running": {}}, "lastState": {"terminated": {"exitCode": 1}}}]}`
	starting := `{"phase": "Running", "startTime": "2026-11-03T18:01:00Z", "conditions": [{"type": "Ready", "status": "False"}],
		"initContainerStatuses": [{"name": "wait-db", "restartCount": 0, "state": {"terminated": {"exitCode": 0}}}],
		"containerStatuses": [{"name": "auth", "restartCount": 0, "state": {"running": {}}}]}`
	pending := `{"phase": "Pending", "initContainerStatuses": [{"name": "wait-auth", "restartCount": 0, "state": {"running": {}}}]}`
	crashLoop := `{"phase": "Running", "startTime": "2026-11-03T18:00:00Z", "conditions": [{"type": "Ready", "status": "False"}],
		"containerStatuses": [{"name": "profile", "restartCount": 4, "state": {"waiting": {"reason": "CrashLoopBackOff"}},
		"lastState": {"terminated": {"exitCode": 1, "reason": "Error"}}}]}`
	restarted := `{"phase": "Running", "conditions": [{"type": "Ready", "status": "False"}],
		"containerStatuses": [{"name": "content", "restartCount": 1, "state": {"running": {}}, "lastState": {"terminated": {"exitCode": 137, "reason": "OOMKilled"}}}]}`
	initCrash := `{"phase": "Pending", "initContainerStatuses": [{"name": "migrations", "restartCount": 3, "state": {"waiting": {"reason": "CrashLoopBackOff"}},
		"lastState": {"terminated": {"exitCode": 1, "reason": "Error"}}}]}`
	exited := `{"phase": "Failed"}`
	badImage := `{"phase": "Pending", "containerStatuses": [{"name": "redis", "restartCount": 0, "state": {"waiting": {"reason": "ImagePullBackOff"}}}]}`
	gone := testPod(t, "fxa-db", "fxa-db-0", exited)
	gone.Metadata.DeletionTimestamp = &time.Time{}
	parts := partsOfPods([]pod{
		testPod(t, "syncstorage", "syncstorage-a", ready),
		// one Ready of two: running, whatever the other
		testPod(t, "fxa-auth", "fxa-auth-a", starting), testPod(t, "fxa-auth", "fxa-auth-b", ready),
		testPod(t, "fxa-content", "fxa-content-a", restarted),
		testPod(t, "fxa-profile", "fxa-profile-a", crashLoop),
		testPod(t, "fxa-pairing", "fxa-pairing-a", initCrash),
		testPod(t, "tokenserver-db", "tokenserver-db-0", starting),
		testPod(t, "storage-db", "storage-db-0", pending),
		testPod(t, "postgres", "postgres-0", exited),
		testPod(t, "fxa-redis", "fxa-redis-a", badImage),
		// being deleted: not counted; not a part (the admin UI, the backups): not either
		gone, testPod(t, "admin", "admin-a", starting), testPod(t, "backup", "backup-1", exited),
	})
	want := map[string]partState{
		"Sync server":          {state: "running"},
		"Accounts API":         {state: "running"},
		"Accounts pages":       {state: "crashed", reason: "fxa-content-a (content): 1 restart, last exit code 137 (OOMKilled)"},
		"Profile server":       {state: "crashed", reason: "fxa-profile-a (profile): CrashLoopBackOff, 4 restarts, last exit code 1 (Error)"},
		"Pairing server":       {state: "crashed", reason: "fxa-pairing-a (migrations): CrashLoopBackOff, 3 restarts, last exit code 1 (Error)"},
		"Tokenserver database": {state: "crashed", reason: "postgres-0: failed"},
		"Storage database":     {state: "starting", since: time.Date(2026, 11, 3, 18, 0, 0, 0, time.UTC)},
		"Accounts Redis":       {state: "crashed", reason: "fxa-redis-a (redis): ImagePullBackOff"},
	}
	for part, w := range want {
		if got := parts[part]; got.state != w.state || got.reason != w.reason || !got.since.Equal(w.since) {
			t.Errorf("%s: %+v, want %+v", part, got, w)
		}
	}
	if _, ok := parts["Accounts database"]; ok || len(parts) != len(want) {
		t.Errorf("parts %+v", parts)
	}
	// the starting tokenserver database and the failed postgres share a part: the crash wins
	if p := partsOfPods([]pod{testPod(t, "tokenserver-db", "t-0", starting)}); p["Tokenserver database"].state != "starting" ||
		!p["Tokenserver database"].since.Equal(time.Date(2026, 11, 3, 18, 1, 0, 0, time.UTC)) {
		t.Errorf("starting since its start: %+v", p)
	}
}

func TestPodView(t *testing.T) {
	var asked *http.Request
	status := http.StatusOK
	api := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		asked = r
		if status != http.StatusOK {
			http.Error(w, "forbidden", status)
			return
		}
		w.Write([]byte(`{"kind": "PodList", "items": [{"metadata": {"name": "syncstorage-a", "labels": {"app.kubernetes.io/component": "syncstorage"}},
			"status": {"phase": "Running", "conditions": [{"type": "Ready", "status": "True"}]}}]}`))
	}))
	defer api.Close()
	dir := t.TempDir()
	defer func(d string) { serviceAccountDir = d }(serviceAccountDir)
	serviceAccountDir = dir
	ca := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: api.Certificate().Raw})
	for name, content := range map[string]string{"token": "the-token\n", "ca.crt": string(ca), "namespace": "sync\n"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	host, port, _ := net.SplitHostPort(strings.TrimPrefix(api.URL, "https://"))
	t.Setenv("KUBERNETES_SERVICE_HOST", host)
	t.Setenv("KUBERNETES_SERVICE_PORT", port)
	d := deployment{kind: "kubernetes", release: "ffs"}

	// off without ADMIN_K8S_POD_STATUS
	if v, err := newPodView(d); v != nil || err != nil {
		t.Fatalf("off: %v %v", v, err)
	}
	t.Setenv("ADMIN_K8S_POD_STATUS", "true")
	v, err := newPodView(d)
	if err != nil || v == nil || v.namespace != "sync" {
		t.Fatalf("view %+v %v", v, err)
	}
	parts, err := v.parts(context.Background())
	if err != nil || parts["Sync server"].state != "running" {
		t.Fatalf("parts %+v %v", parts, err)
	}
	if asked.URL.Path != "/api/v1/namespaces/sync/pods" || asked.URL.Query().Get("labelSelector") != "app.kubernetes.io/instance=ffs" ||
		asked.Header.Get("Authorization") != "Bearer the-token" {
		t.Errorf("asked %s %s", asked.URL, asked.Header.Get("Authorization"))
	}
	// the namespace of the chart first
	if v, _ := newPodView(deployment{kind: "kubernetes", release: "ffs", namespace: "other"}); v.namespace != "other" {
		t.Errorf("namespace %q", v.namespace)
	}
	// without the Role: said
	status = http.StatusForbidden
	if _, err := v.parts(context.Background()); err == nil || !strings.Contains(err.Error(), "status 403 (the Role of admin.podStatus?)") {
		t.Errorf("forbidden: %v", err)
	}
	// outside a pod
	t.Setenv("KUBERNETES_SERVICE_HOST", "")
	if _, err := newPodView(d); err == nil || !strings.Contains(err.Error(), "not in a pod") {
		t.Errorf("outside a pod: %v", err)
	}
}
