# ── Networking ────────────────────────────────────────────────────────────────

output "vpc_id" {
  value = module.networking.vpc_id
}

output "public_subnet_ids" {
  value = module.networking.public_subnet_ids
}

output "private_eks_subnet_ids" {
  value = module.networking.private_eks_subnet_ids
}

output "private_rds_subnet_ids" {
  value = module.networking.private_rds_subnet_ids
}

output "private_cache_subnet_ids" {
  value = module.networking.private_cache_subnet_ids
}

# ── Compute ───────────────────────────────────────────────────────────────────

output "eks_cluster_name" {
  value = module.compute.eks_cluster_name
}

output "eks_cluster_endpoint" {
  value = module.compute.eks_cluster_endpoint
}

output "eks_oidc_provider_arn" {
  description = "EKS OIDC Provider ARN — 추가 IRSA 생성 시 참조"
  value       = module.compute.oidc_provider_arn
}

output "lb_controller_role_arn" {
  description = "AWS Load Balancer Controller IAM Role ARN — Helm chart values.serviceAccount.annotations에 주입"
  value       = module.compute.lb_controller_role_arn
}

output "bastion_instance_id" {
  description = "WorkStation EC2 인스턴스 ID — SSM 접속: aws ssm start-session --target <id>"
  value       = module.compute.bastion_instance_id
}

# ── Database ──────────────────────────────────────────────────────────────────

output "rds_primary_endpoint" {
  description = "RDS Primary 엔드포인트 (host:port)"
  value       = "${module.database.rds_primary_address}:5432"
}

output "rds_replica_c_endpoint" {
  value = "${module.database.rds_replica_address}:5432"
}

output "rds_replica_a_endpoint" {
  value = "${module.database.rds_replica_a_address}:5432"
}

output "elasticache_primary_endpoint_address" {
  description = "ElastiCache Redis Primary 엔드포인트"
  value       = module.database.redis_endpoint
}

# ── CDN ───────────────────────────────────────────────────────────────────────

output "cloudfront_domain_name" {
  value = module.cdn.cloudfront_domain_name
}

output "cloudfront_distribution_id" {
  value = module.cdn.cloudfront_distribution_id
}

output "s3_frontend_bucket" {
  value = module.cdn.s3_frontend_bucket
}

output "s3_frontend_bucket_arn" {
  value = module.cdn.s3_frontend_arn
}

output "frontend_url" {
  value = "https://fiveline.store"
}

output "admin_cloudfront_domain_name" {
  value = var.alb_dns_name != "" ? "https://dashboard.fiveline.store" : "ALB 미설정 (2차 apply 후 확인)"
}

output "cloudfront_waf_arn" {
  value = module.cdn.cloudfront_waf_arn
}

# ── Security ──────────────────────────────────────────────────────────────────

output "regional_waf_arn" {
  description = "Regional WAF ARN — ingress.yaml wafv2-web-acl-arn annotation에 주입"
  value       = module.security.regional_waf_arn
}

# ── CI/CD ─────────────────────────────────────────────────────────────────────

output "github_actions_role_arn" {
  description = "GitHub Actions IAM Role ARN — GitHub repo secrets에 주입"
  value       = module.cicd.github_actions_role_arn
}

output "ecr_repository_urls" {
  description = "ECR 리포지터리 URL 맵 (서비스명 → URL)"
  value       = module.cicd.ecr_repository_urls
}

# ── Observability ─────────────────────────────────────────────────────────────

output "dashboard_url" {
  description = "운영 대시보드 CloudFront URL"
  value       = module.observability.dashboard_url
}

# ── 2-phase apply 가이드 ──────────────────────────────────────────────────────
# 1차 apply 완료 후 아래 output으로 2차 apply에 필요한 ARN을 확인하세요.

output "_2phase_alarm_history_table_arn" {
  description = "[2-phase] ai 모듈에 주입할 alarm_history_table_arn"
  value       = module.observability.alarm_history_table_arn
}

output "_2phase_langgraph_lambda_arn" {
  description = "[2-phase] observability 모듈에 주입할 langgraph_lambda_arn"
  value       = module.ai.langgraph_agent_function_arn
}

output "_2phase_langgraph_lambda_name" {
  description = "[2-phase] observability 모듈에 주입할 langgraph_lambda_name"
  value       = module.ai.langgraph_agent_function_name
}

output "_2phase_dashboard_builder_lambda_arn" {
  description = "[2-phase] data-pipeline 모듈에 주입할 dashboard_builder_lambda_arn"
  value       = module.observability.dashboard_builder_lambda_arn
}

output "_2phase_dashboard_builder_lambda_name" {
  description = "[2-phase] data-pipeline 모듈에 주입할 dashboard_builder_lambda_name"
  value       = module.observability.dashboard_builder_lambda_name
}
