# ══════════════════════════════════════════════════════════════════════════════
# modules/cicd/main.tf
# ECR + GitHub Actions OIDC IAM Role 통합 모듈
# 출처: lhj/modules/ecr/ + lhj/modules/github-actions-oidc/
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
      Resource = "*" # nosonar
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
