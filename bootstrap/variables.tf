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
    Git revision the root Application tracks. Defaults to `main`, which is what
    every committed Application in clusters/homelab/ tracks: a merge is a
    deployment and a rollback is a revert pull request (docs/decisions.md).

    Override it with another branch only while rebuilding a cluster that owns
    nothing yet. Once root syncs, Argo CD reconciles it against
    clusters/homelab/root.yaml, which tracks `main`.
  EOT
  type        = string
  default     = "main"
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
    that can read Secrets in the Argo CD namespace.
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
  description = "Namespace for Argo CD. `argo`, where the running cluster has it (helm release `argocd`)."
  type        = string
  default     = "argo"
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
