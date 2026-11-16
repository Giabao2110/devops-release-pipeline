package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func newTestServer(cfg Config) *Server {
	s := NewServer(BuildInfo{Version: "1.2.3", Commit: "abc1234", BuildDate: "2026-11-16T00:00:00Z", GoVersion: "go-test"}, cfg)
	s.SetReady(true)
	return s
}

func get(t *testing.T, h http.Handler, path string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	return rec
}

func TestHealthAndReadiness(t *testing.T) {
	tests := []struct {
		name     string
		cfg      Config
		ready    bool
		path     string
		wantCode int
	}{
		{"healthy liveness", Config{}, true, "/healthz", 200},
		{"healthy readiness", Config{}, true, "/readyz", 200},
		{"not ready yet", Config{}, false, "/readyz", 503},
		{"liveness ignores readiness", Config{}, false, "/healthz", 200},
		{"bad release liveness", Config{FailMode: "unhealthy"}, true, "/healthz", 503},
		{"bad release readiness", Config{FailMode: "unhealthy"}, true, "/readyz", 503},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s := newTestServer(tc.cfg)
			s.SetReady(tc.ready)
			if got := get(t, s, tc.path).Code; got != tc.wantCode {
				t.Fatalf("GET %s = %d, want %d", tc.path, got, tc.wantCode)
			}
		})
	}
}

func TestVersionEndpoint(t *testing.T) {
	rec := get(t, newTestServer(Config{}), "/version")
	if rec.Code != 200 {
		t.Fatalf("code = %d", rec.Code)
	}
	var info BuildInfo
	if err := json.Unmarshal(rec.Body.Bytes(), &info); err != nil {
		t.Fatal(err)
	}
	if info.Version != "1.2.3" || info.Commit != "abc1234" {
		t.Fatalf("unexpected build info %+v", info)
	}
}

func TestUnknownPathIs404WithBoundedLabel(t *testing.T) {
	s := newTestServer(Config{})
	if got := get(t, s, "/does-not-exist").Code; got != 404 {
		t.Fatalf("code = %d, want 404", got)
	}
	body := get(t, s, "/metrics").Body.String()
	if !strings.Contains(body, `http_requests_total{route="other",method="GET",code="404"} 1`) {
		t.Fatalf("unknown paths should be counted under route=other:\n%s", body)
	}
}

func TestErrorInjection(t *testing.T) {
	s := newTestServer(Config{ErrorRate: 0.5})
	vals := []float64{0.1, 0.9} // first request fails, second succeeds
	i := 0
	s.rnd = func() float64 { v := vals[i%len(vals)]; i++; return v }
	if got := get(t, s, "/api/work").Code; got != 500 {
		t.Fatalf("first call = %d, want 500", got)
	}
	if got := get(t, s, "/api/work").Code; got != 200 {
		t.Fatalf("second call = %d, want 200", got)
	}
	body := get(t, s, "/metrics").Body.String()
	for _, want := range []string{
		`http_requests_total{route="/api/work",method="GET",code="500"} 1`,
		`http_requests_total{route="/api/work",method="GET",code="200"} 1`,
		`app_build_info{version="1.2.3",commit="abc1234",goversion="go-test"} 1`,
		`http_request_duration_seconds_count{route="/api/work"} 2`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("metrics missing %q", want)
		}
	}
}

func TestConfigFromEnv(t *testing.T) {
	t.Setenv("FAIL_MODE", "bogus")
	if _, err := configFromEnv(); err == nil {
		t.Fatal("expected error for invalid FAIL_MODE")
	}
	t.Setenv("FAIL_MODE", "")
	t.Setenv("ERROR_RATE", "1.5")
	if _, err := configFromEnv(); err == nil {
		t.Fatal("expected error for ERROR_RATE > 1")
	}
	t.Setenv("ERROR_RATE", "0.2")
	cfg, err := configFromEnv()
	if err != nil || cfg.ErrorRate != 0.2 {
		t.Fatalf("cfg=%+v err=%v", cfg, err)
	}
}
