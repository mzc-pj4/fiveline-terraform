data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
}

# ────────────────────────────────────────────────
# GitHub OIDC Provider (기존 것 참조)
# ────────────────────────────────────────────────
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# ────────────────────────────────────────────────
# IAM Role — GitHub Actions
# ────────────────────────────────────────────────
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

# ────────────────────────────────────────────────
# Policy — ECR Push
# ────────────────────────────────────────────────
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
        Resource = "*"
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

# ────────────────────────────────────────────────
# Policy — EKS Deploy
# ────────────────────────────────────────────────
resource "aws_iam_role_policy" "eks" {
  name = "eks-deploy-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "EKSDescribe"
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster"]
      Resource = "*"
    }]
  })
}

# ────────────────────────────────────────────────
# Policy — Bedrock (AIOps)
# ────────────────────────────────────────────────
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

# ────────────────────────────────────────────────
# Policy — CloudWatch + ELBv2 (Post-Canary 메트릭)
# ────────────────────────────────────────────────
resource "aws_iam_role_policy" "cloudwatch_read" {
  name = "cloudwatch-read-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchRead"
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:GetMetricData",
          "cloudwatch:ListMetrics",
        ]
        Resource = "*"
      },
      {
        Sid    = "ELBDescribe"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeTargetGroups",
        ]
        Resource = "*"
      },
    ]
  })
}

# ────────────────────────────────────────────────
# Policy — DynamoDB (AIOps 결과 저장)
# ────────────────────────────────────────────────
resource "aws_iam_role_policy" "dynamodb_aiops_write" {
  name = "dynamodb-aiops-write-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "DynamoDBPutItem"
      Effect = "Allow"
      Action = [
        "dynamodb:PutItem",
      ]
      Resource = "arn:aws:dynamodb:${local.region}:${local.account_id}:table/${var.project_name}-${var.environment}-aiops-canary-logs"
    }]
  })
}
