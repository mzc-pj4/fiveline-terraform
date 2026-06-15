data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  common_tags = {
    Service = "network"
  }

  cluster_tag = "kubernetes.io/cluster/${var.cluster_name}"

  public_subnets = {
    public_a = {
      cidr     = cidrsubnet(var.vpc_cidr, 8, 1)
      az_index = 0
      name     = "public-a"
    }
    public_b = {
      cidr     = cidrsubnet(var.vpc_cidr, 8, 2)
      az_index = 1
      name     = "public-b"
    }
  }

  private_app_subnets = {
    private_app_a = {
      cidr     = cidrsubnet(var.vpc_cidr, 8, 10)
      az_index = 0
      name     = "private-app-a"
    }
    private_app_b = {
      cidr     = cidrsubnet(var.vpc_cidr, 8, 11)
      az_index = 1
      name     = "private-app-b"
    }
  }

  private_db_subnets = {
    private_db_a = {
      cidr     = cidrsubnet(var.vpc_cidr, 8, 20)
      az_index = 0
      name     = "private-db-a"
    }
    private_db_b = {
      cidr     = cidrsubnet(var.vpc_cidr, 8, 21)
      az_index = 1
      name     = "private-db-b"
    }
  }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-vpc"
  })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-igw"
  })
}

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = data.aws_availability_zones.available.names[each.value.az_index]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name                     = "${var.project_name}-${var.environment}-${each.value.name}"
    Tier                     = "public"
    Subnet                   = each.value.name
    "kubernetes.io/role/elb" = "1"
    (local.cluster_tag)      = "shared"
  })
}

resource "aws_subnet" "private_app" {
  for_each = local.private_app_subnets

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr
  availability_zone = data.aws_availability_zones.available.names[each.value.az_index]

  tags = merge(local.common_tags, {
    Name                              = "${var.project_name}-${var.environment}-${each.value.name}"
    Tier                              = "private"
    Subnet                            = each.value.name
    Workload                          = "app"
    "kubernetes.io/role/internal-elb" = "1"
    (local.cluster_tag)               = "shared"
  })
}

resource "aws_subnet" "private_db" {
  for_each = local.private_db_subnets

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr
  availability_zone = data.aws_availability_zones.available.names[each.value.az_index]

  tags = merge(local.common_tags, {
    Name                = "${var.project_name}-${var.environment}-${each.value.name}"
    Tier                = "private"
    Subnet              = each.value.name
    Workload            = "db"
    (local.cluster_tag) = "shared"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-public-rt"
    Tier = "public"
  })
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-nat-eip"
  })
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public["public_a"].id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-nat"
  })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "private_app" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name     = "${var.project_name}-${var.environment}-private-app-rt"
    Tier     = "private"
    Workload = "app"
  })
}

resource "aws_route_table_association" "private_app" {
  for_each = aws_subnet.private_app

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private_app.id
}

resource "aws_route_table" "private_db" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name     = "${var.project_name}-${var.environment}-private-db-rt"
    Tier     = "private"
    Workload = "db"
  })
}

resource "aws_route_table_association" "private_db" {
  for_each = aws_subnet.private_db

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private_db.id
}
