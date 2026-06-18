# ── Bedrock Agent ─────────────────────────────────────────────────────────────

output "bedrock_agent_id" {
  value       = aws_bedrockagent_agent.ops_assistant.agent_id
  description = "Bedrock Agent ID (테스트용)"
}

output "bedrock_agent_alias_id" {
  value       = aws_bedrockagent_agent_alias.production.agent_alias_id
  description = "Agent Alias ID (호출 시 사용)"
}

output "bedrock_agent_arn" {
  value       = aws_bedrockagent_agent.ops_assistant.agent_arn
  description = "Bedrock Agent ARN"
}

# ── Lambda Functions ──────────────────────────────────────────────────────────

output "report_generator_function_name" {
  value       = aws_lambda_function.report_generator.function_name
  description = "Report Generator Lambda 함수 이름"
}

output "report_generator_function_arn" {
  value       = aws_lambda_function.report_generator.arn
  description = "Report Generator Lambda 함수 ARN"
}

output "bedrock_agent_action_function_name" {
  value       = aws_lambda_function.bedrock_agent_action.function_name
  description = "Bedrock Agent Action Lambda 함수 이름"
}

output "bedrock_agent_action_function_arn" {
  value       = aws_lambda_function.bedrock_agent_action.arn
  description = "Bedrock Agent Action Lambda 함수 ARN"
}

output "langgraph_agent_function_name" {
  value       = aws_lambda_function.langgraph_agent.function_name
  description = "LangGraph Agent Lambda 함수 이름 (테스트 invoke용)"
}

output "langgraph_agent_function_arn" {
  value       = aws_lambda_function.langgraph_agent.arn
  description = "LangGraph Agent Lambda 함수 ARN"
}

output "report_embedder_function_name" {
  value       = aws_lambda_function.report_embedder.function_name
  description = "Report Embedder Lambda 함수 이름 (백필 invoke용)"
}

output "report_embedder_function_arn" {
  value       = aws_lambda_function.report_embedder.arn
  description = "Report Embedder Lambda 함수 ARN"
}

# ── DynamoDB Tables ───────────────────────────────────────────────────────────

output "report_embeddings_table_name" {
  value       = aws_dynamodb_table.report_embeddings.name
  description = "Report Embeddings DynamoDB 테이블 이름"
}

output "report_embeddings_table_arn" {
  value       = aws_dynamodb_table.report_embeddings.arn
  description = "Report Embeddings DynamoDB 테이블 ARN"
}

output "conversation_history_table_name" {
  value       = aws_dynamodb_table.conversation_history.name
  description = "Conversation History DynamoDB 테이블 이름"
}

output "conversation_history_table_arn" {
  value       = aws_dynamodb_table.conversation_history.arn
  description = "Conversation History DynamoDB 테이블 ARN"
}
