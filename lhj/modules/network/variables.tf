variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "cluster_name" {
  description = "EKS cluster name for subnet tagging."
  type        = string
}
