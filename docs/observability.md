# Observability

Metrics and dashboards run; alerting does not reach anyone yet. Prometheus,
Alertmanager and Grafana come from `kube-prometheus-stack` (chart 92.0.0,
Prometheus v2.49.1, Alertmanager v0.26.0) in namespace `monitoring`, at the
chart's defaults apart from Prometheus storage and the Grafana login.

| Part | State |
| --- | --- |
| Prometheus | running, 15 Gi volume, the chart's default rules and scrape targets |
| Grafana | `https://grafana.lilalala.com`, Keycloak login (client `grafana-oauth`, secret from `monitoring/grafana-oidc`), the chart's default dashboards |
| Alertmanager | `Watchdog` goes to the dead-man's switch every 5 minutes ([Heartbeat](#heartbeat)); every other alert goes to the `null` receiver and is dropped |
| Custom alert rules | written, not deployed: `platform/kube-prometheus-stack/routes/alerts.yaml`, `platform/backup-verify/alerts.yaml`. Deployed: `cnpg-backups` (group `cnpg.backups`, CNPG backup and WAL archiving) with PodMonitor `cnpg-instances`, in `platform/barman-cloud-plugin/monitoring.yaml` |
| Notification credentials | Secret `monitoring/alertmanager-notify` (keys `pushover-token`, `pushover-user-key`, `heartbeat-url`), mounted into Alertmanager; `heartbeat-url` is a healthchecks.io ping URL (check period 5 minutes, grace 15 minutes), the two Pushover keys are still `PENDING` sentinels |
| Hubble | on in the Cilium agents; relay, UI and metrics not enabled ([networking.md](networking.md#debugging)) |
| blackbox-exporter | Application `blackbox-exporter` in `monitoring`; Probes in `platform/blackbox-exporter/probes/`: every public hostname (job `blackbox-public`, label `app`) and the API VIP, Gateway, NAS iSCSI/NFS, Keycloak, Argo CD, router DNS and CoreDNS (job `blackbox-internal`) |

Until notifications are wired, the checks are manual: the smoke suite
([runbooks/cold-start.md](runbooks/cold-start.md#step-8-smoke-suite)), the
Argo CD application list, and `scripts/status.sh`.

`scripts/status.sh` is a read-only, one-screen view without Grafana: nodes,
etcd and the API VIP, Applications not Synced/Healthy, unhealthy pods and the
most restarted, PVCs, CNPG clusters, NAS ports, Immich asset counts,
certificates, the Gateway, HTTPRoutes and LoadBalancer addresses, backup
CronJob freshness, the WAN address against `--default-targets`, and Secrets by
name and age. It exits 1 when anything is red; `--json` prints the same data
as one document. Tested against a fake kubectl in `tests/bash/test_status.sh`.

## Looking at it

```sh
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# http://localhost:9090/alerts : what would fire
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
# http://localhost:9093 : what Alertmanager holds (and drops)
```

## Dashboards

JSON in `platform/kube-prometheus-stack/dashboards/`, one ConfigMap each
(label `grafana_dashboard: "1"`, loaded by the Grafana sidecar). Checked by
`tests/test_dashboards.py` (layout, `${datasource}` everywhere, PromQL parses).

| Dashboard (uid) | Shows |
| --- | --- |
| Homelab / Overview (`homelab-overview`) | 30-day availability and error budget per app, 1h burn rate, probe status and duration, nodes Ready, internal endpoints, eMMC and PVC usage, pods not Ready and restarts, running image tags, certificate expiry as served, hours since each backup CronJob last succeeded |
| Homelab / Security (`homelab-security`) | certificate expiry, TLS version and HTTP status per hostname, Kubernetes API 401/403 rate, public endpoints answering 401/403, Secret age (names only), images without a pinned tag |

Not shown, and what each would need:

| Missing | Needs |
| --- | --- |
| CI and Renovate status | a GitHub exporter with a token, or a JSON datasource plugin |
| NAS pool usage | a TrueNAS exporter (PVC usage is shown) |
| Trivy findings, image CVE counts | trivy-operator |
| Keycloak failed logins | `KC_EVENT_METRICS_USER_ENABLED=true` and a ServiceMonitor on port 9000 |
| Gateway auth errors per route | Cilium Envoy or Hubble HTTP metrics, scraped |
| cert-manager, Argo CD, CNPG metrics | their ServiceMonitors/PodMonitors carry no `release: kube-prometheus-stack` label, so Prometheus ignores them |

## Turning alerting on

The design is written; each step is its own pull request:

1. Put real Pushover values in `platform/secrets/alertmanager-notify.sops.yaml`
   (`task secrets:edit -- platform/secrets/alertmanager-notify.sops.yaml`): a
   Pushover application token and user key. `heartbeat-url` is done
   separately, see [Heartbeat](#heartbeat).
2. Configure Alertmanager in `platform/kube-prometheus-stack/values.yaml` to
   read those files (Pushover receiver, severity routing below; the Secret
   mount and the `Watchdog` route are already there). Key names become file
   names: renaming one gives an Alertmanager that starts and then fails every
   send.
3. Add `alerts.yaml` (and `dashboard-data-protection.yaml`) to
   `platform/kube-prometheus-stack/routes/kustomization.yaml`.
4. Check: `AlertmanagerHasNoReceiverConfigured` clears within 6 hours, and a
   test alert reaches the phone.

### Heartbeat

Alertmanager sends the always-firing `Watchdog` alert every 5 minutes (route
`group_interval: 1m`, `repeat_interval: 5m`) as a webhook POST to the URL in
Secret `monitoring/alertmanager-notify` key `heartbeat-url`, mounted at
`/etc/alertmanager/secrets/alertmanager-notify/heartbeat-url` (`url_file`).
The provider alerts when the pings stop, which covers Prometheus, Alertmanager,
the cluster and the house's internet being down. While the key holds its
sentinel, every send fails: Alertmanager logs `Notify attempt failed` for
receiver `heartbeat`, and nothing else is affected.

Turning it on (one signup, then one secret edit):

1. Sign up at <https://healthchecks.io> (free tier), create a check with period
   5 minutes and grace 15 minutes, set its notification to an address that does
   not depend on this cluster, and copy its ping URL
   (`https://hc-ping.com/<uuid>`).
2. Put it in the Secret, then commit and open a pull request:

   ```sh
   task secrets:edit -- platform/secrets/alertmanager-notify.sops.yaml
   # replace the heartbeat-url value, save
   ```

   Or set `HEARTBEAT_URL=<ping URL>` in `secrets.local.env` and run
   `scripts/seal-secrets-from-env.sh --force`.
3. After Argo CD syncs `secrets-platform` (the mounted file follows within a
   minute or two, no restart): the check turns green within 5 minutes, and
   `kubectl -n monitoring logs alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager --since=10m | grep -c 'Notify attempt failed'`
   prints `0`.

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

## SLOs

Each user-facing app (auth cinema theater media archive cook drive syncthing)
has one availability SLO: 99.5% of its public blackbox probes succeed over 30
days, an error budget of about 3.6 hours a month. Plain recording rules, no
SLO generator: `slo:probe_error:ratio_rate<window>`,
`slo:availability:ratio_rate30d` and `slo:error_budget_remaining:ratio_rate30d`,
all by `app`.

| Alert | Fires when | Severity |
| --- | --- | --- |
| `SLOErrorBudgetBurnFast` | burn rate above 14.4x over 1h and 5m, or 6x over 6h and 30m | `critical` |
| `SLOErrorBudgetBurnSlow` | burn rate above 3x over 1d and 2h, or 1x over 3d and 6h | `warning` |
| `SLOProbesAbsent` | no `probe_success` for job `blackbox-public` for 15m | `warning` |
| `SLOTargetProbeAbsent` | no `probe_success` for one SLO target for 15m (quiet while `SLOProbesAbsent` fires) | `warning` |

Prometheus keeps `retention: 30d` capped by `retentionSize: 20GiB` on a 25Gi
volume. At about 0.55 GB of blocks a day, 30 days take about 17 GB; the rest
of the volume is for the WAL and compaction.

The rules are unit-tested: `scripts/ci/promtool-check.sh` runs `promtool check
rules` on every rendered PrometheusRule and `promtool test rules` on
`tests/prometheus/*_test.yaml` (CI, render job).

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
  probe, or a check from outside like blackbox-exporter, catches it. The
  syncthing and qBittorrent LoadBalancer ports are not probed from inside: their
  network policies admit `world` only, so a pod's probe would be dropped.

## Why it is like this

- Parity first: the chart was adopted with its running values, and alerting is
  new behaviour that ships in its own changes
  ([decisions.md](decisions.md#adopt-at-parity-change-afterwards)).
- Pushover plus an external heartbeat: one person, one phone. Routing warnings
  to a quieter channel was rejected, because a warning that goes where nobody
  looks is the original problem again; warnings are batched harder instead.
- Credentials as mounted files, not values: nothing about the destination
  devices is in git.
