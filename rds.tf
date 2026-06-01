# ── RDS Security Group ────────────────────────────────────────────────────────

resource "aws_security_group" "rds_sg" {
  name        = "${local.project}-rds-sg"
  description = "RDS PostgreSQL security group - allow 5432 from EKS cluster SG"
  vpc_id      = aws_vpc.fiveline_vpc.id

  ingress {
    description     = "PostgreSQL from EKS cluster SG (least privilege)"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_eks_cluster.fiveline_eks.vpc_config[0].cluster_security_group_id]
  }

  egress {
    description = "Allow internal VPC traffic only (least privilege)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.10.0.0/16"]
  }

  tags = {
    Service = "rds"
    Name    = "${local.project}-rds-sg"
  }
}

# ── RDS Subnet Group ──────────────────────────────────────────────────────────

resource "aws_db_subnet_group" "rds_subnet_group" {
  name        = "${local.project}-rds-subnet-group"
  description = "RDS 전용 프라이빗 서브넷 그룹 (ap-northeast-2a/2c)"
  subnet_ids  = [
    aws_subnet.private_rds_2a.id,
    aws_subnet.private_rds_2c.id,
  ]

  tags = {
    Service = "rds"
    Name    = "${local.project}-rds-subnet-group"
  }
}

# ── RDS Primary Instance (Multi-AZ Standby — HA) ─────────────────────────────

resource "aws_db_instance" "rds_primary" {
  identifier     = "${local.project}-rds-primary"
  engine         = "postgres"
  engine_version = "16.3"
  instance_class = "db.t3.medium"

  db_name  = "fiveline"
  username = "fiveline_admin"

  # 비밀번호를 Secrets Manager로 자동 관리 (KMS 암호화)
  manage_master_user_password = true

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  # Multi-AZ Standby — Primary 장애 시 자동 페일오버 (RPO≈0, HA 목적)
  multi_az = true

  db_subnet_group_name   = aws_db_subnet_group.rds_subnet_group.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  deletion_protection = false  # 교육용: 삭제 방지 비활성
  skip_final_snapshot = true   # 교육용: 최종 스냅샷 생략
  apply_immediately   = true

  tags = {
    Service = "rds"
    Name    = "${local.project}-rds-primary"
  }
}

# ── RDS Read Replica (읽기 분산 — 분석 쿼리 분리) ────────────────────────────

resource "aws_db_instance" "rds_replica" {
  identifier          = "${local.project}-rds-replica"
  replicate_source_db = aws_db_instance.rds_primary.identifier
  instance_class      = "db.t3.medium"
  availability_zone   = "ap-northeast-2c"

  db_subnet_group_name   = aws_db_subnet_group.rds_subnet_group.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]

  # 분석/조회 트래픽 분리용 — 독립 백업 비활성
  backup_retention_period = 0
  skip_final_snapshot     = true
  apply_immediately       = true

  tags = {
    Service = "rds"
    Name    = "${local.project}-rds-replica"
  }
}
