# 2026-10-23: Every public hostname down after the Cilium 1.20.4 update

## Summary

An automerged Cilium patch update (1.20.3 to 1.20.4, #654) left the shared
Gateway without listeners: every HTTPS hostname refused connections for about
1 h 55 min, from the internet, the LAN and inside the cluster. The agent kept
serving its Envoy configuration on one aggregated (ADS) stream because a
`cilium-config` key from the bootstrap Helm install survived the upgrade,
while the new Envoy bootstrap asked for separate listener and cluster streams.
The pages fired but were held by quiet hours; the operator found the outage by
trying to use it. A manual revert (#659) restored service.

| | |
| --- | --- |
| Start / end | `2026-10-23 21:02Z` / `22:57Z` |
| Detected by | the operator noticing; `SLOErrorBudgetBurnFast` (21:09Z) and `SLOErrorBudgetBurnFastPersistent` (21:37Z) fired but were muted by quiet hours |
| Apps affected | `archive`, `auth`, `cinema`, `cook`, `media`, `syncthing`, `theater`, and every other hostname behind the shared Gateway |
| Budget spent | about 115 min per app, about 53% of the 30-day budget at 99.5% (216 min) |
| Data lost | none |
| Trigger | SLO fast burn on several apps; a cluster-wide user-facing outage |

## Impact

No web UI answered: Immich, Home Assistant, Keycloak (so no SSO login
anywhere), the media apps, Grafana, Argo CD, Headlamp, Hubble, SigNoz.
Connections to 192.168.1.254 (the Gateway's LoadBalancer IP) and to its
ClusterIP were refused. Traffic that does not pass the Gateway kept working:
the Kubernetes API, Syncthing and qBittorrent peer ports, Plex and Jellyfin
clients on the LAN by IP, in-cluster service-to-service calls, backups.

## Timeline

| UTC | Event |
| --- | --- |
| 20:55 | Renovate PR #654 (`chore(deps): update chart cilium to v1.20.4`) automerges on green CI |
| 21:00 | quiet hours start (23:00 Europe/Zurich) |
| 21:01 | Argo CD applies the new `cilium-envoy-config` (Envoy bootstrap with separate LDS/CDS streams) |
| 21:02 | agents and `cilium-envoy` restart on 1.20.4; Envoy gets no listeners; the Gateway refuses connections |
| 21:04 | the `cilium` Application finishes syncing: Synced, Healthy |
| 21:09 | `SLOErrorBudgetBurnFast` fires for 7 apps (muted) |
| 21:37 | `SLOErrorBudgetBurnFastPersistent` fires for 7 apps (a page; muted until 08:00 Zurich) |
| about 22:30 | the operator cannot reach any hostname and asks for help |
| 22:35–22:45 | diagnosis: WAN IP and DNS unchanged, L2 announcement fine, Gateway `Programmed`; connection refused in-cluster; `cilium-envoy` logs `unknown service envoy.service.listener.v3.ListenerDiscoveryService` |
| 22:45 | revert PR #659 opened |
| 22:53 | #659 merged |
| 22:57 | agents back on 1.20.3; the Gateway answers; all 15 published hostnames respond |

## Cause

Confirmed, from the rendered charts and the live objects:

1. Cilium chart 1.20.3 defaults `envoy.xdsMode` to `ads` on new 1.20
   installations: it writes `envoy-xds-mode: ads` into `cilium-config` and an
   ADS bootstrap (`adsConfig`) into `cilium-envoy-config`. Chart 1.20.4 changes
   the default to none: it stops rendering the key and renders a bootstrap with
   separate `ldsConfig`/`cdsConfig` gRPC streams.
2. Cilium was installed on 2026-10-14 with `helm install` (bootstrap) and then
   adopted by Argo CD, which applies with server-side apply. In the live
   `cilium-config`, the key `envoy-xds-mode` is owned only by the field manager
   `helm`; `argocd-controller` never owned it.
3. Server-side apply removes only fields the applying manager owns. On the
   1.20.4 sync, Argo CD replaced the Envoy bootstrap (that ConfigMap is now
   owned by `argocd-controller`) but left `envoy-xds-mode: ads` in place.
4. The 1.20.4 agents read `ads` and served ADS; Envoy opened LDS/CDS streams
   and got `unknown service`. No listener, so nothing bound the Gateway port.

A plain `helm upgrade` would have removed the key, so the upstream default
change only broke this cluster because of the adoption leftover.

Contributing:

- CI never sends traffic through a Cilium Gateway: the render, schema and
  policy checks pass, preprod (kind) boots three workloads, and the Talos
  upgrade rehearsal, which does install Cilium with the repo's values, runs
  only when `talos/talconfig.yaml` changes.
- Argo CD health is object-level: the DaemonSets were ready and the Gateway
  `Programmed`, so the app stayed Healthy and auto-rollback had no trigger.
- `cilium` is on the auto-rollback no-revert list
  (`scripts/ci/auto-rollback-decide.sh`).
- Renovate automerges Cilium at any time with no release age; this one merged
  on a Friday evening.
- Quiet hours mute every ntfy route, including an outage of every app at once.

## What went well

- The SLO alerts fired within 7 minutes and named the affected apps.
- `kubectl` and the API were unaffected, so the diagnosis took about 10
  minutes once it started.
- The revert was a single signed PR through the normal CI path; Argo CD rolled
  Cilium back in 4 minutes and nothing needed a manual fix.
- No data path other than the Gateway broke.

## What went badly

- The operator learned of the outage by trying to use it, 1.5 hours in.
- The upgrade was tested only on rendered YAML; the first traffic through the
  new Gateway was production's.
- The Helm ownership left by the bootstrap was known (gitops-delivery task 22)
  but only as a stale release Secret, not as live fields that block a removal.

## Where we got lucky

- The operator was awake and tried to use a service the same evening;
  otherwise the outage would have lasted until 08:00 Zurich (about 11 hours,
  more than twice the monthly budget).
- The failure was total and immediate. A partial one (some listeners) would
  have been harder to see.

## Action items

Tracked in spec `cilium-upgrades` (`.kiro/specs/cilium-upgrades/`).

| Action | Type | Status |
| --- | --- | --- |
| Revert Cilium to 1.20.3 | mitigate | #659 |
| Set `envoy.xdsMode` explicitly; remove the `helm` field ownership and the stale Helm release Secrets of Cilium | prevent | open (cilium-upgrades task 2) |
| Run the Talos rehearsal with a Gateway smoke test on every Cilium change | prevent | open (cilium-upgrades task 3) |
| PostSync smoke on the `cilium` app: a request through the shared Gateway | detect | open (cilium-upgrades task 4) |
| Renovate: Cilium only in a daytime window, after a release age | prevent | open (cilium-upgrades task 5) |
| A Gateway-wide outage pages through quiet hours | detect | open (cilium-upgrades task 6) |
| Auto-revert a failed Cilium patch update | mitigate | open (cilium-upgrades task 7) |
| Runbook: shared Gateway down | mitigate | open (cilium-upgrades task 6) |
| Re-apply Cilium 1.20.4 | — | open (cilium-upgrades task 8) |
