# ── ACM Certificate (us-east-1) ───────────────────────────────────────────────
# CloudFront와 연동하려면 인증서가 반드시 us-east-1에 있어야 함 (AWS 제약)
# fiveline.store + *.fiveline.store 와일드카드로 모든 서브도메인 커버

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

# ── Route53 Hosted Zone 데이터 소스 ───────────────────────────────────────────
data "aws_route53_zone" "fiveline" {
  name         = "fiveline.store"
  private_zone = false
}

# ── ACM DNS 검증 레코드 자동 생성 ─────────────────────────────────────────────
# ACM이 요구하는 CNAME 레코드를 Route53에 자동 추가 → 도메인 소유권 검증
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

# ── 인증서 검증 완료 대기 ─────────────────────────────────────────────────────
# CloudFront가 이 리소스에 depends_on → 검증 완료 후 CloudFront 생성 보장
resource "aws_acm_certificate_validation" "fiveline" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.fiveline.arn
  validation_record_fqdns = [for record in aws_route53_record.acm_validation : record.fqdn]
}
