# ── CloudWatch Log Groups (Fluent Bit + Lambda 로그 수집용) ──────────────────

locals {
  log_groups = {
    application    = "/aws/eks/mzc-pj4-${local.owner}/application"
    service_events = "/aws/eks/mzc-pj4-${local.owner}/service-events"
    dataplane      = "/aws/eks/mzc-pj4-${local.owner}/dataplane"
    host           = "/aws/eks/mzc-pj4-${local.owner}/host"
    lambda         = "/aws/lambda/mzc-pj4-${local.owner}"
    audit          = "/aws/eks/mzc-pj4-${local.owner}/audit"
  }
}

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

# ── IAM: CloudWatch Logs → Firehose 전송 권한 ────────────────────────────────

resource "aws_iam_role" "logs_to_firehose" {
  name = "mzc-pj4-${local.owner}-logs-to-firehose-${local.env}"

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
    Name    = "mzc-pj4-${local.owner}-logs-to-firehose-${local.env}"
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

# ── Subscription Filter: service-events Log → Firehose ──────────────────────
# service-events Log Group에 들어오는 로그를 Firehose로 자동 전달

resource "aws_cloudwatch_log_subscription_filter" "service_events_to_firehose" {
  name            = "mzc-pj4-${local.owner}-service-events-to-firehose"
  log_group_name  = aws_cloudwatch_log_group.eks_logs["service_events"].name
  filter_pattern  = ""
  destination_arn = aws_kinesis_firehose_delivery_stream.service_events.arn
  role_arn        = aws_iam_role.logs_to_firehose.arn
}

# EKS Control Plane 임시 Filter는 Fluent Bit + Pod 로그 흐름 검증 후 제거됨
# (2026-06-09). 진짜 비즈니스 이벤트는 amazon-cloudwatch ns의 Fluent Bit 사용.
