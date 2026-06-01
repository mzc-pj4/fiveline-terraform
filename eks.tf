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

# ── Node Group: On-Demand (베이스라인 — 시스템 + 서비스 워크로드) ────────────────
# 비율 목표: On-Demand 70% : Spot 30%
# 서비스 Pod는 On-Demand에 우선 스케줄, On-Demand 포화 시 Spot으로 오버플로
# 피크 트래픽 시 Spot 가용성이 낮아지는 역설을 고려해 On-Demand를 기반으로 확보

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
    Service = "eks"
    Name    = "${local.project}-ondemand-ng"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_readonly,
    aws_iam_role_policy_attachment.eks_ssm,
  ]
}

# ── Node Group: Spot (오버플로 버퍼 — On-Demand 포화 시 확장) ─────────────────
# 평시 0대, On-Demand 포화 시 최대 2대까지 확장
# Spot 비율 상한 30% 유지 목적 (On-Demand 4대 : Spot 2대 = 67:33)
# prod 전환 시 인스턴스 타입 다양화(t3/t3a/m5 계열 혼합) 권장

resource "aws_eks_node_group" "spot" {
  cluster_name    = aws_eks_cluster.fiveline_eks.name
  node_group_name = "${local.project}-spot-ng"
  node_role_arn   = aws_iam_role.eks_node_role.arn

  subnet_ids = [
    aws_subnet.private_eks_2a.id,
    aws_subnet.private_eks_2c.id,
  ]

  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = "SPOT"
  instance_types = ["t3.medium", "t3a.medium"]
  disk_size      = 20

  labels = {
    workload = "spot"
  }

  taint {
    key    = "spot"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  scaling_config {
    desired_size = 0
    min_size     = 0
    max_size     = 2
  }

  update_config {
    max_unavailable_percentage = 50
  }

  tags = {
    Service = "eks"
    Name    = "${local.project}-spot-ng"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_readonly,
    aws_iam_role_policy_attachment.eks_ssm,
  ]
}
