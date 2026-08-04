# Migration plan

This repo is a **rewrite**, not a diff. Pointing the running Argo CD at it and
letting it sync would be an outage. This document is the ordered, gated path from
what is running today to what is in `main`.

Everything below was checked against the live cluster, not inferred. Where a
claim comes from a command, the command is included so you can re-verify it.

- [Read this first: the prune hazard](#read-this-first-the-prune-hazard)
- [Where things actually stand](#where-things-actually-stand)
- [Prerequisites](#prerequisites)
- [Cutover, phase by phase](#cutover-phase-by-phase)
- [One-time normalisations](#one-time-normalisations)
- [Version upgrades, after cutover](#version-upgrades-after-cutover)
- [Pre-existing problems](#pre-existing-problems)
- [Rollback](#rollback)

---

## Read this first: the prune hazard

The live `all-apps` Application was configured like this:

```
path:            kubernetes/applications
targetRevision:  HEAD
prune:           true
selfHeal:        true
```

This repo **deletes `kubernetes/`**. So the sequence "merge to `main`, Argo
notices" would have been: source path disappears → the desired state becomes
empty → `prune: true` deletes every managed object in the cluster.

That is a full self-inflicted outage, including the PVCs it does not own but
whose owners it does.

It has been defused. Applied on 2026-07-31:

```sh
kubectl -n argo patch application all-apps --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":false,"selfHeal":true}}}}'

# Pin to the last commit that predates the restructure, so `HEAD` moving
# cannot drag the cluster along with it.
kubectl -n argo patch application all-apps --type merge \
  -p '{"spec":{"source":{"targetRevision":"c2dbd3503bea688af674aa22e9ccd4fced6e7fff"}}}'
```

Verify before you touch anything:

```sh
kubectl -n argo get application all-apps \
  -o jsonpath='revision={.spec.source.targetRevision} prune={.spec.syncPolicy.automated.prune}{"\n"}'
# expected: revision=c2dbd3503bea688af674aa22e9ccd4fced6e7fff prune=false
```

**This pin is load-bearing. Do not remove it as tidy-up.** It is removed in
[Phase 6](#phase-6-decommission), deliberately, after the new hierarchy owns
everything.

Merging the PR to `main` is therefore **safe on its own** — nothing consumes
`main` until Phase 1.

---

## Where things actually stand

Collected 2026-07-31 against `https://192.168.1.11:6443`.

### Platform

| Component | Running | This repo declares | Gap |
|---|---|---|---|
| Kubernetes | **v1.31.2** | CI validates at 1.31.2 | none — deliberate |
| Node OS | Ubuntu 22.04.5, kernel 5.10.160-rockchip, arm64 | — | 22.04 goes EOL Apr 2027 |
| containerd | 1.7.24 | — | — |
| Cilium | **1.16.3** | 1.16.3 | none — deliberate |
| Gateway API CRDs | **v1.2.0, `experimental` channel** | v1.2.0 experimental | none — deliberate |
| Argo CD | **v2.9.3** (chart 5.53.0), ns **`argo`** | chart 10.2.1 (Argo 3.x), ns **`argocd`** | major + namespace move |
| cert-manager | v1.15.0 | v1.21.1 | 6 minors |
| CloudNativePG | **1.24.1** (chart 0.22.1), ns **`immich`** | chart 0.29.0, ns **`cnpg-system`** | major + namespace move |
| democratic-csi | chart 0.14.7, image `:latest` | chart 0.15.1, pinned image | 1 minor |
| external-dns | v1.15.0 | chart 1.21.1 | 6 minors |
| ingress-nginx | chart 4.11.3, ns `ingress`, holds **192.168.1.254** | **removed** | decommission |
| kube-prometheus-stack | 56.2.0, ns `monitoring` | 88.0.1 | 32 majors — staged separately |
| Traefik | `ingressclass` exists, unused | **removed** | delete |

### Workloads

| App | Running | Repo | Note |
|---|---|---|---|
| Immich | `immich-server:v2.3.1`, chart 0.10.3 | v3.x, chart 0.13.1 | **breaking**, see [immich-upgrade.md](./runbooks/immich-upgrade.md) |
| Immich DB | `cloudnative-pgvecto.rs:16.5-v0.3.0` | `cloudnative-vectorchord:17-1.1.0` | **PG major + extension swap** |
| Keycloak | `keycloak:26.0.5` | `26.7.0` | in-place, fine |
| Seafile MariaDB | `mariadb:10.11` (EOL) | `mariadb:12.3` | **no major skipping**, see [runbook](./runbooks/seafile-mariadb-upgrade.md) |
| Seafile | `seafile-mc:11.0-latest` | pinned | floating tag today |
| Paperless | `paperless-ngx:2.13.5` | pinned newer | stays on SQLite, see [runbook](./runbooks/paperless-postgres.md) |
| Mealie | `mealie:v2.4.0` | pinned newer | |
| *arr, qBittorrent | **`:latest`** | pinned | floating tags today |
| Plex, Jellyfin | **no tag at all** (= `latest`) | pinned | floating tags today |
| Other Postgres | `postgresql:17.0` ×6 | `17.6` | patch bump, safe |

Cluster names match the repo exactly (`immich-db`, `keycloak-db`,
`mealie-postgresql`, `{sonarr,radarr,lidarr,prowlarr}-postgresql`), so the
backup and verification manifests address real objects.

The floating tags are worth dwelling on: `theater/*` running `:latest` means
**you do not know what is deployed and cannot reproduce it.** It is also how
qBittorrent silently moved 5.2.0 → 5.2.3 during an unrelated pod restart. Pinning
them is one of the more valuable parts of this change.

### Routing: the part that changes shape

Today: one nginx Ingress on `theater.lilalala.com` doing path-based fan-out.

```
theater.lilalala.com/               -> plex
theater.lilalala.com/arr/radarr     -> radarr
theater.lilalala.com/arr/sonarr     -> sonarr
theater.lilalala.com/arr/prowlarr   -> prowlarr
theater.lilalala.com/arr/lidarr     -> lidarr
```

Target: one hostname per app, each served at `/`.

**Verified this is safe:** none of the *arr `config.xml` files contain a
`<UrlBase>` element, so the apps already serve from root and need no
reconfiguration.

```sh
kubectl -n theater exec deploy/sonarr -- cat /config/config.xml | grep -c UrlBase   # 0
```

What it does need is **DNS and certificates** for the new names before the routes
go live:

| New hostname | Backend | Existed before? |
|---|---|---|
| `sonarr.lilalala.com` | sonarr | no |
| `radarr.lilalala.com` | radarr | no |
| `lidarr.lilalala.com` | lidarr | no |
| `prowlarr.lilalala.com` | prowlarr | no |
| `qbittorrent.lilalala.com` | qbittorrent | **no — had no external route at all** |
| `theater.lilalala.com` | plex | yes |
| `argo.lilalala.com` | Argo CD | yes |
| `media`, `auth`, `cook`, `archive`, `drive`, `syncthing`, `cinema`, `grafana` | unchanged | yes |

external-dns is running and manages these, so the records follow the Gateway
automatically — but only once the Gateway has an address.

### The 192.168.1.254 handover

```sh
kubectl -n ingress get svc ingress-nginx-controller -o wide
# EXTERNAL-IP  192.168.1.254
```

`ingress-nginx-controller` holds `192.168.1.254`, which is the whole of the
`gateway` LB pool (`192.168.1.254/32`). Two services cannot share it.

So the Gateway **cannot get its address until ingress-nginx gives it up**. This
is an unavoidable, brief, all-services interruption — plan it, don't discover it.
Details in [Phase 3](#phase-3-gateway-and-the-ip-handover).

> The LB pools were also corrected during this work. An earlier draft used
> `192.168.1.240-249`, which overlaps `homelab-w-1` (.240) and `homelab-cp-1`
> (.247). Handing a node's own IP to a LoadBalancer would have been an
> interesting afternoon. Pools are now `192.168.1.254/32` and `192.168.2.0/24`.

---

## Prerequisites

Do all of these before Phase 1. None of them change running workloads.

- [x] **Backups exist and have been verified.** Done 2026-08-03:
      `task backup:dump` took all nine databases (390MB, 9/9 verified), and
      `task backup:verify-restore` restored `mealie` and `immich` into throwaway
      clusters and matched every row count against live. See
      [backups.md](./backups.md). **Re-run it immediately before starting** —
      a backup from days ago is not a backup of today.
- [ ] **Immich library volume snapshotted** on TrueNAS. It is the one
      irreplaceable thing here.
- [ ] `all-apps` still pinned and `prune: false` — re-check with the command
      above.
- [x] **`cilium-mgr9z` fixed** — the DaemonSet is 4/4 and the datapath on
      `homelab-cp-2` is verified working. Phase 3 now has one variable, not two.
- [ ] **Seal the Cloudflare Secrets before syncing `cert-manager-issuers` or
      `external-dns`.** They replace live Secrets in place, and getting the name
      wrong fails silently — see [the repo bugs
      below](#two-repo-bugs-this-turned-up-now-fixed). Certificates renew
      2026-08-11, so a broken issuer has a deadline.
- [ ] **age key generated and stored somewhere that is not this cluster.**
      `scripts/age-key.sh`. Losing it means losing every encrypted secret.
- [ ] **Secrets encrypted.** `scripts/secrets-inventory.sh` writes the values
      currently in the cluster to a git-ignored file for copy-paste. Then
      `task secrets:seal`.
- [ ] `bash scripts/leak-check.sh` passes.
- [ ] `bash scripts/render-check.sh` passes.
- [ ] `bash scripts/dryrun-server.sh` shows only the known-benign failures
      (namespaces this change itself creates: `argocd`, `gateway`,
      `backup-verify`, `cnpg-system`).
- [ ] **DNS records for the five new hostnames** resolve, or external-dns is
      confirmed working with a test record.
- [ ] [One-time normalisations](#one-time-normalisations) applied.
- [ ] You have a terminal with working `kubectl` **and are physically able to
      reach the machines**. Phase 3 briefly breaks ingress.

---

## Cutover, phase by phase

Each phase has a gate. **If a gate fails, stop and roll back that phase** — do
not continue and hope a later phase fixes it.

Sync manually throughout. Do not enable `selfHeal` on anything until its phase
has passed its gate.

### Phase 0 — merge, change nothing

Merge the PR to `main`. Nothing reads `main` yet, because `all-apps` is pinned to
`c2dbd35`. This is deliberately a no-op, so that later phases are `git`-clean.

**Gate:** `kubectl -n argo get applications` — everything still `Synced`/`Healthy`.

### Phase 1 — Argo CD side by side

The new hierarchy declares `namespace: argocd`; the running Argo CD is in `argo`.
Rather than move a running controller, install the new one alongside:

```sh
cd bootstrap
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars          # git_username, target_revision, api_server_ip

# The age key and the git token go through the environment, never into a file
# on disk. See the comment at the top of terraform.tfvars.example.
export TF_VAR_sops_age_key="$(cat ~/.config/sops/age/keys.txt)"
export TF_VAR_git_token="ghp_..."

tofu init
tofu plan
```

Read the plan properly. It should create: namespace `argocd`, two Secrets, the
`argo-cd` Helm release, the root Application. It should **adopt** Cilium 1.16.3,
not change it — if the plan wants to modify the Cilium release, stop.

```sh
tofu apply
```

Then immediately, before it syncs anything:

```sh
kubectl -n argocd patch application root --type merge \
  -p '{"spec":{"syncPolicy":null}}'
```

Now two Argo CDs are running. The old one owns everything and is pinned; the new
one owns nothing and syncs nothing. That is the intended state.

**Gate:** `argocd` pods Ready; the new UI lists the Applications as
`OutOfSync`/`Missing`; the old Argo CD is untouched; no workload restarted.

**Rollback:** `tofu destroy`. The old Argo CD never stopped owning anything.

### Phase 2 — infrastructure, except the Gateway

Sync in this order, gating each:

1. `namespaces` — creates the new `gateway`, `cnpg-system` and `backup-verify`
   namespaces (and adopts the existing app namespaces), applying Pod Security
   labels to all of them. `argocd` is not here: OpenTofu creates it in Phase 1,
   because Argo CD cannot create the namespace it is installed into. Once this
   syncs, the "namespace not found" dry-run failures disappear — which is why
   they were benign rather than real.
2. `gateway-api` — CRDs only. **Pinned to v1.2.0 `experimental`** to match what
   is installed. This matters: the repo only uses `Gateway`, `HTTPRoute`,
   `GRPCRoute` and `ReferenceGrant`, all of which are in the *standard* channel,
   so `standard-install.yaml` looks like the tidier choice — but applying it
   would **delete** the `TCPRoute`, `UDPRoute`, `TLSRoute` and `BackendLBPolicy`
   CRDs that the experimental channel installed, and Cilium's operator watches
   them. Moving to the standard channel is a separate, deliberate decision.
3. `cilium` — pinned to **1.16.3**, the running version. This is an **adoption,
   not an upgrade**. `values.yaml` also has `bpf.masquerade: false` and
   `encryption.enabled: false` to match the live datapath (IPTables masquerading,
   no WireGuard). Changing the datapath during a restructure would make any
   network problem impossible to attribute.
4. `democratic-csi`, `cert-manager`, `external-dns`, `nfs-storage`.

**Gate after each:** `kubectl get pods -A | grep -v Running\|Completed` is empty
(except the known-broken `cilium-mgr9z`, see
[pre-existing problems](#pre-existing-problems)), and:

```sh
kubectl get httproute,gateway -A                # still nothing, expected
kubectl -n theater exec deploy/sonarr -- curl -sf -o /dev/null -w '%{http_code}\n' \
  http://qbittorrent:8080/api/v2/app/version    # 200 -- pod networking intact
```

**Gate for Cilium specifically** — connectivity is the thing most likely to
break, and the most confusing when it does:

```sh
kubectl -n kube-system get ds cilium          # desired == ready (minus cilium-mgr9z)
kubectl -n kube-system exec ds/cilium -- cilium status --brief
kubectl get ciliumloadbalancerippools.cilium.io   # gateway + services pools
```

### Phase 3 — Gateway and the IP handover

This is the disruptive phase. Everything before it was additive.

Order matters, because `192.168.1.254` can only belong to one Service:

```sh
# 1. Create the Gateway and all HTTPRoutes. The Gateway will sit Pending
#    without an address -- that is expected and harmless.
#    (sync the `gateway` Application, then the per-app routes)
kubectl -n gateway get gateway shared

# 2. Confirm the GatewayClass is actually accepted. It reported
#    ACCEPTED=Unknown before this work, because no Gateway had ever existed.
kubectl get gatewayclass cilium -o jsonpath='{.status.conditions}' ; echo

# 3. Release the address. THIS IS THE OUTAGE. All ingress stops here.
kubectl -n ingress scale deploy ingress-nginx-controller --replicas=0
kubectl -n ingress delete svc ingress-nginx-controller

# 4. Cilium should now assign .254 to the Gateway within a few seconds.
kubectl -n gateway get gateway shared -o wide
kubectl -n gateway get svc            # cilium-gateway-shared -> 192.168.1.254
```

**Gate:**

```sh
for h in theater.lilalala.com auth.lilalala.com media.lilalala.com \
         drive.lilalala.com cook.lilalala.com archive.lilalala.com \
         sonarr.lilalala.com qbittorrent.lilalala.com; do
  printf '%-30s %s\n' "$h" \
    "$(curl -sk -o /dev/null -w '%{http_code}' -H "Host: $h" https://192.168.1.254/)"
done
```

Every host must return something that is not a connection error or `404` from the
Gateway itself. `302` (login redirect) and `200` are both fine.

Then check certificates — a working route with a bad certificate is still an
outage for anything that validates TLS:

```sh
bash scripts/tls-check.sh
kubectl get certificate -A
```

**Rollback:** re-enable ingress-nginx. Keep the old Application ready to sync:

```sh
kubectl -n gateway delete gateway shared      # frees .254
kubectl -n argo app sync nginx                # recreates the LB Service
kubectl -n ingress scale deploy ingress-nginx-controller --replicas=1
```

Because the Ingress objects were never deleted, this restores the previous state
in full. **Do not delete any Ingress object until Phase 6.** They cost nothing
while nginx is scaled to zero, and they are the rollback path.

### Phase 4 — platform

1. `secrets-platform` — needs KSOPS working in the new repo-server. Verify the
   age key is mounted before blaming the manifests:
   ```sh
   kubectl -n argocd exec deploy/argocd-repo-server -- ls -l /helm-secrets-private-keys/
   ```
2. `cloudnative-pg` — installs the operator into `cnpg-system`. The running
   1.24.1 operator lives in `immich`, which is an odd place for a cluster-scoped
   controller. Two operators watching the same CRD **will fight.** Scale the old
   one to zero *before* syncing the new one, and do not delete it until the new
   one has reconciled every Cluster:
   ```sh
   kubectl -n immich scale deploy cnpg-cloudnative-pg --replicas=0
   # sync cloudnative-pg, then:
   kubectl get clusters.postgresql.cnpg.io -A     # all "Cluster in healthy state"
   ```
3. `keycloak` — image bump plus the move to a Secret-sourced bootstrap admin.
4. `backup-verify` — new, touches nothing existing.

Leave `barman-cloud-plugin` **out**. It needs CNPG ≥ 1.26; see
[the CNPG note](#cloudnativepg-and-barman) below.

**Gate:** every Postgres Cluster healthy, Keycloak reachable, and a manual backup
verification run passes:

```sh
kubectl -n backup-verify create job --from=cronjob/backup-verify-postgres check
kubectl -n backup-verify logs -f job/check
```

### Phase 5 — apps, one at a time

`immich` last, and read [immich-upgrade.md](./runbooks/immich-upgrade.md) first.

Order: `syncthing` → `mealie` → `paperless` → `seafile` → `theater` → `immich`.

Cheapest-to-recover first, so that if the machinery is wrong you learn it on
Syncthing rather than on the photo library.

For each: sync, wait for Healthy, exercise the actual app in a browser, then move
on. `theater` additionally needs the *arr ↔ qBittorrent link re-tested, because
that was the original reported fault:

```sh
kubectl -n theater exec deploy/sonarr -- curl -s -X POST \
  -H "X-Api-Key: $(kubectl -n theater exec deploy/sonarr -- \
     sh -c 'grep -o "<ApiKey>[^<]*" /config/config.xml | cut -d">" -f2')" \
  http://localhost:8989/api/v3/downloadclient/testall
# expected: [{"id":1,"isValid":true,"validationFailures":[]}]
```

`seafile` needs the MariaDB runbook — `10.11` → `12.3` cannot skip majors.

**Gate per app:** Healthy, reachable, and its data present. Not "the pod is
Running".

### Phase 6 — decommission

Only when every phase above has passed and you have used the cluster normally for
a few days.

```sh
# The old Ingress objects, now that the Gateway has proven itself.
kubectl -n argo delete application nginx
kubectl delete ns ingress
kubectl delete ingressclass traefik nginx

# The old Argo CD. Removing all-apps LAST, and only with prune still false.
kubectl -n argo delete application all-apps --cascade=orphan
kubectl -n argo delete application cert-manager cnpg external-dns immich \
  kube-prometheus-stack --cascade=orphan
helm -n argo uninstall argocd
kubectl delete ns argo db
```

`--cascade=orphan` is not optional. Without it, deleting the Application deletes
the workloads.

Then, and only then, enable `selfHeal` in the new hierarchy — layer by layer, in
the same order as the phases.

**Gate:** `kubectl -n argocd get applications` all Synced/Healthy, and
`kubectl get all -A` contains nothing owned by the old release.

---

## One-time normalisations

Things the API server will not let a declarative apply do. Run them before the
phase that needs them.

### Deployment strategy: `RollingUpdate` → `Recreate`

Thirteen Deployments should be `Recreate`; seven currently are not. Single
replicas on ReadWriteOnce iSCSI volumes cannot roll: the replacement pod waits
forever for a volume the old pod still holds.

An apply cannot fix this on its own:

```
spec.strategy.rollingUpdate: Forbidden: may not be specified when
strategy `type` is 'Recreate'
```

The API server defaulted `rollingUpdate` when the Deployment was created. A
server-side apply only manages fields it *sets*, so it will not remove that
block, and `--force-conflicts` does not help — there is no conflict, nobody is
claiming the field. Writing `rollingUpdate: null` in the manifest does not work
either; under SSA a null means "I don't manage this", not "delete it".

A strategic-merge **patch** with an explicit null does remove it:

```sh
bash scripts/normalize-deployment-strategy.sh          # report only
bash scripts/normalize-deployment-strategy.sh --apply  # patch
```

**This is not disruptive.** Verified in a throwaway namespace: the pod template
is unchanged, so no new ReplicaSet is created and no pod restarts. Only
`metadata.generation` moves; `Recreate` takes effect at the next rollout.

Affected: `keycloak/keycloak`, `paperless/valkey`, `seafile/mariadb`,
`theater/{lidarr,prowlarr,radarr,sonarr}`. Already correct:
`mealie/mealie`, `paperless/paperless`, `seafile/seafile`,
`theater/{jellyfin,plex,qbittorrent}`.

### Immutable fields left deliberately alone

`spec.selector` on a Deployment and `spec.serviceName` /
`spec.volumeClaimTemplates` on a StatefulSet are immutable. Normalising them
means delete + recreate, which for a StatefulSet means detaching volumes.

So the repo **keeps the existing values** rather than the tidier ones:

| Object | Kept | Would prefer | Cost of changing |
|---|---|---|---|
| `seafile/mariadb` | `selector: app: mariadb` | `app.kubernetes.io/name` | delete + recreate Deployment |
| `seafile/memcached` | `selector: app: memcached` | `app.kubernetes.io/name` | delete + recreate Deployment |
| `syncthing` StatefulSet | `serviceName: syncthing`, standalone PVC `syncthing-pvc` | headless Service + `volumeClaimTemplates` | delete + recreate, volume detach |

Both label spellings are set on the pod templates, so a future migration is a
one-line selector change plus a recreate — not a re-labelling exercise.

This is why `labels:` with `includeSelectors: false` is used in the
kustomizations instead of `commonLabels`: `commonLabels` injects into
`spec.selector` and would make every one of these an immutable-field error.

---

## Version upgrades, after cutover

**Do not do any of this during the cutover.** The point of pinning everything to
the running version is that if the restructure breaks something, the version is
not a suspect.

Do them one at a time, with a gate, in this order.

### 1. Kubernetes 1.31 → newer

`ansible/kube-upgrade.yml`, **one minor at a time** — `kubeadm` supports n → n+1
only.

```sh
cd ansible
ansible-playbook kube-upgrade.yml -e kube_version=1.32.0 --check
ansible-playbook kube-upgrade.yml -e kube_version=1.32.0
```

Before each minor, confirm the running Cilium supports the target Kubernetes
version. Cilium 1.16 does not support arbitrarily new Kubernetes, so in practice
Cilium and Kubernetes leapfrog each other. The playbook asserts this and refuses
to run blind.

Bump `K8S_VERSION` in `.github/workflows/ci.yaml` afterwards, or CI keeps
validating against the old schema.

### 2. Ubuntu 22.04 → 24.04

`ansible/os-upgrade.yml`, one node at a time with drain/uncordon.

Note the kernel is `5.10.160-rockchip` — a vendor kernel for the RK1 modules, not
Ubuntu's. A release upgrade may or may not carry it forward, and Cilium's eBPF
features depend on it. **Do one node and live with it for a week** before doing
the rest. This is also the moment where [Talos](./talos-migration.md) becomes the
more attractive option.

### 3. Cilium 1.16.3 → 1.20

One minor at a time: 1.16 → 1.17 → 1.18 → 1.19 → 1.20. Cilium does not support
skipping minors, and each step needs the matching CRD versions.

Watch specifically for:

- `ciliumloadbalancerippools` and `ciliuml2announcementpolicies` currently serve
  **only `v2alpha1`**. Newer Cilium promotes these to `v2`. Once the cluster
  serves `v2`, `infrastructure/cilium/ip-pools.yaml` and
  `l2-announcement-policy.yaml` must be bumped — and the `v2alpha1` version may
  stop being served, which breaks the apply, not just a warning.
- Gateway API support: each Cilium minor supports a specific Gateway API range.
  Upgrade Cilium first, then the CRDs.

### 4. Gateway API v1.2.0 → v1.6.x

After Cilium. Still the **experimental** channel unless you have deliberately
established nothing needs `TCPRoute`/`UDPRoute`/`TLSRoute`/`BackendLBPolicy`.
Switching channels deletes CRDs.

### 5. Argo CD 2.9.3 → 3.x

Already handled structurally by Phase 1 (side-by-side install of chart 10.2.1),
so by the time you get here it is done. Kept in this list because the version gap
is large enough that anyone reading only the table will wonder.

Argo CD 3.x changed defaults around resource tracking and RBAC. The side-by-side
approach exists precisely so those defaults are exercised on a controller that
owns nothing yet.

### 6. CloudNativePG and Barman

<a id="cloudnativepg-and-barman"></a>

The operator is **1.24.1**. Every database in this repo therefore uses the
in-tree `spec.backup.barmanObjectStore`.

This was not a style choice. The plugin form fails on 1.24.1, confirmed by
server-side dry-run:

```
.spec.plugins[0].isWALArchiver: field not declared in schema
no matches for kind "ObjectStore" in version "barmancloud.cnpg.io/v1"
```

CNPG deprecated the in-tree field in 1.26, so this is a stopgap with a known end
date. The sequence:

1. Upgrade CNPG to ≥ 1.26 (chart 0.29.0), one minor at a time.
2. Enable the plugin: add `barman-cloud-plugin.yaml` to
   `clusters/homelab/platform/kustomization.yaml`. The manifest is already
   written and deliberately not referenced.
3. Convert each Cluster from `spec.backup.barmanObjectStore` to an `ObjectStore`
   CR plus `spec.plugins`.
4. Convert `platform/backup-verify/restore-postgres.yaml` the same way.
5. Re-run backup verification **before** deleting the old configuration.

Do not do 1 and 2 in the same sync. The plugin runs as a sidecar, so enabling it
rolls every database pod.

### 7. Immich

The genuinely irreversible one. [immich-upgrade.md](./runbooks/immich-upgrade.md).
`pgvecto.rs` on PG 16.5 → VectorChord on PG 17, which is an extension migration
and a Postgres major upgrade simultaneously. Immich 3.0 removed pgvecto.rs
support, so it is not optional, only schedulable.

Renovate holds Immich majors behind `dependencyDashboardApproval` so this cannot
arrive unannounced.

### 8. kube-prometheus-stack 56.2.0 → 88.0.1

Thirty-two majors. Mostly CRD churn, and the CRDs are cluster-scoped and shared.
Treat it as its own project, after everything else is stable. This is also where
the observability work the user asked for lands, so it is worth doing properly
rather than as a version bump.

### 9. The floating tags

`theater/*`, Plex and Jellyfin run `:latest`. Pinning them means the first sync
may move them several versions at once. Check each app's release notes for the
range, and expect Plex and Jellyfin to want a database migration on first start.

---

## Pre-existing problems

Found during recon. **None are caused by this restructure**, and none block it,
but do not let the cutover get blamed for them.

### FIXED — `cilium-mgr9z` on `homelab-cp-2`, broken for 140 days

Resolved 2026-08-04. Recorded because the diagnosis was not what it looked like.

The pod sat in `CreateContainerError` with 298 restarts. The obvious reading was
the error in its logs:

```
dial tcp 192.168.1.11:6443: connect: no route to host
```

That was the **historic trigger**, timestamped 2026-04-06, and by itself it is
misleading. It came from `lastState`, not the current state. A transient outage of
the kube-vip-managed API VIP crashed the agent once, in April.

What kept it down for the next four months was containerd:

```
failed to reserve container name "cilium-agent_cilium-mgr9z_kube-system_99eac073-…_299":
name is reserved for "9d25541fe3f392f5973235a2f1ed1df5b031000b9ff4acad1afa6d2a611827ad"
```

A stale container-name reservation. The kubelet retried **790,890 times over 119
days** and could never win, because the name it wanted was permanently held by a
dead sandbox.

The fix needed no containerd surgery. The pod UID is part of the container name,
so deleting the pod produces a new UID, a new name, and no collision:

```sh
kubectl -n kube-system delete pod cilium-mgr9z
```

It was safe to do at any point: the node carried Cilium's own
`node.cilium.io/agent-not-ready:NoSchedule` taint and every pod on it was
`hostNetwork`, so nothing was using that CNI to begin with.

Verified afterwards, rather than assumed:

```
agent            Running 1/1, 0 restarts, 24/24 controllers healthy
DaemonSet        4/4 ready (first time in 140 days)
taint            cleared automatically
cluster health   4/4 reachable
real datapath    test pod on cp-2 got 10.0.0.3, resolved via kube-dns, and
                 reached qbittorrent on another node -> HTTP 200
```

The lesson worth keeping: `kubectl get pods` showed a plausible-looking crash
loop, and the log line pointed at the network. Neither was the current cause.
Read `state`, not just `lastState`.

**Watch the API VIP anyway.** `kube-vip-homelab-cp-2` has 61 restarts (most
recent 12 days ago) and `kube-apiserver-homelab-cp-2` has 100. The April outage
that started this was real. If Phase 3 sees odd behaviour, this is a suspect.

### FIXED — stray objects

- `ssh-node-7uqwbs` in `kube-system` (`Failed`, no owner) — deleted.
- `test-cert` in `default` — deleted, along with `test-cert-tls`. See below,
  because it was not the throwaway it looked like.

### `test-cert` was evidence, not litter

It requested `lilalala.com` **and** `*.lilalala.com` — the wildcard certificate
the Gateway design depends on. Worth knowing before Phase 3:

- **Wildcard issuance does work here.** Orders `test-cert-1/2/3` all reached
  `valid`. The issuer uses DNS-01 via Cloudflare, which is the only solver that
  can do wildcards.
- `test-cert-4` had been stuck `pending` for **474 days**, with two challenges for
  `lilalala.com` (apex and wildcard both validate at
  `_acme-challenge.lilalala.com`) and one of them never completing. Long past
  Let's Encrypt's 7-day order expiry, so it was permanently dead, not slow.
- The ten real certificates are all `Ready: True` and renew **2026-08-11**. So
  certificate issuance is healthy; only this one object was wedged.

Deleted so that Phase 3 starts from a clean cert-manager, and so a genuine
wildcard failure is visible rather than lost in existing noise.

### Two repo bugs this turned up, now fixed

Both would have broken a working system on first sync, and both are the same
mistake: inventing a tidier name for something that already exists.

| Repo said | Cluster has | What would have happened |
|---|---|---|
| Secret `cloudflare-api-token` | `cloudflare-api-token-secret`, in **both** `cert-manager` and `external-dns` | ClusterIssuer and external-dns would reference a Secret that does not exist. Certificate renewal fails **quietly**; renewals are due 2026-08-11 and all ten certs expire 2026-09-10 |
| `privateKeySecretRef: letsencrypt-account-key` | `letsencrypt` | cert-manager generates a new ACME **account key**, registers a new Let's Encrypt account, and abandons the existing one (`acct/2075617627`) with its authorizations — against an endpoint that rate-limits account creation |

The repo now uses the live names. The tidier ones were not worth a silent
certificate outage.

### Still outstanding

- Namespace `db` is **empty** — leftover, deleted in Phase 6.
- The `immich` Application reports `SYNC: Unknown` on the old Argo CD. Worth
  understanding before Phase 5 rather than during it.
- qBittorrent reports `connection_status: firewalled`. The router is not
  forwarding TCP/UDP 50000 to `qbittorrent-seed` (192.168.2.1). Downloads work;
  seeding is degraded. This is a **router** change, and it will need redoing after
  the house move — see [house-move.md](./runbooks/house-move.md).
- `democratic-csi` runs `democraticcsi/democratic-csi:latest`. A CSI driver on a
  floating tag can break volume attachment on any pod restart.
- `/controller` on the nodes is at **83% disk use** (29GB eMMC). Not urgent, but
  it is the volume kubelet and containerd live on, and it is what made a
  source-side checksum awkward in `scripts/dump-databases.sh`.

---

## Rollback

The property that makes this safe is that **the old Argo CD keeps ownership of
everything until Phase 6.** Up to that point, rollback is "stop using the new
one".

| Phase | Rollback | Recovers to |
|---|---|---|
| 0 | revert the merge | identical |
| 1 | `tofu destroy` | identical |
| 2 | sync the old Application for that component | identical |
| 3 | delete Gateway, restore nginx Service, scale up | identical — Ingress objects were never deleted |
| 4 | scale old CNPG operator back up; re-sync old apps | identical |
| 5 | per-app: sync the old Application | identical, except Immich after its migration |
| 6 | **none** | — |

Two irreversible points, both flagged where they occur:

1. **Immich's database migration** (Phase 5). Once Immich 3.x has migrated the
   schema, the 2.x image will not start on it. The library files are untouched
   either way — which is why the prerequisite is a snapshot of the library
   volume, separately from the database dump.
2. **Phase 6.** Deleting the old Argo CD and the `ingress` namespace removes the
   rollback path. Do not start Phase 6 to tidy up; start it because the new setup
   has been carrying real traffic for days.

For anything Argo-managed, the general rollback is to pin the Application to the
last known-good commit rather than to revert files:

```sh
kubectl -n argocd patch application <app> --type merge \
  -p '{"spec":{"source":{"targetRevision":"<sha>"}}}'
```

This is also what CD automation does on a failed health gate — see
`.github/workflows/cd.yaml`, which pins, then opens a revert PR rather than
force-pushing a fix.
