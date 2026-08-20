package middleware

import (
	"net/http"
	"time"

	"github.com/AysuKeskin/kube-pulse/internal/metrics"
)

// Metrics records request count and latency for each request. The route label
// comes from r.Pattern (set by ServeMux during routing), which keeps label
// cardinality bounded to the known routes instead of the raw URL. The /metrics
// scrape endpoint is excluded so Prometheus polling doesn't inflate RPS panels.
func Metrics(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)

		if r.URL.Path == "/metrics" {
			return // pometheus polling, not user traffic
		}

		route := r.Pattern // example: GET user/:id
		if route == "" {
			route = "unmatched"
		}
		metrics.Observe(r.Method, route, rec.status, time.Since(start))
	})
}
