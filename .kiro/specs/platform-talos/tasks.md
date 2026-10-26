# Tasks: platform-talos

Requirement numbers in brackets. A living area spec: the history of the area,
no open tasks. New work is an issue on the board, and a change spec when it
needs one ([README](../README.md)).

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

## Moved to the backlog (2026-10-26)

- 12. Moved to the backlog: #736 (A lean Talos audit policy).
- 13. Moved to the backlog: #737 (SELinux enforcing on the nodes).
- 14. Moved to the backlog: #711 (Kubernetes API authentication through Keycloak OIDC).
- 15. Moved to the backlog: #738 (Revisit NVMe per node from the eMMC wear trend).
- 16. Moved to the backlog: #739 (Seal the Turing Pi BMC credentials).
- 18. Moved to the backlog: #740 (Set the kubelet's graceful node shutdown explicitly).
- 19. Moved to the backlog: #741 (A drain path for the single-instance CNPG clusters).
- 20. Moved to the backlog: #742 (Keep the tailnet addresses out of cluster discovery).
