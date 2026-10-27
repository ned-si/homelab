---
kind: change
status: active
created: 2026-10-27
issue: 762
---
# Requirements: alert-triage

## Introduction

A page (`action: human`, through ntfy) arrives with a title and a runbook
link; the first five minutes go to collecting the same evidence every time.
`scripts/triage.sh` (#770) collects it in one read-only run. This spec runs it
automatically when a page fires, so the evidence is ready before the operator
opens a terminal, without giving the automation any power to act.

Non-goals:
- Fixing anything: diagnosis only; a fix is a pull request a person merges.
- An AI summary. A later spec may add one, read-only, with a monthly budget
  cap and one run per alert group; this one is deterministic.
- Triage for alerts that do not page (`action: auto`, `ticket`, warnings).

## Glossary

- **Page**: a firing, unsilenced, uninhibited alert with label `action: human`.
- **Alert group**: the Alertmanager group of a page (alert name and its group
  labels), identified by its group key.
- **Snapshot**: the output of `scripts/triage.sh <alertname>`.

## Requirements

### Requirement 1: A snapshot for every page

**User story:** As the operator, I want a triage snapshot taken within
minutes of a page, so the evidence of the moment is kept even if it clears.

#### Acceptance criteria

1. WHEN a page starts, THE cluster SHALL take one snapshot for its alert group
   within 5 minutes. (test: a fixture page produces one run)
2. WHILE an alert group keeps firing, THE cluster SHALL take no second
   snapshot for it within 6 hours. (test: state keeps the group key)
3. IF the snapshot run fails, THEN the notification SHALL say so, and the
   `AlertTriageFailing` warning SHALL fire after 3 failed runs in a row.

### Requirement 2: The snapshot stays in the cluster

**User story:** As the operator, I want the cluster's details kept out of
the hosted ntfy.sh topic, so a leaked topic gives away a count, not the map.

#### Acceptance criteria

1. THE snapshot SHALL be stored in the cluster only: a ConfigMap
   `alert-triage-<id>` in `monitoring`, labelled `app=alert-triage`, kept
   7 days, readable through kubectl or Headlamp behind Keycloak.
   (test: expired snapshots deleted, the others kept)
2. THE ntfy message SHALL carry the alert name, the number of findings per
   section and the command to read the snapshot, and nothing from the
   snapshot body. (test on the message builder)

### Requirement 3: Read-only and safe with untrusted input

**User story:** As the operator, I want the automation unable to change the
cluster, and unaffected by text an attacker puts into an alert.

#### Acceptance criteria

1. THE triage ServiceAccount SHALL have only `get`/`list` on the resources
   triage.sh reads, `create` on `pods/exec` for the Alertmanager pod only, and
   `create`/`update`/`delete` on ConfigMaps labelled `app=alert-triage` in
   `monitoring` only (its state and snapshots), and no access to Secrets. (repo-policy or Kyverno test on the Role)
2. Alert label and annotation values SHALL reach triage.sh only as the alert
   name argument, validated against `^[A-Za-z0-9]+$`; anything else is
   dropped and the run says `alertname rejected`. (test with a Tetragon-style
   label containing a path and shell metacharacters)
3. THE triage pod SHALL run non-root, read-only root filesystem, no
   privilege escalation, with a CiliumNetworkPolicy allowing only the
   kube-apiserver, Alertmanager, GitHub (merges) and ntfy.sh.
