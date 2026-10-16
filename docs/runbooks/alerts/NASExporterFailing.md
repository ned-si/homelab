# NASExporterFailing

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/nas-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/nas-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

`truenas-exporter` has failed to read the TrueNAS API for 15 minutes while
the NAS itself answers. Every NAS health alert is inert while this fires.
The exporter uses the CSI driver's API key, so a revoked key also breaks new
volumes.

## Confirm

```sh
q 'truenas_up'
kubectl -n democratic-csi logs deploy/truenas-exporter --since=30m | tail -20
```

Expected while it fires: `0`, and log lines with the failing call, for
example `HTTPError` 401.

## Fix

1. 401: the API key was rotated or revoked on the NAS. Create a new key in
   the TrueNAS UI (top right → API Keys), put it in
   `httpConnection.apiKey` of the democratic-csi driver config (Secret
   `democratic-csi/iscsi-democratic-csi-driver-config`, key
   `driver-config-file.yaml`, sealed in
   `infrastructure/secrets/democratic-csi-iscsi.sops.yaml`) and open a pull request
   ([secrets.md](../../secrets.md#everyday-work)). Restart the exporter
   after the sync: `kubectl -n democratic-csi rollout restart deploy/truenas-exporter`.
2. Timeouts or 5xx: the TrueNAS middleware is overloaded or hung. In the
   TrueNAS Shell, `service middlewared restart` (the web UI reconnects; the
   pool and the shares keep serving).

## Resolved when

`q 'truenas_up'` returns `1`; the alert clears.

## Links

- [observability.md: NAS metrics](../../observability.md#nas-metrics)
