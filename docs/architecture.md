# Architecture

Argo CD deploys the cluster from this repository: one root Application, three
layers, one Application per app. Every Application tracks `main`. This page is
the shape of that tree and why it has that shape; addresses are in
[networking.md](networking.md), first install in [bootstrap.md](bootstrap.md).

## Cluster

| Part | What |
| --- | --- |
| Board | Turing Pi 2, which powers all four slots on with the board |
| Nodes | 4x Turing RK1 (Rockchip RK3588, arm64, 32 GB RAM, 29 GB eMMC): `homelab-cp-1`..`cp-3` (control plane), `homelab-w-1` (worker) |
| OS | Ubuntu 22.04.5, kernel 5.10.160-rockchip, containerd 1.7.24, static addresses in `/etc/netplan/01-homelab-static.yaml` |
| Kubernetes | kubeadm v1.32.13, stacked etcd 3.5.24 on the three control planes |
| API endpoint | `192.168.1.11:6443`, a VIP held by kube-vip v1.2.4 static pods |
| CNI | Cilium 1.17.18: kube-proxy replacement, LB-IPAM with L2 announcements, Gateway API |
| Storage | TrueNAS CORE at `192.168.1.228`: iSCSI block volumes through democratic-csi, an NFS share for media |
| GitOps | Argo CD v3.4.6 in namespace `argo` (Helm release `argocd`, chart argo-cd 10.2.2) |

Everything runs single-replica. Most workloads hold a `ReadWriteOnce` volume,
so a second replica could not mount it, and there is one storage backend
anyway. Node upgrades are `ansible/kube-upgrade.yml` (one minor at a time) and
`ansible/os-upgrade.yml`, one node at a time. The etcd snapshot task in
`kube-upgrade.yml` calls `etcdctl` on the host, which the nodes do not have, so
the playbook stops at that task until it is fixed ([roadmap](roadmap.md)). Take
the snapshot by hand
([cold-start.md](runbooks/cold-start.md#snapshot)) before any upgrade. Replacing a failed node is
[runbooks/node-replacement.md](runbooks/node-replacement.md).

## The tree

```
bootstrap/root-app.yaml          applied once by hand (kubectl apply)
  root                           -> deploy/clusters/homelab/bootstrap
    project-{infrastructure,platform,apps}   AppProjects, wave -1
    layer-infrastructure         wave 1 -> deploy/clusters/homelab/infrastructure
    layer-platform               wave 2 -> deploy/clusters/homelab/platform
    layer-apps                   wave 3 -> deploy/clusters/homelab/apps
      one Application per app    -> deploy/<layer>/<app>/  or a Helm chart
```

`clusters/homelab/` holds only Argo CD objects (`root.yaml`, the AppProjects,
the layers and the leaf Applications). `infrastructure/`, `platform/` and
`apps/` hold only Kubernetes manifests and Helm values. `bootstrap/root-app.yaml`
and `clusters/homelab/root.yaml` are the same object; CI fails if they differ.

### Layers

| Layer | Applications | Depends on |
| --- | --- | --- |
| infrastructure | `namespaces`, `secrets-infrastructure`, `gateway-api`, `cilium`, `cilium-config`, `cert-manager`, `cert-manager-issuers`, `external-dns`, `gateway`, `democratic-csi` | nothing |
| platform | `secrets-platform`, `cnpg`, `kube-prometheus-stack`, `keycloak` | StorageClasses, certificates |
| apps | `secrets-apps`, `immich`, `mealie`, `paperless`, `seafile`, `syncthing`, `theater` | databases, identity, routing |

Sync waves inside `infrastructure`:

| Wave | Application | Why here |
| --- | --- | --- |
| -30 | `namespaces` | Secrets need their namespace |
| -25 | `secrets-infrastructure` | Before anything mounts one |
| -20 | `gateway-api` | CRDs before Cilium programs a Gateway |
| -10 | `cilium` | CNI |
| -5 | `cilium-config` | LB IP pools and the L2 policy need Cilium's CRDs |
| 0 | `cert-manager` | Its CRDs before any issuer |
| 5 | `cert-manager-issuers` | |
| 10 | `external-dns` | |
| 15 | `gateway` | The shared entrypoint |
| 20 | `democratic-csi` | StorageClasses before any PVC in later layers |

`platform`: `secrets-platform` (-25), `cnpg` (0), `kube-prometheus-stack` (10),
`keycloak` (20). `apps`: `secrets-apps` (-25), every app at 0.

On a cold start `cnpg` fails once with `no matches for kind "PodMonitor"`,
because the Prometheus CRDs arrive with `kube-prometheus-stack` at wave 10. The
retry policy on every Application (5 tries, 5 s doubling to 3 min) absorbs it.

Written but not in any layer yet (each is a behaviour change with its own pull
request): `infrastructure/snapshot-controller`, `infrastructure/nfs-storage`,
`infrastructure/network-policies` (Application files in
`clusters/homelab/infrastructure/`, not listed in its `kustomization.yaml`),
`platform/barman-cloud-plugin`, and `clusters/homelab/staged/backup-verify.yaml`.

### Sync policy

| Applications | Automated | Prune |
| --- | --- | --- |
| `root`, the three layers, `namespaces` | yes, self-heal | no |
| `cilium`, `democratic-csi` | yes, self-heal | no |
| Leaves that ship CRDs: `gateway-api`, `cert-manager`, `cnpg`, `kube-prometheus-stack` | yes, self-heal | no |
| Every other leaf | yes, self-heal | yes |
| `immich` | no: synced by hand | - |

Every PVC, CNPG Cluster, StatefulSet and Namespace carries
`argocd.argoproj.io/sync-options: Delete=false,Prune=false`, and no Application
has the cascading `resources-finalizer`. The photo library PVC
`immich/immich-data` belongs to no Application. The reasons are in
[decisions.md](decisions.md#no-prune-where-a-deletion-is-an-outage).

### AppProjects

Each layer has an `AppProject`. None wildcards cluster-scoped kinds:

- `infrastructure`: an enumerated `clusterResourceWhitelist` (Namespace,
  PersistentVolume, ClusterIssuer, the two Cilium kinds, CRDs, ClusterRole and
  binding, CSIDriver, StorageClass, VolumeSnapshotClass, GatewayClass, the two
  webhook kinds), each entry commented with what needs it.
- `platform`: a shorter enumerated list.
- `apps`: namespaced kinds only, in a fixed list of destination namespaces.

A kind that is not on the list cannot be created by that layer: the sync fails
and names the kind. That is why `infrastructure/network-policies/` uses
namespaced `CiliumNetworkPolicy`, not `CiliumClusterwideNetworkPolicy`. Widening
a list is a deliberate edit with the reason on the same line.

## deploy/: rendered manifests

Argo CD does not run kustomize for most of the tree. `scripts/render-deploy.sh`
renders every kustomization ahead of time into `deploy/`, and the Applications
point there. One file per object, named `<kind>-<name>.yaml` (for example
`deploy/apps/theater/deployment-sonarr.yaml`), so a directory listing is the list
of what runs.

```sh
task render          # regenerate deploy/ after changing a manifest
task render:check    # what CI runs: fails if deploy/ differs from its sources
```

`deploy/` is build output: never edit it by hand. The pre-commit hook
re-renders. The renderer's kustomize version is pinned in the header of
`scripts/render-deploy.sh`.

Not rendered:

- The three `*/secrets` directories. Rendering them runs KSOPS, which decrypts,
  so the output would be plaintext Secrets. `render-deploy.sh` refuses those
  paths, and their Applications point at the source directory and decrypt on
  the repo-server ([secrets.md](secrets.md)).
- Upstream Helm charts. They stay versioned `chart:` sources (Renovate bumps
  them) with values in a real file.

## Helm charts

Charts are multi-source Applications: the chart, plus this repository as
`ref: values` for the values file.

```yaml
sources:
  - repoURL: https://helm.cilium.io
    chart: cilium
    # renovate: datasource=helm depName=cilium registryUrl=https://helm.cilium.io
    targetRevision: 1.17.18
    helm:
      releaseName: cilium
      valueFiles:
        - $values/infrastructure/cilium/values.yaml
  - repoURL: https://github.com/ned-si/homelab.git
    targetRevision: main
    ref: values
```

A chart that needs extra manifests (a database, an HTTPRoute) gets a third
source with a `path`, as in `clusters/homelab/apps/immich.yaml`.

`releaseName` keeps the name of the Helm CLI release the Application took over
(`cilium`, `iscsi` for democratic-csi), so every object kept its name. Their old
`sh.helm.release.v1.*` Secrets are stale metadata. Never `helm uninstall` either
release: it deletes the CNI or the CSI driver.

The Argo CD release itself is not an Application. It is upgraded with the Helm
CLI from a merged commit, as described at the top of
`bootstrap/argocd-values.yaml`, with the chart version from
`ci/helm-releases.yaml`.

## Sessions

Long for user apps, short for platform tools. Keycloak holds one long SSO
session per device. User apps (Immich, Mealie, Paperless, Seafile) log in
through it once and stay logged in. Platform tools (Argo CD, Grafana, the
`homelab` realm admin console) ask for the password again once the last
password login is 12 hours old.

| Where | Setting | Value |
| --- | --- | --- |
| Keycloak realm `homelab` | SSO session idle / max | 30 d / 365 d |
| | Remember me idle / max | 180 d / 365 d |
| | Offline session idle / max | 365 d / none |
| | Access token | 5 min |
| | Browser flow `browser-loa`: password step behind "Condition - Level of Authentication", level 1 | max age 12 h |
| | ACR `platform` = level 1 (`acr.loa.map`); default ACR of `argocd`, `grafana-oauth`, `security-admin-console` | `platform` |
| Keycloak realm `master` (Keycloak admin) | defaults | 30 min idle, 10 h max |
| Immich | built in: session tokens do not expire, cookies last 400 d; OAuth `autoLaunch` and `autoRegister` on; mobile redirect `app.immich:///oauth-callback` | none to set |
| Mealie | `TOKEN_TIME` | 8760 h |
| Paperless | `PAPERLESS_SESSION_COOKIE_AGE` | 365 d |
| Seafile (web) | `SESSION_COOKIE_AGE`, `LOGIN_REMEMBER_DAYS` in `seahub_settings.py`, written by the init container `seahub-settings` | 365 d |
| Seafile, Jellyfin, Plex clients | app tokens without expiry; Jellyfin Quick Connect is on; Plex sessions belong to the Plex account | none to set |
| Grafana | `login_maximum_inactive_lifetime_duration` / `login_maximum_lifetime_duration`; no refresh token | 12 h / 24 h |
| Argo CD | `oidc.config`: no refresh, no `offline_access` | Keycloak token lifetime |

How the 12 hours work: a client that requests ACR `platform` is only
satisfied by an SSO cookie whose level-1 (password) login is younger than the
max age; otherwise Keycloak shows the login form. Clients that request no ACR
are satisfied by the cookie alone, so the user apps never see the prompt.

The realm values live in `platform/keycloak/realm/sessions.conf` and
`platform.conf`. After every sync of the `keycloak` Application, the PostSync
Job `keycloak-realm-settings` writes them with `kcadm.sh` and reads them back;
a mismatch fails the Job and the sync. Only what those files list is managed.
Users, credentials, other client settings and groups stay in the Keycloak
admin console.

To change a value, edit the file, run `task render` and merge. To check the
live realm:

```sh
kubectl -n keycloak logs job/keycloak-realm-settings
```

Expected: one `ok   <name>=<value>` line per managed value, `ok   flow
browser-loa: 9 executions`, and no `FAIL` line.

To end a session early (lost phone), sign the user out in the Keycloak admin
console (Users, the user, Sessions) and in the app itself (Immich: Account
settings, Authorized devices; Jellyfin: Dashboard, Devices; Plex: Account,
Authorized Devices).

## Site-specific values

What changes if the house, the LAN or the NAS changes. Re-render after editing
any of the manifests (`task render`).

| Value | Where |
| --- | --- |
| WAN IP | `infrastructure/external-dns/values.yaml` (`--default-targets`), the only copy |
| API VIP `192.168.1.11` | `infrastructure/cilium/values.yaml` (`k8sServiceHost`), `bootstrap/variables.tf`, `ansible/inventory.yml`, the kube-vip manifest on each control plane |
| Node addresses | `ansible/inventory.yml`, netplan on each node |
| LoadBalancer pools | `infrastructure/cilium/ip-pools.yaml` |
| Pinned LoadBalancer IPs | `infrastructure/gateway/gateway.yaml` (`.254`), `apps/theater/qbittorrent.yaml` (`.200`), `apps/syncthing/services.yaml` (`.201`) |
| NAS address | inline NFS volumes in `apps/theater/*.yaml` and `apps/immich/resources/backup-files.yaml` (the local Immich backup), `infrastructure/nfs-storage/*.yaml`, and three times in `infrastructure/secrets/democratic-csi-iscsi.sops.yaml` (API host, SSH host, iSCSI portal) |

`git grep -n 192.168.1.` lists every occurrence. Files carrying a
`SITE-SPECIFIC` comment are a subset of that list.

## Why it is like this

- Layers with sync waves: nothing in `apps` can be healthy before `platform`,
  nor `platform` before `infrastructure`, so a cold start converges on its own
  instead of needing manual sync ordering. Rejected: one flat app-of-apps.
- Rendered manifests: the pull request diff is exactly what the cluster
  receives, a sync does not depend on github.com for remote bases, and the
  kustomize exec flag that KSOPS needs applies to three directories instead of
  the whole repository. Rejected: Argo CD running kustomize at sync time.
- Enumerated AppProjects: `clusterResourceWhitelist` is the only thing that
  reports "this chart started creating a new kind of object". Rejected: the
  `default` project, where everything is allowed.
- Long sessions for user apps: one household, a handful of devices, and TV
  and phone apps that cannot easily sign in again. Repeated login prompts
  cost more than they protect; a lost device is handled by revoking its
  sessions. Rejected: short sessions with silent re-login, which most of these
  apps cannot do.
- Short sessions for platform tools: there is a single admin, and a stolen
  Argo CD or Grafana session is cluster-admin. Enforced once in Keycloak (a
  level-of-authentication max age) rather than per app, so every platform
  client gets the same rule. Rejected: per-client session lifetimes, which do
  not force a password when the SSO cookie is still valid.
- Realm settings applied by a Job with `kcadm.sh`, scoped to what two files
  list: it cannot reset users, credentials or other client settings. Rejected: a full
  realm import (keycloak-config-cli), which would make every client and
  mapper code first and is a larger change.
- Cross-cutting decisions (`main` is production, prune policy, what is
  hand-installed): [decisions.md](decisions.md).
