output "vpc_id" {
  value = aws_vpc.fiveline_vpc.id
}

output "public_subnet_ids" {
  value = [aws_subnet.public_2a.id, aws_subnet.public_2c.id]
}

output "private_eks_subnet_ids" {
  value = [aws_subnet.private_eks_2a.id, aws_subnet.private_eks_2c.id]
}

output "private_rds_subnet_ids" {
  value = [aws_subnet.private_rds_2a.id, aws_subnet.private_rds_2c.id]
}

output "private_cache_subnet_ids" {
  value = [aws_subnet.private_cache_2a.id, aws_subnet.private_cache_2c.id]
}

output "private_bastion_subnet_id" {
  value = aws_subnet.private_bastion_2a.id
}

output "cluster_name" {
  value = local.cluster_name
}
