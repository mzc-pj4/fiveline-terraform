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

# ── NAT Gateways ─────────────────────────────────────────────────────────────

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

# ── Private Cache Subnets ─────────────────────────────────────────────────────

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

# ── NACL: RDS 서브넷 ──────────────────────────────────────────────────────────

resource "aws_network_acl" "rds" {
  vpc_id     = aws_vpc.fiveline_vpc.id
  subnet_ids = [aws_subnet.private_rds_2a.id, aws_subnet.private_rds_2c.id]

  ingress {
    rule_no    = 100
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "10.10.10.0/23"
    from_port  = 5432
    to_port    = 5432
  }

  ingress {
    rule_no    = 110
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "10.10.2.0/24"
    from_port  = 5432
    to_port    = 5432
  }

  ingress {
    rule_no    = 120
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "10.10.20.0/23"
    from_port  = 1024
    to_port    = 65535
  }

  egress {
    rule_no    = 100
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "10.10.10.0/23"
    from_port  = 1024
    to_port    = 65535
  }

  egress {
    rule_no    = 110
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "10.10.2.0/24"
    from_port  = 1024
    to_port    = 65535
  }

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

# ── NACL: Cache 서브넷 ────────────────────────────────────────────────────────

resource "aws_network_acl" "cache" {
  vpc_id     = aws_vpc.fiveline_vpc.id
  subnet_ids = [aws_subnet.private_cache_2a.id, aws_subnet.private_cache_2c.id]

  ingress {
    rule_no    = 100
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "10.10.10.0/23"
    from_port  = 6379
    to_port    = 6379
  }

  ingress {
    rule_no    = 110
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "10.10.2.0/24"
    from_port  = 6379
    to_port    = 6379
  }

  ingress {
    rule_no    = 120
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "10.10.30.0/23"
    from_port  = 1024
    to_port    = 65535
  }

  egress {
    rule_no    = 100
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "10.10.10.0/23"
    from_port  = 1024
    to_port    = 65535
  }

  egress {
    rule_no    = 110
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "10.10.2.0/24"
    from_port  = 1024
    to_port    = 65535
  }

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
