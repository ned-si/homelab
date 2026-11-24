# KubernetesUpgradeFailed

`critical`, pages. Rule: [`platform/kube-prometheus-stack/routes/tuppr-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/tuppr-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

The KubernetesUpgrade is in phase `Failed`, which is terminal until reset.

## Confirm

```sh
kubectl describe kubernetesupgrade kubernetes
kubectl -n system-upgrade logs deploy/tuppr --tail=50
kubectl get nodes -o wide
```

Expected while it fires: `PHASE` `Failed` and a message with the cause.

## Fix

1. Take an etcd snapshot: `task talos:etcd-snapshot`.
2. Fix the cause. A minor cannot be downgraded: fix forward in a pull
   request (the next patch, or the fix).
3. Retry from scratch:
   `kubectl annotate kubernetesupgrade kubernetes tuppr.home-operations.com/reset="$(date)"`.

## Resolved when

`kubectl get kubernetesupgrade kubernetes` shows a phase other than `Failed`; the alert clears.

## Links

- [talos-cheatsheet.md: Talos and Kubernetes upgrades](../../talos-cheatsheet.md#talos-and-kubernetes-upgrades) (watch, pause, recovery)
- [talos-cheatsheet.md: A node won't come back](../../talos-cheatsheet.md#a-node-wont-come-back)
