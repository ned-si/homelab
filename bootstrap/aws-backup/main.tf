# ---------------------------------------------------------------------------
# The off-site backup target: one S3 bucket and one tightly-scoped IAM user.
#
# Separate OpenTofu root module from bootstrap/, with its own state, because it
# has a different lifetime and a different blast radius. The cluster can be
# rebuilt from scratch; this bucket is the thing that must survive the cluster
# being rebuilt from scratch, so nothing that manages the cluster should be able
# to destroy it by accident.
#
# Apply it with YOUR OWN credentials:
#
#     export AWS_PROFILE=homelab          # or AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
#     cd bootstrap/aws-backup
#     tofu init && tofu plan
#     tofu apply
#     tofu output -raw backup_access_key_id
#     tofu output -raw backup_secret_access_key
#
# ###########################################################################
# # DO NOT APPLY THIS WITH ROOT CREDENTIALS, and do not create root access
# # keys. AWS advises against it and root cannot be scoped, so a leaked key
# # would be able to delete the backups and everything else in the account.
# # Create an admin IAM user for yourself, or use IAM Identity Center.
# ###########################################################################
#
# NOTE ON STATE: `tofu apply` puts the generated secret access key in
# terraform.tfstate. That file is git-ignored, but it is now a secret. Transcribe
# the key into Bitwarden, then treat the state file accordingly (mode 600, and
# ideally moved off this machine or into an encrypted backend).
#
# Full reasoning for the storage classes and the verification strategy:
# docs/backups.md.
# ---------------------------------------------------------------------------

locals {
  # restic repositories, as laid out by the CronJobs in apps/. Each one gets its
  # own lifecycle rule, because S3 prefix filters are literal prefixes with no
  # wildcard support -- there is no way to say `*/data/`.
  #
  # ONLY the `data/` prefix may be archived. restic reads `config`, `keys/`,
  # `index/` and `snapshots/` on EVERY operation, so those must stay in a class
  # with immediate GET. Archiving them makes the repository unusable, which is
  # the single most common way people break restic-on-Glacier.
  restic_repos = [
    "immich/library",
    "paperless/media",
  ]
}

# ---------------------------------------------------------------------------
# The bucket
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "backups" {
  bucket = var.bucket_name

  # Refuse to destroy the backup bucket via `tofu destroy`. Removing it should be
  # a deliberate, manual act, not a side effect of tearing down this module.
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name    = var.bucket_name
    Purpose = "homelab off-site backups"
    Managed = "opentofu"
  }
}

# Versioning is what turns "the credential deleted my backups" from a disaster
# into an inconvenience: DeleteObject leaves a delete marker and the old version
# is still there. The IAM policy below then denies DeleteObjectVersion, so the
# backup credential cannot make a deletion permanent.
resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# SSE-S3 rather than SSE-KMS. restic already encrypts client-side, so this only
# protects the barman/Postgres objects at rest -- and SSE-KMS would add a
# per-request charge on every WAL segment for no meaningful gain here.
resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  # --- restic pack files -> Glacier Instant Retrieval ----------------------
  #
  # GIR, not Flexible Retrieval or Deep Archive. Those require an asynchronous
  # thaw before an object can be read, and restic has no concept of that -- it
  # expects every GET to work. GIR keeps millisecond reads, so restic (and
  # `restic check --read-data`, and a real restore) keep working unchanged.
  #
  # Transition at 1 day rather than 0 so a pack written during a run cannot
  # change class mid-run. The cost difference is a rounding error.
  #
  # Trade-off to be aware of: GIR has a 90-day minimum storage duration. Deleting
  # a pack earlier is billed to 90 days anyway. That is fine here because the
  # data is write-once photos and documents, so `restic prune` rarely deletes
  # packs -- but it is why the retention policies are months, not days.
  dynamic "rule" {
    for_each = local.restic_repos
    content {
      id     = "archive-${replace(rule.value, "/", "-")}-data"
      status = "Enabled"

      filter {
        prefix = "${rule.value}/data/"
      }

      transition {
        days          = 1
        storage_class = "GLACIER_IR"
      }
    }
  }

  # --- bound the cost of the versioning safety net --------------------------
  #
  # Without this, every object restic prunes is retained forever as a noncurrent
  # version and the bill grows without limit. 30 days is long enough to notice
  # and recover from a compromised credential or a bad prune.
  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  # Failed multipart uploads are invisible in the console and billed as storage.
  # Over years of nightly uploads on a domestic uplink, they add up.
  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # NOTE: there is deliberately no expiry rule for `*/postgres/`. CloudNativePG
  # manages that itself via `spec.backup.retentionPolicy` (30d for Immich, 90d
  # for Keycloak) and it needs to be the one deciding, because deleting a base
  # backup that later WAL still depends on silently destroys the ability to
  # recover to any point in that window. Nor is it transitioned to Glacier: WAL
  # is a stream of small objects with constant churn, which is the worst possible
  # fit for a class with a 90-day minimum duration.
  depends_on = [aws_s3_bucket_versioning.backups]
}

# ---------------------------------------------------------------------------
# The backup credential
# ---------------------------------------------------------------------------
resource "aws_iam_user" "backup" {
  name = "${var.bucket_name}-writer"
  tags = {
    Purpose = "homelab backup writer -- used by CNPG barman and restic CronJobs"
    Managed = "opentofu"
  }
}

data "aws_iam_policy_document" "backup" {
  # What the backup jobs genuinely need. restic prunes and barman enforces
  # retention, so DeleteObject is required -- it is not a mistake.
  statement {
    sid    = "ObjectReadWrite"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${aws_s3_bucket.backups.arn}/*"]
  }

  statement {
    sid    = "BucketList"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:GetBucketLocation",
    ]
    resources = [aws_s3_bucket.backups.arn]
  }

  # THE IMPORTANT PART.
  #
  # A backup credential that can permanently destroy the backups is ransomware's
  # first target, and it is also what turns one bad script into total data loss.
  # DeleteObject above only writes a delete marker; these denials stop anything
  # from making a deletion irreversible or from disabling the mechanism that
  # makes it reversible.
  #
  # Deny beats Allow in IAM unconditionally, so these hold even if someone later
  # attaches a broader policy to this user.
  statement {
    sid    = "DenyIrreversibleDestruction"
    effect = "Deny"
    actions = [
      "s3:DeleteObjectVersion",
      "s3:DeleteObjectVersionTagging",
      "s3:PutBucketVersioning",
      "s3:PutLifecycleConfiguration",
      "s3:DeleteBucket",
      "s3:DeleteBucketPolicy",
      "s3:PutBucketPolicy",
      "s3:PutBucketAcl",
      "s3:PutEncryptionConfiguration",
    ]
    resources = [
      aws_s3_bucket.backups.arn,
      "${aws_s3_bucket.backups.arn}/*",
    ]
  }
}

resource "aws_iam_user_policy" "backup" {
  name   = "backup-writer"
  user   = aws_iam_user.backup.name
  policy = data.aws_iam_policy_document.backup.json
}

resource "aws_iam_access_key" "backup" {
  user = aws_iam_user.backup.name
}

# ---------------------------------------------------------------------------
# A read-only credential for verification, used by the annual in-region restore
# drill (docs/backups.md). It cannot write or delete anything at all, so a drill
# gone wrong cannot damage the backup it is testing.
# ---------------------------------------------------------------------------
resource "aws_iam_user" "verify" {
  name = "${var.bucket_name}-verifier"
  tags = {
    Purpose = "read-only restore drills"
    Managed = "opentofu"
  }
}

data "aws_iam_policy_document" "verify" {
  statement {
    sid       = "ReadOnly"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${aws_s3_bucket.backups.arn}/*"]
  }
  statement {
    sid       = "BucketList"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.backups.arn]
  }
  # restic insists on being able to write a lock file, even for `check` and
  # `restore`. Confine that to the lock prefix and nothing else, so this
  # credential still cannot touch the data.
  statement {
    sid       = "ResticLocksOnly"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.backups.arn}/*/locks/*"]
  }
}

resource "aws_iam_user_policy" "verify" {
  name   = "verify-readonly"
  user   = aws_iam_user.verify.name
  policy = data.aws_iam_policy_document.verify.json
}

resource "aws_iam_access_key" "verify" {
  user = aws_iam_user.verify.name
}
