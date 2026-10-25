# TetragonAgentMissing

`warning`, pages (not in quiet hours). Rule: [`platform/kube-prometheus-stack/routes/tetragon-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/tetragon-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

For 30 minutes, Prometheus has not scraped a Tetragon agent on the named
node: the pod is not running there, or its metrics are not scraped. No
runtime alert can fire for that node meanwhile.

## Confirm

```sh
kubectl -n tetragon get pods -o wide -l app.kubernetes.io/name=tetragon
kubectl -n tetragon describe ds tetragon | tail -20
kubectl -n tetragon logs -l app.kubernetes.io/name=tetragon -c tetragon --since=1h --prefix | grep -iE 'error|fatal' | tail
```

Expected while it fires: the pod missing on that node (a taint, the node
NotReady), CrashLoopBackOff after an update (a kernel or BTF mismatch after a
Talos upgrade), or OOMKilled; or all pods fine and the target down in
Prometheus, Status, Targets, `serviceMonitor/tetragon/tetragon`.

## Fix

- Crash after a Tetragon or Talos update: revert that update (PR).
- OOMKilled: raise `tetragon.resources.limits.memory` in
  `platform/tetragon/values.yaml` (PR).
- Not scraped: the ServiceMonitor needs the label
  `release: kube-prometheus-stack` (repo-policy `monitor-selected`).
