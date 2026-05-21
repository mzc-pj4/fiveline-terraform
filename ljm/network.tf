locals {
  project      = "fiveline"
  env          = var.environment
  cluster_name = "${local.project}-${local.env}-eks"
}

# ── VPC ───────────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = "10.10.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Service = "network"
    Name    = "${local.project}-${local.env}-vpc"
  }
}

# ── Subnets ───────────────────────────────────────────────────────────────────

resource "aws_subnet" "public_1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.10.0.0/24"
  availability_zone       = "ap-northeast-2a"
  map_public_ip_on_launch = true

  tags = {
    Service                                         = "network"
    Name                                            = "${local.project}-${local.env}-public-1"
    "kubernetes.io/role/elb"                        = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.10.1.0/24"
  availability_zone       = "ap-northeast-2c"
  map_public_ip_on_launch = true

  tags = {
    Service                                         = "network"
    Name                                            = "${local.project}-${local.env}-public-2"
    "kubernetes.io/role/elb"                        = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "private_eks_1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.10.10.0/24"
  availability_zone = "ap-northeast-2a"

  tags = {
    Service                                         = "network"
    Name                                            = "${local.project}-${local.env}-private-eks-1"
    "kubernetes.io/role/internal-elb"               = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "private_eks_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.10.11.0/24"
  availability_zone = "ap-northeast-2c"

  tags = {
    Service                                         = "network"
    Name                                            = "${local.project}-${local.env}-private-eks-2"
    "kubernetes.io/role/internal-elb"               = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "private_rds_1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.10.20.0/24"
  availability_zone = "ap-northeast-2a"

  tags = {
    Service = "network"
    Name    = "${local.project}-${local.env}-private-rds-1"
  }
}

resource "aws_subnet" "private_rds_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.10.21.0/24"
  availability_zone = "ap-northeast-2c"

  tags = {
    Service = "network"
    Name    = "${local.project}-${local.env}-private-rds-2"
  }
}

# ── Internet Gateway ──────────────────────────────────────────────────────────

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Service = "network"
    Name    = "${local.project}-${local.env}-igw"
  }
}

# ── Elastic IPs for NAT Gateways ─────────────────────────────────────────────

resource "aws_eip" "ngw_1" {
  domain = "vpc"

  tags = {
    Service = "network"
    Name    = "${local.project}-${local.env}-eip-ngw-1"
  }
}

# ── NAT Gateway (테스트 환경 — 1개로 비용 절감) ──────────────────────────────

resource "aws_nat_gateway" "ngw_1" {
  allocation_id = aws_eip.ngw_1.id
  subnet_id     = aws_subnet.public_1.id

  tags = {
    Service = "network"
    Name    = "${local.project}-${local.env}-ngw-1"
  }

  depends_on = [aws_internet_gateway.main]
}

# ── Route Tables ──────────────────────────────────────────────────────────────

# Public — IGW 경유
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Service = "network"
    Name    = "${local.project}-${local.env}-rt-public"
  }
}

resource "aws_route_table_association" "public_1" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}

# Private EKS — AZ-a는 NGW-1, AZ-c는 NGW-2 경유 (AZ 장애 격리)
resource "aws_route_table" "private_eks_1" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.ngw_1.id
  }

  tags = {
    Service = "network"
    Name    = "${local.project}-${local.env}-rt-private-eks-1"
  }
}

resource "aws_route_table" "private_eks_2" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.ngw_1.id
  }

  tags = {
    Service = "network"
    Name    = "${local.project}-${local.env}-rt-private-eks-2"
  }
}

resource "aws_route_table_association" "private_eks_1" {
  subnet_id      = aws_subnet.private_eks_1.id
  route_table_id = aws_route_table.private_eks_1.id
}

resource "aws_route_table_association" "private_eks_2" {
  subnet_id      = aws_subnet.private_eks_2.id
  route_table_id = aws_route_table.private_eks_2.id
}

# Private RDS — 인터넷 아웃바운드 없음 (완전 격리)
resource "aws_route_table" "private_rds" {
  vpc_id = aws_vpc.main.id

  tags = {
    Service = "network"
    Name    = "${local.project}-${local.env}-rt-private-rds"
  }
}

resource "aws_route_table_association" "private_rds_1" {
  subnet_id      = aws_subnet.private_rds_1.id
  route_table_id = aws_route_table.private_rds.id
}

resource "aws_route_table_association" "private_rds_2" {
  subnet_id      = aws_subnet.private_rds_2.id
  route_table_id = aws_route_table.private_rds.id
}
