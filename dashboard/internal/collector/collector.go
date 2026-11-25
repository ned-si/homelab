// Package collector is the backend role: it reads Prometheus and the GitHub
// API, builds the snapshot, validates and signs it, and pushes it to every
// web pod (.kiro/specs/homelab-dashboard/design.md, "Collector").
package collector

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"sync/atomic"
	"time"

	"github.com/ned-si/homelab/dashboard/internal/metrics"
	"github.com/ned-si/homelab/dashboard/internal/snapshot"
)

// HTTPTimeout bounds each HTTP call of the collector.
const HTTPTimeout = 10 * time.Second

const (
	cycleEvery    = 60 * time.Second
	cycleDeadline = 50 * time.Second
	// projectDeadline bounds a project refresh, which pages through every
	// pull request merged in 30 days and does not fit in a cycle.
	projectDeadline = 3 * time.Minute
	// The anonymous GitHub quota is 60 calls an hour, shared by the WAN
	// address; a refresh is about 5 calls.
	projectWithToken    = 15 * time.Minute
	projectWithoutToken = 60 * time.Minute
	rateLimitMargin     = 30 * time.Second
	// doraKeep is how long the figures that need the token outlive the
	// last refresh with it: the project block's staleness threshold.
	doraKeep = time.Hour
)

// Collector holds the last good value of each block between cycles.
type Collector struct {
	Prometheus Querier
	GitHub     *GitHub
	Pusher     *Pusher
	// Key signs the pushes; nil in a dry run.
	Key     ed25519.PrivateKey
	Metrics *metrics.Collector
	Logger  *slog.Logger
	// Now is the clock, injected by tests.
	Now func() time.Time

	started      atomic.Bool
	availability *snapshot.Availability
	finished     *finishedDays
	certificates *snapshot.Certificates
	cluster      *snapshot.Cluster
	project      *snapshot.Project
	security     *snapshot.Security
	supplyChain  *snapshot.SupplyChain
	nextProject  time.Time
	// doraAt is the end of the window of the last refresh with the token.
	doraAt time.Time
}

// Ready reports whether the first cycle has started.
func (c *Collector) Ready() bool {
	return c.started.Load()
}

// Run collects and pushes every minute until ctx is done.
func (c *Collector) Run(ctx context.Context) {
	t := time.NewTicker(cycleEvery)
	defer t.Stop()
	for {
		c.Cycle(ctx)
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// Cycle refreshes the blocks that are due and, once every block is held,
// pushes a signed snapshot. It reports whether every web pod accepted it.
func (c *Collector) Cycle(ctx context.Context) bool {
	c.started.Store(true)
	if now := c.Now().Truncate(time.Second); !now.Before(c.nextProject) {
		pctx, cancel := context.WithTimeout(ctx, projectDeadline)
		c.refreshProject(pctx, now)
		cancel()
	}
	ctx, cancel := context.WithTimeout(ctx, cycleDeadline)
	defer cancel()
	now := c.Now().Truncate(time.Second)

	c.refreshAvailability(ctx, now)
	c.refreshCertificates(ctx, now)
	c.refreshCluster(ctx, now)
	c.refreshSecurity(ctx, now)
	c.refreshSupplyChain(ctx, now)
	if c.availability == nil || c.certificates == nil || c.cluster == nil || c.project == nil || c.security == nil ||
		c.supplyChain == nil {
		return false
	}
	s := &snapshot.Snapshot{
		SchemaVersion: snapshot.Version,
		GeneratedAt:   snapshot.FormatTime(now),
		Availability:  *c.availability,
		Certificates:  *c.certificates,
		Cluster:       *c.cluster,
		Project:       *c.project,
		Security:      *c.security,
		SupplyChain:   *c.supplyChain,
	}
	body, err := c.validate(s)
	if err != nil {
		return false
	}
	return c.Push(ctx, body)
}

func (c *Collector) observe(block string, start time.Time, err error, source string) {
	c.Metrics.Duration.WithLabelValues(block).Observe(time.Since(start).Seconds())
	if err == nil {
		c.Metrics.Runs.WithLabelValues(block, "success").Inc()
		return
	}
	c.Metrics.Runs.WithLabelValues(block, "failure").Inc()
	c.Metrics.Errors.WithLabelValues(source).Inc()
	var fe *figureError
	figure := block
	if errors.As(err, &fe) {
		figure = fe.figure
	}
	c.Logger.Warn("block failed, last value kept", "block", block, "figure", figure, "error", err.Error())
}

// refreshAvailability reads the finished days once per Zurich day, at the
// first cycle after midnight, and the rest every cycle.
func (c *Collector) refreshAvailability(ctx context.Context, now time.Time) {
	start := time.Now()
	a, err := c.readAvailability(ctx, now)
	c.observe("availability", start, err, "prometheus")
	if err == nil {
		c.availability = &a
	}
}

func (c *Collector) readAvailability(ctx context.Context, now time.Time) (snapshot.Availability, error) {
	if today := snapshot.Day(now); c.finished == nil || !c.finished.today.Equal(today) {
		f, err := readFinished(ctx, c.Prometheus, today)
		if err != nil {
			return snapshot.Availability{}, err
		}
		c.finished = f
	}
	return availability(ctx, c.Prometheus, now, c.finished)
}

func (c *Collector) refreshCertificates(ctx context.Context, now time.Time) {
	start := time.Now()
	cs, err := certificates(ctx, c.Prometheus, now)
	c.observe("certificates", start, err, "prometheus")
	if err == nil {
		c.certificates = &cs
	}
}

func (c *Collector) refreshCluster(ctx context.Context, now time.Time) {
	start := time.Now()
	cl, err := cluster(ctx, c.Prometheus, now)
	c.observe("cluster", start, err, "prometheus")
	if err == nil {
		c.cluster = &cl
	}
}

func (c *Collector) refreshSecurity(ctx context.Context, now time.Time) {
	start := time.Now()
	s, err := security(ctx, c.Prometheus, now)
	c.observe("security", start, err, "prometheus")
	if err == nil {
		c.security = &s
	}
}

func (c *Collector) refreshSupplyChain(ctx context.Context, now time.Time) {
	start := time.Now()
	s, err := supplyChain(ctx, c.Prometheus, now)
	c.observe("supply_chain", start, err, "prometheus")
	if err == nil {
		c.supplyChain = &s
	}
}

func (c *Collector) refreshProject(ctx context.Context, now time.Time) {
	start := time.Now()
	hasToken := c.GitHub.HasToken()
	cadence := projectWithoutToken
	if hasToken {
		cadence = projectWithToken
	}
	c.nextProject = now.Add(cadence)
	p, source, err := c.readProject(ctx, now)
	c.observe("project", start, err, source)
	var rl *RateLimitError
	switch {
	case errors.As(err, &rl):
		c.nextProject = rl.Reset.Add(rateLimitMargin)
	case errors.Is(err, ErrTokenRejected):
		// No anonymous fallback: it would hide an expired token.
		c.Logger.Error("github token rejected")
		c.Metrics.TokenValid.Set(0)
	case err == nil:
		c.project = &p
		if hasToken {
			c.Metrics.TokenValid.Set(1)
		} else {
			c.Metrics.TokenValid.Set(0)
		}
	}
}

// readProject reads the project block for the 30 days ending at end. With
// the token it adds the DORA figures and the CI median; without, it keeps
// the last ones for an hour, then leaves them null. On an error it names the
// source that failed.
func (c *Collector) readProject(ctx context.Context, end time.Time) (snapshot.Project, string, error) {
	start := end.In(snapshot.Zurich).AddDate(0, 0, -snapshot.Days)
	p, err := c.GitHub.Project(ctx, start, end)
	if err != nil {
		return p, "github", err
	}
	if !c.GitHub.HasToken() {
		if c.project != nil && end.Sub(c.doraAt) <= doraKeep {
			keepDORA(&p, c.project)
		}
		return p, "", nil
	}
	prs, err := c.GitHub.mergedPRs(ctx, start, end)
	if err != nil {
		return p, "github", err
	}
	firings, err := alertFirings(ctx, c.Prometheus, start, end)
	if err != nil {
		return p, "prometheus", err
	}
	setDORA(&p, prs, firings, start, end)
	c.doraAt = end
	return p, "", nil
}

// validate encodes s and runs snapshot.Validate on the exact bytes that
// will be signed. A failure logs every error and pushes nothing.
func (c *Collector) validate(s *snapshot.Snapshot) ([]byte, error) {
	body, err := json.Marshal(s)
	if err == nil {
		_, err = snapshot.Validate(body)
	}
	if err != nil {
		c.Metrics.Errors.WithLabelValues("validation").Inc()
		for _, e := range splitErrors(err) {
			c.Logger.Error("snapshot invalid, nothing pushed", "error", e.Error())
		}
		return nil, err
	}
	return body, nil
}

func splitErrors(err error) []error {
	var joined interface{ Unwrap() []error }
	if errors.As(err, &joined) {
		return joined.Unwrap()
	}
	return []error{err}
}

// Push signs body and posts it to every web pod. It reports whether every
// pod accepted it.
func (c *Collector) Push(ctx context.Context, body []byte) bool {
	results, err := c.Pusher.Push(ctx, body, snapshot.Sign(c.Key, body))
	if err != nil {
		c.Metrics.Pushes.WithLabelValues("error").Inc()
		c.Logger.Warn("push failed", "error", err.Error())
		return false
	}
	ok := len(results) > 0
	for _, r := range results {
		c.Metrics.Pushes.WithLabelValues(r.Result).Inc()
		if r.Err != nil {
			ok = false
			c.Logger.Warn("push failed", "target", r.Target, "result", r.Result, "error", r.Err.Error())
		}
	}
	return ok
}

// Collect computes every block once with queries at at and returns the
// validated snapshot and its encoding; at is also its generated_at.
func (c *Collector) Collect(ctx context.Context, at time.Time) (*snapshot.Snapshot, []byte, error) {
	at = at.Truncate(time.Second)
	a, err := c.readAvailability(ctx, at)
	if err != nil {
		return nil, nil, fmt.Errorf("availability: %w", err)
	}
	certs, err := certificates(ctx, c.Prometheus, at)
	if err != nil {
		return nil, nil, fmt.Errorf("certificates: %w", err)
	}
	cl, err := cluster(ctx, c.Prometheus, at)
	if err != nil {
		return nil, nil, fmt.Errorf("cluster: %w", err)
	}
	p, _, err := c.readProject(ctx, at)
	if err != nil {
		return nil, nil, fmt.Errorf("project: %w", err)
	}
	sec, err := security(ctx, c.Prometheus, at)
	if err != nil {
		return nil, nil, fmt.Errorf("security: %w", err)
	}
	sc, err := supplyChain(ctx, c.Prometheus, at)
	if err != nil {
		return nil, nil, fmt.Errorf("supply chain: %w", err)
	}
	s := &snapshot.Snapshot{
		SchemaVersion: snapshot.Version,
		GeneratedAt:   snapshot.FormatTime(at),
		Availability:  a,
		Certificates:  certs,
		Cluster:       cl,
		Project:       p,
		Security:      sec,
		SupplyChain:   sc,
	}
	body, err := c.validate(s)
	if err != nil {
		return nil, nil, err
	}
	return s, body, nil
}
