# Bootstrap

Bringing the cluster from "nodes with a kubeconfig" to "Argo CD manages
everything".

`bootstrap/` runs **once**. If you find yourself adding a workload there, it
belongs in `clusters/homelab/` instead.

## What it does, and why each step cannot be GitOps

| Step | Why it is here |
|---|---|
| Cilium | No pod can be scheduled without a CNI — including Argo CD. |
| `sops-age` Secret | Argo CD cannot read encrypted secrets until it holds the key, and the key cannot live in the repo it protects. |
| `homelab-repo` Secret | Argo CD needs credentials before it can clone. |
| Argo CD | Something has to install the thing that installs everything. |
| root Application | One object that points Argo CD at the repo. |

Nothing else. Notably **not** here: Argo CD's own HTTPRoute, which is managed by
Argo CD from `infrastructure/gateway/argocd-route.yaml` like any other service.

## Prerequisites

- A working kubeadm cluster and a kubeconfig at `./kubeconfig-homelab`
  (git-ignored).
- Swap disabled on every node — Cilium's kube-proxy replacement and the kubelet
  both require it:
  ```sh
  sudo swapoff -a
  sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
  sudo systemctl mask swapfile.swap
  ```
- Each kubelet started with `--node-ip=<the node's own IP>`, **not** the API VIP.
  Getting this wrong produces ARP confusion that looks like random pod networking
  failures:
  ```sh
  sudo -e /usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf
  ```
- Local tooling: `task tools`.
- **The `deployed` tag exists and is pushed.** See step 0 — this one is not
  optional and nothing in the repo creates it for you.

## Steps

### 0. Create the `deployed` tag

Every `Application` in `clusters/homelab/` tracks a git tag named `deployed`, and
`target_revision` defaults to it. Argo CD resolves that revision on the very first
reconcile, so **without the tag a fresh bootstrap fails immediately** with:

```
rpc error: ... revision "deployed" not found
```

Nothing creates it: `cd.yaml` only *moves* an existing tag. Do it once, by hand:

```sh
git tag deployed <commit-that-is-known-good>
git push origin refs/tags/deployed
```

Then check GitHub's tag protection rules. A rule matching `deployed` that forbids
force-pushes breaks both deploy and rollback, because both are a force-push of that
tag.

Why a tag rather than a branch: [ADR 0001](adr/0001-deploy-by-moving-a-git-tag.md).

### 1. Generate the age key

```sh
task secrets:keygen
```

Back the private key up to your password manager before continuing. See
[secrets.md](secrets.md).

### 2. Create the secrets you need for a first boot

At minimum, infrastructure cannot converge without the Cloudflare tokens:

```sh
cd infrastructure/secrets
cp cloudflare-cert-manager.sops.yaml.example  cloudflare-cert-manager.sops.yaml
cp cloudflare-external-dns.sops.yaml.example  cloudflare-external-dns.sops.yaml
cp democratic-csi-iscsi.sops.yaml.example     democratic-csi-iscsi.sops.yaml
$EDITOR ./*.sops.yaml    # see below on which values must be new
cd -

for f in infrastructure/secrets/*.sops.yaml; do task secrets:seal -- "$f"; done
task secrets:leak-check
bash scripts/secrets-check.sh    # every file a KSOPS generator names exists and is sealed
```

All three of these need **new** values, and none of them is covered by the
deferred-rotation decision: the democratic-csi template requires a fresh keypair
and a non-root TrueNAS account, and the Cloudflare token is not LAN-scoped. See
[security-incident.md](security-incident.md).

Platform and app secrets can wait; those Applications will sit `Degraded` until
they exist, which is the correct signal. `secrets-check.sh` is what tells you
*which* file is missing without needing the age key — the `secrets-*` Applications
sync at the earliest wave in each layer, so one missing file stalls the whole
layer.

### 3. Configure the bootstrap

```sh
cd bootstrap
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars       # git_username, target_revision, api_server_ip
```

Pass the two sensitive values through the environment so they never land on disk:

```sh
export TF_VAR_sops_age_key="$(cat ~/.config/sops/age/keys.txt)"
export TF_VAR_git_token='<a PAT with contents:read on THIS REPO ONLY>'
```

Scope the PAT narrowly. Argo CD stores it in a Secret readable by anything that
can read Secrets in the `argocd` namespace.

`target_revision` defaults to `deployed`, which is what you want for any cluster
that owns real objects.

Override it with a branch **only** while rebuilding a cluster that owns nothing
yet, and understand the trade: a branch means the cluster follows every push with
no health gate in front of it.

```hcl
target_revision = "chore/gitops-restructure"
```

### 4. Apply

```sh
task bootstrap:plan     # read it
task bootstrap:apply
```

This installs Cilium (waits for it), then Argo CD (waits), then the root
Application. Expect 5–10 minutes on RK1 hardware.

### 5. Get in

```sh
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo

kubectl -n argocd port-forward svc/argocd-server 8080:80
```

Then `http://localhost:8080` as `admin`. Port-forward rather than the Gateway,
because on a cold start the Gateway does not exist yet — it is created by the
infrastructure layer that Argo is about to sync.

Once `infrastructure` is healthy, `https://argo.lilalala.com` works. The CLI needs
`--grpc-web` because TLS terminates at the Gateway:

```sh
argocd login argo.lilalala.com --grpc-web
```

### 6. Watch it converge

```sh
kubectl -n argocd get applications -w
```

Expected order: `root` → the three `layer-*` apps → leaves.

**Expected transient failures, not bugs:**

| Application | Error | Resolves when |
|---|---|---|
| `cloudnative-pg` | `no matches for kind "PodMonitor"` | kube-prometheus-stack syncs at wave 10 |
| `secrets-platform`, `secrets-apps` | missing files | you create those secrets (step 7) |
| `keycloak` | CrashLoopBackOff | its Secret and database exist |
| `kube-prometheus-stack` | Alertmanager pod never starts | `alertmanager-notify` exists — see [observability.md](observability.md) |

Anything still failing after all three layers report Synced is a real problem.

### 7. Finish the secrets

Work through the remaining templates:

```sh
ls platform/secrets/*.example apps/secrets/*.example
```

Each documents what the value is, how to generate it, and whether the old one is
compromised. Keycloak first — the OIDC client secrets are generated *in* Keycloak,
so it has to exist before the apps that federate to it.

### 8. Certificates: staging first

`infrastructure/gateway/certificate.yaml` points at `letsencrypt`. On a first
bring-up, switch it to `letsencrypt-staging`, confirm the Certificate reaches
`Ready`, then switch back:

```sh
kubectl -n gateway get certificate wildcard-lilalala -w
kubectl -n gateway describe certificate wildcard-lilalala
```

Production Let's Encrypt allows 50 certificates per registered domain per week, and
a misconfigured DNS-01 solver burns through that quickly.

### 9. Point at the `deployed` tag

Once you are done rebuilding, remove the branch override so `target_revision`
falls back to its default:

```hcl
# target_revision = "chore/gitops-restructure"
```

then `task bootstrap:apply` again. That is the only reason to re-run it. Changing
`targetRevision` is an in-place update to the Helm release, so `prevent_destroy`
does not block it.

From then on, deploying is moving the tag, not re-running OpenTofu.

## Teardown

`tofu destroy` **does not work here, and that is deliberate.**
`helm_release.root_application` carries `lifecycle { prevent_destroy = true }`, so
OpenTofu refuses at plan time rather than partially executing. The root Application
carries `finalizers: [resources-finalizer.argocd.argoproj.io]`, which Argo CD
honours by cascade-deleting every descendant Application and therefore every
Deployment, StatefulSet, PVC and Secret in the cluster — in about a minute, printing
a green `Destroy complete!`.

Two supported teardowns. Pick by whether the workloads should survive.

```sh
# A. Remove Argo CD, KEEP the workloads. Strip the finalizer first, so deleting
#    the Application orphans its children instead of collecting them.
kubectl -n argocd patch application root --type merge \
  -p '{"metadata":{"finalizers":null}}'
kubectl -n argocd delete application root

# B. Delete EVERYTHING Argo manages, including PVCs. Finalizer left in place.
kubectl -n argocd delete application root
```

Either way, PVs backing the media library and the local backup share use
`persistentVolumeReclaimPolicy: Retain`, so the NFS data survives. iSCSI volumes on
the `iscsi` class use `Delete` and will not; `iscsi-retain` exists for the ones that
must.

Rebuilding the root Application is cheap — `tofu apply` recreates it and Argo CD
re-adopts the existing objects. It is the destroy that is not. The full reasoning is
in the comment block above the `lifecycle` stanza in `bootstrap/main.tf`.

## A note on state

OpenTofu state is **local** (`bootstrap/terraform.tfstate`, git-ignored) and
contains the age key and the git PAT in cleartext. For a single-operator homelab
that is a defensible trade-off, but back it up somewhere encrypted, or move to a
remote backend.
