package main

import (
	"encoding/json"
	"math/rand/v2"
	"net/http"
	"runtime"
	"strconv"
	"sync/atomic"
	"time"
)

// BuildInfo is injected at build time with -ldflags (see scripts/version.sh).
type BuildInfo struct {
	Version   string `json:"version"`
	Commit    string `json:"commit"`
	BuildDate string `json:"build_date"`
	GoVersion string `json:"go_version"`
}

// Config controls fault injection used by the rollback and troubleshooting
// drills. It is read from environment variables in main.go.
type Config struct {
	// FailMode "unhealthy" makes /healthz and /readyz return 503, which is how
	// the CI rollback drill simulates a bad release.
	FailMode string
	// ErrorRate is the fraction (0..1) of /api/work requests that return 500;
	// it exists to exercise the HighErrorRate alert.
	ErrorRate float64
}

type Server struct {
	info    BuildInfo
	cfg     Config
	reg     *Registry
	ready   atomic.Bool
	started time.Time
	rnd     func() float64
	mux     *http.ServeMux
}

func NewServer(info BuildInfo, cfg Config) *Server {
	if info.GoVersion == "" {
		info.GoVersion = runtime.Version()
	}
	s := &Server{info: info, cfg: cfg, reg: NewRegistry(), started: time.Now(), rnd: rand.Float64}
	s.reg.NewCounter("http_requests_total", "HTTP requests by route, method and status code.", "route", "method", "code")
	s.reg.NewHistogram("http_request_duration_seconds", "HTTP request latency by route.", DefaultBuckets, "route")
	s.reg.NewGauge("app_build_info", "Build metadata; value is always 1.", "version", "commit", "goversion")
	s.reg.NewGauge("app_start_time_seconds", "Unix time the process started.")
	s.reg.NewGauge("app_ready", "1 when the instance reports ready.")
	s.reg.Set("app_build_info", 1, info.Version, info.Commit, info.GoVersion)
	s.reg.Set("app_start_time_seconds", float64(s.started.Unix()))

	s.mux = http.NewServeMux()
	s.handle("/", s.root)
	s.handle("/healthz", s.healthz)
	s.handle("/health", s.healthz) // friendly alias
	s.handle("/readyz", s.readyz)
	s.handle("/version", s.version)
	s.handle("/api/work", s.work)
	// /metrics is not instrumented to avoid scrape traffic polluting app metrics.
	s.mux.HandleFunc("/metrics", s.metrics)
	return s
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) { s.mux.ServeHTTP(w, r) }

// SetReady flips readiness; main sets it after startup and clears it on SIGTERM
// so Kubernetes stops routing traffic before the process exits.
func (s *Server) SetReady(v bool) {
	s.ready.Store(v)
	if v {
		s.reg.Set("app_ready", 1)
	} else {
		s.reg.Set("app_ready", 0)
	}
}

type statusRecorder struct {
	http.ResponseWriter
	code int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.code = code
	r.ResponseWriter.WriteHeader(code)
}

func (s *Server) handle(route string, h http.HandlerFunc) {
	s.mux.HandleFunc(route, func(w http.ResponseWriter, r *http.Request) {
		// "/" is a catch-all in ServeMux; label unknown paths as one series to
		// keep metric cardinality bounded.
		label := route
		if route == "/" && r.URL.Path != "/" {
			label = "other"
		}
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, code: http.StatusOK}
		h(rec, r)
		s.reg.Inc("http_requests_total", label, r.Method, strconv.Itoa(rec.code))
		s.reg.Observe("http_request_duration_seconds", time.Since(start).Seconds(), label)
	})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func (s *Server) root(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{
		"service": "release-demo",
		"version": s.info.Version,
		"hint":    "try /version, /healthz, /readyz, /metrics, /api/work",
	})
}

func (s *Server) healthz(w http.ResponseWriter, _ *http.Request) {
	if s.cfg.FailMode == "unhealthy" {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "unhealthy", "reason": "FAIL_MODE=unhealthy"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) readyz(w http.ResponseWriter, _ *http.Request) {
	if s.cfg.FailMode == "unhealthy" || !s.ready.Load() {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "not ready"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func (s *Server) version(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, s.info)
}

func (s *Server) work(w http.ResponseWriter, _ *http.Request) {
	if s.cfg.ErrorRate > 0 && s.rnd() < s.cfg.ErrorRate {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "injected failure"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"result": "done"})
}

func (s *Server) metrics(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	_ = s.reg.WriteText(w)
}
