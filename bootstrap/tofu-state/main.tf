# ---------------------------------------------------------------------------
# The bucket for the OpenTofu state of every root module in bootstrap/, apart
# from the backup bucket, whose writer could read the keys in that state.
# Client-side encryption (TOFU_STATE_PASSPHRASE), SSE-S3, TLS only, 90 days of
# versions, S3-native locking (`use_lockfile`).
#
# It stores its own state in the bucket it creates, so a fresh bootstrap
# runs twice:
#
#   1. With local (encrypted) state:
#        printf 'terraform {\n  backend "local" {}\n}\n' \
#          > bootstrap/tofu-state/backend_override.tf     # git-ignored
#        scripts/tofu.sh bootstrap/tofu-state init
#        scripts/tofu.sh bootstrap/tofu-state apply
#   2. Then into the bucket:
#        rm bootstrap/tofu-state/backend_override.tf
#        scripts/tofu.sh bootstrap/tofu-state init -migrate-state -force-copy
#        rm -P bootstrap/tofu-state/terraform.tfstate*   # now in S3
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket = var.bucket_name

  # Losing this bucket loses the record of everything bootstrap/ created.
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name    = var.bucket_name
    Purpose = "homelab OpenTofu state"
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# SSE-S3: the objects are already OpenTofu ciphertext, so SSE-KMS would only
# add a per-request charge.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  # Every apply writes a new state version and every lock leaves a deleted
  # `.tflock` behind. 90 days of history is the rollback window.
  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }

  # Once the noncurrent versions of a deleted `.tflock` have expired, only its
  # delete marker remains; remove those too.
  rule {
    id     = "remove-expired-delete-markers"
    status = "Enabled"

    filter {}

    expiration {
      expired_object_delete_marker = true
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

data "aws_iam_policy_document" "state" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
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
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state.json

  # A bucket policy is "public" to S3 only if it allows, and this one only
  # denies, but apply it after the block so the order never matters.
  depends_on = [aws_s3_bucket_public_access_block.state]
}
