# ── Dashboard S3 Static Hosting Bucket ──────────────────────────────────────

resource "aws_s3_bucket" "dashboard" {
  bucket = "mzc-pj4-${local.owner}-dashboard-${local.env}"

  tags = {
    Service = "dashboard"
    Name    = "mzc-pj4-${local.owner}-dashboard-${local.env}"
  }
}

resource "aws_s3_bucket_public_access_block" "dashboard" {
  bucket                  = aws_s3_bucket.dashboard.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_website_configuration" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "index.html"
  }
}

resource "aws_s3_bucket_policy" "dashboard" {
  bucket     = aws_s3_bucket.dashboard.id
  depends_on = [aws_s3_bucket_public_access_block.dashboard]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicRead"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.dashboard.arn}/*"
    }]
  })
}

# 파일 자동 업로드 (변경 시 etag로 자동 감지)
resource "aws_s3_object" "dashboard_html" {
  bucket       = aws_s3_bucket.dashboard.id
  key          = "index.html"
  source       = "${path.module}/dashboard-web/index.html"
  content_type = "text/html; charset=utf-8"
  etag         = filemd5("${path.module}/dashboard-web/index.html")
}

resource "aws_s3_object" "dashboard_js" {
  bucket       = aws_s3_bucket.dashboard.id
  key          = "app.js"
  source       = "${path.module}/dashboard-web/app.js"
  content_type = "application/javascript; charset=utf-8"
  etag         = filemd5("${path.module}/dashboard-web/app.js")
}

# ── Dashboard API Lambda IAM ────────────────────────────────────────────────

resource "aws_iam_role" "dashboard_api" {
  name = "mzc-pj4-${local.owner}-dashboard-api-${local.env}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Service = "dashboard"
    Name    = "mzc-pj4-${local.owner}-dashboard-api-${local.env}"
  }
}

resource "aws_iam_role_policy_attachment" "dashboard_api_basic" {
  role       = aws_iam_role.dashboard_api.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "dashboard_api_custom" {
  name = "dashboard-api-custom"
  role = aws_iam_role.dashboard_api.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DynamoDBRead"
        Effect = "Allow"
        Action = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan"]
        Resource = [
          aws_dynamodb_table.dashboard_summary.arn,
          aws_dynamodb_table.check_results.arn,
        ]
      },
      {
        Sid    = "AthenaQuery"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
        ]
        Resource = "*"
      },
      {
        Sid      = "GlueCatalogRead"
        Effect   = "Allow"
        Action   = ["glue:GetDatabase", "glue:GetTable", "glue:GetPartitions"]
        Resource = "*"
      },
      {
        Sid    = "S3AthenaResults"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation", "s3:PutObject"]
        Resource = [
          aws_s3_bucket.data_lake.arn,
          "${aws_s3_bucket.data_lake.arn}/*",
        ]
      },
      {
        Sid      = "InvokeLangGraph"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = aws_lambda_function.langgraph_agent.arn
      },
    ]
  })
}

# ── Dashboard API Lambda Function (Zip) ──────────────────────────────────────

data "archive_file" "dashboard_api" {
  type        = "zip"
  source_dir  = "${path.module}/lambda-src/dashboard-api"
  output_path = "${path.module}/lambda-src/dashboard-api.zip"
}

resource "aws_lambda_function" "dashboard_api" {
  function_name = "mzc-pj4-${local.owner}-dashboard-api-${local.env}"
  role          = aws_iam_role.dashboard_api.arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 60
  memory_size   = 512

  filename         = data.archive_file.dashboard_api.output_path
  source_code_hash = data.archive_file.dashboard_api.output_base64sha256

  environment {
    variables = {
      DASHBOARD_TABLE  = aws_dynamodb_table.dashboard_summary.name
      CHECK_TABLE      = aws_dynamodb_table.check_results.name
      ATHENA_DB        = aws_glue_catalog_database.data_lake.name
      ATHENA_OUTPUT    = "s3://${aws_s3_bucket.data_lake.bucket}/athena-results/"
      LANGGRAPH_LAMBDA = aws_lambda_function.langgraph_agent.function_name
    }
  }

  tags = {
    Service = "dashboard"
    Name    = "mzc-pj4-${local.owner}-dashboard-api-${local.env}"
  }
}

# ── API Gateway HTTP API (SCP 우회 — Function URL 대신 API Gateway 사용) ─────
# MZC SCP가 Lambda Function URL 공개 호출을 차단해서 API Gateway HTTP API로 우회.
# CloudFront + OAC는 POST body 서명 이슈로 실패 → API Gateway가 가장 안정적인 패턴.

resource "aws_apigatewayv2_api" "dashboard_api" {
  name          = "mzc-pj4-${local.owner}-dashboard-api-${local.env}"
  protocol_type = "HTTP"
  description   = "Dashboard API HTTP endpoint (SCP-friendly, proxies to dashboard-api Lambda)"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["content-type"]
    max_age       = 86400
  }

  tags = {
    Service = "dashboard"
    Name    = "mzc-pj4-${local.owner}-dashboard-api-${local.env}"
  }
}

# Lambda 통합 (AWS_PROXY)
resource "aws_apigatewayv2_integration" "dashboard_api_lambda" {
  api_id                 = aws_apigatewayv2_api.dashboard_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.dashboard_api.invoke_arn
  payload_format_version = "2.0"
  integration_method     = "POST"
}

# 모든 경로/메서드 catch-all
resource "aws_apigatewayv2_route" "dashboard_api_default" {
  api_id    = aws_apigatewayv2_api.dashboard_api.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.dashboard_api_lambda.id}"
}

# Default stage (자동 배포)
resource "aws_apigatewayv2_stage" "dashboard_api_default" {
  api_id      = aws_apigatewayv2_api.dashboard_api.id
  name        = "$default"
  auto_deploy = true

  tags = {
    Service = "dashboard"
    Name    = "mzc-pj4-${local.owner}-dashboard-api-stage-${local.env}"
  }
}

# API Gateway → Lambda 호출 권한
resource "aws_lambda_permission" "dashboard_api_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dashboard_api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.dashboard_api.execution_arn}/*/*"
}

# ── 출력 ────────────────────────────────────────────────────────────────────

output "dashboard_url" {
  value       = "http://${aws_s3_bucket_website_configuration.dashboard.website_endpoint}"
  description = "대시보드 웹 URL (브라우저에서 열기)"
}

output "dashboard_api_url" {
  value       = "${aws_apigatewayv2_api.dashboard_api.api_endpoint}/"
  description = "Dashboard API Gateway URL (dashboard-builder가 CHAT_API_BASE로 사용)"
}

# ── Dashboard Builder Lambda (Static JSON 생성, EventBridge가 trigger) ───────

resource "aws_iam_role" "dashboard_builder" {
  name = "mzc-pj4-${local.owner}-dashboard-builder-${local.env}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Service = "dashboard"
    Name    = "mzc-pj4-${local.owner}-dashboard-builder-${local.env}"
  }
}

resource "aws_iam_role_policy_attachment" "dashboard_builder_basic" {
  role       = aws_iam_role.dashboard_builder.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "dashboard_builder_custom" {
  name = "dashboard-builder-custom"
  role = aws_iam_role.dashboard_builder.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DynamoDBRead"
        Effect = "Allow"
        Action = ["dynamodb:GetItem", "dynamodb:Scan"]
        Resource = [
          aws_dynamodb_table.dashboard_summary.arn,
          aws_dynamodb_table.check_results.arn,
          aws_dynamodb_table.report_metadata.arn,
        ]
      },
      {
        Sid      = "DynamoDBReadMonitoring"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan"]
        Resource = "arn:aws:dynamodb:ap-northeast-2:${data.aws_caller_identity.current.account_id}:table/dashboard_summary"
      },
      {
        Sid      = "AthenaQuery"
        Effect   = "Allow"
        Action   = ["athena:StartQueryExecution", "athena:GetQueryExecution", "athena:GetQueryResults"]
        Resource = "*"
      },
      {
        Sid      = "GlueCatalogRead"
        Effect   = "Allow"
        Action   = ["glue:GetDatabase", "glue:GetTable", "glue:GetPartitions"]
        Resource = "*"
      },
      {
        Sid    = "S3DataLakeRead"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation", "s3:PutObject"]
        Resource = [
          aws_s3_bucket.data_lake.arn,
          "${aws_s3_bucket.data_lake.arn}/*",
        ]
      },
      {
        Sid      = "S3DashboardWrite"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.dashboard.arn}/*"
      },
    ]
  })
}

data "archive_file" "dashboard_builder" {
  type        = "zip"
  source_dir  = "${path.module}/lambda-src/dashboard-builder"
  output_path = "${path.module}/lambda-src/dashboard-builder.zip"
}

resource "aws_lambda_function" "dashboard_builder" {
  function_name = "mzc-pj4-${local.owner}-dashboard-builder-${local.env}"
  role          = aws_iam_role.dashboard_builder.arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 120
  memory_size   = 512

  filename         = data.archive_file.dashboard_builder.output_path
  source_code_hash = data.archive_file.dashboard_builder.output_base64sha256

  environment {
    variables = {
      DASHBOARD_TABLE            = aws_dynamodb_table.dashboard_summary.name
      CHECK_TABLE                = aws_dynamodb_table.check_results.name
      REPORT_TABLE               = aws_dynamodb_table.report_metadata.name
      MONITORING_DASHBOARD_TABLE = "dashboard_summary"
      MONITORING_SERVICE_KEY     = "ecommerce"
      ATHENA_DB                  = aws_glue_catalog_database.data_lake.name
      ATHENA_OUTPUT              = "s3://${aws_s3_bucket.data_lake.bucket}/athena-results/"
      BUCKET_NAME                = aws_s3_bucket.dashboard.bucket
      JSON_KEY                   = "data.json"
      CHAT_API_BASE              = "${aws_apigatewayv2_api.dashboard_api.api_endpoint}/"
    }
  }

  tags = {
    Service = "dashboard"
    Name    = "mzc-pj4-${local.owner}-dashboard-builder-${local.env}"
  }
}

# EventBridge 룰 — 5분마다 dashboard-builder 호출
resource "aws_cloudwatch_event_rule" "dashboard_builder_schedule" {
  name                = "mzc-pj4-${local.owner}-dashboard-builder-schedule-${local.env}"
  description         = "30분마다 대시보드 data.json 갱신"
  schedule_expression = "rate(30 minutes)"
  state               = "ENABLED"

  tags = {
    Service = "dashboard"
    Name    = "mzc-pj4-${local.owner}-dashboard-builder-schedule-${local.env}"
  }
}

resource "aws_cloudwatch_event_target" "dashboard_builder_target" {
  rule      = aws_cloudwatch_event_rule.dashboard_builder_schedule.name
  target_id = "lambda"
  arn       = aws_lambda_function.dashboard_builder.arn
}

resource "aws_lambda_permission" "dashboard_builder_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dashboard_builder.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.dashboard_builder_schedule.arn
}

output "dashboard_data_url" {
  value       = "http://${aws_s3_bucket_website_configuration.dashboard.website_endpoint}/data.json"
  description = "S3에 적재되는 데이터 JSON URL"
}
