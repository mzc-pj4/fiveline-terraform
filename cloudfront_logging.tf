# ── CloudFront Standard Logging v2 ────────────────────────────────────────────
# v1(legacy) vs v2 핵심 차이:
#  v1: awslogsdelivery AWS 계정 → ACL Grant → block_public_acls=false 강제
#  v2: delivery.logs.amazonaws.com 서비스 → 버킷 정책 → block_public_acls=true 유지 가능
#
# v2 추가 장점:
#  - 수 분 내 준실시간 전달 (v1: 수십 분~수 시간)
#  - Parquet/JSON/W3C 포맷 선택 + c-country, ssl-cipher 등 추가 필드
#  - S3 / CloudWatch Logs / Kinesis Firehose 멀티 목적지 지원
#  - aws:SourceAccount 조건으로 Confused Deputy 방어

# ── CloudFront 로그 전용 S3 버킷 ──────────────────────────────────────────────
# cloudtrail 버킷과 분리: 보존 주기/접근 주체/감사 목적이 다름
resource "aws_s3_bucket" "cloudfront_logs" {
  bucket        = "${local.project}-cloudfront-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = false

  tags = {
    Service = "cloudfront"
    Name    = "${local.project}-cloudfront-logs"
  }
}

resource "aws_s3_bucket_public_access_block" "cloudfront_logs" {
  bucket = aws_s3_bucket.cloudfront_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "cloudfront_logs" {
  bucket = aws_s3_bucket.cloudfront_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudfront_logs" {
  bucket = aws_s3_bucket.cloudfront_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.secrets_manager.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudfront_logs" {
  bucket = aws_s3_bucket.cloudfront_logs.id

  rule {
    id     = "cloudfront-log-retention"
    status = "Enabled"

    filter {}

    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }

    expiration {
      days = 365
    }
  }
}

# SEC: 버킷 자체 액세스 감사 — 무단 열람/삭제 시도 탐지
resource "aws_s3_bucket_logging" "cloudfront_logs" {
  bucket        = aws_s3_bucket.cloudfront_logs.id
  target_bucket = aws_s3_bucket.cloudfront_logs.id
  target_prefix = "s3-access/"
}

# 버킷 정책
# SEC: delivery.logs.amazonaws.com + aws:SourceAccount 조건
#      → 자계정 CloudFront distribution만 쓰기 허용 (타 계정 로그 주입 방어)
resource "aws_s3_bucket_policy" "cloudfront_logs" {
  bucket = aws_s3_bucket.cloudfront_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowLogDeliveryWrite"
        Effect = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cloudfront_logs.arn}/*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid    = "AllowLogDeliveryAclCheck"
        Effect = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.cloudfront_logs.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        # SEC: HTTP 전송 명시적 차단 — 전송 중 암호화 강제 (HTTPS-only)
        Sid       = "DenyHTTP"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [
          aws_s3_bucket.cloudfront_logs.arn,
          "${aws_s3_bucket.cloudfront_logs.arn}/*"
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.cloudfront_logs]
}

# ── CloudWatch Logs Vended Delivery (v2) ──────────────────────────────────────

# ── CloudWatch Logs Vended Delivery 리소스는 반드시 us-east-1에서 생성 ──────────
# CloudFront Standard Logs v2의 PutDeliverySource API는 us-east-1에서만 지원
# (CloudFront 글로벌 컨트롤 플레인이 us-east-1 기반)
# S3 버킷은 ap-northeast-2 유지 — cross-region delivery 지원됨

# 로그 목적지 — S3 버킷 (main/admin 공유)
resource "aws_cloudwatch_log_delivery_destination" "cloudfront_s3" {
  provider = aws.us_east_1
  name     = "${local.project}-cloudfront-logs"

  delivery_destination_configuration {
    destination_resource_arn = aws_s3_bucket.cloudfront_logs.arn
  }

  tags = {
    Service = "cloudfront"
    Name    = "${local.project}-cloudfront-log-dest"
  }

  depends_on = [aws_s3_bucket_policy.cloudfront_logs]
}

# 로그 소스 — main distribution
resource "aws_cloudwatch_log_delivery_source" "cloudfront_main" {
  provider     = aws.us_east_1
  name         = "${local.project}-cloudfront-main"
  log_type     = "ACCESS_LOGS"
  resource_arn = aws_cloudfront_distribution.main.arn

  tags = {
    Service = "cloudfront"
    Name    = "${local.project}-cloudfront-main-source"
  }
}

# 로그 소스 — admin distribution (var.alb_dns_name 설정 시에만 생성)
resource "aws_cloudwatch_log_delivery_source" "cloudfront_admin" {
  count    = var.alb_dns_name != "" ? 1 : 0
  provider = aws.us_east_1

  name         = "${local.project}-cloudfront-admin"
  log_type     = "ACCESS_LOGS"
  resource_arn = aws_cloudfront_distribution.admin[0].arn

  tags = {
    Service = "cloudfront"
    Name    = "${local.project}-cloudfront-admin-source"
  }
}

# 소스 ↔ 목적지 연결 — main distribution
resource "aws_cloudwatch_log_delivery" "cloudfront_main" {
  provider                 = aws.us_east_1
  delivery_source_name     = aws_cloudwatch_log_delivery_source.cloudfront_main.name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.cloudfront_s3.arn

  tags = {
    Service = "cloudfront"
    Name    = "${local.project}-cloudfront-main-delivery"
  }
}

# 소스 ↔ 목적지 연결 — admin distribution (count 조건 동기화)
resource "aws_cloudwatch_log_delivery" "cloudfront_admin" {
  count    = var.alb_dns_name != "" ? 1 : 0
  provider = aws.us_east_1

  delivery_source_name     = aws_cloudwatch_log_delivery_source.cloudfront_admin[0].name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.cloudfront_s3.arn

  tags = {
    Service = "cloudfront"
    Name    = "${local.project}-cloudfront-admin-delivery"
  }
}
