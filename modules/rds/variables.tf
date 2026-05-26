variable "project_name" {
  description = "Project name used for naming and tagging."
  type        = string
}

variable "environment" {
  description = "Deployment environment."
  type        = string
}

variable "db_identifier" {
  description = "RDS instance identifier."
  type        = string
}

variable "db_name" {
  description = "Initial database name."
  type        = string
}

variable "db_username" {
  description = "Master username."
  type        = string
}

variable "db_password" {
  description = "Master password."
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
}

variable "db_allocated_storage" {
  description = "Allocated storage in GiB."
  type        = number
}

variable "db_engine_version" {
  description = "PostgreSQL engine version."
  type        = string
}

variable "multi_az" {
  description = "Whether the DB should be Multi-AZ."
  type        = bool
}

variable "backup_retention_period" {
  description = "Backup retention in days."
  type        = number
}

variable "skip_final_snapshot" {
  description = "Whether to skip final snapshot on destroy."
  type        = bool
}

variable "deletion_protection" {
  description = "Whether deletion protection should be enabled."
  type        = bool
}

variable "vpc_id" {
  description = "VPC ID for RDS networking."
  type        = string
}

variable "private_db_subnet_ids" {
  description = "Private DB subnet IDs."
  type        = list(string)
}

variable "app_subnet_cidrs" {
  description = "Application subnet CIDRs allowed to connect to PostgreSQL."
  type        = list(string)
}
