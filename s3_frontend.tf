# ── S3 Frontend (정적 호스팅) ──────────────────────────────────────────────────
# CloudFront OAC + S3 REST 엔드포인트 방식 사용
# S3 website hosting 기능 미사용 — OAC는 website 엔드포인트를 지원하지 않음
# SPA 라우팅은 CloudFront custom_error_response (403/404 → /index.html)로 처리

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "frontend" {
  # 전역 유일 버킷명: account ID 포함
  bucket = "${local.project}-frontend-${data.aws_caller_identity.current.account_id}"

  tags = {
    Service = "frontend"
    Name    = "${local.project}-frontend"
  }
}

# 퍼블릭 접근 완전 차단 — CloudFront OAC 경유로만 콘텐츠 제공
resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 버전 관리 — 프론트엔드 롤백 지원
resource "aws_s3_bucket_versioning" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  versioning_configuration {
    status = "Enabled"
  }
}

# CloudFront OAC를 통한 접근만 허용하는 버킷 정책
resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowCloudFrontOAC"
      Effect = "Allow"
      Principal = {
        Service = "cloudfront.amazonaws.com"
      }
      Action   = "s3:GetObject"
      Resource = "${aws_s3_bucket.frontend.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.main.arn
        }
      }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.frontend]
}
