# 2026-11-17: Paperless down after the 3.5.0 update

## Summary

Renovate merged paperless-ngx 3.5.0 at 05:35Z. In 3.5.0, `PAPERLESS_URL`
also limits `ALLOWED_HOSTS` to its host and `localhost`, so the readiness
probe, which sends the pod IP as `Host`, got 400 and the pod never became
Ready. `archive.lilalala.com` answered 503 for about 1 h 50 min. The
automatic rollback skipped the revert because a later merge had landed.

| | |
| --- | --- |
| Start / end | `2026-11-17 05:40Z` / `07:30Z` |
| Detected by | `SLOErrorBudgetBurnFastPersistent` for `archive` (page) |
| Apps affected | `archive` (Paperless) |
| Budget spent | about 110 minutes of failed probes, 51% of the 216-minute monthly budget |
| Data lost | none |
| Trigger | one event spent 25% or more of an app's monthly budget; an automated action (Renovate) caused it |

## Impact

The household could not open Paperless from 05:40Z to 07:30Z: the Gateway
had no ready backend and answered 503. The in-cluster callers on
`http://paperless:8000` (canary, `paperless-apply`, the PostSync smoke) would
have got 400 too; the 07:00Z canary failed with "connection refused" because
the Service had no endpoints. No document was lost: the database is SQLite on
the PVC and the 3.5.0 migrations completed.

## Timeline

| UTC | Event |
| --- | --- |
| 05:35 | Renovate PR #1464 (paperless-ngx 3.4.2 to 3.5.0) merges on green CI |
| 05:40 | the public probe for `archive` starts failing; the pod runs but is never Ready (539 readiness failures, `DisallowedHost`) |
| 05:52 | auto-rollback runs and decides `skip (not the newest commit on main)`: #1465 (prowlarr) merged after #1464 |
| 07:00 | the paperless canary fails (no endpoints) |
| 07:07 | the operator's morning check starts from the page |
| 07:22 | #1466 merges: `PAPERLESS_ALLOWED_HOSTS` set, readiness probe with `Host: localhost` |
| 07:28 | Argo CD `paperless` Synced/Healthy, pod Ready, `paperless-apply` and the smoke Job complete |
| 07:30 | the public probe succeeds again |

## Cause

Confirmed. Paperless-ngx 3.5.0 derives `ALLOWED_HOSTS` from `PAPERLESS_URL`
when `PAPERLESS_ALLOWED_HOSTS` is unset; in the pod it read
`['localhost', 'archive.lilalala.com']`. The kubelet readiness probe sends
the pod IP as `Host`, which Django rejects with 400 `DisallowedHost`, so the
pod stayed unready and the Service had no endpoints.

The automatic rollback reverts only the newest commit on `main`. #1465 had
merged after #1464, so it skipped. A revert would not have been safe either:
3.5.0 had already applied its database migrations.

Ruled out: the database, storage (PVCs Bound, NAS healthy), network
policies and the NAS changes of the day before.

## What went well

- The cause was visible in the pod's settings and the probe logs within
  minutes of the check starting.
- The fix was a two-line configuration change, merged through CI like any
  other.

## What went badly

- CI and the kind boot did not catch it: neither sends the kubelet's
  `Host` header against the real `PAPERLESS_URL`.
- The automatic rollback had no path for a degraded app when a later merge
  had landed, so the outage lasted until a person acted.

## Where we got lucky

- The migrations needed no rollback, so fixing forward was enough.

## Action items

| Action | Type | Status |
| --- | --- | --- |
| `PAPERLESS_ALLOWED_HOSTS` set, readiness probe with `Host: localhost` | mitigate | PR #1466 |
| Auto-rollback handles a degraded app when a later merge landed (wait in the train, or revert the app's own merge) | mitigate | open, #1467 |
