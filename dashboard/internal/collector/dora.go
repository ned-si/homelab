package collector

import (
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"regexp"
	"slices"
	"strings"
	"time"

	promv1 "github.com/prometheus/client_golang/api/prometheus/v1"

	"github.com/ned-si/homelab/dashboard/internal/snapshot"
)

// The DORA figures (requirements.md, Requirement 10).
const (
	// searchCap is the most results GitHub's search returns; above it the
	// figures would undercount, so the refresh fails instead.
	searchCap = 1000
	// syncWithin is how long after its merge a deploying pull request may
	// get its first argocd/* status; later ones are left out for good.
	syncWithin = 24 * time.Hour

	// alertExpr is every firing of a paging alert, one series per alert
	// and target.
	alertExpr  = `max by (alertname, app, namespace, instance) (ALERTS{alertstate="firing", action="human"})`
	alertStep  = 60 * time.Second
	alertSlice = 6 * 24 * time.Hour
	// alertGap ends a firing: two missed evaluations.
	alertGap = 120 * time.Second
)

var (
	revertsRE  = regexp.MustCompile(`This reverts commit ([0-9a-f]{7,40})`)
	revertRE   = regexp.MustCompile(`(?i)^revert`)
	errNoToken = errors.New("the GraphQL API needs a token")
)

// mergedQuery pages through the merged pull requests of the window with
// what the DORA figures need: the labels, whether a file under deploy/ or
// clusters/ changed, and the merge commit's statuses.
const mergedQuery = `query($q: String!, $after: String) {
  search(query: $q, type: ISSUE, first: 100, after: $after) {
    issueCount
    pageInfo { hasNextPage endCursor }
    nodes {
      ... on PullRequest {
        title
        createdAt
        mergedAt
        labels(first: 20) { nodes { name } }
        files(first: 100) { totalCount nodes { path } }
        mergeCommit { oid message status { contexts { context state createdAt } } }
      }
    }
  }
}`

// merged is one merged pull request of the window.
type merged struct {
	title     string
	createdAt time.Time
	mergedAt  time.Time
	labels    []string
	// deploys is true when a file under deploy/ or clusters/ changed.
	deploys bool
	oid     string
	message string
	// synced are the times of the argocd/* success statuses of the merge
	// commit.
	synced []time.Time
}

func (m merged) label(name string) bool {
	return slices.Contains(m.labels, name)
}

func (m merged) rollback() bool {
	return m.label("auto-rollback") || revertRE.MatchString(m.title)
}

func (m merged) failed() bool {
	return m.rollback() || m.label("fix-forward")
}

// syncedAt is when the merge reached the cluster: the first argocd/*
// success within 24 h of the merge, or the merge for a change that deploys
// nothing. It reports false for a deploying merge without such a status.
func (m merged) syncedAt() (time.Time, bool) {
	if !m.deploys {
		return m.mergedAt, true
	}
	var first time.Time
	for _, t := range m.synced {
		if t.Before(m.mergedAt) || t.Sub(m.mergedAt) > syncWithin {
			continue
		}
		if first.IsZero() || t.Before(first) {
			first = t
		}
	}
	return first, !first.IsZero()
}

type graphQLPage struct {
	Data struct {
		Search struct {
			IssueCount int `json:"issueCount"`
			PageInfo   struct {
				HasNextPage bool   `json:"hasNextPage"`
				EndCursor   string `json:"endCursor"`
			} `json:"pageInfo"`
			Nodes []struct {
				Title     string    `json:"title"`
				CreatedAt time.Time `json:"createdAt"`
				MergedAt  time.Time `json:"mergedAt"`
				Labels    struct {
					Nodes []struct {
						Name string `json:"name"`
					} `json:"nodes"`
				} `json:"labels"`
				Files struct {
					TotalCount int `json:"totalCount"`
					Nodes      []struct {
						Path string `json:"path"`
					} `json:"nodes"`
				} `json:"files"`
				MergeCommit *struct {
					OID     string `json:"oid"`
					Message string `json:"message"`
					Status  *struct {
						Contexts []struct {
							Context   string    `json:"context"`
							State     string    `json:"state"`
							CreatedAt time.Time `json:"createdAt"`
						} `json:"contexts"`
					} `json:"status"`
				} `json:"mergeCommit"`
			} `json:"nodes"`
		} `json:"search"`
	} `json:"data"`
	Errors []struct {
		Message string `json:"message"`
	} `json:"errors"`
}

// mergedPRs returns the pull requests merged into main from start, inclusive,
// to end, exclusive, through the GraphQL API, which needs the token.
func (g *GitHub) mergedPRs(ctx context.Context, start, end time.Time) ([]merged, error) {
	token, err := g.token()
	if err != nil {
		return nil, &figureError{"github", err}
	}
	if token == "" {
		return nil, &figureError{"lead_time_seconds", errNoToken}
	}
	search := fmt.Sprintf("repo:%s is:pr is:merged base:%s merged:%s..%s", g.Repo, mergedBase, utc(start), utc(end.Add(-time.Second)))
	var out []merged
	var after *string
	for {
		body, err := json.Marshal(map[string]any{
			"query":     mergedQuery,
			"variables": map[string]any{"q": search, "after": after},
		})
		if err != nil {
			return nil, err
		}
		var page graphQLPage
		if err := g.do(ctx, token, http.MethodPost, "/graphql", body, &page); err != nil {
			return nil, &figureError{"lead_time_seconds", err}
		}
		if len(page.Errors) > 0 {
			return nil, &figureError{"lead_time_seconds", fmt.Errorf("graphql: %s", page.Errors[0].Message)}
		}
		s := page.Data.Search
		if s.IssueCount > searchCap {
			return nil, &figureError{"lead_time_seconds",
				fmt.Errorf("%d pull requests merged, above the search cap of %d", s.IssueCount, searchCap)}
		}
		for _, n := range s.Nodes {
			m := merged{title: n.Title, createdAt: n.CreatedAt, mergedAt: n.MergedAt}
			for _, l := range n.Labels.Nodes {
				m.labels = append(m.labels, l.Name)
			}
			// A pull request with more files than one page counts as deploying.
			m.deploys = n.Files.TotalCount > len(n.Files.Nodes)
			for _, f := range n.Files.Nodes {
				if strings.HasPrefix(f.Path, "deploy/") || strings.HasPrefix(f.Path, "clusters/") {
					m.deploys = true
				}
			}
			if c := n.MergeCommit; c != nil {
				m.oid, m.message = c.OID, c.Message
				if c.Status != nil {
					for _, st := range c.Status.Contexts {
						if strings.HasPrefix(st.Context, "argocd/") && st.State == "SUCCESS" {
							m.synced = append(m.synced, st.CreatedAt)
						}
					}
				}
			}
			out = append(out, m)
		}
		if !s.PageInfo.HasNextPage {
			return out, nil
		}
		after = &s.PageInfo.EndCursor
	}
}

// interval is one incident, or one firing before the merge.
type interval struct {
	start, end time.Time
	// open is true for a firing still going on at the end of the window.
	open bool
}

// alertFirings reads the paging alerts' firings from start to end: a range
// query in slices of 6 days (8641 points each, under Prometheus's 11,000),
// a gap of more than 120 s ending a firing.
func alertFirings(ctx context.Context, q Querier, start, end time.Time) ([]interval, error) {
	samples := map[string][]time.Time{}
	for s := start; s.Before(end); s = s.Add(alertSlice) {
		e := s.Add(alertSlice)
		if e.After(end) {
			e = end
		}
		r := promv1.Range{Start: s, End: e, Step: alertStep}
		m, err := q.QueryRange(ctx, alertExpr, r)
		if err != nil {
			return nil, &figureError{"restore_seconds", err}
		}
		for _, series := range m {
			k := series.Metric.String()
			for _, v := range series.Values {
				samples[k] = append(samples[k], v.Timestamp.Time())
			}
		}
	}
	var out []interval
	for _, ts := range samples {
		slices.SortFunc(ts, func(a, b time.Time) int { return a.Compare(b) })
		// Adjacent slices share their boundary sample.
		ts = slices.CompactFunc(ts, func(a, b time.Time) bool { return a.Equal(b) })
		cur := interval{start: ts[0], end: ts[0]}
		for _, t := range ts[1:] {
			if t.Sub(cur.end) > alertGap {
				out = append(out, cur)
				cur = interval{start: t, end: t}
				continue
			}
			cur.end = t
		}
		cur.open = end.Sub(cur.end) <= alertGap
		out = append(out, cur)
	}
	return out, nil
}

// mergeIntervals merges the overlapping intervals, so an outage that pages
// and is reverted counts once.
func mergeIntervals(in []interval) []interval {
	s := slices.Clone(in)
	slices.SortFunc(s, func(a, b interval) int { return cmp.Or(a.start.Compare(b.start), a.end.Compare(b.end)) })
	var out []interval
	for _, i := range s {
		if n := len(out); n > 0 && !i.start.After(out[n-1].end) {
			if i.end.After(out[n-1].end) {
				out[n-1].end = i.end
			}
			out[n-1].open = out[n-1].open || i.open
			continue
		}
		out = append(out, i)
	}
	return out
}

func medianSeconds(ds []time.Duration) int {
	xs := make([]float64, len(ds))
	for i, d := range ds {
		xs[i] = d.Seconds()
	}
	return int(math.RoundToEven(snapshot.Median(xs)))
}

// setDORA sets the DORA figures of p, whose Deploys30d is set, from the
// pull requests merged and the alert firings of the window start..end.
func setDORA(p *snapshot.Project, prs []merged, firings []interval, start, end time.Time) {
	var leads []time.Duration
	failed := 0
	byOID := map[string]merged{}
	for _, m := range prs {
		if m.oid != "" {
			byOID[m.oid] = m
		}
	}
	incidents := slices.Clone(firings)
	for _, m := range prs {
		synced, ok := m.syncedAt()
		if ok {
			leads = append(leads, synced.Sub(m.createdAt))
		}
		if m.failed() {
			failed++
		}
		if !m.rollback() || !ok {
			continue
		}
		// From the merge of the reverted change, or the revert's creation
		// when its message names none in the window.
		from := m.createdAt
		if r := revertsRE.FindStringSubmatch(m.message); r != nil {
			for oid, reverted := range byOID {
				if strings.HasPrefix(oid, r[1]) {
					from = reverted.mergedAt
					break
				}
			}
		}
		if from.After(synced) {
			from = synced
		}
		incidents = append(incidents, interval{start: from, end: synced})
	}

	n := len(leads)
	p.LeadTimeCount = &n
	p.LeadTimeSeconds = nil
	if n > 0 {
		s := medianSeconds(leads)
		p.LeadTimeSeconds = &s
	}
	p.FailedChanges30d = &failed
	p.ChangeFailureRate = nil
	if p.Deploys30d > 0 {
		rate := min(100, snapshot.Round(100*float64(failed)/float64(p.Deploys30d), 1))
		p.ChangeFailureRate = &rate
	}
	var restore []time.Duration
	for _, i := range mergeIntervals(incidents) {
		if !i.open && !i.end.Before(start) && i.end.Before(end) {
			restore = append(restore, i.end.Sub(i.start))
		}
	}
	count := len(restore)
	p.Incidents30d = &count
	p.RestoreSeconds = nil
	if count > 0 {
		s := medianSeconds(restore)
		p.RestoreSeconds = &s
	}
}

// keepDORA copies the DORA figures of the last block, kept between
// refreshes without a token.
func keepDORA(p, last *snapshot.Project) {
	p.LeadTimeSeconds = last.LeadTimeSeconds
	p.LeadTimeCount = last.LeadTimeCount
	p.FailedChanges30d = last.FailedChanges30d
	p.ChangeFailureRate = last.ChangeFailureRate
	p.Incidents30d = last.Incidents30d
	p.RestoreSeconds = last.RestoreSeconds
}
