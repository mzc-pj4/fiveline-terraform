# ══════════════════════════════════════════════════════════════════════════════
# modules/cicd/main.tf
# ECR + GitHub Actions OIDC IAM Role + S3 Artifact 버킷 통합 모듈
# ══════════════════════════════════════════════════════════════════════════════

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
  services   = toset(var.service_names)
}

# ──────────────────────────────────────────────
# ECR (lhj/modules/ecr/main.tf)
# ──────────────────────────────────────────────

resource "aws_ecr_repository" "services" {
  for_each = local.services

  name                 = "${var.project_name}/${each.value}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Service = each.value
  }
}

resource "aws_ecr_lifecycle_policy" "services" {
  for_each   = aws_ecr_repository.services
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ──────────────────────────────────────────────
# GitHub OIDC Provider (lhj/modules/github-actions-oidc/main.tf)
# 계정에 이미 존재하는 리소스를 data source로 조회
# 없으면 루트 main.tf에서 aws_iam_openid_connect_provider 리소스로 생성 필요
# ──────────────────────────────────────────────

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# ──────────────────────────────────────────────
# IAM Role — GitHub Actions
# ──────────────────────────────────────────────

resource "aws_iam_role" "github_actions" {
  name = "${var.project_name}-${var.environment}-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = data.aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike = {
          "token.actions.githubusercontent.com:sub" = concat(
            [for repo in var.github_repos : "repo:${var.github_org}/${repo}:*"],
            ["repo:${var.github_org}/fiveline-terraform:*"]
          )
        }
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

# ──────────────────────────────────────────────
# Policy — ECR Push
# ──────────────────────────────────────────────

resource "aws_iam_role_policy" "ecr" {
  name = "ecr-push-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*" # nosonar
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
        ]
        Resource = "arn:aws:ecr:${local.region}:${local.account_id}:repository/${var.ecr_prefix}/*"
      },
    ]
  })
}

# ──────────────────────────────────────────────
# Policy — EKS Deploy
# ──────────────────────────────────────────────

resource "aws_iam_role_policy" "eks" {
  name = "eks-deploy-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "EKSDescribe"
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster"]
      Resource = "arn:aws:eks:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:cluster/fiveline-eks"
    }]
  })
}

# ──────────────────────────────────────────────
# Policy — Bedrock (AIOps)
# ──────────────────────────────────────────────

resource "aws_iam_role_policy" "bedrock" {
  name = "bedrock-invoke-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "BedrockInvoke"
      Effect = "Allow"
      Action = ["bedrock:InvokeModel"]
      Resource = "arn:aws:bedrock:${local.region}::foundation-model/anthropic.claude-3-haiku-20240307-v1:0"
    }]
  })
}

# ──────────────────────────────────────────────
# S3 Artifact 버킷 — Lambda zip / Glue 스크립트 저장
# Backend/Frontend CI/CD가 빌드 결과물을 업로드하고
# Terraform이 S3 참조 방식으로 Lambda/Glue를 배포
# ──────────────────────────────────────────────

resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.project_name}-artifacts-${local.account_id}"
  force_destroy = false

  tags = {
    Service = "cicd"
    Name    = "${var.project_name}-artifacts"
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket" "access_logs" {
  bucket        = "${var.project_name}-access-logs-${local.account_id}"
  force_destroy = true
  tags = { Service = "logging", Name = "${var.project_name}-access-logs" }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket                  = aws_s3_bucket.access_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "access_logs" {
  bucket     = aws_s3_bucket.access_logs.id
  depends_on = [aws_s3_bucket_public_access_block.access_logs]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowS3LogDelivery"
        Effect    = "Allow"
        Principal = { Service = "logging.s3.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.access_logs.arn}/*"
        Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
      },
      {
        Sid       = "DenyHTTP"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.access_logs.arn, "${aws_s3_bucket.access_logs.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })
}

resource "aws_s3_bucket_logging" "artifacts" {
  bucket        = aws_s3_bucket.artifacts.id
  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "artifacts/"
  depends_on    = [aws_s3_bucket_policy.access_logs]
}

resource "aws_s3_bucket_policy" "artifacts_https_only" {
  bucket     = aws_s3_bucket.artifacts.id
  depends_on = [aws_s3_bucket_public_access_block.artifacts]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyHTTP"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.artifacts.arn,
        "${aws_s3_bucket.artifacts.arn}/*",
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_iam_role_policy" "github_actions_artifacts" {
  name = "${var.project_name}-github-actions-artifacts"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ArtifactsBucketReadWrite"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.artifacts.arn,
          "${aws_s3_bucket.artifacts.arn}/*"
        ]
      },
      {
        Sid      = "ArtifactsKmsEncrypt"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = var.kms_arn # nosonar
      },
      {
        Sid    = "ReadCicdParameters"
        Effect = "Allow"
        Action = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${local.region}:${local.account_id}:parameter/fiveline/cicd/*"
      }
    ]
  })
}

# ── SSM Parameter Store — CI/CD 참조값 자동 관리 ──────────────────────────────
# GitHub Actions가 이 값들을 런타임에 SSM에서 읽어옴 (수동 Secret 관리 불필요)

resource "aws_iam_role_policy" "github_actions_dashboard" {
  name = "${var.project_name}-github-actions-dashboard"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DashboardBucketWrite"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::${var.dashboard_bucket_name}",
          "arn:aws:s3:::${var.dashboard_bucket_name}/*"
        ]
      }
    ]
  })
}

resource "aws_ssm_parameter" "artifacts_bucket" {
  name  = "/fiveline/cicd/artifacts-bucket"
  type  = "String"
  value = aws_s3_bucket.artifacts.bucket

  tags = {
    Name    = "fiveline-cicd-artifacts-bucket"
    Service = "cicd"
  }
}

resource "aws_ssm_parameter" "dashboard_bucket" {
  name  = "/fiveline/cicd/dashboard-bucket"
  type  = "String"
  value = var.dashboard_bucket_name

  tags = {
    Name    = "fiveline-cicd-dashboard-bucket"
    Service = "cicd"
  }
}

resource "aws_ssm_parameter" "github_actions_role_arn" {
  name  = "/fiveline/cicd/github-actions-role-arn"
  type  = "String"
  value = aws_iam_role.github_actions.arn

  tags = {
    Name    = "fiveline-cicd-github-actions-role-arn"
    Service = "cicd"
  }
}
