# Design: disaster-recovery-strategy

## Overview

A cold site in the cloud, built on demand. Nothing runs outside the house in
normal times. When the house or the NAS is lost, `tofu apply` on a new
module, `bootstrap/dr-cloud/`, creates arm64 nodes at a cloud provider.
Talos and the existing GitOps tree go onto them with a site overlay, the
data comes back from the S3 bucket, and the cluster comes home later by the
same path. A timed drill applies the module, restores, measures and
destroys it, and records its MTTR and its cost. Hot and warm sites are
rejected on cost ([Site options](#site-options)).

Every response is rehearsed on a calendar, the measured times go into one
file in git, and a CronJob puts them on the Homelab / Data protection
dashboard. Two gaps that no rehearsal closes get their own work: break-glass
copies that survive a fire, and backups that survive the loss of the AWS
account.

Cluster figures were read on 2026-11-03 from the live Prometheus
(datasource `prometheus`) and `kubectl --request-timeout=20s`. Prices are
on-demand list prices without VAT, read on 2026-11-03 from the providers'
own price lists ([Sources](#sources)); task 9 prices the chosen provider
again in its calculator after the first drill.

## Scenarios

The proposed "Disaster scenarios" table for `docs/sre.md` (task 1).

| Scenario | Signal | Lost | Survives | Response |
| --- | --- | --- | --- | --- |
| One node | `HomelabNodeDown` (NotReady 15 min); `etcdInsufficientMembers` if a second control plane goes | nothing: nodes hold no data ([node-replacement.md](../../../docs/runbooks/node-replacement.md)) | every volume on the NAS, etcd on the other two control planes | reschedule happens on its own; reflash with [node-replacement.md](../../../docs/runbooks/node-replacement.md) |
| The NAS | `HomelabNASDown` (unreachable 10 min), `NASPoolUnhealthy`, `NASPoolDeviceNotOnline` | every iSCSI volume, the media share, the NAS copy of the Immich library | S3 (restic, Barman), git, the nodes | pool intact on dead hardware: move the disks to a replacement and import the pool (RPO 0); pool gone: the DR site, `docs/runbooks/site-lost.md` (task 8) |
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
axis and the MTTR column, which starts empty. The house-lost RTO keeps the
existing "restore from backup" values (24 h for tiers 0 and 1, 72 h for
tier 2); the first drill shows whether they hold.

| Scenario | RPO | RTO tier 0 | RTO tier 1 | RTO tier 2 | MTTR |
| --- | --- | --- | --- | --- | --- |
| One node | none (no data on nodes) | 4 h (service fault) | 4 h | 72 h | not measured |
| The NAS, pool intact | none | 4 h after the replacement hardware is in place | 4 h after tier 0 | 72 h | not measured |
| The NAS, pool lost | Postgres 24 h promised, about 5 min achieved (a WAL segment at least every 5 minutes); files 24 h; media all | 24 h on the DR site | 24 h | 72 h, without the media library | not measured |
| The house | same as the NAS, pool lost; plus the local dumps and etcd snapshots | 24 h on the DR site | 24 h | 72 h, without the media library | not measured |
| The AWS account | live data none; backup history all | no outage | no outage | no outage | not measured; target: backups fresh again within 24 h |
| The operator | none while the house stands | no promise | the household can restore photos and documents to a laptop within 7 days | no promise | not measured |

Today the house-lost RTO is the lead time of new hardware plus an untimed
rebuild: days to weeks. The 24 h above holds only once tasks 7 to 9 are
done and a drill has measured it.

The measured pieces so far:

| Piece | Measured | Source |
| --- | --- | --- |
| Postgres recovery from S3 into a new cluster | 90 s (`lidarr-postgresql`) to 431 s (`sonarr-postgresql`) per cluster; `immich-db` 297 s, `keycloak-db` 363 s | `backup_verify_restore_seconds`, last weekly run |
| First upload of the Immich library | 270 GiB in 2 h 14 min, limited by reading the NAS | [backups.md](../../../docs/backups.md#setting-it-up-from-scratch) |
| Full Immich restore from S3 | not measured; "about 1.5 h" is extrapolated from a 410 MiB sample | [backups.md](../../../docs/backups.md#rpo-and-rto) |
| Node replacement | not measured; the runbook says about 45 minutes | [node-replacement.md](../../../docs/runbooks/node-replacement.md) |
| Cold start | not measured; the runbook says 45 minutes to 2 hours | [cold-start.md](../../../docs/runbooks/cold-start.md) |

## What the cluster uses

The input to the cost estimate, read on 2026-11-03.

| Resource | Value | Source |
| --- | --- | --- |
| Nodes | 4 Turing RK1, 8 cores (4 Cortex-A76, 4 Cortex-A55) and 32 GiB each: 32 cores, 128 GiB | `kubectl get nodes` |
| CPU used | 7.6 cores: cp-1 1.68, cp-2 2.72, cp-3 1.85, w-1 1.36 | `kubectl top nodes` |
| Memory used | 28.2 GiB: 5.9, 7.1, 7.9 and 7.3 GiB | `kubectl top nodes` |
| Used by pods | 4.2 cores, 24.1 GiB over 118 pods | `kubectl top pods -A` |
| Requests | 9.3 CPU, 27.3 GiB; of which theater 2.2 CPU and 6.0 GiB, immich 2.2 and 5.5, kube-system 1.2 and 2.8, signoz 0.6 and 2.3, home 0.16 and 0.8 | `kube_pod_container_resource_requests`; `home` from the pod specs |
| Block volumes, provisioned | 2,557 GiB in 35 iSCSI claims, `immich-data` 2,048 GiB of it; the two Seafile claims (110 GiB, an archive until 2026-11-16) left out | `kubectl get pvc -A` |
| Claims per namespace | theater 15, signoz 3, home 3, immich 3, paperless 3, books 2, mealie 2, monitoring 2, keycloak 1, syncthing 1 | `kubectl get pvc -A` |
| Block volumes, used | 421 GiB: immich 349, signoz 31, monitoring 20, theater 17, the rest under 2 each | `kubelet_volume_stats_used_bytes` |
| Media library (NFS) | about 9.5 TB (8,850 GiB) | [backups.md](../../../docs/backups.md#what-is-not-backed-up); `truenas_dataset_used_bytes{dataset="homelab/k8s"}` is 11,341 GiB with the zvols and the NAS restic repository (the exporter reports no child datasets) |
| Sent by user-facing pods | 63 GiB in 17.6 days, about 108 GiB per 30 days: Immich 25 GiB, theater apps 17 (Plex 3.4, Jellyfin 0.2), Keycloak 12, books 3, Paperless 2.6, the rest under 1.5 | `increase(container_network_transmit_bytes_total[17d])`, without the databases, qBittorrent and backup jobs; Prometheus holds 17.6 days |
| Sent by qBittorrent | 1,469 GiB in 17.6 days, about 2.5 TiB per 30 days (seeding) | the same query |

The transmit counters include LAN and in-cluster traffic, so at home they
are an upper bound for internet egress. In the cloud, all household traffic
is internet egress. Streaming is the unknown: Plex and Jellyfin sent 3.6 GiB
in 17.6 days, and a few evenings of films would multiply that.

## Cost estimate

### Shapes

| Shape | Nodes | Total | Fits |
| --- | --- | --- | --- |
| Full: the current cluster, always on | 3 control planes of 2 vCPU and 8 GiB that also run workloads (`allowSchedulingOnControlPlanes: true`, as at home), 1 worker of 8 vCPU and 32 GiB. Hetzner: 4 and 8, 16 and 32 | 14 vCPU, 56 GiB (Hetzner 28 vCPU, 56 GB) | requests 9.3 CPU and 27.3 GiB; 7.6 RK1 cores used, half of them Cortex-A55 |
| DR: one node, for a drill or a short loss | 1 node of 8 vCPU and 32 GiB (Hetzner 16 and 32) | 8 vCPU, 32 GiB | requests without theater, SigNoz and the Home Assistant stack, the parts the DR shape leaves out: 6.3 CPU, 18.3 GiB |

Storage:

- Full shape: 1,009 GiB of SSD block storage for the 35 claims at their
  size in git, except `immich-data` at 500 GiB instead of 2 TiB (349 GiB
  are used). The site overlay sets that size ([What changes in the GitOps
  tree](#what-changes-in-the-gitops-tree)); priced at the 2 TiB in git, the
  always-on figures become $779 (AWS), $808 (Google Cloud) and €221
  (Hetzner).
- DR shape: 805 GiB in 14 claims, the same claims without theater, SigNoz
  and Home Assistant. One more claim holds the ebook library restored from
  restic; task 7 sizes it from the snapshot, and it is not priced here.
- A 32 GiB root disk per node on AWS and Google Cloud (Hetzner servers
  include a local disk).
- The media library is a separate line: 9,000 GiB on the cheapest HDD-class
  block storage.

Volume attach limits, which the CSI drivers report to the scheduler:

| Provider | Node | Limit | DR shape needs |
| --- | --- | --- | --- |
| AWS | `m7g.2xlarge` | 28 attachments shared by the network interfaces, the root volume and the EBS volumes | 15 volumes, 1 interface |
| Google Cloud | `c4a-standard-8` | 16 Hyperdisk volumes, the boot disk included | 15 plus the boot disk |
| Hetzner | `CAX41` | 16 volumes; the root disk is local | 15 |

The Full shape spreads its 35 claims over 4 nodes.

Egress: 200 GiB a month, the measured 108 GiB doubled for margin; 1 TiB a
month as the heavy-streaming case. qBittorrent seeding stays off in the
cloud: its 2.5 TiB a month would add about $220 on AWS and $200 on Google
Cloud, and fits in Hetzner's included 20 TB.

### Unit prices

| Item | AWS `eu-central-1` | Google Cloud `europe-west3` (`europe-west6`) | Hetzner (Nuremberg, Falkenstein, Helsinki) |
| --- | --- | --- | --- |
| 2 vCPU, 8 GiB | `m7g.large` $0.0978/h | `c4a-standard-2` $0.105966/h ($0.117640) | `CAX21` (4 vCPU) €0.0176/h, €10.99/month |
| 8 vCPU, 32 GiB | `m7g.2xlarge` $0.3910/h | `c4a-standard-8` $0.423864/h ($0.470562) | `CAX41` (16 vCPU) €0.0665/h, €41.49/month |
| SSD block storage | gp3 $0.0952/GB-month | Hyperdisk Balanced $0.094/GiB-month ($0.112) | volume €0.0572/GB-month |
| HDD block storage (media) | sc1 $0.018/GB-month | Hyperdisk Throughput $0.006/GiB-month plus $0.295 per MBps-month | none; volumes only |
| Public IPv4 | $0.005/h | $0.005/h | included in the server prices above |
| Internet egress | 100 GB a month free, then $0.09/GB up to 10 TB | Standard Tier: 200 GiB a month free, then $0.085/GiB | 20 TB per server included, then €1/TB |
| Reading the S3 bucket | Glacier IR retrieval $0.03/GB; no transfer charge inside `eu-central-1` | retrieval plus S3 internet egress $0.09/GB | retrieval plus S3 internet egress $0.09/GB |

Every AWS and Google Cloud figure above is the provider's own published
price for the region; nothing is an estimate or a regional factor.

Arm64 availability: C4A (Axion) runs in all three zones of `europe-west3`
and only in `europe-west6-b`; T2A runs in neither region (in Europe only in
`europe-west4`). Hetzner's order page showed every CAX type as "currently
unavailable" on 2026-11-03; a DR site that cannot be ordered on the day is a
risk the drill has to test.

### Results

| | AWS `eu-central-1` | Google Cloud `europe-west3` | Hetzner |
| --- | --- | --- | --- |
| **Always on**, Full shape, without the media library | **$631/month** | **$663/month** (`europe-west6`: $743) | **€132/month** |
| Always on, with the media library (9,000 GiB) | $793/month | $743/month | €647/month |
| Heavy streaming (1 TiB a month) adds | $74/month | $70/month | nothing |
| Warm standby: DR shape always on, without media | $369/month | $392/month | €88/month |
| **DR drill**, 8 h, DR shape, whole bucket read | **$12 per drill** | **$39 per drill** | **€1.04 + $35 per drill** |
| DR drill per month, two drills a year | $2/month | $7/month | €0.17 + $6/month |

Always on, Full shape, line by line (per month):

| Line | AWS | Google Cloud `europe-west3` | Hetzner |
| --- | --- | --- | --- |
| 3 control planes | $214.18 | $232.07 | €32.97 |
| 1 worker | $285.43 | $309.42 | €41.49 |
| Block storage | $108.24 (1,137 GiB gp3) | $106.88 (1,137 GiB) | €57.71 (1,009 GB) |
| 4 public IPv4 addresses | $14.60 | $14.60 | included |
| Egress, 200 GiB | $9.00 | $0.00 | included |
| **Total** | **$631.45** | **$662.97** | **€132.17** |
| Media library, 9,000 GiB | $162.00 (sc1) | $79.96 (Hyperdisk Throughput at its minimum of 88 MBps) | €514.80 |

DR drill, 8 hours on the DR shape:

| Line | AWS | Google Cloud `europe-west3` | Hetzner |
| --- | --- | --- | --- |
| Node | $3.13 | $3.39 | €0.53 |
| Block storage for 8 h (837 GiB; Hetzner 805 GB) | $0.87 | $0.86 | €0.50 |
| Public IPv4 | $0.04 | $0.04 | included |
| Glacier IR retrieval, 264 GiB | $7.92 | $7.92 | $7.92 |
| S3 internet egress, 300 GiB | none, same region | $27.00 | $27.00 |
| **Total** | **$11.96** | **$39.21** | **€1.04 + $34.92** |

Totals are computed before rounding. The image a drill builds on Hetzner or
Google Cloud ([Talos](#talos)) adds cents: a few minutes of a rescue
server, or a 1 GiB object for an hour.

### Assumptions

- 730 hours a month, on demand. No savings plan or commitment: a site that
  may never run does not justify a one- or three-year commitment.
- No managed Kubernetes (EKS, GKE): Talos runs the control plane, as at home.
- No NAT gateway and no cloud load balancer. Each node has a public IPv4 for
  egress; Cilium serves the Gateway on the host network of the node that
  holds the Gateway address.
- One zone. The house is one site; a DR site in two zones would protect
  against a loss nobody has here.
- The S3 bucket's own cost does not change: backups keep going to it.
- The drill reads the whole bucket once (264 GiB in Glacier IR, 35 GiB in
  Standard, `aws_s3_bucket_size_bytes_average`), before AWS's 100 GB of free
  egress, which would lower the cross-provider figures by about $9.
- Dollars and euros are not converted.

### Sources

Read on 2026-11-03, from the providers' own price lists.

- AWS, the public Price List bulk files for `eu-central-1` (no account
  needed; index at
  `https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/index.json`):
  - `AmazonEC2`, version 20261029175634: `m7g.large` $0.0978/h and
    `m7g.2xlarge` $0.391/h (on demand, Linux, shared tenancy); EBS gp3
    $0.0952 and sc1 $0.018 per GB-month.
  - `AmazonVPC`, version 20261103000947: public IPv4 in use $0.005/h.
  - `AWSDataTransfer`, version 20260916132208: internet egress $0.09/GB for
    the first 10 TB beyond the free tier.
  - `AmazonS3`, version 20261015173540: Glacier Instant Retrieval
    retrieval $0.03/GB.
  - Human-readable pages: [EC2 On-Demand pricing](https://aws.amazon.com/ec2/pricing/on-demand/),
    [EBS pricing](https://aws.amazon.com/ebs/pricing/),
    [VPC pricing](https://aws.amazon.com/vpc/pricing/),
    [S3 pricing](https://aws.amazon.com/s3/pricing/).
- Google Cloud, the region tables of the official pricing pages (Frankfurt
  `europe-west3`, Zurich `europe-west6`):
  - [General-purpose VM pricing](https://cloud.google.com/products/compute/pricing/general-purpose):
    `c4a-standard-8` $0.423864/h (`europe-west6` $0.47056152/h);
    `c4a-standard-2` $0.105966/h ($0.11764038/h).
  - [Disk and image pricing](https://cloud.google.com/compute/disks-image-pricing):
    Hyperdisk Balanced $0.094/GiB-month ($0.112), with 3,000 IOPS and
    140 MBps per volume included; Hyperdisk Throughput $0.006/GiB-month
    plus $0.295 per MBps-month.
  - [Network Service Tiers pricing](https://cloud.google.com/network-tiers/pricing):
    Standard Tier from `europe-west3`, 200 GiB a month free, then
    $0.085/GiB up to 10 TiB.
  - [VPC network pricing](https://cloud.google.com/vpc/network-pricing):
    external IPv4 on a standard VM $0.005/h.
  - Zones per series: [Regions and zones](https://docs.cloud.google.com/compute/docs/regions-zones);
    disks per machine type: [General-purpose machine family](https://docs.cloud.google.com/compute/docs/general-purpose-machines).
  - Calculator for task 9: [Google Cloud pricing calculator](https://cloud.google.com/products/calculator).
- Hetzner: [cost-optimized cloud servers](https://www.hetzner.com/cloud/cost-optimized/)
  (CAX prices with IPv4, hourly and monthly, after the price adjustment of
  15 June 2026); [block storage](https://www.hetzner.com/cloud/block-storage/)
  (up to 16 volumes per server). Hetzner's pages render the volume and
  traffic prices in the browser only, so those two come from the
  [costgoat Hetzner calculator](https://costgoat.com/pricing/hetzner)
  (updated 2026-10-20); task 9 checks them in the Hetzner console.

## Site options

The house-lost scenario decides between them; a node or an AWS account loss
needs no second site.

What is hosted, and what each option buys for it:

- **Photos** (Immich, about 332 GiB, irreplaceable). Protected by the
  backups in every option: nightly restic to S3 and to the NAS. The site
  option changes how soon the app is back, not whether the photos survive.
- **Documents** (Paperless), **recipes** (Mealie), **sync** (Syncthing),
  **identity** (Keycloak). Small, backed up, tier 1 or 2.
- **Media** (about 9.5 TB, re-acquirable, not backed up by decision).
  Nothing to restore in any option.
- **Home automation**. Useless when the house is gone.

The RPO is the same in cold and warm: 24 h promised for Postgres and files
([sre.md](../../../docs/sre.md#rpo)), about 5 minutes achieved for Postgres
by WAL archiving. Warm and hot buy a shorter outage
after a site loss: hours or minutes instead of up to 24 h for tiers 0 and 1.
A house loss already spends many months of error budget, and a household
that has just lost its house does not need the photo app within the hour;
it needs the photos to exist.

| | Cold, home hardware only (before this spec) | Cold in the cloud, on demand (chosen) | Warm | Hot |
| --- | --- | --- | --- | --- |
| What runs outside the house | nothing | nothing; `bootstrap/dr-cloud/` creates the nodes after a loss or for a drill | the DR shape all the time, restoring the latest backups on a schedule; Postgres as CNPG replica clusters replaying WAL from S3 | the Full shape, fed continuously, with DNS failover |
| Cost a month, on top of S3 ($3.07 in October 2026, $5.40 forecast for November) | none | none in normal times; drills $2 (AWS), $7 (Google Cloud), about $6 (Hetzner) a month at two a year | $369 (AWS), $392 (Google Cloud), €88 (Hetzner), plus the scheduled restores | at least $631 (AWS), $663 (Google Cloud), €132 (Hetzner), plus replication traffic |
| A year | none | about $24 (AWS) to $78 (Google Cloud) of drills | $4,425 (AWS), $4,701 (Google Cloud), €1,050 (Hetzner) | at least $7,577 (AWS), $7,956 (Google Cloud), €1,586 (Hetzner) |
| Cost of a 3-day loss | the hardware | about $44 (AWS DR shape: 72 h of node, storage and IPv4 plus the bucket read) or €9 plus $35 (Hetzner) | small: the data is already there | none |
| House-lost RTO | hardware lead time (days to weeks) plus an untimed rebuild | 24 h target for tiers 0 and 1, measured by the drill | hours: switch DNS, catch up the files written since the last scheduled restore | minutes |
| RPO in a house loss | 24 h promised; achieved: Postgres about 5 min, files 24 h | the same | the same | Postgres seconds; files depend on the sync |
| Effort to build | none | the site overlay, the module, the runbook (tasks 7 and 8) | the same, plus a second cluster that runs all the time | everything warm needs, plus per-app replication between sites, failover rules and split-brain handling |
| Effort to run | none | one drill of about a day, twice a year | a second cluster to upgrade (Talos, Kubernetes, charts), watch and pay for, with one operator | as warm, plus every change tested on two live sites |
| Fit with the design | | reuses git, the bucket and the restore path the weekly tests already prove | a second set of alerts and upgrades for one operator | contradicts single replica and `ReadWriteOnce` volumes on one NAS ([tech.md](../../steering/tech.md#constraints)) |

Three-day loss on AWS: 72 × ($0.391 + 0.005) + 837 × $0.0952 × 72 / 730 +
$7.92 = $44.29; on Hetzner 72 × €0.0665 + 805 × €0.0572 × 72 / 730 =
€9.33, plus $34.92 for the bucket read.

### Decision

Cold in the cloud, on demand. The operator ruled out hot and warm on
2026-11-03 as too expensive for what is hosted, and the numbers agree:

- Warm costs €88 (Hetzner) to $392 (Google Cloud) a month, against $3.07
  to $5.40 for today's whole AWS bill, to shorten an outage that the
  backups already make survivable. It also doubles what one person has to
  upgrade and watch.
- Hot needs every app replicated across sites, which the single-replica,
  one-NAS design cannot do without rewriting most apps.
- Cold with home hardware only cannot be rehearsed and has no RTO anyone can
  state. It stays the way home is rebuilt after a DR period.
- Cold in the cloud costs nothing until it is used. A drill costs $12 to $39,
  a three-day loss about $44 (AWS) or €9 plus $35 (Hetzner).

Review it, in one pull request that changes `docs/decisions.md`, when two
consecutive drills exceed the tier 1 RTO of the house-lost scenario, when a
new estimate changes the order of the options, when the household asks for
a shorter outage, or when the recovery provider stops offering hourly arm64
servers.

## The DR module

### The proposal, evaluated

The operator's proposal (2026-11-03): a module `bootstrap/dr-cloud/` that is
not applied in normal times. When the house is lost, `tofu apply` creates
the compute and the storage; the existing GitOps tree (Talos through
talhelper, the Argo CD bootstrap, the apps) deploys unchanged, and only the
kubeconfig and talosconfig endpoints and the provider-specific parts change.

It works, with three amendments:

1. **Volumes come from the CSI driver, not from tofu.** The claims' sizes
   stay in git next to the apps; the provider's CSI driver creates and
   attaches each volume when the claim appears. The module only grants the
   driver its permission. Volumes created by tofu would duplicate every claim
   and need a static PV per volume, mapped by hand.
2. **The apps are unchanged; the infrastructure layer is not.** Storage,
   addresses, the Gateway and everything that needs the NAS differ (table
   below). They become one site overlay, rendered and checked in CI on every
   pull request, so the DR tree is tested before the day it is needed.
3. **CI never applies it.** The `tofu` workflow plans and applies only the
   modules it names (`bootstrap/aws-backup`, `bootstrap/github-oidc`,
   `bootstrap/tofu-state`). `bootstrap/dr-cloud/` stays out of that list; CI
   runs `tofu fmt -check` and `tofu validate` on it. A daily check fails, and
   so notifies ntfy, when the module's state holds resources older than 24 h
   and no real loss is declared, so a forgotten drill does not run up
   close to $400 a month.

The module's state lives in the existing state bucket. If the AWS account is
gone too, the state is empty anyway in normal times: `tofu init` with a
local backend starts from nothing.

### What the module creates

| Resource | AWS | Google Cloud | Hetzner |
| --- | --- | --- | --- |
| Network | a VPC, one public subnet, a security group | a VPC network, a subnet, firewall rules | a private network, a firewall |
| Nodes | the Talos arm64 AMI for the region published by Sidero Labs (default schematic), moved to the DR schematic after boot ([Talos](#talos)) | a `google_compute_image` from the Image Factory `gcp` arm64 disk with the DR schematic, uploaded to a bucket by `scripts/dr-image.sh` before `tofu apply` | a snapshot of the Image Factory `hcloud` arm64 image with the DR schematic, built by `scripts/dr-image.sh` before `tofu apply` |
| Addresses | an Elastic IP on the Gateway node; a public IPv4 on each node for egress | a static external IP on the Gateway node, ephemeral ones on the others, Standard Tier | the servers' own IPv4 |
| CSI permission | an instance profile with the EBS CSI driver policy | a node service account with the Compute storage role | an API token for `hcloud-csi`, from the password manager, passed as a variable, never in git |
| Firewall | 50000 (Talos) and 6443 (Kubernetes) from `var.operator_cidr` only; 80, 443 and 22000 from anywhere in a real loss, from `var.operator_cidr` only in a drill (`var.drill`) | the same | the same |
| Labels | `dr-drill=<date>` on every resource, for the drill's cost | the same | the same |
| Outputs | node addresses, the Gateway address | the same | the same |

### Talos

- A second talhelper config, `talos/dr/talconfig.yaml`: the same Talos and
  Kubernetes versions as home (Renovate bumps both files), its own cluster
  secrets (the DR cluster is a new cluster, never a member of the home one),
  node addresses and the endpoint from the module's outputs,
  `allowSchedulingOnControlPlanes: true` as at home.
- The DR schematic drops the `sbc-rockchip` overlay and `iscsi-tools`,
  keeps `siderolabs/tailscale`, and uses the provider's platform image. It
  gets its own installer image ID; `scripts/ci/talos-validate.sh` checks
  both configs.
- No provider ships an image with that schematic, so it comes from the
  Image Factory on the day:
  - AWS: Sidero's AMIs carry the default schematic only. The nodes boot
    it, then `talhelper gencommand upgrade` with `talos/dr/` moves each node
    to the Factory installer of the DR schematic: one reboot per node,
    timed as step 2a of the restore order.
  - Google Cloud: `scripts/dr-image.sh gcp` downloads the Factory
    `gcp-arm64.raw.tar.gz` and uploads it to a bucket; the module creates
    the image from it.
  - Hetzner: Hetzner has no image import. `scripts/dr-image.sh hcloud`
    writes the Factory `hcloud` arm64 image to a snapshot from a temporary
    arm64 server in rescue mode (`hcloud-upload-image`) and deletes the
    server; the module finds the snapshot by its label. It needs a CAX
    server to be orderable, the same risk as the DR node itself.
- Images are built on the day, not kept. A stored image costs cents a
  month but has to be rebuilt on every Talos bump, and would be the one
  standing resource of a site that is otherwise empty. The image step is
  timed (step 1a), and the drill shows whether keeping one is worth it.
- A drill uses the same schematic, but its config carries no Tailscale auth
  key, so no node joins the tailnet (requirement 8.3).
- No Talos VIP: it needs a shared L2 segment, which cloud networks do not
  give. The Kubernetes endpoint is the first control plane's address (Full
  shape) or the single node (DR shape). In-cluster clients do not depend on
  it: Cilium already reaches the API through KubePrism (`localhost:7445`).
- The talosconfig and kubeconfig point at the new addresses; that is the
  "only the endpoints change" part of the proposal, and it holds.

### What changes in the GitOps tree

| Concern | Home | DR site | How |
| --- | --- | --- | --- |
| Kubernetes API for Cilium | KubePrism `localhost:7445` | unchanged | none |
| Pod networking | Cilium in its default tunnel mode | unchanged; a tunnel works in any cloud network | none |
| LoadBalancer addresses | LB-IPAM pools `192.168.1.200-227` and `.254`, L2 announcements | none: cloud networks do not deliver addresses announced by ARP from a node | overlay: L2 announcements off, pools out, the Gateway on the host network of the Gateway node (`gatewayAPI.hostNetwork`) |
| Syncthing protocol (`.201`), qBittorrent seed (`.200`) | pinned LoadBalancer addresses | Syncthing on hostPort 22000 of the Gateway node; qBittorrent not deployed | overlay patches, and a PolicyException `syncthing-dr` for `disallow-host-ports`, matched by namespace `syncthing` and name prefix `syncthing` like `policies/kyverno/exceptions/lan-inventory.yaml`; the Kyverno baseline denies host ports otherwise |
| Storage | democratic-csi iSCSI on the NAS; classes `iscsi` and `iscsi-retain` | the EBS, GCE PD or `hcloud-csi` driver; two classes with the same names, Delete and Retain, both with `allowVolumeExpansion: true` | overlay: democratic-csi, `iscsi-volumes`, `nfs-storage` and `truenas-exporter` out; the provider's driver and classes in |
| Pinned volumes | static PVs in `infrastructure/iscsi-volumes/`; `volumeName` in the claims of Mealie, Paperless, Syncthing and the theater apps | dynamic | overlay removes `volumeName` from those claims |
| `immich-data` size | 2Ti on the NAS (`apps/immich/resources/library-pvc.yaml`), 349 GiB used | 500Gi, grown online when `KubePersistentVolumeFillingUp` fires; cloud volumes grow but never shrink | overlay patch; the restore Job refuses to start when the restic snapshot is larger than 90% of the claim |
| Apps left out of the DR shape | everything runs | theater (nothing to restore without the media library), SigNoz (logs only, starts empty), Home Assistant, its database, Mosquitto and Zigbee2MQTT (useless without the house) | overlay: their Applications out of the DR render; a long loss adds them back in a pull request, theater with the media library |
| Media share | NFS `192.168.1.228:/mnt/homelab/k8s/nfs/media`, inline in the theater and books apps | theater left out (nothing to restore); the books apps get their library from restic into a claim | overlay; if the house is gone for months, the media library goes on one `ReadWriteOnce` volume and the theater pods follow it to that node |
| The NAS's own backups | `backup-local` PVs: the second Immich repository, `backup-verify`'s copy | none | overlay: the NAS targets out |
| NAS alerts | `HomelabNASDown`, `NASPool*` | would page for a NAS that is gone | overlay: those rules out |
| DNS | external-dns `--default-targets` set to the WAN IP, upsert-only | the Gateway address from the module (real loss); external-dns not deployed (drill) | overlay value |
| Resolution of `*.lilalala.com` inside the cluster | public DNS: the WAN address, back in through the Gateway | real loss: public DNS, which points at the DR Gateway. Drill: public DNS still points home, so CoreDNS answers every `lilalala.com` name with the DR Gateway node's private address | drill component: the DR Talos config disables Talos's CoreDNS (`cluster.coreDNS.disabled`) and the component deploys CoreDNS with a `template` block for `lilalala.com`. Talos's host DNS does not serve static host entries to CoreDNS ([siderolabs/talos#13141](https://github.com/siderolabs/talos/issues/13141)), so it has to be CoreDNS |
| OIDC | every client uses the issuer `https://auth.lilalala.com/realms/homelab` (Argo CD, Grafana, Headlamp, Immich, Mealie, Paperless) | the DR Keycloak, through the resolution above; never the production Keycloak | drill component: the egress rules that allow Keycloak through `world` (`infrastructure/network-policies/20-immich.yaml` describes the split-horizon case) get the Gateway node as well |
| TLS | cert-manager, DNS-01 on Cloudflare | real loss: unchanged. Drill: the same Let's Encrypt DNS-01 certificates, so the OIDC clients trust the DR Keycloak with no CA change; cert-manager writes only `_acme-challenge` TXT records (requirement 8.3; open question 6) | none (real loss); drill component: cert-manager without external-dns |
| Tailnet | nodes join as `talos-<node>`; the operator's API proxy | real loss: `talos-dr-<n>` and `homelab-dr`; drill: no join (requirement 8) | the DR talhelper config; overlay |
| Argo CD bootstrap | `bootstrap/` with `kubeconfig_path`, `repo_url`, the root Application | the same module; `kubeconfig_path` to the DR kubeconfig, the root Application pointing at the DR render | a tfvars file |
| Postgres | CNPG clusters on their existing volumes | `bootstrap.recovery` from the Barman archive; new `serverName` (real loss) or no plugin (drill) | overlay patch per cluster |

What has to be parameterised, in short: node and endpoint addresses (the
DR talhelper config, from the module's outputs), how the Gateway and the
two pinned services are exposed, the CSI driver behind the two StorageClass
names, the size of `immich-data`, the external-dns target, the set of
components and apps (the NAS-bound ones and the ones the DR shape leaves
out), each CNPG cluster's bootstrap and `serverName`, and the rehearsal
switches (name resolution, the network-policy exception, no tailnet, no
notifications). Everything else stays as it is: the apps' manifests and
charts, the Kyverno policies (plus the `syncthing-dr` exception), the
Keycloak realm, the alert rules (minus the NAS ones).

Layout: `clusters/dr/` (root, layers and Applications, the same AppProjects)
pointing at a DR render built by `scripts/render-deploy.sh` from the same
sources plus a Kustomize Component `components/site-dr` and, for the drill
switches, `components/site-dr-drill`. Task 7 settles the details. Two
constraints: the DR render is checked in CI like `deploy/`, and the home
render does not change (`task render:check`).

### Applying the module

By hand, with `scripts/tofu.sh`, like every module outside the `tofu`
workflow. After a house loss the Mac may be gone, so each input has a
source that does not need it:

| Input | Source on a fresh machine |
| --- | --- |
| The repository | `git clone https://github.com/ned-si/homelab` (public, no credential) |
| `tofu`, `talhelper`, `talosctl`, `kubectl`, `sops` | the versions pinned in `.github/workflows/ci.yaml` (`TOFU_VERSION`, `TALHELPER_VERSION`, and so on) |
| The SOPS age key | the password manager, written to `~/.config/sops/age/keys.txt` |
| `TOFU_STATE_PASSPHRASE` | the password manager, written to `secrets.local.env` in the clone (git-ignored), where `scripts/tofu.sh` reads it |
| The state backend, S3 `ned-si-homelab-tofu-state` | `aws login --profile homelab --region eu-central-1`: a browser sign-in with the AWS account's credentials and MFA (break-glass items; open question 2) |
| The recovery provider | AWS: the same `aws login` session, whose identity must be allowed to create EC2, VPC and IAM instance-profile resources. Hetzner: an API token from the password manager, exported as `HCLOUD_TOKEN`. Google Cloud: `gcloud auth application-default login` with the recovery account. |

```sh
git clone https://github.com/ned-si/homelab && cd homelab
aws login --profile homelab --region eu-central-1
scripts/tofu.sh bootstrap/dr-cloud init
scripts/tofu.sh bootstrap/dr-cloud apply -var-file=<provider>.tfvars \
  -var operator_cidr=<your-public-ip>/32 -var drill=<true|false>
```

`apply` prints the node and Gateway addresses. If the AWS account is lost
as well, there is no state bucket: copying
`bootstrap/dr-cloud/backend_override.tf.example` to `backend_override.tf`
switches to a local backend, and `tofu` runs directly with
`TF_VAR_state_passphrase` exported. The state is empty in normal times, so
nothing is lost. The quarterly break-glass check (task 4) runs `tofu plan`
on the module from the password-manager copies, which proves every line of
the table.

### Restore order

The order of `docs/runbooks/site-lost.md`; the drill timestamps every step.

| Step | What | Done when | Timer |
| --- | --- | --- | --- |
| 0 | Declare the site lost (requirement 1.4) | the declaration | T0 |
| 1a | Hetzner and Google Cloud: `scripts/dr-image.sh <provider>` | the image exists | image |
| 1 | `tofu apply` in `bootstrap/dr-cloud/` ([Applying the module](#applying-the-module)) | nodes running, outputs printed | provision |
| 2 | `talhelper genconfig` with `talos/dr/`, `talosctl apply-config`, `talosctl bootstrap`, `talosctl kubeconfig` | every node `Ready` | Talos |
| 2a | AWS: `talhelper gencommand upgrade` with `talos/dr/`, one node at a time | every node on the DR schematic and `Ready` | Talos |
| 3 | `tofu apply` in `bootstrap/` with the DR tfvars: Argo CD, the age key, the root Application | Argo CD syncing | Argo CD |
| 4 | Infrastructure layer: Cilium, cert-manager, the CSI driver, the Gateway | the layer Healthy | tier 0 |
| 5 | CNPG operator; `keycloak-db` recovered from Barman; Keycloak | `auth` DR probe green | tier 1 starts |
| 6 | `immich-db` from Barman; the Immich library from restic `immich/library` into `immich-data` (about 300 GiB, the long step); Paperless and Syncthing from restic | `media`, `archive` and `syncthing` DR probes green | tier 1 |
| 7 | Mealie and the remaining databases; the books apps | `cook` DR probe green | tier 2 |
| 8 | Real loss: backups on with new `serverName`s and restic hosts; external-dns points the public names at the Gateway address | `BackupNotFresh` clear | |
| 9 | Drill: write the row, then `tofu destroy` | the module's state empty | cost |

A DR probe is the public blackbox probe of that name
(`platform/blackbox-exporter/probes/probes.yaml`), run from the operator's
machine against the DR Gateway with the public host name:
`curl -m 10 --resolve <host>:443:<gateway-address> https://<host>/<path>`.
In a real loss, once external-dns has moved the names, the public probes
take over; in a drill, public DNS still points home and the public probes
measure the home cluster, so only the DR probes count.

Each restic restore runs as a Job before its app starts: an Argo CD PreSync
hook in the DR overlay, with the image and repository settings of
`backup-verify`. The Immich restore is the step to watch: inside
`eu-central-1` it reads S3 at network speed; from another provider it
crosses the internet. Neither is measured yet; the first drill measures it.

### The drill

- `scripts/dr-rehearsal.sh <provider>`: preflight (requirement 8: the
  verifier key only, the drill component in the render), `tofu apply`, the
  restore order above with a timestamp per step, then `tofu destroy` in an
  exit trap, whatever happened.
- MTTR: T0 to each tier's DR probes green, written per tier to
  `ci/dr-rehearsals.tsv`. The mean of the last three passing drills is the
  MTTR column in `docs/sre.md`.
- The drill site is reachable only from `var.operator_cidr`, and a browser
  check during a drill needs `/etc/hosts` entries on the operator's machine
  for the drill's duration; without them the browser logs in at home.
- Certificates: the drill requests the same names as home from Let's
  Encrypt, which allows 5 certificates for one exact set of names a week.
  Two drills a year and the home renewals stay far below it.
- Cost: a few days later, the bill for the resources labelled
  `dr-drill=<date>` (AWS Cost Explorer by tag, Google Cloud billing by
  label, the Hetzner invoice by project), plus the bucket read, goes into the
  row's `cost` and `currency` columns. The dashboard shows the last drill's
  cost.
- At most 12 h; the daily leftover check catches a failed destroy.
- Monday to Friday, daytime, Zurich.

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
| Recovery provider API credentials | the password manager (open question 1 names the provider) | not needed | all | password manager | all | password manager |
| Immich library | live on the NAS, the NAS restic repository, S3 `immich/library` | all | S3 | S3 | live and the NAS copy | S3 or the NAS, with `RESTIC_PASSWORD` |
| Databases | live on the NAS; Barman WAL and base backups in S3 `cnpg/`; `pg_dump` of Mealie, Home Assistant and the four *arr clusters in restic; dumps by hand on the Mac | all | S3 | S3 | live, and the Mac's dumps if recent | S3 |
| Cluster configuration | git on GitHub, every clone | all | all | GitHub | all | GitHub |
| Break-glass credentials | the password manager | all | all | password manager, if its own recovery is outside the house (open question 2) | all | emergency access |

Gaps:

- **The AWS account and the house together.** The Immich library and every
  database exist only in S3 once the house is gone; `immich-db` and
  `keycloak-db` have no logical dump at all, only Barman. Task 5 adds a
  second copy at the recovery provider when it is not AWS (requirement 5.3).
- **The recovery of the password manager.** Its master password, its second
  factor and the AWS root MFA must not all depend on a phone in the house
  (open question 2).
- **Emergency access.** Not set up yet; task 4 adds it to the break-glass
  check (open question 3).

## Rehearsal calendar

The proposed calendar for `docs/backups.md` (task 1; open question 4). Live
work keeps the operator's rule: Monday to Friday, daytime, Zurich.

| Rehearsal | Scenario | Interval | Where | Measures |
| --- | --- | --- | --- | --- |
| `backup-verify` (exists) | data of every scenario | weekly, Saturday and Sunday evenings | home cluster | restore per CNPG cluster, restic samples, the bucket lock |
| `dr-rebuild` CI (#723, task 6) | tier 0 from git | monthly, first Tuesday | GitHub Actions, Talos in QEMU | time from empty nodes to infrastructure and platform Healthy, without data; a lower bound for tier 0 |
| Break-glass check (task 4) | the house, the AWS account, the operator | quarterly: January, April, July, October | the Mac and the password manager | each item of the inventory works; emergency access still set up |
| Node replacement (task 10) | one node | twice a year: March and September, `homelab-w-1` first, then a control plane in turn | home cluster | reset to `Ready`, and to every tier 1 probe green |
| DR drill (#723, task 9) | the NAS, the house | twice a year: May and November | the DR module at the recovery provider | each step and tier against its RTO, the full Immich restore, the RPO reached, the cost |
| AWS account tabletop | the AWS account | yearly, June | desk: walk `docs/runbooks/aws-account-lost.md`; with a second copy, restore a sample from it | pass or fail, and the steps that did not match |
| Operator walk-through | the operator | yearly, December | the trusted person, with `docs/runbooks/operator-unavailable.md` | one album and one document restored to a laptop |

## Measurement

One record in git, two readers.

- `ci/dr-scenarios.tsv`: one line per scenario: name, interval in days, RTO
  per tier in seconds. The source of the sre.md targets and of the overdue
  alert.
- `ci/dr-rehearsals.tsv`: one line per run: date (UTC), scenario, result
  (`pass`, `fail`, `partial`), seconds per tier (`-` when not part of the
  run), RPO reached per data class in seconds, cost and currency (`-` for
  runs that cost nothing), and the pull request or run URL. A manual
  rehearsal is recorded by the pull request that adds its line; that pull
  request is the report.
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
| `dr_rehearsal_cost{scenario,currency}` | the last run's cost |

`DRRehearsalOverdue` (warning, `action: human`): the last run is older than
the interval plus 14 days. A person has to schedule the rehearsal, so it
pages; once, then every 24 h like every other warning
([sre.md](../../../docs/sre.md#paging)). The dashboard gets a row "Disaster
recovery": per scenario the last run, its result, duration against RTO per
tier, the MTTR, the last drill's cost and the next due date.

## Components

| Component | Change | Task |
| --- | --- | --- |
| `docs/decisions.md` | entry "Disaster recovery: a cold site in the cloud, built on demand", with the cost per option and provider | 1 |
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
| `docs/runbooks/aws-account-lost.md`; the second copy at the recovery provider | the AWS scenario | 5 |
| `.github/workflows/dr-rebuild.yaml` | monthly rebuild in CI, on the QEMU harness of `scripts/ci/talos-upgrade-rehearsal.sh` | 6 |
| `components/site-dr` (with the `immich-data` size and the `syncthing-dr` PolicyException), `components/site-dr-drill` (CoreDNS for `lilalala.com`, the network-policy exception), `clusters/dr/`, the DR render, repo-policy over it | the site overlay | 7 |
| `bootstrap/dr-cloud/` (with `backend_override.tf.example`), `scripts/dr-image.sh`, `talos/dr/talconfig.yaml`, the leftover check in `.github/workflows/tofu.yaml`, `tofu validate` in `ci`, `docs/runbooks/site-lost.md` | the DR module | 8 |
| `scripts/dr-rehearsal.sh` | the timed drill, preflight for requirement 8, the DR probes, destroy on exit | 9 |

## Decisions

| Decision | Rejected | Why |
| --- | --- | --- |
| Cold site in the cloud, built on demand by `bootstrap/dr-cloud/` | warm standby, hot replica, cold with home hardware only | see [Decision](#decision) |
| Volumes from the provider's CSI driver | volumes created by the module | claim sizes stay in git; no static PV per volume |
| The DR site reuses the StorageClass names `iscsi` and `iscsi-retain` | site-specific classes and a patch per app | no app manifest changes; the class names describe home, the overlay says what backs them |
| `immich-data` at 500Gi on the DR site, grown online | the 2Ti in git | 2 TiB of cloud SSD costs $147 a month more on AWS for 1.5 TiB nobody uses; cloud volumes grow online but never shrink |
| Talos images built from the Image Factory on the day | images kept at each provider | no standing resource, no rebuild on every Talos bump; the step is timed, and the drill shows whether it is too slow |
| Drill certificates from Let's Encrypt DNS-01, as at home | a drill CA mounted into every OIDC client; Let's Encrypt staging | the clients trust the DR Keycloak with no per-app change, and the drill tests the real path; the cost is `_acme-challenge` TXT records in the production zone (open question 6) |
| DR probes with `curl --resolve` against the DR Gateway | the public blackbox probes | during a drill the public names point home, so the public probes would measure home and always pass |
| The house-lost RTO keeps 24 h (tiers 0 and 1) and 72 h (tier 2) | a looser target for a site loss | the existing "restore from backup" values; the drill shows whether they hold, and a miss opens an issue instead of moving the target |
| The module is never applied by CI | applying it from the `tofu` workflow | an apply on merge or a drift run would create the DR site and its bill |
| MTTR from rehearsals only, the last three passing runs | estimates in the docs; the mean of every run ever | an estimate cannot be checked; old runs describe a cluster that no longer exists |
| One TSV record in git, pushed by a CronJob | results only in the Pushgateway; a database of runs | the Pushgateway keeps only the last value and Prometheus at most 30 days, but rehearsals are months apart; a pull request per run is also the report |
| CI results read from the public GitHub API | a cluster credential in GitHub; a pull request per CI run | GitHub holds no cluster credentials ([decisions.md](../../../docs/decisions.md#drift-detection-without-cluster-credentials-in-github)); a monthly automated pull request is noise |
| `DRRehearsalOverdue` pages | INFO only | only a person can schedule a drill, and an INFO alert nobody reads lets the calendar rot |
| Drills with the verifier key only | the writer key with a separate prefix | IAM refuses every write, so no mistake in the DR tree can touch the backups |
| #723 inside this spec (tasks 6 and 9) | its own spec | the drill is the measurement this strategy depends on; two specs would share one calendar and one record |

## Error handling

- A drill fails midway: its line says `fail` or `partial` with the tiers it
  reached, and the pull request names the gap and opens an issue. The exit
  trap runs `tofu destroy` either way.
- `tofu destroy` fails or the Mac dies during a drill: the daily leftover
  check fails the `tofu` run after 24 h and notifies ntfy; the runbook's
  last step is a manual `tofu destroy`.
- The provider has no capacity for the requested type: the module takes the
  type and location as variables; the runbook lists the fallbacks (another
  location, the next size up, another provider's module).
- The GitHub API is unreachable or rate-limited: the CronJob pushes the TSV
  values and skips the CI runs; `dr-rebuild` then goes overdue by the normal
  rule.
- A drill exceeds an RTO: the target is not raised in that pull request
  (requirement 2.3); two in a row trigger the decision review (requirement 3.4).
- A real loss during a drill: the drill stops; the DR nodes become the DR
  site only through the real-loss overlay, never the drill one.
- The Immich library outgrows the DR claim: the restore Job stops before
  writing when the snapshot is larger than 90% of `immich-data`; the fix is
  a pull request that raises the size in `components/site-dr`.
- The image step fails (no CAX server to order, the Image Factory
  unreachable): the runbook's fallbacks apply, as for node capacity.

## Verification

- Requirements 1, 3, 4.1, 4.2: review of the task 1 pull request against the
  tech-docs checklist.
- Requirements 1.3, 2.2, 6.2: repo-policy rules in CI.
- Requirement 6.4: promtool and Alertmanager tests in CI.
- Requirements 7.1, 7.2: the first scheduled `dr-rebuild` run appears on the
  dashboard.
- Requirements 8, 10.4: repo-policy over the DR render, `task render:check`
  for the home render, the drill preflight refusing to start with a writer
  key present, and the drill checking from a pod, before step 5, that
  `auth.lilalala.com` resolves to the DR Gateway.
- Requirement 10.7: the break-glass check's `tofu plan` (task 4).
- Requirements 10.1, 10.2, 10.3: `tofu validate` in CI; the leftover check's
  test.
- Requirements 2.4, 7.3, 7.4, 10.5, 10.6: the first drill's pull request
  (task 9).

Open questions: [requirements.md](requirements.md#open-questions).
