# Testing

Every change passes four layers of checks. Each layer catches what the one
before cannot. The first three run before a merge, and the last one runs at
deploy time, against production.

| Layer | Where | Runs | Blocks |
|---|---|---|---|
| 1. Local hooks | the operator's Mac | `pre-commit` on commit, `pre-push` on push | the commit or push |
| 2. Static CI | GitHub Actions `ci` (`lint`, `render`, `security`, `pr-metadata`) | every pull request and push to `main` | the merge (`ci` is the required check) |
| 3. Pre-production | GitHub Actions `ci` / `preprod`, an ephemeral kind cluster | every pull request and push to `main` | the merge |
| 4. Deploy-time smoke tests | Argo CD PostSync hooks in the live cluster | after every sync of a user-facing app | the sync, which triggers the automatic rollback |

## 1. Local hooks

`.pre-commit-config.yaml` is the one list of local checks. `task tools`
installs the hooks for `pre-commit`, `commit-msg` and `pre-push`.

- On commit (seconds): hygiene, gitleaks, yamllint, shellcheck, actionlint,
  `tofu fmt`, `scripts/leak-check.sh` (every `*.sops.yaml` is encrypted, no
  plaintext Secret, no inline credential), placeholders, KSOPS references,
  Trivy waiver hygiene, Renovate annotations and `renovate-config-validator`,
  and `scripts/render-deploy.sh` (re-renders `deploy/`).
- On commit message: Conventional Commits.
- On push: `ci-render` (`scripts/ci/render-validate.sh`), which runs the CI
  `render` job end to end: render every Application, kubeconform,
  `scripts/ci/repo-policy.sh`.

Run everything by hand:

```sh
pre-commit run --all-files
pre-commit run --all-files --hook-stage pre-push
```

Expected: every hook `Passed` (or `Skipped` when no file matches).

## 2. Static CI

`.github/workflows/ci.yaml`, parallel jobs, no cluster:

- `lint`: `pre-commit run --all-files`, skipping only the hooks that another
  CI step runs with the same script or pinned binary; then yamllint,
  actionlint, shellcheck, `tofu fmt` and `tofu validate`.
  `tests/test_precommit_parity.py` fails when the hook list and the CI steps
  drift.
- `render`:
  - unit tests: `pytest tests` (render, repo policy, workflow entry points,
    pre-commit parity) and `tests/run-bash-tests.sh` (`tests/bash/`,
    `tests/smoke/`: auto-rollback decisions, pins, merge script, PostSync hook
    script)
  - render every Application, kubeconform against pinned schemas
  - `scripts/ci/kyverno.sh`: the policy unit tests in
    `policies/kyverno/tests/`, then the policies in `policies/kyverno/` over
    every file in `deploy/`
  - `scripts/ci/repo-policy.sh`: pins, repository invariants, `deploy/`
    matches its sources, kube-linter
- `security`: gitleaks on the new commits, the Trivy gate (CRITICAL on
  presence, HIGH on delta against the merge-base).
- `pr-metadata`: PR title and every commit subject (`scripts/ci/check-title.sh`),
  every commit verified.

Kyverno policies:

| Policy | Action |
|---|---|
| `disallow-latest-tag` | Deny: blocks CI |
| `disallow-privileged` (allowlist: `kube-system`, `democratic-csi`) | Deny: blocks CI |
| `require-resources` | Audit: reported in the step summary |
| `require-probes` (Deployments) | Audit: reported in the step summary |

An Audit policy moves to Deny once `deploy/` passes it. The in-cluster Kyverno
syncs the same files, in Audit there ([security.md](security.md#admission-kyverno)).

## 3. Pre-production (kind)

The `preprod` job creates a kind cluster on the cluster's Kubernetes minor
and runs `scripts/ci/kind-preprod.sh`:

1. `crds`: installs every CRD source pinned in `ci/schemas/SOURCES.txt`
   (sha256-checked), then the CRDs vendored in `deploy/`.
2. `dry-run`: creates the namespaces, then runs
   `kubectl apply --server-side --dry-run=server` on all of `deploy/`, as
   `argocd-controller`.
3. `boot`: applies the stateless workloads listed in `ci/kind-workloads.txt`
   for real. Every Deployment must roll out, every Service must get a ready
   endpoint, and Valkey must answer `PING` through its Service.

CRD sources and images are cached, so the job takes about two minutes. It
gets no credentials for the real cluster. To add a workload, add its files to
`ci/kind-workloads.txt`. It qualifies only if it needs no PersistentVolumeClaim,
no Secret and no external service.

## 4. Deploy-time smoke tests

`components/postsync-smoke` is a kustomize Component that adds a PostSync hook
Job, `postsync-smoke`. Each user-facing app includes it and lists its URLs: the
app's in-cluster Service and its health endpoint.

| App | URLs |
|---|---|
| immich | `immich-server:2283/api/server/ping` |
| mealie | `mealie:9000/api/app/about` |
| paperless | `paperless:8000/accounts/login/` |
| syncthing | `syncthing-dashboard:8384/rest/noauth/health` |
| theater | `/ping` of sonarr, radarr, lidarr and prowlarr; `qbittorrent:8080/`, `plex:32400/identity`, `jellyfin:8096/health` |
| keycloak | `keycloak:9000/health/ready` |

The hook runs after every synced resource is Healthy. Each URL must answer
2xx or 3xx. A URL gets six tries, 5 s apart, each with a 5 s timeout.

When a hook fails, the sync fails. Argo CD Notifications then sends
`on-sync-failed`, and `.github/workflows/auto-rollback.yaml` reverts the merge
that deployed it ([decisions.md](decisions.md#automatic-rollback)). The revert
syncs and runs the hook again. If that also fails, nothing more is reverted,
because a revert is never reverted; the `ArgoCDSyncFailed` alert reports it.
A failing check therefore cannot loop.

Read a failure:

```sh
kubectl -n <namespace> logs job/postsync-smoke
```

Expected on success: one `ok   <code> <url>` line per URL.

Test the rollback path without side effects: send a dry-run dispatch, shaped
like Argo CD's, and read the `decide` job's output:

```sh
gh api repos/ned-si/homelab/dispatches -f event_type=argo-degraded \
  -F 'client_payload[app]=mealie' -F 'client_payload[trigger]=on-sync-failed' \
  -F "client_payload[revision]=$(git rev-parse origin/main)" \
  -F 'client_payload[dry_run]=true'
gh run list --repo ned-si/homelab --workflow auto-rollback.yaml --limit 1
```

## Why it is like this

- One list of checks: CI runs the pre-commit config rather than a copy of it.
  Two lists had already drifted, and a parity test is cheaper than review.
- A kind cluster rather than credentials for the real one: the public
  repository's Actions minutes are free, and no runner ever holds a key to
  production. The trade-off is that the dry-run cannot see live state (for
  example an immutable field changed against a running object). Argo CD's
  sync and the PostSync hooks cover that.
- Smoke tests as PostSync hooks rather than an external prober: a failure
  fails the sync, so it lands in the existing rollback path with its guard
  rails, with no new moving part.

Rejected: a self-hosted runner in the cluster, because it would run code from
pull requests next to production.
