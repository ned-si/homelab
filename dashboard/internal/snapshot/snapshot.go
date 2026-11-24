// Package snapshot defines snapshot.json, the public figures of the homelab
// dashboard: its types, its embedded JSON Schema, the compiled list of shown
// apps and the checks both roles run on every document
// (.kiro/specs/homelab-dashboard/design.md, "The snapshot").
package snapshot

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/santhosh-tekuri/jsonschema/v6"
	// The binary runs on a distroless base: Europe/Zurich must not depend
	// on the image's zoneinfo.
	_ "time/tzdata"
)

// Version is the schema version this package writes and accepts.
const Version = 3

// MaxSize is the largest snapshot body accepted, in bytes.
const MaxSize = 64 << 10

// DateLayout is the layout of availability.days.
const DateLayout = "2006-01-02"

// Days is the number of daily availability values per app.
const Days = 30

// MaxCIRuns is the number of ci runs on main the project block lists.
const MaxCIRuns = 5

// The states of an app in the availability block.
const (
	StateUp   = "up"
	StateDown = "down"
	StateNone = "none"
)

// ErrNotShown marks a document that names an app outside the shown apps.
var ErrNotShown = errors.New("not the shown apps")

//go:embed snapshot.schema.json
var schemaJSON []byte

// Zurich is the time zone the days are counted in.
var Zurich = mustLoad("Europe/Zurich")

func mustLoad(name string) *time.Location {
	loc, err := time.LoadLocation(name)
	if err != nil {
		// time/tzdata is linked in, so this cannot fail at run time.
		panic(err)
	}
	return loc
}

// Snapshot is the document the collector signs and the web role serves.
type Snapshot struct {
	SchemaVersion int          `json:"schema_version"`
	GeneratedAt   string       `json:"generated_at"`
	Availability  Availability `json:"availability"`
	Certificates  Certificates `json:"certificates"`
	Cluster       Cluster      `json:"cluster"`
	Project       Project      `json:"project"`
}

// Availability is the live availability block: each shown app's state, its
// rolling 30 days ending at AsOf and 30 daily values, the last one today.
type Availability struct {
	AsOf string `json:"as_of"`
	// Days are the 30 Zurich dates of the daily values, oldest first.
	Days []string  `json:"days"`
	Apps []LiveApp `json:"apps"`
}

// LiveApp is one shown app in the availability block. A nil figure has no
// data.
type LiveApp struct {
	ID                      string     `json:"id"`
	Name                    string     `json:"name"`
	State                   string     `json:"state"`
	Availability30d         *float64   `json:"availability_30d"`
	ErrorBudgetRemaining30d *int       `json:"error_budget_remaining_30d"`
	AvailabilityDaily       []*float64 `json:"availability_daily"`
}

// Certificates is the live block of the shown certificates.
type Certificates struct {
	AsOf  string `json:"as_of"`
	Certs []Cert `json:"certs"`
}

// Cert is one shown certificate; DaysLeft is nil without a probe result.
type Cert struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	DaysLeft *int   `json:"days_left"`
}

// Cluster is the live block of cluster facts.
type Cluster struct {
	AsOf              string    `json:"as_of"`
	Nodes             int       `json:"nodes"`
	Apps              int       `json:"apps"`
	TalosVersion      string    `json:"talos_version"`
	KubernetesVersion string    `json:"kubernetes_version"`
	Synced            int       `json:"synced"`
	Healthy           int       `json:"healthy"`
	NodeUse           []NodeUse `json:"node_use"`
	NAS               NAS       `json:"nas"`
	Gateway           Gateway   `json:"gateway"`
	Restarts24h       int       `json:"restarts_24h"`
	Volumes           Volumes   `json:"volumes"`
}

// NodeUse is one node's utilisation, saturation and errors, in percent
// except the errors. A nil figure has no series.
type NodeUse struct {
	Name               string   `json:"name"`
	Ready              bool     `json:"ready"`
	CPU                *float64 `json:"cpu"`
	Memory             *float64 `json:"memory"`
	Disk               *float64 `json:"disk"`
	CPUPressure        *float64 `json:"cpu_pressure"`
	MemoryPressure     *float64 `json:"memory_pressure"`
	IOPressure         *float64 `json:"io_pressure"`
	NetErrorsPerSecond *float64 `json:"net_errors_per_second"`
}

// NAS is the NAS's utilisation, saturation and errors. A nil figure has no
// series.
type NAS struct {
	Up           bool     `json:"up"`
	PoolHealthy  *bool    `json:"pool_healthy"`
	Pool         *float64 `json:"pool"`
	CPU          *float64 `json:"cpu"`
	Memory       *float64 `json:"memory"`
	LoadPerCore  *float64 `json:"load_per_core"`
	DeviceErrors *int     `json:"device_errors"`
	ScrubErrors  *int     `json:"scrub_errors"`
}

// Gateway is the shared Gateway's rate, errors and duration over 5 minutes.
// Errors5xx and LatencyP95Ms are nil without requests.
type Gateway struct {
	RequestsPerSecond *float64 `json:"requests_per_second"`
	Errors5xx         *float64 `json:"errors_5xx"`
	LatencyP95Ms      *int     `json:"latency_p95_ms"`
}

// Volumes sums the persistent volumes; Fullest is the highest used share of
// one volume, in percent, without its name.
type Volumes struct {
	Count         int     `json:"count"`
	UsedBytes     int64   `json:"used_bytes"`
	CapacityBytes int64   `json:"capacity_bytes"`
	Fullest       float64 `json:"fullest"`
}

// Project is the live block of repository figures over the last 30 days.
// The DORA figures are nil until the first refresh with a token.
type Project struct {
	AsOf               string   `json:"as_of"`
	PRsMerged30d       int      `json:"prs_merged_30d"`
	RenovateShare30d   int      `json:"renovate_share_30d"`
	CIMedianSeconds30d int      `json:"ci_median_seconds_30d"`
	Deploys30d         int      `json:"deploys_30d"`
	LeadTimeSeconds    *int     `json:"lead_time_seconds"`
	LeadTimeCount      *int     `json:"lead_time_count"`
	FailedChanges30d   *int     `json:"failed_changes_30d"`
	ChangeFailureRate  *float64 `json:"change_failure_rate"`
	Incidents30d       *int     `json:"incidents_30d"`
	RestoreSeconds     *int     `json:"restore_seconds"`
	CIRuns             []CIRun  `json:"ci_runs"`
}

// The results of a ci run.
const (
	RunSuccess   = "success"
	RunFailure   = "failure"
	RunCancelled = "cancelled"
	RunOther     = "other"
)

// CIRun is one completed run of the ci workflow on main.
type CIRun struct {
	Run             int    `json:"run"`
	Result          string `json:"result"`
	Commit          string `json:"commit"`
	PR              *int   `json:"pr"`
	StartedAt       string `json:"started_at"`
	DurationSeconds int    `json:"duration_seconds"`
}

// FormatTime formats t as the snapshot's timestamps: RFC 3339, second
// precision, Zurich offset.
func FormatTime(t time.Time) string {
	return t.In(Zurich).Truncate(time.Second).Format(time.RFC3339)
}

// ParseTime parses a snapshot timestamp.
func ParseTime(s string) (time.Time, error) {
	return time.Parse(time.RFC3339, s)
}

// ParseDate parses a date of availability.days as midnight in Zurich.
func ParseDate(s string) (time.Time, error) {
	return time.ParseInLocation(DateLayout, s, Zurich)
}

// Day returns the Zurich midnight that starts the day t falls on.
func Day(t time.Time) time.Time {
	l := t.In(Zurich)
	return time.Date(l.Year(), l.Month(), l.Day(), 0, 0, 0, 0, Zurich)
}

// AddDays returns the Zurich midnight n days after the midnight day.
func AddDays(day time.Time, n int) time.Time {
	l := day.In(Zurich)
	return time.Date(l.Year(), l.Month(), l.Day()+n, 0, 0, 0, 0, Zurich)
}

var compiled = sync.OnceValues(func() (*jsonschema.Schema, error) {
	doc, err := jsonschema.UnmarshalJSON(bytes.NewReader(schemaJSON))
	if err != nil {
		return nil, fmt.Errorf("read the schema: %w", err)
	}
	c := jsonschema.NewCompiler()
	if err := c.AddResource("snapshot.schema.json", doc); err != nil {
		return nil, fmt.Errorf("add the schema: %w", err)
	}
	return c.Compile("snapshot.schema.json")
})

// Validate parses body and checks it: the size, the schema, then the rules
// a schema cannot express (the shown apps and certificates in order, no
// hidden app or node, the days ending today, no block newer than
// generated_at, the counts within their totals, the ci runs newest first). An error about the shown names wraps
// ErrNotShown.
func Validate(body []byte) (*Snapshot, error) {
	if len(body) > MaxSize {
		return nil, fmt.Errorf("%d bytes, more than %d", len(body), MaxSize)
	}
	sch, err := compiled()
	if err != nil {
		return nil, err
	}
	inst, err := jsonschema.UnmarshalJSON(bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("parse: %w", err)
	}
	if err := sch.Validate(inst); err != nil {
		return nil, fmt.Errorf("schema: %w", err)
	}
	var s Snapshot
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&s); err != nil {
		return nil, fmt.Errorf("decode: %w", err)
	}
	if err := s.check(); err != nil {
		return nil, err
	}
	return &s, nil
}

func (s *Snapshot) check() error {
	var errs []error
	want := Shown()
	errs = append(errs, checkShown("availability.apps", len(s.Availability.Apps), len(want), func(i int) (string, string) {
		return s.Availability.Apps[i].ID, s.Availability.Apps[i].Name
	}, func(i int) (string, string) { return want[i].ID, want[i].Name })...)
	certs := ShownCerts()
	errs = append(errs, checkShown("certificates.certs", len(s.Certificates.Certs), len(certs), func(i int) (string, string) {
		return s.Certificates.Certs[i].ID, s.Certificates.Certs[i].Name
	}, func(i int) (string, string) { return certs[i].ID, certs[i].Name })...)
	errs = append(errs, s.Cluster.check()...)
	for i := 1; i < len(s.Project.CIRuns); i++ {
		if s.Project.CIRuns[i].Run >= s.Project.CIRuns[i-1].Run {
			errs = append(errs, fmt.Errorf("project.ci_runs[%d] run %d is not older than run %d",
				i, s.Project.CIRuns[i].Run, s.Project.CIRuns[i-1].Run))
		}
	}
	generated, err := ParseTime(s.GeneratedAt)
	if err != nil {
		return errors.Join(append(errs, fmt.Errorf("generated_at: %w", err))...)
	}
	times := []struct{ name, value string }{
		{"availability.as_of", s.Availability.AsOf},
		{"certificates.as_of", s.Certificates.AsOf},
		{"cluster.as_of", s.Cluster.AsOf},
		{"project.as_of", s.Project.AsOf},
	}
	for _, t := range times {
		v, err := ParseTime(t.value)
		if err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", t.name, err))
			continue
		}
		if v.After(generated) {
			errs = append(errs, fmt.Errorf("%s %s is after generated_at %s", t.name, t.value, s.GeneratedAt))
		}
	}
	errs = append(errs, checkDays(s.Availability.Days, Day(generated))...)
	return errors.Join(errs...)
}

// checkShown compares n entries named by got with the m compiled ones named
// by want, in order, and refuses hidden tooling.
func checkShown(block string, n, m int, got, want func(i int) (id, name string)) []error {
	var errs []error
	if n != m {
		errs = append(errs, fmt.Errorf("%w: %s has %d entries, want %d", ErrNotShown, block, n, m))
	}
	for i := range n {
		id, name := got(i)
		if Hidden(id) {
			errs = append(errs, fmt.Errorf("%w: %s[%d] %q is download or indexer tooling", ErrNotShown, block, i, id))
		}
		if i >= m {
			continue
		}
		if wid, wname := want(i); id != wid || name != wname {
			errs = append(errs, fmt.Errorf("%w: %s[%d] is %q (%q), want %q (%q)", ErrNotShown, block, i, id, name, wid, wname))
		}
	}
	return errs
}

// checkDays wants Days consecutive Zurich dates ending on today.
func checkDays(days []string, today time.Time) []error {
	if len(days) != Days {
		return []error{fmt.Errorf("availability.days has %d dates, want %d", len(days), Days)}
	}
	for i, d := range days {
		if want := AddDays(today, i-(Days-1)).Format(DateLayout); d != want {
			return []error{fmt.Errorf("availability.days[%d] is %s, want %s: %d consecutive days ending on %s",
				i, d, want, Days, today.Format(DateLayout))}
		}
	}
	return nil
}

func (c *Cluster) check() []error {
	var errs []error
	if c.Synced > c.Apps || c.Healthy > c.Apps {
		errs = append(errs, fmt.Errorf("cluster: synced %d or healthy %d above apps %d", c.Synced, c.Healthy, c.Apps))
	}
	if len(c.NodeUse) != c.Nodes {
		errs = append(errs, fmt.Errorf("cluster.node_use has %d nodes, want %d", len(c.NodeUse), c.Nodes))
	}
	for i, n := range c.NodeUse {
		if Hidden(n.Name) {
			errs = append(errs, fmt.Errorf("%w: cluster.node_use[%d] %q matches the hidden pattern", ErrNotShown, i, n.Name))
		}
		if i > 0 && n.Name <= c.NodeUse[i-1].Name {
			errs = append(errs, fmt.Errorf("cluster.node_use[%d] %q is not after %q", i, n.Name, c.NodeUse[i-1].Name))
		}
	}
	return errs
}
