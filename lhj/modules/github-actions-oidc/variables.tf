variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "github_org" {
  type        = string
  description = "GitHub organization name (e.g. mzc-pj4)"
}

variable "github_repo" {
  type        = string
  description = "GitHub repository name (e.g. fiveline-backend)"
}

variable "ecr_prefix" {
  type        = string
  description = "ECR repository prefix (e.g. fiveline-ecr)"
}
