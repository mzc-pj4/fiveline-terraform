# ── Route53 A 레코드 (CloudFront Alias) ──────────────────────────────────────
# fiveline.store          → 사용자 이커머스 CloudFront
# dashboard.fiveline.store → 관리자 CloudFront (ALB 설정 후 생성)
#
# CloudFront Hosted Zone ID (전 세계 공통 고정값): Z2FDTNDATAQYW2

# ── fiveline.store ────────────────────────────────────────────────────────────

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

# ── dashboard.fiveline.store ──────────────────────────────────────────────────

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
