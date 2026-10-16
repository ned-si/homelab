# SLOTargetProbeAbsent

`warning`, pages, one per app. Rule: [`platform/kube-prometheus-stack/routes/slo.yaml`](../../../platform/kube-prometheus-stack/routes/slo.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

There are probe results, but none for `app`: its target was dropped from the
Probe, or its `app` relabeling no longer matches. The app's SLO alerts are
blind; an outage would page nobody.

## Confirm

```sh
q 'count by (app) (probe_success{job="blackbox-public"})'
grep -n '<app>.lilalala.com' platform/blackbox-exporter/probes/probes.yaml
```

Expected while it fires: `app` missing from the first list, and no target
line (or a renamed one) in the Probe.

## Fix

1. Put the app's health URL back in the `static` list of Probe
   `public-https` (`https://<app>.lilalala.com/<health path>`), in a pull
   request. The `app` label is the first DNS label of the URL.
2. The app was renamed or removed on purpose: change its SLO in
   `platform/kube-prometheus-stack/routes/slo.yaml` (the `app=~` regex, the
   `slo:app:info` entry and its `SLOTargetProbeAbsent` rule) and the table in
   [sre.md](../../sre.md#service-level) in the same pull request.

## Resolved when

`app` is back in the first query; the alert clears.

## Links

- [observability.md: SLOs](../../observability.md#slos)
