# Fiveline 보안 설계 — 개인 발표 참고 문서

> 담당: 이재민 (보안 파트)  
> 시나리오: 무신사/올리브영 수준 이커머스 기업으로부터 인프라 아키텍처 설계를 의뢰받은 MSP

---

## 발표 구성 요약

| # | 항목 | 위협 시나리오 | 상태 |
|---|------|-------------|------|
| 1 | 이커머스 특화 WAF Custom Rate Limit | 크리덴셜 스터핑 / 카드 BIN 어택 / 가격 스크래핑 | ✅ |
| 2 | GuardDuty → Lambda → WAF 자동 차단 (Reactive SOAR) | 탐지~차단 사이 수동 대응 공백 | ✅ |

---

## 1. 이커머스 특화 WAF Custom Rate Limit ✅

### 왜 필요한가

AWS 관리형 룰셋은 SQLi, XSS 등 패턴 기반 공격을 탐지한다.
이커머스를 실제로 위협하는 공격은 **형식이 완전히 정상인 HTTP 요청**이어서 관리형 룰셋으로 탐지할 수 없다.

| 공격 | 방식 | 피해 |
|------|------|------|
| 크리덴셜 스터핑 | 유출된 ID/PW를 `/api/auth/login`에 대량 대입 | 계정 탈취 → 포인트/결제수단 도용 |
| 카드 BIN 어택 | 훔친 카드번호를 `/api/orders/from-cart`에 대량 검증 | 결제사 제재, 매출 손실 |

### 구현

**배치 위치: CloudFront WAF (us-east-1)**

Regional WAF는 ALB 앞에 위치하므로 CloudFront Edge IP만 보고, 실제 공격자 IP를 식별할 수 없다. 실제 클라이언트 IP가 보이는 CloudFront WAF에 Rate Limit을 배치해야 한다.

**CloudFront WAF — 모든 이커머스 Rate Limit 통합 배치 (modules/cdn/main.tf)**

Regional WAF는 ALB 앞에서 CloudFront Edge IP만 본다. `aggregate_key_type = "IP"` 기준 집계가 개별 공격자 IP가 아닌 Edge IP 기준으로 동작하므로, 실제 클라이언트 IP가 보이는 CloudFront WAF에 모든 rate limit을 배치한다.

```
/api/auth/login  → 100 req / 5min  (priority 0 — 크리덴셜 스터핑)
/api/orders      → 100 req / 5min  (priority 1 — 카드 BIN 어택)
```

임계값 근거: 정상 사용자는 5분 내 로그인 100회, 결제 100회를 시도하지 않는다. 봇은 초당 수백 건 시도한다.

### 한계

IP 변경(프록시/봇넷 사용)으로 우회 가능하다. WAF Rate Limit은 1차 방어선이며, 애플리케이션 레벨 Rate Limit(IP당 1분 10회) + Account Lockout(5회 실패 시 잠금)과 계층화해야 완전한 방어가 된다.

---

## 2. GuardDuty 자동 대응: Reactive SOAR ✅

### 설계 배경

GuardDuty가 탐지해도 차단은 수동이었다. 보안 담당자가 콘솔에 접속해 WAF 룰을 추가하는 수분~수시간의 공백 동안 공격이 지속된다.

목표: **탐지와 차단 사이의 지연을 제거한다.**

### 구현

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

### 구조적 한계

Reactive 방식의 태생적 한계: GuardDuty는 반복 패턴 누적 후 탐지한다.
**신규 악성 IP의 첫 번째 요청은 탐지 이전이므로 EKS까지 통과한다.**

### 알려진 개선 항목 (to-be)

| 항목 | 현재 | 개선 방향 |
|------|------|---------|
| DLQ 미설치 | 동시 HIGH finding 시 `WAFOptimisticLockException` → 차단 이벤트 소실 가능 | EventBridge target에 `retry_policy` + SQS DLQ 추가 |
| IP Set TTL 없음 | IP 누적만 되고 제거 메커니즘 없음 → 오탐 IP 영구 차단, 10,000개 한도 위험 | DynamoDB에 차단 시각 기록 + sweeper Lambda로 N일 후 자동 해제 |
