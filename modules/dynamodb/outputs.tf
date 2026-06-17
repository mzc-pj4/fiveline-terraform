output "resource_check_results_table_name" {
  value = aws_dynamodb_table.resource_check_results.name
}

output "resource_check_results_table_arn" {
  value = aws_dynamodb_table.resource_check_results.arn
}

output "cost_estimation_summary_table_name" {
  value = aws_dynamodb_table.cost_estimation_summary.name
}

output "cost_estimation_summary_table_arn" {
  value = aws_dynamodb_table.cost_estimation_summary.arn
}
