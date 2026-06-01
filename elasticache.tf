# ── ElastiCache Security Group ────────────────────────────────────────────────

resource "aws_security_group" "elasticache_sg" {
  name        = "${local.project}-elasticache-sg"
  description = "ElastiCache Redis security group - allow 6379 from EKS nodes"
  vpc_id      = aws_vpc.fiveline_vpc.id

  ingress {
    description     = "Redis from EKS cluster SG (least privilege)"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_eks_cluster.fiveline_eks.vpc_config[0].cluster_security_group_id]
  }

  tags = {
    Service = "cache"
    Name    = "${local.project}-elasticache-sg"
  }
}

# ── ElastiCache Subnet Group ──────────────────────────────────────────────────

resource "aws_elasticache_subnet_group" "cache_subnet_group" {
  name        = "${local.project}-cache-subnet-group"
  description = "ElastiCache private subnet group for ap-northeast-2a and 2c"
  
  subnet_ids  = [aws_subnet.private_cache_2a.id, aws_subnet.private_cache_2c.id]

  tags = {
    Service = "cache"
    Name    = "${local.project}-cache-subnet-group"
  }
}

# ── ElastiCache Parameter Group ───────────────────────────────────────────────

resource "aws_elasticache_parameter_group" "cache_params" {
  name        = "${local.project}-cache-params"
  description = "Fiveline Redis 7 parameter group using default values" 
  family      = "redis7"

  tags = {
    Service = "cache"
    Name    = "${local.project}-cache-params"
  }
}

# ── ElastiCache Replication Group (Redis Cluster) ─────────────────────────────

resource "aws_elasticache_replication_group" "redis_cluster" {
  replication_group_id = "${local.project}-redis"
  description          = "fiveline redis cluster"

  # 테스트 환경 최소 사양
  node_type = "cache.t3.micro"

  # Multi-AZ 구성 — Primary + Replica 각 1개
  num_cache_clusters         = 2
  automatic_failover_enabled = true

  # 보안 설정 — 저장/전송 데이터 암호화
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  port = 6379

  parameter_group_name = aws_elasticache_parameter_group.cache_params.name
  subnet_group_name    = aws_elasticache_subnet_group.cache_subnet_group.name
  security_group_ids   = [aws_security_group.elasticache_sg.id]

  # 유지 보수 설정
  apply_immediately = true

  tags = {
    Service = "cache"
    Name    = "${local.project}-redis"
  }
}