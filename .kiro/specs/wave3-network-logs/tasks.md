# Tasks: wave 3 network visibility and logs (Hubble, policy audit, SigNoz trial)

Each task is one PR or one recorded check. Requirement numbers in brackets. One topic per
PR; CI is the gate; merge with `scripts/pr-merge.sh`. Silence before anything that rolls
the Cilium agents or applies Talos config; take an etcd snapshot before `task talos:apply`.

- [x] 1. (design.md, Answers) Answer the design's open questions 1 to 4 and 8 to 10 in `design.md` (read-only:
      Cilium docs and chart, the live agents, the tailnet policy). [1.5, 1.6, 3.1, 3.4,
      4.5]
- [x] 2. (#515) PR `feat(network): Hubble relay and UI`: Cilium values, `ignoreDifferences` for the
      relay certificate. Silence `kube-system` if open question 2 says the agents roll.
      [1.1, 1.5, 1.6]
- [x] 3. (#519) PR `feat(network): Hubble UI on the tailnet`: namespace `hubble`, app
      `hubble-access` (oauth2-proxy, Tailscale Ingress, CNPs in `hubble` and
      `kube-system`), Keycloak client `hubble` (platform client, `admins`), SOPS Secret,
      `ci/expected-ingresses.txt`, `docs/remote-access.md`. Check the login matrix
      (member in, non-member out). [1.2, 1.3, 1.4]
- [x] 2b. (#521) PR `feat(network): renew the Hubble certificates with certgen`:
      `hubble.tls.auto.method: cronJob`, relay metrics and PodMonitor, alerts with
      promtool tests and `routes.txt` lines, `docs/networking.md`. [1.5]
- [x] 3b. (#539) PR `feat(network): Hubble UI on the shared Gateway`: the operator
      decision of 2026-10-16 (every UI public behind Keycloak): HTTPRoute
      `hubble.lilalala.com` with the #465 headers, the tailnet Ingress removed, the
      `hubble-sso` CNP from `reserved:ingress`, the Keycloak redirect URI, a public
      probe. [1.2, 1.3, 1.4]
- [x] 4. (#525) PR `feat(network): sync the Cilium policies, not enforced`: `network-policies`
      in the infrastructure layer as-is, switches false; check `cilium-dbg endpoint list`
      shows nothing enforced and Headlamp still is. [2.1, 2.5]
- [x] 5. (#530) PR `feat(network): would-be drops from policy verdicts`: the Hubble `policy`
      metric (or the flow-export fallback with Vector, after task 9), `routes/netpol.yaml`,
      the Network dashboard row, `docs/networking.md`. [3.1, 3.2, 3.3, 3.4]
- [x] 6. (#533) PR `feat(network): netpol-observe script`: `scripts/netpol-observe.sh` and its
      bash test. [2.3]
- [ ] 7. Observe 7 days, then one PR per namespace group, `feat(network): allow-lists for
      <namespaces> from observed flows`: regenerated or new files with one comment per
      rule, switch pairs in `90-enforcement.yaml` all false. Groups: application
      namespaces; `keycloak` and `backup-verify`; `monitoring` and the exporters;
      `tailscale`, `headlamp`, `hubble`; the wave 3 namespaces (`kyverno`, `tetragon`,
      `logging`, `signoz`). [2.2, 2.3, 2.4, 2.5]
- [x] 8. (design.md, Answers) Answer open questions 5 to 7 (ClickHouse on the RK3588 first; stop the logs part
      here if it fails). [5.1, 5.5, 6.1]
- [x] 9. (#535, #549) PR `feat(observability): Vector agent for pod logs`: namespace `logging`, Vector
      DaemonSet (parsing, memory buffer, metrics, blackhole sink until task 11),
      PodMonitor, `docs/observability.md` Logs section. [4.1, 4.2, 4.4, 4.6, 4.7]
- [x] 10. (#540) PR `feat(observability): SigNoz behind Keycloak`: namespace `signoz`, chart
      values (limits, retention, `iscsi` volume, digests, JSON logs), `signoz-sso`,
      HTTPRoute `signoz.lilalala.com`, CNPs (OTLP from `logging` only), Keycloak client
      `signoz`, SOPS Secrets, `docs/observability.md`. [5.1, 5.2, 5.3, 5.4, 5.5, 5.6]
- [ ] 11. PR `feat(observability): ship logs to SigNoz over OTLP`: Vector sink switched to
      OTLP. [4.3]
- [ ] 12. PR `feat(talos): send service and kernel logs to Vector`: `talos/patches/logging.yaml`,
      the `KmsgLogConfig` document, `docs/talos.md`; etcd snapshot, then
      `task talos:apply` node by node from main. [4.5]
- [x] 13. (#561) PR `feat(backups): SigNoz metadata backup`: restic CronJob with the pending
      guard, `ci/active-cronjobs.txt`, `ci/guard-modes.txt`, `docs/backups.md` (metadata
      backed up, ClickHouse disposable); rehearse one restore into a scratch namespace and
      write it down. [6.1, 6.2, 6.3, 6.4]
- [x] 14. (#564) PR `feat(observability): SigNoz trial gate`: `platform/signoz/rules.yaml` (trial
      recording rules, `signoz_trial:pass`, `LogPipelineDiscarding`,
      `SigNozCollectorAbsent`) with promtool tests, runbook sections, `routes.txt` lines,
      the dashboard panel, start and end dates and thresholds in
      `docs/observability.md`. [7.1, 7.2, 7.3, 7.6]
- [ ] 15. On the end date: read `signoz_trial:pass` over the trial window and the phone
      check; PR `docs(observability): SigNoz trial result` that either drops "trial" or
      removes SigNoz and records the Loki fallback. [7.4, 7.5]
- [ ] 16. Tick this file and record the PR numbers. [all]
