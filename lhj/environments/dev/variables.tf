variable "project_name" {
  type    = string
  default = "team4-aiops"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

# EKS
variable "eks_cluster_version" {
  type    = string
  default = "1.30"
}

variable "eks_node_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "eks_node_desired_size" {
  type    = number
  default = 2
}

variable "eks_node_min_size" {
  type    = number
  default = 1
}

variable "eks_node_max_size" {
  type    = number
  default = 4
}

# RDS
variable "db_password" {
  description = "RDS master password. Set via TF_VAR_db_password env var."
  type        = string
  sensitive   = true
}

variable "rds_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "rds_multi_az" {
  type    = bool
  default = true
}
