# ════════════════════════════════════════════════════════════════════════════
# 의존성 체인 (위에서 아래로)
#
#  networking ──┐
#  kms        ──┼──▶ cdn ──▶ security
#               │         ▶ compute ──▶ database
#               │
#               └──────────────────────────▶ data-pipeline
#                                         ▶ ai            (data-pipeline 출력)
#                                         ▶ observability (data-pipeline + ai 출력)
#                                         ▶ cicd          (독립)
#
#  순환 의존성 해소 (2-phase apply):
#   1차: 모든 모듈 apply (alarm_history_table_arn / langgraph_lambda_arn /
#         dashboard_builder_lambda_arn 은 "" 로 시작)
#   2차: terraform output으로 확인한 ARN을 variables에 넣고 재 apply
# ════════════════════════════════════════════════════════════════════════════

# ── 1. Networking ─────────────────────────────────────────────────────────────

module "networking" {
  source = "./modules/networking"
}

# ── 2. KMS ────────────────────────────────────────────────────────────────────

module "kms" {
  source = "./modules/kms"
}

# ── 3. CDN (CloudFront + S3 + WAF + ACM + Route53) ────────────────────────────
# us_east_1 provider alias 전달 필수 (ACM, CloudFront WAF)

module "cdn" {
  source = "./modules/cdn"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  kms_secrets_arn     = module.kms.secrets_manager_arn
  alb_dns_name        = var.alb_dns_name
  admin_allowed_cidrs = var.admin_allowed_cidrs
}

# ── 4. Security (GuardDuty + CloudTrail + Regional WAF) ──────────────────────

module "security" {
  source = "./modules/security"

  vpc_id                   = module.networking.vpc_id
  kms_secrets_arn          = module.kms.secrets_manager_arn
  s3_frontend_arn          = module.cdn.s3_frontend_arn
  cloudfront_origin_secret = module.cdn.cloudfront_origin_secret
  security_alert_email     = var.security_alert_email
}

# ── 5. Compute (EKS + IAM + Workstation) ──────────────────────────────────────

module "compute" {
  source = "./modules/compute"

  vpc_id                    = module.networking.vpc_id
  private_eks_subnet_ids    = module.networking.private_eks_subnet_ids
  private_bastion_subnet_id = module.networking.private_bastion_subnet_id
  kms_eks_secrets_arn       = module.kms.eks_secrets_arn
  s3_frontend_arn           = module.cdn.s3_frontend_arn
  k8s_version               = var.k8s_version
}

# ── 6. Database (RDS + ElastiCache) ───────────────────────────────────────────
# compute 이후 (eks_cluster_sg_id, workstation_sg_id 필요)

module "database" {
  source = "./modules/database"

  vpc_id                   = module.networking.vpc_id
  eks_cluster_sg_id        = module.compute.eks_cluster_sg_id
  workstation_sg_id        = module.compute.workstation_sg_id
  kms_secrets_arn          = module.kms.secrets_manager_arn
  kms_rds_arn              = module.kms.rds_arn
  private_rds_subnet_ids   = module.networking.private_rds_subnet_ids
  private_cache_subnet_ids = module.networking.private_cache_subnet_ids
}

# ── 7. Data Pipeline (jihoo — Firehose, Glue, Athena, Lambda, DynamoDB) ───────
# 2-phase 변수: dashboard_builder_lambda_arn (1차=""  → 2차=observability output)

module "data_pipeline" {
  source = "./modules/data-pipeline"

  artifacts_bucket              = module.cicd.artifacts_bucket
  dashboard_builder_lambda_arn  = var.dashboard_builder_lambda_arn
  dashboard_builder_lambda_name = var.dashboard_builder_lambda_name
}

# ── 8. AI (jihoo — Bedrock, LangGraph, Report Embedder) ───────────────────────
# data-pipeline 이후 (data_lake_bucket_arn, check_results_table_arn 등 필요)
# 2-phase 변수: alarm_history_table_arn (1차="" → 2차=observability output)

module "ai" {
  source = "./modules/ai"

  env              = "prod"
  artifacts_bucket = module.cicd.artifacts_bucket

  data_lake_bucket_arn         = module.data_pipeline.data_lake_bucket_arn
  data_lake_bucket_name        = module.data_pipeline.data_lake_bucket_id
  check_results_table_arn      = module.data_pipeline.check_results_table_arn
  check_results_table_name     = module.data_pipeline.check_results_table_name
  dashboard_summary_table_arn  = module.data_pipeline.dashboard_summary_table_arn
  dashboard_summary_table_name = module.data_pipeline.dashboard_summary_table_name
  report_metadata_table_arn    = module.data_pipeline.report_metadata_table_arn
  report_metadata_table_name   = module.data_pipeline.report_metadata_table_name
  glue_database_name           = module.data_pipeline.glue_database_name
  alarm_history_table_arn      = var.alarm_history_table_arn
}

# ── 9. Observability (hsh 알람/모니터링 + jihoo 대시보드) ─────────────────────
# 2-phase 변수: langgraph_lambda_arn/name (1차="" → 2차=ai output)
# data-pipeline 이후 (data_lake_bucket_arn, check_results_table_arn 등 필요)
# hsh Lambda 소스 코드: hsh/lambda/alarm_handler/ → modules/observability/lambda/alarm_handler/ 복사 필요

module "observability" {
  source = "./modules/observability"

  artifacts_bucket = module.cicd.artifacts_bucket

  # hsh 변수
  s3_bucket_name             = module.data_pipeline.data_lake_bucket_id
  slack_webhook_url          = var.slack_webhook_url
  alb_arn_suffix             = var.alb_arn_suffix
  eks_cluster_name           = module.compute.eks_cluster_name
  rds_instance_id            = module.database.rds_primary_identifier
  redis_replication_group_id = module.database.redis_replication_group_id
  alarm_email                = var.alarm_email

  # jihoo dashboard.tf 변수
  dashboard_check_results_table_arn    = module.data_pipeline.check_results_table_arn
  dashboard_check_results_table_name   = module.data_pipeline.check_results_table_name
  dashboard_report_metadata_table_arn  = module.data_pipeline.report_metadata_table_arn
  dashboard_report_metadata_table_name = module.data_pipeline.report_metadata_table_name
  data_lake_bucket_arn                 = module.data_pipeline.data_lake_bucket_arn
  data_lake_bucket_name                = module.data_pipeline.data_lake_bucket_id
  glue_data_lake_database_name         = module.data_pipeline.glue_database_name

  # 2-phase 변수 (1차="" → ai apply 후 2차에서 실제 값 주입)
  langgraph_lambda_arn           = var.langgraph_lambda_arn
  langgraph_lambda_function_name = var.langgraph_lambda_name

  # CloudFront 설정 (cdn 모듈 output)
  cloudfront_waf_arn = module.cdn.cloudfront_waf_arn
  acm_cert_arn       = module.cdn.acm_cert_arn
}

# ── data.fiveline.store Route53 A 레코드 (observability → cdn 역방향 의존성 방지용 루트 배치) ──

resource "aws_route53_record" "dashboard_data" {
  zone_id = module.cdn.hosted_zone_id
  name    = "data.fiveline.store"
  type    = "A"

  alias {
    name                   = module.observability.dashboard_cloudfront_domain_name
    zone_id                = module.observability.dashboard_cloudfront_hosted_zone_id
    evaluate_target_health = false
  }
}

# ── 10. CI/CD (lhj — ECR + GitHub Actions OIDC) ──────────────────────────────

module "cicd" {
  source = "./modules/cicd"

  github_org            = var.github_org
  github_repos          = var.github_repos
  kms_arn               = module.kms.secrets_manager_arn
  dashboard_bucket_name = module.observability.dashboard_bucket_name
}
