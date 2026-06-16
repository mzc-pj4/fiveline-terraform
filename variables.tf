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

variable "security_alert_email" {
  description = "GuardDuty 보안 알림 수신 이메일 주소"
  type        = string
  default     = "lljjmm1010@gmail.com"
}

variable "admin_allowed_cidrs" {
  description = "관리자 대시보드(dashboard.fiveline.store) 접근 허용 IP 대역 (CIDR 리스트). 비어있으면 IP 제한 없음."
  type        = list(string)
  default     = []
}
