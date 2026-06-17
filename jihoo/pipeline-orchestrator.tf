# ─── Pipeline Orchestrator: MSCK → Glue ETL → Summary Writer → Dashboard ──
# EventBridge가 3시간마다 호출 (발표 직전 1시간으로 변경 가능)

resource "aws_iam_role" "pipeline_orchestrator" {
  name = "mzc-pj4-${local.owner}-pipeline-orchestrator-${local.env}"

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
    Name    = "mzc-pj4-${local.owner}-pipeline-orchestrator-${local.env}"
  }
}

resource "aws_iam_role_policy_attachment" "pipeline_orchestrator_basic" {
  role       = aws_iam_role.pipeline_orchestrator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "pipeline_orchestrator_custom" {
  name = "pipeline-orchestrator-custom"
  role = aws_iam_role.pipeline_orchestrator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "GlueJob"
        Effect   = "Allow"
        Action   = ["glue:StartJobRun", "glue:GetJobRun"]
        Resource = aws_glue_job.cleansed_to_aggregated.arn
      },
      {
        Sid      = "GlueCatalog"
        Effect   = "Allow"
        Action   = ["glue:GetDatabase", "glue:GetTable", "glue:GetPartitions", "glue:BatchCreatePartition", "glue:CreatePartition", "glue:UpdatePartition"]
        Resource = "*"
      },
      {
        Sid    = "InvokeLambda"
        Effect = "Allow"
        Action = ["lambda:InvokeFunction"]
        Resource = [
          aws_lambda_function.summary_writer.arn,
          aws_lambda_function.dashboard_builder.arn,
        ]
      },
      {
        Sid      = "AthenaQuery"
        Effect   = "Allow"
        Action   = ["athena:StartQueryExecution", "athena:GetQueryExecution", "athena:GetQueryResults"]
        Resource = "*"
      },
      {
        Sid    = "AthenaS3"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [
          aws_s3_bucket.data_lake.arn,
          "${aws_s3_bucket.data_lake.arn}/*",
        ]
      },
    ]
  })
}

data "archive_file" "pipeline_orchestrator" {
  type        = "zip"
  source_dir  = "${path.module}/lambda-src/pipeline-orchestrator"
  output_path = "${path.module}/lambda-src/pipeline-orchestrator.zip"
}

resource "aws_lambda_function" "pipeline_orchestrator" {
  function_name = "mzc-pj4-${local.owner}-pipeline-orchestrator-${local.env}"
  role          = aws_iam_role.pipeline_orchestrator.arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 900 # 15분 (Lambda 최대) — Glue 첫 실행이 새 파티션 많으면 8분+
  memory_size   = 256

  filename         = data.archive_file.pipeline_orchestrator.output_path
  source_code_hash = data.archive_file.pipeline_orchestrator.output_base64sha256

  environment {
    variables = {
      GLUE_JOB_NAME          = aws_glue_job.cleansed_to_aggregated.name
      SUMMARY_WRITER_NAME    = aws_lambda_function.summary_writer.function_name
      DASHBOARD_BUILDER_NAME = aws_lambda_function.dashboard_builder.function_name
      ATHENA_DB              = aws_glue_catalog_database.data_lake.name
      ATHENA_OUTPUT          = "s3://${aws_s3_bucket.data_lake.bucket}/athena-results/"
    }
  }

  tags = {
    Service = "data-lake"
    Name    = "mzc-pj4-${local.owner}-pipeline-orchestrator-${local.env}"
  }
}

# EventBridge — 3시간 주기 (발표 직전 rate(1 hour)로 변경)
resource "aws_cloudwatch_event_rule" "pipeline_orchestrator_schedule" {
  name                = "mzc-pj4-${local.owner}-pipeline-orchestrator-${local.env}"
  description         = "3시간마다 데이터 파이프라인 자동 갱신 (집계 → 요약 → 대시보드)"
  schedule_expression = "rate(3 hours)"
  state               = "ENABLED"

  tags = {
    Service = "data-lake"
    Name    = "mzc-pj4-${local.owner}-pipeline-orchestrator-${local.env}"
  }
}

resource "aws_cloudwatch_event_target" "pipeline_orchestrator_target" {
  rule      = aws_cloudwatch_event_rule.pipeline_orchestrator_schedule.name
  target_id = "lambda"
  arn       = aws_lambda_function.pipeline_orchestrator.arn
}

resource "aws_lambda_permission" "pipeline_orchestrator_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.pipeline_orchestrator.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.pipeline_orchestrator_schedule.arn
}

output "pipeline_orchestrator_name" {
  value       = aws_lambda_function.pipeline_orchestrator.function_name
  description = "수동 호출시: aws lambda invoke --function-name <위 값>"
}
