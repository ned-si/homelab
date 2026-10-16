# SLOProbesAbsent

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/slo.yaml`](../../../platform/kube-prometheus-stack/routes/slo.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

Prometheus has had no public probe result (job `blackbox-public`) for 15
minutes, so no SLO alert can fire for any app.

## Confirm

```sh
q 'count(probe_success{job="blackbox-public"})'
kubectl -n monitoring get probes
kubectl -n monitoring get deploy blackbox-exporter
```

Expected while it fires: no result. Healthy: one series per target, the
Probe `public-https` present, the exporter available.

## Fix

1. The exporter is down: `kubectl -n monitoring describe deploy blackbox-exporter`
   and its pod logs; the Application `blackbox-exporter` in Argo CD.
2. The Probe is gone or lost its `release: kube-prometheus-stack` label:
   restore it in `platform/blackbox-exporter/probes/probes.yaml`.
3. Prometheus ignores Probes: check the operator log
   (`kubectl -n monitoring logs deploy/kube-prometheus-stack-operator --since=1h | grep -i probe`).

## Resolved when

`q 'count(probe_success{job="blackbox-public"})'` returns the target count;
the alert clears.

## Links

- [observability.md: SLOs](../../observability.md#slos)
- [SLOTargetProbeAbsent](SLOTargetProbeAbsent.md)
