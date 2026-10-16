# BackupNotFresh

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/backup-slo.yaml`](../../../platform/kube-prometheus-stack/routes/backup-slo.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

The restic CronJob `namespace`/`target` has no successful run in 26 hours,
so its data is past the 24 h RPO ([sre.md: RPO](../../sre.md#rpo)). The cause
is anything but a failed Job (a failed Job pages as `KubeJobFailed`): the
CronJob is suspended, its schedule never fires, its Jobs never finish, or it
was deleted while still listed in `ci/active-cronjobs.txt`.

## Confirm

```sh
kubectl -n <namespace> get cronjob <target> -o jsonpath='{.spec.suspend} {.spec.schedule} {.status.lastScheduleTime} {.status.lastSuccessfulTime}{"\n"}'
kubectl -n <namespace> get jobs --sort-by=.status.startTime | grep <target>
q 'slo:backup_fresh{target="<target>"}'
q 'slo:backup_freshness:ratio_rate30d{target="<target>"}'
```

Expected while it fires: the CronJob's `suspend`, schedule and times (a
`lastSuccessfulTime` over 26 hours old, or none), its newest Jobs (none, or
one still running), `0`, and the share of the last 30 days it was fresh
(objective 0.99). `NotFound` on the CronJob means it was deleted.

## Fix

1. `suspend` is `true`: something suspended it (a pending-guard decision, a
   hand edit). Every CronJob in `ci/active-cronjobs.txt` ships
   `suspend: false`; let Argo CD self-heal it, or sync the app.
2. No Job since the last success: the schedule does not fire. Check
   `kubectl -n <namespace> describe cronjob <target>` events (a missed
   deadline, `startingDeadlineSeconds`), and the node clock after a cold start.
3. A Job still running for hours: read its log
   (`kubectl -n <namespace> logs job/<job> --all-containers --tail=50`); a
   restic lock or a slow NAS ([HomelabNASDown](HomelabNASDown.md)) is the
   usual cause. Delete the stuck Job, then run one by hand:

   ```sh
   kubectl -n <namespace> create job --from=cronjob/<target> <target>-manual
   kubectl -n <namespace> logs -f job/<target>-manual --all-containers
   kubectl -n <namespace> delete job <target>-manual
   ```

4. The CronJob is gone on purpose: remove it from `ci/active-cronjobs.txt` and
   from `platform/kube-prometheus-stack/routes/backup-slo-targets.yaml` in one
   pull request (repo-policy rule `backup-slo-targets` keeps them equal).

## Resolved when

The manual or next scheduled run succeeds: `lastSuccessfulTime` is recent,
`q 'slo:backup_fresh{target="<target>"}'` returns `1` within 2 minutes, and
the alert clears. Not rehearsed.

## Links

- [backups.md: Freshness](../../backups.md#freshness)
- [backups.md: Schedule](../../backups.md#schedule)
- Homelab / Data protection dashboard
