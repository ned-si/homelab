# Observability

Prometheus, Alertmanager and Grafana from `kube-prometheus-stack`, in the
`monitoring` namespace. Grafana is at `grafana.lilalala.com` behind Keycloak.

This page is about **getting paged**. The alert rules themselves are documented
where they are defined — `platform/kube-prometheus-stack/routes/alerts.yaml` for
the cluster and `platform/backup-verify/alerts.yaml` for the backups — each with
the incident it exists because of.

## How to get paged: the one-time setup

Alertmanager reads its credentials from files, so nothing site-specific and nothing
identifying your devices is in git — not even the destination. That is why Pushover
was chosen over Telegram, ntfy, gotify and email; the rejected alternatives and the
exact edit to switch to Telegram are in
`platform/kube-prometheus-stack/values.yaml`.

**The Alertmanager pod will not start until the Secret exists**, because the
operator mounts it as a volume. That is deliberate: the alternative — Alertmanager
running happily and failing every delivery — is indistinguishable from having no
alerting at all.

Three values, all documented in
`platform/secrets/alertmanager-notify.sops.yaml.example`: a Pushover **application**
token, your Pushover **user key**, and a **dead-man's-switch ping URL** from
healthchecks.io or Better Stack. For the heartbeat, set the provider's grace period
to **15–20 minutes** and point its notification at an address that does *not* depend
on this cluster.

Fill in the copy, seal it, **then** add the line to
`platform/secrets/secret-generator.yaml` — in that order, or the whole
`secrets-platform` Application fails ([secrets.md](secrets.md)). The key names are
load-bearing: they become filenames and the paths are hard-coded in `values.yaml`,
so renaming one gives an Alertmanager that starts and then fails every send.

## The dead-man's switch is the most important route

`Watchdog` is an alert the chart ships that is **always firing, by design**. It is
routed to the heartbeat URL every 5 minutes and never reaches the phone.

Nothing running inside this cluster can report that this cluster is unreachable. The
heartbeat turns "Prometheus, Alertmanager, the node they run on, or the house's
internet has died" — the failure that silences every other alert — into an inbound
notification from a third party. Without it, the monitoring stack's failure mode is
silence, and silence gets read as health, which is worse than no alerting because it
is believed.

The route's `repeat_interval` is 5m and must stay comfortably shorter than the
provider's grace period, or a normal quiet period is reported as an outage and you
will mute the check within a week.

## Severity conventions

Two levels reach the phone. There is one operator and one phone, so routing warnings
to a quieter destination was rejected — a warning that goes somewhere you do not look
is the original problem again. Warnings are batched harder instead.

| Severity | Meaning | `group_wait` | `repeat_interval` |
|---|---|---|---|
| `critical` | acting later costs data or availability | 1m | 4h |
| `warning` | look at this week | 10m | 24h |
| `none` | `Watchdog` only → heartbeat, never the phone | 0s | 5m |

Grouping is by `(alertname, namespace)`, and the base `group_wait` is 5m rather than
the default 30s: a cold start fires every rule that has no data yet at once, and 30s
means one notification per straggler.

**Inhibition** is the other mechanism, and it is not interchangeable with grouping:
it suppresses by *cause*. A node going down makes every pod on it unready, every PVC
unreachable and every Service empty — thirty notifications for one event. The
inhibit rules are scoped with `equal: [node]`; without that key an inhibit rule
suppresses cluster-wide the moment any node goes down, which is how one turns into a
silence. That scoping is also why several pod-level rules join `kube_pod_info` with
`group_left(node)`: without the join the inhibition looks configured and silently
never applies. Do not remove those joins as tidy-up.

## Silencing

Silences are imperative, expire on their own, and are the right tool for planned
work. Do not reach for editing a rule.

```sh
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
# then http://localhost:9093 -> Silences -> New
```

- Always set a **duration**, never an indefinite silence. An indefinite silence is a
  deleted alert that nobody remembers deleting.
- Silence the narrowest matcher that works — `alertname` plus `namespace`, not
  `severity`.
- Before an OS or Kubernetes upgrade, silence `PodNotReady`, `PodPendingTooLong` and
  `KubeNodeNotReady` for the length of the window. `ansible/os-upgrade.yml` drains
  one node at a time, so these will fire legitimately.
- Do **not** silence `Watchdog`. It is the one alert whose *absence* is the signal.

## When an alert fires and the pod looks fine

Two failure modes this cluster has actually had, both of which read as something
else.

**A container stuck `Waiting`, not crash-looping.** `PodStuckNotRunning` covers the
`CreateContainerError` / `ImagePullBackOff` family, which the chart's
`KubePodCrashLooping` cannot see — a container that never *starts* does not
crash-loop, it waits. When you get one: **read `state`, not `lastState`.** The
canonical case was a `cilium-agent` whose log pointed at the network
(`dial tcp …:6443: no route to host`) — a `lastState` line months old. The current
cause was containerd holding a stale container-name reservation from a dead sandbox,
which the kubelet could never win. The pod UID is part of the container name, so:

```sh
kubectl -n <ns> delete pod <pod>      # new UID, new name, no collision
```

**A pod `Running 1/1` with `0` restarts and nothing listening.** That is the
qBittorrent outage, and no metric in this cluster would have caught it: Kubernetes
believed the pod was healthy, so every derived metric inherited the wrong premise.
The fix was a readiness probe, which every workload now has; `PodNotReady` and
`ServiceHasNoReadyBackend` are the delivery mechanism, not the detection.
[runbooks/arr-qbittorrent.md](runbooks/arr-qbittorrent.md).

The remaining gap is honest: **blackbox-exporter is not deployed**, so `probe_success`
does not exist and no rule uses it. It is the one thing that would catch the second
failure mode without a probe, because it tests the thing rather than asking
Kubernetes about it. Highest-value addition left in this area.
