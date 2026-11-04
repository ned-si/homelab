# Tasks: pod-security-restricted

One pull request per task, in this order. Tasks 1 to 7 come before the
first flip. A flip follows "The flip, step by step" in
[design.md](design.md). Requirement numbers in brackets. Later namespaces
are [#1020](https://github.com/ned-si/homelab/issues/1020) and the Kyverno
restricted set in Deny is [#1021](https://github.com/ned-si/homelab/issues/1021),
both blocked by #726.

## Done

- [x] 1. `fix(kyverno): reports read pods/ephemeralcontainers`: the
      read-only grant in `infrastructure/kyverno/values.yaml` to
      `kyverno-reports-controller`, the ServiceAccount the
      `RBACPermissionsGranted` condition checks; after the sync, the 17
      policies that match `pods/ephemeralcontainers` read `ready: true`.
      [1] (#1032)
- [x] 2. `feat(scripts): psa-readiness.sh per namespace`: G1 to G3 of
      design.md, read-only, its bash test with a stubbed `kubectl` (a
      clean namespace, one failing Pod, one failing CronJob template, a
      ReplicaSet at 0 ignored, a StatefulSet with a claim template, a
      non-PodSecurity dry-run error read as `NOT READY`, a write verb
      refused); one live run per namespace of the evidence table quoted in
      the pull request. [2.1, 2.2] (#1058)

## Open

- [ ] 3. `feat(ci): restricted set blocks in enforced namespaces`:
      `scripts/ci/kyverno.sh` reads the `enforce: restricted` namespaces
      from `namespaces.yaml`, keeps for this rule the Helm-rendered objects
      of every namespace in both that set and `EXCLUDED_NAMESPACES`
      (computed at run time; today `argo` and `kyverno`, both named in the
      log), and its test with a fixture; `docs/testing.md`. [3]
- [ ] 4. `chore(namespaces): explicit Pod Security enforce labels`:
      `enforce: baseline` on `backup-verify`, `books` and `theater` (server
      dry-run without warning in the pull request), the repo-policy rule
      `pod-security-labels` and its test, the header of `namespaces.yaml`
      with the reason per namespace below `restricted`. [4]
- [ ] 5. `feat(monitoring): page on Pod Security enforce denials`: the
      alert `PodSecurityEnforceDenied` of D15 in
      `platform/kube-prometheus-stack/routes/kyverno-alerts.yaml`, its
      cases in `tests/prometheus/kyverno_test.yaml`, its runbook
      `docs/runbooks/alerts/PodSecurityEnforceDenied.md` (find the
      namespace, then the break-glass); the live query in the pull
      request. [10.1]
- [ ] 6. `chore(renovate): operator releases merge on weekdays`: the rule
      of D15 for the tuppr chart, the `cloudnative-pg` chart and
      `plugin-barman-cloud` in `.github/renovate.json5`. [10.2]
- [ ] 7. `docs(runbooks): pod security break-glass and flip`:
      `docs/runbooks/pod-security.md` (the break-glass, the merge hold, the
      revert, the flip procedure, the Kyverno break-glass for #1021,
      expected outputs), linked from `namespaces.yaml`,
      `docs/architecture.md` and the `PodSecurityEnforceDenied` runbook;
      the live test of Requirement 5.2 with its times and outputs in the
      pull request. [5]
- [ ] 8. Flip `home`, with G4 for `home-assistant-postgresql` and the
      checks of Requirement 7 (`home.lilalala.com`). [6, 7, 8]
- [ ] 9. Flip `system-upgrade`, with G4 for the tuppr Jobs (the pinned
      source, and after the sync a server dry-run of an equivalent Pod) and
      the G3 result of the `talos-drift` CronJob named. [6, 7, 8]
- [ ] 10. Close: `docs/architecture.md`, `docs/threat-model.md` and the
      `namespaces.yaml` header describe the enforced levels;
      [gitops-delivery](../gitops-delivery/) task 17b points here;
      `status: done`, `closed:`; #724 closed with links to #1020 and #1021.
      [9]
