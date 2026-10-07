# Roadmap

What the cluster deliberately does not do yet, in rough order. Each line is its
own pull request with its own diff, test and rollback
([decisions.md](decisions.md#adopt-at-parity-change-afterwards)).

## Networking

- Choose between kube-vip `svc_enable` and Cilium L2 announcements for
  LoadBalancer IPs (both announce today, [networking.md](networking.md#loadbalancer-ips)).
- Enforce the CiliumNetworkPolicies (`infrastructure/network-policies/`,
  written, not in a layer), one namespace at a time.
- Cilium WireGuard transparent encryption, then Hubble relay, UI and metrics
  ([decisions.md](decisions.md#no-service-mesh)).

## Monitoring

- Turn alerting on: real Pushover values, Alertmanager receivers, the custom
  rules ([observability.md](observability.md#turning-alerting-on)).
- blackbox-exporter probes for every public hostname.

## Backups

- WAL archiving and base backups for `immich-db` and `keycloak-db` with the
  Barman Cloud plugin (`platform/barman-cloud-plugin/`, written), once the CNPG
  upgrade below reaches 1.26 or later. Not the in-tree `barmanObjectStore`,
  which CNPG deprecates from 1.26 ([backups.md](backups.md#why-it-is-like-this)).
- Enable the weekly restore tests (`clusters/homelab/staged/backup-verify.yaml`).
- Snapshot-then-backup for the two best-effort SQLite databases (Jellyfin,
  Grafana) and a consistent Paperless SQLite copy.
- Fix the etcd snapshot task in `ansible/kube-upgrade.yml` (it calls a host
  `etcdctl` that does not exist), or replace it with the runbook procedure.

## Delivery

- Automatic rollback: Argo CD Notifications on sync failure or degraded health
  -> GitHub `repository_dispatch` -> an auto-merged revert pull request.
  Renovate already automerges every update on green CI
  (`.github/renovate.json5`), so until this exists a bad update is reverted by
  hand.
- Scripts and tasks that still use namespace `argocd` (`task apps:status`,
  `ansible/os-upgrade.yml`, `scripts/graceful-*.sh`) move to `argo`.

## Versions (each a separate upgrade)

- cert-manager v1.15.0 -> current; external-dns v0.15.0 -> current (add
  `--force-default-targets` first); kube-prometheus-stack 56.2.0 -> current
  (CRDs first); CloudNativePG chart 0.22.1 (operator 1.24.1) -> current, moved to
  `cnpg-system` (never two operators at once).
- Immich chart 0.9.0 / v2.3.1 -> current, with the irreversible pgvecto.rs ->
  VectorChord migration: [runbooks/immich-upgrade.md](runbooks/immich-upgrade.md)
  only, after an off-site backup of `immich-db` exists.
- MariaDB 10.11 -> 12.3 for Seafile ([runbook](runbooks/seafile-mariadb-upgrade.md)).
- Cilium 1.18, then Argo CD 3.x.
- Talos, as a new cluster ([decisions.md](decisions.md#kubeadm-today-talos-later)).

## Images: next pins

Digests running on 2026-10-04 for every `latest`, floating or untagged image.
Pinning changes the pod template, so each is a restart and its own change.

| Workload | Image | Running digest |
|---|---|---|
| theater/jellyfin | ghcr.io/jellyfin/jellyfin | sha256:008ec8024bdaaa6f0a3f0de468e185633eeba9d67c56936e8dbf5ef6b8d6200f |
| theater/plex | plexinc/pms-docker | sha256:e0ab27395614a8e1a4fdf84c6bc60ac664915cfdde70c52d030c7728a1c48e14 |
| theater/sonarr | ghcr.io/hotio/sonarr:latest | sha256:e6052fce3715b3bdc8ad517aae6f2dfb5e6bcf68f71585274099236aa47365a2 |
| theater/radarr | ghcr.io/hotio/radarr:latest | sha256:c6f864f144065d5f89636bb2d6db4377688ca9aa40f0b9f733d8ab3f0604c93f |
| theater/lidarr | ghcr.io/hotio/lidarr:latest | sha256:ee5ab4f9c441c0a122075ed92e9d10139887d54a77371226f43d762d3707cfb1 |
| theater/prowlarr | ghcr.io/hotio/prowlarr:latest | sha256:7716a811bdae7f95351ccdd893f54c028a88949b5c4e694074df2048265b6d2c |
| theater/qbittorrent | ghcr.io/hotio/qbittorrent:latest | sha256:ec7a0c3cdf1258dbd5f395261b5d341b63655850d0f44d246dd56668dcfcfe7f |
| syncthing/syncthing | syncthing/syncthing:latest | sha256:397aa00b92b48d65540ea3ae3cbf271b87bdccbe07a0b7bd7d2debc3a7b29138 |
| seafile/seafile | seafileltd/seafile-mc:11.0-latest | sha256:1239b087aa4bdf1b60a3802e80855f230736ac5d5fa3325a40b15d4c598f422c |
| democratic-csi driver | democraticcsi/democratic-csi:latest | sha256:944d0e65077efbd9c1fdf23997eec8fac4b4bfb7c3de400f63e33a0a849c5ced |

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

- Bazarr (`apps/theater/bazarr.yaml`) and SSO in front of the *arr UIs
  (`apps/theater/sso.yaml`, new public hostnames).
- Jellyfin on Keycloak SSO (the TV app keeps Quick Connect or local login).
- Keycloak long sessions: SSO Session Idle 30 days, Max 365 days, Remember Me.
