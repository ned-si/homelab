# ---------------------------------------------------------------------------
# GitHub Actions to AWS without stored keys: the GitHub OIDC identity provider
# and the two roles .github/workflows/tofu.yaml assumes.
#
#   homelab-github-tofu-plan   read-only on the resources of every module under
#                              bootstrap/ that holds AWS resources, and on their
#                              state. Assumable from pull requests and from main.
#   homelab-github-tofu-apply  applies bootstrap/aws-backup, and only that
#                              module. Assumable from main only.
#
# This module and bootstrap/tofu-state are plan-only: CI never applies them.
# The apply role must not be able to change its own permissions, and the state
# bucket must not depend on the pipeline that writes to it. Apply them by hand:
#
#     aws login --profile homelab --region eu-central-1
#     scripts/tofu.sh bootstrap/github-oidc init
#     scripts/tofu.sh bootstrap/github-oidc apply
#
# then store the role ARNs as the repository secrets AWS_PLAN_ROLE_ARN and
# AWS_APPLY_ROLE_ARN (docs/bootstrap.md "Drift detection").
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  oidc_host  = "token.actions.githubusercontent.com"

  backup_bucket_arn = "arn:aws:s3:::${var.backup_bucket_name}"
  state_bucket_arn  = "arn:aws:s3:::${var.state_bucket_name}"

  # The IAM users bootstrap/aws-backup manages.
  backup_user_arns = [
    "arn:aws:iam::${local.account_id}:user/${var.backup_bucket_name}-*",
    "arn:aws:iam::${local.account_id}:user/homelab-metrics-reader",
  ]
  github_role_arn_pattern = "arn:aws:iam::${local.account_id}:role/homelab-github-tofu-*"

  # Modules the plan role reads; the apply role writes only aws-backup.
  planned_modules = ["bootstrap/aws-backup", "bootstrap/github-oidc", "bootstrap/tofu-state"]
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]

  tags = {
    Purpose = "GitHub Actions OIDC for ${var.github_repository}"
  }
}

# ---------------------------------------------------------------------------
# Trust: this repository only. `sub` is `repo:<owner>/<repo>:pull_request` for
# pull request runs and `repo:<owner>/<repo>:ref:refs/heads/main` for pushes,
# schedules and dispatches on main. Pull requests from forks get no ID token.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "trust_plan" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values = [
        "repo:${var.github_repository}:pull_request",
        "repo:${var.github_repository}:ref:refs/heads/main",
      ]
    }
  }
}

data "aws_iam_policy_document" "trust_apply" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["repo:${var.github_repository}:ref:refs/heads/main"]
    }
  }
}

# ---------------------------------------------------------------------------
# Plan role: bucket-level reads (no object reads in the backup bucket, which
# holds WAL and base backups), IAM reads on the managed users, roles and the
# provider, and the state objects. Plans run with -lock=false, so no write at
# all.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "plan" {
  statement {
    sid    = "BucketConfigRead"
    effect = "Allow"
    actions = [
      "s3:GetBucket*",
      "s3:GetAccelerateConfiguration",
      "s3:GetEncryptionConfiguration",
      "s3:GetLifecycleConfiguration",
      "s3:GetReplicationConfiguration",
    ]
    resources = [local.backup_bucket_arn, local.state_bucket_arn]
  }

  statement {
    sid       = "StateList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.state_bucket_arn]
  }

  statement {
    sid       = "StateRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = [for m in local.planned_modules : "${local.state_bucket_arn}/${m}/terraform.tfstate"]
  }

  statement {
    sid     = "IamRead"
    effect  = "Allow"
    actions = ["iam:Get*", "iam:List*"]
    resources = concat(local.backup_user_arns, [
      local.github_role_arn_pattern,
      aws_iam_openid_connect_provider.github.arn,
    ])
  }
}

resource "aws_iam_role" "plan" {
  name                 = "homelab-github-tofu-plan"
  description          = "tofu plan from GitHub Actions (${var.github_repository}), read-only"
  assume_role_policy   = data.aws_iam_policy_document.trust_plan.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "plan" {
  name   = "tofu-plan"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan.json
}

# ---------------------------------------------------------------------------
# Apply role: what bootstrap/aws-backup needs to create and update its
# resources, and nothing that deletes one. The workflow refuses any plan that
# destroys or replaces a resource, so those changes are applied by hand; the
# role could not run them anyway.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "apply" {
  statement {
    sid    = "BucketConfigRead"
    effect = "Allow"
    actions = [
      "s3:GetBucket*",
      "s3:GetAccelerateConfiguration",
      "s3:GetEncryptionConfiguration",
      "s3:GetLifecycleConfiguration",
      "s3:GetReplicationConfiguration",
    ]
    resources = [local.backup_bucket_arn]
  }

  statement {
    sid    = "BucketConfigWrite"
    effect = "Allow"
    actions = [
      "s3:PutBucketTagging",
      "s3:PutBucketVersioning",
      "s3:PutBucketPublicAccessBlock",
      "s3:PutBucketPolicy",
      "s3:PutEncryptionConfiguration",
      "s3:PutLifecycleConfiguration",
    ]
    resources = [local.backup_bucket_arn]
  }

  statement {
    sid    = "UsersWrite"
    effect = "Allow"
    actions = [
      "iam:GetUser",
      "iam:GetUserPolicy",
      "iam:ListUserPolicies",
      "iam:ListAttachedUserPolicies",
      "iam:ListAccessKeys",
      "iam:ListUserTags",
      "iam:CreateUser",
      "iam:TagUser",
      "iam:UntagUser",
      "iam:PutUserPolicy",
      "iam:CreateAccessKey",
    ]
    resources = local.backup_user_arns
  }

  statement {
    sid       = "StateList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.state_bucket_arn]
  }

  statement {
    sid       = "StateReadWrite"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${local.state_bucket_arn}/bootstrap/aws-backup/terraform.tfstate"]
  }

  # S3-native locking: the lock object is created and then deleted.
  statement {
    sid       = "StateLock"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.state_bucket_arn}/bootstrap/aws-backup/terraform.tfstate.tflock"]
  }
}

resource "aws_iam_role" "apply" {
  name                 = "homelab-github-tofu-apply"
  description          = "tofu apply of bootstrap/aws-backup from GitHub Actions (${var.github_repository} main)"
  assume_role_policy   = data.aws_iam_policy_document.trust_apply.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "apply" {
  name   = "tofu-apply-aws-backup"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply.json
}
