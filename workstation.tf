# ── Bastion (WorkStation) — SSM Session Manager 전용 ──────────────────────────
# 아키텍처 다이어그램: Public subnet 2a에 WorkStation 배치
# SSH 포트 22 인바운드 없음 — SSM이 AWS 내부 채널을 통해 접속 처리
# CloudTrail로 모든 접속 자동 감사

# ── AMI Data Source (AL2023 최신, ap-northeast-2) ─────────────────────────────

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

# ── Bastion Security Group ────────────────────────────────────────────────────
# Ingress: 없음 — SSM은 EC2가 AWS API를 아웃바운드로 호출하므로 인바운드 포트 불필요
# Egress: HTTPS(443) — SSM Agent ↔ AWS 서비스 API (ssm, ec2messages, ssmmessages)
# Egress: PostgreSQL(5432) → RDS private subnets
# Egress: Redis(6379) → ElastiCache private subnets

resource "aws_security_group" "bastion_sg" {
  name        = "${local.project}-bastion-sg"
  description = "Bastion WorkStation SG - SSM only, no inbound port 22"
  vpc_id      = aws_vpc.fiveline_vpc.id

  # Egress 규칙은 순환 참조 방지를 위해 aws_vpc_security_group_egress_rule로 분리 관리
  # (rds_sg/elasticache_sg ingress에서 bastion_sg 참조 ↔ bastion_sg egress에서 SG 참조)

  tags = {
    Service = "bastion"
    Name    = "${local.project}-bastion-sg"
  }
}

# ── Bastion Egress Rules (SG 참조 — 신원 기반 신뢰) ──────────────────────────
# SEC: CIDR 기반(위치 신뢰) → SG ID 기반(신원 신뢰)으로 전환
# CIDR: "이 IP 대역에서 오면 신뢰" → IP 스푸핑/내부 이동 시 우회 가능
# SG 참조: "이 SG가 붙은 리소스만 신뢰" → 리소스 ID 기반, 훨씬 강력한 제어

resource "aws_vpc_security_group_egress_rule" "bastion_to_ssm" {
  security_group_id = aws_security_group.bastion_sg.id
  description       = "SSM Agent outbound to AWS API endpoints (ssm, ec2messages, ssmmessages)"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"  # SSM 엔드포인트 IP가 AWS 내부적으로 변경되므로 CIDR 불가피
}

resource "aws_vpc_security_group_egress_rule" "bastion_to_rds" {
  security_group_id            = aws_security_group.bastion_sg.id
  description                  = "PostgreSQL outbound to RDS SG (identity-based trust)"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.rds_sg.id
}

resource "aws_vpc_security_group_egress_rule" "bastion_to_cache" {
  security_group_id            = aws_security_group.bastion_sg.id
  description                  = "Redis outbound to ElastiCache SG (identity-based trust)"
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.elasticache_sg.id
}

# ── Bastion IAM Role ──────────────────────────────────────────────────────────

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

# ── Bastion EC2 Instance (WorkStation) ───────────────────────────────────────
# 접속 방법: AWS Console → Systems Manager → Session Manager → Start session
#           또는: aws ssm start-session --target <instance-id>
# EKS: endpoint_public_access=true이므로 aws eks update-kubeconfig 후 kubectl 사용 가능

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.private_bastion_2a.id
  iam_instance_profile        = aws_iam_instance_profile.bastion_profile.name
  associate_public_ip_address = false  # SEC: private subnet 배치, SSM 접속 전용

  vpc_security_group_ids = [aws_security_group.bastion_sg.id]

  # SEC: IMDSv2 강제 — WorkStation 자체가 침해될 경우 SSRF 방어
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"  # IMDSv2 강제 (IMDSv1 차단)
    http_put_response_hop_limit = 1
  }

  lifecycle {
    ignore_changes = [ami]
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -e

    # kubectl 설치 (EKS endpoint_public_access=true → 인터넷 경유 접근)
    curl -sLO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    install -m 0755 kubectl /usr/local/bin/kubectl
    rm -f kubectl

    # psql 설치 — RDS 직접 접근용
    dnf install -y postgresql15

    echo "Bastion bootstrap complete"
  EOF
  )

  tags = {
    Service = "bastion"
    Name    = "${local.project}-workstation"
  }
}
