terraform {
  backend "s3" {
    bucket         = "fiveline-tfstate-089955620282"
    key            = "fiveline/dev/terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "fiveline-tflock"
    encrypt        = true
  }
}
