output "alarm_handler_lambda_arn" {
  description = "Alarm Handler Lambda ARN — sns.tf 구독 endpoint에서 참조"
  value       = aws_lambda_function.alarm_handler.arn
}

output "alarm_history_table_name" {
  description = "alarm_history DynamoDB 테이블명"
  value       = aws_dynamodb_table.alarm_history.name
}

output "dashboard_summary_table_name" {
  description = "dashboard_summary DynamoDB 테이블명"
  value       = aws_dynamodb_table.dashboard_summary.name
}
