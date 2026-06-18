# ──────────────────────────────────────────────
# hsh/outputs.tf 에서 온 outputs
# ──────────────────────────────────────────────

output "alarm_handler_lambda_arn" {
  description = "Alarm Handler Lambda ARN"
  value       = aws_lambda_function.alarm_handler.arn
}

output "alarm_history_table_name" {
  description = "alarm_history DynamoDB 테이블명"
  value       = aws_dynamodb_table.alarm_history.name
}

output "alarm_history_table_arn" {
  description = "alarm_history DynamoDB 테이블 ARN"
  value       = aws_dynamodb_table.alarm_history.arn
}

output "dashboard_summary_table_name" {
  description = "dashboard_summary DynamoDB 테이블명"
  value       = aws_dynamodb_table.dashboard_summary.name
}

output "dashboard_summary_table_arn" {
  description = "dashboard_summary DynamoDB 테이블 ARN"
  value       = aws_dynamodb_table.dashboard_summary.arn
}

output "alarm_topic_arn" {
  description = "SNS alarm topic ARN"
  value       = aws_sns_topic.alarm.arn
}

# ──────────────────────────────────────────────
# jihoo/dashboard.tf 에서 온 outputs
# ──────────────────────────────────────────────

output "dashboard_url" {
  value       = "http://${aws_s3_bucket_website_configuration.dashboard.website_endpoint}"
  description = "대시보드 웹 URL (브라우저에서 열기)"
}

output "dashboard_api_url" {
  value       = "${aws_apigatewayv2_api.dashboard_api.api_endpoint}/"
  description = "Dashboard API Gateway URL (dashboard-builder가 CHAT_API_BASE로 사용)"
}

output "dashboard_data_url" {
  value       = "http://${aws_s3_bucket_website_configuration.dashboard.website_endpoint}/data.json"
  description = "S3에 적재되는 데이터 JSON URL"
}

output "dashboard_bucket_name" {
  description = "대시보드 S3 버킷명"
  value       = aws_s3_bucket.dashboard.bucket
}

output "dashboard_builder_lambda_arn" {
  description = "[2-phase] data-pipeline 오케스트레이터에 주입할 dashboard_builder Lambda ARN"
  value       = aws_lambda_function.dashboard_builder.arn
}

output "dashboard_builder_lambda_name" {
  description = "[2-phase] data-pipeline 오케스트레이터에 주입할 dashboard_builder Lambda 함수명"
  value       = aws_lambda_function.dashboard_builder.function_name
}
