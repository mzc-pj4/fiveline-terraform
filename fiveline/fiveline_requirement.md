# Fiveline 프로젝트 요구사항 분석

> 메가존 클라우드 파이널 프로젝트 (2025-05-11 ~ 2025-07-08)
> 3개 전문 에이전트(Cloud Architect / SRE / Security Engineer) 병렬 분석 기반 작성

---

## 1. 문서 개요

| 항목 | 내용 |
|------|------|
| 프로젝트명 | Fiveline — 이커머스 기반 Data Analytics & CI/CD 클라우드 아키텍처 |
| 작성 기준 | 실제 Terraform 코드 + k8s 매니페스트 대조 분석 |
| 요구사항 총계 | 기능 요구사항 63건 / 비기능 요구사항 115건 / 합계 178건 |
| 우선순위 체계 | Must (필수) / Should (권장) / Could (선택) |

---

## 2. 프로젝트 개요

**시나리오**: 무신사, 올리브영과 같이 트래픽이 많은 이커머스 기업으로부터 인프라 아키텍처 설계 및 운영을 의뢰받은 MSP로서, 컨테이너 기반 이커머스 서비스를 구축하고 Data Analytics, CI/CD, 모니터링, AI 분석까지 End-to-End로 제공한다.

**핵심 목표**:
- 고트래픽(프로모션 시 최대 10배 폭증) 환경에서의 안정적인 서비스 운영
- 서비스 이벤트 데이터를 수집·분석하여 비즈니스 인사이트 제공
- Bedrock AI 챗봇 및 자동 리포트로 운영 효율화
- 보안·비용·확장성의 균형 잡힌 아키텍처 설계

**기술 스택**:
- 백엔드: Python + Flask MSA (user/product/order-service), Alembic
- DB: RDS PostgreSQL 16.3 (Multi-AZ Standby + Read Replica)
- 캐시: ElastiCache Redis 7 (Primary + Replica)
- 컨테이너: EKS (On-Demand 1개 + Spot 2~6개)
- 데이터: CloudWatch → Firehose → S3 → Glue → Athena
- AI: EventBridge → Lambda → Amazon Bedrock → S3
- CI/CD: GitHub Actions → ECR → Manifest Repo → ArgoCD

---

## 3. 이해관계자

| 역할 | 관심사 |
|------|--------|
| 이커머스 고객사 | 서비스 안정성, 트래픽 대응, 보안 |
| 운영 엔지니어 | 모니터링, 알람, 장애 대응, 대시보드 |
| 개발자 | CI/CD 자동화, 배포 속도, 롤백 |
| 경영진 | 비용 최적화, 비즈니스 지표, AI 리포트 |
| 메가존 심사위원 | 아키텍처 타당성, 기술 선택 근거, 완성도 |

---

## 4. 기능 요구사항

### 4.1 이커머스 서비스 기능 (SVC)

| ID | 요구사항 | 상세 설명 | 우선순위 | 관련 서비스 |
|----|---------|----------|---------|------------|
| SVC-001 | 회원가입 | 이메일/비밀번호 가입, 비밀번호 해시 저장(bcrypt), 입력 검증 | Must | user-service, RDS |
| SVC-002 | 로그인 / JWT 인증 | 로그인 성공 시 JWT 발급, 만료·갱신 처리. JWT 서명키는 secretKeyRef로 주입 | Must | user-service, JWT |
| SVC-003 | 인증/인가 미들웨어 | 보호된 API는 JWT 검증, 사용자 본인 리소스만 접근(IDOR 방지) | Must | user-service |
| SVC-004 | 상품 목록 조회 | 페이지네이션·정렬 지원 상품 목록 API | Must | product-service |
| SVC-005 | 상품 검색 | 키워드·카테고리 필터 검색. 조회 트래픽은 RDS Read Replica 활용 | Must | product-service, RDS Replica |
| SVC-006 | 상품 상세 | 상품 단건 상세 조회. 인기 상품은 Redis 캐싱 | Must | product-service, ElastiCache |
| SVC-007 | 장바구니 CRUD | 담기/수정/삭제/조회. 장바구니 상태 Redis 저장으로 고트래픽 대응 | Must | order-service, Redis |
| SVC-008 | 주문 생성 | 장바구니 기반 주문 생성, 재고 차감, 트랜잭션 정합성 보장 | Must | order-service, RDS |
| SVC-009 | 주문 조회 | 사용자별 주문 내역·상세 조회 | Must | order-service |
| SVC-010 | 리뷰 작성/조회 | 구매 사용자 리뷰 작성, 상품별 리뷰 목록 조회, 입력 검증(XSS 방지) | Should | product-service |
| SVC-011 | 서비스 이벤트 로그 발행 | 가입·로그인·조회·장바구니·주문·리뷰 등 16종 이벤트 JSON 로그 발행 | Must | 전체 서비스, CloudWatch |
| SVC-012 | 주문 실패/지연 시뮬레이션 | 프로모션 모드에서 의도적 실패·지연 유발로 장애 대응·모니터링 검증 | Should | order-service |
| SVC-013 | 헬스체크 API | 각 서비스 `/api/health` 제공 (readiness/liveness probe 연동) | Must | 전체 서비스 |
| SVC-014 | API 입력 검증·Rate Limit | 전 API 입력 스키마 검증, 애플리케이션 레벨 속도 제한 | Should | 전체 서비스 |

### 4.2 CI/CD 파이프라인 (CICD)

| ID | 요구사항 | 상세 설명 | 우선순위 | 관련 서비스 |
|----|---------|----------|---------|------------|
| CICD-001 | 완전 자동 파이프라인 | 코드 push 시 수동 개입 없이 빌드→테스트→이미지 빌드→푸시→배포 자동 실행 | Must | GitHub Actions |
| CICD-002 | GitOps Pull 기반 배포 | 클러스터가 Manifest Repo를 pull하여 동기화(ArgoCD). CI의 직접 kubectl push 금지 | Must | ArgoCD |
| CICD-003 | 앱·매니페스트 리포 분리 | 애플리케이션 코드 리포와 K8s Manifest 리포 분리. CI는 이미지 태그만 Manifest Repo에 커밋 | Must | GitHub |
| CICD-004 | 브랜치 전략 | `main`→`staging`→`prod` 흐름. 환경별 Kustomize 오버레이로 매니페스트 분리 | Must | Git, Kustomize |
| CICD-005 | 동일 실행 환경 보장 | 컨테이너 이미지로 빌드·테스트·운영 동일성 확보. 이미지 태그는 커밋 SHA 사용(`latest` 운영 배포 금지) | Must | Docker, ECR |
| CICD-006 | 이미지 취약점 스캔 | 파이프라인에 Trivy/ECR 스캔 단계 포함. Critical/High 취약점 발견 시 배포 차단 | Must | Trivy, ECR |
| CICD-007 | SAST 정적분석 | 소스 정적분석(CodeQL/Bandit-Python)으로 코드 취약점 조기 차단 | Must | CodeQL, Bandit |
| CICD-008 | Secret 스캐닝 | 커밋·PR에서 하드코딩 시크릿 탐지(Gitleaks)로 유출 차단 | Must | Gitleaks |
| CICD-009 | IaC 보안 스캔 | Terraform 보안 스캔(tfsec/Checkov)으로 미암호화·퍼블릭 노출 사전 탐지 | Should | tfsec, Checkov |
| CICD-010 | 무중단 배포 | RollingUpdate 기본 적용. 핵심 서비스(order)는 Canary/Blue-Green 고려 | Must | K8s RollingUpdate, Argo Rollouts |
| CICD-011 | 즉시 롤백 | ArgoCD 이전 동기화 리비전으로 즉시 롤백. 불변 태그로 롤백 대상 명확화 | Must | ArgoCD |
| CICD-012 | 배포 이력 추적 | 모든 배포가 Git 커밋으로 기록(Who/What/When). ArgoCD 히스토리 보존 | Must | Git, ArgoCD |
| CICD-013 | 배포 승인 게이트 | prod 배포는 PR 리뷰 승인 + GitHub Environment protection(수동 승인) | Must | GitHub Environments |
| CICD-014 | ArgoCD Sync 정책 | staging은 auto-sync + self-heal, prod는 manual-sync. drift 자동 감지 | Should | ArgoCD |
| CICD-015 | 키리스 인증(OIDC) | GitHub Actions→AWS 접근 시 장기 액세스키 금지, OIDC 임시 자격증명 사용 | Should | GitHub OIDC, IAM |
| CICD-016 | 빌드 아티팩트 무결성 | 이미지 서명(Cosign)·SBOM 생성을 파이프라인에 통합 | Should | Cosign, Syft |

### 4.3 데이터 파이프라인 (DATA)

| ID | 요구사항 | 상세 설명 | 우선순위 | 관련 서비스 |
|----|---------|----------|---------|------------|
| DATA-001 | 로그 중앙 수집 | 애플리케이션/액세스/인프라 로그를 CloudWatch Logs로 수집(Fluent Bit DaemonSet) | Must | CloudWatch Logs, Fluent Bit |
| DATA-002 | 실시간 스트리밍 적재 | CloudWatch Logs Subscription → Kinesis Firehose → S3 Data Lake | Must | Kinesis Firehose |
| DATA-003 | S3 Data Lake 계층화 | raw / cleansed / aggregated 3계층 분리. 계층별 접근·암호화 정책 적용 | Must | S3, KMS |
| DATA-004 | 데이터 파티셔닝 | `year=/month=/day=/hour=` + `service=` 파티션 키 적용. Firehose Dynamic Partitioning | Must | S3, Firehose, Glue |
| DATA-005 | Glue 표준화/카탈로그 | Glue Crawler로 스키마 자동 등록, Glue Job으로 raw→cleansed 정제(타입 캐스팅, 중복 제거, PII 마스킹) | Must | Glue Crawler, Glue Job |
| DATA-006 | Athena 분석 | 워크그룹별 스캔량 제한, Parquet+압축으로 비용 절감 | Must | Athena |
| DATA-007 | 집계 결과 DynamoDB 저장 | 대시보드·조회용 집계 지표를 DynamoDB에 저장(저지연 조회) | Should | DynamoDB |
| DATA-008 | 데이터 보존 정책 | raw: 90일 후 Glacier, 1년 후 삭제. cleansed/aggregated 장기 보관 | Must | S3 Lifecycle, Glacier |
| DATA-009 | 처리 SLA | 실시간 적재 지연 < 5분, 일배치 정제 SLA(익일 06시 완료). 미달 시 알람 | Should | CloudWatch Alarm, EventBridge |
| DATA-010 | 데이터 품질 검증 | Glue Data Quality 룰(Null 비율, 스키마 일관성). 실패 시 quarantine prefix 격리 | Should | Glue Data Quality |
| DATA-011 | PII 보호/마스킹 | 주문/회원 데이터 내 개인정보 마스킹/토큰화. 접근 로깅 | Must | Glue, KMS |
| DATA-012 | 파이프라인 오케스트레이션 | Glue Workflow 또는 Step Functions로 Crawler→ETL→집계 의존성 관리 | Should | Step Functions, Glue Workflow |
| DATA-013 | 스키마 진화 대응 | 로그 포맷 변경 시 스키마 버저닝, 하위호환 보장 | Could | Glue Schema Registry |
| DATA-014 | 데이터 접근 제어 | Lake Formation으로 테이블/컬럼 레벨 접근 제어 | Could | Lake Formation |

### 4.4 AI 운영 지원 + 리포트 자동화 (AI)

| ID | 요구사항 | 상세 설명 | 우선순위 | 관련 서비스 |
|----|---------|----------|---------|------------|
| AI-001 | 자연어 질의 | 운영자가 자연어로 지표·로그 질의 → Bedrock Agent가 **사전 정의된 Lambda Action Group 함수**(get_dashboard_summary, query_order_failure 등)를 호출하여 DynamoDB/Athena 조회 후 요약. 임의 SQL 자유 생성 방식은 비용·보안 리스크로 제외 | Must | Bedrock, Athena, Lambda |
| AI-002 | 운영 챗봇 | Slack 연동 챗봇으로 질의응답, 알람 컨텍스트 제공. 권한 기반 응답 범위 제한 | Should | Bedrock, Lambda, Slack API |
| AI-003 | 일간/주간 정기 리포트 | EventBridge 스케줄 → Lambda → Bedrock 요약 → S3 저장 → Slack 발송 | Must | EventBridge, Lambda, Bedrock |
| AI-004 | 장애 리포트 자동화 | 알람 트리거 시 관련 로그·지표 수집 → Bedrock이 원인 추정·영향 범위·타임라인 정리 | Must | EventBridge, CloudWatch, Bedrock |
| AI-005 | Bedrock 모델 선택 기준 | 용도별 모델 매핑 문서화(예: Claude=장문 분석/리포트, 경량 모델=실시간 챗봇) | Must | Bedrock |
| AI-006 | 리포트 형식 표준화 | 리포트 템플릿(요약/핵심지표/이상징후/권고사항 섹션). Slack 메시지 + S3 마크다운 | Should | Bedrock, S3 |
| AI-007 | 데이터 소스 정의 | 트래픽=ALB/CloudFront, 에러=CloudWatch, 분석=Athena, 비용=Cost Explorer | Must | Athena, CloudWatch |
| AI-008 | 갱신 주기 정의 | 실시간 챗봇(온디맨드), 일간(매일 09시), 주간(월요일 09시), 장애(이벤트 트리거) | Should | EventBridge |
| AI-009 | 프롬프트 거버넌스 | 프롬프트 템플릿 버전 관리, 환각 방지(RAG), 민감정보 미노출 가드레일 | Should | Bedrock Guardrails |
| AI-010 | AI 비용 통제 | Bedrock 토큰 사용량·호출 비용 모니터링, 모델 호출 한도 설정 | Should | CloudWatch, Cost Explorer |
| AI-011 | 리포트 아카이브/감사 | 생성 리포트 S3 버저닝 보관, 접근 로깅, 보존 정책 적용 | Could | S3, CloudTrail |

### 4.5 운영자 대시보드 (DASH)

| ID | 요구사항 | 상세 설명 | 우선순위 | 관련 서비스 |
|----|---------|----------|---------|------------|
| DASH-001 | 통합 단일 대시보드 | 서비스 지표·인프라 지표·알람·리포트를 하나의 Grafana 대시보드에서 조회 | Must | Grafana |
| DASH-002 | EKS 인프라 지표 | 노드·Pod CPU/Memory, Pod 재시작·Pending, HPA 스케일, On-Demand/Spot 노드그룹 상태 | Must | Grafana, Prometheus, metrics-server |
| DASH-003 | 트래픽/엣지 지표 | ALB 요청수·5xx·지연(TargetResponseTime), CloudFront 캐시 적중률, WAF 차단 건수 | Must | CloudWatch, ALB, WAF |
| DASH-004 | 데이터 계층 지표 | RDS CPU/연결수/Replica Lag, ElastiCache Hit Rate/메모리/Eviction | Must | CloudWatch, RDS, ElastiCache |
| DASH-005 | 서비스 비즈니스 지표 | 가입·로그인·주문 성공/실패율, 주문 처리 지연(이벤트 로그 기반) | Should | Prometheus, 이벤트 로그 |
| DASH-006 | 알람/알림 연동 | 임계치 초과 시 Grafana Alerting → Slack/이메일. 핵심 SLI 알람 | Must | Grafana Alerting, Slack |
| DASH-007 | 대시보드 갱신 주기 | 인프라/트래픽 패널 15~30초, 비즈니스 리포트 패널 1~5분 단위 갱신 | Should | Prometheus scrape_interval |
| DASH-008 | 접근 제어 | 대시보드는 운영자만 접근(SSO/OIDC + RBAC). 외부 노출 금지 | Must | Grafana RBAC, SSO |
| DASH-009 | Bedrock 챗봇 연동 | 자연어로 지표·로그·알람 질의. 운영자 한정·읽기 전용 권한 | Should | Amazon Bedrock |
| DASH-010 | 리포트 패널 | 일/주 단위 트래픽·주문·에러 요약 리포트 패널 | Could | Grafana |

---

## 5. 비기능 요구사항

### 5.1 인프라/네트워크 (INFRA)

| ID | 요구사항 | 상세 설명 | 우선순위 | 관련 서비스 |
|----|---------|----------|---------|------------|
| INFRA-001 | 네트워크 4계층 격리 | Public(ALB/NAT) / Private-EKS / Private-RDS / Private-Cache 서브넷 CIDR 분리 | Must | VPC, Subnet |
| INFRA-002 | 멀티 AZ 이중화 | 모든 계층을 ap-northeast-2a/2c 2개 AZ에 분산 | Must | VPC, EKS, RDS |
| INFRA-003 | 데이터 계층 완전 격리 | RDS/ElastiCache SG를 EKS 클러스터 SG 참조로만 제한 | Must | Security Group |
| INFRA-004 | EKS 엔드포인트 노출 최소화 | **현재 `endpoint_public_access=true`. prod는 private-only 또는 운영자 IP 화이트리스트로 제한 필요** | Must | EKS Cluster |
| INFRA-005 | On-Demand/Spot 혼합 노드 | 시스템 워크로드는 On-Demand, 서비스 워크로드는 Spot taint 분리 (현 구성) | Must | EKS Node Group |
| INFRA-006 | 오토스케일링 트래픽 대응 | HPA(Pod) + **Cluster Autoscaler/Karpenter(Node)** 조합. CA/Karpenter 없이는 On-Demand 70:Spot 30 비율이 실현되지 않으며 HPA가 무의미. **Must Have로 HPA와 반드시 함께 구현** | Must | HPA, Karpenter/CA |
| INFRA-007 | NAT Gateway 다중 AZ | prod 전환 시 AZ별 NAT Gateway 분리 (현재 테스트용 1개) | Should | NAT Gateway |
| INFRA-008 | ALB Ingress + TLS | AWS Load Balancer Controller, ACM TLS, HTTP→HTTPS 리다이렉트 | Must | ALB, ACM |
| INFRA-009 | CloudFront CDN | 정적 자산 캐싱, Origin Shield, ALB origin 보호 | Must | CloudFront, S3 |
| INFRA-010 | Route53 DNS | 도메인 관리, ALB/CloudFront alias, 헬스체크 기반 페일오버 | Must | Route53 |
| INFRA-011 | WAF 적용 | WAFv2 2개 배포: **REGIONAL**(ALB, ap-northeast-2) + **CLOUDFRONT**(us-east-1 별도 생성 필수, AWS 제약). Managed Rule(SQLi/XSS) + Rate-based Rule | Must | WAFv2 |
| INFRA-012 | 시크릿/암호화 | RDS 자격증명은 Secrets Manager, 데이터는 KMS CMK 암호화 | Must | Secrets Manager, KMS |
| INFRA-013 | VPC Endpoint | S3/ECR/CloudWatch/STS PrivateLink로 NAT 비용·노출 축소 | Should | VPC Endpoint |
| INFRA-014 | Pod Disruption Budget | Spot 회수 시 서비스별 최소 가용 Pod 보장 (minAvailable: 1) | Must | K8s PDB |
| INFRA-015 | RDS Read Replica / Proxy | 조회 트래픽 Read Replica 분산, 커넥션 폭증 시 RDS Proxy 흡수 | Should | RDS Replica, RDS Proxy |
| INFRA-016 | VPC Flow Logs | 네트워크 트래픽 감사·이상탐지용 수집 | Must | VPC Flow Logs | ✅ SEC-051과 통합 구현 완료 (`cloudtrail.tf`) |
| INFRA-017 | 멀티 리전 DR | prod 한정, RPO/RTO 기반 백업 리전 또는 Pilot Light | Could | Route53, RDS Cross-Region |

### 5.2 가용성/안정성 (AVAIL)

| ID | 요구사항 | 상세 설명 | 우선순위 | 측정 기준 |
|----|---------|----------|---------|----------|
| AVAIL-001 | SLO 정의 | 서비스별 월간 가용성 SLO 수립. 테스트 환경 99.9%, prod 목표 99.99% | Must | HTTP 5xx 비율 < 0.1% (30일 롤링) |
| AVAIL-002 | 에러 버짓 정책 | 에러 버짓 50% 소진 시 기능 배포 속도 조정, 100% 소진 시 피처 프리즈 | Must | 번 레이트 > 2x 시 알람 |
| AVAIL-003 | Multi-AZ 장애 격리 | 단일 AZ 장애 시 서비스 유지. (현재 NAT 단일 구성 — prod 개선 필요) | Must | 단일 AZ 장애 시 다운타임 0초 |
| AVAIL-004 | Spot 회수 대응 | NTH(Node Termination Handler)로 2분 전 노티스 수신 후 자동 드레인 | Must | Pod 재스케줄 완료 < 90초 |
| AVAIL-005 | PodDisruptionBudget | 각 서비스 PDB minAvailable: 1로 롤링 업데이트·노드 드레인 중 최소 1 Pod 유지 | Must | 업데이트 중 5xx = 0건 |
| AVAIL-006 | RDS 페일오버 목표 | Multi-AZ 자동 페일오버 + 애플리케이션 재연결 포함 복구 시간 | Must | 전체 복구 < 120초 |
| AVAIL-007 | Redis 페일오버 대응 | automatic_failover_enabled=true (현 구성). 페일오버 중 캐시 미스 시 DB 폴백 | Must | 페일오버 완료 < 60초 |
| AVAIL-008 | 프로모션 폭증 대응 | 정규 트래픽 대비 최대 10배 폭증 사전 부하 테스트 검증 | Must | 10배 폭증 시 에러율 < 5%, 오토스케일 < 5분 (5배에서는 SLO 유지, PERF-005 통일) |
| AVAIL-009 | 서비스 간 장애 격리 | 하위 서비스 장애 시 서킷 브레이커로 전파 차단 | Should | 하위 장애 시 상위 서비스 가용성 유지 |
| AVAIL-010 | 유지보수 창 정의 | 계획된 유지보수 vs 비계획 장애 허용 범위 분리. RDS 유지보수: 일 03:00~04:00 | Should | 비계획 장애 MTTR < 30분 |

### 5.3 성능 (PERF)

| ID | 요구사항 | 상세 설명 | 우선순위 | 측정 기준 |
|----|---------|----------|---------|----------|
| PERF-001 | user-service 응답시간 | 로그인/토큰 발급 API 엔드투엔드 응답시간 | Must | P50 < 200ms / P95 < 500ms / P99 < 1,000ms |
| PERF-002 | product-service 응답시간 | 상품 목록/상세. 캐시 히트/미스 목표 분리 | Must | P99 < 300ms(캐시히트) / P99 < 800ms(DB) |
| PERF-003 | order-service 응답시간 | 주문 생성(복합 처리). 가장 엄격하게 관리 | Must | P50 < 300ms / P95 < 800ms / P99 < 2,000ms |
| PERF-004 | 처리량(TPS) 목표 | 서비스별 평시 최대 처리량. HPA max 스케일 시 수용 가능 TPS | Must | 평시: user 100 / product 200 / order 50 TPS |
| PERF-005 | 프로모션 트래픽 허용 범위 | 정규 트래픽 대비 5배 SLO 유지, 10배 에러율 < 5% | Must | 10배 초과 시 로드 쉐딩 발동 |
| PERF-006 | HPA 발동 기준 검증 | CPU 70% 도달 후 스케일 업 Pod Ready 상태까지 | Must | < 90초. order-service는 60%로 선제 발동 권고 |
| PERF-007 | 리소스 요청/한도 적정성 | OOMKilled 방지. CPU Throttling 비율 최소화 | Should | OOMKilled = 0, CPU Throttling < 10% |
| PERF-008 | DB 쿼리 성능 | 슬로우 쿼리 탐지·인덱스 점검 | Should | 슬로우 쿼리 임계값 1초, 일 발생 < 100건 |
| PERF-009 | 네트워크 지연 | EKS Pod → RDS/Redis 구간 내부 지연 | Should | EKS→RDS P99 < 5ms / EKS→Redis P99 < 2ms |
| PERF-010 | 부하 테스트 정기 실행 | 프로모션 전 2주, 정기 월 1회. Locust/k6 사용 | Should | HPA 최대 수용량 검증, 병목 TOP3 식별 |

### 5.4 보안 (SEC)

#### 5.4.1 네트워크 보안

| ID | 요구사항 | 상세 설명 | 우선순위 | 관련 서비스 |
|----|---------|----------|---------|------------|
| SEC-001 | VPC 격리 및 서브넷 분리 | Public/Private-EKS/Private-RDS/Private-Cache 4계층 분리 | Must | VPC, Subnet |
| SEC-002 | 핵심 리소스 외부 접근 차단 | RDS·ElastiCache·EKS 워커노드는 Private Subnet 배치, 퍼블릭 IP 미할당 | Must | Private Subnet, ALB |
| SEC-003 | EKS API 엔드포인트 최소 노출 | `endpoint_public_access=true` 유지 (교육용). ✅ `eks.tf`에 prod 전환 시 `public_access_cidrs` 제한 주석 명시. prod에서는 운영자 IP/CI 대역으로 제한 필요 | Must | EKS Cluster |
| SEC-004 | SG 최소 권한 원칙 | RDS/Redis ingress는 EKS 클러스터 SG만 허용. ✅ RDS SG egress `0.0.0.0/0` → VPC CIDR(`10.10.0.0/16`)로 제한 완료 | Must | Security Group |
| SEC-005 | Kubernetes NetworkPolicy | default-deny 후 서비스 간 필요 통신만 명시 허용 | Should | NetworkPolicy |
| SEC-006 | NAT/VPC Endpoint | VPC Endpoint로 ECR/S3/STS 접근 사설화 | Should | VPC Endpoint |

#### 5.4.2 암호화/키 관리

| ID | 요구사항 | 상세 설명 | 우선순위 | 관련 서비스 |
|----|---------|----------|---------|------------|
| SEC-010 | 저장 데이터 암호화 | RDS `storage_encrypted=true`, ElastiCache `at_rest_encryption_enabled=true`, EBS 암호화 | Must | KMS, RDS, ElastiCache |
| SEC-011 | 전송 데이터 암호화 | TLS 1.2+ 강제, ElastiCache `transit_encryption_enabled=true`, RDS `sslmode=require` | Must | ACM, TLS |
| SEC-012 | KMS 고객관리키(CMK) | 서비스별 CMK 생성 + 자동 로테이션. RDS/EBS/Secrets/S3에 적용 | Should | KMS CMK |
| SEC-013 | EKS Secret 봉투 암호화 | etcd 내 K8s Secret을 KMS로 암호화 | Should | KMS, EKS encryption_config |

#### 5.4.3 자격증명 관리

| ID | 요구사항 | 상세 설명 | 우선순위 | 관련 서비스 |
|----|---------|----------|---------|------------|
| SEC-020 | IRSA / Pod Identity 적용 | Pod별 최소권한 ServiceAccount 매핑(IRSA). ✅ OIDC Provider + 서비스별 IAM Role(user/product/order) + Secrets Manager 최소권한 정책 구현 완료 | Must | IRSA, EKS Pod Identity, IAM |
| SEC-021 | Secrets Manager + ESO 통합 | 앱 시크릿은 Secrets Manager 저장. **External Secrets Operator(ESO)**가 IRSA 권한으로 SM에서 값을 읽어 K8s Secret 자동 생성·갱신. Pod는 secretKeyRef로 참조. 전체 흐름: `Pod(IRSA) → SM → ESO → K8s Secret → secretKeyRef` | Must | Secrets Manager, ESO, IRSA |
| SEC-022 | secretKeyRef 사용 | 컨테이너 환경변수 평문 금지, `secretKeyRef`로 주입 (현 매니페스트 적용됨) | Must | K8s Secret |
| SEC-023 | 시크릿 로테이션 | DB 자격증명·JWT 서명키 자동 로테이션 | Should | Secrets Manager Rotation |
| SEC-024 | IAM 최소권한·검토 | 와일드카드(*) 정책 금지. Access Analyzer로 미사용 권한 정기 검토 | Must | IAM, Access Analyzer |

#### 5.4.4 WAF/엣지 보안

| ID | 요구사항 | 상세 설명 | 우선순위 | 관련 서비스 |
|----|---------|----------|---------|------------|
| SEC-030 | WAF 배포 | ✅ `waf.tf` 구현 완료. REGIONAL(ALB 연결), CloudFront 연결 시 us-east-1 provider 추가 필요 | Must | WAFv2 |
| SEC-031 | OWASP 공격 차단 | AWS Managed Rules(CommonRuleSet, SQLi, KnownBadInputs) 적용 | Must | WAF Managed Rules |
| SEC-032 | Rate Limiting | IP 기준 요청 속도 제한으로 로그인/주문 API 무차별 대입·DoS 방어 | Must | WAF Rate-based Rule |
| SEC-033 | Bot 탐지 | 매크로·스크래핑·재고 사재기 봇 탐지. WAF Bot Control 또는 Captcha | Should | WAF Bot Control |
| SEC-034 | 지역/IP 평판 차단 | Amazon IP Reputation List 적용, GeoMatch 선택 적용 | Could | WAF IPSet, GeoMatch |
| SEC-035 | CloudFront 엣지 보안 | ALB 직접 접근 차단, 보안 응답 헤더(HSTS, CSP) 부여 | Should | CloudFront |

#### 5.4.5 컨테이너/공급망 보안

| ID | 요구사항 | 상세 설명 | 우선순위 | 관련 서비스 |
|----|---------|----------|---------|------------|
| SEC-040 | 컨테이너 이미지 스캔 | **ECR 미구현. Enhanced Scanning(Inspector) 활성화. Critical/High 취약점 시 배포 차단** | Must | ECR, Inspector |
| SEC-041 | Pod SecurityContext | ✅ `k8s/*.yaml` 3개 서비스 — `runAsNonRoot`, `allowPrivilegeEscalation: false`, `capabilities drop ALL` 적용 완료 | Must | K8s SecurityContext |
| SEC-042 | Pod Security Standards | 네임스페이스에 PSA `restricted` 레벨 적용 | Should | Pod Security Admission |
| SEC-043 | 이미지 서명·검증 | Cosign 서명 + admission controller로 미서명 이미지 거부 | Should | Cosign, Kyverno |
| SEC-044 | SBOM 생성·관리 | 빌드 시 SBOM(Syft) 생성·보관으로 공급망 취약점 추적 | Should | Syft |
| SEC-045 | ECR 거버넌스 | 이미지 태그 불변(immutable), 오래된 이미지 라이프사이클 정책 | Should | ECR Lifecycle |
| SEC-046 | 런타임 위협 탐지 | GuardDuty EKS Runtime Monitoring 또는 Falco | Could | GuardDuty, Falco |

#### 5.4.6 감사 로깅/거버넌스

| ID | 요구사항 | 상세 설명 | 우선순위 | 관련 서비스 |
|----|---------|----------|---------|------------|
| SEC-050 | 리소스 변경 이력 기록 | ✅ `cloudtrail.tf` 구현 완료 — 멀티리전 Trail, S3 감사 버킷(암호화+퍼블릭차단), 무결성 검증 활성화 | Must | CloudTrail |
| SEC-051 | VPC Flow Logs | ✅ `cloudtrail.tf` 구현 완료 — VPC Flow Logs → CloudWatch Logs(`/aws/vpc/flowlogs/`) 30일 보존 | Must | VPC Flow Logs |
| SEC-052 | EKS 컨트롤플레인 로그 | api/audit/authenticator 로그 활성화 | Must | EKS Control Plane Logging |
| SEC-053 | 구성 규정준수 | AWS Config로 리소스 드리프트·비준수 자동 탐지 | Should | AWS Config |
| SEC-054 | 위협 탐지 | GuardDuty로 비정상 API 호출·크리덴셜 유출 탐지 | Should | GuardDuty |
| SEC-055 | 보안 상태 통합 | Security Hub로 CIS/AWS 표준 벤치마크 점수화 | Should | Security Hub |
| SEC-056 | 로그 보존·중앙화 | 감사/애플리케이션 로그 중앙 수집, 보존주기 정의, 삭제 방지 | Should | S3, CloudWatch Logs |
| SEC-057 | 침해 대응 절차 | 탐지→격리→포렌식→복구 런북 정의 및 정기 훈련 | Could | Runbook, IR Plan |

### 5.5 모니터링/알람 (MON)

| ID | 요구사항 | 상세 설명 | 우선순위 | 측정 기준 |
|----|---------|----------|---------|----------|
| MON-001 | EKS CPU/Memory 수집 | metrics-server 기반 노드/Pod 수집. CloudWatch Container Insights | Must | 수집 주기 60초 |
| MON-002 | ALB 5xx 알람 | 5xx 응답 비율 초과 시 즉시 알람. 503(Spot 회수) 전용 알람 분리 | Must | 5분 평균 5xx > 1% 시 Critical |
| MON-003 | RDS 지표 모니터링 | DatabaseConnections, ReadLatency, WriteLatency, FreeStorageSpace | Must | Connections > 80% 시 Warning, WriteLatency > 100ms 시 Critical |
| MON-004 | Redis Hit Rate | CacheHitRate, CacheMisses, ReplicationLag 수집 | Must | HitRate < 80% Warning / < 60% Critical |
| MON-005 | Pod 재시작 알람 | OOMKilled, CrashLoopBackOff 등 비정상 재시작 감지 | Must | 30분 내 3회 이상 재시작 시 Warning |
| MON-006 | HPA 스케일 이벤트 | HPA scaleUp/Down 이벤트 기록. maxReplicas 도달 시 알람 | Must | max(6) 도달 시 Critical |
| MON-007 | Spot 회수 이벤트 감지 | EventBridge로 인터럽션 노티스 수신 → DynamoDB 이벤트 로그 기록 | Must | 회수 이벤트 후 30초 내 Slack 알람 |
| MON-008 | API 응답시간 P95/P99 | ALB TargetResponseTime 백분위수. 서비스별 포트 기준 분리 측정 | Must | order-service P99 > 2초 시 Critical |
| MON-009 | 알람 노이즈 억제 | DatapointsToAlarm으로 단발성 스파이크 알람 방지 | Must | 연속 2개 데이터 포인트 위반 시 발화 |
| MON-010 | 알람 채널·에스컬레이션 | SNS→Lambda→DynamoDB + Slack 웹훅. 5분 무응답 시 자동 에스컬레이션 | Must | Critical 알람 수신→확인 < 5분 |
| MON-011 | Grafana 대시보드 구성 | 골든 시그널 4행 구성(Latency/Traffic/Errors/Saturation) | Must | 갱신 주기 30초 |
| MON-012 | 로그 중앙화·추적 | trace_id 기반 서비스 간 분산 추적 | Should | 장애 발생 시 전체 경로 추적 < 5분 |
| MON-013 | SLO 번 레이트 대시보드 | 에러 버짓 소진율 실시간 시각화 | Should | 1시간 번 레이트 > 14.4x 시 Critical |
| MON-014 | CA 스케일 이벤트 모니터링 | Pending Pod 대기 시간, 노드 Ready 시간 (CA 설치 예정) | Should | Pending → 노드 Ready < 4분 |

### 5.6 장애 대응/복구 (IR)

| ID | 요구사항 | 상세 설명 | 우선순위 | 측정 기준 |
|----|---------|----------|---------|----------|
| IR-001 | RTO 목표 정의 | 장애 유형별 복구 시간 목표 | Must | 단순(Pod/노드) < 5분 / RDS 페일오버 < 10분 / 전체 < 30분 |
| IR-002 | RPO 목표 정의 | 데이터 손실 허용 범위. RDS PITR 활성화 | Must | RPO < 5분. 주문 데이터 RPO = 0 |
| IR-003 | 장애 심각도 분류 | P1~P4 4단계 정의. 심각도별 대응 시간 SLA | Must | P1: 즉시 대응, 15분 내 상태 업데이트 |
| IR-004 | 롤백 자동화 | 에러율 임계값 초과 시 자동 롤백 트리거. ArgoCD GitOps 롤백 | Must | 수동 롤백 실행 < 5분 |
| IR-005 | Spot 회수 대응 런북 | Spot 전량 회수 시나리오 런북화. On-Demand 수동 스케일 아웃 절차 포함 | Must | 런북 기반 대응 절차 30분 내 완료 |
| IR-006 | RDS 페일오버 런북 | Primary 장애→Standby 승격→DNS 갱신→재연결 확인 절차 문서화 | Must | 런북 기반 완료 < 15분 |
| IR-007 | 에스컬레이션 경로 | 온콜→팀 리드→서비스 오너→CTO 자동 에스컬레이션 | Must | P1 장애 15분 내 팀 리드 에스컬레이션 |
| IR-008 | 포스트모템 프로세스 | P1/P2 장애 72시간 내 포스트모템 초안 작성. Blameless 문화 | Must | 액션 아이템 2주 내 완료율 > 80% |
| IR-009 | HPA 동작 검증 | 월 1회 HPA 강제 트리거 테스트. metrics-server 가용성 알람 추가 | Must | 정기 검증으로 HPA 정상 동작 확인 |
| IR-010 | CA 동작 검증 | 노드 스케일 아웃 전체 흐름 검증 (CA 설치 예정) | Should | Pending Pod → 노드 Ready < 4분 |
| IR-011 | 장애 훈련(Game Day) | Spot 회수, RDS 페일오버, Redis 장애 시나리오 실행 | Should | 분기 1회 실시, RTO 목표 달성 여부 측정 |
| IR-012 | 온콜 런북 | 각 알람에 대응하는 런북(증상→진단→조치→에스컬레이션) 작성 | Should | 런북 없는 알람 = 0건 목표 |
| IR-013 | 비상 접근 권한 관리 | 장애 시 AWS Console·kubectl·RDS 자격증명 접근 경로 사전 확인 | Should | MFA 설정 완료, 분기 1회 갱신 |
| IR-014 | 재해 복구(DR) 계획 | 리전 전체 장애 대응. RDS 스냅샷 크로스 리전 복사 | Could | DR RTO < 4시간(수동 복구 기준) |

### 5.7 비용/FinOps (COST)

| ID | 요구사항 | 상세 설명 | 우선순위 | 관련 서비스 |
|----|---------|----------|---------|------------|
| COST-001 | 서비스별/일자별 비용 산정 | Cost Allocation Tag(`Service`, `env`) 기반 일자별·서비스별 비용 리포트 | Must | Cost Explorer, Cost Allocation Tags |
| COST-002 | 태깅 표준 강제 | 필수 태그(Service/env/owner) 미부착 리소스 탐지. Tag Policy + Config 룰 | Must | AWS Config, Organizations |
| COST-003 | 사용량 기반 예상 비용 | 사용량 추세로 월말 예상 비용 산출, 전월 대비 증감 분석 | Should | Cost Explorer, Cost Anomaly Detection |
| COST-004 | 미사용 리소스 탐지 | 미사용 EIP/유휴 EBS/저활용 노드/오래된 스냅샷 탐지 및 리포트 | Should | Trusted Advisor, Compute Optimizer |
| COST-005 | 비용 이상 알람 | ML 기반 이상 지출 감지 시 Slack/이메일 알림 | Must | Cost Anomaly Detection, SNS |
| COST-006 | 예산 임계값 알림 | 월 예산 50/80/100% 도달·예측 초과 시 알람. 환경별 예산 분리 | Must | AWS Budgets, SNS |
| COST-007 | Spot 비용 절감 검증 | Spot vs On-Demand 절감액 정량화, Spot 회수율 모니터링 | Must | Cost Explorer, CloudWatch |
| COST-008 | Savings Plans 분석 | 안정 워크로드에 Compute Savings Plans/RI 적용 권고 및 커버리지 추적 | Should | Cost Explorer, Savings Plans |
| COST-009 | 데이터 파이프라인 비용 통제 | Athena 스캔량/Firehose/S3 비용 모니터링. 워크그룹 스캔 한도 설정 | Should | Athena Workgroup, Cost Explorer |
| COST-010 | 환경별 비용 가드레일 | dev 환경 야간/주말 자동 셧다운, prod와 비용 분리 | Could | EventBridge, Lambda, Budgets |
| COST-011 | 단위 경제성 지표 | 주문 1건당/요청 1건당 인프라 비용 산출 | Could | Cost Explorer, Athena |

---

## 6. 제약 조건

| 구분 | 내용 |
|------|------|
| 기간 | 2025-05-11 ~ 2025-07-08 (약 2개월) |
| 환경 | AWS 서울 리전(ap-northeast-2) 단일 리전 |
| 비용 | 교육 프로젝트 예산 내 운영. Spot 인스턴스 활용으로 비용 최적화 |
| 팀 구조 | 팀 공통 프로젝트(핵심 코어 서비스) + 개인 프로젝트(확장/강화) 분리 |
| 시연 | 발표 시에만 전체 인프라 가동. 평소에는 비용 절감 우선 |
| 실제 결제 | 이커머스 실제 결제/배송/쿠폰/포인트 기능 제외 |
| 보안 | 교육용이나 실제 자격증명 노출 금지, 프로덕션급 보안 설계 적용 |

---

## 7. 요구사항 우선순위 매트릭스

### Must Have 핵심 요약 (즉시 구현 대상)

| 영역 | Must 건수 | 핵심 항목 |
|------|----------|----------|
| 이커머스 서비스 (SVC) | 10 | 회원/상품/장바구니/주문/이벤트로그/헬스체크 |
| CI/CD (CICD) | 11 | 자동파이프라인/GitOps/보안게이트/롤백/이력 |
| 데이터 파이프라인 (DATA) | 7 | 로그수집/S3적재/Glue/Athena/PII보호 |
| AI/리포트 (AI) | 5 | 자연어질의/정기리포트/장애리포트/데이터소스 |
| 대시보드 (DASH) | 5 | 통합대시보드/EKS지표/ALB지표/RDS지표/알람 |
| 인프라 (INFRA) | 9 | 서브넷격리/멀티AZ/EKS/ALB/CloudFront/Route53/WAF |
| 가용성 (AVAIL) | 8 | SLO/멀티AZ격리/Spot대응/RDS페일오버/프로모션대응 |
| 성능 (PERF) | 6 | 서비스별응답시간/TPS/HPA발동기준 |
| 보안 (SEC) | 17 | 네트워크격리/암호화/IAM/WAF/이미지스캔/CloudTrail |
| 모니터링 (MON) | 10 | EKS/ALB/RDS/Redis/Pod/HPA/응답시간 알람 |
| 장애대응 (IR) | 9 | RTO/RPO/심각도분류/롤백/런북 |
| 비용 (COST) | 5 | 태깅/비용이상알람/예산임계값/Spot절감검증 |
| **합계** | **102** | |

---

## 8. 주요 위험 및 현재 코드 갭 분석

### ✅ 해결 완료 (6건)

| 위험 | 조치 전 | 요구사항 | 조치 결과 |
|------|--------|---------|----------|
| EKS API 퍼블릭 노출 | `endpoint_public_access=true` 전체 개방 | SEC-003 | `eks.tf` — prod 전환 시 `public_access_cidrs` 제한 주석 명시 |
| WAF 부재 | 미구현 | SEC-030~032 | `waf.tf` 신규 생성 — Managed Rules(CommonRuleSet/SQLi/IP Reputation) + Rate Limiting(2000req/5min) |
| CloudTrail 부재 | 미구현 | SEC-050 | `cloudtrail.tf` 신규 생성 — 전 리전 Trail, S3 감사 버킷, 무결성 검증 활성화 |
| VPC Flow Logs 부재 | 미구현 | SEC-051 | `cloudtrail.tf` — VPC Flow Logs → CloudWatch Logs 수집 구현 |
| Pod SecurityContext 부재 | k8s 매니페스트에 없음 | SEC-041 | `k8s/*.yaml` 3개 — Pod/Container 레벨 `runAsNonRoot`, `allowPrivilegeEscalation: false`, `capabilities drop ALL` 적용 |
| IRSA 미연결 | 애드온만 설치, 역할 매핑 없음 | SEC-020 | `iam.tf` — OIDC Provider + 서비스별 IAM Role 3개 + Secrets Manager 최소권한 정책 |
| RDS SG egress 과도 | `0.0.0.0/0` 전체 허용 | SEC-004 | `rds.tf` — egress를 VPC 내부(`10.10.0.0/16`)로 제한 |

### 구조적 리스크 (SRE 관점)

| 위험 | 현재 상태 | 관련 요구사항 |
|------|----------|-------------|
| NAT Gateway 단일 AZ | 2a에만 존재. 2a 장애 시 2c 노드 아웃바운드 단절 | AVAIL-003, INFRA-007 |
| On-Demand 노드 min=2/max=4 | Spot 전량 회수 시 On-Demand 2대로 서비스 Pod 흡수. 단, CA 미설치 시 확장 불가 | AVAIL-004, IR-005 |
| metrics-server On-Demand 의존 | On-Demand 노드 장애 시 HPA 동작 불능 위험 (min=2로 단일 장애점 완화) | MON-001, IR-009 |
| Cluster Autoscaler 미설치 | HPA Pod 증가 시 노드 확장 주체 없음 | INFRA-006, MON-014 |
| PDB 미구현 | Spot 회수 시 최소 가용 Pod 보장 없음 | INFRA-014, AVAIL-005 |

### 미구현 주요 인프라 (Must Have 예정)

ECR, GitHub Actions 파이프라인, ArgoCD, CloudFront, Route53, KMS CMK, Cluster Autoscaler, PDB, External Secrets Operator

> ✅ WAF(`waf.tf`), CloudTrail+VPC Flow Logs(`cloudtrail.tf`), IRSA(`iam.tf`) 구현 완료

---

## 9. 이벤트 로그 표준 (서비스→분석 연계 기준)

**이벤트 종류 (16종)**:
`USER_SIGNUP`, `USER_LOGIN`, `PRODUCT_LIST_VIEW`, `PRODUCT_SEARCH`, `PRODUCT_VIEW`,
`CART_ITEM_ADDED`, `CART_VIEWED`, `CART_ITEM_UPDATED`, `CART_ITEM_REMOVED`,
`ORDER_FROM_CART`, `ORDER_SUCCESS`, `ORDER_FAILED`, `REVIEW_CREATED`, `REVIEW_FAILED`,
`API_ERROR`, `SLOW_RESPONSE`

**공통 JSON 포맷**:
```json
{
  "log_type": "SERVICE_EVENT",
  "event_type": "ORDER_FAILED",
  "event_time": "2025-06-01T10:12:00",
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

**분석 파이프라인**: CloudWatch Logs → Firehose(Parquet, `event_type/date` 파티션) → S3 Data Lake → Glue → Athena → Bedrock

---

*본 문서는 Cloud Architect / SRE / Security Engineer 3개 전문 에이전트가 실제 Terraform 코드 및 k8s 매니페스트를 대조 분석하여 작성하였습니다.*
