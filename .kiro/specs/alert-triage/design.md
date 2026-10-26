# Design: alert-triage

## Shape

A CronJob `alert-triage` in namespace `monitoring`, every 2 minutes:

1. Read the active alerts from the Alertmanager API
   (`/api/v2/alerts/groups?active=true&silenced=false&inhibited=false`) and
   keep the groups with a `action="human"` alert.
2. For each group key not in the state ConfigMap `alert-triage-state` (key
   hash and first-seen time, entries older than 6 h dropped): run
   `triage.sh <alertname>`, store the snapshot in ConfigMap
   `alert-triage-<UTC time>-<alertname, lowercased>` (not tracked by Argo CD, so never
   pruned by a sync), post the summary to ntfy, and record the key.
   Snapshots older than 7 days are deleted in the same run.
3. Write back the state; exit non-zero if a run failed (the failure counter
   for `AlertTriageFailing` is `kube_job_status_failed` on the CronJob's Jobs).

`concurrencyPolicy: Forbid`, `startingDeadlineSeconds: 60`, history 3/3.

## Why a polling CronJob, not an Alertmanager webhook

| | CronJob polling | Webhook receiver |
| --- | --- | --- |
| New always-on service | none | a Deployment with an HTTP endpoint |
| Image | a pinned kubectl image with bash, jq, git, curl | the same, plus an HTTP server |
| Latency | up to 2 min | seconds |
| Lost events | none: it reads state, not events | a missed POST is a missed snapshot |

Two minutes of latency is inside the 5-minute target, and reading state means
a restart loses nothing.

## Image and script

triage.sh and status.sh ship as a ConfigMap generated from `scripts/` by the
kustomization (one source, no copy). The image needs bash, kubectl, jq, git
and curl: the first task picks a pinned, digest-locked image that has them
(candidates: `alpine/k8s`, `bitnami/kubectl`), checked by Renovate like the
others. Merges come from `git fetch` of the public repository over HTTPS
(read-only, no token).

## ntfy message

Same topic and secret as Alertmanager (`platform/secrets/alertmanager-notify`,
key `ntfy-url`), title `triage: <alertname>`, body like:

```
State: 3 problems, Warning events: 4, Firing alerts: 2, Merges (6 h): 1
kubectl -n monitoring get cm alert-triage-20261027t0912-gatewaydown -o jsonpath='{.data.snapshot}'
```

Priority low, tag `mag`: it follows the page, it does not page again.
Quiet hours do not apply to it separately: it is sent only when a page was.

## Untrusted input

Only the alert name is used, and only after the regex check. No label value is
interpolated into a shell command, a URL or the message.

## Tests

`tests/bash/test_alert_triage.sh` with a fake Alertmanager response and a
fake triage.sh: one run per new group, none for a known one, state expiry,
rejected alert names, the message contains no snapshot line.
