# ---------------------------------------------------------------------------
# Bootstrap: the minimum to hand control to Argo CD. Cilium (no pod runs
# without a CNI), Argo CD, the age key and Git credential (which cannot live
# in the repo), and the root Application. A workload added here belongs in
# clusters/homelab/.
# ---------------------------------------------------------------------------

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = var.argocd_namespace
    labels = {
      "homelab.lilalala.com/managed-by"    = "opentofu"
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

# ---------------------------------------------------------------------------
# 1. Cilium, adopted afterwards by the `cilium` Application with the same
# values file. The Gateway API CRDs must exist first (docs/bootstrap.md step 3).
# ---------------------------------------------------------------------------
resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  # Must match ci/helm-releases.yaml (the bootstrap version) and
  # clusters/homelab/infrastructure/cilium.yaml; CI checks both.
  # renovate: datasource=helm depName=cilium registryUrl=https://helm.cilium.io
  version   = "1.20.4"
  namespace = "kube-system"

  # No overrides: the values file reaches the API through Talos KubePrism
  # (localhost:7445), which does not depend on the LAN or the VIP.
  values = [file("${path.module}/../infrastructure/cilium/values.yaml")]

  wait          = true
  wait_for_jobs = true
  timeout       = 900

  # Argo CD adopts this release afterwards, so let it manage the ConfigMap
  # without OpenTofu fighting it on the next plan.
  lifecycle {
    ignore_changes = [values]
  }
}

# ---------------------------------------------------------------------------
# 2. Secrets that must exist before Argo CD can be useful
# ---------------------------------------------------------------------------

# The age identity. This single key decrypts every *.sops.yaml in the repo.
resource "kubernetes_secret_v1" "sops_age" {
  metadata {
    name      = "sops-age"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  }
  # Key name must be `keys.txt`: it is mounted into the repo-server and pointed
  # at by SOPS_AGE_KEY_FILE.
  data = {
    "keys.txt" = var.sops_age_key
  }
  type = "Opaque"
}

# Repository credentials. The `argocd.argoproj.io/secret-type: repository` label
# is what makes Argo CD pick this up as a repo definition rather than an
# arbitrary Secret.
resource "kubernetes_secret_v1" "repo_credentials" {
  metadata {
    name      = "homelab-repo"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }
  data = {
    type     = "git"
    url      = var.repo_url
    username = var.git_username
    password = var.git_token
  }
  type = "Opaque"
}

# ---------------------------------------------------------------------------
# 3. Argo CD
#
# Adopted afterwards by the `argocd` Application
# (clusters/homelab/infrastructure/argocd.yaml), same release and values file.
# ---------------------------------------------------------------------------
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  # Must match the argocd entry of ci/helm-releases.yaml; CI checks it.
  # renovate: datasource=helm depName=argo-cd registryUrl=https://argoproj.github.io/argo-helm
  version   = "10.14.0"
  namespace = kubernetes_namespace_v1.argocd.metadata[0].name

  values = [file("${path.module}/argocd-values.yaml")]

  depends_on = [
    helm_release.cilium,
    kubernetes_secret_v1.sops_age,
    kubernetes_secret_v1.repo_credentials,
  ]

  wait          = true
  wait_for_jobs = true
  timeout       = 900
}

# ---------------------------------------------------------------------------
# 4. The root Application, rendered from clusters/homelab/root.yaml with only
# `targetRevision` overridden. Created by Helm: `kubernetes_manifest` needs
# the CRD at plan time, which a fresh cluster does not have.
# ---------------------------------------------------------------------------
resource "helm_release" "root_application" {
  name      = "root-application"
  namespace = kubernetes_namespace_v1.argocd.metadata[0].name

  # A tiny local chart whose only job is to template the root Application. This
  # avoids both the `kubernetes_manifest` plan-time CRD problem and a
  # `local-exec kubectl` shell-out.
  chart = "${path.module}/charts/root-application"

  set = [
    {
      name  = "repoURL"
      value = var.repo_url
    },
    {
      name  = "targetRevision"
      value = var.target_revision
    },
    {
      name  = "namespace"
      value = kubernetes_namespace_v1.argocd.metadata[0].name
    },
  ]

  depends_on = [helm_release.argocd]

  # No `resources-finalizer` on the root Application (CI:
  # `no-resources-finalizer`), so deleting it orphans its workloads.
  # `prevent_destroy` makes a bare `tofu destroy` fail as a whole; it guards
  # this resource only, and also blocks a replacement (rename, namespace
  # move). `targetRevision` changes in place. Teardown: docs/bootstrap.md.
  lifecycle {
    prevent_destroy = true
  }
}
