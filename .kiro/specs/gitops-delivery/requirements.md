# Requirements: gitops-delivery (as-is)

## Introduction

`main` is production. Argo CD applies every merge, Renovate keeps every
dependency current, CI is the only gate and a deploy that degrades an app is
reverted automatically. This spec records how a change travels from a branch
to the cluster today. Map: [structure.md](../../steering/structure.md),
[tech.md](../../steering/tech.md); detail:
[docs/architecture.md](../../../docs/architecture.md),
[docs/testing.md](../../../docs/testing.md).

Non-goals:
- Node configuration (`platform-talos`) and backups (`backups-dr`).
- Approval steps of any kind ([no human gates](../../../docs/decisions.md#no-human-gates)).

## Requirements

### Requirement 1: Git is the desired state

**User story:** As the operator, I want what is merged to be what runs, so
that a revert is always the rollback.

#### Acceptance criteria

1. THE root Application SHALL track `main` and fan out to three layers
   (infrastructure, platform, apps), one Application per app, every one
   automated with self-heal. (repo-policy `root-profiles`;
   `bootstrap/root-app.yaml` must equal `clusters/homelab/root.yaml`)
2. THE Applications SHALL read rendered manifests from `deploy/`, one file per
   object; WHEN `deploy/` differs from its sources, THE `render` job SHALL fail.
   (`task render:check`)
3. WHEN Renovate opens a pull request, THE `renovate-render` workflow SHALL
   re-render `deploy/` and commit it to the branch as a verified commit.
   (`scripts/ci/commit-render.sh`, `tests/bash/test_commit_render.sh`)
4. THE system SHALL NOT prune where a deletion is an outage: no Application
   carries the cascading finalizer, and every PVC carries
   `Delete=false,Prune=false`. (repo-policy `no-resources-finalizer`,
   `pvc-sync-options`)

### Requirement 2: CI is the only gate

**User story:** As the operator, I want one required check that means "safe
to deploy", so that merging needs no person.

#### Acceptance criteria

1. THE branch `main` SHALL require the strict status check `ci`, signed
   commits and linear history, for admins too, with no force push, no
   deletion and 0 required approvals. (`gh api
   repos/ned-si/homelab/branches/main/protection`)
2. THE `ci` check SHALL aggregate the jobs `lint`, `render`, `security`,
   `talos`, `talos-upgrade`, `pr-metadata` and `preprod`.
   (`.github/workflows/ci.yaml`)
3. WHEN a pull request is merged by hand, THE merge SHALL go through
   `scripts/pr-merge.sh`, which squash-merges only on a green `ci`.
   (`tests/bash/test_pr_merge.sh`)
4. THE `render` job SHALL validate `deploy/` with kubeconform at the cluster's
   Kubernetes minor and with the Kyverno policies; the `preprod` job SHALL
   dry-run all of `deploy/` server-side on a kind cluster and boot the
   stateless workloads. (repo-policy `k8s-version-match`,
   `scripts/ci/kyverno.sh`, `scripts/ci/kind-preprod.sh`)
5. THE Kyverno policies `disallow-latest-tag` and `disallow-privileged` SHALL
   block CI; `require-resources` and `require-probes` SHALL report only.
   (`policies/kyverno/`, `policies/kyverno/tests/`)

### Requirement 3: Dependencies stay current on their own

**User story:** As the operator, I want every update merged as soon as CI is
green, so that nothing waits in a queue.

#### Acceptance criteria

1. THE Renovate config SHALL automerge every update type on green CI, except
   the technical caps it names with a reason (the Immich database image, CNPG
   Postgres majors, Paperless 3 only from 2.20).
   (`.github/renovate.json5`, `task lint:renovate`)
2. EVERY container image SHALL be pinned by digest. (repo-policy `image-digest`)
3. WHEN an update changes an image tag's variant (alpine, slim, distroless,
   a distro codename), THE update SHALL be refused, except in a revert.
   (Renovate "Keep -<variant>" rules; repo-policy `image-variant`)
4. THE images SHALL avoid bulky bases where a light variant exists.
   (repo-policy `image-bulky-base`)
5. Digest-only refreshes SHALL arrive as one grouped pull request.
   (Renovate rule "Group image digest refreshes into one pull request")

### Requirement 4: A bad deploy undoes itself

**User story:** As the operator, I want a merge that breaks an app reverted
without me, but never during an outage it did not cause.

#### Acceptance criteria

1. WHEN a user-facing app syncs, ITS PostSync hook `postsync-smoke` SHALL
   probe the app's health URLs; a failure fails the sync.
   (`components/postsync-smoke`, `tests/bash/test_postsync_smoke.sh`)
2. WHEN Argo CD reports a failed sync or a Degraded app, THE workflow
   `auto-rollback` SHALL open `revert: <title> (auto)` with auto-merge, only
   if the commit is the newest on `main`, under an hour old, touched that
   app, is not `cilium` (except a chart patch update, spec cilium-upgrades),
   `democratic-csi` or `tuppr`, and is not a second automatic revert. (`scripts/ci/auto-rollback-decide.sh`, `tests/bash/test_auto_rollback.sh`)
3. IF 3 or more apps failed within 10 minutes, a node is NotReady or the NAS
   is unreachable, THEN THE workflow SHALL hold the revert back.
   (`scripts/ci/auto-rollback-guard.sh`)
4. IF an app stays Degraded for 30 minutes or OutOfSync 30 minutes after a
   failed sync, THEN THE system SHALL page with `ArgoCDAppStillDegraded` or
   `ArgoCDSyncStuck`. (`tests/prometheus/argocd_test.yaml`)
