package web

import (
	"bytes"
	"fmt"
	"html"
	"html/template"
	"strconv"
	"strings"
	"time"

	"github.com/ned-si/homelab/dashboard/internal/snapshot"
)

// liveStaleAfter is how old the live figures may be before the page says so.
const liveStaleAfter = 5 * time.Minute

// dailyStaleDays is how many days before today daily.covers may be before
// the page says the daily update is failing.
const dailyStaleDays = 2

type when struct {
	Datetime string
	Text     string
}

type appRow struct {
	Name         string
	Availability string
	Since        string
	Budget       string
	Spark        template.HTML
}

type figures struct {
	Covers     when
	DailyStale bool
	Apps       []appRow
	Cluster    snapshot.Cluster
	Project    snapshot.Project
	CIMedian   string
	Generated  when
}

type pageData struct {
	Title        string
	CSS          string
	CSSIntegrity string
	LiveStale    *when
	Figures      *figures
}

func dayText(t time.Time) string {
	return t.In(snapshot.Zurich).Format("2 January 2006")
}

func timeText(t time.Time) string {
	return t.In(snapshot.Zurich).Format("2 January 2006, 15:04")
}

func duration(s int) string {
	if s >= 60 {
		return fmt.Sprintf("%d min %02d s", s/60, s%60)
	}
	return fmt.Sprintf("%d s", s)
}

// view turns a validated snapshot into the page's data at now.
func view(s *snapshot.Snapshot, now time.Time) (*pageData, error) {
	d := &pageData{Title: "Homelab"}
	if s == nil {
		return d, nil
	}
	generated, err := snapshot.ParseTime(s.GeneratedAt)
	if err != nil {
		return nil, err
	}
	covers, err := snapshot.ParseDate(s.Daily.Covers)
	if err != nil {
		return nil, err
	}
	if now.Sub(generated) > liveStaleAfter {
		d.LiveStale = &when{s.GeneratedAt, timeText(generated)}
	}
	f := &figures{
		Covers:     when{s.Daily.Covers, dayText(covers)},
		DailyStale: covers.Before(snapshot.AddDays(snapshot.Day(now), -dailyStaleDays)),
		Cluster:    s.Cluster,
		Project:    s.Project,
		CIMedian:   duration(s.Project.CIMedianSeconds30d),
		Generated:  when{s.GeneratedAt, timeText(generated)},
	}
	for _, a := range s.Daily.Apps {
		row := appRow{
			Name:         a.Name,
			Availability: strconv.FormatFloat(a.Availability30d, 'f', 1, 64) + "%",
			Spark:        sparkline(a.AvailabilityDaily),
		}
		first := len(a.AvailabilityDaily)
		for i, v := range a.AvailabilityDaily {
			if v != nil {
				first = i
				break
			}
		}
		switch {
		case first > 0:
			// Under 30 days of data: a 30-day budget would mean nothing yet.
			since := snapshot.AddDays(covers, -(len(a.AvailabilityDaily) - 1 - first))
			row.Since = since.Format("2 January")
		case a.ErrorBudgetRemaining30d <= -100:
			row.Budget = "exhausted"
		default:
			row.Budget = strconv.Itoa(a.ErrorBudgetRemaining30d) + "%"
		}
		f.Apps = append(f.Apps, row)
	}
	d.Figures = f
	return d, nil
}

func coord(v float64) string {
	return strconv.FormatFloat(v, 'f', 1, 64)
}

// sparkline draws the daily values as inline SVG, 90 % at the bottom, with
// a gap for a day without probes. Only numbers go in: every attribute is a
// formatted float, and the label is escaped.
func sparkline(values []*float64) template.HTML {
	const w, h, floor = 120, 24, 90.0
	step := float64(w) / float64(snapshot.Days-1)
	y := func(v float64) string {
		return coord(h - (max(v, floor)-floor)/(100-floor)*h)
	}
	var marks strings.Builder
	var run [][2]string
	flush := func() {
		switch {
		case len(run) == 1:
			fmt.Fprintf(&marks, `<circle cx="%s" cy="%s" r="1.5"/>`, run[0][0], run[0][1])
		case len(run) > 1:
			pts := make([]string, len(run))
			for i, p := range run {
				pts[i] = p[0] + "," + p[1]
			}
			fmt.Fprintf(&marks, `<polyline points="%s"/>`, strings.Join(pts, " "))
		}
		run = run[:0]
	}
	lowest, seen := 100.0, false
	for i, v := range values {
		if v == nil {
			flush()
			continue
		}
		run = append(run, [2]string{coord(float64(i) * step), y(*v)})
		lowest, seen = min(lowest, *v), true
	}
	flush()
	label := "No daily values yet"
	if seen {
		label = "Daily availability, lowest " + coord(lowest) + "%"
	}
	target := y(99.5)
	var b bytes.Buffer
	fmt.Fprintf(&b, `<svg class="spark" viewBox="0 0 %d %d" width="%d" height="%d" role="img" aria-label="%s">`,
		w, h, w, h, html.EscapeString(label))
	fmt.Fprintf(&b, `<line class="target" x1="0" y1="%s" x2="%d" y2="%s"/>`, target, w, target)
	b.WriteString(marks.String())
	b.WriteString("</svg>")
	//nolint:gosec // G203: built from formatted numbers and an escaped label only; TestSparklineMarkup checks it.
	return template.HTML(b.String())
}
