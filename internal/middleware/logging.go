package middleware

import (
	"log/slog"
	"net/http"
	"time"
)

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) { // should be pointer since we want to change the status field of the struct
	r.status = code
	r.ResponseWriter.WriteHeader(code) // codeu yazar ama doğrudan vermez
}

func AccessLog(logger *slog.Logger) func(http.Handler) http.Handler { // returns the handler
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
			next.ServeHTTP(rec, r)

			// /metrics and /healthz are noisy on probes; demote to DEBUG.
			level := slog.LevelInfo
			if r.URL.Path == "/healthz" || r.URL.Path == "/readyz" || r.URL.Path == "/metrics" {
				level = slog.LevelDebug
			}

			logger.LogAttrs(r.Context(), level, "http request", // loger a bilgi verir ve zorunlu
				slog.String("request_id", FromContext(r.Context())),
				slog.String("method", r.Method),
				slog.String("path", r.URL.Path),
				slog.Int("status", rec.status),
				slog.Int64("duration_ms", time.Since(start).Milliseconds()),
				slog.String("remote", r.RemoteAddr), // procy client ip:port
			)
		})
	}
}

// r -> http request, w -> interface used to write response
