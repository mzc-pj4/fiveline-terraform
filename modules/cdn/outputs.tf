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
