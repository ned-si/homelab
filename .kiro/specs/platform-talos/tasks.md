# Tasks: platform-talos

Requirement numbers in brackets. New work in this area adds a task here first.

## Done

- [x] 1. Talos cluster config as code: talhelper, patches, CI job `talos`. [1.1, 1.2] (#295)
- [x] 2. Seal the cluster secrets; keep workload isolation off. [1.3] (#311)
- [x] 3. Cutover manifests for the Talos cluster; drop the kubeadm and Ubuntu
      playbooks. [1] (#296, #334, #342)
- [x] 4. Scripts read nodes, etcd and addresses through `talosctl`. [1] (#324, #336)
- [x] 5. Automated Talos and Kubernetes upgrades: Renovate, the `talos-upgrade`
      rehearsal, tuppr. [2.1-2.3] (#361)
- [x] 6. Node golden-signals dashboard, eMMC wear, etcd metrics. [4.1, 4.2] (#381, #388)
- [x] 7. Kubelet image GC from 70%. [4.3] (#393)
- [x] 8. Daily drift check against main. [3] (#456, #464)
- [x] 9. Page on read-only disks and on failed or stuck upgrades. [2.4, 4.4] (#472)
- [x] 10. First automated rollouts through tuppr: Talos 1.14.3 and 1.14.4. [2.3] (#457, #499)
- [x] 11. Docs: Talos crash course and cheatsheet; keep the boot partitions
      when resetting a node; BMC slots and the power-cycle runbook. (#312, #318, #236)
- [x] 17. Talos API on the tailnet: `siderolabs/tailscale` in the schematic,
      an ExtensionServiceConfig per node with the sealed OAuth secret,
      tailnet names in `certSANs` and `/etc/hosts`, kubelet and etcd pinned to
      the LAN, the `tag:talos` grant; rolled out node by node (w-1, cp-3,
      cp-2, cp-1) without drain; context `homelab-ts`. [5] (#527)

## Open

- [ ] 12. Lean Talos audit policy (`apiServer.auditPolicy`): drop read-only
      system traffic, Metadata for Secrets, RequestResponse for RBAC changes,
      shipped to the log store chosen in wave 3 (`.kiro/specs/wave3-*`).
      Rolling apiserver restart, one control plane at a time.
- [ ] 13. SELinux enforcing, proven in the Talos CI cluster before the nodes.
      Record in the threat model why STATE/EPHEMERAL encryption is not done
      without a TPM.
- [ ] 14. Kubernetes API authentication by Keycloak OIDC (Talos apiServer
      patch). Tracked in [access-identity](../access-identity/tasks.md).
- [ ] 15. Revisit NVMe per node once the eMMC `life_time` trend has a few
      weeks of data.
- [ ] 16. Seal the Turing Pi BMC credentials.
- [ ] 18. Set the kubelet's graceful node shutdown explicitly in
      `talconfig.yaml` (`shutdownGracePeriod`,
      `shutdownGracePeriodCriticalPods`; Talos defaults 30 s / 10 s today),
      sized so single-instance Postgres stops cleanly on a reboot.
- [ ] 19. A drain path for the single-instance CloudNativePG clusters
      (`nodeMaintenanceWindow` with `reusePVC`, set by the upgrade automation
      around each node), so upgrades can drain instead of skipping it.
- [ ] 20. Keep the tailnet addresses out of the cluster discovery data:
      KubePrism lists them as API endpoints (unreachable, filtered as
      unhealthy) and `talosctl health` without node lists dials them.
