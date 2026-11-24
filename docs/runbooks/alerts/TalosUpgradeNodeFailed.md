# TalosUpgradeNodeFailed

`critical`, pages. Rule: [`platform/kube-prometheus-stack/routes/tuppr-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/tuppr-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

tuppr marked at least one node as failed and stopped the run. The other
nodes stay on their current version.

## Confirm

```sh
kubectl get talosupgrade,kubernetesupgrade
kubectl describe talosupgrade cluster
kubectl -n system-upgrade get jobs,pods
kubectl -n system-upgrade logs deploy/tuppr --tail=50
kubectl get nodes -o wide
```

Expected while it fires: `status.failedNodes` lists the node.

## Fix

1. Take an etcd snapshot before touching a control plane:
   `task talos:etcd-snapshot`.
2. Find the cause in the Job log and `talosctl -n <ip> dmesg`, and fix it.
   A node that does not come back: the recovery list in
   [talos-cheatsheet.md](../../talos-cheatsheet.md#a-node-wont-come-back).
3. Retry from scratch:
   `kubectl annotate talosupgrade cluster tuppr.home-operations.com/reset="$(date)"`.

## Resolved when

`status.failedNodes` is empty and the run goes on to `Completed`; the alert clears.

## Links

- [talos-cheatsheet.md: Talos and Kubernetes upgrades](../../talos-cheatsheet.md#talos-and-kubernetes-upgrades) (watch, pause, recovery)
- [talos-cheatsheet.md: A node won't come back](../../talos-cheatsheet.md#a-node-wont-come-back)
