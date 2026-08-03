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
deploy/               GENERATED. Rendered manifests -- this is what Argo syncs.
ansible/              Node OS and Kubernetes upgrades. Imperative on purpose.
docs/                 How and why.
scripts/              age key, leak check, render check, live-cluster dry-run.
```

Two splits matter.

`clusters/homelab/` contains only Argo `Application` objects; the three top-level
directories contain only manifests and Helm values.

And **Argo CD never runs kustomize.** `task render` builds every kustomization into
`deploy/`, which is committed and syncs as plain YAML. So a PR diff shows what the
cluster will actually receive, and the `--enable-exec` that KSOPS requires applies
to 3 directories instead of 23. CI fails if `deploy/` does not match its sources.
The three `*/secrets` directories are the deliberate exception — rendering them
would decrypt them. Details in [architecture.md](docs/architecture.md#deploy-rendered-manifests).

## Documentation

| | |
|---|---|
| [**migration-plan.md**](docs/migration-plan.md) | **Start here.** Ordered, gated path from the running cluster to this repo |
| [architecture.md](docs/architecture.md) | The hierarchy, layers, sync waves, AppProjects |
| [bootstrap.md](docs/bootstrap.md) | Cold-start procedure |
| [secrets.md](docs/secrets.md) | SOPS + age workflow |
| [networking.md](docs/networking.md) | Gateway API, DNS, certificates |
| [backups.md](docs/backups.md) | S3 backups, what is deliberately not backed up, restore verification |
| [renovate.md](docs/renovate.md) | Comment-driven dependency updates |
| [talos-migration.md](docs/talos-migration.md) | Study: what moving to Talos would take |
| [security-incident.md](docs/security-incident.md) | **Committed credentials — rotation required** |

Runbooks: [*arr ↔ qBittorrent](docs/runbooks/arr-qbittorrent.md) ·
[Immich → VectorChord](docs/runbooks/immich-upgrade.md) ·
[house move](docs/runbooks/house-move.md) ·
[NFS hardening](docs/runbooks/nfs-hardening.md) ·
[Seafile/MariaDB](docs/runbooks/seafile-mariadb-upgrade.md) ·
[Paperless → Postgres](docs/runbooks/paperless-postgres.md)

## Read these first

### 0. Do not point the running Argo CD at this branch

The live `all-apps` Application had `prune: true` on a path this repo **deletes**.
Merging and letting it reconcile would have pruned the cluster. It is currently
pinned to the pre-restructure commit with `prune: false`, and that pin is
load-bearing — do not remove it as tidy-up.

The cutover is staged, phase by phase, with a gate and a rollback for each:
[**migration-plan.md**](docs/migration-plan.md). Everything in this repo is
pinned to the versions actually running, so the restructure and the upgrades are
separate changes.

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

### 3. The *arr / qBittorrent fault is fixed

Root cause was a stale `ipc-socket` in qBittorrent's config volume, left by an
unclean shutdown in April. It made the process abort ~2s into every start, and s6
restarted it forever inside the container. With **no probes** on the Deployment,
Kubernetes reported `Running 1/1`, `0` restarts and kept the Service endpoint —
routing traffic to a process that was not listening.

Fixed on the live cluster: qBittorrent now binds `:8080` and
`downloadclient/testall` returns `isValid: true` on Sonarr and Radarr. The probes
whose absence hid this for months are now in the manifests.

An earlier version of this README blamed the qBittorrent 4.6.1 credential change.
That was a plausible hypothesis and it was wrong.
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

**Nothing in this repo has been synced to the cluster.** The new hierarchy is
inert: the `argocd` namespace does not exist yet, and the old Argo CD still owns
every object.

Verified against the live cluster on 2026-07-31:

```
leak-check                clean (and proven to reject planted secrets)
renovate annotations      43/43 produce a complete match
kustomize render          19/19 non-SOPS kustomizations
server-side dry-run       ok=8  expected-fail=12  unexpected-fail=0
```

The twelve expected failures are all accounted for in
[migration-plan.md](docs/migration-plan.md): namespaces this change creates,
seven Deployments needing the documented `RollingUpdate → Recreate` patch, and
Immich's database migration. `scripts/dryrun-server.sh` carries that list, so it
can tell you whether anything is failing for an *undocumented* reason.

Also verified on the cluster: Cilium 1.16.3 with `v2alpha1` as the only served
version for both `CiliumLoadBalancerIPPool` and `CiliumL2AnnouncementPolicy`; the
L2 `interfaces` regex against the real NIC (`eth0` on all four nodes); Gateway API
v1.2.0 on the **experimental** channel; CNPG 1.24.1; and that the
`RollingUpdate → Recreate` patch restarts nothing.

Not exercised yet:

- the KSOPS decryption path — wired per upstream's documented Helm recipe, but no
  Argo CD in the `argocd` namespace has read a `*.sops.yaml` yet
- the S3 backups and their verification jobs — they need the bucket and the
  `s3-backup` Secret to exist first
- the Gateway itself, which cannot get an address until ingress-nginx releases
  192.168.1.254

Known pre-existing breakage, unrelated to this work: `cilium-mgr9z` on
`homelab-cp-2` has been in `CreateContainerError` for 137 days, unable to reach the
API VIP. Details in [migration-plan.md](docs/migration-plan.md#pre-existing-problems).

Next: observability (dashboards, alert rules, retention), then
[NFS hardening](docs/runbooks/nfs-hardening.md).
