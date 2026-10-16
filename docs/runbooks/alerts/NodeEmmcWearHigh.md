# NodeEmmcWearHigh

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/alerts.yaml`](../../../platform/kube-prometheus-stack/routes/alerts.yaml).
Shell: [Before you start](README.md#before-you-start). Needs the LAN.

## What it means

The eMMC of `instance` reports 80% or more of its rated wear used
(`life_time` step 9) or 80% of its reserved blocks consumed (`pre_eol_info`
2). It is soldered to the RK1 module: plan a module replacement within
months, not days.

## Confirm

```sh
q 'max by (instance, device) (node_emmc_life_time_estimate)'
q 'max by (instance, device) (node_emmc_pre_eol_info)'
talosctl -n <ip> read /sys/class/mmc_host/mmc0/mmc0:0001/life_time
talosctl -n <ip> read /sys/class/mmc_host/mmc0/mmc0:0001/pre_eol_info
```

Expected while it fires: life time 9 or more, or pre-EOL 2.

## Fix

1. Order a replacement Turing RK1 module of the same model.
2. Find what writes most on that node: Homelab / Nodes dashboard, disk
   writes per node. Move a heavy writer to another node if one stands out.
3. When the module arrives, replace it
   ([node-replacement.md](../node-replacement.md)).

## Resolved when

The new module reports `life_time` `0x01 0x01`. The alert clears once the
old one is gone.

## Links

- [NodeEmmcEndOfLife](NodeEmmcEndOfLife.md)
