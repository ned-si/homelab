# Tasks: alert-triage

One PR per task, in order; each is safe on its own.

## Done

- [x] 1. `scripts/alert-triage.sh` (poll, state, regex check, message
      builder) with its tests; no cluster objects yet. [1.1, 1.2, 2.2, 3.2] (#786)
      Superseded by the webhook design (2026-10-27); removed in task 4.
- [x] 2. Image: `alpine/k8s:1.37.1` (digest
      `sha256:712dc5385d1c1a3f83b747fa9e40f64d433a97f72ff42f9755ff7dd1f62846e4`)
      has bash, kubectl, jq, git, curl, sha256sum, paste and timeout (checked
      2026-10-27). The run against the cluster happens in task 5 under the
      snapshot ServiceAccount, not with the operator's kubeconfig. [4.4]
- [x] 3. triage.sh reads Alertmanager over HTTP (`AM_URL`; unset, through
      the kube-apiserver's service proxy, for a local run); status.sh
      reports `unavailable (no exec)` for a forbidden exec; bash tests. [4.1]

## Open

- [ ] 4. The receiver (`platform/alert-triage/receiver/`, Python, stdlib):
      webhook handler, alert-name check, incident ID, Job templates, message
      builder, JSON logs, unittest; remove `scripts/alert-triage.sh` and its
      test. No cluster objects yet. [1.1, 1.3, 2.1, 3.1, 3.2, 4.3]
- [ ] 5. Namespace `alert-triage`: Deployment, Service, the ServiceAccounts
      and Roles, the empty fix table, the Kyverno policy with its CLI test,
      the CiliumNetworkPolicies, and the Alertmanager route (`action=human`,
      `repeat_interval: 6h`, `send_resolved: true`) with `routes.txt`. One
      `amtool alert add` test page, its snapshot found in SigNoz.
      [1.2, 3.3, 4.1, 4.2, 4.4]
- [ ] 6. `AlertTriageFailing`, runbook and promtool test; the ntfy link to the
      store; docs/observability.md "Alert triage". [1.4, 3.2]
- [ ] 7. Record one real page's incident and close. The first fix entries are
      separate PRs (2.2, 2.3).
