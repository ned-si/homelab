# Replace a node

Reflash one node and join it back: a failed module, a broken install, or a
planned reinstall. The other three nodes keep running throughout. Nodes hold
no data (volumes are iSCSI and NFS on the NAS), so a node is its Talos
machine config plus a flashed image. Command reference:
[talos-cheatsheet.md](../talos-cheatsheet.md).

- Time: about 45 minutes, most of it flashing.
- You need: the Mac with this repository and `kubeconfig-homelab`, `talosctl`
  and `talhelper` (`task tools`), the SOPS age key (to render the machine
  configs), and the Turing Pi 2 BMC (`tpi` CLI or web UI).
- Replace one node at a time. With one control plane gone, etcd keeps quorum
  on the other two; with two gone, it has none
  ([cold-start.md](cold-start.md#restore)).

## Facts this runbook relies on

| Thing | Fact |
| --- | --- |
| Nodes | `homelab-cp-1` `192.168.1.247` (BMC slot 1), `homelab-cp-2` `.238` (slot 2), `homelab-cp-3` `.239` (slot 3): control planes with etcd, schedulable. `homelab-w-1` `.240` (slot 4): worker. The hostname is the node name and the etcd member name. |
| Config | Every node is an entry under `nodes:` in [`talos/talconfig.yaml`](../../talos/talconfig.yaml): static address on the physical NIC, install disk `/dev/mmcblk0`, the VIP `.11` on the control planes. `task talos:genconfig` renders `talos/clusterconfig/homelab-<hostname>.yaml`. |
| Image | The Image Factory disk image for the schematic in `talconfig.yaml` (RK1 overlay, `iscsi-tools`, `tailscale`), flashed to the eMMC by the BMC ([talos.md](../talos.md#image)). The flashed image is the install. |
| Hardware | Turing RK1 in a Turing Pi 2 slot. The 29 GB eMMC is on the module: a failed eMMC means a new module. |
| iSCSI | Each node has its own initiator name (`iqn.2017-11.dev.talos:...`), generated on first boot. |

## Step 0: terminal

One bash shell for the whole runbook. Set the node being replaced:

```sh
/bin/bash
cd ~/repos/homelab
export KUBECONFIG="$PWD/kubeconfig-homelab"
task talos:genconfig
export TALOSCONFIG="$PWD/talos/clusterconfig/talosconfig"
N=homelab-cp-3 IP=192.168.1.239 SLOT=3 ROLE=control-plane   # or: N=homelab-w-1 IP=192.168.1.240 SLOT=4 ROLE=worker
OK=192.168.1.238                                             # a healthy control plane, not $IP
talosctl -n "$OK" etcd members
```

Expected: the last `genconfig` line
`talos-genconfig: 4 machine config(s) in <repo>/talos/clusterconfig`, then a
table with three members named `homelab-cp-1`..`3` (the one being replaced
may be missing if it already failed). Note the `ID` of `$N`.

## Step 1: back up

Take an etcd snapshot from a healthy control plane:

```sh
task talos:etcd-snapshot -- "$OK"
```

Expected: an `ls -l` line for `~/homelab-backups/etcd/talos-<utc>.db`. For a
control plane, also take the database dumps of
[cold-start.md step 9](cold-start.md#step-9-take-a-backup).

## Step 2: remove the old node

If the node still runs, drain it and shut it down (bounded; single-instance
databases move to another node with their volume):

```sh
kubectl drain "$N" --ignore-daemonsets --delete-emptydir-data --timeout=15m
talosctl -n "$IP" shutdown
```

Expected: `node/<name> drained`, then the node goes off the network. A dead
node cannot be drained; power its slot off instead:

```sh
tpi --host turingpi.local power -n "$SLOT" off
```

Control plane only: remove its etcd member, by the `ID` from step 0:

```sh
talosctl -n "$OK" etcd remove-member <member-id>
talosctl -n "$OK" etcd members
```

Expected: `etcd members` lists two members. Do not remove a second member.

```sh
kubectl delete node "$N"
```

Expected: `node "<name>" deleted`. Pods that ran there are recreated on the
other nodes within a few minutes. A pod stuck in `ContainerCreating` with
`Multi-Attach error` holds an iSCSI volume still attached to the old node:
`kubectl get volumeattachment | grep "$N"`, then
`kubectl delete volumeattachment <name>` for each.

## Step 3: flash

Download the disk image for the pinned schematic and Talos version, and flash
the slot:

```sh
URL=$(cd talos && talhelper genurl image --offline-mode -n "$N")
echo "$URL"
curl -fL -m 900 -o /tmp/metal-arm64.raw.xz "$URL" && xz -df /tmp/metal-arm64.raw.xz
tpi --host turingpi.local flash -n "$SLOT" -i /tmp/metal-arm64.raw
tpi --host turingpi.local power -n "$SLOT" on
```

Expected: a `factory.talos.dev/image/<schematic>/<talosVersion>/metal-arm64.raw.xz`
URL, then `tpi` reports the flash and its verification done (about 10
minutes). Keep the shell open: `tpi flash` stops if the session dies.

A minute after power-on, read the serial console:

```sh
tpi --host turingpi.local uart -n "$SLOT" get | tail -40
```

Expected: Talos in maintenance mode, printing the DHCP address it took from
the router's pool (`.50`-`.199`). Call it `<dhcp-ip>`.

## Step 4: apply the machine config

A node in maintenance mode has no certificates yet, so the first apply is
`--insecure`:

```sh
talosctl -n <dhcp-ip> get disks --insecure
talosctl apply-config --insecure -n <dhcp-ip> -f "talos/clusterconfig/homelab-$N.yaml"
```

Expected: `mmcblk0` in the disk list, then `apply-config` exits 0. The node
moves to `$IP` and joins; a control plane joins etcd by itself. If it stays
on the DHCP address, read the UART again.

TrueNAS: if iSCSI initiator group 1 (Shares, Block (iSCSI), Initiators Groups)
lists initiator names instead of allowing all initiators, add the new node's
name from `talosctl -n "$IP" read /etc/iscsi/initiatorname.iscsi`. Otherwise
volumes cannot attach on this node.

## Step 5: check

Wait 3 minutes, then:

```sh
kubectl get node "$N" -o wide
kubectl get pods -A -o wide --field-selector spec.nodeName="$N"
talosctl -n "$IP" services
talosctl -n "$OK" etcd members
talosctl -n "$OK" health
```

Expected:

- the node `Ready`, the same version as the others, `INTERNAL-IP` equal to
  `$IP`, `OS-IMAGE` `Talos (<talosVersion>)`;
- `cilium`, `cilium-envoy`, `iscsi-democratic-csi-node` and the node exporter
  `Running` on it (plus `kube-apiserver`, `kube-controller-manager` and
  `kube-scheduler` on a control plane);
- every service `Running`, health `OK` (`etcd` only on a control plane);
- three etcd members (control plane);
- every `health` check ending `OK`.

Then recreate the smoke suite's `node-macs.txt` (a new module has a new MAC)
and run the suite, both as in
[cold-start.md step 8](cold-start.md#step-8-smoke-suite). Expected:
`{"green":true,"failing":[]}`.

## Rollback

There is no previous state to return to: the old install is gone after step 3.
If the new node cannot join, leave it out (power its slot off, no etcd member
for it) and run on three nodes, two control planes with quorum. Replacing a
second control plane before the first is back leaves etcd without quorum.
