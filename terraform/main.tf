# Define the AWS provider and region
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # Store the state file locally for now (we will move this to S3 later)
  required_version = ">= 1.0.0"
}

provider "aws" {
  region = var.aws_region
}

# ==========================================
# RESOURCE 1: ECR Repository
# ==========================================
resource "aws_ecr_repository" "app_repo" {
  name                 = var.app_name
  image_tag_mutability = "MUTABLE" # Allows overwriting tags (useful for CI/CD 'latest' tag)

  # FREE TIER PROTECTION: Automatically delete old images to stay under the 500MB free limit
  image_scanning_configuration {
    scan_on_push = true
  }
}

# Lifecycle policy to keep only the last 3 images, preventing storage costs
resource "aws_ecr_lifecycle_policy" "app_repo_policy" {
  repository = aws_ecr_repository.app_repo.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the last 3 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 3
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}