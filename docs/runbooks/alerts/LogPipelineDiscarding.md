# LogPipelineDiscarding

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/signoz-trial.yaml`](../../../platform/kube-prometheus-stack/routes/signoz-trial.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

For an hour the Vector agents have been discarding log events: logs from the
nodes are lost before they reach SigNoz. The usual cause is a full sink
buffer because the SigNoz collector is down or slow.

## Confirm

```sh
q 'sum by (component_id, node) (increase(vector_component_discarded_events_total[15m])) > 0'
kubectl -n logging get pods -o wide
kubectl -n signoz get pods
```

Expected while it fires: one or more `component_id` rows (the sink `signoz`
when the collector is the cause), and the collector or ClickHouse not Running.

## Fix

1. Collector or ClickHouse down: [SigNozCollectorAbsent](SigNozCollectorAbsent.md#fix).
2. A transform discarding: `kubectl -n logging logs ds/vector --tail=50` names
   the component and the error; fix the VRL in `platform/vector/values.yaml`
   in a pull request.

## Resolved when

`q 'sum(increase(vector_component_discarded_events_total[15m]))'` returns 0
for 15 minutes; the alert clears.

## Links

- [observability.md: Logs](../../observability.md#logs)
