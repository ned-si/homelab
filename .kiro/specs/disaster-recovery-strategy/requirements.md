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
rehearsal (#723) is part of it (tasks 6 and 8), not a separate spec.

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
  a scenario, per tier, from the rehearsal record. Never estimated: a
  scenario that has not been rehearsed shows "not measured".
- **Cold site**: nothing runs outside the house. A loss is answered by a
  rebuild from git and the off-site backups onto hardware that is bought or
  rented after the loss.
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
   rehearsal has measured it. (tasks 8 and 9)

### Requirement 3: The site option is chosen on cost, RTO and effort

**User story:** As the operator, I want cold, warm and hot compared on
numbers, the choice recorded with its reasons, and the conditions that would
change it.

#### Acceptance criteria

1. THE design SHALL compare the cold, warm and hot options on standing cost
   per month, cost per rehearsal or incident, RTO in the house-lost scenario,
   and effort to build and run. (design.md, "Site options")
2. THE page `docs/decisions.md` SHALL have an entry for the chosen option:
   the decision, why, the options rejected, and the measured conditions under
   which it is reviewed. (task 1)
3. WHEN two consecutive full rehearsals exceed the tier 1 RTO of the
   house-lost scenario, THE decision SHALL be reviewed in one pull request
   that changes `docs/decisions.md`. (the decision entry; the rehearsal PR)

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
2. EACH item SHALL have at least one copy outside the house and outside the
   AWS account, or the row SHALL name the gap and its issue. (review)
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
3. WHERE the operator agrees (open question 4), THE Immich library and a
   logical dump of every database SHALL also go to a second provider outside
   the AWS account, verified weekly like the S3 repositories.
   (`backup-verify`, `scripts/restic-targets.txt`)

### Requirement 6: Rehearsals on a calendar, results on the dashboard

**User story:** As the operator, I want each scenario rehearsed on a fixed
calendar and the numbers on the Data protection dashboard, so a recovery
time is a fact with a date.

#### Acceptance criteria

1. THE calendar in `docs/backups.md` SHALL list every rehearsal with its
   scenario, interval, where it runs and what it measures; live-cluster
   rehearsals run Monday to Friday in the daytime, Zurich time. (review)
2. EVERY rehearsal SHALL add a row to `ci/dr-rehearsals.tsv`: scenario, date,
   result, duration per tier, RPO reached per data class, and the pull
   request or run. (repo-policy `dr-rehearsals`: known scenarios, dates,
   numbers)
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
3. TWICE A YEAR, A full rehearsal SHALL rebuild the cluster on the DR site
   from git and restore every tier from the off-site backups, the whole
   Immich library included, timed per tier. (`scripts/dr-rehearsal.sh`, a row
   in `ci/dr-rehearsals.tsv`)

### Requirement 8: A rehearsal cannot touch production

**User story:** As the operator, I want a rehearsal that can fail in any way
without changing anything at home or in the backups.

#### Acceptance criteria

1. A REHEARSAL cluster SHALL read the bucket with the verifier key only; the
   writer and `cnpg` keys SHALL NOT be present. (`scripts/dr-rehearsal.sh`
   preflight)
2. A REHEARSAL cluster SHALL run no backup CronJob unsuspended, and no CNPG
   Cluster with a WAL archiver. (repo-policy over the rehearsal render)
3. A REHEARSAL cluster SHALL NOT write DNS (no external-dns), SHALL NOT
   notify (no ntfy receiver, no healthchecks.io ping, no Argo CD
   notifications to GitHub) and SHALL NOT join the tailnet under a production
   name. (repo-policy over the rehearsal render)
4. THE DR site in a real loss SHALL back up with new `serverName`s and new
   restic hosts, so its archives never overwrite the home cluster's.
   (`docs/runbooks/site-lost.md`)

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
2. THE password manager SHALL give a trusted person emergency access to the
   items that runbook needs; the quarterly break-glass check confirms the
   access is still set up. (`scripts/dr-offsite-check.sh` prompt; a row in
   `ci/dr-rehearsals.tsv`)

## Open questions

The operator decides these in review; the design assumes the first option
of each until then.

1. Site option: cold, with an on-demand rebuild on rented arm64 nodes
   (recommended), rather than warm or hot?
2. House-lost RTO: keep 24 h for tiers 0 and 1 and 72 h for tier 2 (the
   existing "restore from backup" values), or set a looser target for a site
   loss?
3. DR provider: a non-AWS provider such as Hetzner Cloud (survives the AWS
   account loss, pays S3 egress), or EC2 Graviton in `eu-central-1` (no S3
   transfer charge, lost with the account)?
4. A second off-site copy outside the AWS account for the Immich library and
   the database dumps (task 5): build it now, or defer it as an issue?
5. Full rehearsals with the real age key on rented nodes destroyed afterwards
   (tests the real path), or with a rehearsal key and re-sealed test secrets
   (the key never leaves the Mac)?
6. Operator unavailable: who gets password-manager emergency access, and is a
   printed instruction kept outside the house? Names stay out of git.
7. Where do the recovery codes for the password manager, the AWS root MFA and
   GitHub live outside the house, since a fire takes the phone and the Mac?
8. Calendar: node replacement and the full rebuild twice a year, the
   break-glass check quarterly, tabletops yearly. Acceptable?
9. #723: tracked as tasks 6 and 8 here and closed by task 8, rather than a
   spec of its own?
10. StorageClasses at the DR site: reuse the names `iscsi` and `iscsi-retain`
    on local storage (no app manifest changes), or site-specific classes with
    a patch per app?
