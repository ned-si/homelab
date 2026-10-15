# SRE policy

What the homelab promises its users, how much unreliability it may spend, and
what happens when it spends too much. The numbers and triggers on this page
are fixed and read from Prometheus; nobody, human or agent, decides them case
by case. How they are measured and alerted on is in
[observability.md](observability.md#slos).

## Service level

The self-SLA is the SLO: one number, 99.5% availability over a rolling 30
days, per user-facing app. There is no penalty and no separate, looser
contractual figure; a second number would only be a second thing to watch.

| App (`app` label) | Service | Tier |
| --- | --- | --- |
| `auth` | Keycloak | 1 |
| `media` | Immich | 1 |
| `archive` | Paperless-ngx | 1 |
| `drive` | Seafile | 1 |
| `syncthing` | Syncthing UI | 1 |
| `cook` | Mealie | 2 |
| `cinema` | Jellyfin | 2 |
| `theater` | Plex and the *arr apps | 2 |

Argo CD and Grafana are tools for the operator and carry no SLO.

- Availability: the share of public blackbox probes (job `blackbox-public`)
  that succeed. The probes run inside the cluster against the public names
  through NAT loopback.
- Error budget: 0.5% of 30 days, about 3.6 hours a month per app.
- Everything counts: planned work, power cuts, upstream bugs. No exclusions,
  so the budget never needs an argument about what counted.
- Not seen: an outage of the WAN link alone. The external heartbeat
  ([observability.md](observability.md#heartbeat)) covers it as a missed
  ping, not as budget.

## RPO

| Data | RPO (promised) | What runs today |
| --- | --- | --- |
| Postgres (all CloudNativePG clusters) | 24 h | continuous WAL archiving, a segment at least every 5 minutes, plus a daily base backup |
| Files (Immich originals, Paperless, Seafile, Syncthing, app configs) | 24 h | nightly restic to S3; Immich also to the NAS |
| Seafile MariaDB | 24 h | nightly `mariadb-dump` inside the restic snapshot |
| Cluster state | last merged commit | git; etcd snapshots before risky changes |
| Media library | none | not backed up; re-acquirable by design |

Details, schedules and rehearsed restores: [backups.md](backups.md#rpo-and-rto).

## RTO per tier

| Tier | What | RTO, service fault | RTO, restore from backup |
| --- | --- | --- | --- |
| 0 | Nodes and etcd, Cilium and the Gateway, NAS storage, Argo CD, cert-manager | 4 h ([runbooks/cold-start.md](runbooks/cold-start.md)) | 24 h: rebuild from git ([bootstrap.md](bootstrap.md)), not rehearsed end to end |
| 1 | `auth`, `media`, `archive`, `drive`, `syncthing` | 4 h | 24 h, data back to the RPO |
| 2 | `cook`, `cinema`, `theater` | 72 h | 72 h |

A service fault is anything fixed without restoring data: a revert, a pod or
node restart, a configuration fix. Tier 1 waits for tier 0; tier 2 waits for
both. The full Immich library restore (about 256 GiB) is not rehearsed; at the
rate of the sampled restore it fits in the tier 1 RTO.

## Error-budget policy

The state of each budget is
`slo:error_budget_remaining:ratio_rate30d{app="<app>"}`: 1 is the whole
budget left, 0 is spent, negative is the SLO missed. Read it:

```sh
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 > /dev/null 2>&1 &
PF=$!
sleep 3
curl -s -m 10 http://localhost:9090/api/v1/query \
  --data-urlencode 'query=slo:error_budget_remaining:ratio_rate30d' |
  jq -r '.data.result[] | "\(.metric.app) \(.value[1])"'
kill "$PF"
```

Expected: one line per app in the table above, for example `cook 0.97`.

| State | Condition | What changes |
| --- | --- | --- |
| Healthy | remaining ≥ 0.25 | nothing |
| At risk | 0 < remaining < 0.25 | the next agent pass starts with that app's open reliability items; other work continues |
| Exhausted | remaining ≤ 0 | reliability-only for that app (below) |

While a budget is exhausted:

- The agent pass works only on reliability for that app: the cause of the
  burn, the postmortem's action items, probes, resources, alerts, runbooks.
  New features, new hostnames and configuration changes for that app wait.
- Renovate automerge continues, for that app too. Updates are small, gated by
  CI and reverted automatically when they break a deploy
  ([decisions.md](decisions.md#automatic-rollback)); freezing them would hold
  back security fixes and make the next update bigger. There is no human gate
  ([decisions.md](decisions.md#no-human-gates)).
- Security fixes are never held.
- Other apps are not affected. A cluster-wide outage exhausts every budget,
  and then the whole agent pass is reliability work, as intended.

The state ends on its own when the value is above 0 again. Nobody declares
it over.

If an app is exhausted on the 1st of two consecutive months, its SLO is
reviewed in one pull request that changes this page and
`platform/kube-prometheus-stack/routes/slo.yaml` together: either the app gets
a design change that removes the cause, or its target is lowered on purpose.

## Paging

A notification (ntfy) means a user is affected or data is at risk now. One
root cause sends one notification. Every other alert stays in Grafana and
Alertmanager, where the agent pass and the dashboards read it.

| Notifies | Alerts | Grouped by | Repeats |
| --- | --- | --- | --- |
| SLO fast burn | `SLOErrorBudgetBurnFast` (critical) | app | 4 h |
| SLO slow burn | `SLOErrorBudgetBurnSlow` (warning); quiet for a day after a fast burn of the same app | app | 24 h |
| Node down | `HomelabNodeNotReady` | alert | 4 h |
| etcd quorum | `etcdInsufficientMembers`, `etcdNoLeader` | alert | 4 h |
| NAS | `HomelabNASUnreachable`, `NASPoolUnhealthy` | alert | 4 h |
| Backups | `BackupVerifyFailed`, `CNPGBackupFailed`, `CNPGWALArchivingFailing`, `KubeJobFailed` of a `*-backup-*` Job | alert | 24 h |
| Security | any `critical` alert labelled `category: security` | alert | 4 h |
| Heartbeat | `Watchdog`, to healthchecks.io every 5 minutes, which notifies when it stops | | |

Not notified, by design: pod, workload and Argo CD alerts
(`KubePodCrashLooping`, `ServiceHasNoReadyBackend`, `ArgoCDAppDegraded`, ...),
capacity and certificate warnings, LAN and exporter alerts. A cause that
matters to users shows up as an SLO burn.

### Quiet hours

From 23:00 to 08:00 Europe/Zurich, every day, Alertmanager sends nothing to
ntfy (time interval `quiet-hours`, `mute_time_intervals` on every ntfy
route). Nothing is dropped: a group still firing at 08:00 notifies at its
next flush, within 5 minutes, once per group. A group that fired and
resolved overnight sends nothing; it stays in Alertmanager and Grafana.

What quiet hours do not cover:

- healthchecks.io posts to ntfy directly when the heartbeat stops, so a dead
  cluster or a dead house internet still notifies at night.
- The GitHub Actions failure posts (`dast`, `renovate-render`) go to ntfy
  directly, at priority low. In quiet hours they carry a `Delay` until 08:00
  Zurich (`scripts/ci/ntfy-quiet-delay.sh`), so ntfy delivers them then.
- `HomelabNodeNotReady` and `HomelabNASUnreachable` also go, unmuted, to a
  second topic (`ntfy-guard-url`, the topic plus `-guard`) that nobody
  subscribes to. The auto-rollback outage guard reads it, so it keeps
  holding reverts back during a night-time outage.

Inhibition hides the causes behind the alert that notified:

| While this fires | These are inhibited |
| --- | --- |
| `SLOErrorBudgetBurnFast` | the pod, workload and Argo CD alerts and `ServiceHasNoReadyBackend` of the app's namespace |
| `ServiceHasNoReadyBackend`, `StatefulSetHasNoReadyReplica` | the pod, workload and Argo CD alerts of that namespace |
| `HomelabNodeNotReady` | the node and pod alerts with the same `node` label |
| `HomelabNASUnreachable` | every storage consumer: SLO burns, pods, workloads, Argo CD, CNPG, backups, the NAS exporter |
| any `critical` | the `warning` of the same alert and namespace |

The routes, inhibit rules and timings are in
`platform/kube-prometheus-stack/values.yaml`. CI replays the Keycloak outage
of 2026-10-15 (nine alerts), a node down and the NAS unreachable against a
real Alertmanager and requires one notification each
(`scripts/ci/alertmanager-test.sh`, scenarios in `tests/alertmanager/`). It
also checks that every ntfy route mutes `quiet-hours`, and that a node down
during quiet hours notifies once after they end.
Adding an alert to the table above is a change to this page and to
`tests/alertmanager/routes.txt` in the same pull request.

## Postmortems

A postmortem is written, from [postmortems/template.md](postmortems/template.md),
within 7 days of the end of any of these:

- one event spends 25% or more of any app's monthly budget (about 54 minutes
  of failed probes);
- a budget reaches the exhausted state;
- data is lost, or a restore from backup is needed outside a rehearsal;
- a credential is exposed;
- an automated action (automatic rollback, Renovate, a hook) made things worse.

Postmortems are blameless: they describe what the system allowed, not who did
what. Each action item is a pull request or a [roadmap.md](roadmap.md) entry.
The list is in [postmortems/README.md](postmortems/README.md).

## Toil register

Manual, repetitive work that should not exist. Each entry stays until it is
automated away or accepted with a reason.

| Toil | When | Why it is manual | Way out |
| --- | --- | --- | --- |
| Press the NAS power button | after every power loss | the NAS does not power on by itself, and changing its firmware setting needs a display, so a GPU swap | the `HomelabNASUnreachable` alert says when; a UPS, or a relay on the ATX power header |
| Copy `talosconfig`, the admin kubeconfig and the age key into the password manager | after each is created or rotated | the password manager is the off-machine copy and has no API in use here | accepted; the alternative is another secret store with its own bootstrap problem ([secrets.md](secrets.md#why-it-is-like-this)) |
| Upgrade the Immich database image | while `immich-db` runs pgvecto.rs | the migration is one-way, so Renovate excludes `cloudnative-pgvecto.rs` | the one-time migration in [runbooks/immich-upgrade.md](runbooks/immich-upgrade.md); after it the Renovate exclusion can go |

## Who writes what

AI drafts text: postmortems, pull request descriptions, summaries. The
numbers, thresholds and triggers on this page, and the state of each budget,
come from this file and from Prometheus queries, never from a model's
judgement. A test, alert or policy uses AI only where no deterministic check
exists.

## Why it is like this

- One availability SLO at 99.5%: about 3.6 hours a month absorbs a power cut
  or an upgrade gone wrong without paging over every blip. Rejected: 99.9%,
  which one cold start would spend in a day on hardware with no UPS.
- Budget exhaustion changes the work, not the deploys: with one operator and
  automerge, a deploy freeze only lets updates pile up. Rejected: the classic
  release freeze.
- Triggers as thresholds, not judgement: they are checkable by a script and
  by an agent, and they cannot be argued with during an incident.
- Page on symptoms, not causes: sending every `warning` and `critical` sent
  eight notifications for the one Keycloak outage of 2026-10-15. The SLO burn
  says a user is affected; the causes are in Grafana when the operator looks.
  Rejected: per-alert tuning of `for:` durations, which still sends one
  notification per cause.
