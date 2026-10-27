---
kind: change
status: active
created: 2026-10-27
issue: 762
---
# Requirements: alert-triage

## Introduction

A page (`action: human`, through ntfy) arrives with a title and a runbook
link; the first five minutes go to collecting the same evidence every time,
and some pages have a fix that is the same every time too. This spec makes a
page do both before the operator opens a terminal: an Alertmanager webhook
runs the read-only snapshot (`scripts/triage.sh`, #770) and, where the alert
has one, a known fix written as code. Both land in the observability store
as structured logs, under one incident ID, behind the operator's login.

Revised 2026-10-27 (operator): a webhook, not a polling CronJob; code
remediation; nothing in a public place (the repository is public, so no
GitHub issues); the AI summary stays manual (`/homelab-debug` in Claude Code
or Kiro). The store is the one the platform settles on: SigNoz while it is
on trial as the single place for observability and security, Grafana's
stack if it fails. The receiver emits OpenTelemetry-shaped JSON logs and
takes webhooks, so either backend can read it and either alerting engine can
call it.

Non-goals:
- An AI summary in the loop (free hosted models train on what they are sent;
  a local model is not worth the hardware yet).
- Fixes that change git: a fix is a cluster action from a fixed list; a
  repository change is a pull request a person reviews.
- Triage for alerts that do not page (`action: auto`, `ticket`, warnings).
- Choosing between SigNoz and Grafana (the observability evaluation decides).

## Glossary

- **Page**: a firing, unsilenced, uninhibited alert with label `action: human`.
- **Incident**: one Alertmanager group of pages, identified by its group key;
  `incident.id` is the first 16 hex characters of its sha256.
- **Snapshot**: the output of `scripts/triage.sh <alertname>`.
- **Fix**: an entry in the remediation table: alert name, the Job it runs,
  the ServiceAccount that Job uses, and the reason it is safe to automate.
- **Store**: the log backend Vector ships to (SigNoz today).

## Requirements

### Requirement 1: A snapshot for every page

**User story:** As the operator, I want a triage snapshot taken within a
minute of a page, so the evidence of the moment is kept even if it clears.

#### Acceptance criteria

1. WHEN Alertmanager sends a firing notification for an incident, THE
   receiver SHALL start one snapshot Job for it within 60 seconds.
   (test: a fixture webhook produces one Job)
2. WHILE an incident keeps firing, Alertmanager SHALL notify the receiver at
   most every 6 hours (`repeat_interval` of its route); the receiver keeps no
   state of its own. (test: route config)
3. WHEN an incident resolves, THE receiver SHALL log a `resolved` event with
   its `incident.id` and start nothing.
4. IF a snapshot or fix Job fails, THEN the ntfy message SHALL say so, and
   `AlertTriageFailing` SHALL fire after 3 failed Jobs within 6 hours.

### Requirement 2: Known fixes run as code

**User story:** As the operator, I want a page with a known, safe fix fixed
before I look, and told what was done.

#### Acceptance criteria

1. WHEN a firing incident's alert name is in the remediation table, THE
   receiver SHALL start that fix's Job once per notification, after the
   snapshot Job. (test: table lookup)
2. EACH fix SHALL run under its own ServiceAccount with only the verbs and
   resources it needs, and SHALL be added in its own pull request with a
   test, the reason it is safe, and a line in the alert's runbook.
3. THE table SHALL start empty; the first entries come from pages whose
   runbook fix was the same twice.

### Requirement 3: Everything in one private place

**User story:** As the operator, I want the snapshot, the fix result and the
incident's history where I already look, and nowhere public.

#### Acceptance criteria

1. THE receiver and its Jobs SHALL write JSON log lines with `incident.id`,
   `alertname`, `event` (`received`, `snapshot`, `fix`, `resolved`,
   `failed`) and the output; Vector SHALL ship them to the store like any
   pod log. (test: log line shape)
2. THE ntfy message SHALL carry the alert name, the outcome counts and a link
   to the store filtered on the `incident.id`, and nothing from the snapshot
   body. (test on the message builder)
3. Nothing SHALL be written to GitHub or any other public place.

### Requirement 4: Least privilege and safe with untrusted input

**User story:** As the operator, I want the automation unable to do more
than its table allows, and unaffected by text an attacker puts in an alert.

#### Acceptance criteria

1. THE receiver's ServiceAccount SHALL only `create` Jobs and `get` their
   status in its namespace. THE snapshot ServiceAccount SHALL only
   `get`/`list` what triage.sh reads, with no `pods/exec` and no Secrets;
   the checks that need exec report `unavailable`. (Role test)
2. A Job created by the receiver SHALL use one of the ServiceAccounts in the
   table and an image from the table; a Kyverno policy SHALL reject anything
   else from the receiver's ServiceAccount. (Kyverno test)
3. Alert label and annotation values SHALL reach a Job only as the alert
   name, validated against `^[A-Za-z0-9]+$`; anything else is logged as
   `alertname rejected` and nothing starts. (test with a label holding a
   path and shell metacharacters)
4. THE receiver and its Jobs SHALL run non-root, read-only root filesystem,
   no privilege escalation; CiliumNetworkPolicies SHALL allow the receiver
   ingress from Alertmanager only, and the Jobs egress to the kube-apiserver,
   Alertmanager, github.com (the clone) and ntfy.sh only.
