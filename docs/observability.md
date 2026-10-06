# Observability

Metrics and dashboards run; alerting does not reach anyone yet. Prometheus,
Alertmanager and Grafana come from `kube-prometheus-stack` (chart 92.0.0,
Prometheus v2.49.1, Alertmanager v0.26.0) in namespace `monitoring`, at the
chart's defaults apart from Prometheus storage and the Grafana login.

| Part | State |
| --- | --- |
| Prometheus | running, 15 Gi volume, the chart's default rules and scrape targets |
| Grafana | `https://grafana.lilalala.com`, Keycloak login (client `grafana-oauth`, secret from `monitoring/grafana-oidc`), the chart's default dashboards |
| Alertmanager | running with the chart's default configuration: one `null` receiver, so every alert is dropped |
| Custom alert rules | written, not deployed: `platform/kube-prometheus-stack/routes/alerts.yaml`, `platform/backup-verify/alerts.yaml` |
| Notification credentials | Secret `monitoring/alertmanager-notify` exists (keys `pushover-token`, `pushover-user-key`, `heartbeat-url`); nothing reads it yet, and the Pushover values are still `PENDING` sentinels |
| Hubble | on in the Cilium agents; relay, UI and metrics not enabled ([networking.md](networking.md#debugging)) |
| blackbox-exporter | not deployed: no rule can probe a service from outside |

Until notifications are wired, the checks are manual: the smoke suite
([runbooks/cold-start.md](runbooks/cold-start.md#step-8-smoke-suite)) and the
Argo CD application list.

## Looking at it

```sh
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# http://localhost:9090/alerts : what would fire
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
# http://localhost:9093 : what Alertmanager holds (and drops)
```

## Turning alerting on

The design is written; each step is its own pull request:

1. Put real Pushover values in `platform/secrets/alertmanager-notify.sops.yaml`
   (`task secrets:edit -- platform/secrets/alertmanager-notify.sops.yaml`): a
   Pushover application token and user key. `heartbeat-url` is a
   dead-man's-switch ping URL (healthchecks.io or similar) whose own alert
   reaches you without this cluster; set its grace period to 15 to 20 minutes.
2. Configure Alertmanager in `platform/kube-prometheus-stack/values.yaml` to
   read those files (Pushover receiver, `Watchdog` routed to the heartbeat every
   5 minutes, severity routing below). Key names become file names: renaming one
   gives an Alertmanager that starts and then fails every send.
3. Add `alerts.yaml` (and `dashboard-data-protection.yaml`) to
   `platform/kube-prometheus-stack/routes/kustomization.yaml`.
4. Check: `AlertmanagerHasNoReceiverConfigured` clears within 6 hours, and a
   test alert reaches the phone.

### Severity conventions once enabled

| Severity | Meaning | `group_wait` | `repeat_interval` |
| --- | --- | --- | --- |
| `critical` | acting later costs data or availability | 1m | 4h |
| `warning` | look at it this week | 10m | 24h |
| `none` | `Watchdog` only, to the heartbeat, never the phone | 0s | 5m |

Grouping is by `(alertname, namespace)` with a base `group_wait` of 5m, so a
cold start that fires every rule at once sends one batch. Inhibition rules are
scoped with `equal: [node]`: a node going down suppresses the pod and volume
alerts on that node, not cluster-wide. Several pod rules join `kube_pod_info`
with `group_left(node)` for that reason; do not remove the joins.

`Watchdog` always fires, by design: the heartbeat provider alerts when it stops
arriving, which is the only way to learn that the cluster, Alertmanager or the
house's internet is down. Never silence it.

## Silencing

Silences are imperative, expire on their own, and are the tool for planned
work:

```sh
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
# http://localhost:9093 -> Silences -> New
```

- Always set a duration; an indefinite silence is a deleted alert nobody
  remembers deleting.
- Match the narrowest set that works (`alertname` plus `namespace`).
- Before an OS or Kubernetes upgrade, silence `PodNotReady`,
  `PodPendingTooLong` and `KubeNodeNotReady` for the window: each node is
  drained in turn.

## When something looks healthy and is not

Two failure modes this cluster has had:

- A container stuck `Waiting` (`CreateContainerError`, `ImagePullBackOff`) does
  not crash-loop, so `KubePodCrashLooping` never sees it. Read `state`, not
  `lastState`, in `kubectl describe pod`. A stale containerd name reservation
  from a dead sandbox is cleared by deleting the pod (new UID, new name).
- A pod `Running 1/1` with nothing listening: the qBittorrent case
  ([runbooks/arr-qbittorrent.md](runbooks/arr-qbittorrent.md)). Only a readiness
  probe, or a check from outside like blackbox-exporter, catches it.

## Why it is like this

- Parity first: the chart was adopted with its running values, and alerting is
  new behaviour that ships in its own changes
  ([decisions.md](decisions.md#adopt-at-parity-change-afterwards)).
- Pushover plus an external heartbeat: one person, one phone. Routing warnings
  to a quieter channel was rejected, because a warning that goes where nobody
  looks is the original problem again; warnings are batched harder instead.
- Credentials as mounted files, not values: nothing about the destination
  devices is in git.
