# HubbleRelayPeersNotReady

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/hubble-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/hubble-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

For 30 minutes the Hubble relay has been connected to fewer Cilium agents than
are Ready. The Hubble UI and `hubble observe` through the relay miss the flows
of those nodes. Traffic itself is not affected.

## Confirm

```sh
q 'hubble_relay_pool_peer_connection_status'
kubectl -n kube-system logs deploy/hubble-relay --tail=20
```

Expected while it fires: `READY` plus `IDLE` (connected, no stream open) below the node count, and the relay log names
the cause for each peer it cannot reach.

## Fix

1. `certificate signed by unknown authority`, `unknown certificate
   authority` or `expired`: the certificates. Re-issue them
   ([networking.md: Hubble certificates](../../networking.md#hubble-certificates)):

   ```sh
   kubectl -n kube-system create job --from=cronjob/hubble-generate-certs hubble-generate-certs-now
   kubectl -n kube-system wait --for=condition=complete job/hubble-generate-certs-now --timeout=120s
   kubectl -n kube-system delete job hubble-generate-certs-now
   ```

   Expected: `condition met`; the relay logs `Connected` for each node within a
   minute. If the Job fails, read its log: past 2028-10-13 the CA must be
   rotated first (same page).
2. `connection refused` or timeouts to `<node-ip>:4244`: that node's agent.
   `kubectl -n kube-system get pods -l k8s-app=cilium -o wide` and the agent's
   log on that node.

## Resolved when

`q 'sum(hubble_relay_pool_peer_connection_status{status=~"READY|IDLE"})'` equals the
number of nodes; the alert clears.

## Links

- [networking.md: Hubble](../../networking.md#hubble)
