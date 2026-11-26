package collector

import (
	"context"
	"fmt"
	"math"
	"slices"
	"time"

	"github.com/ned-si/homelab/dashboard/internal/snapshot"
)

// The cluster queries of version 2 (design.md, "Cadence and sources of the
// redesign"). Each aggregates in PromQL, so no namespace, pod or volume name
// reaches the collector.
const (
	// nodeJoin names each node-exporter series by its node.
	nodeJoin  = ` * on (instance) group_left (nodename) node_uname_info`
	listeners = `envoy_http_conn_manager_prefix=~"listener-secure|listener-insecure"`

	readyQuery = `max by (node) (kube_node_status_condition{condition="Ready", status="true"})`
)

var nodeQueries = []struct {
	figure, expr string
	value        func(float64) float64
	set          func(*snapshot.NodeUse, *float64)
}{
	{"node_use.cpu", `1 - avg by (nodename) (rate(node_cpu_seconds_total{mode="idle"}[5m])` + nodeJoin + `)`,
		snapshot.ToPercent, func(n *snapshot.NodeUse, v *float64) { n.CPU = v }},
	{"node_use.memory", `max by (nodename) ((1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)` + nodeJoin + `)`,
		snapshot.ToPercent, func(n *snapshot.NodeUse, v *float64) { n.Memory = v }},
	{"node_use.disk", `max by (nodename) ((1 - node_filesystem_avail_bytes{mountpoint="/var"} / node_filesystem_size_bytes{mountpoint="/var"})` + nodeJoin + `)`,
		snapshot.ToPercent, func(n *snapshot.NodeUse, v *float64) { n.Disk = v }},
	{"node_use.cpu_pressure", `max by (nodename) (rate(node_pressure_cpu_waiting_seconds_total[5m])` + nodeJoin + `)`,
		snapshot.ToPercent, func(n *snapshot.NodeUse, v *float64) { n.CPUPressure = v }},
	{"node_use.memory_pressure", `max by (nodename) (rate(node_pressure_memory_waiting_seconds_total[5m])` + nodeJoin + `)`,
		snapshot.ToPercent, func(n *snapshot.NodeUse, v *float64) { n.MemoryPressure = v }},
	{"node_use.io_pressure", `max by (nodename) (rate(node_pressure_io_waiting_seconds_total[5m])` + nodeJoin + `)`,
		snapshot.ToPercent, func(n *snapshot.NodeUse, v *float64) { n.IOPressure = v }},
	{"node_use.net_errors_per_second", `sum by (nodename) ((rate(node_network_receive_errs_total[5m]) + rate(node_network_transmit_errs_total[5m]))` + nodeJoin + `)`,
		func(x float64) float64 { return max(0, snapshot.Round(x, 2)) }, func(n *snapshot.NodeUse, v *float64) { n.NetErrorsPerSecond = v }},
}

// optional runs a query whose single value may be missing: nil without a
// series or for NaN (a ratio without requests).
func optional(ctx context.Context, q Querier, figure, expr string, at time.Time) (*float64, error) {
	v, err := query(ctx, q, figure, expr, at)
	if err != nil {
		return nil, err
	}
	if len(v) == 0 || math.IsNaN(float64(v[0].Value)) || math.IsInf(float64(v[0].Value), 0) {
		return nil, nil
	}
	x := float64(v[0].Value)
	return &x, nil
}

// counted is a count that is 0 without a series: count() of nothing is
// empty.
func counted(ctx context.Context, q Querier, figure, expr string, at time.Time) (int, error) {
	v, err := optional(ctx, q, figure, expr, at)
	if err != nil || v == nil {
		return 0, err
	}
	return int(*v), nil
}

func mapped(v *float64, f func(float64) float64) *float64 {
	if v == nil {
		return nil
	}
	x := f(*v)
	return &x
}

func integer(v *float64) *int {
	if v == nil {
		return nil
	}
	n := max(0, int(math.Floor(*v)))
	return &n
}

// use adds the version 2 cluster figures and the databases of version 10 to
// c, whose Nodes and Apps are set.
func use(ctx context.Context, q Querier, at time.Time, c *snapshot.Cluster) error {
	var err error
	if c.Synced, err = counted(ctx, q, "synced", `count(argocd_app_info{sync_status="Synced"})`, at); err != nil {
		return err
	}
	if c.Healthy, err = counted(ctx, q, "healthy", `count(argocd_app_info{health_status="Healthy"})`, at); err != nil {
		return err
	}
	if c.NodeUse, err = nodeUse(ctx, q, at, c.Nodes); err != nil {
		return err
	}
	if c.NAS, err = nas(ctx, q, at); err != nil {
		return err
	}
	if c.Gateway, err = gateway(ctx, q, at); err != nil {
		return err
	}
	restarts, err := optional(ctx, q, "restarts_24h", `sum(increase(kube_pod_container_status_restarts_total[24h]))`, at)
	if err != nil {
		return err
	}
	if restarts == nil {
		return &figureError{"restarts_24h", errEmpty}
	}
	c.Restarts24h = *integer(restarts)
	if c.Volumes, err = volumes(ctx, q, at); err != nil {
		return err
	}
	c.Databases, err = databases(ctx, q, at)
	return err
}

// nodeUse returns one entry per node with a Ready condition, sorted by
// name; there must be nodes of them, as counted by kube_node_info.
func nodeUse(ctx context.Context, q Querier, at time.Time, nodes int) ([]snapshot.NodeUse, error) {
	v, err := query(ctx, q, "node_use.ready", readyQuery, at)
	if err != nil {
		return nil, err
	}
	if len(v) != nodes {
		return nil, &figureError{"node_use.ready", fmt.Errorf("%d nodes with a Ready condition, %d in kube_node_info", len(v), nodes)}
	}
	ready := byLabel(v, "node")
	names := make([]string, 0, len(ready))
	for n := range ready {
		names = append(names, n)
	}
	slices.Sort(names)
	out := make([]snapshot.NodeUse, len(names))
	for i, n := range names {
		out[i] = snapshot.NodeUse{Name: n, Ready: ready[n] == 1}
	}
	for _, nq := range nodeQueries {
		v, err := query(ctx, q, nq.figure, nq.expr, at)
		if err != nil {
			return nil, err
		}
		values := byLabel(v, "nodename")
		for i := range out {
			// No series for a node: its exporter is down, the figure is null.
			if x, ok := values[out[i].Name]; ok && !math.IsNaN(x) {
				nq.set(&out[i], mapped(&x, nq.value))
			}
		}
	}
	return out, nil
}

func nas(ctx context.Context, q Querier, at time.Time) (snapshot.NAS, error) {
	var n snapshot.NAS
	figures := []struct {
		figure, expr string
		set          func(*float64)
	}{
		{"nas.up", `max(truenas_up)`, func(v *float64) { n.Up = v != nil && *v == 1 }},
		{"nas.pool_healthy", `max(truenas_pool_healthy{pool="homelab"})`, func(v *float64) {
			if v != nil {
				healthy := *v == 1
				n.PoolHealthy = &healthy
			}
		}},
		{"nas.pool", `max(nas:pool_used:ratio{pool="homelab"})`, func(v *float64) { n.Pool = mapped(v, snapshot.ToPercent) }},
		{"nas.cpu", `max(truenas_cpu_utilisation_ratio)`, func(v *float64) { n.CPU = mapped(v, snapshot.ToPercent) }},
		{"nas.memory", `max(truenas_memory_used_bytes / truenas_memory_total_bytes)`, func(v *float64) { n.Memory = mapped(v, snapshot.ToPercent) }},
		{"nas.load_per_core", `max(truenas_load1 / truenas_cpu_cores)`, func(v *float64) {
			n.LoadPerCore = mapped(v, func(x float64) float64 { return max(0, snapshot.Round(x, 2)) })
		}},
		{"nas.device_errors", `sum(truenas_pool_device_errors{pool="homelab"})`, func(v *float64) { n.DeviceErrors = integer(v) }},
		{"nas.scrub_errors", `max(truenas_pool_scrub_errors{pool="homelab"})`, func(v *float64) { n.ScrubErrors = integer(v) }},
	}
	for _, f := range figures {
		v, err := optional(ctx, q, f.figure, f.expr, at)
		if err != nil {
			return n, err
		}
		f.set(v)
	}
	return n, nil
}

func gateway(ctx context.Context, q Querier, at time.Time) (snapshot.Gateway, error) {
	var g snapshot.Gateway
	rps, err := optional(ctx, q, "gateway.requests_per_second",
		`sum(rate(envoy_http_downstream_rq_total{`+listeners+`}[5m]))`, at)
	if err != nil {
		return g, err
	}
	g.RequestsPerSecond = mapped(rps, func(x float64) float64 { return max(0, snapshot.Round(x, 2)) })
	if rps == nil || *rps == 0 {
		return g, nil
	}
	errs, err := optional(ctx, q, "gateway.errors_5xx",
		`sum(rate(envoy_http_downstream_rq_xx{envoy_response_code_class="5", `+listeners+`}[5m]))`+
			` / sum(rate(envoy_http_downstream_rq_xx{`+listeners+`}[5m]))`, at)
	if err != nil {
		return g, err
	}
	g.Errors5xx = mapped(errs, snapshot.ToPercent)
	p95, err := optional(ctx, q, "gateway.latency_p95_ms",
		`histogram_quantile(0.95, sum by (le) (rate(envoy_http_downstream_rq_time_bucket{`+listeners+`}[5m])))`, at)
	if err != nil {
		return g, err
	}
	if p95 != nil {
		ms := max(0, int(math.RoundToEven(*p95)))
		g.LatencyP95Ms = &ms
	}
	return g, nil
}

func volumes(ctx context.Context, q Querier, at time.Time) (snapshot.Volumes, error) {
	var v snapshot.Volumes
	count, err := scalar(ctx, q, "volumes.count", `count(kubelet_volume_stats_capacity_bytes)`, at)
	if err != nil {
		return v, err
	}
	v.Count = count
	figures := []struct {
		figure, expr string
		set          func(float64)
	}{
		{"volumes.used_bytes", `sum(kubelet_volume_stats_used_bytes)`, func(x float64) { v.UsedBytes = int64(x) }},
		{"volumes.capacity_bytes", `sum(kubelet_volume_stats_capacity_bytes)`, func(x float64) { v.CapacityBytes = int64(x) }},
		{"volumes.fullest", `max(kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes)`,
			func(x float64) { v.Fullest = snapshot.ToPercent(x) }},
	}
	for _, f := range figures {
		x, err := optional(ctx, q, f.figure, f.expr, at)
		if err != nil {
			return v, err
		}
		if x == nil {
			return v, &figureError{f.figure, errEmpty}
		}
		f.set(*x)
	}
	return v, nil
}
