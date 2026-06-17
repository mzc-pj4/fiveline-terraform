# Athena 분석 쿼리 — 가이드

## 개요

`analytics-queries.sql` 에 14개의 분석 쿼리가 카테고리별로 정리되어 있습니다.

| 카테고리 | 쿼리 수 | 목적 |
|---|---|---|
| A. service_events 기본 통계 | 4 | 적재량·시간대 분포 |
| B. 로그 메시지 키워드 분석 | 4 | 에러·경고 패턴 추출 |
| C. resource_check (FinOps) | 4 | 미사용 자원·태그 누락 |
| D. 결합·이상 탐지 | 3 | 피크·스트림별 에러율 |

## 실행 방법

### AWS 콘솔
1. Athena 콘솔 진입
2. 워크그룹 `mzc-pj4-jihoo-analytics-dev` 선택
3. 데이터베이스 `mzc_pj4_jihoo_data_lake_dev` 선택
4. `analytics-queries.sql` 에서 원하는 쿼리 복사 → 실행

### CLI
```powershell
$DB = "mzc_pj4_jihoo_data_lake_dev"
$WG = "mzc-pj4-jihoo-analytics-dev"

# 쿼리 시작
$qid = aws athena start-query-execution `
  --query-string "SELECT COUNT(*) FROM service_events CROSS JOIN UNNEST(logevents) AS t(ev)" `
  --query-execution-context Database=$DB `
  --work-group $WG `
  --query 'QueryExecutionId' --output text

# 결과 확인
aws athena get-query-results --query-execution-id $qid
```

## 발표용 핵심 쿼리 5선

검증 완료된 의미 있는 쿼리. 발표에 그대로 사용 가능.

### 1. 적재된 총 로그 이벤트 수 (A1)
```sql
SELECT COUNT(*) AS total_events
FROM service_events
CROSS JOIN UNNEST(logevents) AS t(ev);
```
**결과**: `32,331건` (EKS Control Plane 로그)

### 2. 에러·경고 비율 (B1)
```sql
SELECT
  SUM(CASE WHEN regexp_like(ev.message, '(?i)error')   THEN 1 ELSE 0 END) AS error_count,
  SUM(CASE WHEN regexp_like(ev.message, '(?i)failed')  THEN 1 ELSE 0 END) AS failed_count,
  COUNT(*) AS total_messages
FROM service_events
CROSS JOIN UNNEST(logevents) AS t(ev);
```
**결과**: error 2,517 / failed 2,568 / total 32,331 → **에러 키워드 ~7.8%**

### 3. 시간대별 로그 분포 (A2)
```sql
SELECT hour, COUNT(*) AS event_count
FROM service_events
CROSS JOIN UNNEST(logevents) AS t(ev)
GROUP BY hour
ORDER BY hour;
```
**결과**: 01시 32,330 / 02시 1 → 가동 직후 1시간에 로그 집중

### 4. 스트림별 에러율 TOP (D2)
```sql
SELECT logstream,
       COUNT(*) AS total,
       SUM(CASE WHEN regexp_like(ev.message, '(?i)error|failed|exception')
                THEN 1 ELSE 0 END) AS errors,
       ROUND(100.0 * SUM(CASE WHEN regexp_like(ev.message, '(?i)error|failed|exception')
                              THEN 1 ELSE 0 END) / COUNT(*), 2) AS error_pct
FROM service_events
CROSS JOIN UNNEST(logevents) AS t(ev)
GROUP BY logstream
HAVING COUNT(*) >= 10
ORDER BY error_pct DESC
LIMIT 5;
```
**결과**:
| logstream | total | errors | error_pct |
|---|---|---|---|
| kube-apiserver-0471c97...     | 2,073 | 1,277 | 61.60% |
| kube-apiserver-91b3eadf...    | 1,923 | 1,165 | 60.58% |
| kube-apiserver-94731c6a...    |   218 |    56 | 25.69% |
| kube-apiserver-027b38cf...    |   226 |    49 | 21.68% |
| authenticator-91b3eadf...     |    59 |     1 |  1.69% |

### 5. 리소스 점검 결과 분포 (C1)
```sql
SELECT f.checkType AS check_type, COUNT(*) AS finding_count
FROM resource_check r
CROSS JOIN UNNEST(r.findings) AS t(f)
GROUP BY f.checkType
ORDER BY finding_count DESC;
```
**결과**: MISSING_TAGS 4 / UNUSED_RESOURCE 1

## 데이터 소스 정리

### service_events
- **출처**: CloudWatch Logs Subscription Filter (EKS Control Plane `/aws/eks/fiveline-eks/cluster`) → Kinesis Firehose → S3
- **적재**: 약 60초 주기 자동
- **규모**: 32,331개 이벤트 (2026-06-04 01시 기준)

### resource_check
- **출처**: Resource Checker Lambda (EC2/EBS 점검) → DynamoDB + S3
- **적재**: EventBridge 일간 스케줄
- **규모**: 5건 findings

## 워크그룹 비용 제한

| 워크그룹 | 쿼리당 한도 | 용도 |
|---|---|---|
| `analytics` | 10 GB | 운영자 Ad-hoc 분석 |
| `ai-reports` | 5 GB | Bedrock Lambda 자동 호출 |

→ 위 쿼리들은 모두 1 MB 미만 (파티션 프루닝 적용).
