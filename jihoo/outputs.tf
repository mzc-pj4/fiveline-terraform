output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = [aws_subnet.public_1.id, aws_subnet.public_2.id]
}

output "private_eks_subnet_ids" {
  value = [aws_subnet.private_eks_1.id, aws_subnet.private_eks_2.id]
}

output "private_rds_subnet_ids" {
  value = [aws_subnet.private_rds_1.id, aws_subnet.private_rds_2.id]
}

output "eks_cluster_name" {
  value = aws_eks_cluster.main.name
}

output "eks_cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}

output "eks_node_group_name" {
  value = aws_eks_node_group.main.node_group_name
}
