# ---------------------------------------------------------------------------
# The bucket that holds the OpenTofu state of every root module in bootstrap/.
#
# Separate from the backup bucket on purpose: the backup writer credential can
# GetObject anything in the backup bucket, and the state of bootstrap/aws-backup
# contains that credential's own secret key and the verifier's. State and
# backups must not share a bucket or a reader.
#
# State is protected three ways:
#   - OpenTofu encrypts state and plans client-side (aes_gcm, key derived from
#     TOFU_STATE_PASSPHRASE with pbkdf2), so S3 only ever sees ciphertext;
#   - SSE-S3 encrypts that ciphertext again at rest, and the bucket policy
#     refuses any request that is not TLS;
#   - versioning keeps every previous state for 90 days, so a bad apply or a
#     corrupted write can be rolled back by restoring an older version.
#
# Locking is S3-native (`use_lockfile = true`, OpenTofu >= 1.10): a
# `<key>.tflock` object next to the state. No DynamoDB table.
#
# ###########################################################################
# # CHICKEN AND EGG. This module stores its own state in the bucket it
# # creates. A fresh bootstrap therefore runs in two steps:
# #
# #   1. Apply with LOCAL state (the bucket does not exist yet). The local
# #      state is already encrypted by the encryption block in providers.tf.
# #
# #        printf 'terraform {\n  backend "local" {}\n}\n' \
# #          > bootstrap/tofu-state/backend_override.tf     # git-ignored
# #        scripts/tofu.sh bootstrap/tofu-state init
# #        scripts/tofu.sh bootstrap/tofu-state apply
# #
# #   2. Remove the override and move the state into the bucket:
# #
# #        rm bootstrap/tofu-state/backend_override.tf
# #        scripts/tofu.sh bootstrap/tofu-state init -migrate-state -force-copy
# #        rm -P bootstrap/tofu-state/terraform.tfstate*   # now in S3
# #
# # After that it is an ordinary module. See docs/bootstrap.md.
# ###########################################################################
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
