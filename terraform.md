# Terraform 인프라 레포 컨텍스트

mzc-pj4 프로젝트의 인프라 레포에서 작업 시 참고할 전체 컨텍스트 문서.

---

## 프로젝트 기본 정보

| 항목                     | 값                             |
| ------------------------ | ------------------------------ |
| project_name             | `mzc-pj4`                      |
| AWS 계정 ID              | `089955620282`                 |
| 리전                     | `ap-northeast-2`               |
| Terraform state S3       | `mzc-pj4-tfstate-089955620282` |
| Terraform state DynamoDB | `mzc-pj4-tflock`               |
| 백엔드 레포              | `mzc-pj4/fiveline-backend`     |
| 프론트엔드 레포          | `mzc-pj4/fiveline-frontend`    |

> Terraform state 백엔드(S3 + DynamoDB) 포함 AWS 리소스는 아직 아무것도 생성되지 않은 상태.

---

## 전체 아키텍처 흐름

```
사용자 → CloudFront ──→ ALB → Ingress(EKS) → EKS Node → RDS PostgreSQL
                   ↑
              S3 (Frontend 정적 배포)

CI/CD: GitHub Actions → ECR 이미지 빌드/푸시
       → ArgoCD가 Manifest Repo Sync → EKS 배포
```

- CloudFront는 S3(정적 프론트엔드)와 ALB(API) 두 곳을 Origin으로 가짐
- ALB → Ingress Controller → EKS Node(Pod) 순으로 API 트래픽 처리
- EKS 클러스터는 **AWS 콘솔에서 직접 구성** (Terraform 범위 아님)
- ArgoCD가 Manifest Repo를 감시하며 EKS에 자동 배포

---

## 백엔드 서비스 구성

3개 FastAPI MSA 서비스로 구성된 샘플 이커머스 워크로드.

| 서비스            | 포트 | 역할                                 |
| ----------------- | ---- | ------------------------------------ |
| `user-service`    | 8001 | 회원가입, 로그인, JWT 발급           |
| `product-service` | 8002 | 상품 목록/상세, 리뷰                 |
| `order-service`   | 8003 | 장바구니, 주문, 실패·지연 시뮬레이션 |

각 서비스는 독립 Docker 이미지로 빌드되어 ECR에 푸시 후 EKS Pod으로 실행됨.

---

## 네트워크 구성 (Terraform 작업 범위)

### 개요

- 리전: `ap-northeast-2`
- AZ: `ap-northeast-2a`, `ap-northeast-2c` (2개)
- 총 서브넷: **6개** (Public 2 + Private EKS 2 + Private RDS 2)

### 서브넷 구조

| 종류          | 서브넷        | AZ  | 용도              |
| ------------- | ------------- | --- | ----------------- |
| Public        | public-1      | 2a  | NGW, Bastion, ALB |
| Public        | public-2      | 2c  | NGW, Bastion, ALB |
| Private (EKS) | private-eks-1 | 2a  | EKS 노드          |
| Private (EKS) | private-eks-2 | 2c  | EKS 노드          |
| Private (RDS) | private-rds-1 | 2a  | RDS Primary       |
| Private (RDS) | private-rds-2 | 2c  | RDS Standby       |

### 라우팅

- Public subnet → Internet Gateway (IGW)
- Private subnet (EKS, RDS) → NGW (아웃바운드 전용)
- Private subnet (RDS) — RDS는 인터넷 아웃바운드도 불필요하므로 별도 격리 고려 가능

### EKS 콘솔 연동을 위한 필수 서브넷 태그

EKS가 서브넷을 인식하고 로드밸런서를 자동 생성하려면 아래 태그가 반드시 있어야 함.

```hcl
# EKS 노드용 private subnet
"kubernetes.io/role/internal-elb"    = "1"
"kubernetes.io/cluster/<클러스터명>" = "shared"

# ALB Ingress용 public subnet
"kubernetes.io/role/elb"             = "1"
"kubernetes.io/cluster/<클러스터명>" = "shared"
```

> 클러스터명은 콘솔 작업 후 확정되면 서브넷 태그에 반영 필요.

---

## Terraform 코딩 규칙

### 태그

공통 태그는 provider `default_tags`로 일괄 적용:

```hcl
default_tags = {
  Project     = "mzc-pj4"
  Environment = "dev"
  ManagedBy   = "terraform"
}
```

모듈별로 `Service` 태그, 리소스별로 `Name` 태그를 추가 부여:

```hcl
tags = {
  Service = "network"
  Name    = "mzc-pj4-dev-vpc"
}
```

### 네이밍 컨벤션

```
{project_name}-{environment}-{resource}

예시:
  mzc-pj4-dev-vpc
  mzc-pj4-dev-public-1
  mzc-pj4-dev-private-eks-1
  mzc-pj4-dev-private-rds-1
  mzc-pj4-dev-igw
  mzc-pj4-dev-ngw
```

### 금지 사항

- ARN, 계정 ID 하드코딩 금지 → `data source` 또는 `variable` 사용
- AWS 자격증명 하드코딩 금지 → OIDC 기반 IAM Role assume 사용
- 모호한 부분은 추측하지 않고 질문

---

## 현재 작업 범위 및 상태

| 항목                                   | 상태                                             |
| -------------------------------------- | ------------------------------------------------ |
| Terraform state 백엔드 (S3 + DynamoDB) | 미생성 — 인프라 레포에서 bootstrap 먼저 필요     |
| VPC / 서브넷 / IGW / NGW / 라우팅      | 미생성 — 오늘 Terraform으로 작성 및 apply 예정   |
| EKS 클러스터                           | 미생성 — 네트워크 완료 후 AWS 콘솔에서 직접 구성 |
| RDS                                    | 미생성 — 추후 작업                               |
| ECR                                    | 미생성 — 추후 작업                               |
| ALB / Ingress Controller               | 미생성 — EKS 구성 후 작업                        |
| ArgoCD                                 | 미생성 — EKS 구성 후 작업                        |
| CloudFront                             | 미생성 — 추후 작업                               |
