# LANInventoryAbsent

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/lan-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/lan-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

Prometheus has had no `lan_inventory_devices` for 30 minutes: `lan-inventory`
is not running or not scraped, so [LANNewDeviceSeen](LANNewDeviceSeen.md)
cannot fire.

## Confirm

```sh
q 'up{job="lan-inventory"}'
kubectl -n monitoring get deploy,servicemonitor lan-inventory --show-labels
```

Expected while it fires: no series or `0`. Healthy: `1`, the Deployment
available, the ServiceMonitor labelled `release=kube-prometheus-stack`.

## Fix

1. Deployment missing or not available: the Application `lan-inventory` in
   Argo CD; then [LANInventoryFailing](LANInventoryFailing.md#fix).
2. ServiceMonitor missing or without the `release` label: fix it in
   `platform/lan-inventory/` in a pull request.

## Resolved when

`q 'lan_inventory_devices'` returns a count; the alert clears.

## Links

- [observability.md: LAN inventory](../../observability.md#lan-inventory)
