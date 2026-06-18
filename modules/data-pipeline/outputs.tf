# ── S3 ───────────────────────────────────────────────────────────────────────

output "data_lake_bucket_id" {
  description = "Data Lake S3 버킷 이름"
  value       = aws_s3_bucket.data_lake.id
}

output "data_lake_bucket_arn" {
  description = "Data Lake S3 버킷 ARN"
  value       = aws_s3_bucket.data_lake.arn
}

# ── DynamoDB ──────────────────────────────────────────────────────────────────

output "check_results_table_name" {
  description = "check_results DynamoDB 테이블 이름"
  value       = aws_dynamodb_table.check_results.name
}

output "check_results_table_arn" {
  description = "check_results DynamoDB 테이블 ARN (AI 모듈 IAM 정책용)"
  value       = aws_dynamodb_table.check_results.arn
}

output "dashboard_summary_table_name" {
  description = "dashboard_summary DynamoDB 테이블 이름"
  value       = aws_dynamodb_table.dashboard_summary.name
}

output "dashboard_summary_table_arn" {
  description = "dashboard_summary DynamoDB 테이블 ARN (AI 모듈 IAM 정책용)"
  value       = aws_dynamodb_table.dashboard_summary.arn
}

output "report_metadata_table_name" {
  description = "report_metadata DynamoDB 테이블 이름"
  value       = aws_dynamodb_table.report_metadata.name
}

output "report_metadata_table_arn" {
  description = "report_metadata DynamoDB 테이블 ARN"
  value       = aws_dynamodb_table.report_metadata.arn
}

output "hourly_order_summary_table_name" {
  description = "hourly_order_summary DynamoDB 테이블 이름"
  value       = aws_dynamodb_table.hourly_order_summary.name
}

output "infra_health_summary_table_name" {
  description = "infra_health_summary DynamoDB 테이블 이름"
  value       = aws_dynamodb_table.infra_health_summary.name
}

# ── Glue ──────────────────────────────────────────────────────────────────────

output "glue_database_name" {
  description = "Glue Catalog 데이터베이스 이름 (Athena 쿼리용)"
  value       = aws_glue_catalog_database.data_lake.name
}

# ── Athena ────────────────────────────────────────────────────────────────────

output "athena_workgroup_analytics" {
  description = "Analytics Athena 워크그룹 이름"
  value       = aws_athena_workgroup.analytics.name
}

output "athena_workgroup_ai_reports" {
  description = "AI Reports Athena 워크그룹 이름"
  value       = aws_athena_workgroup.ai_reports.name
}

# ── Lambda ────────────────────────────────────────────────────────────────────

output "pipeline_orchestrator_function_name" {
  description = "Pipeline Orchestrator Lambda 이름 (수동 호출: aws lambda invoke --function-name <value>)"
  value       = aws_lambda_function.pipeline_orchestrator.function_name
}

output "summary_writer_function_name" {
  description = "Summary Writer Lambda 이름"
  value       = aws_lambda_function.summary_writer.function_name
}

output "summary_writer_function_arn" {
  description = "Summary Writer Lambda ARN"
  value       = aws_lambda_function.summary_writer.arn
}

output "resource_checker_function_name" {
  description = "Resource Checker Lambda 이름"
  value       = aws_lambda_function.resource_checker.function_name
}

output "metrics_collector_function_name" {
  description = "Metrics Collector Lambda 이름"
  value       = aws_lambda_function.metrics_collector.function_name
}

# ── Firehose ──────────────────────────────────────────────────────────────────

output "firehose_service_events_arn" {
  description = "Service Events Firehose 스트림 ARN"
  value       = aws_kinesis_firehose_delivery_stream.service_events.arn
}

output "firehose_cw_metrics_arn" {
  description = "CW Metrics Firehose 스트림 ARN"
  value       = aws_kinesis_firehose_delivery_stream.cw_metrics.arn
}

# ── CloudWatch Log Groups ─────────────────────────────────────────────────────

output "log_group_service_events_name" {
  description = "service-events CloudWatch Log Group 이름 (Fluent Bit 설정용)"
  value       = aws_cloudwatch_log_group.eks_logs["service_events"].name
}
