# fiveline-terraform

Terraform IaC repository for the fiveline dev AWS environment.

## Scope

This repository manages the backend platform infrastructure:

- Network
  - VPC
  - public subnets
  - private app subnets
  - private DB subnets
  - internet gateway
  - one NAT gateway for dev cost control
- EKS
  - cluster
  - managed node group
  - OIDC provider
  - IAM roles
  - AWS Load Balancer Controller IAM role
- RDS
  - PostgreSQL instance
  - DB subnet group
  - security group

Frontend resources such as S3 and CloudFront are intentionally handled outside this repo.

## Dev Topology

```text
Region: ap-northeast-2
VPC:    10.0.0.0/16

Public subnets
- 10.0.1.0/24
- 10.0.2.0/24

Private app subnets
- 10.0.10.0/24
- 10.0.11.0/24

Private DB subnets
- 10.0.20.0/24
- 10.0.21.0/24
```

## Cost-Sensitive Defaults

- NAT Gateway: 1
- EKS node group: `t3.small`, desired `2`
- RDS: `db.t3.micro`, single AZ, `20GB gp3`
- ALB is expected to be shared by backend services through path-based ingress rules

## Structure

```text
modules/
  network/
  eks/
  rds/

environments/
  dev/
```

## Usage

1. Set a real database password in `terraform.tfvars`.
2. Run Terraform from `environments/dev`.

```bash
cd environments/dev
terraform init
terraform plan
terraform apply
```

After apply:

```bash
aws eks update-kubeconfig --region ap-northeast-2 --name fiveline-dev-eks
kubectl get nodes
```

## Notes

- `terraform.tfvars` is ignored by git because it may contain secrets.
- `terraform.tfvars.example` is the safe template for teammates.
- The backend currently uses S3 state with DynamoDB locking.
