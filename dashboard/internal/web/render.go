package web

import (
	"html/template"
	"strconv"
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

type appCard struct {
	Name         string
	Availability string
	Status       status
	Word         string
	NoData       bool
	Since        string
	Exhausted    bool
	BudgetLeft   int
	Meter        template.HTML
	Bars         template.HTML
}

type ciMedian struct {
	Minutes int
	Seconds string
}

type figures struct {
	Covers        when
	DailyStale    bool
	Apps          []appCard
	Cluster       snapshot.Cluster
	ClusterAsOf   when
	Project       snapshot.Project
	ProjectAsOf   when
	RenovateShare template.HTML
	CIMedian      ciMedian
	Generated     when
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

// at formats an RFC 3339 timestamp of the snapshot for a <time> element.
func at(s string) (when, error) {
	t, err := snapshot.ParseTime(s)
	if err != nil {
		return when{}, err
	}
	return when{s, timeText(t)}, nil
}

func median(s int) ciMedian {
	sec := strconv.Itoa(s % 60)
	if s >= 60 && len(sec) == 1 {
		sec = "0" + sec
	}
	return ciMedian{Minutes: s / 60, Seconds: sec}
}

// card builds one app's card from its 30-day figures and daily values.
func card(a snapshot.App, covers time.Time) appCard {
	c := appCard{
		Name:         a.Name,
		Availability: strconv.FormatFloat(a.Availability30d, 'f', 1, 64),
		Bars:         dailyBars(covers, a.AvailabilityDaily),
	}
	first := -1
	for i, v := range a.AvailabilityDaily {
		if v != nil {
			first = i
			break
		}
	}
	switch {
	case first < 0:
		c.Status, c.NoData = statusNone, true
	case first > 0:
		// Under 30 days of data: a 30-day budget would mean nothing yet.
		c.Status = sinceStatus(a.Availability30d)
		c.Since = snapshot.AddDays(covers, -(len(a.AvailabilityDaily) - 1 - first)).Format("2 January")
	default:
		c.Status = monthStatus(a.ErrorBudgetRemaining30d)
		c.BudgetLeft = max(a.ErrorBudgetRemaining30d, 0)
		c.Exhausted = a.ErrorBudgetRemaining30d <= 0
		c.Meter = budgetMeter(a.ErrorBudgetRemaining30d)
	}
	c.Word = monthWord(c.Status)
	return c
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
	clusterAsOf, err := at(s.Cluster.AsOf)
	if err != nil {
		return nil, err
	}
	projectAsOf, err := at(s.Project.AsOf)
	if err != nil {
		return nil, err
	}
	covers, err := snapshot.ParseDate(s.Daily.Covers)
	if err != nil {
		return nil, err
	}
	g, err := snapshot.ParseTime(s.GeneratedAt)
	if err != nil {
		return nil, err
	}
	if now.Sub(g) > liveStaleAfter {
		d.LiveStale = &generated
	}
	f := &figures{
		Covers:        when{s.Daily.Covers, dayText(covers)},
		DailyStale:    covers.Before(snapshot.AddDays(snapshot.Day(now), -dailyStaleDays)),
		Cluster:       s.Cluster,
		ClusterAsOf:   clusterAsOf,
		Project:       s.Project,
		ProjectAsOf:   projectAsOf,
		RenovateShare: shareBar("Opened by Renovate", s.Project.RenovateShare30d),
		CIMedian:      median(s.Project.CIMedianSeconds30d),
		Generated:     generated,
	}
	for _, a := range s.Daily.Apps {
		f.Apps = append(f.Apps, card(a, covers))
	}
	d.Figures = f
	return d, nil
}
