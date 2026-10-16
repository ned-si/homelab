# CertificateExpiringVerySoon

`critical`, pages. Rule: [`platform/kube-prometheus-stack/routes/alerts.yaml`](../../../platform/kube-prometheus-stack/routes/alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

Certificate `namespace/name` expires in under 7 days and renewal keeps
failing. When the wildcard `gateway/wildcard-lilalala` expires, every public
hostname breaks at once.

## Confirm

As in [CertificateExpiringSoon](CertificateExpiringSoon.md#confirm), plus
what clients see:

```sh
echo | openssl s_client -connect auth.lilalala.com:443 -servername auth.lilalala.com 2>/dev/null | openssl x509 -noout -enddate
```

Expected: `notAfter=` under 7 days away.

## Fix

Follow [CertificateExpiringSoon](CertificateExpiringSoon.md#fix). Let's
Encrypt rate-limits failed validations (5 per hour per hostname): fix the
cause before you retry, and do not delete and recreate the Certificate in a
loop.

## Resolved when

`READY True` with a new `Not After`, and the `openssl` check shows it.

## Links

- [CertificateExpiringSoon](CertificateExpiringSoon.md)
