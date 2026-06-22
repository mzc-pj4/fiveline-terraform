variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "eks_cluster_sg_id" {
  description = "EKS 클러스터 보안 그룹 ID (RDS/Redis ingress 허용 대상)"
  type        = string
}

variable "workstation_sg_id" {
  description = "Workstation(Bastion) 보안 그룹 ID (DB admin access)"
  type        = string
}

variable "kms_secrets_arn" {
  description = "Secrets Manager CMK ARN (RDS 패스워드 시크릿 암호화)"
  type        = string
}

variable "kms_rds_arn" {
  description = "RDS CMK ARN (스토리지/스냅샷 SSE-KMS 암호화)"
  type        = string
}

variable "private_rds_subnet_ids" {
  description = "RDS 프라이빗 서브넷 ID 목록 [2a, 2c]"
  type        = list(string)
}

variable "private_cache_subnet_ids" {
  description = "ElastiCache 프라이빗 서브넷 ID 목록 [2a, 2c]"
  type        = list(string)
}
