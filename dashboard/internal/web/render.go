package web

import (
	"html/template"
	"math"
	"strconv"
	"time"

	"github.com/ned-si/homelab/dashboard/internal/snapshot"
)

// liveStaleAfter is how old the live figures may be before the page says so.
const liveStaleAfter = 5 * time.Minute

// blockStaleAfter is how much older than generated_at a block's as_of may be
// before its card says so; projectStaleAfter is the same for the project
// block, refreshed every 15 minutes.
const (
	blockStaleAfter   = 5 * time.Minute
	projectStaleAfter = 60 * time.Minute
)

type when struct {
	Datetime string
	Text     string
}

// part is a figure and its unit, as the page shows it: "2" "h", "10" "min".
type part struct {
	Num  string
	Unit string
}

type appCard struct {
	Name         string
	State        status
	StateWord    string
	Availability string
	Status       status
	Word         string
	NoData       bool
	Since        string
	Exhausted    bool
	BudgetLeft   string
	Meter        template.HTML
	Bars         template.HTML
}

// tile is one stat: a label, the big figure with its units, its status and
// word when it has a threshold, an optional meter and a line of detail.
type tile struct {
	Label  string
	Value  []part
	Status status
	Word   string
	Meter  template.HTML
	Spark  template.HTML
	Detail string
}

// useRow is one node or the NAS on the cluster card.
type useRow struct {
	Name      string
	State     status
	StateWord string
	Figures   []useFigure
}

type useFigure struct {
	Label  string
	Value  string
	Status status
	Word   string
	Meter  template.HTML
}

type ciRun struct {
	Status   status
	Word     string
	PR       *int
	Commit   string
	Started  when
	Duration []part
}

// overall is the overall DORA level: a band word in its colour.
type overall struct {
	Status status
	Word   string
	NoData bool
}

// block is a card's as of time and, when it lags generated_at, the notice.
type block struct {
	AsOf  when
	Stale bool
}

type figures struct {
	Generated    when
	Availability block
	Apps         []appCard
	Certificates block
	Certs        []tile
	Cluster      block
	Use          []useRow
	RED          []tile
	State        []tile
	Security     block
	Signals      []tile
	Project      block
	DORA         []tile
	DORALevel    overall
	Delivery     []tile
	Runs         []ciRun
}

type pageData struct {
	Title        string
	CSS          string
	CSSIntegrity string
	LiveStale    *when
	Figures      *figures
}

func timeText(t time.Time) string {
	return t.In(snapshot.Zurich).Format("2 January 2006, 15:04")
}

func shortTime(t time.Time) string {
	return t.In(snapshot.Zurich).Format("2 Jan 15:04")
}

// at formats an RFC 3339 timestamp of the snapshot for a <time> element.
func at(s string) (when, error) {
	t, err := snapshot.ParseTime(s)
	if err != nil {
		return when{}, err
	}
	return when{s, timeText(t)}, nil
}

// blockAt is a block's as of time, stale when it is more than after before
// generated.
func blockAt(asOf string, generated time.Time, after time.Duration) (block, error) {
	w, err := at(asOf)
	if err != nil {
		return block{}, err
	}
	t, _ := snapshot.ParseTime(asOf) // at parsed it
	return block{AsOf: w, Stale: generated.Sub(t) > after}, nil
}

func fixed(v float64, decimals int) string {
	return strconv.FormatFloat(v, 'f', decimals, 64)
}

// thousands formats n with a comma between groups of three digits.
func thousands(n int) string {
	s := strconv.Itoa(n)
	neg := n < 0
	if neg {
		s = s[1:]
	}
	for i := len(s) - 3; i > 0; i -= 3 {
		s = s[:i] + "," + s[i:]
	}
	if neg {
		s = "-" + s
	}
	return s
}

// bytesText formats a size in binary units: whole GiB below a TiB, one
// decimal above.
func bytesText(n int64) string {
	const gib, tib = 1 << 30, 1 << 40
	switch {
	case n >= tib:
		return fixed(float64(n)/tib, 1) + " TiB"
	case n >= gib:
		return strconv.FormatInt(int64(math.Round(float64(n)/gib)), 10) + " GiB"
	default:
		return strconv.FormatInt(int64(math.Round(float64(n)/(1<<20))), 10) + " MiB"
	}
}

// durationParts writes s seconds as its two largest units, the second left
// out when it is 0; seconds after minutes have two digits.
func durationParts(s int) []part {
	units := []struct {
		size int
		name string
	}{{86400, "d"}, {3600, "h"}, {60, "min"}, {1, "s"}}
	for i, u := range units[:len(units)-1] {
		if s < u.size {
			continue
		}
		out := []part{{strconv.Itoa(s / u.size), u.name}}
		next := units[i+1]
		if rest := s % u.size / next.size; rest > 0 {
			n := strconv.Itoa(rest)
			if next.name == "s" && len(n) == 1 {
				n = "0" + n
			}
			out = append(out, part{n, next.name})
		}
		return out
	}
	return []part{{strconv.Itoa(s), "s"}}
}

func one(num, unit string) []part {
	return []part{{num, unit}}
}

// card builds one app's card from its live figures; days are the dates of
// its daily values.
func card(a snapshot.LiveApp, days []string) appCard {
	c := appCard{Name: a.Name, Bars: dailyBars(days, a.AvailabilityDaily)}
	c.State, c.StateWord = appState(a.State)
	first := -1
	for i, v := range a.AvailabilityDaily {
		if v != nil {
			first = i
			break
		}
	}
	switch {
	case a.Availability30d == nil || first < 0:
		c.Status, c.NoData = statusNone, true
		return c
	case first > 0:
		// Under 30 days of data the 30-day target cannot be judged yet: the
		// figure stays neutral, with no word and no budget.
		c.Status = statusNone
		if d, err := snapshot.ParseDate(days[first]); err == nil {
			c.Since = d.Format("2 January")
		}
	case a.ErrorBudgetRemaining30d == nil:
		c.Status = statusNone
	default:
		left := *a.ErrorBudgetRemaining30d
		c.Status = monthStatus(left)
		c.Word = monthWord(c.Status)
		c.BudgetLeft = fixed(float64(max(left, 0)), 2)
		c.Exhausted = left <= 0
		c.Meter = budgetMeter(left)
	}
	c.Availability = fixed(*a.Availability30d, 2)
	return c
}

func certTiles(cs []snapshot.Cert) []tile {
	out := make([]tile, 0, len(cs))
	for _, c := range cs {
		t := tile{Label: c.Name}
		t.Status, t.Word = certStatus(c.DaysLeft)
		if c.DaysLeft != nil {
			unit := "days"
			if *c.DaysLeft == 1 || *c.DaysLeft == -1 {
				unit = "day"
			}
			t.Value = one(strconv.Itoa(*c.DaysLeft), unit)
		}
		out = append(out, t)
	}
	return out
}

func pct(v *float64) string {
	if v == nil {
		return noData
	}
	return percent(*v)
}

// useFig is a utilisation or saturation figure in percent with its status;
// withMeter adds the meter.
func useFig(label string, v *float64, l limits, withMeter bool) useFigure {
	st := level(v, l)
	f := useFigure{Label: label, Value: pct(v), Status: st, Word: levelWord(st)}
	if withMeter && v != nil {
		f.Meter = meter(label, *v, st)
	}
	return f
}

func errorFig(label string, v *float64, text string) useFigure {
	st := errorLevel(v)
	if v == nil {
		text = noData
	}
	return useFigure{Label: label, Value: text, Status: st, Word: levelWord(st)}
}

func intPtr(n *int) *float64 {
	if n == nil {
		return nil
	}
	x := float64(*n)
	return &x
}

func nodeRow(n snapshot.NodeUse) useRow {
	r := useRow{Name: n.Name, State: statusOK, StateWord: "Ready"}
	if !n.Ready {
		r.State, r.StateWord = statusBad, "Not ready"
	}
	netText := ""
	if n.NetErrorsPerSecond != nil {
		netText = fixed(*n.NetErrorsPerSecond, 2) + "/s"
	}
	r.Figures = []useFigure{
		useFig("CPU", n.CPU, useLimits, true),
		useFig("Memory", n.Memory, useLimits, true),
		useFig("Disk", n.Disk, diskLimits, true),
		useFig("CPU pressure", n.CPUPressure, pressureLimits, false),
		useFig("Memory pressure", n.MemoryPressure, pressureLimits, false),
		useFig("I/O pressure", n.IOPressure, pressureLimits, false),
		errorFig("Network errors", n.NetErrorsPerSecond, netText),
	}
	return r
}

func nasRow(n snapshot.NAS) useRow {
	r := useRow{Name: "NAS", State: statusOK, StateWord: "Up"}
	if !n.Up {
		r.State, r.StateWord = statusBad, "Down"
	}
	pool := useFig("Pool", n.Pool, poolLimits, true)
	if n.PoolHealthy != nil && !*n.PoolHealthy {
		pool.Status, pool.Word = statusBad, levelWord(statusBad)
		pool.Value += ", unhealthy"
	}
	load := useFigure{Label: "Load per core", Value: noData, Status: level(n.LoadPerCore, loadLimits)}
	if n.LoadPerCore != nil {
		load.Value = fixed(*n.LoadPerCore, 2)
	}
	load.Word = levelWord(load.Status)
	count := func(v *int) string {
		if v == nil {
			return ""
		}
		return strconv.Itoa(*v)
	}
	r.Figures = []useFigure{
		pool,
		useFig("CPU", n.CPU, useLimits, true),
		useFig("Memory", n.Memory, useLimits, true),
		load,
		errorFig("Device errors", intPtr(n.DeviceErrors), count(n.DeviceErrors)),
		errorFig("Scrub errors", intPtr(n.ScrubErrors), count(n.ScrubErrors)),
	}
	return r
}

// statTile is a tile with a threshold: no value without data.
func statTile(label string, v *float64, value []part, l limits) tile {
	st := level(v, l)
	t := tile{Label: label, Status: st, Word: levelWord(st)}
	if v != nil {
		t.Value = value
	}
	return t
}

func redTiles(g snapshot.Gateway) []tile {
	rps := tile{Label: "Requests"}
	if g.RequestsPerSecond != nil {
		rps.Value = one(fixed(*g.RequestsPerSecond, 2), "per second")
	} else {
		rps.Status, rps.Word = statusNone, noData
	}
	var share, p95 []part
	if g.Errors5xx != nil {
		share = one(fixed(*g.Errors5xx, 2), "%")
	}
	var p95v *float64
	if g.LatencyP95Ms != nil {
		p95 = one(thousands(*g.LatencyP95Ms), "ms")
		p95v = intPtr(g.LatencyP95Ms)
	}
	return []tile{
		rps,
		statTile("5xx answers", g.Errors5xx, share, errorShareLimits),
		statTile("p95 duration", p95v, p95, p95Limits),
	}
}

func stateTiles(c snapshot.Cluster) []tile {
	argo := tile{
		Label:  "Argo CD",
		Value:  one(strconv.Itoa(c.Apps), "apps"),
		Status: argoStatus(c.Apps, c.Synced, c.Healthy),
		Detail: strconv.Itoa(c.Synced) + " Synced, " + strconv.Itoa(c.Healthy) + " Healthy",
	}
	argo.Word = levelWord(argo.Status)
	restarts := float64(c.Restarts24h)
	fullest := c.Volumes.Fullest
	volumes := statTile("Volumes", &fullest, one(strconv.Itoa(c.Volumes.Count), "PVCs"), volumeLimits)
	volumes.Detail = bytesText(c.Volumes.UsedBytes) + " of " + bytesText(c.Volumes.CapacityBytes) +
		", fullest " + percent(fullest)
	return []tile{
		argo,
		statTile("Restarts in 24 h", &restarts, one(thousands(c.Restarts24h), ""), restartLimits),
		volumes,
		{Label: "Nodes", Value: one(strconv.Itoa(c.Nodes), "nodes")},
		{Label: "Talos", Value: one(c.TalosVersion, "")},
		{Label: "Kubernetes", Value: one(c.KubernetesVersion, "")},
	}
}

func bandTile(t tile, b band) tile {
	t.Status, t.Word = bandStatus(b), string(b)
	return t
}

func noDataTile(label string) tile {
	return tile{Label: label, Status: statusNone, Word: noData}
}

// doraTiles are the four DORA tiles and their bands, "" for a metric
// without data; no incident in 30 days is elite.
func doraTiles(p snapshot.Project) ([]tile, []band) {
	var tiles []tile
	var bands []band
	add := func(t tile, b band) {
		tiles = append(tiles, bandTile(t, b))
		bands = append(bands, b)
	}
	none := func(label string) {
		tiles = append(tiles, noDataTile(label))
		bands = append(bands, "")
	}

	add(tile{
		Label:  "Deployment frequency",
		Value:  one(thousands(p.Deploys30d), "deploys"),
		Detail: fixed(float64(p.Deploys30d)/snapshot.Days, 1) + " a day",
	}, deployBand(p.Deploys30d))

	if p.LeadTimeSeconds == nil {
		none("Lead time for changes")
	} else {
		t := tile{Label: "Lead time for changes", Value: durationParts(*p.LeadTimeSeconds), Detail: "Median"}
		if p.LeadTimeCount != nil {
			t.Detail = "Median of " + thousands(*p.LeadTimeCount) + " changes"
		}
		add(t, leadBand(time.Duration(*p.LeadTimeSeconds)*time.Second))
	}

	if p.ChangeFailureRate == nil {
		none("Change failure rate")
	} else {
		t := tile{Label: "Change failure rate", Value: one(fixed(*p.ChangeFailureRate, 2), "%")}
		if p.FailedChanges30d != nil {
			t.Detail = thousands(*p.FailedChanges30d) + " failed changes"
		}
		add(t, failureBand(*p.ChangeFailureRate))
	}

	switch {
	case p.Incidents30d == nil:
		none("Time to restore")
	case *p.Incidents30d == 0 || p.RestoreSeconds == nil:
		tiles = append(tiles, tile{Label: "Time to restore", Value: one("None", ""), Status: statusOK, Word: "No incident"})
		bands = append(bands, bandElite)
	default:
		add(tile{
			Label:  "Time to restore",
			Value:  durationParts(*p.RestoreSeconds),
			Detail: "Median of " + thousands(*p.Incidents30d) + " incidents",
		}, restoreBand(time.Duration(*p.RestoreSeconds)*time.Second))
	}
	return tiles, bands
}

// doraOverall is the overall level of bands, in the colour of its band;
// without it, "No data".
func doraOverall(bands []band) overall {
	b := overallBand(bands)
	if b == "" {
		return overall{Status: statusNone, Word: noData, NoData: true}
	}
	return overall{Status: bandStatus(b), Word: string(b)}
}

func deliveryTiles(p snapshot.Project) []tile {
	return []tile{
		{Label: "Opened by Renovate", Value: one(fixed(float64(p.RenovateShare30d), 2), "%"),
			Meter: shareBar("Opened by Renovate", p.RenovateShare30d)},
		{Label: "Median CI run", Value: durationParts(p.CIMedianSeconds30d)},
	}
}

func signalTiles(s snapshot.Security) []tile {
	end, _ := snapshot.ParseTime(s.AsOf) // validated
	shown := map[string]snapshot.ShownSignal{}
	for _, sig := range snapshot.ShownSignals() {
		shown[sig.ID] = sig
	}
	out := make([]tile, 0, len(s.Signals))
	for _, sig := range s.Signals {
		t := tile{Label: sig.Name, Spark: sparkBars(end, sig.Buckets)}
		t.Status, t.Word = signalStatus(shown[sig.ID].ExpectedZero, sig.Count24h, sig.Count7d)
		if sig.Count24h != nil {
			t.Value = one(thousands(*sig.Count24h), "in 24 h")
		}
		if sig.Count7d != nil {
			t.Detail = thousands(*sig.Count7d) + " in 7 days"
		}
		out = append(out, t)
	}
	return out
}

func runs(rs []snapshot.CIRun) []ciRun {
	out := make([]ciRun, 0, len(rs))
	for _, r := range rs {
		c := ciRun{PR: r.PR, Commit: r.Commit, Duration: durationParts(r.DurationSeconds)}
		c.Status, c.Word = runStatus(r.Result)
		if t, err := snapshot.ParseTime(r.StartedAt); err == nil {
			c.Started = when{r.StartedAt, shortTime(t)}
		}
		out = append(out, c)
	}
	return out
}

// view turns a validated snapshot into the page's data at now.
func view(s *snapshot.Snapshot, now time.Time) (*pageData, error) {
	d := &pageData{Title: "Homelab"}
	if s == nil {
		return d, nil
	}
	generated, err := at(s.GeneratedAt)
	if err != nil {
		return nil, err
	}
	g, _ := snapshot.ParseTime(s.GeneratedAt) // at parsed it
	if now.Sub(g) > liveStaleAfter {
		d.LiveStale = &generated
	}
	f := &figures{
		Generated: generated,
		Certs:     certTiles(s.Certificates.Certs),
		RED:       redTiles(s.Cluster.Gateway),
		State:     stateTiles(s.Cluster),
		Delivery:  deliveryTiles(s.Project),
		Runs:      runs(s.Project.CIRuns),
		Signals:   signalTiles(s.Security),
	}
	var bands []band
	f.DORA, bands = doraTiles(s.Project)
	f.DORALevel = doraOverall(bands)
	blocks := []struct {
		dst   *block
		asOf  string
		after time.Duration
	}{
		{&f.Availability, s.Availability.AsOf, blockStaleAfter},
		{&f.Certificates, s.Certificates.AsOf, blockStaleAfter},
		{&f.Cluster, s.Cluster.AsOf, blockStaleAfter},
		{&f.Project, s.Project.AsOf, projectStaleAfter},
		{&f.Security, s.Security.AsOf, blockStaleAfter},
	}
	for _, b := range blocks {
		if *b.dst, err = blockAt(b.asOf, g, b.after); err != nil {
			return nil, err
		}
	}
	for _, a := range s.Availability.Apps {
		f.Apps = append(f.Apps, card(a, s.Availability.Days))
	}
	for _, n := range s.Cluster.NodeUse {
		f.Use = append(f.Use, nodeRow(n))
	}
	f.Use = append(f.Use, nasRow(s.Cluster.NAS))
	d.Figures = f
	return d, nil
}
