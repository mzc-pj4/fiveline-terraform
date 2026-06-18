locals {
  project = "fiveline"
}

data "aws_caller_identity" "current" {}

# ── EKS etcd Secrets CMK ──────────────────────────────────────────────────────

resource "aws_kms_key" "eks_secrets" {
  description             = "${local.project} EKS etcd Secrets encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  rotation_period_in_days = 90

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RootFullAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "EKSServiceUse"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Service = "eks"
    Name    = "${local.project}-kms-eks-secrets"
  }
}

resource "aws_kms_alias" "eks_secrets" {
  name          = "alias/${local.project}-eks-secrets"
  target_key_id = aws_kms_key.eks_secrets.key_id
}

# ── RDS CMK ───────────────────────────────────────────────────────────────────

resource "aws_kms_key" "rds" {
  description             = "${local.project} RDS storage encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  rotation_period_in_days = 90

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RootFullAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "RDSServiceUse"
        Effect = "Allow"
        Principal = {
          Service = "rds.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
          "kms:CreateGrant",
          "kms:ListGrants",
          "kms:RevokeGrant"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Service = "rds"
    Name    = "${local.project}-kms-rds"
  }
}

resource "aws_kms_alias" "rds" {
  name          = "alias/${local.project}-rds"
  target_key_id = aws_kms_key.rds.key_id
}

# ── Secrets Manager CMK ───────────────────────────────────────────────────────

resource "aws_kms_key" "secrets_manager" {
  description             = "${local.project} Secrets Manager encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  rotation_period_in_days = 90

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RootFullAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "SecretsManagerServiceUse"
        Effect = "Allow"
        Principal = {
          Service = "secretsmanager.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
          "kms:CreateGrant"
        ]
        Resource = "*"
      },
      {
        Sid    = "SNSAndEventBridgeUse"
        Effect = "Allow"
        Principal = {
          Service = ["sns.amazonaws.com", "events.amazonaws.com"]
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudFrontLogDeliveryUse"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Service = "secretsmanager"
    Name    = "${local.project}-kms-secrets-manager"
  }
}

resource "aws_kms_alias" "secrets_manager" {
  name          = "alias/${local.project}-secrets-manager"
  target_key_id = aws_kms_key.secrets_manager.key_id
}
