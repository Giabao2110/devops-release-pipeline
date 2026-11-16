package main

// A deliberately small Prometheus exposition implementation using only the
// standard library. It supports the two metric types this service needs:
// labelled counters and a labelled histogram. Keeping zero third-party
// dependencies makes the build reproducible and the supply chain trivial to
// audit.

import (
	"fmt"
	"io"
	"math"
	"sort"
	"strconv"
	"strings"
	"sync"
)

// DefaultBuckets are latency buckets in seconds.
var DefaultBuckets = []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5}

type Registry struct {
	mu         sync.Mutex
	counters   map[string]*counterVec
	histograms map[string]*histogramVec
	gauges     map[string]*gaugeVec
	order      []string
}

func NewRegistry() *Registry {
	return &Registry{
		counters:   map[string]*counterVec{},
		histograms: map[string]*histogramVec{},
		gauges:     map[string]*gaugeVec{},
	}
}

type counterVec struct {
	help   string
	labels []string
	values map[string]float64
}

type gaugeVec struct {
	help   string
	labels []string
	values map[string]float64
}

type histogramVec struct {
	help    string
	labels  []string
	buckets []float64
	series  map[string]*histogram
}

type histogram struct {
	counts []uint64 // cumulative counts are computed at render time
	sum    float64
	count  uint64
}

func (r *Registry) NewCounter(name, help string, labels ...string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.counters[name] = &counterVec{help: help, labels: labels, values: map[string]float64{}}
	r.order = append(r.order, name)
}

func (r *Registry) NewGauge(name, help string, labels ...string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.gauges[name] = &gaugeVec{help: help, labels: labels, values: map[string]float64{}}
	r.order = append(r.order, name)
}

func (r *Registry) NewHistogram(name, help string, buckets []float64, labels ...string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	b := append([]float64(nil), buckets...)
	sort.Float64s(b)
	r.histograms[name] = &histogramVec{help: help, labels: labels, buckets: b, series: map[string]*histogram{}}
	r.order = append(r.order, name)
}

// Inc adds 1 to a counter series identified by label values (in declared order).
func (r *Registry) Inc(name string, labelValues ...string) {
	r.Add(name, 1, labelValues...)
}

func (r *Registry) Add(name string, v float64, labelValues ...string) {
	if v < 0 {
		panic("counter cannot decrease")
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	c, ok := r.counters[name]
	if !ok {
		panic("unknown counter " + name)
	}
	c.values[key(c.labels, labelValues)] += v
}

func (r *Registry) Set(name string, v float64, labelValues ...string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	g, ok := r.gauges[name]
	if !ok {
		panic("unknown gauge " + name)
	}
	g.values[key(g.labels, labelValues)] = v
}

func (r *Registry) Observe(name string, v float64, labelValues ...string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	h, ok := r.histograms[name]
	if !ok {
		panic("unknown histogram " + name)
	}
	k := key(h.labels, labelValues)
	s, ok := h.series[k]
	if !ok {
		s = &histogram{counts: make([]uint64, len(h.buckets))}
		h.series[k] = s
	}
	for i, ub := range h.buckets {
		if v <= ub {
			s.counts[i]++
			break
		}
	}
	s.sum += v
	s.count++
}

// key encodes label values into a stable string; it panics on arity mismatch
// so programming errors surface in tests rather than as silent bad data.
func key(labels, values []string) string {
	if len(labels) != len(values) {
		panic(fmt.Sprintf("expected %d label values, got %d", len(labels), len(values)))
	}
	return strings.Join(values, "\xff")
}

func renderLabels(labels []string, k string, extra ...string) string {
	var parts []string
	if len(labels) > 0 {
		vals := strings.Split(k, "\xff")
		for i, l := range labels {
			parts = append(parts, fmt.Sprintf(`%s="%s"`, l, escape(vals[i])))
		}
	}
	for i := 0; i+1 < len(extra); i += 2 {
		parts = append(parts, fmt.Sprintf(`%s="%s"`, extra[i], extra[i+1]))
	}
	if len(parts) == 0 {
		return ""
	}
	return "{" + strings.Join(parts, ",") + "}"
}

func escape(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, "\n", `\n`)
	return strings.ReplaceAll(s, `"`, `\"`)
}

func fmtFloat(v float64) string {
	if math.IsInf(v, 1) {
		return "+Inf"
	}
	return strconv.FormatFloat(v, 'g', -1, 64)
}

func sortedKeys[V any](m map[string]V) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	return ks
}

// WriteTo renders all metrics in the Prometheus text exposition format 0.0.4.
func (r *Registry) WriteText(w io.Writer) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	var b strings.Builder
	for _, name := range r.order {
		if c, ok := r.counters[name]; ok {
			fmt.Fprintf(&b, "# HELP %s %s\n# TYPE %s counter\n", name, c.help, name)
			for _, k := range sortedKeys(c.values) {
				fmt.Fprintf(&b, "%s%s %s\n", name, renderLabels(c.labels, k), fmtFloat(c.values[k]))
			}
		}
		if g, ok := r.gauges[name]; ok {
			fmt.Fprintf(&b, "# HELP %s %s\n# TYPE %s gauge\n", name, g.help, name)
			for _, k := range sortedKeys(g.values) {
				fmt.Fprintf(&b, "%s%s %s\n", name, renderLabels(g.labels, k), fmtFloat(g.values[k]))
			}
		}
		if h, ok := r.histograms[name]; ok {
			fmt.Fprintf(&b, "# HELP %s %s\n# TYPE %s histogram\n", name, h.help, name)
			for _, k := range sortedKeys(h.series) {
				s := h.series[k]
				var cum uint64
				for i, ub := range h.buckets {
					cum += s.counts[i]
					fmt.Fprintf(&b, "%s_bucket%s %d\n", name, renderLabels(h.labels, k, "le", fmtFloat(ub)), cum)
				}
				fmt.Fprintf(&b, "%s_bucket%s %d\n", name, renderLabels(h.labels, k, "le", "+Inf"), s.count)
				fmt.Fprintf(&b, "%s_sum%s %s\n", name, renderLabels(h.labels, k), fmtFloat(s.sum))
				fmt.Fprintf(&b, "%s_count%s %d\n", name, renderLabels(h.labels, k), s.count)
			}
		}
	}
	_, err := io.WriteString(w, b.String())
	return err
}
