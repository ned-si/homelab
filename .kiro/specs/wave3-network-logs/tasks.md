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
      - [ ] 7a. Application namespaces (#772, 2026-10-26): LazyLibrarian, the hook Jobs
        (presync-backup, postsync-smoke), WAL archiving to S3 and the backup-verify reads
        of the theater and mealie databases, qBittorrent's ICMP errors, and the CNPG
        operator, whose rules named `cnpg-system` while it runs in `immich`. Still
        uncovered, ports unknown in 45 minutes of events (the metric has none): Plex
        and Jellyfin to the internet off 443 (209 and 5 in 7 days), qBittorrent to
        `remote-node` (2,342), Syncthing to the API server (331). Left uncovered on
        purpose: Syncthing to peers' private addresses (10.0.0.0/8, a LAN device)
        and NAT-PMP to the host. Next: `netpol-observe.sh` live for those four.
- [x] 8. (design.md, Answers) Answer open questions 5 to 7 (ClickHouse on the RK3588 first; stop the logs part
      here if it fails). [5.1, 5.5, 6.1]
- [x] 9. (#535, #549) PR `feat(observability): Vector agent for pod logs`: namespace `logging`, Vector
      DaemonSet (parsing, memory buffer, metrics, blackhole sink until task 11),
      PodMonitor, `docs/observability.md` Logs section. [4.1, 4.2, 4.4, 4.6, 4.7]
- [x] 10. (#540) PR `feat(observability): SigNoz behind Keycloak`: namespace `signoz`, chart
      values (limits, retention, `iscsi` volume, digests, JSON logs), `signoz-sso`,
      HTTPRoute `signoz.lilalala.com`, CNPs (OTLP from `logging` only), Keycloak client
      `signoz`, SOPS Secrets, `docs/observability.md`. [5.1, 5.2, 5.3, 5.4, 5.5, 5.6]
- [x] 10b. (#570; organisation `homelab` registered, self-registration closed, admin
      password sealed in #572) PR `docs(observability): SigNoz login`: Requirement 8, answer 11, the design
      row, `docs/decisions.md`. Register the organisation and the admin, close
      self-registration; ask the operator for his login email and whether his Google
      account is on a Workspace domain. [8.1, 8.2, 8.3]
- [ ] 10c. PR `feat(observability): SigNoz admin under the operator's identity`: the admin
      email changed to his address, the SOPS password re-sealed, the runbook (break-glass
      `/login?password=Y`); with a Workspace domain also the OAuth client in SOPS and the
      authenticated domain set through the API. Check the login matrix of 8.8. [8.3, 8.4,
      8.5, 8.6, 8.7, 8.8]
- [x] 11. (#574; collector metrics fixed in #571) PR `feat(observability): ship logs to
      SigNoz over OTLP`: Vector sink switched to OTLP. The collector accepts OTLP/HTTP from
      the node identities, not from Vector's pod labels: Vector runs on the host network.
      Checked: rows in `signoz_logs.distributed_logs_v2` from `pods` on all four nodes,
      `talos-service` on all four, `talos-kernel` on cp-1 and w-1 (kernel lines are rare). [4.3]
- [x] 12. (#548; applied on all four nodes without a reboot) PR `feat(talos): send service and kernel logs to Vector`: `talos/patches/logging.yaml`,
      the `KmsgLogConfig` document, `docs/talos.md`; etcd snapshot, then
      `task talos:apply` node by node from main. [4.5]
- [x] 13. (#561) PR `feat(backups): SigNoz metadata backup`: restic CronJob with the pending
      guard, `ci/active-cronjobs.txt`, `ci/guard-modes.txt`, `docs/backups.md` (metadata
      backed up, ClickHouse disposable); rehearse one restore into a scratch namespace and
      write it down. [6.1, 6.2, 6.3, 6.4]
- [ ] 13b. The restore rehearsal of task 13, not done yet: it needs a nightly snapshot of
      the real organisation (the first is 2026-10-17 06:00 UTC) and a scratch SigNoz. [6.4]
- [x] 14. (#564) PR `feat(observability): SigNoz trial gate`: `platform/signoz/rules.yaml` (trial
      recording rules, `signoz_trial:pass`, `LogPipelineDiscarding`,
      `SigNozCollectorAbsent`) with promtool tests, runbook sections, `routes.txt` lines,
      the dashboard panel, start and end dates and thresholds in
      `docs/observability.md`. [7.1, 7.2, 7.3, 7.6]
- [ ] 15. On the end date: read `signoz_trial:pass` over the trial window and the phone
      check; PR `docs(observability): SigNoz trial result` that either drops "trial" or
      removes SigNoz and records the Loki fallback. [7.4, 7.5]
- [x] 16. Tick this file and record the PR numbers. Also merged for this spec: #544
      (relay peers alert counts IDLE), #551 (would-be drops scoped), #560 (Vector memory),
      #566 (SigNoz sync drift), #568 (no automerge for data-store majors). Open: 7 (needs
      7 days of flows, earliest 2026-10-24), 10c (waits on the operator), 13b, 15
      (2026-10-31). [all]
- [x] 17. (#576; amended for 9.9) PR `docs(storage): SELinux labels on iSCSI volumes`: Requirement 9, the design
      rows, `docs/decisions.md` (prerequisite of SELinux enforcing), the threat model. [9]
- [x] 17b. (#578) PR `fix(storage): let the iSCSI node plugin keep SELinux mount options`: the
      ConfigMap and its read-only `subPath` mount in `values-iscsi.yaml`. Before the
      roll: `updateStrategy` RollingUpdate with `maxUnavailable: 1`, no backup Job
      running or due within 15 minutes, `CSIDriver.spec.seLinuxMount` unset or false.
      During it: one node at a time, a scratch claim mounted on that node before the
      next, every Argo CD app Healthy, no pod stuck in `ContainerCreating`. [9.9]
- [x] 18. (#579) PR `feat(storage): SELinux label on the iSCSI StorageClasses`: `mountOptions` and
      `Force=true,Replace=true` in `infrastructure/democratic-csi/values-iscsi.yaml`, a
      repo policy check with tests, the StorageClass table in `docs/backups.md`. Before
      the sync: a scratch
      StorageClass and claim on the cluster prove that deleting a class keeps its
      volumes bound and that a labelled volume mounts as `ephemeral_t`. [9.1, 9.2]
- [x] 19. (#580) PR `feat(storage): pv-selinux-label script`: `scripts/pv-selinux-label.sh` (dry
      run by default, `--apply`, `--revert`, refuses `immich-data` and git-managed
      volumes), its bash test, a runbook. [9.3, 9.4, 9.6]
- [x] 20. (#581) PR `feat(observability): count auditd records`: the Vector counter, the
      `AuditAVCRateHigh` rule with a promtool test, `routes.txt`, the Logs section. [9.7,
      9.8]
- [ ] 21. Roll out: the ClickHouse volume first and its proof (9.5); then one application
      at a time, git-managed volumes by one PR each, the others by the script, databases
      after a fresh backup. Record each volume here. [9.3, 9.5, 9.6]
      Labelled on 2026-10-26 (`mountOptions` with `context=`): every iSCSI volume
      but 2 of 3 in `immich` and both in `seafile` (#583 to #587).
