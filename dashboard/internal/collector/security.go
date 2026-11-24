package collector

import (
	"context"
	"math"
	"strings"
	"time"

	promv1 "github.com/prometheus/client_golang/api/prometheus/v1"

	"github.com/ned-si/homelab/dashboard/internal/snapshot"
)

// The windows of a signal: its two counts and its buckets.
const (
	window24h = "24h"
	window7d  = "7d"
	bucketW   = "6h"
)

// count rounds a counted value to the nearest whole event.
func count(v *float64) *int {
	if v == nil {
		return nil
	}
	n := max(0, int(math.Round(*v)))
	return &n
}

// security reads every shown signal at now: the 24 h and 7 d counts and the
// 28 six-hour buckets ending at now (design.md, "Security signals").
func security(ctx context.Context, q Querier, now time.Time) (snapshot.Security, error) {
	var s snapshot.Security
	for _, sig := range snapshot.ShownSignals() {
		expr := func(w string) string { return strings.ReplaceAll(sig.Query, snapshot.Window, w) }
		figure := "security." + sig.ID
		day, err := optional(ctx, q, figure, expr(window24h), now)
		if err != nil {
			return s, err
		}
		week, err := optional(ctx, q, figure, expr(window7d), now)
		if err != nil {
			return s, err
		}
		out := snapshot.Signal{ID: sig.ID, Name: sig.Name, Count24h: count(day), Count7d: count(week)}
		// Extrapolation can put the 24 h count a little above the 7 d one.
		if out.Count24h != nil && out.Count7d != nil && *out.Count24h > *out.Count7d {
			*out.Count24h = *out.Count7d
		}
		if out.Buckets, err = buckets(ctx, q, figure, expr(bucketW), now); err != nil {
			return s, err
		}
		s.Signals = append(s.Signals, out)
	}
	s.AsOf = snapshot.FormatTime(now)
	return s, nil
}

// buckets runs expr, a count over 6 h, at the end of each of the 28 buckets
// ending at now, oldest first; a bucket without a sample is nil.
func buckets(ctx context.Context, q Querier, figure, expr string, now time.Time) ([]*int, error) {
	start := now.Add(-(snapshot.Buckets - 1) * snapshot.BucketWidth)
	m, err := q.QueryRange(ctx, expr, promv1.Range{Start: start, End: now, Step: snapshot.BucketWidth})
	if err != nil {
		return nil, &figureError{figure, err}
	}
	out := make([]*int, snapshot.Buckets)
	for _, series := range m {
		for _, p := range series.Values {
			i := int(math.Round(float64(p.Timestamp.Time().Sub(start)) / float64(snapshot.BucketWidth)))
			if i < 0 || i >= snapshot.Buckets || math.IsNaN(float64(p.Value)) {
				continue
			}
			v := float64(p.Value)
			out[i] = count(&v)
		}
	}
	return out, nil
}
