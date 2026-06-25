# Fiveline 보안 설계 — 개인 발표 참고 문서

> 담당: 이재민 (보안 파트)  
> 시나리오: 무신사/올리브영 수준 이커머스 기업으로부터 인프라 아키텍처 설계를 의뢰받은 MSP

---

## 발표 구성 요약

| # | 항목 | 위협 시나리오 | 상태 |
|---|------|-------------|------|
| 1 | 이커머스 특화 WAF Custom Rate Limit | 크리덴셜 스터핑 / 카드 BIN 어택 / 가격 스크래핑 | ✅ |
| 2-1 | GuardDuty → Lambda → WAF 자동 차단 (Reactive SOAR) | 탐지~차단 사이 수동 대응 공백 | ✅ |
| 2-2 | IP Reputation List + Rate-based Rule (Proactive) | Reactive 구조의 첫 요청 통과 한계 보완 | ✅ |
| 3 | pgAudit ↔ 앱 로그 교차검증 (Ghost Query Detection) | 앱 레이어 우회 DB 직접 접근 탐지 부재 | ⬜ |

---

## 1. 이커머스 특화 WAF Custom Rate Limit ✅

### 왜 필요한가

AWS 관리형 룰셋은 SQLi, XSS 등 패턴 기반 공격을 탐지한다.
이커머스를 실제로 위협하는 공격은 **형식이 완전히 정상인 HTTP 요청**이어서 관리형 룰셋으로 탐지할 수 없다.

| 공격 | 방식 | 피해 |
|------|------|------|
| 크리덴셜 스터핑 | 유출된 ID/PW를 `/api/auth/login`에 대량 대입 | 계정 탈취 → 포인트/결제수단 도용 |
| 카드 BIN 어택 | 훔친 카드번호를 `/api/orders/from-cart`에 대량 검증 | 결제사 제재, 매출 손실 |
| 가격 스크래핑 | `/api/products` 전 상품 자동 수집 | 경쟁사 실시간 가격 추적, 서버 부하 |

### 구현

**배치 위치: CloudFront WAF (us-east-1)**

Regional WAF는 ALB 앞에 위치하므로 CloudFront Edge IP만 보고, 실제 공격자 IP를 식별할 수 없다. 실제 클라이언트 IP가 보이는 CloudFront WAF에 Rate Limit을 배치해야 한다.

**CloudFront WAF — 로그인 엔드포인트 보호**

```hcl
# modules/cdn/main.tf (priority 0)
rate_based_statement {
  limit              = 100        # IP당 5분 100회 초과 → BLOCK 429
  aggregate_key_type = "IP"
  scope_down_statement {
    uri_path = "/api/auth/login"  # 크리덴셜 스터핑 대상 엔드포인트 한정
  }
}
```

**Regional WAF — 이커머스 엔드포인트별 분리 (modules/security/main.tf)**

```
/api/auth/login         → 100 req / 5min   (크리덴셜 스터핑)
/api/orders/from-cart   → 100 req / 5min   (카드 BIN 어택)
/api/products           → 500 req / 5min   (가격 스크래핑 — 정상 조회가 많아 임계값 완화)
```

임계값 근거: 정상 사용자는 5분 내 로그인 100회, 결제 100회를 시도하지 않는다. 봇은 초당 수백 건 시도한다.

### 한계

IP 변경(프록시/봇넷 사용)으로 우회 가능하다. WAF Rate Limit은 1차 방어선이며, 애플리케이션 레벨 Rate Limit(IP당 1분 10회) + Account Lockout(5회 실패 시 잠금)과 계층화해야 완전한 방어가 된다.

---

## 2. GuardDuty 자동 대응: 3중 방어 체계 ✅

### 설계 배경

단일 방어 레이어는 단일 실패점이다.
**"알려진 위협을 입구에서 선제 차단(Proactive)"** 과 **"행위 탐지 후 자동 대응(Reactive)"** 을 조합해 각 레이어의 약점을 상호 보완한다.

### 3중 방어 구조

```
CloudFront → WAF
              ├─ [Proactive ①] IP Reputation List (priority 1)
              │    └─ 알려진 악성 IP (봇넷/C&C/Tor) → 첫 요청부터 BLOCK
              │
              ├─ [Proactive ②] Rate-based Rule 2000 req/5min (priority 9)
              │    └─ 고속 반복 공격 → 임계값 초과 즉시 BLOCK
              │
              └─ [Reactive]   guardduty-blocked-ips IP Set (priority 7)
                   └─ GuardDuty 탐지 IP → Lambda가 자동 추가 → BLOCK

GuardDuty (VPC 트래픽 행위 탐지)
    │
    ├─ severity ≥ 4 (MEDIUM+) → EventBridge Rule 1 → SNS → 이메일 알림
    └─ severity ≥ 7 (HIGH+)  → EventBridge Rule 2 → Lambda → WAF IP Set 업데이트
```

---

### 2-1. Reactive SOAR: GuardDuty → Lambda → WAF ✅

#### 왜 필요한가

GuardDuty가 탐지해도 차단은 수동이었다. 보안 담당자가 콘솔에 접속해 WAF 룰을 추가하는 수분~수시간의 공백 동안 공격이 지속된다.

목표: **탐지와 차단 사이의 지연을 제거한다.**

#### 구현

**① EventBridge — severity 기준 2개 룰 분리**

| 룰 | 조건 | 대응 |
|----|------|------|
| Rule 1 | severity ≥ 4 (MEDIUM+) | SNS → 이메일 알림 |
| Rule 2 | severity ≥ 7 (HIGH+) | Lambda → WAF IP Set 자동 추가 |

HIGH finding은 두 룰 동시 발화 → 이메일 알림 + 자동 차단 병행.

**자동 차단을 HIGH(≥7)에만 적용하는 이유**: 자동 차단은 오탐 시 정상 사용자를 차단하는 파괴적 액션이다. 신뢰도가 높은 HIGH finding에만 적용하고, MEDIUM은 사람이 판단할 수 있도록 알림에 머문다.

**② Lambda — Finding에서 IP 추출 → WAF IP Set 업데이트**

GuardDuty Finding의 3가지 액션 타입에서 공격자 IP 추출:
- `networkConnectionAction` → `remoteIpDetails.ipAddressV4`
- `awsApiCallAction` → `remoteIpDetails.ipAddressV4`
- `portProbeAction` → `portProbeDetails[0].remoteIpDetails.ipAddressV4`

이미 차단된 IP는 skip(중복 체크). LockToken 기반 optimistic locking으로 동시성 보장.

**③ CloudFront WAF — guardduty-blocked-ips IP Set (priority 7)**

Lambda가 추가한 IP는 이후 모든 요청에서 즉시 BLOCK.

#### 2-1 구조적 한계

Reactive 방식의 태생적 한계: GuardDuty는 반복 패턴 누적 후 탐지한다.
**신규 악성 IP의 첫 번째 요청은 탐지 이전이므로 EKS까지 통과한다.**

이 한계를 2-2 Proactive 레이어가 보완한다.

#### 알려진 개선 항목 (to-be)

| 항목 | 현재 | 개선 방향 |
|------|------|---------|
| DLQ 미설치 | 동시 HIGH finding 시 `WAFOptimisticLockException` → 차단 이벤트 소실 가능 | EventBridge target에 `retry_policy` + SQS DLQ 추가 |
| IP Set TTL 없음 | IP 누적만 되고 제거 메커니즘 없음 → 오탐 IP 영구 차단, 10,000개 한도 위험 | DynamoDB에 차단 시각 기록 + sweeper Lambda로 N일 후 자동 해제 |

---

### 2-2. Proactive 추가: IP Reputation List + Rate-based Rule ✅

#### 왜 추가했는가

2-1 Reactive만으로는 첫 요청이 통과한다.
**알려진 위협과 고속 반복 공격은 탐지 이전에 선제 차단**할 수 있다.

#### ① IP Reputation List — AWS Managed Rules (priority 1)

AWS가 관리하는 악성 IP 데이터베이스(봇넷, C&C 서버, Tor 출구 노드 등).
이미 알려진 악성 IP는 WAF에서 첫 요청부터 즉시 차단된다. 별도 운영 비용 없이 AWS가 데이터베이스를 최신 상태로 유지한다.

#### ② global-rate-limit — Rate-based Rule (priority 9)

동일 IP에서 5분 내 2000회 초과 요청 시 자동 차단 (429 Too Many Requests).

`ecommerce-login-ratelimit`이 특정 엔드포인트를 정밀 차단한다면, 이 룰은 **모든 엔드포인트에 대한 전체 트래픽 볼륨 기반 선제 차단**이다.

#### 각 레이어의 커버리지와 한계

| 레이어 | 탐지 가능 | 탐지 불가 |
|--------|---------|---------|
| IP Reputation | 알려진 봇넷/C&C/Tor IP | 완전히 새로운 IP |
| Rate-based 2000 | 고속 반복 공격(스캔/DDoS) | 임계값 미만 저속 스텔스 공격 |
| GuardDuty→Lambda | 탐지된 행위 기반 악성 IP | 탐지 전 첫 요청 |

세 레이어의 조합이 각각의 공백을 상호 보완한다. 단, 완전히 새롭고 조용한 공격자의 첫 요청은 어떤 레이어로도 막을 수 없다는 것이 현실적인 한계다.

---

## 3. pgAudit ↔ 앱 로그 교차검증 (Ghost Query Detection) ⬜

### 왜 필요한가

`storage_encrypted = true`는 디스크 도난을 방어한다. SQL로 정상 접근하면 평문이다.

정상적인 DB 접근은 항상 앱 API 호출을 수반한다.
**pgAudit 로그에는 쿼리가 있는데 앱 로그에 대응하는 API 요청이 없으면 → 앱 레이어를 우회한 DB 직접 접근**이다.

```
공격자: DB 자격증명 탈취
  → psql로 RDS 직접 접속
  → SELECT email, password_hash FROM user_schema.users
  → pgAudit 로그: 기록됨
  → 앱 service_events: 대응 API 요청 없음  ← 이 불일치가 Ghost Query
  → 감지 장치 없으면 수만 건 유출되어도 알람 없음
```

### 구현

**① pgAudit → S3 Data Lake** (CloudWatch → Firehose → S3)

**② Athena 교차 검증 — EventBridge 스케줄로 매일 자정 Lambda 실행**

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

**③ Ghost Query 탐지 시 SNS 알람 발송**

### SA 포인트

별도 SIEM 없이 기존 pgAudit + Athena 인프라만으로 구현.  
개인정보보호법 제29조(접근 기록 6개월 보관) 준수 + 내부자 위협 탐지를 동일 파이프라인에서 달성.
