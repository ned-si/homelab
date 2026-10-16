# HubbleRelayAbsent

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/hubble-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/hubble-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

Prometheus has had no `hubble_relay_pool_peer_connection_status` for 30
minutes: the relay is not running or not scraped, so
[HubbleRelayPeersNotReady](HubbleRelayPeersNotReady.md) cannot fire.

## Confirm

```sh
q 'up{job="monitoring/hubble-relay"}'
kubectl -n kube-system get deploy hubble-relay
kubectl -n monitoring get podmonitor hubble-relay --show-labels
```

Expected while it fires: no series or `0`. Healthy: `1`, the Deployment
available, the PodMonitor labelled `release=kube-prometheus-stack`.

## Fix

1. Deployment missing or not available: the Application `cilium` in Argo CD
   (`hubble.relay` in `infrastructure/cilium/values.yaml`), then
   `kubectl -n kube-system describe pod -l k8s-app=hubble-relay`.
2. Scrape refused: the CiliumNetworkPolicy `kube-system/hubble-relay`
   (`platform/hubble-access/network-policy.yaml`) must allow Prometheus on 9966.

## Resolved when

`q 'hubble_relay_pool_peer_connection_status'` returns series; the alert clears.

## Links

- [networking.md: Hubble](../../networking.md#hubble)
