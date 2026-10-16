# TalosConfigDrift

`warning`, pages. Rule: [`platform/talos-drift/rules.yaml`](../../../platform/talos-drift/rules.yaml).
Shell: [Before you start](README.md#before-you-start). Needs the LAN.

## What it means

The running machine config of `node` is not the one `talos/talconfig.yaml`
on `main` renders: a merged change that was not applied with
`task talos:apply`, or an apply that did not come from `main`. Nothing
applies Talos config automatically.

## Confirm

```sh
kubectl -n system-upgrade create job --from=cronjob/talos-drift talos-drift-manual
kubectl -n system-upgrade wait --for=condition=complete job/talos-drift-manual --timeout=10m
kubectl -n system-upgrade logs job/talos-drift-manual | grep -E 'DRIFT|matches main|differ'
kubectl -n system-upgrade delete job talos-drift-manual
```

Expected while it fires: a `DRIFT` line for the node and
`talos-drift: <n> node(s) differ from main`.

## Fix

1. From an up-to-date `main` (a worktree on `origin/main`), render and
   preview the change for the node (IP from
   [talos-cheatsheet.md](../../talos-cheatsheet.md#2-how-this-cluster-is-set-up)):

   ```sh
   task talos:genconfig
   talosctl -n <node-ip> apply-config -f talos/clusterconfig/homelab-<node>.yaml --dry-run
   ```

   Expected: the diff, and whether a reboot is needed.
2. The diff is a merged change: apply it with `task talos:apply -- <node>`.
   Take an etcd snapshot first on a control plane (`task talos:etcd-snapshot`).
3. The node is right and `main` is wrong (a by-hand fix that never reached
   git): put the change in `talconfig.yaml` or `talos/patches/` in a pull
   request instead.

## Resolved when

The next drift run (the Job above, or the daily 05:40 UTC run) logs
`matches main` for the node; the alert clears after the push.

## Links

- [talos.md: Drift check](../../talos.md#drift-check)
- [talos-cheatsheet.md: Config changes](../../talos-cheatsheet.md#config-changes)
