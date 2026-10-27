# Tasks: alert-triage

One PR per task, in order; each is safe on its own.

## Done

- [x] 1. `scripts/alert-triage.sh` (poll, state, regex check, message
      builder) with its tests; no cluster objects yet. [1.1, 1.2, 2.2, 3.2] (#786)

## Open
- [ ] 2. Pick and pin the image (bash, kubectl, jq, git, curl); run
      triage.sh from it locally against the cluster. [3.3]
- [ ] 3. The CronJob, ServiceAccount, Role, ConfigMap from `scripts/`, and the
      CiliumNetworkPolicy, with `suspend: true`. [2.1, 3.1, 3.3]
- [ ] 4. `AlertTriageFailing` rule, runbook and test. [1.3]
- [ ] 5. Unsuspend; record one real page's snapshot (or a test page from
      `amtool alert add` with `action=human` on a test receiver) and close.
      [1.1]
