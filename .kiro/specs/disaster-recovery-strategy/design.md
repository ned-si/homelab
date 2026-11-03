# Design: disaster-recovery-strategy

## Overview

A cold site in the cloud, built on demand. Nothing runs outside the house in
normal times. When the house or the NAS is lost, `tofu apply` on a new
module, `bootstrap/dr-cloud/`, creates arm64 nodes in AWS `eu-central-1`,
the region and account that already hold the backups. Talos and the
existing GitOps tree go onto them with a site overlay, the data comes back
from the S3 bucket, and the cluster comes home later by the same path. A
timed drill applies the module, restores, measures and destroys it, and
records its MTTR and its cost. Hot and warm sites are rejected on cost
([Site options](#site-options)). The recovery provider is AWS, by the
operator's decision of 2026-11-03: one provider, the one with the backups
([Recovery provider](#recovery-provider)).

Every response is rehearsed on a calendar, the measured times go into one
file in git, and a CronJob puts them on the Homelab / Data protection
dashboard. Break-glass copies that survive a fire get their own task. The
backups have no copy outside the AWS account: losing the account together
with the house loses them, an accepted risk that the account's own
protection (root MFA, recovery codes off-site, the lockout runbook)
mitigates ([Accepted risk](#accepted-risk-one-account)).

Cluster figures were read on 2026-11-03 from the live Prometheus
(datasource `prometheus`) and `kubectl --request-timeout=20s`. Prices are
on-demand list prices without VAT, read on 2026-11-03 from the providers'
own price lists ([Sources](#sources)); task 9 prices AWS again in its
calculator after the first drill.

## Scenarios

The proposed "Disaster scenarios" table for `docs/sre.md` (task 1).

| Scenario | Signal | Lost | Survives | Response |
| --- | --- | --- | --- | --- |
| One node | `HomelabNodeDown` (NotReady 15 min); `etcdInsufficientMembers` if a second control plane goes | nothing: nodes hold no data ([node-replacement.md](../../../docs/runbooks/node-replacement.md)) | every volume on the NAS, etcd on the other two control planes | reschedule happens on its own; reflash with [node-replacement.md](../../../docs/runbooks/node-replacement.md) |
| The NAS | `HomelabNASDown` (unreachable 10 min), `NASPoolUnhealthy`, `NASPoolDeviceNotOnline` | every iSCSI volume, the media share, the NAS copy of the Immich library | S3 (restic, Barman), git, the nodes | pool intact on dead hardware: move the disks to a replacement and import the pool (RPO 0); pool gone: the DR site, `docs/runbooks/site-lost.md` (task 8) |
| The house (fire, theft, a power cut longer than the tier 1 RTO) | the healthchecks.io heartbeat stops and notifies ntfy directly, at night too | nodes, NAS, router, and whatever was in the house, possibly the Mac with `~/homelab-backups/` (local dumps, etcd snapshots) and the phone with the TOTP apps | S3, git on GitHub, the password manager | a short power cut: [cold-start.md](../../../docs/runbooks/cold-start.md); otherwise the DR site, `docs/runbooks/site-lost.md` |
| The AWS account (closed, locked, suspended for billing) | `BackupNotFresh`, `CNPGWALArchivingFailing`, `CNPGBackupFailed`; the `tofu` workflow posts a failed plan | every off-site backup and its version history, the OpenTofu state bucket `ned-si-homelab-tofu-state`, the GitHub OIDC roles, the AWS cost dashboard, and the DR site's provider until access is back | every live app and its data at home, git | `docs/runbooks/aws-account-lost.md` (task 5): regain a locked or suspended account, reopen a closed one within the 90-day post-closure period, or rebuild in a new account |
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
  always-on figures become $807 (AWS), $808 (Google Cloud) and €221
  (Hetzner).
- DR shape: 805 GiB in 14 claims, the same claims without theater, SigNoz
  and Home Assistant. One more claim holds the ebook library restored from
  restic; task 7 sizes it from the snapshot, and it is not priced here.
- A 32 GiB root disk per node on AWS and Google Cloud (Hetzner servers
  include a local disk).
- The media library is a separate line: 9,000 GiB on the cheapest HDD-class
  block storage.

Volume attach limits, which the CSI drivers report to the scheduler:

| Provider | Node | Limit | DR shape needs | Free slots |
| --- | --- | --- | --- | --- |
| AWS (chosen) | `m7g.2xlarge` | 28 attachments shared by the network interfaces, the root volume and the EBS volumes | 15 volumes, 1 interface, the root volume | 11 |
| Google Cloud (comparison) | `c4a-standard-8` | 16 Hyperdisk volumes, the boot disk included | 15 plus the boot disk | 0 |

The 15 are the 14 claims of the DR shape and the ebook library claim. The
DR shape leaves out the one workload that adds claims at run time:
`backup-verify`'s weekly Postgres restore (`scripts/verify-postgres.sh`
creates one `iscsi` volume per restored cluster), which would take up to 8
of the 11 free slots during its run and leave too little margin for a
volume being replaced. Its restic checks stay; they restore into an
`emptyDir`.

A loss expected to last more than two weeks moves to the Full shape
(`var.shape = "full"`): 4 nodes and 104 slots (26 a node after the
interface and the root volume) for the 35 claims, enough for
the Postgres restore and for the media library volume when theater comes
back. Repo-policy over the DR render counts its claims against the 28
attachments of `m7g.2xlarge`, minus the interface, the root volume and a
margin of 3, so a new claim in an app fails CI before it fails a drill.

Egress: 200 GiB a month, the measured 108 GiB doubled for margin; 1 TiB a
month as the heavy-streaming case. qBittorrent seeding stays off in the
cloud: its 2.5 TiB a month would add about $220 on AWS and $200 on Google
Cloud.

### Unit prices

AWS is the recovery provider. Google Cloud and Hetzner are priced for
comparison only: the operator ruled both out as recovery providers on
2026-11-03 (one provider, the one with the backups).

| Item | AWS `eu-central-1` (chosen) | Google Cloud `europe-west3` (`europe-west6`), comparison | Hetzner (Nuremberg, Falkenstein, Helsinki), reference |
| --- | --- | --- | --- |
| 2 vCPU, 8 GiB | `m7g.large` $0.0978/h | `c4a-standard-2` $0.105966/h ($0.117640) | `CAX21` (4 vCPU) €0.0176/h, €10.99/month |
| 8 vCPU, 32 GiB | `m7g.2xlarge` $0.3910/h | `c4a-standard-8` $0.423864/h ($0.470562) | `CAX41` (16 vCPU) €0.0665/h, €41.49/month |
| SSD block storage | gp3 $0.0952/GB-month | Hyperdisk Balanced $0.094/GiB-month ($0.112) | volume €0.0572/GB-month |
| HDD block storage (media) | sc1 $0.018/GB-month | Hyperdisk Throughput $0.006/GiB-month plus $0.295 per MBps-month | none; volumes only |
| Public IPv4 | $0.005/h | $0.005/h | included in the server prices above |
| Load balancer for the Gateway | Network Load Balancer $0.027/h, plus $0.006 per NLCU-hour | not priced: the comparison keeps a static IP on the Gateway node | not priced |
| Internet egress | 100 GB a month free, then $0.09/GB up to 10 TB | Standard Tier: 200 GiB a month free, then $0.085/GiB | 20 TB per server included, then €1/TB |
| Reading the S3 bucket | Glacier IR retrieval $0.03/GB; no transfer charge from S3 to EC2 inside `eu-central-1` | retrieval plus S3 internet egress $0.09/GB | retrieval plus S3 internet egress $0.09/GB |

Every AWS and Google Cloud figure above is the provider's own published
price for the region; nothing is an estimate or a regional factor.

NLCU usage: one NLCU covers 1 GB processed an hour (or 800 new TCP
connections a second, or 100,000 active ones). The household's 200 GiB a
month is about 0.3 GB an hour, so one NLCU every hour of the month is an
upper bound.

Arm64 availability: `m7g` is in the `eu-central-1` price list; the zone is
a module variable, and the drill's preflight checks it with `aws ec2
describe-instance-type-offerings --location-type availability-zone`. For
comparison, C4A (Axion) runs in all three zones of
`europe-west3` and only in `europe-west6-b`; T2A runs in neither region (in
Europe only in `europe-west4`). Hetzner's order page showed every CAX type
as "currently unavailable" on 2026-11-03.

### Results

| | AWS `eu-central-1` (chosen) | Google Cloud `europe-west3` (comparison) | Hetzner (reference) |
| --- | --- | --- | --- |
| **Always on**, Full shape, without the media library | **$659/month** | **$663/month** (`europe-west6`: $743), without a load balancer | **€132/month** |
| Always on, with the media library (9,000 GiB) | $821/month | $743/month | €647/month |
| Heavy streaming (1 TiB a month) adds | $76/month (egress $74, NLCU $2) | $70/month | nothing |
| Warm standby: DR shape always on, without media | $397/month | $392/month | €88/month |
| **DR drill**, 8 h, DR shape, whole bucket read | **$12.27 per drill** | **$39 per drill** | **€1.04 + $35 per drill** |
| DR drill per month, two drills a year | **$2/month** | $7/month | €0.17 + $6/month |
| **Cold site, per month in normal times** (drills only) | **$2/month** | $7/month | €0.17 + $6/month |

Always on, Full shape, line by line (per month):

| Line | AWS | Google Cloud `europe-west3` | Hetzner |
| --- | --- | --- | --- |
| 3 control planes | $214.18 | $232.07 | €32.97 |
| 1 worker | $285.43 | $309.42 | €41.49 |
| Block storage | $108.24 (1,137 GiB gp3) | $106.88 (1,137 GiB) | €57.71 (1,009 GB) |
| Public IPv4 addresses | $18.25 (4 nodes and the NLB) | $14.60 (4 nodes) | included |
| Network Load Balancer | $19.71 (730 h) plus $4.38 (one NLCU an hour) | none | none |
| Egress, 200 GiB | $9.00 | $0.00 | included |
| **Total** | **$659.19** | **$662.97** | **€132.17** |
| Media library, 9,000 GiB | $162.00 (sc1) | $79.96 (Hyperdisk Throughput at its minimum of 88 MBps) | €514.80 |

DR drill, 8 hours on the DR shape:

| Line | AWS | Google Cloud `europe-west3` | Hetzner |
| --- | --- | --- | --- |
| Node | $3.13 | $3.39 | €0.53 |
| Block storage for 8 h (837 GiB; Hetzner 805 GB) | $0.87 | $0.86 | €0.50 |
| Public IPv4 | $0.08 (the node and the NLB) | $0.04 | included |
| Network Load Balancer, 8 h and one NLCU an hour | $0.26 | none | none |
| Glacier IR retrieval, 264 GiB | $7.92 | $7.92 | $7.92 |
| S3 internet egress, 300 GiB | none, same region | $27.00 | $27.00 |
| **Total** | **$12.27** | **$39.21** | **€1.04 + $34.92** |

Totals are computed before rounding. The task 8 smoke run (the DR shape
for one hour, no restore: node, root volume, NLB and two addresses) costs
about $0.45.

### Assumptions

- 730 hours a month, on demand. No savings plan or commitment: a site that
  may never run does not justify a one- or three-year commitment.
- No managed Kubernetes (EKS, GKE): Talos runs the control plane, as at home.
- No NAT gateway. Each node has a public IPv4 for egress (S3, image pulls,
  Let's Encrypt). On AWS one Network Load Balancer with one Elastic IP
  fronts the Gateway; Cilium's Envoy listens on the host network of the
  Gateway node behind it ([What the module creates](#what-the-module-creates)).
  The Google Cloud and Hetzner columns keep a public address on the
  Gateway node instead and price no load balancer.
- One zone. The house is one site; a DR site in two zones would protect
  against a loss nobody has here.
- The S3 bucket's own cost does not change: backups keep going to it.
- No second copy of the backups outside AWS: the operator decided on
  2026-11-03 to keep one provider ([Accepted risk](#accepted-risk-one-account)).
- The drill reads the whole bucket once (264 GiB in Glacier IR, 35 GiB in
  Standard, `aws_s3_bucket_size_bytes_average`). Inside `eu-central-1` only
  the Glacier IR retrieval fee applies; the comparison columns pay S3
  internet egress before AWS's 100 GB of free egress, which would lower
  them by about $9.
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
  - `AWSELB`, version 20261102102527: Network Load Balancer $0.027 per
    hour and $0.006 per used NLCU-hour (`EUC1-LoadBalancerUsage`,
    `EUC1-LCUUsage`, operation `LoadBalancing:Network`).
  - `AWSDataTransfer`, version 20260916132208: internet egress $0.09/GB for
    the first 10 TB beyond the free tier.
  - `AmazonS3`, version 20261015173540: Glacier Instant Retrieval
    retrieval $0.03/GB.
  - Human-readable pages: [EC2 On-Demand pricing](https://aws.amazon.com/ec2/pricing/on-demand/),
    [EBS pricing](https://aws.amazon.com/ebs/pricing/),
    [VPC pricing](https://aws.amazon.com/vpc/pricing/),
    [S3 pricing](https://aws.amazon.com/s3/pricing/),
    [Elastic Load Balancing pricing](https://aws.amazon.com/elasticloadbalancing/pricing/).
  - Cost allocation tags: [Activating user-defined cost allocation tags](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/activating-tags.html)
    (a key is offered for activation up to 24 h after a resource carries
    it, and activation takes up to 24 h more).
  - Account closure: [Close an AWS account](https://docs.aws.amazon.com/accounts/latest/reference/manage-acct-closing.html)
    (a closed account can be reopened within the 90-day post-closure
    period).
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
- Hetzner, reference only: [cost-optimized cloud servers](https://www.hetzner.com/cloud/cost-optimized/)
  (CAX prices with IPv4, hourly and monthly, after the price adjustment of
  15 June 2026); [block storage](https://www.hetzner.com/cloud/block-storage/).
  Hetzner's pages render the volume and traffic prices in the browser
  only, so those two come from the
  [costgoat Hetzner calculator](https://costgoat.com/pricing/hetzner)
  (updated 2026-10-20).
- Calculator for task 9: the [AWS Pricing Calculator](https://calculator.aws/).
- Cloudflare token limits: [Restrict tokens](https://developers.cloudflare.com/fundamentals/api/how-to/restrict-tokens/)
  (client IP filtering, `notBefore` and `notAfter`) and
  [Create tokens via API](https://developers.cloudflare.com/fundamentals/api/how-to/create-via-api/).

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
| Cost a month, on top of S3 ($3.07 in October 2026, $5.40 forecast for November) | none | no compute in normal times; drills $2 a month at two a year (Google Cloud for comparison: $7) | $397 (Google Cloud: $392), plus the scheduled restores | at least $659 (Google Cloud: $663), plus replication traffic |
| A year | none | about $25 (Google Cloud: $78) | $4,758 (Google Cloud: $4,701) | at least $7,910 (Google Cloud: $7,956) |
| Cost of a 3-day loss | the hardware | about $47 (DR shape: 72 h of node, storage, NLB and two addresses, plus the bucket read) | small: the data is already there | none |
| House-lost RTO | hardware lead time (days to weeks) plus an untimed rebuild | 24 h target for tiers 0 and 1, measured by the drill | hours: switch DNS, catch up the files written since the last scheduled restore | minutes |
| RPO in a house loss | 24 h promised; achieved: Postgres about 5 min, files 24 h | the same | the same | Postgres seconds; files depend on the sync |
| Effort to build | none | the site overlay, the module, the runbook (tasks 7 and 8) | the same, plus a second cluster that runs all the time | everything warm needs, plus per-app replication between sites, failover rules and split-brain handling |
| Effort to run | none | one drill of about a day, twice a year | a second cluster to upgrade (Talos, Kubernetes, charts), watch and pay for, with one operator | as warm, plus every change tested on two live sites |
| Fit with the design | | reuses git, the bucket and the restore path the weekly tests already prove | a second set of alerts and upgrades for one operator | contradicts single replica and `ReadWriteOnce` volumes on one NAS ([tech.md](../../steering/tech.md#constraints)) |

Three-day loss on AWS: 72 × ($0.391 + 2 × $0.005 + $0.027 + $0.006) +
837 × $0.0952 × 72 / 730 + $7.92 = $47.03.

### Decision

Cold in the cloud, on demand, at AWS. The operator ruled out hot and warm
on 2026-11-03 as too expensive for what is hosted, and the numbers agree:

- Warm costs $397 a month at AWS ($392 at Google Cloud, €88 at Hetzner),
  against $3.07 to $5.40 for today's whole AWS bill, to shorten an outage
  that the backups already make survivable. It also doubles what one
  person has to upgrade and watch.
- Hot needs every app replicated across sites, which the single-replica,
  one-NAS design cannot do without rewriting most apps.
- Cold with home hardware only cannot be rehearsed and has no RTO anyone can
  state. It stays the way home is rebuilt after a DR period.
- Cold in the cloud runs no compute until it is used. A drill costs $12.27
  and a three-day loss about $47. Nothing stands in normal times, so the
  cold site costs $2 a month at two drills a year.
- If the house were gone for months, the Full shape costs $659 a month
  ($821 with the media library back). That is the price of a long loss,
  paid only during it, and the reason a short loss stays on the DR shape.

Review it, in one pull request that changes `docs/decisions.md`, when two
consecutive drills exceed the tier 1 RTO of the house-lost scenario, when a
new estimate changes the order of the options, when the household asks for
a shorter outage, or when AWS stops offering on-demand Graviton instances
in `eu-central-1`.

### Recovery provider

AWS `eu-central-1`, the operator's decision of 2026-11-03: one provider,
the one that holds the backups. Google Cloud and Hetzner stay in the cost
tables for comparison only. What the choice gives:

- The backups are in the same region: the drill reads the bucket with no
  transfer charge, which makes it the cheapest drill in the table ($12.27
  against $39 at Google Cloud).
- One account, one sign-in and one bill: the state backend, the backups
  and the DR site use the same `aws login`, so a recovery needs one set of
  break-glass items fewer.
- Sidero Labs publishes Talos arm64 AMIs for the region, so there is no
  image to build or import ([Talos](#talos)).
- `m7g.2xlarge` allows 28 attachments, which leaves the DR shape 11 free
  slots; `c4a-standard-8` leaves none.
- Always on, the Full shape costs about the same as Google Cloud ($659
  against $663 without a load balancer there).

What it costs in risk: the AWS account holds both the backups and the DR
site ([Accepted risk](#accepted-risk-one-account)).

### Accepted risk: one account

Losing the AWS account loses every off-site backup and, until access is
back or a new account exists, the place to rebuild. While the house
stands, nothing is lost but the backup history: the live data is at home,
and `aws-account-lost.md` rebuilds the backup target in a new account
within 24 h. Losing the house and the AWS account for good loses the
photo library and every database: the NAS copy of the Immich library is in
the house. The operator accepted that risk on 2026-11-03 instead of a
second copy at another provider. What makes a permanent loss of the
account unlikely:

- The root user has two MFA devices: the phone, and a TOTP seed in the
  password manager's `homelab break-glass` folder, so a burnt phone does
  not lock the account.
- The root user's mailbox, which password resets go through, has its
  recovery codes in the same folder.
- The password manager's own two-step login recovery code is printed,
  sealed and held outside the house ([Break-glass and emergency
  access](#break-glass-and-emergency-access)).
- A closed account can be reopened within the 90-day post-closure period
  ([Sources](#sources)); the runbook starts there before any rebuild.
- An expired payment method is the likeliest cause of a suspension: the
  quarterly break-glass check confirms the card on file is valid for the
  next 6 months.
- Object versions in the bucket are locked, so an attacker inside the
  account cannot delete the backups before the lock expires
  ([backups.md](../../../docs/backups.md)); a closure does not respect the
  lock.

`docs/runbooks/aws-account-lost.md` (task 5) covers the lockout cases
(lost MFA, lost root password, suspended for billing), the reopening of a
closed account, and the rebuild in a new account.

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
   runs `tofu fmt -check` and `tofu validate` on it. A daily check fails,
   and so notifies ntfy, when DR resources older than 24 h exist in
   `eu-central-1` and no real loss is declared, so a forgotten drill does
   not run up $397 a month (the DR shape). The check and the declaration
   are in [Leftover check and the real-loss
   declaration](#leftover-check-and-the-real-loss-declaration).

The module's state lives in the existing state bucket. If the AWS account is
gone too, the state is empty anyway in normal times: `tofu init` with a
local backend starts from nothing.

### What the module creates

All in `eu-central-1`, one zone (`var.zone`, default `eu-central-1a`).

| Resource | What |
| --- | --- |
| Network | a VPC, one public subnet, an internet gateway and its route; no NAT gateway |
| Nodes | `m7g.large` control planes and an `m7g.2xlarge` worker (Full shape) or one `m7g.2xlarge` (DR shape, `var.shape`); the Talos arm64 AMI that Sidero Labs publishes for the region and the pinned Talos version (default schematic), moved to the DR schematic after boot ([Talos](#talos)); a 32 GiB gp3 root volume; IMDSv2 required, with a hop limit of 2 so the EBS CSI pods reach the instance metadata |
| Gateway | an internet-facing Network Load Balancer in the subnet, with one Elastic IP in its subnet mapping; TCP listeners on 80 and 443 and a `TCP_UDP` listener on 22000 (Syncthing), each to a target group with the Gateway node as its instance target and a TCP health check; its own security group |
| Addresses | the NLB's Elastic IP, the address external-dns publishes in a real loss; an auto-assigned public IPv4 on each node for egress (S3, image pulls, Let's Encrypt), also the addresses the drill's Cloudflare token is limited to |
| CSI permission | an instance profile with the AWS-managed `AmazonEBSCSIDriverPolicy`; nothing else |
| Security groups | nodes: 50000 (Talos) and 6443 (Kubernetes) from `var.operator_cidr` only, all traffic between the nodes, and 80, 443 and 22000 from the NLB's security group only. NLB: 80, 443 and 22000 from anywhere in a real loss, from `var.operator_cidr` only in a drill (`var.drill`) |
| Tags | provider `default_tags`: `dr-site=homelab-dr` and `dr-drill=<date>` on every resource |
| Outputs | node private and public addresses, the NLB's Elastic IP |

The NLB, rather than the AWS Load Balancer Controller: the module creates
it with fixed targets, so nothing in the cluster needs AWS credentials
beyond the CSI driver's, and the host-network Envoy of the home design
stays. The controller would need its own IAM policy (it creates and
deletes load balancers and security groups), a webhook, and a cloud
provider integration that Talos does not run here. The cost is that the
Gateway node is fixed: when it is replaced, `tofu apply` re-registers the
new one.

### StorageClasses and the EBS CSI driver

The DR infrastructure layer installs the `aws-ebs-csi-driver` Helm chart in
place of democratic-csi, with `controller.region: eu-central-1` and
`controller.extraVolumeTags: {dr-site: homelab-dr}`. The driver also tags
every volume it creates with `ebs.csi.aws.com/cluster=true`. Both tags make
the volumes that no tofu state holds visible to the sweep, the leftover
check and the cost report ([Leftover check and the real-loss
declaration](#leftover-check-and-the-real-loss-declaration)).

| Name | Home | DR site |
| --- | --- | --- |
| `iscsi` (default) | democratic-csi, iSCSI zvol on the NAS, `reclaimPolicy: Delete` | `ebs.csi.aws.com`, `type: gp3`, `encrypted: "true"` (the AWS-managed key), `csi.storage.k8s.io/fstype: ext4`, `reclaimPolicy: Delete`, `volumeBindingMode: WaitForFirstConsumer`, `allowVolumeExpansion: true` |
| `iscsi-retain` | the same, `reclaimPolicy: Retain` | the same as `iscsi`, `reclaimPolicy: Retain` |
| Mount options | `context=system_u:object_r:ephemeral_t:s0` | the same, so SELinux labels behave as at home |

The names stay so that no app manifest changes; the overlay says what backs
them. A volume kept by `iscsi-retain` after its claim is gone still carries
both tags, which is why the sweep looks for tags and not for the module's
state.

### Talos

- A second talhelper config, `talos/dr/talconfig.yaml`: the same Talos and
  Kubernetes versions as home (Renovate bumps both files), its own cluster
  secrets (the DR cluster is a new cluster, never a member of the home one),
  node addresses and the endpoint from the module's outputs,
  `allowSchedulingOnControlPlanes: true` as at home.
- The DR schematic drops the `sbc-rockchip` overlay and `iscsi-tools`,
  keeps `siderolabs/tailscale`, and uses the `aws` platform. It gets its
  own installer image ID; `scripts/ci/talos-validate.sh` checks both
  configs.
- One image path: Sidero Labs' AMIs carry the default schematic only. The
  nodes boot the AMI for the pinned version, then `talhelper gencommand
  upgrade` with `talos/dr/` moves each node to the Image Factory installer
  of the DR schematic: one reboot per node, timed as step 2a of the
  restore order. No image is built, imported or stored, so nothing stands
  between drills and nothing needs rebuilding on a Talos bump.
- A drill uses the same schematic, but its config carries no Tailscale auth
  key, so no node joins the tailnet (requirement 8.3).
- Name resolution in a drill: `talos/dr/drill/static-hosts.yaml`, a
  drill-only patch with one `StaticHostConfig` document whose `name` is the
  Gateway node's private address and whose `hostnames` are every
  `lilalala.com` name in the DR render's HTTPRoutes, like
  `talos/patches/talosctl/tailnet-hosts.yaml` at home.
  `scripts/dr-rehearsal.sh` writes it from the module's outputs and the
  render, and adds it with `--config-patch` at step 2. Talos's host DNS
  answers static host entries for pods since Talos v1.14.0
  ([siderolabs/talos#13347](https://github.com/siderolabs/talos/pull/13347),
  which closed [#13141](https://github.com/siderolabs/talos/issues/13141));
  the cluster runs v1.14.5. Talos's CoreDNS stays, and with
  `forwardKubeDNSToHost` at its default it forwards to the host DNS, so
  every pod resolves those names to the DR Gateway from the first boot,
  before Argo CD runs. `talos/dr/talconfig.yaml` itself carries no static
  hosts: a real loss keeps Talos's CoreDNS and public DNS unchanged.
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
| LoadBalancer addresses | LB-IPAM pools `192.168.1.200-227` and `.254`, L2 announcements | none: a VPC does not deliver addresses announced by ARP from a node. The module's NLB takes the public traffic to the Gateway node ([What the module creates](#what-the-module-creates)) | overlay: a DR values file for the `cilium` release (`infrastructure/cilium/values-dr.yaml`): L2 announcements off, pools out, the Gateway on the host network (`gatewayAPI.hostNetwork.enabled: true`) of the Gateway node only (`gatewayAPI.hostNetwork.nodes.matchLabels`, a label the DR talhelper config sets on that node), and `envoy.securityContext.capabilities.keepCapNetBindService: true`, without which Envoy cannot bind the listeners on 80 and 443 (`infrastructure/gateway/gateway.yaml`) |
| Syncthing protocol (`.201`), qBittorrent seed (`.200`) | pinned LoadBalancer addresses | Syncthing on hostPort 22000 of the Gateway node, behind the NLB's 22000 listener; qBittorrent not deployed | overlay patches, and a PolicyException `syncthing-dr` for `disallow-host-ports`, matched by namespace `syncthing` and name prefix `syncthing` like `policies/kyverno/exceptions/lan-inventory.yaml`; the Kyverno baseline denies host ports otherwise |
| Storage | democratic-csi iSCSI on the NAS; classes `iscsi` and `iscsi-retain` | the EBS CSI driver; two gp3 classes with the same names, Delete and Retain ([StorageClasses and the EBS CSI driver](#storageclasses-and-the-ebs-csi-driver)) | overlay: democratic-csi, `iscsi-volumes`, `nfs-storage` and `truenas-exporter` out; `aws-ebs-csi-driver` and the two classes in |
| Pinned volumes | static PVs in `infrastructure/iscsi-volumes/`; `volumeName` in the claims of Mealie, Paperless, Syncthing and the theater apps | dynamic | overlay removes `volumeName` from those claims |
| `immich-data` size | 2Ti on the NAS (`apps/immich/resources/library-pvc.yaml`), 349 GiB used | 500Gi, grown online when `KubePersistentVolumeFillingUp` fires; cloud volumes grow but never shrink | overlay patch; the restore Job refuses to start when the restic snapshot is larger than 90% of the claim |
| Apps left out of the DR shape | everything runs | theater (nothing to restore without the media library), SigNoz (logs only, starts empty), Home Assistant, its database, Mosquitto and Zigbee2MQTT (useless without the house) | overlay: their Applications out of the DR render; a long loss adds them back in a pull request, theater with the media library |
| Media share | NFS `192.168.1.228:/mnt/homelab/k8s/nfs/media`, inline in the theater and books apps | theater left out (nothing to restore); the books apps get their library from restic into a claim | overlay; if the house is gone for months, the media library goes on one `ReadWriteOnce` volume and the theater pods follow it to that node |
| The NAS's own backups | `backup-local` PVs: the second Immich repository, `backup-verify`'s copy | none | overlay: the NAS targets out |
| NAS alerts | `HomelabNASDown`, `NASPool*` | would page for a NAS that is gone | overlay: those rules out |
| DNS | external-dns `--default-targets` set to the WAN IP, upsert-only | the NLB's Elastic IP from the module's outputs, still A records (real loss); external-dns not deployed (drill) | overlay value |
| Resolution of `*.lilalala.com` inside the cluster | public DNS: the WAN address, back in through the Gateway | real loss: public DNS, which points at the DR Gateway. Drill: public DNS still points home, so the nodes' host DNS answers every `lilalala.com` name with the DR Gateway node's private address | none in GitOps: the drill-only Talos patch `talos/dr/drill/static-hosts.yaml` ([Talos](#talos)); Talos's CoreDNS is kept in both modes |
| OIDC | every client uses the issuer `https://auth.lilalala.com/realms/homelab` (Argo CD, Grafana, Headlamp, Immich, Mealie, Paperless) | the DR Keycloak, through the resolution above; never the production Keycloak | drill component: the egress rules that allow Keycloak through `world` (`infrastructure/network-policies/20-immich.yaml` describes the split-horizon case) get the Gateway node as well |
| TLS | cert-manager, DNS-01 on Cloudflare | real loss: unchanged. Drill: the same Let's Encrypt DNS-01 certificates, so the OIDC clients trust the DR Keycloak with no CA change; cert-manager writes only `_acme-challenge` TXT records (requirement 8.3), with a Cloudflare token created for that drill ([The drill's Cloudflare token](#the-drills-cloudflare-token)) | none (real loss); drill component: cert-manager without external-dns, its issuer reading the Secret `cloudflare-drill-token`, which the drill script creates and which is not in git |
| Tailnet | nodes join as `talos-<node>`; the operator's API proxy | real loss: `talos-dr-<n>` and `homelab-dr`; drill: no join (requirement 8) | the DR talhelper config; overlay |
| Argo CD bootstrap | `bootstrap/` with `kubeconfig_path`, `repo_url`, the root Application | the same module; `kubeconfig_path` to the DR kubeconfig, the root Application pointing at the DR render | a tfvars file |
| Postgres | CNPG clusters on their existing volumes | `bootstrap.recovery` from the Barman archive; new `serverName` (real loss) or no plugin (drill) | overlay patch per cluster |

What has to be parameterised, in short: node and endpoint addresses (the
DR talhelper config, from the module's outputs), how the Gateway and the
two pinned services are exposed (the NLB in front of the host-network
Gateway), the CSI driver behind the two StorageClass names, the size of `immich-data`, the external-dns target, the set of
components and apps (the NAS-bound ones and the ones the DR shape leaves
out), each CNPG cluster's bootstrap and `serverName`, and the rehearsal
switches (the network-policy exception, no tailnet, no notifications, the
Secrets sealed to the rehearsal key). Name resolution in a drill is a Talos
patch, outside the GitOps tree. Everything else stays as it is: the apps' manifests and
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
| The state backend, S3 `ned-si-homelab-tofu-state`, and the DR site itself | `aws login --profile homelab --region eu-central-1`: a browser sign-in with the AWS account's credentials and MFA (break-glass items: [Break-glass and emergency access](#break-glass-and-emergency-access)). One sign-in covers both: the DR site is in the same account |
| A drill's Cloudflare token | created by `scripts/dr-rehearsal.sh` with the token-creator token from the password manager ([The drill's Cloudflare token](#the-drills-cloudflare-token)); a real loss uses the home tokens from git |

```sh
git clone https://github.com/ned-si/homelab && cd homelab
aws login --profile homelab --region eu-central-1
scripts/tofu.sh bootstrap/dr-cloud init
scripts/tofu.sh bootstrap/dr-cloud apply -var shape=<dr|full> \
  -var operator_cidr=<your-public-ip>/32 -var drill=<true|false>
```

`apply` prints the node addresses and the NLB's Elastic IP. If the AWS account is lost
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
| 0 | Declare the site lost (requirement 1.4): a pull request that adds `ci/dr-site-lost.txt` ([Leftover check and the real-loss declaration](#leftover-check-and-the-real-loss-declaration)); a drill skips this step and starts its timer instead | the declaration merged; T0 is when its pull request opens | T0 |
| 1 | `tofu apply` in `bootstrap/dr-cloud/` ([Applying the module](#applying-the-module)) | nodes running, NLB targets registered, outputs printed | provision |
| 2 | `talhelper genconfig` with `talos/dr/`, `talosctl apply-config` (a drill adds `--config-patch @talos/dr/drill/static-hosts.yaml`), `talosctl bootstrap`, `talosctl kubeconfig` | every node `Ready`; in a drill, `auth.lilalala.com` resolves to the DR Gateway from a pod | Talos |
| 2a | `talhelper gencommand upgrade` with `talos/dr/`, one node at a time, from the Sidero AMI to the DR schematic | every node on the DR schematic and `Ready` | Talos |
| 3 | `tofu apply` in `bootstrap/` with the DR tfvars: Argo CD, the age key (a drill: the rehearsal key), the root Application; a drill also creates its Cloudflare token and the Secret `cloudflare-drill-token` | Argo CD syncing | Argo CD |
| 4 | Infrastructure layer: Cilium, cert-manager, the EBS CSI driver and the two classes, the Gateway | the layer Healthy; the NLB's targets healthy | tier 0 |
| 5 | CNPG operator; `keycloak-db` recovered from Barman; Keycloak | `auth` DR probe green | tier 1 starts |
| 6 | `immich-db` from Barman; the Immich library from restic `immich/library` into `immich-data` (about 300 GiB, the long step); Paperless and Syncthing from restic | `media`, `archive` and `syncthing` DR probes green | tier 1 |
| 7 | Mealie and the remaining databases; the books apps | `cook` DR probe green | tier 2 |
| 8 | Real loss: backups on with new `serverName`s and restic hosts; external-dns points the public names at the NLB's Elastic IP | `BackupNotFresh` clear | |
| 9 | Drill: write the row, delete the Cloudflare token, then `tofu destroy` and `scripts/dr-sweep.sh --delete` | the module's state empty; `scripts/dr-sweep.sh --check` finds nothing | cost |

A DR probe is the public blackbox probe of that name
(`platform/blackbox-exporter/probes/probes.yaml`), run from the operator's
machine against the DR Gateway with the public host name:
`curl -m 10 --resolve <host>:443:<gateway-address> https://<host>/<path>`.
In a real loss, once external-dns has moved the names, the public probes
take over; in a drill, public DNS still points home and the public probes
measure the home cluster, so only the DR probes count.

Each restic restore runs as a Job before its app starts: an Argo CD PreSync
hook in the DR overlay, with the image and repository settings of
`backup-verify`. The Immich restore is the step to watch: about 300 GiB
from S3 to EBS inside `eu-central-1`, never measured; the first drill
measures it.

### The drill

- `scripts/dr-rehearsal.sh`: preflight (requirement 8: the verifier key
  only, the drill component in the render, the static-host patch listing
  every HTTPRoute host name of the render, `m7g` offered in the zone, no
  `ci/dr-site-lost.txt`), `tofu apply`, the restore order above with a
  timestamp per step, then an exit trap, whatever happened: delete the
  drill's Cloudflare token, `tofu destroy` (network, nodes, the NLB, the
  addresses, the instance profile), then `scripts/dr-sweep.sh --delete`.
  The sweep deletes every EBS volume in `eu-central-1` tagged
  `dr-site=homelab-dr` or `ebs.csi.aws.com/cluster=true` (nothing at home
  uses the EBS CSI driver), and fails when an instance, a load balancer or
  an Elastic IP with the `dr-site` tag is left. That covers the volumes the
  CSI driver created, which no tofu state holds and which the
  `iscsi-retain` class keeps after their claims are gone.
- The rehearsal key. A drill never gets the real age key. It uses a
  separate age key, kept in the password manager next to the real one:
  `components/site-dr-drill/secrets/` holds a copy of each Secret the DR
  render needs, sealed to the real key and the rehearsal key, and the
  bootstrap gives Argo CD the rehearsal key only. Every copy holds test
  values except two that read real data: the verifier S3 key (read-only)
  and `RESTIC_PASSWORD`. A drill node that leaks the rehearsal key leaks
  read access to the backups, never the writer keys, the cluster secrets or
  a Cloudflare token: the drill's token is not in git at all. The real
  key's path is still proven: the quarterly break-glass check decrypts a
  sealed file with the password-manager copy, and a real loss uses
  `talos/dr/` with that key.
- Certificates: Let's Encrypt through DNS-01, as at home, so the six OIDC
  clients (Argo CD, Grafana, Headlamp, Immich, Mealie, Paperless) trust the
  DR Keycloak unchanged and the drill tests the path a real loss takes,
  with a token created for the drill ([The drill's Cloudflare
  token](#the-drills-cloudflare-token)). A drill CA was rejected: one trust
  patch per client, in four different mechanisms, plus a CA in every
  browser used for the checks, and a path that a real loss never takes.
- MTTR: T0 to each tier's DR probes green, written per tier to
  `ci/dr-rehearsals.tsv`. The mean of the last three passing drills is the
  MTTR column in `docs/sre.md`.
- The drill site is reachable only from `var.operator_cidr`, and a browser
  check during a drill needs `/etc/hosts` entries on the operator's machine
  for the drill's duration; without them the browser logs in at home.
- Certificate limits: the drill requests the same names as home from Let's
  Encrypt, which allows 5 certificates for one exact set of names a week.
  Two drills a year and the home renewals stay far below it.
- Cost: a few days later, Cost Explorer filtered on the cost allocation
  tag `dr-site=homelab-dr` over the drill's days, plus the Glacier IR
  retrieval of those days on the bucket, goes into the row's `cost` and
  `currency` columns. The `dr-site` key is activated in task 8: AWS offers
  a key for activation only after a resource has carried it (up to 24 h),
  activation takes up to 24 h more, and it is not retroactive, so task 8's
  one-hour smoke run of the module seeds the key and the operator's
  one-time set-up activates it before the first drill. If the tag is not
  active, the fallback is the same filter on EC2, EBS, ELB and public IPv4
  in `eu-central-1` over the drill's days: nothing else in the account uses
  those services. The dashboard shows the last drill's cost.
- At most 12 h; the daily leftover check catches a failed destroy.
- Monday to Friday, daytime, Zurich.

### The drill's Cloudflare token

The home tokens (`docs/secrets.md`) have Zone Read and DNS Edit on
`lilalala.com`, and a drill needs the same DNS Edit for its DNS-01
challenges: Cloudflare scopes DNS permissions to a zone, not to single
records. A standing token of that scope, sealed in the public repo and
used on cloud nodes with public addresses, could repoint
`auth.lilalala.com` and collect Keycloak logins. So the drill's token is
narrowed by the two limits Cloudflare does offer, and never stored:

- `scripts/dr-rehearsal.sh` creates it at step 3 through the Cloudflare API
  ([Create tokens via API](https://developers.cloudflare.com/fundamentals/api/how-to/create-via-api/)):
  Zone Read and DNS Edit on `lilalala.com` only; a client IP filter
  (`condition.request_ip.in`) holding the nodes' public addresses from the
  module's outputs, the addresses the cluster's egress leaves from;
  `not_before` now and `expires_on` 12 h later, the drill's maximum
  length.
- The script writes it straight into the Secret `cloudflare-drill-token`
  in `cert-manager` with `kubectl`; it is in no file, no commit and no log.
- The exit trap deletes the token through the API, whatever happened; its
  expiry covers a trap that never ran.
- The creator is a token with the API Tokens Write permission, an item in
  the password manager's `homelab break-glass` folder, used only on the
  operator's machine and never on a drill node. It can mint tokens as
  powerful as the account, so it is treated like the account's own
  sign-in.

A leak from a drill node is then usable only from the drill nodes'
addresses, and only until the drill ends.

Rejected: delegating each `_acme-challenge` name by CNAME to a separate
challenge zone (cert-manager `cnameStrategy: Follow`). Let's Encrypt
follows the CNAME for every requester, so home's cert-manager would move to
that zone as well, and the challenge zone needs a second registered
domain. A one-off token per drill gives the same protection without
changing home.

### Leftover check and the real-loss declaration

- The switch is a file in git, `ci/dr-site-lost.txt`: one line, the UTC
  date of the declaration and the issue that tracks the loss
  (`2026-05-12 #1234`). Step 0 of `site-lost.md` adds it in a pull request;
  the return home removes it in the pull request that records the final
  `tofu destroy`. Repo-policy `dr-site-lost` checks the line's format.
  A file rather than a repository variable: it is reviewed, dated and in
  the history, and only a merged pull request changes it.
- The daily check runs in the `tofu` workflow's schedule (05:17 UTC) with
  the read-only plan role `homelab-github-tofu-plan`, which task 8 grants
  `tag:GetResources`, `ec2:DescribeInstances`, `ec2:DescribeVolumes`,
  `ec2:DescribeAddresses` and `elasticloadbalancing:DescribeLoadBalancers`.
  It runs `scripts/dr-sweep.sh --check`: every instance, volume, load
  balancer and Elastic IP in `eu-central-1` tagged `dr-site=homelab-dr`,
  and every volume tagged `ebs.csi.aws.com/cluster=true`, with its
  creation time.
- It fails, and so notifies ntfy, in two cases: DR resources older than
  24 h and no `ci/dr-site-lost.txt`, a forgotten drill; or
  `ci/dr-site-lost.txt` older than 24 h and no DR resource, a declaration
  left behind or added by mistake. A real loss with its DR site running
  passes.
- A drill cannot set the switch: `scripts/dr-rehearsal.sh` never writes
  the file and refuses to start while it exists, and a drill's resources
  without the file fail the check after 24 h as they should.

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
| Cloudflare token-creator token (API Tokens Write), for drills only | the password manager, folder `homelab break-glass` | not needed | all | password manager | all | not needed |
| Rehearsal age key | the password manager, the Mac while a drill runs | not needed | all | password manager | all | not needed |
| Recovery codes and second factors: GitHub recovery codes, a second MFA device on the AWS root user (a TOTP seed), the recovery codes of the AWS root user's mailbox, Cloudflare recovery codes | the password manager, folder `homelab break-glass`, one item each | all | all | password manager | all | emergency access |
| The password manager's own recovery (its two-step login recovery code) | a printed sealed envelope held by the emergency contact, outside the house | all | all | the envelope | all | the envelope |
| Immich library | live on the NAS, the NAS restic repository, S3 `immich/library` | all | S3 | S3 | live and the NAS copy | S3 or the NAS, with `RESTIC_PASSWORD` |
| Databases | live on the NAS; Barman WAL and base backups in S3 `cnpg/`; `pg_dump` of Mealie, Home Assistant and the four *arr clusters in restic; dumps by hand on the Mac | all | S3 | S3 | live, and the Mac's dumps if recent | S3 |
| Cluster configuration | git on GitHub, every clone | all | all | GitHub | all | GitHub |
| Break-glass credentials | the password manager | all | all | password manager, through the envelope if the phone is gone | all | emergency access |

Gaps until the tasks land:

- **The AWS account and the house together.** The Immich library and every
  database exist only in S3 once the house is gone. This gap stays by
  decision: one provider, no copy outside AWS
  ([Accepted risk](#accepted-risk-one-account)). Task 5 hardens the
  account against lockout instead.
- **Recovery codes, the envelope and emergency access.** Not set up yet;
  task 4 sets them up and adds them to the break-glass check
  ([Break-glass and emergency access](#break-glass-and-emergency-access)).

### Break-glass and emergency access

Decided 2026-11-03, on the operator's direction: documented locations in
the password manager plus an emergency contact.

- Every recovery code and second factor a recovery needs is an item in the
  password manager's folder `homelab break-glass`. The inventory above names
  the items; git never holds a value. The AWS root user gets a second MFA
  device (AWS allows several per root user), a TOTP seed in that folder, so
  a burnt phone does not lock the account.
- The password manager is then the single way in, so its own recovery must
  not depend on the house: its two-step login recovery code is printed,
  sealed in an envelope and held by the emergency contact, outside the
  house. The master password stays in the operator's head.
- The emergency contact is a trusted person outside the household, named
  only in the password manager. They get the password manager's emergency
  access, view only, with a 2-day wait: short next to the household's
  7-day target, long enough for the operator to refuse a request made by
  mistake. Emergency access covers the operator's whole individual vault,
  not one folder: after the wait, the contact can see every item, the
  homelab ones and the personal ones. That is accepted: the person is
  trusted with the age key anyway, which opens every backup. The
  alternative, sharing only the break-glass folder through an organization
  collection, was rejected: a shared collection is readable at once, with
  no wait period and no chance for the operator to refuse.
- The household gets a printed copy of
  `docs/runbooks/operator-unavailable.md`.
- Trade-off: the root MFA seed in the same vault as the root password makes
  the vault one factor for AWS. It already holds the age key, which opens
  every backup, so the vault is the keystone either way; its own
  protection (master password, second factor, the envelope) is what
  matters.
- The quarterly break-glass check confirms each item exists and signs in
  with it, and that emergency access is still granted; the yearly
  walk-through (December) confirms with the emergency contact that the
  envelope is still sealed and in their keeping.

## Rehearsal calendar

The calendar for `docs/backups.md` (task 1), decided 2026-11-03 as
proposed. Live work keeps the operator's rule: Monday to Friday, daytime,
Zurich.

| Rehearsal | Scenario | Interval | Where | Measures |
| --- | --- | --- | --- | --- |
| `backup-verify` (exists) | data of every scenario | weekly, Saturday and Sunday evenings | home cluster | restore per CNPG cluster, restic samples, the bucket lock |
| `dr-rebuild` CI (#723, task 6) | tier 0 from git | monthly, first Tuesday | GitHub Actions, Talos in QEMU | time from empty nodes to infrastructure and platform Healthy, without data; a lower bound for tier 0 |
| Break-glass check (task 4) | the house, the AWS account, the operator | quarterly: January, April, July, October | the Mac and the password manager | each item of the inventory works; emergency access still set up; the AWS payment method valid for the next 6 months |
| Node replacement (task 10) | one node | twice a year: March and September, `homelab-w-1` first, then a control plane in turn | home cluster | reset to `Ready`, and to every tier 1 probe green |
| DR drill (#723, task 9) | the NAS, the house | twice a year: May and November | the DR module in AWS `eu-central-1` | each step and tier against its RTO, the full Immich restore, the RPO reached, the cost |
| AWS account tabletop | the AWS account | yearly, June | desk: walk `docs/runbooks/aws-account-lost.md` (lockout, reopening, rebuild); sign in as root with the second MFA device | pass or fail, and the steps that did not match |
| Operator walk-through | the operator | yearly, December | the emergency contact, with `docs/runbooks/operator-unavailable.md` | one album and one document restored to a laptop; the envelope still sealed |

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
| `docs/decisions.md` | entry "Disaster recovery: a cold site in the cloud, built on demand", with the cost per option at AWS (Google Cloud and Hetzner for comparison), AWS as the one provider, and the accepted one-account risk | 1 |
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
| `docs/runbooks/aws-account-lost.md` (lockout, reopening, rebuild); the second root MFA device and the root mailbox's recovery codes in the break-glass folder | the AWS scenario | 5 |
| `.github/workflows/dr-rebuild.yaml` | monthly rebuild in CI, on the QEMU harness of `scripts/ci/talos-upgrade-rehearsal.sh` | 6 |
| `components/site-dr` (with the `immich-data` size and the `syncthing-dr` PolicyException), `infrastructure/cilium/values-dr.yaml` (host-network Gateway on the labelled node, `keepCapNetBindService`), `components/site-dr-drill` (the network-policy exception, the Secrets sealed to the rehearsal key, no notifications), `clusters/dr/`, the DR render, repo-policy over it (requirement 8 switches, claims against the attach limit) | the site overlay | 7 |
| `bootstrap/dr-cloud/` for AWS `eu-central-1` (VPC, Graviton nodes, the NLB, the EBS CSI instance profile, `backend_override.tf.example`), `scripts/dr-sweep.sh`, `talos/dr/talconfig.yaml`, `ci/dr-site-lost.txt` and repo-policy `dr-site-lost`, the leftover check in `.github/workflows/tofu.yaml` with the plan role's read permissions in `bootstrap/github-oidc`, `tofu validate` in `ci`, `docs/runbooks/site-lost.md`, the smoke run and the `dr-site` cost allocation tag | the DR module | 8 |
| `scripts/dr-rehearsal.sh`, `talos/dr/drill/static-hosts.yaml` (written by the script) | the timed drill, preflight for requirement 8, drill name resolution, the per-drill Cloudflare token, the DR probes, token deletion, destroy and sweep on exit | 9 |
| `.kiro/specs/backups-dr/` | the area spec updated: scenarios, the off-site inventory, the calendar, the DR site | 9 |

## Decisions

| Decision | Rejected | Why |
| --- | --- | --- |
| Cold site in the cloud, built on demand by `bootstrap/dr-cloud/` | warm standby, hot replica, cold with home hardware only | see [Decision](#decision) |
| Volumes from the provider's CSI driver | volumes created by the module | claim sizes stay in git; no static PV per volume |
| The DR site reuses the StorageClass names `iscsi` and `iscsi-retain` | site-specific classes and a patch per app | no app manifest changes; the class names describe home, the overlay says what backs them |
| `immich-data` at 500Gi on the DR site, grown online | the 2Ti in git | 2 TiB of cloud SSD costs $147 a month more on AWS for 1.5 TiB nobody uses; cloud volumes grow online but never shrink |
| Recovery provider: AWS `eu-central-1`, the account that holds the backups | Google Cloud C4A; Hetzner CAX; a second copy of the backups outside AWS | the operator's decision of 2026-11-03: one provider; in-region reads, one sign-in, published Talos AMIs ([Recovery provider](#recovery-provider)); the one-account risk accepted ([Accepted risk](#accepted-risk-one-account)) |
| The Gateway behind a Network Load Balancer created by the module | the AWS Load Balancer Controller; an Elastic IP on the Gateway node | no AWS credentials in the cluster beyond the CSI driver's, the host-network Envoy stays; an NLB keeps the public address stable when the Gateway node is replaced, for $19.71 a month plus NLCUs |
| The Sidero Labs AMI, then a Talos upgrade to the DR schematic | an AMI built from the Image Factory and kept, or imported on the day | nothing to build or store; the upgrade is one reboot per node, timed as step 2a |
| EBS CSI volumes tagged `dr-site=homelab-dr` through `extraVolumeTags`, swept by tag | volumes found through the module's state | the CSI driver creates volumes outside any tofu state, and `iscsi-retain` keeps them after their claims go |
| A Cloudflare token created for each drill, IP-filtered and expiring, deleted on exit | a standing drill token sealed in git; a separate challenge zone with CNAME delegation | Cloudflare scopes DNS Edit to a zone, so a standing token could rewrite any record; a challenge zone would move home's challenges too ([The drill's Cloudflare token](#the-drills-cloudflare-token)) |
| The real-loss declaration as `ci/dr-site-lost.txt` | a repository variable | reviewed in a pull request, dated, in the history; the leftover check fails both on resources without it and on it without resources |
| Emergency access to the whole vault after a 2-day wait | an organization collection with only the break-glass items | a collection has no wait period and no refusal; the contact is trusted with the age key anyway |
| Drill name resolution by a drill-only Talos `StaticHostConfig` patch | disabling Talos's CoreDNS and deploying a replacement from the drill component | Talos v1.14 host DNS serves static hosts to pods; the patch works from the first boot, while a replacement CoreDNS synced by Argo CD needs cluster DNS to exist first; the real-loss config stays untouched |
| The DR shape without `backup-verify`'s Postgres restore; the Full shape for a loss longer than two weeks | a larger single node | the restore adds up to 8 volumes during its run, most of the DR shape's 11 free slots; a long loss needs the Full shape's capacity anyway |
| Drills with a separate rehearsal key and drill copies of the Secrets | the real age key on the drill nodes | a leak from a drill node exposes read access to the backups, not every secret in git; the real key is proven by the break-glass check |
| Drill certificates from Let's Encrypt DNS-01, as at home, with the per-drill Cloudflare token | a drill CA mounted into every OIDC client; Let's Encrypt staging | the clients trust the DR Keycloak with no per-app change, and the drill tests the real path; the cost is `_acme-challenge` TXT records in the production zone, written with a token usable only from the drill nodes and only during the drill |
| Recovery codes in the password manager, its own recovery in an envelope with the emergency contact | codes on paper in the house; a second password manager | one documented place for every code; the one thing that cannot live in the vault, the vault's own recovery, lives outside the house |
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
  last steps are a manual `tofu destroy` and `scripts/dr-sweep.sh
  --delete`. The Cloudflare token expires on its own 12 h after creation.
- AWS has no capacity for the requested type (`InsufficientInstanceCapacity`):
  the module takes the zone and the instance types as variables; the
  runbook lists the fallbacks (another zone of `eu-central-1`, then
  another Graviton family of the same size, such as `m6g` or `m8g`, each
  checked with `aws ec2 describe-instance-type-offerings` first).
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
- The Image Factory is unreachable at step 2a: the nodes stay on the Sidero
  AMI's default schematic, which runs everything except the Tailscale
  extension. A drill continues and records the gap; a real loss continues
  with `talosctl` over the module's `var.operator_cidr` rule until the
  Factory is back.
- The AWS account is locked during a real loss: `aws-account-lost.md`
  first; the DR site waits for access.

## Verification

- Requirements 1, 3, 4.1, 4.2: review of the task 1 pull request against the
  tech-docs checklist.
- Requirements 1.3, 2.2, 6.2: repo-policy rules in CI.
- Requirement 6.4: promtool and Alertmanager tests in CI.
- Requirements 7.1, 7.2: the first scheduled `dr-rebuild` run appears on the
  dashboard.
- Requirements 8, 10.4: repo-policy over the DR render, `task render:check`
  for the home render, the drill preflight refusing to start with a writer
  key present or with a render host name missing from the static-host
  patch, and the drill checking from a pod, at step 2 and before Argo CD,
  that `auth.lilalala.com` resolves to the DR Gateway.
- Requirement 10.7: the break-glass check's `tofu plan` (task 4).
- Requirements 10.1, 10.2, 10.3: `tofu validate` in CI; the leftover check's
  test, with both failure cases (resources without the declaration, the
  declaration without resources); repo-policy `dr-site-lost`; the task 8
  smoke run.
- Requirement 8.9: repo-policy (no Cloudflare token in the drill
  component); the drill's pull request shows the token's expiry and its
  deletion in the log.
- Requirement 5.3: the quarterly break-glass check's prompts; the June
  tabletop.
- Requirements 2.4, 7.3, 7.4, 10.5, 10.6: the first drill's pull request
  (task 9).

Decisions on the former open questions: [requirements.md](requirements.md#decided-questions).
