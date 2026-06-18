# ══════════════════════════════════════════════════════════════════════════════
# modules/observability/main.tf
# hsh 알람/Lambda/DynamoDB + jihoo 대시보드 통합 모듈
# ══════════════════════════════════════════════════════════════════════════════

# NOTE: hsh/lambda/alarm_handler/ → modules/observability/lambda/alarm_handler/ 로 복사 필요
#       cp -r hsh/lambda/alarm_handler modules/observability/lambda/alarm_handler

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  # 할당 스토리지의 10% (bytes)
  rds_storage_threshold_bytes = floor(var.rds_allocated_storage_gb * 1024 * 1024 * 1024 * 0.1)
  # 할당 메모리의 10% (bytes)
  rds_memory_threshold_bytes  = floor(var.rds_allocated_memory_gb * 1024 * 1024 * 1024 * 0.1)

  # 대시보드 네이밍에 사용 (jihoo/dashboard.tf 통합 시 local.project 대응)
  project = "fiveline"
}

# ──────────────────────────────────────────────
# SNS (hsh/sns.tf)
# ──────────────────────────────────────────────

resource "aws_sns_topic" "alarm" {
  name = "fiveline-prod-alarm-topic"

  tags = {
    Name    = "fiveline-prod-alarm-topic"
    Service = "monitoring"
  }
}

resource "aws_sns_topic_policy" "alarm" {
  arn = aws_sns_topic.alarm.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudWatchPublish"
        Effect = "Allow"
        Principal = {
          Service = "cloudwatch.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.alarm.arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" = "arn:aws:cloudwatch:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:alarm:*"
          }
        }
      }
    ]
  })
}

resource "aws_sns_topic_subscription" "lambda" {
  topic_arn = aws_sns_topic.alarm.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.alarm_handler.arn
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alarm_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.alarm.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# ──────────────────────────────────────────────
# DynamoDB (hsh/dynamodb_monitoring.tf)
# ──────────────────────────────────────────────

resource "aws_dynamodb_table" "alarm_history" {
  name         = "alarm_history"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "alarmId"

  attribute {
    name = "alarmId"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = {
    Name    = "fiveline-prod-alarm-history"
    Service = "monitoring"
  }
}

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

# ──────────────────────────────────────────────
# Lambda 알람 핸들러 (hsh/lambda_alarm.tf)
# ──────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "alarm_handler" {
  name              = "/aws/lambda/mzc-pj4-prod-alarm-handler"
  retention_in_days = 30

  tags = {
    Name    = "fiveline-prod-alarm-handler-logs"
    Service = "monitoring"
  }
}

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

# NOTE: modules/observability/lambda/alarm_handler/ 디렉토리가 존재해야 합니다.
#       원본 위치: hsh/lambda/alarm_handler/
#       복사 명령: Copy-Item -Recurse hsh\lambda\alarm_handler modules\observability\lambda\alarm_handler
data "archive_file" "alarm_handler" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/alarm_handler"
  output_path = "${path.module}/lambda/alarm_handler.zip"
}

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

resource "aws_lambda_permission" "sns_invoke" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.alarm_handler.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alarm.arn
}

# ══════════════════════════════════════════════
# CloudWatch 알람 (hsh/monitoring.tf)
# ══════════════════════════════════════════════

# 공통 설정
# datapoints_to_alarm = 2, evaluation_periods = 2, treat_missing_data = "notBreaching"
# 예외: fiveline-alarm-ca-pending-pods (period=60, eval=4, dtp=4)
#       fiveline-alarm-burn-rate-1h    (period=3600, eval=1, dtp=1)

# ── ALB 알람 — ALB(Ingress) 생성 후 활성화 ──────────────────────────────────
# CI/CD 담당자 작업 완료 후 alb_arn_suffix 변수 채워서 apply

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  count               = var.alb_arn_suffix != "" ? 1 : 0
  alarm_name          = "fiveline-alarm-alb-5xx"
  alarm_description   = "[Critical] ALB 백엔드 5xx 에러율 1% 초과"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 1
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "error_rate"
    expression  = "m1/m2*100"
    label       = "5xx Error Rate (%)"
    return_data = true
  }
  metric_query {
    id = "m1"
    metric {
      metric_name = "HTTPCode_Target_5XX_Count"
      namespace   = "AWS/ApplicationELB"
      period      = 300
      stat        = "Sum"
      dimensions  = { LoadBalancer = var.alb_arn_suffix }
    }
  }
  metric_query {
    id = "m2"
    metric {
      metric_name = "RequestCount"
      namespace   = "AWS/ApplicationELB"
      period      = 300
      stat        = "Sum"
      dimensions  = { LoadBalancer = var.alb_arn_suffix }
    }
  }

  alarm_actions = [aws_sns_topic.alarm.arn]
  ok_actions    = [aws_sns_topic.alarm.arn]

  tags = {
    Name     = "fiveline-alarm-alb-5xx"
    Service  = "monitoring"
    Severity = "critical"
  }
}

resource "aws_cloudwatch_metric_alarm" "alb_503" {
  count               = var.alb_arn_suffix != "" ? 1 : 0
  alarm_name          = "fiveline-alarm-alb-503"
  alarm_description   = "[Warning] ALB ELB 5xx 발생 (503 포함 — healthy target 없음 의심)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  alarm_actions = [aws_sns_topic.alarm.arn]
  ok_actions    = [aws_sns_topic.alarm.arn]

  tags = {
    Name     = "fiveline-alarm-alb-503"
    Service  = "monitoring"
    Severity = "warning"
  }
}

# ── RDS 알람 ──────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  alarm_name          = "fiveline-alarm-rds-storage"
  alarm_description   = "[Warning] RDS 여유 스토리지 전체 용량의 10% 미만"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Minimum"
  threshold           = local.rds_storage_threshold_bytes
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = var.rds_instance_id
  }

  alarm_actions = [aws_sns_topic.alarm.arn]
  ok_actions    = [aws_sns_topic.alarm.arn]

  tags = {
    Name     = "fiveline-alarm-rds-storage"
    Service  = "monitoring"
    Severity = "warning"
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_freeable_memory" {
  alarm_name          = "fiveline-alarm-rds-freeable-memory"
  alarm_description   = "[Warning] RDS 여유 메모리 전체 메모리의 10% 미만 (사용률 90% 초과)"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  metric_name         = "FreeableMemory"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Minimum"
  threshold           = local.rds_memory_threshold_bytes
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = var.rds_instance_id
  }

  alarm_actions = [aws_sns_topic.alarm.arn]
  ok_actions    = [aws_sns_topic.alarm.arn]

  tags = {
    Name     = "fiveline-alarm-rds-freeable-memory"
    Service  = "monitoring"
    Severity = "warning"
  }
}

# ── Redis (ElastiCache) 알람 ───────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "redis_hitrate_warn" {
  alarm_name          = "fiveline-alarm-redis-hitrate-warn"
  alarm_description   = "[Warning] Redis Hit Rate 80% 미만"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 80
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "hit_rate"
    expression  = "m1/(m1+m2)*100"
    label       = "Hit Rate (%)"
    return_data = true
  }
  metric_query {
    id = "m1"
    metric {
      metric_name = "GetHits"
      namespace   = "AWS/ElastiCache"
      period      = 300
      stat        = "Sum"
      dimensions  = { ReplicationGroupId = var.redis_replication_group_id }
    }
  }
  metric_query {
    id = "m2"
    metric {
      metric_name = "GetMisses"
      namespace   = "AWS/ElastiCache"
      period      = 300
      stat        = "Sum"
      dimensions  = { ReplicationGroupId = var.redis_replication_group_id }
    }
  }

  alarm_actions = [aws_sns_topic.alarm.arn]
  ok_actions    = [aws_sns_topic.alarm.arn]

  tags = {
    Name     = "fiveline-alarm-redis-hitrate-warn"
    Service  = "monitoring"
    Severity = "warning"
  }
}

resource "aws_cloudwatch_metric_alarm" "redis_hitrate_crit" {
  alarm_name          = "fiveline-alarm-redis-hitrate-crit"
  alarm_description   = "[Critical] Redis Hit Rate 60% 미만"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 60
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "hit_rate"
    expression  = "m1/(m1+m2)*100"
    label       = "Hit Rate (%)"
    return_data = true
  }
  metric_query {
    id = "m1"
    metric {
      metric_name = "GetHits"
      namespace   = "AWS/ElastiCache"
      period      = 300
      stat        = "Sum"
      dimensions  = { ReplicationGroupId = var.redis_replication_group_id }
    }
  }
  metric_query {
    id = "m2"
    metric {
      metric_name = "GetMisses"
      namespace   = "AWS/ElastiCache"
      period      = 300
      stat        = "Sum"
      dimensions  = { ReplicationGroupId = var.redis_replication_group_id }
    }
  }

  alarm_actions = [aws_sns_topic.alarm.arn]
  ok_actions    = [aws_sns_topic.alarm.arn]

  tags = {
    Name     = "fiveline-alarm-redis-hitrate-crit"
    Service  = "monitoring"
    Severity = "critical"
  }
}

resource "aws_cloudwatch_metric_alarm" "redis_replication_lag" {
  alarm_name          = "fiveline-alarm-redis-replication-lag"
  alarm_description   = "[Warning] Redis Replication Lag 10초 초과"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  metric_name         = "ReplicationLag"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Maximum"
  threshold           = 10
  treat_missing_data  = "notBreaching"

  dimensions = {
    ReplicationGroupId = var.redis_replication_group_id
  }

  alarm_actions = [aws_sns_topic.alarm.arn]
  ok_actions    = [aws_sns_topic.alarm.arn]

  tags = {
    Name     = "fiveline-alarm-redis-replication-lag"
    Service  = "monitoring"
    Severity = "warning"
  }
}

# ── EKS / Pod 알람 (Container Insights 필요) ─────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "pod_restart" {
  alarm_name          = "fiveline-alarm-pod-restart"
  alarm_description   = "[Warning] Pod 재시작 30분 내 3회 초과"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  metric_name         = "pod_number_of_container_restarts"
  namespace           = "ContainerInsights"
  period              = 1800
  statistic           = "Maximum"
  threshold           = 3
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.eks_cluster_name
  }

  alarm_actions = [aws_sns_topic.alarm.arn]
  ok_actions    = [aws_sns_topic.alarm.arn]

  tags = {
    Name     = "fiveline-alarm-pod-restart"
    Service  = "monitoring"
    Severity = "warning"
  }
}

# kube-state-metrics → ADOT → ContainerInsights/Prometheus 필요
resource "aws_cloudwatch_metric_alarm" "hpa_maxreplicas" {
  alarm_name          = "fiveline-alarm-hpa-maxreplicas"
  alarm_description   = "[Critical] HPA가 최대 레플리카(6)에 도달 — 용량 부족 가능성"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  metric_name         = "kube_hpa_status_current_replicas"
  namespace           = "ContainerInsights/Prometheus"
  period              = 300
  statistic           = "Maximum"
  threshold           = 6
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.eks_cluster_name
  }

  alarm_actions = [aws_sns_topic.alarm.arn]
  ok_actions    = [aws_sns_topic.alarm.arn]

  tags = {
    Name     = "fiveline-alarm-hpa-maxreplicas"
    Service  = "monitoring"
    Severity = "critical"
  }
}

resource "aws_cloudwatch_metric_alarm" "ca_pending_pods" {
  alarm_name          = "fiveline-alarm-ca-pending-pods"
  alarm_description   = "[Warning] Pending Pod 4분 이상 지속 — Cluster Autoscaler 미동작 의심"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 4
  datapoints_to_alarm = 4
  metric_name         = "pod_number_of_pending"
  namespace           = "ContainerInsights"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.eks_cluster_name
  }

  alarm_actions = [aws_sns_topic.alarm.arn]
  ok_actions    = [aws_sns_topic.alarm.arn]

  tags = {
    Name     = "fiveline-alarm-ca-pending-pods"
    Service  = "monitoring"
    Severity = "warning"
  }
}

# ── SLO 알람 ──────────────────────────────────────────────────────────────────

# order-service P99 응답시간 > 2초 (ALB 생성 후 활성화)
resource "aws_cloudwatch_metric_alarm" "order_p99_latency" {
  count               = var.alb_arn_suffix != "" ? 1 : 0
  alarm_name          = "fiveline-alarm-order-p99-latency"
  alarm_description   = "[Critical] order-service P99 응답시간 2초 초과"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  extended_statistic  = "p99"
  threshold           = 2
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  alarm_actions = [aws_sns_topic.alarm.arn]
  ok_actions    = [aws_sns_topic.alarm.arn]

  tags = {
    Name     = "fiveline-alarm-order-p99-latency"
    Service  = "monitoring"
    Severity = "critical"
  }
}

# 애플리케이션이 fiveline/SLO 네임스페이스로 커스텀 메트릭을 푸시해야 동작
resource "aws_cloudwatch_metric_alarm" "burn_rate_1h" {
  alarm_name          = "fiveline-alarm-burn-rate-1h"
  alarm_description   = "[Critical] 에러 예산 소진율 14.4 초과 (1시간 내 1% 에러 예산 소진 위험)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  metric_name         = "ErrorBudgetBurnRate"
  namespace           = "fiveline/SLO"
  period              = 3600
  statistic           = "Maximum"
  threshold           = 14.4
  treat_missing_data  = "notBreaching"

  dimensions = {
    Service = "order-service"
  }

  alarm_actions = [aws_sns_topic.alarm.arn]
  ok_actions    = [aws_sns_topic.alarm.arn]

  tags = {
    Name     = "fiveline-alarm-burn-rate-1h"
    Service  = "monitoring"
    Severity = "critical"
  }
}

# ══════════════════════════════════════════════════════════════════════════════
# 대시보드 (jihoo/dashboard.tf 통합)
# 네이밍: mzc-pj4-${local.owner}-xxx-${local.env} → ${local.project}-xxx
# ══════════════════════════════════════════════════════════════════════════════

# ── Dashboard S3 Static Hosting Bucket ───────────────────────────────────────

resource "aws_s3_bucket" "dashboard" {
  bucket = "${local.project}-dashboard"

  tags = {
    Service = "dashboard"
    Name    = "${local.project}-dashboard"
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

# ── Dashboard API Lambda IAM ──────────────────────────────────────────────────

resource "aws_iam_role" "dashboard_api" {
  name = "${local.project}-dashboard-api"

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
    Name    = "${local.project}-dashboard-api"
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
          var.dashboard_check_results_table_arn,
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
          var.data_lake_bucket_arn,
          "${var.data_lake_bucket_arn}/*",
        ]
      },
      {
        Sid      = "InvokeLangGraph"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = var.langgraph_lambda_arn != "" ? var.langgraph_lambda_arn : "*"
      },
    ]
  })
}

# ── Dashboard API Lambda Function ─────────────────────────────────────────────

data "archive_file" "dashboard_api" {
  type        = "zip"
  source_dir  = "${path.module}/lambda-src/dashboard-api"
  output_path = "${path.module}/lambda-src/dashboard-api.zip"
}

resource "aws_lambda_function" "dashboard_api" {
  function_name = "${local.project}-dashboard-api"
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
      CHECK_TABLE      = var.dashboard_check_results_table_name
      ATHENA_DB        = var.glue_data_lake_database_name
      ATHENA_OUTPUT    = "s3://${var.data_lake_bucket_name}/athena-results/"
      LANGGRAPH_LAMBDA = var.langgraph_lambda_function_name
    }
  }

  tags = {
    Service = "dashboard"
    Name    = "${local.project}-dashboard-api"
  }
}

# ── API Gateway HTTP API ───────────────────────────────────────────────────────
# MZC SCP가 Lambda Function URL 공개 호출을 차단해서 API Gateway HTTP API로 우회.
# CloudFront + OAC는 POST body 서명 이슈로 실패 → API Gateway가 가장 안정적인 패턴.

resource "aws_apigatewayv2_api" "dashboard_api" {
  name          = "${local.project}-dashboard-api"
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
    Name    = "${local.project}-dashboard-api"
  }
}

resource "aws_apigatewayv2_integration" "dashboard_api_lambda" {
  api_id                 = aws_apigatewayv2_api.dashboard_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.dashboard_api.invoke_arn
  payload_format_version = "2.0"
  integration_method     = "POST"
}

resource "aws_apigatewayv2_route" "dashboard_api_default" {
  api_id    = aws_apigatewayv2_api.dashboard_api.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.dashboard_api_lambda.id}"
}

resource "aws_apigatewayv2_stage" "dashboard_api_default" {
  api_id      = aws_apigatewayv2_api.dashboard_api.id
  name        = "$default"
  auto_deploy = true

  tags = {
    Service = "dashboard"
    Name    = "${local.project}-dashboard-api-stage"
  }
}

resource "aws_lambda_permission" "dashboard_api_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dashboard_api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.dashboard_api.execution_arn}/*/*"
}

# ── Dashboard Builder Lambda ───────────────────────────────────────────────────

resource "aws_iam_role" "dashboard_builder" {
  name = "${local.project}-dashboard-builder"

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
    Name    = "${local.project}-dashboard-builder"
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
          var.dashboard_check_results_table_arn,
          var.dashboard_report_metadata_table_arn,
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
          var.data_lake_bucket_arn,
          "${var.data_lake_bucket_arn}/*",
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
  function_name = "${local.project}-dashboard-builder"
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
      CHECK_TABLE                = var.dashboard_check_results_table_name
      REPORT_TABLE               = var.dashboard_report_metadata_table_name
      MONITORING_DASHBOARD_TABLE = "dashboard_summary"
      MONITORING_SERVICE_KEY     = "ecommerce"
      ATHENA_DB                  = var.glue_data_lake_database_name
      ATHENA_OUTPUT              = "s3://${var.data_lake_bucket_name}/athena-results/"
      BUCKET_NAME                = aws_s3_bucket.dashboard.bucket
      JSON_KEY                   = "data.json"
      CHAT_API_BASE              = "${aws_apigatewayv2_api.dashboard_api.api_endpoint}/"
    }
  }

  tags = {
    Service = "dashboard"
    Name    = "${local.project}-dashboard-builder"
  }
}

# EventBridge 룰 — 30분마다 dashboard-builder 호출
resource "aws_cloudwatch_event_rule" "dashboard_builder_schedule" {
  name                = "${local.project}-dashboard-builder-schedule"
  description         = "30분마다 대시보드 data.json 갱신"
  schedule_expression = "rate(30 minutes)"
  state               = "ENABLED"

  tags = {
    Service = "dashboard"
    Name    = "${local.project}-dashboard-builder-schedule"
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
