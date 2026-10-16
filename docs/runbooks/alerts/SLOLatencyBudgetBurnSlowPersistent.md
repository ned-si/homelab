# SLOLatencyBudgetBurnSlowPersistent

`warning`, pages, one per app. Rule: [`platform/kube-prometheus-stack/routes/slo.yaml`](../../../platform/kube-prometheus-stack/routes/slo.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

`SLOLatencyBudgetBurnSlow` has fired for `app` for 24 hours: more than 1% of
its public probes answer slower than its threshold
(`slo:latency_threshold_seconds`), while the app is up (an availability burn
of the same app silences the latency alerts). The app works but is slow, and
nothing automatic fixes that.

## Confirm

```sh
q 'slo:latency_threshold_seconds{app="<app>"}'
q 'slo:probe_slow:ratio_rate1d{app="<app>"}'
q 'slo:latency_budget_remaining:ratio_rate30d{app="<app>"}'
q 'quantile_over_time(0.95, probe_duration_seconds{job="blackbox-public", app="<app>"}[1d])'
q 'max_over_time(probe_http_duration_seconds{job="blackbox-public", app="<app>"}[1h])'
```

Expected while it fires: the threshold (0.25 s today), a slow share above
0.03 over the day, the remaining latency budget falling, a p95 above the
threshold, and the probe phase (`resolve`, `connect`, `tls`, `processing`,
`transfer`) that takes the time.

## Fix

1. `processing` dominates: the app itself. CPU throttling
   (`q 'rate(container_cpu_cfs_throttled_periods_total{namespace="<namespace>"}[1h])'`),
   memory pressure or restarts
   (`kubectl -n <namespace> describe pod <pod> | grep -A5 'Last State'`);
   raise the limit in git, or fix the slow query in the app.
2. Slow storage: the NAS (Homelab / Storage, NAS latency) or a nearly full
   volume ([PersistentVolumeNearlyFull](PersistentVolumeNearlyFull.md)).
3. `resolve` dominates: DNS, CoreDNS in the cluster then the router's
   forwarder (`kubectl -n kube-system logs -l k8s-app=kube-dns --tail=50`).
4. `connect` or `tls` dominates: the Gateway or a node (Homelab / Network,
   Homelab / Nodes); one node slower than the others points at that node.
5. Slow at the same time every day: a backup or CronJob competing for the
   app's volume ([backups.md: Schedule](../../backups.md#schedule)).
6. The app got slower for good after an update and the new speed is
   acceptable: recompute the threshold with
   `scripts/slo-latency-thresholds.sh` and change it in `slo.yaml` in a pull
   request, with the output in its description.

## Resolved when

`slo:probe_slow:ratio_rate1d{app="<app>"}` is back under 0.03 and the 6h
ratio under 0.01; the slow burn clears, then this alert. Not rehearsed.

## Links

- [sre.md: Latency](../../sre.md#latency)
- [observability.md: SLOs](../../observability.md#slos)
