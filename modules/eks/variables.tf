variable "project_name" {
  description = "Project name used for naming and tagging."
  type        = string
}

variable "environment" {
  description = "Deployment environment."
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for the cluster."
  type        = string
}

variable "private_app_subnet_ids" {
  description = "Private subnets for cluster and node group placement."
  type        = list(string)
}

variable "node_group_name" {
  description = "Managed node group name."
  type        = string
}

variable "node_instance_types" {
  description = "EC2 instance types for the managed node group."
  type        = list(string)
}

variable "node_desired_size" {
  description = "Desired number of worker nodes."
  type        = number
}

variable "node_min_size" {
  description = "Minimum number of worker nodes."
  type        = number
}

variable "node_max_size" {
  description = "Maximum number of worker nodes."
  type        = number
}

variable "node_disk_size" {
  description = "Disk size in GiB for worker nodes."
  type        = number
}

variable "enable_cluster_log_types" {
  description = "Cluster log types enabled for CloudWatch."
  type        = list(string)
}

variable "log_retention_in_days" {
  description = "Retention in days for CloudWatch log group."
  type        = number
}
