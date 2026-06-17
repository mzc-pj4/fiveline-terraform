locals {
  project      = "fiveline"
  cluster_name = "${local.project}-eks"
}

# ── VPC ───────────────────────────────────────────────────────────────────────

resource "aws_vpc" "fiveline_vpc" {
  cidr_block           = "10.10.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Service = "network"
    Name    = "${local.project}-vpc"
  }
}

# ── Subnets ───────────────────────────────────────────────────────────────────

resource "aws_subnet" "public_2a" {
  vpc_id                  = aws_vpc.fiveline_vpc.id
  cidr_block              = "10.10.0.0/24"
  availability_zone       = "ap-northeast-2a"
  map_public_ip_on_launch = true

  tags = {
    Service                                        = "network"
    Name                                           = "${local.project}-public-2a"
    "kubernetes.io/role/elb"                       = "1"
    "kubernetes.io/cluster/${local.cluster_name}"  = "shared"
  }
}

resource "aws_subnet" "public_2c" {
  vpc_id                  = aws_vpc.fiveline_vpc.id
  cidr_block              = "10.10.1.0/24"
  availability_zone       = "ap-northeast-2c"
  map_public_ip_on_launch = true

  tags = {
    Service                                        = "network"
    Name                                           = "${local.project}-public-2c"
    "kubernetes.io/role/elb"                       = "1"
    "kubernetes.io/cluster/${local.cluster_name}"  = "shared"
  }
}

resource "aws_subnet" "private_eks_2a" {
  vpc_id            = aws_vpc.fiveline_vpc.id
  cidr_block        = "10.10.10.0/24"
  availability_zone = "ap-northeast-2a"

  tags = {
    Service                                        = "network"
    Name                                           = "${local.project}-private-eks-2a"
    "kubernetes.io/role/internal-elb"              = "1"
    "kubernetes.io/cluster/${local.cluster_name}"  = "shared"
  }
}

resource "aws_subnet" "private_eks_2c" {
  vpc_id            = aws_vpc.fiveline_vpc.id
  cidr_block        = "10.10.11.0/24"
  availability_zone = "ap-northeast-2c"

  tags = {
    Service                                        = "network"
    Name                                           = "${local.project}-private-eks-2c"
    "kubernetes.io/role/internal-elb"              = "1"
    "kubernetes.io/cluster/${local.cluster_name}"  = "shared"
  }
}

resource "aws_subnet" "private_rds_2a" {
  vpc_id            = aws_vpc.fiveline_vpc.id
  cidr_block        = "10.10.20.0/24"
  availability_zone = "ap-northeast-2a"

  tags = {
    Service = "network"
    Name    = "${local.project}-private-rds-2a"
  }
}

resource "aws_subnet" "private_rds_2c" {
  vpc_id            = aws_vpc.fiveline_vpc.id
  cidr_block        = "10.10.21.0/24"
  availability_zone = "ap-northeast-2c"

  tags = {
    Service = "network"
    Name    = "${local.project}-private-rds-2c"
  }
}

# ── WorkStation (Bastion) Private Subnet ─────────────────────────────────────
# SEC: WorkStation을 public subnet에서 private subnet으로 이동
# 공인 IP 없음 — SSM Agent가 NAT Gateway → SSM 서비스 엔드포인트 경유로 통신

resource "aws_subnet" "private_bastion_2a" {
  vpc_id            = aws_vpc.fiveline_vpc.id
  cidr_block        = "10.10.2.0/24"
  availability_zone = "ap-northeast-2a"

  tags = {
    Service = "network"
    Name    = "${local.project}-private-bastion-2a"
  }
}

# ── Internet Gateway ──────────────────────────────────────────────────────────

resource "aws_internet_gateway" "fiveline_igw" {
  vpc_id = aws_vpc.fiveline_vpc.id

  tags = {
    Service = "network"
    Name    = "${local.project}-igw"
  }
}

# ── Elastic IPs for NAT Gateways ─────────────────────────────────────────────

resource "aws_eip" "nat_2a" {
  domain = "vpc"

  tags = {
    Service = "network"
    Name    = "${local.project}-eip-nat-2a"
  }
}

resource "aws_eip" "nat_2c" {
  domain = "vpc"

  tags = {
    Service = "network"
    Name    = "${local.project}-eip-nat-2c"
  }
}

# ── NAT Gateways (멀티 AZ — 2a/2c 각각 배치, AVAIL-003) ─────────────────────

resource "aws_nat_gateway" "nat_2a" {
  allocation_id = aws_eip.nat_2a.id
  subnet_id     = aws_subnet.public_2a.id

  tags = {
    Service = "network"
    Name    = "${local.project}-nat-gw-2a"
  }

  depends_on = [aws_internet_gateway.fiveline_igw]
}

resource "aws_nat_gateway" "nat_2c" {
  allocation_id = aws_eip.nat_2c.id
  subnet_id     = aws_subnet.public_2c.id

  tags = {
    Service = "network"
    Name    = "${local.project}-nat-gw-2c"
  }

  depends_on = [aws_internet_gateway.fiveline_igw]
}

# ── Route Tables ──────────────────────────────────────────────────────────────

# Public — IGW 경유
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.fiveline_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.fiveline_igw.id
  }

  tags = {
    Service = "network"
    Name    = "${local.project}-rt-public"
  }
}

resource "aws_route_table_association" "public_2a" {
  subnet_id      = aws_subnet.public_2a.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "public_2c" {
  subnet_id      = aws_subnet.public_2c.id
  route_table_id = aws_route_table.public_rt.id
}

# Private EKS — AZ별 NAT Gateway 분리 (2a → nat_2a, 2c → nat_2c)
resource "aws_route_table" "private_eks_2a_rt" {
  vpc_id = aws_vpc.fiveline_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_2a.id
  }

  tags = {
    Service = "network"
    Name    = "${local.project}-rt-private-eks-2a"
  }
}

resource "aws_route_table" "private_eks_2c_rt" {
  vpc_id = aws_vpc.fiveline_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_2c.id
  }

  tags = {
    Service = "network"
    Name    = "${local.project}-rt-private-eks-2c"
  }
}

resource "aws_route_table_association" "private_eks_2a" {
  subnet_id      = aws_subnet.private_eks_2a.id
  route_table_id = aws_route_table.private_eks_2a_rt.id
}

resource "aws_route_table_association" "private_eks_2c" {
  subnet_id      = aws_subnet.private_eks_2c.id
  route_table_id = aws_route_table.private_eks_2c_rt.id
}

# Private Bastion — NAT Gateway 경유 아웃바운드 (SSM Agent 통신 + 패키지 설치)
resource "aws_route_table" "private_bastion_rt" {
  vpc_id = aws_vpc.fiveline_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_2a.id
  }

  tags = {
    Service = "network"
    Name    = "${local.project}-rt-private-bastion"
  }
}

resource "aws_route_table_association" "private_bastion_2a" {
  subnet_id      = aws_subnet.private_bastion_2a.id
  route_table_id = aws_route_table.private_bastion_rt.id
}

# Private RDS — 인터넷 아웃바운드 없음 (완전 격리)
resource "aws_route_table" "private_rds_rt" {
  vpc_id = aws_vpc.fiveline_vpc.id

  tags = {
    Service = "network"
    Name    = "${local.project}-rt-private-rds"
  }
}

resource "aws_route_table_association" "private_rds_2a" {
  subnet_id      = aws_subnet.private_rds_2a.id
  route_table_id = aws_route_table.private_rds_rt.id
}

resource "aws_route_table_association" "private_rds_2c" {
  subnet_id      = aws_subnet.private_rds_2c.id
  route_table_id = aws_route_table.private_rds_rt.id
}

# ── Private Cache Subnets (ElastiCache) ───────────────────────────────────────

resource "aws_subnet" "private_cache_2a" {
  vpc_id            = aws_vpc.fiveline_vpc.id
  cidr_block        = "10.10.30.0/24"
  availability_zone = "ap-northeast-2a"

  tags = {
    Service = "network"
    Name    = "${local.project}-private-cache-2a"
  }
}

resource "aws_subnet" "private_cache_2c" {
  vpc_id            = aws_vpc.fiveline_vpc.id
  cidr_block        = "10.10.31.0/24"
  availability_zone = "ap-northeast-2c"

  tags = {
    Service = "network"
    Name    = "${local.project}-private-cache-2c"
  }
}

# Private Cache — 인터넷 아웃바운드 없음 (RDS와 동일 패턴, 완전 격리)
resource "aws_route_table" "private_cache_rt" {
  vpc_id = aws_vpc.fiveline_vpc.id

  tags = {
    Service = "network"
    Name    = "${local.project}-rt-private-cache"
  }
}

resource "aws_route_table_association" "private_cache_2a" {
  subnet_id      = aws_subnet.private_cache_2a.id
  route_table_id = aws_route_table.private_cache_rt.id
}

resource "aws_route_table_association" "private_cache_2c" {
  subnet_id      = aws_subnet.private_cache_2c.id
  route_table_id = aws_route_table.private_cache_rt.id
}

# ── NACL: RDS 서브넷 (Defense in Depth — SG 실수 시 백스톱) ─────────────────
# SG는 stateful이지만 NACL은 stateless → 양방향 명시 필요
# EKS(10.10.10.0/23), Bastion(10.10.2.0/24) → 5432만 허용, 나머지 차단

resource "aws_network_acl" "rds" {
  vpc_id     = aws_vpc.fiveline_vpc.id
  subnet_ids = [aws_subnet.private_rds_2a.id, aws_subnet.private_rds_2c.id]

  # 인바운드: EKS → PostgreSQL
  ingress {
    rule_no    = 100
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "10.10.10.0/23"
    from_port  = 5432
    to_port    = 5432
  }

  # 인바운드: Bastion → PostgreSQL
  ingress {
    rule_no    = 110
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "10.10.2.0/24"
    from_port  = 5432
    to_port    = 5432
  }

  # 인바운드: Multi-AZ 내부 복제 (Primary ↔ Standby 통신)
  ingress {
    rule_no    = 120
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "10.10.20.0/23"
    from_port  = 1024
    to_port    = 65535
  }

  # 아웃바운드: EKS로 응답 (임시 포트 — NACL은 stateless라 명시 필요)
  egress {
    rule_no    = 100
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "10.10.10.0/23"
    from_port  = 1024
    to_port    = 65535
  }

  # 아웃바운드: Bastion으로 응답
  egress {
    rule_no    = 110
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "10.10.2.0/24"
    from_port  = 1024
    to_port    = 65535
  }

  # 아웃바운드: Multi-AZ 복제 (5432 포함)
  egress {
    rule_no    = 120
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "10.10.20.0/23"
    from_port  = 5432
    to_port    = 65535
  }

  tags = {
    Service = "network"
    Name    = "${local.project}-nacl-rds"
  }
}

# ── NACL: Cache 서브넷 (ElastiCache Redis 격리) ──────────────────────────────

resource "aws_network_acl" "cache" {
  vpc_id     = aws_vpc.fiveline_vpc.id
  subnet_ids = [aws_subnet.private_cache_2a.id, aws_subnet.private_cache_2c.id]

  # 인바운드: EKS → Redis
  ingress {
    rule_no    = 100
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "10.10.10.0/23"
    from_port  = 6379
    to_port    = 6379
  }

  # 인바운드: Bastion → Redis
  ingress {
    rule_no    = 110
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "10.10.2.0/24"
    from_port  = 6379
    to_port    = 6379
  }

  # 인바운드: Cache 내부 Primary ↔ Replica 복제
  ingress {
    rule_no    = 120
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "10.10.30.0/23"
    from_port  = 1024
    to_port    = 65535
  }

  # 아웃바운드: EKS로 응답
  egress {
    rule_no    = 100
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "10.10.10.0/23"
    from_port  = 1024
    to_port    = 65535
  }

  # 아웃바운드: Bastion으로 응답
  egress {
    rule_no    = 110
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "10.10.2.0/24"
    from_port  = 1024
    to_port    = 65535
  }

  # 아웃바운드: Cache 내부 복제
  egress {
    rule_no    = 120
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "10.10.30.0/23"
    from_port  = 6379
    to_port    = 65535
  }

  tags = {
    Service = "network"
    Name    = "${local.project}-nacl-cache"
  }
}
