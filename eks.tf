# ── EKS Cluster ───────────────────────────────────────────────────────────────

resource "aws_eks_cluster" "fiveline_eks" {
  name     = local.cluster_name
  role_arn = aws_iam_role.eks_cluster_role.arn
  version  = var.k8s_version

  vpc_config {
    subnet_ids = [
      aws_subnet.private_eks_2a.id,
      aws_subnet.private_eks_2c.id,
    ]
    endpoint_private_access = true
    endpoint_public_access  = true
    # prod 전환 시 아래 주석 해제 후 실제 운영자 IP 대역으로 제한
    # public_access_cidrs = ["<운영자_IP>/32", "<CI_러너_IP>/32"]
  }

  access_config {
    authentication_mode = "API"
    # prod 전환 시 false로 변경 후 aws_eks_access_entry로 명시적 RBAC 매핑
    bootstrap_cluster_creator_admin_permissions = true
  }

  # EKS 컨트롤플레인 감사 로그 (SEC-052, Must)
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  tags = {
    Service = "eks"
    Name    = local.cluster_name
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
  ]
}

# ── Add-ons ───────────────────────────────────────────────────────────────────

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.fiveline_eks.name
  addon_name   = "vpc-cni"
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.fiveline_eks.name
  addon_name   = "kube-proxy"
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.fiveline_eks.name
  addon_name   = "coredns"

  depends_on = [aws_eks_node_group.ondemand]
}

resource "aws_eks_addon" "pod_identity" {
  cluster_name = aws_eks_cluster.fiveline_eks.name
  addon_name   = "eks-pod-identity-agent"
}

resource "aws_eks_addon" "metrics_server" {
  cluster_name = aws_eks_cluster.fiveline_eks.name
  addon_name   = "metrics-server"

  depends_on = [aws_eks_node_group.ondemand]
}

# ── Node Group: On-Demand ──────────────────────────────────────────────────────

resource "aws_eks_node_group" "ondemand" {
  cluster_name    = aws_eks_cluster.fiveline_eks.name
  node_group_name = "${local.project}-ondemand-ng"
  node_role_arn   = aws_iam_role.eks_node_role.arn

  subnet_ids = [
    aws_subnet.private_eks_2a.id,
    aws_subnet.private_eks_2c.id,
  ]

  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = "ON_DEMAND"
  instance_types = ["t3.medium"]
  disk_size      = 20

  labels = {
    workload = "stable"
  }

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 4
  }

  update_config {
    max_unavailable = 1
  }

  tags = {
    Service                                                   = "eks"
    Name                                                      = "${local.project}-ondemand-ng"
    "k8s.io/cluster-autoscaler/enabled"                       = "true"
    "k8s.io/cluster-autoscaler/${aws_eks_cluster.fiveline_eks.name}" = "owned"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_readonly,
    aws_iam_role_policy_attachment.eks_ssm,
  ]
}

