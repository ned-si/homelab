# CertificateExpiringSoon

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/alerts.yaml`](../../../platform/kube-prometheus-stack/routes/alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

Certificate `namespace/name` expires in under 21 days. cert-manager renews
Let's Encrypt certificates at 30 days left, so at least one renewal has
failed silently. Every public hostname is served from
`gateway/wildcard-lilalala` (ClusterIssuer `letsencrypt`, DNS-01 through
Cloudflare).

## Confirm

```sh
kubectl -n <namespace> describe certificate <name> | sed -n '/^Status:/,$p'
kubectl -n <namespace> get certificaterequests,orders.acme.cert-manager.io,challenges.acme.cert-manager.io
kubectl -n cert-manager logs deploy/cert-manager --since=24h | grep -iE 'error|fail' | tail -20
```

Expected while it fires: `Not After` under 21 days away, and a failed
CertificateRequest, Order or Challenge with its reason.

## Fix

1. `Unauthorized`, `Invalid request headers` or `Authentication error` from
   Cloudflare: the API token in Secret `cert-manager/cloudflare-api-token-secret`
   expired or was revoked. Create a new token (Zone DNS edit on
   `lilalala.com`) and seal it
   ([secrets.md: Rotating a credential](../../secrets.md#rotating-a-credential)).
2. A challenge stuck on DNS propagation: check the `_acme-challenge` TXT
   record with `dig +short TXT _acme-challenge.lilalala.com @1.1.1.1`.
3. Once the cause is fixed, ask for a new issuance by deleting the failed
   request (cert-manager backs off for hours otherwise):
   `kubectl -n <namespace> delete certificaterequest <request>`.

## Resolved when

`kubectl -n <namespace> get certificate <name>` is `READY True` with a new
`Not After` about 90 days away; the alert clears.

## Links

- [CertificateExpiringVerySoon](CertificateExpiringVerySoon.md), [CertificateNotReady](CertificateNotReady.md)
- [networking.md](../../networking.md)
