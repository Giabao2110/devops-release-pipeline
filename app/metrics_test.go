package main

import (
	"strings"
	"testing"
)

func TestHistogramBucketsAreCumulative(t *testing.T) {
	r := NewRegistry()
	r.NewHistogram("lat", "latency", []float64{0.1, 1}, "route")
	r.Observe("lat", 0.05, "/a")
	r.Observe("lat", 0.5, "/a")
	r.Observe("lat", 5, "/a")

	var b strings.Builder
	if err := r.WriteText(&b); err != nil {
		t.Fatal(err)
	}
	out := b.String()
	for _, want := range []string{
		`lat_bucket{route="/a",le="0.1"} 1`,
		`lat_bucket{route="/a",le="1"} 2`,
		`lat_bucket{route="/a",le="+Inf"} 3`,
		`lat_count{route="/a"} 3`,
		`lat_sum{route="/a"} 5.55`,
		"# TYPE lat histogram",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
}

func TestLabelEscaping(t *testing.T) {
	r := NewRegistry()
	r.NewCounter("c", "help", "path")
	r.Inc("c", `a"b\c`)
	var b strings.Builder
	_ = r.WriteText(&b)
	if !strings.Contains(b.String(), `c{path="a\"b\\c"} 1`) {
		t.Fatalf("bad escaping:\n%s", b.String())
	}
}

func TestLabelArityPanics(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("expected panic on label arity mismatch")
		}
	}()
	r := NewRegistry()
	r.NewCounter("c", "help", "a", "b")
	r.Inc("c", "only-one")
}
