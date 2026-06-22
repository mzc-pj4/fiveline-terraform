# ── DynamoDB: Resource Check Results ────────────────────────────────────────

resource "aws_dynamodb_table" "check_results" {
  name         = "mzc-pj4-${local.owner}-check-results-${local.env}"
  billing_mode = "PAY_PER_REQUEST"

  hash_key  = "resourceId"
  range_key = "checkedAt"

  attribute {
    name = "resourceId"
    type = "S"
  }

  attribute {
    name = "checkedAt"
    type = "S"
  }

  tags = {
    Service = "data-lake"
    Name    = "mzc-pj4-${local.owner}-check-results-${local.env}"
  }
}

# ── DynamoDB: Dashboard Summary ──────────────────────────────────────────────
# 일1회 적재 — 하루 한 줄 요약 (대시보드 상단 표시용)

resource "aws_dynamodb_table" "dashboard_summary" {
  name         = "mzc-pj4-${local.owner}-dashboard-summary-${local.env}"
  billing_mode = "PAY_PER_REQUEST"

  hash_key = "summaryDate"

  attribute {
    name = "summaryDate"
    type = "S"
  }

  tags = {
    Service = "data-lake"
    Name    = "mzc-pj4-${local.owner}-dashboard-summary-${local.env}"
  }
}

# ── DynamoDB: Hourly Order Summary ───────────────────────────────────────────
# 시간대별 주문 요약 (실패율/전환율/응답시간)

resource "aws_dynamodb_table" "hourly_order_summary" {
  name         = "mzc-pj4-${local.owner}-hourly-order-summary-${local.env}"
  billing_mode = "PAY_PER_REQUEST"

  hash_key  = "summaryDate"
  range_key = "hourBucket"

  attribute {
    name = "summaryDate"
    type = "S"
  }

  attribute {
    name = "hourBucket"
    type = "S"
  }

  tags = {
    Service = "data-lake"
    Name    = "mzc-pj4-${local.owner}-hourly-order-summary-${local.env}"
  }
}

# ── DynamoDB: Infra Health Summary ───────────────────────────────────────────
# 시간대별 인프라 헬스 (EKS CPU/Mem, RDS Connection, ALB 5xx 등)

resource "aws_dynamodb_table" "infra_health_summary" {
  name         = "mzc-pj4-${local.owner}-infra-health-summary-${local.env}"
  billing_mode = "PAY_PER_REQUEST"

  hash_key  = "summaryDate"
  range_key = "hourBucket"

  attribute {
    name = "summaryDate"
    type = "S"
  }

  attribute {
    name = "hourBucket"
    type = "S"
  }

  tags = {
    Service = "data-lake"
    Name    = "mzc-pj4-${local.owner}-infra-health-summary-${local.env}"
  }
}

# ── DynamoDB: Report Metadata ────────────────────────────────────────────────
# Report Generator Lambda가 만든 리포트들의 메타데이터 (S3 경로, 타입 등)

resource "aws_dynamodb_table" "report_metadata" {
  name         = "mzc-pj4-${local.owner}-report-metadata-${local.env}"
  billing_mode = "PAY_PER_REQUEST"

  hash_key  = "reportType"
  range_key = "createdAt"

  attribute {
    name = "reportType"
    type = "S"
  }

  attribute {
    name = "createdAt"
    type = "S"
  }

  tags = {
    Service = "data-lake"
    Name    = "mzc-pj4-${local.owner}-report-metadata-${local.env}"
  }
}

# ── DynamoDB: Report Embeddings (경량 RAG) ───────────────────────────────────
# Bedrock Titan Embed v2 1024차원 벡터 + 마크다운 미리보기 저장
# LangGraph search_reports 도구가 Scan + 코사인 유사도로 Top-K 검색

resource "aws_dynamodb_table" "report_embeddings" {
  name         = "mzc-pj4-${local.owner}-report-embeddings-${local.env}"
  billing_mode = "PAY_PER_REQUEST"

  hash_key = "reportId"

  attribute {
    name = "reportId"
    type = "S"
  }

  tags = {
    Service = "data-lake"
    Name    = "mzc-pj4-${local.owner}-report-embeddings-${local.env}"
  }
}

# ── DynamoDB: Conversation History (LangGraph Checkpointer Lite) ──────────────
# session_id 별로 이전 대화 메시지 저장 → 멀티턴 대화 가능
# TTL 30일 자동 만료 (오래된 세션 자동 정리)

resource "aws_dynamodb_table" "conversation_history" {
  name         = "mzc-pj4-${local.owner}-conversation-history-${local.env}"
  billing_mode = "PAY_PER_REQUEST"

  hash_key = "session_id"

  attribute {
    name = "session_id"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  tags = {
    Service = "data-lake"
    Name    = "mzc-pj4-${local.owner}-conversation-history-${local.env}"
  }
}
