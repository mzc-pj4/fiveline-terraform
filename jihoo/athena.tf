# ── Athena Workgroups ────────────────────────────────────────────────────────
# - analytics: 운영자 Ad-hoc 분석, 쿼리당 10GB 제한
# - ai-reports: Bedrock/Report Lambda 전용, 쿼리당 5GB 제한

resource "aws_athena_workgroup" "analytics" {
  name = "mzc-pj4-${local.owner}-analytics-${local.env}"

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
    Name    = "mzc-pj4-${local.owner}-analytics-${local.env}"
  }
}

resource "aws_athena_workgroup" "ai_reports" {
  name = "mzc-pj4-${local.owner}-ai-reports-${local.env}"

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
    Name    = "mzc-pj4-${local.owner}-ai-reports-${local.env}"
  }
}
