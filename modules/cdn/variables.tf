variable "kms_secrets_arn" {
  description = "Secrets Manager CMK ARN (CloudFront 로그 버킷 SSE-KMS 암호화)"
  type        = string
}

variable "alb_dns_name" {
  description = "ALB DNS name — 비어있으면 API origin 없이 S3 only로 배포 (2-phase apply)"
  type        = string
  default     = ""
}

variable "admin_allowed_cidrs" {
  description = "관리자 대시보드 접근 허용 IP 대역 (비어있으면 IP 제한 없음)"
  type        = list(string)
  default     = []
}
