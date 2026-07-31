# Architecture

## The hierarchy

One Application is applied imperatively. Everything else descends from it.

```
bootstrap/  (OpenTofu, run once)
  ├─ Cilium                 ← no pod can schedule without a CNI
  ├─ Argo CD                ← incl. KSOPS tooling + the age key
  ├─ sops-age  Secret       ← the key that decrypts the repo
  ├─ homelab-repo Secret    ← git credentials
  └─ root Application ──────┐
                            │
clusters/homelab/           │
  root.yaml  ───────────────┘   the same object, committed for reference
    │
    └─ bootstrap/                       AppProjects + the three layer apps
         ├─ project-{infrastructure,platform,apps}      wave -1
         ├─ layer-infrastructure  ──┐                   wave  1
         ├─ layer-platform  ────────┤                   wave  2
         └─ layer-apps  ────────────┤                   wave  3
                                    │
    ┌───────────────────────────────┘
    │
    ├─ infrastructure/   Application CRs ──→  infrastructure/<component>/
    ├─ platform/         Application CRs ──→  platform/<component>/
    └─ apps/             Application CRs ──→  apps/<component>/
```

Four levels: root → layer set → layer → leaf. The split that matters is between
`clusters/homelab/` (which contains **only** Argo CD `Application` objects) and
the three top-level directories (which contain **only** Kubernetes manifests and
Helm values).

That separation is what the old repo lacked. Previously a single Application
pointed at `kubernetes/applications` with `directory.recurse: true`, so Argo
applied every YAML in the tree in one undifferentiated blob — Applications,
Deployments, Secrets and namespaces all at once, with no ordering beyond a few
sync-wave annotations and no way to sync or roll back one app.

### Why layers, and why in this order

| Layer | Contains | Depends on |
|---|---|---|
| infrastructure | CNI, Gateway API, cert-manager, external-dns, CSI, namespaces | nothing |
| platform | CloudNativePG, monitoring, Keycloak | StorageClasses, certificates |
| apps | media, photos, documents, recipes, sync | databases, identity, routing |

Nothing in `apps` can be healthy before `platform`, and nothing in `platform`
before `infrastructure`. Encoding that as three Applications with sync waves
means a cold start converges on its own rather than needing manual sync ordering.

### AppProjects

Each layer has an `AppProject` that bounds what it may do:

- **infrastructure** — the only project allowed cluster-scoped resources
  (`clusterResourceWhitelist: "*"`). CRDs, ClusterRoles and webhooks live here.
- **platform** — an *enumerated* list of cluster-scoped kinds. A chart that
  suddenly wants a new `MutatingWebhookConfiguration` fails to sync instead of
  silently gaining cluster-wide reach.
- **apps** — namespaced only, and restricted to a fixed list of destination
  namespaces. An application needing a cluster-scoped resource is a design smell
  that should be promoted to `platform`, not accommodated by widening this.

Previously everything used the `default` project, which permits everything
everywhere.

## Sync waves

Within `infrastructure`:

| Wave | Component | Why here |
|---|---|---|
| -30 | namespaces | Secrets need their namespace to exist |
| -25 | secrets | Before anything mounts one |
| -20 | gateway-api | CRDs before Cilium programs a Gateway |
| -10 | cilium | CNI |
| -5 | cilium-config | LB IP pools, L2 policy — needs Cilium CRDs |
| 0 | cert-manager | CRDs must establish before issuers |
| 5 | cert-manager-issuers | |
| 10 | external-dns | |
| 15 | gateway | The shared entrypoint |
| 20 | democratic-csi | StorageClasses before any PVC |
| 25 | nfs-storage | |

`platform`: secrets (-25) → CloudNativePG (0) → monitoring (10) → Keycloak (20).
`apps`: secrets (-25) → everything else in parallel (0).

One known wrinkle: CloudNativePG at wave 0 enables a `PodMonitor`, but the
Prometheus CRDs arrive at wave 10. Its first sync therefore fails with
`no matches for kind "PodMonitor"` and succeeds on retry. That is handled by the
Application's retry policy and is not worth reordering the layer to avoid.

## Helm charts: multi-source Applications

Charts are consumed as Argo multi-source Applications:

```yaml
sources:
  - repoURL: https://helm.cilium.io
    chart: cilium
    # renovate: datasource=helm registryUrl=https://helm.cilium.io depName=cilium
    targetRevision: 1.20.0
    helm:
      valueFiles:
        - $values/infrastructure/cilium/values.yaml
  - repoURL: https://github.com/ned-si/homelab.git
    targetRevision: main
    ref: values
```

The chart version sits next to its `# renovate:` comment, and the values live in a
real file that can be diffed and commented. Previously values were inline YAML
strings inside the Application, so a values change and a version change were
indistinguishable in a diff, and the values were not syntax-highlighted or
lintable.

Where a chart needs extra manifests it does not provide (an HTTPRoute, a
database), a third source with a `path` is added — see
`clusters/homelab/apps/immich.yaml`.

## Hardware and cluster

- **BMC**: Turing Pi 2
- **Nodes**: 4× RK1, 32GB each, arm64
- **Kubernetes**: kubeadm on Ubuntu (the old README claimed Talos; the Ansible
  inventory and the `10-kubeadm.conf` notes say otherwise — it is kubeadm)
- **Storage**: TrueNAS at `192.168.1.228`; iSCSI via democratic-csi for
  block volumes, NFS for the media library
- **CNI**: Cilium with kube-proxy replacement, L2 announcements, WireGuard
  encryption, and Gateway API

Everything is single-replica. On four nodes with one storage backend, a second
replica of most of these buys availability against node failure but costs memory
and makes drains harder — and several of them (anything on a `ReadWriteOnce`
volume) cannot have one anyway.

## What is deliberately not GitOps

Two things, both genuine bootstrap paradoxes:

1. **Cilium** is installed by OpenTofu because no pod — including Argo CD — can be
   scheduled without a CNI. The Argo `cilium` Application then adopts that release
   and both read the same values file, so they cannot drift.
2. **The age key and the git credential** cannot live in the repository they
   protect.

Everything else, including Argo CD's own HTTPRoute, is managed by Argo CD.

## Site-specific values

Four places contain values tied to the current house. They are flagged with
`SITE-SPECIFIC` comments:

| File | Value |
|---|---|
| `infrastructure/gateway/gateway.yaml` | **the public WAN IP** — the only copy |
| `infrastructure/cilium/ip-pools.yaml` | LoadBalancer address ranges |
| `infrastructure/cilium/values.yaml` | `k8sServiceHost` (API VIP) |
| `infrastructure/nfs-storage/nfs-volumes.yaml` | TrueNAS address |

Plus `infrastructure/cilium/l2-announcement-policy.yaml`, whose `interfaces`
regex must match the node NIC names.

See [networking.md](networking.md) for the move checklist.
