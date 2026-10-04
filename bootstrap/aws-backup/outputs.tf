# The two credentials, plus the values that have to be copied into the manifests.
#
# Read them with `tofu output -raw <name>`. They are marked sensitive so a plain
# `tofu output` or a CI log cannot spill them by accident.

output "bucket_name" {
  description = "Bucket name, for RESTIC_REPOSITORY and barman destinationPath."
  value       = aws_s3_bucket.backups.id
}

output "region" {
  description = "Region. Also where the annual restore drill must run to avoid egress charges."
  value       = var.region
}

output "s3_endpoint" {
  description = "Endpoint for barman `endpointURL` and the restic repository string."
  value       = "https://s3.${var.region}.amazonaws.com"
}

output "backup_access_key_id" {
  description = "ACCESS_KEY_ID for the s3-backup Secret. Save to Bitwarden."
  value       = aws_iam_access_key.backup.id
  sensitive   = true
}

output "backup_secret_access_key" {
  description = "ACCESS_SECRET_KEY for the s3-backup Secret. Save to Bitwarden."
  value       = aws_iam_access_key.backup.secret
  sensitive   = true
}

output "verify_access_key_id" {
  description = "Read-only key for restore drills. Save to Bitwarden."
  value       = aws_iam_access_key.verify.id
  sensitive   = true
}

output "verify_secret_access_key" {
  description = "Read-only secret for restore drills. Save to Bitwarden."
  value       = aws_iam_access_key.verify.secret
  sensitive   = true
}

output "next_steps" {
  description = "What to do with the above."
  value       = <<-EOT

    Bucket ${aws_s3_bucket.backups.id} created in ${var.region}.

    1. Save all four keys to Bitwarden, plus RESTIC_PASSWORD (see below).
       terraform.tfstate now contains the secrets -- treat it as one.

    2. Generate the restic repository password. WITHOUT IT THE FILE BACKUPS ARE
       UNREADABLE, including by you. Back it up beside the age key:

           openssl rand -base64 48

    3. Fill in and seal the Secret:

           cp platform/secrets/s3-backup.sops.yaml.example \\
              platform/secrets/s3-backup.sops.yaml
           $EDITOR platform/secrets/s3-backup.sops.yaml
           task secrets:seal -- platform/secrets/s3-backup.sops.yaml

    4. Point the manifests at this bucket and endpoint:

           task backup:set-target -- ${aws_s3_bucket.backups.id} ${var.region}

    5. Initialise the restic repositories, then take the first Immich upload
       deliberately rather than letting a CronJob start it -- it is large and
       slow. See docs/backups.md.
  EOT
}
