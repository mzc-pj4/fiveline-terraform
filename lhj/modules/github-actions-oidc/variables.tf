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

variable "github_repos" {
  type        = list(string)
  description = "GitHub repository names (e.g. [\"fiveline-backend\", \"fiveline-frontend\"])"
}

variable "ecr_prefix" {
  type        = string
  description = "ECR repository prefix (e.g. fiveline-ecr)"
}
