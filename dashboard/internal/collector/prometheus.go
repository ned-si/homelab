package collector

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/prometheus/client_golang/api"
	promv1 "github.com/prometheus/client_golang/api/prometheus/v1"
	"github.com/prometheus/common/model"

	"github.com/ned-si/homelab/dashboard/internal/snapshot"
)

// Querier runs PromQL queries.
type Querier interface {
	// Query runs an instant query at at.
	Query(ctx context.Context, query string, at time.Time) (model.Vector, error)
	// QueryRange runs a range query.
	QueryRange(ctx context.Context, query string, r promv1.Range) (model.Matrix, error)
}

type promClient struct {
	api promv1.API
}

// NewPrometheus returns a Querier for the Prometheus HTTP API at url.
func NewPrometheus(url string) (Querier, error) {
	c, err := api.NewClient(api.Config{Address: url})
	if err != nil {
		return nil, fmt.Errorf("prometheus client: %w", err)
	}
	return &promClient{api: promv1.NewAPI(c)}, nil
}

func (p *promClient) Query(ctx context.Context, query string, at time.Time) (model.Vector, error) {
	ctx, cancel := context.WithTimeout(ctx, HTTPTimeout)
	defer cancel()
	v, _, _, err := p.api.Query(ctx, query, at)
	if err != nil {
		return nil, err
	}
	vec, ok := v.(model.Vector)
	if !ok {
		return nil, fmt.Errorf("result type %s, want vector", v.Type())
	}
	return vec, nil
}

func (p *promClient) QueryRange(ctx context.Context, query string, r promv1.Range) (model.Matrix, error) {
	ctx, cancel := context.WithTimeout(ctx, HTTPTimeout)
	defer cancel()
	v, _, _, err := p.api.QueryRange(ctx, query, r)
	if err != nil {
		return nil, err
	}
	m, ok := v.(model.Matrix)
	if !ok {
		return nil, fmt.Errorf("result type %s, want matrix", v.Type())
	}
	return m, nil
}

// figureError names the figure a query failed for.
type figureError struct {
	figure string
	err    error
}

func (e *figureError) Error() string { return e.figure + ": " + e.err.Error() }
func (e *figureError) Unwrap() error { return e.err }

var errEmpty = errors.New("empty result")

var versionRE = regexp.MustCompile(`v\d+\.\d+\.\d+`)

func query(ctx context.Context, q Querier, figure, expr string, at time.Time) (model.Vector, error) {
	v, err := q.Query(ctx, expr, at)
	if err != nil {
		return nil, &figureError{figure, err}
	}
	return v, nil
}

func scalar(ctx context.Context, q Querier, figure, expr string, at time.Time) (int, error) {
	v, err := query(ctx, q, figure, expr, at)
	if err != nil {
		return 0, err
	}
	if len(v) == 0 {
		return 0, &figureError{figure, errEmpty}
	}
	return int(v[0].Value), nil
}

// lowestVersion returns the lowest vX.Y.Z found in label: mid-upgrade the
// nodes disagree, and the lowest is what the whole cluster runs.
func lowestVersion(ctx context.Context, q Querier, figure, label string, at time.Time) (string, error) {
	v, err := query(ctx, q, figure, fmt.Sprintf("count by (%s) (kube_node_info)", label), at)
	if err != nil {
		return "", err
	}
	var found [][3]int
	for _, s := range v {
		raw := string(s.Metric[model.LabelName(label)])
		m := versionRE.FindString(raw)
		if m == "" {
			return "", &figureError{figure, fmt.Errorf("no version in %s %q", label, raw)}
		}
		var parts [3]int
		for i, p := range strings.Split(m[1:], ".") {
			parts[i], _ = strconv.Atoi(p) // the regexp guarantees digits
		}
		found = append(found, parts)
	}
	if len(found) == 0 {
		return "", &figureError{figure, errEmpty}
	}
	low := slices.MinFunc(found, func(a, b [3]int) int {
		return cmp.Or(cmp.Compare(a[0], b[0]), cmp.Compare(a[1], b[1]), cmp.Compare(a[2], b[2]))
	})
	return fmt.Sprintf("v%d.%d.%d", low[0], low[1], low[2]), nil
}

// cluster reads the cluster facts at at, those of version 1 and the USE and
// RED figures.
func cluster(ctx context.Context, q Querier, at time.Time) (snapshot.Cluster, error) {
	var c snapshot.Cluster
	var err error
	if c.Nodes, err = scalar(ctx, q, "nodes", "count(kube_node_info)", at); err != nil {
		return c, err
	}
	if c.Apps, err = scalar(ctx, q, "apps", "count(argocd_app_info)", at); err != nil {
		return c, err
	}
	if c.TalosVersion, err = lowestVersion(ctx, q, "talos_version", "os_image", at); err != nil {
		return c, err
	}
	if c.KubernetesVersion, err = lowestVersion(ctx, q, "kubernetes_version", "kubelet_version", at); err != nil {
		return c, err
	}
	if err := use(ctx, q, at, &c); err != nil {
		return c, err
	}
	c.AsOf = snapshot.FormatTime(at)
	return c, nil
}

func byApp(v model.Vector) map[string]float64 {
	return byLabel(v, "app")
}

func byLabel(v model.Vector, label model.LabelName) map[string]float64 {
	out := make(map[string]float64, len(v))
	for _, s := range v {
		out[string(s.Metric[label])] = float64(s.Value)
	}
	return out
}

// sloSelector is the matcher of the shown apps' SLO series.
func sloSelector() string {
	shown := snapshot.Shown()
	labels := make([]string, len(shown))
	for i, a := range shown {
		labels[i] = a.SLOApp
	}
	return `{app=~"` + strings.Join(labels, "|") + `"}`
}
