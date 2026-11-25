package collector

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/ned-si/homelab/dashboard/internal/snapshot"
)

// ciPages is how many pages of 100 workflow runs the CI median reads.
const ciPages = 3

// mergedBase is the branch a pull request counts for once merged into.
const mergedBase = "main"

// ErrTokenRejected is returned when GitHub answers 401 to the token.
var ErrTokenRejected = errors.New("github token rejected")

// RateLimitError is returned on a 403 or 429 with no calls left.
type RateLimitError struct {
	// Reset is when GitHub resets the quota.
	Reset time.Time
}

func (e *RateLimitError) Error() string {
	return "github rate limit exhausted until " + e.Reset.UTC().Format(time.RFC3339)
}

// GitHub reads the project figures from the public GitHub API.
type GitHub struct {
	// BaseURL is the API root, https://api.github.com in production.
	BaseURL string
	// Repo is owner/name.
	Repo string
	// Workflow is the file name of the CI workflow.
	Workflow string
	// TokenFile holds the token; a missing file means anonymous calls.
	TokenFile string
	// UserAgent identifies the app and its version.
	UserAgent string
	// Client makes the calls; its Timeout bounds each one.
	Client *http.Client
	// Remaining, when set, receives X-RateLimit-Remaining of every answer.
	Remaining func(n int)
}

// token reads the token file; an absent file is no token.
func (g *GitHub) token() (string, error) {
	if g.TokenFile == "" {
		return "", nil
	}
	b, err := os.ReadFile(g.TokenFile)
	if errors.Is(err, fs.ErrNotExist) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("read the token: %w", err)
	}
	return strings.TrimSpace(string(b)), nil
}

// HasToken reports whether a token is configured.
func (g *GitHub) HasToken() bool {
	t, err := g.token()
	return err == nil && t != ""
}

func (g *GitHub) get(ctx context.Context, token, path string, out any) error {
	return g.do(ctx, token, http.MethodGet, path, nil, out)
}

func (g *GitHub) do(ctx context.Context, token, method, path string, body []byte, out any) error {
	var rd io.Reader
	if body != nil {
		rd = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, g.BaseURL+path, rd)
	if err != nil {
		return err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", g.UserAgent)
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := g.Client.Do(req)
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	remaining, rerr := strconv.Atoi(resp.Header.Get("X-RateLimit-Remaining"))
	if rerr == nil && g.Remaining != nil {
		g.Remaining(remaining)
	}
	switch {
	case resp.StatusCode == http.StatusUnauthorized && token != "":
		return ErrTokenRejected
	case (resp.StatusCode == http.StatusForbidden || resp.StatusCode == http.StatusTooManyRequests) &&
		rerr == nil && remaining == 0:
		reset, err := strconv.ParseInt(resp.Header.Get("X-RateLimit-Reset"), 10, 64)
		if err != nil {
			return fmt.Errorf("status %d, rate limited without a reset time", resp.StatusCode)
		}
		return &RateLimitError{Reset: time.Unix(reset, 0)}
	case resp.StatusCode != http.StatusOK:
		return fmt.Errorf("status %d", resp.StatusCode)
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 4<<20)).Decode(out); err != nil {
		return fmt.Errorf("decode: %w", err)
	}
	return nil
}

func utc(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05Z")
}

func (g *GitHub) mergedCount(ctx context.Context, token, figure, span, extra string) (int, error) {
	q := url.Values{
		"q":        {fmt.Sprintf("repo:%s is:pr is:merged base:%s merged:%s%s", g.Repo, mergedBase, span, extra)},
		"per_page": {"1"},
	}
	var r struct {
		TotalCount        int  `json:"total_count"`
		IncompleteResults bool `json:"incomplete_results"`
	}
	if err := g.get(ctx, token, "/search/issues?"+q.Encode(), &r); err != nil {
		return 0, &figureError{figure, err}
	}
	if r.IncompleteResults {
		return 0, &figureError{figure, errors.New("GitHub search returned incomplete results")}
	}
	return r.TotalCount, nil
}

// Project reads the figures from start, inclusive, to end, exclusive: pull
// requests merged into main (the deploys), Renovate's share of them, the
// median wall time of the successful CI runs and the last CI runs on main.
// The search API's total_count is exact, so no page limit applies to the
// counts. The DORA figures that need the GraphQL API are left nil.
func (g *GitHub) Project(ctx context.Context, start, end time.Time) (snapshot.Project, error) {
	var p snapshot.Project
	token, err := g.token()
	if err != nil {
		return p, &figureError{"github", err}
	}
	span := utc(start) + ".." + utc(end.Add(-time.Second))
	if p.PRsMerged30d, err = g.mergedCount(ctx, token, "prs_merged_30d", span, ""); err != nil {
		return p, err
	}
	renovate, err := g.mergedCount(ctx, token, "renovate_share_30d", span, " author:app/renovate")
	if err != nil {
		return p, err
	}
	p.RenovateShare30d = snapshot.SharePercent(renovate, p.PRsMerged30d)

	var walls []float64
	for page := 1; page <= ciPages; page++ {
		q := url.Values{
			"status":                {"success"},
			"created":               {span},
			"per_page":              {"100"},
			"page":                  {strconv.Itoa(page)},
			"exclude_pull_requests": {"true"},
		}
		var r struct {
			WorkflowRuns []struct {
				RunStartedAt string `json:"run_started_at"`
				UpdatedAt    string `json:"updated_at"`
			} `json:"workflow_runs"`
		}
		path := fmt.Sprintf("/repos/%s/actions/workflows/%s/runs?%s", g.Repo, g.Workflow, q.Encode())
		if err := g.get(ctx, token, path, &r); err != nil {
			return p, &figureError{"ci_median_seconds_30d", err}
		}
		for _, run := range r.WorkflowRuns {
			if run.RunStartedAt == "" {
				continue
			}
			started, err1 := time.Parse(time.RFC3339, run.RunStartedAt)
			updated, err2 := time.Parse(time.RFC3339, run.UpdatedAt)
			if err := errors.Join(err1, err2); err != nil {
				return p, &figureError{"ci_median_seconds_30d", err}
			}
			walls = append(walls, updated.Sub(started).Seconds())
		}
		if len(r.WorkflowRuns) < 100 {
			break
		}
	}
	if len(walls) == 0 {
		return p, &figureError{"ci_median_seconds_30d", errors.New("no successful run in the window")}
	}
	p.CIMedianSeconds30d = snapshot.RoundSeconds(snapshot.Median(walls))
	p.Deploys30d = p.PRsMerged30d
	if p.CIRuns, err = g.ciRuns(ctx, token); err != nil {
		return p, err
	}
	p.AsOf = snapshot.FormatTime(end)
	return p, nil
}

// prRE finds the pull request number GitHub appends to a merged title.
var prRE = regexp.MustCompile(`\(#(\d+)\)`)

// ciRuns returns the last completed runs of the CI workflow on main, newest
// first.
func (g *GitHub) ciRuns(ctx context.Context, token string) ([]snapshot.CIRun, error) {
	q := url.Values{
		"branch":                {mergedBase},
		"event":                 {"push"},
		"status":                {"completed"},
		"per_page":              {strconv.Itoa(snapshot.MaxCIRuns)},
		"exclude_pull_requests": {"true"},
	}
	var r struct {
		WorkflowRuns []struct {
			RunNumber    int    `json:"run_number"`
			Conclusion   string `json:"conclusion"`
			HeadSHA      string `json:"head_sha"`
			RunStartedAt string `json:"run_started_at"`
			UpdatedAt    string `json:"updated_at"`
			HeadCommit   struct {
				Message string `json:"message"`
			} `json:"head_commit"`
		} `json:"workflow_runs"`
	}
	path := fmt.Sprintf("/repos/%s/actions/workflows/%s/runs?%s", g.Repo, g.Workflow, q.Encode())
	if err := g.get(ctx, token, path, &r); err != nil {
		return nil, &figureError{"ci_runs", err}
	}
	runs := []snapshot.CIRun{}
	for _, run := range r.WorkflowRuns {
		if len(runs) == snapshot.MaxCIRuns {
			break
		}
		started, err1 := time.Parse(time.RFC3339, run.RunStartedAt)
		updated, err2 := time.Parse(time.RFC3339, run.UpdatedAt)
		if err := errors.Join(err1, err2); err != nil {
			return nil, &figureError{"ci_runs", err}
		}
		if len(run.HeadSHA) < 7 {
			return nil, &figureError{"ci_runs", fmt.Errorf("run %d: head_sha %q", run.RunNumber, run.HeadSHA)}
		}
		c := snapshot.CIRun{
			Run:             run.RunNumber,
			Result:          result(run.Conclusion),
			Commit:          strings.ToLower(run.HeadSHA[:7]),
			StartedAt:       snapshot.FormatTime(started),
			DurationSeconds: min(86400, max(0, int(updated.Sub(started).Seconds()))),
		}
		title, _, _ := strings.Cut(run.HeadCommit.Message, "\n")
		if m := prRE.FindAllStringSubmatch(title, -1); m != nil {
			if n, err := strconv.Atoi(m[len(m)-1][1]); err == nil && n > 0 {
				c.PR = &n
			}
		}
		runs = append(runs, c)
	}
	return runs, nil
}

func result(conclusion string) string {
	switch conclusion {
	case snapshot.RunSuccess, snapshot.RunFailure, snapshot.RunCancelled:
		return conclusion
	}
	return snapshot.RunOther
}
