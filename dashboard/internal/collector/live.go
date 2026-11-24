package collector

import (
	"context"
	"fmt"
	"math"
	"strings"
	"time"

	"github.com/ned-si/homelab/dashboard/internal/snapshot"
)

const (
	// probeJobs are the probes an app's state reads: an app with several
	// probes is down when any of them fails.
	probeJobs = `job=~"blackbox-public|blackbox-internal"`
	// minToday is the shortest window of today's bar, so a cycle just after
	// midnight still has a sample.
	minToday = 60 * time.Second
)

// finishedDays are the 29 finished Zurich days before today, each the shown
// apps' availability by SLOApp, oldest first, read once a day.
type finishedDays struct {
	today time.Time
	days  []map[string]float64
}

// readFinished reads the finished days before today: 1 -
// slo:probe_error:ratio_rate1d at each of the 29 midnights, the newest at
// today's 00:00, instant queries so the DST days stay right.
func readFinished(ctx context.Context, q Querier, today time.Time) (*finishedDays, error) {
	f := &finishedDays{today: today}
	for i := snapshot.Days - 2; i >= 0; i-- {
		v, err := query(ctx, q, "availability_daily", "1 - slo:probe_error:ratio_rate1d"+sloSelector(), snapshot.AddDays(today, -i))
		if err != nil {
			return nil, err
		}
		f.days = append(f.days, byApp(v))
	}
	return f, nil
}

// probeSelector is the matcher of every probe behind the shown apps.
func probeSelector(apps []snapshot.ShownApp) string {
	var labels []string
	for _, a := range apps {
		labels = append(labels, a.Probes()...)
	}
	return `app=~"` + strings.Join(labels, "|") + `"`
}

// availability builds the live block at now from the finished days.
func availability(ctx context.Context, q Querier, now time.Time, f *finishedDays) (snapshot.Availability, error) {
	var a snapshot.Availability
	shown := snapshot.Shown()
	sel := sloSelector()
	v, err := query(ctx, q, "availability_30d", "slo:availability:ratio_rate30d"+sel, now)
	if err != nil {
		return a, err
	}
	avail := byApp(v)
	if v, err = query(ctx, q, "error_budget_remaining_30d", "slo:error_budget_remaining:ratio_rate30d"+sel, now); err != nil {
		return a, err
	}
	budget := byApp(v)
	if v, err = query(ctx, q, "state", "min by (app) (probe_success{"+probeJobs+", "+probeSelector(shown)+"})", now); err != nil {
		return a, err
	}
	probes := byApp(v)
	today, err := todayValues(ctx, q, shown, now, f.today)
	if err != nil {
		return a, err
	}

	for i := range snapshot.Days {
		a.Days = append(a.Days, snapshot.AddDays(f.today, i-(snapshot.Days-1)).Format(snapshot.DateLayout))
	}
	for _, s := range shown {
		app := snapshot.LiveApp{ID: s.ID, Name: s.Name, State: state(s, probes)}
		if x, ok := avail[s.SLOApp]; ok {
			p := snapshot.PercentDown(x)
			app.Availability30d = &p
		}
		if x, ok := budget[s.SLOApp]; ok {
			b := snapshot.Budget(x)
			app.ErrorBudgetRemaining30d = &b
		}
		for _, d := range f.days {
			app.AvailabilityDaily = append(app.AvailabilityDaily, percent(d, s.SLOApp))
		}
		app.AvailabilityDaily = append(app.AvailabilityDaily, percent(today, s.SLOApp))
		a.Apps = append(a.Apps, app)
	}
	a.AsOf = snapshot.FormatTime(now)
	return a, nil
}

// state is up when every probe of s succeeds, down when one fails and none
// without a probe.
func state(s snapshot.ShownApp, probes map[string]float64) string {
	st := snapshot.StateNone
	for _, p := range s.Probes() {
		v, ok := probes[p]
		switch {
		case !ok:
		case v < 1:
			return snapshot.StateDown
		default:
			st = snapshot.StateUp
		}
	}
	return st
}

func percent(values map[string]float64, app string) *float64 {
	x, ok := values[app]
	if !ok || math.IsNaN(x) {
		return nil
	}
	p := snapshot.PercentDown(x)
	return &p
}

// todayValues returns today's availability so far by SLOApp: the mean of
// the public probes since midnight, or for an app of several probes the
// mean of all of them, as its recording rules compute it.
func todayValues(ctx context.Context, q Querier, shown []snapshot.ShownApp, now, today time.Time) (map[string]float64, error) {
	window := fmt.Sprintf("[%ds]", int(max(minToday, now.Sub(today)).Seconds()))
	out := map[string]float64{}
	var single []snapshot.ShownApp
	for _, s := range shown {
		if len(s.ProbeApps) == 0 {
			single = append(single, s)
			continue
		}
		x, err := optional(ctx, q, "availability_daily",
			"avg(avg_over_time(probe_success{"+probeJobs+", "+probeSelector([]snapshot.ShownApp{s})+"}"+window+"))", now)
		if err != nil {
			return nil, err
		}
		if x != nil {
			out[s.SLOApp] = *x
		}
	}
	if len(single) == 0 {
		return out, nil
	}
	v, err := query(ctx, q, "availability_daily",
		`avg by (app) (avg_over_time(probe_success{job="blackbox-public", `+probeSelector(single)+"}"+window+"))", now)
	if err != nil {
		return nil, err
	}
	for app, x := range byApp(v) {
		out[app] = x
	}
	return out, nil
}

// certificates reads the days left of each shown certificate at now, the
// earliest expiry over the probes it covers; nil without a probe.
func certificates(ctx context.Context, q Querier, now time.Time) (snapshot.Certificates, error) {
	var c snapshot.Certificates
	for _, s := range snapshot.ShownCerts() {
		x, err := optional(ctx, q, "days_left",
			`floor((min(probe_ssl_earliest_cert_expiry{job="blackbox-public", instance=~"`+s.Instance+`"}) - time()) / 86400)`, now)
		if err != nil {
			return c, err
		}
		cert := snapshot.Cert{ID: s.ID, Name: s.Name}
		if x != nil {
			d := min(400, max(-30, int(math.Floor(*x))))
			cert.DaysLeft = &d
		}
		c.Certs = append(c.Certs, cert)
	}
	c.AsOf = snapshot.FormatTime(now)
	return c, nil
}
