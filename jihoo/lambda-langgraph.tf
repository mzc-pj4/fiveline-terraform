# ── LangGraph Agent Lambda IAM ───────────────────────────────────────────────

resource "aws_iam_role" "langgraph_agent" {
  name = "mzc-pj4-${local.owner}-langgraph-agent-${local.env}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Service = "data-lake"
    Name    = "mzc-pj4-${local.owner}-langgraph-agent-${local.env}"
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
        Resource = "*"
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
          aws_dynamodb_table.dashboard_summary.arn,
          aws_dynamodb_table.check_results.arn,
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
        Resource = "arn:aws:dynamodb:ap-northeast-2:${data.aws_caller_identity.current.account_id}:table/alarm_history"
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
        Resource = "*"
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
        Resource = "*"
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
          aws_s3_bucket.data_lake.arn,
          "${aws_s3_bucket.data_lake.arn}/*",
        ]
      },
    ]
  })
}

# ── LangGraph Agent Lambda Function (Container Image) ────────────────────────

resource "aws_lambda_function" "langgraph_agent" {
  function_name = "mzc-pj4-${local.owner}-langgraph-agent-${local.env}"
  role          = aws_iam_role.langgraph_agent.arn
  package_type  = "Image"
  image_uri     = "089955620282.dkr.ecr.ap-northeast-2.amazonaws.com/fiveline-ecr/platform:langgraph-v2-rag"

  timeout     = 300
  memory_size = 1024

  environment {
    variables = {
      DASHBOARD_TABLE = aws_dynamodb_table.dashboard_summary.name
      CHECK_TABLE     = aws_dynamodb_table.check_results.name
      ALARM_TABLE     = "alarm_history"
      ATHENA_DB       = aws_glue_catalog_database.data_lake.name
      ATHENA_OUTPUT   = "s3://${aws_s3_bucket.data_lake.bucket}/athena-results/"
      EMBED_TABLE     = aws_dynamodb_table.report_embeddings.name
      EMBED_MODEL     = "amazon.titan-embed-text-v2:0"
      CONVERSATION_TABLE     = aws_dynamodb_table.conversation_history.name
      CONVERSATION_TTL_DAYS  = "30"
      MAX_HISTORY_MESSAGES   = "20"
    }
  }

  tags = {
    Service = "data-lake"
    Name    = "mzc-pj4-${local.owner}-langgraph-agent-${local.env}"
  }
}

output "langgraph_agent_function_name" {
  value       = aws_lambda_function.langgraph_agent.function_name
  description = "LangGraph Agent Lambda 함수 이름 (테스트 invoke용)"
}
