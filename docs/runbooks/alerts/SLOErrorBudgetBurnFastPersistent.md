# SLOErrorBudgetBurnFastPersistent

`critical`, pages, one per app. Rule: [`platform/kube-prometheus-stack/routes/slo.yaml`](../../../platform/kube-prometheus-stack/routes/slo.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

The public probes of `app` have failed for half an hour (the 1h / 5m pair of
the fast burn, held for 30 minutes) and nothing automatic fixed it. Users see
the outage. `namespace` is where the app runs.

## Confirm

```sh
curl -sS -m 10 -o /dev/null -w '%{http_code}\n' https://<app>.lilalala.com/
q 'probe_success{job="blackbox-public", app="<app>"}'
q 'probe_http_status_code{job="blackbox-public", app="<app>"}'
kubectl -n <namespace> get pods
kubectl -n argo get applications | grep -v 'Synced.*Healthy'
```

Expected while it fires: probes at `0`, an HTTP code that is not 2xx (or
`0`: no answer, DNS or TLS failure), and the pods or Application that are
not healthy.

## Fix

1. Read the Homelab / Automation dashboard: an auto-rollback that was
   refused or failed means the newest merge is the suspect
   ([ArgoCDAppStillDegraded](ArgoCDAppStillDegraded.md#fix)).
2. Pods not Ready: `kubectl -n <namespace> describe pod <pod>` and its logs;
   a crash after a config change is fixed by a revert.
3. Pods fine but probes fail: the path in between. `502`/`503` from the
   Gateway (`kubectl -n <namespace> get httproute -o wide`, the Service's
   endpoints), `0` for every app at once (DNS, the WAN address:
   [wan-ip-change.md](../wan-ip-change.md), or the certificate:
   [CertificateExpiringVerySoon](CertificateExpiringVerySoon.md)).
4. A node or the NAS is down: [HomelabNodeDown](HomelabNodeDown.md),
   [HomelabNASDown](HomelabNASDown.md).

## Resolved when

`https://<app>.lilalala.com` answers and the probes are back at `1`; the
alert clears within minutes. An outage of about 54 minutes or more (25% of
the monthly budget) needs a postmortem ([sre.md](../../sre.md#postmortems)).

## Links

- [sre.md: Error-budget policy](../../sre.md#error-budget-policy)
- [observability.md: SLOs](../../observability.md#slos)
- Homelab / Overview dashboard
