# ── Firehose IAM Role ────────────────────────────────────────────────────────

resource "aws_iam_role" "firehose" {
  name = "mzc-pj4-${local.owner}-firehose-${local.env}"

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
    Name    = "mzc-pj4-${local.owner}-firehose-${local.env}"
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
# 백엔드 Pod 로그 (ORDER_FAILED 등) 수집 라인

resource "aws_kinesis_firehose_delivery_stream" "service_events" {
  name        = "mzc-pj4-${local.owner}-service-events-${local.env}"
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
    Name    = "mzc-pj4-${local.owner}-service-events-${local.env}"
  }
}

# ── Firehose: CW Metrics (Metric Streams → S3) ───────────────────────────────
# ALB·EKS·RDS·NAT 메트릭 수집 라인

resource "aws_kinesis_firehose_delivery_stream" "cw_metrics" {
  name        = "mzc-pj4-${local.owner}-cw-metrics-${local.env}"
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
    Name    = "mzc-pj4-${local.owner}-cw-metrics-${local.env}"
  }
}
