# AlertmanagerHasNoReceiverConfigured

`critical`, pages. Rule: [`platform/kube-prometheus-stack/routes/alerts.yaml`](../../../platform/kube-prometheus-stack/routes/alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

Alertmanager has sent nothing in 6 hours. The Watchdog route sends a
heartbeat every 5 minutes, so either every route leads to the `null`
receiver, or Alertmanager is wedged. Nothing pages while this is true.

## Confirm

```sh
q 'sum(increase(alertmanager_notifications_total[6h]))'
kubectl -n monitoring get pod alertmanager-kube-prometheus-stack-alertmanager-0
kubectl -n monitoring logs alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager --since=1h | tail -20
```

Then the loaded config: `kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093`,
`http://localhost:9093/#/status`.

Expected while it fires: `0` (or no series), and a config without the
`heartbeat` and `ntfy` receivers, or a pod not Ready.

## Fix

1. The config lost its routes: compare `alertmanager.config` in
   `platform/kube-prometheus-stack/values.yaml` with the status page. A bad
   merge is reverted; `scripts/ci/alertmanager-test.sh` must pass on the fix.
2. Alertmanager wedged: restart it,
   `kubectl -n monitoring delete pod alertmanager-kube-prometheus-stack-alertmanager-0`.
3. The Watchdog is missing: it comes from the chart's default rules; check
   `q 'ALERTS{alertname="Watchdog"}'`.

## Resolved when

`q 'sum(increase(alertmanager_notifications_total[15m]))'` is above `0`, and
healthchecks.io shows the check green.

## Links

- [observability.md: Heartbeat](../../observability.md#heartbeat)
- [sre.md: Paging](../../sre.md#paging)
