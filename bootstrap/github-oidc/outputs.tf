# The role ARNs go into the repository secrets AWS_PLAN_ROLE_ARN and
# AWS_APPLY_ROLE_ARN. They are secrets only so that Actions masks the account
# ID in public logs.

output "plan_role_arn" {
  description = "Role for tofu plan (pull requests and main)."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "Role for tofu apply of bootstrap/aws-backup (main only)."
  value       = aws_iam_role.apply.arn
}
