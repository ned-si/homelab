# Roadmap

What the layered tree deliberately does not do yet, in rough order. Each line is
its own change with its own diff, test and rollback; parity with the running
cluster came first (ADR 0002).

## Cutover and ingress

- Adopt the layered tree app by app: [runbooks/adopt-layered-tree.md](runbooks/adopt-layered-tree.md).
- KSOPS on the Argo CD repo-server (`bootstrap/argocd-values.yaml`).
- external-dns: `gateway-httproute` as the only source (ingress-nginx is
  removed).
- Decide between kube-vip `svc_enable` and Cilium L2 announcements for
  LoadBalancer IPs (both announce today).

## Delivery

- Renovate: automerge on green CI for patch, minor and digest updates, behind
  one top-level switch that stays off until automatic rollback exists.
- Automatic rollback: Argo CD Notifications on sync-failed/degraded and probe
  alerts -> GitHub `repository_dispatch` -> auto-merged revert PR. One
  Application per app keeps every app revertable on its own.

## Versions (each a separate upgrade)

- cert-manager v1.15.0 -> current; external-dns 0.15 -> current (add
  `--force-default-targets` first); kube-prometheus-stack 56.2.0 -> current
  (CRDs first); CloudNativePG 0.22.1 -> current and move it to `cnpg-system`
  (never two operators at once).
- Immich chart 0.9.0 / v2.3.1 -> current, and the irreversible
  pgvecto.rs -> VectorChord migration: [runbooks/immich-upgrade.md](runbooks/immich-upgrade.md)
  only, after a verified off-site backup.
- Argo CD 3.x.

## Images: next pins

Running image digests on 2026-10-04 for every `latest` or untagged image. Pinning
changes the pod template, so each is a restart and its own change.

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

- The restructure's hardened workload manifests (probes, security contexts,
  resources, renamed volumes) are in git history (`feat(apps): migrate mealie,
  paperless, seafile and syncthing`, `feat(apps): pin the theater stack ...`);
  bring them back one app at a time, keeping every PVC name.
- PSA `enforce` per namespace once its `audit` events are clean.
- CiliumNetworkPolicies (`infrastructure/network-policies/`, written, not enabled).
- Plex and Jellyfin mount the media share `readOnly`; move the NFS mounts to the
  `nfs-storage` leaf (`Retain` PVs).
- Leaves on client-side apply (cert-manager, external-dns, ingress-nginx, Immich)
  move to server-side apply after adoption.
- The unmanaged `kube-system/snapshot-controller` v6.3.1: enabling the
  `snapshot-controller` leaf (v6.3.2) must replace it in the same change, never
  run beside it.

## Backups and features

- Off-site backups (ADR 0008): restic CronJobs, CNPG barman, backup-verify, once
  real storage credentials exist. Every CronJob ships suspended with the
  pending-guard.
- Jellyfin on Keycloak SSO (the TV app keeps Quick Connect / local login).
- Keycloak long sessions: SSO Session Idle 30 days, Max 365 days, Remember Me.
- Bazarr (`apps/theater/bazarr.yaml`) and SSO in front of the *arr UIs
  (`apps/theater/sso.yaml`, new public hostnames).
