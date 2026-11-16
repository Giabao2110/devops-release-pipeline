output "app_url" {
  description = "Health endpoint of the EC2 instance (reachable from allowed_cidr only)."
  value       = "http://${aws_instance.app.public_ip}:8080/healthz"
}

output "artifact_bucket" {
  value = aws_s3_bucket.artifacts.bucket
}

output "ci_publisher_role_arn" {
  description = "Use with aws-actions/configure-aws-credentials (role-to-assume)."
  value       = aws_iam_role.ci_publisher.arn
}
