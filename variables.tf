# ── 기본 인프라 ────────────────────────────────────────────────────────────────

variable "k8s_version" {
  description = "EKS Kubernetes 버전"
  type        = string
  default     = "1.35"
}

variable "alb_dns_name" {
  description = "ALB DNS name — LB Controller가 Ingress로 ALB를 생성한 뒤 입력. 비어있으면 CloudFront API origin 비활성화 (2-phase apply)"
  type        = string
  default     = ""
}

variable "security_alert_email" {
  description = "GuardDuty 보안 알림 수신 이메일 주소"
  type        = string
  default     = ""
}

variable "admin_allowed_cidrs" {
  description = "관리자 대시보드(dashboard.fiveline.store) 접근 허용 IP 대역 (CIDR 리스트). 비어있으면 IP 제한 없음."
  type        = list(string)
  default     = []
}

# ── observability (hsh) ─────────────────────────────────────────────────────────

variable "slack_webhook_url" {
  description = "Slack Incoming Webhook URL (hsh 알람 Lambda 수신용)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "alb_arn_suffix" {
  description = "ALB ARN suffix (CloudWatch 차원, hsh 모니터링용) — ALB 생성 후 입력 (2-phase apply)"
  type        = string
  default     = ""
}

variable "alarm_email" {
  description = "CloudWatch 알람 수신 이메일 (비워두면 이메일 구독 미생성)"
  type        = string
  default     = ""
}

# ── CI/CD (lhj) ────────────────────────────────────────────────────────────────

variable "github_org" {
  description = "GitHub organization 이름 (e.g. mzc-pj4)"
  type        = string
  default     = "mzc-pj4"
}

variable "github_repos" {
  description = "GitHub Actions OIDC 허용 리포지터리 목록"
  type        = list(string)
  default     = ["fiveline-backend", "fiveline-frontend", "fiveline-terraform"]
}

# ── 2-phase apply 순환 의존성 해소 변수 ─────────────────────────────────────────
# 아래 3개 변수는 1차 apply 후 생성된 ARN/이름을 2차 apply 시 주입한다.
# 기존 alb_dns_name 패턴과 동일 — 비어있으면 해당 연결이 비활성화됨.

variable "alarm_history_table_arn" {
  description = "observability 모듈이 생성하는 alarm_history DynamoDB ARN → ai 모듈 IAM 정책 주입 (2-phase)"
  type        = string
  default     = ""
}

variable "langgraph_lambda_arn" {
  description = "ai 모듈이 생성하는 langgraph_agent Lambda ARN → observability 모듈 dashboard 주입 (2-phase)"
  type        = string
  default     = ""
}

variable "langgraph_lambda_name" {
  description = "ai 모듈이 생성하는 langgraph_agent Lambda 함수명 → observability 모듈 주입 (2-phase)"
  type        = string
  default     = ""
}

variable "dashboard_builder_lambda_arn" {
  description = "observability 모듈이 생성하는 dashboard_builder Lambda ARN → data-pipeline 오케스트레이터 주입 (2-phase)"
  type        = string
  default     = ""
}

variable "dashboard_builder_lambda_name" {
  description = "observability 모듈이 생성하는 dashboard_builder Lambda 함수명 → data-pipeline 오케스트레이터 주입 (2-phase)"
  type        = string
  default     = ""
}
