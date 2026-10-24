# Tasks: cilium-upgrades

One PR per task, in order; each is safe on its own.

## Done

- [x] 1. Revert Cilium to 1.20.3 and write the postmortem and this spec.
      (#659, this PR)

## Open

- [ ] 2. `envoy.xdsMode: ads` in the Cilium values, repo-policy rule
      `cilium-explicit-xds`; then the recorded live cleanup: no `helm`
      managedFields on the Cilium objects, no `sh.helm.release.v1.cilium.*`
      Secret. Owns gitops-delivery task 22. [1.1, 1.2]
- [ ] 3. Talos rehearsal on every Cilium change, with the Gateway smoke. [2.1, 2.2]
- [ ] 4. PostSync Gateway smoke on the `cilium` Application. [3.1]
- [ ] 5. Renovate: Cilium after 3 days, weekdays 09:00–17:00 Zurich. [4.1]
- [ ] 6. `GatewayDown`: alert, route through quiet hours, inhibit of the per-app
      SLO burns, runbook. [5.1, 5.2, 7.1]
- [ ] 7. Auto-revert a failed Cilium patch update; gitops-delivery Req 4.2
      updated in the same PR. [6.1]
- [ ] 8. Re-apply Cilium 1.20.4 (the Renovate PR, after tasks 2–5); the
      rehearsal must pass. [2.2]
