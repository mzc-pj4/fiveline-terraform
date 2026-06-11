# Fiveline 보안 강화 방안

> 담당: 이재민 (보안 파트) | 최종 업데이트: 2026-06-09  
> 현재 구성 기준: EKS 배포 완료, 보안 베이스라인 미완성 상태

---

## 1. 현재 보안 상태 요약

### 구현 완료

| 항목 | 위치 | 비고 |
|------|------|------|
| EKS 컨트롤플레인 로그 (api/audit/authenticator) | `eks.tf:26` | CloudWatch 수집 |
| OIDC Provider (IRSA 기반) | `iam.tf` | 인프라 컴포넌트 3종 |
| LB Controller IRSA | `iam.tf:277` | kube-system:aws-load-balancer-controller |
| ESO IRSA + 정책 | `iam.tf:310` | `secret:fiveline/*` 읽기 권한 |
| Cluster Autoscaler IRSA | `iam.tf:401` | |
| RDS/ElastiCache 보안 그룹 격리 | `rds.tf`, `elasticache.tf` | EKS SG에서만 허용 |
| EKS Private Subnet 배치 | `eks.tf:9` | Private EKS 서브넷 |
| Pod SecurityContext | K8s manifest | runAsNonRoot, allowPrivilegeEscalation:false, capabilities:ALL DROP |
| S3 OAC (CloudFront만 S3 접근) | `cloudfront.tf`, `s3_frontend.tf` | S3 URL 직접 접근 불가 |
| S3 Public Access Block | `s3_frontend.tf` | 퍼블릭 접근 완전 차단 |
| S3 Versioning | `s3_frontend.tf` | 파일 변조 시 이전 버전 복원 가능 |
| RDS 저장 데이터 암호화 | `rds.tf` | `storage_encrypted=true` |
| RDS TLS 전송 암호화 | `rds.tf` | `ca_cert_identifier` (sslmode=require) |
| RDS 자동 백업 (7일) | `rds.tf` | 랜섬웨어 공격 시 복구 가능 |
| ACM 와일드카드 인증서 | `acm.tf` | fiveline.store + *.fiveline.store (us-east-1) |
| 커스텀 도메인 | `cloudfront.tf` + `route53.tf` | fiveline.store (이커머스), dashboard.fiveline.store (관리자) |
| HTTPS 강제 + TLSv1.2_2021 | `cloudfront.tf` | viewer_protocol_policy = redirect-to-https |
| WAF v2 (2-Tier) | `waf.tf` | CloudFront WAF(us-east-1) + Regional WAF(ap-northeast-2) |

### 미구현 (우선순위 순)

| 우선순위 | 항목 | 위험도 | 비고 |
|---------|------|--------|------|
| P1 🔴 | Secrets Manager + ESO 실제 연동 | 높음 | 현재 DB 비밀번호 환경변수 직접 주입 |
| P1 🔴 | 앱 서비스 IRSA Role (5개) | 높음 | user/product/order/admin/notification Pod별 최소권한 미설정 |
| P2 🟡 | KMS CMK (RDS/S3/EKS etcd) | 중간 | 저장 데이터 암호화 미완성 |
| P2 🟡 | CloudTrail | 중간 | API 감사 로그 없음 |
| P2 🟡 | VPC Flow Logs | 중간 | 네트워크 트래픽 감사 없음 |
| P2 🟡 | NetworkPolicy | 중간 | Pod 간 동서 트래픽 default-allow |
| P3 🟢 | EKS 엔드포인트 접근 제한 | 낮음 | 현재 public_access_cidrs 제한 없음 |
| P3 🟢 | GitHub Actions 보안 스캔 | 낮음 | 이미지 취약점 스캔 미완성 |
| P3 🟢 | etcd 봉투 암호화 | 낮음 | K8s Secret KMS 암호화 미적용 |

---

## 2. P1: Secrets Manager + ESO 통합 (최우선)

### 현재 문제

환경변수에 DB 비밀번호가 직접 노출됨:
```yaml
# 현재 (위험)
env:
  - name: DATABASE_URL
    value: "postgresql+psycopg://fiveline:fiveline@rds-host:5432/fiveline"
```

컨테이너 이미지 inspect, kubectl describe pod 등으로 노출 가능.

### 해결 흐름

```
Pod (IRSA ServiceAccount)
  └── AssumeRoleWithWebIdentity → 앱 서비스 IAM Role
         └── GetSecretValue (secretsmanager:fiveline/*)
              └── ESO가 K8s Secret 자동 생성
                   └── secretKeyRef → 컨테이너 환경변수
```

### Terraform: Secrets 생성

```hcl
# 서비스 공통 DB 자격증명
resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "fiveline/db-credentials"
  recovery_window_in_days = 7
  kms_key_id              = aws_kms_key.secrets.arn  # KMS 암호화
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = "fiveline"
    password = var.db_password  # terraform.tfvars 또는 CI 환경변수
    host     = aws_db_instance.primary.address
    port     = 5432
    dbname   = "fiveline"
  })
}

# JWT 서명키
resource "aws_secretsmanager_secret" "jwt_secret" {
  name = "fiveline/jwt-secret-key"
}
```

### K8s: SecretStore + ExternalSecret

```yaml
# secretstore.yaml — ESO가 Secrets Manager에 접근하는 방법 정의
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: fiveline-secret-store
  namespace: fiveline
spec:
  provider:
    aws:
      service: SecretsManager
      region: ap-northeast-2
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa   # IRSA 설정된 SA
---
# externalsecret.yaml — 실제 K8s Secret 생성 선언
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: fiveline-db-secret
  namespace: fiveline
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: fiveline-secret-store
    kind: SecretStore
  target:
    name: fiveline-db-secret          # 생성될 K8s Secret 이름
    creationPolicy: Owner
  data:
    - secretKey: DATABASE_URL
      remoteRef:
        key: fiveline/db-credentials
        property: username            # JSON 키
```

### K8s: Pod에서 참조

```yaml
# deployment.yaml
env:
  - name: DATABASE_URL
    valueFrom:
      secretKeyRef:
        name: fiveline-db-secret
        key: DATABASE_URL
```

---

## 3. P1: 앱 서비스 IRSA Role (5개 서비스)

### 현재 상태

`iam.tf`에 인프라 컴포넌트 IRSA 3종(LB Controller, ESO, CA)은 구현됨.  
앱 5개 서비스 Pod용 Role **미구현** → Pod가 AWS API 호출 시 권한 없음.

### Terraform: 앱 서비스 IRSA (user-service 예시, 나머지도 동일 패턴)

```hcl
resource "aws_iam_role" "app_user_service" {
  name = "${local.project}-user-service-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks_oidc.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_url}:sub" = "system:serviceaccount:fiveline:user-service-sa"
          "${local.oidc_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

# 최소 권한: Secrets Manager에서 자신 서비스의 Secret만 읽기
resource "aws_iam_role_policy" "app_user_service" {
  name = "${local.project}-user-service-policy"
  role = aws_iam_role.app_user_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = "arn:aws:secretsmanager:ap-northeast-2:${data.aws_caller_identity.current.account_id}:secret:fiveline/db-credentials*"
    }]
  })
}
```

### 서비스별 추가 권한

| 서비스 | 추가 권한 |
|--------|---------|
| user-service | Secrets Manager (db, jwt-secret) |
| product-service | Secrets Manager (db) |
| order-service | Secrets Manager (db), SQS SendMessage (`fiveline-order-events`) |
| admin-service | Secrets Manager (db) |
| notification-service | Secrets Manager (db), SQS ReceiveMessage/DeleteMessage |

### K8s: ServiceAccount에 IRSA 연결

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: user-service-sa
  namespace: fiveline
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::089955620282:role/fiveline-user-service-role
```

---

## 4. WAF v2 — 2-Tier 방어 구조 ✅ 구현 완료

### 아키텍처 (SA 핵심 어필 포인트)

```
인터넷
  ↓
[CloudFront WAF]  ← us-east-1, CLOUDFRONT scope
  ↓  악성 IP / SQLi / XSS / 나쁜 입력값 엣지 레벨 차단
[CloudFront] — fiveline.store / dashboard.fiveline.store
  ↓
[Regional WAF]  ← ap-northeast-2, REGIONAL scope
  ↓  CloudFront 우회 직접 접근 방어 (Defense in Depth)
[ALB] → EKS 서비스
```

**왜 2개인가?**: CloudFront WAF는 엣지에서 조기 차단하지만, ALB URL을 직접 아는 경우 우회 가능. Regional WAF가 두 번째 방어선 역할.

### 적용된 관리형 룰셋

| 룰셋 | 방어 대상 | 적용 위치 |
|------|---------|---------|
| AWSManagedRulesAmazonIpReputationList | 악성 IP, C&C 서버, 봇넷 | CloudFront + Regional |
| AWSManagedRulesCommonRuleSet | SQLi, XSS, LFI, RCE 등 OWASP Top 10 | CloudFront + Regional |
| AWSManagedRulesSQLiRuleSet | SQL 인젝션 특화 (이커머스 DB 보호) | CloudFront + Regional |
| AWSManagedRulesKnownBadInputsRuleSet | 알려진 악성 페이로드 | CloudFront만 |

**관리형 룰셋 선택 이유**: AWS 보안팀이 새로운 CVE/공격 패턴을 실시간으로 업데이트. 팀이 직접 룰을 유지보수할 필요 없음.

---

## 5. P2: KMS CMK 키 관리

### 암호화 대상별 CMK 분리

```hcl
# EKS etcd 봉투 암호화 (K8s Secret 암호화)
resource "aws_kms_key" "eks_etcd" {
  description             = "fiveline EKS etcd envelope encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

# RDS 저장 데이터 암호화
resource "aws_kms_key" "rds" {
  description             = "fiveline RDS encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

# Secrets Manager 암호화
resource "aws_kms_key" "secrets" {
  description             = "fiveline Secrets Manager encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}
```

### EKS etcd 봉투 암호화 적용

```hcl
# eks.tf에 추가
resource "aws_eks_cluster" "fiveline_eks" {
  # ... 기존 설정

  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.eks_etcd.arn
    }
  }
}
```

**주의**: 기존 클러스터에 etcd 암호화 추가 시 `terraform apply`로 적용 가능하나, 기존 Secret은 재암호화 필요 (`kubectl get secrets --all-namespaces -o json | kubectl replace -f -`)

---

## 6. P2: CloudTrail + VPC Flow Logs

### CloudTrail (API 감사)

```hcl
resource "aws_cloudtrail" "fiveline" {
  name                          = "${local.project}-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  include_global_service_events = true
  is_multi_region_trail         = true          # 전 리전 API 감사
  enable_log_file_validation    = true          # 무결성 검증
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.cloudtrail.arn
  kms_key_id                    = aws_kms_key.secrets.arn

  event_selector {
    read_write_type           = "All"
    include_management_events = true

    # S3 데이터 이벤트 (Data Lake 버킷)
    data_resource {
      type   = "AWS::S3::Object"
      values = ["arn:aws:s3:::${aws_s3_bucket.data_lake.id}/"]
    }
  }
}
```

### VPC Flow Logs

```hcl
resource "aws_flow_log" "fiveline_vpc" {
  vpc_id          = aws_vpc.fiveline_vpc.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_log.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_logs.arn

  tags = { Name = "${local.project}-vpc-flow-logs" }
}

resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/aws/vpc/fiveline-flow-logs"
  retention_in_days = 30   # 30일 보관
}
```

---

## 7. P2: NetworkPolicy (Pod 간 트래픽 격리)

현재는 namespace 내 모든 Pod가 자유롭게 통신 가능. default-deny 후 필요한 통신만 명시적 허용.

```yaml
# default-deny-all.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: fiveline
spec:
  podSelector: {}       # 네임스페이스 내 모든 Pod
  policyTypes:
  - Ingress
  - Egress
---
# allow-user-service.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-user-service
  namespace: fiveline
spec:
  podSelector:
    matchLabels:
      app: user-service
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system   # ALB Ingress Controller
  egress:
  - to:
    - ipBlock:
        cidr: 10.10.20.0/23   # RDS Private Subnet (2a: /24 + 2c: /24)
    ports:
    - port: 5432
---
# allow-order-to-product.yaml (서비스 간 통신)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-order-to-product
  namespace: fiveline
spec:
  podSelector:
    matchLabels:
      app: product-service
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: order-service
    ports:
    - port: 8000
```

---

## 8. P3: EKS API 서버 엔드포인트 접근 제한

### 현재 상태

```hcl
# eks.tf:14
endpoint_public_access  = true
# public_access_cidrs 미설정 → 전 인터넷에서 K8s API 접근 가능
```

### 개선 방안

```hcl
vpc_config {
  endpoint_private_access = true
  endpoint_public_access  = true
  # 운영자 IP + GitHub Actions 러너 IP 대역으로 제한
  public_access_cidrs = [
    "<운영자_공인_IP>/32",
    "0.0.0.0/0"   # 임시 (프로젝트 기간 중), prod 전환 시 운영자 IP만
  ]
}

access_config {
  authentication_mode                        = "API"
  bootstrap_cluster_creator_admin_permissions = false  # prod: 명시적 RBAC만 허용
}
```

---

## 9. P3: GitHub Actions 보안 파이프라인

### 장기 Access Key 제거 (OIDC 기반)

```hcl
# GitHub OIDC Provider (이미 iam.tf에 구현됨 확인 필요)
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "github_actions" {
  name = "${local.project}-github-actions-role"
  assume_role_policy = jsonencode({
    Statement = [{
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:mzc-pj4/fiveline-backend:*"
        }
      }
    }]
  })
}
```

### GitHub Actions 보안 스캔 워크플로우

```yaml
# .github/workflows/security-scan.yml
name: Security Scan
on: [push, pull_request]

jobs:
  security:
    runs-on: ubuntu-latest
    steps:
      # 1. 시크릿 유출 스캔 (가장 먼저)
      - name: Gitleaks
        uses: gitleaks/gitleaks-action@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      # 2. Python 코드 보안 분석
      - name: Bandit
        run: |
          pip install bandit
          bandit -r . -ll -x tests/  # HIGH 이상만 실패 처리

      # 3. 컨테이너 이미지 취약점 스캔
      - name: Trivy
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: '${{ env.ECR_URI }}:${{ github.sha }}'
          severity: 'CRITICAL,HIGH'
          exit-code: '1'   # Critical/High 발견 시 빌드 실패
```

---

## 10. 구현 로드맵

### Phase 1 — 즉시 (현재 ~ 1주)

| # | 작업 | 예상 소요 |
|---|------|---------|
| 1 | Secrets Manager Secret 생성 (db-credentials, jwt-secret) | 1시간 |
| 2 | ESO SecretStore + ExternalSecret K8s manifest 작성 | 2시간 |
| 3 | 앱 5개 서비스 IRSA Role terraform 추가 | 2시간 |
| 4 | Deployment 환경변수를 secretKeyRef로 전환 | 1시간 |
| 5 | WAF v2 terraform 작성 + ALB 연결 | 3시간 |

### Phase 2 — 단기 (1~2주)

| # | 작업 | 예상 소요 |
|---|------|---------|
| 1 | KMS CMK 3개 생성 (etcd/rds/secrets) | 1시간 |
| 2 | RDS KMS 암호화 적용 (신규 인스턴스 or 스냅샷 복원) | 주의: 다운타임 |
| 3 | EKS etcd 봉투 암호화 적용 | 1시간 |
| 4 | CloudTrail 활성화 | 1시간 |
| 5 | VPC Flow Logs 활성화 | 30분 |
| 6 | NetworkPolicy default-deny + 서비스별 허용 규칙 | 3시간 |

### Phase 3 — 중기 (프로젝트 마감 전)

| # | 작업 | 예상 소요 |
|---|------|---------|
| 1 | CloudFront WAF (us-east-1 provider) 추가 | 2시간 |
| 2 | GitHub Actions 보안 스캔 파이프라인 완성 | 3시간 |
| 3 | EKS 엔드포인트 public_access_cidrs IP 제한 | 30분 |
| 4 | Pod Security Standards Namespace Label 적용 | 30분 |

---

## 참고: 현재 IRSA 구성 현황 (iam.tf)

| Role | ServiceAccount | Namespace | 권한 |
|------|---------------|-----------|------|
| `fiveline-lb-controller-role` | `aws-load-balancer-controller` | kube-system | ALB 생성/관리 |
| `fiveline-eso-sa-role` | `external-secrets-sa` | external-secrets | `secretsmanager:fiveline/*` 읽기 |
| `fiveline-cluster-autoscaler-role` | `cluster-autoscaler-sa` | kube-system | EC2 Auto Scaling |
| 앱 5개 서비스 Role | — | — | **미구현 (추가 필요)** |
