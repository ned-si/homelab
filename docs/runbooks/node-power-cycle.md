# Power-cycle a node

Hard-reset one RK1 module from the Turing Pi 2 BMC when the node is gone: no
ping, no answer from `talosctl`, `NotReady` in `kubectl get nodes`. Talos sets
`kernel.panic_on_oops=1` and `kernel.panic=10`
([talos.md](../talos.md#machine-config)), so a kernel oops reboots the node by
itself; a module that hangs without a panic stays down until it is
power-cycled.

- Time: 10 minutes.
- You need: the BMC login (kept by the owner, not in this repository) and the
  `tpi` CLI on the Mac, from the
  [tpi releases](https://github.com/turing-machines/tpi/releases). The BMC web
  UI can power slots but is not needed.
- Precondition: the other two control planes are up (etcd keeps quorum while
  one member is reset).

## BMC and slots

The BMC (firmware 2.0.5) answers at `https://turingpi.local`. Its address
comes from the router's DHCP pool, so use the mDNS name. Slots are numbered 1
to 4:

| BMC slot | Node | Address |
| --- | --- | --- |
| Node 1 | `homelab-cp-1` | `192.168.1.247` |
| Node 2 | `homelab-cp-2` | `192.168.1.238` |
| Node 3 | `homelab-cp-3` | `192.168.1.239` |
| Node 4 | `homelab-w-1` | `192.168.1.240` |

The serial console prints the node's hostname and address in its Talos boot
messages; read it to confirm the mapping before resetting anything.

## 1. Confirm which node is down

```sh
cd ~/repos/homelab
export KUBECONFIG="$PWD/kubeconfig-homelab"
export TALOSCONFIG="$PWD/talos/clusterconfig/talosconfig"   # from task talos:genconfig
kubectl get nodes
for h in 192.168.1.247 192.168.1.238 192.168.1.239 192.168.1.240; do
  printf '%-15s ' "$h"; ping -c1 -W2000 "$h" >/dev/null 2>&1 && echo up || echo DOWN
done
```

Expected: one node `NotReady` and its address `DOWN`. If it answers ping or
`talosctl -n <ip> version`, do not reset it; read
`talosctl -n <ip> services` and `talosctl -n <ip> dmesg` instead
([talos-cheatsheet.md](../talos-cheatsheet.md#4-troubleshooting)).

## 2. Read the serial console

The console holds the last kernel messages, the only record of a hang: Talos
keeps its logs in memory, so they are gone after the reset.

```sh
tpi --host turingpi.local uart -n 3 get | tail -60
```

Copy anything after the last normal line (`Unable to handle kernel ...`, a call
trace) before resetting: the reset clears the buffer.

## 3. Reset the slot

```sh
tpi --host turingpi.local power -n 3 off
sleep 10
tpi --host turingpi.local power -n 3 on
tpi --host turingpi.local power status
```

Expected: `node3: on`. `tpi` asks for the BMC login once and caches a token.
In the web UI (`https://turingpi.local`, Nodes) the same is the slot's power
switch: off, 10 seconds, on.

## 4. Verify

Wait 3 minutes, then:

```sh
kubectl get nodes
kubectl get pods -A --no-headers | grep -Ev 'Running|Completed' || echo "all pods Running"
```

Expected: four nodes `Ready` and `all pods Running` within about 10 minutes,
then the etcd check of
[cold-start.md step 3](cold-start.md#step-3-nodes) shows three healthy
members. Pods that were on the node are recreated elsewhere while it was down;
those stuck in `ContainerCreating` with a `Multi-Attach` event clear once the
reset node releases its iSCSI volumes. If the node does not come back, follow
[node-replacement.md](node-replacement.md).

After it is back, the UART capture from step 2 is the record of why it died.
The current boot's kernel log shows what the reset left behind (eMMC or iSCSI
errors, for example):

```sh
talosctl -n 192.168.1.239 dmesg | grep -Ei 'error|fail|oops|mmc' | tail -40
```
