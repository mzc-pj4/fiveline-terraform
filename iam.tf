# ── EKS Cluster Role ─────────────────────────────────────────────────────────

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

# ── EKS Node Role ─────────────────────────────────────────────────────────────

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

# ── EKS OIDC Provider ─────────────────────────────────────────────────────────
# LB Controller IRSA를 위한 OIDC IdP 등록
# tls provider를 사용해 EKS OIDC 엔드포인트에서 CA 지문 자동 취득

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

# ── AWS Load Balancer Controller IRSA ─────────────────────────────────────────
# EKS Ingress로 ALB를 생성/관리하기 위한 IRSA (IAM Role for Service Accounts)
# Helm 설치 시 ServiceAccount: kube-system/aws-load-balancer-controller

locals {
  oidc_url = replace(aws_eks_cluster.fiveline_eks.identity[0].oidc[0].issuer, "https://", "")
}

resource "aws_iam_policy" "lb_controller" {
  name        = "${local.project}-lb-controller-policy"
  description = "AWS Load Balancer Controller IAM Policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]
        Resource = "*"
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
        Resource = "*"
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
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateSecurityGroup"]
        Resource = "*"
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
        Resource = "*"
        Condition = {
          Null = { "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false" }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:CreateLoadBalancer", "elasticloadbalancing:CreateTargetGroup"]
        Resource = "*"
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
        Resource = "*"
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
        Resource = "*"
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
        Resource = "*"
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

# ── External Secrets Operator IRSA ────────────────────────────────────────────
# ESO가 Secrets Manager에서 DB 자격증명/JWT 키를 읽어 K8s Secret으로 동기화
# Helm 설치 시 ServiceAccount: external-secrets/external-secrets-sa

resource "aws_iam_policy" "eso" {
  name        = "${local.project}-eso-policy"
  description = "External Secrets Operator - Secrets Manager 읽기 전용"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecretVersionIds"
        ]
        Resource = "arn:aws:secretsmanager:ap-northeast-2:${data.aws_caller_identity.current.account_id}:secret:fiveline/*"
      }
    ]
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

# ── Cluster Autoscaler IRSA ───────────────────────────────────────────────────
# Helm 설치 시 ServiceAccount: kube-system/cluster-autoscaler

resource "aws_iam_policy" "cluster_autoscaler" {
  name        = "${local.project}-cluster-autoscaler-policy"
  description = "Cluster Autoscaler - ASG 조회 및 스케일링 권한"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Describe 계열은 리소스 수준 제한 미지원 — Resource "*" 불가피
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
          "ec2:GetInstanceTypesFromInstanceRequirements",
          "eks:DescribeNodegroup"
        ]
        Resource = "*"
      },
      {
        # 스케일링 변경 권한은 이 클러스터 소속 ASG로만 범위 제한
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup"
        ]
        Resource = "*"
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

# ── 앱 서비스 IRSA (Pod 수준 최소 권한) ──────────────────────────────────────
# SEC: Node Role은 EKS 인프라 운영에만 사용 — 앱 비즈니스 로직 권한 분리
# IRSA 없이 앱을 실행하면 Node의 과도한 Role이 모든 Pod에 상속됨 (Blast Radius 전체)
# 서비스별 독립 Role → 하나의 Pod가 침해되어도 다른 서비스 AWS 리소스 접근 불가
#
# ESO가 DB 자격증명/JWT 키를 K8s Secret으로 동기화하므로
# 각 앱 SA는 서비스 특화 AWS 리소스만 접근 (Secrets Manager 직접 접근 불필요)
#
# namespace: production (K8s 네임스페이스)

locals {
  app_services = {
    user    = { namespace = "production", sa = "user-sa" }
    product = { namespace = "production", sa = "product-sa" }
    order   = { namespace = "production", sa = "order-sa" }
    admin   = { namespace = "production", sa = "admin-sa" }
  }
}

# 공통 IRSA Trust Policy 생성 (서비스 어카운트 → IAM Role)
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

# ── user-service: SES 이메일 발송 (이메일 인증, 비밀번호 재설정) ──────────────

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

# ── product-service: S3 상품 이미지 업로드/조회 ───────────────────────────────

resource "aws_iam_policy" "product_service" {
  name        = "${local.project}-product-service-policy"
  description = "product-service: S3 프론트엔드 버킷 product-images/ 읽기/쓰기"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.frontend.arn}/product-images/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.frontend.arn
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

# ── order-service: SNS 주문 이벤트 발행 ──────────────────────────────────────

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

# ── admin-service: CloudWatch 메트릭/로그 읽기 (대시보드) ─────────────────────

resource "aws_iam_policy" "admin_service" {
  name        = "${local.project}-admin-service-policy"
  description = "admin-service: CloudWatch 읽기 전용 (대시보드 메트릭 조회)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # CloudWatch 메트릭 조회 — 메트릭 액션은 ARN 기반 제한 불가 (AWS 설계 특성)
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics"
        ]
        Resource = "*"
      },
      {
        # SEC: 로그 조회는 fiveline 관련 로그 그룹으로 범위 제한 (최소 권한)
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

