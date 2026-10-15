# 2026-10-15: keycloak-db crash-loops on the CNPG minimal image

## Summary

PR #413 moved every CNPG cluster except immich-db to the
`-minimal-trixie` PostgreSQL images. keycloak-db could not start on
`17.11-minimal-trixie`, so Keycloak, and every login through it, was down
until #419 put the cluster back on `17.11`. The data dir carries
`en_US.utf8` locale settings, and the minimal image has no such locale.

| | |
| --- | --- |
| Start / end | `2026-10-15 14:47Z` / `15:46Z` |
| Detected by | the agent watching the rollout (Argo `keycloak` Degraded, `keycloak-db-1` CrashLoopBackOff) |
| Apps affected | `keycloak`, and every app behind Keycloak SSO or oauth2-proxy |
| Budget spent | about 59 minutes of failed Keycloak probes, about 27% of its monthly budget |
| Data lost | none: Postgres never started on the new image, and WAL archiving was current before the restart |
| Trigger | one event spent 25% or more of an app's monthly budget |

## Impact

- `https://auth.lilalala.com` returned 503. No new login to any app that
  signs in through Keycloak: the OIDC clients and the oauth2-proxy routes
  (`theater.lilalala.com` and the other *arr UIs).
- Plex and Jellyfin, which are not behind SSO, were unaffected.
- The other six CNPG clusters in #413 (mealie, sonarr, radarr, lidarr,
  prowlarr, home-assistant) restarted once and came back Ready with
  `ContinuousArchiving=True`.

## Timeline

| UTC | Event |
| --- | --- |
| 14:40 | #413 merged: CNPG clusters to `-minimal-trixie` |
| 14:47 | keycloak-db-1 starts on `17.11-minimal-trixie`; Postgres exits with `FATAL: configuration file ... postgresql.conf contains errors` |
| 14:50 | detected from the rollout watch |
| 14:54 | revert #419 opened; the `image-variant` CI rule fails it (back from `minimal-trixie` to the bare tag) until an allow comment is added |
| 15:29 | #419 merged; Argo CD does not apply it: the #413 sync of `keycloak` is still running, waiting for the Keycloak Deployment to become healthy |
| 15:41 | the stuck sync is cleared; keycloak-db moves to `17.11` |
| 15:46 | keycloak-db Ready, `ContinuousArchiving=True`; the OIDC discovery endpoint answers 200 |

## Cause

Confirmed:

1. keycloak-db was bootstrapped on this cluster by `recovery` from the
   previous cluster's backup (`spec.bootstrap.recovery`). The data directory,
   including the `lc_*` lines that `initdb` wrote into `postgresql.conf`,
   comes from the original cluster, which ran `initdb` with `en_US.utf8`.
2. The other clusters in #413 were initialised later with the C locale
   (`datcollate`, `datctype` and every `lc_*` setting are `C`, checked with
   `pg_settings`), so they do not depend on OS locales.
3. The `minimal` CNPG images ship only the C locales. On start, Postgres
   logged `invalid value for parameter "lc_messages": "en_US.utf8"` (and the
   same for `lc_monetary`, `lc_numeric`, `lc_time`), then refused the config.
4. A single instance has no replica to fail over to, so the crash loop was a
   full outage of Keycloak.

Not a cause: `shared_preload_libraries` and `postgresql.parameters` are the
same on keycloak-db and the clusters that started.

## What went well

- The rollout was watched, so the crash was seen within minutes.
- The revert was a one-line change; no data was at risk.
- The other clusters were checked per cluster (Ready, WAL archiving, locale).

## What went badly

- One PR changed seven stateful clusters at once, with no health gate between
  them. The check that would have caught it (the database locale against what
  the image ships) was not part of the change.
- The `image-variant` CI guard (#408, #410), added the same day to stop
  variant drift, blocked the emergency revert: going from `minimal-trixie`
  back to the bare tag reads as a variant change. The revert needed a
  `# image-policy: allow` comment before it could merge, which lengthened
  the outage.
- After the revert merged, Argo CD kept the #413 sync operation running
  (it waits for the app to become healthy, which needed the revert), so the
  fix sat in git for 12 minutes until the operation was cleared.
- Size was the only criterion; the image's locale set was not compared.

## Where we got lucky

- keycloak-db was the only cluster in #413 with a non-C locale. Any other
  would have failed the same way.
- Postgres refused the config before opening the data, so nothing was written
  under the new image.

## Action items

| Action | Type | Status |
| --- | --- | --- |
| Put keycloak-db back on `17.11` | mitigate | PR #419 |
| Roll out image switches for single-instance stateful apps one cluster per PR, with a health gate (Ready, `ContinuousArchiving=True`, the app answers) before the next | prevent | operator rule, from 2026-10-15 |
| Before moving a CNPG cluster to a `minimal` image, check that `datcollate`, `datctype` and `lc_*` are `C` or `C.UTF-8` | prevent | open |
| Move keycloak-db to the C locale at its next major upgrade (new `initdb`), then to `minimal` | prevent | open |
| Exempt revert pull requests from `image-variant`: a `revert` title, or an `auto-revert/` branch | mitigate | PR #427 |
| Runbook step: after a revert merges, terminate a sync operation that waits on the broken revision | mitigate | open |
