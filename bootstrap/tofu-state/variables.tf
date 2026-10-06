variable "bucket_name" {
  description = <<-EOT
    State bucket name. Must equal `bucket` in the backend block of every module
    under bootstrap/ (backend blocks cannot read variables).
  EOT
  type        = string
  default     = "ned-si-homelab-tofu-state"
}

variable "region" {
  description = "Region of the state bucket. Same as the backup bucket: eu-central-1."
  type        = string
  default     = "eu-central-1"
}

variable "state_passphrase" {
  description = <<-EOT
    Passphrase for OpenTofu's client-side state and plan encryption. Read by the
    encryption block in providers.tf, never stored. scripts/tofu.sh sets it from
    TOFU_STATE_PASSPHRASE in secrets.local.env. Without it the state is
    unreadable.
  EOT
  type        = string
  sensitive   = true
}
