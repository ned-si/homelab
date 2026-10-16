# LANDeviceUnreachable

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/lan-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/lan-alerts.yaml).
Shell: [Before you start](README.md#before-you-start). Needs the LAN.

## What it means

`device` (`router` at `192.168.1.1`, or `bmc`, the Turing Pi 2 BMC) has not
answered a ping from the cluster for 10 minutes. Without the router the
cluster has no internet, so this page may only arrive once it is back. Without
the BMC a hung node cannot be power-cycled remotely.

## Confirm

```sh
q 'probe_success{job="blackbox-lan"}'
ping -c3 192.168.1.1
ping -c3 turingpi.local
```

Expected while it fires: the device at `0`. The probe's address for `bmc` is
in [`platform/blackbox-exporter/probes/lan.yaml`](../../../platform/blackbox-exporter/probes/lan.yaml).

## Fix

- Router: if the house has no internet, power-cycle the router (physical:
  its power switch, 30 seconds off). Port forwards and DHCP survive a reboot;
  check them afterwards ([wan-ip-change.md](../wan-ip-change.md#4-check-the-router)).
- BMC answers on `turingpi.local` from the Mac but not on the probed
  address: its DHCP lease moved. Put the new address
  (`ping -c1 turingpi.local`) in `probes/lan.yaml` in a pull request.
- BMC does not answer at all: the nodes keep running without it. Do not cut
  the Turing Pi's power to recover it: that powers off all four nodes. If it
  must be restarted, do it as a planned cold start
  ([cold-start.md: Planned shutdown](../cold-start.md#planned-shutdown)).

## Resolved when

`q 'probe_success{job="blackbox-lan", device="<device>"}'` returns `1`; the
alert clears.

## Links

- [node-power-cycle.md: BMC and slots](../node-power-cycle.md#bmc-and-slots)
- [networking.md](../../networking.md)
