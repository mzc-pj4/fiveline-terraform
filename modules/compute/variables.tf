variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "private_eks_subnet_ids" {
  description = "EKS 노드 그룹 프라이빗 서브넷 ID 목록 [2a, 2c]"
  type        = list(string)
}

variable "private_bastion_subnet_id" {
  description = "Workstation EC2 배치 서브넷 ID (private 2a)"
  type        = string
}

variable "kms_eks_secrets_arn" {
  description = "EKS Secrets(etcd) CMK ARN — K8s Secret 저장 시 envelope 암호화"
  type        = string
}

variable "s3_frontend_arn" {
  description = "프론트엔드 S3 버킷 ARN (product-service IRSA 정책용)"
  type        = string
}

variable "k8s_version" {
  description = "EKS Kubernetes 버전"
  type        = string
  default     = "1.31"
}
