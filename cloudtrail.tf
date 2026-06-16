# ── CloudTrail + VPC Flow Logs ─────────────────────────────────────────────────
# SEC: Defense in Depth 4번째 레이어 — 감사(Audit) + 이상징후 탐지 기반
#
# CloudTrail = 블랙박스(비행기록장치): "누가, 언제, 무엇을 했는가" 사후 분석
# VPC Flow Logs = 네트워크 트래픽 기록: "어디서 어디로 어떤 포트 트래픽 흐름"
# GuardDuty = 실시간 경보(guardduty.tf 별도 관리)
#
# S3 → Glacier 자동 전환으로 비용 최적화:
#  - 90일 이내: S3 Standard ($0.023/GB) — 빠른 조회 가능
#  - 90일~365일: Glacier Instant ($0.004/GB) — 감사 시 즉시 조회
#  - 365일 이후: 삭제 (법적 보존 기준 1년)

# ── CloudTrail 전용 S3 버킷 ───────────────────────────────────────────────────

resource "aws_s3_bucket" "cloudtrail" {
  bucket        = "${local.project}-cloudtrail-${data.aws_caller_identity.current.account_id}"
  force_destroy = false  # SEC: 감사 로그 실수 삭제 방지 — 삭제 전 수동 확인 강제

  tags = {
    Service = "cloudtrail"
    Name    = "${local.project}-cloudtrail"
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.secrets_manager.arn  # 감사 로그용 CMK 재사용
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    id     = "cloudtrail-retention"
    status = "Enabled"

    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }

    expiration {
      days = 365
    }
  }
}

# CloudTrail이 S3에 쓰기 위한 버킷 정책
resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.cloudtrail.arn
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.cloudtrail]
}

# ── CloudTrail (Multi-Region, Management + Data Events) ───────────────────────

resource "aws_cloudtrail" "fiveline" {
  name                          = "${local.project}-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  include_global_service_events = true  # IAM, STS 등 글로벌 이벤트 포함
  is_multi_region_trail         = true  # 모든 리전 이벤트 단일 트레일로 수집
  enable_log_file_validation    = true  # 로그 파일 무결성 검증 (위조 방지)

  # S3 Data Events: 프론트엔드 버킷 오브젝트 접근 감사
  event_selector {
    read_write_type           = "All"
    include_management_events = true

    data_resource {
      type   = "AWS::S3::Object"
      values = ["${aws_s3_bucket.frontend.arn}/"]
    }
  }

  tags = {
    Service = "cloudtrail"
    Name    = "${local.project}-trail"
  }

  depends_on = [aws_s3_bucket_policy.cloudtrail]
}

# ── VPC Flow Logs (네트워크 트래픽 감사) ─────────────────────────────────────
# REJECT 트래픽 분석 → 포트 스캔/DDoS 패턴 탐지에 활용
# GuardDuty도 Flow Logs를 내부적으로 분석하므로 활성화 필수

resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/aws/vpc/flowlogs/${local.project}"
  retention_in_days = 30  # 30일 CW 보관 후 S3/Glacier로 이관 (비용 최적화)

  tags = {
    Service = "cloudtrail"
    Name    = "${local.project}-vpc-flow-logs"
  }
}

resource "aws_iam_role" "vpc_flow_logs_role" {
  name = "${local.project}-vpc-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Service = "cloudtrail"
    Name    = "${local.project}-vpc-flow-logs-role"
  }
}

resource "aws_iam_role_policy" "vpc_flow_logs_policy" {
  name = "${local.project}-vpc-flow-logs-policy"
  role = aws_iam_role.vpc_flow_logs_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_flow_log" "fiveline_vpc" {
  vpc_id          = aws_vpc.fiveline_vpc.id
  traffic_type    = "ALL"  # ACCEPT + REJECT 모두 기록
  iam_role_arn    = aws_iam_role.vpc_flow_logs_role.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_logs.arn

  tags = {
    Service = "cloudtrail"
    Name    = "${local.project}-vpc-flow-log"
  }
}
