variable "environment" {
  description = "배포 환경 (dev / stg / prod)"
  type        = string
  default     = "dev"
}

variable "eks_cluster_name" {
  description = "EKS 클러스터 이름 — 콘솔 생성 후 서브넷 태그에 반영"
  type        = string
  default     = "mzc-pj4-dev-eks"
}
