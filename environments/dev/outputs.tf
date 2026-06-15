output "vpc_id" {
  description = "Created VPC ID."
  value       = module.network.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs for ALB and NAT Gateway."
  value       = module.network.public_subnet_ids
}

output "private_app_subnet_ids" {
  description = "Private app subnet IDs for EKS nodes and pods."
  value       = module.network.private_app_subnet_ids
}

output "private_db_subnet_ids" {
  description = "Private DB subnet IDs for RDS."
  value       = module.network.private_db_subnet_ids
}

output "eks_cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "eks_cluster_arn" {
  description = "EKS cluster ARN."
  value       = module.eks.cluster_arn
}

output "eks_oidc_provider_arn" {
  description = "OIDC provider ARN for IRSA integrations."
  value       = module.eks.oidc_provider_arn
}

output "aws_load_balancer_controller_role_arn" {
  description = "IAM role ARN to use with the AWS Load Balancer Controller service account."
  value       = module.eks.aws_load_balancer_controller_role_arn
}

output "rds_endpoint" {
  description = "RDS endpoint address."
  value       = module.rds.db_endpoint
}

output "rds_port" {
  description = "RDS port."
  value       = module.rds.db_port
}

output "rds_security_group_id" {
  description = "Security group attached to the RDS instance."
  value       = module.rds.security_group_id
}
