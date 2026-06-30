# GuardDuty 개인 고도화 — Reactive SOAR: 자동 차단 파이프라인

> GuardDuty가 탐지한 위협을 사람의 개입 없이 WAF까지 전파해 차단 지연을 제거한다.

---

## 배경

GuardDuty가 탐지해도 실제 차단은 수동이었다.
보안 담당자가 Finding을 확인하고 WAF 룰을 추가하는 데 수분~수시간이 걸리며,
그 공백 동안 동일 IP의 공격이 계속된다.

목표: **탐지와 차단 사이의 지연을 제거한다.**

---

## 구성 요소

| 리소스 | 역할 |
|--------|------|
| GuardDuty Detector | VPC Flow Logs, S3, EKS Audit 로그 행위 탐지 |
| EventBridge Rule 1 | severity ≥ 4 (MEDIUM+) → SNS 이메일 알림 |
| EventBridge Rule 2 | severity ≥ 7 (HIGH+) → Lambda 자동 차단 |
| Lambda (guardduty-auto-block) | Finding에서 공격자 IP 추출 → WAF IP Set 업데이트 |
| CloudFront WAF IP Set | guardduty-blocked-ips — Lambda가 추가한 IP 즉시 BLOCK |
| SNS | 이메일 알림 (MEDIUM+, HIGH+ 공통) |

---

## 자동화 흐름

```
GuardDuty Finding 발생
  ├─ severity ≥ 4 (MEDIUM+) → EventBridge Rule 1 → SNS → 이메일 알림
  └─ severity ≥ 7 (HIGH+)  → EventBridge Rule 2 → Lambda
                                    ↓
                          Finding에서 공격자 IP 추출
                          (networkConnectionAction / awsApiCallAction / portProbeAction)
                                    ↓
                       WAF guardduty-blocked-ips IP Set 업데이트
                                    ↓
                          이후 해당 IP 모든 요청 즉시 BLOCK
```

---

## 왜 이렇게 구현했는가

**HIGH(≥7)에만 자동 차단을 적용한 이유**

자동 차단은 오탐 시 정상 사용자를 즉시 차단하는 파괴적 액션이다.
GuardDuty HIGH finding은 신뢰도가 높고 즉각적 위협을 의미하므로 자동 차단에 적합하다.
MEDIUM finding은 사람이 판단할 수 있도록 알림에만 머문다.

HIGH finding은 두 룰 동시 발화 → 이메일 알림 + 자동 차단 병행.

**LockToken 기반 동시성 처리**

여러 Finding이 동시에 발생해 Lambda가 동시 실행될 경우, WAF IP Set 업데이트 충돌을 `LockToken` optimistic locking으로 방지한다.

---

## 한계 (알려진 개선 항목)

| 항목 | 현재 | 개선 방향 |
|------|------|---------|
| DLQ 미설치 | 동시 HIGH finding 시 WAFOptimisticLockException → 차단 이벤트 소실 가능 | EventBridge target retry_policy + SQS DLQ 추가 |
| IP Set TTL 없음 | IP 누적만 되고 제거 메커니즘 없음 → 오탐 IP 영구 차단, 10,000개 한도 위험 | DynamoDB 차단 시각 기록 + sweeper Lambda로 N일 후 자동 해제 |

---

## 구조적 한계

Reactive 방식의 태생적 한계: GuardDuty는 반복 패턴 누적 후 탐지한다.
**신규 악성 IP의 첫 번째 요청은 탐지 이전이므로 EKS까지 통과한다.**

이 한계를 2-2 Proactive 레이어가 보완한다.
