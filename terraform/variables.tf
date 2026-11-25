variable "aws_region" {
  description = "The AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "app_name" {
  description = "The name of the application, used for resource naming"
  type        = string
  default     = "commitpulse_github-tracker"
}

# --- NEW DATABASE VARIABLES ---

variable "db_instance_class" {
  description = "RDS instance class (db.t4g.micro = free tier)"
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = "GB of storage (20 = free tier)"
  type        = number
  default     = 20
}

variable "db_name" {
  description = "Initial database name"
  type        = string
}

variable "db_username" {
  description = "RDS master username"
  type        = string
}

variable "db_password" {
  description = "RDS master password (DEV ONLY - throwaway value)"
  type        = string
  sensitive   = true
}

variable "auth_secret" {
  description = "Auth.js session signing secret"
  type        = string
  sensitive   = true
}

variable "github_client_id" {
  description = "GitHub OAuth app client ID"
  type        = string
}

variable "github_client_secret" {
  description = "GitHub OAuth app client secret"
  type        = string
  sensitive   = true
}