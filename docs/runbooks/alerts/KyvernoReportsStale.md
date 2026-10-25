# KyvernoReportsStale

`warning`, pages (not in quiet hours). Rule: [`platform/kube-prometheus-stack/routes/kyverno-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/kyverno-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

Kyverno's reports controller has not run a background scan for 3 hours (it
runs every hour), or Prometheus no longer scrapes it. Admission keeps
working (16 policies in Deny, the rest in Audit); the PolicyReports, the Security dashboard row
"Admission policy (Kyverno, audit)" and the Deny-readiness they show are stale.

## Confirm

```sh
kubectl -n kyverno get pods -l app.kubernetes.io/component=reports-controller
kubectl -n kyverno logs deploy/kyverno-reports-controller --since=3h | grep -iE 'error|background'
kubectl get policyreports -A --sort-by=.metadata.creationTimestamp | tail -3
```

Expected while it fires: the pod restarting, OOMKilled (limit 256Mi) or
logging API errors; or the pod fine and the ServiceMonitor not scraped
(Prometheus, Status, Targets, `kyverno-reports-controller`).

## Fix

- OOMKilled: raise `reportsController.resources.limits.memory` in
  `infrastructure/kyverno/values.yaml` (PR).
- Crash loop after an update: revert the Kyverno update (PR); the webhook is
  `failurePolicy: Ignore`, so admission keeps working meanwhile.
- Not scraped: check the ServiceMonitor label `release: kube-prometheus-stack`.
