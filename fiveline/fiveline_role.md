# Fiveline 프로젝트 팀원 역할 분담

> 작성 기준: 2026-06-01

---

## 현재 구현 상태 (공통 인지 사항)

VPC 기본 인프라가 완료된 상태이며, 각 담당자는 이 위에서 작업을 시작한다.

### ✅ 완료된 인프라

| 파일 | 내용 |
|------|------|
| `network.tf` | VPC, 서브넷 4계층, IGW, NAT GW (2a/2c 멀티AZ), 라우트 테이블 |
| `eks.tf` | EKS 클러스터, On-Demand/Spot 노드 그룹, 필수 애드온 5종, 컨트롤플레인 로그 |
| `iam.tf` | EKS 클러스터/노드 IAM 역할 (기본) |
| `rds.tf` | RDS PostgreSQL Multi-AZ Primary + Read Replica, SG |
| `elasticache.tf` | ElastiCache Redis Primary+Replica, at-rest/transit 암호화 |

### ⚠️ k8s 파일 현황

`k8s/` 디렉토리 파일들은 EKS 클러스터 생성에는 영향 없으나, **클러스터 생성 후 반드시 수정 후 적용**해야 한다.

| 파일 | 문제 | 담당 |
|------|------|------|
| `serviceaccount.yaml` | 구 네이밍(`fiveline-dev-...`) + IRSA Role 미존재 | 보안 담당자 |
| `*-service.yaml` | `<AWS_ACCOUNT_ID>` 플레이스홀더, ECR 미생성 | CI/CD 담당자 |
| `hpa.yaml`, `pdb.yaml` | 적용만 하면 동작 (내용 검토 필요) | CI/CD 담당자 |

---

## 역할 분담 개요

| # | 역할 | 담당 서비스 | 주요 Terraform 파일 |
|---|------|------------|-------------------|
| 1 | **보안** | WAF, KMS, Secrets Manager, IRSA, ESO, CloudTrail, ACM | `kms.tf`, `secrets.tf`, `waf.tf`, `waf_cloudfront.tf`, `acm.tf`, `cloudtrail.tf` |
| 2 | **데이터 파이프라인** | CloudWatch Logs, Firehose, S3 Data Lake, Glue, Athena, Bedrock | `data_pipeline.tf`, `dynamodb.tf`, `lambda.tf`, `eventbridge.tf` |
| 3 | **모니터링/알람** | CloudWatch Alarms/Dashboard, SNS, Lambda, DynamoDB, Grafana, CA, NTH | `monitoring.tf`, `sns.tf`, `lambda_alarm.tf`, `dynamodb_monitoring.tf`, `iam_monitoring.tf`, `sqs_nth.tf` |
| 4 | **CI/CD** | ECR, GitHub Actions, ArgoCD, ALB Controller, K8s 매니페스트 완성 | `ecr.tf`, `github_oidc_iam.tf`, `alb_controller_iam.tf` |

### ALB 생성 방식 (공통 인지)

이 프로젝트는 **AWS Load Balancer Controller + Kubernetes Ingress** 방식을 사용한다.  
ALB는 Terraform으로 직접 만들지 않는다. Ingress 매니페스트를 적용하면 Controller가 자동으로 ALB를 프로비저닝한다.

```
k8s/ingress.yaml 적용
  → ALB Controller 감지
    → AWS API 호출 → ALB 자동 생성
```

### 팀 간 의존성

```
보안 (KMS, IRSA, ACM, WAF)
  └── 데이터 파이프라인 (KMS CMK 참조, Fluent Bit IRSA)
  └── CI/CD (ACM ARN → Ingress 어노테이션, WAF ARN → Ingress 어노테이션)
  └── 모니터링/알람 (CA/NTH IRSA)

CI/CD (ECR, Ingress → ALB 자동 생성)
  └── 모니터링/알람 (ALB 생성 후 ALB 관련 알람 설정 가능)
  └── 데이터 파이프라인 (Fluent Bit이 Pod 로그 수집)

모니터링/알람 (alarm_history, dashboard_summary DynamoDB)
  └── 데이터 파이프라인 (report-generator가 dashboard_summary 읽기)
```

### DynamoDB 테이블 담당 분리

| 테이블 | 담당 | 파일 |
|--------|------|------|
| `fiveline-ddb-alarm-history` | 모니터링/알람 | `dynamodb_monitoring.tf` |
| `fiveline-ddb-dashboard-summary` | 모니터링/알람 | `dynamodb_monitoring.tf` |
| `fiveline-ddb-hourly-order-summary` | 데이터 파이프라인 | `dynamodb.tf` |
| `fiveline-ddb-infra-health-summary` | 데이터 파이프라인 | `dynamodb.tf` |
| `fiveline-ddb-report-metadata` | 데이터 파이프라인 | `dynamodb.tf` |
| `fiveline-ddb-resource-check-results` | 데이터 파이프라인 | `dynamodb.tf` |

### Lambda 함수 담당 분리

| Lambda 함수 | 담당 | 파일 |
|-------------|------|------|
| `alarm-handler` | 모니터링/알람 | `lambda_alarm.tf` |
| `metrics-collector` | 데이터 파이프라인 | `lambda.tf` |
| `report-generator` | 데이터 파이프라인 | `lambda.tf` |
| `bedrock-agent-action` | 데이터 파이프라인 | `lambda.tf` |
| `resource-checker` | 데이터 파이프라인 | `lambda.tf` |

---

---

# 1. 보안 담당자

## 담당 AWS 서비스

| # | 서비스 | 역할 | 요구사항 |
|---|--------|------|---------|
| 1 | **AWS WAFv2 (REGIONAL)** | ALB 앞단 SQLi/XSS/Rate-limit/IP평판 방어 (ap-northeast-2) | SEC-030~034 |
| 2 | **AWS WAFv2 (CLOUDFRONT)** | CloudFront 엣지 보호 — us-east-1 별도 생성 (AWS 제약) | SEC-030~035 |
| 3 | **AWS KMS (CMK)** | EKS etcd 봉투암호화, Data Lake, Secrets 키 — 자동 로테이션 | SEC-012, SEC-013 |
| 4 | **AWS Secrets Manager** | DB Credential, JWT 서명키 중앙 관리 | SEC-021, SEC-023 |
| 5 | **IAM — IRSA + OIDC** | OIDC Provider, 서비스별 SA Role 3개, ESO Role | SEC-020, SEC-024 |
| 6 | **External Secrets Operator (ESO)** | IRSA로 SM 값을 읽어 K8s Secret 자동 동기화 | SEC-021, SEC-022 |
| 7 | **AWS CloudTrail** | 전 리전 API 감사, 무결성 검증, S3 감사버킷 | SEC-050, SEC-056 |
| 8 | **VPC Flow Logs** | 네트워크 트래픽 감사 → CloudWatch Logs | SEC-051 |
| 9 | **EKS etcd 봉투 암호화** | KMS CMK로 K8s Secret 암호화 | SEC-013 |
| 10 | **AWS ACM (2개 리전)** | ALB용 (ap-northeast-2) + CloudFront용 (us-east-1) TLS 인증서 | SEC-011, INFRA-008 |

## 구현할 Terraform 파일 목록

| 파일 | 포함 리소스 | 의존성 |
|------|------------|--------|
| `providers.tf` (수정) | `aws.us_east_1` alias 추가, `data.aws_caller_identity` 추가 | **선행 필수** |
| `kms.tf` | `aws_kms_key.eks_etcd`, `aws_kms_key.data_lake`, `aws_kms_key.secrets` + alias | 없음 (최우선 생성) |
| `eks.tf` (수정) | `encryption_config` 블록 추가 (etcd 봉투 암호화) | `kms.tf` |
| `iam.tf` (확장) | OIDC Provider, 서비스별 IRSA Role 3개, ESO Role | `eks.tf` (OIDC URL) |
| `secrets.tf` | `aws_secretsmanager_secret.app_db_credential`, `jwt_signing_key` + version | `kms.tf`, `rds.tf` |
| `cloudtrail.tf` | CloudTrail, S3 감사버킷, VPC Flow Logs → CloudWatch | `kms.tf`, `network.tf` |
| `acm.tf` | ACM 인증서 2개 (ap-northeast-2 / us-east-1) | `providers.tf` |
| `waf.tf` | WAFv2 REGIONAL WebACL + Managed Rules + Rate-limit | — |
| `waf_cloudfront.tf` | WAFv2 CLOUDFRONT WebACL (`provider = aws.us_east_1` 필수) | `providers.tf` |

## 구현 순서

| 단계 | 작업 | 예상 시간 |
|------|------|---------|
| **0단계** | `providers.tf`에 `aws.us_east_1` alias 추가 + `terraform init` | 30분 |
| **1단계** | `kms.tf` — CMK 3개 생성 (eks_etcd / data_lake / secrets) | 1시간 |
| **2단계** | `eks.tf` 수정 — `encryption_config` 추가 (주의: terraform plan으로 replace 여부 확인) | 30분 |
| **3단계** | `iam.tf` 확장 — OIDC Provider + 서비스별 IRSA Role 3개 + ESO Role | 2시간 |
| **4단계** | `secrets.tf` — 앱 DB 계정 시크릿, JWT 서명키 (KMS 암호화) | 1시간 |
| **5단계** | `cloudtrail.tf` — CloudTrail + VPC Flow Logs | 2시간 |
| **6단계** | `acm.tf` — ALB용 + CloudFront용 인증서 (DNS 검증) | 1시간 |
| **7단계** | `waf.tf` + `waf_cloudfront.tf` — WAF 2개 생성 | 2시간 |
| **8단계** | ESO Helm 설치 + K8s SecretStore + ExternalSecret 적용 | 2시간 |

## 핵심 구현 상세

### KMS CMK 핵심 설정

```hcl
resource "aws_kms_key" "eks_etcd" {
  description             = "fiveline EKS etcd secret envelope encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccount"
        Effect = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowEKS"
        Effect = "Allow"
        Principal = { Service = "eks.amazonaws.com" }
        Action   = ["kms:Encrypt","kms:Decrypt","kms:DescribeKey","kms:CreateGrant"]
        Resource = "*"
      }
    ]
  })
  tags = { Service = "security", Name = "fiveline-kms-eks-etcd" }
}
```

> **주의**: 루트 계정 `kms:*` 절대 제거 금지 — 키 lockout 발생.

### IRSA 핵심 설정

```hcl
data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.fiveline_eks.identity[0].oidc[0].issuer
}
resource "aws_iam_openid_connect_provider" "eks_oidc" {
  url             = aws_eks_cluster.fiveline_eks.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
}
locals {
  oidc_url = replace(aws_iam_openid_connect_provider.eks_oidc.url, "https://", "")
}

resource "aws_iam_role" "user_service_sa" {
  name = "fiveline-user-service-sa-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks_oidc.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_url}:sub" = "system:serviceaccount:default:user-service-sa"
          "${local.oidc_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}
```

> **중요**: `serviceaccount.yaml`의 role-arn을 `fiveline-user-service-sa-role`로 교체 (구 `fiveline-dev-` 잔재 제거).  
> 모니터링/데이터 파이프라인 담당자가 추가로 필요한 IRSA Role(CA, NTH, Fluent Bit 등)은 각자 별도 파일에 작성하되, OIDC Provider는 이 파일에서 이미 생성된 것을 `data` source로 참조한다.

### WAF Managed Rules 우선순위

| 우선순위 | 규칙 | 목적 |
|---------|------|------|
| 10 | Rate-based (IP 기준, 2000req/5min) | DoS/무차별 대입 방어 (SEC-032) |
| 20 | AWSManagedRulesAmazonIpReputationList | 악성 IP 차단 (SEC-034) |
| 30 | AWSManagedRulesCommonRuleSet | XSS 등 일반 공격 (SEC-031) |
| 40 | AWSManagedRulesSQLiRuleSet | SQL Injection (SEC-031) |
| 50 | AWSManagedRulesKnownBadInputsRuleSet | 알려진 악성 입력 (SEC-031) |

> **주의**: `waf_cloudfront.tf`는 반드시 `provider = aws.us_east_1` 지정 필수.  
> WAF Managed Rule은 `override_action { none {} }`, 일반 Rule은 `action { block {} }` — 혼동 시 오류.

### ESO 설치 + K8s 연동

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace \
  --set serviceAccount.name=external-secrets-sa
```

```yaml
# k8s/external-secrets/secretstore.yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: fiveline-aws-sm
  namespace: default
spec:
  provider:
    aws:
      service: SecretsManager
      region: ap-northeast-2
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa
```

전체 흐름: `Pod (IRSA) → Secrets Manager → ESO → K8s Secret → secretKeyRef → 컨테이너`

## 완료 검증 방법

| 항목 | 검증 명령 | 기대 결과 |
|------|---------|---------|
| KMS 로테이션 | `aws kms get-key-rotation-status --key-id <id>` | `KeyRotationEnabled: true` |
| etcd 암호화 | `aws eks describe-cluster --name fiveline-eks --query cluster.encryptionConfig` | `resources:["secrets"]` + key ARN |
| OIDC Provider | `aws iam list-open-id-connect-providers` | EKS issuer URL provider 존재 |
| IRSA 동작 | Pod 내 `aws sts get-caller-identity` | `assumed-role/fiveline-user-service-sa-role` |
| ESO 동기화 | `kubectl get externalsecret -n default` | `SecretSynced=True` |
| CloudTrail | `aws cloudtrail get-trail-status --name fiveline-cloudtrail` | `IsLogging: true` |
| WAF SQLi 차단 | ALB DNS에 `?id=1' OR '1'='1` 요청 | HTTP 403 반환 |

## 담당 요구사항 ID

**Must**: SEC-010~013, SEC-020~024, SEC-030~032, SEC-050~052, INFRA-008, INFRA-011~012, INFRA-016  
**Should**: SEC-005, SEC-006, SEC-023, SEC-033~035, SEC-042, SEC-053~056

---

---

# 2. 데이터 파이프라인 담당자

## 담당 AWS 서비스

| 서비스 | 역할 |
|--------|------|
| **CloudWatch Logs** | Fluent Bit이 Push하는 로그 중앙 수집. Subscription Filter로 Firehose 연결 |
| **Kinesis Data Firehose** | 로그를 버퍼링하여 S3 Data Lake 적재. Dynamic Partitioning |
| **S3 Data Lake** | raw/cleansed/aggregated/quarantine 4계층. KMS 암호화 + Lifecycle 정책 |
| **AWS Glue** | Crawler(스키마 자동 탐지) + ETL Job(PII 마스킹/정제) + Workflow(DAG) |
| **Amazon Athena** | 워크그룹별 스캔 제한. Report Lambda + Bedrock Agent의 분석 엔진 |
| **Fluent Bit DaemonSet** | On-Demand + Spot 전 노드에서 Pod stdout 수집 |
| **EventBridge** | Glue 파이프라인 트리거(매일 06:00), 일간/주간 리포트 트리거 |
| **Lambda** | metrics-collector, report-generator, bedrock-agent-action, resource-checker |
| **Amazon Bedrock** | Claude 3.5 Sonnet으로 운영 리포트 생성, Agent로 자연어 질의 지원 |
| **KMS CMK (data-lake)** | 보안 담당자가 생성 — data_pipeline.tf에서 `data` source로 참조 |

## 구현할 Terraform 파일 목록

| 파일 | 포함 리소스 | 의존성 |
|------|------------|--------|
| `data_pipeline.tf` | S3 Data Lake 버킷 3개, Firehose, CloudWatch Log Group 6개, Subscription Filter, Glue Crawler/Job/Workflow, Athena Workgroup | `kms.tf` (보안 담당자 선행 필요) |
| `dynamodb.tf` | DynamoDB 4개 테이블 (hourly_order_summary, infra_health_summary, report_metadata, resource_check_results) | `kms.tf` |
| `lambda.tf` | Lambda 4개 함수 (metrics-collector, report-generator, bedrock-agent-action, resource-checker) | `data_pipeline.tf`, `dynamodb.tf` |
| `eventbridge.tf` | EventBridge 스케줄 (5분 메트릭 수집, 일간/주간 리포트, Glue 파이프라인) | `lambda.tf` |

> **alarm-handler Lambda는 모니터링/알람 담당자의 `lambda_alarm.tf`에서 관리한다.**  
> **alarm_history, dashboard_summary DynamoDB 테이블도 모니터링/알람 담당자의 `dynamodb_monitoring.tf`에서 관리한다.**  
> report-generator가 dashboard_summary를 읽어야 할 경우 테이블 이름을 환경변수로 참조한다.

## 구현 순서

| 단계 | 작업 | 예상 시간 |
|------|------|---------|
| **1단계** | S3 버킷 3개 생성 (보안 담당자의 `kms.tf` 적용 후 진행) | 1시간 |
| **2단계** | IAM Role 생성 (Glue, Firehose, CloudWatch→Firehose, Fluent Bit, Lambda) | 2시간 |
| **3단계** | CloudWatch Log Group + Firehose + Subscription Filter | 2시간 |
| **4단계** | Fluent Bit DaemonSet 배포 (k8s/fluent-bit-configmap.yaml + daemonset.yaml) | 2시간 |
| **5단계** | Glue Database + Crawler 생성 + 수동 실행 1회 | 1시간 |
| **6단계** | Glue ETL Job + Workflow 생성 + PySpark 스크립트 S3 업로드 | 3시간 |
| **7단계** | Athena Workgroup 생성 + 쿼리 검증 | 1시간 |
| **8단계** | DynamoDB 테이블 4개 생성 | 1시간 |
| **9단계** | Lambda 4개 + EventBridge 배포 | 3시간 |
| **10단계** | Bedrock Agent 설정 (콘솔 또는 Terraform) | 3시간 |

## 핵심 구현 상세

### S3 Data Lake 버킷 구조

```
fiveline-s3-data-lake/
├── raw/
│   ├── service_events/event_type=ORDER_FAILED/year=2025/month=06/day=01/hour=14/
│   └── application_logs/service=order-service/year=2025/...
├── cleansed/service_events/year=2025/month=06/day=01/event_type=ORDER_FAILED/
├── aggregated/hourly_order_stats/year=2025/month=06/day=01/
├── quarantine/firehose-errors/
└── glue-scripts/raw_to_cleansed_service_events.py
```

S3 Lifecycle 정책 (DATA-008):

| 계층 | 31일 후 | 91일 후 | 만료 |
|------|---------|---------|------|
| raw | STANDARD_IA | GLACIER_IR | 365일 |
| cleansed | STANDARD_IA | GLACIER_IR | 1095일 (3년) |
| aggregated | STANDARD_IA | GLACIER_IR | 1825일 (5년) |
| quarantine | — | — | 90일 |

### Firehose Dynamic Partitioning 핵심 설정

```hcl
resource "aws_kinesis_firehose_delivery_stream" "service_events" {
  name        = "fiveline-firehose-service-events"
  destination = "extended_s3"
  extended_s3_configuration {
    buffering_size     = 128   # MB (소형 파일 문제 방지)
    buffering_interval = 300  # 초 (DATA-009: 적재 지연 < 5분)
    compression_format = "UNCOMPRESSED"  # Dynamic Partitioning JQ 파싱 호환 필수

    prefix              = "raw/service_events/event_type=!{partitionKeyFromQuery:event_type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/"
    error_output_prefix = "quarantine/firehose-errors/!{firehose:error-output-type}/..."

    dynamic_partitioning_configuration { enabled = true }
    processing_configuration {
      enabled = true
      processors {
        type = "MetadataExtraction"
        parameters {
          parameter_name  = "JsonParsingEngine"
          parameter_value = "JQ-1.6"
        }
        parameters {
          parameter_name  = "MetadataExtractionQuery"
          parameter_value = "{event_type:.event_type}"
        }
      }
    }
  }
}
```

> **주의**: `compression_format = "UNCOMPRESSED"` 필수 — JQ 파싱 전 압축 해제 불가.

### Glue ETL Job PySpark 핵심 로직

```python
# PII 마스킹 — user_id SHA-256 해시화 (DATA-011)
sha256_udf = F.udf(lambda v: hashlib.sha256(str(v).encode()).hexdigest() if v else None)
df = df.withColumn("user_id_hashed", sha256_udf(F.col("user_id"))).drop("user_id")

# 스키마 검증 (DATA-010) — Null 비율 > 10% 시 quarantine 격리
for col in ["event_type", "event_time", "trace_id"]:
    null_ratio = df.filter(F.col(col).isNull()).count() / max(df.count(), 1)
    if null_ratio > 0.10:
        df.filter(F.col(col).isNull()).write.mode("append").json(
            f"s3://{bucket}/quarantine/schema-violation/{col}/"
        )
        df = df.filter(F.col(col).isNotNull())

# 중복 제거 + Parquet 저장
df.dropDuplicates(["trace_id", "event_time"]) \
  .write.mode("append") \
  .partitionBy("year", "month", "day", "event_type") \
  .option("compression", "snappy") \
  .parquet(f"s3://{bucket}/cleansed/service_events/")
```

### Athena 워크그룹 스캔 제한

| 워크그룹 | 스캔 제한 | 사용처 |
|---------|---------|-------|
| `fiveline-analytics` | 10GB/쿼리 | 운영자 Ad-hoc 분석 |
| `fiveline-ai-reports` | 5GB/쿼리 | Bedrock Lambda 전용 |

### Fluent Bit DaemonSet — Spot 노드 필수 설정

```yaml
tolerations:
  - key: "spot"
    operator: "Equal"
    value: "true"
    effect: "NoSchedule"
  - key: node-role.kubernetes.io/master
    effect: NoSchedule
```

> **주의**: Fluent Bit 자신의 로그 무한 루프 방지 — `Exclude_Path`에 `*_kube-system_*.log` 반드시 포함.

### Bedrock Report Generator 프롬프트 구조

```
[지시] 한국어로 4개 섹션 운영 리포트 작성:
1. 운영 요약 (3줄 이내)
2. 핵심 지표 (서비스별 수치 포함)
3. 이상 징후 (임계값 초과 항목)
4. 권고 사항 (즉시/단기/장기 구분)

[모델] anthropic.claude-3-5-sonnet-20241022-v2:0
[temperature] 0.3 / [max_tokens] 4096
```

## 완료 검증 방법

1. EKS Pod에서 테스트 이벤트 발생 → CloudWatch Logs 도달 확인 (5~30초)
2. Firehose Monitoring — `IncomingBytes` 증가 + S3 `raw/service_events/` 파일 생성 (5분 후)
3. Glue Crawler 수동 실행 → Glue Catalog에 `service_events` 테이블 생성 확인
4. Athena `fiveline-analytics` 워크그룹으로 `SELECT event_type, COUNT(*) FROM service_events GROUP BY event_type` 실행
5. Glue ETL Job 수동 실행 → `cleansed/` 경로 Parquet 파일 생성 + `user_id` 컬럼 없음 확인
6. Lambda `report-generator` 수동 Test 이벤트 → S3 `reports/daily/` 리포트 파일 생성 확인

## 담당 요구사항 ID

**Must**: DATA-001~006, DATA-008, DATA-011, AI-001, AI-003~005, AI-007  
**Should**: DATA-007, DATA-009~010, DATA-012, AI-002, AI-006, AI-008~010, COST-009

---

---

# 3. 모니터링/알람 담당자

## 담당 AWS 서비스

| 서비스 | 역할 |
|--------|------|
| **CloudWatch Alarms** | EKS/RDS/Redis/ALB/Pod 임계값 알람 14개 (MON-002~010) |
| **CloudWatch Dashboard** | `fiveline-dashboard` — 운영자용 AWS 네이티브 대시보드 |
| **SNS** | 알람 토픽 → Lambda/이메일/Slack 구독 |
| **Lambda (Alarm Handler)** | SNS 메시지 파싱 → DynamoDB 저장 → Slack 발송 |
| **DynamoDB** | `alarm_history`, `dashboard_summary` — 알람 이력/집계 전용 |
| **Grafana** | EKS 내부 배포, Prometheus 데이터소스, 골든 시그널 4행 대시보드 |
| **Prometheus** | kube-state-metrics, node-exporter로 EKS 메트릭 수집 (kube-prometheus-stack) |
| **Cluster Autoscaler** | On-Demand/Spot 노드 자동 확장 — HPA와 반드시 함께 동작 (Must, INFRA-006) |
| **Node Termination Handler** | Spot 인터럽션 2분 전 노티스 수신 → 자동 cordon + drain |

## 구현할 Terraform 파일 목록

| 파일 | 포함 리소스 | 의존성 |
|------|------------|--------|
| `dynamodb_monitoring.tf` | `alarm_history`, `dashboard_summary` DynamoDB 테이블 | 없음 (최우선) |
| `iam_monitoring.tf` | CA IRSA Role + Policy, NTH IRSA Role, Grafana CloudWatch Role | `eks.tf` (OIDC Provider — 보안 담당자 생성 후 data source 참조) |
| `sqs_nth.tf` | SQS Queue, EventBridge Rule 3개 (Spot 인터럽션, ASG, Rebalance) | 없음 |
| `lambda_alarm.tf` | Lambda Alarm Handler, CloudWatch Log Group, Lambda IAM Role | `dynamodb_monitoring.tf` |
| `sns.tf` | SNS 토픽, Lambda/이메일 구독, 토픽 정책 | `lambda_alarm.tf` |
| `monitoring.tf` | CloudWatch Alarm 14개, CloudWatch Dashboard | `sns.tf` |
| `eks.tf` (수정) | On-Demand/Spot 노드 그룹 `tags`에 CA 자동 발견 태그 추가 | — |

### `eks.tf` 수정 필요 사항

On-Demand/Spot 노드 그룹 `tags` 블록에 다음 2개 태그 추가 필요:

```hcl
"k8s.io/cluster-autoscaler/enabled"       = "true"
"k8s.io/cluster-autoscaler/fiveline-eks" = "owned"
```

> ALB 관련 알람(5xx, P99 latency)은 CI/CD 담당자가 Ingress를 적용하여 ALB가 생성된 이후에 설정해야 한다.

## 구현 순서

| 단계 | 작업 | 예상 시간 |
|------|------|---------|
| **1단계** | `dynamodb_monitoring.tf` — DynamoDB 테이블 2개 생성 | 30분 |
| **2단계** | `iam_monitoring.tf` — CA/NTH/Grafana IRSA Role 생성 (OIDC Provider는 보안 담당자 생성 후 data source 참조) | 2시간 |
| **3단계** | `sqs_nth.tf` — SQS + EventBridge 3개 Rule 생성 | 1시간 |
| **4단계** | `lambda_alarm.tf` — Alarm Handler Lambda 배포 | 3시간 |
| **5단계** | `sns.tf` — SNS 토픽 + 구독 생성 | 1시간 |
| **6단계** | `eks.tf` 수정 — CA 자동 발견 태그 추가 + `terraform apply` | 30분 |
| **7단계** | `monitoring.tf` — CloudWatch Alarm 14개 + Dashboard 생성 (ALB 알람은 CI/CD Ingress 적용 후) | 3시간 |
| **8단계** | K8s: Cluster Autoscaler Helm 설치 | 1시간 |
| **9단계** | K8s: Node Termination Handler Helm 설치 | 1시간 |
| **10단계** | K8s: Prometheus (kube-prometheus-stack) Helm 설치 | 1시간 |
| **11단계** | K8s: Grafana Helm 설치 + 대시보드 프로비저닝 | 3시간 |

## 핵심 구현 상세

### CloudWatch Alarm 14개 임계값

| 알람 이름 | 지표 | 임계값 | Period | 심각도 |
|---------|------|--------|--------|--------|
| `fiveline-alarm-alb-5xx` | `HTTPCode_Target_5XX_Count` 비율 | > 1% | 300초 | Critical |
| `fiveline-alarm-alb-503` | 503 특이 알람 | > 0 | 300초 | Warning |
| `fiveline-alarm-rds-connections` | `DatabaseConnections` | > 136 (80%) | 300초 | Warning |
| `fiveline-alarm-rds-write-latency` | `WriteLatency` | > 100ms | 300초 | Critical |
| `fiveline-alarm-rds-replica-lag` | `ReplicaLag` | > 30초 | 300초 | Warning |
| `fiveline-alarm-rds-storage` | `FreeStorageSpace` | < 5GiB | 300초 | Warning |
| `fiveline-alarm-redis-hitrate-warn` | HitRate (Metric Math) | < 80% | 300초 | Warning |
| `fiveline-alarm-redis-hitrate-crit` | HitRate (Metric Math) | < 60% | 300초 | Critical |
| `fiveline-alarm-redis-replication-lag` | `ReplicationLag` | > 10초 | 300초 | Warning |
| `fiveline-alarm-pod-restart` | `pod_number_of_container_restarts` | > 3 (30분 내) | 1800초 | Warning |
| `fiveline-alarm-hpa-maxreplicas` | `kube_hpa_status_current_replicas` | = 6 | 300초 | Critical |
| `fiveline-alarm-order-p99-latency` | `TargetResponseTime` (p99) | > 2초 | 300초 | Critical |
| `fiveline-alarm-burn-rate-1h` | `ErrorBudgetBurnRate` (커스텀) | > 14.4 | 3600초 | Critical |
| `fiveline-alarm-ca-pending-pods` | `pod_number_of_pending` | > 0 (4분 지속) | 60초 | Warning |

**공통 설정** (MON-009 노이즈 억제):
```hcl
datapoints_to_alarm = 2
evaluation_periods  = 2
treat_missing_data  = "notBreaching"
```

### SNS → Lambda → DynamoDB 알람 처리 흐름

```
CloudWatch Alarm (상태 변화)
  → SNS Topic (fiveline-sns-alarm)
    → Lambda Alarm Handler
      ├─ alarm_history DynamoDB PutItem (원시 이력, 90일 TTL)
      ├─ dashboard_summary DynamoDB UpdateItem (집계)
      ├─ Slack Webhook POST (Critical=빨강, Warning=노랑)
      └─ (옵션) Bedrock 분석 Lambda 비동기 트리거
```

### Cluster Autoscaler Helm 설치

```bash
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm install cluster-autoscaler autoscaler/cluster-autoscaler \
  --namespace kube-system \
  --set autoDiscovery.clusterName=fiveline-eks \
  --set awsRegion=ap-northeast-2 \
  --set rbac.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=<CA_IRSA_ROLE_ARN> \
  --set extraArgs.balance-similar-node-groups=true \
  --set extraArgs.expander=least-waste \
  --set nodeSelector."workload"=stable
```

> **필수**: `eks.tf` 노드 그룹 tags에 CA 자동 발견 태그 2개 추가 후 `terraform apply` 먼저 실행.

### Node Termination Handler Helm 설치

```bash
helm install aws-node-termination-handler eks/aws-node-termination-handler \
  --namespace kube-system \
  --set enableSqsTerminationDraining=true \
  --set queueURL=<SQS_NTH_QUEUE_URL> \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=<NTH_IRSA_ROLE_ARN> \
  --set tolerations[0].operator=Exists \
  --set podTerminationGracePeriod=120
```

### Grafana 골든 시그널 4행 대시보드

| 행 | 골든 시그널 | 주요 패널 |
|----|------------|---------|
| Row 1 | Latency | ALB P50/P95/P99, order-service P99 게이지 |
| Row 2 | Traffic | ALB 요청 RPS, HPA currentReplicas, On-Demand/Spot 노드 수 |
| Row 3 | Errors | ALB 5xx 비율, ORDER_FAILED 이벤트 수, Pod 재시작 횟수 |
| Row 4 | Saturation | 노드 CPU/Memory%, RDS 커넥션 수, Redis HitRate%, FreeStorage |

## 완료 검증 방법

```bash
# 1. 알람 강제 발화 테스트
aws cloudwatch set-alarm-state \
  --alarm-name "fiveline-alarm-rds-write-latency" \
  --state-value ALARM \
  --state-reason "테스트 발화"
# → Slack 알림 수신 + DynamoDB alarm_history 레코드 생성 확인

# 2. Spot 회수 시뮬레이션
aws events put-events --entries '[{
  "Source": "aws.ec2",
  "DetailType": "EC2 Spot Instance Interruption Warning",
  "Detail": "{\"instance-id\": \"<SPOT_NODE_ID>\", \"instance-action\": \"terminate\"}",
  "EventBusName": "default"
}]'
# → NTH가 노드 cordon + drain 확인 (kubectl get nodes -w)

# 3. CA 동작 검증 (IR-009)
kubectl run cpu-stress --image=busybox --restart=Never \
  -- sh -c "while true; do :; done"
# → HPA scaleUp → Pending Pod 발생 → CA 노드 추가 < 4분 (MON-014)
```

## 담당 요구사항 ID

**Must**: MON-001~011, AVAIL-001~002, AVAIL-004~005, INFRA-006, IR-009, DASH-001~002, DASH-006  
**Should**: MON-012~014, AVAIL-010, IR-010~012, DASH-003~004, DASH-007

---

---

# 4. CI/CD 담당자

## 담당 AWS 서비스 및 도구

| 서비스 | 역할 |
|--------|------|
| **Amazon ECR** | 3개 서비스 컨테이너 이미지 레지스트리 (user/product/order-service) |
| **GitHub Actions** | 빌드/보안스캔/이미지 푸시 자동화 파이프라인 |
| **GitHub OIDC IAM Role** | 장기 액세스키 없이 임시 자격증명으로 AWS 접근 |
| **ArgoCD** | Manifest Repository 기반 GitOps 선언적 배포 |
| **AWS Load Balancer Controller** | K8s Ingress 적용 시 ALB 자동 프로비저닝 |
| **K8s 매니페스트** | Deployment, Service, Ingress, HPA, PDB 완성 |

## 구현할 Terraform 파일 목록

| 파일 | 포함 리소스 | 의존성 |
|------|------------|--------|
| `ecr.tf` | ECR 레포 3개 (user/product/order-service), Lifecycle Policy | — |
| `github_oidc_iam.tf` | GitHub OIDC Provider, GitHub Actions IAM Role + Policy | — |
| `alb_controller_iam.tf` | ALB Controller IRSA Role + Policy | `eks.tf` (OIDC Provider — 보안 담당자 생성 후 data source 참조) |

> **ALB는 Terraform으로 직접 생성하지 않는다.** ALB Controller를 Helm으로 설치하고 K8s Ingress를 적용하면 Controller가 자동으로 ALB를 프로비저닝한다.

## 구현 순서

| 단계 | 작업 | 예상 시간 |
|------|------|---------|
| **1단계** | `ecr.tf` — ECR 레포 3개 생성 | 1시간 |
| **2단계** | `github_oidc_iam.tf` — GitHub OIDC + IAM Role | 1시간 |
| **3단계** | `alb_controller_iam.tf` — ALB Controller IRSA Role 생성 | 1시간 |
| **4단계** | AWS Load Balancer Controller Helm 설치 | 1시간 |
| **5단계** | Manifest Repository (`fiveline-manifest`) 구조 생성 (Kustomize) | 2시간 |
| **6단계** | ArgoCD 설치 + Application 설정 | 2시간 |
| **7단계** | GitHub Actions 워크플로우 작성 (보안 스캔 포함) | 4시간 |
| **8단계** | K8s 매니페스트 완성 (`<AWS_ACCOUNT_ID>` 교체, Ingress 작성, IRSA 바인딩) | 2시간 |
| **9단계** | End-to-End 테스트 (코드 푸시 → 자동 배포) | 2시간 |

## 핵심 구현 상세

### ECR 설정

```hcl
resource "aws_ecr_repository" "services" {
  for_each = toset(["user-service", "product-service", "order-service"])

  repository_name      = "fiveline/${each.value}"
  image_tag_mutability = "IMMUTABLE"  # 불변 태그 (CICD-005)
  tags = { Name = "fiveline-ecr-${each.value}", Service = "cicd" }
}
```

Lifecycle Policy: 언태그 이미지 30일 후 삭제, 최근 10개 태그 이미지 유지.

### GitHub OIDC IAM Role (장기 키 불필요, CICD-015)

```hcl
resource "aws_iam_role" "github_actions" {
  name = "fiveline-iam-github-actions"
  assume_role_policy = jsonencode({
    ...
    Condition = {
      StringLike = {
        "token.actions.githubusercontent.com:sub" = "repo:fiveline-org/*:ref:refs/heads/main"
      }
    }
  })
}
```

### GitHub Actions 워크플로우 — 보안 스캔 포함

```
코드 push
  → 1. OIDC 인증 (장기 키 없음)
  → 2. CodeQL 정적분석 (CICD-007)
  → 3. Bandit Python 보안 스캔 (CICD-007)
  → 4. Gitleaks 시크릿 스캔 (CICD-008)
  → 5. 유닛 테스트
  → 6. Docker 이미지 빌드
  → 7. Trivy 취약점 스캔 — Critical/High 발견 시 배포 차단 (CICD-006)
  → 8. ECR 푸시 (커밋 SHA 태그: sha-abc1234)
  → 9. Manifest Repo 이미지 태그 업데이트 + git commit
  → ArgoCD 감지 → 자동 배포
```

| 스캔 도구 | 대상 | 실패 조건 |
|---------|------|---------|
| CodeQL | Python 소스 | SQL Injection, 인증우회 등 |
| Bandit | Python | 하드코딩 비밀번호, SQL 인젝션 |
| Gitleaks | Git History | API Key, DB 패스워드 패턴 |
| Trivy | 컨테이너 이미지 | CVE Critical/High |

### Manifest Repository 구조 (Kustomize)

```
fiveline-manifest/
├── base/
│   ├── kustomization.yaml
│   ├── user-service/ (deployment, service, hpa, pdb, serviceaccount)
│   ├── product-service/
│   ├── order-service/
│   ├── ingress.yaml          # ALB Controller가 이 파일로 ALB 자동 생성
│   └── external-secrets/ (secretstore, externalsecret)
└── overlays/
    └── prod/ (ArgoCD Application이 참조)
```

### ArgoCD 동기화 정책

```yaml
# 이 프로젝트는 단일 AWS 환경 운영
# prod overlay 하나만 사용, manual-sync로 배포 승인 관리
spec:
  syncPolicy:
    automated: null   # 수동 동기화 (배포 시 argocd app sync 또는 UI 승인)
    syncOptions:
      - CreateNamespace=true
```

**롤백**: `argocd app rollback fiveline <REVISION>` — 이전 Git 리비전으로 즉시 복구

### ALB Ingress 핵심 어노테이션

```yaml
annotations:
  alb.ingress.kubernetes.io/scheme: internet-facing
  alb.ingress.kubernetes.io/target-type: ip
  alb.ingress.kubernetes.io/certificate-arn: <ACM_ARN>           # 보안 담당자가 생성
  alb.ingress.kubernetes.io/ssl-redirect: '443'
  alb.ingress.kubernetes.io/wafv2-web-acl-arn: <WAF_REGIONAL_ARN>  # 보안 담당자가 생성
  alb.ingress.kubernetes.io/healthcheck-path: /api/health
  alb.ingress.kubernetes.io/load-balancer-name: fiveline-alb
```

경로 라우팅: `/api/users` → user-service:8001 / `/api/products` → product-service:8002 / `/api/orders` → order-service:8003

### K8s 매니페스트 수정 사항

| 항목 | 현재 | 수정 후 |
|------|------|--------|
| ECR 이미지 | `<AWS_ACCOUNT_ID>.dkr.ecr.../fiveline/user-service:latest` | 실제 계정 ID + SHA 태그 |
| ServiceAccount role-arn | `fiveline-dev-user-service-sa-role` (구 네이밍) | `fiveline-user-service-sa-role` |
| fiveline-secret | 수동 생성 필요 | ESO ExternalSecret으로 자동 생성 (보안 담당자와 협력) |

## 완료 검증 방법

```bash
# 1. fiveline-backend 코드 push
git push origin main

# 2. GitHub Actions 완료 확인 (약 10~15분)
# → Trivy 스캔 통과, ECR 이미지 push 확인

# 3. Manifest Repo 자동 커밋 확인
git log --oneline fiveline-manifest:main | head -3
# "ci: update user-service image to sha-abc1234"

# 4. ArgoCD 동기화 확인
argocd app get fiveline
# syncStatus: Synced

# 5. EKS 배포 + ALB 생성 확인
kubectl get pods -l app=user-service -o wide
kubectl get ingress fiveline-ingress   # ALB DNS 주소 확인

# 6. ALB 통신 확인
curl https://<ALB_DNS>/api/health
# {"status": "ok"}
```

## 담당 요구사항 ID

**Must**: CICD-001~015, INFRA-008, INFRA-014, SEC-022  
**Should**: CICD-009 (tfsec IaC 스캔), CICD-016 (Cosign 이미지 서명)

---

---

## 팀 간 협업 포인트

| 항목 | 주도 담당 | 협력 담당 |
|------|---------|---------|
| KMS CMK 생성 | 보안 | 데이터 파이프라인 (data source로 참조), 모니터링 |
| OIDC Provider 생성 | 보안 | 모니터링, CI/CD, 데이터 파이프라인 (data source로 참조) |
| IRSA Role ARN → K8s ServiceAccount | 보안 | CI/CD (serviceaccount.yaml 수정) |
| ACM 인증서 ARN → Ingress 어노테이션 | 보안 | CI/CD |
| WAF Regional ARN → Ingress 어노테이션 | 보안 | CI/CD |
| Fluent Bit IRSA Role | 데이터 파이프라인 | 보안 (iam.tf에 추가 또는 별도 파일) |
| alarm_history/dashboard_summary 테이블 | 모니터링/알람 | 데이터 파이프라인 (report-generator가 읽기만) |
| eks.tf 노드 그룹 CA 태그 추가 | 모니터링/알람 | 인프라 담당자에게 PR |
| ALB 생성 (Ingress 적용) | CI/CD | 모니터링/알람 (ALB 알람 설정 가능 시점) |
| IRSA 방식 통일 결정 | 보안 | 전체 팀 |

> **IRSA 방식으로 통일**: 현재 EKS에 `eks-pod-identity-agent` 애드온이 설치되어 있으나, 기존 매니페스트가 IRSA 방식을 사용하고 ESO/ALB Controller와의 호환성을 고려하여 **IRSA(OIDC) 방식으로 통일**한다. 모든 담당자는 IRSA Role 생성 시 보안 담당자가 만든 OIDC Provider를 `data` source로 참조한다.
