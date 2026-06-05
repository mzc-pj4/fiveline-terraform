output "nth_sqs_queue_url" {
  description = "NTH SQS Queue URL — Helm values: queueURL"
  value       = aws_sqs_queue.nth.url
}

output "nth_sqs_queue_arn" {
  description = "NTH SQS Queue ARN — iam_monitoring.tf NTH IRSA Policy에서 참조"
  value       = aws_sqs_queue.nth.arn
}

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
