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
