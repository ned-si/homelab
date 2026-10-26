# Tasks: gitops-delivery

Requirement numbers in brackets. A living area spec: the history of the area,
no open tasks. New work is an issue on the board, and a change spec when it
needs one ([README](../README.md)).

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

## Moved to the backlog (2026-10-26)

Wave 3 puts Kyverno in the cluster in Audit mode: `.kiro/specs/wave3-*`.

- [x] 17. (#687 for 17a; 17b moved to #724) Kyverno Deny in the cluster for the policies CI already denies,
      then the PSS-restricted set; prefer CEL policies Kyverno turns into
      native ValidatingAdmissionPolicies (no webhook in a cold start).
      - [x] 17a. Deny for the 16 baseline policies with no live finding outside
        the excluded namespaces (2026-10-24, after the PolicyExceptions);
        CI blocks on the same 16 over `deploy/` and the rendered Helm apps.
        (#687)
      - 17b. Moved to the backlog: #724 (Kyverno: the PSS-restricted policies in Deny, then PSA enforce).
- 18. Moved to the backlog: #725 (Image provenance and a weekly SBOM).
- 19. Moved to the backlog: #726 (Per-app hardening: resources, probes, non-root).
- 20. Moved to the backlog: #723 (Disaster recovery: rebuild from git, rehearsed).
- 21. Moved to the backlog: #749 (Adopt or delete the staged snapshot-controller and nfs-storage trees).
- 22. Stale Helm ownership of the adopted Cilium release: owned by
      `cilium-upgrades` task 2.
- 23. Moved to the backlog: #727 (A weekly agent pass over docs, repo and cluster).
- [x] 24. (#543) Serialise local merges: `pr-merge.sh` takes a lock in the git
      common dir, rebases, waits for `ci` and merges inside it, retrying
      when `main` moves (no merge queue on a user-owned repository). [2.3]
      (`tests/bash/test_pr_merge_lock.sh`)
