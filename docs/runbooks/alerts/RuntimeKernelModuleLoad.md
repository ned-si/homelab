# RuntimeKernelModuleLoad

`critical`, `category: security`, pages (not in quiet hours). MITRE T1547.006 (kernel modules). Rule: [`platform/kube-prometheus-stack/routes/tetragon-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/tetragon-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

A kernel module was loaded from a file (`finit_module`, as `insmod` does) outside the allowlist (the democratic-csi iSCSI node plugin and cilium-agent). Autoload requests by the kernel (a socket of an unloaded family) never page; they are on the Security dashboard. Loads on a node in its first 15 minutes after boot do not page (`tetragon:node_booted_recently`): udev, the kernel and the starting control plane request modules then, on every reboot and Talos upgrade. A rootkit loads as a module; one loaded in that window shows on the Security dashboard but does not page.

A node that just rebooted may load a module late (a new NIC driver after a Talos upgrade): that is a host process with a Talos binary.

## Confirm

The alert names the hook, the binary and the namespace/workload (none: a
host process). The event itself, with the parent process and arguments, is
in Tetragon's export (the node is the alert's; events go to stdout):

```sh
kubectl -n tetragon logs -l app.kubernetes.io/name=tetragon -c export-stdout --since=30m --prefix \
  | grep '"policy_name":"monitor-kernel-modules"' | tail -5
```

Read `process.binary`, `process.arguments`, `parent.binary` and
`process.pod` (absent for a host process).

## Fix

- Known-good (a new image version doing what its predecessor did not, a new
  workload with a documented need): add one `unless` line for its
  namespace/workload (or host binary) to the alert in the rule file, with a
  promtool case in `tests/prometheus/tetragon_test.yaml` (PR). Never a manual
  silence, never an edited upstream policy.
- Not explained: treat the node as compromised. Cordon it
  (`kubectl cordon <node>`), keep the pod for evidence (do not delete it: scale
  its workload to 0 only after copying the export lines above), rotate the
  secrets mounted in that namespace, and rebuild the node from its Talos
  config (`talosctl reset` then re-join) before uncordoning.
