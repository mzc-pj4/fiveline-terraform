# ── 공통 ─────────────────────────────────────────────────────────────────────

variable "project" {
  description = "프로젝트 이름 (리소스 명칭 prefix)"
  type        = string
  default     = "fiveline"
}

variable "env" {
  description = "배포 환경 (dev / stg / prod)"
  type        = string
}

# ── data-pipeline 모듈 출력값 (외부 의존성) ────────────────────────────────

variable "data_lake_bucket_arn" {
  description = "data-pipeline 모듈에서 넘겨받는 Data Lake S3 버킷 ARN"
  type        = string
}

variable "data_lake_bucket_name" {
  description = "data-pipeline 모듈에서 넘겨받는 Data Lake S3 버킷 이름"
  type        = string
}

variable "check_results_table_arn" {
  description = "data-pipeline 모듈에서 넘겨받는 check_results DynamoDB 테이블 ARN"
  type        = string
}

variable "check_results_table_name" {
  description = "data-pipeline 모듈에서 넘겨받는 check_results DynamoDB 테이블 이름"
  type        = string
}

variable "dashboard_summary_table_arn" {
  description = "data-pipeline 모듈에서 넘겨받는 dashboard_summary DynamoDB 테이블 ARN"
  type        = string
}

variable "dashboard_summary_table_name" {
  description = "data-pipeline 모듈에서 넘겨받는 dashboard_summary DynamoDB 테이블 이름"
  type        = string
}

variable "report_metadata_table_arn" {
  description = "data-pipeline 모듈에서 넘겨받는 report_metadata DynamoDB 테이블 ARN"
  type        = string
}

variable "report_metadata_table_name" {
  description = "data-pipeline 모듈에서 넘겨받는 report_metadata DynamoDB 테이블 이름"
  type        = string
}

variable "glue_database_name" {
  description = "data-pipeline 모듈에서 넘겨받는 Glue Catalog 데이터베이스 이름"
  type        = string
}

variable "alarm_history_table_arn" {
  description = "monitoring 모듈에서 넘겨받는 alarm_history DynamoDB 테이블 ARN"
  type        = string
}
