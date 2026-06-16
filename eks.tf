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
    endpoint_private_access = true   # VPC 내부(WorkStation)에서 kubectl 접근
    endpoint_public_access  = false  # SEC: 인터넷에서 EKS API 서버 접근 완전 차단
  }

  access_config {
    authentication_mode = "API"
    # prod 전환 시 false로 변경 후 aws_eks_access_entry로 명시적 RBAC 매핑
    # 주의: false로 변경하면 EKS 클러스터 강제 재생성 발생 (force replacement)
    bootstrap_cluster_creator_admin_permissions = true
  }

  # EKS 컨트롤플레인 감사 로그 — scheduler/controllerManager 추가 (무단 Pod 스케줄링 탐지)
  enabled_cluster_log_types = ["api", "audit", "authenticator", "scheduler", "controllerManager"]

  # SEC: CMK로 K8s Secrets(etcd) 암호화 — AWS Managed Key 대신 고객 통제 키 사용
  encryption_config {
    provider {
      key_arn = aws_kms_key.eks_secrets.arn
    }
    resources = ["secrets"]
  }

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
  # SEC: NetworkPolicy 적용을 위해 반드시 활성화 필요
  # 이 설정 없이는 kubectl apply -f network-policy/*.yaml 해도 아무 효과 없음
  configuration_values = jsonencode({ enableNetworkPolicy = "true" })
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

# ── Launch Template (IMDSv2 강제 + hop_limit=1) ────────────────────────────────
# SEC: SSRF 공격으로 Pod가 노드 EC2 자격증명을 탈취하는 경로 차단
# hop_limit=1 → 컨테이너(Pod)에서 메타데이터 서버(169.254.169.254) 접근 물리적 차단
# http_tokens=required → IMDSv1(GET만으로 응답) 비활성화, PUT 토큰 필수 (Capital One 해킹 동일 경로)

resource "aws_launch_template" "eks_nodes" {
  name_prefix = "${local.project}-eks-node-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"  # IMDSv2 강제
    http_put_response_hop_limit = 1           # Pod -> 메타데이터 서버 접근 차단
    instance_metadata_tags      = "enabled"
  }

  # SEC: Launch Template 사용 시 disk_size는 반드시 여기에 지정 (node group 레벨 불가)
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = "${local.project}-eks-node"
      Service = "eks"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
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

  launch_template {
    id      = aws_launch_template.eks_nodes.id
    version = "$Latest"
  }

  labels = {
    workload = "stable"
  }

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 6
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

# ── Bastion IAM Role → EKS 접근 권한 등록 ────────────────────────────────────
# authentication_mode=API 방식에서는 aws_eks_access_entry로 명시적 등록 필요
# ClusterAdmin: kubectl 전체 권한 (WorkStation 관리자 용도)

resource "aws_eks_access_entry" "bastion" {
  cluster_name  = aws_eks_cluster.fiveline_eks.name
  principal_arn = aws_iam_role.bastion_role.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "bastion" {
  cluster_name  = aws_eks_cluster.fiveline_eks.name
  principal_arn = aws_iam_role.bastion_role.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.bastion]
}

# ── Bastion → EKS API 서버 접근 허용 ──────────────────────────────────────────
# endpoint_public_access=false 설정 후 WorkStation에서 kubectl 사용을 위해 필요
# EKS 클러스터 SG는 AWS가 자동 생성 — 별도 ingress 규칙으로 Bastion 허용

resource "aws_vpc_security_group_ingress_rule" "eks_api_from_bastion" {
  security_group_id            = aws_eks_cluster.fiveline_eks.vpc_config[0].cluster_security_group_id
  description                  = "EKS API server 443 from Bastion WorkStation"
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.bastion_sg.id
}

