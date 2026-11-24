# KubernetesUpgradeStuck

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/tuppr-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/tuppr-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

A tuppr Kubernetes upgrade (`talosctl upgrade-k8s`) is broken. With
`reason` `job-hung`, it has been in phase Upgrading for 45 minutes. With
`job-failed`, a pod of a KubernetesUpgrade Job failed in the last 15
minutes. A run waiting on its health checks does not fire this alert.

## Confirm

```sh
kubectl get kubernetesupgrade kubernetes
kubectl -n system-upgrade get jobs,pods
kubectl -n system-upgrade logs deploy/tuppr --tail=50
kubectl get nodes -o wide
```

Expected while it fires: `PHASE` `Upgrading`, or a failed Job.

## Fix

1. Take an etcd snapshot: `task talos:etcd-snapshot`.
2. Read the Job log (`kubectl -n system-upgrade logs job/<job_name>`) and
   fix its cause; delete a failed Job so tuppr retries.
3. A minor cannot be downgraded: fix forward in a pull request.

## Resolved when

`kubectl get kubernetesupgrade kubernetes` shows `Completed`; the alert clears.

## Links

- [talos-cheatsheet.md: Talos and Kubernetes upgrades](../../talos-cheatsheet.md#talos-and-kubernetes-upgrades) (watch, pause, recovery)
- [talos-cheatsheet.md: A node won't come back](../../talos-cheatsheet.md#a-node-wont-come-back)
