# ── CloudFront ─────────────────────────────────────────────────────────────────
# Origin 1 (기본): S3 Frontend — 정적 자산 (/, /static/*, index.html)
# Origin 2 (조건부): ALB API — /api/* 경로 (var.alb_dns_name 설정 후 2차 apply)
#
# 2-phase apply:
#   1차: EKS + VPC + S3 + CloudFront (ALB origin 없이) → S3 frontend 배포 가능
#   2차: EKS 앱 배포 → LB Controller가 ALB 생성 → var.alb_dns_name 주입 → re-apply
#
# 관리형 Cache Policy ID (AWS 제공, 변경되지 않음):
#   CachingOptimized:  658327ea-f89d-4fab-a63d-7e88639e58f6
#   CachingDisabled:   4135ea2d-6df8-44a3-9df3-4b5a84be39ad
# 관리형 Origin Request Policy ID:
#   AllViewerExceptHostHeader: b689b0a8-53d0-40ab-baf2-68738e2966ac

# ── Origin Access Control (S3 → CloudFront 서명 인증) ─────────────────────────

resource "aws_cloudfront_origin_access_control" "frontend_oac" {
  name                              = "${local.project}-frontend-oac"
  description                       = "OAC for Fiveline S3 frontend bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ── CloudFront Distribution ───────────────────────────────────────────────────

resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Fiveline - S3 frontend + ALB API"
  default_root_object = "index.html"
  price_class         = "PriceClass_200"  # 한국 포함, 북미/유럽/아시아 엣지 포함

  # WAF 연결 — 팀원이 waf_cloudfront.tf 구현 후 var.cloudfront_waf_arn 주입
  web_acl_id = var.cloudfront_waf_arn

  # ── Origin 1: S3 Frontend (기본) ─────────────────────────────────────────────
  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "s3-frontend"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend_oac.id
  }

  # ── Origin 2: ALB API (조건부 — var.alb_dns_name 설정 후 활성화) ─────────────
  dynamic "origin" {
    for_each = var.alb_dns_name != "" ? [1] : []
    content {
      domain_name = var.alb_dns_name
      origin_id   = "alb-api"

      custom_origin_config {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "http-only"  # ALB는 ACM 없이 HTTP. 팀원 ACM 구현 후 https-only로 변경
        origin_ssl_protocols   = ["TLSv1.2"]
      }
    }
  }

  # ── Default Cache Behavior: S3 Frontend ──────────────────────────────────────
  default_cache_behavior {
    target_origin_id       = "s3-frontend"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"  # CachingOptimized
  }

  # ── Ordered Cache Behavior: ALB API (/api/*) ─────────────────────────────────
  dynamic "ordered_cache_behavior" {
    for_each = var.alb_dns_name != "" ? [1] : []
    content {
      path_pattern           = "/api/*"
      target_origin_id       = "alb-api"
      viewer_protocol_policy = "redirect-to-https"
      allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
      cached_methods         = ["GET", "HEAD"]
      compress               = true

      cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"  # CachingDisabled
      origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac"  # AllViewerExceptHostHeader
    }
  }

  # ── SPA 라우팅: React/Vue 등 CSR 앱을 위한 fallback ─────────────────────────
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  # ── 인증서 설정 ──────────────────────────────────────────────────────────────
  # 교육용: 실도메인 없이 CloudFront 기본 도메인(*.cloudfront.net) 사용
  # 실도메인 전환 시: acm_certificate_arn + ssl_support_method = "sni-only" 로 교체
  viewer_certificate {
    cloudfront_default_certificate = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = {
    Service = "frontend"
    Name    = "${local.project}-cloudfront"
  }

  depends_on = [aws_s3_bucket_public_access_block.frontend]
}
