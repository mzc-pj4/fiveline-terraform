locals {
  project = var.project
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ════════════════════════════════════════════════════════════════════════════
# DynamoDB: AI 전용 테이블
# ════════════════════════════════════════════════════════════════════════════

# ── Report Embeddings (경량 RAG) ─────────────────────────────────────────────
# Bedrock Titan Embed v2 1024차원 벡터 + 마크다운 미리보기 저장
# LangGraph search_reports 도구가 Scan + 코사인 유사도로 Top-K 검색

resource "aws_dynamodb_table" "report_embeddings" {
  name         = "${local.project}-report-embeddings"
  billing_mode = "PAY_PER_REQUEST"

  hash_key = "reportId"

  attribute {
    name = "reportId"
    type = "S"
  }

  tags = {
    Service = "ai"
    Name    = "${local.project}-report-embeddings"
  }
}

# ── Conversation History (LangGraph Checkpointer Lite) ───────────────────────
# session_id 별로 이전 대화 메시지 저장 → 멀티턴 대화 가능
# TTL 30일 자동 만료 (오래된 세션 자동 정리)

resource "aws_dynamodb_table" "conversation_history" {
  name         = "${local.project}-conversation-history"
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
    Service = "ai"
    Name    = "${local.project}-conversation-history"
  }
}

# ════════════════════════════════════════════════════════════════════════════
# Bedrock Agent
# ════════════════════════════════════════════════════════════════════════════

# ── IAM Role ─────────────────────────────────────────────────────────────────

resource "aws_iam_role" "bedrock_agent" {
  name = "${local.project}-bedrock-agent"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Service = "ai"
    Name    = "${local.project}-bedrock-agent"
  }
}

resource "aws_iam_role_policy" "bedrock_agent" {
  name = "bedrock-agent-policy"
  role = aws_iam_role.bedrock_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "InvokeFoundationModel"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = "arn:aws:bedrock:*::foundation-model/anthropic.claude-3-*"
      },
      {
        Sid    = "MarketplaceSubscribe"
        Effect = "Allow"
        Action = [
          "aws-marketplace:ViewSubscriptions",
          "aws-marketplace:Subscribe",
        ]
        Resource = "*" # nosonar
      },
    ]
  })
}

# ── Bedrock Agent ─────────────────────────────────────────────────────────────

resource "aws_bedrockagent_agent" "ops_assistant" {
  agent_name              = "${local.project}-ops-assistant"
  agent_resource_role_arn = aws_iam_role.bedrock_agent.arn
  foundation_model        = "anthropic.claude-3-haiku-20240307-v1:0"

  instruction = <<-EOT
당신은 AWS 운영 자동화 플랫폼의 한국어 어시스턴트입니다. 운영자의 질문에 데이터를 기반으로 답합니다.

사용 가능한 도구:
- get_dashboard_summary: 특정 날짜의 일간 운영 요약 (총 주문 수, 성공/실패, 응답시간, 알람 수)
- get_resource_check: 미사용 리소스, 태그 누락, 보안 위반 점검 결과
- get_recent_alarms: 최근 발생한 CloudWatch 알람 이력
- query_athena: 자유 SQL 쿼리 (service_events 등 분석)

답변 규칙:
- 추측하지 말 것. 데이터에 없으면 "데이터 없음"이라고 명시
- 구체적 수치를 인용할 것
- 한국어로 친절하게 설명
- 필요 시 여러 도구를 차례로 사용
EOT

  idle_session_ttl_in_seconds = 600
}

# ── Action Group ──────────────────────────────────────────────────────────────

resource "aws_bedrockagent_agent_action_group" "ops_actions" {
  action_group_name          = "ops-data-actions"
  agent_id                   = aws_bedrockagent_agent.ops_assistant.agent_id
  agent_version              = "DRAFT"
  skip_resource_in_use_check = true

  action_group_executor {
    lambda = aws_lambda_function.bedrock_agent_action.arn
  }

  function_schema {
    member_functions {
      functions {
        name        = "get_dashboard_summary"
        description = "특정 날짜의 일간 운영 대시보드 요약 조회. 총 주문 수, 성공/실패율, 평균/p99 응답시간, 활성 알람 수 등 반환."
        parameters {
          map_block_key = "date"
          type          = "string"
          description   = "조회 날짜 YYYY-MM-DD 형식. 생략 시 오늘 날짜."
          required      = false
        }
      }

      functions {
        name        = "get_resource_check"
        description = "미사용 리소스(EBS·EIP·Snapshot), 태그 누락, 보안그룹 0.0.0.0/0 오픈, RDS Public Access 등 점검 결과 조회."
        parameters {
          map_block_key = "limit"
          type          = "string"
          description   = "조회 항목 수 (기본 20)"
          required      = false
        }
      }

      functions {
        name        = "get_recent_alarms"
        description = "최근 발생한 CloudWatch 알람 이력 조회 (모니터링 담당자 영역, 데이터 없을 수 있음)."
        parameters {
          map_block_key = "limit"
          type          = "string"
          description   = "조회 항목 수 (기본 10)"
          required      = false
        }
      }

      functions {
        name        = "query_athena"
        description = "Athena SQL 쿼리 실행. service_events(EKS 로그), cleansed, raw 테이블에서 SELECT 가능. DML 금지."
        parameters {
          map_block_key = "sql"
          type          = "string"
          description   = "실행할 SELECT SQL 쿼리"
          required      = true
        }
      }
    }
  }
}

# ── Lambda Permission: Bedrock Agent → Lambda ─────────────────────────────────

resource "aws_lambda_permission" "bedrock_agent_invoke" {
  statement_id  = "AllowBedrockAgentInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.bedrock_agent_action.function_name
  principal     = "bedrock.amazonaws.com"
  source_arn    = aws_bedrockagent_agent.ops_assistant.agent_arn
}

# ── Agent Alias (호출용 안정 별칭) ───────────────────────────────────────────

resource "aws_bedrockagent_agent_alias" "production" {
  agent_alias_name = "production"
  agent_id         = aws_bedrockagent_agent.ops_assistant.agent_id

  depends_on = [
    aws_bedrockagent_agent_action_group.ops_actions,
  ]
}

# ════════════════════════════════════════════════════════════════════════════
# Lambda: Report Generator
# ════════════════════════════════════════════════════════════════════════════

resource "aws_iam_role" "report_generator" {
  name = "${local.project}-report-generator"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Service = "ai"
    Name    = "${local.project}-report-generator"
  }
}

resource "aws_iam_role_policy_attachment" "report_generator_basic" {
  role       = aws_iam_role.report_generator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "report_generator_custom" {
  name = "report-generator-custom"
  role = aws_iam_role.report_generator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BedrockInvoke"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:Converse",
        ]
        Resource = "arn:aws:bedrock:*::foundation-model/anthropic.claude-3-*"
      },
      {
        Sid    = "MarketplaceSubscribe"
        Effect = "Allow"
        Action = [
          "aws-marketplace:ViewSubscriptions",
          "aws-marketplace:Subscribe",
          "aws-marketplace:Unsubscribe",
        ]
        Resource = "*" # nosonar
      },
      {
        Sid    = "DynamoDBRead"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:Query",
          "dynamodb:Scan",
        ]
        Resource = [
          var.dashboard_summary_table_arn,
          var.check_results_table_arn,
        ]
      },
      {
        Sid      = "DynamoDBWriteReport"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = var.report_metadata_table_arn
      },
      {
        Sid      = "S3WriteReports"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${var.data_lake_bucket_arn}/reports/*"
      },
    ]
  })
}

data "aws_s3_object" "report_generator_zip" {
  bucket = var.artifacts_bucket
  key    = "lambda/ai/report-generator.zip"
}

resource "aws_lambda_function" "report_generator" {
  function_name = "${local.project}-report-generator"
  role          = aws_iam_role.report_generator.arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 300
  memory_size   = 512

  s3_bucket        = var.artifacts_bucket
  s3_key           = "lambda/ai/report-generator.zip"
  source_code_hash = data.aws_s3_object.report_generator_zip.etag

  environment {
    variables = {
      BUCKET_NAME     = var.data_lake_bucket_name
      REPORT_TABLE    = var.report_metadata_table_name
      DASHBOARD_TABLE = var.dashboard_summary_table_name
      CHECK_TABLE     = var.check_results_table_name
      MODEL_ID        = "anthropic.claude-3-haiku-20240307-v1:0"
    }
  }

  tags = {
    Service = "ai"
    Name    = "${local.project}-report-generator"
  }
}

# ════════════════════════════════════════════════════════════════════════════
# Lambda: Bedrock Agent Action
# ════════════════════════════════════════════════════════════════════════════

resource "aws_iam_role" "bedrock_agent_action" {
  name = "${local.project}-bedrock-agent-action"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Service = "ai"
    Name    = "${local.project}-bedrock-agent-action"
  }
}

resource "aws_iam_role_policy_attachment" "bedrock_agent_action_basic" {
  role       = aws_iam_role.bedrock_agent_action.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "bedrock_agent_action_custom" {
  name = "bedrock-agent-action-custom"
  role = aws_iam_role.bedrock_agent_action.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DynamoDBRead"
        Effect = "Allow"
        Action = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan"]
        Resource = [
          var.dashboard_summary_table_arn,
          var.check_results_table_arn,
        ]
      },
      {
        Sid      = "DynamoDBReadMonitoring"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan"]
        Resource = var.alarm_history_table_arn != "" ? var.alarm_history_table_arn : "*"
      },
      {
        Sid    = "AthenaQuery"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
        ]
        Resource = "arn:aws:athena:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:workgroup/primary"
      },
      {
        Sid    = "GlueCatalogRead"
        Effect = "Allow"
        Action = ["glue:GetDatabase", "glue:GetTable", "glue:GetPartitions"]
        Resource = [
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:catalog",
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:database/${var.glue_database_name}",
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/${var.glue_database_name}/*",
        ]
      },
      {
        Sid    = "S3DataLake"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:PutObject",
        ]
        Resource = [
          var.data_lake_bucket_arn,
          "${var.data_lake_bucket_arn}/*",
        ]
      },
    ]
  })
}

data "aws_s3_object" "bedrock_agent_action_zip" {
  bucket = var.artifacts_bucket
  key    = "lambda/ai/bedrock-agent-action.zip"
}

resource "aws_lambda_function" "bedrock_agent_action" {
  function_name = "${local.project}-bedrock-agent-action"
  role          = aws_iam_role.bedrock_agent_action.arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 60
  memory_size   = 512

  s3_bucket        = var.artifacts_bucket
  s3_key           = "lambda/ai/bedrock-agent-action.zip"
  source_code_hash = data.aws_s3_object.bedrock_agent_action_zip.etag

  environment {
    variables = {
      DASHBOARD_TABLE = var.dashboard_summary_table_name
      CHECK_TABLE     = var.check_results_table_name
      ALARM_TABLE     = "alarm_history"
      ATHENA_DB       = var.glue_database_name
      ATHENA_OUTPUT   = "s3://${var.data_lake_bucket_name}/athena-results/"
    }
  }

  tags = {
    Service = "ai"
    Name    = "${local.project}-bedrock-agent-action"
  }
}

# ════════════════════════════════════════════════════════════════════════════
# Lambda: LangGraph Agent (Container Image)
# ════════════════════════════════════════════════════════════════════════════

resource "aws_iam_role" "langgraph_agent" {
  name = "${local.project}-langgraph-agent"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Service = "ai"
    Name    = "${local.project}-langgraph-agent"
  }
}

resource "aws_iam_role_policy_attachment" "langgraph_agent_basic" {
  role       = aws_iam_role.langgraph_agent.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "langgraph_agent_custom" {
  name = "langgraph-agent-custom"
  role = aws_iam_role.langgraph_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BedrockInvoke"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:Converse",
          "bedrock:ConverseStream",
        ]
        Resource = [
          "arn:aws:bedrock:*::foundation-model/anthropic.claude-3-*",
          "arn:aws:bedrock:*::foundation-model/amazon.titan-embed-*",
        ]
      },
      {
        Sid    = "MarketplaceSubscribe"
        Effect = "Allow"
        Action = [
          "aws-marketplace:ViewSubscriptions",
          "aws-marketplace:Subscribe",
        ]
        Resource = "*" # nosonar
      },
      {
        Sid    = "DynamoDBRead"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:Query",
          "dynamodb:Scan",
        ]
        Resource = [
          var.dashboard_summary_table_arn,
          var.check_results_table_arn,
          aws_dynamodb_table.report_embeddings.arn,
        ]
      },
      {
        Sid      = "DynamoDBConversationHistory"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem"]
        Resource = aws_dynamodb_table.conversation_history.arn
      },
      {
        Sid      = "DynamoDBReadMonitoring"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan"]
        Resource = var.alarm_history_table_arn != "" ? var.alarm_history_table_arn : "*"
      },
      {
        Sid    = "AthenaQuery"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:StopQueryExecution",
        ]
        Resource = "arn:aws:athena:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:workgroup/primary"
      },
      {
        Sid    = "GlueCatalogRead"
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetTable",
          "glue:GetPartition",
          "glue:GetPartitions",
        ]
        Resource = [
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:catalog",
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:database/${var.glue_database_name}",
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/${var.glue_database_name}/*",
        ]
      },
      {
        Sid    = "S3DataLake"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:PutObject",
        ]
        Resource = [
          var.data_lake_bucket_arn,
          "${var.data_lake_bucket_arn}/*",
        ]
      },
    ]
  })
}

resource "aws_lambda_function" "langgraph_agent" {
  function_name = "${local.project}-langgraph-agent"
  role          = aws_iam_role.langgraph_agent.arn
  package_type  = "Image"
  image_uri     = "089955620282.dkr.ecr.ap-northeast-2.amazonaws.com/fiveline-ecr/platform:langgraph-v2-rag"

  timeout     = 300
  memory_size = 1024

  environment {
    variables = {
      DASHBOARD_TABLE        = var.dashboard_summary_table_name
      CHECK_TABLE            = var.check_results_table_name
      ALARM_TABLE            = "alarm_history"
      ATHENA_DB              = var.glue_database_name
      ATHENA_OUTPUT          = "s3://${var.data_lake_bucket_name}/athena-results/"
      EMBED_TABLE            = aws_dynamodb_table.report_embeddings.name
      EMBED_MODEL            = "amazon.titan-embed-text-v2:0"
      CONVERSATION_TABLE     = aws_dynamodb_table.conversation_history.name
      CONVERSATION_TTL_DAYS  = "30"
      MAX_HISTORY_MESSAGES   = "20"
    }
  }

  tags = {
    Service = "ai"
    Name    = "${local.project}-langgraph-agent"
  }
}

# ════════════════════════════════════════════════════════════════════════════
# Lambda: Report Embedder
# ════════════════════════════════════════════════════════════════════════════

resource "aws_iam_role" "report_embedder" {
  name = "${local.project}-report-embedder"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Service = "ai"
    Name    = "${local.project}-report-embedder"
  }
}

resource "aws_iam_role_policy_attachment" "report_embedder_basic" {
  role       = aws_iam_role.report_embedder.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "report_embedder_custom" {
  name = "report-embedder-custom"
  role = aws_iam_role.report_embedder.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BedrockEmbed"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel"]
        Resource = [
          "arn:aws:bedrock:*::foundation-model/amazon.titan-embed-text-v2:0",
          "arn:aws:bedrock:*::foundation-model/amazon.titan-embed-*",
        ]
      },
      {
        Sid    = "S3ReadReports"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket",
        ]
        Resource = [
          var.data_lake_bucket_arn,
          "${var.data_lake_bucket_arn}/*",
        ]
      },
      {
        Sid    = "DDBEmbeddings"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:Scan",
          "dynamodb:Query",
        ]
        Resource = aws_dynamodb_table.report_embeddings.arn
      },
    ]
  })
}

data "aws_s3_object" "report_embedder_zip" {
  bucket = var.artifacts_bucket
  key    = "lambda/ai/report-embedder.zip"
}

resource "aws_lambda_function" "report_embedder" {
  function_name = "${local.project}-report-embedder"
  role          = aws_iam_role.report_embedder.arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 300
  memory_size   = 512

  s3_bucket        = var.artifacts_bucket
  s3_key           = "lambda/ai/report-embedder.zip"
  source_code_hash = data.aws_s3_object.report_embedder_zip.etag

  environment {
    variables = {
      BUCKET_NAME    = var.data_lake_bucket_name
      REPORTS_PREFIX = "reports/daily/"
      EMBED_TABLE    = aws_dynamodb_table.report_embeddings.name
      EMBED_MODEL    = "amazon.titan-embed-text-v2:0"
      MAX_CHARS      = "8000"
    }
  }

  tags = {
    Service = "ai"
    Name    = "${local.project}-report-embedder"
  }
}

# ── EventBridge: 매일 16:00 KST (07:00 UTC) — Report Generator(15:00 KST) 1시간 후 ─

resource "aws_cloudwatch_event_rule" "report_embedder_daily" {
  name                = "${local.project}-report-embedder-daily"
  description         = "매일 16:00 KST: 신규 리포트를 Bedrock Titan Embed로 벡터화"
  schedule_expression = "cron(0 7 * * ? *)"

  tags = {
    Service = "ai"
    Name    = "${local.project}-report-embedder-daily"
  }
}

resource "aws_cloudwatch_event_target" "report_embedder_daily" {
  rule      = aws_cloudwatch_event_rule.report_embedder_daily.name
  target_id = "report-embedder"
  arn       = aws_lambda_function.report_embedder.arn
}

resource "aws_lambda_permission" "allow_eventbridge_report_embedder" {
  statement_id  = "AllowEventBridgeReportEmbedder"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.report_embedder.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.report_embedder_daily.arn
}
