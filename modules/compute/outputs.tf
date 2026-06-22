output "eks_cluster_name" {
  description = "EKS 클러스터 이름"
  value       = aws_eks_cluster.fiveline_eks.name
}

output "eks_cluster_endpoint" {
  description = "EKS API 서버 엔드포인트"
  value       = aws_eks_cluster.fiveline_eks.endpoint
}

output "eks_cluster_sg_id" {
  description = "EKS 클러스터 보안 그룹 ID (database 모듈 ingress 허용용)"
  value       = aws_eks_cluster.fiveline_eks.vpc_config[0].cluster_security_group_id
}

output "workstation_sg_id" {
  description = "Workstation 보안 그룹 ID (database 모듈 egress 규칙, RDS/ElastiCache ingress 허용용)"
  value       = aws_security_group.bastion_sg.id
}

output "bastion_role_arn" {
  description = "Workstation IAM Role ARN"
  value       = aws_iam_role.bastion_role.arn
}

output "bastion_instance_id" {
  description = "Workstation EC2 인스턴스 ID"
  value       = aws_instance.bastion.id
}

output "oidc_provider_arn" {
  description = "EKS OIDC Provider ARN (jihoo/lhj IRSA용)"
  value       = aws_iam_openid_connect_provider.eks_oidc.arn
}

output "oidc_provider_url" {
  description = "EKS OIDC Provider URL (https:// 포함)"
  value       = aws_eks_cluster.fiveline_eks.identity[0].oidc[0].issuer
}

output "lb_controller_role_arn" {
  description = "AWS Load Balancer Controller IAM Role ARN"
  value       = aws_iam_role.lb_controller.arn
}

output "eks_node_role_arn" {
  description = "EKS 노드 IAM Role ARN (cicd/observability 모듈용)"
  value       = aws_iam_role.eks_node_role.arn
}
