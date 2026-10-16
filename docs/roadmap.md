# Roadmap

What the cluster deliberately does not do yet, in rough order. Each line is its
own pull request with its own diff, test and rollback
([decisions.md](decisions.md#adopt-at-parity-change-afterwards)).

## Networking

- Enforce the CiliumNetworkPolicies (`infrastructure/network-policies/`,
  written, not in a layer), one namespace at a time.
- Cilium WireGuard transparent encryption
  ([decisions.md](decisions.md#no-service-mesh)).

## Monitoring

- Deploy the custom alert rules (`platform/kube-prometheus-stack/routes/alerts.yaml`,
  [observability.md](observability.md#notifications)).

## Backups

- Automatic Postgres majors: a Renovate major bump also moves the Barman Cloud
  `serverName` to `<cluster>-pg<major>`, CI checks they agree, then the Renovate
  cap on CNPG Postgres majors goes ([backups.md](backups.md#why-it-is-like-this)).
- Snapshot-then-backup for the two best-effort SQLite databases (Jellyfin,
  Grafana) and a consistent Paperless SQLite copy.

## Delivery

- `task apps:status` still uses namespace `argocd`; move it to `argo`.

## Versions

Renovate automerges every other update on green CI
([decisions.md](decisions.md#no-human-gates)). What it cannot do alone:

- The Immich database image (VectorChord or PostgreSQL major):
  [runbooks/immich-upgrade.md](runbooks/immich-upgrade.md#updating-the-database-image).
- external-dns: add `--force-default-targets` before chart 1.16 and later.

## Images: next pins

`democraticcsi/democratic-csi` runs `latest` pinned by digest
(`infrastructure/democratic-csi/values-iscsi.yaml`), so Renovate cannot offer
updates. Pin it to a release tag. Every other image carries a version tag and a
`# renovate:` annotation.

## Hardening

- Probes, security contexts and resources for the workloads adopted at parity
  (the hardened manifests are in git history: `feat(apps): migrate mealie,
  paperless, seafile and syncthing`, `feat(apps): pin the theater stack ...`),
  one app at a time, keeping every PVC name. qBittorrent first: a readiness
  probe turns its stale-socket fault into a visible failure
  ([runbook](runbooks/arr-qbittorrent.md)).
- PSA `enforce` per namespace once its `audit` events are clean.
- Plex and Jellyfin mount the media share `readOnly`; move the NFS mounts to the
  `nfs-storage` leaf (`Retain` PVs); scope the NAS exports to the node addresses
  ([runbook](runbooks/nfs-hardening.md)).
- Replace the unmanaged `kube-system/snapshot-controller` v6.3.1 with the
  `snapshot-controller` leaf (v6.3.2) in one change, never beside it.

## Features

- Jellyfin on Keycloak SSO (the TV app keeps Quick Connect or local login).
