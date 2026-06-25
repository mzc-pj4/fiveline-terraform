# Fiveline 이커머스 보안 설계

> 담당: 이재민 (보안 파트)
> 전략: 기본 인프라 보안은 공통 발표, 이커머스 특화 고도화는 개인 발표

---

## 발표 전략

### 공통 발표 항목 (기본 인프라 보안 — 베이스라인)

> 이커머스가 아니어도 동일하게 적용. "당연히 해야 하는 것들을 빠짐없이 구축했다"는 메시지로 빠르게 정리.

| 항목 | 파일 | 핵심 |
|------|------|------|
| HTTPS 강제 + TLSv1.2_2021 | `cloudfront.tf` | 전송 암호화 기본 |
| CloudFront 보안 헤더 (HSTS / CSP / X-Frame-Options) | `cloudfront.tf` | OWASP Secure Headers, Magecart 웹스키밍 방어 |
| WAF 관리형 룰셋 4종 | `waf.tf` | SQLi / XSS / 악성 IP / KnownBad 자동 차단 |
| KMS CMK 3개 (etcd / rds / secrets) | `kms.tf` | AWS 관리 키 대신 고객 통제 키 |
| IMDSv2 + hop_limit=1 | `eks.tf`, `workstation.tf` | Capital One 사례 동일 경로 SSRF 차단 |
| EKS private endpoint 5-layer 설계 | `eks.tf`, `network.tf`, `iam.tf` | 외부 kubectl 접근 원천 차단 |
| Zero Trust: IRSA + VPC CNI NetworkPolicy | `iam.tf`, `eks.tf` | Pod별 최소 권한, 동서 트래픽 격리 |
| GuardDuty + SNS 알림 | `guardduty.tf` | MEDIUM 이상 이메일 자동 알림 |
| RDS 저장 암호화 + SG 격리 + 자동 백업 | `rds.tf` | 데이터 보호 3종 세트 |
| pgAudit (PII 접근 감사) | `rds.tf` | PIPA 제29조 접근 기록 의무 준수 |

---

### 개인 발표 핵심 (이커머스 특화 고도화 보안)

> "일반 인프라 보안은 '누가 들어오나'를 막습니다.
> 이커머스 고도화 보안은 **정상처럼 생긴 공격**, **파이프라인 무결성**, **DB 직접 접근 탐지**를 다룹니다."

| # | 항목 | 위협 시나리오 | 상태 |
|---|------|-------------|------|
| 1 | **이커머스 특화 WAF Custom Rate Limit** | 크리덴셜 스터핑 — 관리형 룰셋으로 탐지 불가 (정상 POST 요청처럼 보임) | ✅ |
| 2 | **GuardDuty → Lambda → WAF 자동 차단** | 악성 IP/행위 탐지 후 수동 대응 지연 — 탐지부터 차단까지 자동화 부재 | ⬜ |
| 3 | **pgAudit ↔ 앱 로그 교차검증 (Ghost Query)** | 앱 레이어 우회 후 DB 직접 접근 — 앱 로그에는 흔적 없음, pgAudit에만 기록 | ⬜ |

---

## 1. 이커머스 특화 WAF Custom Rate Limit ✅

### 왜 고도화가 필요한가

관리형 룰셋은 악성 코드 패턴(SQLi, XSS 등)을 탐지한다.
크리덴셜 스터핑은 형식이 완전히 정상인 로그인 요청이므로 탐지 불가.

| 공격 | 형태 | 관리형 룰셋 |
|------|------|------------|
| 크리덴셜 스터핑 | 유출 ID/PW를 `/api/auth/login`에 수만 건 대입 | **차단 불가** |
| 카드 BIN 어택 | 훔친 카드번호를 `/api/orders`에 대량 검증 | **차단 불가** |
| 가격 스크래핑 | 전 상품 가격 자동 수집 (`/api/products`) | **차단 불가** |

### 구현

**CloudFront WAF** (us-east-1)에 `ecommerce-login-ratelimit` 룰 추가.

- 동일 IP → `/api/auth/login` 경로 → 5분 100회 초과 → **BLOCK (429 Too Many Requests)**
- CloudFront WAF를 선택한 이유: Regional WAF는 CloudFront Edge IP만 보기 때문에 실제 공격자 IP 식별 불가. CloudFront WAF는 클라이언트와 직접 연결하는 엣지에서 실제 IP를 봄.

```hcl
# modules/cdn/main.tf
rule {
  name     = "ecommerce-login-ratelimit"
  priority = 0
  action { block {} }
  statement {
    rate_based_statement {
      limit              = 100
      aggregate_key_type = "IP"
      scope_down_statement {
        byte_match_statement {
          search_string         = "/api/auth/login"
          positional_constraint = "STARTS_WITH"
          field_to_match { uri_path {} }
          text_transformation { priority = 0; type = "LOWERCASE" }
        }
      }
    }
  }
}
```

### 남은 한계 및 추가 보완 방향

| 한계 | 보완 방법 |
|------|---------|
| IP 변경(프록시/봇넷) 시 우회 가능 | App Rate Limit (IP당 1분 10회), Account Lockout (5회 실패 시 잠금) |
| 계정 자체 보호 없음 | MFA 도입 |

---

## 2. GuardDuty → Lambda → WAF 자동 차단 ⬜

### 왜 고도화가 필요한가

GuardDuty는 악성 IP, 비정상 API 호출, 계정 탈취 시도 등을 탐지한다.
그러나 탐지 후 실제 차단까지는 보안 담당자가 콘솔에 접속해 수동으로 WAF 룰을 추가해야 한다.
이 공백 시간 동안 공격은 계속된다.

**핵심 통찰**: 탐지(Detection)와 대응(Response) 사이의 지연을 없애야 한다.
GuardDuty 탐지 즉시 Lambda가 WAF IP Set에 해당 IP를 자동 추가해 사람 개입 없이 차단한다.

### 구현

**① GuardDuty Finding → EventBridge → Lambda**

GuardDuty HIGH severity finding 발생 시 EventBridge 트리거 → Lambda 실행

**② Lambda — 악성 IP 추출 후 WAF IP Set 자동 추가**

```python
wafv2.update_ip_set(
    Name='guardduty-blocked-ips',
    Scope='CLOUDFRONT',
    Addresses=[malicious_ip + '/32']
)
```

**③ WAF — guardduty-blocked-ips IP Set 참조 BLOCK 룰**

CloudFront WAF에 IP Set 기반 차단 룰 추가 → 이후 해당 IP 모든 요청 즉시 차단

**④ SNS 알림**

Lambda 차단 완료 시 SNS → 이메일 알림

### Before / After 데모

| | 내용 |
|--|------|
| Before | GuardDuty finding 발생 → 콘솔 알림만 → 수동 대응 필요 (수분~수시간 공백) |
| After | GuardDuty finding 발생 → 수 초 내 WAF 자동 차단 + 이메일 알림 도착 |

### SA 포인트

별도 SOAR 솔루션 없이 GuardDuty + EventBridge + Lambda + WAF 조합으로 탐지→차단 자동화(Auto-remediation) 구현. 대응 시간을 수분에서 수초로 단축.

---

## 3. pgAudit ↔ 앱 로그 교차검증 (Ghost Query Detection) ⬜

### 왜 고도화가 필요한가

정상적인 DB 접근은 항상 앱 API 호출을 수반한다.
DB 쿼리가 있는데 대응하는 앱 API 호출이 없으면 → 앱 레이어를 우회한 직접 접근.

```
공격자가 DB 자격증명 탈취 → psql로 RDS 직접 접속
→ SELECT email, password_hash FROM user_schema.users
→ pgAudit 로그에는 기록됨
→ 앱 service_events 로그에는 대응 API 요청 없음
→ 이 "Ghost Query"를 탐지하는 장치가 없으면 수만 건 유출되어도 알람 없음
```

**SA 포인트**: 별도 SIEM 솔루션 없이 기존 pgAudit + Athena 인프라만으로 구현.

### 구현

**① pgAudit 로그 → S3 Data Lake 전송** (pgAudit → CloudWatch → Firehose → S3)

**② Athena 교차 검증 쿼리 — EventBridge 스케줄로 매일 자정 Lambda 실행**

```sql
WITH db_queries AS (
    SELECT date_trunc('minute', query_time) AS query_minute
    FROM fiveline_dev_analytics.pgaudit_logs
    WHERE command_tag IN ('SELECT', 'UPDATE', 'DELETE')
      AND object_name IN ('users', 'orders')
),
app_requests AS (
    SELECT date_trunc('minute', event_time) AS req_minute
    FROM fiveline_dev_analytics.service_events
)
SELECT db.query_minute, 'Ghost Query — 앱 우회 직접 접근 의심' AS alert
FROM db_queries db
LEFT JOIN app_requests app ON db.query_minute = app.req_minute
WHERE app.req_minute IS NULL
```

**③ Lambda — Ghost Query 탐지 시 SNS 알람 발송**

### Before / After 데모

| | 내용 |
|--|------|
| Before | Bastion → psql → `SELECT * FROM users` → pgAudit 로그에 기록되지만 알림 없음 |
| After | 동일 직접 접속 → Lambda 실행 → "앱 레이어 우회 직접 접근 탐지" SNS 알람 |
