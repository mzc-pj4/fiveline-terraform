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

  egress {
    description = "SSM Agent to AWS APIs (ssm, ec2messages, ssmmessages endpoints)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "PostgreSQL to RDS private subnets"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.10.20.0/24", "10.10.21.0/24"]
  }

  egress {
    description = "Redis to ElastiCache private subnets"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = ["10.10.30.0/24", "10.10.31.0/24"]
  }

  tags = {
    Service = "bastion"
    Name    = "${local.project}-bastion-sg"
  }
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
  ami                  = data.aws_ami.al2023.id
  instance_type        = "t3.micro"
  subnet_id            = aws_subnet.public_2a.id
  iam_instance_profile = aws_iam_instance_profile.bastion_profile.name

  vpc_security_group_ids = [aws_security_group.bastion_sg.id]

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
