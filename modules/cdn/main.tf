locals {
  project                  = "fiveline"
  cloudfront_origin_secret = random_password.cloudfront_origin_secret.result
}

data "aws_caller_identity" "current" {}

data "aws_route53_zone" "fiveline" {
  name         = "fiveline.store"
  private_zone = false
}

# ════════════════════════════════════════════════════════════════════════════
# S3 Frontend
# ════════════════════════════════════════════════════════════════════════════

resource "aws_s3_bucket" "frontend" {
  bucket        = "${local.project}-frontend-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Service = "frontend"
    Name    = "${local.project}-frontend"
  }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  versioning_configuration {
    status = "Enabled"
  }
}

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

# ════════════════════════════════════════════════════════════════════════════
# CloudFront 로그 버킷 (Standard Logging v2)
# ════════════════════════════════════════════════════════════════════════════

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
      kms_master_key_id = var.kms_secrets_arn
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

resource "aws_s3_bucket_logging" "cloudfront_logs" {
  bucket        = aws_s3_bucket.cloudfront_logs.id
  target_bucket = aws_s3_bucket.cloudfront_logs.id
  target_prefix = "s3-access/"
}

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
        Sid       = "DenyHTTP"
        Effect    = "Deny"
        Principal = "*" # nosonar — HTTPS 강제 Deny 정책 (보안 강화)
        Action    = "s3:*"
        Resource = [
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

# ════════════════════════════════════════════════════════════════════════════
# ACM Certificate (us-east-1)
# ════════════════════════════════════════════════════════════════════════════

resource "aws_acm_certificate" "fiveline" {
  provider          = aws.us_east_1
  domain_name       = "fiveline.store"
  validation_method = "DNS"

  subject_alternative_names = [
    "*.fiveline.store",
  ]

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${local.project}-cert"
  }
}

resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.fiveline.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.fiveline.zone_id
}

resource "aws_acm_certificate_validation" "fiveline" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.fiveline.arn
  validation_record_fqdns = [for record in aws_route53_record.acm_validation : record.fqdn]
}

# ════════════════════════════════════════════════════════════════════════════
# CloudFront WAF (us-east-1, CLOUDFRONT scope)
# ════════════════════════════════════════════════════════════════════════════

resource "aws_wafv2_ip_set" "admin_allowlist" {
  count              = length(var.admin_allowed_cidrs) > 0 ? 1 : 0
  provider           = aws.us_east_1
  name               = "${local.project}-admin-allowlist"
  scope              = "CLOUDFRONT"
  ip_address_version = "IPV4"
  addresses          = var.admin_allowed_cidrs

  tags = {
    Service = "waf"
    Name    = "${local.project}-admin-allowlist"
  }
}

resource "aws_wafv2_web_acl" "cloudfront" {
  provider    = aws.us_east_1
  name        = "${local.project}-cloudfront-waf"
  scope       = "CLOUDFRONT"
  description = "Fiveline CloudFront WAF - Edge level protection"

  default_action {
    allow {}
  }

  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesAmazonIpReputationList"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesSQLiRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 4

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesKnownBadInputsRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesAnonymousIpList"
    priority = 5

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAnonymousIpList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesAnonymousIpList"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesLinuxRuleSet"
    priority = 6

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesLinuxRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesLinuxRuleSet"
      sampled_requests_enabled   = true
    }
  }

  dynamic "rule" {
    for_each = length(var.admin_allowed_cidrs) > 0 ? [1] : []
    content {
      name     = "admin-ip-allowlist"
      priority = 7

      statement {
        and_statement {
          statement {
            byte_match_statement {
              search_string = "dashboard.fiveline.store"
              field_to_match {
                single_header { name = "host" }
              }
              positional_constraint = "EXACTLY"
              text_transformation {
                priority = 0
                type     = "LOWERCASE"
              }
            }
          }
          statement {
            not_statement {
              statement {
                ip_set_reference_statement {
                  arn = aws_wafv2_ip_set.admin_allowlist[0].arn
                }
              }
            }
          }
        }
      }

      action {
        block {}
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "admin-ip-allowlist"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.project}-cloudfront-waf"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "${local.project}-cloudfront-waf"
  }
}

resource "aws_cloudwatch_log_group" "waf_cloudfront" {
  provider          = aws.us_east_1
  name              = "aws-waf-logs-${local.project}-cloudfront"
  retention_in_days = 90

  tags = {
    Service = "waf"
    Name    = "${local.project}-waf-cloudfront-logs"
  }
}

resource "aws_wafv2_web_acl_logging_configuration" "cloudfront" {
  provider                = aws.us_east_1
  log_destination_configs = [aws_cloudwatch_log_group.waf_cloudfront.arn]
  resource_arn            = aws_wafv2_web_acl.cloudfront.arn
}

# ════════════════════════════════════════════════════════════════════════════
# CloudFront Origin Secret
# ════════════════════════════════════════════════════════════════════════════

resource "random_password" "cloudfront_origin_secret" {
  length  = 32
  special = false
}

# ════════════════════════════════════════════════════════════════════════════
# CloudFront Response Headers Policy
# ════════════════════════════════════════════════════════════════════════════

resource "aws_cloudfront_response_headers_policy" "security_headers" {
  name    = "${local.project}-security-headers"
  comment = "OWASP 기준 보안 HTTP 헤더 — XSS/클릭재킹/MIME스니핑 방어"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      preload                    = true
      override                   = true
    }

    content_type_options {
      override = true
    }

    frame_options {
      frame_option = "DENY"
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
      content_security_policy = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' https://fonts.gstatic.com; connect-src 'self' https://api.fiveline.store; frame-ancestors 'none'; base-uri 'self'; form-action 'self';"
      override                = true
    }
  }
}

# ════════════════════════════════════════════════════════════════════════════
# CloudFront Function
# ════════════════════════════════════════════════════════════════════════════

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

# ════════════════════════════════════════════════════════════════════════════
# CloudFront OAC
# ════════════════════════════════════════════════════════════════════════════

resource "aws_cloudfront_origin_access_control" "frontend_oac" {
  name                              = "${local.project}-frontend-oac"
  description                       = "OAC for Fiveline S3 frontend bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ════════════════════════════════════════════════════════════════════════════
# CloudFront Distributions
# ════════════════════════════════════════════════════════════════════════════

resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Fiveline - S3 frontend + ALB API"
  default_root_object = "index.html"
  price_class         = "PriceClass_200"
  aliases             = ["fiveline.store"]

  web_acl_id = aws_wafv2_web_acl.cloudfront.arn

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "s3-frontend"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend_oac.id
  }

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

      custom_header {
        name  = "X-Origin-Verify"
        value = local.cloudfront_origin_secret
      }
    }
  }

  default_cache_behavior {
    target_origin_id       = "s3-frontend"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id            = "658327ea-f89d-4fab-a63d-7e88639e58f6"
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security_headers.id
  }

  dynamic "ordered_cache_behavior" {
    for_each = var.alb_dns_name != "" ? [1] : []
    content {
      path_pattern           = "/api/*"
      target_origin_id       = "alb-api"
      viewer_protocol_policy = "redirect-to-https"
      allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
      cached_methods         = ["GET", "HEAD"]
      compress               = true

      cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
      origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac"

      function_association {
        event_type   = "viewer-response"
        function_arn = aws_cloudfront_function.api_error_handler.arn
      }
    }
  }

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

resource "aws_cloudfront_distribution" "admin" {
  count               = var.alb_dns_name != "" ? 1 : 0
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Fiveline Dashboard - ALB admin-service"
  default_root_object = "index.html"
  price_class         = "PriceClass_200"
  aliases             = ["dashboard.fiveline.store"]

  web_acl_id = aws_wafv2_web_acl.cloudfront.arn

  origin {
    domain_name = var.alb_dns_name
    origin_id   = "alb-admin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    custom_header {
      name  = "X-Origin-Verify"
      value = local.cloudfront_origin_secret
    }
  }

  default_cache_behavior {
    target_origin_id       = "alb-admin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id            = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    origin_request_policy_id   = "b689b0a8-53d0-40ab-baf2-68738e2966ac"
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security_headers.id
  }

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

# ════════════════════════════════════════════════════════════════════════════
# CloudFront Standard Logging v2
# ════════════════════════════════════════════════════════════════════════════

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

resource "aws_cloudwatch_log_delivery" "cloudfront_main" {
  provider                 = aws.us_east_1
  delivery_source_name     = aws_cloudwatch_log_delivery_source.cloudfront_main.name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.cloudfront_s3.arn

  tags = {
    Service = "cloudfront"
    Name    = "${local.project}-cloudfront-main-delivery"
  }
}

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

# ════════════════════════════════════════════════════════════════════════════
# Route53
# ════════════════════════════════════════════════════════════════════════════

resource "aws_route53_record" "root" {
  zone_id = data.aws_route53_zone.fiveline.zone_id
  name    = "fiveline.store"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "dashboard" {
  count   = var.alb_dns_name != "" ? 1 : 0
  zone_id = data.aws_route53_zone.fiveline.zone_id
  name    = "dashboard.fiveline.store"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.admin[0].domain_name
    zone_id                = aws_cloudfront_distribution.admin[0].hosted_zone_id
    evaluate_target_health = false
  }
}
