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

output "rds_replica_endpoint" {
  description = "RDS Read Replica 엔드포인트 (host:port)"
  value       = aws_db_instance.rds_replica.endpoint
}

output "rds_master_user_secret_arn" {
  description = "RDS 마스터 계정 패스워드가 저장된 Secrets Manager ARN"
  value       = try(aws_db_instance.rds_primary.master_user_secret[0].secret_arn, null)
}
