# NASiSCSITargetOpen

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/nas-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/nas-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

For an hour, `truenas-exporter` has counted iSCSI targets that accept more
than the four nodes. Any host on the LAN can log in to such a target and
read or write its volume.

On SCALE the limit is each target's `auth_networks`, set every 10 minutes
by the CronJob `democratic-csi/nas-iscsi-guard`
(`platform/truenas-exporter/iscsi_guard.py`): an hour open means six runs
failed or the CronJob is suspended. On CORE the limit is initiator group
1's `auth_network`, and the guard does nothing.

## Confirm

```sh
q 'truenas_iscsi_targets_unrestricted'
kubectl -n democratic-csi get cronjob nas-iscsi-guard
kubectl -n democratic-csi logs -l app.kubernetes.io/name=nas-iscsi-guard --tail=20
```

Expected while it fires: a count above `0`, and either `SUSPEND True` or
`error` lines in the log.

## Fix

1. `SUSPEND True` outside a NAS window: `scripts/nas-maintenance.sh up
   <state-file>` did not finish. Re-run it; it restores the CronJob and
   Argo CD's automated sync, which keeps `suspend: false`.
2. `api key rejected`: the key in the democratic-csi Secret was rotated or
   revoked; [NASExporterFailing](NASExporterFailing.md) fires too and has
   the fix.
3. `bad ISCSI_AUTH_NETWORKS`: the literal in
   `platform/truenas-exporter/kustomization.yaml` is not the four node
   addresses as `/32`s in `192.168.1.0/24`. Fix it in a pull request.
4. `unexpected answer` with `has no auth_networks` on SCALE: the API shape
   changed. Set the four `/32`s on each target in the TrueNAS UI (Shares →
   Block (iSCSI) Shares Targets → Targets → Edit → Authorized Networks) and
   open an issue for the guard.
5. `core, nothing to do`: in the CORE UI (Sharing → Block Shares (iSCSI) →
   Initiators), group 1's Authorized Networks must be the four `/32`s, and
   every target's group must use initiator group 1.

Then run the guard once:

```sh
kubectl -n democratic-csi create job --from=cronjob/nas-iscsi-guard nas-iscsi-guard-manual
kubectl -n democratic-csi logs -f job/nas-iscsi-guard-manual
# expected: {"msg": "done", "changed": <n>, ...} or "core, nothing to do"
kubectl -n democratic-csi delete job nas-iscsi-guard-manual
```

## Resolved when

`q 'truenas_iscsi_targets_unrestricted'` returns `0`; the alert clears.

## Links

- [observability.md: NAS metrics](../../observability.md#nas-metrics)
- [nas-on-truenas-scale design](../../../.kiro/specs/nas-on-truenas-scale/design.md#iscsi-limited-to-the-four-nodes)
