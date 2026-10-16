---
inclusion: always
---
# Product

A family homelab, run as if it were a small production platform. It hosts
the household's photos, media, documents, recipes and home automation behind
one Keycloak single sign-on, and it is public as an implementation example.

## Users

- The household: phones, TVs and browsers, on the LAN and through the
  public names `<name>.lilalala.com`.
- The operator: one person, who decides what gets built and acts only when a
  page asks for it. AI agents do most of the implementation through pull
  requests.

## Services by area

| Area | Services |
| --- | --- |
| Photos | Immich |
| Films, series, music | Plex, Jellyfin, Sonarr, Radarr, Lidarr, Prowlarr, Bazarr, Recyclarr, qBittorrent |
| Books | Audiobookshelf, Calibre-Web, LazyLibrarian |
| Documents | Paperless-ngx |
| Recipes | Mealie |
| Device sync | Syncthing |
| Home | Home Assistant, Mosquitto, Zigbee2MQTT |
| Identity | Keycloak, realm `homelab`, per-app access by group |
| Operator tools | Argo CD, Grafana, Headlamp (tailnet only) |

The current list with namespaces and hostnames is the Services table in
[README.md](../../README.md#services). Plex and Jellyfin stay off SSO so the
TV apps can sign in.

## Service level

- One number: 99.5% availability over 30 days per user-facing app, measured
  by public blackbox probes. It is the SLO and the self-SLA; no penalty.
- Tiers, RPO, RTO and the error-budget policy: [docs/sre.md](../../docs/sre.md).
- Argo CD and Grafana carry no SLO.

## Principles

- No human gates. CI is the only gate: green CI merges, Renovate automerges,
  a merge that degrades an app is reverted automatically.
- Deterministic first. Scripts, checks, thresholds and alerts decide; AI only
  where determinism is impossible, and for writing and summarising.
- One topic per pull request. Unrelated changes get their own branch.
- `main` is production. Merging deploys; rollback is a revert.
- Backups: no ad-hoc backup when a successful one is under 24 h old, except
  before a one-way change (database major, cutover, node flash), which always
  gets a fresh one.
- Page only when a person has to act. Everything automation handles is an
  INFO event on the Grafana dashboards ([docs/sre.md](../../docs/sre.md#paging)).
- No data loss: data volumes are `Retain`, no prune where a deletion is an
  outage ([docs/decisions.md](../../docs/decisions.md)).
- Public repository: no secrets, no personal data, LAN addresses are fine.
