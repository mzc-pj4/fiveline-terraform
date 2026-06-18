output "ecr_repository_urls" {
  description = "서비스별 ECR 리포지터리 URL map (key = service name)"
  value       = { for k, v in aws_ecr_repository.services : k => v.repository_url }
}

output "ecr_registry_id" {
  description = "ECR 레지스트리 ID (AWS 계정 ID)"
  value       = values(aws_ecr_repository.services)[0].registry_id
}

output "github_actions_role_arn" {
  description = "IAM Role ARN for GitHub Actions — workflow의 AWS_ROLE_ARN으로 사용"
  value       = aws_iam_role.github_actions.arn
}
