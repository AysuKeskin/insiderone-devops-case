output "aws_region" {
  description = "Region used; set this as the AWS_REGION GitHub repo secret."
  value       = var.region
}

output "aws_role_arn" {
  description = "GitHub Actions OIDC deploy role; set this as the AWS_ROLE_ARN GitHub repo secret."
  value       = aws_iam_role.gha_deploy.arn
}

output "ec2_instance_id" {
  description = "EC2 instance ID for SSM Send-Command; set this as the EC2_INSTANCE_ID GitHub repo secret."
  value       = aws_instance.app.id
}

output "public_ip" {
  description = "Elastic IP attached to the EC2 instance (point the DNS A record here)."
  value       = aws_eip.app.public_ip
}

output "public_url" {
  description = "Public URL (Cloudflare → Elastic IP → ingress, TLS via cert-manager)."
  value       = "https://insiderone-devopscase.aysu-keskin.uk"
}

output "public_ip_url" {
  description = "Raw Elastic IP URL — still answers over HTTP via the catch-all rule."
  value       = "http://${aws_eip.app.public_ip}"
}
