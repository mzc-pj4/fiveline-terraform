terraform {
  backend "s3" {
    bucket       = "team4-aiops-tfstate-089955620282"
    key          = "dev/terraform.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
    encrypt      = true
  }
}
