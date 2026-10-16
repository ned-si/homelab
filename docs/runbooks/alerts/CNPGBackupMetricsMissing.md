# CNPGBackupMetricsMissing

`warning`, pages. Rule: [`platform/barman-cloud-plugin/monitoring.yaml`](../../../platform/barman-cloud-plugin/monitoring.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

The Postgres instance `namespace/pod` is scraped but reports no Barman Cloud
metrics: it has no `plugin-barman-cloud` sidecar, or the plugin is down. That
instance is probably not archiving WAL or taking base backups.

## Confirm

```sh
kubectl -n <namespace> get pod <pod> -o jsonpath='{.spec.initContainers[*].name}{"\n"}'
kubectl -n <namespace> get cluster.postgresql.cnpg.io <cluster> -o jsonpath='{.spec.plugins}{"\n"}'
kubectl -n immich get deploy
```

Expected while it fires: no `plugin-barman-cloud` in the first line.
Healthy: it is there, the Cluster lists `barman-cloud.cloudnative-pg.io`
with `isWALArchiver: true`, and the plugin Deployment in `immich` is
available.

## Fix

1. The Cluster has no plugin entry: add it in git, as the other clusters do
   (CI rule `cnpg-backup`).
2. The plugin was down when the pod was created, so the sidecar was not
   injected: bring the plugin back (`kubectl -n immich describe deploy <plugin>`),
   then recreate the instance pod in a quiet moment. This restarts the
   database (single instance, a minute or two of downtime):
   `kubectl -n <namespace> delete pod <pod>`.

## Resolved when

The pod lists `plugin-barman-cloud` and
`q 'barman_cloud_cloudnative_pg_io_last_available_backup_timestamp{pod="<pod>"}'`
returns a value; the alert clears within the hour.

## Links

- [backups.md: Databases](../../backups.md#databases)
