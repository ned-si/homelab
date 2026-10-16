# Requirements: wave 3 reliability (runbooks and SLO refinements)

## Introduction

Every page should tell the person holding the phone what to do, and the SLOs should see
more than "the probe answered". Today no custom alert carries a `runbook_url` (0 of the
alerts in the homelab PrometheusRules), the only SLI is availability, nothing measures
backup freshness as an objective, and a restic CronJob that silently stops running pages
nobody (only a failed Job pages). This feature adds a runbook for every alert that can
page, enforced by CI, a latency SLO and a backup-freshness SLO per `docs/sre.md`, and a
deterministic pause of Renovate automerge for an app that is out of budget and still
failing.

Non-goals:
- Changing the availability objective (99.5%), the tiers, the RPO or the RTO.
- Changing which existing alerts page (`action: human` vs `action: auto`), their routes,
  grouping, inhibition or quiet hours, beyond the routes this feature adds.
- Editing chart-provided rules (kube-prometheus-stack, tuppr) or their annotations.
- An external probing vantage point; the healthchecks.io heartbeat stays the only one.
- Log-based alerts (they come with the log pipeline, spec `wave3-network-logs`).
- Postmortems, the toil register and the threat model.

## Glossary

- **PAGE alert**: an alert that can reach the `ntfy` receiver: every homelab rule labelled
  `action: human`, plus the chart rules the Alertmanager routes name (etcd quorum, the
  tuppr upgrade alerts, `KubeJobFailed` of a `*-backup-*` Job, critical `category: security`).
- **Homelab rule**: an alert in a `PrometheusRule` under `platform/` or `apps/`.
- **Runbook section**: the page `docs/runbooks/alerts/<AlertName>.md` of a homelab rule,
  or the row naming a chart rule in the chart table of `docs/runbooks/alerts/README.md`.
- **SLO app**: an `app` value in the `homelab.slo.apps` group of
  `platform/kube-prometheus-stack/routes/slo.yaml`.
- **Backup target**: a restic backup CronJob (name contains `-backup`) or a CNPG cluster.

## Requirements

### Requirement 1: A runbook for every page

**User story:** As the operator, I want each notification to link to the steps for that
exact alert, so that I can act from the phone without searching the repo.

#### Acceptance criteria

1. THE repository SHALL contain one runbook section per PAGE alert name under
   `docs/runbooks/alerts/`, each listed in its `README.md`.
2. EVERY homelab rule with `action: human` SHALL carry the annotation
   `runbook_url: https://github.com/ned-si/homelab/blob/main/docs/runbooks/alerts/<AlertName>.md`.
3. EACH runbook section SHALL state, in the `tech-docs` runbook form: what the alert means
   and why a person is needed, the checks as copy-paste commands with their expected output,
   the fix, how to verify it, and what to do when the fix does not work.
4. WHERE a chart rule pages by name and the chart supplies a `runbook_url`, ITS runbook
   section SHALL link the upstream runbook and add the homelab-specific steps.
5. WHEN a notification reaches ntfy for an alert with a `runbook_url`, THE notification
   SHALL contain that URL.
6. IF a homelab rule with `action: auto` carries a `runbook_url`, THEN it SHALL follow the
   form of 1.2 and resolve.

### Requirement 2: CI keeps the runbooks and tests complete

**User story:** As the operator, I want CI to refuse an alert without a runbook or a test,
so that the guarantee does not rot as alerts are added.

#### Acceptance criteria

1. IF a homelab rule with `action: human` has no `runbook_url`, a URL not of the form in
   1.2, or a page that does not exist, THEN CI SHALL fail and name the alert and file.
2. IF `docs/runbooks/alerts/` has a page for an alert name that no `action: human`
   homelab rule defines, THEN CI SHALL fail (stale section).
3. IF an alert name on an `ntfy` line of `tests/alertmanager/routes.txt` has no runbook
   section, THEN CI SHALL fail.
4. IF a homelab rule's alert name is not the `alertname` of at least one
   `alert_rule_test` in `tests/prometheus/*_test.yaml`, THEN CI SHALL fail.
5. THE checks SHALL run in the existing `render` job (`scripts/ci/repo_policy.py`), read
   only the repository, and give the same result on the same tree.

### Requirement 3: A latency SLO per app

**User story:** As a user of the apps, I want slow responses to count against the
service, so that "up but unusable" is seen and fixed.

#### Acceptance criteria

1. THE system SHALL record, per SLO app and for the windows of the availability SLO, the
   share of `blackbox-public` probes that failed or took longer than the app's threshold.
2. EACH SLO app SHALL have one latency threshold, chosen by a script as the smallest value
   of the ladder 0.25, 0.5, 1, 2, 5 seconds that is at least twice the app's p95
   `probe_duration_seconds` over the 14 days before the change, and committed as a static
   value.
3. THE latency objective SHALL be 99% of probes under the threshold over 30 days, with
   `slo:latency_budget_remaining:ratio_rate30d{app}` recorded as for availability.
4. WHEN the latency budget burns at the slow-burn rates of the availability SLO,
   `SLOLatencyBudgetBurnSlow` SHALL fire with `action: auto`; WHEN it has fired for one day,
   `SLOLatencyBudgetBurnSlowPersistent` SHALL fire with `action: human`.
5. WHILE an availability burn alert of the same app fires, THE latency burn alerts of that
   app SHALL NOT fire, so one outage notifies once.
6. THE self-SLA and the error-budget policy of `docs/sre.md` SHALL stay the availability
   number; the latency objective SHALL be documented as an internal objective.
7. THE Homelab overview dashboard SHALL show the latency SLI and budget next to
   availability.

### Requirement 4: A backup-freshness SLO

**User story:** As the operator, I want the 24 h RPO measured as an objective, and a page
when a backup simply stops happening, so that a silent stop is not found during a restore.

#### Acceptance criteria

1. THE system SHALL record, per backup target, whether its last successful backup is
   younger than 26 hours (restic: the CronJob's last successful run; CNPG: the last
   available base backup).
2. THE freshness objective SHALL be 99% of the time over 30 days per target, recorded as
   `slo:backup_freshness:ratio_rate30d{kind, target}`.
3. WHEN a restic backup CronJob has had no successful run for 26 hours, `BackupNotFresh`
   SHALL fire with `action: human`, whatever the cause (failed, suspended, never
   scheduled, deleted while still listed in `ci/active-cronjobs.txt`).
4. THE system SHALL NOT page twice for one stale target: CNPG staleness stays
   `CNPGBaseBackupTooOld`, and `BackupNotFresh` SHALL be inhibited while a `KubeJobFailed`
   page for the same CronJob fires.
5. THE Data Protection dashboard SHALL show freshness and the 30-day objective per target.
6. THE RPO table of `docs/sre.md` SHALL name the freshness SLO as the measure of the
   promise.

### Requirement 5: Automerge pauses while an app is out of budget and still failing

**User story:** As the operator, I want Renovate to stop adding changes to an app that is
out of budget and still unstable, so that a struggling app is not hit by unrelated
updates, without any person deciding when to pause or resume.

#### Acceptance criteria

1. WHILE an SLO app's availability budget remaining is at or below 0 AND an availability
   burn alert of that app fires, THE `ci` check SHALL fail for a Renovate pull request
   that changes that app's files, unless the pull request carries the label `security`.
2. WHEN that condition ends, THE held pull requests SHALL be re-evaluated within one hour
   without a person, and merge on green CI as before.
3. IF the budget state cannot be read, THEN the gate SHALL pass; it can only hold back.
4. THE gate SHALL NOT affect pull requests that are not from Renovate, nor apps whose
   budget is not exhausted.
5. THE mapping from SLO app to repository paths SHALL be one file that CI checks against
   the SLO app list.
6. `docs/sre.md` (error-budget policy and "Why it is like this") SHALL describe the pause
   in the same pull request.

### Requirement 6: Every new alert follows the paging rules

**User story:** As the operator, I want new alerts to follow the same rules as the
existing ones, so that paging stays "a person has to act".

#### Acceptance criteria

1. EVERY alert added by this feature SHALL carry `action: human` or `action: auto` and at
   least one promtool test, including a case where it must not fire.
2. EVERY PAGE alert added by this feature SHALL have a runbook section, a line in
   `tests/alertmanager/routes.txt`, and a row in the PAGE table of `docs/sre.md`.
3. THE alerts SHALL be deterministic PromQL with fixed thresholds; no AI judges whether to
   alert, pause or merge.
