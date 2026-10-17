# SigNozCollectorAbsent

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/signoz-trial.yaml`](../../../platform/kube-prometheus-stack/routes/signoz-trial.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

No SigNoz OTel collector has been up for an hour. Vector cannot deliver logs:
they buffer in memory, then [LogPipelineDiscarding](LogPipelineDiscarding.md)
follows.

## Confirm

```sh
q 'up{namespace="signoz", job=~".*otel-collector.*"}'
kubectl -n signoz get pods
kubectl -n signoz logs deploy/signoz-otel-collector --tail=30
```

Expected while it fires: no series or `0`, and the collector not Running or
not Ready; its log names the cause (often ClickHouse unreachable).

## Fix

1. ClickHouse not Running: `kubectl -n signoz get chi` and
   `kubectl -n signoz describe pod -l app.kubernetes.io/name=clickhouse`;
   an OOM kill means the memory limit in `platform/signoz/values.yaml` (and a
   failed trial criterion).
2. Collector crash-looping: the Application `signoz` in Argo CD, then the log
   above.

## Resolved when

`q 'up{namespace="signoz", job=~".*otel-collector.*"}'` is `1`; the alert clears.

## Links

- [observability.md: SigNoz](../../observability.md#signoz)
