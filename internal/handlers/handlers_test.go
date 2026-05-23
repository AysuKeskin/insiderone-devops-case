package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"github.com/AysuKeskin/insiderone-devops-case/internal/version"
)

func TestPing(t *testing.T) {
	rr := httptest.NewRecorder()
	Ping(rr, httptest.NewRequest(http.MethodGet, "/ping", nil))

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rr.Code)
	}
	if got := rr.Body.String(); got != "pong\n" {
		t.Fatalf("body = %q, want %q", got, "pong\n")
	}
}

func TestReadyz(t *testing.T) {
	var ready atomic.Bool
	h := Readyz(&ready)

	ready.Store(true)
	rr := httptest.NewRecorder()
	h(rr, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("ready=true status = %d, want 200", rr.Code)
	}

	ready.Store(false)
	rr = httptest.NewRecorder()
	h(rr, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("ready=false status = %d, want 503", rr.Code)
	}
}

func TestHealthz(t *testing.T) {
	rr := httptest.NewRecorder()
	Healthz(rr, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rr.Code)
	}
}

func TestVersion(t *testing.T) {
	// Pin the package vars so the test asserts on a known payload
	// regardless of how the test binary was linked.
	version.Version, version.Commit, version.BuiltAt = "v9.9.9", "deadbeef", "2026-01-01T00:00:00Z"

	rr := httptest.NewRecorder()
	Version(rr, httptest.NewRequest(http.MethodGet, "/version", nil))

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rr.Code)
	}
	if ct := rr.Header().Get("Content-Type"); ct != "application/json" {
		t.Fatalf("content-type = %q, want application/json", ct)
	}

	var body map[string]string
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatalf("invalid json: %v", err)
	}
	if body["version"] != "v9.9.9" || body["commit"] != "deadbeef" || body["built_at"] != "2026-01-01T00:00:00Z" {
		t.Fatalf("unexpected body: %v", body)
	}
}
