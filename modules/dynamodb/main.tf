
resource "aws_dynamodb_table" "aiops_canary_logs" {
  name         = "${var.project_name}-${var.environment}-aiops-canary-logs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "service_name"
  range_key    = "deployed_at"

  attribute {
    name = "service_name"
    type = "S"
  }

  attribute {
    name = "deployed_at"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = {
    Name    = "${var.project_name}-${var.environment}-aiops-canary-logs"
    Service = "aiops"
  }
}
