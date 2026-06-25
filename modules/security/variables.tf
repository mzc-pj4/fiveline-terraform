variable "kms_secrets_arn" {
  description = "Secrets Manager CMK ARN (SNS 암호화, CloudTrail S3 암호화)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID (VPC Flow Logs 대상)"
  type        = string
}

variable "s3_frontend_arn" {
  description = "프론트엔드 S3 버킷 ARN (CloudTrail Data Event 감시 대상)"
  type        = string
  default     = ""
}

variable "cloudfront_origin_secret" {
  description = "CloudFront → ALB 요청 검증 토큰 (Regional WAF ALB 직접 접근 차단용)"
  type        = string
  sensitive   = true
}

variable "security_alert_email" {
  description = "보안 알림 수신 이메일"
  type        = string
}

variable "guardduty_blocked_ip_set_arn" {
  description = "GuardDuty 자동 차단 WAF IP Set ARN (Lambda WAF 업데이트 권한용)"
  type        = string
}

variable "guardduty_blocked_ip_set_id" {
  description = "GuardDuty 자동 차단 WAF IP Set ID (Lambda 환경변수 주입용)"
  type        = string
}
