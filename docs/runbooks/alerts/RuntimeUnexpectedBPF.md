# RuntimeUnexpectedBPF

`critical`, `category: security`, pages (not in quiet hours). MITRE T1014 (rootkit). Rule: [`platform/kube-prometheus-stack/routes/tetragon-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/tetragon-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

A BPF program or map was loaded outside the allowlist (Tetragon, cilium-agent and runc on the host, which loads the cgroup device filter for every container). BPF can hide processes and traffic.

A Cilium or Tetragon update that runs BPF from a new helper binary or workload name shows up here first.

## Confirm

The alert names the hook, the binary and the namespace/workload (none: a
host process). The event itself, with the parent process and arguments, is
in Tetragon's export (the node is the alert's; events go to stdout):

```sh
kubectl -n tetragon logs -l app.kubernetes.io/name=tetragon -c export-stdout --since=30m --prefix \
  | grep '"policy_name":"bpf-library-policy"' | tail -5
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
