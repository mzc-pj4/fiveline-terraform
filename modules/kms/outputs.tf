output "eks_secrets_arn" {
  value = aws_kms_key.eks_secrets.arn
}

output "rds_arn" {
  value = aws_kms_key.rds.arn
}

output "secrets_manager_arn" {
  value = aws_kms_key.secrets_manager.arn
}

output "account_id" {
  value = data.aws_caller_identity.current.account_id
}
