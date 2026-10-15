# Bootstrap

From "four Talos nodes in maintenance mode" to "Argo CD manages everything".
This runs once per cluster. It keeps the data: the iSCSI volumes on the NAS are
re-bound by name and the databases are recovered from their off-site backups.
Machine configs, images and Talos upgrades are in [talos.md](talos.md).
Day-to-day changes go through pull requests
([README](../README.md#how-changes-reach-the-cluster)).

## What is bootstrapped, and why it cannot be GitOps

| Step | Why by hand |
| --- | --- |
| Machine configs, etcd bootstrap | There is no cluster yet. `talosctl` talks to the nodes directly. |
| Gateway API CRDs | Cilium's Gateway controller checks for them when it starts. The `gateway-api` Application adopts them. |
| Cilium | No pod schedules without a CNI, including Argo CD. The `cilium` Application adopts the release. |
| Namespace `argo` and Secret `argo/sops-age` | Argo CD cannot decrypt the repo's secrets without the age key, and the key cannot live in the repo. |
| Argo CD (Helm release `argocd`) | Something has to install the thing that installs everything. The `argocd` Application adopts the release. |
| Root Application | One object that points Argo CD at `deploy/clusters/homelab/bootstrap` on `main`. |
| PV and PVC `immich-data` | The photo library. Never synced by Argo CD; applied by hand after a check ([step 7](#7-immich)). |

Everything else is created by Argo CD from git, including the static PVs of
the other data volumes (`iscsi-volumes`) and the database recoveries.

## Prerequisites

- Every node flashed with the Image Factory image and booted into maintenance
  mode, its DHCP address read from the UART ([talos.md](talos.md#image)).
- `talos/talsecret.sops.yaml` sealed and committed
  ([talos.md](talos.md#cluster-secrets-once)).
- The age identity in `~/.config/sops/age/keys.txt`, mode 600: restore it from
  the password manager, or generate a new one (step 1).
- Tools: `task tools`, plus `kubectl`.
- Run every command from the repository root on a checkout of `origin/main`.

When the cluster replaces one that held data (the normal case):

- The old cluster is powered off. The NAS shows **no iSCSI sessions** (TrueNAS
  UI, Sharing, iSCSI, Sessions): a volume attached by two clusters at once is
  corrupted.
- Every CNPG Cluster has a completed backup in its ObjectStore `cnpg-backup`
  (S3 `s3://ned-si-homelab-backups/cnpg/<cluster>/`), taken on the old cluster
  after its writers stopped: `kubectl get backups.postgresql.cnpg.io -A` there
  lists one `completed` per Cluster ([backups.md](backups.md)).
- Each Cluster's `externalClusters[0]` server name is the archive to recover
  from, and its `plugins[0]` server name is a new, empty one. Today:
  recover from `<cluster>`, archive to `<cluster>-t1`. For the next rebuild,
  first move both by one (`<cluster>-t1` and `<cluster>-t2`) in a pull request:
  CNPG refuses to archive into a path that already holds an archive.
- A recursive ZFS snapshot of the iSCSI parent dataset on the NAS, the
  rollback point for every volume.

Check:

```sh
talosctl version --client --short
age-keygen -y ~/.config/sops/age/keys.txt
grep -o 'age1[0-9a-z]*' .sops.yaml | sort -u
```

Expected: the talosctl client version equal to `talosVersion` in
`talos/talconfig.yaml`, and the public key printed by `age-keygen -y` equal to
the recipient in `.sops.yaml`.

## Steps

### 1. Age key (new cluster with new secrets only)

Skip this when restoring the existing key. For a new identity:

```sh
task secrets:keygen
```

It writes `~/.config/sops/age/keys.txt` and prints the public key. Save the
private key in the password manager now, put the public key in `.sops.yaml`,
and re-seal every secret ([secrets.md](secrets.md)) before continuing: the
sealed files in git are encrypted to the current key.

### 2. Machine configs and etcd

```sh
task talos:genconfig
export TALOSCONFIG="$PWD/talos/clusterconfig/talosconfig"
talosctl apply-config --insecure -n <dhcp-ip> -f talos/clusterconfig/homelab-homelab-cp-3.yaml
```

Repeat the `apply-config` line for every node in maintenance mode, each with
its own file (`homelab-<hostname>.yaml`). A node that already runs Talos from
another cluster (a test node) goes back to maintenance mode first:
`talosctl -e <ip> -n <ip> --talosconfig <its-old-talosconfig> reset --graceful=false --reboot`.
Expected: the last line of
`genconfig` is `talos-genconfig: 4 machine config(s) in <repo>/talos/clusterconfig`;
each `apply-config` exits 0 and the node reboots onto its static address.

Bootstrap etcd once, on one control plane, then fetch the kubeconfig:

```sh
talosctl -e 192.168.1.239 -n 192.168.1.239 bootstrap
talosctl -e 192.168.1.239 -n 192.168.1.239 kubeconfig kubeconfig-homelab
export KUBECONFIG="$PWD/kubeconfig-homelab"
kubectl get nodes
```

Expected: `bootstrap` and `kubeconfig` exit 0 (`kubeconfig-homelab` is
git-ignored); within about 5 minutes every configured node is listed as
`NotReady`, which is normal before a CNI. The API answers on the VIP
`192.168.1.11:6443` once etcd is up. Store `talosconfig` and the kubeconfig in
the password manager.

### 3. Gateway API CRDs

From the render in git, no network fetch:

```sh
kubectl apply --server-side -f deploy/infrastructure/gateway-api/
kubectl get crd gateways.gateway.networking.k8s.io \
  -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}{"\n"}'
```

Expected: every object `serverside-applied`, then the version pinned in
`infrastructure/gateway-api/kustomization.yaml` (`v1.6.3`).

### 4. Cilium

From the values and chart version in git:

```sh
version=$(yq '.releases[] | select(.name == "cilium") | .version' ci/helm-releases.yaml)
helm install cilium cilium --repo https://helm.cilium.io --version "$version" \
  -n kube-system -f infrastructure/cilium/values.yaml --wait --timeout 15m
kubectl -n kube-system rollout status ds/cilium --timeout=5m
talosctl -e 192.168.1.239 -n 192.168.1.239 health --wait-timeout 10m
```

Expected: `STATUS: deployed`, then `daemon set "cilium" successfully rolled
out`, every node `Ready`, and `talosctl health` ending without an error.

### 5. Argo CD and its key

```sh
kubectl create namespace argo
kubectl -n argo create secret generic sops-age \
  --from-file=keys.txt="$HOME/.config/sops/age/keys.txt"
version=$(yq '.releases[] | select(.name == "argocd") | .version' ci/helm-releases.yaml)
helm install argocd argo-cd --repo https://argoproj.github.io/argo-helm \
  --version "$version" -n argo -f bootstrap/argocd-values.yaml --wait --timeout 15m
kubectl -n argo get pods
```

Expected: `STATUS: deployed` and every pod in `argo` `Running`. The repository
is public, so Argo CD needs no credential to clone it.

### 6. Root Application

When the old cluster's wildcard certificate is still valid, import its Secret
first (exported from the old cluster with `kubectl -n gateway get secret
wildcard-lilalala-tls -o yaml`, kept outside the repo). cert-manager then
reuses it instead of requesting a new one, which keeps the rebuild clear of
Let's Encrypt rate limits:

```sh
kubectl create namespace gateway
yq 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp)' \
  <exported-secret>.yaml | kubectl apply -f -
```

Then:

```sh
kubectl apply -f bootstrap/root-app.yaml
kubectl -n argo get applications -w
```

Expected: `root`, then the three `layer-*` Applications, then every leaf
appear. Expect 10 to 20 minutes on RK1 hardware, plus the database recoveries.
The `argocd`, `cilium` and `gateway-api` Applications adopt what steps 3 to 5
installed; their diff is only the `argocd.argoproj.io/instance` label.

Expected transient states:

| Application | State | Clears when |
| --- | --- | --- |
| `cnpg` | `no matches for kind "PodMonitor"` | `kube-prometheus-stack` syncs (wave 10) and the retry runs |
| `keycloak` | CrashLoopBackOff | `keycloak-db` has recovered |
| CNPG Clusters | `Setting up primary`, a `*-full-recovery` pod | the base backup and WAL are restored; minutes per GB |
| everything in `platform` and `apps` | Progressing | `democratic-csi` (wave 20) provides the StorageClasses and `iscsi-volumes` (wave 25) the PVs |

Then check that every data claim got its old volume and every database
recovered:

```sh
kubectl get pv -o custom-columns=PV:.metadata.name,STATUS:.status.phase,CLAIM:.spec.claimRef.name \
  | grep -F -f <(yq -N '.metadata.name' infrastructure/iscsi-volumes/*.yaml | grep '^pvc-')
kubectl get clusters.postgresql.cnpg.io -A
```

Expected: 15 lines, every one `Bound`; every Cluster `Cluster in healthy state`.
A data claim bound to any other PV is on a new, empty volume: scale its
workload to 0 and stop. Compare row counts and file counts with the values
recorded before the old cluster stopped.

The PreSync backup hooks of `mealie`, `seafile`, `theater`, `keycloak` and
`immich` do nothing on this first sync: their CronJob or CNPG Cluster does not
exist yet. From the next sync on they follow the backup freshness rule in
[backups.md](backups.md). Expected in each hook's log (`kubectl -n <app> logs
job/presync-backup`): `presync-backup: <object> not found (fresh cluster): no-op`.

Anything not `Synced` and `Healthy` 30 minutes after the last layer appeared is
a real problem: `kubectl -n argo get application <name> -o yaml` and read
`status.conditions` and `status.operationState`. `immich` is the exception: it
has no automated sync and stays `OutOfSync` until step 7.

### 7. Immich

**Operator decision.** The photo library volume is the one thing that is not
replaceable. Apply it only when step 6 is green and the NAS still shows no
iSCSI session from any other host:

```sh
kubectl apply --server-side -f infrastructure/iscsi-volumes/operator/immich-data.yaml
kubectl -n immich get pvc immich-data -o jsonpath='{.status.phase} {.spec.volumeName}{"\n"}'
```

Expected: `Bound pvc-b9d3e7d8-0d3e-43d4-b8d3-8f212ede0ea6`. Anything else:
stop, do not sync Immich.

Then sync it by hand (read [runbooks/immich-upgrade.md](runbooks/immich-upgrade.md)
before ever syncing a changed Immich chart or image):

```sh
kubectl config set-context --current --namespace argo
argocd app sync immich --core
argocd app wait immich --health --timeout 900 --core
```

`--core` talks to the cluster with the kubeconfig, so it needs neither the
Argo CD API nor a login.

Expected: the sync succeeds, the wait ends with `Health Status: Healthy`, and
the image and video counts (Administration, Server Stats) equal the values
recorded before the old cluster stopped.

### 8. Log in to Argo CD

The local `admin` account is disabled (`admin.enabled: false` in
`bootstrap/argocd-values.yaml`). The only login is Keycloak SSO: members of
the group `ArgoCDAdmins` get `role:admin`, everyone else gets nothing
(`policy.default: ""`). Until Keycloak runs, use `kubectl` or
`argocd --core`. Break-glass if SSO breaks: fix the realm as the Keycloak
master-realm admin, or use `argocd --core`.

Keycloak login needs the client secret of the
Keycloak client `argocd` in `argocd-secret`. It is not in git; set it once
Keycloak runs:

```sh
kubectl -n argo patch secret argocd-secret --type merge \
  -p '{"stringData":{"oidc.keycloak.clientSecret":"<client-secret-from-keycloak>"}}'
```

The `argocd` Application ignores the data of `argocd-secret`, so a sync keeps
it.

### 9. Check

```sh
kubectl -n argo get applications \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
kubectl -n gateway get certificate wildcard-lilalala
```

Expected: 27 Applications, all `Synced` and `Healthy`; the certificate
`READY True`. Production Let's Encrypt allows 50 certificates per domain per
week; on a new domain or DNS token, try the staging issuer first
(`infrastructure/cert-manager-issuers/cluster-issuer-staging.yaml`, kept out of
the kustomization on purpose).

If a database recovery fails, the fallback is an empty cluster plus the latest
dump from `task backup:dump`: restore the Cluster's `bootstrap.initdb` block
from git history, sync, then `pg_restore` as in
`scripts/verify-dump-restore.sh`.

## OpenTofu alternative

`bootstrap/main.tf` performs steps 4 and 5 and the root Application of step 6
in one run (Cilium, the `argo` namespace, `sops-age`, a repository credential,
Argo CD, and the root Application through the local chart
`bootstrap/charts/root-application`). Steps 2 and 3 come first, by hand.

```sh
cp bootstrap/terraform.tfvars.example bootstrap/terraform.tfvars
export TF_VAR_sops_age_key="$(cat ~/.config/sops/age/keys.txt)"
export TF_VAR_git_token='<github-token-with-contents-read-on-this-repo>'
task bootstrap:plan
task bootstrap:apply
```

State is remote and encrypted ([OpenTofu state](#opentofu-state)); it will hold
the age key and the token. `helm_release.root_application` has
`prevent_destroy`, so `tofu destroy` refuses at plan time.

## OpenTofu state

> [!CAUTION]
> Without `TOFU_STATE_PASSPHRASE` every module's state is unreadable and there
> is no recovery: the next apply tries to recreate everything. Keep it in the
> password manager as well as in `secrets.local.env` (git-ignored).

Every root module under `bootstrap/` keeps its state in the S3 bucket
`ned-si-homelab-tofu-state` (eu-central-1), key `<module path>/terraform.tfstate`:

| Module | Holds |
|---|---|
| `bootstrap/tofu-state` | the state bucket itself |
| `bootstrap/aws-backup` | backup bucket, both IAM users and their secret keys |
| `bootstrap` | once applied, the age key and the Git token |

- **Client-side encryption.** The `encryption` block in each `providers.tf`
  encrypts state and plans with AES-GCM, key derived (PBKDF2) from
  `var.state_passphrase`, `enforced = true`. S3 only holds ciphertext.
- **Locking.** S3-native (`use_lockfile = true`): a `.tflock` object next to the
  state while a command runs. No DynamoDB table.
- **The bucket.** Versioning (90 days of previous states), SSE-S3, public access
  blocked, TLS-only bucket policy, `prevent_destroy`. Separate from the backup
  bucket, whose writer must not read the state that holds its own key.

Run OpenTofu through the wrapper, never bare `tofu`:

```sh
aws login --profile homelab --region eu-central-1   # browser, once per session
scripts/tofu.sh bootstrap/aws-backup init
scripts/tofu.sh bootstrap/aws-backup plan
```

`scripts/tofu.sh <module> <tofu args>` exports the login session as environment
credentials, passes `TOFU_STATE_PASSPHRASE` from `secrets.local.env` as
`TF_VAR_state_passphrase`, prints neither, and runs `tofu` in the module.
`task bootstrap:plan` and `task bootstrap:apply` use it. CI only runs
`tofu fmt -check` and `tofu init -backend=false && tofu validate`.

**Creating the state bucket (fresh account only).** `bootstrap/tofu-state`
stores its state in the bucket it creates, so apply it first with local
(already encrypted) state, then move it:

```sh
printf 'terraform {\n  backend "local" {}\n}\n' \
  > bootstrap/tofu-state/backend_override.tf          # git-ignored
scripts/tofu.sh bootstrap/tofu-state init
scripts/tofu.sh bootstrap/tofu-state apply
rm bootstrap/tofu-state/backend_override.tf
scripts/tofu.sh bootstrap/tofu-state init -migrate-state -force-copy
rm -P bootstrap/tofu-state/terraform.tfstate*
```

**Moving a plaintext state in, or changing the passphrase.** For one run, in the
module's `providers.tf`, add the old method (`method "unencrypted" "migrate" {}`
or the old key provider) as `fallback` and set `enforced = false`; run
`scripts/tofu.sh <module> init -migrate-state -force-copy`; revert, confirm
`plan` shows no changes, and delete any local `terraform.tfstate*`.

## Removing Argo CD without deleting workloads

No Application carries the `resources-finalizer`, so deleting one orphans what
it manages instead of deleting it:

```sh
kubectl -n argo delete application root
```

Expected: the root goes away; layers, leaves and workloads keep running. Delete
the layers the same way, then the `argocd` Application, before uninstalling
Argo CD. Re-applying `bootstrap/root-app.yaml` adopts everything again.

## Why it is like this

- Argo CD manages its own release. Upgrades and values changes are pull
  requests, and the live version cannot drift from git the way a Helm CLI
  release did. The cost is that a bad Argo CD sync cannot be repaired by Argo
  CD: the break-glass `helm upgrade` from a known-good commit is in
  `clusters/homelab/infrastructure/argocd.yaml`.
- Cilium and the Gateway API CRDs are installed once by hand and then adopted,
  rather than kept as Talos inline manifests: Talos re-applies inline manifests
  on every Kubernetes upgrade and would fight Argo CD for them.
- Cilium reaches the API through KubePrism (`localhost:7445`), so it needs no
  working pod network or VIP to start.
- Data volumes are re-bound as static PVs with their old volume handles instead
  of restored from backups: the zvols on the NAS are the data, and restoring
  hundreds of GB from S3 would take hours. The databases are recovered from their
  Barman Cloud backups instead of re-bound, because a PGDATA volume carries the
  old cluster's identity; their old volumes stay on the NAS as a fallback.
- `immich-data` stays out of every Application, so no sync, prune or mistake in
  git can touch the photo library.
- The repository credential is optional: the repository is public.
