# CNPGMetricsAbsent

`critical`, pages. Rule: [`platform/barman-cloud-plugin/monitoring.yaml`](../../../platform/barman-cloud-plugin/monitoring.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

Prometheus scrapes no CNPG instance at all, so no backup or WAL alert can
fire. Either the PodMonitor is gone or ignored, or every database pod is down.

## Confirm

```sh
q 'up{job="immich/cnpg-instances"}'
kubectl -n immich get podmonitor cnpg-instances --show-labels
kubectl get cluster.postgresql.cnpg.io -A
```

Expected while it fires: no `up` series (or all `0`). Healthy: 8 targets at
`1`, the PodMonitor labelled `release=kube-prometheus-stack`, every Cluster
`Cluster in healthy state`.

## Fix

1. Clusters not healthy: the databases are down; find out why (NAS, node:
   [HomelabNASDown](HomelabNASDown.md), [HomelabNodeDown](HomelabNodeDown.md)).
2. PodMonitor missing or without the `release` label: the Application
   `barman-cloud-plugin` is not synced, or the label was dropped in git.
3. Targets `0`: the instance exporter (port `metrics`, 9187) does not answer;
   check a pod with `kubectl -n <namespace> describe pod <cluster>-1`.

## Resolved when

`q 'count(cnpg_collector_up)'` returns `8`; the alert clears.

## Links

- [backups.md: Schedule](../../backups.md#schedule) (the alert list)
