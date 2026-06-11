# ── WAF v2 ───────────────────────────────────────────────────────────────────
#
# [구성 개요 — 2-Tier 방어]
# 1. CloudFront WAF (us-east-1, CLOUDFRONT scope)
#    → fiveline.store / dashboard.fiveline.store 엣지 레벨 보호
#    → 악성 IP, SQLi, XSS, 알려진 나쁜 입력값 차단
#
# 2. Regional WAF (ap-northeast-2, REGIONAL scope)
#    → ALB(API 레이어) 보호 — CloudFront를 우회한 직접 요청 방어
#    → 동일 관리형 룰셋으로 심층 방어(Defense in Depth) 구현

# ── CloudFront WAF (us-east-1) ────────────────────────────────────────────────

resource "aws_wafv2_web_acl" "cloudfront" {
  provider    = aws.us_east_1
  name        = "${local.project}-cloudfront-waf"
  scope       = "CLOUDFRONT"
  description = "Fiveline CloudFront WAF - Edge level protection"

  default_action {
    allow {}
  }

  # ── Rule 1: AWS 관리형 — 알려진 악성 IP 차단 ─────────────────────────────
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

  # ── Rule 2: AWS 관리형 — 공통 룰셋 (SQLi, XSS, LFI 등) ──────────────────
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

  # ── Rule 3: AWS 관리형 — SQL 인젝션 특화 ─────────────────────────────────
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

  # ── Rule 4: AWS 관리형 — 알려진 나쁜 입력값 차단 ─────────────────────────
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

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.project}-cloudfront-waf"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "${local.project}-cloudfront-waf"
  }
}

# ── Regional WAF (ap-northeast-2) ─────────────────────────────────────────────
# ALB에 연결 — CloudFront를 우회한 직접 ALB 접근 방어
# ingress.yaml의 wafv2-web-acl-arn annotation에 주입

resource "aws_wafv2_web_acl" "regional" {
  name        = "${local.project}-regional-waf"
  scope       = "REGIONAL"
  description = "Fiveline ALB WAF - API layer defense in depth"

  default_action {
    allow {}
  }

  # ── Rule 1: AWS 관리형 — 악성 IP 차단 ────────────────────────────────────
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
      metric_name                = "RegionalAWSManagedRulesAmazonIpReputationList"
      sampled_requests_enabled   = true
    }
  }

  # ── Rule 2: AWS 관리형 — 공통 룰셋 ──────────────────────────────────────
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
      metric_name                = "RegionalAWSManagedRulesCommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # ── Rule 3: AWS 관리형 — SQL 인젝션 특화 ─────────────────────────────────
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
      metric_name                = "RegionalAWSManagedRulesSQLiRuleSet"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.project}-regional-waf"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "${local.project}-regional-waf"
  }
}
