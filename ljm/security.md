# Fiveline 이커머스 보안 설계

> 담당: 이재민 (보안 파트) | 최종 업데이트: 2026-06-17
> 전략: 기본 인프라 보안은 공통 발표, 이커머스 특화 고도화 보안은 개인 발표

---

## 발표 전략

### 공통 발표 항목 (기본 인프라 보안 — 당연히 해야 하는 것)

> 이커머스가 아니어도 동일하게 적용. 공통 발표에서 "베이스라인 전부 구축"으로 언급.

| 항목 | 파일 | 비고 |
|------|------|------|
| HTTPS 강제 + TLSv1.2_2021 | `cloudfront.tf` | redirect-to-https |
| ACM 와일드카드 인증서 | `acm.tf` | fiveline.store + *.fiveline.store |
| S3 OAC + Public Access Block + Versioning | `cloudfront.tf`, `s3_frontend.tf` | S3 직접 접근 차단 |
| CloudFront 보안 헤더 (HSTS/CSP/X-Frame-Options/Referrer) | `cloudfront.tf` | OWASP Secure Headers |
| CloudFront Standard Logging v2 | `cloudfront_logging.tf` | ACL 방식 → 버킷 정책 방식 전환 |
| RDS 저장/전송 암호화 | `rds.tf` | storage_encrypted + TLS |
| RDS 보안 그룹 격리 + egress 없음 | `rds.tf` | EKS/Workstation SG에서만 허용 |
| RDS deletion_protection=true + 자동 백업 7일 | `rds.tf` | 랜섬웨어/실수 삭제 방지 |
| KMS CMK 3개 (etcd/rds/secrets) | `kms.tf` | AWS 관리형 키 대신 고객 통제 키 |
| GuardDuty + SNS 알림 | `guardduty.tf` | MEDIUM 이상 이메일 알림 |
| CloudTrail + HTTPS-only 버킷 정책 | `cloudtrail.tf` | 감사 로그 무결성 + 전송 암호화 |
| VPC Flow Logs | `cloudtrail.tf` | 네트워크 트래픽 감사 |
| EKS 컨트롤플레인 로그 | `eks.tf` | api/audit/authenticator |
| OIDC Provider + 인프라 IRSA 3종 | `iam.tf` | LB Controller / ESO / Cluster Autoscaler |
| IMDSv2 + hop_limit=1 | `eks.tf`, `workstation.tf` | Capital One 동일 경로 SSRF 차단 |
| WAF 관리형 룰셋 4종 (2-Tier) | `waf.tf`, `waf_cloudfront.tf` | SQLi/XSS/악성 IP/KnownBad |
| Pod SecurityContext | K8s manifest | runAsNonRoot, capabilities DROP ALL |
| Workstation associate_public_ip_address=false | `workstation.tf` | private subnet 배치, SSM 전용 |

---

### 개인 발표 핵심 5개 (이커머스 특화 고도화 보안)

> "일반 인프라 보안은 '누가 들어오나'를 막습니다.
> 이커머스 보안은 **정상처럼 생긴 공격**과 **내가 가진 데이터**를 지킵니다."

| # | 항목 | 위협 시나리오 | 상태 |
|---|------|-------------|------|
| 1 | **EKS private endpoint 접근 경로 설계** | 인터넷 → K8s API 직접 접근 | ✅ |
| 2 | **이커머스 특화 WAF Custom Rate Limit** | 크리덴셜 스터핑 / 재고 봇 / 카드 BIN 어택 | ✅ |
| 3 | **Zero Trust: IRSA(N-S) + VPC CNI NetworkPolicy(E-W)** | Pod 침해 후 내부 이동 (Blast Radius) | ✅ |
| 4 | **CSP unsafe-inline 제거 (웹스키밍 방어)** | Magecart / XSS 인라인 스크립트 | ✅ |
| 5 | **pgaudit (PII 데이터 감사)** | 내부자 위협 / PIPA 접근 기록 의무 위반 | ✅ |

---

## 1. EKS private endpoint 접근 경로 설계 ✅

### 왜 이커머스에서 치명적인가

K8s API 서버가 인터넷에 열려 있으면:
- `kubectl delete namespace production` 한 줄로 전체 서비스 삭제 가능
- 자격증명 탈취 시 재고 조작, DB 직접 접근 경로 생성 가능

### 5-layer 설계 (하나라도 빠지면 동작 안 함)

```
endpoint_public_access=false → 인터넷에서 K8s API 완전 차단
     ↓
Workstation을 private subnet으로 이동 (신규 서브넷 + NAT 라우팅)
     ↓
EKS 클러스터 SG에 Workstation SG → 443 ingress (CIDR 아닌 SG ID 참조)
     ↓
aws_eks_access_entry + AmazonEKSClusterAdminPolicy (API 인증 모드)
     ↓
workstation_role에 eks:DescribeCluster + eks:DescribeNodegroup 권한 (ARN 제한)
```

### 접근 경로

```
로컬 PC
  └── AWS SSM Session Manager (포트 22 없음, IAM 기반)
        └── Workstation (private subnet 10.10.2.0/24)
              └── kubectl → EKS API 서버 (10.10.10.x:443, private endpoint only)
```

### 관련 파일

| 파일 | 내용 |
|------|------|
| `eks.tf:13-14` | endpoint_public_access=false |
| `eks.tf:158-174` | aws_eks_access_entry + policy_association |
| `eks.tf:180-187` | eks_api_from_bastion (SG 참조 ingress) |
| `workstation.tf:101-110` | bastion_eks policy |
| `workstation.tf:133` | subnet_id = private_bastion_2a |
| `network.tf` | private_bastion_2a + NAT 라우팅 |
| `iam.tf` | eks:DescribeNodegroup ARN 제한 |

**발표 포인트**: "단순 설정 변경이 아닙니다. 네트워크/SG/IAM/RBAC 4개 레이어가 모두 맞물려야 동작합니다. 하나라도 빠지면 kubectl이 안 됩니다."

---

## 2. 이커머스 특화 WAF Custom Rate Limit ✅

### 관리형 룰셋이 못 막는 이커머스 특화 공격

| 공격 | 형태 | 관리형 룰셋 | 피해 |
|------|------|------------|------|
| **크리덴셜 스터핑** | 유출 ID/PW를 `/api/auth/login`에 초당 수천 건 | **차단 불가** (정상 POST 요청) | 계정 탈취 → 포인트/결제수단 도용 |
| **재고 선점 봇** | 한정판 장바구니 자동 선점 (`/api/cart/items`) | **차단 불가** | 실고객 구매 불가 |
| **카드 BIN 어택** | 훔친 카드번호를 `/api/orders`에 대량 검증 | **차단 불가** | 결제사 제재, 매출 손실 |
| **가격 스크래핑** | 전 상품 가격 자동 수집 (`/api/products`) | **차단 불가** | 경쟁사에 가격 정책 노출 |

모두 **정상 HTTP 요청처럼 생겼기 때문에** 관리형 룰셋이 탐지 불가.

### 구현: 엔드포인트별 Rate Limit (waf.tf)

| 공격 | 엔드포인트 | Rate Limit |
|------|-----------|-----------|
| 크리덴셜 스터핑 | `/api/auth/login` | IP당 5분 100회 초과 → 차단 |
| 카드 BIN 어택 | `/api/orders` | IP당 5분 20회 초과 → 차단 |
| 가격 스크래핑 | `/api/products` | IP당 1분 200회 초과 → 차단 |

Regional WAF Web ACL에 `priority=0`으로 연결 → 관리형 룰셋보다 먼저 평가.

**발표 포인트**: "관리형 룰셋은 AWS가 아는 공격을 막습니다. 이커머스를 겨냥한 공격은 **우리 비즈니스 로직을 이해한 커스텀 룰**이 필요합니다."

---

## 3. Zero Trust: IRSA(N-S) + VPC CNI NetworkPolicy(E-W) ✅

### 현재 상태

```
구현 완료:
  Pod → AWS (남북 축): IRSA 8종으로 격리
    user-sa     → SES SendEmail (fiveline.store)
    product-sa  → S3 product-images/ PutObject/GetObject
    order-sa    → SNS Publish (fiveline-* 토픽)
    admin-sa    → CloudWatch GetMetricData/FilterLogEvents
    notification-sa → SES + SNS
    + 인프라 IRSA 3종 (LB Controller / ESO / Cluster Autoscaler)

  Pod ↔ Pod (동서 축): VPC CNI enableNetworkPolicy=true 활성화
    → NetworkPolicy YAML 적용 가능한 인프라 레이어 구축 완료
    → 실제 Policy YAML은 앱팀 K8s manifest에서 관리
```

### IRSA 구성 현황

| Role | ServiceAccount | 권한 범위 |
|------|--------------|---------|
| `fiveline-lb-controller-role` | `aws-load-balancer-controller` | ALB 생성/관리 |
| `fiveline-eso-sa-role` | `external-secrets-sa` | secretsmanager:fiveline/* |
| `fiveline-cluster-autoscaler-role` | `cluster-autoscaler` | EC2 Auto Scaling (태그 조건) |
| `fiveline-user-sa-role` | `user-sa` | SES SendEmail (fiveline.store) |
| `fiveline-product-sa-role` | `product-sa` | S3 product-images/ |
| `fiveline-order-sa-role` | `order-sa` | SNS Publish (fiveline-* 토픽) |
| `fiveline-admin-sa-role` | `admin-sa` | CloudWatch (특정 LogGroup ARN) |
| `fiveline-notification-sa-role` | `notification-sa` | SES + SNS |

### VPC CNI Network Policy 활성화 (eks.tf)

```hcl
resource "aws_eks_addon" "vpc_cni" {
  configuration_values = jsonencode({ enableNetworkPolicy = "true" })
}
```

**발표 포인트**: "IRSA는 Pod가 AWS 서비스에 접근하는 남북 권한을 격리합니다. VPC CNI NetworkPolicy는 Pod 간 동서 통신을 격리합니다. 두 축이 함께 있어야 Zero Trust가 완성됩니다."

---

## 4. CSP unsafe-inline 제거 (웹스키밍 방어) ✅

### Magecart 공격 시나리오

```
1. 공격자가 XSS 취약점으로 결제 페이지에 악성 스크립트 삽입
2. 고객이 카드번호 입력 → 악성 스크립트가 입력값 캡처
3. 공격자 서버로 카드번호 전송

실제 피해: British Airways(2018) 50만 건, $230M 과징금
           Ticketmaster, Newegg 동일 방식
```

### 발견한 결함 → 수정

```
수정 전 (취약):
  script-src 'self' 'unsafe-inline'
                    ↑ 인라인 스크립트 실행 허용 → CSP 무력화

수정 후 (cloudfront.tf):
  script-src 'self'
  (unsafe-inline 완전 제거 → 브라우저가 인라인 스크립트 실행 자체를 차단)
```

**발표 포인트**: "보안 헤더를 달았다고 끝이 아닙니다. `unsafe-inline` 하나가 XSS 방어 전체를 무력화합니다. 아무도 못 보는 디테일을 발견하고 수정한 것이 진짜 보안입니다."

---

## 5. pgaudit (PII 데이터 감사) ✅

### RDS storage_encrypted의 한계

```
storage_encrypted=true:
  디스크 물리적 도난 → ✅ 막음
  SQL로 정상 접근 (SELECT * FROM users) → ❌ 평문 노출
  권한 있는 DBA가 회원 100만 건 조회 → ❌ 막을 수 없음
  내부자 유출 후 "접근 기록 없음" → ❌ 증거 없음
```

### pgaudit 구현 (rds.tf parameter_group)

```hcl
parameter { name = "shared_preload_libraries"; value = "pg_stat_statements,auto_explain,pgaudit" }
parameter { name = "pgaudit.log";              value = "read,write,ddl" }
parameter { name = "pgaudit.log_relation";     value = "1" }
```

감사 로그 예시:
```
AUDIT: SESSION,1,1,READ,SELECT,TABLE,public.users,
  "SELECT id, name, phone FROM users WHERE id > 1000 LIMIT 100000"
  user=admin, client=10.10.2.15
```

### 한국 개인정보보호법(PIPA) 연결

```
개인정보보호법 제29조:
  "개인정보에 대한 접근 기록을 최소 6개월 이상 보관"
  위반 시: 과태료 최대 3,000만 원

pgaudit + CloudWatch Logs 30일 + CloudTrail → PIPA 준수
```

**발표 포인트**: "RDS 암호화는 디스크를 지킵니다. 내부자가 SQL로 조회하는 것은 암호화가 막지 못합니다. pgaudit이 누가 어떤 데이터를 언제 봤는지 기록합니다."

---

## 전체 구현 현황

### 공통 발표 항목 (완료)

| 항목 | 파일 | 상태 |
|------|------|------|
| HTTPS 강제 + TLSv1.2_2021 | `cloudfront.tf` | ✅ |
| ACM 인증서 | `acm.tf` | ✅ |
| S3 OAC + Public Block + Versioning | `s3_frontend.tf` | ✅ |
| CloudFront 보안 헤더 (HSTS/CSP/X-Frame-Options) | `cloudfront.tf` | ✅ |
| CloudFront Standard Logging v2 | `cloudfront_logging.tf` | ✅ |
| RDS 저장/전송 암호화 + SG 격리 | `rds.tf` | ✅ |
| RDS deletion_protection + 자동 백업 | `rds.tf` | ✅ |
| RDS egress 없음 (SG stateful) | `rds.tf` | ✅ |
| KMS CMK 3개 | `kms.tf` | ✅ |
| GuardDuty + SNS 알림 | `guardduty.tf` | ✅ |
| CloudTrail + HTTPS-only + lifecycle | `cloudtrail.tf` | ✅ |
| VPC Flow Logs | `cloudtrail.tf` | ✅ |
| EKS 컨트롤플레인 로그 | `eks.tf` | ✅ |
| OIDC + 인프라 IRSA 3종 | `iam.tf` | ✅ |
| IMDSv2 + hop_limit=1 | `eks.tf`, `workstation.tf` | ✅ |
| WAF 관리형 룰셋 4종 (2-Tier) | `waf.tf`, `waf_cloudfront.tf` | ✅ |
| Pod SecurityContext | K8s manifest | ✅ |
| Workstation associate_public_ip_address=false | `workstation.tf` | ✅ |

### 개인 발표 핵심 5개 (완료)

| 항목 | 파일 | 상태 |
|------|------|------|
| EKS private endpoint 5-layer 설계 | `eks.tf`, `network.tf`, `iam.tf` | ✅ |
| WAF Custom Rate Limit (로그인/결제/상품) | `waf.tf` | ✅ |
| IRSA 8종 최소권한 | `iam.tf` | ✅ |
| VPC CNI Network Policy 활성화 | `eks.tf` | ✅ |
| CSP unsafe-inline 제거 | `cloudfront.tf` | ✅ |
| pgaudit (read/write/ddl 감사) | `rds.tf` | ✅ |

### 프로젝트 범위 외

| 항목 | 비고 |
|------|------|
| Secrets Manager ESO 실제 연동 | K8s manifest — 앱팀 담당 |
| ALB Access Logs | LB Controller 배포 후 Ingress annotation |
| ECR Enhanced Scanning | Inspector 비용 발생, 별도 판단 |
