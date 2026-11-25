# Design: image-provenance

## Overview

Three pieces share one data file. `ci/image-signers.yaml` says, per image
repository, who signs it or why it is unsigned. `scripts/ci/image_provenance.py`
reads the running image set and the signer list and asks cosign about each
image; the weekly workflow `image-provenance` publishes that inventory.
Kyverno `ImageValidatingPolicy` objects verify the listed identities in the
cluster, in Audit. The required `ci` check verifies only our own image and
blocks on failure; a repo-policy rule keeps the signer list complete
offline. Our own image starts being signed in task 2, in `site-publish`.

Stack, locked: Python 3 with PyYAML (as `scripts/ci/repo_policy.py`),
cosign (one pinned binary, `COSIGN_VERSION`/`COSIGN_SHA256` in the
`ci.yaml` env, installed by `scripts/ci/install-tool.sh`, read by the other
workflows the way `site-publish` reads the Hugo pin), Kyverno 1.20
`ImageValidatingPolicy` `policies.kyverno.io/v1` (CRD present in the
cluster), Docker BuildKit attestations, GitHub Actions OIDC.

## The signer list

`ci/image-signers.yaml`, a list sorted by `repository`:

```yaml
# Who signs each image repository the cluster runs
# (.kiro/specs/image-provenance/design.md#the-signer-list).
- repository: ghcr.io/ned-si/homelab-site
  issuer: https://token.actions.githubusercontent.com
  subject: https://github.com/ned-si/homelab/.github/workflows/site-publish.yaml@refs/heads/main
- repository: quay.io/keycloak/keycloak
  unsigned: no signature published (inventory 2026-11-18)
```

`repository` values are in `repo_policy.parse_image` form: Docker Hub
names without `docker.io/`, `index.docker.io/` and `library/` (`nginx`,
`grafana/grafana`), every other registry as written.

Validation, done by the script on load (exit 2, message naming the entry):
`repository` required, a string without tag or digest, in `parse_image`
form, unique; exactly one
of `subject` or `unsigned`; `subject` requires `issuer`; `issuer` is an
`https://` URL; `subjectRegExp` may replace `subject` for publishers that
sign from several workflows or tags (for example
`^https://github.com/cilium/cilium/\.github/workflows/.+@refs/tags/v.+$`),
and is compiled with Python `re` to reject a broken expression; `unsigned`
is a non-empty string. Unknown keys fail. The file is the single source for
the inventory, the CI gate (task 3), the completeness rule (task 4) and the
upstream policy (task 5).

## Inventory (task 1)

`scripts/ci/image_provenance.py [--deploy deploy] [--render DIR]
[--signers ci/image-signers.yaml] [--json FILE] [--offline]`.

Collection: every `*.yaml` under `--deploy`, and every `manifests.yaml`
under `--render` (the `render_apps.py` layout), parsed with
`yaml.safe_load_all`. Image references are every string value under a key
`image` or `imageName`, found by walking each document recursively. That
covers Pod templates of every workload kind, CNPG `Cluster.spec.imageName`
and images on other custom resources (`Prometheus`/`Alertmanager`
`spec.image`, `ClickHouseInstallation` pod templates, `ProxyClass`), which
Kyverno also sees in the Pods those operators create. Each reference is
split with `repo_policy.parse_image` (imported, so both agree on what a
repository is). References are deduplicated by `repository@digest`; each
keeps the list of `namespace/kind/name` that use it. A reference without a
digest is reported with status `unsigned` and note `no digest`; one that
`parse_image` rejects (no tag, `repo@sha256:...`) gets status `unsigned`
and note `no tag`, keyed by the reference as written. Repo-policy
`image-digest` already fails both in CI. An unparsable document fails the
run (exit 2): the render is broken and the inventory would be incomplete.

Checks per unique image, read-only subcommands only (`cosign tree`,
`cosign verify`, `docker buildx imagetools inspect --raw`). Each call has a
60 s subprocess timeout and up to 3 attempts, backing off 10 s, 30 s and
60 s, on a non-zero exit whose stderr names a network or registry error
(`timeout`, `connection reset`, `429`, `5xx`). The order keeps the registry
calls to about one per image, so anonymous Docker Hub limits are not hit:

1. `cosign tree <ref>`, once. Its output gives the signature check and the
   attestation column (`yes` when it lists an attestation or SBOM).
2. No signature in the tree: `unsigned-listed` when the list has an
   `unsigned:` entry, `mismatch` when the list names an identity, else
   `unsigned`. No further call.
3. A signature and a listed identity: `cosign verify
   --certificate-oidc-issuer <issuer> --certificate-identity[-regexp]
   <subject> <ref>`. Pass: `verified`; fail: `mismatch`.
4. A signature and no listed identity: `cosign verify
   --certificate-identity-regexp '.*' --certificate-oidc-issuer-regexp '.*'
   --output json <ref>`. A pass reads the first certificate's issuer and
   subject and gives `signed-unlisted` (the line suggests a signer-list
   entry). A failure means a key-based or otherwise unverifiable signature:
   `signed-unlisted` with subject `key-based`.
5. `ghcr.io/ned-si/*` only, where BuildKit puts attestations in the image
   index: `docker buildx imagetools inspect --raw` when Docker is present,
   counting a manifest with annotation `vnd.docker.reference.type:
   attestation-manifest`.

Retries exhausted on a network error: status `error` for that image, the run
continues. Exit codes as requirement 1.4: 1 for any `mismatch` or `error`,
2 for a schema or parse error, else 0. The step summary records the number
of registry calls made, so the budget stays visible. `--offline` skips steps 1 to 3 and lists
images with their signer-list entry only (used by tests and for a quick
local look). Output: a Markdown table to stdout (repository, digest short,
status, signer, attestations, used by) sorted by status then repository,
plus counts per status; `--json` writes the same rows. Logging: one stderr
line per retry; cosign stderr is kept only for `mismatch` and `error` rows,
truncated to 300 characters.

Workflow `.github/workflows/image-provenance.yaml`: triggers `schedule`
(Mondays 05:17 UTC), `workflow_dispatch`, `pull_request` on paths
`scripts/ci/image_provenance.py`, `ci/image-signers.yaml`,
`.github/workflows/image-provenance.yaml`. `permissions: {}` at the top,
`contents: read` on the job, `timeout-minutes: 30`,
`persist-credentials: false`. Steps: install
`helm` and `cosign` through `install-tool.sh` with the pins read from
`ci.yaml`; `setup-python-deps.sh`; restore the chart
cache (restore only, as the `tests` job); `render_apps.py --out
$RUNNER_TEMP/render`; the inventory with `--render`; the table to
`GITHUB_STEP_SUMMARY`; the JSON as artefact `image-provenance` (14 days).
On a scheduled run that fails, the ntfy step copied from `site-publish`
(priority low, quiet-hours delay): a `mismatch` is something to look at,
not a page. Not a required check; it never writes to the repository.

Seeding: task 1 runs the inventory once and commits a signer list with an
entry for every repository: identities for `signed-unlisted` rows,
`unsigned:` with the reason and date for the rest.
`ghcr.io/ned-si/homelab-site` starts as `unsigned: signed from task 2`, so
the first runs do not fail.

## Signing the site image (task 2)

`site-publish` gains `id-token: write` on the `publish` job. BuildKit
attestations need a builder that supports them (the default `docker`
driver with the classic image store rejects `--sbom`/`--provenance`), so
the job creates one: `docker buildx create --name attest --driver
docker-container --use` before the build. The smoke test keeps the default
builder (`docker buildx build --builder default --load ...`), because a
`docker-container` builder does not load into the local image store.

Step order, all before "Log out of GHCR" (`cosign sign` pushes the `.sig`
tag with the docker login credentials):

1. `docker buildx build --builder attest ... --sbom=true
   --provenance=mode=max --push -t "$IMAGE:$SHA"`: only the commit tag is
   pushed; it is an image index with the arm64 manifest and its
   attestation manifest.
2. The existing arm64 check, on the index digest (it pulls with
   `--platform linux/arm64`, so it keeps working).
3. Install cosign (pin from `ci.yaml`), `cosign sign --yes
   "$IMAGE@$digest"` on the index digest, then `cosign verify` with the
   own-image identity.
4. `docker buildx imagetools create -t "$IMAGE:main" "$IMAGE@$digest"`.
5. Log out of GHCR.

Renovate follows `:main`, so it never sees an unsigned digest. A failed
sign or verify fails the job before step 4, which sends the existing ntfy
message; recovery is re-running the workflow.

Signature format: cosign's classic signature tag (`sha256-<digest>.sig`)
with the Rekor bundle, because every verifier in play (Kyverno's cosign
verifier, `cosign verify`, the inventory) reads it. With cosign 3.x that is
`--new-bundle-format=false --use-signing-config=false` on `sign`. If the
Kyverno report shows `error` for a signature the CLI verifies, the format is
the first suspect; switching formats is a change to this section.

From homelab-dashboard task 20, `site-publish` also pushes a signed SLSA
v1 provenance made by `actions/attest-build-provenance` (a Sigstore bundle
as an OCI referrer), as `dashboard-publish` already did. The inventory's
attestation column already reads `yes` from BuildKit's attestation
manifest and does not tell the two apart; Kyverno's `verify-own-images`
verifies the signed one in the cluster
([homelab-dashboard design, Provenance](../homelab-dashboard/design.md#provenance-task-20)).

## The own-image policy (task 2)

`infrastructure/kyverno-policies/verify-own-images.yaml`, listed in that
kustomization's `resources`. It stays out of `policies/kyverno/`, because
`scripts/ci/kyverno.sh` runs everything there offline with the CLI, and
image verification needs the network.

```yaml
apiVersion: policies.kyverno.io/v1
kind: ImageValidatingPolicy
metadata:
  name: verify-own-images
spec:
  validationActions: [Audit]
  failurePolicy: Ignore
  webhookConfiguration:
    timeoutSeconds: 10
  evaluation:
    background:
      enabled: true
  validationConfigurations:
    mutateDigest: false
    verifyDigest: false
    required: false
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: [v1]
        operations: [CREATE, UPDATE]
        resources: [pods]
  matchImageReferences:
    - glob: "ghcr.io/ned-si/*"
  attestors:
    - name: homelab
      cosign:
        keyless:
          identities:
            - issuer: https://token.actions.githubusercontent.com
              subject: https://github.com/ned-si/homelab/.github/workflows/site-publish.yaml@refs/heads/main
        ctlog:
          url: https://rekor.sigstore.dev
  validations:
    - expression: >-
        images.containers.map(image, verifyImageSignatures(image, [attestors.homelab])).all(e, e > 0)
      message: ghcr.io/ned-si images must be signed by site-publish on main.
```

Pods only: reports land on the Pod, and the background scan (reports
controller, hourly) re-checks running Pods without a new admission. The
timeout is 10 s instead of the 3 s of the ValidatingPolicies because
verification fetches from GHCR and Sigstore; with `failurePolicy: Ignore`
and Kyverno's fail-open webhooks a slow answer admits the Pod and the
background scan reports later. Egress: the `kyverno` namespace has no
egress default-deny (`infrastructure/network-policies/90-enforcement.yaml`),
so no network policy change. The field names above are those of the
Kyverno 1.20 CRD; the implementer checks them with `kubectl apply
--dry-run=server` before the PR, and `kubeconform` checks them in CI against
the vendored schema.

Two files outside the policy make it deployable:

- `ci/schemas/` has no ImageValidatingPolicy schema and
  `scripts/ci/kubeconform.sh` runs without `-ignore-missing-schemas`.
  `scripts/ci/gen-crd-schemas.sh` adds `imagevalidatingpolicies` to its
  `policies.kyverno.io` loop (same pinned Kyverno release as the other
  kinds), and the PR commits
  `ci/schemas/policies.kyverno.io_imagevalidatingpolicy_v1.json` and any
  other served versions the script emits.
- `ImageValidatingPolicy` is cluster-scoped, and the infrastructure
  AppProject allows only `ValidatingPolicy` and `DeletingPolicy` from
  `policies.kyverno.io`. `clusters/homelab/bootstrap/project-infrastructure.yaml`
  gains, in `clusterResourceWhitelist`:

  ```yaml
      - group: policies.kyverno.io
        kind: ImageValidatingPolicy # kyverno-policies/verify-*-images.yaml, Audit only
  ```

  Without it Argo CD refuses the sync ("resource not permitted in
  project"); repo-policy `appproject-kinds` catches the omission in CI.

`tests/test_security_controls.py` gains a test that the file is in the
kustomization, is `Audit` with `Ignore`, has `mutateDigest: false`, matches
only `ghcr.io/ned-si/*`, and that its identity equals the signer-list entry
for `ghcr.io/ned-si/homelab-site`. A `kyverno test` case would need the
network, so there is none.

Rollout order inside task 2: the PR changes `site-publish`, the policy, the
AppProject, the schema and the signer-list entry together. On merge,
`site-publish` runs (its own file changed) and pushes a signed `:main`;
Renovate opens the digest pull request; once it merges, the `website` Pod
runs the signed digest. Until then the report shows `fail` for the old,
unsigned digest, which Audit tolerates. Verification: Ready condition true,
the `website` report shows `pass`, and no other namespace has a `fail` or
`error` for `verify-own-images` (requirement 2.5; the Security dashboard
and `scripts/kyverno-deny-readiness.sh` sum results across namespaces).
Whether Kyverno 1.20 skips Pods with no image matching
`matchImageReferences` is unverified; if it reports them, the policy gains
a `matchConditions` entry that limits it to Pods with a `ghcr.io/ned-si/`
image. Kyverno admission and reports controller memory is watched against
the 384Mi/256Mi limits in the same check.

## CI gate on own images (task 3)

A mode of the inventory script, so it shares the signer-list loader and
needs no extra tool: `scripts/ci/image_provenance.py --gate-own --deploy
deploy --base <PR base sha> [--pr-title T] [--head-ref R]`, in the
`security` job of `ci.yaml` after the Trivy steps, with PyYAML from
`setup-python-deps.sh` and cosign added to that job's `install-tool.sh`
call and cache key.

- It skips with a summary line when the PR title starts with `Revert` or
  the head branch is `auto-revert/*` (the inputs repo-policy already gets
  for `image-variant`): an automatic rollback never waits on Sigstore or
  GHCR, nor fails on a pre-signing digest.
- Otherwise it collects `ghcr.io/ned-si/*` references in `deploy/` at the
  head and at `--base` (read with `git show`), and verifies only the
  digests that are new at the head, with `cosign verify` and the
  signer-list identity (the same retry and back-off as the inventory).
- Fails: no digest, no signer-list entry with an identity, a failed verify
  after the attempts; each failure prints the image and cosign's first
  error line. Passes with nothing to verify.

`COSIGN_BIN` lets `tests/test_image_provenance.py` use a fake cosign for
the gate cases (changed digest verifies, changed digest fails, unchanged
digest skipped, revert skipped). A transient Sigstore outage fails `ci` on
a digest PR; the run conventions allow one `gh run rerun --failed`.

## Signer-list completeness (task 4)

Repo-policy rule `image-signers` in `scripts/ci/repo_policy.py`: the
repositories of the running image set (deploy/ and the render directory the
script already receives) minus the signer-list repositories must be empty;
each missing one fails with its file. It reads files only. A Renovate digest
or tag bump keeps the repository, so automerge is unaffected; a new image
needs one line. Unit tests in `tests/test_repo_policy.py`.

## Upstream policy (task 5)

`infrastructure/kyverno-policies/verify-upstream-images.yaml`, same shape
as the own-image policy, with one attestor per signer-list entry with an
identity outside `ghcr.io/ned-si/`. Each entry gets two
`matchImageReferences` globs, built from the reference as written in
`deploy/` (so `nginx` becomes `docker.io/library/nginx` if that is how the
manifest spells it): `<repo>:*` and `<repo>@*`. A bare `<repo>*` would also
match `<repo>-exporter`. Each attestor gets one validation that filters
the images of its repository:

```yaml
- expression: >-
    images.containers.filter(i, i.startsWith('quay.io/cilium/cilium:') || i.startsWith('quay.io/cilium/cilium@'))
      .map(i, verifyImageSignatures(i, [attestors.cilium])).all(e, e > 0)
```

Written by hand; `tests/test_security_controls.py` checks agreement both
ways: the identities equal the signer list, every `deploy/` reference of a
listed repository matches one of its entry's globs, and no reference of
another repository matches any glob. Requirement 5.3 is checked in the
reports the same way as 2.5. Which publishers enter is
the task 1 inventory's `signed-unlisted` rows; the policy starts with the
ones that verify keyless. Verification: Ready true; each `fail` in the
reports is either a signer-list fix in the same PR or an issue.

## Docs (task 6)

`docs/threat-model.md` supply-chain control and residual, the control table
row; `docs/architecture.md` admission section (the two image policies, why
outside `policies/kyverno`); `docs/testing.md` (the `image-provenance`
workflow, the `security` step, the `image-signers` rule); the
`gitops-delivery` area spec's image-pinning criterion, if it changes.

## Error handling summary

| Operation | Failure | Recoverable | Result | Logged |
| --- | --- | --- | --- | --- |
| Load signer list | schema error | fix the file | exit 2, entry named | stderr |
| Parse manifests | YAML error | fix the render | exit 2, file named | stderr |
| cosign call | network, 429, 5xx | retried 3 times | row `error`, exit 1 at end | stderr per retry |
| cosign verify (listed) | identity mismatch | fix signing or list | row `mismatch`, exit 1 | row note |
| site-publish sign/verify | Sigstore down | re-run workflow | job fails, ntfy low | job log |
| Kyverno verification | timeout | background scan | Pod admitted, report later | Kyverno log |
| CI gate | unsigned own image | sign it | `ci` fails | step log |

## Testing

- Unit: `tests/test_image_provenance.py` with fixture manifests and a fake
  `cosign` on `PATH` (statuses, retries, exit codes, signer-list
  validation, `--offline`, the `--gate-own` cases);
  `tests/test_repo_policy.py` for `image-signers`;
  `tests/test_security_controls.py` for both policies.
- Integration: the `image-provenance` workflow run on the task 1 PR; the
  `site-publish` run after task 2; the live checks (Ready, policy reports)
  read-only with `kubectl`.

## Follow-ups

- #1506: enforce the image policies per namespace, `deferred` until four
  weeks of Audit reports without `fail`; `website` first.
- #1507: the weekly SBOM of the running image set and its CVE scan, from
  #725's body.
