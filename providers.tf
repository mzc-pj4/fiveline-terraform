terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
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

# ── CloudFront 전용 provider (us-east-1) ──────────────────────────────────────
# CloudFront의 ACM 인증서 / WAF(CLOUDFRONT scope)는 반드시 us-east-1에 있어야 함 (AWS 제약)
provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1"
  profile = "ljm"

  default_tags {
    tags = {
      Project   = "fiveline"
      ManagedBy = "terraform"
    }
  }
}
