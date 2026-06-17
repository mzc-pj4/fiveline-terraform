output "resource_check_results_table_name" {
  value = aws_dynamodb_table.resource_check_results.name
}

output "resource_check_results_table_arn" {
  value = aws_dynamodb_table.resource_check_results.arn
}

output "aiops_canary_logs_table_name" {
  value = aws_dynamodb_table.aiops_canary_logs.name
}

output "aiops_canary_logs_table_arn" {
  value = aws_dynamodb_table.aiops_canary_logs.arn
}

output "cost_estimation_summary_table_name" {
  value = aws_dynamodb_table.cost_estimation_summary.name
}

output "cost_estimation_summary_table_arn" {
  value = aws_dynamodb_table.cost_estimation_summary.arn
}
