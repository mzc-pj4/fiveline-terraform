terraform {
  backend "s3" {
    bucket         = "fiveline-tfstate-089955620282"
    key            = "dev/terraform.tfstate"
    region         = "ap-northeast-2"
    encrypt        = true
    dynamodb_table = "fiveline-tflock"
  }
}
