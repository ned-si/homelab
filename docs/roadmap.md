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
  Barman Cloud plugin (`platform/barman-cloud-plugin/`, written; CNPG 1.30.1
  supports it). Not the in-tree `barmanObjectStore`, which CNPG deprecates
  ([backups.md](backups.md#why-it-is-like-this)). Then lift the Renovate rule
  that holds Postgres majors for `keycloak-db`.
- Enable the weekly restore tests (`clusters/homelab/staged/backup-verify.yaml`).
- Snapshot-then-backup for the two best-effort SQLite databases (Jellyfin,
  Grafana) and a consistent Paperless SQLite copy.
- Fix the etcd snapshot task in `ansible/kube-upgrade.yml` (it calls a host
  `etcdctl` that does not exist), or replace it with the runbook procedure.

## Delivery

- Turn automatic rollback on: create its GitHub token
  ([decisions.md](decisions.md#automatic-rollback)). Everything else is
  deployed; until then a bad update is reverted by hand.
- A watchdog outside the cluster: automatic rollback runs through Argo CD and
  needs a working CNI, so it cannot rescue a broken Argo CD or Cilium.
- Scripts and tasks that still use namespace `argocd` (`task apps:status`,
  `ansible/os-upgrade.yml`, `scripts/graceful-*.sh`) move to `argo`.

## Versions

Renovate automerges every other update on green CI
([decisions.md](decisions.md#no-human-gates)). What it cannot do alone:

- Immich chart and server with the irreversible pgvecto.rs -> VectorChord
  migration: [runbooks/immich-upgrade.md](runbooks/immich-upgrade.md), after an
  off-site backup of `immich-db` exists.
- MariaDB above 10.11 and Seafile 12 (capped in `.github/renovate.json5`):
  [runbook](runbooks/seafile-mariadb-upgrade.md).
- Cilium 1.18 and Gateway API 1.3 need a newer node kernel than
  5.10.160-rockchip.
- external-dns: add `--force-default-targets` before chart 1.16 and later.
- Talos, as a new cluster ([decisions.md](decisions.md#kubeadm-today-talos-later)).

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

- Bazarr (`apps/theater/bazarr.yaml`) and SSO in front of the *arr UIs
  (`apps/theater/sso.yaml`, new public hostnames).
- Jellyfin on Keycloak SSO (the TV app keeps Quick Connect or local login).
