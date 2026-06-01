output "vpc_id" {
  value = module.network.vpc_id
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

output "rds_endpoint" {
  value = module.rds.endpoint
}

output "rds_secret_arn" {
  description = "Secrets Manager ARN containing DB credentials."
  value       = module.rds.secret_arn
}

output "github_actions_role_arn" {
  description = "IAM Role ARN for GitHub Actions"
  value       = module.github_actions_oidc.github_actions_role_arn
}
