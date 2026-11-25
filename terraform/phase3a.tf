# ==========================================
# VPC (minimal: private subnets only, NO IGW/NAT)
# ==========================================
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "${var.app_name}-vpc"
    Project     = var.app_name
    Environment = "dev"
  }
}

resource "aws_subnet" "private_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = false

  tags = { Name = "${var.app_name}-private-a" }
}

resource "aws_subnet" "private_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "${var.aws_region}b"
  map_public_ip_on_launch = false

  tags = { Name = "${var.app_name}-private-b" }
}

# ==========================================
# Security Group (minimal: allow RDS access from EC2 only)
# ==========================================
resource "aws_security_group" "rds" {
  name        = "${var.app_name}-rds-sg"
  description = "PostgreSQL, reachable only from App Runner connector"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.app_name}-rds-sg" }
}

# ==========================================
# RDS PostgreSQL (Free Tier: db.t4g.micro, single-AZ, private)
# ==========================================
resource "aws_db_subnet_group" "private" {
  name       = "${var.app_name}-private-db-subnet-group"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_b.id]

  tags = { Name = "${var.app_name}-private-db-subnet-group" }
}

resource "aws_db_instance" "app" {
  identifier             = "${replace(var.app_name, "_", "-")}-db"
  engine                 = "postgres"
  engine_version         = "16.4"
  instance_class         = var.db_instance_class
  allocated_storage      = var.db_allocated_storage
  storage_encrypted      = true
  db_name                = var.db_name
  username               = var.db_username
  password               = var.db_password
  port                   = 5432
  multi_az               = false # single-AZ = free tier
  publicly_accessible    = false # private subnet only
  db_subnet_group_name   = aws_db_subnet_group.private.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  skip_final_snapshot    = true # CRITICAL: lets `terraform destroy` work cleanly
  deletion_protection    = false

  tags = {
    Name    = "${var.app_name}-db"
    Project = var.app_name
  }
}

# ==========================================
# SSM Parameter Store (SecureString = KMS-encrypted at rest)
# ==========================================
resource "aws_ssm_parameter" "database_url" {
  name = "/${var.app_name}/DATABASE_URL"
  type = "SecureString"
  # This correctly uses the variables we declared in variables.tf
  value = "postgres://${var.db_username}:${var.db_password}@${aws_db_instance.app.endpoint}/${var.db_name}"
}

resource "aws_ssm_parameter" "auth_secret" {
  name  = "/${var.app_name}/AUTH_SECRET"
  type  = "SecureString"
  value = var.auth_secret
}

resource "aws_ssm_parameter" "auth_github_id" {
  name  = "/${var.app_name}/AUTH_GITHUB_ID"
  type  = "SecureString"
  value = var.github_client_id
}

resource "aws_ssm_parameter" "auth_github_secret" {
  name  = "/${var.app_name}/AUTH_GITHUB_SECRET"
  type  = "SecureString"
  value = var.github_client_secret
}