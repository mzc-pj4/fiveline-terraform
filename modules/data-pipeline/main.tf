# ══════════════════════════════════════════════════════════════════════════════
#  modules/data-pipeline/main.tf
#  S3 Data Lake → Firehose → Glue ETL → Athena → Lambda 집계/요약 파이프라인
# ══════════════════════════════════════════════════════════════════════════════

locals {
  project = "fiveline"

  log_groups = {
    application    = "/aws/eks/${local.project}/application"
    service_events = "/aws/eks/${local.project}/service-events"
    dataplane      = "/aws/eks/${local.project}/dataplane"
    host           = "/aws/eks/${local.project}/host"
    lambda         = "/aws/lambda/${local.project}"
    audit          = "/aws/eks/${local.project}/audit"
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ── S3 Data Lake Bucket ───────────────────────────────────────────────────────

resource "aws_s3_bucket" "data_lake" {
  bucket = "${local.project}-data-lake"

  tags = {
    Service = "data-lake"
    Name    = "${local.project}-data-lake"
  }
}

resource "aws_s3_bucket_versioning" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket" "access_logs" {
  bucket        = "${local.project}-data-access-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags = { Service = "logging", Name = "${local.project}-data-access-logs" }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket                  = aws_s3_bucket.access_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "access_logs" {
  bucket     = aws_s3_bucket.access_logs.id
  depends_on = [aws_s3_bucket_public_access_block.access_logs]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowS3LogDelivery"
        Effect    = "Allow"
        Principal = { Service = "logging.s3.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.access_logs.arn}/*"
        Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
      },
      {
        Sid       = "DenyHTTP"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.access_logs.arn, "${aws_s3_bucket.access_logs.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })
}

resource "aws_s3_bucket_logging" "data_lake" {
  bucket        = aws_s3_bucket.data_lake.id
  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "data-lake/"
  depends_on    = [aws_s3_bucket_policy.access_logs]
}

resource "aws_s3_bucket_policy" "data_lake_https_only" {
  bucket     = aws_s3_bucket.data_lake.id
  depends_on = [aws_s3_bucket_public_access_block.data_lake]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyHTTP"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.data_lake.arn,
        "${aws_s3_bucket.data_lake.arn}/*",
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

# ── Firehose IAM Role ─────────────────────────────────────────────────────────

resource "aws_iam_role" "firehose" {
  name = "${local.project}-firehose"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Service = "data-lake"
    Name    = "${local.project}-firehose"
  }
}

resource "aws_iam_role_policy" "firehose_s3" {
  name = "firehose-s3-write"
  role = aws_iam_role.firehose.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Write"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetBucketLocation",
          "s3:ListBucket",
          "s3:GetObject",
          "s3:AbortMultipartUpload",
          "s3:ListBucketMultipartUploads",
        ]
        Resource = [
          aws_s3_bucket.data_lake.arn,
          "${aws_s3_bucket.data_lake.arn}/*",
        ]
      },
      {
        Sid      = "CloudWatchLogs"
        Effect   = "Allow"
        Action   = ["logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
    ]
  })
}

# ── Firehose: Service Events (CW Logs → S3) ──────────────────────────────────

resource "aws_kinesis_firehose_delivery_stream" "service_events" {
  name        = "${local.project}-service-events"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose.arn
    bucket_arn = aws_s3_bucket.data_lake.arn

    prefix              = "raw/service-events/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/"
    error_output_prefix = "quarantine/firehose-errors/service-events/!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"

    buffering_size     = 5
    buffering_interval = 60
    compression_format = "GZIP"
  }

  tags = {
    Service = "data-lake"
    Name    = "${local.project}-service-events"
  }
}

# ── Firehose: CW Metrics (Metric Streams → S3) ───────────────────────────────

resource "aws_kinesis_firehose_delivery_stream" "cw_metrics" {
  name        = "${local.project}-cw-metrics"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose.arn
    bucket_arn = aws_s3_bucket.data_lake.arn

    prefix              = "raw/cw-metrics/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/"
    error_output_prefix = "quarantine/firehose-errors/cw-metrics/!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"

    buffering_size     = 5
    buffering_interval = 60
    compression_format = "GZIP"
  }

  tags = {
    Service = "data-lake"
    Name    = "${local.project}-cw-metrics"
  }
}

# ── Glue Catalog Database ─────────────────────────────────────────────────────

resource "aws_glue_catalog_database" "data_lake" {
  name        = "${replace(local.project, "-", "_")}_data_lake"
  description = "Data lake catalog for ${local.project}"
}

# ── Glue Crawler IAM ──────────────────────────────────────────────────────────

resource "aws_iam_role" "glue_crawler" {
  name = "${local.project}-glue-crawler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Service = "data-lake"
    Name    = "${local.project}-glue-crawler"
  }
}

resource "aws_iam_role_policy_attachment" "glue_crawler_service" {
  role       = aws_iam_role.glue_crawler.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_crawler_s3_read" {
  name = "glue-crawler-s3-read"
  role = aws_iam_role.glue_crawler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:ListBucket",
      ]
      Resource = [
        aws_s3_bucket.data_lake.arn,
        "${aws_s3_bucket.data_lake.arn}/*",
      ]
    }]
  })
}

resource "aws_iam_role_policy" "glue_etl_s3_write" {
  name = "glue-etl-s3-write"
  role = aws_iam_role.glue_crawler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:GetObject",
        "s3:ListBucket",
      ]
      Resource = [
        aws_s3_bucket.data_lake.arn,
        "${aws_s3_bucket.data_lake.arn}/*",
      ]
    }]
  })
}

# ── Glue Crawler ──────────────────────────────────────────────────────────────

resource "aws_glue_crawler" "raw" {
  name          = "${local.project}-raw-crawler"
  database_name = aws_glue_catalog_database.data_lake.name
  role          = aws_iam_role.glue_crawler.arn

  s3_target {
    path = "s3://${aws_s3_bucket.data_lake.bucket}/raw/"
  }
  s3_target {
    path = "s3://${aws_s3_bucket.data_lake.bucket}/cleansed/"
  }
  s3_target {
    path = "s3://${aws_s3_bucket.data_lake.bucket}/aggregated/events_hourly/"
  }
  s3_target {
    path = "s3://${aws_s3_bucket.data_lake.bucket}/aggregated/resource_findings_daily/"
  }

  configuration = jsonencode({
    Version = 1.0
    CrawlerOutput = {
      Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
    }
    Grouping = {
      TableGroupingPolicy = "CombineCompatibleSchemas"
    }
  })

  tags = {
    Service = "data-lake"
    Name    = "${local.project}-raw-crawler"
  }
}

# Glue 스크립트는 fiveline-backend 레포의 CI/CD가 artifact 버킷에 업로드
# fiveline-backend/.github/workflows/build-lambda-artifacts.yml 참고
# Glue job script_location은 artifact 버킷의 glue/ 경로를 직접 참조

# ── Glue ETL Job: raw → cleansed ─────────────────────────────────────────────

resource "aws_glue_job" "raw_to_cleansed" {
  name     = "${local.project}-raw-to-cleansed"
  role_arn = aws_iam_role.glue_crawler.arn

  command {
    name            = "glueetl"
    script_location = "s3://${var.artifacts_bucket}/glue/raw-to-cleansed.py"
    python_version  = "3"
  }

  glue_version      = "4.0"
  worker_type       = "G.1X"
  number_of_workers = 2
  timeout           = 10
  max_retries       = 0

  default_arguments = {
    "--source_path"                      = "s3://${aws_s3_bucket.data_lake.bucket}/raw/resource-check/"
    "--target_path"                      = "s3://${aws_s3_bucket.data_lake.bucket}/cleansed/resource-check/"
    "--job-language"                     = "python"
    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"
  }

  tags = {
    Service = "data-lake"
    Name    = "${local.project}-raw-to-cleansed"
  }
}

# ── Glue ETL Job: cleansed → aggregated ──────────────────────────────────────

resource "aws_glue_job" "cleansed_to_aggregated" {
  name     = "${local.project}-cleansed-to-aggregated"
  role_arn = aws_iam_role.glue_crawler.arn

  command {
    name            = "glueetl"
    script_location = "s3://${var.artifacts_bucket}/glue/cleansed-to-aggregated.py"
    python_version  = "3"
  }

  glue_version      = "4.0"
  worker_type       = "G.1X"
  number_of_workers = 2
  timeout           = 30
  max_retries       = 0

  execution_property {
    max_concurrent_runs = 2
  }

  default_arguments = {
    "--catalog_db"                       = aws_glue_catalog_database.data_lake.name
    "--events_table"                     = "service_events"
    "--events_target_path"               = "s3://${aws_s3_bucket.data_lake.bucket}/aggregated/events_hourly/"
    "--findings_source_path"             = "s3://${aws_s3_bucket.data_lake.bucket}/cleansed/resource-check/"
    "--findings_target_path"             = "s3://${aws_s3_bucket.data_lake.bucket}/aggregated/resource_findings_daily/"
    "--job-language"                     = "python"
    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"
  }

  tags = {
    Service = "data-lake"
    Name    = "${local.project}-cleansed-to-aggregated"
  }
}

# ── Glue Workflow ─────────────────────────────────────────────────────────────

resource "aws_glue_workflow" "raw_to_cleansed" {
  name        = "${local.project}-raw-to-cleansed-workflow"
  description = "raw 데이터 크롤링 → cleansed ETL 변환 DAG"

  tags = {
    Service = "data-lake"
    Name    = "${local.project}-raw-to-cleansed-workflow"
  }
}

# Trigger 1: 스케줄 → Crawler (DEACTIVATED)
resource "aws_glue_trigger" "schedule_crawler" {
  name          = "${local.project}-trigger-schedule"
  type          = "SCHEDULED"
  workflow_name = aws_glue_workflow.raw_to_cleansed.name
  schedule      = "cron(0 6 * * ? *)"
  enabled       = false

  actions {
    crawler_name = aws_glue_crawler.raw.name
  }

  tags = {
    Service = "data-lake"
    Name    = "${local.project}-trigger-schedule"
  }
}

# Trigger 2: Crawler SUCCEEDED → ETL Job
resource "aws_glue_trigger" "crawler_to_etl" {
  name          = "${local.project}-trigger-crawler-to-etl"
  type          = "CONDITIONAL"
  workflow_name = aws_glue_workflow.raw_to_cleansed.name

  predicate {
    conditions {
      logical_operator = "EQUALS"
      crawler_name     = aws_glue_crawler.raw.name
      crawl_state      = "SUCCEEDED"
    }
  }

  actions {
    job_name = aws_glue_job.raw_to_cleansed.name
  }

  tags = {
    Service = "data-lake"
    Name    = "${local.project}-trigger-crawler-to-etl"
  }
}

# Trigger 3: raw-to-cleansed SUCCEEDED → cleansed-to-aggregated
resource "aws_glue_trigger" "etl_to_aggregated" {
  name          = "${local.project}-trigger-etl-to-aggregated"
  type          = "CONDITIONAL"
  workflow_name = aws_glue_workflow.raw_to_cleansed.name

  predicate {
    conditions {
      logical_operator = "EQUALS"
      job_name         = aws_glue_job.raw_to_cleansed.name
      state            = "SUCCEEDED"
    }
  }

  actions {
    job_name = aws_glue_job.cleansed_to_aggregated.name
  }

  tags = {
    Service = "data-lake"
    Name    = "${local.project}-trigger-etl-to-aggregated"
  }
}

# ── Athena Workgroups ─────────────────────────────────────────────────────────

resource "aws_athena_workgroup" "analytics" {
  name = "${local.project}-analytics"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = 10737418240 # 10 GB

    result_configuration {
      output_location = "s3://${aws_s3_bucket.data_lake.bucket}/athena-results/analytics/"
    }
  }

  state = "ENABLED"

  tags = {
    Service = "data-lake"
    Name    = "${local.project}-analytics"
  }
}

resource "aws_athena_workgroup" "ai_reports" {
  name = "${local.project}-ai-reports"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = 5368709120 # 5 GB

    result_configuration {
      output_location = "s3://${aws_s3_bucket.data_lake.bucket}/athena-results/ai-reports/"
    }
  }

  state = "ENABLED"

  tags = {
    Service = "data-lake"
    Name    = "${local.project}-ai-reports"
  }
}

# ── CloudWatch Log Groups ─────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "eks_logs" {
  for_each          = local.log_groups
  name              = each.value
  retention_in_days = 30

  tags = {
    Service = "data-lake"
    Name    = each.value
    Type    = each.key
  }
}

# ── IAM: CloudWatch Logs → Firehose ──────────────────────────────────────────

resource "aws_iam_role" "logs_to_firehose" {
  name = "${local.project}-logs-to-firehose"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "logs.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Service = "data-lake"
    Name    = "${local.project}-logs-to-firehose"
  }
}

resource "aws_iam_role_policy" "logs_to_firehose" {
  name = "logs-to-firehose"
  role = aws_iam_role.logs_to_firehose.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "firehose:PutRecord",
        "firehose:PutRecordBatch",
      ]
      Resource = [
        aws_kinesis_firehose_delivery_stream.service_events.arn,
      ]
    }]
  })
}

# ── Subscription Filter: service-events → Firehose ───────────────────────────

resource "aws_cloudwatch_log_subscription_filter" "service_events_to_firehose" {
  name            = "${local.project}-service-events-to-firehose"
  log_group_name  = aws_cloudwatch_log_group.eks_logs["service_events"].name
  filter_pattern  = ""
  destination_arn = aws_kinesis_firehose_delivery_stream.service_events.arn
  role_arn        = aws_iam_role.logs_to_firehose.arn
}

# ── DynamoDB: check_results ───────────────────────────────────────────────────

resource "aws_dynamodb_table" "check_results" {
  name         = "${local.project}-check-results"
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
    Name    = "${local.project}-check-results"
  }
}

# ── DynamoDB: dashboard_summary ───────────────────────────────────────────────

resource "aws_dynamodb_table" "dashboard_summary" {
  name         = "${local.project}-dashboard-summary"
  billing_mode = "PAY_PER_REQUEST"

  hash_key = "summaryDate"

  attribute {
    name = "summaryDate"
    type = "S"
  }

  tags = {
    Service = "data-lake"
    Name    = "${local.project}-dashboard-summary"
  }
}

# ── DynamoDB: hourly_order_summary ────────────────────────────────────────────

resource "aws_dynamodb_table" "hourly_order_summary" {
  name         = "${local.project}-hourly-order-summary"
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
    Name    = "${local.project}-hourly-order-summary"
  }
}

# ── DynamoDB: infra_health_summary ────────────────────────────────────────────

resource "aws_dynamodb_table" "infra_health_summary" {
  name         = "${local.project}-infra-health-summary"
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
    Name    = "${local.project}-infra-health-summary"
  }
}

# ── DynamoDB: report_metadata ─────────────────────────────────────────────────

resource "aws_dynamodb_table" "report_metadata" {
  name         = "${local.project}-report-metadata"
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
    Name    = "${local.project}-report-metadata"
  }
}

# ── Lambda: Resource Checker ──────────────────────────────────────────────────

resource "aws_iam_role" "resource_checker" {
  name = "${local.project}-resource-checker"

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
    Name    = "${local.project}-resource-checker"
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
        Resource = "*" # nosonar
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

data "aws_s3_object" "resource_checker_zip" {
  bucket = var.artifacts_bucket
  key    = "lambda/data-pipeline/resource-checker.zip"
}

resource "aws_lambda_function" "resource_checker" {
  function_name = "${local.project}-resource-checker"
  role          = aws_iam_role.resource_checker.arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 60
  memory_size   = 256

  s3_bucket        = var.artifacts_bucket
  s3_key           = "lambda/data-pipeline/resource-checker.zip"
  source_code_hash = data.aws_s3_object.resource_checker_zip.etag

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
    Name    = "${local.project}-resource-checker"
  }
}

# ── Lambda: Summary Writer ────────────────────────────────────────────────────

resource "aws_iam_role" "summary_writer" {
  name = "${local.project}-summary-writer"

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
    Name    = "${local.project}-summary-writer"
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
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.data_lake.name}",
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.data_lake.name}/*",
        ]
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
        Sid    = "DynamoDBWrite"
        Effect = "Allow"
        Action = ["dynamodb:PutItem", "dynamodb:Scan"]
        Resource = aws_dynamodb_table.dashboard_summary.arn
      },
      {
        Sid      = "CloudWatchGetMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:GetMetricData"]
        Resource = "*" # nosonar
      },
    ]
  })
}

data "aws_s3_object" "summary_writer_zip" {
  bucket = var.artifacts_bucket
  key    = "lambda/data-pipeline/summary-writer.zip"
}

resource "aws_lambda_function" "summary_writer" {
  function_name = "${local.project}-summary-writer"
  role          = aws_iam_role.summary_writer.arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 120
  memory_size   = 256

  s3_bucket        = var.artifacts_bucket
  s3_key           = "lambda/data-pipeline/summary-writer.zip"
  source_code_hash = data.aws_s3_object.summary_writer_zip.etag

  environment {
    variables = {
      ATHENA_DB      = aws_glue_catalog_database.data_lake.name
      ATHENA_OUTPUT  = "s3://${aws_s3_bucket.data_lake.bucket}/athena-results/"
      TABLE_NAME     = aws_dynamodb_table.dashboard_summary.name
      MONITORING_SVC = "ecommerce"
      ALB_LB_NAME    = var.alb_lb_name
    }
  }

  tags = {
    Service = "data-lake"
    Name    = "${local.project}-summary-writer"
  }
}

# ── Lambda: Metrics Collector ─────────────────────────────────────────────────

resource "aws_iam_role" "metrics_collector" {
  name = "${local.project}-metrics-collector"

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
    Name    = "${local.project}-metrics-collector"
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
        Resource = "*" # nosonar
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

data "aws_s3_object" "metrics_collector_zip" {
  bucket = var.artifacts_bucket
  key    = "lambda/data-pipeline/metrics-collector.zip"
}

resource "aws_lambda_function" "metrics_collector" {
  function_name = "${local.project}-metrics-collector"
  role          = aws_iam_role.metrics_collector.arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 60
  memory_size   = 256

  s3_bucket        = var.artifacts_bucket
  s3_key           = "lambda/data-pipeline/metrics-collector.zip"
  source_code_hash = data.aws_s3_object.metrics_collector_zip.etag

  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.data_lake.bucket
      S3_PREFIX   = "raw/cw-metrics"
    }
  }

  tags = {
    Service = "data-lake"
    Name    = "${local.project}-metrics-collector"
  }
}

# EventBridge: Metrics Collector 5분 스케줄 (DISABLED — 실데이터 흐를 때 활성화)
resource "aws_cloudwatch_event_rule" "metrics_collector_schedule" {
  name                = "${local.project}-metrics-collector-schedule"
  description         = "5분마다 Metrics Collector Lambda 트리거"
  schedule_expression = "rate(5 minutes)"
  state               = "DISABLED"

  tags = {
    Service = "data-lake"
    Name    = "${local.project}-metrics-collector-schedule"
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

# ── Pipeline Orchestrator Lambda ──────────────────────────────────────────────
# dashboard_builder는 AI/Dashboard 모듈 소유 — ARN/name을 variable로 주입

resource "aws_iam_role" "pipeline_orchestrator" {
  name = "${local.project}-pipeline-orchestrator"

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
    Name    = "${local.project}-pipeline-orchestrator"
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
        Sid    = "GlueCatalog"
        Effect = "Allow"
        Action = ["glue:GetDatabase", "glue:GetTable", "glue:GetPartitions", "glue:BatchCreatePartition", "glue:CreatePartition", "glue:UpdatePartition"]
        Resource = [
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:catalog",
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.data_lake.name}",
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.data_lake.name}/*",
        ]
      },
      {
        Sid    = "InvokeLambda"
        Effect = "Allow"
        Action = ["lambda:InvokeFunction"]
        Resource = var.dashboard_builder_lambda_arn != "" ? [
          aws_lambda_function.summary_writer.arn,
          var.dashboard_builder_lambda_arn,
        ] : [aws_lambda_function.summary_writer.arn]
      },
      {
        Sid      = "AthenaQuery"
        Effect   = "Allow"
        Action   = ["athena:StartQueryExecution", "athena:GetQueryExecution", "athena:GetQueryResults"]
        Resource = "arn:aws:athena:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:workgroup/primary"
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

data "aws_s3_object" "pipeline_orchestrator_zip" {
  bucket = var.artifacts_bucket
  key    = "lambda/data-pipeline/pipeline-orchestrator.zip"
}

resource "aws_lambda_function" "pipeline_orchestrator" {
  function_name = "${local.project}-pipeline-orchestrator"
  role          = aws_iam_role.pipeline_orchestrator.arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 900
  memory_size   = 256

  s3_bucket        = var.artifacts_bucket
  s3_key           = "lambda/data-pipeline/pipeline-orchestrator.zip"
  source_code_hash = data.aws_s3_object.pipeline_orchestrator_zip.etag

  environment {
    variables = {
      GLUE_JOB_NAME          = aws_glue_job.cleansed_to_aggregated.name
      SUMMARY_WRITER_NAME    = aws_lambda_function.summary_writer.function_name
      DASHBOARD_BUILDER_NAME = var.dashboard_builder_lambda_name
      ATHENA_DB              = aws_glue_catalog_database.data_lake.name
      ATHENA_OUTPUT          = "s3://${aws_s3_bucket.data_lake.bucket}/athena-results/"
    }
  }

  tags = {
    Service = "data-lake"
    Name    = "${local.project}-pipeline-orchestrator"
  }
}

# EventBridge: 3시간 주기
resource "aws_cloudwatch_event_rule" "pipeline_orchestrator_schedule" {
  name                = "${local.project}-pipeline-orchestrator"
  description         = "3시간마다 데이터 파이프라인 자동 갱신 (집계 → 요약 → 대시보드)"
  schedule_expression = "rate(3 hours)"
  state               = "ENABLED"

  tags = {
    Service = "data-lake"
    Name    = "${local.project}-pipeline-orchestrator"
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

# ── EventBridge: Report Generator 스케줄 ─────────────────────────────────────
# report_generator Lambda는 AI 모듈 소유이지만, 스케줄 룰은 데이터 파이프라인 흐름의
# 일부이므로 이 모듈에서 관리. report_generator ARN은 AI 모듈 output으로 주입.
# NOTE: 현재 eventbridge.tf의 report_daily/weekly 룰은 report_generator Lambda를
#       직접 참조함 → AI 모듈이 별도로 관리하도록 위임. 아래는 참고용 주석.
#
# resource "aws_cloudwatch_event_rule" "report_daily" { ... }  # AI 모듈에서 관리
# resource "aws_cloudwatch_event_rule" "report_weekly" { ... } # AI 모듈에서 관리
