# CNPGBackupFailed

`critical`, pages. Rule: [`platform/barman-cloud-plugin/monitoring.yaml`](../../../platform/barman-cloud-plugin/monitoring.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

The newest Barman Cloud base backup of `namespace/pod` failed after the last
good one. WAL archiving may still work, but recovery replays more WAL the
older the last base backup gets, and after 26 h `CNPGBaseBackupTooOld` fires.

| Namespace | Cluster (pod `<cluster>-1`) |
| --- | --- |
| `immich` | `immich-db` |
| `keycloak` | `keycloak-db` |
| `mealie` | `mealie-postgresql` |
| `theater` | `sonarr-postgresql`, `radarr-postgresql`, `lidarr-postgresql`, `prowlarr-postgresql` |
| `home` | `home-assistant-postgresql` |

## Confirm

```sh
kubectl -n <namespace> get backups.postgresql.cnpg.io --sort-by=.metadata.creationTimestamp | tail -3
kubectl -n <namespace> get backups.postgresql.cnpg.io <backup> -o jsonpath='{.status.phase}: {.status.error}{"\n"}'
kubectl -n <namespace> logs <pod> -c plugin-barman-cloud --since=24h | grep -iE 'error|fail' | tail -20
```

Expected while it fires: the newest Backup `failed`, with its error.

## Fix

1. Read the error. Usual causes: S3 credentials (`AccessDenied`,
   `InvalidAccessKeyId`: Secret `cnpg-backup-s3` of that namespace, used by
   ObjectStore `cnpg-backup`), the
   network (timeouts, DNS), or a full volume.
2. Fix the cause in git (credentials: [secrets.md](../../secrets.md#rotating-a-credential)).
3. Take a base backup now instead of waiting for the next night:

   ```sh
   kubectl -n <namespace> create -f - <<EOF
   apiVersion: postgresql.cnpg.io/v1
   kind: Backup
   metadata:
     name: <cluster>-manual-$(date -u +%Y%m%d%H%M)
   spec:
     cluster:
       name: <cluster>
     method: plugin
     pluginConfiguration:
       name: barman-cloud.cloudnative-pg.io
   EOF
   kubectl -n <namespace> get backups.postgresql.cnpg.io -w
   ```

   Expected: the new Backup reaches `completed` (minutes; `immich-db` longer).
   Stop the watch with Ctrl-C.

## Resolved when

A Backup newer than the failed one is `completed`; the alert clears within
15 minutes.

## Links

- [backups.md: Databases](../../backups.md#databases)
- [backups.md: Schedule](../../backups.md#schedule)
