# ── ElastiCache Security Group ────────────────────────────────────────────────

resource "aws_security_group" "elasticache_sg" {
  name        = "${local.project}-elasticache-sg"
  description = "ElastiCache Redis security group - allow 6379 from EKS nodes and Bastion"
  vpc_id      = aws_vpc.fiveline_vpc.id

  ingress {
    description     = "Redis from EKS cluster SG (least privilege)"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_eks_cluster.fiveline_eks.vpc_config[0].cluster_security_group_id]
  }

  ingress {
    description     = "Redis from Bastion WorkStation (cache admin access)"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion_sg.id]
  }

  # SEC: egress 룰 없음 — SG는 stateful이므로 ingress에 대한 응답 트래픽은 자동 허용
  # ElastiCache는 어떤 아웃바운드 연결도 개시하지 않으므로 egress 불필요

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

# Redis AUTH 토큰 — Terraform이 생성, Secrets Manager에도 별도 등록 권장
resource "random_password" "redis_auth_token" {
  length  = 32
  special = false  # ElastiCache AUTH 토큰 특수문자 제한 (@, ",", / 불가)
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

  # SEC: 저장/전송 암호화 + AUTH 토큰 (transit_encryption=true 필수)
  # auth_token 없으면 EKS 내 어떤 Pod이든 6379 무인증 접근 가능 — SEC-012
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = random_password.redis_auth_token.result

  port = 6379

  parameter_group_name = aws_elasticache_parameter_group.cache_params.name
  subnet_group_name    = aws_elasticache_subnet_group.cache_subnet_group.name
  security_group_ids   = [aws_security_group.elasticache_sg.id]

  # 유지보수 창 — RDS(Mon 04:00-05:00)와 겹치지 않게 분리 (AVAIL-010)
  maintenance_window = "tue:03:00-tue:04:00"

  # 스냅샷 보존 — RPO < 5분(IR-002) 대응, 최소 1일 설정 (교육용, prod는 7 권장)
  snapshot_retention_limit = 1
  snapshot_window          = "02:00-03:00"

  apply_immediately = true

  tags = {
    Service = "cache"
    Name    = "${local.project}-redis"
  }
}
