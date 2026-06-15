variable "project_name" {
  description = "Project name used for resource naming and tagging."
  type        = string
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
}

variable "aws_region" {
  description = "AWS region for deployment."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name used for Kubernetes subnet discovery tags."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.31"
}

variable "node_group_name" {
  description = "Managed node group name."
  type        = string
  default     = "general"
}

variable "node_instance_types" {
  description = "EC2 instance types used by the managed node group."
  type        = list(string)
  default     = ["t3.small"]
}

variable "node_desired_size" {
  description = "Desired number of nodes."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of nodes."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of nodes."
  type        = number
  default     = 2
}

variable "node_disk_size" {
  description = "Disk size in GiB for managed node group instances."
  type        = number
  default     = 20
}

variable "enable_cluster_log_types" {
  description = "Minimal EKS control plane log types to keep for dev."
  type        = list(string)
  default     = ["api", "audit"]
}

variable "log_retention_in_days" {
  description = "Retention in days for EKS control plane logs."
  type        = number
  default     = 7
}

variable "app_subnet_cidrs" {
  description = "Private app subnet CIDRs allowed to reach RDS."
  type        = list(string)
}

variable "db_identifier" {
  description = "RDS instance identifier."
  type        = string
}

variable "db_name" {
  description = "Initial PostgreSQL database name."
  type        = string
}

variable "db_username" {
  description = "Master username for PostgreSQL."
  type        = string
}

variable "db_password" {
  description = "Master password for PostgreSQL."
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "Allocated storage in GiB."
  type        = number
  default     = 20
}

variable "db_engine_version" {
  description = "PostgreSQL engine version."
  type        = string
  default     = "17.5"
}

variable "multi_az" {
  description = "Whether to enable Multi-AZ for RDS."
  type        = bool
  default     = false
}

variable "backup_retention_period" {
  description = "Backup retention in days for RDS."
  type        = number
  default     = 7
}

variable "skip_final_snapshot" {
  description = "Skip final snapshot on destroy for dev convenience."
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = "Enable deletion protection for RDS."
  type        = bool
  default     = false
}
