module "network" {
  source = "../../modules/network"

  project_name = var.project_name
  environment  = var.environment
  vpc_cidr     = var.vpc_cidr
  cluster_name = var.cluster_name
}

module "eks" {
  source = "../../modules/eks"

  project_name             = var.project_name
  environment              = var.environment
  cluster_name             = var.cluster_name
  kubernetes_version       = var.kubernetes_version
  vpc_id                   = module.network.vpc_id
  private_app_subnet_ids   = module.network.private_app_subnet_ids
  node_group_name          = var.node_group_name
  node_instance_types      = var.node_instance_types
  node_desired_size        = var.node_desired_size
  node_min_size            = var.node_min_size
  node_max_size            = var.node_max_size
  node_disk_size           = var.node_disk_size
  enable_cluster_log_types = var.enable_cluster_log_types
  log_retention_in_days    = var.log_retention_in_days
}

module "rds" {
  source = "../../modules/rds"

  project_name            = var.project_name
  environment             = var.environment
  db_identifier           = var.db_identifier
  db_name                 = var.db_name
  db_username             = var.db_username
  db_password             = var.db_password
  db_instance_class       = var.db_instance_class
  db_allocated_storage    = var.db_allocated_storage
  db_engine_version       = var.db_engine_version
  multi_az                = var.multi_az
  backup_retention_period = var.backup_retention_period
  skip_final_snapshot     = var.skip_final_snapshot
  deletion_protection     = var.deletion_protection
  vpc_id                  = module.network.vpc_id
  private_db_subnet_ids   = module.network.private_db_subnet_ids
  app_subnet_cidrs        = var.app_subnet_cidrs
}
