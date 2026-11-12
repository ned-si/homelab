# ---------------------------------------------------------------------------
# The off-site backup target: one S3 bucket and tightly scoped IAM users. Its
# own root module and state: it must survive a cluster rebuild, so nothing
# that manages the cluster can destroy it.
#
# Applied by the `tofu` workflow; by hand, with short-lived credentials:
#
#     aws login --profile homelab --region eu-central-1
#     scripts/tofu.sh bootstrap/aws-backup init
#     scripts/tofu.sh bootstrap/aws-backup plan
#     scripts/tofu.sh bootstrap/aws-backup apply
#
# The state holds the generated secret keys: encrypted by OpenTofu in
# s3://ned-si-homelab-tofu-state, only as safe as TOFU_STATE_PASSPHRASE
# (docs/bootstrap.md). Storage classes and verification: docs/backups.md.
# ---------------------------------------------------------------------------

locals {
  # restic repositories, one lifecycle rule each (S3 prefix filters have no
  # wildcards). Only `data/` may be archived: restic reads `config`, `keys/`,
  # `index/` and `snapshots/` on every operation. A repository missing here
  # still works but stays in S3 Standard at about 6x the price;
  # scripts/check-restic-repos.sh keeps this list equal to the manifests.
  restic_repos = [
    "grafana/data",    # platform/kube-prometheus-stack/routes/grafana-backup.yaml
    "immich/library",  # apps/immich/resources/backup-files.yaml
    "mealie/data",     # apps/mealie/backup.yaml
    "paperless/media", # apps/paperless/backup.yaml
    "syncthing/data",  # apps/syncthing/backup.yaml
    "theater/configs", # apps/theater/backup.yaml (all six config jobs share it)
    "books/configs",   # apps/books/backup.yaml
    "home/configs",    # apps/home/backup.yaml
    "signoz/metadata", # platform/signoz/resources/backup.yaml
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
# Immutable versions: the bucket policy. It denies every principal, the CI
# roles and admin sessions included, deleting an object version, suspending
# versioning or deleting the bucket; only the 30-day noncurrent-version
# lifecycle rule removes old versions. Only the CI apply role can change the
# lifecycle and this policy. Break-glass: the root user can delete the policy
# (docs/backups.md "Immutable versions").
#
# Not Object Lock: its retention counts from each version's creation, so an
# old pack pruned today would get none; it also forces checksum headers on
# every PUT and cannot be undone.
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
  # Not Flexible Retrieval or Deep Archive: restic expects every GET to work.
  # After 1 day, so a pack cannot change class mid-run. GIR bills 90 days at
  # least, which is why retention is months, not days.
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
  # 30 days to notice a compromised credential or a bad prune.
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

  # No expiry rule for `cnpg/`: the Barman Cloud plugin enforces retention,
  # since deleting a base backup that later WAL depends on breaks recovery.
  # Not transitioned: WAL churn is the worst fit for a 90-day minimum.
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

  # DeleteObject above only writes a delete marker; these denials stop
  # anything making a deletion irreversible or disabling versioning. Deny
  # beats Allow, so they hold even under a broader policy.
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
# One restic writer per namespace (assessment finding P6), scoped to that
# namespace's top-level prefix, so one namespace's key reaches neither another
# namespace's repository nor cnpg/. Replaces the shared writer above once
# every s3-backup Secret holds its own key; the shared one then goes.
# ---------------------------------------------------------------------------
locals {
  # namespace = top-level prefix of its restic repositories (restic_repos).
  restic_writers = {
    books      = "books"
    home       = "home"
    immich     = "immich"
    mealie     = "mealie"
    monitoring = "grafana"
    paperless  = "paperless"
    signoz     = "signoz"
    syncthing  = "syncthing"
    theater    = "theater"
  }
}

resource "aws_iam_user" "restic" {
  for_each = local.restic_writers
  name     = "${var.bucket_name}-restic-${each.key}"
  tags = {
    Purpose = "restic writer for ${each.value}/, namespace ${each.key}"
    Managed = "opentofu"
  }
}

data "aws_iam_policy_document" "restic" {
  for_each = local.restic_writers

  # restic prunes, so DeleteObject is required (a delete marker only).
  statement {
    sid    = "PrefixReadWrite"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${aws_s3_bucket.backups.arn}/${each.value}/*"]
  }

  # As for cnpg: HeadBucket is ListBucket without a prefix; any listing with
  # a prefix outside this namespace's is denied.
  statement {
    sid       = "PrefixList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.backups.arn]
    condition {
      test     = "StringLikeIfExists"
      variable = "s3:prefix"
      values   = ["${each.value}/*"]
    }
  }

  statement {
    sid       = "BucketLocation"
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
    resources = [aws_s3_bucket.backups.arn]
  }

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

resource "aws_iam_user_policy" "restic" {
  for_each = local.restic_writers
  name     = "restic-${each.key}"
  user     = aws_iam_user.restic[each.key].name
  policy   = data.aws_iam_policy_document.restic[each.key].json
}

resource "aws_iam_access_key" "restic" {
  for_each = local.restic_writers
  user     = aws_iam_user.restic[each.key].name
}

# ---------------------------------------------------------------------------
# The Barman Cloud credential (cnpg/<cluster>/), apart from the restic writer
# so neither holds a key to the other's data.
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
# Read-only credential for the restore tests and the annual drill
# (docs/backups.md): it writes only restic locks and _lock-test/.
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
  # The weekly version-lock test: DeleteObjectVersion is allowed on
  # _lock-test/ only, so the bucket policy's deny is what stops it, and the
  # test fails if that statement goes.
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
# Read-only metrics credential for platform/aws-exporter: CloudWatch S3
# metrics, Cost Explorer and a listing of the bucket. No object reads.
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
