# ──────────────────────────────────────────────
# CloudWatch Log Group — 로그 보존 30일
# Lambda보다 먼저 생성해야 retention 설정이 적용됨
# ──────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "alarm_handler" {
  name              = "/aws/lambda/mzc-pj4-prod-alarm-handler"
  retention_in_days = 30

  tags = {
    Name    = "fiveline-prod-alarm-handler-logs"
    Service = "monitoring"
  }
}

# ──────────────────────────────────────────────
# IAM Role: Lambda 실행 역할
# (DynamoDB 테이블은 dynamodb_monitoring.tf에 정의)
# ──────────────────────────────────────────────
resource "aws_iam_role" "alarm_handler" {
  name = "mzc-pj4-prod-alarm-handler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name    = "mzc-pj4-prod-alarm-handler-role"
    Service = "alarm"
  }
}

resource "aws_iam_role_policy" "alarm_handler" {
  name = "mzc-pj4-prod-alarm-handler-policy"
  role = aws_iam_role.alarm_handler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.alarm_handler.arn}:*"
      },
      {
        Sid    = "DynamoDB"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:UpdateItem"
        ]
        Resource = [
          aws_dynamodb_table.alarm_history.arn,
          aws_dynamodb_table.dashboard_summary.arn,
        ]
      },
      {
        Sid      = "S3PutAlarmEvents"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "arn:aws:s3:::${var.s3_bucket_name}/raw/alarm-events/*"
      }
    ]
  })
}

# ──────────────────────────────────────────────
# Lambda 배포 패키지 (archive)
# ──────────────────────────────────────────────
data "archive_file" "alarm_handler" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/alarm_handler"
  output_path = "${path.module}/lambda/alarm_handler.zip"
}

# ──────────────────────────────────────────────
# Lambda 함수
# ──────────────────────────────────────────────
resource "aws_lambda_function" "alarm_handler" {
  function_name    = "mzc-pj4-prod-alarm-handler"
  filename         = data.archive_file.alarm_handler.output_path
  source_code_hash = data.archive_file.alarm_handler.output_base64sha256
  role             = aws_iam_role.alarm_handler.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 30

  environment {
    variables = {
      DYNAMODB_TABLE         = aws_dynamodb_table.alarm_history.name
      DYNAMODB_SUMMARY_TABLE = aws_dynamodb_table.dashboard_summary.name
      S3_BUCKET              = var.s3_bucket_name
      SLACK_WEBHOOK_URL      = var.slack_webhook_url
    }
  }

  depends_on = [aws_cloudwatch_log_group.alarm_handler]

  tags = {
    Name    = "mzc-pj4-prod-alarm-handler"
    Service = "alarm"
  }
}

# SNS가 Lambda를 호출할 수 있도록 권한 부여
resource "aws_lambda_permission" "sns_invoke" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.alarm_handler.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alarm.arn
}
