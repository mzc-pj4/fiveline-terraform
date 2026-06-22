output "regional_waf_arn" {
  description = "Regional WAF ARN (ap-northeast-2) — ALB Ingress annotation에 주입"
  value       = aws_wafv2_web_acl.regional.arn
}

output "security_alerts_sns_arn" {
  description = "보안 알림 SNS 토픽 ARN"
  value       = aws_sns_topic.security_alerts.arn
}
