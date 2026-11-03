package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"time"
)

// What the container runtime says of the parts of the stack, when the admin UI can read
// it: positive evidence that a part is starting (its pod not Ready yet, nothing
// restarted), or that it crashed (restarts, an exit code, CrashLoopBackOff). With the
// chart and admin.podStatus: the pods of the release, through the Kubernetes API (get and
// list pods in its namespace, nothing else). With docker compose and the Quadlets: none,
// the Docker or Podman socket would give the admin UI the host

type partState struct {
	// starting, running or crashed
	state string
	// starting: since when (its pod)
	since time.Time
	// crashed: what the runtime says ("fxa-profile-5d9 (profile): CrashLoopBackOff, 4 restarts, exit code 1")
	reason string
}

type runtimeView interface {
	// the state of the parts it sees, by the name of their check
	parts(ctx context.Context) (map[string]partState, error)
}

// the parts of the stack that are containers, by the component label of the chart's pods
var podParts = map[string]string{
	"syncstorage": "Sync server", "tokenserver-db": "Tokenserver database", "storage-db": "Storage database",
	"postgres": "Tokenserver database", "fxa-auth": "Accounts API", "fxa-content": "Accounts pages",
	"fxa-profile": "Profile server", "fxa-db": "Accounts database", "fxa-redis": "Accounts Redis", "fxa-pairing": "Pairing server",
}

// containerPart: a check of a container of the stack (not of the internet, a setting, a
// server of yours)
func containerPart(name string) bool {
	for _, p := range podParts {
		if p == name {
			return true
		}
	}
	return name == "Admin UI database"
}

// noRuntime: why the admin UI cannot see the containers, "" when it can
func (d deployment) noRuntime() string {
	switch {
	case d.kind == "kubernetes" && !switchOn("ADMIN_K8S_POD_STATUS"):
		return "admin.podStatus is off: the admin UI does not read the pods"
	case d.kind == "kubernetes":
		return ""
	case d.Quadlets():
		return "the admin UI does not see the Podman containers (their socket would give it your account)"
	}
	return "the admin UI does not see the Docker containers (the Docker socket would give it the host)"
}

// the service account's files in the admin UI's pod (the chart's projected volume)
var serviceAccountDir = "/var/run/secrets/kubernetes.io/serviceaccount"

// podView: the pods of the release, through the Kubernetes API
type podView struct {
	api, namespace, release string
	client                  *http.Client
}

// newPodView: nil without admin.podStatus, or outside a pod
func newPodView(d deployment) (*podView, error) {
	if d.kind != "kubernetes" || !switchOn("ADMIN_K8S_POD_STATUS") {
		return nil, nil
	}
	host, port := os.Getenv("KUBERNETES_SERVICE_HOST"), os.Getenv("KUBERNETES_SERVICE_PORT")
	if host == "" || port == "" {
		return nil, errors.New("ADMIN_K8S_POD_STATUS: not in a pod (no KUBERNETES_SERVICE_HOST)")
	}
	ca, err := os.ReadFile(serviceAccountDir + "/ca.crt")
	if err != nil {
		return nil, fmt.Errorf("ADMIN_K8S_POD_STATUS: the cluster's CA: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(ca) {
		return nil, errors.New("ADMIN_K8S_POD_STATUS: no certificate in " + serviceAccountDir + "/ca.crt")
	}
	namespace := d.namespace
	if namespace == "" {
		b, err := os.ReadFile(serviceAccountDir + "/namespace")
		if err != nil {
			return nil, fmt.Errorf("ADMIN_K8S_POD_STATUS: the namespace: %w", err)
		}
		namespace = strings.TrimSpace(string(b))
	}
	return &podView{api: "https://" + net.JoinHostPort(host, port), namespace: namespace, release: d.release,
		client: &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool}}}}, nil
}

// the part of a pod the states are read from
type pod struct {
	Metadata struct {
		Name              string            `json:"name"`
		Labels            map[string]string `json:"labels"`
		CreationTimestamp time.Time         `json:"creationTimestamp"`
		DeletionTimestamp *time.Time        `json:"deletionTimestamp"`
	} `json:"metadata"`
	Status struct {
		Phase      string     `json:"phase"`
		StartTime  *time.Time `json:"startTime"`
		Conditions []struct {
			Type   string `json:"type"`
			Status string `json:"status"`
		} `json:"conditions"`
		InitContainerStatuses []containerStatus `json:"initContainerStatuses"`
		ContainerStatuses     []containerStatus `json:"containerStatuses"`
	} `json:"status"`
}

type containerState struct {
	Waiting *struct {
		Reason string `json:"reason"`
	} `json:"waiting"`
	Terminated *struct {
		ExitCode int    `json:"exitCode"`
		Reason   string `json:"reason"`
	} `json:"terminated"`
}

type containerStatus struct {
	Name         string         `json:"name"`
	RestartCount int            `json:"restartCount"`
	State        containerState `json:"state"`
	LastState    containerState `json:"lastState"`
}

// the reasons of a container that does not start, whatever its restarts
var crashReasons = map[string]bool{"CrashLoopBackOff": true, "Error": true, "OOMKilled": true, "ErrImagePull": true, "ImagePullBackOff": true,
	"InvalidImageName": true, "CreateContainerConfigError": true, "CreateContainerError": true, "RunContainerError": true, "ContainerCannotRun": true}

func (v *podView) parts(ctx context.Context) (map[string]partState, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, v.api+"/api/v1/namespaces/"+url.PathEscape(v.namespace)+"/pods?labelSelector="+
		url.QueryEscape("app.kubernetes.io/instance="+v.release), nil)
	if err != nil {
		return nil, err
	}
	// (read every time: the kubelet renews the token)
	token, err := os.ReadFile(serviceAccountDir + "/token")
	if err != nil {
		return nil, fmt.Errorf("the service account's token: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(string(token)))
	res, err := v.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("listing the pods: status %d (the Role of admin.podStatus?)", res.StatusCode)
	}
	var list struct {
		Items []pod `json:"items"`
	}
	if err := json.NewDecoder(io.LimitReader(res.Body, 16<<20)).Decode(&list); err != nil {
		return nil, fmt.Errorf("listing the pods: %w", err)
	}
	return partsOfPods(list.Items), nil
}

// partsOfPods: by part, from its pods. One Ready: running. Else a crash in one (its
// reasons, its restarts, an exit code): crashed. Else starting, since its oldest pod
func partsOfPods(pods []pod) map[string]partState {
	byPart := map[string][]pod{}
	for _, p := range pods {
		if part := podParts[p.Metadata.Labels["app.kubernetes.io/component"]]; part != "" && p.Metadata.DeletionTimestamp == nil {
			byPart[part] = append(byPart[part], p)
		}
	}
	states := map[string]partState{}
	for part, pods := range byPart {
		var crashes []string
		var since time.Time
		ready := false
		for _, p := range pods {
			for _, c := range p.Status.Conditions {
				ready = ready || (c.Type == "Ready" && c.Status == "True")
			}
			if crash := podCrash(p); crash != "" {
				crashes = append(crashes, crash)
			}
			start := p.Metadata.CreationTimestamp
			if p.Status.StartTime != nil {
				start = *p.Status.StartTime
			}
			if since.IsZero() || start.Before(since) {
				since = start
			}
		}
		sort.Strings(crashes)
		switch {
		case ready:
			states[part] = partState{state: "running"}
		case len(crashes) > 0:
			states[part] = partState{state: "crashed", reason: strings.Join(crashes, "; ")}
		default:
			states[part] = partState{state: "starting", since: since}
		}
	}
	return states
}

// podCrash: what says a pod does not start, "" when nothing does
func podCrash(p pod) string {
	if p.Status.Phase == "Failed" {
		return p.Metadata.Name + ": failed"
	}
	for _, c := range append(append([]containerStatus(nil), p.Status.InitContainerStatuses...), p.Status.ContainerStatuses...) {
		var what []string
		if w := c.State.Waiting; w != nil && crashReasons[w.Reason] {
			what = append(what, w.Reason)
		}
		if t := c.State.Terminated; t != nil && t.ExitCode != 0 {
			what = append(what, fmt.Sprintf("exited with code %d", t.ExitCode))
		}
		if c.RestartCount > 0 {
			restarts := fmt.Sprintf("%d restarts", c.RestartCount)
			if c.RestartCount == 1 {
				restarts = "1 restart"
			}
			if t := c.LastState.Terminated; t != nil {
				restarts += fmt.Sprintf(", last exit code %d", t.ExitCode)
				if t.Reason != "" {
					restarts += " (" + t.Reason + ")"
				}
			}
			what = append(what, restarts)
		}
		if len(what) > 0 {
			return p.Metadata.Name + " (" + c.Name + "): " + strings.Join(what, ", ")
		}
	}
	return ""
}
