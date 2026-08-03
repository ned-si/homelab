# Migrating to Talos Linux

**Assessment, not a plan of record.** Talos is now supported on the Turing RK1 and
would be a genuine improvement. It is also a rebuild, not a migration, and this
document exists so that decision is made with the costs visible.

## Why it is attractive

The current nodes are Ubuntu + kubeadm, which means:

- an OS with a package manager, SSH, and mutable state on every node
- upgrades are a procedural Ansible playbook (`ansible/os-upgrade.yml`) that
  drains, patches, reboots and hopes
- swap has to be actively suppressed after kernel upgrades, because a package can
  re-enable it and the kubelet then refuses to start
- `--node-ip` has to be hand-set in a systemd drop-in, and getting it wrong
  produces ARP problems that look like random pod networking failures
- node configuration is **not in this repository** — it lives in netplan and
  systemd files on four machines

Talos replaces all of that with an immutable, API-driven OS. There is no SSH, no
shell, no package manager. Configuration is a YAML document; upgrading is an API
call that A/B-swaps the system partition and rolls back on failure.

Concretely, it would delete `ansible/os-upgrade.yml` and most of
`ansible/kube-upgrade.yml`, and move node config into git — which is the one
remaining part of this homelab that is not declarative.

## What makes it a rebuild rather than a migration

Talos cannot be installed over a running Ubuntu node in place. The realistic
sequence is: wipe a node, install Talos, join it, repeat. With four nodes and one
of them a worker, there is no comfortable margin.

### The blockers, in order of severity

**1. democratic-csi and iSCSI — this is the real one.**

The iSCSI CSI driver needs `iscsid` and `multipathd` running on the host, plus
kernel modules. On Ubuntu those are packages. On Talos there is no package
manager: `iscsi-tools` is a
[system extension](https://github.com/siderolabs/extensions) baked into the boot
image at build time.

So this is not "install a package" — it means producing a custom Talos installer
image with the `iscsi-tools` and `util-linux-tools` extensions for arm64, via
Image Factory or `imager`. That is well-trodden, but it is a build step that has
to be repeated for every Talos upgrade, and it must exist *before* the first node
is wiped, because without it no PVC will attach.

**2. NFS mounts.** The media library uses in-tree NFS PVs. Talos supports NFS,
but `nfs-utils` is likewise an extension. Same build, same constraint.

**3. Everything kubeadm-specific goes away.** `bootstrap/` assumes a kubeadm
cluster. `kubeadm upgrade` and the etcd snapshot step become meaningless. The
`ansible/` directory largely stops applying. Not hard, but it is real work in this
repo, not just on the nodes.

**4. Cilium install method changes.** Talos ships without kube-proxy if you tell
it to, which suits Cilium's kube-proxy replacement well — but `k8sServiceHost`
handling and the CNI bootstrap differ, and the Talos config has to disable the
default CNI explicitly.

**5. No SSH means a different debugging posture.** `talosctl` covers logs, dmesg,
service state and packet capture, which is genuinely enough. But the habit of
"ssh in and poke" is gone, and the first time something fails to boot you will
want to have practised.

## What would NOT be affected

Worth stating, because it is most of the value in this repository:

- every manifest under `clusters/`, `infrastructure/`, `platform/`, `apps/`
- the Argo CD hierarchy
- SOPS/age secrets
- Gateway API, Cilium configuration, cert-manager, external-dns
- all backups — CNPG and restic are cluster-agnostic
- Renovate, CI

The workload layer is portable. That was worth building regardless.

## A realistic sequence

Only attempt this when the cluster is **not** the thing you depend on that week.

### Phase 0 — prepare, changes nothing

1. Build an arm64 Talos installer with the needed extensions:
   `siderolabs/iscsi-tools`, `siderolabs/util-linux-tools`, and the RK1 overlay
   (`siderolabs/sbc-rockchip`). Use Image Factory and record the resulting schematic
   ID in this repo.
2. Write `talos/` machine configs (controlplane + worker) and commit them. This is
   the part that moves node config into git.
3. **Verify backups restore.** Run `task` on the backup verification jobs and read
   the output. This is the safety net for the whole exercise.
4. Practise on something that is not the homelab — a VM, or one node detached from
   the cluster.

### Phase 1 — the worker, as a rehearsal

`homelab-w-1` holds no control-plane state, so it is the cheap experiment.

1. `kubectl drain homelab-w-1 --ignore-daemonsets --delete-emptydir-data`
2. `kubectl delete node homelab-w-1`
3. Flash Talos, apply the worker config, join it.
4. Verify: does a pod schedule, does an **iSCSI PVC attach**, does the NFS mount
   work?

Step 4 is the whole point of the rehearsal. If iSCSI does not attach, stop — the
extension image is wrong, and finding that out now costs one worker rather than
the cluster.

If it fails and cannot be fixed quickly, reinstall Ubuntu on that node and
rejoin. Nothing else has changed.

### Phase 2 — control plane, one at a time

With three control-plane nodes, etcd tolerates losing one. Never two.

For each, in turn: drain, remove from the cluster, flash Talos, join as a
control-plane node, **wait for etcd to report three healthy members** before
touching the next.

```sh
talosctl -n <node> etcd members
```

Do not proceed on a two-member etcd. That is a single failure away from losing
quorum and the cluster with it.

### Phase 3 — cleanup

Delete `ansible/os-upgrade.yml`, gut `kube-upgrade.yml`, rewrite `bootstrap/` for
Talos, update `docs/bootstrap.md`.

## The honest recommendation

**Not now, and not as part of the current work.**

Reasons:

1. You are about to move house. Doing an OS migration and a physical relocation in
   the same window means that when something breaks you will not know which change
   caused it.
2. The current restructure is unverified against a real cluster. Get *this*
   working, running and backed up first. Talos changes the floor, not the ceiling.
3. The iSCSI extension image is the genuine unknown. It deserves a rehearsal on a
   VM before it is on the critical path.

**A reasonable trigger to revisit:** after the move, once the cluster has been
stable for a month and a backup restore has been verified at the new location.
Then do Phase 0 and Phase 1 (the worker) as a contained experiment, and decide
based on how that goes rather than on how appealing it sounds.

The thing that makes this defensible to defer is that the Ansible playbooks now
make Ubuntu upgrades a single command. The pain Talos removes is real but it is
no longer acute.

## Reading

- [Talos on Turing RK1](https://www.talos.dev/latest/talos-guides/install/single-board-computers/turing_rk1/)
- [System extensions](https://www.talos.dev/latest/talos-guides/configuration/system-extensions/)
- [Image Factory](https://factory.talos.dev/)
- [iscsi-tools extension](https://github.com/siderolabs/extensions/tree/main/storage/iscsi-tools)
- [Cilium on Talos](https://www.talos.dev/latest/kubernetes-guides/network/deploying-cilium/)
