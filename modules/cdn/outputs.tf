output "s3_frontend_arn" {
  description = "프론트엔드 S3 버킷 ARN (security/cloudtrail 데이터 이벤트, compute/iam 정책용)"
  value       = aws_s3_bucket.frontend.arn
}

output "s3_frontend_bucket" {
  description = "프론트엔드 S3 버킷 이름"
  value       = aws_s3_bucket.frontend.bucket
}

output "cloudfront_domain_name" {
  description = "CloudFront 배포 도메인 (main)"
  value       = aws_cloudfront_distribution.main.domain_name
}

output "cloudfront_distribution_id" {
  description = "CloudFront main 배포 ID"
  value       = aws_cloudfront_distribution.main.id
}

output "cloudfront_waf_arn" {
  description = "CloudFront WAF ARN (CLOUDFRONT scope, us-east-1)"
  value       = aws_wafv2_web_acl.cloudfront.arn
}

output "cloudfront_origin_secret" {
  description = "CloudFront → ALB 요청 검증 토큰 (security/regional WAF 차단 규칙용)"
  value       = random_password.cloudfront_origin_secret.result
  sensitive   = true
}

output "acm_cert_arn" {
  description = "ACM 인증서 ARN (us-east-1, *.fiveline.store 와일드카드)"
  value       = aws_acm_certificate_validation.fiveline.certificate_arn
}

output "hosted_zone_id" {
  description = "Route53 Hosted Zone ID (fiveline.store)"
  value       = data.aws_route53_zone.fiveline.zone_id
}

output "guardduty_blocked_ip_set_arn" {
  description = "GuardDuty 자동 차단 WAF IP Set ARN (Lambda가 업데이트하는 대상)"
  value       = aws_wafv2_ip_set.guardduty_blocked_ips.arn
}

output "guardduty_blocked_ip_set_id" {
  description = "GuardDuty 자동 차단 WAF IP Set ID"
  value       = aws_wafv2_ip_set.guardduty_blocked_ips.id
}
