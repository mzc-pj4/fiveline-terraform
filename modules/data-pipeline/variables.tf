# ── 외부에서 주입되는 값들 ────────────────────────────────────────────────────

variable "artifacts_bucket" {
  description = "S3 artifact 버킷 이름 — Lambda zip 및 Glue 스크립트 저장소 (CI/CD가 업로드)"
  type        = string
}

variable "dashboard_builder_lambda_arn" {
  description = "dashboard_builder Lambda ARN — pipeline_orchestrator가 완료 후 invoke (AI/Dashboard 모듈 output)"
  type        = string
}

variable "dashboard_builder_lambda_name" {
  description = "dashboard_builder Lambda function_name — pipeline_orchestrator 환경변수 주입용"
  type        = string
}
