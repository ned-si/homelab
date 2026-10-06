output "bucket_name" {
  description = "State bucket, for the backend block of every module under bootstrap/."
  value       = aws_s3_bucket.state.id
}

output "region" {
  description = "Region of the state bucket."
  value       = var.region
}
