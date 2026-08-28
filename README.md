# homelab

> ### ⏭ Bringing the cluster back up after the house move?
>
> **→ [docs/runbooks/restart-after-move.md](docs/runbooks/restart-after-move.md)**
>
> Copy-pasteable, eleven steps, about 1h50. Start at Step 0 and do not skip
> Step 1's gate — `192.168.1.247` is held by a TP-Link Deco unit and the control
> plane needs it.
>
> That runbook restarts the cluster on the **old** layout that is currently live.
> It is not this restructure, and nothing else in this README is needed for it.

GitOps configuration for a four-node Kubernetes cluster on a Turing Pi 2.

Argo CD reconciles everything from this repository. One `Application` is applied
by OpenTofu; every other object in the cluster descends from it.

```
bootstrap/            OpenTofu. Runs once: Cilium, Argo CD, the age key, the root Application.
clusters/homelab/     Argo CD Application + AppProject objects ONLY. The hierarchy.
infrastructure/       CNI, Gateway API, cert-manager, external-dns, CSI, namespaces, network policy.
platform/             CloudNativePG, monitoring, Keycloak, backup verification.
apps/                 Media, photos, documents, recipes, sync.
deploy/               GENERATED. Rendered manifests -- this is what Argo syncs.
ansible/              Node OS and Kubernetes upgrades. Imperative on purpose.
docs/                 How and why.
scripts/              age key, leak/secret/placeholder checks, dumps, dry-run, shutdown/startup.
```

Two splits matter.

`clusters/homelab/` contains only Argo `Application` objects; the three top-level
directories contain only manifests and Helm values.

And **Argo CD never runs kustomize.** `task render` builds every kustomization into
`deploy/`, which is committed and syncs as plain YAML. So a PR diff shows what the
cluster will actually receive, and the `--enable-exec` that KSOPS requires applies
only to the three `*/secrets` directories instead of every kustomization in the
repo. CI fails if `deploy/` does not match its sources. Those three directories are
the deliberate exception — rendering them would decrypt them. Reasoning in
[architecture.md](docs/architecture.md#deploy-rendered-manifests).

Deployment is "move a git tag": every `Application` tracks a tag named `deployed`,
and a rollback is moving it back. See
[ADR 0001](docs/adr/0001-deploy-by-moving-a-git-tag.md).

## Documentation

| | |
|---|---|
| [**runbooks/restart-after-move.md**](docs/runbooks/restart-after-move.md) | **Start here if the cluster is down.** Bring the OLD, live layout back up. Nothing to do with this restructure. |
| [**migration-plan.md**](docs/migration-plan.md) | **Then here.** Ordered, gated path from the running cluster to this repo. Requires a cluster that is up and a proven restore. |
| [architecture.md](docs/architecture.md) | The hierarchy, layers, sync waves, AppProjects, rendered `deploy/` |
| [bootstrap.md](docs/bootstrap.md) | Cold-start procedure |
| [secrets.md](docs/secrets.md) | SOPS + age workflow, and the checks around it |
| [networking.md](docs/networking.md) | Gateway API, DNS, certificates, LB pools, network policy |
| [backups.md](docs/backups.md) | Coverage, restores, what is deliberately not backed up |
| [observability.md](docs/observability.md) | Getting paged: Alertmanager, severities, silences |
| [security-incident.md](docs/security-incident.md) | The credentials that were committed, and the current position on them |
| [adr/](docs/adr/) | Decisions that are expensive to revisit |

Runbooks: [*arr ↔ qBittorrent](docs/runbooks/arr-qbittorrent.md) ·
[Immich → VectorChord](docs/runbooks/immich-upgrade.md) ·
[restart after a move](docs/runbooks/restart-after-move.md) ·
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
Private is not secret.

Three of those must be replaced before the cluster works at all: the NAS SSH key,
the TrueNAS API key and the Cloudflare token. Rotation of the LAN-only application
passwords is **deferred by decision**, on stated conditions, and the history is
scrubbed at the end of the migration. Inventory, conditions and order:
[security-incident.md](docs/security-incident.md).

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

Fixed on the live cluster: qBittorrent binds `:8080` and
`downloadclient/testall` returns `isValid: true` on Sonarr and Radarr. The probes
whose absence hid this for months are in the manifests, and
`ServiceHasNoReadyBackend` is the alert that now carries the verdict off the
cluster.

Still outstanding: `connection_status: firewalled`, which is a router change.
[runbooks/arr-qbittorrent.md](docs/runbooks/arr-qbittorrent.md) has the full
diagnosis, including the hypothesis that was wrong and why.

## Why it is shaped this way

Each of these replaces something that was actively wrong, so the rejected
alternative is named rather than implied.

**A hierarchy, not a blob.** Root → three layer app-of-apps → leaves, with sync
waves and a per-layer `AppProject` bounding what each may do. The alternative,
which is what ran before, is one Application pointed at a directory with
`directory.recurse: true`: no ordering, and no way to sync or roll back a single
app. Namespaces are declared explicitly, because a namespace that exists only
because someone ran `kubectl create ns` does not survive a rebuild.

**Ingress → Gateway API.** ingress-nginx was archived by the Kubernetes project in
March 2026 — no more releases, no more security patches. Cilium is now the Gateway
controller, so there is no separate ingress controller at all. One Gateway, one
wildcard certificate, and **no HTTPRoute or application manifest carries the WAN
IP** — it is an annotation on the Gateway, which is the only place external-dns
honours it. The source of truth is `infrastructure/gateway/gateway.yaml`; the
rendered copy in `deploy/infrastructure/gateway/manifests.yaml` is what Argo reads,
so `task render` after editing it is not optional.

**No plaintext secrets.** SOPS + age. Postgres passwords stopped existing as
artefacts entirely — CloudNativePG generates them into `<cluster>-app` Secrets, so
there is nothing to encrypt, rotate or leak.

**Everything pinned.** Nine workloads ran a floating tag: qBittorrent, all four
*arr apps and Syncthing on `:latest`, Plex and Jellyfin with no tag at all (which
means `:latest`), and Seafile on the `11.0-latest` minor alias — which survived an
earlier pinning sweep precisely because it does not end in `:latest`. Every
`image:` and `imageName:` in the repo now names a concrete tag, each with a
`# renovate:` comment above it. Renovate configuration and its reasoning live
inline in [`.github/renovate.json5`](.github/renovate.json5).

**Constraints that are not obvious and must not be tidied away:**

- The media NFS share is mounted at the **parent** of both `torrents/` and
  `media/`, because hardlinks cannot cross a mount point. Splitting them into two
  PersistentVolumes silently degrades every *arr import to a full copy.
  `infrastructure/nfs-storage/nfs-volumes.yaml` argues this at length.
- Plex and Jellyfin mount media **read-only**; qBittorrent is confined to
  `subPath: torrents`. That is the only part of the NFS threat model this repo can
  control — see [NFS hardening](docs/runbooks/nfs-hardening.md) for the rest.
- Every workload holding a `ReadWriteOnce` volume is `strategy: Recreate` — 13 of
  the 14 Deployments; only `memcached` has no volume. A RollingUpdate cannot work:
  the new pod cannot mount what the old one holds. Applying that over an *existing*
  Deployment needs the one-time patch in
  `scripts/normalize-deployment-strategy.sh`; the header explains why a plain
  server-side apply produces an invalid object.
- Paperless is deliberately still on SQLite. Pointing it at Postgres does not
  migrate the data, it presents an empty archive —
  [runbook](docs/runbooks/paperless-postgres.md).
- Only the `network-policies` Application has `selfHeal: false`, so the documented
  one-command enforcement revert sticks. Do not "fix" it.
- The `all-apps` pin described above. Do not remove it as tidy-up.

## Common tasks

```sh
task --list              # everything below, with descriptions
task tools             # sops, age, kustomize, kubeconform, helm, yq

task secrets:keygen           # once, then back the key up
task secrets:seal -- ...     # encrypt a secret
task secrets:edit -- ...     # edit an encrypted secret
task secrets:leak-check        # refuse plaintext secrets before committing
task lint:secrets              # every KSOPS-referenced file exists and is sealed
task lint:placeholders         # no REPLACE-ME reaches the cluster
task lint                      # all of the above, plus yaml and tofu

task render           # regenerate deploy/ after changing any manifest
task render:check     # what CI gates on
task validate         # render + schema-validate
bash scripts/render-check.sh   # read-only diagnostic: which directory is broken

task backup:dump               # every database to local disk, verified
task backup:set-target -- ...  # point the backups at the real S3 bucket

task bootstrap:plan
task bootstrap:apply
```

## Status

**Nothing in this repo has been synced to the cluster.** The new hierarchy is
inert: the `argocd` namespace does not exist yet, and the old Argo CD still owns
every object.

What the tree is checked against, and by what: the `ci` workflow
([`.github/workflows/ci.yaml`](.github/workflows/ci.yaml)) is the record. It
renders `deploy/` and fails if it does not match its sources, schema-validates the
result against the cluster's Kubernetes version, runs kube-linter and Trivy, and
runs the secret and placeholder checks. Read the latest run rather than a number
copied into prose — measurements go stale here within two commits.

Locally: `task validate`, `bash scripts/leak-check.sh`,
`bash scripts/dryrun-server.sh`. The dry-run script carries the list of failures
that are *expected* on the current cluster (namespaces this change creates, the
Deployments needing the `RollingUpdate → Recreate` patch, Immich's database
migration), so it can tell you whether anything is failing for an undocumented
reason.

Verified against the live cluster rather than assumed: Cilium 1.16.3 serves
`v2alpha1` only, for both `CiliumLoadBalancerIPPool` and
`CiliumL2AnnouncementPolicy`; the L2 `interfaces` regex matches the real NIC
(`eth0` on all four nodes); Gateway API v1.2.0 on the **experimental** channel;
CNPG 1.24.1, which is why the in-tree `barmanObjectStore` is used rather than the
Barman Cloud plugin.

Not exercised yet:

- the KSOPS decryption path — wired per upstream's documented Helm recipe, but no
  Argo CD in the `argocd` namespace has read a `*.sops.yaml` yet
- the backups and their verification jobs — they need the S3 bucket and the
  `s3-backup` Secret to exist first. See the checklist in
  [backups.md](docs/backups.md#before-any-of-this-works)
- Alertmanager — the receivers are configured but the `alertmanager-notify` Secret
  does not exist, and the pod will not start without it.
  [observability.md](docs/observability.md)
- network policy enforcement — the policies are shipped inert on purpose.
  [networking.md](docs/networking.md#network-policy)
- the Gateway itself, which cannot get an address until ingress-nginx releases
  192.168.1.254

Next: [NFS hardening](docs/runbooks/nfs-hardening.md).
