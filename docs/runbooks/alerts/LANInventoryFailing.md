# LANInventoryFailing

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/lan-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/lan-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

`lan-inventory` has not completed an ARP scan for 30 minutes, so
[LANNewDeviceSeen](LANNewDeviceSeen.md) cannot fire.

## Confirm

```sh
q 'lan_inventory_scan_success'
kubectl -n monitoring get pod -l app.kubernetes.io/name=lan-inventory -o wide
kubectl -n monitoring logs deploy/lan-inventory --tail=20
```

Expected while it fires: `0`, or log lines with `"ok": false` and an error.
Healthy: JSON lines with `"msg": "scan"`, `"ok": true` and a `devices` count.

## Fix

1. `Operation not permitted` or a socket error: the pod lost `CAP_NET_RAW`
   or host networking; compare `platform/lan-inventory/deployment.yaml` with
   the live pod, and check the `monitoring` namespace still allows the
   privileged Pod Security level.
2. Timeouts on every address: the node it runs on has a network problem;
   delete the pod so it lands elsewhere:
   `kubectl -n monitoring delete pod -l app.kubernetes.io/name=lan-inventory`.
3. A crash loop: read `kubectl -n monitoring logs deploy/lan-inventory --previous`.

## Resolved when

A log line with `"ok": true`; the alert clears.

## Links

- [observability.md: LAN inventory](../../observability.md#lan-inventory)
