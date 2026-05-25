package middleware

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/prometheus/client_golang/prometheus/promhttp"
)

func TestMetricsMiddlewareRecordsRequest(t *testing.T) {
	h := Metrics(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))

	req := httptest.NewRequest(http.MethodGet, "/ping", nil)
	req.Pattern = "GET /ping" // ServeMux sets this during routing; simulate it here
	h.ServeHTTP(httptest.NewRecorder(), req)

	body := scrapeMetrics(t)
	if !strings.Contains(body, `route="GET /ping"`) || !strings.Contains(body, "http_requests_total") {
		t.Fatalf("expected http_requests_total for route GET /ping, got:\n%s", body)
	}
}

func TestMetricsEndpointServesPrometheusFormat(t *testing.T) {
	body := scrapeMetrics(t)
	// Default registry also exposes Go runtime + process collectors.
	if !strings.Contains(body, "go_goroutines") {
		t.Fatalf("expected default Go collector metrics, got:\n%s", body)
	}
}

func scrapeMetrics(t *testing.T) string {
	t.Helper()
	rr := httptest.NewRecorder()
	promhttp.Handler().ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("metrics endpoint returned %d", rr.Code)
	}
	body, err := io.ReadAll(rr.Body)
	if err != nil {
		t.Fatalf("read metrics body: %v", err)
	}
	return string(body)
}
