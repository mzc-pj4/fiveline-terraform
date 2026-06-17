# ── Report Embedder Lambda (경량 RAG: Bedrock Titan Embed + DDB) ─────────────

# ── IAM ─────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "report_embedder" {
  name = "mzc-pj4-${local.owner}-report-embedder-${local.env}"

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
    Name    = "mzc-pj4-${local.owner}-report-embedder-${local.env}"
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
          aws_s3_bucket.data_lake.arn,
          "${aws_s3_bucket.data_lake.arn}/*",
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

# ── Lambda Function ──────────────────────────────────────────────────────────

data "archive_file" "report_embedder" {
  type        = "zip"
  source_dir  = "${path.module}/lambda-src/report-embedder"
  output_path = "${path.module}/lambda-src/report-embedder.zip"
}

resource "aws_lambda_function" "report_embedder" {
  function_name = "mzc-pj4-${local.owner}-report-embedder-${local.env}"
  role          = aws_iam_role.report_embedder.arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 300
  memory_size   = 512

  filename         = data.archive_file.report_embedder.output_path
  source_code_hash = data.archive_file.report_embedder.output_base64sha256

  environment {
    variables = {
      BUCKET_NAME     = aws_s3_bucket.data_lake.bucket
      REPORTS_PREFIX  = "reports/daily/"
      EMBED_TABLE     = aws_dynamodb_table.report_embeddings.name
      EMBED_MODEL     = "amazon.titan-embed-text-v2:0"
      MAX_CHARS       = "8000"
    }
  }

  tags = {
    Service = "data-lake"
    Name    = "mzc-pj4-${local.owner}-report-embedder-${local.env}"
  }
}

# ── EventBridge: 매일 16:00 KST (07:00 UTC) — Report Generator(15:00 KST) 1시간 후 ─

resource "aws_cloudwatch_event_rule" "report_embedder_daily" {
  name                = "mzc-pj4-${local.owner}-report-embedder-daily-${local.env}"
  description         = "매일 16:00 KST: 신규 리포트를 Bedrock Titan Embed로 벡터화"
  schedule_expression = "cron(0 7 * * ? *)"

  tags = {
    Service = "data-lake"
    Name    = "mzc-pj4-${local.owner}-report-embedder-daily-${local.env}"
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

output "report_embedder_function_name" {
  value       = aws_lambda_function.report_embedder.function_name
  description = "Report Embedder Lambda 함수 이름 (백필 invoke용)"
}
