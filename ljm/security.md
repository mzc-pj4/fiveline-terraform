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
| WAF 관리형 룰셋 4종 (2-Tier) | `waf.tf` | SQLi/XSS/악성 IP/KnownBad |
| Pod SecurityContext | `fiveline_k8s_manifest` repo | runAsNonRoot, capabilities DROP ALL |
| Workstation associate_public_ip_address=false | `workstation.tf` | private subnet 배치, SSM 전용 |
| EKS private endpoint 5-layer 설계 | `eks.tf`, `network.tf`, `iam.tf` | endpoint_public_access=false + SG + IAM + RBAC |
| Zero Trust: IRSA(N-S) + VPC CNI NetworkPolicy(E-W) | `iam.tf`, `eks.tf`, `fiveline_k8s_manifest` | 남북/동서 양축 Pod 격리 |
| CSP unsafe-inline 제거 | `cloudfront.tf` | Magecart 웹스키밍 방어 |
| pgaudit (PII 데이터 감사) | `rds.tf` | PIPA 제29조 접근 기록 의무 준수 |

---

### 개인 발표 핵심 (이커머스 특화 고도화 보안)

> "일반 인프라 보안은 '누가 들어오나'를 막습니다.
> 이커머스 고도화 보안은 **정상처럼 생긴 공격**, **공급망**, **AI/데이터 무결성**을 지킵니다."

| # | 항목 | 위협 시나리오 | 성숙도 | 상태 |
|---|------|-------------|--------|------|
| 1 | **이커머스 특화 WAF Custom Rate Limit** | 크리덴셜 스터핑 / 재고 봇 / 카드 BIN 어택 | 선도기업 | ✅ |
| 2 | **이미지 서명 (Cosign + Kyverno)** | ECR 이미지 변조 → ArgoCD가 악성 이미지 배포 | 표준화 진행 중 | ⬜ |
| 3 | **Manifest Repo PR만 허용** | GitHub Actions 토큰 탈취 → Manifest 직접 푸시 | 업계 표준 | ⬜ |
| 4 | **ArgoCD Admission + GitOps 무결성 감시** | ArgoCD 탈취 후 K8s 리소스 수동 변조 | 업계 표준 | ⬜ |
| 5 | **간접 프롬프트 인젝션 방어** | 상품 리뷰 악성 지시문 → 데이터 파이프라인 → Bedrock 오염 | 연구~초기 도입 | ⬜ |
| 6 | **로그 위조 / Metric Poisoning 차단** | 침해 Pod이 가짜 ORDER_SUCCESS 발행 → AI 리포트 오염 | 선도/고급 커스텀 | ⬜ |
| 7 | **로그 파이프라인 무력화 탐지** | 공격자가 Firehose/Fluent Bit 삭제로 흔적 제거 | 업계 표준 (SRE) | ⬜ |
| 8 | **pgaudit ↔ 앱 로그 교차검증** | 앱 우회 후 DB 직접 대량 SELECT — 앱 로그에 흔적 없음 | 선도/고급 커스텀 | ⬜ |
| 9 | **재고 Hoarding 봇 탐지** | 카트 담기만 반복해 재고 묶기 → WAF Rate Limit으론 안 잡힘 | 선도기업 적용 | ⬜ |

---

## 1. 이커머스 특화 WAF Custom Rate Limit ✅

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

## 전체 구현 현황

### 공통 발표 항목

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
| WAF 관리형 룰셋 4종 (2-Tier) | `waf.tf` | ✅ |
| Pod SecurityContext | `fiveline_k8s_manifest` repo | ✅ |
| Workstation associate_public_ip_address=false | `workstation.tf` | ✅ |
| EKS private endpoint 5-layer 설계 | `eks.tf`, `network.tf`, `iam.tf` | ✅ |
| Zero Trust: IRSA 8종 + VPC CNI NetworkPolicy | `iam.tf`, `eks.tf`, `fiveline_k8s_manifest` | ✅ |
| CSP unsafe-inline 제거 | `cloudfront.tf` | ✅ |
| pgaudit (read/write/ddl 감사) | `rds.tf` | ✅ |

### 개인 발표 항목

| 항목 | 파일 | 상태 |
|------|------|------|
| WAF Custom Rate Limit (로그인/결제/상품) | `waf.tf` | ✅ |
| 이미지 서명 (Cosign + Kyverno) | GitHub Actions, `fiveline_k8s_manifest` | ⬜ |
| Manifest Repo PR만 허용 | GitHub 설정, GitHub Actions | ⬜ |
| ArgoCD Admission + GitOps 무결성 감시 | `fiveline_k8s_manifest`, CloudWatch | ⬜ |
| 간접 프롬프트 인젝션 방어 | Glue ETL, Bedrock Guardrails | ⬜ |
| 로그 위조 / Metric Poisoning 차단 | Glue Data Quality, Fluent Bit | ⬜ |
| 로그 파이프라인 무력화 탐지 | CloudWatch Alarm, EventBridge | ⬜ |
| pgaudit ↔ 앱 로그 교차검증 | Athena, CloudWatch | ⬜ |
| 재고 Hoarding 봇 탐지 | WAF IPSet, DynamoDB, EventBridge | ⬜ |

### 프로젝트 범위 외

| 항목 | 비고 |
|------|------|
| Secrets Manager ESO 실제 연동 | K8s manifest — 앱팀 담당 |
| ALB Access Logs | LB Controller 배포 후 Ingress annotation |
| ECR Enhanced Scanning | Inspector 비용 발생, 별도 판단 |
