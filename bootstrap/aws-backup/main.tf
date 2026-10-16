# ---------------------------------------------------------------------------
# The off-site backup target: one S3 bucket and one tightly-scoped IAM user.
#
# Separate OpenTofu root module from bootstrap/, with its own state, because it
# has a different lifetime and a different blast radius. The cluster can be
# rebuilt from scratch; this bucket is the thing that must survive the cluster
# being rebuilt from scratch, so nothing that manages the cluster should be able
# to destroy it by accident.
#
# Apply it with YOUR OWN short-lived credentials, through the wrapper:
#
#     aws login --profile homelab --region eu-central-1
#     scripts/tofu.sh bootstrap/aws-backup init
#     scripts/tofu.sh bootstrap/aws-backup plan
#     scripts/tofu.sh bootstrap/aws-backup apply
#     scripts/tofu.sh bootstrap/aws-backup output -raw backup_access_key_id
#     scripts/tofu.sh bootstrap/aws-backup output -raw backup_secret_access_key
#
# scripts/tofu.sh exports the `aws login` session as environment credentials
# (the AWS provider cannot read login sessions itself) and supplies the state
# passphrase. Never create long-lived access keys for yourself, and never root
# access keys: a leaked key could delete the backups and everything else.
#
# NOTE ON STATE: the state contains both generated secret access keys. It lives
# in s3://ned-si-homelab-tofu-state (bootstrap/tofu-state), encrypted by
# OpenTofu before upload, so there is no local state file to protect. It is
# only as safe as TOFU_STATE_PASSPHRASE. See docs/bootstrap.md.
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
  # EVERY restic repository must be listed here. A repository that is missing
  # still works -- its packs simply stay in S3 Standard at roughly 6x the price,
  # for ever, with nothing to indicate it. That is the failure mode this list
  # exists to prevent, so it is checked by scripts/check-restic-repos.sh in CI
  # against the actual RESTIC_REPOSITORY values in the manifests.
  #
  # Derived from the manifests, not from memory. To regenerate:
  #   scripts/check-restic-repos.sh
  # which reads the RESTIC_REPOSITORY values out of apps/ and platform/ and
  # diffs them against this list in both directions.
  restic_repos = [
    "grafana/data",    # platform/kube-prometheus-stack/routes/grafana-backup.yaml
    "immich/library",  # apps/immich/resources/backup-files.yaml
    "mealie/data",     # apps/mealie/backup.yaml
    "paperless/media", # apps/paperless/backup.yaml
    "seafile/shared",  # retained, no new snapshots: Seafile removed 2026-10-16
    "syncthing/data",  # apps/syncthing/backup.yaml
    "theater/configs", # apps/theater/backup.yaml (all six config jobs share it)
    "books/configs",   # apps/books/backup.yaml
    "home/configs",    # apps/home/backup.yaml
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

# ---------------------------------------------------------------------------
# Immutable versions: the bucket policy
#
# The IAM denials on each user below protect against those keys. This policy
# protects against every other principal in the account too, the account's
# own admin sessions and the CI roles included: nobody can delete an object
# version, suspend versioning or delete the bucket. A delete only ever adds a
# delete marker, and the noncurrent-version lifecycle rule (30 days) is the
# only thing that removes old versions. Lifecycle expiration is done by S3
# itself and is not subject to bucket policies.
#
# The rules that bound that window (lifecycle) and this policy can be changed
# only by the CI apply role (bootstrap/github-oidc), i.e. by a merge to main.
# The account root user can always delete a bucket policy (S3 exempts it from
# denials on the policy actions): that is the break-glass, in the console
# (docs/backups.md "Immutable versions").
#
# Not S3 Object Lock: default retention counts from each version's creation,
# so a restic pack written a year ago and pruned today would get no
# protection, while this policy covers every noncurrent version for its whole
# 30 days. Default retention also makes every PUT require a checksum header,
# a new failure mode for WAL archiving, and enabling Object Lock cannot be
# undone.
# ---------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

locals {
  ci_apply_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/homelab-github-tofu-apply"
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.backups.arn,
      "${aws_s3_bucket.backups.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "DenyVersionDestruction"
    effect = "Deny"
    actions = [
      "s3:DeleteObjectVersion",
      "s3:PutBucketVersioning",
      "s3:DeleteBucket",
    ]
    resources = [
      aws_s3_bucket.backups.arn,
      "${aws_s3_bucket.backups.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }

  statement {
    sid    = "RetentionRulesFromCiOnly"
    effect = "Deny"
    actions = [
      "s3:PutLifecycleConfiguration",
      "s3:PutBucketPolicy",
      "s3:DeleteBucketPolicy",
    ]
    resources = [aws_s3_bucket.backups.arn]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = [local.ci_apply_role_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "backups" {
  bucket = aws_s3_bucket.backups.id
  policy = data.aws_iam_policy_document.bucket.json

  depends_on = [aws_s3_bucket_public_access_block.backups]
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

  # NOTE: there is deliberately no expiry rule for `cnpg/`. The Barman Cloud
  # plugin enforces the 30-day retention of each ObjectStore itself, and it needs
  # to be the one deciding, because deleting a base backup that later WAL still
  # depends on silently destroys the ability to recover to any point in that
  # window. Nor is it transitioned to Glacier: WAL is a stream of small objects
  # with constant churn, the worst possible fit for a class with a 90-day minimum
  # duration.
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
# The Postgres credential, used by the Barman Cloud plugin of every CNPG cluster
# (WAL archiving and base backups under cnpg/<cluster>/). Separate from the
# writer so a database pod never holds a key that can reach the restic
# repositories, and the restic jobs never hold one that can reach the WAL.
# ---------------------------------------------------------------------------
resource "aws_iam_user" "cnpg" {
  name = "${var.bucket_name}-cnpg"
  tags = {
    Purpose = "CNPG WAL archiving and base backups under cnpg/"
    Managed = "opentofu"
  }
}

data "aws_iam_policy_document" "cnpg" {
  # The plugin enforces retention, so DeleteObject is required.
  statement {
    sid    = "CnpgObjectReadWrite"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${aws_s3_bucket.backups.arn}/cnpg/*"]
  }

  # barman-cloud checks the bucket with HeadBucket, which IAM authorises as
  # ListBucket without a prefix. `IfExists` lets that through while any listing
  # with a prefix outside cnpg/ is still denied.
  statement {
    sid       = "CnpgBucketList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.backups.arn]
    condition {
      test     = "StringLikeIfExists"
      variable = "s3:prefix"
      values   = ["cnpg/*"]
    }
  }

  statement {
    sid       = "CnpgBucketLocation"
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
    resources = [aws_s3_bucket.backups.arn]
  }

  # Same denials as the writer: nothing this key does can be made permanent.
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

resource "aws_iam_user_policy" "cnpg" {
  name   = "cnpg-backups"
  user   = aws_iam_user.cnpg.name
  policy = data.aws_iam_policy_document.cnpg.json
}

resource "aws_iam_access_key" "cnpg" {
  user = aws_iam_user.cnpg.name
}

# ---------------------------------------------------------------------------
# A read-only credential for verification, used by the restore tests
# (platform/backup-verify) and the annual in-region restore drill
# (docs/backups.md). It writes only restic lock files and the _lock-test/
# prefix, so a test gone wrong cannot damage the backup it is testing.
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
  # The weekly version-lock test (platform/backup-verify/lock-test.yaml): it
  # writes _lock-test/weekly, tries to delete an old version of it and reads
  # the bucket policy. DeleteObjectVersion is allowed here on purpose, on that
  # prefix only: the bucket policy's deny is then the only thing that stops
  # it, so the test fails if that statement goes.
  statement {
    sid       = "LockTestObject"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:DeleteObjectVersion"]
    resources = ["${aws_s3_bucket.backups.arn}/_lock-test/*"]
  }
  statement {
    sid       = "LockTestPolicyRead"
    effect    = "Allow"
    actions   = ["s3:GetBucketPolicy"]
    resources = [aws_s3_bucket.backups.arn]
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

# ---------------------------------------------------------------------------
# A read-only metrics credential for the AWS dashboard (platform/aws-exporter):
# CloudWatch S3 storage metrics (bucket size per storage class, via YACE),
# Cost Explorer (cost per day, month and service) and a listing of the backup
# bucket for the size per prefix. No object reads, no writes.
# ---------------------------------------------------------------------------
resource "aws_iam_user" "metrics" {
  name = "homelab-metrics-reader"
  tags = {
    Purpose = "read-only CloudWatch and Cost Explorer for Grafana"
    Managed = "opentofu"
  }
}

data "aws_iam_policy_document" "metrics" {
  # These actions do not support resource-level permissions.
  statement {
    sid    = "MetricsRead"
    effect = "Allow"
    actions = [
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:ListMetrics",
      "tag:GetResources",
      "ce:GetCostAndUsage",
      "ce:GetCostForecast",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "BackupBucketList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.backups.arn]
  }
}

resource "aws_iam_user_policy" "metrics" {
  name   = "metrics-readonly"
  user   = aws_iam_user.metrics.name
  policy = data.aws_iam_policy_document.metrics.json
}

resource "aws_iam_access_key" "metrics" {
  user = aws_iam_user.metrics.name
}
