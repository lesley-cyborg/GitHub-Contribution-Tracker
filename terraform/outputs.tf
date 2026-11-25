output "ecr_repository_url" {
  description = "The URL of the ECR repository"
  value       = aws_ecr_repository.app_repo.repository_url
}

output "rds_endpoint" {
  description = "RDS connection endpoint (host:port)"
  value       = aws_db_instance.app.endpoint
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (RDS subnet group)"
  value       = [aws_subnet.private_a.id, aws_subnet.private_b.id]
}

output "ssm_parameter_names" {
  description = "Names of the SSM parameters the EC2 instance reads at boot"
  value = [
    aws_ssm_parameter.database_url.name,
    aws_ssm_parameter.auth_secret.name,
    aws_ssm_parameter.auth_github_id.name,
    aws_ssm_parameter.auth_github_secret.name,
  ]
}