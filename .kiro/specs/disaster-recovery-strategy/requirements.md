---
kind: change
status: active
created: 2026-11-03
issue: 918
---
# Requirements: disaster-recovery-strategy

## Introduction

The homelab can lose a node, the NAS, the whole house, the AWS account that
holds every off-site backup, or the one person who runs it. Today the answer
to each is partly written down. Backups are nightly and restored weekly
([backups.md](../../../docs/backups.md)), the RPO and RTO per tier are set
([sre.md](../../../docs/sre.md#rto-per-tier)), and a node or a power cut has a
runbook. A rebuild from git onto new hardware has never been timed. No site
other than the house has been chosen. Nothing lists what has to survive
outside the house for each loss. The only recovery times on record are the
weekly Postgres restores (90 to 431 s per cluster on 2026-11-03,
`backup_verify_restore_seconds`); every other figure is an estimate.

This spec writes the strategy down: the scenarios and their responses, the
targets per tier, the site option and the reasons for it, the off-site
inventory, and a rehearsal calendar whose measured times replace the
estimates on the Homelab / Data protection dashboard. The rebuild-from-git
rehearsal (#723) is part of it (tasks 6 and 9), not a separate spec.

The site option is decided (operator, 2026-11-03): no hot or warm site. The
DR site is cold and in the cloud: an OpenTofu module, `bootstrap/dr-cloud/`,
that is applied only when the house is lost or during a drill. It creates
arm64 nodes for Talos at a cloud provider, and the existing GitOps tree
deploys onto them with a site overlay. A timed drill applies it, restores,
measures and destroys it.

Non-goals:
- Protecting the media library (about 9.5 TB, re-acquirable, not backed up
  by decision: [backups.md](../../../docs/backups.md#what-is-not-backed-up)).
- High availability inside the house: more replicas, a second storage
  backend, a UPS. Single replica stays the design
  ([tech.md](../../steering/tech.md#constraints)).
- Changing the availability SLO (99.5% over 30 days) or the tier list.
- Chaos experiments (#733) and the pentest (#718).
- Writing restored data back into a live volume at home (a backups-dr gap,
  its own issue if needed).

## Glossary

- **Scenario**: one of the five losses: one node, the NAS, the house (fire,
  theft, or a power cut longer than the tier 1 RTO), the AWS account (closed,
  locked or suspended), the operator (unreachable for weeks).
- **RPO**: the most data a scenario may lose, per data class
  ([sre.md](../../../docs/sre.md#rpo)).
- **RTO**: the longest a tier may stay down in a scenario.
- **MTTR**: the mean of the measured durations of the last three rehearsals of
  a scenario, per tier, from the rehearsal record. A duration runs from the
  declaration to the tier's DR probes green. Never estimated: a scenario
  that has not been rehearsed shows "not measured".
- **DR probe**: a public blackbox probe run against the DR site's Gateway
  with the public host name (`curl --resolve`), so it measures the DR site
  even while public DNS points home.
- **Cold site**: nothing runs outside the house. A loss is answered by a
  rebuild from git and the off-site backups onto hardware that is bought or
  rented after the loss. Here: cloud nodes created by the DR module.
- **DR module**: the OpenTofu module `bootstrap/dr-cloud/`. Its state is
  empty in normal times; `tofu apply` creates the DR site's network, nodes
  and addresses, `tofu destroy` removes them.
- **Site overlay**: the set of patches and components that turns the home
  tree into the DR tree (storage, addresses, the Gateway, the parts that need
  the NAS). The apps' own manifests do not change.
- **Drill**: a rehearsal of the house-lost scenario on the DR site: apply the
  DR module, rebuild, restore, measure, destroy.
- **Warm site**: a small standby cluster that runs all the time outside the
  house and restores the latest backups on a schedule.
- **Hot site**: a live replica outside the house, fed continuously, ready to
  take the traffic.
- **DR site**: wherever the cluster is rebuilt after the house or the NAS is
  lost.
- **Off-site**: a copy that survives the loss of the house: in a cloud
  account, the password manager or another building.
- **Break-glass credential**: a credential needed only to recover: the AWS
  root user and its MFA, the password manager's recovery, GitHub recovery
  codes, the Keycloak `master` admin, the BMC and TrueNAS logins.
- **Rehearsal**: a timed run of a scenario's response, against production
  copies but never production itself.

## Requirements

### Requirement 1: Every scenario has a written response

**User story:** As the operator, I want each loss to have its signal, its
consequence and its first step written down, so the response does not depend
on what I remember at 3 a.m.

#### Acceptance criteria

1. THE page `docs/sre.md` SHALL have a section "Disaster scenarios" with one
   row per scenario: the signal that reports it, what is lost, what survives,
   the runbook, and the RTO per tier. (review; tech-docs checklist)
2. EACH scenario's signal SHALL be an existing PAGE alert or the external
   heartbeat: `HomelabNodeDown` (node), `HomelabNASDown` (NAS), the
   healthchecks.io heartbeat (house), `BackupNotFresh` and
   `CNPGWALArchivingFailing` (AWS account); the operator scenario names the
   person who notices instead. (`tests/alertmanager/routes.txt`)
3. EACH scenario SHALL link a runbook under `docs/runbooks/` that starts
   from the signal and ends with the check that the service is back.
   (repo-policy `dr-runbooks`: every runbook named in the table exists)
4. WHEN the house or the NAS is lost, THE runbook SHALL say when to declare
   the site lost and start the DR site: the outage is expected to outlast the
   tier 1 RTO, or the hardware is destroyed or gone.
   (`docs/runbooks/site-lost.md`)
5. THE site-lost runbook SHALL include the return home: DR-site data goes
   back by backup and restore, with new `serverName`s, as a planned cutover.
   (`docs/runbooks/site-lost.md`)

### Requirement 2: Targets per tier, and times that are measured

**User story:** As the operator, I want a target and a measured time for
every tier in every scenario, so I know which promises hold and which are
hopes.

#### Acceptance criteria

1. THE scenario table SHALL set, per tier from
   [sre.md](../../../docs/sre.md#rto-per-tier), an RPO and an RTO for each
   scenario, and SHALL keep the existing values where a scenario matches an
   existing case (service fault: 4 h tiers 0 and 1, 72 h tier 2; restore from
   backup: 24 h tiers 0 and 1, 72 h tier 2). (review)
2. THE MTTR column SHALL come only from the rehearsal record
   (`ci/dr-rehearsals.tsv`); a scenario without a rehearsal SHALL read "not
   measured". (repo-policy `dr-mttr-source`: every MTTR figure in the table
   equals the mean of its last three records)
3. WHEN a rehearsal exceeds a tier's RTO, THE rehearsal pull request SHALL
   name the gap and open an issue (`area/backups`) for it; the RTO is not
   raised in the same pull request. (rehearsal PR template in
   `docs/runbooks/dr-rehearsal.md`)
4. THE estimates in [backups.md](../../../docs/backups.md#rpo-and-rto),
   [sre.md](../../../docs/sre.md#rto-per-tier) and the runbooks ("about 45
   minutes", "about 1.5 h") SHALL be replaced by the measured value once a
   rehearsal has measured it. (tasks 9 and 10)

### Requirement 3: The site option is chosen on cost against value

**User story:** As the operator, I want cold, warm and hot compared on
numbers, the choice recorded with its reasons, and the conditions that would
change it.

#### Acceptance criteria

1. THE design SHALL compare the cold, warm and hot options on cost per month
   at AWS (`eu-central-1`, the recovery provider), and for comparison
   Google Cloud (`europe-west3`, `europe-west6`) and Hetzner, cost per drill, RTO in the house-lost scenario, and effort to
   build and run. Every price SHALL name its source and the date it was read.
   (design.md, "Cost estimate" and "Site options")
2. THE cost estimate SHALL be sized from the live cluster: CPU and memory
   requests and usage, the claims' sizes and use, the media library, and the
   measured egress; every assumption SHALL be stated. (design.md, "What the
   cluster uses")
3. THE page `docs/decisions.md` SHALL have an entry "Disaster recovery: a
   cold site in the cloud, built on demand": the decision, the monthly cost of
   each option against the value of what is hosted and the RPO and RTO per
   tier from `docs/sre.md`, the options rejected, and the conditions under
   which it is reviewed. (task 1)
4. WHEN two consecutive drills exceed the tier 1 RTO of the house-lost
   scenario, or a new price estimate changes the order of the options, THE
   decision SHALL be reviewed in one pull request that changes
   `docs/decisions.md`. (the decision entry; the drill PR)

### Requirement 4: What must exist off-site, per scenario

**User story:** As the operator, I want every item a recovery needs to have
a copy that survives the scenario it is needed for, and proof that the copy
works.

#### Acceptance criteria

1. THE page `docs/backups.md` SHALL have a section "Off-site inventory" with
   one row per item (`talosconfig` and the means to regenerate it, the SOPS
   age key, `RESTIC_PASSWORD`, `TOFU_STATE_PASSPHRASE`, the Immich library,
   every database, every break-glass credential) and one column per scenario
   naming the copy that survives it. (review)
2. EACH item SHALL have at least one copy outside the house, and each item
   other than the backups themselves SHALL also have one outside the AWS
   account, or the row SHALL name the gap and its issue. The backups (the
   Immich library, the databases) have no copy outside the AWS account by
   decision (requirement 5.4). (review)
3. QUARTERLY, THE break-glass check SHALL prove each copy works: the age key
   from the password manager decrypts a sealed file, the `talosconfig` copy
   reaches a node, `RESTIC_PASSWORD` opens `immich/library`, the state
   passphrase decrypts a state file, the AWS root user signs in with its MFA.
   (`scripts/dr-offsite-check.sh`, a row in `ci/dr-rehearsals.tsv`)
4. THE inventory, the check and every commit SHALL name items by file and key
   only; no value enters git, a pull request or a log. (gitleaks,
   `scripts/leak-check.sh`)

### Requirement 5: The AWS account can be lost without losing the backups

**User story:** As the operator, I want a closed or locked AWS account to
cost me the backup history at most, and to have backups protected again
within a day.

#### Acceptance criteria

1. WHEN backups stop reaching S3, THE existing alerts (`BackupNotFresh`,
   `CNPGWALArchivingFailing`, `CNPGBackupFailed`) SHALL page; no new alert is
   needed. (`tests/alertmanager/routes.txt`)
2. THE runbook `docs/runbooks/aws-account-lost.md` SHALL rebuild the backup
   target in a new account from `bootstrap/tofu-state`, `bootstrap/aws-backup`
   and `bootstrap/github-oidc`, re-seal the keys, move every `serverName` and
   re-seed the Immich repository, and SHALL state the target: backups fresh
   again within 24 h. (review; the yearly tabletop in the calendar)
3. THE AWS account SHALL be protected against lockout, since the backups
   have no copy outside it (an accepted risk, operator 2026-11-03): the
   root user with MFA; its credentials and recovery codes, and those of
   its mailbox, kept offline by the operator, each with one documented
   off-site place in the off-site inventory; the payment method valid for
   the next 6 months at each quarterly break-glass check. The runbook SHALL
   cover a locked or suspended account and the reopening of a closed one
   within the 90-day post-closure period before a rebuild in a new
   account. (`scripts/dr-offsite-check.sh` prompts; `docs/runbooks/aws-account-lost.md`)
4. THE page `docs/decisions.md` SHALL state the accepted risk: losing the
   AWS account together with the house loses the photo library and every
   database. (task 1)

### Requirement 6: Rehearsals on a calendar, results on the dashboard

**User story:** As the operator, I want each scenario rehearsed on a fixed
calendar and the numbers on the Data protection dashboard, so a recovery
time is a fact with a date.

#### Acceptance criteria

1. THE calendar in `docs/backups.md` SHALL list every rehearsal with its
   scenario, interval, where it runs and what it measures; live-cluster
   rehearsals run Monday to Friday in the daytime, Zurich time. (review)
2. EVERY rehearsal SHALL add a row to `ci/dr-rehearsals.tsv`: scenario, date,
   result, duration per tier, RPO reached per data class, the cost and its
   currency (drills: from the provider's bill), and the pull request or run.
   (repo-policy `dr-rehearsals`: known scenarios, dates, numbers)
3. THE Homelab / Data protection dashboard SHALL show per scenario the last
   rehearsal, its result, the duration per tier against the RTO, the MTTR,
   and the next due date. (`platform/kube-prometheus-stack/dashboards/homelab-data-protection.json`)
4. IF a scenario's last rehearsal is older than its interval plus 14 days,
   THEN `DRRehearsalOverdue` (warning, `action: human`) SHALL page once, with
   its runbook. (`tests/prometheus/dr_rehearsal_test.yaml`, repo-policy
   `alert-runbooks`)

### Requirement 7: The cluster is rebuilt from git, and timed (#723)

**User story:** As the operator, I want proof that git, the age key and the
off-site backups are enough to rebuild everything, and how long it takes.

#### Acceptance criteria

1. MONTHLY, A CI workflow SHALL boot a throwaway Talos cluster, bootstrap it
   from `bootstrap/` with test secrets, and wait for the infrastructure and
   platform layers to be Healthy; the apps with data are excluded. One step
   per phase, so the step times are the phase times.
   (`.github/workflows/dr-rebuild.yaml`)
2. THE monthly result SHALL reach the dashboard without cluster credentials
   in GitHub: a CronJob in `backup-verify` reads the run and its step times
   from the public GitHub API and pushes them.
   (`platform/backup-verify/dr-rehearsal-report.yaml`)
3. TWICE A YEAR (May and November), A drill SHALL apply the DR module,
   rebuild the cluster from git, restore every tier from the off-site
   backups, the whole Immich library included, time each step from the
   declaration to each tier's DR probes green, and destroy every resource
   it created, also when it fails. (`scripts/dr-rehearsal.sh`, a row in
   `ci/dr-rehearsals.tsv`)
4. EACH drill SHALL record its cost from the AWS bill: the cost allocation
   tag `dr-site=homelab-dr` (on every resource the module creates and every
   volume the EBS CSI driver creates) over the drill's days, plus the
   bucket's Glacier IR retrieval. The tag key SHALL be active before the
   first drill. (`ci/dr-rehearsals.tsv`; the module's default tags; task 8)

### Requirement 8: A rehearsal cannot touch production

**User story:** As the operator, I want a rehearsal that can fail in any way
without changing anything at home or in the backups.

#### Acceptance criteria

1. A REHEARSAL cluster SHALL read the bucket with the verifier key only; the
   writer and `cnpg` keys SHALL NOT be present. (`scripts/dr-rehearsal.sh`
   preflight)
2. A REHEARSAL cluster SHALL run no backup CronJob unsuspended, and no CNPG
   Cluster with a WAL archiver. (repo-policy over the rehearsal render)
3. A REHEARSAL cluster SHALL NOT write DNS records other than the
   `_acme-challenge` TXT records of cert-manager's DNS-01 challenges, made
   with the drill's own Cloudflare token (requirement 8.9; no
   external-dns), SHALL NOT notify (no ntfy receiver, no
   healthchecks.io ping, no Argo CD notifications to GitHub) and SHALL NOT
   join the tailnet. (repo-policy over the rehearsal render)
4. THE DR site in a real loss SHALL back up with new `serverName`s and new
   restic hosts, so its archives never overwrite the home cluster's.
   (`docs/runbooks/site-lost.md`)
5. INSIDE a rehearsal cluster, every `lilalala.com` name SHALL resolve to the
   DR Gateway, so OIDC clients reach the DR Keycloak and never the
   production one. Talos's CoreDNS SHALL stay enabled, in a drill and in a
   real loss; the drill gets the names from a drill-only Talos
   `StaticHostConfig` patch applied at boot. (`scripts/dr-rehearsal.sh`
   preflight: every HTTPRoute host name of the DR render is in the patch;
   the drill checks it from a pod before Argo CD is installed)
6. A REHEARSAL SHALL measure the DR site with DR probes only; the public
   probes, which still reach home, SHALL NOT count.
   (`scripts/dr-rehearsal.sh`)
7. A REHEARSAL cluster SHALL get the rehearsal age key, never the real
   one; the Secrets it needs SHALL be drill copies sealed to that key,
   holding test values except the verifier S3 key and `RESTIC_PASSWORD`.
   (`scripts/dr-rehearsal.sh` preflight;
   repo-policy: `components/site-dr-drill/secrets/` sealed to the
   rehearsal key)
8. WHEN a drill ends, pass or fail, `eu-central-1` SHALL hold no
   resource tagged `dr-mode=drill`; the EBS CSI driver SHALL tag every
   volume it creates with `dr-site=homelab-dr` and the site's `dr-mode`
   (`extraVolumeTags`: `site` in `components/site-dr`, `drill` in
   `components/site-dr-drill`). (the drill's exit trap,
   `scripts/dr-sweep.sh --delete`; the daily leftover check; repo-policy
   over both renders)
9. A DRILL's Cloudflare token SHALL be created for that drill, limited to
   the drill nodes' public addresses, expire within 12 h, be deleted when
   the drill ends, and never be written to git. (`scripts/dr-rehearsal.sh`;
   repo-policy: no Cloudflare token in `components/site-dr-drill/`)

### Requirement 9: The household is not stranded without the operator

**User story:** As a member of the household, I want to get our photos and
documents out, and to know what keeps the lights on, if the operator is not
there.

#### Acceptance criteria

1. THE runbook `docs/runbooks/operator-unavailable.md` SHALL say, in plain
   language: what keeps running on its own, which accounts must stay paid and
   renewed, and how to restore the photo library and the documents to a
   laptop with restic. It names no person and holds no value. (review;
   tech-docs checklist)
2. THE credentials and recovery codes the runbook needs SHALL be kept
   offline by the operator, each with one documented off-site place. The
   quarterly break-glass check confirms they are still in place.
   (`scripts/dr-offsite-check.sh` prompt; a row in `ci/dr-rehearsals.tsv`)

### Requirement 10: The DR site is a module applied only on loss or drill

**User story:** As the operator, I want one `tofu apply` to create the DR
site and the existing GitOps tree to deploy onto it, so a rebuild needs no
design work on the day of the loss and costs nothing until then.

#### Acceptance criteria

1. THE module `bootstrap/dr-cloud/` SHALL create, in AWS `eu-central-1`,
   the network, Graviton nodes booting the Talos arm64 AMI that Sidero Labs
   publishes, a Network Load Balancer with one Elastic IP in front of the
   Gateway node, the security groups, the instance profile the EBS CSI
   driver needs, and nothing else, every resource tagged
   `dr-site=homelab-dr` and `dr-mode=<workspace>`. A drill SHALL apply in
   the state workspace `drill` and a real loss in `site`; `plan` and
   `apply` SHALL fail in any other workspace (a `lifecycle.precondition`,
   not a `check` block, which only warns). Every named resource SHALL
   carry the workspace in its name or use `name_prefix`, so a `drill` and
   a `site` can exist at the same time. Block volumes SHALL come from the
   EBS CSI driver when a claim asks. (`tofu validate` in CI; a `tofu plan`
   in `default` fails; repo-policy `dr-cloud-names`; the task 8 smoke run
   with both workspaces applied; review)
2. THE `tofu` workflow SHALL NOT plan or apply the module; CI SHALL run
   `tofu fmt -check` and `tofu validate` on it.
   (`.github/workflows/tofu.yaml`, `.github/workflows/ci.yaml`)
3. A real loss SHALL be declared by the file `ci/dr-site-lost.txt` (the
   UTC date and the tracking issue), added by step 0 of `site-lost.md` and
   removed by the return home. THE daily `tofu` run SHALL fail and notify
   ntfy once IF a resource tagged `dr-mode=drill` is older than 24 h
   (a drill lasts at most 12 h), OR a resource tagged `dr-mode=site`, or
   an EBS volume tagged `ebs.csi.aws.com/cluster=true` without `dr-mode`,
   is older than 24 h and the file is absent, OR the file is older than
   24 h and no resource tagged `dr-mode=site` exists, OR, at any age, a
   resource tagged `dr-site=homelab-dr` has no `dr-mode` or one other than
   `drill` and `site`, or a CSI volume has a `dr-mode` other than those
   two. A drill SHALL refuse to start while the file exists.
   (`.github/workflows/tofu.yaml`, `scripts/dr-sweep.sh --check`; their
   tests; repo-policy `dr-site-lost`)
4. THE DR site SHALL deploy from the same sources as home: only the site
   overlay differs, and the home render SHALL not change because of it.
   (`task render:check`; repo-policy over the DR render)
5. THE Talos and Kubernetes APIs of the DR nodes SHALL accept connections
   only from `var.operator_cidr`, and only while it is set. In a real loss,
   THE restore order SHALL close them once `talosctl` and `kubectl` reach
   the DR site over the tailnet: a re-apply with `operator_cidr` empty,
   which removes the two rules. A drill joins no tailnet, so its rules stay
   until `tofu destroy`. In a drill, the Gateway and Syncthing ports SHALL
   also accept connections from `var.operator_cidr` only, at the NLB's
   security group; the nodes SHALL accept them only from the NLB. (the
   module's security groups; `docs/runbooks/site-lost.md` step 8; review)
6. THE runbook `docs/runbooks/site-lost.md` SHALL give the restore order:
   the declaration, the module, Talos and the upgrade to the DR schematic,
   Argo CD, the infrastructure layer, `keycloak-db` and Keycloak, tier 1, tier 2,
   backups with new `serverName`s (real loss), the restore-test,
   lock-test and `vuln-enrich` runs and the alert gate (requirement
   10.11), then `tofu destroy` (drill).
   (review; the first drill)
7. THE runbook SHALL name the command that applies the module and, for
   each input (the AWS sign-in for the state backend and the DR site, the
   state passphrase, the age key), where it comes from on a fresh
   machine without the Mac; the quarterly break-glass check SHALL run
   `tofu plan` on the module from those sources.
   (`docs/runbooks/site-lost.md`; `scripts/dr-offsite-check.sh`)
8. THE drill's cleanup SHALL NOT be able to delete the real-loss site,
   whether the declaration has merged or not: the drill's exit trap SHALL
   run `tofu destroy` in the `drill` workspace only, with `TF_WORKSPACE=drill`
   set on the call, whatever the shell exported;
   `scripts/dr-sweep.sh --delete` SHALL delete only detached EBS volumes
   tagged `dr-mode=drill`. THE only path to the site's volumes SHALL be
   `scripts/dr-sweep.sh --delete --return-home`, which SHALL refuse unless
   `ci/dr-site-lost.txt` exists on `origin/main` and the `site`
   workspace's state is empty; `site-lost.md` uses it once, in the return
   home, after the final `tofu destroy`. (`scripts/dr-sweep.sh` and its
   bash test: `--delete` leaves `dr-mode=site` volumes, volumes without
   `dr-mode` and attached volumes; `--return-home` refuses without the
   declaration or with a non-empty `site` state; `scripts/dr-rehearsal.sh`
   and its test, run with `TF_WORKSPACE=site` exported: every `tofu` call,
   the trap's included, gets `TF_WORKSPACE=drill`)
9. ON the DR site, only the EBS CSI driver's pods SHALL reach the
   instance metadata address `169.254.169.254`, where the instance
   profile's credentials are served; every other pod SHALL be denied by
   Cilium. (`components/site-dr`; repo-policy over the DR render; the
   drill checks it from a pod at step 4)
10. THE DR render SHALL hold no alert rule, probe target or
    backup-freshness target for a component, an app or a LAN address it
    does not run: its backup targets SHALL come from its own active-CronJob
    list, `ci/dr-active-cronjobs.txt`; the NAS rules of `homelab-outage`,
    the PrometheusRules `homelab-nas` and `homelab-signoz`,
    `lan-alerts.yaml`, the `SLOTargetProbeAbsent` rules of left-out apps,
    the `tuppr` and `talos-drift` Applications with their rules (Talos
    and Kubernetes upgrades on the DR site are by hand, from
    `talos/dr/`), the `postgres` term of `BackupVerifyMissing`, and every
    Probe target in `192.168.1.0/24` (`lan-icmp` included) SHALL be out,
    so no page fires for what is not there and the auto-rollback outage
    guard is not held by an absent NAS. (repo-policy over the DR render,
    with `cronjob-active` and `backup-slo-targets` reading
    `ci/dr-active-cronjobs.txt`)
11. AFTER the restore order, in a drill and in a real loss, and once
    `backup-verify-files` (with `DATA_CHECK=always`), `backup-verify-lock`
    and `vuln-enrich` have each run once, THE DR Prometheus SHALL hold no
    alert, firing or pending, that the home Alertmanager routing tree
    (`platform/kube-prometheus-stack/values.yaml`) sends to `ntfy` or
    `ntfy-urgent`, decided by `amtool config routes test` on each alert's
    labels; IF one does, THEN the drill's row SHALL be `partial` and its
    pull request SHALL list each alert and open an issue per rule. THE
    drill render SHALL NOT hold `AlertmanagerHasNoReceiverConfigured`,
    since requirement 8.3 leaves it no receiver; the site render SHALL
    keep it. (`scripts/dr-rehearsal.sh` step 8a;
    `docs/runbooks/site-lost.md` step 8a; repo-policy over both renders)
12. THE Kubernetes endpoint of the DR cluster SHALL be a node's private
    address, and every node's public address SHALL be in the API server's
    and the Talos API's certificate names, so the nodes talk over the VPC
    and the operator reaches both APIs from `var.operator_cidr` without a
    certificate error, in both shapes. (`talos/dr/talconfig.yaml`; the
    task 8 smoke run, the Full shape included)

## Decided questions

None is open. The operator asked on 2026-11-03 for each remaining question
to be decided on a reasoned default; the reasons are in
[design.md](design.md).

1. Recovery provider: **AWS `eu-central-1`**, the operator's decision of
   2026-11-03: one provider, the one that holds the backups; no second
   copy outside AWS. $659 a month always on (Full shape), $12.27 a drill,
   $2 a month at two drills a year. Google Cloud and Hetzner stay in the
   cost tables for comparison. The accepted risk: losing the AWS account
   with the house loses the backups; root MFA and recovery codes kept
   offline by the operator mitigate it (requirement 5.3).
   ([Recovery provider](design.md#recovery-provider),
   [Accepted risk](design.md#accepted-risk-one-account))
2. Recovery codes and operator unavailable: **credentials and recovery
   codes are kept offline by the operator**, each with one documented
   off-site place, named in the off-site inventory.
   ([Break-glass items](design.md#break-glass-items))
3. Drill calendar: **as proposed**: the DR drill in May and November,
   node replacement in March and September, the break-glass check
   quarterly, the AWS tabletop in June, `dr-rebuild` monthly.
   ([Rehearsal calendar](design.md#rehearsal-calendar))
4. Rehearsal key: **a separate rehearsal age key**, with drill copies of
   the Secrets sealed to it; the real key never reaches a drill node
   (requirement 8.7). ([The drill](design.md#the-drill))
5. Drill certificates: **Let's Encrypt through DNS-01, as at home**, with
   a Cloudflare token created for each drill, limited to the drill nodes'
   addresses, expiring after 12 h and deleted on exit, never in git; the
   OIDC clients trust the DR Keycloak unchanged. A drill CA was rejected:
   a trust patch per client and a path a real loss never takes.
   ([The drill's Cloudflare token](design.md#the-drills-cloudflare-token))
6. Real-loss declaration: **the file `ci/dr-site-lost.txt`**, added in a
   pull request at step 0 of `site-lost.md`, which the daily leftover
   check reads. ([Leftover check and the real-loss declaration](design.md#leftover-check-and-the-real-loss-declaration))

Settled in the operator's review of 2026-11-03: no hot or warm site; a cold
site in the cloud built by `bootstrap/dr-cloud/`, rehearsed as a timed drill
with its cost tracked. Settled in the design, on the recommended default:
the house-lost RTO keeps 24 h for tiers 0 and 1 and 72 h for tier 2; #723 is
tasks 6 and 9 here; the DR site reuses the StorageClass names `iscsi` and
`iscsi-retain`; the DR shape leaves out theater, SigNoz with Vector and
the SigNoz alert rules, the Home Assistant stack, and `backup-verify`'s
Postgres restore (attach limit); the DR site, in both shapes, runs
neither tuppr nor the Talos drift check, and is upgraded by hand;
a loss longer than two weeks moves to the Full shape; `immich-data` is
500Gi on the DR site; the nodes boot Sidero Labs' AMI and are upgraded to
the DR schematic, with no image built or kept; the Gateway sits behind a
Network Load Balancer created by the module, not the AWS Load Balancer
Controller; drill name resolution is a Talos `StaticHostConfig` patch, and
Talos's CoreDNS stays.

The spec is generic: implementation comes much later (operator,
2026-11-03). Details the last review left open are listed in
[To settle at implementation](design.md#to-settle-at-implementation), each
with the task that settles it.
