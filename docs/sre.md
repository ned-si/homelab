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

## Latency

An internal objective, not part of the self-SLA or the error-budget policy:
99% of each app's public probes succeed within its threshold over 30 days, a
budget of 1% (about 7 hours a month). A failed probe counts as slow.

| App | Threshold | p95 at the choice |
| --- | --- | --- |
| `auth` | 0.25 s | 0.073 s |
| `media` | 0.25 s | 0.065 s |
| `archive` | 0.25 s | 0.098 s |
| `syncthing` | 0.25 s | 0.066 s |
| `cook` | 0.25 s | 0.106 s |
| `cinema` | 0.25 s | 0.074 s |
| `theater` | 0.25 s | 0.069 s |

A threshold is the smallest of 0.25, 0.5, 1, 2 and 5 s that is at least twice
the app's p95 probe duration, from `scripts/slo-latency-thresholds.sh`
([observability.md](observability.md#slos)), and is committed as a static
value. It changes only in a pull request that carries the script's output.
The p95 above covers the 3.2 days of probe data Prometheus held on
2026-10-16; rerun the script once 14 days exist. The state is
`slo:latency_budget_remaining:ratio_rate30d{app="<app>"}`. A slow burn that
lasts a day pages (`SLOLatencyBudgetBurnSlowPersistent`); an availability
burn of the same app silences the latency alerts, so one outage notifies once.

## RPO

| Data | RPO (promised) | What runs today |
| --- | --- | --- |
| Postgres (all CloudNativePG clusters) | 24 h | continuous WAL archiving, a segment at least every 5 minutes, plus a daily base backup |
| Files (Immich originals, Paperless, Syncthing, app configs) | 24 h | nightly restic to S3; Immich also to the NAS |
| Cluster state | last merged commit | git; etcd snapshots before risky changes |
| Media library | none | not backed up; re-acquirable by design |

The measure of the 24 h promise is the backup-freshness SLO: every restic
backup CronJob and every CloudNativePG cluster has a successful backup younger
than 26 hours 99% of the time over 30 days
(`slo:backup_freshness:ratio_rate30d{kind, namespace, target}`,
[backups.md: Freshness](backups.md#freshness)). A restic target stale for 15
minutes pages `BackupNotFresh`.

Details, schedules and rehearsed restores: [backups.md](backups.md#rpo-and-rto).

## RTO per tier

| Tier | What | RTO, service fault | RTO, restore from backup |
| --- | --- | --- | --- |
| 0 | Nodes and etcd, Cilium and the Gateway, NAS storage, Argo CD, cert-manager | 4 h ([runbooks/cold-start.md](runbooks/cold-start.md)) | 24 h: rebuild from git ([bootstrap.md](bootstrap.md)), not rehearsed end to end |
| 1 | `auth`, `media`, `archive`, `syncthing` | 4 h | 24 h, data back to the RPO |
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

A notification (ntfy) means a person has to do something. What automation
handles (a pod restart, an auto-rollback, a Talos upgrade, a corrected
drift, a Renovate automerge, a burn that ends by itself) notifies nobody: it
is visible in Grafana and on the Homelab / Automation dashboard. One root
cause sends one notification.

Every alert of a homelab PrometheusRule carries one of two labels, and CI
fails a rule without it (`scripts/ci/alertmanager-test.sh`):

| Class | Label | Goes to |
| --- | --- | --- |
| PAGE | `action: human` | ntfy |
| INFO | `action: auto` | Grafana only |

The chart rules (kube-prometheus-stack, tuppr) have no label: they are INFO
unless named in the PAGE table. An alert that needs no person and that no
automation handles is deleted, not kept as INFO.

PAGE, grouped by alert name (the persistent burns by app); repeated every
4 h while critical, every 24 h otherwise:

| Why a person | Alerts |
| --- | --- |
| Automation gave up or failed | `ArgoCDAppStillDegraded` (Degraded for 30 min: auto-rollback refused, skipped by the outage guard, or its revert failed), `ArgoCDSyncStuck` (OutOfSync 30 min after a failed sync), `TalosUpgradeFailed`, `TalosUpgradeNodeFailed`, `TalosUpgradeStuck`, `KubernetesUpgradeFailed`, `KubernetesUpgradeStuck`, `TupprOperatorAbsent`, `TalosConfigDrift` (nothing applies Talos config), `PodStuckNotRunningLongTerm` (6 h) |
| Backups | `BackupLockBroken` (old versions deletable), `BackupLockCheckStale`, `BackupNotFresh` (a restic CronJob without a success in 26 h), `BackupVerifyFailed`, `BackupVerifyStale`, `BackupVerifyDataStale`, `BackupVerifyMissing`, `CNPGBackupFailed`, `CNPGBaseBackupTooOld`, `CNPGBackupMetricsMissing`, `CNPGWALArchivingFailing`, `CNPGWALArchiveLag`, `CNPGMetricsAbsent`, `KubeJobFailed` of a `*-backup-*` Job |
| The physical world | `HomelabNodeDown` (NotReady 15 min), `HomelabNASDown` (unreachable 10 min: press the NAS power button), `etcdInsufficientMembers`, `etcdNoLeader`, `NodeFilesystemReadOnly`, `NodeEmmcWearHigh`, `NodeEmmcEndOfLife`, `NASPoolUnhealthy`, `NASPoolDeviceNotOnline`, `NASPoolDeviceErrors`, `NASSmartTestFailed`, `NASDiskHot`, `LANDeviceUnreachable`, `LANNewDeviceSeen` |
| Capacity (nothing grows a volume) | `PersistentVolumeNearlyFull`, `PersistentVolumeCriticallyFull`, `PersistentVolumeFillingUp`, `PrometheusTsdbVolumeNearlyFull`, `NodeFilesystemNearlyFull`, `NodeFilesystemCriticallyFull`, `NodeFilesystemInodesNearlyFull`, `NASPoolNearlyFull`, `NASPoolCriticallyFull`, `NASPoolFillingUp`, `NASScrubOverdue` |
| Expired credentials and accounts | `CertificateExpiringSoon` (a renewal failed), `CertificateExpiringVerySoon`, `CertificateNotReady`, `ArrIndexersFailing` (Prowlarr indexers failing for 6 h: login, cookie, locked account), `NASExporterFailing` (an API key revoked) |
| A user-facing burn that outlasted remediation | `SLOErrorBudgetBurnFastPersistent` (still failing after 30 min), `SLOErrorBudgetBurnSlowPersistent` (a slow burn for a day), `SLOLatencyBudgetBurnSlowPersistent` (up but slow for a day) |
| Monitoring went blind | `SLOProbesAbsent`, `SLOTargetProbeAbsent`, `KubeStateMetricsAbsent`, `NodeExporterAbsent`, `CertManagerMetricsAbsent`, `ArgoCDMetricsAbsent`, `NASExporterAbsent`, `LANInventoryFailing`, `LANInventoryAbsent`, `TalosDriftCheckStale`, `VulnEnrichmentStale`, `AlertmanagerNotificationsFailing`, `AlertmanagerHasNoReceiverConfigured` |
| Security | any `critical` alert labelled `category: security` |
| Heartbeat | `Watchdog`, to healthchecks.io every 5 minutes; healthchecks.io notifies ntfy when it stops |

INFO (`action: auto`): `SLOErrorBudgetBurnFast` and `SLOErrorBudgetBurnSlow`
(most burns end with a restart or a revert), `HomelabNodeNotReady` (a node
rebooting for an upgrade) and `HomelabNASUnreachable` (a switch flap), which
also feed the outage guard; `ArgoCDAppDegraded`, `ArgoCDSyncFailed` and
`ArgoCDAppOutOfSync` (auto-rollback and self-heal); `ServiceHasNoReadyBackend`,
`StatefulSetHasNoReadyReplica`, `PodStuckNotRunning`, `PodPendingTooLong`,
`PodNotReady`; and the chart's pod, workload and node alerts. The Homelab /
Automation dashboard marks them as annotations.

GitHub Actions post to ntfy directly only for a person's action: a failed or
refused `tofu` plan or apply (a destroy, a plan-only module with changes), a
`dast` regression, a failed `renovate-render`, a secret past its rotation
period (`secret-age`), a nightly `fuzz` finding. A corrected drift posts
nothing.

### Quiet hours

From 23:00 to 08:00 Europe/Zurich, every day, Alertmanager sends nothing to
ntfy (time interval `quiet-hours`, `mute_time_intervals` on every ntfy
route). Nothing is dropped: a group still firing at 08:00 notifies at its
next flush, within 5 minutes, once per group. A group that fired and
resolved overnight sends nothing; it stays in Alertmanager and Grafana.

What quiet hours do not cover:

- `GatewayDown` (half or more of the public hostnames down): receiver
  `ntfy-urgent`, the same topic, never muted.
- healthchecks.io posts to ntfy directly when the heartbeat stops, so a dead
  cluster or a dead house internet still notifies at night.
- The GitHub Actions failure posts (`dast`, `renovate-render`, `secret-age`, `fuzz`) go to ntfy
  directly, at priority low. In quiet hours they carry a `Delay` until 08:00
  Zurich (`scripts/ci/ntfy-quiet-delay.sh`), so ntfy delivers them then.
- `HomelabNodeNotReady` and `HomelabNASUnreachable` also go, unmuted, to a
  second topic (`ntfy-guard-url`, the topic plus `-guard`) that nobody
  subscribes to. The auto-rollback outage guard reads it, so it keeps
  holding reverts back during a night-time outage.

Inhibition hides the causes behind the alert that notified:

| While this fires | These are inhibited |
| --- | --- |
| `SLOErrorBudgetBurnFast` | the pod, workload and Argo CD alerts (pages included: the persistent burn covers the app) and `ServiceHasNoReadyBackend` of the app's namespace |
| `ServiceHasNoReadyBackend`, `StatefulSetHasNoReadyReplica` | the INFO pod, workload and Argo CD alerts of that namespace |
| `HomelabNodeNotReady` | the node and pod alerts with the same `node` label |
| `HomelabNASUnreachable` | every storage consumer: SLO burns, pods, workloads, Argo CD, CNPG, backups, the NAS exporter |
| any `critical` | the `warning` of the same alert and namespace |
| the critical alert of a certificate, PVC, node filesystem, NAS pool or eMMC | its milder alerts |

The routes, inhibit rules and timings are in
`platform/kube-prometheus-stack/values.yaml`. CI replays scenarios against a
real Alertmanager and counts notifications (`scripts/ci/alertmanager-test.sh`,
`tests/alertmanager/`): the Keycloak outage of 2026-10-15 sends none within
the remediation window and one past it; an auto-rollback that works sends
none, one that fails sends one; a node reboot and a NAS flap reach only the
guard topic, a node or the NAS down for good sends one; the Watchdog reaches
the heartbeat. It also checks that every ntfy route mutes `quiet-hours`, and
that a node down during quiet hours notifies once after they end.
Adding a PAGE alert is a change to this page, to
`tests/alertmanager/routes.txt` and to [runbooks/alerts/](runbooks/alerts/README.md)
in the same pull request.

Every `action: human` rule links its runbook in the `runbook_url`
annotation: what it means, how to confirm, what to do, how to tell it is
resolved. The CI rule `alert-runbooks` (`scripts/ci/repo_policy.py`) fails a
paging rule without one, a missing page, a page with no rule, or a chart rule
that pages by name without a row in the index. The CI rule `alert-tests`
fails an alert without a promtool test (`tests/prometheus/`).

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
| Press the NAS power button | after every power loss | the NAS does not power on by itself, and changing its firmware setting needs a display, so a GPU swap | the `HomelabNASDown` alert says when; a UPS, or a relay on the ATX power header |
| Copy `talosconfig`, the admin kubeconfig and the age key into the password manager | after each is created or rotated | the password manager is the off-machine copy and has no API in use here | accepted; the alternative is another secret store with its own bootstrap problem ([secrets.md](secrets.md#why-it-is-like-this)) |
| Upgrade the Immich database image | on a VectorChord release Immich supports, or a PostgreSQL major | a VectorChord update needs `ALTER EXTENSION vchord UPDATE` and a reindex, a major an in-place upgrade; both are one-way, so Renovate excludes `cloudnative-vectorchord` | [runbooks/immich-upgrade.md](runbooks/immich-upgrade.md#updating-the-database-image) |

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
- Latency as a second, internal objective: "up but unusable" counts, but the
  self-SLA and the budget policy stay one number. Its thresholds are static
  and twice the measured p95, so a regression cannot move its own bar and
  normal jitter does not spend the budget. Rejected: a p95 alert (no budget,
  no burn rate) and a dynamic baseline (drifts with the regression it should
  catch).
- Triggers as thresholds, not judgement: they are checkable by a script and
  by an agent, and they cannot be argued with during an incident.
- Page when a person has to act, not when something broke: sending every
  `warning` and `critical` sent eight notifications for the one Keycloak
  outage of 2026-10-15, and most failures here are fixed by a restart, a
  revert or a retry before anyone could look. A failure pages once automation
  had its chance (the persistent and "still" alerts), or when no automation
  exists for it (hardware, capacity, credentials, backups). Rejected: paging
  on every SLO burn, which woke the operator for outages auto-rollback had
  already ended; and per-alert tuning of `for:` durations, which still sends
  one notification per cause.
