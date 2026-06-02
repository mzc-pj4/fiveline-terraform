output "vpc_id" {
  value = aws_vpc.fiveline_vpc.id
}

output "public_subnet_ids" {
  value = [aws_subnet.public_2a.id, aws_subnet.public_2c.id]
}

output "private_eks_subnet_ids" {
  value = [aws_subnet.private_eks_2a.id, aws_subnet.private_eks_2c.id]
}

output "private_rds_subnet_ids" {
  value = [aws_subnet.private_rds_2a.id, aws_subnet.private_rds_2c.id]
}

output "private_cache_subnet_ids" {
  value = [aws_subnet.private_cache_2a.id, aws_subnet.private_cache_2c.id]
}

output "eks_cluster_name" {
  value = aws_eks_cluster.fiveline_eks.name
}

output "eks_cluster_endpoint" {
  value = aws_eks_cluster.fiveline_eks.endpoint
}

output "eks_ondemand_node_group_name" {
  value = aws_eks_node_group.ondemand.node_group_name
}

output "eks_spot_node_group_name" {
  value = aws_eks_node_group.spot.node_group_name
}

# ── ElastiCache Outputs ───────────────────────────────────────────────────────

output "elasticache_primary_endpoint_address" {
  description = "ElastiCache Redis Primary 엔드포인트 주소"
  value       = aws_elasticache_replication_group.redis_cluster.primary_endpoint_address
}

output "elasticache_reader_endpoint_address" {
  description = "ElastiCache Redis Reader 엔드포인트 주소 (읽기 전용)"
  value       = aws_elasticache_replication_group.redis_cluster.reader_endpoint_address
}

# ── RDS Outputs ───────────────────────────────────────────────────────────────

output "rds_primary_endpoint" {
  description = "RDS Primary 인스턴스 엔드포인트 (host:port)"
  value       = aws_db_instance.rds_primary.endpoint
}

output "rds_replica_c_endpoint" {
  description = "RDS Read Replica C (ap-northeast-2c) 엔드포인트 — EKS 2c Pod 조회, 데이터 파이프라인"
  value       = aws_db_instance.rds_replica.endpoint
}

output "rds_replica_a_endpoint" {
  description = "RDS Read Replica A (ap-northeast-2a) 엔드포인트 — EKS 2a Pod 조회, Zone Affinity"
  value       = aws_db_instance.rds_replica_a.endpoint
}

output "rds_master_username" {
  description = "RDS 마스터 계정명"
  value       = aws_db_instance.rds_primary.username
}

# ── CloudFront / S3 Outputs ───────────────────────────────────────────────────

output "cloudfront_domain_name" {
  description = "CloudFront 배포 도메인 (https://<id>.cloudfront.net) — 프론트엔드 접속 URL"
  value       = aws_cloudfront_distribution.main.domain_name
}

output "cloudfront_distribution_id" {
  description = "CloudFront 배포 ID — 캐시 무효화(invalidation) 및 WAF 연결 시 사용"
  value       = aws_cloudfront_distribution.main.id
}

output "s3_frontend_bucket" {
  description = "프론트엔드 정적 자산 S3 버킷명"
  value       = aws_s3_bucket.frontend.bucket
}

output "s3_frontend_bucket_arn" {
  description = "프론트엔드 S3 버킷 ARN"
  value       = aws_s3_bucket.frontend.arn
}

# ── IAM Outputs ───────────────────────────────────────────────────────────────

output "lb_controller_role_arn" {
  description = "AWS Load Balancer Controller IAM Role ARN — Helm chart values.serviceAccount.annotations에 주입"
  value       = aws_iam_role.lb_controller.arn
}

output "eks_oidc_provider_arn" {
  description = "EKS OIDC Provider ARN — 추가 IRSA 생성 시 참조"
  value       = aws_iam_openid_connect_provider.eks_oidc.arn
}

# ── Bastion Outputs ───────────────────────────────────────────────────────────

output "bastion_instance_id" {
  description = "Bastion WorkStation EC2 인스턴스 ID — SSM 접속: aws ssm start-session --target <id>"
  value       = aws_instance.bastion.id
}
