# Design: cilium-upgrades

## Overview

Three layers, each cheap and deterministic: make the upgrade safe to apply
(one owner, explicit values), test it on traffic before merge (rehearsal with
a Gateway smoke), and catch what still slips through after merge (PostSync
smoke, a night-time page, an automatic revert for patch updates).

## Components

| Component | Change |
| --- | --- |
| `infrastructure/cilium/values.yaml` | `envoy.xdsMode: ads`, the mode the live agents and Envoy use today |
| `scripts/ci/repo_policy.py` | rule `cilium-explicit-xds` |
| Live cleanup (recorded check) | remove the `helm` manager entries from the Cilium objects (`kubectl apply --server-side --force-conflicts` is not enough: the entries are deleted with a managedFields patch), delete `sh.helm.release.v1.cilium.v1` |
| `scripts/ci/talos-upgrade-rehearsal.sh` | `plan`: a Cilium change rehearses; `gateway-smoke`: a Gateway, an HTTPRoute and an echo backend on the rehearsal cluster, then a request through it |
| `clusters/homelab/infrastructure/cilium.yaml` | a third source with the PostSync smoke (`components/postsync-smoke`) aimed at the shared Gateway |
| `.github/renovate.json5` | a package rule for `cilium` (chart) and `quay.io/cilium/**` |
| `platform/kube-prometheus-stack/routes/` | `GatewayDown`, its route without `quiet-hours`, an inhibit rule |
| `scripts/ci/auto-rollback-decide.sh` | a patch-bump exception for `cilium` |
| `docs/runbooks/alerts/GatewayDown.md` | the layer-by-layer checks |

## Decisions

| Decision | Rejected | Why |
| --- | --- | --- |
| `xdsMode: ads`, pinned | `none` (1.20.4's new default) | `ads` is what runs today; switching the mode is its own change, tested by the rehearsal once it exists |
| Delete the `helm` managedFields entries | leave them; re-install with Argo | they are what kept the stale key; a reinstall of the CNI is an outage |
| Gateway smoke in the Talos rehearsal | a new kind job | the rehearsal already installs Cilium with the repo's values on Talos; kind runs amd64 with a different CNI setup |
| PostSync smoke on `cilium` | an Argo CD health check | health is object-level and was green during the outage |
| Release age 3 days, weekday window | no automerge | automerge keeps Cilium current without a person; the window only moves the merge to a time when a failure is seen |
| `GatewayDown` from SLO probes (half the targets) | Envoy listener metrics | the probes already exist and measure what users see; half the targets is never one app's fault |
| Auto-revert patch updates only | all Cilium updates | a patch downgrade within a minor is safe; minor downgrades and config changes stay a person's call |

## Error handling

- Rehearsal infrastructure failure (QEMU, image pull): the job fails, the PR
  waits; it does not merge on a skipped smoke.
- PostSync smoke failure: the sync fails, `ArgoCDSyncFailed` and, for a patch
  bump, the auto-revert; otherwise `ArgoCDSyncStuck` pages after 30 minutes.
- `GatewayDown` while a node is down: the node-down inhibit does not apply;
  both notify, which is intended (two causes).

## Verification

- Requirement 1: the repo-policy rule in CI; the recorded live check in
  tasks.md.
- Requirement 2: the rehearsal job on the re-apply PR of 1.20.4 (task 8) with
  `envoy.xdsMode` removed from the values must fail; with it set, pass.
- Requirements 3, 5, 6: their bash, promtool and Alertmanager tests in CI.
