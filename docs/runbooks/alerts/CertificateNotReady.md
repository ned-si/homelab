# CertificateNotReady

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/alerts.yaml`](../../../platform/kube-prometheus-stack/routes/alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

Certificate `namespace/name` has not been Ready for an hour: an order or a
challenge is failing. A Let's Encrypt order expires after 7 days and then
never completes, so a stuck Certificate does not recover on its own.

## Confirm

```sh
kubectl -n <namespace> get certificate <name>
kubectl -n <namespace> describe certificate <name> | sed -n '/^Status:/,$p'
kubectl -n <namespace> get orders.acme.cert-manager.io,challenges.acme.cert-manager.io
```

Expected while it fires: `READY False` (or `Unknown`), and an Order or
Challenge in `pending`, `invalid` or `errored`.

## Fix

1. Fix the cause, as in [CertificateExpiringSoon](CertificateExpiringSoon.md#fix)
   (usually the Cloudflare token).
2. Restart the issuance: delete the stuck request; cert-manager creates a
   new one and a new order:
   `kubectl -n <namespace> delete certificaterequest <request>`.

## Resolved when

`READY True`; the alert clears within the hour.

## Links

- [CertificateExpiringSoon](CertificateExpiringSoon.md)
