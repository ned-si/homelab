# TalosUpgradeStuck

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/tuppr-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/tuppr-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

A tuppr Talos upgrade is broken partway through. The `reason` label says how:

- `node-mid-upgrade`: a node has been cordoned or NotReady for 30 minutes
  and does not run the target version.
- `job-failed`: a pod of a TalosUpgrade Job failed in the last 15 minutes
  (tuppr retries the Job, or the Job gave up).
- `old-version-after-reboot`: a node booted in the last hour and still runs
  the old version (Talos A/B fallback).
- `job-hung`: the run has been in Upgrading, Rebooting or Draining for
  45 minutes, past its 30 minute policy timeout.

A run waiting on its health checks (phase `HealthChecking`: an app not
Healthy, a node NotReady) does not fire this alert. The unhealthy thing has
its own alert, and the wait shows on the Homelab / Automation timeline.

## Confirm

```sh
kubectl get talosupgrade,kubernetesupgrade
kubectl describe talosupgrade cluster
kubectl -n system-upgrade get jobs,pods
kubectl -n system-upgrade logs deploy/tuppr --tail=50
kubectl get nodes -o wide
```

Expected while it fires: `PHASE` not `Completed`, and the node named in the
alert off the target in `OS-IMAGE`, cordoned, or with a failed Job.

## Fix

1. Take an etcd snapshot before touching a control plane:
   `task talos:etcd-snapshot`.
2. `job-failed` or `job-hung`: read the Job's log
   (`kubectl -n system-upgrade logs job/<job_name>`). An installer pull
   error or a Talos API error is fixed at its source; delete the failed Job
   (`kubectl -n system-upgrade delete job <job_name>`) and tuppr retries.
3. `node-mid-upgrade`: `talosctl -n <ip> services` and `dmesg`. A node that
   finished its upgrade but stayed cordoned: `kubectl uncordon <node>`.
   A node that does not come back: the recovery list in
   [talos-cheatsheet.md](../../talos-cheatsheet.md#a-node-wont-come-back).
4. `old-version-after-reboot`: the new image did not boot. Suspend the run
   (`kubectl annotate talosupgrade cluster tuppr.home-operations.com/suspend="true"`),
   read `talosctl -n <ip> dmesg`, and revert the version PR or fix forward.
5. Never upgrade two control planes at once. Resume with
   `kubectl annotate talosupgrade cluster tuppr.home-operations.com/suspend-`.

## Resolved when

`kubectl get talosupgrade cluster` shows `Completed`, and every node runs the target version, Ready and uncordoned; the alert clears.

## Links

- [talos-cheatsheet.md: Talos and Kubernetes upgrades](../../talos-cheatsheet.md#talos-and-kubernetes-upgrades) (watch, pause, recovery)
- [talos-cheatsheet.md: A node won't come back](../../talos-cheatsheet.md#a-node-wont-come-back)
