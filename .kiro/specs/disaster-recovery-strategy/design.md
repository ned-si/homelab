# Design: disaster-recovery-strategy

## Overview

Keep the cold site and make it real. Nothing new runs all the time. A loss
of the house or the NAS is answered by rebuilding the cluster from git onto
rented arm64 nodes, restoring the data from the S3 bucket, and coming home
later by the same path. Every response is rehearsed on a calendar, the
measured times go into one file in git, and a CronJob puts them on the
Homelab / Data protection dashboard. Two gaps that no rehearsal closes get
their own work: break-glass copies that survive a fire, and backups that
survive the loss of the AWS account.

Figures below were read on 2026-11-03 from the live Prometheus
(datasource `prometheus`) unless a source is linked. Cloud prices exclude
VAT and change; task 7 prices the chosen provider again.

## Scenarios

The proposed "Disaster scenarios" table for `docs/sre.md` (task 1).

| Scenario | Signal | Lost | Survives | Response |
| --- | --- | --- | --- | --- |
| One node | `HomelabNodeDown` (NotReady 15 min); `etcdInsufficientMembers` if a second control plane goes | nothing: nodes hold no data ([node-replacement.md](../../../docs/runbooks/node-replacement.md)) | every volume on the NAS, etcd on the other two control planes | reschedule happens on its own; reflash with [node-replacement.md](../../../docs/runbooks/node-replacement.md) |
| The NAS | `HomelabNASDown` (unreachable 10 min), `NASPoolUnhealthy`, `NASPoolDeviceNotOnline` | every iSCSI volume, the media share, the NAS copy of the Immich library | S3 (restic, Barman), git, the nodes | pool intact on dead hardware: move the disks to a replacement and import the pool (RPO 0); pool gone: the DR site, `docs/runbooks/site-lost.md` (task 7) |
| The house (fire, theft, a power cut longer than the tier 1 RTO) | the healthchecks.io heartbeat stops and notifies ntfy directly, at night too | nodes, NAS, router, and whatever was in the house, possibly the Mac with `~/homelab-backups/` (local dumps, etcd snapshots) and the phone with the TOTP apps | S3, git on GitHub, the password manager | a short power cut: [cold-start.md](../../../docs/runbooks/cold-start.md); otherwise the DR site, `docs/runbooks/site-lost.md` |
| The AWS account (closed, locked, suspended for billing) | `BackupNotFresh`, `CNPGWALArchivingFailing`, `CNPGBackupFailed`; the `tofu` workflow posts a failed plan | every off-site backup and its version history, the OpenTofu state bucket `ned-si-homelab-tofu-state`, the GitHub OIDC roles, the AWS cost dashboard | every live app and its data at home, git | `docs/runbooks/aws-account-lost.md` (task 5) |
| The operator | a member of the household notices; pages go unanswered | the knowledge, the Mac, the phone | automation (Renovate, auto-rollback, backups, restore tests), the password manager through emergency access | `docs/runbooks/operator-unavailable.md` (task 4) |

Variants that need no row of their own:

- The Turing Pi 2 board powers all four slots, so a dead board loses every
  node at once. The data on the NAS is intact; the response is a rebuild from
  git on a replacement board, the same steps as the DR site without the data
  restore.
- Two control planes lost: etcd has no quorum. The response is an etcd
  snapshot restore ([cold-start.md](../../../docs/runbooks/cold-start.md#etcd-snapshot-and-restore))
  if a recent snapshot exists, otherwise a rebuild from git. Snapshots are
  taken by hand only ([backups.md](../../../docs/backups.md#what-is-not-backed-up)).

## Targets per tier

Tiers and the existing values come from
[sre.md](../../../docs/sre.md#rto-per-tier). The new part is the scenario
axis and the MTTR column, which starts empty.

| Scenario | RPO | RTO tier 0 | RTO tier 1 | RTO tier 2 | MTTR |
| --- | --- | --- | --- | --- | --- |
| One node | none (no data on nodes) | 4 h (service fault) | 4 h | 72 h | not measured |
| The NAS, pool intact | none | 4 h after the replacement hardware is in place | 4 h after tier 0 | 72 h | not measured |
| The NAS, pool lost | Postgres about 5 min (`archive_timeout`); files 24 h; media all | 24 h on the DR site | 24 h | 72 h, without the media library | not measured |
| The house | same as the NAS, pool lost; plus the local dumps and etcd snapshots | 24 h on the DR site | 24 h | 72 h, without the media library | not measured |
| The AWS account | live data none; backup history all | no outage | no outage | no outage | not measured; target: backups fresh again within 24 h |
| The operator | none while the house stands | no promise | the household can restore photos and documents to a laptop within 7 days | no promise | not measured |

Today the house-lost RTO is the lead time of new hardware plus an untimed
rebuild: days to weeks. The 24 h above holds only once tasks 7 and 8 are
done and a rehearsal has measured it.

The measured pieces so far:

| Piece | Measured | Source |
| --- | --- | --- |
| Postgres recovery from S3 into a new cluster | 90 s (`lidarr-postgresql`) to 431 s (`sonarr-postgresql`) per cluster; `immich-db` 297 s, `keycloak-db` 363 s | `backup_verify_restore_seconds`, last weekly run |
| First upload of the Immich library | 270 GiB in 2 h 14 min, limited by reading the NAS | [backups.md](../../../docs/backups.md#setting-it-up-from-scratch) |
| Full Immich restore from S3 | not measured; "about 1.5 h" is extrapolated from a 410 MiB sample | [backups.md](../../../docs/backups.md#rpo-and-rto) |
| Node replacement | not measured; the runbook says about 45 minutes | [node-replacement.md](../../../docs/runbooks/node-replacement.md) |
| Cold start | not measured; the runbook says 45 minutes to 2 hours | [cold-start.md](../../../docs/runbooks/cold-start.md) |

## Site options

The house-lost scenario decides between them; a node or an AWS account loss
needs no second site.

Inputs: the bucket holds 264 GiB in Glacier Instant Retrieval and 35 GiB in
Standard (`aws_s3_bucket_size_bytes_average`). AWS cost in October 2026 was
$3.07, of which S3 $2.51 (`aws_cost_last_month_usd`); the November forecast
is $5.40 (`aws_cost_month_forecast_usd`, linear). The cluster requests 9.3
CPU and 27.3 GiB of memory, SigNoz and monitoring included
(`kube_pod_container_resource_requests`). Reading the whole Immich repository
back out of S3 costs about $30 in retrieval and egress
([backups.md](../../../docs/backups.md#rpo-and-rto)). Hetzner Cloud prices
from the [costgoat Hetzner calculator](https://costgoat.com/pricing/hetzner)
(October 2026, after the June 2026 price change): CAX31 (8 arm64 vCPU, 16 GB)
€20.99 a month, CAX41 (16 vCPU, 32 GB) €40.99 a month or €0.0657 an hour,
block storage €0.0572 per GB and month.

| | Cold, home hardware only (today) | Cold, rebuilt on rented nodes (recommended) | Warm | Hot |
| --- | --- | --- | --- | --- |
| What runs outside the house | nothing | nothing; nodes are rented by the hour after a loss | one small cluster, restoring the latest backups on a schedule; Postgres as CNPG replica clusters replaying WAL from S3 | a full second cluster fed continuously, with DNS failover |
| Standing cost a month | about $3 to $5.40 (S3) | the same | the same plus about €44 (CAX31 and 400 GB) to €64 (CAX41 and 400 GB), plus the scheduled restores: an incremental restore is not measured, a full Immich re-read is about $30 | at least the warm figure plus a site link and continuous replication traffic; sized for every tier 0 and 1 app |
| Cost per rehearsal or incident | a rehearsal is impossible without spare hardware | an 8 h rehearsal: about €0.55 of CAX41, €0.25 of storage, about $30 for the Immich read; a 3-day incident about €7 plus the same $30 | small: the data is already there | none |
| House-lost RTO | hardware lead time (days to weeks) plus an untimed rebuild | target 24 h for tiers 0 and 1, to be measured | hours: switch DNS, catch up the files written since the last scheduled restore | minutes |
| RPO in a house loss | Postgres about 5 min, files 24 h | the same | the same; Postgres replica clusters keep about 5 min | Postgres seconds; files depend on the sync |
| Effort to build | none | the DR site tree and its rehearsal switches (task 7), the runbook, two rehearsals a year | everything in the column before, plus a second cluster that runs all the time | everything warm needs, plus per-app replication between sites, failover rules and split-brain handling |
| Effort to run | none | about a day per full rehearsal, twice a year | a second cluster to upgrade (Talos, Kubernetes, charts), monitor and pay for, with one operator | as warm, plus every change tested on two live sites |
| Fit with the design | | reuses git, the bucket and the restore path the weekly tests already prove | a second set of alerts and upgrades for one operator | contradicts single replica and `ReadWriteOnce` volumes on one NAS ([tech.md](../../steering/tech.md#constraints)) |

### Recommendation

Cold, rebuilt on rented nodes.

- It moves the house-lost RTO from weeks to a 24 h target without a
  standing cost. Hourly billing makes a three-day incident cost about as much
  as one month of S3 today, plus the one-off Immich read.
- Warm buys hours instead of a day for about 10 to 20 times today's whole
  AWS bill, every month, and doubles what one person has to upgrade and
  watch. A house loss is rare, and one already spends many months of error
  budget; the extra hours do not change what the household lives through.
- Hot needs every app replicated across sites, which the single-replica,
  one-NAS design cannot do without rewriting most apps. Rejected.
- Cold with home hardware only cannot be rehearsed and has no RTO anyone can
  state. It stays the way home is rebuilt after a DR period, not the first
  response.

Review it, in one pull request that changes `docs/decisions.md`, when two
consecutive full rehearsals exceed the tier 1 RTO of the house-lost
scenario, when the household asks for a shorter outage, or when the chosen
provider stops offering hourly arm64 nodes.

## The DR site

What a rebuild away from the house needs, built in task 7.

- **Talos.** A second talhelper config for the DR nodes (provider image from
  the Image Factory, arm64), with its own cluster secrets: the DR cluster is
  a new cluster, not a member of the home one.
- **Site-specific values.** Every value in
  [architecture.md, Site-specific values](../../../docs/architecture.md#site-specific-values)
  gets a DR value or is dropped: WAN IP (the DR node's public address), API
  VIP and node addresses, LoadBalancer pools, the NAS address (none).
- **Storage.** No NAS, so no democratic-csi, `iscsi-volumes` or
  `nfs-storage`. A local provisioner on the node's disk serves the claims.
  Default: StorageClasses named `iscsi` and `iscsi-retain`, so no app
  manifest changes (open question 10).
- **What it leaves out.** The media library and everything that only serves
  it at home; SigNoz (logs are disposable by decision,
  [backups.md](../../../docs/backups.md#what-is-not-backed-up)).
- **Data.** CNPG Clusters bootstrap with `recovery` from the Barman Cloud
  archive; restic restores into the claims before each app starts, the order
  given by the tiers.
- **Rehearsal switches** (requirement 8). The verifier key only, so every
  write to the bucket is refused by IAM. Backup CronJobs suspended, CNPG
  Clusters without `spec.plugins`. No external-dns, no Argo CD
  notifications, no ntfy receivers and no Watchdog route (a rehearsal must
  never ping healthchecks.io: it would hide a real outage at home), no
  Tailscale operator. A self-signed issuer instead of Let's Encrypt.
- **Real loss.** The same tree with the writer and `cnpg` keys, backups on,
  `serverName` `<cluster>-dr<n>` and restic host `<app>-dr<n>`, so nothing
  overwrites the home archives; external-dns points the public names at the
  DR node; Let's Encrypt DNS-01 works from anywhere.
- **Coming home.** Rebuild home from git, then restore from the DR site's
  archives as a planned cutover, the same path as the Talos cutover of
  October 2026 ([decisions.md](../../../docs/decisions.md#talos-built-as-a-new-cluster)).

How the DR tree is laid out in git (a second cluster directory, Kustomize
components or overlays) is settled in task 7. Two constraints: it is rendered
into `deploy/` like the rest, and repo-policy checks requirement 8 over that
render.

## Off-site inventory

The proposed "Off-site inventory" for `docs/backups.md` (task 1). Each cell
names the copy that survives the scenario. Items are named by file and key,
never by value.

| Item | Copies today | One node | The NAS | The house | The AWS account | The operator |
| --- | --- | --- | --- | --- | --- | --- |
| SOPS age key | the Mac (`~/.config/sops/age/keys.txt`), the password manager, `argo/sops-age` ([secrets.md](../../../docs/secrets.md#the-key)); also the `bootstrap` OpenTofu state | all | all three | password manager | all three | password manager, through emergency access |
| `talosconfig` | the password manager, `~/homelab-backups/talos/`; regenerated by `task talos:genconfig` from `talos/talsecret.sops.yaml` and the age key | all | all | password manager, or git and the age key | all | password manager |
| `RESTIC_PASSWORD` | `platform/secrets/s3-backup.sops.yaml` (git, needs the age key), the password manager | all | all | password manager, or git and the age key | all | password manager |
| `TOFU_STATE_PASSPHRASE` | the password manager, the Mac's working copy; the Actions secret cannot be read back | all | all | password manager | not needed: the state is gone with the account | password manager |
| Immich library | live on the NAS, the NAS restic repository, S3 `immich/library` | all | S3 | S3 | live and the NAS copy | S3 or the NAS, with `RESTIC_PASSWORD` |
| Databases | live on the NAS; Barman WAL and base backups in S3 `cnpg/`; `pg_dump` of Mealie, Home Assistant and the four *arr clusters in restic; dumps by hand on the Mac | all | S3 | S3 | live, and the Mac's dumps if recent | S3 |
| Cluster configuration | git on GitHub, every clone | all | all | GitHub | all | GitHub |
| Break-glass credentials | the password manager | all | all | password manager, if its own recovery is outside the house (open question 7) | all | emergency access |

Gaps:

- **The AWS account and the house together.** The Immich library and every
  database exist only in S3 once the house is gone; `immich-db` and
  `keycloak-db` have no logical dump at all, only Barman. Task 5 adds a
  second copy at another provider if the operator agrees (open question 4).
- **The recovery of the password manager.** Its master password, its second
  factor and the AWS root MFA must not all depend on a phone in the house
  (open question 7).
- **Emergency access.** Not set up yet; task 4 adds it to the break-glass
  check.

## Rehearsal calendar

The proposed calendar for `docs/backups.md` (task 1). Live work keeps the
operator's rule: Monday to Friday, daytime, Zurich.

| Rehearsal | Scenario | Interval | Where | Measures |
| --- | --- | --- | --- | --- |
| `backup-verify` (exists) | data of every scenario | weekly, Saturday and Sunday evenings | home cluster | restore per CNPG cluster, restic samples, the bucket lock |
| `dr-rebuild` CI (#723, task 6) | tier 0 from git | monthly, first Tuesday | GitHub Actions, Talos in QEMU | time from empty nodes to infrastructure and platform Healthy, without data; a lower bound for tier 0 |
| Break-glass check (task 4) | the house, the AWS account, the operator | quarterly: January, April, July, October | the Mac and the password manager | each item of the inventory works; emergency access still set up |
| Node replacement (task 9) | one node | twice a year: March and September, `homelab-w-1` first, then a control plane in turn | home cluster | reset to `Ready`, and to every tier 1 probe green |
| Full rebuild (#723, task 8) | the NAS, the house | twice a year: May and November | rented nodes at the DR provider | each tier's time against its RTO, the full Immich restore, the RPO reached |
| AWS account tabletop | the AWS account | yearly, June | desk: walk `docs/runbooks/aws-account-lost.md`; with a second copy, restore a sample from it | pass or fail, and the steps that did not match |
| Operator walk-through | the operator | yearly, December | the trusted person, with `docs/runbooks/operator-unavailable.md` | one album and one document restored to a laptop |

## Measurement

One record in git, two readers.

- `ci/dr-scenarios.tsv`: one line per scenario: name, interval in days, RTO
  per tier in seconds. The source of the sre.md targets and of the overdue
  alert.
- `ci/dr-rehearsals.tsv`: one line per run: date (UTC), scenario, result
  (`pass`, `fail`, `partial`), seconds per tier (`-` when not part of the
  run), RPO reached per data class in seconds, and the pull request or run
  URL. A manual rehearsal is recorded by the pull request that adds its line;
  that pull request is the report.
- `scripts/dr-mttr.sh` prints the MTTR per scenario and tier (the mean of the
  last three passing runs). The sre.md column is that output; repo-policy
  `dr-mttr-source` fails when they differ.
- CronJob `dr-rehearsal-report` (namespace `backup-verify`, hourly): a
  ConfigMap generated from both files, plus the last three completed runs of
  `dr-rebuild.yaml` and their step times from the public GitHub API (no
  token; a public repository's runs and jobs are readable without one). It
  pushes to the existing Pushgateway, job `dr-rehearsal`. Needs an egress
  rule to `api.github.com` in that namespace.

| Metric | Meaning |
| --- | --- |
| `dr_rehearsal_last_timestamp_seconds{scenario}` | end of the last run |
| `dr_rehearsal_success{scenario}` | 1 when the last run passed |
| `dr_rehearsal_duration_seconds{scenario,tier}` | the last run's time per tier |
| `dr_rehearsal_mttr_seconds{scenario,tier}` | mean of the last three passing runs |
| `dr_rehearsal_rto_seconds{scenario,tier}` | the target, from `ci/dr-scenarios.tsv` |
| `dr_rehearsal_rpo_seconds{scenario,data}` | data age at the restore point |
| `dr_rehearsal_interval_seconds{scenario}` | the calendar interval |

`DRRehearsalOverdue` (warning, `action: human`): the last run is older than
the interval plus 14 days. A person has to schedule the rehearsal, so it
pages; once, then every 24 h like every other warning
([sre.md](../../../docs/sre.md#paging)). The dashboard gets a row "Disaster
recovery": per scenario the last run, its result, duration against RTO per
tier, the MTTR and the next due date.

## Components

| Component | Change | Task |
| --- | --- | --- |
| `docs/decisions.md` | entry "Disaster recovery: a cold site, rebuilt on rented nodes" | 1 |
| `docs/sre.md` | "Disaster scenarios" table; the RTO table gains the scenario axis and the MTTR column | 1 |
| `docs/backups.md` | "Off-site inventory", "Rehearsal calendar"; "Known gaps" updated | 1 |
| `docs/roadmap.md` | the "Recoverable from git alone" theme points at this spec | 1 |
| `ci/dr-scenarios.tsv`, `ci/dr-rehearsals.tsv`, `scripts/dr-mttr.sh` | the record | 2 |
| `scripts/ci/repo_policy.py` | `dr-rehearsals`, `dr-runbooks`, `dr-mttr-source` | 2 |
| `docs/runbooks/dr-rehearsal.md` | how to run and record a rehearsal; the pull request template | 2 |
| `platform/backup-verify/dr-rehearsal-report.yaml` | CronJob, ConfigMap generator, egress policy | 3 |
| `platform/backup-verify/alerts.yaml`, `tests/prometheus/dr_rehearsal_test.yaml`, `tests/alertmanager/routes.txt`, `docs/runbooks/alerts/DRRehearsalOverdue.md` | the overdue alert | 3 |
| `platform/kube-prometheus-stack/dashboards/homelab-data-protection.json` | the "Disaster recovery" row | 3 |
| `scripts/dr-offsite-check.sh`, `docs/runbooks/operator-unavailable.md` | the break-glass check, the household runbook | 4 |
| `docs/runbooks/aws-account-lost.md`; optionally the second copy | the AWS scenario | 5 |
| `.github/workflows/dr-rebuild.yaml` | monthly rebuild in CI, on the QEMU harness of `scripts/ci/talos-upgrade-rehearsal.sh` | 6 |
| the DR tree, its Talos config, `docs/runbooks/site-lost.md` | the DR site | 7 |
| `scripts/dr-rehearsal.sh` | timed full rehearsal, preflight for requirement 8 | 8 |

## Decisions

| Decision | Rejected | Why |
| --- | --- | --- |
| Cold site, rebuilt on rented nodes | warm standby, hot replica, cold with home hardware only | see [Recommendation](#recommendation) |
| MTTR from rehearsals only, the last three passing runs | estimates in the docs; the mean of every run ever | an estimate cannot be checked; old runs describe a cluster that no longer exists |
| One TSV record in git, pushed by a CronJob | results only in the Pushgateway; a database of runs | the Pushgateway keeps only the last value and Prometheus at most 30 days, but rehearsals are months apart; a pull request per run is also the report |
| CI results read from the public GitHub API | a cluster credential in GitHub; a pull request per CI run | GitHub holds no cluster credentials ([decisions.md](../../../docs/decisions.md#drift-detection-without-cluster-credentials-in-github)); a monthly automated pull request is noise |
| `DRRehearsalOverdue` pages | INFO only | only a person can schedule a full rehearsal, and an INFO alert nobody reads lets the calendar rot |
| Rehearsals with the verifier key only | the writer key with a separate prefix | IAM refuses every write, so no mistake in the DR tree can touch the backups |
| #723 inside this spec (tasks 6 and 8) | its own spec | the rehearsal is the measurement this strategy depends on; two specs would share one calendar and one record |

## Error handling

- A rehearsal fails midway: its line says `fail` or `partial` with the tiers
  it reached, and the pull request names the gap and opens an issue. The DR
  nodes are deleted at the end either way (`scripts/dr-rehearsal.sh` deletes
  them on exit).
- The GitHub API is unreachable or rate-limited: the CronJob pushes the TSV
  values and skips the CI runs; `dr-rebuild` then goes overdue by the normal
  rule.
- A rehearsal exceeds an RTO: the target is not raised in that pull request
  (requirement 2.3); two in a row trigger the decision review (requirement 3.3).
- A real loss during a rehearsal: the rehearsal stops; the DR nodes become the
  DR site only through the real-loss tree, never the rehearsal one.

## Verification

- Requirements 1, 3, 4.1, 4.2: review of the task 1 pull request against the
  tech-docs checklist.
- Requirements 1.3, 2.2, 6.2: repo-policy rules in CI.
- Requirement 6.4: promtool and Alertmanager tests in CI.
- Requirements 7.1, 7.2: the first scheduled `dr-rebuild` run appears on the
  dashboard.
- Requirement 8: repo-policy over the DR render, and the rehearsal preflight
  refusing to start with a writer key present.
- Requirements 2.4, 7.3: the first full rehearsal's pull request (task 8).

Open questions: [requirements.md](requirements.md#open-questions).
