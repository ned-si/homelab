// Package metrics defines the Prometheus metrics of both roles and serves
// them with the health endpoints on the internal metrics port. No label
// value is ever taken from a request, so a scanner cannot grow the series.
package metrics

import (
	"net/http"
	"runtime"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

const namespace = "homelab_dashboard"

// Label values the collector uses.
var (
	Blocks      = []string{"availability", "certificates", "cluster", "project"}
	Sources     = []string{"prometheus", "github", "validation"}
	PushResults = []string{"accepted", "rejected", "error"}
)

// LiveBlocks are the snapshot blocks with an as_of, whose age the web role
// exports.
var LiveBlocks = []string{"availability", "certificates", "cluster", "project"}

// RejectReasons are the reasons the web role refuses a push for.
var RejectReasons = []string{"size", "content_type", "signature", "replay", "schema", "allowlist"}

// NewRegistry returns a registry with the Go and process collectors and
// build_info for role at version.
func NewRegistry(role, version string) *prometheus.Registry {
	reg := prometheus.NewRegistry()
	reg.MustRegister(
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	)
	info := prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Namespace: namespace,
		Name:      "build_info",
		Help:      "Always 1: the commit, Go version and role of this process.",
	}, []string{"version", "goversion", "role"})
	info.WithLabelValues(version, runtime.Version(), role).Set(1)
	reg.MustRegister(info)
	return reg
}

// Collector holds the collector role's metrics.
type Collector struct {
	Runs               *prometheus.CounterVec
	Errors             *prometheus.CounterVec
	Duration           *prometheus.HistogramVec
	Pushes             *prometheus.CounterVec
	RateLimitRemaining prometheus.Gauge
	TokenValid         prometheus.Gauge
}

// NewCollector registers the collector role's metrics on reg.
func NewCollector(reg prometheus.Registerer) *Collector {
	m := &Collector{
		Runs: prometheus.NewCounterVec(prometheus.CounterOpts{
			Namespace: namespace, Name: "collect_runs_total",
			Help: "Block refreshes by block and result.",
		}, []string{"block", "result"}),
		Errors: prometheus.NewCounterVec(prometheus.CounterOpts{
			Namespace: namespace, Name: "collect_errors_total",
			Help: "Collection errors by source.",
		}, []string{"source"}),
		Duration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Namespace: namespace, Name: "collect_duration_seconds",
			Help:    "Duration of a block refresh.",
			Buckets: []float64{0.1, 0.25, 0.5, 1, 2.5, 5, 10, 25, 50},
		}, []string{"block"}),
		Pushes: prometheus.NewCounterVec(prometheus.CounterOpts{
			Namespace: namespace, Name: "push_total",
			Help: "Snapshot pushes to web pods by result.",
		}, []string{"result"}),
		RateLimitRemaining: prometheus.NewGauge(prometheus.GaugeOpts{
			Namespace: namespace, Name: "github_ratelimit_remaining",
			Help: "X-RateLimit-Remaining of the last GitHub answer.",
		}),
		TokenValid: prometheus.NewGauge(prometheus.GaugeOpts{
			Namespace: namespace, Name: "github_token_valid",
			Help: "1 when the last authenticated GitHub call succeeded; 0 after a 401 or without a token.",
		}),
	}
	reg.MustRegister(m.Runs, m.Errors, m.Duration, m.Pushes, m.RateLimitRemaining, m.TokenValid)
	for _, b := range Blocks {
		for _, r := range []string{"success", "failure"} {
			m.Runs.WithLabelValues(b, r)
		}
		m.Duration.WithLabelValues(b)
	}
	for _, s := range Sources {
		m.Errors.WithLabelValues(s)
	}
	for _, r := range PushResults {
		m.Pushes.WithLabelValues(r)
	}
	return m
}

// Web holds the web role's metrics.
type Web struct {
	PushRejected *prometheus.CounterVec
	Requests     *prometheus.CounterVec
	Duration     prometheus.Histogram
}

// NewWeb registers the web role's metrics on reg. snapshotAge and blockAge
// (for each of LiveBlocks) are computed at scrape time, in seconds.
func NewWeb(reg prometheus.Registerer, snapshotAge func() float64, blockAge func(block string) float64) *Web {
	m := &Web{
		PushRejected: prometheus.NewCounterVec(prometheus.CounterOpts{
			Namespace: namespace, Name: "push_rejected_total",
			Help: "Refused snapshot pushes by reason.",
		}, []string{"reason"}),
		Requests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Namespace: namespace, Name: "http_requests_total",
			Help: "Public requests by status code and method (GET, HEAD, other).",
		}, []string{"code", "method"}),
		Duration: prometheus.NewHistogram(prometheus.HistogramOpts{
			Namespace: namespace, Name: "http_request_duration_seconds",
			Help:    "Duration of public requests.",
			Buckets: []float64{0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1},
		}),
	}
	age := prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Namespace: namespace, Name: "snapshot_age_seconds",
		Help: "Now minus generated_at of the snapshot served; without one, now minus the process start.",
	}, snapshotAge)
	reg.MustRegister(m.PushRejected, m.Requests, m.Duration, age)
	for _, b := range LiveBlocks {
		reg.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{
			Namespace: namespace, Name: "block_age_seconds",
			Help:        "Now minus as_of of the block in the snapshot served; without one, now minus the process start.",
			ConstLabels: prometheus.Labels{"block": b},
		}, func() float64 { return blockAge(b) }))
	}
	for _, r := range RejectReasons {
		m.PushRejected.WithLabelValues(r)
	}
	return m
}

// Method returns the method label value: GET, HEAD or other.
func Method(m string) string {
	if m == http.MethodGet || m == http.MethodHead {
		return m
	}
	return "other"
}

// Handler serves /metrics, /healthz (the process runs) and /readyz (ready
// reports true) for the metrics port.
func Handler(reg *prometheus.Registry, ready func() bool) http.Handler {
	mux := http.NewServeMux()
	mux.Handle("GET /metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{}))
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, _ *http.Request) {
		if !ready() {
			http.Error(w, "not ready", http.StatusServiceUnavailable)
			return
		}
		_, _ = w.Write([]byte("ok\n"))
	})
	return mux
}
