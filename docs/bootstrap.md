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

## Steps

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
$EDITOR ./*.sops.yaml    # fill in real, freshly rotated values
cd -

for f in infrastructure/secrets/*.sops.yaml; do task secrets:seal -- "$f"; done
task secrets:leak-check
```

The values must be **new**. Every credential in the old repo is compromised —
[security-incident.md](security-incident.md).

Platform and app secrets can wait; those Applications will sit `Degraded` until
they exist, which is the correct signal.

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

While rebuilding, keep `target_revision` on the working branch:

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

### 9. Point at main

Once the restructure is merged:

```hcl
target_revision = "main"
```

then `task bootstrap:apply` again. That is the only reason to re-run it.

## Teardown

Deleting the root Application cascades to the entire cluster — it carries
`resources-finalizer.argocd.argoproj.io` deliberately, so teardown is one explicit
action rather than a surprise.

```sh
# This deletes EVERYTHING Argo manages, including PVCs.
kubectl -n argocd delete application root
```

PVs backing the media library use `persistentVolumeReclaimPolicy: Retain`, so the
NFS data survives. iSCSI volumes use `Delete` and will not.

## A note on state

OpenTofu state is **local** (`bootstrap/terraform.tfstate`, git-ignored) and
contains the age key and the git PAT in cleartext. For a single-operator homelab
that is a defensible trade-off, but back it up somewhere encrypted, or move to a
remote backend.
