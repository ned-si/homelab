# Talos

The cluster runs Talos Linux and Kubernetes at the versions pinned in
[`talos/talconfig.yaml`](../talos/talconfig.yaml), on four Turing RK1 nodes:
three control planes with etcd, one worker. The machine configs are generated
from [`talos/`](../talos) with
[talhelper](https://budimanjojo.github.io/talhelper/). A merged config change
reaches a node only through the `task talos:*` commands below. A merged
version change is rolled out by tuppr ([Upgrades](#upgrades)).

## Layout

| Path | Contents |
| --- | --- |
| [`talos/talconfig.yaml`](../talos/talconfig.yaml) | Cluster, versions, Image Factory schematic, the four nodes |
| [`talos/patches/`](../talos/patches) | Patches talhelper applies: `sysctls.yaml` (every node), `kube-proxy.yaml` and `controlplane-metrics.yaml` (control planes) |
| [`talos/patches/talosctl/`](../talos/patches/talosctl) | Documents talhelper 3.1.17 cannot parse yet (`SecurityProfileConfig`; in `controlplane/`, `KubeTalosAPIAccessConfig` for tuppr); `scripts/talos-genconfig.sh` applies them with `talosctl machineconfig patch` |
| `talos/talsecret.sops.yaml` | Cluster CAs, keys and tokens, SOPS-encrypted (created once, [below](#cluster-secrets-once)) |
| `talos/clusterconfig/` | Generated machine configs and `talosconfig`. Git-ignored: they hold the keys in plaintext |
| [`scripts/talos-genconfig.sh`](../scripts/talos-genconfig.sh) | `task talos:genconfig`: talhelper, then the talosctl patches |
| [`scripts/ci/talos-validate.sh`](../scripts/ci/talos-validate.sh) | The `talos` CI job |
| [`scripts/ci/talos-upgrade-rehearsal.sh`](../scripts/ci/talos-upgrade-rehearsal.sh) | The `talos-upgrade` CI job: a version change rehearsed on a throwaway cluster |
| [`platform/tuppr/`](../platform/tuppr) | tuppr values and the `TalosUpgrade` / `KubernetesUpgrade` resources with the target versions |
| [`platform/talos-drift/`](../platform/talos-drift) | The daily [drift check](#drift-check) and its alerts |

## Nodes

| Hostname | IP | Role |
| --- | --- | --- |
| `homelab-cp-1` | `192.168.1.247` | control plane |
| `homelab-cp-2` | `192.168.1.238` | control plane |
| `homelab-cp-3` | `192.168.1.239` | control plane |
| `homelab-w-1` | `192.168.1.240` | worker |

- API endpoint `https://192.168.1.11:6443`. Talos holds the VIP itself
  (`Layer2VIPConfig` on the control planes); there is no kube-vip. When the
  holder goes down, another control plane takes the VIP within seconds.
- Static addresses on the one physical NIC (`deviceSelector: physical: true`),
  gateway and DNS `192.168.1.1`.
- Install disk `/dev/mmcblk0`, the eMMC.
- `talosctl` talks to the node IPs, not the VIP.

## Image

The Image Factory schematic is in `talconfig.yaml` (`controlPlane.schematic`,
reused by `worker`): the `sbc-rockchip` overlay `turingrk1` plus the
`siderolabs/iscsi-tools` extension for democratic-csi. Its ID is
`ca77d17f5b2c67e1fdb32a57cdbb166e20b8e19010ab6d35a888970958d76c02`; CI fails if
the generated installer image carries another one.

Print the disk image URL:

```sh
cd talos && talhelper genurl image --offline-mode -n homelab-cp-3
```

Expected:
`https://factory.talos.dev/image/ca77d17f5b2c67e1fdb32a57cdbb166e20b8e19010ab6d35a888970958d76c02/v1.14.2/metal-arm64.raw.xz`.

Flash a slot from the BMC (slot 4 is `homelab-w-1`), after `xz -d`:

```sh
tpi --host turingpi.local flash -n 4 -i metal-arm64.raw
tpi --host turingpi.local power on -n 4
tpi --host turingpi.local uart -n 4 get
```

A fresh node boots into maintenance mode on a DHCP address, printed on the UART.

## Machine config

- Kubernetes: no kube-proxy (Cilium replaces it and reaches the API through
  KubePrism on `localhost:7445`), no CNI (Cilium is installed separately and
  then adopted by Argo CD), pod CIDR `10.244.0.0/16`, service CIDR
  `10.96.0.0/12`, workloads scheduled on the control planes.
- Metrics: controller-manager and scheduler bind `0.0.0.0`, etcd serves metrics
  on `http://0.0.0.0:2381`, so kube-prometheus-stack can scrape them.
- Sysctls: `kernel.panic=10`, `kernel.panic_on_oops=1`. A kernel oops reboots
  the node instead of hanging it.
- Workload isolation: `SecurityProfileConfig workloadIsolation: false`. Talos
  1.14 turns it on for new clusters. It runs the kubelet and every pod in a
  separate PID and mount namespace, where democratic-csi cannot find the host
  `iscsid` it `nsenter`s into: with `true`, every iSCSI mount fails with
  `failed to find iscsid pid for nsenter` (measured on Talos v1.14.2,
  democratic-csi chart 0.15.1). Generate with
  `WORKLOAD_ISOLATION=true task talos:genconfig` to test the other value, and
  reboot the node after applying a change.

## Cluster secrets (once)

Generate the secrets and seal them before the first `genconfig`:

```sh
(cd talos && talhelper gensecret > talsecret.sops.yaml)
task secrets:seal -- talos/talsecret.sops.yaml
```

Expected: `sealed: talos/talsecret.sops.yaml`. The `.sops.yaml` rule for this
path encrypts every value. Commit the file. Regenerating it later creates a new
cluster identity, which running nodes reject.

## Commands

Install talhelper and talosctl with `task tools`; `talosctl version --client`
must match `talosVersion`. `apply`, `upgrade` and `upgrade-k8s` regenerate the
configs first. `<node>` is a
hostname or IP from the table; without it a task runs on every node in file
order, one at a time, and stops at the first failure.

| Task | Does |
| --- | --- |
| `task talos:genconfig` | Writes `talos/clusterconfig/` (the only task that needs no node) |
| `task talos:apply [-- <node>]` | `talosctl apply-config` to running nodes |
| `task talos:upgrade [-- <node>]` | `talosctl upgrade` to the installer image at `talosVersion` |
| `task talos:upgrade-k8s [-- <node>]` | `talosctl upgrade-k8s --to <kubernetesVersion>` through one control plane (default cp-1) |
| `task talos:etcd-snapshot [-- <ip>]` | Saves `~/homelab-backups/etcd/talos-<utc>.db` (default node cp-3) |

`task talos:genconfig` prints a talhelper warning that `v1.14.2` "might not be
compatible": talhelper 3.1.17 predates Talos 1.14.0. CI validates the output
with talosctl v1.14.2. The last line is
`talos-genconfig: 4 machine config(s) in <repo>/talos/clusterconfig`.

The other tasks print the `talosctl` commands they run, then talosctl's own
output.

A node in maintenance mode has no certificates yet, so the first apply is
`--insecure` to its DHCP address:

```sh
talosctl apply-config --insecure -n <dhcp-ip> -f talos/clusterconfig/homelab-homelab-w-1.yaml
```

The client config is `talos/clusterconfig/talosconfig`. Keep a copy in the
password manager; `genconfig` recreates the same file from the sealed secrets.

## Upgrades

Automated end to end; operating it is in
[talos-cheatsheet.md](talos-cheatsheet.md#talos-and-kubernetes-upgrades).

1. Renovate tracks `talosVersion` (`ghcr.io/siderolabs/talos`; Talos 1.14
   publishes no `installer` image) and `kubernetesVersion`
   (`ghcr.io/siderolabs/kubelet`). The same depNames annotate the versions in
   [`platform/tuppr/upgrades/`](../platform/tuppr/upgrades), so one pull
   request bumps both places; `talos-validate.sh` fails if they differ. Each
   Talos or Kubernetes minor is its own pull request.
2. The `talos-upgrade` CI job rehearses the change: a QEMU cluster (one
   control plane, one worker) at main's versions, with the patches from
   `talos/patches/`, no kube-proxy and Cilium from
   [`ci/helm-releases.yaml`](../ci/helm-releases.yaml); a smoke workload;
   `talosctl upgrade` node by node and `talosctl upgrade-k8s` to the new
   versions; then nodes Ready on them, Cilium OK, the workload answering.
   It is part of `ci`, so a failure blocks the automerge.
3. After the merge, Argo CD syncs the new version into the `TalosUpgrade` or
   `KubernetesUpgrade`, and tuppr rolls it out one node at a time, health
   checks before each node.

`task talos:upgrade` and `task talos:upgrade-k8s` remain for a manual
upgrade with tuppr suspended. Keep `TALOSCTL_VERSION` in
`.github/workflows/ci.yaml` on `talosVersion`: bump it with its sha256 after
Renovate's pull request has merged.

## Drift check

The CronJob `talos-drift` (namespace `system-upgrade`, daily 05:40 UTC,
[`platform/talos-drift/`](../platform/talos-drift)) compares each node's
running machine config with the one `main` renders:

1. It downloads `main` at one commit from GitHub (public, no credentials).
2. It reads every node's config over the Talos API, rebuilds the cluster
   secrets from a control plane's config (`talosctl gen secrets
   --from-controlplane-config`) and runs `scripts/talos-genconfig.sh` with
   them. The age key never enters the cluster.
3. It compares sha256 per node and pushes `talos_config_drift{node}` (1 =
   differs) to the backup-verify Pushgateway.

`TalosConfigDrift` (warning) fires for a node that differs: a merged change
not yet applied with `task talos:apply`, or an apply that did not come from
`main`. `TalosDriftCheckStale` (warning) fires after 2 days without a result.
The configs and the rebuilt secrets stay in a memory-backed volume; the log
shows node names, `matches main` or `DRIFT`, and hash prefixes.

Run it now and read the result:

```sh
kubectl -n system-upgrade create job --from=cronjob/talos-drift talos-drift-manual
kubectl -n system-upgrade logs -f job/talos-drift-manual
kubectl -n system-upgrade delete job talos-drift-manual
```

Expected: one `homelab-<node> (<ip>) matches main (<hash>)` line per node,
then `talos-drift: 0 node(s) differ from main`.

## Validation

The `talos` CI job runs [`scripts/ci/talos-validate.sh`](../scripts/ci/talos-validate.sh)
offline, with throwaway secrets from `talhelper gensecret`:

- `talhelper validate talconfig`, then `genconfig` twice (workload isolation
  off and on).
- `talosctl validate --mode metal` on every generated file.
- Invariants: 3 control planes and 1 worker, the pinned schematic, the VIP only
  on control planes, kube-proxy disabled, no Flannel, the sysctls, the metrics
  addresses, and that `talos/clusterconfig/` and `talosconfig` are git-ignored.

Locally, with talhelper and talosctl on `PATH`:

```sh
scripts/ci/talos-validate.sh
```

Expected: `ok` lines only, the last one `ok  git-ignore rules`, exit 0.

## Why it is like this

- talhelper, not the OpenTofu Talos provider. The provider would keep machine
  secrets in remote state behind an AWS login and still needs talosctl for OS
  upgrades. talhelper reads SOPS natively and builds the installer URL from the
  schematic.
- Kubernetes 1.37, the version Talos 1.14.2 ships. Cilium 1.20, Argo CD 3.5
  and cert-manager 1.21 are tested up to 1.36 only, so the CI test cluster
  runs 1.37 before the nodes do.
- eMMC only, no NVMe. EPHEMERAL stays on the eMMC; revisit once the eMMC
  `life_time` trend gives a reason (Homelab / Nodes dashboard, alerts
  `NodeEmmcWearHigh` and `NodeEmmcEndOfLife`).
- Kubelet image GC from 70% used down to 60% (`patches/kubelet-image-gc.yaml`).
  Images share EPHEMERAL with everything else, so the default start at 85%
  coincides with the default eviction threshold: GC only ran once the node was
  already under DiskPressure and evicting pods.
- The drift check holds an `os:admin` Talos certificate, like tuppr. Machine
  configs are a sensitive resource that `os:reader` and `os:operator` cannot
  read, and a check that compares anything less (derived resources, redacted
  fields) misses changes. It runs in the cluster because GitHub holds no
  cluster credentials ([decisions.md](decisions.md#drift-detection-without-cluster-credentials-in-github)).
- Workload isolation off. iSCSI volumes, including the photo library, must
  mount, and with isolation on they do not. Revisit when democratic-csi can
  reach `iscsid` from inside the sandbox.
- `patches/talosctl/` exists because talhelper vendors a pre-release of the
  Talos 1.14 config library. Move those documents into `talconfig.yaml` once
  talhelper parses them.
