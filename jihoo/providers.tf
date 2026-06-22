terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # S3 백엔드는 bootstrap 완료 후 주석 해제
  # backend "s3" {
  #   bucket         = "mzc-pj4-tfstate-089955620282"
  #   key            = "network/terraform.tfstate"
  #   region         = "ap-northeast-2"
  #   dynamodb_table = "mzc-pj4-tflock"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = "ap-northeast-2"

  default_tags {
    tags = {
      Project     = "fiveline"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}

# 다른 팀원 리소스 ARN 구성에 사용 (alarm_history 등 우리 모듈 밖 자원)
data "aws_caller_identity" "current" {}
