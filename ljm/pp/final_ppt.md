# Fiveline 발표 전체 정리 — 공통 + 개인 (이재민)

> 메가존 클라우드 파이널 프로젝트 (2025-05-11 ~ 2025-07-08)  
> 시나리오: 무신사/올리브영 규모 이커머스 기업으로부터 인프라 아키텍처 설계를 의뢰받은 MSP

---

## 1. 프로젝트 개요

### 1.1 한 줄 요약

> "고트래픽 이커머스 서비스를 컨테이너(EKS) 기반으로 구축하고, 데이터 수집/분석, CI/CD 자동화, AI 리포트, 이커머스 특화 보안까지 End-to-End로 설계·구현한 클라우드 아키텍처 프로젝트"

### 1.2 팀 구성 및 역할

| 역할 | 담당자 | 주요 서비스 |
|------|--------|------------|
| 보안 | **이재민 (개인 발표)** | WAF, KMS, Secrets Manager, IRSA, GuardDuty, CloudTrail |
| 데이터 파이프라인 | 팀원 | Firehose, S3 Data Lake, Glue, Athena, Bedrock |
| 모니터링/알람 | 팀원 | CloudWatch, SNS, Lambda, Grafana, CA, NTH |
| CI/CD | 팀원 | ECR, GitHub Actions, ArgoCD, ALB Controller |

### 1.3 발표 구조

- **팀 공통 발표**: 전체 아키텍처 + 핵심 코어 서비스 (모든 팀원 공동 설명)
- **개인 발표 (이재민)**: 보안 파트 고도화 — 이커머스 특화 WAF Rate Limit + GuardDuty SOAR

---

## 2. 전체 아키텍처 흐름

### 2.1 사용자 트래픽 흐름

```
[사용자 브라우저]
      │
      ▼
[Route53 DNS] ──── fiveline.store
      │
      ▼
[CloudFront + WAF (us-east-1)] ─── [S3: 정적 프론트엔드 (React SPA)]
      │
      ▼ (API 요청)
[ALB (ap-northeast-2) + WAF]
      │
[EKS Ingress Controller]
      ├── /api/auth, /api/users  → user-service (8001)
      ├── /api/products          → product-service (8002)
      ├── /api/orders, /api/cart → order-service (8003)
      └── /api/notifications     → notification-service (8005)
             │
      ┌──────┴──────┐
      ▼             ▼
   [RDS PostgreSQL]  [ElastiCache Redis]
   Multi-AZ Primary  Primary/Replica
   + Read Replica×2
```

### 2.2 이벤트 데이터 → 분석 → AI 리포트 흐름

```
[EKS 마이크로서비스] — 16종 이벤트 JSON 로그 발행
      │
      ▼
[CloudWatch Logs] ← Fluent Bit DaemonSet 수집
      │ Subscription Filter
      ▼
[Kinesis Firehose] — 버퍼링 300초, Dynamic Partitioning
      │
      ▼
[S3 Data Lake: raw/cleansed/aggregated]
      │
      ├── [AWS Glue Crawler] → Data Catalog
      ├── [Glue ETL Job] → PII 마스킹 + Parquet 변환 → cleansed
      └── [Amazon Athena] → SQL 분석
              │
              ▼
      [EventBridge 스케줄]
              │
              ▼
      [Lambda: report-generator]
              │
              ▼
      [Amazon Bedrock (Claude 3.5 Sonnet)] → 자연어 리포트
              │
              ▼
      [S3: reports/daily/] + Slack 발송
```

### 2.3 CI/CD 흐름

```
[Developer Push]
      │
      ▼
[GitHub Actions]
  1. OIDC 인증 (장기 액세스키 없음)
  2. CodeQL 정적분석 (Python 취약점)
  3. Bandit 보안 스캔
  4. Gitleaks 시크릿 스캔
  5. 유닛 테스트
  6. Docker 이미지 빌드
  7. Trivy 취약점 스캔 (Critical/High 시 배포 차단)
  8. ECR 푸시 (커밋 SHA 태그: latest 금지)
  9. Manifest Repo 이미지 태그 업데이트
      │
      ▼
[fiveline-k8s-manifest (GitOps)]
      │ ArgoCD가 Pull
      ▼
[EKS 클러스터 자동 배포]
```

### 2.4 모니터링/알람 흐름

```
[EKS/RDS/ALB 지표 + 애플리케이션 로그]
      │
      ▼
[CloudWatch Alarms (14개)]
      │
      ▼
[SNS Topic: fiveline-sns-alarm]
      │
      ▼
[Lambda: alarm-handler]
      ├── DynamoDB: alarm_history (90일 TTL)
      ├── DynamoDB: dashboard_summary
      ├── Slack Webhook (Critical=빨강, Warning=노랑)
      └── Grafana Dashboard (골든 시그널 4행)
```

---

## 3. 공통 인프라 — 네트워크

### 3.1 VPC 설계 (4계층 서브넷 격리)

| 서브넷 계층 | CIDR | 배치 리소스 |
|------------|------|------------|
| Public 2a/2c | 10.10.0.0/24, 10.10.1.0/24 | NAT Gateway, ALB |
| Private-EKS 2a/2c | 10.10.10.0/24, 10.10.11.0/24 | EKS 워커 노드 |
| Private-RDS 2a/2c | 10.10.20.0/24, 10.10.21.0/24 | RDS Primary/Standby/Replica |
| Private-Cache 2a/2c | 10.10.30.0/24, 10.10.31.0/24 | ElastiCache Redis |

- **멀티 AZ**: ap-northeast-2a / ap-northeast-2c 2개 AZ 분산
- **NAT Gateway**: 2a/2c AZ별 각 1개 (AZ 장애 시 아웃바운드 독립 유지)
- **RDS/Cache 완전 격리**: 아웃바운드 라우트 없음, EKS SG에서만 inbound 허용

### 3.2 보안 그룹 설계

| SG | 인바운드 | 설명 |
|----|---------|------|
| ALB SG | 80/443 (0.0.0.0/0) | 인터넷 → ALB |
| EKS Worker SG | ALB SG에서만 | ALB → EKS |
| RDS SG | EKS Worker SG에서 5432만 | EKS → RDS |
| ElastiCache SG | EKS Worker SG에서 6379만 | EKS → Redis |

---

## 4. 공통 인프라 — EKS 컨테이너 플랫폼

### 4.1 클러스터 구성

| 항목 | 설정 |
|------|------|
| EKS 버전 | Kubernetes 1.35 |
| 컨트롤플레인 | AWS 관리형 (Managed Control Plane) |
| 애드온 | VPC CNI, kube-proxy, CoreDNS, metrics-server, Pod Identity Agent |
| 컨트롤플레인 로그 | api/audit/authenticator → CloudWatch |
| etcd 봉투 암호화 | KMS CMK (fiveline-kms-eks-etcd) |

### 4.2 노드 그룹 전략 (On-Demand 70% : Spot 30%)

| 노드 그룹 | 인스턴스 | min/max | taint | 용도 |
|---------|---------|---------|-------|------|
| On-Demand | t3.medium | 2/4 | 없음 | 시스템 워크로드 + 서비스 기본 |
| Spot | t3.medium, t3a.medium | 0/2 | spot=true:NoSchedule | 트래픽 폭증 오버플로 버퍼 |

- **Node Termination Handler (NTH)**: Spot 인터럽션 2분 전 노티스 → 자동 cordon + drain
- **Cluster Autoscaler**: HPA Pod 증가 시 노드 자동 추가/제거 (CA 없으면 70:30 비율 실현 불가)
- **PodDisruptionBudget**: 서비스별 `minAvailable: 1` — 노드 드레인 중 최소 1 Pod 보장

### 4.3 서비스 Pod 구성

| 서비스 | 포트 | HPA CPU | readiness/liveness |
|--------|------|---------|-------------------|
| user-service | 8001 | 70% | /api/health |
| product-service | 8002 | 70% | /api/health |
| order-service | 8003 | 60% (선제 발동) | /api/health |
| admin-service | 8004 | 70% | /api/health |
| notification-service | 8005 | 70% | /api/health |

- **HPA**: CPU 70% 기준, min 2 / max 6 (order-service: 60%)
- **Pod SecurityContext**: `runAsNonRoot`, `allowPrivilegeEscalation: false`, `capabilities drop ALL`
- **배포 방식**: RollingUpdate (maxUnavailable=0, maxSurge=1)

### 4.4 IRSA (Pod별 최소권한 AWS 접근)

```
Pod (IRSA) → Secrets Manager → ESO → K8s Secret → secretKeyRef → 컨테이너
```

- user-service-sa → SES SendEmail (fiveline.store 도메인만)
- product-service-sa → S3 product-images/ 만
- order-service-sa → SNS fiveline-* 토픽만

### 4.5 GitOps 배포 (ArgoCD)

- Manifest Repository 분리 (`fiveline-k8s-manifest`)
- Kustomize: base + overlays/prod 구조
- 롤백: `argocd app rollback fiveline <REVISION>` — 이전 Git 리비전으로 즉시 복구
- 모든 배포 이력 Git으로 추적 가능

---

## 5. 공통 인프라 — 데이터 계층

### 5.1 RDS PostgreSQL (CQRS 패턴)

| 인스턴스 | 역할 | AZ |
|---------|------|-----|
| Primary (fiveline-rds-primary) | 쓰기 (INSERT/UPDATE) | 2a |
| Standby | 자동 페일오버 (Multi-AZ) | 2c |
| Replica-A | 읽기 부하분산 (Zone Affinity) | 2a |
| Replica-C | 데이터 파이프라인 쿼리 격리 | 2c |

- **RDS 선택 이유**: Aurora 대비 교육 예산 내 Multi-AZ HA 검증 충분, Aurora Serverless v2 최소 비용도 RDS 대비 높음
- **Zone Affinity**: 2a Pod → Replica-A, 2c Pod → Replica-C (Cross-AZ 비용 제거)
- **암호화**: storage_encrypted=true, KMS CMK 적용
- **스키마**: user_schema / product_schema / order_schema / notification_schema 분리

### 5.2 ElastiCache Redis

- Primary/Replica 구성 (at-rest + in-transit 암호화)
- 세션 캐싱, 상품 목록 캐싱, 장바구니 상태 저장
- automatic_failover_enabled=true

---

## 6. 공통 인프라 — 이커머스 애플리케이션

### 6.1 서비스 개요

- **언어/프레임워크**: Python + FastAPI, Alembic (DB 마이그레이션)
- **상품 데이터**: 무신사 크롤링 9,997개 상품 (패션 전 카테고리)
- **서비스 이벤트**: 16종 이벤트 JSON 로그 → 데이터 파이프라인 원천 데이터

### 6.2 핵심 API 엔드포인트

| 영역 | 엔드포인트 | 설명 |
|------|-----------|------|
| Auth | POST /api/auth/login | 로그인 (JWT 30분) |
| Products | GET /api/products | 상품 목록 (검색/필터/정렬) |
| Cart | POST /api/cart/items | 장바구니 담기 |
| Orders | POST /api/orders/from-cart | 장바구니 기반 주문 |
| Admin | GET /api/admin/dashboard | KPI 대시보드 |
| System | GET /api/health | 헬스체크 (readiness/liveness) |
| Simulate | GET /api/error-test | 장애 시뮬레이션 (order-service) |

### 6.3 주문 실패/지연 시뮬레이션

- 실패율: 평상시 5%, 프로모션 모드 15%
- 지연율: 3% 확률로 2~5초 응답 지연
- 실패 코드: OUT_OF_STOCK, PAYMENT_FAILED_SIMULATED, DB_TIMEOUT
- 목적: HPA 발동, CloudWatch 알람, Bedrock 분석 리포트 시나리오 생성

### 6.4 서비스 이벤트 로그 포맷 (16종)

```json
{
  "log_type": "SERVICE_EVENT",
  "event_type": "ORDER_FAILED",
  "event_time": "2026-06-30T10:12:00",
  "trace_id": "abc-123",
  "user_id": 1,
  "order_id": 1001,
  "status": "FAILED",
  "status_code": 500,
  "response_time_ms": 2860,
  "error_code": "DB_TIMEOUT"
}
```

---

## 7. 공통 인프라 — CDN / DNS / 인증서

### 7.1 CloudFront

| 배포 | 도메인 | 원본 |
|------|--------|------|
| 메인 (사용자) | fiveline.store | S3 정적 프론트엔드 + ALB (API) |
| 관리자 | dashboard.fiveline.store | ALB |

- CloudFront WAF (us-east-1) 연결 — 이커머스 특화 Rate Limit
- S3 OAC (Origin Access Control) — S3 직접 접근 차단
- 보안 응답 헤더: HSTS, CSP, X-Frame-Options 등

### 7.2 Route53 + ACM

- Route53: fiveline.store 호스팅 존 → CloudFront/ALB alias
- ACM 인증서 2개 (AWS 리전 제약):
  - ap-northeast-2: ALB TLS 인증서
  - us-east-1: CloudFront TLS 인증서 (반드시 us-east-1)

---

## 8. 공통 인프라 — 데이터 파이프라인

### 8.1 아키텍처

```
EKS Pod (Fluent Bit DaemonSet 수집)
  → CloudWatch Logs
  → Kinesis Firehose (300초 버퍼링, Dynamic Partitioning)
  → S3 Data Lake
      ├── raw/    (event_type별 파티셔닝)
      ├── cleansed/ (Glue ETL → Parquet, PII 마스킹)
      └── aggregated/ (집계 결과)
  → Glue Crawler → Data Catalog
  → Athena (SQL 분석)
  → Lambda report-generator → Bedrock → 자연어 리포트
```

### 8.2 S3 Lifecycle 정책

| 계층 | 31일 후 | 91일 후 | 만료 |
|------|---------|---------|------|
| raw | STANDARD_IA | GLACIER_IR | 365일 |
| cleansed | STANDARD_IA | GLACIER_IR | 1095일 (3년) |
| aggregated | STANDARD_IA | GLACIER_IR | 1825일 (5년) |

### 8.3 분석 지표

| 분류 | 지표 |
|------|------|
| 검색 | 시간대별 검색 수, TOP 검색 키워드, 결과 없는 키워드 |
| 전환율 | 상품 조회 → 장바구니 전환율, 장바구니 → 주문 전환율 |
| 주문 | 주문 성공/실패율, 실패 원인 TOP5 (DB_TIMEOUT, OUT_OF_STOCK 등) |

### 8.4 Bedrock AI 리포트

- 모델: Claude 3.5 Sonnet (anthropic.claude-3-5-sonnet-20241022-v2:0)
- 트리거: EventBridge 스케줄 (매일 09시, 매주 월요일 09시)
- 리포트 섹션: 운영 요약 / 핵심 지표 / 이상 징후 / 권고 사항
- 저장: S3 reports/daily/ + Slack 발송

---

## 9. 공통 인프라 — 모니터링/알람

### 9.1 CloudWatch Alarm 14개

| 알람 | 지표 | 임계값 | 심각도 |
|------|------|--------|--------|
| ALB 5xx | HTTPCode_Target_5XX_Count | > 1% | Critical |
| RDS 연결 수 | DatabaseConnections | > 136 (80%) | Warning |
| RDS 쓰기 지연 | WriteLatency | > 100ms | Critical |
| Redis HitRate | CacheHitRate | < 80% | Warning / < 60% Critical |
| Pod 재시작 | container_restarts | > 3 (30분) | Warning |
| HPA Max | current_replicas | = 6 | Critical |
| order P99 | TargetResponseTime p99 | > 2초 | Critical |
| 에러 버짓 번 레이트 | ErrorBudgetBurnRate | > 14.4 (1h) | Critical |

### 9.2 Grafana 골든 시그널 4행 대시보드

| 행 | 시그널 | 주요 패널 |
|----|--------|---------|
| Row 1 | Latency | ALB P50/P95/P99, order-service P99 게이지 |
| Row 2 | Traffic | ALB 요청 RPS, HPA currentReplicas, 노드 수 |
| Row 3 | Errors | ALB 5xx 비율, ORDER_FAILED 이벤트 수, Pod 재시작 |
| Row 4 | Saturation | 노드 CPU/Memory, RDS 커넥션, Redis HitRate |

### 9.3 SLO 목표

- 테스트 환경: 월간 가용성 99.9%
- prod 전환 시: 99.99% (AZ별 NAT + 시스템 노드 다중화)

---

## 10. 개인 발표 — 보안 (이재민)

### 10.1 발표 핵심 메시지

> "이커머스를 실제로 망하게 하는 공격은 따로 있다. 형식이 완전히 정상인 HTTP 요청이라 관리형 WAF 룰셋이 탐지하지 못한다. 그 공격에 맞는 설계가 필요하다."

### 10.2 보안 베이스라인 (공통 포함)

| 항목 | 구현 내용 | 상태 |
|------|----------|------|
| HTTPS/TLS | ACM + ALB/CloudFront TLS 1.2+ | ✅ |
| S3 OAC | CloudFront만 S3 접근 가능 | ✅ |
| RDS 암호화 | storage_encrypted=true, KMS CMK | ✅ |
| ElastiCache 암호화 | at-rest + in-transit | ✅ |
| EKS etcd 봉투 암호화 | KMS CMK로 K8s Secret 암호화 | ✅ |
| Secrets Manager + IRSA | ESO → K8s Secret 자동 동기화 | ✅ |
| Pod SecurityContext | runAsNonRoot, no privilege escalation | ✅ |
| CloudTrail | 전 리전 API 감사 로그, 무결성 검증 | ✅ |
| VPC Flow Logs | 네트워크 트래픽 감사 → CloudWatch | ✅ |
| WAF Managed Rules | SQLi, XSS, IP Reputation List | ✅ |
| GuardDuty | VPC 트래픽 행위 탐지 | ✅ |
| IMDSv2 | EC2 메타데이터 서비스 v2 강제 | ✅ |

---

## 11. 개인 발표 항목 1 — 이커머스 특화 WAF Custom Rate Limit

### 11.1 왜 필요한가

AWS 관리형 룰셋은 SQLi, XSS 등 **패턴 기반** 공격을 탐지한다. 이커머스를 실제로 위협하는 공격은 **형식이 완전히 정상인 HTTP 요청**이어서 관리형 룰셋으로 탐지할 수 없다.

| 공격 | 방식 | 피해 |
|------|------|------|
| 크리덴셜 스터핑 | 유출된 ID/PW를 /api/auth/login에 초당 수백 건 대입 | 계정 탈취 → 포인트/결제수단 도용 |
| 카드 BIN 어택 | 훔친 카드번호를 /api/orders에 대량 검증 | 결제사 제재, 매출 손실 |

### 11.2 핵심 설계 결정: Regional WAF가 아닌 CloudFront WAF에 배치

**이유**: Regional WAF는 ALB 앞에서 CloudFront Edge IP만 본다.  
`aggregate_key_type = "IP"` 집계가 개별 공격자 IP가 아닌 Edge IP 기준으로 동작해 Rate Limit이 무의미해진다.  
→ **실제 클라이언트 IP가 보이는 CloudFront WAF(us-east-1)에 배치**

```
CloudFront WAF (us-east-1)
  ├── ecommerce-login-ratelimit:  /api/auth/login  → 100 req / 5min  (priority 0)
  └── ecommerce-orders-ratelimit: /api/orders      → 100 req / 5min  (priority 1)
```

### 11.3 Before / After 데모

| | Before (COUNT 모드) | After (BLOCK 모드) |
|--|--------|-------|
| 스크립트 결과 | `[SUCCESS] a123@gmail.com JWT: eyJ...` | `[BLOCKED 429] a123@gmail.com` |
| 계정 피해 | 3 accounts compromised | 0 accounts compromised |

### 11.4 한계 및 Defense-in-Depth

WAF Rate Limit은 1차 방어선. IP 변경(프록시/봇넷)으로 우회 가능.
→ 애플리케이션 레벨 Rate Limit(IP당 1분 10회) + Account Lockout(5회 실패 시 잠금) 계층화 필요

---

## 12. 개인 발표 항목 2 — GuardDuty → Lambda → WAF Reactive SOAR

### 12.1 왜 필요한가

GuardDuty가 탐지해도 차단은 수동이었다. 보안 담당자가 콘솔에 접속해 WAF 룰을 추가하는 **수분~수시간의 공백** 동안 공격이 지속된다.

목표: **탐지와 차단 사이의 지연을 제거한다 (Auto-remediation)**

### 12.2 구현 아키텍처

```
GuardDuty Finding
  │
  ├── severity ≥ 4 (MEDIUM+) → EventBridge Rule 1 → SNS → 이메일 알림
  └── severity ≥ 7 (HIGH+)   → EventBridge Rule 2 → Lambda → WAF IP Set 자동 추가

  ※ HIGH finding은 두 룰 동시 발화 → 이메일 알림 + 자동 차단 병행
```

### 12.3 자동 차단을 HIGH에만 적용하는 이유

자동 차단은 오탐 시 정상 사용자를 차단하는 **파괴적 액션**이다.  
신뢰도가 높은 HIGH finding(≥7)에만 적용하고, MEDIUM은 사람이 판단하도록 알림에 머문다.

### 12.4 Lambda 구현 상세

GuardDuty Finding의 3가지 액션 타입에서 공격자 IP 추출:
- `networkConnectionAction` → `remoteIpDetails.ipAddressV4`
- `awsApiCallAction` → `remoteIpDetails.ipAddressV4`
- `portProbeAction` → `portProbeDetails[0].remoteIpDetails.ipAddressV4`

LockToken 기반 optimistic locking으로 동시 업데이트 충돌 방지.  
중복 IP skip 처리.

### 12.5 KMS 이슈 해결 스토리 (SA 역량 어필)

SNS 토픽이 KMS CMK로 암호화되어 있어 Lambda가 SNS publish 시 `KMSAccessDeniedException` 발생.  
원인 분석: Lambda IAM Role에 `kms:GenerateDataKey` + `kms:Decrypt` 권한 누락.  
→ `modules/security/main.tf`에 KMS 권한 추가로 해결.

### 12.6 Before / After 데모 내용

| | Before | After |
|--|--------|-------|
| EventBridge Rule 2 | disabled (is_enabled = false) | enabled |
| GuardDuty Sample Finding | UnauthorizedAccess:EC2/TorClient (HIGH) 생성 | 동일 |
| WAF IP Set | 비어있음 | 198.51.100.0/32 자동 추가됨 |
| SNS 이메일 | 발송 안됨 | "자동 차단 완료: 198.51.100.0 차단됨" |

### 12.7 알려진 개선 항목 (to-be) — SA 아키텍트 시각

| 항목 | 현재 한계 | 개선 방향 |
|------|----------|---------|
| DLQ 미설치 | 동시 HIGH finding 시 WAFOptimisticLockException → 차단 이벤트 소실 | EventBridge retry_policy + SQS DLQ 추가 |
| IP Set TTL 없음 | IP 누적만 되고 제거 메커니즘 없음 → 오탐 IP 영구 차단, 10,000개 한도 위험 | DynamoDB에 차단 시각 기록 + sweeper Lambda로 N일 후 자동 해제 |

---

## 13. 개인 발표 항목 3 — EKS Zero Trust 접근 경로 설계

### 13.1 Before / After

```
BEFORE                              AFTER
───────────────────────────────     ───────────────────────────────────────
인터넷                              인터넷
  ↓                                   ↓
EKS API 서버 (0.0.0.0/0 오픈)       [SSM Session Manager]
  ↓                                   ↓ (포트 22 없음, IAM 기반)
kubectl 명령 (누구든 가능)           Workstation EC2 (private subnet)
                                      ↓
                                    kubectl → EKS API 서버
                                               (443, private endpoint only)
```

### 13.2 5-layer 설계 (하나라도 빠지면 동작 안 함)

| 레이어 | 변경 내용 | 없으면 |
|--------|---------|--------|
| 네트워크 | Workstation → private subnet + NAT 라우팅 | SSM Agent AWS 통신 불가 |
| SG | EKS 클러스터 SG에 Workstation SG → 443 ingress | kubectl i/o timeout |
| IAM | eks:DescribeCluster + ARN 제한 | AccessDeniedException |
| RBAC | access_entry + ClusterAdminPolicy | credentials error |

### 13.3 NetworkPolicy (Zero Trust 완성)

```
IRSA: Pod → AWS 서비스 (남북 통제) ✅
NetworkPolicy: Pod ↔ Pod (동서 통제) — enableNetworkPolicy = "true" (eks.tf)

default-deny (namespace 전체 차단)
  + allow-order-to-product (order → product:8000만)
  + allow-egress-rds (모든 Pod → RDS:5432)
  = Pod 침해 시 인접 서비스로 이동 불가
```

---

## 14. 개인 발표 항목 4 — 웹스키밍 방어: CSP 강화

### 14.1 Magecart 공격 시나리오

```
XSS로 결제 페이지에 악성 스크립트 삽입
→ 카드번호 입력 시 공격자 서버로 실시간 전송
→ British Airways 2018: 50만 건, $230M 과징금
```

### 14.2 발견한 결함

```
# BEFORE — unsafe-inline이 CSP를 무력화
script-src 'self' 'unsafe-inline'
                  ^^^^^^^^^^^^^^^
                  인라인 스크립트 허용 → CSP 방어 전체 무력화

# AFTER — unsafe-inline 제거
script-src 'self'
(브라우저가 인라인 스크립트 실행 자체를 차단)
```

### 14.3 발표 멘트

> "보안 헤더를 달았다고 끝이 아닙니다. unsafe-inline 하나가 XSS 방어 전체를 무력화합니다. British Airways는 이 결함으로 $230M 과징금을 맞았습니다."

---

## 15. 발표 흐름 (개인 파트, 7~10분)

| 순서 | 내용 | 시간 | 핵심 포인트 |
|------|------|------|------------|
| 1 | 표지 + 이커머스 위협 모델 | 1분 | "관리형 룰셋이 못 막는 공격이 있다" |
| 2 | EKS Zero Trust 접근 경로 | 1분 30초 | 5-layer 설계, SSM 접속 화면 |
| 3 | WAF Custom Rate Limit (Before/After) | 2분 | CloudFront 배치 이유, 429 차단 데모 |
| 4 | GuardDuty SOAR (Before/After) | 2분 | Auto-remediation, KMS 이슈 해결 |
| 5 | CSP 웹스키밍 방어 | 30초 | unsafe-inline 결함 발견 |
| 6 | 종합 + 클로징 | 1분 | 위협→방어 매핑 테이블 |

---

## 16. 종합 위협 → 방어 매핑

| 이커머스 특화 위협 | 방어 설계 | 상태 |
|----------------|---------|------|
| 크리덴셜 스터핑 / 카드 BIN 어택 | CloudFront WAF Custom Rate Limit | ✅ |
| 악성 IP 탐지 후 수동 대응 공백 | GuardDuty → Lambda → WAF 자동 차단 | ✅ |
| K8s API 서버 인터넷 노출 | EKS private endpoint + SSM 접근 경로 | ✅ |
| Pod 침해 후 내부 이동 | IRSA(N-S) + VPC CNI NetworkPolicy(E-W) | ✅ |
| 결제 페이지 웹스키밍 | CSP unsafe-inline 제거 | ✅ |

**보안 베이스라인** (공통 발표):
HTTPS · ACM · S3 OAC · RDS 암호화 · KMS CMK · EKS etcd 봉투 암호화  
Secrets Manager + ESO · Pod SecurityContext · CloudTrail · VPC Flow Logs · GuardDuty · WAF 관리형 룰셋

---

## 17. 예상 Q&A

**Q: CloudFront WAF에 Rate Limit을 건 이유가 Regional WAF로 안 되는가?**
> A: "Regional WAF는 ALB 앞에서 CloudFront Edge IP만 봅니다. 전 세계 수천 개 Edge에서 들어오는 요청이 하나의 Edge IP로 집계되어 실제 공격자 IP 기준 Rate Limit이 동작하지 않습니다. CloudFront WAF에서만 실제 클라이언트 IP를 볼 수 있어 CloudFront WAF에 배치했습니다."

**Q: 자동 차단 시 정상 사용자가 차단될 위험은?**
> A: "HIGH severity(≥7)에만 자동 차단을 적용합니다. GuardDuty HIGH는 Tor 출구 노드, 알려진 C&C 서버 등 신뢰도가 매우 높은 위협만 해당합니다. MEDIUM은 사람이 판단할 수 있도록 이메일 알림에 머뭅니다."

**Q: Lambda가 WAF IP Set 업데이트할 때 동시성 문제는?**
> A: "LockToken 기반 optimistic locking을 사용합니다. WAFOptimisticLockException 발생 시 최신 LockToken을 재조회해 재시도합니다. 추가로 SQS DLQ를 두면 이벤트 소실도 방지할 수 있습니다."

**Q: NetworkPolicy는 Terraform이 아닌데?**
> A: "EKS VPC CNI의 Network Policy 기능 활성화는 `enableNetworkPolicy = true`로 Terraform에서 했습니다. 이 인프라 레이어 없이는 kubectl로 NetworkPolicy를 적용해도 아무 효과가 없습니다."

---

## 18. AWS 리소스 주요 식별자 (이재민 담당)

| 리소스 | 식별자 |
|--------|--------|
| CloudFront WAF | fiveline-cloudfront-waf (us-east-1) |
| GuardDuty Detector ID | 0dc6f205e5c84fe6b4a420a0dc159b4b |
| WAF IP Set | fiveline-guardduty-blocked-ips (fbc8cae6-45d5-43b3-b350-87eb9ce97bda) |
| Lambda | fiveline-guardduty-auto-block |
| EventBridge Rule (HIGH) | fiveline-guardduty-high-findings |
| EventBridge Rule (MEDIUM) | fiveline-guardduty-medium-findings |
| SNS Topic | fiveline-security-alerts |
| KMS Key | arn:aws:kms:ap-northeast-2:089955620282:key/36f986e5-1b58-4fc4-bc5a-d8ffc43d5ee9 |
| CloudTrail | fiveline-cloudtrail |
| S3 Data Lake | fiveline-s3-data-lake |
| EKS Cluster | fiveline-eks |
| RDS Primary | fiveline-rds-primary |
| ElastiCache | fiveline-redis |
