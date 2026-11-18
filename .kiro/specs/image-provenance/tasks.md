# Tasks: image-provenance

One PR per task, in order. No task writes to the cluster outside Argo CD;
the live checks are read-only. The defaults are in
[requirements.md](requirements.md#decided-defaults).

- [x] 1. Inventory, read-only: `scripts/ci/image_provenance.py`,
      `ci/image-signers.yaml` seeded from its first run (an entry for every
      repository, `ghcr.io/ned-si/homelab-site` as `unsigned: signed from
      task 2`), the cosign pin in the `ci.yaml` env and
      `scripts/ci/install-tool.sh`, the workflow
      `.github/workflows/image-provenance.yaml`,
      `tests/test_image_provenance.py`. Check: the workflow run on the PR
      lists every image of the running image set with a status and exits 0;
      a fixture with a `mismatch` exits 1. [1.1-1.6] (#1515)
- [ ] 2. Own image signed and verified in Audit: `site-publish` signs the
      index digest keyless with SBOM and provenance attestations and
      verifies it; `infrastructure/kyverno-policies/verify-own-images.yaml`
      in that kustomization; `ImageValidatingPolicy` in the
      `clusterResourceWhitelist` of
      `clusters/homelab/bootstrap/project-infrastructure.yaml`;
      `scripts/ci/gen-crd-schemas.sh` extended and
      `ci/schemas/policies.kyverno.io_imagevalidatingpolicy_v1.json`
      committed; the signer-list entry for `ghcr.io/ned-si/homelab-site`
      with its identity; the test in `tests/test_security_controls.py`;
      `task render`. `site-publish` builds with a `docker-container`
      builder, pushes only `:$SHA`, signs and verifies before tagging
      `:main` and before the GHCR logout. Check: after the `site-publish`
      run and Renovate's digest PR, the policy is Ready, the `website`
      policy report shows `pass` and no `fail` for `verify-own-images`,
      and no other namespace has a `fail` or `error` for it. [2.1-2.5]
- [ ] 3. CI gate on own images: `scripts/ci/image_provenance.py
      --gate-own` in the `security` job (changed own digests against the
      PR base only, reverts and `auto-revert/*` skipped), its cases in
      `tests/test_image_provenance.py`. Check: a throwaway commit pointing
      `deploy/` at an unsigned digest fails `ci`; the clean tree passes.
      [3.1-3.3]
- [ ] 4. Repo-policy rule `image-signers` and its tests. Check: a fixture
      repository without an entry fails the rule. [4.1-4.2]
- [ ] 5. Upstream signatures in Audit:
      `infrastructure/kyverno-policies/verify-upstream-images.yaml` from
      the signer-list identities (globs `<repo>:*` and `<repo>@*`), its
      agreement test both ways. Check: Ready; every `fail` in its reports
      fixed or an issue; no result outside the listed repositories.
      [5.1-5.3]
- [ ] 6. Docs: `docs/threat-model.md`, `docs/architecture.md`,
      `docs/testing.md`. Check: links resolve; the threat model's
      supply-chain residual matches the controls. [6.1]

Not tasks here: Enforce per namespace (#1506) and the weekly SBOM CVE scan
(#1507) ([design](design.md#follow-ups)).

The last task ticked sets `status: done`, `closed:`, and closes #725.
