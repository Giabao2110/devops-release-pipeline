// Command release-demo is a tiny HTTP service used to demonstrate a release
// pipeline: versioned builds, health/readiness probes, Prometheus metrics and
// fault injection for rollback drills.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"
)

// Overridden at build time: -ldflags "-X main.version=1.2.3 -X main.commit=abc ..."
var (
	version   = "0.0.0-dev"
	commit    = "unknown"
	buildDate = "unknown"
)

func configFromEnv() (Config, error) {
	cfg := Config{FailMode: os.Getenv("FAIL_MODE")}
	switch cfg.FailMode {
	case "", "unhealthy", "crash":
	default:
		return cfg, fmt.Errorf("invalid FAIL_MODE %q (want unhealthy|crash)", cfg.FailMode)
	}
	if v := os.Getenv("ERROR_RATE"); v != "" {
		f, err := strconv.ParseFloat(v, 64)
		if err != nil || f < 0 || f > 1 {
			return cfg, fmt.Errorf("invalid ERROR_RATE %q (want 0..1)", v)
		}
		cfg.ErrorRate = f
	}
	return cfg, nil
}

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	if len(os.Args) > 1 && os.Args[1] == "-version" {
		fmt.Printf("%s (commit %s, built %s)\n", version, commit, buildDate)
		return
	}

	cfg, err := configFromEnv()
	if err != nil {
		log.Error("bad configuration", "err", err)
		os.Exit(2)
	}
	if cfg.FailMode == "crash" {
		// Used by the CrashLoopBackOff troubleshooting drill.
		log.Error("FAIL_MODE=crash: exiting on purpose to simulate a broken release")
		os.Exit(1)
	}

	addr := ":" + envOr("PORT", "8080")
	srv := NewServer(BuildInfo{Version: version, Commit: commit, BuildDate: buildDate}, cfg)
	httpSrv := &http.Server{Addr: addr, Handler: srv, ReadHeaderTimeout: 5 * time.Second}

	go func() {
		log.Info("listening", "addr", addr, "version", version, "commit", commit)
		if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("server failed", "err", err)
			os.Exit(1)
		}
	}()
	srv.SetReady(true)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()
	<-ctx.Done()

	// Fail readiness first so endpoints are removed, then drain connections.
	log.Info("shutdown requested, draining")
	srv.SetReady(false)
	time.Sleep(time.Duration(envInt("SHUTDOWN_DELAY_SECONDS", 2)) * time.Second)
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := httpSrv.Shutdown(shutdownCtx); err != nil {
		log.Error("shutdown error", "err", err)
	}
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func envInt(k string, def int) int {
	if v, err := strconv.Atoi(os.Getenv(k)); err == nil {
		return v
	}
	return def
}
