# homelab

GitOps configuration for a four-node Kubernetes cluster on a Turing Pi 2.

Argo CD reconciles everything from this repository. One `Application` is applied
by OpenTofu; every other object in the cluster descends from it.

```
bootstrap/            OpenTofu. Runs once: Cilium, Argo CD, the age key, the root Application.
clusters/homelab/     Argo CD Application + AppProject objects ONLY. The hierarchy.
infrastructure/       CNI, Gateway API, cert-manager, external-dns, CSI, namespaces.
platform/             CloudNativePG, monitoring, Keycloak.
apps/                 Media, photos, documents, recipes, sync.
docs/                 How and why.
scripts/              age key generation, leak check, render check.
```

The split that matters: `clusters/homelab/` contains only Argo `Application`
objects, the three top-level directories contain only manifests and Helm values.

## Documentation

| | |
|---|---|
| [architecture.md](docs/architecture.md) | The hierarchy, layers, sync waves, AppProjects |
| [bootstrap.md](docs/bootstrap.md) | Cold-start procedure |
| [secrets.md](docs/secrets.md) | SOPS + age workflow |
| [networking.md](docs/networking.md) | Gateway API, DNS, certificates, **house-move checklist** |
| [renovate.md](docs/renovate.md) | Comment-driven dependency updates |
| [security-incident.md](docs/security-incident.md) | **Committed credentials — rotation required** |

Runbooks: [*arr ↔ qBittorrent](docs/runbooks/arr-qbittorrent.md) ·
[Immich → VectorChord](docs/runbooks/immich-upgrade.md) ·
[NFS hardening](docs/runbooks/nfs-hardening.md) ·
[Seafile/MariaDB](docs/runbooks/seafile-mariadb-upgrade.md) ·
[Paperless → Postgres](docs/runbooks/paperless-postgres.md)

## Read these first

Three items need a decision or an action before this branch is deployed.

### 1. Every credential in the git history is compromised

An OpenSSH **private key for `root` on the NAS**, a TrueNAS API key, a Cloudflare
token, four OIDC client secrets and five passwords were committed in plaintext.
Private is not secret. All of them must be rotated.

Full inventory and remediation order: [security-incident.md](docs/security-incident.md).

### 2. Immich cannot be upgraded in place

Immich 3.0 dropped pgvecto.rs and requires VectorChord. The database image,
`shared_preload_libraries`, the extension and the Postgres major version all
change together, and it is not reversible.

The `immich` Application is deliberately set to `selfHeal: false` so Argo cannot
roll this forward while you are still reading.
[runbooks/immich-upgrade.md](docs/runbooks/immich-upgrade.md).

### 3. The *arr apps are probably not broken by networking

qBittorrent 4.6.1 removed the `admin`/`adminadmin` default and now generates a
random password on every start. Running `:latest` with `imagePullPolicy: Always`
meant an unrelated pod restart silently crossed that version, and the saved
credentials in Sonarr/Radarr/Lidarr stopped working — which the *arr UIs report as
the client being unavailable.

Strong hypothesis, not confirmed: derived from the manifests and changelog with no
cluster access. One log line confirms it.
[runbooks/arr-qbittorrent.md](docs/runbooks/arr-qbittorrent.md).

## What changed in this restructure

**Actual GitOps.** Previously one Application pointed at `kubernetes/applications`
with `directory.recurse: true`, applying the whole tree as one blob with no
ordering and no way to sync or roll back a single app. Now: root → three layer
app-of-apps → leaves, with sync waves and a per-layer `AppProject` bounding what
each may do. Namespaces are declared explicitly (the `syncthing` namespace
previously existed only because someone had run `kubectl create ns` by hand).

**Ingress → Gateway API.** ingress-nginx was archived by the Kubernetes project in
March 2026 — no more releases, no more security patches. Cilium is now the Gateway
controller, so there is no separate ingress controller at all. One Gateway, one
wildcard certificate, and the WAN IP lives in exactly one file instead of a dozen.

**No plaintext secrets.** SOPS + age. Postgres passwords stopped existing as
artefacts entirely — CloudNativePG generates them into `<cluster>-app` Secrets, so
there is nothing to encrypt, rotate or leak.

**Everything pinned.** Eight workloads ran `:latest` with
`imagePullPolicy: Always`, which turns every pod restart into an unreviewed
upgrade. All pinned and tracked by comment-driven Renovate.

**Correctness fixes found along the way:**

- The CloudNativePG operator was installed into the `immich` namespace.
- Lidarr had a CloudNativePG cluster provisioned but every `LIDARR__POSTGRES__*`
  variable commented out — burning a 5Gi volume and ~200Mi of RAM on an unused
  database while running on SQLite.
- Paperless never set `PAPERLESS_SECRET_KEY`, so Django used the public default
  signing key: session cookies and password-reset tokens were forgeable.
- Paperless' Valkey had no volume, so a restart dropped in-flight OCR jobs.
- Jellyfin published UDP auto-discovery on a ClusterIP, where it can never work.
- Syncthing's StatefulSet named a governing Service that did not exist.
- The media NFS share is mounted at the parent of both `torrents/` and `media/`,
  because hardlinks cannot cross a mount point — splitting them would have
  silently degraded every *arr import to a full copy.
- Plex and Jellyfin now mount media read-only.

## Common tasks

```sh
task --list              # everything below, with descriptions
task tools             # sops, age, kustomize, kubeconform, helm, yq

task secrets:keygen           # once, then back the key up
task secrets:seal -- ...     # encrypt a secret
task secrets:edit -- ...     # edit an encrypted secret
task secrets:leak-check        # refuse plaintext secrets before committing

task build             # render every kustomization
task validate          # render + schema-validate
bash scripts/render-check.sh   # same, without a standalone kustomize binary

task bootstrap:plan
task bootstrap:apply
```

## Status

Verified: all 17 non-SOPS kustomizations render. Chart and image versions checked
against upstream registries as of 2026-07-31.

Not verified — no cluster access at the time of writing:

- nothing has been applied or synced
- the KSOPS decryption path is wired per upstream's documented Helm recipe but has
  not been exercised
- `CiliumL2AnnouncementPolicy` is `cilium.io/v2alpha1` (what Cilium 1.20's own docs
  use) while `CiliumLoadBalancerIPPool` is `cilium.io/v2` — worth re-checking on the
  next Cilium bump; a wrong apiVersion fails loudly at sync
- the L2 policy's `interfaces` regex needs checking against the real NIC names

Next: observability (dashboards, alert rules, retention), then
[NFS hardening](docs/runbooks/nfs-hardening.md).
