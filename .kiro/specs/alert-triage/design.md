# Design: alert-triage

## Shape

```
Alertmanager ──webhook──▶ alert-triage receiver (Deployment, namespace alert-triage)
  route: action=human,     │ validates alertname, computes incident.id
  repeat 6h, resolved on   │ creates Jobs from fixed templates, logs JSON
                           ├─▶ Job snapshot  (SA alert-triage-snapshot, read-only)
                           │     clone main, scripts/triage.sh <alertname>, log, ntfy
                           └─▶ Job fix-<alert> (SA from the table, if any)
                                 the fix, its result, log
pod logs ──Vector──▶ store (SigNoz) ◀── ntfy link, filtered on incident.id
```

- **Receiver**: a small Python service (stdlib `http.server`, no
  dependencies), one replica. It holds no state: Alertmanager owns grouping,
  repeats and resolution, and a restart loses nothing but the request in
  flight (Alertmanager retries it).
- **Snapshot Job**: `alpine/k8s` (bash, kubectl, jq, git, curl), digest
  pinned. It does a shallow clone of `main` (2 s, 2.6 MB) and runs
  `scripts/triage.sh` from it: one source, the same trust as Argo CD
  deploying main, and the merges section gets its history. A ConfigMap built
  from `scripts/` is not possible: the render keeps kustomize's load
  restrictor, so a kustomization cannot read files outside its directory.
- **Fix Jobs**: one template per table entry, each with its own
  ServiceAccount. The table is a ConfigMap of the receiver; the Kyverno
  policy is generated from the same file, so the two cannot drift.

## Why these choices

| Choice | Instead of | Why |
| --- | --- | --- |
| Webhook | polling CronJob (the first design, #786) | no 2-minute loop, no state ConfigMap, Alertmanager already dedupes and repeats |
| Logs in the store | ConfigMaps, GitHub issues | one place with the rest of observability; the repository is public |
| Jobs per action | the receiver acting itself | the receiver holds no power beyond creating Jobs; each fix's rights are visible in its own Role |
| No exec for the snapshot | `pods/exec` on Alertmanager and Immich | exec is arbitrary commands in a database pod, every page; triage.sh reads Alertmanager over its API instead |
| Manual AI summary | hosted free tier, local model | privacy, cost; `/homelab-debug` does it on demand with the live cluster |

The receiver can create Jobs under any ServiceAccount in its namespace, so it
effectively holds the union of the fixes' rights; the Kyverno policy (4.2)
and one namespace for the triage objects only bound that union to the table.

## Backend independence

The receiver speaks Alertmanager's webhook JSON. SigNoz's alert channels
send a webhook too; if alerting moves to SigNoz, a thin adapter maps its
payload to the same fields (alert name, status, group key). The logs are
plain JSON on stdout: Vector parses them for either sink (SigNoz over OTLP,
or Loki if the trial fails).

## ntfy message

Title `triage: <alertname>`, priority low, tag `mag` (it follows the page,
it does not page again), body like:

```
Snapshot: 3 problems, 4 warning events, 2 firing alerts, 1 merge (6 h)
Fix: none for this alert
<store URL filtered on incident.id=3f2a9c0d1e4b5a6f>
```

## Changes to existing scripts

- `scripts/triage.sh`: the Alertmanager section reads
  `/api/v2/alerts` over HTTP (`AM_URL`), not `kubectl exec ... amtool`.
- `scripts/status.sh`: a check whose exec is forbidden prints
  `unavailable (no exec)` instead of failing the run.
- `scripts/alert-triage.sh` and its test (the polling CronJob, #786) are
  removed; the message builder and the alert-name check move to the
  receiver with their tests.

## Tests

- Receiver (Python unittest): fixture webhooks (firing, resolved, repeated,
  rejected alert name), the Job manifests it would create, the message
  builder, the log line shape.
- Kyverno CLI test: a Job from the receiver's ServiceAccount with a
  ServiceAccount or image outside the table is rejected.
- promtool: `AlertTriageFailing`.
- Live: `amtool alert add` with `action=human` on a test alert name, the
  snapshot found in the store by its `incident.id`.
