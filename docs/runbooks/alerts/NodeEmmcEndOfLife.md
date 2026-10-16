# NodeEmmcEndOfLife

`critical`, pages. Rule: [`platform/kube-prometheus-stack/routes/alerts.yaml`](../../../platform/kube-prometheus-stack/routes/alerts.yaml).
Shell: [Before you start](README.md#before-you-start). Needs the LAN.

## What it means

The eMMC of `instance` has exceeded its rated wear (`life_time` 11) or nearly
run out of reserved blocks (`pre_eol_info` 3). Writes can fail at any time;
the next symptom is [NodeFilesystemReadOnly](NodeFilesystemReadOnly.md).

## Confirm

```sh
q 'max by (instance, device) (node_emmc_life_time_estimate) >= 11 or max by (instance, device) (node_emmc_pre_eol_info) >= 3'
talosctl -n <ip> read /sys/class/mmc_host/mmc0/mmc0:0001/life_time
```

Expected while it fires: the node, with life time 11 (`0x0b`) or pre-EOL 3.

## Fix

1. A control plane: take an etcd snapshot now (`task talos:etcd-snapshot`).
2. Stop new pods landing there: `kubectl cordon <node>`. Do not drain: the
   CNPG PDBs allow no eviction, and the replacement runbook shuts the node
   down cleanly.
3. Replace the RK1 module in that slot
   ([node-replacement.md](../node-replacement.md)). No spare: keep the node
   cordoned and order one.

## Resolved when

The new module is `Ready`, uncordoned, and reports `life_time` `0x01 0x01`.

## Links

- [NodeEmmcWearHigh](NodeEmmcWearHigh.md)
- [talos-cheatsheet.md: Adding or replacing a node](../../talos-cheatsheet.md#adding-or-replacing-a-node)
