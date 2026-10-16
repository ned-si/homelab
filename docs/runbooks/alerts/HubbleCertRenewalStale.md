# HubbleCertRenewalStale

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/hubble-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/hubble-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

The CronJob `kube-system/hubble-generate-certs` (Cilium's certgen) has not
succeeded for 130 days, one missed four-monthly run. The Hubble certificates
are valid 365 days from their last issue, so there are months left, but they
are no longer being renewed.

## Confirm

```sh
q 'time() - kube_cronjob_status_last_successful_time{cronjob="hubble-generate-certs"}'
kubectl -n kube-system get cronjob,jobs -l k8s-app=hubble-generate-certs
kubectl -n kube-system get secret hubble-relay-client-certs -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -enddate
```

Expected while it fires: more than 11232000 seconds, and the end date of the
current certificate.

## Fix

1. A failed Job: `kubectl -n kube-system logs job/<name>`. `CA certificate ...
   expires at ..., which is before the requested validity`: rotate the CA
   ([networking.md: Hubble certificates](../../networking.md#hubble-certificates)).
2. The CronJob missing or suspended: the Application `cilium` in Argo CD
   (`hubble.tls.auto` in `infrastructure/cilium/values.yaml`).
3. Then re-issue now:

   ```sh
   kubectl -n kube-system create job --from=cronjob/hubble-generate-certs hubble-generate-certs-now
   kubectl -n kube-system wait --for=condition=complete job/hubble-generate-certs-now --timeout=120s
   kubectl -n kube-system delete job hubble-generate-certs-now
   ```

   A Job created by hand does not reset the CronJob's last success; the alert
   clears after the next scheduled run, or delete the CronJob's failed Jobs and
   let the next run succeed.

## Resolved when

The CronJob's last success is recent; the alert clears.

## Links

- [networking.md: Hubble certificates](../../networking.md#hubble-certificates)
