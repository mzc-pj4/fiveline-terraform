terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # S3 백엔드는 bootstrap 완료 후 주석 해제
  # backend "s3" {
  #   bucket         = "mzc-pj4-tfstate-089955620282"
  #   key            = "alarm/terraform.tfstate"
  #   region         = "ap-northeast-2"
  #   dynamodb_table = "mzc-pj4-tflock"
  #   encrypt        = true
  # }
}

provider "aws" {
  region  = "ap-northeast-2"

  default_tags {
    tags = {
      Project     = "mzc-pj4"
      Environment = "prod"
      ManagedBy   = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
