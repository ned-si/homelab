# Requirements: platform-talos (as-is)

## Introduction

The nodes run Talos Linux on four Turing RK1 boards: three control planes with
etcd and one worker, eMMC only. This spec records what the node layer does
today: configuration from git, automated upgrades, drift detection and disk
health. Stack and versions: [tech.md](../../steering/tech.md); operating
detail: [docs/talos.md](../../../docs/talos.md) and
[docs/talos-cheatsheet.md](../../../docs/talos-cheatsheet.md).

Non-goals:
- Kubernetes objects above the node (Argo CD owns them: `gitops-delivery`).
- Applying Talos config changes automatically (a config change can reboot a node).

## Glossary

- **Render**: the machine configs `scripts/talos-genconfig.sh` writes to
  `talos/clusterconfig/` from `talos/talconfig.yaml`, `talos/patches/` and the
  sealed `talos/talsecret.sops.yaml`.
- **Rollout**: tuppr applying a merged version to the nodes, one at a time.

## Requirements

### Requirement 1: Node configuration is code

**User story:** As the operator, I want every node's configuration in git, so
that a node can be rebuilt from the repository alone.

#### Acceptance criteria

1. THE machine configs SHALL be generated only from `talos/`; the generated
   files and `talosconfig` SHALL stay git-ignored. (CI job `talos`,
   `scripts/ci/talos-validate.sh`, check `git-ignore rules`.)
2. WHEN a pull request changes `talos/`, THE `talos` job SHALL validate every
   render with `talosctl validate --mode metal` and check the invariants:
   3 control planes and 1 worker, the pinned Image Factory schematic, the VIP
   on control planes only, kube-proxy and Flannel off, the panic sysctls and
   the metrics bind addresses. (`talos-validate.sh`)
3. THE render SHALL succeed with workload isolation both off and on, and the
   cluster SHALL run with it off so iSCSI volumes mount. (`talos-validate.sh`,
   two `genconfig` passes)
4. THE API endpoint `https://192.168.1.11:6443` SHALL be held by Talos itself
   (`Layer2VIPConfig`), with no kube-vip. (`talos-validate.sh` VIP invariant)

### Requirement 2: Upgrades without a person

**User story:** As the operator, I want Talos and Kubernetes to upgrade
themselves safely, so that the cluster stays current without a window.

#### Acceptance criteria

1. WHEN Renovate bumps `talosVersion` or `kubernetesVersion`, THE pull request
   SHALL change `talos/talconfig.yaml` and `platform/tuppr/upgrades/`
   together, one minor per pull request. (`talos-validate.sh` fails when they
   differ; Renovate rule "Talos and Kubernetes: one minor per pull request")
2. WHEN such a pull request runs CI, THE `talos-upgrade` job SHALL upgrade a
   throwaway QEMU cluster from main's versions to the new ones and require
   nodes Ready, Cilium OK and a smoke workload answering; a failure blocks
   the automerge. (`scripts/ci/talos-upgrade-rehearsal.sh`, part of `ci`)
3. WHEN the change merges, tuppr SHALL roll it out one node at a time, only
   while etcd is healthy, every node is Ready and every Argo CD Application
   is Healthy (15 min timeout each). (`TalosUpgrade/cluster`,
   `KubernetesUpgrade/kubernetes` reach phase `Completed`)
4. IF a rollout fails or stalls, THEN THE system SHALL page with
   `TalosUpgradeFailed`, `TalosUpgradeNodeFailed`, `TalosUpgradeStuck`,
   `KubernetesUpgradeFailed`, `KubernetesUpgradeStuck` or
   `TupprOperatorAbsent`. (ntfy route in `platform/kube-prometheus-stack/values.yaml`)

### Requirement 3: Running config matches main

**User story:** As the operator, I want to know when a node differs from git,
so that a merged change is never left unapplied.

#### Acceptance criteria

1. THE CronJob `system-upgrade/talos-drift` SHALL run daily at 05:40 UTC,
   compare each node's config with main's render by sha256 and push
   `talos_config_drift{node}`. (`platform/talos-drift/check.sh`)
2. WHEN a node differs from main, THE system SHALL page with
   `TalosConfigDrift`. (`tests/prometheus/talos_drift_test.yaml`)
3. IF no result arrives for 2 days, THEN THE system SHALL page with
   `TalosDriftCheckStale`. (`tests/prometheus/talos_drift_test.yaml`)
4. THE check SHALL never hold the age key: it rebuilds the cluster secrets
   from a control plane's config in a memory-backed volume.
   (`platform/talos-drift/cronjob.yaml`)

### Requirement 4: Disks last and warn early

**User story:** As the operator, I want eMMC wear and disk pressure visible
before they take a node down.

#### Acceptance criteria

1. THE node-exporter DaemonSet SHALL export `node_emmc_life_time_estimate`
   and `node_emmc_pre_eol_info` for every eMMC every 5 minutes. (`emmc-wear`
   sidecar in `platform/kube-prometheus-stack/values.yaml`; Homelab / Nodes)
2. WHEN wear reaches step 9 or pre-EOL 2, THE system SHALL page with
   `NodeEmmcWearHigh`; at step 11 or pre-EOL 3 with `NodeEmmcEndOfLife`.
   (`platform/kube-prometheus-stack/routes/alerts.yaml`)
3. THE kubelet SHALL start image garbage collection at 70% disk use and stop
   at 60%. (`talos/patches/kubelet-image-gc.yaml`)
4. WHEN a node filesystem turns read-only, THE system SHALL page with
   `NodeFilesystemReadOnly`. (`routes/alerts.yaml`)
5. WHEN a node is NotReady for 15 minutes, THE system SHALL page with
   `HomelabNodeDown`. (`tests/prometheus/outage_test.yaml`)
