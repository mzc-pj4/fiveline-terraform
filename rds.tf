# ── RDS Security Group ────────────────────────────────────────────────────────

resource "aws_security_group" "rds_sg" {
  name        = "${local.project}-rds-sg"
  description = "RDS PostgreSQL security group - allow 5432 from EKS cluster SG and Bastion"
  vpc_id      = aws_vpc.fiveline_vpc.id

  ingress {
    description     = "PostgreSQL from EKS cluster SG (least privilege)"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_eks_cluster.fiveline_eks.vpc_config[0].cluster_security_group_id]
  }

  ingress {
    description     = "PostgreSQL from Bastion WorkStation (DB admin access)"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion_sg.id]
  }

  # SEC: egress 룰 없음 — SG는 stateful이므로 ingress에 대한 응답 트래픽은 자동 허용
  # RDS는 어떤 아웃바운드 연결도 개시하지 않으므로 egress 불필요

  tags = {
    Service = "rds"
    Name    = "${local.project}-rds-sg"
  }
}

# ── RDS Subnet Group ──────────────────────────────────────────────────────────

resource "aws_db_subnet_group" "rds_subnet_group" {
  name        = "${local.project}-rds-subnet-group"
  description = "RDS private subnet group for ap-northeast-2a and 2c"
  subnet_ids  = [aws_subnet.private_rds_2a.id, aws_subnet.private_rds_2c.id]

  tags = {
    Service = "rds"
    Name    = "${local.project}-rds-subnet-group"
  }
}

# ── RDS Master Password ───────────────────────────────────────────────────────
# manage_master_user_password = true는 Read Replica 생성과 호환되지 않음 (AWS 제약)
# random_password로 생성 후 Terraform이 Secrets Manager에 자동 저장

resource "random_password" "rds_master" {
  length  = 20
  special = false  # PostgreSQL 연결 문자열 파싱 오류 방지
}

resource "aws_secretsmanager_secret" "rds_master" {
  name                    = "fiveline-rds-master-password"
  description             = "RDS master password for fiveline PostgreSQL"
  kms_key_id              = aws_kms_key.secrets_manager.arn
  recovery_window_in_days = 0

  tags = {
    Service = "rds"
    Name    = "${local.project}-rds-master-password"
  }
}

resource "aws_secretsmanager_secret_version" "rds_master" {
  secret_id = aws_secretsmanager_secret.rds_master.id
  secret_string = jsonencode({
    username = "fiveline_admin"
    password = random_password.rds_master.result
    host     = aws_db_instance.rds_primary.address
    port     = 5432
    dbname   = "fiveline"
  })
}

# ── RDS Parameter Group (PostgreSQL 16) ──────────────────────────────────────
# 슬로우 쿼리 로깅(PERF-008) + Top SQL 수집(MON-003) + 커넥션 감사

resource "aws_db_parameter_group" "rds_pg16" {
  name        = "${local.project}-rds-pg16"
  family      = "postgres16"
  description = "Fiveline PostgreSQL 16 - slow query logging + pg_stat_statements"

  # PERF-008: 슬로우 쿼리 1초 이상 기록
  parameter {
    name         = "log_min_duration_statement"
    value        = "1000"
    apply_method = "immediate"
  }

  # Top SQL 수집 + PII 감사 — pgaudit 추가 (SEC: 내부자 위협/PIPA 접근 기록 의무)
  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements,auto_explain,pgaudit"
    apply_method = "pending-reboot"
  }

  # pgaudit: 누가 언제 어떤 데이터를 조회/수정했는지 기록 (PIPA 제29조 준수)
  parameter {
    name         = "pgaudit.log"
    value        = "read,write,ddl"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "pgaudit.log_relation"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "auto_explain.log_min_duration"
    value        = "1000"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "pg_stat_statements.track"
    value        = "all"
    apply_method = "pending-reboot"
  }

  # 커넥션 이상 추적
  parameter {
    name         = "log_connections"
    value        = "1"
    apply_method = "immediate"
  }

  parameter {
    name         = "log_disconnections"
    value        = "1"
    apply_method = "immediate"
  }

  tags = {
    Service = "rds"
    Name    = "${local.project}-rds-pg16"
  }
}

# ── RDS Enhanced Monitoring IAM Role ─────────────────────────────────────────
# OS 레벨 지표(CPU, 메모리, 파일시스템)를 CloudWatch에 1분 간격으로 전송 (MON-003)

resource "aws_iam_role" "rds_monitoring_role" {
  name = "${local.project}-rds-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Service = "rds"
    Name    = "${local.project}-rds-monitoring-role"
  }
}

resource "aws_iam_role_policy_attachment" "rds_monitoring_attach" {
  role       = aws_iam_role.rds_monitoring_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ── RDS Primary Instance (Multi-AZ Standby — HA) ─────────────────────────────

resource "aws_db_instance" "rds_primary" {
  identifier     = "${local.project}-rds-primary"
  engine         = "postgres"
  engine_version = "16"
  instance_class = "db.t3.medium"
  # Multi-AZ 활성화 시 availability_zone 지정 불가 — AWS가 자동으로 AZ 배치

  db_name  = "fiveline"
  username = "fiveline_admin"
  password = random_password.rds_master.result

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.rds.arn  # SEC: CMK로 스토리지/스냅샷 암호화

  # Multi-AZ Standby — Primary 장애 시 자동 페일오버 (RPO≈0, HA 목적)
  multi_az = true

  db_subnet_group_name   = aws_db_subnet_group.rds_subnet_group.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]

  # 파라미터 그룹 — 슬로우 쿼리 로깅 + pg_stat_statements (PERF-008)
  parameter_group_name = aws_db_parameter_group.rds_pg16.name

  # Enhanced Monitoring — OS 레벨 지표 60초 간격 전송 (MON-003)
  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_monitoring_role.arn

  # Performance Insights — Top SQL 분석, 무료 7일 보존 (MON-003, PERF-008)
  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  # TLS CA 인증서 명시 — 앱 sslmode=require와 함께 SEC-011 충족 (PostgreSQL 16 권장)
  ca_cert_identifier = "rds-ca-rsa2048-g1"

  # 마이너 버전 자동 업그레이드 — 유지보수 창(Mon 04:00-05:00) 내 적용
  auto_minor_version_upgrade = true

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  deletion_protection       = true   # SEC: 랜섬웨어/실수로 인한 DB 삭제 방지
  skip_final_snapshot       = false  # SEC: 삭제 전 최종 스냅샷 강제 생성
  final_snapshot_identifier = "${local.project}-rds-primary-final"
  apply_immediately         = true

  tags = {
    Service = "rds"
    Name    = "${local.project}-rds-primary"
  }
}

# ── RDS Read Replica C (2c — EKS 2c Pod 조회 + 데이터 파이프라인 격리) ────────

resource "aws_db_instance" "rds_replica" {
  identifier          = "${local.project}-rds-replica-c"
  replicate_source_db = aws_db_instance.rds_primary.arn
  instance_class      = "db.t3.medium"
  availability_zone   = "ap-northeast-2c"

  db_subnet_group_name   = aws_db_subnet_group.rds_subnet_group.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]

  # Parameter Group — Primary와 동일한 슬로우 쿼리 설정 적용
  parameter_group_name = aws_db_parameter_group.rds_pg16.name

  # Primary 암호화 상속 명시 (tfsec/Checkov CICD-009 대응)
  storage_encrypted = true

  # Performance Insights — Read 트래픽 슬로우 쿼리 추적
  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  # Enhanced Monitoring
  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_monitoring_role.arn

  ca_cert_identifier = "rds-ca-rsa2048-g1"

  backup_retention_period = 0
  skip_final_snapshot     = true
  apply_immediately       = true

  tags = {
    Service = "rds"
    Name    = "${local.project}-rds-replica-c"
  }
}

# ── RDS Read Replica A (2a — EKS 2a Pod 조회, Zone Affinity) ─────────────────
# Primary(2a)와 동일 AZ 배치 → Cross-AZ 비용 제거, 2c 전체 장애 시 Read 생존

resource "aws_db_instance" "rds_replica_a" {
  identifier          = "${local.project}-rds-replica-a"
  replicate_source_db = aws_db_instance.rds_primary.arn
  instance_class      = "db.t3.medium"
  availability_zone   = "ap-northeast-2a"

  db_subnet_group_name   = aws_db_subnet_group.rds_subnet_group.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]

  parameter_group_name = aws_db_parameter_group.rds_pg16.name

  storage_encrypted = true

  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_monitoring_role.arn

  ca_cert_identifier = "rds-ca-rsa2048-g1"

  backup_retention_period = 0
  skip_final_snapshot     = true
  apply_immediately       = true

  # rds_replica(2c)와 동시 생성 시 Primary가 modifying 상태가 되어 실패
  # 순차 생성으로 강제
  depends_on = [aws_db_instance.rds_replica]

  tags = {
    Service = "rds"
    Name    = "${local.project}-rds-replica-a"
  }
}
