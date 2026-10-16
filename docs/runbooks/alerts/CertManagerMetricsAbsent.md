# CertManagerMetricsAbsent

`critical`, pages. Rule: [`platform/kube-prometheus-stack/routes/alerts.yaml`](../../../platform/kube-prometheus-stack/routes/alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

Prometheus has had no certificate expiry series for an hour, so every
certificate alert is inert and the next expiry would be a surprise.

## Confirm

```sh
q 'up{job="cert-manager"}'
kubectl -n cert-manager get servicemonitor --show-labels
kubectl -n cert-manager get deploy
```

Expected while it fires: no series or `0`. Healthy: `1`, a ServiceMonitor
labelled `release=kube-prometheus-stack`, the deployments available.

## Fix

1. ServiceMonitor missing or without the label: `prometheus.enabled` and
   `prometheus.servicemonitor.enabled` plus the label in
   `infrastructure/cert-manager/values.yaml`.
2. cert-manager down: `kubectl -n cert-manager logs deploy/cert-manager --tail=50`
   and the Application `cert-manager` in Argo CD. While it is down nothing
   renews; check [CertificateExpiringSoon](CertificateExpiringSoon.md#confirm).

## Resolved when

`q 'count(certmanager_certificate_expiration_timestamp_seconds)'` returns the
certificate count; the alert clears.

## Links

- [observability.md: Dashboards](../../observability.md#dashboards) (the cert-manager label pitfall)
