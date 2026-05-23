// Package main is the entrypoint for the service. It wires the HTTP
// server, middleware chain, and lifecycle (startup logging + graceful
// shutdown). All request handling logic lives in internal/.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/AysuKeskin/insiderone-devops-case/internal/handlers"
	"github.com/AysuKeskin/insiderone-devops-case/internal/middleware"
	"github.com/AysuKeskin/insiderone-devops-case/internal/version"
)

const (
	// readHeaderTimeout caps slow-header attacks (Slowloris). Body reads
	// are handled per-request by individual handlers.
	readHeaderTimeout = 5 * time.Second

	// shutdownTimeout is the drain window after SIGTERM. Long enough for
	// in-flight requests to finish, short enough that Kubernetes won't
	// SIGKILL us first (default terminationGracePeriodSeconds is 30).
	shutdownTimeout = 15 * time.Second
)

func main() {
	logger := newLogger()
	slog.SetDefault(logger)

	addr := ":" + getenv("PORT", "8080")
	var ready atomic.Bool
	ready.Store(true)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /ping", handlers.Ping)
	mux.HandleFunc("GET /healthz", handlers.Healthz)
	mux.Handle("GET /readyz", handlers.Readyz(&ready))
	mux.HandleFunc("GET /version", handlers.Version)

	// Order matters: RequestID must be outermost so AccessLog can pull
	// the id from context when emitting the request log line.
	handler := middleware.RequestID(middleware.AccessLog(logger)(mux))

	srv := &http.Server{
		Addr:              addr,
		Handler:           handler,
		ReadHeaderTimeout: readHeaderTimeout,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go func() {
		logger.Info("server started",
			"addr", addr,
			"version", version.Version,
			"commit", version.Commit,
		)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("listen failed", "err", err)
			os.Exit(1)
		}
	}()

	<-ctx.Done()
	logger.Info("shutdown signal received")
	ready.Store(false)

	// Give in-flight requests time to drain; readiness probe failures
	// will steer new traffic away before this window closes.
	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()

	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error("graceful shutdown failed", "err", err)
		os.Exit(1)
	}
	logger.Info("server stopped")
}

func newLogger() *slog.Logger {
	var level slog.Level
	_ = level.UnmarshalText([]byte(strings.ToUpper(getenv("LOG_LEVEL", "INFO"))))
	return slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: level}))
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
