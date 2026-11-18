---
kind: change
status: active
created: 2026-11-18
issue: 725
---
# Requirements: image-provenance

## Introduction

Every image in the cluster is pinned by digest, but nothing checks who built
it. A digest proves the bytes did not change since Renovate saw them; it
does not prove the publisher pushed them. The threat model lists this as a
residual of the supply chain path
([threat-model.md](../../../docs/threat-model.md#supply-chain-renovate-and-github-actions-to-main)).

This spec adds image provenance in the order that costs least and breaks
nothing: first an inventory of which running images carry a cosign
signature, then signing our own image (`ghcr.io/ned-si/homelab-site`) and
verifying it in Kyverno in Audit, then CI blocking an unsigned own image,
then Audit verification for the upstream publishers that sign. Enforce comes
later, per namespace, in #1506. It covers #725 (roadmap security
S5).

## Glossary

- **Own image**: an image under `ghcr.io/ned-si/`. Today only
  `ghcr.io/ned-si/homelab-site`, built by `.github/workflows/site-publish.yaml`.
- **Running image set**: every string value under an `image` or `imageName`
  key, at any depth, in `deploy/` and in the Helm renders of
  `scripts/ci/render_apps.py`. That covers Pod templates, CNPG `imageName`
  and images set on other custom resources (`Prometheus`, `Alertmanager`,
  `ClickHouseInstallation`, `ProxyClass`).
- **Signer list**: `ci/image-signers.yaml`, one entry per image repository:
  either the keyless identity that signs it (OIDC issuer and certificate
  subject) or `unsigned:` with a reason. Repositories are in
  `repo_policy.parse_image` form (Docker Hub names without `docker.io/` and
  `library/`).
- **Keyless signature**: a cosign signature with a Fulcio certificate and a
  Rekor entry, verifiable against an issuer and subject.
- **Inventory**: the report of `scripts/ci/image_provenance.py` over the
  running image set.

## Decided defaults

| Question | Default | Why |
| --- | --- | --- |
| Signature scheme | cosign keyless (Sigstore public Fulcio and Rekor), GitHub Actions OIDC | No key to store or rotate; the identity is the workflow path on `main`; what most upstreams publish |
| Kyverno object | `ImageValidatingPolicy` (`policies.kyverno.io/v1`), not a `ClusterPolicy` `verifyImages` rule | The cluster runs only the CEL policy types; the CRD is installed with Kyverno 1.20 |
| Mode | Audit, `failurePolicy: Ignore`, no digest mutation | Kyverno never blocks a Pod; images are already pinned by digest, so mutation only adds Argo CD diffs |
| Own-image identity | issuer `https://token.actions.githubusercontent.com`, subject `https://github.com/ned-si/homelab/.github/workflows/site-publish.yaml@refs/heads/main` | Only that workflow on `main` can produce a valid signature |
| SBOM and provenance | BuildKit attestations (`--sbom=true --provenance=mode=max`) in the signed image index; the inventory records whether an image has attestations | Free at build time; the signature over the index covers them; no extra tool |
| Inventory scope | the rendered manifests (`deploy/` plus the Helm renders), not the Helm values | What the cluster runs, chart default images included |
| Inventory job | a separate workflow `image-provenance`, weekly, on demand and on pull requests that change the script, the signer list or the workflow; read-only | It calls registries for about 80 images; not on every `ci` run |
| CI gate | only own images block, in the required `ci` check | We control their signing; upstream signing is not ours to gate on |
| Enforce | deferred to an issue, per namespace | Needs weeks of clean Audit reports first |

## Requirements

### Requirement 1: Know which running images are signed

**User story:** As the operator, I want a list of every running image with
its signature status, so I know which publishers I can verify.

#### Acceptance criteria

1. THE inventory SHALL list every unique image reference in the running
   image set with its repository, digest, the objects that use it, and one
   status: `verified`, `mismatch`, `signed-unlisted`, `unsigned-listed`,
   `unsigned` or `error` (registry calls failed after the retries).
   (`tests/test_image_provenance.py`)
2. WHEN an image has a keyless signature, THE inventory SHALL report the
   signer's issuer and subject. (`tests/test_image_provenance.py`, fake cosign)
3. THE inventory SHALL report whether each image has attestations (SBOM or
   provenance). (`tests/test_image_provenance.py`)
4. WHEN any image has status `mismatch` or `error`, THE inventory SHALL
   exit 1; a schema or parse error SHALL exit 2; otherwise it SHALL exit 0.
   (`tests/test_image_provenance.py`)
5. THE workflow `image-provenance` SHALL run weekly, on `workflow_dispatch`
   and on pull requests that change the script, the signer list or the
   workflow, with `contents: read` only, and SHALL write the inventory to
   the step summary and a JSON artefact. (`tests/test_ci_workflow.py`,
   actionlint)
6. THE signer list SHALL give every `unsigned` repository a reason.
   (`tests/test_image_provenance.py`)

### Requirement 2: Our own image is signed and verified in the cluster

**User story:** As the operator, I want the site image signed by its
workflow and checked by Kyverno, so a re-pushed or foreign image shows up.

#### Acceptance criteria

1. WHEN `site-publish` pushes `ghcr.io/ned-si/homelab-site`, IT SHALL sign
   the pushed index digest keyless and attach BuildKit SBOM and provenance
   attestations; `cosign verify` with the own-image identity SHALL pass.
   (the workflow's verify step)
2. THE `ImageValidatingPolicy` `verify-own-images` SHALL match images
   `ghcr.io/ned-si/*` in Pods, run in Audit with `failurePolicy: Ignore`,
   and accept only the own-image identity.
   (`tests/test_security_controls.py`)
3. WHEN the policy is synced, ITS Ready condition SHALL be true.
   (recorded check: `kubectl get imagevalidatingpolicy verify-own-images`)
4. WHEN the `website` Pod runs a signed digest, THE policy report in
   namespace `website` SHALL show `pass` and no `fail` or `error` for
   `verify-own-images`. (recorded check: `kubectl get policyreport -n website`)
5. THE PolicyReports of every namespace other than `website` SHALL show no
   `fail` or `error` for `verify-own-images`. (recorded check:
   `kubectl get policyreports -A -o json | jq` over
   `.results[] | select(.policy=="verify-own-images")`)

### Requirement 3: CI blocks an unsigned own image

**User story:** As the operator, I want a pull request that deploys an own
image without a valid signature to fail, so it never reaches `main`.

#### Acceptance criteria

1. WHEN a pull request changes the digest of a `ghcr.io/ned-si/*` image in
   `deploy/` (against the PR base) AND that digest does not verify against
   its signer-list identity, THE `ci` check SHALL fail and name the image.
   (`tests/test_image_provenance.py`, fake cosign)
2. WHEN every changed own digest verifies, THE step SHALL pass and list
   each verified digest in the step summary.
3. WHEN the PR title starts with `Revert` OR the head branch is
   `auto-revert/*`, THE step SHALL skip verification, so an automatic
   rollback never depends on Sigstore or GHCR.
   (`tests/test_image_provenance.py`)

### Requirement 4: No image without a signer-list entry

**User story:** As the operator, I want a new image repository to come with
its signing status, so the list stays complete without a weekly chore.

#### Acceptance criteria

1. WHEN a repository in `deploy/` or the Helm renders has no signer-list
   entry, THE repo-policy rule `image-signers` SHALL fail and name it.
   (`tests/test_repo_policy.py`)
2. THE rule SHALL run offline. (no network call in the rule)

### Requirement 5: Upstream signatures checked in Audit

**User story:** As the operator, I want the upstream images that publish
keyless signatures verified like ours, in Audit, so I see a broken or
missing signature before I enforce.

#### Acceptance criteria

1. THE `ImageValidatingPolicy` `verify-upstream-images` SHALL have one
   attestor per signer-list entry with an identity outside `ghcr.io/ned-si/`,
   in Audit with `failurePolicy: Ignore`. (`tests/test_security_controls.py`
   checks the policy and the list agree)
2. WHEN the policy is synced, ITS Ready condition SHALL be true, and every
   `fail` in its reports SHALL be either fixed in the signer list or have an
   issue. (recorded check)
3. THE PolicyReports SHALL show no `verify-upstream-images` result for an
   image outside the listed repositories. (recorded check, as 2.5)

### Requirement 6: Docs match

#### Acceptance criteria

1. `docs/threat-model.md` (supply chain), `docs/architecture.md`
   (admission policy) and `docs/testing.md` SHALL describe the inventory,
   the two policies, the CI gate and the signer list as they are.
   (review; links resolve)

## Out of scope

- Enforce for any namespace: #1506 (`deferred`), after four weeks of Audit
  reports without `fail`.
- The weekly CycloneDX SBOM of the running image set with a CVE scan to code
  scanning and ntfy (the second half of #725's body): #1507, because it is a
  scan pipeline, not a signature check.
- Verifying attestation contents (SLSA level, SBOM policy) in Kyverno.
- Key-based (non-keyless) upstream signatures: listed by the inventory as
  `unsigned` with the reason "key-based signature", not verified.
- Images not in the rendered manifests (Talos system images, Helm hook
  images not rendered, images an operator picks without a field in a
  manifest).
- Signing Helm charts or verifying chart provenance.
