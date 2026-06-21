variable "project_name" {
  description = "ECR 리포지터리 prefix에 사용되는 프로젝트명 (e.g. fiveline-ecr)"
  type        = string
  default     = "fiveline-ecr"
}

variable "environment" {
  description = "배포 환경 (dev / stg / prod)"
  type        = string
  default     = "prod"
}

variable "service_names" {
  description = "ECR 리포지터리를 생성할 서비스 목록"
  type        = list(string)
  default     = ["user-service", "product-service", "order-service", "frontend"]
}

variable "github_org" {
  description = "GitHub organization name (e.g. mzc-pj4)"
  type        = string
}

variable "github_repos" {
  description = "GitHub Actions OIDC를 허용할 리포지터리 이름 목록 (e.g. [\"fiveline-backend\", \"fiveline-frontend\"])"
  type        = list(string)
}

variable "ecr_prefix" {
  description = "ECR 리포지터리 prefix — IAM 정책 Resource 필터에 사용 (e.g. fiveline-ecr)"
  type        = string
  default     = "fiveline-ecr"
}

variable "kms_arn" {
  description = "KMS 키 ARN — artifact 버킷 암호화에 사용"
  type        = string
}

variable "dashboard_bucket_name" {
  description = "대시보드 S3 버킷명 — GitHub Actions 배포 권한 및 SSM 파라미터에 사용"
  type        = string
}
