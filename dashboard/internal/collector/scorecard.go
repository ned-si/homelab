package collector

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/ned-si/homelab/dashboard/internal/snapshot"
)

// ScorecardURL is the repository's result in the public OpenSSF Scorecard
// API (design.md, "Scorecard (task 24)").
const ScorecardURL = "https://api.securityscorecards.dev/projects/github.com/ned-si/homelab"

// scorecardEvery is how often the result is fetched: Scorecard runs on a
// push to main and weekly, so an hour is never far behind.
const scorecardEvery = time.Hour

// scorecardHosts are the hosts a redirect of the Scorecard API may lead to:
// the API under both its names.
var scorecardHosts = []string{"api.securityscorecards.dev", "api.scorecard.dev"}

// maxScorecardBody bounds the answer read; a result with every check's
// details is about 16 KiB.
const maxScorecardBody = 1 << 20

// ScorecardRedirect is the CheckRedirect of the Scorecard client: https to
// a Scorecard host only.
func ScorecardRedirect(req *http.Request, via []*http.Request) error {
	if req.URL.Scheme != "https" || !slices.Contains(scorecardHosts, req.URL.Hostname()) {
		return fmt.Errorf("redirect to %s refused", req.URL.Redacted())
	}
	if len(via) >= 10 {
		return errors.New("stopped after 10 redirects")
	}
	return nil
}

// Scorecard reads the repository's latest result from the Scorecard API,
// without a token.
type Scorecard struct {
	// URL is the project's result, ScorecardURL in production.
	URL string
	// UserAgent identifies the app and its version.
	UserAgent string
	// Client makes the call; its Timeout bounds it, its CheckRedirect is
	// ScorecardRedirect.
	Client *http.Client
}

type scorecardResult struct {
	Date   string   `json:"date"`
	Score  *float64 `json:"score"`
	Checks []struct {
		Name   string `json:"name"`
		Score  int    `json:"score"`
		Reason string `json:"reason"`
	} `json:"checks"`
}

// Result fetches the result at now: its score to one decimal, its date and
// every check in name order, an inconclusive one (score -1) without a
// score. A check with a name outside the compiled list or named twice, a
// score outside -1 to 10 or a reason that is not plain text is dropped,
// and dropped counts them.
func (s *Scorecard) Result(ctx context.Context, now time.Time) (sc snapshot.Scorecard, dropped int, err error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.URL, nil)
	if err != nil {
		return sc, 0, err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", s.UserAgent)
	resp, err := s.Client.Do(req)
	if err != nil {
		return sc, 0, err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return sc, 0, fmt.Errorf("scorecard: %s", resp.Status)
	}
	var r scorecardResult
	if err := json.NewDecoder(io.LimitReader(resp.Body, maxScorecardBody)).Decode(&r); err != nil {
		return sc, 0, fmt.Errorf("scorecard: decode: %w", err)
	}
	if r.Score == nil || *r.Score < 0 || *r.Score > 10 {
		return sc, 0, errors.New("scorecard: no score from 0 to 10")
	}
	date, err := time.Parse(time.RFC3339, r.Date)
	if err != nil {
		return sc, 0, fmt.Errorf("scorecard: date: %w", err)
	}
	checks := []snapshot.ScorecardCheck{}
	for _, c := range r.Checks {
		if !snapshot.ScorecardCheckShown(c.Name) || c.Score < -1 || c.Score > 10 || !snapshot.PlainReason(c.Reason) ||
			slices.ContainsFunc(checks, func(k snapshot.ScorecardCheck) bool { return k.Name == c.Name }) {
			dropped++
			continue
		}
		k := snapshot.ScorecardCheck{Name: c.Name, Reason: c.Reason}
		if c.Score >= 0 {
			k.Score = &c.Score
		}
		checks = append(checks, k)
	}
	slices.SortFunc(checks, func(a, b snapshot.ScorecardCheck) int { return strings.Compare(a.Name, b.Name) })
	score := snapshot.Round(*r.Score, 1)
	asOf, d := snapshot.FormatTime(now), snapshot.FormatTime(date)
	return snapshot.Scorecard{
		AsOf:   &asOf,
		Score:  &score,
		Date:   &d,
		Checks: checks,
	}, dropped, nil
}

// noScorecard is the result before the first fetch.
func noScorecard() snapshot.Scorecard {
	return snapshot.Scorecard{Checks: []snapshot.ScorecardCheck{}}
}
