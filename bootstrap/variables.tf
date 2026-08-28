variable "kubeconfig_path" {
  description = "Path to the cluster kubeconfig. Git-ignored; keep it out of the repo."
  type        = string
  default     = "../kubeconfig-homelab"
}

variable "repo_url" {
  description = "HTTPS URL of this repository, as Argo CD should clone it."
  type        = string
  default     = "https://github.com/ned-si/homelab.git"
}

variable "target_revision" {
  description = <<-EOT
    Git revision the root Application tracks. Defaults to the `deployed` tag,
    which is what every committed Application in clusters/homelab/ tracks.

    `deployed` is a moving tag that .github/workflows/cd.yaml advances after a
    health-gated rollout and moves back on failure. A deploy is "move the tag";
    a rollback is "move it back". Because every Application here runs
    `automated.selfHeal: true`, a rollback expressed any other way (syncing or
    pinning to a SHA) is undone by the next reconcile -- see the long comment in
    clusters/homelab/root.yaml.

    Override it with a BRANCH only while rebuilding from a working branch, e.g.
    "chore/gitops-restructure". A branch here means the cluster follows every
    push with no health gate in front of it, which is fine for a cluster that
    owns nothing yet and not fine afterwards.
  EOT
  type        = string
  default     = "deployed"
}

variable "git_username" {
  description = "GitHub username for cloning the repository."
  type        = string
}

variable "git_token" {
  description = <<-EOT
    GitHub Personal Access Token with read-only access to this repository.

    Needs only `contents: read` on this single repo. Do NOT reuse a
    broadly-scoped token: Argo CD stores it in a Secret readable by anything
    that can read Secrets in the argocd namespace.
  EOT
  type        = string
  sensitive   = true
}

variable "sops_age_key" {
  description = <<-EOT
    Contents of the age identity file (~/.config/sops/age/keys.txt), including
    the AGE-SECRET-KEY line. This is what lets the Argo CD repo-server decrypt
    every *.sops.yaml in the repository.

    Pass it via the environment rather than a tfvars file:
        export TF_VAR_sops_age_key="$(cat ~/.config/sops/age/keys.txt)"
  EOT
  type        = string
  sensitive   = true
}

variable "argocd_namespace" {
  description = "Namespace for Argo CD. Changed from `argo` to the conventional `argocd`."
  type        = string
  default     = "argocd"
}

variable "api_server_ip" {
  description = <<-EOT
    Kubernetes API server VIP, needed by Cilium's kube-proxy replacement.

    SITE-SPECIFIC: this changes if the LAN subnet changes. It must match
    `k8sServiceHost` in infrastructure/cilium/values.yaml.
  EOT
  type        = string
  default     = "192.168.1.11"
}
