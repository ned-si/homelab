variable "github_repository" {
  description = "owner/name of the repository whose workflows may assume the roles."
  type        = string
  default     = "ned-si/homelab"
}

variable "backup_bucket_name" {
  description = "Backup bucket managed by bootstrap/aws-backup (its var.bucket_name)."
  type        = string
  default     = "ned-si-homelab-backups"
}

variable "state_bucket_name" {
  description = "State bucket managed by bootstrap/tofu-state."
  type        = string
  default     = "ned-si-homelab-tofu-state"
}

variable "region" {
  description = "AWS region of the provider. IAM is global; the buckets are in eu-central-1."
  type        = string
  default     = "eu-central-1"
}

variable "state_passphrase" {
  description = <<-EOT
    Passphrase for OpenTofu's client-side state and plan encryption. Read by the
    encryption block in providers.tf, never stored. scripts/tofu.sh sets it from
    TOFU_STATE_PASSPHRASE in secrets.local.env; CI from the Actions secret of the
    same name. Without it the state is unreadable.
  EOT
  type        = string
  sensitive   = true
}
