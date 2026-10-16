---
inclusion: always
---
# Tech

Versions are not repeated here. Talos and Kubernetes are pinned in
[`talos/talconfig.yaml`](../../talos/talconfig.yaml), charts next to each
Application in `clusters/homelab/`, images by digest in the manifests.

## Stack

| Concern | Choice | Docs |
| --- | --- | --- |
| Hardware | 4x Turing RK1 (RK3588, arm64) on a Turing Pi 2: 3 control planes, 1 worker, eMMC only | [architecture](../../docs/architecture.md#cluster) |
| OS | Talos Linux, configs rendered by talhelper; API VIP held by Talos | [talos](../../docs/talos.md) |
| Upgrades | Renovate pull requests, rehearsed in CI, rolled out node by node by tuppr | [talos](../../docs/talos.md#upgrades) |
| Network | Cilium (kube-proxy replacement, LB-IPAM, L2 announcements), one shared Gateway API `Gateway` | [networking](../../docs/networking.md) |
| GitOps | Argo CD: `root` -> three layers (infrastructure, platform, apps) -> one Application per app, tracking `main` | [architecture](../../docs/architecture.md#the-tree) |
| Storage | TrueNAS CORE: democratic-csi iSCSI (`iscsi`, `iscsi-retain`) and an NFS share for media | [architecture](../../docs/architecture.md) |
| Databases | CloudNativePG; WAL and daily base backups to S3 through the Barman Cloud plugin | [backups](../../docs/backups.md) |
| File backups | restic to S3 (the photo library also to the NAS); weekly restore tests; old object versions locked | [backups](../../docs/backups.md) |
| TLS and DNS | cert-manager (Let's Encrypt, DNS-01 on Cloudflare); external-dns, upsert only | [networking](../../docs/networking.md) |
| Identity | Keycloak, OIDC per app, access by group | [architecture](../../docs/architecture.md#per-app-access) |
| Remote access | Tailscale operator with the Kubernetes API proxy; web UIs (Headlamp) public behind Keycloak | [remote-access](../../docs/remote-access.md) |
| Observability | kube-prometheus-stack; Alertmanager -> ntfy; healthchecks.io heartbeat; SLOs as recording rules | [observability](../../docs/observability.md), [sre](../../docs/sre.md) |
| Automation | Renovate automerge on green CI; automatic rollback on a degraded sync, with an outage guard | [decisions](../../docs/decisions.md#automatic-rollback) |
| Cloud resources | OpenTofu under `bootstrap/`, applied by the `tofu` workflow through GitHub OIDC | [bootstrap](../../docs/bootstrap.md) |
| Secrets | SOPS with one age key, decrypted by KSOPS in Argo CD | [secrets](../../docs/secrets.md) |
| Policy | Kyverno policies run in CI over `deploy/`; kube-linter; Trivy | [testing](../../docs/testing.md) |

## Checks

Four layers ([docs/testing.md](../../docs/testing.md)):

1. Local hooks: `pre-commit` on commit and push.
2. Static CI (`ci` workflow): `lint`, `render` (unit tests, render,
   kubeconform, Kyverno, repo policy), `security` (gitleaks, Trivy gate),
   `talos`, `pr-metadata`.
3. Pre-production: an ephemeral kind cluster, server-side dry run of
   `deploy/` and a real boot of the stateless workloads.
4. Deploy time: PostSync smoke hooks; a failure triggers the rollback.

`ci` is the only required check. Every action is pinned to a SHA, every tool
to a version and checksum, every image to a digest.

## Constraints

- arm64 only: every image must publish an arm64 variant.
- Single replica everywhere; most volumes are `ReadWriteOnce` on one NAS.
- The `immich-db` image is pinned and excluded from Renovate: its upgrades
  can be one-way.
- Nodes have no shell: everything goes through `talosctl`.
