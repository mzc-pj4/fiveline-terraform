# ── KMS Customer Managed Keys ─────────────────────────────────────────────────
# SEC: AWS Managed Key 대신 CMK를 사용하면:
#  1) 키 회전 주기/정책을 직접 통제 (Compliance)
#  2) 키별 독립 감사 가능 (CloudTrail에 KeyId 포함)
#  3) 서비스 간 키 혼용 방지 (Blast Radius 최소화)
#
# 키 3개 분리 이유:
#  etcd — EKS K8s Secrets 암호화 (Control Plane 전용)
#  rds  — RDS 스토리지 + 스냅샷 암호화 (데이터 계층 전용)
#  sm   — Secrets Manager 비밀값 암호화 (자격증명 계층 전용)

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
        # SEC: SNS 토픽 암호화 + EventBridge → SNS Publish 시 복호화 허용
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
        # SEC: CloudFront Logs v2 — delivery.logs.amazonaws.com이 SSE-KMS 버킷에 PutObject 시
        #      GenerateDataKey 필요 (버킷 기본 암호화 자동 적용)
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

# ── Outputs ───────────────────────────────────────────────────────────────────

output "kms_eks_secrets_arn" {
  description = "EKS etcd Secrets CMK ARN"
  value       = aws_kms_key.eks_secrets.arn
}

output "kms_rds_arn" {
  description = "RDS CMK ARN"
  value       = aws_kms_key.rds.arn
}

output "kms_secrets_manager_arn" {
  description = "Secrets Manager CMK ARN"
  value       = aws_kms_key.secrets_manager.arn
}
