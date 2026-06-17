# ── Resource Checker Lambda IAM ──────────────────────────────────────────────

resource "aws_iam_role" "resource_checker" {
  name = "mzc-pj4-${local.owner}-resource-checker-${local.env}"

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
    Name    = "mzc-pj4-${local.owner}-resource-checker-${local.env}"
  }
}

resource "aws_iam_role_policy_attachment" "resource_checker_basic" {
  role       = aws_iam_role.resource_checker.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "resource_checker_custom" {
  name = "resource-checker-custom"
  role = aws_iam_role.resource_checker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2RDSReadOnly"
        Effect = "Allow"
        Action = [
          "ec2:DescribeVolumes",
          "ec2:DescribeAddresses",
          "ec2:DescribeSnapshots",
          "ec2:DescribeInstances",
          "ec2:DescribeSecurityGroups",
          "rds:DescribeDBInstances",
        ]
        Resource = "*"
      },

      {
        Sid      = "DynamoDBWriteCheckResults"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = aws_dynamodb_table.check_results.arn
      },
      {
        Sid      = "S3WriteResourceCheck"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.data_lake.arn}/raw/resource-check/*"
      },
    ]
  })
}

# ── Resource Checker Lambda Function ─────────────────────────────────────────

data "archive_file" "resource_checker" {
  type        = "zip"
  source_dir  = "${path.module}/lambda-src/resource-checker"
  output_path = "${path.module}/lambda-src/resource-checker.zip"
}

resource "aws_lambda_function" "resource_checker" {
  function_name = "mzc-pj4-${local.owner}-resource-checker-${local.env}"
  role          = aws_iam_role.resource_checker.arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 60
  memory_size   = 256

  filename         = data.archive_file.resource_checker.output_path
  source_code_hash = data.archive_file.resource_checker.output_base64sha256

  environment {
    variables = {
      TABLE_NAME        = aws_dynamodb_table.check_results.name
      BUCKET_NAME       = aws_s3_bucket.data_lake.bucket
      SNAPSHOT_AGE_DAYS = "30"
      REQUIRED_TAGS     = "Project,Environment,Owner"
    }
  }


  tags = {
    Service = "data-lake"
    Name    = "mzc-pj4-${local.owner}-resource-checker-${local.env}"
  }
}



# ── Summary Writer Lambda IAM ────────────────────────────────────────────────

resource "aws_iam_role" "summary_writer" {
  name = "mzc-pj4-${local.owner}-summary-writer-${local.env}"

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
    Name    = "mzc-pj4-${local.owner}-summary-writer-${local.env}"
  }
}

resource "aws_iam_role_policy_attachment" "summary_writer_basic" {
  role       = aws_iam_role.summary_writer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "summary_writer_custom" {
  name = "summary-writer-custom"
  role = aws_iam_role.summary_writer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
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
        Sid    = "S3DataLakeReadWrite"
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
      {
        Sid      = "DynamoDBWrite"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = aws_dynamodb_table.dashboard_summary.arn
      },
    ]
  })
}

# ── Summary Writer Lambda Function ───────────────────────────────────────────

data "archive_file" "summary_writer" {
  type        = "zip"
  source_dir  = "${path.module}/lambda-src/summary-writer"
  output_path = "${path.module}/lambda-src/summary-writer.zip"
}

resource "aws_lambda_function" "summary_writer" {
  function_name = "mzc-pj4-${local.owner}-summary-writer-${local.env}"
  role          = aws_iam_role.summary_writer.arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 120
  memory_size   = 256

  filename         = data.archive_file.summary_writer.output_path
  source_code_hash = data.archive_file.summary_writer.output_base64sha256

  environment {
    variables = {
      ATHENA_DB     = aws_glue_catalog_database.data_lake.name
      ATHENA_OUTPUT = "s3://${aws_s3_bucket.data_lake.bucket}/athena-results/"
      TABLE_NAME    = aws_dynamodb_table.dashboard_summary.name
    }
  }

  tags = {
    Service = "data-lake"
    Name    = "mzc-pj4-${local.owner}-summary-writer-${local.env}"
  }
}


# ── Metrics Collector Lambda IAM ─────────────────────────────────────────────

resource "aws_iam_role" "metrics_collector" {
  name = "mzc-pj4-${local.owner}-metrics-collector-${local.env}"

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
    Name    = "mzc-pj4-${local.owner}-metrics-collector-${local.env}"
  }
}

resource "aws_iam_role_policy_attachment" "metrics_collector_basic" {
  role       = aws_iam_role.metrics_collector.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "metrics_collector_custom" {
  name = "metrics-collector-custom"
  role = aws_iam_role.metrics_collector.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchGetMetrics"
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricData",
          "cloudwatch:ListMetrics",
        ]
        Resource = "*"
      },
      {
        Sid      = "S3WriteCWMetrics"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.data_lake.arn}/raw/cw-metrics/*"
      },
    ]
  })
}

# ── Metrics Collector Lambda Function ────────────────────────────────────────

data "archive_file" "metrics_collector" {
  type        = "zip"
  source_dir  = "${path.module}/lambda-src/metrics-collector"
  output_path = "${path.module}/lambda-src/metrics-collector.zip"
}

resource "aws_lambda_function" "metrics_collector" {
  function_name = "mzc-pj4-${local.owner}-metrics-collector-${local.env}"
  role          = aws_iam_role.metrics_collector.arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 60
  memory_size   = 256

  filename         = data.archive_file.metrics_collector.output_path
  source_code_hash = data.archive_file.metrics_collector.output_base64sha256

  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.data_lake.bucket
      S3_PREFIX   = "raw/cw-metrics"
    }
  }

  tags = {
    Service = "data-lake"
    Name    = "mzc-pj4-${local.owner}-metrics-collector-${local.env}"
  }
}

# ── EventBridge Rule (5분 스케줄, 안전 위해 비활성으로 시작) ────────────────

resource "aws_cloudwatch_event_rule" "metrics_collector_schedule" {
  name                = "mzc-pj4-${local.owner}-metrics-collector-schedule-${local.env}"
  description         = "5분마다 Metrics Collector Lambda 트리거"
  schedule_expression = "rate(5 minutes)"
  state               = "DISABLED"

  tags = {
    Service = "data-lake"
    Name    = "mzc-pj4-${local.owner}-metrics-collector-schedule-${local.env}"
  }
}

resource "aws_cloudwatch_event_target" "metrics_collector_target" {
  rule      = aws_cloudwatch_event_rule.metrics_collector_schedule.name
  target_id = "lambda"
  arn       = aws_lambda_function.metrics_collector.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.metrics_collector.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.metrics_collector_schedule.arn
}

# ── Report Generator Lambda IAM ──────────────────────────────────────────────

resource "aws_iam_role" "report_generator" {
  name = "mzc-pj4-${local.owner}-report-generator-${local.env}"

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
    Name    = "mzc-pj4-${local.owner}-report-generator-${local.env}"
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
        ]
      },
      {
        Sid      = "DynamoDBWriteReport"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = aws_dynamodb_table.report_metadata.arn
      },
      {
        Sid      = "S3WriteReports"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.data_lake.arn}/reports/*"
      },
    ]
  })
}

# ── Report Generator Lambda Function ─────────────────────────────────────────

data "archive_file" "report_generator" {
  type        = "zip"
  source_dir  = "${path.module}/lambda-src/report-generator"
  output_path = "${path.module}/lambda-src/report-generator.zip"
}

resource "aws_lambda_function" "report_generator" {
  function_name = "mzc-pj4-${local.owner}-report-generator-${local.env}"
  role          = aws_iam_role.report_generator.arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 300
  memory_size   = 512

  filename         = data.archive_file.report_generator.output_path
  source_code_hash = data.archive_file.report_generator.output_base64sha256

  environment {
    variables = {
      BUCKET_NAME     = aws_s3_bucket.data_lake.bucket
      REPORT_TABLE    = aws_dynamodb_table.report_metadata.name
      DASHBOARD_TABLE = aws_dynamodb_table.dashboard_summary.name
      CHECK_TABLE     = aws_dynamodb_table.check_results.name
      MODEL_ID        = "anthropic.claude-3-haiku-20240307-v1:0"
    }
  }

  tags = {
    Service = "data-lake"
    Name    = "mzc-pj4-${local.owner}-report-generator-${local.env}"
  }
}


# ── Bedrock Agent Action Lambda IAM ──────────────────────────────────────────

resource "aws_iam_role" "bedrock_agent_action" {
  name = "mzc-pj4-${local.owner}-bedrock-agent-action-${local.env}"

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
    Name    = "mzc-pj4-${local.owner}-bedrock-agent-action-${local.env}"
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
          aws_dynamodb_table.dashboard_summary.arn,
          aws_dynamodb_table.check_results.arn,
        ]
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

# ── Bedrock Agent Action Lambda Function ─────────────────────────────────────

data "archive_file" "bedrock_agent_action" {
  type        = "zip"
  source_dir  = "${path.module}/lambda-src/bedrock-agent-action"
  output_path = "${path.module}/lambda-src/bedrock-agent-action.zip"
}

resource "aws_lambda_function" "bedrock_agent_action" {
  function_name = "mzc-pj4-${local.owner}-bedrock-agent-action-${local.env}"
  role          = aws_iam_role.bedrock_agent_action.arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 60
  memory_size   = 512

  filename         = data.archive_file.bedrock_agent_action.output_path
  source_code_hash = data.archive_file.bedrock_agent_action.output_base64sha256

  environment {
    variables = {
      DASHBOARD_TABLE = aws_dynamodb_table.dashboard_summary.name
      CHECK_TABLE     = aws_dynamodb_table.check_results.name
      ALARM_TABLE     = "alarm_history"
      ATHENA_DB       = aws_glue_catalog_database.data_lake.name
      ATHENA_OUTPUT   = "s3://${aws_s3_bucket.data_lake.bucket}/athena-results/"
    }
  }

  tags = {
    Service = "data-lake"
    Name    = "mzc-pj4-${local.owner}-bedrock-agent-action-${local.env}"
  }
}
