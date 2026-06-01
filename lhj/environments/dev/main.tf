locals {
  cluster_name = "${var.project_name}-${var.environment}-eks"
}

module "network" {
  source       = "../../modules/network"
  project_name = var.project_name
  environment  = var.environment
  vpc_cidr     = var.vpc_cidr
  cluster_name = local.cluster_name
}

module "ecr" {
  source        = "../../modules/ecr"
  project_name  = var.project_name
  service_names = ["user-service", "product-service", "order-service"]
}

module "eks" {
  source = "../../modules/eks"

  cluster_name       = local.cluster_name
  cluster_version    = var.eks_cluster_version
  vpc_id             = module.network.vpc_id
  subnet_ids         = module.network.private_eks_subnet_ids
  node_instance_type = var.eks_node_instance_type
  node_desired_size  = var.eks_node_desired_size
  node_min_size      = var.eks_node_min_size
  node_max_size      = var.eks_node_max_size
}

module "github_actions_oidc" {
  source       = "../../modules/github-actions-oidc"
  project_name = var.project_name
  environment  = var.environment
  github_org   = "mzc-pj4"
  github_repo  = "fiveline-backend"
  ecr_prefix   = "fiveline-ecr"
}

module "rds" {
  source = "../../modules/rds"

  project_name        = var.project_name
  environment         = var.environment
  vpc_id              = module.network.vpc_id
  subnet_ids          = module.network.private_rds_subnet_ids
  eks_node_sg_id      = module.eks.node_security_group_id
  db_password         = var.db_password
  instance_class      = var.rds_instance_class
  multi_az            = var.rds_multi_az
  deletion_protection = false
}
