# Testing

Every change passes four layers of checks. Each layer catches what the one
before cannot. The first three run before a merge, and the last one runs at
deploy time, against production.

| Layer | Where | Runs | Blocks |
|---|---|---|---|
| 1. Local hooks | the operator's Mac | `pre-commit` on commit, `pre-push` on push | the commit or push |
| 2. Static CI | GitHub Actions `ci` (`lint`, `render`, `tests`, `promtool`, `alertmanager`, `security`, `pr-metadata`, `site`, `dashboard`) | every pull request and push to `main` | the merge (`ci` is the required check) |
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

`.github/workflows/ci.yaml`, parallel jobs, no cluster. `ci` needs every job
and fails unless each one passed (`tests/test_ci_workflow.py` keeps the list
complete). `render` and `tests` install the same tools, so no test skips
for a missing tool; `promtool` and `alertmanager` install only the binaries
their script runs, and the script fails when one is missing.

- `lint`: `pre-commit run --all-files`, skipping only the hooks that another
  CI step runs with the same script or pinned binary; then yamllint,
  actionlint, shellcheck, `tofu fmt` and `tofu validate`.
  `tests/test_precommit_parity.py` fails when the hook list and the CI steps
  drift.
- `render`:
  - render every Application, kubeconform against pinned schemas
  - `scripts/ci/kyverno.sh`: the vendor check, the policy unit tests in
    `policies/kyverno/tests/`, then the policies in `policies/kyverno/` and
    `policies/kyverno/upstream/` over every file in `deploy/`
  - `scripts/ci/repo-policy.sh`: pins, repository invariants, `deploy/`
    matches its sources, kube-linter
  - the repository invariant `pod-hardening` (spec
    [per-app-hardening](../.kiro/specs/per-app-hardening/)): every container
    of a rendered pod template in `APP_NAMESPACES` of
    `scripts/ci/repo_policy.py` has readiness and liveness probes (when it is
    long-running), seccomp `RuntimeDefault`, `allowPrivilegeEscalation:
    false`, `capabilities.drop: [ALL]` and `runAsNonRoot: true`; outside the
    Kyverno-excluded namespaces, a Pod of the `default` ServiceAccount sets
    `automountServiceAccountToken: false` and no binding grants a `default`
    ServiceAccount. What is still missing is listed in
    `ci/pod-hardening-gaps.txt` with a reason that stays, and the issue when
    it can be fixed later; a new gap and a line that is no longer a gap
    both fail, so the file only shrinks. An Application under
    `clusters/homelab/apps/` whose namespace is not in `APP_NAMESPACES`
    fails too.
  - the repository invariant `container-args-unique`: no container of any
    rendered pod template, upstream Helm charts included, passes the same
    `--flag[=value]` twice. A chart that starts setting a flag our values
    also set fails here instead of crash-looping in the cluster (#1824).
    The kind boot cannot catch it: the upstream charts are not in `deploy/`,
    and node-exporter needs host paths and the host network.
  - the regression rules of `scripts/ci/repo_policy.py` (listed in its
    docstring): each one fails on a configuration bug that once reached
    `main` and names its pull request in the failure, with a fixture in
    `tests/test_repo_policy.py` that reproduces the bug.
- `tests`:
  - unit tests: `pytest tests` under coverage.py (render, repo policy,
    workflow entry points, pre-commit parity, the `ci` job list; see
    [Coverage](#coverage)) and `tests/run-bash-tests.sh`
    (`tests/bash/`, `tests/smoke/`: auto-rollback decisions, pins, merge
    script, PostSync hook script, Vector config check)
  - `scripts/ci/vector-validate.sh`: the Vector config. The chart is not
    rendered into `deploy/` and passes `customConfig` through Helm `tpl`, so
    the script runs `helm template` at the Application's chart version with
    its values, takes `vector.yaml` from the ConfigMap and runs
    `vector validate --no-environment` in the image the DaemonSet runs
    (`image.tag` and `image.sha` in `platform/vector/values.yaml`). A chart
    or image bump is checked with its own binary; an invalid config (a VRL
    error such as E103) fails, warnings do not. Locally, without Docker:
    `VECTOR_BIN=<vector of the same version> scripts/ci/vector-validate.sh`.
- `promtool`: `scripts/ci/promtool-check.sh`, `promtool check rules` on every
  rendered PrometheusRule and `promtool test rules` on
  `tests/prometheus/*_test.yaml`.
- `alertmanager`: `scripts/ci/alertmanager-test.sh`, the routing and
  inhibition tests ([observability](observability.md)).
- `security`: gitleaks on the new commits, the Trivy gate (CRITICAL on
  presence, HIGH on delta against the merge-base).
- `pr-metadata`: PR title and every commit subject (`scripts/ci/check-title.sh`),
  every commit verified.
- `site`: `scripts/ci/site-check.sh` builds the blog and checks links,
  markup, the site nav, image metadata and the `layout.css` copies;
  `scripts/ci/site-serve-check.sh` serves it with the real nginx config;
  `scripts/ci/layout-check.sh` compares the container and nav of the
  landing page, the blog, the dashboard and the tech radar in
  `chrome-headless-shell` at
  1920x1080 and 390x844 ([website.md](website.md#shared-layout)). Skipped
  when nothing under `site/`, `apps/website/` or `dashboard/internal/web/`
  changed.
- `dashboard`: `scripts/ci/dashboard-check.sh` on the Go module in
  `dashboard/` ([homelab-dashboard.md](homelab-dashboard.md)), skipped when
  nothing under it changed: `go mod verify` and `tidy -diff`, golangci-lint
  v2 with `dashboard/.golangci.yaml` (the Google Go Style Guide, formatting
  included), `go vet`, `govulncheck`, `go test -race` with the golden pages,
  `go build`, and the builder image's Go version against `go.mod`. Then
  `scripts/ci/dashboard-screenshots.sh` renders the golden pages in a
  pinned `chrome-headless-shell` with the CSP, fails on a CSP violation or a
  layout break and uploads the `dashboard-screenshots` artefact. CodeQL
  analyses the Go code too. A merge that touches `dashboard/` runs
  `.github/workflows/dashboard-publish.yaml`: smoke test, multi-arch build
  with SBOM and provenance, cosign signature, tag `main`.
- `jamulus`: `scripts/ci/jamulus-check.sh` builds the Jamulus image in
  `jamulus/` for `linux/amd64` and runs `scripts/ci/jamulus-smoke.sh` on
  it: the pinned version, then the server read-only, non-root and without
  capabilities must echo `jamulus-ping` within 20 s. Skipped when nothing
  under `jamulus/`, `scripts/ci/jamulus-*.sh` or `platform/jamulus-probe/`
  changed. A merge that touches `jamulus/` runs
  `.github/workflows/jamulus-publish.yaml`: the same smoke test, multi-arch
  build with SBOM and provenance, cosign signature, tag `main`.

Downloads and caches:

A cache key always contains the pins it holds, so a version bump misses.
Each key has one job that saves it, and only when the key was not an exact
hit; the other jobs restore. A restored file goes through the same check as
a downloaded one.

| What | Key | Saved by | Check on restore |
|---|---|---|---|
| Helm chart archives (`scripts/ci/chart_fetch.py`) | the Application files and `ci/helm-releases.yaml`; restores the newest older key and fetches what is missing | `render`, pruned to the pinned charts | sha256 recorded at fetch time, `Chart.yaml` name and version against the pin |
| kubeconform core schemas | `KUBE_SCHEMA_SHA`, `K8S_VERSION` and the rendered kinds | `render` | none, as before: the URL pins the commit |
| Tool archives (`scripts/ci/install-tool.sh`, `TOOL_CACHE`) | `tools-<job>-` and the `<TOOL>_VERSION` of every tool the job installs (`tests/test_ci_workflow.py` checks the list) | each job its own; `tests` restores `render`'s | the `<TOOL>_SHA256` pin; a mismatch is deleted and downloaded again |
| pip downloads (`~/.cache/pip`) | `ci/requirements-ci.txt` (`fuzz`: `ci/requirements-fuzz.txt`) | `render`; `lint` and `tests` restore | `--require-hashes` |
| tofu providers (`TF_PLUGIN_CACHE_DIR`) | `TOFU_VERSION` and the `bootstrap/**` lock files | `lint` | the lock file hashes; `bootstrap/` has no lock file, so its providers are downloaded |
| pre-commit environments | `.pre-commit-config.yaml`; a pull request that changes it starts from main's newest entry | `lint`, on pushes to `main` only, after `pre-commit gc` | none, as before: `rev:` pins each hook |

`chart_fetch.py` retries `helm pull` after 5, 15 and 45 s on a transient
error (HTTP 5xx or 429, timeout, reset, DNS); kubeconform retries schema
downloads twice itself; `install-tool.sh` lets curl retry six times with
exponential backoff; `tofu init` retries provider downloads six times
(`TF_PROVIDER_DOWNLOAD_RETRY`); pip retries five times by default.

Kyverno policies:

The policies are the upstream `kyverno/policies` Pod Security Standards
(baseline and restricted) and a subset of its best practices, vendored
unchanged in `policies/kyverno/upstream/` at the commit in its `SOURCE` (which
also lists what is left out and why), plus the homelab `require-probes`.
`scripts/kyverno-vendor.sh` re-vendors them; `--check` (run first by
`kyverno.sh`) fails when a file differs from its recorded sha256. Renovate
moves the commit and the `renovate-render` workflow re-vendors.

| Policy | CI |
|---|---|
| `disallow-latest-tag` | blocks |
| `disallow-privileged-containers` | blocks |
| `require-probes` | blocks |
| every other policy | reported in the step summary |

What blocks is the `BLOCKING` list in `scripts/ci/kyverno.sh`, by policy name;
the vendored files keep upstream's `validationActions`. An evaluation error
blocks too, except the CLI gaps listed in the script (fields the API server
defaults, such as a Service's `spec.type`). A policy joins `BLOCKING` once
`deploy/` passes it.

In the cluster, a policy moves from Audit to Deny once
`scripts/kyverno-deny-readiness.sh <policy>` prints `READY` (read-only, any
kubeconfig): K1, no `fail` of the policy in the PolicyReports on a workload
(a ReplicaSet only above 0 replicas) outside `EXCLUDED_NAMESPACES`; K2,
`KyvernoReportsStale` not firing and the newest result under 2 hours old.
An API or parse error, or an unknown policy, reads `NOT READY`. Test:
`tests/bash/test_kyverno_deny_readiness.sh`.

Pod Security: in a namespace that `infrastructure/namespaces/namespaces.yaml`
labels `pod-security.kubernetes.io/enforce: restricted`, a finding of the
restricted set (`policies/kyverno/upstream/pod-security-vpol/restricted/`)
blocks as well, because the API server would reject the Pod. The Kyverno
webhooks skip `EXCLUDED_NAMESPACES`, PSA does not: the Helm renders of a
namespace in both lists (today `argo` and `kyverno`) are kept, and for them
only the Pod Security Standards policies block. The log names both sets.
Test: `tests/bash/test_kyverno_restricted.sh`.

### Coverage

Statement coverage of the first-party code, printed in the job log and the
job summary:

| Component | Job | Measured by |
|---|---|---|
| `dashboard`, `techradar`, `drumcharts` | the job of the same name, when its change filter runs it | `go test -coverpkg=./... -coverprofile` in the check script; a package without tests counts as 0% |
| `python`: `scripts/`, `platform/`, `apps/` | `tests`, every run | pytest under coverage.py ([`.coveragerc`](../.coveragerc)), child Python processes included (a test that replaces the environment passes its `COVERAGE_*` variables on); a file no test runs counts as 0% |

`scripts/ci/coverage-report.sh` turns a Go profile or the coverage.py JSON
into covered and total statements and fails the job when the figure is
below the component's floor in `ci/coverage-floors.txt`. A component gets
the floor 80 once it measures 80.0% or more; below that its figure is only
reported.

Measured on 2026-11-27:

| Component | Coverage | Statements | Floor |
|---|---|---|---|
| `dashboard` | 83.5% | 1864/2232 | 80 |
| `techradar` | 76.0% | 222/292 | none |
| `drumcharts` | 86.9% | 293/337 | 80 |
| `python` | 83.0% | 4795/5780 | 80 |
| combined | 83.0% | 7174/8641 | |

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
- A coverage floor only where a component already measures 80%: it stops
  a regression without tests written to move a number. No badge, which
  would need a hosted endpoint; the job summary carries the figure.

Rejected: a self-hosted runner in the cluster, because it would run code from
pull requests next to production.
