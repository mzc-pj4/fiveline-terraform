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

  # ── Rule 5: AWS 관리형 — 익명 IP 차단 ────────────────────────────────────
  # VPN, Tor, 오픈 프록시 등 신원을 숨긴 채 접근하는 IP 차단
  # 이커머스 사기 구매 / 어뷰징 시 신원 은닉 목적으로 주로 사용
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

  # ── Rule 6: AWS 관리형 — Linux 특화 공격 차단 ────────────────────────────
  # LFI(로컬 파일 포함), 명령 인젝션 등 Linux 환경 특화 공격
  # EKS 노드가 AL2023(Linux) 위에서 실행되므로 해당
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

  # ── Rule 7: 관리자 대시보드 IP 화이트리스트 (조건부) ─────────────────────
  # var.admin_allowed_cidrs 설정 시에만 활성화
  # host = dashboard.fiveline.store 이고 IP가 허용 목록에 없으면 차단
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

# ── 이커머스 특화 Custom Rule Group ──────────────────────────────────────────
# 관리형 룰셋이 탐지하지 못하는 공격 방어:
# - 크리덴셜 스터핑: 정상 로그인 요청처럼 보이지만 초당 수백 번 반복
# - 카드 BIN 어택: 훔친 카드번호를 결제 엔드포인트에서 유효성 검증
# - 가격 스크래핑: 전 상품 가격을 자동 수집해 경쟁사에 노출
#
# Rate Limit 방식: 내용(Content)이 아닌 행동 패턴(빈도)으로 공격 식별
# 엔드포인트별 임계값을 비즈니스 특성에 맞게 차등 설계

resource "aws_wafv2_rule_group" "ecommerce_ratelimit" {
  name        = "${local.project}-ecommerce-ratelimit"
  scope       = "REGIONAL"
  capacity    = 100
  description = "E-commerce Rate Limit rules - blocks credential stuffing and card BIN attacks"

  # Rule 1: 크리덴셜 스터핑 방어
  # 공격 형태: 유출된 ID/PW DB를 돌리며 /api/users/login에 수천 건 전송
  # 정상 사용자는 5분에 100번 로그인하지 않음 → 봇과 명확히 구분
  rule {
    name     = "login-rate-limit"
    priority = 1

    statement {
      rate_based_statement {
        limit              = 100
        aggregate_key_type = "IP"

        scope_down_statement {
          byte_match_statement {
            search_string         = "/api/users/login"
            positional_constraint = "STARTS_WITH"
            field_to_match {
              uri_path {}
            }
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
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
      metric_name                = "login-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # Rule 2: 카드 BIN 어택 방어
  # 공격 형태: 훔친 카드번호를 /api/orders에 반복 요청해 유효 카드 선별
  # 정상 사용자는 5분에 100번 결제 시도하지 않음
  rule {
    name     = "checkout-rate-limit"
    priority = 2

    statement {
      rate_based_statement {
        limit              = 100
        aggregate_key_type = "IP"

        scope_down_statement {
          byte_match_statement {
            search_string         = "/api/orders"
            positional_constraint = "STARTS_WITH"
            field_to_match {
              uri_path {}
            }
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
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
      metric_name                = "checkout-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # Rule 3: 가격 스크래핑 방어
  # 공격 형태: 경쟁사가 전 상품 가격을 자동 크롤링 → 가격 정책 무력화
  # 상품 조회는 정상적으로 많을 수 있어 임계값을 넉넉하게 설정
  rule {
    name     = "product-scraping-limit"
    priority = 3

    statement {
      rate_based_statement {
        limit              = 500
        aggregate_key_type = "IP"

        scope_down_statement {
          byte_match_statement {
            search_string         = "/api/products"
            positional_constraint = "STARTS_WITH"
            field_to_match {
              uri_path {}
            }
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
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
      metric_name                = "product-scraping-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.project}-ecommerce-ratelimit"
    sampled_requests_enabled   = true
  }

  tags = {
    Name    = "${local.project}-ecommerce-ratelimit"
    Service = "waf"
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

  # ── Rule 0: ALB 직접 접근 차단 ───────────────────────────────────────────
  # CloudFront는 모든 ALB 요청에 X-Origin-Verify 헤더를 주입
  # 이 헤더가 없으면 CloudFront를 거치지 않은 직접 접근 → 차단
  # NOT statement: "헤더 값이 정확히 일치하지 않으면" 차단
  rule {
    name     = "block-direct-alb-access"
    priority = 0

    statement {
      not_statement {
        statement {
          byte_match_statement {
            search_string = local.cloudfront_origin_secret
            field_to_match {
              single_header {
                name = "x-origin-verify"
              }
            }
            positional_constraint = "EXACTLY"
            text_transformation {
              priority = 0
              type     = "NONE"
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
      metric_name                = "block-direct-alb-access"
      sampled_requests_enabled   = true
    }
  }

  # ── Rule 1: 이커머스 특화 Rate Limit (Custom) ─────────────────────────────
  # 크리덴셜 스터핑 / 카드 BIN 어택 / 가격 스크래핑 차단
  rule {
    name     = "ecommerce-ratelimit"
    priority = 1

    statement {
      rule_group_reference_statement {
        arn = aws_wafv2_rule_group.ecommerce_ratelimit.arn
      }
    }

    override_action {
      none {}
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "ecommerce-ratelimit-group"
      sampled_requests_enabled   = true
    }
  }

  # ── Rule 2: AWS 관리형 — 악성 IP 차단 ────────────────────────────────────
  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 2

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

  # ── Rule 3: AWS 관리형 — 공통 룰셋 ──────────────────────────────────────
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 3

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

  # ── Rule 4: AWS 관리형 — SQL 인젝션 특화 ─────────────────────────────────
  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 4

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

  # ── Rule 5: AWS 관리형 — 익명 IP 차단 ────────────────────────────────────
  # VPN, Tor, 오픈 프록시 등 신원을 숨긴 채 접근하는 IP 차단
  # 이커머스 사기 구매 / 어뷰징 시 신원 은닉 목적으로 주로 사용
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
      metric_name                = "RegionalAWSManagedRulesAnonymousIpList"
      sampled_requests_enabled   = true
    }
  }

  # ── Rule 6: AWS 관리형 — Linux 특화 공격 차단 ────────────────────────────
  # LFI(로컬 파일 포함), 명령 인젝션 등 Linux 환경 특화 공격
  # EKS 노드가 AL2023(Linux) 위에서 실행되므로 해당
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
      metric_name                = "RegionalAWSManagedRulesLinuxRuleSet"
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

# ── WAF 로깅 — Regional (ALB) ────────────────────────────────────────────────
# visibility_config의 sampled_requests는 1/500 샘플링만 → 포렌식 불충분
# 전체 요청 로그는 WAF logging_configuration으로만 가능
# CloudWatch 로그 그룹명은 반드시 "aws-waf-logs-" 로 시작해야 함 (AWS 제약)

resource "aws_cloudwatch_log_group" "waf_regional" {
  name              = "aws-waf-logs-${local.project}-regional"
  retention_in_days = 90

  tags = {
    Service = "waf"
    Name    = "${local.project}-waf-regional-logs"
  }
}

resource "aws_wafv2_web_acl_logging_configuration" "regional" {
  log_destination_configs = [aws_cloudwatch_log_group.waf_regional.arn]
  resource_arn            = aws_wafv2_web_acl.regional.arn
}

# ── WAF 로깅 — CloudFront (us-east-1) ────────────────────────────────────────

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

# ── Admin IP 화이트리스트 — dashboard.fiveline.store 접근 제한 ────────────────
# var.admin_allowed_cidrs 에 실제 IP를 설정해야 활성화됨
# 기본값 [] → 룰 없음 (제한 없음)
# 설정 예: terraform apply -var='admin_allowed_cidrs=["203.0.113.0/24"]'

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
