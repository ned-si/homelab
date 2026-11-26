package web

import (
	"html/template"
	"math"
	"strconv"
	"strings"
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

// tile is one stat tile (design.md, "Stat tiles"): a label, the value with
// its units, its status and word when it has a threshold, an optional meter,
// detail lines, a sparkline and a note. Accent marks a value that is a word:
// its status is a left border, not the value's colour.
type tile struct {
	Label   string
	Value   []part
	Status  status
	Word    string
	Accent  bool
	Meter   template.HTML
	Spark   template.HTML
	Details []string
	Note    string
}

// useRow is one node or the NAS on the cluster card: a tile group.
type useRow struct {
	Name      string
	State     status
	StateWord string
	Figures   []tile
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
	Databases    []tile
	Engines      []tile
	Security     block
	Signals      []tile
	SupplyChain  block
	Images       []tile
	Scorecard    *block
	Score        []tile
	Checks       []tile
	Project      block
	DORA         []tile
	DORALevel    tile
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

// pct formats a percentage with two decimals, rounded once, half to even on
// an exact binary tie (design.md, "Rounding"); the status rules read the raw
// value.
func pct(v float64) string {
	return strconv.FormatFloat(v, 'f', 2, 64)
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

// durationText is durationParts as one line of text: "19 h 31 min".
func durationText(s int) string {
	var words []string
	for _, p := range durationParts(s) {
		words = append(words, p.Num, p.Unit)
	}
	return strings.Join(words, " ")
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
		c.BudgetLeft = pct(max(left, 0))
		c.Exhausted = left <= 0
		c.Meter = budgetMeter(left)
	}
	c.Availability = pct(*a.Availability30d)
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

// useFig is a utilisation or saturation tile in percent with its status;
// withMeter adds the meter.
func useFig(label string, v *float64, l limits, withMeter bool) tile {
	st := level(v, l)
	f := tile{Label: label, Status: st, Word: levelWord(st)}
	if v != nil {
		f.Value = one(pct(*v), "%")
		if withMeter {
			f.Meter = meter(label, *v, st)
		}
	}
	return f
}

// errorFig is an error tile: any error is bad.
func errorFig(label string, v *float64, value []part) tile {
	st := errorLevel(v)
	f := tile{Label: label, Status: st, Word: levelWord(st)}
	if v != nil {
		f.Value = value
	}
	return f
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
	var net []part
	if n.NetErrorsPerSecond != nil {
		net = one(fixed(*n.NetErrorsPerSecond, 2), "/s")
	}
	r.Figures = []tile{
		useFig("CPU", n.CPU, useLimits, true),
		useFig("Memory", n.Memory, useLimits, true),
		useFig("Disk", n.Disk, diskLimits, true),
		useFig("CPU pressure", n.CPUPressure, pressureLimits, false),
		useFig("Memory pressure", n.MemoryPressure, pressureLimits, false),
		useFig("I/O pressure", n.IOPressure, pressureLimits, false),
		errorFig("Network errors", n.NetErrorsPerSecond, net),
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
		pool.Details = []string{"Unhealthy"}
	}
	load := statTile("Load per core", n.LoadPerCore, nil, loadLimits)
	if n.LoadPerCore != nil {
		load.Value = one(fixed(*n.LoadPerCore, 2), "")
	}
	count := func(v *int) []part {
		if v == nil {
			return nil
		}
		return one(strconv.Itoa(*v), "")
	}
	r.Figures = []tile{
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
		share = one(pct(*g.Errors5xx), "%")
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
		Label:   "Argo CD",
		Value:   one(strconv.Itoa(c.Apps), "apps"),
		Status:  argoStatus(c.Apps, c.Synced, c.Healthy),
		Details: []string{strconv.Itoa(c.Synced) + " Synced, " + strconv.Itoa(c.Healthy) + " Healthy"},
	}
	argo.Word = levelWord(argo.Status)
	restarts := float64(c.Restarts24h)
	fullest := c.Volumes.Fullest
	volumes := statTile("Volumes", &fullest, one(strconv.Itoa(c.Volumes.Count), "PVCs"), volumeLimits)
	volumes.Details = []string{bytesText(c.Volumes.UsedBytes) + " of " + bytesText(c.Volumes.CapacityBytes) +
		", fullest " + percent(fullest)}
	restartTile := statTile("Restarts", &restarts, one(thousands(c.Restarts24h), ""), restartLimits)
	restartTile.Details = []string{"Rolling 24 h"}
	return []tile{
		argo,
		restartTile,
		volumes,
		{Label: "Nodes", Value: one(strconv.Itoa(c.Nodes), "nodes")},
		{Label: "Talos", Value: one(c.TalosVersion, "")},
		{Label: "Kubernetes", Value: one(c.KubernetesVersion, "")},
	}
}

// plural is unit with an s unless n is 1.
func plural(n int, unit string) string {
	if n == 1 {
		return unit
	}
	return unit + "s"
}

// databaseTiles are the "Databases and backups" group (design.md,
// "Collector and page (task 26)"); a detail whose figure is null is left
// out, and with no database reporting every tile has no data.
func databaseTiles(d snapshot.Databases) []tile {
	const (
		pgLabel       = "PostgreSQL"
		walLabel      = "WAL archiving"
		baseLabel     = "Base backups"
		recoveryLabel = "Point-in-time recovery"
		restoreLabel  = "Restore tests"
		freshLabel    = "Backup freshness"
	)
	if d.Count == 0 {
		return []tile{noDataTile(pgLabel), noDataTile(walLabel), noDataTile(baseLabel),
			noDataTile(recoveryLabel), noDataTile(restoreLabel), noDataTile(freshLabel)}
	}
	of := "of " + strconv.Itoa(d.Count)

	pg := tile{Label: pgLabel, Value: one(strconv.Itoa(d.Count), plural(d.Count, "database"))}
	pg.Status, pg.Word = databasesStatus(d.Up, d.Count)
	up := strconv.Itoa(d.Up) + " up"
	if d.DataBytes != nil {
		up += ", " + bytesText(*d.DataBytes) + " of data"
	}
	pg.Details = []string{"Seen in the rolling 24 h", up}

	wal := tile{Label: walLabel, Value: one(strconv.Itoa(d.WALArchiving), of)}
	wal.Status, wal.Word = walStatus(d.WALArchiving, d.WALBehind, d.Count)
	if d.WALArchived24h != nil {
		wal.Details = []string{thousands(*d.WALArchived24h) + " files archived, rolling 24 h"}
	}

	base := tile{Label: baseLabel, Value: one(strconv.Itoa(d.BaseFresh), of),
		Details: []string{"Nightly, each in the rolling 26 h"}}
	base.Status, base.Word = baseBackupStatus(d.BaseFresh, d.Count)
	if d.BaseOldestSeconds != nil {
		base.Details = append(base.Details, "Oldest "+durationText(*d.BaseOldestSeconds)+" ago")
	}

	recovery := noDataTile(recoveryLabel)
	if d.RecoveryWindowSeconds != nil {
		days := *d.RecoveryWindowSeconds / 86400
		recovery = tile{Label: recoveryLabel, Value: one(strconv.Itoa(days), plural(days, "day")),
			Details: []string{"The shortest window of all databases"}}
	}

	restore := tile{Label: restoreLabel, Value: one(strconv.Itoa(d.RestorePassed), of),
		Details: []string{"Weekly, rolling 8 days"}}
	restore.Status, restore.Word = restoreStatus(d.RestorePassed, d.RestoreFailed, d.Count)
	if d.RestoreRows != nil {
		restore.Details = append(restore.Details, thousands(*d.RestoreRows)+" rows compared")
	}
	if d.RestoreMedianSeconds != nil {
		restore.Details = append(restore.Details, "Median "+durationText(*d.RestoreMedianSeconds)+" to a restored copy")
	}

	fresh := noDataTile(freshLabel)
	if d.Freshness30d != nil {
		fresh = tile{Label: freshLabel, Value: one(pct(*d.Freshness30d), "%"),
			Details: []string{"Lowest database, rolling 30 days, target " + pct(freshnessTarget) + "%"}}
		fresh.Status, fresh.Word = freshnessStatus(d.Freshness30d)
	}
	return []tile{pg, wal, base, recovery, restore, fresh}
}

// engineTiles are the other database engines next to PostgreSQL
// (dashboard-database-engines design, "The tiles"); an engine with no
// count has no data.
func engineTiles(d snapshot.Databases) []tile {
	const (
		sqliteLabel = "SQLite"
		backupLabel = "SQLite backups"
		valkeyLabel = "Valkey and Redis"
		chLabel     = "ClickHouse"
		seen        = "Seen in the rolling 24 h"
	)
	server := func(label string, count, up int, note string) tile {
		if count == 0 {
			return noDataTile(label)
		}
		t := tile{Label: label, Value: one(strconv.Itoa(count), plural(count, "instance")),
			Details: []string{seen, strconv.Itoa(up) + " up", note}}
		t.Status, t.Word = databasesStatus(up, count)
		return t
	}
	sqlite, backups := noDataTile(sqliteLabel), noDataTile(backupLabel)
	if d.SQLiteCount > 0 {
		sqlite = tile{Label: sqliteLabel, Value: one(strconv.Itoa(d.SQLiteCount), plural(d.SQLiteCount, "app")),
			Details: []string{seen, strconv.Itoa(d.SQLiteUp) + " up"}}
		sqlite.Status, sqlite.Word = databasesStatus(d.SQLiteUp, d.SQLiteCount)
		backups = tile{Label: backupLabel, Value: one(strconv.Itoa(d.SQLiteBackupFresh), "of "+strconv.Itoa(d.SQLiteCount)),
			Details: []string{"Nightly to S3, each in the rolling 26 h",
				strconv.Itoa(d.SQLiteRestorePassed) + " passed the weekly restore test, rolling 8 days"}}
		backups.Status, backups.Word = sqliteBackupStatus(d.SQLiteBackupFresh, d.SQLiteRestoreFailed, d.SQLiteCount)
	}
	return []tile{sqlite, backups,
		server(valkeyLabel, d.ValkeyRedisCount, d.ValkeyRedisUp, "In memory, not backed up"),
		server(chLabel, d.ClickHouseCount, d.ClickHouseUp, "Logs and traces expire, not backed up")}
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
		Label:   "Deployment frequency",
		Value:   one(thousands(p.Deploys30d), "deploys"),
		Details: []string{fixed(float64(p.Deploys30d)/snapshot.Days, 1) + " a day"},
	}, deployBand(p.Deploys30d))

	if p.LeadTimeSeconds == nil {
		none("Lead time for changes")
	} else {
		t := tile{Label: "Lead time for changes", Value: durationParts(*p.LeadTimeSeconds), Details: []string{"Median"}}
		if p.LeadTimeCount != nil {
			t.Details = []string{"Median of " + thousands(*p.LeadTimeCount) + " changes"}
		}
		add(t, leadBand(time.Duration(*p.LeadTimeSeconds)*time.Second))
	}

	if p.ChangeFailureRate == nil {
		none("Change failure rate")
	} else {
		t := tile{Label: "Change failure rate", Value: one(pct(*p.ChangeFailureRate), "%")}
		if p.FailedChanges30d != nil {
			t.Details = []string{thousands(*p.FailedChanges30d) + " failed changes"}
		}
		add(t, failureBand(*p.ChangeFailureRate))
	}

	switch {
	case p.Incidents30d == nil:
		none("Time to restore")
	case *p.Incidents30d == 0 || p.RestoreSeconds == nil:
		tiles = append(tiles, tile{Label: "Time to restore", Value: one("None", ""), Status: statusOK, Word: "No incident", Accent: true})
		bands = append(bands, bandElite)
	default:
		add(tile{
			Label:   "Time to restore",
			Value:   durationParts(*p.RestoreSeconds),
			Details: []string{"Median of " + thousands(*p.Incidents30d) + " incidents"},
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

// overallTile is the overall level as a tile: the band word as the value,
// its status as the left border.
func overallTile(o overall) tile {
	if o.NoData {
		return tile{Label: "Overall level", Status: statusNone, Word: noData}
	}
	return tile{Label: "Overall level", Value: one(o.Word, ""), Status: o.Status, Accent: true}
}

// reworkTile is the rework rate: no band, no status, no part in the
// overall level (requirements.md, 10.9).
func reworkTile(p snapshot.Project) tile {
	const label = "Rework rate"
	if p.Rework == nil || p.Rework.Rate == nil {
		return noDataTile(label)
	}
	return tile{
		Label:   label,
		Value:   one(pct(100**p.Rework.Rate), "%"),
		Details: []string{thousands(p.Rework.Count) + " of " + thousands(p.Rework.Deploys) + " deploys"},
	}
}

func deliveryTiles(p snapshot.Project) []tile {
	ci := noDataTile("Median CI run")
	if p.CIMedianSeconds30d != nil {
		ci = tile{Label: "Median CI run", Value: durationParts(*p.CIMedianSeconds30d)}
	}
	return []tile{
		{Label: "Opened by Renovate", Value: one(pct(p.RenovateShare30d), "%"),
			Meter: shareBar("Opened by Renovate", p.RenovateShare30d)},
		ci,
	}
}

// signalTiles are the security tiles: the rolling 24 h count with its
// status, its share of the signal's total, the part its detail names, the
// rolling 7 days, the Gateway's unattributed 4xx and the compiled note.
func signalTiles(s snapshot.Security) []tile {
	end, _ := snapshot.ParseTime(s.AsOf) // validated
	shown := map[string]snapshot.ShownSignal{}
	for _, sig := range snapshot.ShownSignals() {
		shown[sig.ID] = sig
	}
	out := make([]tile, 0, len(s.Signals))
	for _, sig := range s.Signals {
		c := shown[sig.ID]
		t := tile{Label: sig.Name, Spark: sparkBars(end, sig.Buckets), Note: c.Note}
		t.Status, t.Word = signalStatus(c.ExpectedZero, sig.Count24h, sig.Count7d)
		if sig.Count24h != nil {
			t.Value = one(thousands(*sig.Count24h), "")
			day := "Rolling 24 h"
			if sig.Share24h != nil && sig.Total24h != nil {
				day += ", " + percent(100**sig.Share24h) + " of " + thousands(*sig.Total24h) + " " + c.TotalNoun
			}
			t.Details = append(t.Details, day)
		}
		if sig.Part24h != nil {
			t.Details = append(t.Details, "Of these, "+thousands(*sig.Part24h)+" are "+c.PartNoun+"s")
		}
		if sig.Count7d != nil {
			week := "Rolling 7 days: " + thousands(*sig.Count7d)
			if sig.Share7d != nil {
				week += " (" + percent(100**sig.Share7d) + ")"
			}
			t.Details = append(t.Details, week)
		}
		if sig.Unattributed24h != nil && *sig.Unattributed24h > 0 {
			t.Details = append(t.Details, "Another "+thousands(*sig.Unattributed24h)+
				" answered by the Gateway itself cannot be attributed.")
		}
		out = append(out, t)
	}
	return out
}

// imageTiles are the first-party images: the SLSA Build level as the value,
// the verification as the status word, the builder as the detail line.
func imageTiles(sc snapshot.SupplyChain) []tile {
	out := make([]tile, 0, len(sc.Images))
	for _, img := range sc.Images {
		t := tile{Label: img.Name, Details: []string{img.Builder}}
		t.Status, t.Word = provenanceStatus(img.Verified)
		if img.Level != nil {
			t.Value = one("Build L"+strconv.Itoa(*img.Level), "")
		}
		out = append(out, t)
	}
	return out
}

// scorecardTiles are the Scorecard score with its status and date.
func scorecardTiles(sc snapshot.Scorecard) []tile {
	const label = "Score"
	if sc.Score == nil {
		return []tile{noDataTile(label)}
	}
	t := tile{Label: label, Value: one(fixed(*sc.Score, 1), "/ 10")}
	t.Status, t.Word = scoreStatus(sc.Score)
	if sc.Date != nil {
		if d, err := snapshot.ParseTime(*sc.Date); err == nil {
			t.Details = []string{"Scorecard run of " + timeText(d)}
		}
	}
	return []tile{t}
}

// notApplicable is the word of a check Scorecard could not apply (-1).
const notApplicable = "Not applicable"

// checkNotes say why a check's score is on purpose where Scorecard's
// reason does not (design.md, "Scorecard"). The score and reason stay
// Scorecard's own.
var checkNotes = map[string]string{
	"Branch-Protection": "On purpose: main takes only pull requests with signed commits and a green CI, and needs no approval, so Renovate and the agents merge without waiting for a person.",
	"Code-Review":       "On purpose: I run this alone and agents open the pull requests, so nobody else approves them. Green CI is the only gate.",
	"Contributors":      "On purpose: one operator and a few agents, with no company or organisation behind the repository.",
	"Signed-Releases":   "The images are signed with cosign and carry SLSA Build L2 provenance. No GitHub releases on purpose: these are personal apps, not meant for others to download.",
}

// checkTiles are every Scorecard check in the snapshot's name order, each
// with its score in its status colour, Scorecard's reason and its note.
func checkTiles(sc snapshot.Scorecard) []tile {
	out := make([]tile, 0, len(sc.Checks))
	for _, c := range sc.Checks {
		t := tile{Label: c.Name, Details: []string{c.Reason}, Note: checkNotes[c.Name]}
		t.Status, t.Word = checkStatus(c.Score)
		if c.Score != nil {
			t.Value = one(strconv.Itoa(*c.Score), "/ 10")
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
		Databases: databaseTiles(s.Cluster.Databases),
		Engines:   engineTiles(s.Cluster.Databases),
		Delivery:  deliveryTiles(s.Project),
		Runs:      runs(s.Project.CIRuns),
		Signals:   signalTiles(s.Security),
		Images:    imageTiles(s.SupplyChain),
		Score:     scorecardTiles(s.SupplyChain.Scorecard),
		Checks:    checkTiles(s.SupplyChain.Scorecard),
	}
	var bands []band
	f.DORA, bands = doraTiles(s.Project)
	f.DORALevel = overallTile(doraOverall(bands))
	f.DORA = append(f.DORA, reworkTile(s.Project))
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
		{&f.SupplyChain, s.SupplyChain.AsOf, blockStaleAfter},
	}
	for _, b := range blocks {
		if *b.dst, err = blockAt(b.asOf, g, b.after); err != nil {
			return nil, err
		}
	}
	// The Scorecard result is fetched hourly, like the project block.
	if a := s.SupplyChain.Scorecard.AsOf; a != nil {
		b, err := blockAt(*a, g, projectStaleAfter)
		if err != nil {
			return nil, err
		}
		f.Scorecard = &b
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
