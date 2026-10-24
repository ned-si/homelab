# Requirements: cilium-upgrades

## Introduction

On 2026-10-23 an automerged Cilium patch update left the shared Gateway
without listeners for about two hours
([postmortem](../../../docs/postmortems/2026-10-23-gateway-cilium-xds.md)).
A Helm-owned `cilium-config` key from the bootstrap survived the upgrade, CI
sent no traffic through a Gateway, Argo CD stayed Healthy, auto-rollback
excludes Cilium, and quiet hours held the pages. This spec makes a Cilium
change either prove the data path before it merges, or fail loudly and undo
itself after.

Non-goals:
- A second Gateway, an external probing vantage point, or a canary node.
- Changing the CNI, kube-proxy replacement or the Gateway API implementation.
- Auto-revert of Cilium minor or major updates, or of `democratic-csi`/`tuppr`.
- Release age or windows for other dependencies (gitops-delivery).

## Glossary

- **Cilium change**: a PR that changes the `cilium` chart version, a Cilium
  image, `infrastructure/cilium/` or `talos/patches/`.
- **Gateway smoke**: an HTTPS request with a known `Host` through the shared
  Gateway that must return a non-5xx status from a backend.

## Requirements

### Requirement 1: One owner for Cilium's live configuration

**User story:** As the operator, I want every Cilium setting that changed
between chart releases to be set by git, so an upgrade cannot leave a stale
value behind.

#### Acceptance criteria

1. THE Cilium values SHALL set `envoy.xdsMode` explicitly.
   (repo-policy rule `cilium-explicit-xds`)
2. THE live Cilium objects SHALL have no field owned by the field manager
   `helm`, and no `sh.helm.release.v1.cilium.*` Secret SHALL exist.
   (recorded check: `kubectl get cm -n kube-system cilium-config --show-managed-fields`, `kubectl get secret -n kube-system -l owner=helm,name=cilium`)

### Requirement 2: A Cilium change is tested on traffic before it merges

**User story:** As the operator, I want a Cilium update that breaks the
Gateway to fail its pull request, not production.

#### Acceptance criteria

1. WHEN a pull request is a Cilium change, THE Talos upgrade rehearsal SHALL
   run. (`talos-upgrade-rehearsal.sh plan`, `tests/bash/test_talos_rehearsal_plan.sh`)
2. WHEN the rehearsal cluster is up, THE rehearsal SHALL run the Gateway
   smoke through a Gateway with the repo's Cilium values and fail on a refused
   connection or a 5xx. (`talos-upgrade-rehearsal.sh gateway-smoke`)

### Requirement 3: A Cilium sync proves the data path

**User story:** As the operator, I want the `cilium` Application to fail its
sync when the Gateway does not answer, so the failure is visible in minutes.

#### Acceptance criteria

1. WHEN the `cilium` Application syncs, ITS PostSync hook SHALL run the
   Gateway smoke against the shared Gateway for `auth.lilalala.com` and
   `media.lilalala.com`; a failure fails the sync.
   (`components/postsync-smoke`, `tests/bash/test_postsync_smoke.sh`)

### Requirement 4: Cilium updates land when the operator is around

**User story:** As the operator, I want Cilium updates to wait a few days and
merge in the daytime, so a bad release is reported upstream first and a
failure finds me awake.

#### Acceptance criteria

1. THE Renovate rule for the Cilium chart and images SHALL set
   `minimumReleaseAge` of 3 days and an `automergeSchedule` on weekdays
   between 09:00 and 17:00 Europe/Zurich. (`renovate.json5`, `tests/test_renovate_config.py`)

### Requirement 5: A Gateway-wide outage reaches the operator at night

**User story:** As the operator, I want an outage of every app at once to wake
me, while single-app problems still wait for the morning.

#### Acceptance criteria

1. WHEN at least half of the SLO targets fail their probe for 5 minutes, THE
   alert `GatewayDown` SHALL fire. (`tests/prometheus/gateway_test.yaml`)
2. THE `GatewayDown` route SHALL NOT mute `quiet-hours`, and SHALL inhibit
   the per-app SLO burn alerts while it fires.
   (`tests/alertmanager/routes.txt`, `tests/alertmanager/gateway-down.json`)

### Requirement 6: A failed Cilium patch update undoes itself

**User story:** As the operator, I want a Cilium patch update that fails its
sync reverted without me, like any other app.

#### Acceptance criteria

1. WHEN the `cilium` sync fails AND the newest commit on `main` only moves the
   `cilium` chart within the same minor, THE workflow `auto-rollback` SHALL
   revert it; every other Cilium change stays on the no-revert list.
   (`scripts/ci/auto-rollback-decide.sh`, `tests/bash/test_auto_rollback.sh`)

### Requirement 7: The Gateway can be debugged from a runbook

**User story:** As the operator, I want the steps that find a Gateway fault
written down, layer by layer, so I can do it without help.

#### Acceptance criteria

1. THE runbook `docs/runbooks/alerts/GatewayDown.md` SHALL list the checks
   from the Gateway object down to Envoy and the Cilium agent, each with its
   command and expected output. (repo-policy `alert-runbooks`)
