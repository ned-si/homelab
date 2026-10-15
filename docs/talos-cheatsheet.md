# Talos cheatsheet

A crash course for operating the Talos nodes, and the commands to keep at hand.
The tree, the patches and the CI checks are in [talos.md](talos.md); versions
are the ones pinned in [`talos/talconfig.yaml`](../talos/talconfig.yaml).

## 1. What Talos is

- An immutable Linux built only to run Kubernetes. No SSH, no shell, no package
  manager. The root filesystem is a read-only image.
- One machine config (YAML) per node is the whole OS state: network, disks,
  kubelet, control plane, sysctls, extensions. Change the file, apply it, done.
  Nothing else on the node is configurable.
- Everything goes through `talosctl`, a client for the Talos API on port
  `50000`, authenticated with mutual TLS. The client certificate and the CA
  are in `talosconfig`.
- Upgrades write the new image to the inactive of two system slots (A/B) and
  boot it. If it fails to boot, the node falls back to the previous slot;
  `talosctl rollback` does the same by hand.
- Extra binaries come as system extensions, baked into the image by the
  [Image Factory](https://factory.talos.dev) from a schematic. Here: the RK1
  board overlay and `siderolabs/iscsi-tools` (for democratic-csi), in
  `talconfig.yaml` under `controlPlane.schematic`.

## 2. How this cluster is set up

| Hostname | IP | Role | BMC slot |
| --- | --- | --- | --- |
| `homelab-cp-1` | `192.168.1.247` | control plane | 1 |
| `homelab-cp-2` | `192.168.1.238` | control plane | 2 |
| `homelab-cp-3` | `192.168.1.239` | control plane | 3 |
| `homelab-w-1` | `192.168.1.240` | worker | 4 |

- Turing RK1 modules on a Turing Pi 2, eMMC only (`/dev/mmcblk0`), no NVMe.
  A node is installed by flashing the Factory disk image through the BMC
  (`tpi flash`, [talos.md](talos.md#image)); the flashed image is the install.
- talhelper renders one machine config per node from `talconfig.yaml`, the
  files in `talos/patches/`, and the cluster CAs and keys in
  `talos/talsecret.sops.yaml` (SOPS). `task talos:genconfig` writes them to
  `talos/clusterconfig/`, which is git-ignored: those files and `talosconfig`
  hold the keys in plaintext. Regenerate them any time from the sealed
  secrets; keep a copy of `talosconfig` in the password manager (Bitwarden)
  and in `~/homelab-backups/talos/` (mode 700).
- The API VIP `192.168.1.11` is held by Talos itself on the control planes
  (`vip:` in `talconfig.yaml`). There is no kube-vip. `talosctl` talks to the
  node IPs, never the VIP.
- Cilium is the CNI and replaces kube-proxy (`cniConfig: none`,
  `patches/kube-proxy.yaml`). It is installed once with Helm and then adopted
  by Argo CD ([bootstrap.md](bootstrap.md)).
- `workloadIsolation: false` (`patches/talosctl/security-profile.yaml`). With
  isolation on, the kubelet and pods run in their own PID and mount
  namespaces, and democratic-csi cannot find the host `iscsid` it `nsenter`s
  into: every iSCSI mount fails.
- Split of ownership: Talos owns the OS, kubelet, etcd and the control plane
  static pods. Argo CD owns everything above that, from git.

Point `talosctl` at the generated client config from the repository root.
Its endpoints are the three control planes and it has no default node, so
every command takes `-n <ip>`:

```sh
task talos:genconfig
export TALOSCONFIG="$PWD/talos/clusterconfig/talosconfig"
talosctl -n 192.168.1.239 version
```

Expected: a `Client` and a `Server` block, both on `talosVersion`.

## 3. Day-2 management

### Config changes

1. Edit `talos/talconfig.yaml` or a file in `talos/patches/`, open a PR. The
   `talos` CI job renders and validates every node's config
   ([talos.md](talos.md#validation)).
2. After the merge, from an up-to-date `main`:
   `task talos:apply -- <node>` (one node), or without `-- <node>` for every
   node in turn. It regenerates the configs and runs `talosctl apply-config`
   in mode `auto`.
3. Check the node: `talosctl -n <ip> health` or `services`.

For another apply mode, run talosctl directly. Preview first with
`--dry-run`, which prints the diff and whether a reboot is needed:

```sh
talosctl -n 192.168.1.240 apply-config -f talos/clusterconfig/homelab-homelab-w-1.yaml --dry-run
talosctl -n 192.168.1.240 apply-config -f talos/clusterconfig/homelab-homelab-w-1.yaml --mode try
```

| `--mode` | Effect |
| --- | --- |
| `auto` (default) | Applies live, reboots only if the change needs it |
| `no-reboot` | Applies live; fails if the change needs a reboot |
| `staged` | Stores the config for the next boot; follow with `talosctl reboot` |
| `try` | Applies live and reverts after `--timeout` (default 1m) unless re-applied |

### Talos and Kubernetes upgrades

- Renovate opens a PR when `talosVersion` or `kubernetesVersion` in
  `talconfig.yaml` moves; it automerges on green CI. CI validates the
  rendered configs; it does not boot Talos.
- A merge changes no node. Run `task talos:upgrade` (one node at a time, A/B
  fallback on a failed boot) or `task talos:upgrade-k8s` (rolls the control
  plane and kubelets through cp-1). Both take `-- <node>`.
- Planned, not built: tuppr in the cluster, so a merge triggers the upgrade
  with health checks and stops on failure.

### etcd snapshots

```sh
task talos:etcd-snapshot            # cp-3 by default; -- <control-plane-ip> for another
```

Expected: an `ls -l` line for `~/homelab-backups/etcd/talos-<utc>.db`.
Restoring is `talosctl -n <cp-ip> bootstrap --recover-from <file>` on a
control plane that is reset and has no etcd data.

### Adding or replacing a node

Nodes are stateless: volumes are iSCSI and NFS on the NAS. A new node first
needs an entry in `nodes:` in `talconfig.yaml` (PR, merge, `task talos:genconfig`).
To replace one:

1. Control plane only: `talosctl -n <healthy-cp-ip> etcd members`, then
   `talosctl -n <healthy-cp-ip> etcd remove-member <member-id>` for the dead
   one. Then `kubectl delete node <hostname>`.
2. Flash, power on and read the UART ([talos.md](talos.md#image)). The node
   boots into maintenance mode on a DHCP address.
3. `talosctl apply-config --insecure -n <dhcp-ip> -f talos/clusterconfig/homelab-<hostname>.yaml`.
   It moves to its static IP (usually without a reboot) and joins; a control
   plane shows up in `etcd members` within about two minutes.

## 4. Troubleshooting

`<ip>` is a node IP from the table; etcd commands need a control plane.

| Command | Shows | Healthy looks like |
| --- | --- | --- |
| `talosctl -n 192.168.1.239 health` | Cluster-wide checks: etcd, API, nodes, control plane | Every check ends `OK` |
| `talosctl -n <ip> dashboard` | Live CPU, memory, logs, network (`q` quits) | |
| `talosctl -n <ip> dmesg` | Kernel log (`-f` follows) | No oops, iSCSI or eMMC errors |
| `talosctl -n <ip> logs kubelet` | One service's log; also `etcd`, `containerd` (`-f`, `--tail 100`) | |
| `talosctl -n <ip> services` | Talos services and their state | All `Running` / `OK` |
| `talosctl -n <ip> get members` | Nodes this node knows about | 4 rows |
| `talosctl -n <cp-ip> etcd members` | etcd membership | 3 members |
| `talosctl -n <cp-ip> etcd status` | Leader, DB size, errors per member | One leader, no errors |
| `talosctl -n <ip> containers -k` | Kubernetes containers on the node | |
| `talosctl -n <ip> logs -k <container-id>` | A Kubernetes container's log, when the API is down | |
| `talosctl -n <ip> get addresses` | IPs; also `links`, `routes` | Node IP on the NIC, `.11` on one control plane |
| `talosctl -n <ip> read /proc/mounts` | Any file; `ls <dir>` lists a directory | |
| `talosctl -n <ip> read /sys/class/mmc_host/mmc0/mmc0:0001/life_time` | eMMC wear | `0x01 0x01` (low) |
| `talosctl -n <ip> get machineconfig -o yaml` | The config the node runs. Holds secrets: never paste it | |
| `talosctl -n <ip> support --no-encryption -O support.zip` | Logs and state in one archive. Without `--no-encryption` only Sidero Labs can open it | |
| `talosctl -n <ip> reboot` | Reboot; `--drain` evicts pods first | Back in `services` within minutes |
| `talosctl -n <ip> reset --reboot --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL` | Leaves etcd, wipes config and data, reboots into maintenance mode | Without the labels it wipes the whole eMMC, boot partitions included: flash the node again |

Outside the API:

- Serial console: `tpi --host turingpi.local uart -n <slot> get | tail -60`.
  Shows boot progress, kernel panics, and the DHCP address in maintenance
  mode.
- Maintenance mode is a node with no config: it waits on DHCP for
  `apply-config --insecure`. `talosctl -n <dhcp-ip> get disks --insecure`
  works there; nothing else does.
- A frozen module: power-cycle it from the BMC,
  [runbooks/node-power-cycle.md](runbooks/node-power-cycle.md) steps 2 and 3.

### A node won't come back

1. `ping <ip>` answers: the OS is up. `talosctl -n <ip> services` and
   `dmesg`; read the failing service's `logs`.
2. No ping, `talosctl` times out: read the UART before anything else.
3. UART shows a kernel oops or stops mid-boot: power-cycle the slot.
4. UART shows maintenance mode on a DHCP address: the config is gone. Apply
   it with `--insecure` (section 3).
5. It broke right after `task talos:upgrade`: wait for the A/B fallback to
   boot the old image, or `talosctl -n <ip> rollback` if it is reachable.
6. Still dead after a power-cycle: replace it (section 3, reflash and apply).
