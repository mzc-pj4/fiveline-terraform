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
  project_name  = "fiveline-ecr"
  service_names = ["user-service", "product-service", "order-service", "frontend", "platform"]
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
  github_repos = ["fiveline-backend", "fiveline-frontend"]
  ecr_prefix   = "fiveline-ecr"
  # platform repo는 김지호(데이터 파이프라인) Role에서만 push 가능하도록 제외
  ecr_repositories = ["user-service", "product-service", "order-service", "frontend", "admin-service", "tools/python"]
  # bedrock invoke policy added for AIOps
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

resource "aws_iam_role_policy" "admin_service_sa_dynamodb" {
  name = "dynamodb-aiops-read-policy"
  role = "fiveline-admin-service-sa-role"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "DynamoDBRead"
      Effect = "Allow"
      Action = [
        "dynamodb:Query",
        "dynamodb:Scan",
        "dynamodb:GetItem",
      ]
      Resource = "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/fiveline-${var.environment}-aiops-canary-logs"
    }]
  })
}

data "aws_caller_identity" "current" {}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.3.11"
  namespace        = "argocd"
  create_namespace = true

  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  depends_on = [module.eks]
}

resource "helm_release" "argocd_notifications" {
  name             = "argocd-notifications"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argocd-notifications"
  version          = "1.8.1"
  namespace        = "argocd"
  create_namespace = false

  depends_on = [helm_release.argocd]
}

# IAM Role for ArgoCD Image Updater (ECR read access via IRSA)
resource "aws_iam_role" "argocd_image_updater" {
  name = "fiveline-${var.environment}-argocd-image-updater"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = module.eks.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${module.eks.oidc_provider_url}:sub" = "system:serviceaccount:argocd:argocd-image-updater"
          "${module.eks.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "argocd_image_updater_ecr" {
  name = "ecr-read-policy"
  role = aws_iam_role.argocd_image_updater.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:DescribeImages",
        "ecr:ListImages",
        "ecr:BatchGetImage",
      ]
      Resource = "*"
    }]
  })
}

resource "helm_release" "argocd_image_updater" {
  name             = "argocd-image-updater"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argocd-image-updater"
  version          = "0.11.0"
  namespace        = "argocd"
  create_namespace = false

  set {
    name  = "config.registries[0].name"
    value = "ECR"
  }
  set {
    name  = "config.registries[0].prefix"
    value = "089955620282.dkr.ecr.ap-northeast-2.amazonaws.com"
  }
  set {
    name  = "config.registries[0].api_url"
    value = "https://089955620282.dkr.ecr.ap-northeast-2.amazonaws.com"
  }
  set {
    name  = "config.registries[0].credentials"
    value = "ext:/scripts/auth1.sh"
  }
  set {
    name  = "config.registries[0].credsexpire"
    value = "10h"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.argocd_image_updater.arn
  }

  depends_on = [helm_release.argocd, aws_iam_role_policy.argocd_image_updater_ecr]
}
