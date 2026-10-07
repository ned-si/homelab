# ---------------------------------------------------------------------------
# Bootstrap: the minimum needed to hand control to Argo CD, and nothing more.
#
# Everything OpenTofu does here is a genuine chicken-and-egg problem that GitOps
# cannot solve on its own:
#
#   1. Cilium  -- no pod can be scheduled without a CNI, including Argo CD.
#   2. Argo CD -- something has to install the thing that installs everything.
#   3. The age key and the Git credential -- Argo CD cannot read encrypted
#      secrets from git until it holds the key that decrypts them, and the key
#      obviously cannot be stored in the repo it protects.
#   4. The root Application -- one object that points Argo CD at the repo.
#
# After `tofu apply`, this directory should never need to run again. If you find
# yourself adding a workload here, it belongs in clusters/homelab/ instead.
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
# 1. Cilium
#
# Installed here, then ADOPTED by the `cilium` Argo CD Application which reads
# the same values file. So this is the only bootstrap step that is intentionally
# duplicated in git -- and because both read
# infrastructure/cilium/values.yaml, they cannot drift.
# ---------------------------------------------------------------------------
resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  # Must match ci/helm-releases.yaml (the bootstrap version) and
  # clusters/homelab/infrastructure/cilium.yaml; CI checks the latter.
  # renovate: datasource=helm depName=cilium registryUrl=https://helm.cilium.io
  version   = "1.17.18"
  namespace = "kube-system"

  values = [file("${path.module}/../infrastructure/cilium/values.yaml")]

  # The API VIP lives in a variable so the bootstrap can be pointed at a new LAN
  # without editing the shared values file first.
  set = [{
    name  = "k8sServiceHost"
    value = var.api_server_ip
  }]

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
# ---------------------------------------------------------------------------
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  # Must match the argocd entry of ci/helm-releases.yaml.
  # renovate: datasource=helm depName=argo-cd registryUrl=https://argoproj.github.io/argo-helm
  version   = "10.10.0"
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
# 4. The root Application
#
# Rendered from clusters/homelab/root.yaml so the file in git stays the single
# definition, with only `targetRevision` overridden -- that lets the bootstrap
# track a working branch while the committed manifest tracks `main`.
#
# `kubernetes_manifest` is avoided deliberately: it needs the CRD to exist at
# PLAN time, which it does not on a fresh cluster. A manifest applied through
# the `kubernetes` provider's generic resource has the same problem, so this
# uses a null-free approach: the Application is created by Helm as an extra
# object instead.
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

  # #########################################################################
  # # The root Application carries no `resources-finalizer` (CI:
  # # repo_policy.py `no-resources-finalizer`), so deleting it orphans what it
  # # created instead of cascade-deleting the cluster's workloads. A finalizer
  # # added later would turn `tofu destroy` into a complete teardown that prints
  # # a green "Destroy complete!".
  # #
  # # `prevent_destroy` makes OpenTofu refuse such a plan anyway, so a bare
  # # `tofu destroy` is rejected as a whole rather than partially executed. It
  # # guards THIS resource only: `tofu destroy -target=kubernetes_namespace_v1.argocd`
  # # still deletes the namespace and everything Argo CD runs in it.
  # #
  # # Rebuilding the Application itself is cheap: `tofu apply` recreates it and
  # # Argo CD re-adopts the existing objects. Teardown steps: docs/bootstrap.md.
  # #
  # # SIDE EFFECT to know about: `prevent_destroy` also blocks any change that
  # # would REPLACE this release (destroy-then-create) -- renaming it or moving
  # # it to another namespace. Changing `targetRevision` is an in-place update
  # # and is unaffected, which is the only field expected to change here.
  # #########################################################################
  lifecycle {
    prevent_destroy = true
  }
}
