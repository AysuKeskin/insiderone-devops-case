package main

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestNewLoggerUsesTimestampField(t *testing.T) {
	t.Setenv("LOG_LEVEL", "info")

	var buf bytes.Buffer
	logger := newLogger(&buf)

	logger.Info("test message", slog.String("request_id", "req-1"))

	var fields map[string]any
	if err := json.Unmarshal(buf.Bytes(), &fields); err != nil {
		t.Fatalf("invalid json log: %v", err)
	}
	if _, ok := fields["timestamp"]; !ok {
		t.Fatalf("timestamp field missing from log: %v", fields)
	}
	if _, ok := fields["time"]; ok {
		t.Fatalf("unexpected time field in log: %v", fields)
	}
}

func TestRunHealthcheck(t *testing.T) {
	paths := make(chan string, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		paths <- r.URL.Path
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	if code := runHealthcheck(server.URL + "/healthz"); code != 0 {
		t.Fatalf("exit code = %d, want 0", code)
	}
	if path := <-paths; path != "/healthz" {
		t.Fatalf("path = %q, want /healthz", path)
	}
}

func TestRunHealthcheckFailsOnNonOK(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "not ready", http.StatusServiceUnavailable)
	}))
	defer server.Close()

	if code := runHealthcheck(server.URL); code == 0 {
		t.Fatal("exit code = 0, want failure")
	}
}
