# Fiveline 이커머스 보안 설계

> 담당: 이재민 (보안 파트) | 최종 업데이트: 2026-06-12
> 전략: 기본 인프라 보안은 공통 발표로, 이커머스 특화 고도화 보안은 개인 발표로

---

## 발표 전략

### 공통 발표 항목 (기본 인프라 보안 — 당연히 해야 하는 것)

> 아래 항목들은 이커머스가 아니어도 동일하게 적용된다.
> 공통 발표에서 "베이스라인은 당연히 다 깔았다"로 30초 언급하고 넘긴다.

| 항목 | 파일 | 비고 |
|------|------|------|
| HTTPS 강제 + TLSv1.2_2021 | `cloudfront.tf` | redirect-to-https |
| ACM 와일드카드 인증서 | `acm.tf` | fiveline.store + *.fiveline.store |
| S3 OAC + Public Access Block + Versioning | `cloudfront.tf`, `s3_frontend.tf` | S3 직접 접근 차단 |
| RDS 저장/전송 암호화 | `rds.tf` | storage_encrypted + TLS |
| RDS 보안 그룹 격리 | `rds.tf` | EKS/Bastion SG에서만 허용 |
| RDS 자동 백업 (7일) | `rds.tf` | 운영 기본 |
| RDS deletion_protection=true | `rds.tf:184` | 랜섬웨어/실수 DB 삭제 방지 |
| KMS CMK 3개 (etcd/rds/secrets) | `kms.tf` | AWS 관리형 키 대신 고객 통제 키 |
| GuardDuty + SNS 알림 | `guardduty.tf` | MEDIUM 이상 이메일 알림 |
| CloudTrail + VPC Flow Logs | `cloudtrail.tf` | API 감사 + 네트워크 기록 |
| EKS 컨트롤플레인 로그 | `eks.tf:24` | api/audit/authenticator |
| Pod SecurityContext | K8s manifest | runAsNonRoot, capabilities DROP ALL |
| OIDC Provider + 인프라 IRSA 3종 | `iam.tf` | LB Controller / ESO / CA |
| IMDSv2 + hop_limit=1 | `eks.tf`, `bastion.tf` | Capital One 동일 경로 차단 |
| WAF 관리형 룰셋 4종 | `waf.tf` | SQLi / XSS / 악성 IP / KnownBad |

---

### 개인 발표 핵심 (이커머스 특화 고도화 보안 — 5가지)

> "일반 인프라 보안은 '누가 들어오나'를 막습니다.
> 이커머스 보안은 **정상처럼 생긴 공격**과 **내가 가진 데이터**를 지킵니다."

| # | 항목 | 위협 | SA 역량 | 상태 |
|---|------|------|---------|------|
| 1 | **이커머스 특화 WAF Custom Rule** | 크리덴셜 스터핑 / 재고 봇 / 카드 BIN 어택 | 위협 모델링 → 설계 결정 | 🔄 구현 예정 |
| 2 | **Zero Trust 완성: IRSA + NetworkPolicy** | Blast Radius (Pod 간 동서 이동) | N-S + E-W 2축 격리 설계 | 🔄 부분 구현 |
| 3 | **EKS private endpoint 접근 경로 설계** | 인터넷에서 K8s API 접근 | Multi-component 설계 조합 | ✅ 완료 |
| 4 | **CSP unsafe-inline 취약점 발견 + 수정** | 웹스키밍 (Magecart) / XSS | 결함 발견 → 강화 | 🔄 구현 예정 |
| 5 | **PII 데이터 감사 (pgaudit)** | 내부자 위협 / PIPA 위반 | 데이터 계층 Zero Trust | 🔄 구현 예정 |

---

## 1. 이커머스 특화 WAF Custom Rule Group

### 왜 관리형 룰셋만으로는 부족한가

현재 WAF는 SQLi/XSS/악성 IP를 막는다. 그런데 이커머스를 망하게 하는 공격은 이것들이다:

| 공격 | 형태 | 현재 WAF | 피해 |
|------|------|---------|------|
| **크리덴셜 스터핑** | 유출된 ID/PW를 `/api/login`에 초당 수천 건 | **차단 불가** (정상 요청 형태) | 계정 탈취 → 포인트/결제수단 도용 |
| **재고 선점 봇** | 한정판 상품 장바구니 자동 선점 | **차단 불가** | 실고객 구매 불가, 리셀 |
| **카드 BIN 어택** | 훔친 카드번호를 `/api/payment`에 대량 검증 | **차단 불가** | 결제사 제재, 매출 손실 |
| **가격 스크래핑** | 전 상품 가격 자동 수집 | **차단 불가** | 경쟁사에 가격 정책 노출 |

이것들은 **정상 HTTP 요청처럼 생겼기 때문에** 관리형 룰셋이 탐지하지 못한다.

### 설계: 엔드포인트별 Rate Limit

```hcl
# waf.tf에 추가 예정
resource "aws_wafv2_rule_group" "ecommerce_custom" {
  name     = "${local.project}-ecommerce-rules"
  scope    = "REGIONAL"
  capacity = 150

  # 크리덴셜 스터핑 방어: 로그인 엔드포인트 Rate Limit (IP당 5분 100회)
  rule {
    name     = "login-rate-limit"
    priority = 1
    statement {
      rate_based_statement {
        limit              = 100
        aggregate_key_type = "IP"
        scope_down_statement {
          byte_match_statement {
            search_string         = "/api/users/login"
            positional_constraint = "STARTS_WITH"
            field_to_match { uri_path {} }
            text_transformation { priority = 0; type = "LOWERCASE" }
          }
        }
      }
    }
    action { block {} }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "login-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # 카드 BIN 어택 방어: 결제 엔드포인트 Rate Limit (IP당 5분 20회)
  rule {
    name     = "checkout-rate-limit"
    priority = 2
    statement {
      rate_based_statement {
        limit              = 20
        aggregate_key_type = "IP"
        scope_down_statement {
          byte_match_statement {
            search_string         = "/api/orders"
            positional_constraint = "STARTS_WITH"
            field_to_match { uri_path {} }
            text_transformation { priority = 0; type = "LOWERCASE" }
          }
        }
      }
    }
    action { block {} }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "checkout-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # 가격 스크래핑 방어: 상품 목록 API Rate Limit (IP당 1분 200회)
  rule {
    name     = "product-scraping-limit"
    priority = 3
    statement {
      rate_based_statement {
        limit              = 200
        aggregate_key_type = "IP"
        scope_down_statement {
          byte_match_statement {
            search_string         = "/api/products"
            positional_constraint = "STARTS_WITH"
            field_to_match { uri_path {} }
            text_transformation { priority = 0; type = "LOWERCASE" }
          }
        }
      }
    }
    action { block {} }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "product-scraping-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "ecommerce-custom-rules"
    sampled_requests_enabled   = true
  }
}
```

기존 Regional WAF Web ACL에 Rule Group 연결:
```hcl
# 기존 aws_wafv2_web_acl.regional에 rule 블록 추가
rule {
  name     = "ecommerce-custom-rules"
  priority = 0  # 관리형 룰셋보다 높은 우선순위
  statement {
    rule_group_reference_statement {
      arn = aws_wafv2_rule_group.ecommerce_custom.arn
    }
  }
  override_action { none {} }
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "ecommerce-custom-group"
    sampled_requests_enabled   = true
  }
}
```

**발표 포인트**: "관리형 룰셋은 AWS가 관리하는 공격을 막습니다. 이커머스를 겨냥한 공격은 **비즈니스 로직을 이해한 커스텀 룰**이 필요합니다."

---

## 2. Zero Trust 완성: IRSA(N-S) + NetworkPolicy(E-W)

### 현재 상태의 GAP

```
현재 구현된 것:
  Pod → AWS 서비스: IRSA로 격리됨 (남북 축)
    user-service-pod → S3 product-images/ 만 가능
    order-service-pod → SNS fiveline-* 만 가능

현재 빠진 것:
  Pod ↔ Pod: 완전 무방비 (동서 축)
    order-service가 침해되면 → user-service DB 직접 접근 가능
    외부 공격자가 Pod 하나를 탈취하면 → 네임스페이스 내 전체 서비스 접근 가능
```

**IRSA만으로는 절반이다.** AWS 권한은 격리했지만 K8s 내부 통신은 무방비.

### 설계: default-deny + 명시적 허용

```yaml
# k8s/network-policy/default-deny.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: production
spec:
  podSelector: {}   # 네임스페이스 내 모든 Pod
  policyTypes:
    - Ingress
    - Egress
---
# k8s/network-policy/allow-order-to-product.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-order-to-product
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: product-service
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: order-service
      ports:
        - port: 8000
---
# k8s/network-policy/allow-egress-rds.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-rds
  namespace: production
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 10.10.20.0/23   # RDS private subnets (2a + 2c)
      ports:
        - port: 5432
    - to:
        - ipBlock:
            cidr: 10.10.30.0/23   # Cache private subnets (2a + 2c)
      ports:
        - port: 6379
    - ports:
        - port: 53    # DNS
          protocol: UDP
```

Terraform 연동 (EKS VPC CNI Network Policy 활성화):
```hcl
# eks.tf: vpc-cni addon에 network policy 활성화 설정
resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.fiveline_eks.name
  addon_name   = "vpc-cni"
  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
  })
}
```

**발표 포인트**: "IRSA는 AWS 리소스에 대한 남북 권한을 격리합니다. NetworkPolicy는 Pod 간 동서 트래픽을 격리합니다. 두 가지가 함께 있어야 Zero Trust가 완성됩니다."

### 현재 IRSA 구성 현황

| Role | ServiceAccount | Namespace | 권한 범위 |
|------|--------------|-----------|---------|
| `fiveline-lb-controller-role` | `aws-load-balancer-controller` | kube-system | ALB 생성/관리 |
| `fiveline-eso-sa-role` | `external-secrets-sa` | external-secrets | secretsmanager:fiveline/* |
| `fiveline-cluster-autoscaler-role` | `cluster-autoscaler` | kube-system | EC2 Auto Scaling (태그 조건) |
| `fiveline-user-sa-role` | `user-sa` | production | SES SendEmail (fiveline.store) |
| `fiveline-product-sa-role` | `product-sa` | production | S3 product-images/ PutObject/GetObject |
| `fiveline-order-sa-role` | `order-sa` | production | SNS Publish (fiveline-* 토픽) |
| `fiveline-admin-sa-role` | `admin-sa` | production | CloudWatch GetMetricData/FilterLogEvents |
| `fiveline-notification-sa-role` | `notification-sa` | production | SES + SNS Publish |

---

## 3. EKS private endpoint 접근 경로 설계 ✅ 완료

### 왜 설계가 필요한가

단순히 `endpoint_public_access=false` 한 줄로 끝나지 않는다.
아래 5개 컴포넌트가 모두 맞물려야 동작한다:

```
endpoint_public_access=false → 인터넷에서 K8s API 완전 차단
     ↓
WorkStation을 private subnet으로 이동 (신규 서브넷 + NAT 라우팅)
     ↓
EKS 클러스터 SG에 Bastion SG → 443 ingress 추가 (CIDR 아닌 SG 참조)
     ↓
aws_eks_access_entry + AmazonEKSClusterAdminPolicy (API 인증 모드)
     ↓
bastion_role에 eks:DescribeCluster 권한 추가
```

이 5가지 중 하나라도 빠지면 동작하지 않는다. 각각 다른 레이어(네트워크/SG/IAM/RBAC)를 건드리는 설계.

### 접근 경로

```
로컬 PC
  └── AWS SSM Session Manager (포트 22 없음, IAM 기반)
        └── WorkStation (private subnet 10.10.2.0/24, NAT → SSM Agent 통신)
              └── kubectl → EKS API 서버 (10.10.10.x:443, private endpoint only)
                    ↑ bastion_sg → 443만 허용 (CIDR 아닌 SG 참조)
```

**발표 포인트**: "이것은 단순한 설정 변경이 아닙니다. 네트워크/SG/IAM/RBAC 4개 레이어를 조합해서 인터넷 접근 경로를 완전히 제거한 설계입니다."

### 관련 파일

| 파일 | 변경 내용 |
|------|---------|
| `eks.tf:13-14` | endpoint_public_access=false |
| `eks.tf:158-174` | aws_eks_access_entry + policy_association |
| `eks.tf:180-187` | eks_api_from_bastion (SG 참조 ingress) |
| `bastion.tf:101-110` | bastion_eks policy (eks:DescribeCluster) |
| `bastion.tf:133` | subnet_id = private_bastion_2a |
| `network.tf:101-110` | private_bastion_2a 신규 서브넷 |
| `network.tf:236-252` | private_bastion_rt + NAT 라우팅 |

---

## 4. CSP 취약점 발견 + 수정

### 현재 코드의 실제 결함

```hcl
# cloudfront.tf:57 — 현재 (취약)
content_security_policy = "default-src 'self'; script-src 'self' 'unsafe-inline'; ..."
#                                                              ^^^^^^^^^^^^^^^^
#                          이 부분이 있으면 CSP의 XSS 방어 기능이 거의 무력화됨
```

`'unsafe-inline'`이 있으면 공격자가 주입한 인라인 스크립트(`<script>악성코드</script>`)가 그대로 실행된다.

### 왜 이커머스에서 치명적인가 — Magecart 공격

```
Magecart 공격 시나리오:
  1. 공격자가 XSS 취약점으로 결제 페이지에 악성 스크립트 삽입
  2. 고객이 카드번호 입력 → 악성 스크립트가 입력값 캡처
  3. 공격자 서버로 카드번호 전송

  실제 피해: British Airways(2018) 50만 건 카드정보 유출, $230M 과징금
             Ticketmaster, Newegg 동일 방식 피해

  현재 CSP에 unsafe-inline → 위 공격 시 스크립트 차단 불가
```

### 수정

```hcl
# cloudfront.tf 수정 예정
content_security_policy = join("; ", [
  "default-src 'self'",
  "script-src 'self'",                         # unsafe-inline 제거
  "style-src 'self' 'unsafe-inline'",          # CSS inline은 허용 (디자인 필요)
  "img-src 'self' data: https:",
  "font-src 'self' https://fonts.gstatic.com",
  "connect-src 'self' https://api.fiveline.store",
  "frame-ancestors 'none'",
  "base-uri 'self'",
  "form-action 'self'"
])
```

**발표 포인트**: "보안 헤더를 달았지만 `unsafe-inline`이 있으면 XSS 방어가 무의미합니다. 아무도 못 보는 디테일을 발견하고 수정한 것이 진짜 보안입니다."

---

## 5. PII 데이터 보안: pgaudit (감사 로깅)

### RDS storage_encrypted의 한계

```
storage_encrypted=true 는:
  디스크가 물리적으로 도난당할 때 → ✅ 효과 있음
  SQL 쿼리로 정상 접근할 때 → ❌ 평문으로 노출됨
  권한 있는 DBA가 SELECT * FROM users → ❌ 막을 수 없음
  내부자가 회원 100만 건 조회 후 유출 → ❌ 흔적 없음
```

**암호화 ≠ 데이터 보안.** 암호화는 저장 매체 보호고, 접근 감사가 데이터 보안이다.

### pgaudit: 누가 어떤 데이터를 조회했는지 기록

```hcl
# rds.tf — parameter_group에 pgaudit 추가 예정
resource "aws_db_parameter_group" "postgres" {
  name   = "${local.project}-postgres-params"
  family = "postgres16"

  parameter {
    name         = "shared_preload_libraries"
    value        = "pgaudit"
    apply_method = "pending-reboot"
  }

  parameter {
    name  = "pgaudit.log"
    value = "read,write,ddl"   # SELECT/INSERT/UPDATE/DELETE + 테이블 변경 감사
  }

  parameter {
    name  = "pgaudit.log_relation"
    value = "on"   # 테이블별 상세 기록
  }

  parameter {
    name  = "log_connections"
    value = "1"    # 접속 시도 기록 (기존 설정 유지)
  }
}
```

생성된 감사 로그 예시 (CloudWatch에서 조회):
```
AUDIT: SESSION,1,1,READ,SELECT,TABLE,public.users,
  "SELECT id, name, phone, address FROM users WHERE id > 1000 LIMIT 100000",
  <not logged>
  user=admin, client=10.10.2.15, application=psql
```

→ DBA가 회원 100만 건 SELECT 시도 즉시 탐지 가능

### 한국 개인정보보호법(PIPA) 연결

```
개인정보보호법 제29조:
"개인정보처리자는 개인정보에 대한 접근 기록을 최소 6개월 이상 보관하여야 한다"

위반 시: 과태료 최대 3,000만 원 + 손해배상
이커머스 침해 사고 시 "접근 기록 없음" = 규정 위반 자체가 추가 제재

→ pgaudit + CloudWatch Logs 90일 보관 = PIPA 준수
```

**발표 포인트**: "RDS 암호화는 디스크 도난을 막습니다. 내부자가 SQL로 회원정보를 조회하는 것은 암호화가 막지 못합니다. pgaudit이 누가 어떤 데이터를 언제 조회했는지 기록합니다."

---

## 즉시 수정 필요: 코드 레벨 결함

보안 에이전트가 발견한 현재 코드의 실제 결함들.

| 파일 | 위치 | 결함 | 수정 방향 |
|------|------|------|---------|
| `cloudfront.tf` | ~57행 CSP | `script-src 'unsafe-inline'` → XSS 방어 무력 | unsafe-inline 제거 |
| `iam.tf` | ~585-598행 | admin_service `Resource = "*"` → 모든 로그그룹 조회 가능 | 특정 LogGroup ARN으로 제한 |
| `rds.tf` | ~24-30행 | RDS SG egress `protocol="-1"` VPC 전체 오픈 | DB는 egress 불필요, 제거 또는 최소화 |
| `cloudtrail.tf` | force_destroy | CloudTrail S3에 force_destroy=true → 감사 로그 한 명령으로 삭제 가능 | false로 변경 |

---

## 전체 구현 현황

### 공통 발표 항목 (완료)

| 항목 | 파일 | 상태 |
|------|------|------|
| HTTPS 강제 + TLSv1.2_2021 | `cloudfront.tf` | ✅ |
| ACM 인증서 | `acm.tf` | ✅ |
| S3 OAC + Public Block + Versioning | `s3_frontend.tf` | ✅ |
| RDS 저장/전송 암호화 + 보안그룹 격리 | `rds.tf` | ✅ |
| RDS deletion_protection + 자동 백업 | `rds.tf` | ✅ |
| KMS CMK 3개 | `kms.tf` | ✅ |
| GuardDuty + SNS 알림 | `guardduty.tf` | ✅ |
| CloudTrail + VPC Flow Logs | `cloudtrail.tf` | ✅ |
| EKS 컨트롤플레인 로그 | `eks.tf` | ✅ |
| Pod SecurityContext | K8s manifest | ✅ |
| OIDC + 인프라 IRSA 3종 | `iam.tf` | ✅ |
| IMDSv2 + hop_limit=1 | `eks.tf`, `bastion.tf` | ✅ |
| WAF 관리형 룰셋 4종 (2-Tier) | `waf.tf` | ✅ |
| CloudFront 보안 헤더 | `cloudfront.tf` | ✅ |
| Bastion SG 참조 전환 (신원 기반) | `bastion.tf` | ✅ |

### 개인 발표 항목 (구현 예정)

| 항목 | 파일 | 상태 |
|------|------|------|
| WAF Custom Rate Limit (이커머스 특화) | `waf.tf` | 🔄 구현 예정 |
| CSP unsafe-inline 제거 | `cloudfront.tf` | 🔄 구현 예정 |
| pgaudit (PII 감사) | `rds.tf` parameter_group | 🔄 구현 예정 |
| NetworkPolicy default-deny | K8s manifest | 🔄 구현 예정 |
| EKS VPC CNI Network Policy 활성화 | `eks.tf` | 🔄 구현 예정 |
| admin IAM Resource="*" 수정 | `iam.tf` | 🔄 구현 예정 |
| RDS SG egress 최소화 | `rds.tf` | 🔄 구현 예정 |

### 프로젝트 범위 외

| 항목 | 비고 |
|------|------|
| Secrets Manager ESO 실제 연동 | K8s manifest — 앱팀 담당 |
| ALB Access Logs | LB Controller 배포 후 Ingress annotation |
| GitHub Actions 보안 스캔 | CI 담당자 협의 필요 |
| ECR Enhanced Scanning | Inspector 비용 발생, 별도 판단 |

---

## 구현 로드맵

### 완료 ✅

Phase 1~3 전 항목 완료 (상세 내역 위 현황 표 참조)

### 진행 예정 (개인 발표 고도화)

| # | 작업 | 파일 | 우선순위 |
|---|------|------|---------|
| 1 | CSP unsafe-inline 제거 | `cloudfront.tf` | P1 — 실제 결함 수정 |
| 2 | admin IAM Resource="*" → 특정 ARN | `iam.tf` | P1 — 최소권한 위반 수정 |
| 3 | WAF Custom Rate Limit 룰 그룹 | `waf.tf` | P1 — 이커머스 특화 |
| 4 | pgaudit 파라미터 그룹 | `rds.tf` | P2 — PII 감사 |
| 5 | EKS VPC CNI Network Policy 활성화 | `eks.tf` | P2 — Zero Trust 완성 |
| 6 | NetworkPolicy YAML 작성 | K8s manifest | P2 — Zero Trust 완성 |
| 7 | RDS SG egress 제거 | `rds.tf` | P3 — 불필요 egress |
| 8 | CloudTrail force_destroy=false | `cloudtrail.tf` | P3 — 감사 버킷 보호 |
