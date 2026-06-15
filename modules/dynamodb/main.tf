resource "aws_dynamodb_table" "resource_check_results" {
  name         = "${var.project_name}-${var.environment}-resource-check-results"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "resource_id"
  range_key    = "checked_at"

  attribute {
    name = "resource_id"
    type = "S"
  }

  attribute {
    name = "checked_at"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = {
    Name    = "${var.project_name}-${var.environment}-resource-check-results"
    Service = "finops"
  }
}

resource "aws_dynamodb_table" "cost_estimation_summary" {
  name         = "${var.project_name}-${var.environment}-cost-estimation-summary"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "service_name"
  range_key    = "estimated_at"

  attribute {
    name = "service_name"
    type = "S"
  }

  attribute {
    name = "estimated_at"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = {
    Name    = "${var.project_name}-${var.environment}-cost-estimation-summary"
    Service = "finops"
  }
}
