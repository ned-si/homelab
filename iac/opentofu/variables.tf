variable "argo-ns" {
  description = "ArgoCD namespace"
  type        = string
  default     = "argo"
}

variable "gh-pat" {
  description = "GitHub Personal Access Token"
  type        = string
}

variable "gh-user" {
  description = "GitHub User"
  type        = string
}

variable "repo-url" {
  description = "GitHub Repo URL"
  type        = string
}
