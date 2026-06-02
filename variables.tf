variable "k8s_version" {
  description = "EKS Kubernetes 버전"
  type        = string
  default     = "1.35"
}

variable "alb_dns_name" {
  description = "ALB DNS name — LB Controller가 Ingress로 ALB를 생성한 뒤 입력. 비어있으면 CloudFront API origin 비활성화 (2-phase apply)"
  type        = string
  default     = ""
}

variable "cloudfront_waf_arn" {
  description = "CloudFront용 WAF WebACL ARN (us-east-1) — 팀원이 waf_cloudfront.tf 구현 후 주입"
  type        = string
  default     = null
}
