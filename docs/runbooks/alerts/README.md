# Alert runbooks

One page per paging alert (`action: human`, [sre.md](../../sre.md#paging)).
Each rule links its page in the `runbook_url` annotation, and CI fails a
paging rule without one, a missing page, a page that is not listed here, or a
page for an alert that no longer pages (rule `alert-runbooks` in
[`scripts/ci/repo_policy.py`](../../../scripts/ci/repo_policy.py)).

A new paging alert needs, in the same pull request: the rule with
`runbook_url: https://github.com/ned-si/homelab/blob/main/docs/runbooks/alerts/<AlertName>.md`,
the page (same sections as the others) and a line below.

## Before you start

Every page assumes this shell on the Mac, from the repository root, with
`kubectl` on the cluster's admin context (or the tailnet one,
[remote-access.md](../../remote-access.md)):

```sh
cd ~/repos/homelab
kubectl get nodes
export TALOSCONFIG="$PWD/talos/clusterconfig/talosconfig"   # task talos:genconfig
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 > /dev/null 2>&1 &
PF=$!
q() { curl -s -m 15 http://localhost:9090/api/v1/query --data-urlencode "query=$1" | jq -c '.data.result[] | [.metric, .value[1]]'; }
q 'ALERTS{alertstate="firing", action="human"}'
```

Expected: four nodes, then one line per firing paging alert, with its labels. `q '<PromQL>'`
is the query helper the pages use. When done: `kill "$PF"`.

Then the snapshot, with the alert's name:

```sh
scripts/triage.sh <AlertName>
```

It prints the state (`scripts/status.sh`), Warning events of the last 30
minutes, firing alerts, what merged to `main` in the last 6 hours (most
breakage follows a merge) and the alert's Confirm section below. Exit 1
means something is red. With an Argo CD application name instead, it prints
that application's failing conditions and resources.

- Alertmanager (silences, what is inhibited):
  `kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093`,
  then `http://localhost:9093`.
- Grafana: `https://grafana.lilalala.com`. Dashboards named on the pages:
  Homelab / Overview (`/d/homelab-overview`), Homelab / Automation
  (`/d/homelab-automation`), Homelab / Data protection
  (`/d/homelab-data-protection`), Homelab / Storage (`/d/homelab-storage`),
  Homelab / Nodes (`/d/homelab-nodes`), Homelab / LAN (`/d/homelab-lan`),
  Homelab / Security (`/d/homelab-security`).
- Planned work while an alert fires: silence it with
  `scripts/maintenance-silence.sh` ([observability.md](../../observability.md#silencing)).
- `talosctl` needs the LAN; `kubectl` also works over the tailnet
  ([remote-access.md](../../remote-access.md)).
- A one-screen view without Grafana: `scripts/status.sh` (the first part of
  `scripts/triage.sh`).

## Automation gave up

- [ArgoCDAppStillDegraded](ArgoCDAppStillDegraded.md): an app Degraded for 30 minutes, not reverted
- [ArgoCDSyncStuck](ArgoCDSyncStuck.md): a failed sync, still OutOfSync after 30 minutes
- [PodStuckNotRunningLongTerm](PodStuckNotRunningLongTerm.md): a container unable to start for 6 hours
- [TalosConfigDrift](TalosConfigDrift.md): a node runs a machine config main does not render

## Backups

- [BackupLockBroken](BackupLockBroken.md): old backup versions can be deleted
- [BackupLockCheckStale](BackupLockCheckStale.md): no passing lock test in 8 days
- [BackupNotFresh](BackupNotFresh.md): a restic CronJob without a successful run in 26 hours
- [BackupVerifyFailed](BackupVerifyFailed.md): a restore test failed
- [BackupVerifyStale](BackupVerifyStale.md): no passing weekly restore test in 8 days
- [BackupVerifyDataStale](BackupVerifyDataStale.md): no monthly pack read in 36 days
- [BackupVerifyMissing](BackupVerifyMissing.md): no restore test result on record
- [CNPGBackupFailed](CNPGBackupFailed.md): the newest Postgres base backup failed
- [CNPGBaseBackupTooOld](CNPGBaseBackupTooOld.md): no Postgres base backup in 26 hours
- [CNPGBackupMetricsMissing](CNPGBackupMetricsMissing.md): a Postgres instance without the backup sidecar
- [CNPGWALArchivingFailing](CNPGWALArchivingFailing.md): WAL archiving fails
- [CNPGWALArchiveLag](CNPGWALArchiveLag.md): WAL segments pile up
- [CNPGMetricsAbsent](CNPGMetricsAbsent.md): no Postgres instance is scraped

## The physical world

- [GatewayDown](GatewayDown.md): half or more of the public hostnames down for 5 minutes
- [HomelabNodeDown](HomelabNodeDown.md): a node NotReady for 15 minutes
- [KyvernoReportsStale](KyvernoReportsStale.md): no Kyverno background scan for 3 hours
- [HomelabNASDown](HomelabNASDown.md): the NAS unreachable for 10 minutes
- [NodeFilesystemReadOnly](NodeFilesystemReadOnly.md): a node filesystem remounted read-only
- [NodeEmmcWearHigh](NodeEmmcWearHigh.md): an eMMC past 80% of its rated wear
- [NodeEmmcEndOfLife](NodeEmmcEndOfLife.md): an eMMC at end of life
- [NASPoolUnhealthy](NASPoolUnhealthy.md): a ZFS pool not healthy
- [NASPoolDeviceNotOnline](NASPoolDeviceNotOnline.md): a pool device not ONLINE
- [NASPoolDeviceErrors](NASPoolDeviceErrors.md): read, write or checksum errors on a pool device
- [NASSmartTestFailed](NASSmartTestFailed.md): a disk failed its SMART self-test
- [NASDiskHot](NASDiskHot.md): a disk above 65 °C
- [LANDeviceUnreachable](LANDeviceUnreachable.md): the router or the BMC does not answer
- [LANNewDeviceSeen](LANNewDeviceSeen.md): new hardware on the LAN

## Capacity

- [PersistentVolumeNearlyFull](PersistentVolumeNearlyFull.md): a PVC over 85% full
- [PersistentVolumeCriticallyFull](PersistentVolumeCriticallyFull.md): a PVC over 95% full
- [PersistentVolumeFillingUp](PersistentVolumeFillingUp.md): a PVC full within 24 hours
- [PrometheusTsdbVolumeNearlyFull](PrometheusTsdbVolumeNearlyFull.md): the Prometheus volume nearly full
- [NodeFilesystemNearlyFull](NodeFilesystemNearlyFull.md): a node filesystem over 85% full
- [NodeFilesystemCriticallyFull](NodeFilesystemCriticallyFull.md): a node filesystem over 92% full
- [NodeFilesystemInodesNearlyFull](NodeFilesystemInodesNearlyFull.md): a node filesystem under 10% free inodes
- [NASPoolNearlyFull](NASPoolNearlyFull.md): a NAS pool over 80% used
- [NASPoolCriticallyFull](NASPoolCriticallyFull.md): a NAS pool over 90% used
- [NASPoolFillingUp](NASPoolFillingUp.md): a NAS pool full within 30 days
- [NASScrubOverdue](NASScrubOverdue.md): no finished scrub in 40 days

## Expired credentials and accounts

- [CertificateExpiringSoon](CertificateExpiringSoon.md): a certificate expires in under 21 days
- [CertificateExpiringVerySoon](CertificateExpiringVerySoon.md): a certificate expires in under 7 days
- [CertificateNotReady](CertificateNotReady.md): a certificate not Ready for an hour
- [HubbleCertRenewalStale](HubbleCertRenewalStale.md): the Hubble certificates not renewed for 130 days
- [ArrIndexersFailing](ArrIndexersFailing.md): Prowlarr indexers failing for 6 hours
- [NASExporterFailing](NASExporterFailing.md): the TrueNAS API refuses the exporter

## A user-facing burn that outlasted remediation

- [SLOErrorBudgetBurnFastPersistent](SLOErrorBudgetBurnFastPersistent.md): an app failing for 30 minutes
- [SLOErrorBudgetBurnSlowPersistent](SLOErrorBudgetBurnSlowPersistent.md): an app burning its budget for a day
- [SLOLatencyBudgetBurnSlowPersistent](SLOLatencyBudgetBurnSlowPersistent.md): an app up but slow for a day

## Monitoring went blind

- [SLOProbesAbsent](SLOProbesAbsent.md): no public probe results at all
- [SLOTargetProbeAbsent](SLOTargetProbeAbsent.md): no probe results for one app
- [KubeStateMetricsAbsent](KubeStateMetricsAbsent.md): kube-state-metrics not scraped
- [NodeExporterAbsent](NodeExporterAbsent.md): node-exporter not scraped
- [CertManagerMetricsAbsent](CertManagerMetricsAbsent.md): cert-manager not scraped
- [ArgoCDMetricsAbsent](ArgoCDMetricsAbsent.md): Argo CD not scraped
- [NASExporterAbsent](NASExporterAbsent.md): truenas-exporter not scraped
- [LANInventoryFailing](LANInventoryFailing.md): no ARP scan for 30 minutes
- [LANInventoryAbsent](LANInventoryAbsent.md): lan-inventory not scraped
- [HubbleRelayPeersNotReady](HubbleRelayPeersNotReady.md): the Hubble relay misses some nodes
- [HubbleRelayAbsent](HubbleRelayAbsent.md): the Hubble relay not scraped
- [LogPipelineDiscarding](LogPipelineDiscarding.md): Vector discards log events
- [SigNozCollectorAbsent](SigNozCollectorAbsent.md): no SigNoz collector up
- [TalosDriftCheckStale](TalosDriftCheckStale.md): no Talos drift check in 2 days
- [VulnEnrichmentStale](VulnEnrichmentStale.md): no KEV/EPSS enrichment in 3 days
- [AlertmanagerNotificationsFailing](AlertmanagerNotificationsFailing.md): Alertmanager cannot deliver
- [AlertmanagerHasNoReceiverConfigured](AlertmanagerHasNoReceiverConfigured.md): Alertmanager sent nothing in 6 hours
- [TetragonAgentMissing](TetragonAgentMissing.md): a node without a Tetragon agent for 30 minutes

## Chart rules that page

These come from the kube-prometheus-stack and tuppr charts, carry no
`action` label and page by name ([sre.md](../../sre.md#paging)). The
kube-prometheus-stack rules carry the chart's `runbook_url` (linked below);
the tuppr rules carry none, so their notification has no link. CI fails an
alert on an `ntfy` line of `tests/alertmanager/routes.txt` that has neither a
page nor a row here. The steps for this cluster are:

| Alert | Upstream | Where |
| --- | --- | --- |
| `etcdInsufficientMembers`, `etcdNoLeader` | [etcdInsufficientMembers](https://runbooks.prometheus-operator.dev/runbooks/etcd/etcdinsufficientmembers), [etcdNoLeader](https://runbooks.prometheus-operator.dev/runbooks/etcd/etcdnoleader) | [talos-cheatsheet.md](../../talos-cheatsheet.md#4-troubleshooting) (`etcd members`, `etcd status`), then [HomelabNodeDown](HomelabNodeDown.md) for the missing member |
| `TalosUpgradeFailed`, `TalosUpgradeNodeFailed`, `TalosUpgradeStuck`, `KubernetesUpgradeFailed`, `KubernetesUpgradeStuck`, `TupprOperatorAbsent` | none | [talos-cheatsheet.md](../../talos-cheatsheet.md#talos-and-kubernetes-upgrades) (watch, pause, recovery) |
| `KubeJobFailed` of a `*-backup-*` Job | [KubeJobFailed](https://runbooks.prometheus-operator.dev/runbooks/kubernetes/kubejobfailed) | [backups.md](../../backups.md#schedule): the Job's log (`kubectl -n <namespace> logs job/<job_name>`), then a manual run (`kubectl -n <namespace> create job --from=cronjob/<cronjob> <cronjob>-manual`) |
| Any `critical` rule labelled `category: security` (none today) | the rule's own | [threat-model.md](../../threat-model.md) |

## Security (runtime detections)

- [RuntimeEscapeToHost](RuntimeEscapeToHost.md): a user namespace or capabilities gained (T1611)
- [RuntimePrivilegeEscalation](RuntimePrivilegeEscalation.md): a process set its uid or gid to root (T1068)
- [RuntimeKernelModuleLoad](RuntimeKernelModuleLoad.md): a kernel module loaded from a file (T1547.006)
- [RuntimeUnexpectedBPF](RuntimeUnexpectedBPF.md): an unexpected process loading BPF (T1014)
