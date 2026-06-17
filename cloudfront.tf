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

# CloudFront → ALB 비밀 헤더 값을 Terraform이 런타임에 생성
# git 소스코드에 하드코딩하지 않음 → 레포 노출 시에도 실제 헤더 값 보호
resource "random_password" "cloudfront_origin_secret" {
  length  = 32
  special = false
}

locals {
  cloudfront_origin_secret = random_password.cloudfront_origin_secret.result
}

# ── 보안 HTTP Response Headers Policy ───────────────────────────────────────
# SEC: OWASP Secure Headers Project 기준 — 브라우저 레벨 방어 추가
#
# HSTS: 브라우저가 이후 모든 요청을 HTTPS로 강제 (HTTP 다운그레이드 공격 방어)
# X-Content-Type-Options: Content-Type 헤더 위조로 스크립트 실행 방지
# X-Frame-Options: 클릭재킹(Clickjacking) 방지 — <iframe> 내 로드 차단
# Referrer-Policy: 외부 링크 클릭 시 URL 유출 최소화
# CSP: 허가된 출처에서만 스크립트/스타일 로드 허용 (XSS 1차 방어선)

resource "aws_cloudfront_response_headers_policy" "security_headers" {
  name    = "${local.project}-security-headers"
  comment = "OWASP 기준 보안 HTTP 헤더 — XSS/클릭재킹/MIME스니핑 방어"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 31536000  # 1년
      include_subdomains         = true
      preload                    = true
      override                   = true
    }

    content_type_options {
      override = true  # X-Content-Type-Options: nosniff
    }

    frame_options {
      frame_option = "DENY"  # X-Frame-Options: DENY
      override     = true
    }

    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }

    xss_protection {
      mode_block = true
      protection = true
      override   = true
    }

    content_security_policy {
      # SEC: 'unsafe-inline' 제거 — script-src에 있으면 인라인 스크립트 실행 허용으로 XSS/Magecart 방어 무력화
      # Tailwind를 빌드 번들링 방식으로 전환했으므로 CDN 스크립트 태그 불필요
      # base-uri/form-action self 추가 — dangling markup + form hijacking 방어
      content_security_policy = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' https://fonts.gstatic.com; connect-src 'self' https://api.fiveline.store; frame-ancestors 'none'; base-uri 'self'; form-action 'self';"
      override                = true
    }
  }
}

# ── CloudFront Function: API 경로 SPA Fallback 차단 ──────────────────────────
# 문제: custom_error_response(403→200+index.html)가 API 에러까지 가로채서
#       프론트엔드가 403을 성공(200)으로 착각하는 부작용 발생
# 해결: /api/* viewer-response 단계에서 text/html 응답을 감지 → 403 JSON으로 복원
resource "aws_cloudfront_function" "api_error_handler" {
  name    = "${local.project}-api-error-handler"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = <<-EOT
    function handler(event) {
      var response = event.response;
      var request  = event.request;

      if (request.uri.startsWith('/api/')) {
        var ct = response.headers['content-type']
          ? response.headers['content-type'].value
          : '';
        if (response.statusCode === 200 && ct.includes('text/html')) {
          response.statusCode        = 403;
          response.statusDescription = 'Forbidden';
          response.headers['content-type'] = { value: 'application/json' };
          response.body = JSON.stringify({ detail: 'Access denied' });
          delete response.headers['age'];
          delete response.headers['cache-control'];
          delete response.headers['etag'];
        }
      }
      return response;
    }
  EOT
}

# ── Origin Access Control (S3 → CloudFront 서명 인증) ─────────────────────────

resource "aws_cloudfront_origin_access_control" "frontend_oac" {
  name                              = "${local.project}-frontend-oac"
  description                       = "OAC for Fiveline S3 frontend bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ── CloudFront Distribution (사용자 이커머스) ─────────────────────────────────

resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Fiveline - S3 frontend + ALB API"
  default_root_object = "index.html"
  price_class         = "PriceClass_200"
  aliases             = ["fiveline.store"]

  web_acl_id = aws_wafv2_web_acl.cloudfront.arn

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
        origin_protocol_policy = "http-only"
        origin_ssl_protocols   = ["TLSv1.2"]
      }

      # SEC: CloudFront → ALB 전달 시 비밀 헤더 추가
      # ALB 직접 접근 요청에는 이 헤더가 없음 → Regional WAF에서 차단
      custom_header {
        name  = "X-Origin-Verify"
        value = local.cloudfront_origin_secret
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

    cache_policy_id            = "658327ea-f89d-4fab-a63d-7e88639e58f6"  # CachingOptimized
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security_headers.id
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

      function_association {
        event_type   = "viewer-response"
        function_arn = aws_cloudfront_function.api_error_handler.arn
      }
    }
  }

  # ── SPA 라우팅: React/Vue 등 CSR 앱을 위한 fallback ─────────────────────────
  # S3 OAC 환경에서 존재하지 않는 경로는 403으로 반환되므로 403도 index.html로 fallback.
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

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.fiveline.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
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

  depends_on = [
    aws_s3_bucket_public_access_block.frontend,
    aws_acm_certificate_validation.fiveline,
  ]
}

# ── Admin CloudFront Distribution (관리자 대시보드) ───────────────────────────
# dashboard.fiveline.store → ALB → admin-service
# WAF IP 화이트리스트로 허가된 IP만 접근 가능

resource "aws_cloudfront_distribution" "admin" {
  count               = var.alb_dns_name != "" ? 1 : 0
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Fiveline Dashboard - ALB admin-service (HTTPS + IP 제한)"
  default_root_object = "index.html"
  price_class         = "PriceClass_200"
  aliases             = ["dashboard.fiveline.store"]

  web_acl_id = aws_wafv2_web_acl.cloudfront.arn

  # ── Origin: 기존 ALB (admin-service 포함) ────────────────────────────────────
  origin {
    domain_name = var.alb_dns_name
    origin_id   = "alb-admin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    # SEC: 관리자 페이지 ALB 직접 접근 방어 — Regional WAF에서 헤더 없는 요청 차단
    custom_header {
      name  = "X-Origin-Verify"
      value = local.cloudfront_origin_secret
    }
  }

  # ── 기본 동작: 모든 요청을 ALB(admin-service)로 전달 ─────────────────────────
  default_cache_behavior {
    target_origin_id       = "alb-admin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id            = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"  # CachingDisabled (API/SPA)
    origin_request_policy_id   = "b689b0a8-53d0-40ab-baf2-68738e2966ac"  # AllViewerExceptHostHeader
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security_headers.id
  }

  # ── SPA 라우팅 ────────────────────────────────────────────────────────────────
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

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.fiveline.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = {
    Service = "admin"
    Name    = "${local.project}-admin-cloudfront"
  }

  depends_on = [
    aws_cloudfront_distribution.main,
    aws_acm_certificate_validation.fiveline,
  ]
}
