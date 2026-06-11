# Fiveline 데이터 파이프라인 설계

> 메가존 클라우드 파이널 프로젝트 (2025-05-11 ~ 2025-07-08)
> Cloud Architect / Database Administrator / DevOps Engineer 3개 에이전트 병렬 분석 기반

---

## 1. 개요

### 한 줄 정의

> 서비스 이벤트 로그는 **Fluent Bit → CloudWatch Logs → Firehose → S3 Data Lake**로,
> 인프라 메트릭은 **Container Insights / CloudWatch Metric Stream → S3**로 수집하고,
> **Glue + Athena**로 결합 분석하여 **DynamoDB 요약 테이블**에 저장,
> **Admin Dashboard / Bedrock Agent / Report Generator**가 활용한다.

### 전체 흐름 (5개 영역)

```
① 발생 (Source)
  EKS Pod (user/product/order-service), ALB, RDS, ElastiCache

② 수집 (Ingest)
  Fluent Bit DaemonSet → CloudWatch Logs → Subscription Filter → Firehose
  Container Insights + CloudWatch Metric Stream (인프라 메트릭)
  CloudWatch Alarm → SNS (알람 이벤트)

③ 저장/정제/분석 (Store & Analyze)
  S3 Data Lake (raw / cleansed / aggregated 3계층)
  Glue Crawler (스키마 카탈로그) + Glue ETL Job (PII 마스킹/정제/집계)
  Amazon Athena (SQL 분석, 워크그룹 스캔 제한)

④ 요약 (Summarize)
  DynamoDB Summary Tables (저지연 조회용)
  EventBridge → Lambda(Report) → Bedrock → S3(Report)

⑤ 활용 (Consume)
  Admin Dashboard (Grafana), Bedrock Agent (자연어 질의)
  Slack 알림, 자동 리포트
```

---

## 2. 전체 아키텍처 다이어그램

```
═══════════════════════════════════════════════════════════════════════
 ① 발생 (Source)
═══════════════════════════════════════════════════════════════════════

┌─────────────────────────┐
│  EKS Cluster             │
│  (On-Demand 70% + Spot 30%)
│ ┌──────┬───────┬───────┐ │  stdout JSON (SERVICE_EVENT, 16종)
│ │user  │product│order  │─┼──────────────────────────────────┐
│ │ svc  │  svc  │  svc  │ │                                  │
│ └──────┴───────┴───────┘ │                                  ▼
│                           │               ┌─────────────────────────┐
│ [Fluent Bit DaemonSet]    │               │  CloudWatch Logs         │
│  *spot=true toleration*   │               │ /fiveline/dev/svc-events │
│  *tail /var/log/cri*      │──(cri parser)─▶ /fiveline/dev/app-logs   │
└─────────────────────────┘               └───────────┬─────────────┘
                                                        │ Subscription Filter
┌──────────────────────┐                              │
│ 인프라 메트릭          │                              ▼
│ Container Insights    │  ┌──────────────────────────────┐
│ Prometheus/kube-state │  │  Kinesis Data Firehose        │
│ CloudWatch Metric     │──┤  buffer: 128MB / 300초        │
│   Stream              │  │  Dynamic Partitioning (JQ)    │
└──────────────────────┘  └───────────────┬──────────────┘
                                           │ Parquet (cleansed 이후)
═══════════════════════════════════════════│═══════════════════════════
 ③ 저장/정제/분석
═══════════════════════════════════════════│═══════════════════════════
                                           ▼
                           ┌──────────────────────────────────────┐
                           │  S3 Data Lake                         │
                           │  s3://fiveline-{env}-data-lake/       │
                           │  ├── raw/         (원본 JSON, 90d→Glac)│
                           │  ├── cleansed/    (Parquet+Snappy,PII) │
                           │  ├── aggregated/  (집계 지표)          │
                           │  └── quarantine/  (파싱 실패 격리)    │
                           └──────────────┬───────────────────────┘
                                          │
                        ┌─────────────────┴─────────────────┐
                        ▼                                   ▼
               ┌─────────────────┐               ┌────────────────────┐
               │ Glue Crawler     │               │ Glue ETL Job        │
               │ (스키마 카탈로그) │               │ raw→cleansed        │
               │  Recrawl: 매시30분│              │ PII 마스킹/중복제거  │
               └────────┬────────┘               │ Glue Data Quality   │
                        │                        │ (Step Functions 오케) │
                        ▼                        └────────┬────────────┘
               ┌─────────────────┐                        │
               │ Glue Data Catalog│◀───────────────────────┘
               │ fiveline_dev_    │        ▲ cleansed/aggregated 완료 후
               │ analytics DB     │        │ Crawler 재실행 (매일06:10)
               └────────┬────────┘
                        │
                        ▼
               ┌─────────────────┐
               │  Amazon Athena   │
               │  워크그룹 스캔   │
               │  제한:10GB/5GB   │
               └────────┬────────┘
                        │
════════════════════════│════════════════════════════════════
 ④ 요약 (Summarize / AI)
═══════════════════════════════════════════════════════════

 ┌──────────────┐       ├──────────────────────────────────┐
 │EventBridge   │       │  DynamoDB Summary Tables          │
 │(스케줄/이벤트)│──────▶│  - alarm_history                  │
 │일 09시/주 월  │       │  - dashboard_summary              │
 └──────────────┘       │  - hourly_order_summary           │
         │              │  - infra_health_summary           │
         ▼              │  - report_metadata                │
 ┌──────────────┐       │  - resource_check_results         │
 │Lambda(Report)│◀──────┘                                  │
 │  Athena 조회  │                                          │
 │  DynamoDB 조회│                                          │
 └──────┬───────┘                                          │
        ▼                                                  │
 ┌──────────────┐                                          │
 │Amazon Bedrock│ (Action Group + Knowledge Base + Guard.)  │
 │Claude 3.5    │                                          │
 └──────┬───────┘                                          │
        ▼                                                  │
 ┌──────────────┐                                          │
 │S3 Report     │◀─────────────────────────────────────────┘
 │Versioning    │
 └──────────────┘

═══════════════════════════════════════════════════════════
 ⑤ 활용 (Consume)
═══════════════════════════════════════════════════════════

 [CloudWatch Alarm]──▶[SNS]──▶[Lambda(Alarm Handler)]──▶[DynamoDB + Slack]
 [EventBridge: EC2 Spot Interruption]──▶[Lambda]──▶[DynamoDB + Slack]  ← 별도 경로
 [운영자]──자연어 질의──▶[Bedrock Agent]──▶[Action Group(Athena/DynamoDB)]
                                        └──▶[Knowledge Base(RAG, 런북/리포트)]
 [Grafana / CloudWatch Dashboard]◀── 집계 지표
 [Slack]◀── 리포트/알람
```

---

## 3. 데이터 종류별 파이프라인

### 3.1 서비스 이벤트 로그 (log_type: SERVICE_EVENT)

**발생**: EKS Pod stdout JSON (16종 이벤트)

```json
{
  "log_type": "SERVICE_EVENT",
  "event_type": "ORDER_FAILED",
  "event_time": "2025-06-01T14:22:10",
  "trace_id": "abc-123",
  "user_id": 12,
  "product_id": 3,
  "category": "electronics",
  "api_path": "/api/orders/from-cart",
  "http_method": "POST",
  "status": "FAILED",
  "status_code": 500,
  "response_time_ms": 2860,
  "error_code": "DB_TIMEOUT",
  "environment": "dev"
}
```

**이벤트 16종**:
`USER_SIGNUP`, `USER_LOGIN`, `PRODUCT_LIST_VIEW`, `PRODUCT_SEARCH`, `PRODUCT_VIEW`,
`CART_ITEM_ADDED`, `CART_VIEWED`, `CART_ITEM_UPDATED`, `CART_ITEM_REMOVED`,
`ORDER_FROM_CART`, `ORDER_SUCCESS`, `ORDER_FAILED`, `REVIEW_CREATED`, `REVIEW_FAILED`,
`API_ERROR`, `SLOW_RESPONSE`

**파이프라인**:
```
EKS Pod stdout JSON
  → Fluent Bit DaemonSet (cri parser, rewrite_tag로 SERVICE_EVENT 분기)
  → CloudWatch Logs (/fiveline/dev/service-events/{service_name})
  → Subscription Filter
  → Kinesis Firehose (Dynamic Partitioning by event_type/year/month/day/hour)
  → S3 raw/service_events/event_type={type}/year=../month=../day=../hour=../
  → Glue Crawler (매시 30분, 스키마 등록)
  → Glue ETL Job (PII 마스킹, 타입변환, 중복제거, Parquet 변환)
  → S3 cleansed/service_events/
  → Athena (주문 실패율, 전환율, 응답시간 분석)
```

### 3.2 애플리케이션 로그 (log_type: APPLICATION_LOG)

**발생**: EKS Pod stdout 일반 서버/에러 로그

```json
{
  "log_type": "APPLICATION_LOG",
  "event_time": "2025-06-01T14:22:09",
  "level": "ERROR",
  "api_path": "/api/orders/from-cart",
  "message": "DB connection timeout after 3000ms",
  "trace_id": "abc-123",
  "service": "order-service"
}
```

**파이프라인**:
```
EKS Pod stdout
  → Fluent Bit (rewrite_tag로 APPLICATION_LOG 분기)
  → CloudWatch Logs (/fiveline/dev/app-logs/{service_name}, 14일 보존)
  → Firehose → S3 raw/application_logs/
  → Glue → Athena (장애 원인 분석, Bedrock Agent 쿼리 대상)
```

### 3.3 인프라 메트릭

> **초안 수정**: Lambda 폴링 방식의 한계 (Gap 발생, API 비용, Pod 레벨 부재)
> → **Container Insights + CloudWatch Metric Stream으로 교체**

**수집 방식**:
- **실시간 시각화**: Container Insights (노드/Pod CPU/Memory, 자동 수집)
- **S3 분석 적재**: CloudWatch Metric Stream → Firehose → S3 (폴링 아닌 스트리밍, Gap 없음)
- **Lambda 역할 한정**: 집계 결과를 DynamoDB Summary에 저장하는 배치용으로만 사용

**수집 메트릭**:

| 서비스 | 주요 메트릭 |
|--------|------------|
| ALB | RequestCount, HTTPCode_ELB_5XX_Count, TargetResponseTime(p95/p99) |
| EKS | node_cpu_utilization, node_memory_utilization, pod_number_of_container_restarts |
| RDS | CPUUtilization, DatabaseConnections, ReadLatency, WriteLatency, ReplicaLag |
| ElastiCache | CacheHits, CacheMisses, FreeableMemory, ReplicationLag, Evictions |

**파이프라인**:
```
ALB / EKS / RDS / ElastiCache
  → CloudWatch Metrics
  → CloudWatch Metric Stream → Firehose → S3 raw/infra_metrics/namespace={ns}/year=../
  → Glue → Athena (서비스 이벤트와 JOIN 분석)
```

### 3.4 알람 이벤트

> **중요**: Spot 회수 이벤트(EC2 Interruption Notice)는 **별도 EventBridge 경로**로 처리.
> CloudWatch Alarm 파이프라인과 혼동하지 말 것.

**CloudWatch Alarm 파이프라인**:
```
CloudWatch Alarm (DatapointsToAlarm: 연속 2회 위반 시 발화)
  → SNS Topic (fiveline-dev-alarm-topic)
  → Lambda (Alarm Handler)
  → DynamoDB (alarm_history, TTL 90일)
  → S3 raw/alarm_events/ (원본 아카이브)
  → Slack (P1 → @channel 멘션, 5분 무응답 시 자동 에스컬레이션)
  → [P1 조건] Bedrock 분석 Lambda 비동기 트리거
```

**Spot 회수 이벤트 별도 파이프라인**:
```
EC2 Spot Instance Interruption Notice (EventBridge: 회수 2분 전)
  → Lambda (Spot Interruption Handler)
  → Node Termination Handler와 연동 (Pod graceful drain)
  → DynamoDB (alarm_history, check_type: SPOT_INTERRUPTION)
  → Slack 즉시 알림
```

### 3.5 리소스 점검 데이터

```
EventBridge 스케줄 (매일 KST 01:00)
  → Resource Checker Lambda
  → boto3 AWS API 조회 (EC2/RDS/IAM/Lambda 등)
  → DynamoDB (resource_check_results, TTL 30일)
  → Slack 알림 (HIGH 이슈 발생 시)
```

**점검 항목**: 미사용 EBS, 보안그룹 0.0.0.0/0, 태그 누락, 미연결 EIP, Public RDS, IAM MFA 미설정, Lambda 런타임 EOL

---

## 4. S3 Data Lake 구조

### 버킷 구성

```
s3://fiveline-{env}-data-lake/     # 데이터 레이크 (KMS CMK 암호화)
s3://fiveline-{env}-athena-results/ # Athena 결과 (7일 TTL)
s3://fiveline-{env}-reports/        # Bedrock 생성 리포트 (365일 보존)
```

### prefix 계층 구조

```
s3://fiveline-{env}-data-lake/
│
├── raw/                              # 원본 보존 (JSON, 변환 없음)
│   ├── service_events/
│   │   └── event_type=ORDER_FAILED/
│   │       └── year=2025/month=06/day=01/hour=14/
│   │           └── fiveline-dev-2025-06-01-14-30-00-{uuid}.json
│   ├── application_logs/
│   │   └── year=2025/month=06/day=01/service=order-service/
│   ├── infra_metrics/
│   │   └── namespace=AWS%2FEKS/year=2025/month=06/day=01/
│   └── alarm_events/
│       └── year=2025/month=06/day=01/
│
├── cleansed/                         # 정제됨 (Parquet+Snappy, PII 마스킹)
│   ├── service_events/
│   │   └── year=2025/month=06/day=01/event_type=ORDER_FAILED/
│   │       └── part-00000.parquet
│   ├── infra_metrics/
│   └── alarm_events/
│
├── aggregated/                       # 집계 결과 (Bedrock/Dashboard 입력)
│   ├── hourly_order_stats/           # 시간대별 주문 집계
│   ├── product_funnel/               # 상품 전환 퍼널
│   └── service_sla/                  # 서비스별 SLA 지표
│
├── quarantine/                       # 파싱 실패 격리 (90일 삭제)
│   └── firehose-errors/
└── glue-scripts/                     # ETL 스크립트
    ├── raw_to_cleansed_service_events.py
    └── cleansed_to_aggregated.py
```

### Lifecycle 정책

| 계층 | STANDARD | STANDARD_IA | GLACIER_IR | 만료 |
|------|---------|------------|-----------|------|
| `raw/` | 0~30일 | 31~90일 | 91~365일 | 365일 삭제 |
| `cleansed/` | 0~90일 | 91~365일 | 366일~3년 | 3년 |
| `aggregated/` | 0~90일 | 91~365일 | 366일~5년 | 5년 |
| `quarantine/` | 0~90일 | — | — | 90일 삭제 |

### KMS CMK 설정

```hcl
resource "aws_kms_key" "data_lake" {
  description             = "fiveline Data Lake S3/Glue/DynamoDB 암호화 키"
  deletion_window_in_days = 7
  enable_key_rotation     = true   # 연 1회 자동 로테이션
}
```

---

## 5. Kinesis Firehose 상세 설정

### 핵심 설정값

| 설정 | 값 | 이유 |
|------|---|------|
| BufferingSize | **128 MB** | 기본 5MB 대비 S3 PutObject 비용 96% 절감 |
| BufferingInterval | **300초** | DATA-009 SLA "적재 지연 < 5분" 상한 충족 |
| 압축 | UNCOMPRESSED | Dynamic Partitioning JQ 파싱 호환성 |
| 암호화 | KMS CMK | bucket_key_enabled=true (KMS API 비용 99% 절감) |
| Dynamic Partitioning | event_type 기준 | 파티션 프루닝으로 Athena 스캔 비용 최소화 |

### S3 경로 패턴

```
정상:  raw/service_events/event_type=!{partitionKeyFromQuery:event_type}/
       year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/

실패:  quarantine/firehose-errors/!{firehose:error-output-type}/
       year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/
```

### Dynamic Partitioning JQ 쿼리

```json
{
  "event_type": ".event_type"
}
```

### CloudWatch Logs Subscription Filter → Firehose 연결

```hcl
resource "aws_cloudwatch_log_subscription_filter" "service_events" {
  name            = "fiveline-dev-service-events-filter"
  log_group_name  = "/fiveline/dev/service-events"
  filter_pattern  = "{ $.log_type = \"SERVICE_EVENT\" }"
  destination_arn = aws_kinesis_firehose_delivery_stream.service_events.arn
  role_arn        = aws_iam_role.cwlogs_firehose.arn
}
```

---

## 6. Fluent Bit DaemonSet (EKS 로그 수집)

> **주의**: ECS Fargate의 awslogs 드라이버 방식이 아닌, **DaemonSet 방식**이 필수 (DATA-001).
> DaemonSet이므로 Spot 노드에도 배포되어야 하므로 **toleration 필수**.

### 로그 그룹 명명 규칙

```
/fiveline/dev/service-events/user-service    (SERVICE_EVENT)
/fiveline/dev/service-events/product-service
/fiveline/dev/service-events/order-service
/fiveline/dev/app-logs/user-service          (APPLICATION_LOG, 14일 보존)
/fiveline/dev/app-logs/product-service
/fiveline/dev/app-logs/order-service
```

### 핵심 ConfigMap 설정

```yaml
[SERVICE]
    Flush        5
    Daemon       Off
    Log_Level    info
    Parsers_File parsers.conf
    HTTP_Server  On
    HTTP_Port    2020    # Prometheus scrape 용 메트릭 노출

[INPUT]
    Name          tail
    Tag           kube.*
    Path          /var/log/containers/*.log
    Exclude_Path  /var/log/containers/*_kube-system_*.log
    Parser        docker      # EKS 1.24+ containerd → cri 파서 권장
    DB            /var/log/flb_kube.db
    Mem_Buf_Limit 50MB

[FILTER]
    Name              kubernetes
    Match             kube.*
    Merge_Log         On
    Merge_Log_Key     log_processed

[FILTER]
    Name          rewrite_tag
    Match         kube.*
    Rule          $log_processed['log_type'] SERVICE_EVENT  service_event.$TAG false
    Rule          $log_processed['log_type'] APPLICATION_LOG app_log.$TAG       false

[OUTPUT]
    Name              cloudwatch_logs
    Match             service_event.*
    region            ap-northeast-2
    log_group_name    /fiveline/dev/service-events/$(k8s_labels_app)
    auto_create_group true
    log_retention_days 30

[OUTPUT]
    Name              cloudwatch_logs
    Match             app_log.*
    region            ap-northeast-2
    log_group_name    /fiveline/dev/app-logs/$(k8s_labels_app)
    auto_create_group true
    log_retention_days 14
```

### DaemonSet 리소스 설정

```yaml
# Spot 노드에도 배포 필수 (toleration)
tolerations:
  - key: "spot"
    operator: "Equal"
    value: "true"
    effect: "NoSchedule"

resources:
  requests:
    cpu: "100m"     # 평시 ~50m
    memory: "128Mi" # 버퍼 포함 ~100Mi
  limits:
    cpu: "500m"
    memory: "256Mi"
```

### IRSA 권한 (Fluent Bit ServiceAccount)

필요 권한: `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`, `logs:DescribeLogGroups`

---

## 7. Glue 구성

### Database

```
이름: fiveline_{env}_analytics
```

### Crawler 스케줄

| Crawler | 대상 prefix | 스케줄 | 설정 |
|---------|------------|--------|------|
| `raw_service_events` | `raw/service_events/` | 매시 30분 | CRAWL_NEW_FOLDERS_ONLY |
| `cleansed` | `cleansed/` | 매일 06:10 (KST) | CRAWL_NEW_FOLDERS_ONLY |
| `aggregated` | `aggregated/` | 매일 08:10 (KST) | CRAWL_NEW_FOLDERS_ONLY |

### ETL Job: raw → cleansed 변환 로직 (PySpark)

**처리 단계**:
1. **타입 캐스팅**: `event_time` string → timestamp, `response_time_ms` → int
2. **PII 마스킹** (DATA-011, Must): `user_id` → SHA-256 해시화 (`user_id_hashed`), 원본 삭제
3. **스키마 검증** (DATA-010): 필수 컬럼 Null 비율 > 10% → `quarantine/` 격리
4. **중복 제거**: `trace_id + event_time` 기준 dedup (동일 이벤트 재전송 처리)
5. **처리 시각 추가**: `ingested_at = CURRENT_TIMESTAMP()`
6. **Parquet+Snappy 저장**: Athena 스캔 비용 최적화

### 오케스트레이션 (Step Functions / Glue Workflow)

```
Glue Workflow: fiveline-data-pipeline-workflow

  Trigger 1 (EventBridge 매일 06:00)
    → Glue Job: raw_to_cleansed_service_events
      → [성공] Trigger 2
      → [실패] CloudWatch Alarm + Slack 알림 (DATA-009)

  Trigger 2 (raw_to_cleansed 완료)
    → Glue Crawler: cleansed

  Trigger 3 (cleansed Crawler 완료)
    → Glue Job: cleansed_to_aggregated
```

### Athena 워크그룹

| 워크그룹 | 스캔 제한 | 용도 |
|---------|---------|------|
| `fiveline-dev-analytics` | **10 GB** | 운영 분석 Ad-hoc |
| `fiveline-dev-ai-reports` | **5 GB** | Bedrock Agent / Report Lambda |

결과 버킷: `s3://fiveline-{env}-athena-results/`, **7일 자동 삭제**

---

## 8. DynamoDB 6개 테이블 설계

### 8.1 alarm_history

```
PK: alarm_name (String)
SK: occurred_at (String, ISO8601)
용량: PAY_PER_REQUEST
TTL: expires_at (90일)
GSI: state-index (state / occurred_at)
PITR: ON
```

**아이템 예시**:
```json
{
  "alarm_name": "fiveline-dev-order-5xx-critical",
  "occurred_at": "2025-06-01T14:32:10Z",
  "state": "ALARM",
  "previous_state": "OK",
  "severity": "P1",
  "service": "order-service",
  "metric_name": "HTTPCode_ELB_5XX_Count",
  "threshold": 20,
  "bedrock_triggered": true,
  "slack_sent": true,
  "expires_at": 1759449600
}
```

### 8.2 dashboard_summary

```
PK: metric_key (String)  예: "order_failure_rate_5m"
SK: recorded_at (String, ISO8601)
용량: PAY_PER_REQUEST
TTL: expires_at (24시간)
GSI: service-index (service_name / recorded_at)
```

### 8.3 hourly_order_summary

```
PK: date_hour (String)   예: "2025-06-01T14"
SK: service_name (String)
용량: PROVISIONED Read 5 / Write 5 (예측 가능한 배치 패턴, 비용 절감)
TTL: expires_at (365일)
GSI: date-index (date / date_hour) — 일별 전체 시간대 Bedrock 리포트용
```

**아이템 예시**:
```json
{
  "date_hour": "2025-06-01T14",
  "service_name": "order-service",
  "date": "2025-06-01",
  "total_orders": 342,
  "success_orders": 329,
  "failed_orders": 13,
  "failure_rate_pct": 3.8,
  "avg_response_time_ms": 487,
  "p95_response_time_ms": 1240,
  "p99_response_time_ms": 1890,
  "top_error_code": "DB_TIMEOUT"
}
```

### 8.4 infra_health_summary

```
PK: resource_id (String)  예: "rds/fiveline-dev-rds-primary"
SK: checked_at (String)
용량: PAY_PER_REQUEST
TTL: expires_at (7일)
GSI 2개:
  resource-type-index (resource_type / checked_at)
  health-status-index (health_status / checked_at)
```

### 8.5 report_metadata

```
PK: report_id (String, UUID v4)
SK: report_type (String)  daily | weekly | incident
용량: PAY_PER_REQUEST
TTL: expires_at (365일)
GSI: type-date-index (report_type / created_at) — Grafana 리포트 패널용
```

### 8.6 resource_check_results

```
PK: check_id (String, UUID v4)
SK: resource_id (String)
용량: PAY_PER_REQUEST
TTL: expires_at (30일)
GSI 2개:
  resource-time-index (resource_id / checked_at)
  result-index (check_result / checked_at)  — FAIL/WARN 즉시 필터링
```

### 공통 설정 (전체 6개 테이블)

- `point_in_time_recovery = true` (RPO < 5분, IR-002)
- KMS CMK 암호화 (`server_side_encryption.kms_master_key_id`)
- 삭제 방지: `deletion_protection_enabled = true` (prod 전환 시 필수)

---

## 9. Athena 핵심 쿼리

### 9.1 시간대별 주문 실패율

```sql
SELECT
    date_trunc('hour', event_time)             AS hour_bucket,
    COUNT(*)                                    AS total_orders,
    COUNT(*) FILTER (WHERE status = 'FAILED')   AS failed_orders,
    ROUND(
        COUNT(*) FILTER (WHERE status = 'FAILED') * 100.0
        / NULLIF(COUNT(*), 0), 2
    )                                           AS failure_rate_pct,
    APPROX_PERCENTILE(response_time_ms, 0.95)  AS p95_response_ms,
    APPROX_PERCENTILE(response_time_ms, 0.99)  AS p99_response_ms
FROM fiveline_dev_analytics.service_events
WHERE year = '2025' AND month = '06' AND day = '01'
  AND event_type IN ('ORDER_SUCCESS', 'ORDER_FAILED')
GROUP BY date_trunc('hour', event_time)
ORDER BY hour_bucket;
```

### 9.2 주문 실패율 vs EKS CPU (JOIN 분석)

```sql
WITH order_stats AS (
    SELECT
        date_trunc('minute', event_time)                               AS ts,
        ROUND(
            COUNT(*) FILTER (WHERE status = 'FAILED') * 100.0
            / NULLIF(COUNT(*), 0), 2
        )                                                              AS failure_rate_pct,
        APPROX_PERCENTILE(response_time_ms, 0.99)                     AS p99_ms
    FROM fiveline_dev_analytics.service_events
    WHERE year = '2025' AND month = '06' AND day = '01'
      AND event_type IN ('ORDER_SUCCESS', 'ORDER_FAILED')
    GROUP BY date_trunc('minute', event_time)
),
eks_cpu AS (
    SELECT
        date_trunc('minute', "timestamp") AS ts,
        AVG(value)                         AS cpu_avg_pct
    FROM fiveline_dev_analytics.infra_metrics
    WHERE year = '2025' AND month = '06' AND day = '01'
      AND namespace = 'ContainerInsights'
      AND metric_name = 'node_cpu_utilization'
    GROUP BY date_trunc('minute', "timestamp")
)
SELECT
    o.ts,
    o.failure_rate_pct,
    o.p99_ms,
    COALESCE(e.cpu_avg_pct, 0) AS eks_cpu_avg_pct,
    CASE
        WHEN e.cpu_avg_pct > 80 THEN 'HIGH_CPU'
        WHEN e.cpu_avg_pct > 60 THEN 'MEDIUM_CPU'
        ELSE 'NORMAL_CPU'
    END AS cpu_zone
FROM order_stats o
LEFT JOIN eks_cpu e ON o.ts = e.ts
ORDER BY o.ts;
```

### 9.3 상품별 전환율 (조회→장바구니→주문)

```sql
WITH funnel AS (
    SELECT
        product_id, category,
        COUNT(*) FILTER (WHERE event_type = 'PRODUCT_VIEW')    AS view_count,
        COUNT(*) FILTER (WHERE event_type = 'CART_ITEM_ADDED') AS cart_count,
        COUNT(*) FILTER (WHERE event_type = 'ORDER_SUCCESS')   AS order_count
    FROM fiveline_dev_analytics.service_events
    WHERE year = '2025' AND month = '06'
      AND event_type IN ('PRODUCT_VIEW', 'CART_ITEM_ADDED', 'ORDER_SUCCESS')
      AND product_id IS NOT NULL
    GROUP BY product_id, category
)
SELECT
    product_id, category, view_count, cart_count, order_count,
    ROUND(cart_count  * 100.0 / NULLIF(view_count, 0), 2) AS view_to_cart_pct,
    ROUND(order_count * 100.0 / NULLIF(cart_count, 0), 2) AS cart_to_order_pct,
    ROUND(order_count * 100.0 / NULLIF(view_count, 0), 2) AS overall_conversion_pct
FROM funnel
WHERE view_count > 10
ORDER BY overall_conversion_pct DESC
LIMIT 50;
```

### 9.4 프로모션 시간대 영향 분석

```sql
WITH hourly AS (
    SELECT
        EXTRACT(HOUR FROM event_time)                              AS hour_of_day,
        ROUND(
            COUNT(*) FILTER (WHERE event_type = 'ORDER_FAILED') * 100.0
            / NULLIF(COUNT(*) FILTER (WHERE event_type IN ('ORDER_SUCCESS','ORDER_FAILED')), 0),
            2
        )                                                          AS failure_rate_pct,
        APPROX_PERCENTILE(response_time_ms, 0.99)                 AS p99_ms
    FROM fiveline_dev_analytics.service_events
    WHERE year = '2025' AND month = '06' AND day IN ('01','02')
    GROUP BY EXTRACT(HOUR FROM event_time)
)
SELECT
    hour_of_day,
    CASE
        WHEN hour_of_day BETWEEN 12 AND 13 THEN 'PROMOTION_LUNCH'
        WHEN hour_of_day BETWEEN 18 AND 19 THEN 'PROMOTION_EVENING'
        ELSE 'NORMAL'
    END AS traffic_type,
    failure_rate_pct,
    p99_ms
FROM hourly
ORDER BY hour_of_day;
```

---

## 10. Lambda 함수 구현 상세

### 10.1 Metrics Collector Lambda

**역할**: CloudWatch Metric Stream 보완용 배치 집계 → DynamoDB Summary 저장

```python
# 5분 주기 EventBridge 트리거
# GetMetricData 배치 API (최대 500개 쿼리 한 번에 처리)
# S3 파티셔닝: metrics/year={y}/month={m}/day={d}/hour={h}/
# 환경변수: DATA_LAKE_BUCKET, CLUSTER_NAME, ENVIRONMENT, ALB_ARN_SUFFIX, RDS_IDENTIFIER, REDIS_CLUSTER_ID
```

**수집 흐름**:
```
EventBridge rate(5 minutes)
  → Lambda
  → CloudWatch GetMetricData (ALB/EKS/RDS/ElastiCache 일괄)
  → JSON 파싱 → S3 raw/infra_metrics/
```

### 10.2 Alarm Handler Lambda

**역할**: CloudWatch Alarm SNS → DynamoDB 저장 + Slack + Bedrock 트리거

**알람 우선순위 분류**:

| 우선순위 | 알람 패턴 |
|---------|---------|
| P1 | order-5xx-critical, order-latency-critical, rds-write-latency, pod-crashloop |
| P2 | alb-5xx, rds-connections, redis-hitrate, hpa-maxreplicas |
| P3 | node-cpu, node-memory, pod-restart |
| P4 | replica-lag, storage-warning |

**처리 흐름**:
```python
def lambda_handler(event, context):
    # 1. SNS 메시지 파싱
    # 2. 우선순위 분류 (P1~P4)
    # 3. DynamoDB alarm_history 저장 (TTL 90일)
    # 4. S3 원본 JSON 아카이브
    # 5. Slack 발송 (P1: @channel 멘션, 색상: 빨강/주황/노랑/초록)
    # 6. P1 + ALARM 상태 → Bedrock 분석 Lambda 비동기 호출 (InvocationType=Event)
    # 7. DynamoDB 상태 업데이트 (slack_sent, bedrock_triggered)
```

### 10.3 Report Generator Lambda

**역할**: EventBridge 스케줄 → Athena 조회 → Bedrock 요약 → S3 저장 + Slack

**EventBridge 스케줄**:
- 일간: `cron(0 0 * * ? *)` → KST 09:00
- 주간: `cron(0 0 ? * MON *)` → 월요일 KST 09:00

**Bedrock 프롬프트 구조**:
```
[시스템] AWS 인프라 운영 전문가. 4개 섹션 한국어 리포트 작성:
  1. 운영 요약 (3줄 이내)
  2. 핵심 지표 (서비스별 수치)
  3. 이상 징후 (임계값 초과, 알람)
  4. 권고 사항 (즉시/단기/장기)

[데이터] Athena 집계 결과 + DynamoDB 알람 이력 + CloudWatch 메트릭 요약
[모델] anthropic.claude-3-5-sonnet-20241022-v2:0 (temperature=0.3)
[최대 토큰] 4096
```

**S3 저장 경로**:
```
s3://fiveline-{env}-reports/
├── daily/2025/06/01/report_2025-06-01T00-00-00.md
├── weekly/2025/06/01/report_2025-06-01T00-00-00.md
└── incident/2025/06/01/report_2025-06-01T14-32-00.md
```

### 10.4 Bedrock Agent Action Group Lambda

**역할**: 운영자 자연어 질의 → 함수 라우팅 → DynamoDB/Athena 조회

> **설계 원칙**: Action Group (실시간/구조화 쿼리) + Knowledge Base (준정적 텍스트/RAG) 분리

**Action Group 함수 5개**:

| 함수명 | 데이터 소스 | 설명 |
|--------|-----------|------|
| `get_dashboard_summary` | DynamoDB | 현재 운영 현황 |
| `query_order_failure` | Athena | 주문 실패 분석 |
| `get_alarm_history` | DynamoDB | 알람 이력 조회 |
| `trigger_report` | Lambda 호출 | 즉시 리포트 생성 |
| `get_resource_check` | DynamoDB | 리소스 점검 결과 |

**Knowledge Base** (AI-009 환각 방지):
- 소스: S3 리포트 아카이브 + 런북 문서
- 벡터 저장소: OpenSearch Serverless
- 용도: 과거 유사 장애 검색, 운영 정책 조회

**질의별 라우팅 예시**:
```
"오늘 주문 실패율?" → get_dashboard_summary (DynamoDB)
"어제 프로모션 장애 원인?" → query_order_failure (Athena)
"최근 알람 보여줘" → get_alarm_history (DynamoDB)
"주간 리포트 만들어줘" → trigger_report (Lambda)
"이번 주 유사 장애가 있었나?" → Knowledge Base (RAG)
```

**Bedrock Guardrails** (SEC-021, AI-009):
- 개인정보(user_id_hashed 이전 raw 데이터) 미노출
- 프롬프트 인젝션 방어
- 응답 길이 제한

### 10.5 Resource Checker Lambda

**역할**: 매일 KST 01:00 AWS 리소스 점검 → DynamoDB 저장 → Slack 알림

**점검 항목 및 boto3 API**:

| 점검 항목 | boto3 API | 심각도 |
|----------|----------|--------|
| 미사용 EBS | `ec2.describe_volumes(Filters=[available])` | HIGH |
| SG 0.0.0.0/0 (80/443 제외) | `ec2.describe_security_groups` | HIGH |
| Public RDS | `rds.describe_db_instances` | HIGH |
| IAM MFA 미설정 | `iam.list_mfa_devices` | HIGH |
| 태그 누락 | `resourcegroupstaggingapi.get_resources` | MEDIUM |
| 미연결 EIP | `ec2.describe_addresses` | MEDIUM |
| Lambda 런타임 EOL | `lambda.list_functions` | MEDIUM |

---

## 11. EventBridge 스케줄 요약

| 규칙명 | 스케줄 | KST 시각 | 대상 Lambda |
|--------|--------|---------|------------|
| `metrics-collector` | `rate(5 minutes)` | 5분마다 | metrics-collector |
| `daily-report` | `cron(0 0 * * ? *)` | 매일 09:00 | report-generator (daily) |
| `weekly-report` | `cron(0 0 ? * MON *)` | 월요일 09:00 | report-generator (weekly) |
| `resource-checker` | `cron(0 16 * * ? *)` | 매일 01:00 | resource-checker |
| `glue-pipeline` | `cron(0 21 * * ? *)` | 매일 06:00 | (Glue Workflow 트리거) |

---

## 12. Lambda 함수 구성 요약

| 함수명 | 트리거 | 타임아웃 | 메모리 | 주요 IAM 권한 |
|--------|--------|---------|--------|-------------|
| `fiveline-dev-metrics-collector` | EventBridge 5분 | 60초 | 256MB | CloudWatch:GetMetricData, S3:PutObject |
| `fiveline-dev-alarm-handler` | SNS | 30초 | 256MB | DynamoDB:PutItem, S3:PutObject, Lambda:InvokeFunction |
| `fiveline-dev-report-generator` | EventBridge 스케줄 | 300초 | 512MB | Athena, DynamoDB, Bedrock:InvokeModel, S3:PutObject |
| `fiveline-dev-bedrock-agent-action` | Bedrock Agent | 30초 | 256MB | DynamoDB:GetItem/Scan, Athena, Lambda:InvokeFunction |
| `fiveline-dev-resource-checker` | EventBridge 매일 01시 | 300초 | 512MB | EC2/RDS/IAM/Lambda Describe*, DynamoDB:BatchWriteItem |

---

## 13. 신규 Terraform 파일 목록

| 파일 | 포함 리소스 |
|------|-----------|
| `data_pipeline.tf` | S3(data-lake, athena-results, reports), KMS CMK, Firehose, Glue(DB/Crawler/Job/Workflow), Athena 워크그룹, CloudWatch Log Subscription |
| `dynamodb.tf` | 6개 테이블 (alarm_history, dashboard_summary, hourly_order_summary, infra_health_summary, report_metadata, resource_check_results) |
| `lambda.tf` | 5개 Lambda 함수 + 레이어 + CloudWatch Log Groups |
| `eventbridge.tf` | 5개 EventBridge 규칙 + 타겟 |
| `k8s/fluent-bit-configmap.yaml` | Fluent Bit ConfigMap |
| `k8s/fluent-bit-daemonset.yaml` | Fluent Bit DaemonSet + ServiceAccount |

---

## 14. 요구사항 대조 (DATA-001~014 충족 여부)

| ID | 요구사항 | 구현 방법 | 충족 |
|----|---------|---------|------|
| DATA-001 | Fluent Bit DaemonSet 로그 수집 | DaemonSet (Spot toleration 포함) | ✅ |
| DATA-002 | Subscription → Firehose → S3 | CloudWatch Subscription Filter 명시 | ✅ |
| DATA-003 | raw/cleansed/aggregated 3계층 | S3 prefix 구조 3계층 분리 | ✅ |
| DATA-004 | year/month/day/hour + service 파티션 | Dynamic Partitioning (event_type + 시간) | ✅ |
| DATA-005 | Glue Job (raw→cleansed 정제) | PySpark ETL Job (타입변환/중복제거) | ✅ |
| DATA-006 | Athena 워크그룹 스캔 제한 | analytics: 10GB, ai_reports: 5GB | ✅ |
| DATA-007 | 집계 결과 DynamoDB 저장 | 6개 테이블 (hourly_order_summary 등) | ✅ |
| DATA-008 | 보존 정책 (raw 90일→Glacier) | S3 Lifecycle 정책 계층별 정의 | ✅ |
| DATA-009 | 처리 SLA (적재 < 5분) | Firehose BufferingInterval 300초 | ✅ |
| DATA-010 | Glue Data Quality + quarantine | ETL Job 내 Null 검증 + quarantine/ 격리 | ✅ |
| DATA-011 | PII 마스킹 (Must) | user_id SHA-256 해시화, 원본 삭제 | ✅ |
| DATA-012 | 파이프라인 오케스트레이션 | Glue Workflow (Trigger 체인) | ✅ |
| DATA-013 | 스키마 진화 대응 | Glue Schema Registry (Could, 선택) | ⬜ |
| DATA-014 | Lake Formation 접근 제어 | (Could, 선택) | ⬜ |

---

*본 문서는 Cloud Architect / Database Administrator / DevOps Engineer 3개 전문 에이전트가 실제 코드베이스(eks.tf, iam.tf, network.tf 등)와 설계 문서를 대조 분석하여 작성하였습니다.*
