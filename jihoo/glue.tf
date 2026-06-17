# ── Glue Catalog Database ────────────────────────────────────────────────────

resource "aws_glue_catalog_database" "data_lake" {
  name        = "mzc_pj4_${local.owner}_data_lake_${local.env}"
  description = "Data lake catalog for mzc-pj4 (${local.owner}/${local.env})"
}

# ── Glue Crawler IAM ─────────────────────────────────────────────────────────

resource "aws_iam_role" "glue_crawler" {
  name = "mzc-pj4-${local.owner}-glue-crawler-${local.env}"

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
    Name    = "mzc-pj4-${local.owner}-glue-crawler-${local.env}"
  }
}

# AWS 기본 Glue 권한 (Catalog 쓰기 + CloudWatch Logs)
resource "aws_iam_role_policy_attachment" "glue_crawler_service" {
  role       = aws_iam_role.glue_crawler.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# 우리 S3 버킷 raw/ 읽기 권한만 (최소권한)
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

# ── Glue Crawler ─────────────────────────────────────────────────────────────

resource "aws_glue_crawler" "raw" {
  name          = "mzc-pj4-${local.owner}-raw-crawler-${local.env}"
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
    Name    = "mzc-pj4-${local.owner}-raw-crawler-${local.env}"
  }
}


# ── Glue ETL Job: S3 cleansed/ 쓰기 권한 추가 ────────────────────────────────

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

# ── Glue ETL Script Upload (PySpark 코드를 S3에 자동 배포) ───────────────────

resource "aws_s3_object" "etl_script_raw_to_cleansed" {
  bucket = aws_s3_bucket.data_lake.id
  key    = "glue-scripts/raw-to-cleansed.py"
  source = "${path.module}/glue-scripts/raw-to-cleansed.py"
  etag   = filemd5("${path.module}/glue-scripts/raw-to-cleansed.py")
}

# ── Glue ETL Job 정의 ────────────────────────────────────────────────────────

resource "aws_glue_job" "raw_to_cleansed" {
  name     = "mzc-pj4-${local.owner}-raw-to-cleansed-${local.env}"
  role_arn = aws_iam_role.glue_crawler.arn

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.data_lake.bucket}/glue-scripts/raw-to-cleansed.py"
    python_version  = "3"
  }

  glue_version      = "4.0"
  worker_type       = "G.1X" # 1 DPU per worker
  number_of_workers = 2      # 최소값 2개
  timeout           = 10     # minutes
  max_retries       = 0      # 학습용 — 실패해도 재시도 X

  default_arguments = {
    "--source_path"                      = "s3://${aws_s3_bucket.data_lake.bucket}/raw/resource-check/"
    "--target_path"                      = "s3://${aws_s3_bucket.data_lake.bucket}/cleansed/resource-check/"
    "--job-language"                     = "python"
    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"
  }

  tags = {
    Service = "data-lake"
    Name    = "mzc-pj4-${local.owner}-raw-to-cleansed-${local.env}"
  }
}


# ── Glue Workflow: raw → cleansed DAG ────────────────────────────────────────
# Crawler (스키마 갱신) → ETL Job (Parquet 변환) 순차 실행

resource "aws_glue_workflow" "raw_to_cleansed" {
  name        = "mzc-pj4-${local.owner}-raw-to-cleansed-workflow-${local.env}"
  description = "raw 데이터 크롤링 → cleansed ETL 변환 DAG"

  tags = {
    Service = "data-lake"
    Name    = "mzc-pj4-${local.owner}-raw-to-cleansed-workflow-${local.env}"
  }
}

# Trigger 1: 스케줄 (매일 06:00 UTC = 한국 15:00) → Crawler 시작
# 학습 안전을 위해 DEACTIVATED. 실데이터 흐를 때 활성화.
resource "aws_glue_trigger" "schedule_crawler" {
  name          = "mzc-pj4-${local.owner}-trigger-schedule-${local.env}"
  type          = "SCHEDULED"
  workflow_name = aws_glue_workflow.raw_to_cleansed.name
  schedule      = "cron(0 6 * * ? *)"
  enabled       = false

  actions {
    crawler_name = aws_glue_crawler.raw.name
  }

  tags = {
    Service = "data-lake"
    Name    = "mzc-pj4-${local.owner}-trigger-schedule-${local.env}"
  }
}

# Trigger 2: Crawler SUCCEEDED → ETL Job 자동 시작
resource "aws_glue_trigger" "crawler_to_etl" {
  name          = "mzc-pj4-${local.owner}-trigger-crawler-to-etl-${local.env}"
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
    Name    = "mzc-pj4-${local.owner}-trigger-crawler-to-etl-${local.env}"
  }
}

# ── cleansed → aggregated ETL Job ────────────────────────────────────────────
# 두 가지 집계 산출:
#   1) aggregated/events_hourly/         (시간×스트림별 에러율)
#   2) aggregated/resource_findings_daily/ (일별 checkType 카운트)

resource "aws_s3_object" "etl_script_cleansed_to_aggregated" {
  bucket = aws_s3_bucket.data_lake.id
  key    = "glue-scripts/cleansed-to-aggregated.py"
  source = "${path.module}/glue-scripts/cleansed-to-aggregated.py"
  etag   = filemd5("${path.module}/glue-scripts/cleansed-to-aggregated.py")
}

resource "aws_glue_job" "cleansed_to_aggregated" {
  name     = "mzc-pj4-${local.owner}-cleansed-to-aggregated-${local.env}"
  role_arn = aws_iam_role.glue_crawler.arn

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.data_lake.bucket}/glue-scripts/cleansed-to-aggregated.py"
    python_version  = "3"
  }

  glue_version      = "4.0"
  worker_type       = "G.1X"
  number_of_workers = 2
  timeout           = 30 # 누적 데이터 증가 대응 (어제 8분 → 오늘 10분 초과)
  max_retries       = 0

  execution_property {
    max_concurrent_runs = 2 # EventBridge + 수동 동시 호출 대응
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
    Name    = "mzc-pj4-${local.owner}-cleansed-to-aggregated-${local.env}"
  }
}

# Trigger 3: raw-to-cleansed SUCCEEDED → cleansed-to-aggregated 자동 시작
resource "aws_glue_trigger" "etl_to_aggregated" {
  name          = "mzc-pj4-${local.owner}-trigger-etl-to-aggregated-${local.env}"
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
    Name    = "mzc-pj4-${local.owner}-trigger-etl-to-aggregated-${local.env}"
  }
}
