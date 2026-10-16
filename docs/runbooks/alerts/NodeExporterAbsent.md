# NodeExporterAbsent

`critical`, pages. Rule: [`platform/kube-prometheus-stack/routes/alerts.yaml`](../../../platform/kube-prometheus-stack/routes/alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

Prometheus has had no `node_filesystem_avail_bytes` for 15 minutes: no
node-exporter is scraped. Node disk, filesystem, memory and eMMC wear alerts
are inert.

## Confirm

```sh
q 'up{job="node-exporter"}'
kubectl -n monitoring get ds kube-prometheus-stack-prometheus-node-exporter
kubectl -n monitoring get pods -l app.kubernetes.io/name=prometheus-node-exporter -o wide
```

Expected while it fires: no series or `0`; the DaemonSet with fewer ready
pods than nodes.

## Fix

1. Pods not ready: `kubectl -n monitoring describe pod <pod>` and
   `kubectl -n monitoring logs <pod> --all-containers`. The `emmc-wear`
   sidecar has its own liveness probe; a failing sidecar restarts the pod.
2. DaemonSet or ServiceMonitor gone: the Application `kube-prometheus-stack`
   in Argo CD.

## Resolved when

`q 'count(up{job="node-exporter"} == 1)'` returns `4`; the alert clears.

## Links

- [NodeFilesystemNearlyFull](NodeFilesystemNearlyFull.md), [NodeEmmcWearHigh](NodeEmmcWearHigh.md)
