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
  #   bucket         = "fiveline-tfstate-089955620282"
  #   key            = "terraform.tfstate"
  #   region         = "ap-northeast-2"
  #   dynamodb_table = "fiveline-tflock"
  #   encrypt        = true
  # }
}

# ── 기본 provider (서울 리전) ─────────────────────────────────────────────────
provider "aws" {
  region  = "ap-northeast-2"
  profile = "ljm"

  default_tags {
    tags = {
      Project   = "fiveline"
      ManagedBy = "terraform"
    }
  }
}
