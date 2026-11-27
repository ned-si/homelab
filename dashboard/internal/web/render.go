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
	Unit         string
	Status       status
	Word         string
	NoData       bool
	Since        string
	Exhausted    bool
	Budget       string
	Meter        template.HTML
	Bars         template.HTML
}

// tile is one stat tile (design.md, "Stat tiles"): a label, the value with
// its units, its status and word when it has a threshold, an optional meter,
// detail lines, a sparkline and a note. Accent marks a value that is a word:
// its status is a left border, not the value's colour. DetailLang marks
// details in another language than the page's (Scorecard's reasons).
type tile struct {
	Label      string
	Value      []part
	Status     status
	Word       string
	Accent     bool
	Meter      template.HTML
	Spark      template.HTML
	Details    []string
	DetailLang string
	Note       string
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

// pageData is what layout.html and the page render: Lang is <html lang>,
// T the catalogue, Path the page in its language ("/", "/fr/"), URL its
// canonical, EN and FR its two language versions. A not-found page has no
// hreflang links.
type pageData struct {
	Title        string
	CSS          string
	CSSIntegrity string
	Lang         string
	Code         string
	T            catalogue
	Path         string
	URL          string
	EN, FR       string
	NotFound     bool
	LiveStale    *when
	Figures      *figures
}

// asOf is what the asof template renders: a block and the catalogue.
type asOf struct {
	block
	T catalogue
}

// At pairs a block with the page's catalogue for the asof template.
func (d *pageData) At(b block) asOf {
	return asOf{b, d.T}
}

// newPage is the page data of l with the title of key.
func newPage(l *locale, key string) *pageData {
	return &pageData{
		Title: l.t(key), Lang: l.Tag, Code: l.Code, T: l.T, Path: l.Path, URL: l.page(),
		EN: english.page(), FR: french.page(),
	}
}

// at formats an RFC 3339 timestamp of the snapshot for a <time> element.
func at(l *locale, s string) (when, error) {
	t, err := snapshot.ParseTime(s)
	if err != nil {
		return when{}, err
	}
	return when{s, l.timeText(t)}, nil
}

// blockAt is a block's as of time, stale when it is more than after before
// generated.
func blockAt(l *locale, asOf string, generated time.Time, after time.Duration) (block, error) {
	w, err := at(l, asOf)
	if err != nil {
		return block{}, err
	}
	t, _ := snapshot.ParseTime(asOf) // at parsed it
	return block{AsOf: w, Stale: generated.Sub(t) > after}, nil
}

// bytesText formats a size in binary units: whole GiB below a TiB, one
// decimal above.
func (l *locale) bytesText(n int64) string {
	const gib, tib = 1 << 30, 1 << 40
	switch {
	case n >= tib:
		return l.fixed(float64(n)/tib, 1) + l.spaced + l.t("unit.tib")
	case n >= gib:
		return strconv.FormatInt(int64(math.Round(float64(n)/gib)), 10) + l.spaced + l.t("unit.gib")
	default:
		return strconv.FormatInt(int64(math.Round(float64(n)/(1<<20))), 10) + l.spaced + l.t("unit.mib")
	}
}

// durationParts writes s seconds as its two largest units, the second left
// out when it is 0; seconds after minutes have two digits.
func (l *locale) durationParts(s int) []part {
	units := []struct {
		size int
		name string
	}{{86400, "d"}, {3600, "h"}, {60, "min"}, {1, "s"}}
	for i, u := range units[:len(units)-1] {
		if s < u.size {
			continue
		}
		out := l.one(strconv.Itoa(s/u.size), "unit."+u.name)
		next := units[i+1]
		if rest := s % u.size / next.size; rest > 0 {
			n := strconv.Itoa(rest)
			if next.name == "s" && len(n) == 1 {
				n = "0" + n
			}
			out = append(out, l.one(n, "unit."+next.name)...)
		}
		return out
	}
	return l.one(strconv.Itoa(s), "unit.s")
}

// durationText is durationParts as one line of text: "19 h 31 min".
func (l *locale) durationText(s int) string {
	var words []string
	for _, p := range l.durationParts(s) {
		words = append(words, p.Num+l.spaced+strings.TrimPrefix(p.Unit, l.tight))
	}
	return strings.Join(words, " ")
}

// of is n with the unit "of count".
func (l *locale) of(n, count int) []part {
	return []part{{strconv.Itoa(n), l.tight + l.f("unit.of", strconv.Itoa(count))}}
}

// one is a figure with the unit of the catalogue key unit, "" for none.
func (l *locale) one(num, unit string) []part {
	if unit == "" {
		return []part{{num, ""}}
	}
	return []part{{num, l.unit(unit)}}
}

// card builds one app's card from its live figures; days are the dates of
// its daily values.
func card(l *locale, a snapshot.LiveApp, days []string) appCard {
	c := appCard{Name: l.t("app." + a.ID), Unit: l.unit("unit.percent"), Bars: dailyBars(l, days, a.AvailabilityDaily)}
	c.State, c.StateWord = appState(l, a.State)
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
			c.Since = l.dayMonth(d)
		}
	case a.ErrorBudgetRemaining30d == nil:
		c.Status = statusNone
	default:
		left := *a.ErrorBudgetRemaining30d
		c.Status = monthStatus(left)
		c.Word = monthWord(l, c.Status)
		c.Exhausted = left <= 0
		c.Budget = l.t("card.exhausted")
		if !c.Exhausted {
			c.Budget = l.f("card.budget", l.percent(left))
		}
		c.Meter = budgetMeter(l, left)
	}
	c.Availability = l.pct(*a.Availability30d)
	return c
}

func certTiles(l *locale, cs []snapshot.Cert) []tile {
	out := make([]tile, 0, len(cs))
	for _, c := range cs {
		t := tile{Label: c.Name}
		t.Status, t.Word = certStatus(l, c.DaysLeft)
		if c.DaysLeft != nil {
			t.Value = l.one(strconv.Itoa(*c.DaysLeft), l.plural(*c.DaysLeft, "unit.day", "unit.days"))
		}
		out = append(out, t)
	}
	return out
}

// useFig is a utilisation or saturation tile in percent with its status;
// withMeter adds the meter.
func useFig(l *locale, label string, v *float64, lim limits, withMeter bool) tile {
	st := level(v, lim)
	f := tile{Label: l.t(label), Status: st, Word: levelWord(l, st)}
	if v != nil {
		f.Value = l.one(l.pct(*v), "unit.percent")
		if withMeter {
			f.Meter = meter(l, f.Label, *v, st)
		}
	}
	return f
}

// errorFig is an error tile: any error is bad.
func errorFig(l *locale, label string, v *float64, value []part) tile {
	st := errorLevel(v)
	f := tile{Label: l.t(label), Status: st, Word: levelWord(l, st)}
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

func nodeRow(l *locale, n snapshot.NodeUse) useRow {
	r := useRow{Name: n.Name, State: statusOK, StateWord: l.t("status.ready")}
	if !n.Ready {
		r.State, r.StateWord = statusBad, l.t("status.not-ready")
	}
	var net []part
	if n.NetErrorsPerSecond != nil {
		net = l.one(l.fixed(*n.NetErrorsPerSecond, 2), "unit.per-s")
	}
	r.Figures = []tile{
		useFig(l, "use.cpu", n.CPU, useLimits, true),
		useFig(l, "use.memory", n.Memory, useLimits, true),
		useFig(l, "use.disk", n.Disk, diskLimits, true),
		useFig(l, "use.cpu-pressure", n.CPUPressure, pressureLimits, false),
		useFig(l, "use.memory-pressure", n.MemoryPressure, pressureLimits, false),
		useFig(l, "use.io-pressure", n.IOPressure, pressureLimits, false),
		errorFig(l, "use.net-errors", n.NetErrorsPerSecond, net),
	}
	return r
}

func nasRow(l *locale, n snapshot.NAS) useRow {
	r := useRow{Name: l.t("use.nas"), State: statusOK, StateWord: l.t("status.up")}
	if !n.Up {
		r.State, r.StateWord = statusBad, l.t("status.down")
	}
	pool := useFig(l, "use.pool", n.Pool, poolLimits, true)
	if n.PoolHealthy != nil && !*n.PoolHealthy {
		pool.Status, pool.Word = statusBad, levelWord(l, statusBad)
		pool.Details = []string{l.t("use.unhealthy")}
	}
	load := statTile(l, "use.load", n.LoadPerCore, nil, loadLimits)
	if n.LoadPerCore != nil {
		load.Value = l.one(l.fixed(*n.LoadPerCore, 2), "")
	}
	count := func(v *int) []part {
		if v == nil {
			return nil
		}
		return l.one(strconv.Itoa(*v), "")
	}
	r.Figures = []tile{
		pool,
		useFig(l, "use.cpu", n.CPU, useLimits, true),
		useFig(l, "use.memory", n.Memory, useLimits, true),
		load,
		errorFig(l, "use.device-errors", intPtr(n.DeviceErrors), count(n.DeviceErrors)),
		errorFig(l, "use.scrub-errors", intPtr(n.ScrubErrors), count(n.ScrubErrors)),
	}
	return r
}

// statTile is a tile with a threshold: no value without data.
func statTile(l *locale, label string, v *float64, value []part, lim limits) tile {
	st := level(v, lim)
	t := tile{Label: l.t(label), Status: st, Word: levelWord(l, st)}
	if v != nil {
		t.Value = value
	}
	return t
}

func redTiles(l *locale, g snapshot.Gateway) []tile {
	rps := tile{Label: l.t("red.requests")}
	if g.RequestsPerSecond != nil {
		rps.Value = l.one(l.fixed(*g.RequestsPerSecond, 2), "unit.per-second")
	} else {
		rps.Status, rps.Word = statusNone, l.t("status.nodata")
	}
	var share, p95 []part
	if g.Errors5xx != nil {
		share = l.one(l.pct(*g.Errors5xx), "unit.percent")
	}
	var p95v *float64
	if g.LatencyP95Ms != nil {
		p95 = l.one(l.thousands(*g.LatencyP95Ms), "unit.ms")
		p95v = intPtr(g.LatencyP95Ms)
	}
	return []tile{
		rps,
		statTile(l, "red.5xx", g.Errors5xx, share, errorShareLimits),
		statTile(l, "red.p95", p95v, p95, p95Limits),
	}
}

func stateTiles(l *locale, c snapshot.Cluster) []tile {
	argo := tile{
		Label:   l.t("state.argo"),
		Value:   l.one(strconv.Itoa(c.Apps), "unit.apps"),
		Status:  argoStatus(c.Apps, c.Synced, c.Healthy),
		Details: []string{l.f("state.argo.detail", strconv.Itoa(c.Synced), strconv.Itoa(c.Healthy))},
	}
	argo.Word = levelWord(l, argo.Status)
	restarts := float64(c.Restarts24h)
	fullest := c.Volumes.Fullest
	volumes := statTile(l, "state.volumes", &fullest, l.one(strconv.Itoa(c.Volumes.Count), "unit.pvcs"), volumeLimits)
	volumes.Details = []string{l.f("state.volumes.detail",
		l.bytesText(c.Volumes.UsedBytes), l.bytesText(c.Volumes.CapacityBytes), l.percent(fullest))}
	restartTile := statTile(l, "state.restarts", &restarts, l.one(l.thousands(c.Restarts24h), ""), restartLimits)
	restartTile.Details = []string{l.t("rolling.24h")}
	return []tile{
		argo,
		restartTile,
		volumes,
		{Label: l.t("state.nodes"), Value: l.one(strconv.Itoa(c.Nodes), "unit.nodes")},
		{Label: l.t("state.talos"), Value: l.one(c.TalosVersion, "")},
		{Label: l.t("state.kubernetes"), Value: l.one(c.KubernetesVersion, "")},
	}
}

// databaseTiles are the "Databases and backups" group (design.md,
// "Collector and page (task 26)"); a detail whose figure is null is left
// out, and with no database reporting every tile has no data.
func databaseTiles(l *locale, d snapshot.Databases) []tile {
	const (
		pgLabel       = "db.postgresql"
		walLabel      = "db.wal"
		baseLabel     = "db.base"
		recoveryLabel = "db.recovery"
		restoreLabel  = "db.restore"
		freshLabel    = "db.fresh"
	)
	if d.Count == 0 {
		return []tile{noDataTile(l, pgLabel), noDataTile(l, walLabel), noDataTile(l, baseLabel),
			noDataTile(l, recoveryLabel), noDataTile(l, restoreLabel), noDataTile(l, freshLabel)}
	}
	of := func(n int) []part { return l.of(n, d.Count) }

	pg := tile{Label: l.t(pgLabel), Value: l.one(strconv.Itoa(d.Count), l.plural(d.Count, "unit.database", "unit.databases"))}
	pg.Status, pg.Word = databasesStatus(l, d.Up, d.Count)
	up := l.f("db.up", strconv.Itoa(d.Up))
	if d.DataBytes != nil {
		up = l.f("db.up.data", strconv.Itoa(d.Up), l.bytesText(*d.DataBytes))
	}
	pg.Details = []string{l.t("db.seen"), up}

	wal := tile{Label: l.t(walLabel), Value: of(d.WALArchiving)}
	wal.Status, wal.Word = walStatus(l, d.WALArchiving, d.WALBehind, d.Count)
	if d.WALArchived24h != nil {
		wal.Details = []string{l.f("db.wal.detail", l.thousands(*d.WALArchived24h))}
	}

	base := tile{Label: l.t(baseLabel), Value: of(d.BaseFresh), Details: []string{l.t("db.base.detail")}}
	base.Status, base.Word = baseBackupStatus(l, d.BaseFresh, d.Count)
	if d.BaseOldestSeconds != nil {
		base.Details = append(base.Details, l.f("db.base.oldest", l.durationText(*d.BaseOldestSeconds)))
	}

	recovery := noDataTile(l, recoveryLabel)
	if d.RecoveryWindowSeconds != nil {
		days := *d.RecoveryWindowSeconds / 86400
		recovery = tile{Label: l.t(recoveryLabel), Value: l.one(strconv.Itoa(days), l.plural(days, "unit.day", "unit.days")),
			Details: []string{l.t("db.recovery.detail")}}
	}

	restore := tile{Label: l.t(restoreLabel), Value: of(d.RestorePassed), Details: []string{l.t("db.restore.detail")}}
	restore.Status, restore.Word = restoreStatus(l, d.RestorePassed, d.RestoreFailed, d.Count)
	if d.RestoreRows != nil {
		restore.Details = append(restore.Details, l.f("db.restore.rows", l.thousands(*d.RestoreRows)))
	}
	if d.RestoreMedianSeconds != nil {
		restore.Details = append(restore.Details, l.f("db.restore.median", l.durationText(*d.RestoreMedianSeconds)))
	}

	fresh := noDataTile(l, freshLabel)
	if d.Freshness30d != nil {
		fresh = tile{Label: l.t(freshLabel), Value: l.one(l.pct(*d.Freshness30d), "unit.percent"),
			Details: []string{l.f("db.fresh.detail", l.percent(freshnessTarget))}}
		fresh.Status, fresh.Word = freshnessStatus(l, d.Freshness30d)
	}
	return []tile{pg, wal, base, recovery, restore, fresh}
}

// engineTiles are the other database engines next to PostgreSQL
// (dashboard-database-engines design, "The tiles"); an engine with no
// count has no data.
func engineTiles(l *locale, d snapshot.Databases) []tile {
	const (
		sqliteLabel = "db.sqlite"
		backupLabel = "db.sqlite-backups"
		valkeyLabel = "db.valkey"
		chLabel     = "db.clickhouse"
	)
	seen := l.t("db.seen")
	server := func(label string, count, up int, note string) tile {
		if count == 0 {
			return noDataTile(l, label)
		}
		t := tile{Label: l.t(label), Value: l.one(strconv.Itoa(count), l.plural(count, "unit.instance", "unit.instances")),
			Details: []string{seen, l.f("db.up", strconv.Itoa(up)), l.t(note)}}
		t.Status, t.Word = databasesStatus(l, up, count)
		return t
	}
	sqlite, backups := noDataTile(l, sqliteLabel), noDataTile(l, backupLabel)
	if d.SQLiteCount > 0 {
		sqlite = tile{Label: l.t(sqliteLabel), Value: l.one(strconv.Itoa(d.SQLiteCount), l.plural(d.SQLiteCount, "unit.app", "unit.apps")),
			Details: []string{seen, l.f("db.up", strconv.Itoa(d.SQLiteUp))}}
		sqlite.Status, sqlite.Word = databasesStatus(l, d.SQLiteUp, d.SQLiteCount)
		backups = tile{Label: l.t(backupLabel), Value: l.of(d.SQLiteBackupFresh, d.SQLiteCount),
			Details: []string{l.t("db.sqlite-backups.detail"),
				l.f("db.sqlite-backups.restore", strconv.Itoa(d.SQLiteRestorePassed))}}
		backups.Status, backups.Word = sqliteBackupStatus(l, d.SQLiteBackupFresh, d.SQLiteRestoreFailed, d.SQLiteCount)
	}
	return []tile{sqlite, backups,
		server(valkeyLabel, d.ValkeyRedisCount, d.ValkeyRedisUp, "db.valkey.note"),
		server(chLabel, d.ClickHouseCount, d.ClickHouseUp, "db.clickhouse.note")}
}

func bandTile(l *locale, t tile, b band) tile {
	t.Status, t.Word = bandStatus(b), bandWord(l, b)
	return t
}

func noDataTile(l *locale, label string) tile {
	return tile{Label: l.t(label), Status: statusNone, Word: l.t("status.nodata")}
}

// doraTiles are the four DORA tiles and their bands, "" for a metric
// without data; no incident in 30 days is elite.
func doraTiles(l *locale, p snapshot.Project) ([]tile, []band) {
	var tiles []tile
	var bands []band
	add := func(t tile, b band) {
		tiles = append(tiles, bandTile(l, t, b))
		bands = append(bands, b)
	}
	none := func(label string) {
		tiles = append(tiles, noDataTile(l, label))
		bands = append(bands, "")
	}

	add(tile{
		Label:   l.t("dora.deploys"),
		Value:   l.one(l.thousands(p.Deploys30d), "unit.deploys"),
		Details: []string{l.f("dora.deploys.detail", l.fixed(float64(p.Deploys30d)/snapshot.Days, 1))},
	}, deployBand(p.Deploys30d))

	if p.LeadTimeSeconds == nil {
		none("dora.lead")
	} else {
		t := tile{Label: l.t("dora.lead"), Value: l.durationParts(*p.LeadTimeSeconds), Details: []string{l.t("dora.lead.median")}}
		if p.LeadTimeCount != nil {
			t.Details = []string{l.f("dora.lead.detail", l.thousands(*p.LeadTimeCount))}
		}
		add(t, leadBand(time.Duration(*p.LeadTimeSeconds)*time.Second))
	}

	if p.ChangeFailureRate == nil {
		none("dora.failure")
	} else {
		t := tile{Label: l.t("dora.failure"), Value: l.one(l.pct(*p.ChangeFailureRate), "unit.percent")}
		if p.FailedChanges30d != nil {
			t.Details = []string{l.f("dora.failure.detail", l.thousands(*p.FailedChanges30d))}
		}
		add(t, failureBand(*p.ChangeFailureRate))
	}

	switch {
	case p.Incidents30d == nil:
		none("dora.restore")
	case *p.Incidents30d == 0 || p.RestoreSeconds == nil:
		tiles = append(tiles, tile{Label: l.t("dora.restore"), Value: l.one(l.t("dora.restore.none"), ""),
			Status: statusOK, Word: l.t("status.no-incident"), Accent: true})
		bands = append(bands, bandElite)
	default:
		add(tile{
			Label:   l.t("dora.restore"),
			Value:   l.durationParts(*p.RestoreSeconds),
			Details: []string{l.f("dora.restore.detail", l.thousands(*p.Incidents30d))},
		}, restoreBand(time.Duration(*p.RestoreSeconds)*time.Second))
	}
	return tiles, bands
}

// doraOverall is the overall level of bands, in the colour of its band;
// without it, "No data".
func doraOverall(l *locale, bands []band) overall {
	b := overallBand(bands)
	if b == "" {
		return overall{Status: statusNone, Word: l.t("status.nodata"), NoData: true}
	}
	return overall{Status: bandStatus(b), Word: bandWord(l, b)}
}

// overallTile is the overall level as a tile: the band word as the value,
// its status as the left border.
func overallTile(l *locale, o overall) tile {
	if o.NoData {
		return noDataTile(l, "dora.level")
	}
	return tile{Label: l.t("dora.level"), Value: l.one(o.Word, ""), Status: o.Status, Accent: true}
}

// reworkTile is the rework rate: no band, no status, no part in the
// overall level (requirements.md, 10.9).
func reworkTile(l *locale, p snapshot.Project) tile {
	const label = "dora.rework"
	if p.Rework == nil || p.Rework.Rate == nil {
		return noDataTile(l, label)
	}
	return tile{
		Label:   l.t(label),
		Value:   l.one(l.pct(100**p.Rework.Rate), "unit.percent"),
		Details: []string{l.f("dora.rework.detail", l.thousands(p.Rework.Count), l.thousands(p.Rework.Deploys))},
	}
}

func deliveryTiles(l *locale, p snapshot.Project) []tile {
	ci := noDataTile(l, "delivery.ci")
	if p.CIMedianSeconds30d != nil {
		ci = tile{Label: l.t("delivery.ci"), Value: l.durationParts(*p.CIMedianSeconds30d)}
	}
	renovate := l.t("delivery.renovate")
	return []tile{
		{Label: renovate, Value: l.one(l.pct(p.RenovateShare30d), "unit.percent"),
			Meter: shareBar(l, renovate, p.RenovateShare30d)},
		ci,
	}
}

// signalTiles are the security tiles: the rolling 24 h count with its
// status, its share of the signal's total, the part its detail names, the
// rolling 7 days, the Gateway's unattributed 4xx and the compiled note.
func signalTiles(l *locale, s snapshot.Security) []tile {
	end, _ := snapshot.ParseTime(s.AsOf) // validated
	shown := map[string]snapshot.ShownSignal{}
	for _, sig := range snapshot.ShownSignals() {
		shown[sig.ID] = sig
	}
	out := make([]tile, 0, len(s.Signals))
	for _, sig := range s.Signals {
		c := shown[sig.ID]
		t := tile{Label: l.t("signal." + sig.ID), Spark: sparkBars(l, end, sig.Buckets)}
		if c.Note != "" {
			t.Note = l.t("signal." + sig.ID + ".note")
		}
		t.Status, t.Word = signalStatus(l, c.ExpectedZero, sig.Count24h, sig.Count7d)
		if sig.Count24h != nil {
			t.Value = l.one(l.thousands(*sig.Count24h), "")
			day := l.t("rolling.24h")
			if sig.Share24h != nil && sig.Total24h != nil {
				day = l.f("signal.share", day, l.percent(100**sig.Share24h), l.thousands(*sig.Total24h), l.t("noun."+c.TotalNoun))
			}
			t.Details = append(t.Details, day)
		}
		if sig.Part24h != nil {
			t.Details = append(t.Details, l.f("signal.part", l.thousands(*sig.Part24h), c.PartNoun))
		}
		if sig.Count7d != nil {
			week := l.f("signal.week", l.thousands(*sig.Count7d))
			if sig.Share7d != nil {
				week = l.f("signal.week.share", week, l.percent(100**sig.Share7d))
			}
			t.Details = append(t.Details, week)
		}
		if sig.Unattributed24h != nil && *sig.Unattributed24h > 0 {
			t.Details = append(t.Details, l.f("signal.unattributed", l.thousands(*sig.Unattributed24h)))
		}
		out = append(out, t)
	}
	return out
}

// imageTiles are the first-party images: the SLSA Build level as the value,
// the verification as the status word, the builder as the detail line.
func imageTiles(l *locale, sc snapshot.SupplyChain) []tile {
	workflow := map[string]string{}
	for _, img := range snapshot.ShownImages() {
		workflow[img.Name] = img.Workflow
	}
	out := make([]tile, 0, len(sc.Images))
	for _, img := range sc.Images {
		builder := img.Builder
		if w, ok := workflow[img.Name]; ok {
			builder = l.f("image.builder", w)
		}
		t := tile{Label: img.Name, Details: []string{builder}}
		t.Status, t.Word = provenanceStatus(l, img.Verified)
		if img.Level != nil {
			t.Value = l.one(l.f("image.level", strconv.Itoa(*img.Level)), "")
		}
		out = append(out, t)
	}
	return out
}

// scorecardTiles are the Scorecard score with its status and date.
func scorecardTiles(l *locale, sc snapshot.Scorecard) []tile {
	const label = "scorecard.score"
	if sc.Score == nil {
		return []tile{noDataTile(l, label)}
	}
	t := tile{Label: l.t(label), Value: l.one(l.fixed(*sc.Score, 1), "unit.out-of-10")}
	t.Status, t.Word = scoreStatus(l, sc.Score)
	if sc.Date != nil {
		if d, err := snapshot.ParseTime(*sc.Date); err == nil {
			t.Details = []string{l.f("scorecard.run", l.timeText(d))}
		}
	}
	return []tile{t}
}

// checkNotes are the catalogue keys of the notes that say why a check's
// score is on purpose where Scorecard's reason does not (design.md,
// "Scorecard"). The score and reason stay Scorecard's own.
var checkNotes = map[string]string{
	"Branch-Protection": "check.note.branch-protection",
	"Code-Review":       "check.note.code-review",
	"Contributors":      "check.note.contributors",
	"Signed-Releases":   "check.note.signed-releases",
}

// checkTiles are every Scorecard check in the snapshot's name order, each
// with its score in its status colour, Scorecard's reason, which stays in
// English, and its note.
func checkTiles(l *locale, sc snapshot.Scorecard) []tile {
	out := make([]tile, 0, len(sc.Checks))
	for _, c := range sc.Checks {
		t := tile{Label: c.Name, Details: []string{c.Reason}}
		if k, ok := checkNotes[c.Name]; ok {
			t.Note = l.t(k)
		}
		if l != english {
			t.DetailLang = english.Tag
		}
		t.Status, t.Word = checkStatus(l, c.Score)
		if c.Score != nil {
			t.Value = l.one(strconv.Itoa(*c.Score), "unit.out-of-10")
		}
		out = append(out, t)
	}
	return out
}

func runs(l *locale, rs []snapshot.CIRun) []ciRun {
	out := make([]ciRun, 0, len(rs))
	for _, r := range rs {
		c := ciRun{PR: r.PR, Commit: r.Commit, Duration: l.durationParts(r.DurationSeconds)}
		c.Status, c.Word = runStatus(l, r.Result)
		if t, err := snapshot.ParseTime(r.StartedAt); err == nil {
			c.Started = when{r.StartedAt, l.shortTime(t)}
		}
		out = append(out, c)
	}
	return out
}

// view turns a validated snapshot into the page's data in l at now.
func view(l *locale, s *snapshot.Snapshot, now time.Time) (*pageData, error) {
	d := newPage(l, "title")
	if s == nil {
		return d, nil
	}
	generated, err := at(l, s.GeneratedAt)
	if err != nil {
		return nil, err
	}
	g, _ := snapshot.ParseTime(s.GeneratedAt) // at parsed it
	if now.Sub(g) > liveStaleAfter {
		d.LiveStale = &generated
	}
	f := &figures{
		Generated: generated,
		Certs:     certTiles(l, s.Certificates.Certs),
		RED:       redTiles(l, s.Cluster.Gateway),
		State:     stateTiles(l, s.Cluster),
		Databases: databaseTiles(l, s.Cluster.Databases),
		Engines:   engineTiles(l, s.Cluster.Databases),
		Delivery:  deliveryTiles(l, s.Project),
		Runs:      runs(l, s.Project.CIRuns),
		Signals:   signalTiles(l, s.Security),
		Images:    imageTiles(l, s.SupplyChain),
		Score:     scorecardTiles(l, s.SupplyChain.Scorecard),
		Checks:    checkTiles(l, s.SupplyChain.Scorecard),
	}
	var bands []band
	f.DORA, bands = doraTiles(l, s.Project)
	f.DORALevel = overallTile(l, doraOverall(l, bands))
	f.DORA = append(f.DORA, reworkTile(l, s.Project))
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
		if *b.dst, err = blockAt(l, b.asOf, g, b.after); err != nil {
			return nil, err
		}
	}
	// The Scorecard result is fetched hourly, like the project block.
	if a := s.SupplyChain.Scorecard.AsOf; a != nil {
		b, err := blockAt(l, *a, g, projectStaleAfter)
		if err != nil {
			return nil, err
		}
		f.Scorecard = &b
	}
	for _, a := range s.Availability.Apps {
		f.Apps = append(f.Apps, card(l, a, s.Availability.Days))
	}
	for _, n := range s.Cluster.NodeUse {
		f.Use = append(f.Use, nodeRow(l, n))
	}
	f.Use = append(f.Use, nasRow(l, s.Cluster.NAS))
	d.Figures = f
	return d, nil
}
