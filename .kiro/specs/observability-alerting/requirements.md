# Requirements: observability-alerting (as-is)

## Introduction

kube-prometheus-stack collects metrics; Alertmanager pages the operator on
ntfy only when a person has to act; Grafana shows everything else. Each
user-facing app has one availability SLO and an error budget. This spec
records that behaviour. Policy: [docs/sre.md](../../../docs/sre.md); how it
is measured: [docs/observability.md](../../../docs/observability.md).

Non-goals:
- Logs and traces (no log store yet; wave 3 trials one).
- Deciding anything with AI: thresholds and triggers are fixed rules.

## Glossary

- **PAGE**: an alert labelled `action: human`, sent to ntfy.
- **INFO**: an alert labelled `action: auto`, shown in Grafana only.

## Requirements

### Requirement 1: One SLO per user-facing app

**User story:** As a user, I want the apps up; as the operator, I want one
number that says whether they are up enough.

#### Acceptance criteria

1. THE system SHALL measure availability per app as the share of successful
   `blackbox-public` probes, against 99.5% over 30 days, and publish
   `slo:error_budget_remaining:ratio_rate30d{app}`.
   (`platform/kube-prometheus-stack/routes/slo.yaml`, `tests/prometheus/slo_test.yaml`)
2. WHEN a budget burns fast or slow, THE system SHALL raise the INFO alerts
   `SLOErrorBudgetBurnFast` / `SLOErrorBudgetBurnSlow`; IF the burn persists
   (30 min, or a day for a slow burn), THEN it SHALL page with the
   `...Persistent` alert. (`tests/prometheus/slo_test.yaml`)
3. IF the probes or one app's probe stop reporting, THEN THE system SHALL page
   with `SLOProbesAbsent` or `SLOTargetProbeAbsent`. (`slo_test.yaml`)
4. THE budget states (healthy, at risk, exhausted) and what each changes SHALL
   follow [sre.md](../../../docs/sre.md#error-budget-policy); budget
   exhaustion changes the work, never the deploys.

### Requirement 2: Page only when a person has to act

**User story:** As the operator, I want a notification to mean "do
something", once per cause.

#### Acceptance criteria

1. EVERY alert of a homelab PrometheusRule SHALL carry `action: human` or
   `action: auto`, one per alert name; CI fails a rule without it.
   (`scripts/ci/alertmanager-test.sh`)
2. WHEN an alert is PAGE, THE system SHALL send it to ntfy; WHEN INFO, to
   Grafana only. (`tests/alertmanager/routes.txt`)
3. THE inhibition rules SHALL hide causes behind the alert that notified;
   replayed scenarios (a Keycloak outage, an auto-rollback that works or
   fails, a node reboot, a NAS flap, a node or NAS down) SHALL send the
   expected number of notifications. (`tests/alertmanager/*.json`,
   `alertmanager-test.sh` against a real Alertmanager)
4. THE alert rules SHALL have promtool unit tests. (`tests/prometheus/`,
   `scripts/ci/promtool-check.sh`)

### Requirement 3: Quiet nights, loud outages

**User story:** As the operator, I want to sleep through what can wait, and
still hear when the house is down.

#### Acceptance criteria

1. WHILE it is 23:00-08:00 Europe/Zurich, EVERY ntfy route SHALL mute
   (`quiet-hours`); a group still firing at 08:00 notifies once.
   (`alertmanager-test.sh` checks every ntfy route and the 08:00 flush)
2. WHILE quiet hours last, THE GitHub Actions failure posts SHALL carry a
   `Delay` until 08:00. (`scripts/ci/ntfy-quiet-delay.sh`,
   `tests/bash/test_ntfy_quiet_delay.sh`)
3. THE `Watchdog` SHALL ping healthchecks.io every 5 minutes; WHEN it stops,
   healthchecks.io SHALL notify ntfy directly, quiet hours included.
4. THE node and NAS outage alerts SHALL also reach the unmuted guard topic
   the auto-rollback outage guard reads. (`ntfy-guard-url`; scenario tests)

### Requirement 4: Planned work does not page

**User story:** As the operator or an agent, I want to silence a planned
disruption narrowly and for a bounded time.

#### Acceptance criteria

1. WHEN `scripts/maintenance-silence.sh <namespace|node/<node>|cluster>
   <duration> <reason>` runs, THE system SHALL create a silence of 1m-12h
   and print its ID; `--expire <id>` ends it. (`tests/bash/test_maintenance_silence.sh`)
2. THE `cluster` target SHALL never silence `Watchdog`.
   (`maintenance-silence.sh`)

### Requirement 5: Dashboards as code

**User story:** As the operator, I want one start page and a timeline of
what automation did, from my phone.

#### Acceptance criteria

1. THE dashboards SHALL be JSON in `platform/kube-prometheus-stack/dashboards/`,
   loaded by the Grafana sidecar, with `${datasource}` everywhere and PromQL
   that parses. (`tests/test_dashboards.py`)
2. THE Homelab / Overview dashboard SHALL be the start page and link every
   other dashboard.
3. THE Homelab / Automation dashboard SHALL list the last 7 days of automated
   events (merges, reverts, syncs, backups, upgrades, silences) from
   `automation:event:timestamp_seconds`, with INFO and PAGE alerts as
   annotations. (`routes/automation.yaml`, `tests/prometheus/automation_test.yaml`,
   `tests/test_github_exporter.py`)
4. THE `grafana.db` SHALL persist on a volume, so service accounts survive
   restarts. (PVC `monitoring/kube-prometheus-stack-grafana`)
