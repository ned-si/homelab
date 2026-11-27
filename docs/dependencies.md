# Dependencies and updates

Every dependency is declared in a file in this repository and pinned to an
exact version, a digest or a hash. Renovate moves the pins; CI decides
whether the update merges. No library is vendored: what is copied in
(Kyverno and Tetragon policies, CRD schemas) is pinned to its upstream
commit or release and re-fetched, never edited.

## Where each dependency is declared

| Kind | Declared in | Pinned by | Updated by |
| --- | --- | --- | --- |
| Go modules | `dashboard/go.mod`, `techradar/go.mod`, `drumcharts/go.mod` and their `go.sum` | version and checksum | Renovate (`gomod`, tidied) |
| Go toolchain and builder image | the `go` line of each `go.mod`, `dashboard/Dockerfile` | version, image digest | Renovate, one pull request for both |
| CI Python packages | `ci/requirements-ci.txt`, `ci/requirements-fuzz.txt` | version and sha256 (`--require-hashes`) | Renovate (`pip_requirements`) |
| Helm charts | `clusters/homelab/<layer>/<app>.yaml`; `ci/helm-releases.yaml` for the bootstrap releases | chart version | Renovate (annotated `targetRevision`) |
| Container images | the manifests and Helm values, as `repo:tag@sha256:<digest>` | index digest (`repo-policy` rule `image-digest`) | Renovate (tag and digest together) |
| GitHub Actions | `.github/workflows/*.yaml` | commit SHA, enforced by the repository setting | Renovate (`github-actions`) |
| CI tools | `env:` of the workflows, installed by `scripts/ci/install-tool.sh` | version and sha256 | Renovate (`# renovate:` annotations) |
| pre-commit hooks | `.pre-commit-config.yaml` | `rev` | Renovate, one pull request on Mondays |
| Talos and Kubernetes | `talos/talconfig.yaml`, `platform/tuppr/upgrades/` | version | Renovate, one minor per pull request |
| OpenTofu providers | `bootstrap/*/` | version and `.terraform.lock.hcl` | Renovate (`terraform`) |
| Vendored policies | `policies/kyverno/upstream/SOURCE`, `platform/tetragon/policies/SOURCE` | upstream commit | Renovate, re-vendored by `renovate-render` |
| CRD schemas for kubeconform | `ci/schemas/`, sources in `ci/schemas/SOURCES.txt` | sha256 per source | by hand, `scripts/ci/gen-crd-schemas.sh` |

The configuration of Renovate is `.github/renovate.json5`; every pin it
tracks carries a `# renovate:` comment that names its datasource.

## How updates merge

- Every update automerges on a green `ci`, at any time
  ([decisions.md](decisions.md#no-human-gates)). The `renovate-next` train
  (`scripts/ci/renovate-next.sh`) rebases one pull request after each merge,
  so CI runs on the one that merges next.
- `automerge-weekdays`: Cilium and the Gateway API CRDs open 3 days after
  their release and merge Monday to Friday, 09:00 to 16:59 Zurich; the
  operators that build Pods in code (tuppr, CloudNativePG and its Barman
  Cloud plugin) merge in the same window.
- `no-automerge`: majors of data stores (PostgreSQL, ClickHouse, ZooKeeper,
  Valkey, Redis, MariaDB, MySQL) open a pull request that a person merges,
  because a store that ran on a new major cannot be rolled back.
- Never by Renovate: the Immich database image, and the versions listed in
  [roadmap.md](roadmap.md#versions-renovate-cannot-move-alone), each with its
  runbook.
- A merge that degrades its Application is reverted automatically
  ([decisions.md](decisions.md#automatic-rollback)).

## Finding vulnerable dependencies

| Check | Covers | Runs |
| --- | --- | --- |
| GitHub vulnerability alerts | the manifests GitHub parses (`go.mod`, requirements files, Actions) | continuously, on GitHub |
| `govulncheck` | the Go modules and the standard library, reachable code only | the `dashboard`, `techradar` and `drumcharts` jobs of `ci` |
| Trivy config scan | the configuration files (manifests, Dockerfiles, OpenTofu); CRITICAL fails, a HIGH count above the merge base fails | the `security` job of `ci` |
| CodeQL | Go, Python and the workflows | workflow `codeql` |
| trivy-operator | every running image, fixable MEDIUM and above, rescanned every 24 h | in the cluster ([observability.md](observability.md#vulnerability-priority)) |

A publicly known vulnerability of medium or higher severity in a
dependency is fixed within 60 days of becoming public: by the Renovate
update when one exists, otherwise by hand or by removing the dependency.

## Deprecated interfaces

Kyverno's `check-deprecated-apis` runs in the `render` job of `ci` and
reports every manifest that uses a deprecated Kubernetes API or one removed
in a coming release (Audit: reported with counts, the job does not fail on
it). Known use of a deprecated interface: the TrueNAS REST API
v2.0, called by democratic-csi and the NAS exporters (#1490).

## Upgrading

There are no releases and no supported versions other than `main`, which
is what the cluster runs; an upgrade is a merge. Upgrades that need steps
beyond the merge have a runbook: Talos and Kubernetes in
[talos.md](talos.md#upgrades), the Immich database in
[runbooks/immich-upgrade.md](runbooks/immich-upgrade.md).

## Why it is like this

- Pins everywhere, moved by a bot: an exact pin makes every change a
  reviewable diff and lets CI test the exact bytes that deploy. Rejected:
  version ranges and floating tags, which change what runs without a commit.
- Automerge on CI rather than an approval queue: one operator, and an
  update that waits for a person ages
  ([decisions.md](decisions.md#no-human-gates)).
