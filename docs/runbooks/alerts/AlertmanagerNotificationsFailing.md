# AlertmanagerNotificationsFailing

`critical`, pages. Rule: [`platform/kube-prometheus-stack/routes/alerts.yaml`](../../../platform/kube-prometheus-stack/routes/alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

Alertmanager has failed to deliver notifications through `integration` for
15 minutes. If it is the ntfy path, this page cannot arrive either: you find
it in Grafana, or because the phone went quiet. If it is the heartbeat,
healthchecks.io will report the cluster down although it is not.

## Confirm

```sh
q 'rate(alertmanager_notifications_failed_total[15m]) > 0'
kubectl -n monitoring logs alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager --since=30m | grep 'Notify attempt failed' | tail -5
kubectl -n monitoring get secret alertmanager-notify -o json | jq -r '.data | keys[]'
```

Expected while it fires: the failing integration, log lines naming the
receiver (`ntfy`, `ntfy-guard` or `heartbeat`) and the error, and the keys
`heartbeat-url`, `ntfy-guard-url`, `ntfy-url` (names only; never print the
values: the ntfy topic is the credential).

## Fix

1. Test ntfy from the Mac: `curl -m 10 -d test "https://ntfy.sh/<topic>"`.
   An error or `429`: ntfy.sh is down or rate-limits; it recovers on its own.
2. `ntfy` or `heartbeat` refused (`401`, `404`, a wrong URL): the value in
   `platform/secrets/alertmanager-notify.sops.yaml` is wrong or still a
   sentinel. Fix it ([observability.md: Notifications](../../observability.md#notifications),
   [Heartbeat](../../observability.md#heartbeat)).
3. DNS or connection errors: the cluster has no internet
   ([LANDeviceUnreachable](LANDeviceUnreachable.md) for the router).

## Resolved when

No new `Notify attempt failed` lines and the query returns nothing; the
alert clears. Send a test through the whole path
([observability.md: Notifications](../../observability.md#notifications)).

## Links

- [AlertmanagerHasNoReceiverConfigured](AlertmanagerHasNoReceiverConfigured.md)
