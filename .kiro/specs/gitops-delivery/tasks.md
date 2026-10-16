# Tasks: gitops-delivery

Requirement numbers in brackets. New work in this area adds a task here first.

## Done

- [x] 1. Root tracks `main`; layered tree adopted at parity and made the
      bootstrap root. [1.1] (#49, #51, #78)
- [x] 2. Auto-sync the three layers, prune per leaf. [1.1, 1.4] (#75, #76, #77)
- [x] 3. Argo CD owns democratic-csi and Cilium: self-heal, no prune. [1.4] (#92, #95)
- [x] 4. `deploy/`: one rendered file per object. [1.2] (#87)
- [x] 5. CI as parallel jobs behind one aggregate `ci` check. [2.2] (#122)
- [x] 6. Re-render `deploy/` on Renovate pull requests. [1.3] (#123, #125)
- [x] 7. Renovate: automerge every update on green CI, no approval gates. [3.1] (#180, #198)
- [x] 8. Automatic rollback, armed with its token; outage guard, no issues. [4.2, 4.3]
      (#181, #224, #331)
- [x] 9. pre-commit hooks in CI; Kyverno policies over `deploy/`; kind
      pre-production. [2.4, 2.5] (#243, #244, #246)
- [x] 10. PostSync smoke tests on every user-facing app. [4.1] (#248)
- [x] 11. Argo CD alerts: degraded, failed, drifting apps. [4.4] (#330)
- [x] 12. Validate against Kubernetes 1.37; bootstrap chart versions in step
      with Renovate. [2.4] (#354, #376)
- [x] 13. CodeQL and the OpenSSF Scorecard workflow. (#357, #344)
- [x] 14. Never change a tag variant; fail on bulky bases and variant changes;
      exempt reverts. [3.3, 3.4] (#406, #407, #408, #410, #427)
- [x] 15. Pin every image by digest; group digest refreshes. [3.2, 3.5] (#474, #476)
- [x] 16. Branch protection on `main`: strict `ci`, signatures, linear history,
      admins included, 0 approvals (GitHub settings, no PR). [2.1]
- [x] 24. repo_policy.py matches API groups exactly; closes its CodeQL
      url-substring alerts. (#542)

## Open

Wave 3 puts Kyverno in the cluster in Audit mode: `.kiro/specs/wave3-*`.

- [ ] 17. Kyverno Deny in the cluster for the policies CI already denies,
      then the PSS-restricted set; prefer CEL policies Kyverno turns into
      native ValidatingAdmissionPolicies (no webhook in a cold start).
- [ ] 18. Image provenance: a Kyverno `ImageValidatingPolicy` in Audit for
      publishers that sign with cosign keyless; unsigned images listed with a
      reason. Weekly CycloneDX SBOM of the running image set, scanned for new
      CVEs, findings to code scanning and ntfy.
- [ ] 19. Per-app hardening, one PR per app: requests and a memory limit on
      every container, probes where missing, non-root and `restricted` Pod
      Security, `automountServiceAccountToken: false` where unused. Then
      `require-resources` and `require-probes` move to Deny. Not in the same
      window as that app's network-policy flip.
- [ ] 20. Monthly rebuild-from-git rehearsal: a throwaway Talos cluster in CI,
      `bootstrap/` with test secrets, infrastructure and platform layers
      converge (apps with data excluded).
- [ ] 21. Adopt or delete the staged trees `infrastructure/snapshot-controller`
      and `infrastructure/nfs-storage`.
- [ ] 22. Delete the stale Helm release Secret `kube-system/sh.helm.release.v1.cilium.v1`
      left by the adopted Cilium release.
- [ ] 23. Weekly agent pass: check the docs against the repo and the live
      cluster, and review whether each area is still on the right solution;
      output is pull requests.
- [ ] 24. Serialise local merges: `pr-merge.sh` takes a lock in the git
      common dir, rebases, waits for `ci` and merges inside it, retrying
      when `main` moves (no merge queue on a user-owned repository). [2.3]
      (`tests/bash/test_pr_merge_lock.sh`)
