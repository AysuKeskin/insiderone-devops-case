// Package metrics defines the service's Prometheus collectors and a helper to
// record one finished request. Registration uses the default registry, which
// already exports Go runtime and process collectors through promhttp.Handler().
package metrics // defines metrics and helper

import (
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

var (
	requestsTotal = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total HTTP requests by method, route, and status code.",
		},
		// route is the matched ServeMux pattern, never the raw URL, so label
		// cardinality stays bounded by the number of routes.
		[]string{"method", "route", "status"},
	)

	requestDuration = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "http_request_duration _seconds",
			Help:    "HTTP request latency in seconds by method and route.",
			Buckets: prometheus.DefBuckets,
		},
		[]string{"method", "route"},
	)
)

// Observe records one finished request: bumps the counter and adds the latency
// to the histogram.
func Observe(method, route string, status int, dur time.Duration) {
	requestsTotal.WithLabelValues(method, route, strconv.Itoa(status)).Inc()
	requestDuration.WithLabelValues(method, route).Observe(dur.Seconds())
}
