# TalosDriftCheckStale

`warning`, pages. Rule: [`platform/talos-drift/rules.yaml`](../../../platform/talos-drift/rules.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

The `talos-drift` CronJob (namespace `system-upgrade`, daily 05:40 UTC) has
not pushed a successful result for 2 days, so a node running a config that
`main` does not render would go unnoticed.

## Confirm

```sh
q 'time() - talos_config_drift_last_success_timestamp_seconds'
kubectl -n system-upgrade get cronjob,jobs -l app.kubernetes.io/name=talos-drift
kubectl -n system-upgrade logs job/<newest-job> | tail -20
```

Expected while it fires: an age over 172800 seconds (or nothing), and failed
Jobs or none.

## Fix

1. A failed Job: its log says where it stopped. GitHub unreachable (the
   download of `main`), a node the Talos API did not answer (a node down:
   [HomelabNodeDown](HomelabNodeDown.md)), or the Pushgateway in
   `backup-verify` not reachable.
2. No Jobs: the CronJob is suspended or missing; it must be in
   `ci/active-cronjobs.txt` and synced.
3. Run it now ([TalosConfigDrift](TalosConfigDrift.md#confirm)).

## Resolved when

A run ends with `talos-drift: <n> node(s) differ from main`; the alert
clears within the hour.

## Links

- [talos.md: Drift check](../../talos.md#drift-check)
