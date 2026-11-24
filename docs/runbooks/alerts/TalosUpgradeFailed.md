# TalosUpgradeFailed

`critical`, pages. Rule: [`platform/kube-prometheus-stack/routes/tuppr-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/tuppr-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

The TalosUpgrade is in phase `Failed`, which is terminal: tuppr touches no
other node until it is reset.

## Confirm

```sh
kubectl get talosupgrade,kubernetesupgrade
kubectl describe talosupgrade cluster
kubectl -n system-upgrade get jobs,pods
kubectl -n system-upgrade logs deploy/tuppr --tail=50
kubectl get nodes -o wide
```

Expected while it fires: `PHASE` `Failed` and a message with the cause.

## Fix

1. Take an etcd snapshot before touching a control plane:
   `task talos:etcd-snapshot`.
2. Fix the cause named in `kubectl describe talosupgrade cluster` and the
   tuppr log.
3. Retry from scratch:
   `kubectl annotate talosupgrade cluster tuppr.home-operations.com/reset="$(date)"`.

## Resolved when

`kubectl get talosupgrade cluster` shows a phase other than `Failed`; the alert clears.

## Links

- [talos-cheatsheet.md: Talos and Kubernetes upgrades](../../talos-cheatsheet.md#talos-and-kubernetes-upgrades) (watch, pause, recovery)
- [talos-cheatsheet.md: A node won't come back](../../talos-cheatsheet.md#a-node-wont-come-back)
