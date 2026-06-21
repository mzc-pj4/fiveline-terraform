
output "aiops_canary_logs_table_name" {
  value = aws_dynamodb_table.aiops_canary_logs.name
}

output "aiops_canary_logs_table_arn" {
  value = aws_dynamodb_table.aiops_canary_logs.arn
}
