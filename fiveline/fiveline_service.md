# Fiveline Service Architecture

> 메가존 클라우드 파이널 프로젝트 (2025-05-11 ~ 2025-07-08)
> Data Analytics 및 CI/CD 환경의 컨테이너 기반 이커머스 아키텍처

---

## 1. 서비스 개요

Fiveline 프로젝트는 무신사, 올리브영과 같이 트래픽이 많은 이커머스 환경을 가정하여 **컨테이너 기반(EKS) 워크로드 운영, 실시간 데이터 수집/분석, 자동화된 CI/CD, 모니터링/알람, 그리고 Bedrock 기반 AI 분석/리포트**까지 End-to-End로 구현하는 클라우드 아키텍처 프로젝트이다. 이커머스 애플리케이션은 단순한 쇼핑몰이 아니라 **서비스 이벤트(검색·조회·장바구니·주문·리뷰)를 발생시키는 워크로드 발생원** 역할을 수행하며, 발생한 이벤트는 CloudWatch → Firehose → S3 Data Lake → Glue → Athena 파이프라인을 거쳐 운영 데이터 분석과 Bedrock Agent 분석의 기반 데이터로 활용된다.

---

## 2. 핵심 코어 서비스 목록

### 2.1 이커머스 애플리케이션 (Workload Source)

- **서비스명**: Fiveline E-Commerce Backend (user / product / order service)
- **역할 요약**: 회원가입·로그인, 상품 검색/조회, 장바구니, 주문, 리뷰 등 이커머스 핵심 기능을 제공하며 모든 사용자 행동을 **구조화된 이벤트 로그(JSON)** 로 발행한다. 백엔드는 **Python + Flask** 기반이며, DB 마이그레이션은 **Alembic**을 사용한다.
- **왜 필요한가**:
  - 이 서비스가 없으면 **데이터 분석 파이프라인에 흘릴 원천 이벤트 데이터가 존재하지 않는다.** 분석 지표(전환율, 주문 실패율, 검색 키워드)는 모두 이 서비스에서 발생하는 이벤트에 의존한다.
  - 트래픽 부하 시뮬레이션(평상시 95~98% / 프로모션 시 85~90%) 및 장애 시뮬레이션(OUT_OF_STOCK, DB_TIMEOUT, SLOW_RESPONSE)을 통해 **EKS Auto-scaling, RDS 부하, 알람 동작**을 검증하기 위한 필수 워크로드이다.
  - Bedrock Agent가 분석할 비즈니스 컨텍스트(매출, 주문 실패, 유저 행동)의 단일 진실 공급원(Single Source of Truth)이다.
- **구성 요소**:
  - Python + FastAPI 기반 5개 Microservice (user / product / order / admin / notification)
  - DB 마이그레이션: Alembic (init container 자동 실행)
  - RDS for PostgreSQL Primary Multi-AZ (Standby — HA 페일오버) + Read Replica × 2 (2a/2c AZ별 Zone Affinity 분산 — CQRS 패턴, Cross-AZ 비용 제거). Aurora 대신 RDS 선택 이유: 교육 예산 제약 + Multi-AZ로 충분한 HA 검증 범위, Aurora는 Serverless v2 최소 비용도 RDS 대비 높음
  - ElastiCache for Redis (Primary/Replica) — 세션/캐시
  - S3 (Frontend 정적 호스팅), CloudFront (배포)
  - SQS (order → notification 이벤트 발행)
- **백엔드 레포 구조** (fiveline-backend):
  - `docs/` — decisions, runbooks
  - `infra/` — 인프라 스크립트
  - `platform/` — glue-jobs, grafana-dashboards, lambda (데이터파이프라인/모니터링 팀원 담당)
  - `user-service/` (8001), `product-service/` (8002), `order-service/` (8003)
  - `admin-service/` (8004, NEW), `notification-service/` (8005, NEW)
- **연관 서비스**: EKS, ALB, RDS, ElastiCache, CloudWatch, Bedrock

---

### 2.2 컨테이너 인프라 (EKS Runtime)

- **서비스명**: Amazon EKS 기반 컨테이너 플랫폼
- **역할 요약**: 이커머스 마이크로서비스를 컨테이너로 실행하고, 트래픽 증감에 따라 자동 확장/축소하며, 안전한 무중단 배포 환경을 제공한다.
- **왜 필요한가**:
  - 이커머스 트래픽은 **프로모션 시 평상시 대비 수배 증가**하는 특성이 있어 정적 인프라(EC2 단독)로는 비효율적이며, **HPA/Cluster Autoscaler 기반 동적 확장이 필수**이다.
  - 마이크로서비스(user/product/order)를 **독립 배포·독립 스케일링**하려면 컨테이너 오케스트레이션이 반드시 필요하다.
  - ArgoCD GitOps와 결합하여 **선언적·감사 가능한 배포 운영**을 가능하게 하며, 이는 메가존 파이널 프로젝트의 핵심 요구사항이다.
- **구성 요소**:
  - EKS Cluster (Managed Control Plane)
  - On-Demand 노드 그룹 (`workload=stable`) — 베이스라인 2대 (min=2/max=4), 시스템+서비스 워크로드 모두 수용. 피크 시 Spot 가용성 역설 대응
  - Spot 노드 그룹 (`workload=spot`, taint: `spot=true:NoSchedule`) — 오버플로 버퍼, 평시 0대 / On-Demand 포화 시 최대 2대. **On-Demand 70% : Spot 30% 비율 유지**
  - 서비스 Pod 스케줄링: `nodeSelector` 없이 On-Demand 우선 배치, Spot toleration으로 오버플로 허용
  - AWS Load Balancer Controller + ALB Ingress
  - ArgoCD (GitOps Controller)
  - HPA (CPU 70% 기준, min 2 / max 6) — Pod 단위 자동 확장
  - **Cluster Autoscaler 또는 Karpenter** — 노드 단위 자동 확장 (HPA와 반드시 함께 동작해야 "탄력 확장" 스토리 성립. Must Have)
  - On-Demand 70% : Spot 30% 비율은 CA/Karpenter가 Spot 노드를 프로비저닝해야 실제 구현됨
  - PodDisruptionBudget (PDB) — Spot 회수 및 노드 드레인 시 서비스별 최소 1 Pod 보장
  - readiness/liveness probe (`/api/health` 엔드포인트)
  - k8s 보안 설계: DB 자격증명은 `secretKeyRef`로 주입, `podAntiAffinity preferred`로 AZ 간 Pod 분산
  - Pod SecurityContext: `runAsNonRoot`, `allowPrivilegeEscalation: false`, capabilities drop ALL
- **연관 서비스**: ECR, ALB, VPC, Route53, ACM, ArgoCD

---

### 2.3 데이터 수집/분석 파이프라인 (Data Lake & Analytics)

- **서비스명**: CloudWatch → Firehose → S3 Data Lake → Glue → Athena
- **역할 요약**: 이커머스 애플리케이션에서 발생한 서비스 이벤트 로그를 실시간으로 수집하여 S3 데이터 레이크에 적재하고, 카탈로그/스키마 관리를 통해 SQL 기반 분석을 가능하게 한다.
- **왜 필요한가**:
  - **분석 지표(검색 키워드 TOP, 장바구니→주문 전환율, 주문 실패 원인 TOP5)** 는 raw 이벤트 로그가 시계열 데이터 레이크에 축적되어야만 산출 가능하다.
  - RDS OLTP에서 직접 분석 쿼리를 실행하면 운영 DB 성능 저하가 발생하므로, **OLTP와 OLAP를 분리**해야 한다. (RDS Read Replica × 2는 실시간 조회 부하분산 용도이며, 이력성 집계 분석은 Athena에서 수행한다. 2c Replica는 데이터 파이프라인 쿼리 격리 담당.)
  - Bedrock Agent의 입력 데이터(매출 추이, 실패 패턴)는 Athena 쿼리 결과를 기반으로 하므로 **AI 리포트 기능의 전제 조건**이다.
- **구성 요소**:
  - CloudWatch Logs (Application Log 수집)
  - Kinesis Data Firehose (S3 적재 버퍼링)
  - S3 (Data Lake, Parquet 변환, 파티셔닝 by date/event_type)
  - AWS Glue (Crawler, Data Catalog)
  - Amazon Athena (SQL 분석 엔진)
- **연관 서비스**: EKS, Lambda, DynamoDB, Bedrock

---

### 2.4 모니터링/알람 (Observability)

- **서비스명**: CloudWatch + SNS + Lambda + DynamoDB 기반 알람 시스템
- **역할 요약**: EKS, RDS, ALB, 애플리케이션 지표/로그를 수집하고, 이상 징후 발생 시 알람을 발송하며 알람 이력을 영속화하여 운영 대시보드를 제공한다.
- **왜 필요한가**:
  - 이커머스 서비스에서 **장애 인지 지연은 곧 매출 손실**이며, 주문 실패율 급증·응답시간 지연을 실시간 감지하는 채널이 반드시 필요하다.
  - **SLO 목표 달성 여부를 측정·검증**하려면 메트릭 수집과 알람 임계치 운영이 전제되어야 한다. (테스트 환경: 99.9% 목표 / prod 전환 시 AZ별 NAT + 시스템 노드 다중화로 99.99% 목표)
  - 알람 이력을 DynamoDB에 저장하여 **사후 분석 및 대시보드 요약**이 가능해야 운영팀의 의사결정을 지원할 수 있다.
- **구성 요소**:
  - CloudWatch Metrics / Logs / Alarms
  - SNS (알람 토픽)
  - Lambda (Alarm Handler — 알람 정규화·저장)
  - DynamoDB (`alarm_history`, `dashboard_summary` 테이블)
  - CloudWatch Dashboard (알람 지표 시각화)
  - Grafana Dashboard (EKS/서비스 메트릭 심층 시각화 — `platform/grafana-dashboards/`)
- **연관 서비스**: EKS, RDS, ALB, Bedrock (리포트 트리거)

---

### 2.5 CI/CD (GitOps Pipeline)

- **서비스명**: GitHub Actions + ECR + Manifest Repo + ArgoCD
- **역할 요약**: 소스 코드 변경 시 자동으로 이미지를 빌드/푸시하고, Manifest Repo를 업데이트하여 ArgoCD가 EKS 클러스터에 선언적으로 배포한다.
- **왜 필요한가**:
  - 다수의 마이크로서비스를 수동 배포할 경우 **휴먼 에러와 배포 지연**이 발생하며, 이커머스의 빠른 기능 개선 속도를 따라갈 수 없다.
  - GitOps(Manifest Repo) 구조는 **모든 배포 이력을 Git으로 감사**할 수 있게 하며, 롤백을 단순 git revert로 수행할 수 있어 SRE 관점의 안정성을 보장한다.
  - 보안적으로 EKS 클러스터에 직접 push 권한을 부여하는 대신, ArgoCD가 pull 기반으로 동작하므로 **공격 표면을 축소**한다.
- **구성 요소**:
  - GitHub Repository (Source)
  - GitHub Actions (Build/Test/Push)
  - Amazon ECR (Container Registry)
  - Manifest Repository (Kubernetes YAML/Kustomize)
  - ArgoCD (Continuous Deployment, Image Tag Update)
- **연관 서비스**: EKS, IAM, KMS, Secrets Manager

---

### 2.6 보안 (Security Baseline)

- **서비스명**: WAF + KMS + Secrets Manager + IAM (+ ACM)
- **역할 요약**: 외부 공격 방어, 통신/저장 데이터 암호화, 비밀 정보 안전 관리, 최소 권한 원칙 적용으로 이커머스 환경의 보안 베이스라인을 구축한다.
- **왜 필요한가**:
  - 이커머스는 **개인정보(이메일, 비밀번호 해시)와 주문 데이터**를 다루므로, 암호화·접근 통제·감사 기능이 컴플라이언스 관점에서 필수이다.
  - CloudFront/ALB 앞단의 **WAF는 SQLi·XSS·봇 트래픽**을 차단하여 애플리케이션 부하 및 데이터 유출을 사전 방지한다.
  - DB 비밀번호, API Key를 코드/환경변수에 노출하지 않고 **Secrets Manager + IRSA**로 안전하게 주입해야 한다.
- **구성 요소**:
  - AWS WAF — 2개 배포 전략:
    - **REGIONAL WAF** (ALB 연결, ap-northeast-2) — API 서버 보호
    - **CLOUDFRONT WAF** (us-east-1에 별도 생성 필수, AWS 제약) — CDN 엣지 보호
  - ACM 인증서 — 2개 리전 분리 (AWS 제약):
    - **ap-northeast-2 ACM** — ALB용 TLS 인증서
    - **us-east-1 ACM** — CloudFront용 TLS 인증서 (CloudFront는 반드시 us-east-1 인증서 사용)
    - 적용 규칙: SQLi/XSS/Rate Limiting/Bot/IP Reputation
  - AWS KMS (CMK — RDS/S3/Secrets/EKS etcd 암호화 키, 자동 로테이션)
  - AWS Secrets Manager (DB Credential, API Key 중앙 관리)
  - **External Secrets Operator (ESO)** — IRSA로 Secrets Manager에서 값을 읽어 K8s Secret 자동 생성·동기화. Pod는 secretKeyRef로 참조
    - 전체 흐름: `Pod (IRSA) → Secrets Manager → ESO → K8s Secret → secretKeyRef → 컨테이너`
  - AWS IAM (IRSA — Pod별 최소권한 ServiceAccount 매핑)
  - ACM (TLS 인증서)
  - AWS CloudTrail (전 리전 API 호출 감사 로그, 무결성 검증)
  - VPC Flow Logs (네트워크 트래픽 감사·이상탐지)
  - EKS 컨트롤플레인 로그 (api/audit/authenticator — K8s API 감사 추적)
  - EKS etcd 봉투 암호화 (KMS CMK로 K8s Secret 암호화)
- **연관 서비스**: CloudFront, ALB, EKS, RDS, S3

---

### 2.7 Bedrock AI 분석/리포트 (Intelligence Layer)

- **서비스명**: EventBridge + Lambda + Amazon Bedrock + S3 (Report)
- **역할 요약**: 정기적으로(예: 일/주 단위) Athena·DynamoDB의 운영 데이터를 Bedrock LLM에 전달하여 자연어 리포트(매출 요약, 장애 분석, 인사이트)를 생성하고 S3에 저장한다. 운영자의 자연어 질의에 대한 챗봇 응답도 제공한다.
- **왜 필요한가**:
  - 운영자가 Athena SQL을 직접 작성하지 않고도 **"어제 주문 실패 원인 TOP3은?"** 같은 자연어 질의로 통찰을 얻을 수 있어야 한다.
  - 알람 발생 시 단순 메시지가 아닌 **AI가 컨텍스트(직전 1시간 메트릭, 유사 과거 장애)를 종합한 분석 리포트**를 제공하면 MTTR(평균 복구 시간)이 크게 단축된다.
  - 메가존 파이널 프로젝트의 차별화 포인트인 **데이터 분석 + AI 워크로드 통합** 시연을 가능하게 한다.
- **구성 요소**:
  - Amazon EventBridge (스케줄 트리거)
  - AWS Lambda (Report Generator)
  - Amazon Bedrock (Claude / Titan 모델)
  - S3 (Report Output, Versioning)
  - Athena / DynamoDB (입력 데이터 소스)
- **연관 서비스**: Athena, DynamoDB, CloudWatch, SNS

---

## 3. 서비스 간 데이터 흐름

### 3.1 사용자 트래픽 흐름

```
[User Browser]
     |
     v
[Route53] --> [CloudFront + WAF] --> [S3 Frontend (정적)]
                    |
                    v
              [ALB + WAF + ACM]
                    |
                    v
        [EKS Ingress Controller]
                    |
       +------------+------------+
       v            v            v
 [user-svc]   [product-svc]  [order-svc]
       |            |            |
       +-----+------+------+-----+
             v             v
          [RDS]      [ElastiCache]
```

### 3.2 이벤트 데이터 → 분석 → AI 리포트 흐름

```
[E-Commerce App on EKS]
   |  (JSON 이벤트 로그 발행)
   v
[CloudWatch Logs]
   |
   v
[Kinesis Data Firehose] ----(buffering / JSON 적재)--------+
                                  (Parquet 변환은 Glue ETL Job)         |
                                                          v
                                    [S3 Data Lake (raw / cleansed / aggregated)]
                                                          |
                                            +-------------+-------------+
                                            v                           v
                                      [AWS Glue Crawler]          [Athena Query]
                                            |                           |
                                            v                           |
                                     [Glue Data Catalog] <--------------+
                                                                        |
                                                                        v
                                                          +-------------+--------------+
                                                          |                            |
                                                          v                            v
                                              [EventBridge Schedule]          [운영자 Ad-hoc 분석]
                                                          |
                                                          v
                                                  [Lambda (Report)]
                                                          |
                                                          v
                                                  [Amazon Bedrock]
                                                          |
                                                          v
                                                  [S3 (AI Report)]
```

### 3.3 알람/모니터링 흐름

```
[EKS/RDS/ALB Metrics + App Logs]
        |
        v
[CloudWatch Metrics & Alarms]
        |
        v
      [SNS Topic]
        |
        v
   [Lambda (Alarm Handler)]
        |
        +-----> [DynamoDB: alarm_history]     -----> [Grafana Dashboard]
        +-----> [DynamoDB: dashboard_summary] -----> [Grafana Dashboard]
        +-----> [CloudWatch Dashboard]
        +-----> [Bedrock 분석 트리거 (옵션)]
```

### 3.4 CI/CD 흐름

```
[Developer Push]
        |
        v
[GitHub Repo (App Source)]
        |
        v
[GitHub Actions]
   - build / test
   - docker build
        |
        v
   [Amazon ECR]
        |
        v
[GitHub Actions: update image tag]
        |
        v
[Manifest Repo (k8s YAML)]
        |
        v
   [ArgoCD (Pull, Sync)]
        |
        v
[EKS Cluster: 새 버전 배포]
```

---

## 4. 이커머스 애플리케이션 상세

### 4.1 백엔드 API

| 영역 | Method | Endpoint | 설명 |
|------|--------|----------|------|
| Auth | POST | `/api/auth/signup` | 회원가입 (phone 선택) |
| Auth | POST | `/api/auth/login` | 로그인 (JWT 발급, 30분 만료) |
| Users | GET | `/api/users/me` | 내 프로필 조회 |
| Users | PUT | `/api/users/me` | 내 프로필 수정 (name, phone) |
| Products | GET | `/api/products` | 상품 목록 (q, category, brand, min_price, max_price, sort, page, size) |
| Products | GET | `/api/products/{productId}` | 상품 상세 |
| Reviews | POST | `/api/products/{productId}/reviews` | 리뷰 작성 |
| Reviews | GET | `/api/products/{productId}/reviews` | 리뷰 조회 |
| Cart | POST | `/api/cart/items` | 장바구니 담기 |
| Cart | GET | `/api/cart` | 장바구니 조회 |
| Cart | PATCH | `/api/cart/items/{cartItemId}` | 수량 변경 |
| Cart | DELETE | `/api/cart/items/{cartItemId}` | 항목 삭제 |
| Orders | POST | `/api/orders/from-cart` | 장바구니 기반 주문 |
| Orders | GET | `/api/orders/me` | 내 주문 내역 |
| Admin | GET | `/api/admin/dashboard` | 대시보드 통계 (role=admin) |
| Admin | GET | `/api/admin/orders` | 전체 주문 목록 (role=admin) |
| Admin | GET | `/api/admin/users` | 전체 사용자 목록 (role=admin) |
| Admin | GET | `/api/admin/products` | 전체 상품 목록 (role=admin) |
| Admin | PATCH | `/api/admin/products/{id}/stock` | 재고 수정 (role=admin) |
| Notifications | GET | `/api/notifications` | 내 알림 목록 |
| Notifications | POST | `/api/notifications/read/{id}` | 알림 읽음 처리 |
| System | GET | `/api/health` | 헬스체크 (각 서비스) |
| System | GET | `/api/error-test` | 장애 시뮬레이션 (order-service) |
| System | GET | `/api/slow-test` | 지연 시뮬레이션 (order-service) |

**제외 기능**: 실제 결제, 배송 관리, 쿠폰, 포인트, 소셜 로그인, 추천 시스템

### 4.2 DB 스키마 및 테이블 (RDS for PostgreSQL)

| 스키마 | 테이블 | 주요 컬럼 | 역할 |
|--------|--------|-----------|------|
| `user_schema` | `users` | id, email, password_hash, name, phone, role, created_at, updated_at | 회원 정보 |
| `product_schema` | `products` | id, name, description, category, brand, price, original_price, stock_quantity, image_url, ... | 패션 상품 카탈로그 |
| `product_schema` | `reviews` | id, product_id, user_id, rating, content, ... | 상품 리뷰 |
| `order_schema` | `cart_items` | id, user_id, product_id, quantity, ... | 장바구니 |
| `order_schema` | `orders` | id, user_id, total_price, status, error_code, response_time_ms, ... | 주문 헤더 (실패 원인 포함) |
| `order_schema` | `order_items` | id, order_id, product_id, quantity, price, created_at | 주문 라인 |
| `notification_schema` | `notifications` | id, user_id, type, title, message, is_read, created_at | 알림 내역 |

### 4.3 서비스 이벤트 로그

**이벤트 종류 (16종)**:
`USER_SIGNUP`, `USER_LOGIN`, `PRODUCT_LIST_VIEW`, `PRODUCT_SEARCH`, `PRODUCT_VIEW`, `CART_ITEM_ADDED`, `CART_VIEWED`, `CART_ITEM_UPDATED`, `CART_ITEM_REMOVED`, `ORDER_FROM_CART`, `ORDER_SUCCESS`, `ORDER_FAILED`, `REVIEW_CREATED`, `REVIEW_FAILED`, `API_ERROR`, `SLOW_RESPONSE`

**공통 JSON 포맷**:
```json
{
  "log_type": "SERVICE_EVENT",
  "event_type": "ORDER_FAILED",
  "event_time": "2026-05-13T10:12:00",
  "trace_id": "abc-123",
  "user_id": 1,
  "product_id": 1,
  "order_id": 1001,
  "category": "electronics",
  "api_path": "/api/orders/from-cart",
  "http_method": "POST",
  "status": "FAILED",
  "status_code": 500,
  "response_time_ms": 2860,
  "error_code": "DB_TIMEOUT",
  "environment": "prod"
}
```

이 포맷은 **CloudWatch Logs → Firehose → S3 Parquet → Athena**로 흐르며, `event_type` / `event_time` / `category`로 파티셔닝하여 쿼리 효율을 극대화한다.

### 4.4 분석 지표

| 분류 | 지표 |
|------|------|
| 검색 | 시간대별 검색 수, TOP 검색 키워드, 결과 없는 키워드 |
| 전환율 | 상품 조회 → 장바구니 전환율, 장바구니 → 주문 전환율 |
| 주문 | 주문 성공/실패율, 실패 원인 TOP5, 주문 → 리뷰 작성률 |
| 연계 | 주문 실패율 vs API 응답시간, vs EKS CPU, vs RDS Connection |

### 4.5 주문 실패/지연 시뮬레이션

- **실패 코드**: `OUT_OF_STOCK`, `PAYMENT_FAILED_SIMULATED`, `DB_TIMEOUT`, `INTERNAL_SERVER_ERROR`, `SLOW_RESPONSE`
- **성공률**: 평상시 95~98% / 프로모션 85~90%
- **목적**: HPA 동작, 알람 발화, Bedrock 분석 리포트 생성 검증

---

## 5. 개발 우선순위

### Must Have (1차 — 인프라/워크로드 가동의 최소 단위)

| # | 항목 | 상태 |
|---|------|------|
| 1 | **VPC / Subnet / NAT / Bastion** — 네트워크 베이스라인 | ✅ 구현 (NAT 1개, Bastion 예정) |
| 2 | **EKS Cluster + On-Demand/Spot 노드 그룹 분리 + ALB Ingress** — taint/toleration/nodeSelector 포함 | ✅ 노드 구성 완료 / ALB Ingress 예정 |
| 3 | **RDS PostgreSQL Multi-AZ(Standby) + Read Replica × 2(2a/2c) + ElastiCache** — 상태 저장소 | ✅ 구현 완료 |
| 4 | **ECR + GitHub Actions + ArgoCD** — CI/CD 파이프라인 | 📋 예정 |
| 5 | **이커머스 백엔드 핵심 API**: signup/login, products, cart, orders/from-cart, `/api/health` | ✅ 백엔드 레포 구현 |
| 6 | **HPA (3개 서비스) + readiness/liveness probe** — Pod 탄력 확장 및 무중단 배포 전제 | ✅ 구현 완료 |
| 7 | **Cluster Autoscaler 또는 Karpenter** — HPA Pod 증가 시 노드까지 자동 확장. 70:30 비율 실현의 필수 전제 | 📋 예정 |
| 8 | **PodDisruptionBudget (PDB)** — Spot 회수/노드 드레인 시 최소 1 Pod 보장 | 📋 예정 |
| 9 | **CloudWatch Logs + Firehose + S3 Data Lake + Glue + Athena** — 이벤트 분석 파이프라인 | 📋 예정 |
| 10 | **IAM (IRSA) + External Secrets Operator + Secrets Manager + KMS + ACM** — 보안 베이스라인 | 🔄 진행 중 |
| 11 | **CloudFront + S3 Frontend + Route53 + WAF (REGIONAL/CLOUDFRONT 분리)** — 사용자 진입점 | 📋 예정 |
| 12 | **Terraform S3 Remote Backend + DynamoDB Lock** — 팀 협업 State 관리 | 📋 예정 |

### Should Have (2차 — 운영 안정성 및 분석 고도화)

| # | 항목 | 상태 |
|---|------|------|
| 1 | **EKS 컨트롤플레인 로그 + etcd 봉투 암호화(KMS)** — 감사 추적 완성 | 📋 예정 |
| 2 | **NetworkPolicy** — Pod 간 동서 트래픽 default-deny | 📋 예정 |
| 3 | **CloudWatch Alarm + SNS + Lambda + DynamoDB** (alarm_history, dashboard_summary) | 📋 예정 |
| 4 | **Reviews API + Orders direct API** | ✅ 백엔드 레포 구현 |
| 5 | **주문 실패/지연 시뮬레이션 엔드포인트** (`/api/error-test`, `/api/slow-test`) | ✅ 백엔드 레포 구현 |
| 6 | **CloudWatch Dashboard + Grafana Dashboard** (전환율, 실패율, 응답시간) | 🔄 Grafana 구성 진행 중 |

### Could Have (3차 — 차별화/고도화)

| # | 항목 |
|---|------|
| 1 | **EventBridge + Lambda + Bedrock + S3 (AI Report)** — 일/주간 자동 리포트 |
| 2 | **Bedrock Agent 기반 운영 챗봇** — 자연어 질의 → Athena 쿼리 |
| 3 | **분산 추적**: AWS X-Ray 또는 OpenTelemetry |
| 4 | **카오스 엔지니어링**: AWS FIS를 통한 장애 주입 자동화 |
| 5 | **Cross-Region DR** 시나리오 검증 |
| 6 | **FinOps 대시보드** (Cost Explorer + Athena 비용 분석) |

---

## 부록: 핵심 코어 서비스 매핑 요약

| # | 영역 | 대표 서비스 | 산출물 |
|---|------|-------------|--------|
| 1 | 이커머스 애플리케이션 | EKS Pod (Python/Flask MSA) | 서비스 이벤트 로그 |
| 2 | 컨테이너 인프라 | EKS + ALB + ArgoCD | 무중단 배포된 워크로드 |
| 3 | 데이터 수집/분석 | CloudWatch → Firehose → S3 → Glue → Athena | 분석 지표 |
| 4 | 모니터링/알람 | CloudWatch + SNS + Lambda + DynamoDB + Grafana | 알람 이력, CloudWatch + Grafana 대시보드 |
| 5 | CI/CD | GitHub Actions + ECR + ArgoCD | 자동 배포 파이프라인 |
| 6 | 보안 | WAF + KMS + Secrets Manager + IAM | 컴플라이언스 베이스라인 |
| 7 | AI 분석/리포트 | EventBridge + Lambda + Bedrock + S3 | 자연어 리포트, 챗봇 |
