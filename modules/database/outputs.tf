output "rds_primary_address" {
  description = "RDS Primary 엔드포인트 (Write)"
  value       = aws_db_instance.rds_primary.address
}

output "rds_replica_address" {
  description = "RDS Read Replica 엔드포인트 (2c)"
  value       = aws_db_instance.rds_replica.address
}

output "rds_replica_a_address" {
  description = "RDS Read Replica 엔드포인트 (2a)"
  value       = aws_db_instance.rds_replica_a.address
}

output "redis_endpoint" {
  description = "ElastiCache Redis Primary 엔드포인트"
  value       = aws_elasticache_replication_group.redis_cluster.primary_endpoint_address
}

output "redis_replication_group_id" {
  description = "ElastiCache Replication Group ID (observability/hsh 모듈용)"
  value       = aws_elasticache_replication_group.redis_cluster.replication_group_id
}

output "rds_sg_id" {
  description = "RDS 보안 그룹 ID (observability 모니터링용)"
  value       = aws_security_group.rds_sg.id
}

output "rds_primary_identifier" {
  description = "RDS Primary 인스턴스 식별자 (observability/hsh CloudWatch 알람용)"
  value       = aws_db_instance.rds_primary.identifier
}
