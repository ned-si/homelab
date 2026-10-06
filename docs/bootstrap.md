# Bootstrap

From "kubeadm cluster with a kubeconfig" to "Argo CD manages everything". This
runs once per cluster. Day-to-day changes go through pull requests
([README](../README.md#how-changes-reach-the-cluster)); recovering an existing
cluster after a power loss is [runbooks/cold-start.md](runbooks/cold-start.md).

## What is bootstrapped, and why it cannot be GitOps

| Step | Why by hand |
| --- | --- |
| Cilium | No pod schedules without a CNI, including Argo CD. Argo CD adopts the release afterwards. |
| Namespace `argo` and Secret `argo/sops-age` | Argo CD cannot decrypt the repo's secrets without the age key, and the key cannot live in the repo. |
| Argo CD (Helm release `argocd`) | Something has to install the thing that installs everything. It stays a Helm CLI release. |
| Root Application | One object that points Argo CD at `deploy/clusters/homelab/bootstrap` on `main`. |

Everything else, including Argo CD's own HTTPRoute, democratic-csi and the
Gateway, is created by Argo CD from git.

## Prerequisites

- A kubeadm cluster with the API on the VIP `192.168.1.11:6443` (kube-vip static
  pods with the `/etc/nsswitch.conf` mount, see
  [networking.md](networking.md#kubernetes-api-vip)), no kube-proxy (Cilium
  replaces it: `kubeadm init --skip-phases=addon/kube-proxy`), swap off, and
  each kubelet on its own node IP (`--node-ip`), never the VIP.
- `~/repos/homelab/kubeconfig-homelab` (git-ignored) and
  `export KUBECONFIG=~/repos/homelab/kubeconfig-homelab`.
- Tools: `task tools` (sops, age, kustomize, kubeconform, helm, yq), plus
  `kubectl`.
- The age identity in `~/.config/sops/age/keys.txt`, mode 600: restore it from
  the password manager, or generate a new one (step 1).
- Run every command from the repository root on a checkout of `origin/main`.

Check:

```sh
kubectl get nodes
age-keygen -y ~/.config/sops/age/keys.txt
grep -o 'age1[0-9a-z]*' .sops.yaml | sort -u
```

Expected: every node listed (`NotReady` is normal before a CNI), and the
public key printed by `age-keygen -y` equal to the recipient in `.sops.yaml`.

## Steps

### 1. Age key (new cluster with new secrets only)

Skip this when restoring the existing key. For a new identity:

```sh
task secrets:keygen
```

It writes `~/.config/sops/age/keys.txt` and prints the public key. Save the
private key in the password manager now, put the public key in `.sops.yaml`,
and re-seal every secret ([secrets.md](secrets.md)) before
continuing: the sealed files in git are encrypted to the current key.

### 2. Cilium

From the values and chart version in git:

```sh
version=$(yq '.releases[] | select(.name == "cilium") | .version' ci/helm-releases.yaml)
helm install cilium cilium --repo https://helm.cilium.io --version "$version" \
  -n kube-system -f infrastructure/cilium/values.yaml --wait --timeout 15m
kubectl -n kube-system rollout status ds/cilium --timeout=5m
```

Expected: `STATUS: deployed`, then `daemon set "cilium" successfully rolled
out`, and every node `Ready` within a minute.

### 3. Argo CD and its key

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

### 4. Root Application

```sh
kubectl apply -f bootstrap/root-app.yaml
kubectl -n argo get applications -w
```

Expected: `root`, then the three `layer-*` Applications, then every leaf
appear. Expect 10 to 20 minutes on RK1 hardware. Argo CD adopts the Cilium
release from step 2 in the `cilium` Application; its diff is only the
`argocd.argoproj.io/instance` label.

Expected transient failures:

| Application | Error | Clears when |
| --- | --- | --- |
| `cnpg` | `no matches for kind "PodMonitor"` | `kube-prometheus-stack` syncs (wave 10) and the retry runs |
| `keycloak` | CrashLoopBackOff | its database is ready |
| everything in `platform` and `apps` | Progressing | `democratic-csi` (infrastructure wave 20) provides the StorageClasses |

Anything not `Synced` and `Healthy` 30 minutes after the last layer appeared is
a real problem: `kubectl -n argo get application <name> -o yaml` and read
`status.conditions` and `status.operationState`. `immich` is the exception: it
has no automated sync and stays `OutOfSync` until step 5.

### 5. Log in to Argo CD, sync Immich

```sh
kubectl -n argo get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argo port-forward svc/argocd-server 8080:80
```

Open `http://localhost:8080` as `admin`. Once the `gateway` Application is
healthy, `https://argo.lilalala.com` works too. Then sync Immich by hand:

```sh
argocd login argo.lilalala.com --grpc-web
argocd app sync immich --grpc-web
argocd app wait immich --health --timeout 900 --grpc-web
```

Expected: the sync succeeds and the wait ends with `Health Status: Healthy`.
Read [runbooks/immich-upgrade.md](runbooks/immich-upgrade.md) before ever
syncing a changed Immich chart or image.

Keycloak login (group `ArgoCDAdmins` is admin) needs the client secret of the
Keycloak client `argocd` in `argocd-secret`. It is not in git; set it once
Keycloak runs:

```sh
kubectl -n argo patch secret argocd-secret --type merge \
  -p '{"stringData":{"oidc.keycloak.clientSecret":"<client-secret-from-keycloak>"}}'
```

### 6. Check

```sh
kubectl -n argo get applications \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
kubectl -n gateway get certificate wildcard-lilalala
```

Expected: 25 Applications, all `Synced` and `Healthy`; the certificate
`READY True`. Production Let's Encrypt allows 50 certificates per domain per
week; on a new domain or DNS token, try the staging issuer first
(`infrastructure/cert-manager-issuers/cluster-issuer-staging.yaml`, kept out of
the kustomization on purpose).

## OpenTofu alternative

`bootstrap/main.tf` performs steps 2 to 4 in one run (Cilium, the `argo`
namespace, `sops-age`, a repository credential, Argo CD, and the root
Application through the local chart `bootstrap/charts/root-application`). The
current cluster was bootstrapped by hand, not with it.

```sh
cp bootstrap/terraform.tfvars.example bootstrap/terraform.tfvars
export TF_VAR_sops_age_key="$(cat ~/.config/sops/age/keys.txt)"
export TF_VAR_git_token='<github-token-with-contents-read-on-this-repo>'
task bootstrap:plan
task bootstrap:apply
```

State is local (`bootstrap/terraform.tfstate`, git-ignored) and contains the
age key and the token in clear text: keep it encrypted or delete it after the
run. `helm_release.root_application` has `prevent_destroy`, so `tofu destroy`
refuses at plan time.

## Removing Argo CD without deleting workloads

No Application carries the `resources-finalizer`, so deleting one orphans what
it manages instead of deleting it:

```sh
kubectl -n argo delete application root
```

Expected: the root goes away; layers, leaves and workloads keep running. Delete
the layers the same way before uninstalling Argo CD. Re-applying
`bootstrap/root-app.yaml` adopts everything again.

## Why it is like this

- Argo CD is a Helm CLI release, not an Application: an Argo CD that manages its
  own release can break the thing that would repair it. Upgrades are
  `helm upgrade` from a merged commit, with the version from
  `ci/helm-releases.yaml` and the values from `bootstrap/argocd-values.yaml`.
- Cilium is installed once by hand and then adopted, rather than kept as a Helm
  CLI release: the lifecycle (upgrades, values changes, drift) is then a pull
  request like everything else. The cost is this one bootstrap step.
- The repository credential is optional: the repository is public.
