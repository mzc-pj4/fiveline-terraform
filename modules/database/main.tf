locals {
  project = "fiveline"
}

# ════════════════════════════════════════════════════════════════════════════
# RDS Security Group
# ════════════════════════════════════════════════════════════════════════════

resource "aws_security_group" "rds_sg" {
  name        = "${local.project}-rds-sg"
  description = "RDS PostgreSQL security group - allow 5432 from EKS cluster SG and Workstation"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from EKS cluster SG (least privilege)"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.eks_cluster_sg_id]
  }

  ingress {
    description     = "PostgreSQL from Workstation (DB admin access)"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.workstation_sg_id]
  }

  tags = {
    Service = "rds"
    Name    = "${local.project}-rds-sg"
  }

  lifecycle {
    ignore_changes = [description]
  }
}

# ════════════════════════════════════════════════════════════════════════════
# ElastiCache Security Group
# ════════════════════════════════════════════════════════════════════════════

resource "aws_security_group" "elasticache_sg" {
  name        = "${local.project}-elasticache-sg"
  description = "ElastiCache Redis security group - allow 6379 from EKS nodes and Workstation"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Redis from EKS cluster SG (least privilege)"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [var.eks_cluster_sg_id]
  }

  ingress {
    description     = "Redis from Workstation (cache admin access)"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [var.workstation_sg_id]
  }

  tags = {
    Service = "cache"
    Name    = "${local.project}-elasticache-sg"
  }

  lifecycle {
    ignore_changes = [description]
  }
}

# ════════════════════════════════════════════════════════════════════════════
# RDS Subnet Group + Parameter Group
# ════════════════════════════════════════════════════════════════════════════

resource "aws_db_subnet_group" "rds_subnet_group" {
  name        = "${local.project}-rds-subnet-group"
  description = "RDS private subnet group for ap-northeast-2a and 2c"
  subnet_ids  = var.private_rds_subnet_ids

  tags = {
    Service = "rds"
    Name    = "${local.project}-rds-subnet-group"
  }
}

resource "aws_db_parameter_group" "rds_pg16" {
  name        = "${local.project}-rds-pg16"
  family      = "postgres16"
  description = "Fiveline PostgreSQL 16 - slow query logging + pg_stat_statements"

  parameter {
    name         = "log_min_duration_statement"
    value        = "1000"
    apply_method = "immediate"
  }

  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements,auto_explain,pgaudit"
    apply_method = "pending-reboot"
  }

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

# ════════════════════════════════════════════════════════════════════════════
# RDS Enhanced Monitoring IAM Role
# ════════════════════════════════════════════════════════════════════════════

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

# ════════════════════════════════════════════════════════════════════════════
# RDS Password → Secrets Manager
# ════════════════════════════════════════════════════════════════════════════

resource "random_password" "rds_master" {
  length  = 20
  special = false
}

resource "aws_secretsmanager_secret" "rds_master" {
  name                    = "fiveline-rds-master-password"
  description             = "RDS master password for fiveline PostgreSQL"
  kms_key_id              = var.kms_secrets_arn
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

# ════════════════════════════════════════════════════════════════════════════
# RDS Instances
# ════════════════════════════════════════════════════════════════════════════

resource "aws_db_instance" "rds_primary" {
  identifier     = "${local.project}-rds-primary"
  engine         = "postgres"
  engine_version = "16"
  instance_class = "db.t3.medium"

  db_name  = "fiveline"
  username = "fiveline_admin"
  password = random_password.rds_master.result

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_rds_arn

  multi_az = true

  db_subnet_group_name   = aws_db_subnet_group.rds_subnet_group.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]

  parameter_group_name = aws_db_parameter_group.rds_pg16.name

  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_monitoring_role.arn

  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  ca_cert_identifier = "rds-ca-rsa2048-g1"

  auto_minor_version_upgrade = true

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.project}-rds-primary-final"
  apply_immediately         = true

  tags = {
    Service = "rds"
    Name    = "${local.project}-rds-primary"
  }
}

resource "aws_db_instance" "rds_replica" {
  identifier          = "${local.project}-rds-replica-c"
  replicate_source_db = aws_db_instance.rds_primary.arn
  instance_class      = "db.t3.medium"
  availability_zone   = "ap-northeast-2c"

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

  tags = {
    Service = "rds"
    Name    = "${local.project}-rds-replica-c"
  }
}

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

  depends_on = [aws_db_instance.rds_replica]

  tags = {
    Service = "rds"
    Name    = "${local.project}-rds-replica-a"
  }
}

# ════════════════════════════════════════════════════════════════════════════
# Workstation → RDS/Cache Egress 규칙
# (순환 의존성 해소: bastion_sg는 compute에, rds_sg/elasticache_sg는 database에 있으므로
#  이 규칙을 database 모듈에서 var.workstation_sg_id를 써서 관리)
# ════════════════════════════════════════════════════════════════════════════

resource "aws_vpc_security_group_egress_rule" "bastion_to_rds" {
  security_group_id            = var.workstation_sg_id
  description                  = "PostgreSQL outbound to RDS SG (identity-based trust)"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.rds_sg.id
}

resource "aws_vpc_security_group_egress_rule" "bastion_to_cache" {
  security_group_id            = var.workstation_sg_id
  description                  = "Redis outbound to ElastiCache SG (identity-based trust)"
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.elasticache_sg.id
}

# ════════════════════════════════════════════════════════════════════════════
# ElastiCache Subnet Group + Parameter Group
# ════════════════════════════════════════════════════════════════════════════

resource "aws_elasticache_subnet_group" "cache_subnet_group" {
  name        = "${local.project}-cache-subnet-group"
  description = "ElastiCache private subnet group for ap-northeast-2a and 2c"
  subnet_ids  = var.private_cache_subnet_ids

  tags = {
    Service = "cache"
    Name    = "${local.project}-cache-subnet-group"
  }
}

resource "aws_elasticache_parameter_group" "cache_params" {
  name        = "${local.project}-cache-params"
  description = "Fiveline Redis 7 parameter group using default values"
  family      = "redis7"

  tags = {
    Service = "cache"
    Name    = "${local.project}-cache-params"
  }
}

# ════════════════════════════════════════════════════════════════════════════
# ElastiCache Redis Cluster
# ════════════════════════════════════════════════════════════════════════════

resource "random_password" "redis_auth_token" {
  length  = 32
  special = false
}

resource "aws_elasticache_replication_group" "redis_cluster" {
  replication_group_id = "${local.project}-redis"
  description          = "fiveline redis cluster"

  node_type = "cache.t3.micro"

  num_cache_clusters         = 2
  automatic_failover_enabled = true

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = random_password.redis_auth_token.result

  port = 6379

  parameter_group_name = aws_elasticache_parameter_group.cache_params.name
  subnet_group_name    = aws_elasticache_subnet_group.cache_subnet_group.name
  security_group_ids   = [aws_security_group.elasticache_sg.id]

  maintenance_window = "tue:03:00-tue:04:00"

  snapshot_retention_limit = 1
  snapshot_window          = "02:00-03:00"

  apply_immediately = true

  tags = {
    Service = "cache"
    Name    = "${local.project}-redis"
  }
}
