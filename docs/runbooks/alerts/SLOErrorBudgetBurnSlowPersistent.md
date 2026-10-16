# SLOErrorBudgetBurnSlowPersistent

`warning`, pages, one per app. Rule: [`platform/kube-prometheus-stack/routes/slo.yaml`](../../../platform/kube-prometheus-stack/routes/slo.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

`SLOErrorBudgetBurnSlow` has fired for `app` for 24 hours: it fails more
probes than its objective allows, on and off, and the fault does not go away
on its own. Not a full outage; an intermittent one.

## Confirm

```sh
q 'slo:probe_error:ratio_rate1d{app="<app>"}'
q 'slo:error_budget_remaining:ratio_rate30d{app="<app>"}'
q 'count_over_time((probe_success{job="blackbox-public", app="<app>"} == 0)[1d:30s])'
q 'quantile_over_time(0.95, probe_duration_seconds{job="blackbox-public", app="<app>"}[1d])'
q 'increase(kube_pod_container_status_restarts_total{namespace="<namespace>"}[1d]) > 0'
```

Expected while it fires: an error ratio above the objective's allowance, the
number of failed probes in the day, the p95 probe duration (near the 15 s
timeout means slow, not down), and any restarts.

## Fix

1. Restarts: the container's last exit reason
   (`kubectl -n <namespace> describe pod <pod> | grep -A5 'Last State'`).
   `OOMKilled` needs a higher memory limit in git; probe failures need a
   longer timeout or a fix in the app.
2. Slow responses near the probe timeout: CPU throttling or the NAS. Homelab
   / Overview (probe duration) and Homelab / Storage (NAS latency).
3. Failures clustered on one node: a flapping node (`kubectl get events -A
   --field-selector involvedObject.kind=Node`).
4. Failures at the same time every day: a backup or a CronJob competing for
   the app's volume ([backups.md: Schedule](../../backups.md#schedule)).

## Resolved when

The slow burn stops (the 1d error ratio under 3x the allowance) and this
alert clears. Check the budget state against the
[error-budget policy](../../sre.md#error-budget-policy).

## Links

- [observability.md: SLOs](../../observability.md#slos)
