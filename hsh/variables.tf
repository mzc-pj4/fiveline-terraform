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
  description = "ALB ARN suffix used as CloudWatch dimension (e.g. app/mzc-pj4-prod-alb/xxxxxxxx)"
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
