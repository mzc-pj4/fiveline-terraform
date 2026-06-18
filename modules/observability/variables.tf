# ──────────────────────────────────────────────
# hsh/variables.tf 에서 온 변수들
# ──────────────────────────────────────────────

variable "s3_bucket_name" {
  description = "S3 bucket name where alarm events are stored under raw/alarm-events/"
  type        = string
}

variable "slack_webhook_url" {
  description = "Slack Incoming Webhook URL for alarm notifications"
  type        = string
  sensitive   = true
}

variable "alb_arn_suffix" {
  description = "ALB ARN suffix used as CloudWatch dimension (e.g. app/fiveline-prod-alb/xxxxxxxx)"
  type        = string
}

variable "eks_cluster_name" {
  description = "EKS cluster name for CloudWatch Container Insights metric dimension"
  type        = string
}

variable "rds_instance_id" {
  description = "RDS DB instance identifier"
  type        = string
}

variable "alarm_email" {
  description = "알람 수신 이메일 주소 (비워두면 이메일 구독 미생성)"
  type        = string
  default     = ""
}

variable "redis_replication_group_id" {
  description = "ElastiCache Redis Replication Group ID"
  type        = string
}

variable "rds_allocated_storage_gb" {
  description = "RDS 할당 스토리지 용량 (GB) — FreeStorageSpace 10% 임계값 계산에 사용"
  type        = number
  default     = 100
}

variable "rds_allocated_memory_gb" {
  description = "RDS 인스턴스 메모리 용량 (GB) — FreeableMemory 10% 임계값 계산에 사용"
  type        = number
  default     = 2
}

# hsh/variables.tf에 존재하지만 모니터링 알람에서 직접 사용하지 않는 변수
# (하위 호환을 위해 유지)
variable "alarm_5xx_threshold" {
  description = "ALB 5xx error count threshold per evaluation period"
  type        = number
  default     = 10
}

variable "eks_cpu_threshold" {
  description = "EKS cluster CPU utilization threshold (%)"
  type        = number
  default     = 80
}

variable "rds_connections_threshold" {
  description = "RDS DatabaseConnections threshold (max concurrent connections)"
  type        = number
  default     = 100
}

# ──────────────────────────────────────────────
# jihoo/dashboard.tf 에서 온 변수들
# ──────────────────────────────────────────────

variable "dashboard_check_results_table_arn" {
  description = "jihoo 데이터 파이프라인 모듈의 check_results DynamoDB 테이블 ARN"
  type        = string
}

variable "dashboard_check_results_table_name" {
  description = "jihoo 데이터 파이프라인 모듈의 check_results DynamoDB 테이블 이름"
  type        = string
}

variable "dashboard_report_metadata_table_arn" {
  description = "jihoo 데이터 파이프라인 모듈의 report_metadata DynamoDB 테이블 ARN"
  type        = string
}

variable "dashboard_report_metadata_table_name" {
  description = "jihoo 데이터 파이프라인 모듈의 report_metadata DynamoDB 테이블 이름"
  type        = string
}

variable "data_lake_bucket_arn" {
  description = "jihoo 데이터 파이프라인 모듈의 data_lake S3 버킷 ARN"
  type        = string
}

variable "data_lake_bucket_name" {
  description = "jihoo 데이터 파이프라인 모듈의 data_lake S3 버킷 이름"
  type        = string
}

variable "glue_data_lake_database_name" {
  description = "jihoo 데이터 파이프라인 모듈의 Glue 카탈로그 데이터베이스 이름"
  type        = string
}

variable "langgraph_lambda_arn" {
  description = "jihoo 데이터 파이프라인 모듈의 langgraph_agent Lambda ARN"
  type        = string
}

variable "langgraph_lambda_function_name" {
  description = "jihoo 데이터 파이프라인 모듈의 langgraph_agent Lambda 함수명"
  type        = string
}
