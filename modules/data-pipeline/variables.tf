# ── 외부에서 주입되는 값들 ────────────────────────────────────────────────────

variable "lambda_src_path" {
  description = "Lambda 소스 코드 디렉토리 절대 경로 (jihoo/lambda-src/ 기준)"
  type        = string
  # 예: "${path.module}/../../jihoo/lambda-src"
  # 호출자가 path.root 또는 path.module 기준 절대 경로를 전달
}

variable "glue_scripts_path" {
  description = "Glue ETL 스크립트 디렉토리 절대 경로 (jihoo/glue-scripts/ 기준)"
  type        = string
  # 예: "${path.module}/../../jihoo/glue-scripts"
}

variable "dashboard_builder_lambda_arn" {
  description = "dashboard_builder Lambda ARN — pipeline_orchestrator가 완료 후 invoke (AI/Dashboard 모듈 output)"
  type        = string
}

variable "dashboard_builder_lambda_name" {
  description = "dashboard_builder Lambda function_name — pipeline_orchestrator 환경변수 주입용"
  type        = string
}
