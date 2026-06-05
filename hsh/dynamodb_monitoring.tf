# ──────────────────────────────────────────────
# alarm_history — 알람 원시 이력 (90일 TTL)
# ──────────────────────────────────────────────
resource "aws_dynamodb_table" "alarm_history" {
  name         = "alarm_history"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "alarmId"

  attribute {
    name = "alarmId"
    type = "S"
  }

  # ttl 필드(Unix timestamp)가 90일 지나면 자동 삭제
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = {
    Name    = "fiveline-prod-alarm-history"
    Service = "monitoring"
  }
}

# ──────────────────────────────────────────────
# dashboard_summary — 서비스별 알람 집계
# ──────────────────────────────────────────────
resource "aws_dynamodb_table" "dashboard_summary" {
  name         = "dashboard_summary"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "service"
  range_key    = "date"

  attribute {
    name = "service"
    type = "S"
  }

  attribute {
    name = "date"
    type = "S"
  }

  tags = {
    Name    = "fiveline-prod-dashboard-summary"
    Service = "monitoring"
  }
}
