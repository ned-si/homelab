variable "bucket_name" {
  description = <<-EOT
    S3 bucket name. Must be globally unique across all of AWS, so a bare
    `homelab-backups` will almost certainly be taken -- add a suffix.
    Changing this later means moving every object, so pick once.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "Bucket names must be 3-63 chars, lowercase, and start/end alphanumeric."
  }
}

variable "region" {
  description = <<-EOT
    Region to create the bucket in.

    eu-central-1 (Frankfurt) is the default: closest large region to Zurich, and
    the data stays in the EU. eu-central-2 (Zurich) is closer still but prices
    roughly 25% higher for no benefit that matters to a backup you hope never to
    read.

    The region matters for the verification strategy, not just latency: the
    annual full-restore drill runs on an EC2 instance in THIS region, because
    S3 -> EC2 traffic inside a region is free while S3 -> internet is not.
    See docs/backups.md.
  EOT
  type        = string
  default     = "eu-central-1"
}
