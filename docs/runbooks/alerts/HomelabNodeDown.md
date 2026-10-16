# HomelabNodeDown

`critical`, pages. Rule: [`platform/kube-prometheus-stack/routes/outage-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/outage-alerts.yaml).
Shell: [Before you start](README.md#before-you-start). Needs the LAN.

## What it means

Node `node` has not been Ready for 15 minutes and did not come back on its
own (a Talos upgrade reboot takes about 5). Its pods and iSCSI volumes are
down until it returns or the pods move.

| Node | IP | BMC slot |
| --- | --- | --- |
| `homelab-cp-1` | `192.168.1.247` | 1 |
| `homelab-cp-2` | `192.168.1.238` | 2 |
| `homelab-cp-3` | `192.168.1.239` | 3 |
| `homelab-w-1` | `192.168.1.240` | 4 |

## Confirm

```sh
kubectl get nodes
ping -c3 <ip>
talosctl -n <ip> version
```

Expected while it fires: the node `NotReady`. Whether ping and `talosctl`
answer decides the next step.

## Fix

1. It answers: the OS is up. `talosctl -n <ip> services` and
   `talosctl -n <ip> dmesg | tail -50`; read the log of the failing service
   (`talosctl -n <ip> logs kubelet`).
2. No answer: read the serial console, then power-cycle the slot from the
   BMC ([node-power-cycle.md](../node-power-cycle.md) steps 2 to 4). That is a
   physical-world action through the BMC; if the BMC does not answer either,
   see [LANDeviceUnreachable](LANDeviceUnreachable.md).
3. It broke right after an upgrade: suspend tuppr and let the A/B fallback
   boot the old image ([talos-cheatsheet.md](../../talos-cheatsheet.md#a-node-wont-come-back)).
4. Still dead after a power-cycle: replace the module
   ([node-replacement.md](../node-replacement.md)).

A control plane down leaves etcd on 2 of 3 members: do not touch a second
control plane until this one is back.

## Resolved when

`kubectl get nodes` shows four `Ready`, and
`talosctl -n 192.168.1.239 etcd members` lists three. The alert clears at once.

## Links

- [talos-cheatsheet.md: Troubleshooting](../../talos-cheatsheet.md#4-troubleshooting)
- [cold-start.md](../cold-start.md) when more than one node is down
