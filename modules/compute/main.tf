locals {
  project      = "fiveline"
  cluster_name = "fiveline-eks"
  oidc_url     = replace(aws_eks_cluster.fiveline_eks.identity[0].oidc[0].issuer, "https://", "")
}

data "aws_caller_identity" "current" {}

# ════════════════════════════════════════════════════════════════════════════
# EKS IAM Roles
# ════════════════════════════════════════════════════════════════════════════

resource "aws_iam_role" "eks_cluster_role" {
  name = "${local.project}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Service = "eks"
    Name    = "${local.project}-eks-cluster-role"
  }
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "eks_node_role" {
  name = "${local.project}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Service = "eks"
    Name    = "${local.project}-eks-node-role"
  }
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_ecr_readonly" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "eks_ssm" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ════════════════════════════════════════════════════════════════════════════
# EKS Cluster
# ════════════════════════════════════════════════════════════════════════════

resource "aws_eks_cluster" "fiveline_eks" {
  name     = local.cluster_name
  role_arn = aws_iam_role.eks_cluster_role.arn
  version  = var.k8s_version

  vpc_config {
    subnet_ids = var.private_eks_subnet_ids

    endpoint_private_access = true
    endpoint_public_access  = false
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "scheduler", "controllerManager"]

  encryption_config {
    provider {
      key_arn = var.kms_eks_secrets_arn
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

# ════════════════════════════════════════════════════════════════════════════
# EKS Add-ons
# ════════════════════════════════════════════════════════════════════════════

resource "aws_eks_addon" "vpc_cni" {
  cluster_name         = aws_eks_cluster.fiveline_eks.name
  addon_name           = "vpc-cni"
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

# ════════════════════════════════════════════════════════════════════════════
# EKS Node Group
# ════════════════════════════════════════════════════════════════════════════

resource "aws_launch_template" "eks_nodes" {
  name_prefix = "${local.project}-eks-node-"

  network_interfaces {
    associate_public_ip_address = false
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 30
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

resource "aws_eks_node_group" "ondemand" {
  cluster_name    = aws_eks_cluster.fiveline_eks.name
  node_group_name = "${local.project}-ondemand-ng"
  node_role_arn   = aws_iam_role.eks_node_role.arn

  subnet_ids = var.private_eks_subnet_ids

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
    desired_size = 4
    min_size     = 3
    max_size     = 8
  }

  update_config {
    max_unavailable = 1
  }

  tags = {
    Service                                                                = "eks"
    Name                                                                   = "${local.project}-ondemand-ng"
    "k8s.io/cluster-autoscaler/enabled"                                    = "true"
    "k8s.io/cluster-autoscaler/${aws_eks_cluster.fiveline_eks.name}"       = "owned"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_readonly,
    aws_iam_role_policy_attachment.eks_ssm,
  ]
}

# ════════════════════════════════════════════════════════════════════════════
# OIDC Provider
# ════════════════════════════════════════════════════════════════════════════

data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.fiveline_eks.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks_oidc" {
  url             = aws_eks_cluster.fiveline_eks.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]

  tags = {
    Service = "eks"
    Name    = "${local.cluster_name}-oidc"
  }
}

# ════════════════════════════════════════════════════════════════════════════
# AWS Load Balancer Controller IRSA
# ════════════════════════════════════════════════════════════════════════════

resource "aws_iam_policy" "lb_controller" {
  name        = "${local.project}-lb-controller-policy"
  description = "AWS Load Balancer Controller IAM Policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]
        Resource = "*" # nosonar
        Condition = {
          StringEquals = { "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com" }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeAccountAttributes", "ec2:DescribeAddresses",
          "ec2:DescribeAvailabilityZones", "ec2:DescribeInternetGateways",
          "ec2:DescribeVpcs", "ec2:DescribeVpcPeeringConnections",
          "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups",
          "ec2:DescribeInstances", "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeTags", "ec2:GetCoipPoolUsage", "ec2:DescribeCoipPools",
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeLoadBalancerAttributes",
          "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:DescribeListenerAttributes",
          "elasticloadbalancing:DescribeListenerCertificates",
          "elasticloadbalancing:DescribeSSLPolicies",
          "elasticloadbalancing:DescribeRules",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetGroupAttributes",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DescribeTags"
        ]
        Resource = "*" # nosonar
      },
      {
        Effect = "Allow"
        Action = [
          "acm:ListCertificates", "acm:DescribeCertificate",
          "iam:ListServerCertificates", "iam:GetServerCertificate",
          "wafv2:GetWebACL", "wafv2:GetWebACLForResource",
          "wafv2:AssociateWebACL", "wafv2:DisassociateWebACL",
          "waf-regional:GetWebACL", "waf-regional:GetWebACLForResource",
          "waf-regional:AssociateWebACL", "waf-regional:DisassociateWebACL",
          "shield:GetSubscriptionState", "shield:DescribeProtection",
          "shield:CreateProtection", "shield:DeleteProtection"
        ]
        Resource = "*" # nosonar
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress"]
        Resource = "*" # nosonar
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateSecurityGroup"]
        Resource = "*" # nosonar
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateTags"]
        Resource = "arn:aws:ec2:*:*:security-group/*"
        Condition = {
          StringEquals = { "ec2:CreateAction" = "CreateSecurityGroup" }
          Null         = { "aws:RequestedRegion" = "false" }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateTags", "ec2:DeleteTags"]
        Resource = "arn:aws:ec2:*:*:security-group/*"
        Condition = {
          Null = { "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false" }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress",
          "ec2:DeleteSecurityGroup"
        ]
        Resource = "*" # nosonar
        Condition = {
          Null = { "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false" }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:CreateLoadBalancer", "elasticloadbalancing:CreateTargetGroup"]
        Resource = "*" # nosonar
        Condition = {
          Null = { "aws:RequestTag/elbv2.k8s.aws/cluster" = "false" }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateListener", "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:CreateRule", "elasticloadbalancing:DeleteRule"
        ]
        Resource = "*" # nosonar
      },
      {
        Effect = "Allow"
        Action = ["elasticloadbalancing:AddTags", "elasticloadbalancing:RemoveTags"]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*"
        ]
        Condition = {
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster"  = "true"
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = ["elasticloadbalancing:AddTags", "elasticloadbalancing:RemoveTags"]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:listener/net/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener/app/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener-rule/net/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener-rule/app/*/*/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:SetIpAddressType", "elasticloadbalancing:SetSecurityGroups",
          "elasticloadbalancing:SetSubnets", "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:ModifyTargetGroup", "elasticloadbalancing:ModifyTargetGroupAttributes",
          "elasticloadbalancing:DeleteTargetGroup"
        ]
        Resource = "*" # nosonar
        Condition = {
          Null = { "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false" }
        }
      },
      {
        Effect = "Allow"
        Action = ["elasticloadbalancing:AddTags"]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*"
        ]
        Condition = {
          StringEquals = {
            "elasticloadbalancing:CreateAction" = ["CreateTargetGroup", "CreateLoadBalancer"]
          }
          Null = { "aws:RequestTag/elbv2.k8s.aws/cluster" = "false" }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:RegisterTargets", "elasticloadbalancing:DeregisterTargets"]
        Resource = "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:SetWebAcl", "elasticloadbalancing:ModifyListener",
          "elasticloadbalancing:AddListenerCertificates",
          "elasticloadbalancing:RemoveListenerCertificates",
          "elasticloadbalancing:ModifyRule",
          "elasticloadbalancing:SetRulePriorities"
        ]
        Resource = "*" # nosonar
      }
    ]
  })

  tags = {
    Service = "eks"
    Name    = "${local.project}-lb-controller-policy"
  }
}

resource "aws_iam_role" "lb_controller" {
  name = "${local.project}-lb-controller-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks_oidc.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_url}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          "${local.oidc_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Service = "eks"
    Name    = "${local.project}-lb-controller-role"
  }
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.lb_controller.name
  policy_arn = aws_iam_policy.lb_controller.arn
}

# ════════════════════════════════════════════════════════════════════════════
# External Secrets Operator IRSA
# ════════════════════════════════════════════════════════════════════════════

resource "aws_iam_policy" "eso" {
  name        = "${local.project}-eso-policy"
  description = "External Secrets Operator - Secrets Manager 읽기 전용"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
        "secretsmanager:ListSecretVersionIds"
      ]
      Resource = "arn:aws:secretsmanager:ap-northeast-2:${data.aws_caller_identity.current.account_id}:secret:fiveline/*"
    }]
  })

  tags = {
    Service = "eks"
    Name    = "${local.project}-eso-policy"
  }
}

resource "aws_iam_role" "eso" {
  name = "${local.project}-eso-sa-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks_oidc.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_url}:sub" = "system:serviceaccount:external-secrets:external-secrets-sa"
          "${local.oidc_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Service = "eks"
    Name    = "${local.project}-eso-sa-role"
  }
}

resource "aws_iam_role_policy_attachment" "eso" {
  role       = aws_iam_role.eso.name
  policy_arn = aws_iam_policy.eso.arn
}

# ════════════════════════════════════════════════════════════════════════════
# Cluster Autoscaler IRSA
# ════════════════════════════════════════════════════════════════════════════

resource "aws_iam_policy" "cluster_autoscaler" {
  name        = "${local.project}-cluster-autoscaler-policy"
  description = "Cluster Autoscaler - ASG 조회 및 스케일링 권한"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements"
        ]
        Resource = "*" # nosonar
      },
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeNodegroup"]
        Resource = "arn:aws:eks:ap-northeast-2:${data.aws_caller_identity.current.account_id}:nodegroup/${local.cluster_name}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup"
        ]
        Resource = "arn:aws:autoscaling:ap-northeast-2:${data.aws_caller_identity.current.account_id}:autoScalingGroup:*:autoScalingGroupName/*"
        Condition = {
          StringEquals = {
            "autoscaling:ResourceTag/kubernetes.io/cluster/${local.cluster_name}" = "owned"
          }
        }
      }
    ]
  })

  tags = {
    Service = "eks"
    Name    = "${local.project}-cluster-autoscaler-policy"
  }
}

resource "aws_iam_role" "cluster_autoscaler" {
  name = "${local.project}-cluster-autoscaler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks_oidc.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_url}:sub" = "system:serviceaccount:kube-system:cluster-autoscaler-aws-cluster-autoscaler"
          "${local.oidc_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Service = "eks"
    Name    = "${local.project}-cluster-autoscaler-role"
  }
}

resource "aws_iam_role_policy_attachment" "cluster_autoscaler" {
  role       = aws_iam_role.cluster_autoscaler.name
  policy_arn = aws_iam_policy.cluster_autoscaler.arn
}

# ════════════════════════════════════════════════════════════════════════════
# App Service IRSA (서비스별 최소 권한)
# ════════════════════════════════════════════════════════════════════════════

locals {
  app_services = {
    user    = { namespace = "production", sa = "user-sa" }
    product = { namespace = "production", sa = "product-sa" }
    order   = { namespace = "production", sa = "order-sa" }
    admin   = { namespace = "production", sa = "admin-sa" }
  }
}

resource "aws_iam_role" "app_service" {
  for_each = local.app_services
  name     = "${local.project}-${each.key}-sa-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks_oidc.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_url}:sub" = "system:serviceaccount:${each.value.namespace}:${each.value.sa}"
          "${local.oidc_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Service = each.key
    Name    = "${local.project}-${each.key}-sa-role"
  }
}

resource "aws_iam_policy" "user_service" {
  name        = "${local.project}-user-service-policy"
  description = "user-service: SES 이메일 발송 (fiveline.store 도메인)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ses:SendEmail", "ses:SendRawEmail"]
      Resource = "arn:aws:ses:ap-northeast-2:${data.aws_caller_identity.current.account_id}:identity/fiveline.store"
    }]
  })

  tags = {
    Service = "user"
    Name    = "${local.project}-user-service-policy"
  }
}

resource "aws_iam_role_policy_attachment" "user_service" {
  role       = aws_iam_role.app_service["user"].name
  policy_arn = aws_iam_policy.user_service.arn
}

resource "aws_iam_policy" "product_service" {
  name        = "${local.project}-product-service-policy"
  description = "product-service: S3 프론트엔드 버킷 product-images/ 읽기/쓰기"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
        Resource = "${var.s3_frontend_arn}/product-images/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = var.s3_frontend_arn
        Condition = {
          StringLike = { "s3:prefix" = ["product-images/*"] }
        }
      }
    ]
  })

  tags = {
    Service = "product"
    Name    = "${local.project}-product-service-policy"
  }
}

resource "aws_iam_role_policy_attachment" "product_service" {
  role       = aws_iam_role.app_service["product"].name
  policy_arn = aws_iam_policy.product_service.arn
}

resource "aws_iam_policy" "order_service" {
  name        = "${local.project}-order-service-policy"
  description = "order-service: SNS Publish (주문 상태 이벤트)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sns:Publish"]
      Resource = "arn:aws:sns:ap-northeast-2:${data.aws_caller_identity.current.account_id}:${local.project}-*"
    }]
  })

  tags = {
    Service = "order"
    Name    = "${local.project}-order-service-policy"
  }
}

resource "aws_iam_role_policy_attachment" "order_service" {
  role       = aws_iam_role.app_service["order"].name
  policy_arn = aws_iam_policy.order_service.arn
}

resource "aws_iam_policy" "admin_service" {
  name        = "${local.project}-admin-service-policy"
  description = "admin-service: CloudWatch 읽기 전용 (대시보드 메트릭 조회)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics"
        ]
        Resource = "*" # nosonar
      },
      {
        Effect = "Allow"
        Action = [
          "logs:FilterLogEvents",
          "logs:GetLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Resource = [
          "arn:aws:logs:ap-northeast-2:*:log-group:/aws/eks/${local.cluster_name}*:*",
          "arn:aws:logs:ap-northeast-2:*:log-group:aws-waf-logs-${local.project}*:*",
          "arn:aws:logs:ap-northeast-2:*:log-group:/aws/vpc/flowlogs/${local.project}:*"
        ]
      }
    ]
  })

  tags = {
    Service = "admin"
    Name    = "${local.project}-admin-service-policy"
  }
}

resource "aws_iam_role_policy_attachment" "admin_service" {
  role       = aws_iam_role.app_service["admin"].name
  policy_arn = aws_iam_policy.admin_service.arn
}

# ════════════════════════════════════════════════════════════════════════════
# Workstation (Bastion)
# ════════════════════════════════════════════════════════════════════════════

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_security_group" "bastion_sg" {
  name        = "${local.project}-bastion-sg"
  description = "Bastion WorkStation SG - SSM only, no inbound port 22"
  vpc_id      = var.vpc_id

  tags = {
    Service = "bastion"
    Name    = "${local.project}-bastion-sg"
  }
}

resource "aws_vpc_security_group_egress_rule" "bastion_to_ssm" {
  security_group_id = aws_security_group.bastion_sg.id
  description       = "SSM Agent outbound to AWS API endpoints"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_iam_role" "bastion_role" {
  name = "${local.project}-bastion-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Service = "bastion"
    Name    = "${local.project}-bastion-role"
  }
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "bastion_eks" {
  name = "${local.project}-bastion-eks-policy"
  role = aws_iam_role.bastion_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster"]
      Resource = "arn:aws:eks:ap-northeast-2:${data.aws_caller_identity.current.account_id}:cluster/${local.cluster_name}"
    }]
  })
}

resource "aws_iam_role_policy" "workstation_secrets" {
  name = "${local.project}-workstation-secrets-policy"
  role = aws_iam_role.bastion_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
        "secretsmanager:CreateSecret",
        "secretsmanager:PutSecretValue"
      ]
      Resource = [
        "arn:aws:secretsmanager:ap-northeast-2:${data.aws_caller_identity.current.account_id}:secret:fiveline-*",
        "arn:aws:secretsmanager:ap-northeast-2:${data.aws_caller_identity.current.account_id}:secret:fiveline/*"
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "bastion_profile" {
  name = "${local.project}-bastion-profile"
  role = aws_iam_role.bastion_role.name

  tags = {
    Service = "bastion"
    Name    = "${local.project}-bastion-profile"
  }
}

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.micro"
  subnet_id                   = var.private_bastion_subnet_id
  iam_instance_profile        = aws_iam_instance_profile.bastion_profile.name
  associate_public_ip_address = false

  vpc_security_group_ids = [aws_security_group.bastion_sg.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  lifecycle {
    ignore_changes = [ami]
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -e

    curl -sLO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    install -m 0755 kubectl /usr/local/bin/kubectl
    rm -f kubectl

    dnf install -y postgresql15

    echo "Bastion bootstrap complete"
  EOF
  )

  tags = {
    Service = "bastion"
    Name    = "${local.project}-workstation"
  }
}

# ════════════════════════════════════════════════════════════════════════════
# Workstation → EKS Access
# ════════════════════════════════════════════════════════════════════════════

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

resource "aws_vpc_security_group_ingress_rule" "eks_api_from_bastion" {
  security_group_id            = aws_eks_cluster.fiveline_eks.vpc_config[0].cluster_security_group_id
  description                  = "EKS API server 443 from Bastion WorkStation"
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.bastion_sg.id
}

# ════════════════════════════════════════════════════════════════════════════
# Fluent Bit — EKS 로그 수집 (EKS Pod Identity)
# ════════════════════════════════════════════════════════════════════════════

resource "aws_iam_role" "fluent_bit" {
  name = "${local.project}-fluent-bit-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }]
  })

  tags = {
    Name = "${local.project}-fluent-bit-role"
  }
}

resource "aws_iam_role_policy" "fluent_bit" {
  name = "${local.project}-fluent-bit-policy"
  role = aws_iam_role.fluent_bit.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams",
        "logs:DescribeLogGroups",
        "logs:PutRetentionPolicy"
      ]
      Resource = "*" # nosonar — CloudWatch Logs 전체 접근 필요 (로그 그룹 자동 생성)
    }]
  })
}

resource "aws_eks_pod_identity_association" "fluent_bit" {
  cluster_name    = aws_eks_cluster.fiveline_eks.name
  namespace       = "amazon-cloudwatch"
  service_account = "fluent-bit"
  role_arn        = aws_iam_role.fluent_bit.arn
}
