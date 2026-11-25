# =============================================================================
# phase3c.tf: EC2 + Elastic IP + CloudFront (HTTPS edge) for the Next.js app
#
# Assumes these already exist in your other .tf files (rename below if not):
#   var.app_name, var.aws_region
#   aws_vpc.main
#   aws_security_group.rds
#   aws_ecr_repository.app_repo
#   aws_ssm_parameter.database_url / auth_secret / auth_github_id / auth_github_secret
# =============================================================================

locals {
  ecr_registry = split("/", aws_ecr_repository.app_repo.repository_url)[0]
  image        = "${aws_ecr_repository.app_repo.repository_url}:latest"

  ssm_parameter_arns = [
    aws_ssm_parameter.database_url.arn,
    aws_ssm_parameter.auth_secret.arn,
    aws_ssm_parameter.auth_github_id.arn,
    aws_ssm_parameter.auth_github_secret.arn,
  ]
}

# -----------------------------------------------------------------------------
# 1. NETWORKING: IGW + public subnet (EC2 needs outbound internet for ECR/SSM)
# -----------------------------------------------------------------------------
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.app_name}-igw" }
}

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.3.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.app_name}-public-a" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.app_name}-public-rt" }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

# -----------------------------------------------------------------------------
# 2. IAM: instance profile (least privilege)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "ec2" {
  name = "${var.app_name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# Lets the SSM agent register so Session Manager works (no SSH, no port 22)
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "app" {
  name = "${var.app_name}-ec2-app-access"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrAuthToken"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "EcrPullThisRepoOnly"
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchCheckLayerAvailability",
        ]
        Resource = aws_ecr_repository.app_repo.arn
      },
      {
        # Default aws/ssm KMS key needs no explicit kms:Decrypt grant.
        # If you used a customer-managed key for the SecureStrings, add kms:Decrypt on it here.
        Sid      = "ReadOnlyTheFourAppParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = local.ssm_parameter_arns
      },
    ]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.app_name}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# -----------------------------------------------------------------------------
# 3. SECURITY GROUPS
# -----------------------------------------------------------------------------
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "ec2" {
  name        = "${var.app_name}-ec2-sg"
  description = "HTTP from CloudFront origin-facing IPs only"
  vpc_id      = aws_vpc.main.id

  # NOTE: this prefix list counts as ~55 rules against the default 60 rules/SG quota.
  # Don't add many more ingress rules to this SG.
  ingress {
    description     = "HTTP from CloudFront"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  }

  egress {
    description = "All outbound (ECR, SSM, RDS)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.app_name}-ec2-sg" }
}

# RDS accepts Postgres from the EC2 SG.
# IMPORTANT: remove the old connector-sg ingress from aws_security_group.rds in the file where
# it's defined. If that SG uses inline ingress{} blocks, delete them there, otherwise Terraform
# will fight this standalone rule.
resource "aws_security_group_rule" "rds_from_ec2" {
  type                     = "ingress"
  description              = "Postgres from app EC2"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_security_group.ec2.id
}

# -----------------------------------------------------------------------------
# 4. EC2 + ELASTIC IP
#    The EIP exists before the instance, so CloudFront can use its DNS name as the
#    origin and the instance can be told the CloudFront URL at boot. No dependency
#    cycle, no manual sed step.
# -----------------------------------------------------------------------------
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_eip" "app" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.main]
  tags       = { Name = "${var.app_name}-eip" }
}

resource "aws_instance" "app" {
  ami                         = data.aws_ssm_parameter.al2023_ami.value
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public_a.id
  vpc_security_group_ids      = [aws_security_group.ec2.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  associate_public_ip_address = true # temporary IP so boot-time pulls work; released when the EIP attaches

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # containers can't reach instance metadata
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 16
    encrypted   = true
  }

  user_data_replace_on_change = true

  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail
    exec > /var/log/user-data.log 2>&1

    export AWS_DEFAULT_REGION="${var.aws_region}"

    retry() {
      for i in $(seq 1 12); do
        "$@" && return 0
        echo "retry $i failed: $*"
        sleep 10
      done
      return 1
    }

    retry dnf install -y docker
    systemctl enable --now docker

    # ECR login uses the registry host, not the full repo URL
    aws ecr get-login-password | docker login --username AWS --password-stdin ${local.ecr_registry}
    retry docker pull ${local.image}

    get_param() {
      aws ssm get-parameter --name "$1" --with-decryption --query "Parameter.Value" --output text
    }

    DB_URL=$(get_param "${aws_ssm_parameter.database_url.name}")
    AUTH_SEC=$(get_param "${aws_ssm_parameter.auth_secret.name}")
    GH_ID=$(get_param "${aws_ssm_parameter.auth_github_id.name}")
    GH_SEC=$(get_param "${aws_ssm_parameter.auth_github_secret.name}")

    # RDS PostgreSQL 16 requires SSL; append sslmode if the URL doesn't set one
    if [[ "$DB_URL" != *sslmode=* ]]; then
      if [[ "$DB_URL" == *\?* ]]; then DB_URL="$DB_URL&sslmode=require"; else DB_URL="$DB_URL?sslmode=require"; fi
    fi

    umask 077
    {
      printf 'DATABASE_URL=%s\n' "$DB_URL"
      printf 'AUTH_SECRET=%s\n' "$AUTH_SEC"
      printf 'AUTH_GITHUB_ID=%s\n' "$GH_ID"
      printf 'AUTH_GITHUB_SECRET=%s\n' "$GH_SEC"
      printf 'AUTH_URL=%s\n' "https://${aws_cloudfront_distribution.main.domain_name}"
      printf 'NEXT_PUBLIC_APP_URL=%s\n' "https://${aws_cloudfront_distribution.main.domain_name}"
      printf 'AUTH_TRUST_HOST=true\n'
      printf 'NODE_ENV=production\n'
      printf 'PORT=3000\n'
      printf 'HOSTNAME=0.0.0.0\n'
    } > /etc/tracker.env
    chmod 600 /etc/tracker.env

    docker rm -f tracker-app 2>/dev/null || true
    docker run -d --name tracker-app --restart always \
      -p 80:3000 --env-file /etc/tracker.env \
      ${local.image}
  EOT

  # Don't replace the instance every time AWS publishes a new AL2023 AMI
  lifecycle {
    ignore_changes = [ami]
  }

  tags = { Name = "${var.app_name}-ec2" }
}

resource "aws_eip_association" "app" {
  instance_id   = aws_instance.app.id
  allocation_id = aws_eip.app.id
}

# -----------------------------------------------------------------------------
# 5. CLOUDFRONT: HTTPS edge, caching disabled, everything forwarded
# -----------------------------------------------------------------------------
data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

resource "aws_cloudfront_distribution" "main" {
  enabled         = true
  is_ipv6_enabled = true
  http_version    = "http2and3"
  price_class     = "PriceClass_100"
  comment         = "${var.app_name} (Next.js on EC2)"

  origin {
    domain_name = aws_eip.app.public_dns
    origin_id   = "ec2-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only" # no cert on the instance; see note in the review
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    # Optional hardening: add a secret header here and reject requests without it
    # in Next.js middleware, so only YOUR distribution can reach the origin.
    # custom_header {
    #   name  = "X-Origin-Verify"
    #   value = "<random secret>"
    # }
  }

  default_cache_behavior {
    target_origin_id       = "ec2-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # Auth.js sessions + SSR: never cache, forward all cookies/headers/query strings
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = { Name = "${var.app_name}-cloudfront" }
}

# -----------------------------------------------------------------------------
# OUTPUTS
# -----------------------------------------------------------------------------
output "cloudfront_domain" {
  value = aws_cloudfront_distribution.main.domain_name
}

output "github_oauth_callback_url" {
  description = "Paste into the GitHub OAuth app's Authorization callback URL"
  value       = "https://${aws_cloudfront_distribution.main.domain_name}/api/auth/callback/github"
}

output "github_oauth_homepage_url" {
  value = "https://${aws_cloudfront_distribution.main.domain_name}"
}

output "ec2_instance_id" {
  description = "Use with: aws ssm start-session --target <id>"
  value       = aws_instance.app.id
}

output "ec2_public_ip" {
  value = aws_eip.app.public_ip
}