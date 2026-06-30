# 개인 고도화 3 — Proactive Defense: IP Reputation + Rate-based Rule

> Reactive SOAR(2번)의 첫 요청 통과 한계를 선제 차단 레이어로 보완한다.

---

## 배경

2-1 Reactive SOAR만으로는 GuardDuty 탐지 이전 첫 번째 요청이 서버까지 도달한다.
알려진 위협과 고속 반복 공격은 탐지를 기다릴 필요 없이 **입구에서 선제 차단**할 수 있다.

---

## 구성 요소

| 룰 | WAF 위치 | Priority | 상태 |
|----|----------|----------|------|
| AWSManagedRulesAmazonIpReputationList | CloudFront WAF | 2 | ✅ 배포 완료 |
| global-rate-limit (2000 req/5min) | CloudFront WAF | 10 | ✅ 배포 완료 |

---

## 각 룰 설명

### ① IP Reputation List — AWS Managed Rules (priority 2)

AWS가 관리하는 악성 IP 데이터베이스.
봇넷 C&C 서버, Tor 출구 노드, 알려진 스캐너 등 이미 악성으로 분류된 IP를 첫 요청부터 즉시 차단한다.

- 별도 운영 비용 없이 AWS가 DB를 최신 상태로 유지
- 신규 IP는 차단 불가 (알려진 IP에만 유효)

### ② global-rate-limit — Rate-based Rule (priority 10)

동일 IP에서 5분 내 2000회 초과 요청 시 자동 차단 (429 Too Many Requests).

`ecommerce-login-ratelimit`이 특정 엔드포인트를 정밀 차단한다면,
이 룰은 **모든 엔드포인트에 대한 전체 트래픽 볼륨 기반 선제 차단**이다.
스캔, DDoS, 무차별 대입 등 고속 반복 공격을 패턴 무관하게 차단한다.

---

## 3중 방어 구조 전체

```
CloudFront → WAF
              ├─ [Proactive ①] IP Reputation List (priority 2)
              │    └─ 알려진 악성 IP → 첫 요청부터 BLOCK
              │
              ├─ [Reactive]   guardduty-blocked-ips IP Set (priority 7)
              │    └─ GuardDuty 탐지 IP → Lambda 자동 추가 → BLOCK
              │
              └─ [Proactive ②] global-rate-limit 2000 req/5min (priority 10)
                   └─ 고속 반복 공격 → 임계값 초과 즉시 BLOCK
```

---

## 각 레이어의 커버리지

| 레이어 | 탐지 가능 | 탐지 불가 |
|--------|---------|---------|
| IP Reputation | 알려진 봇넷/C&C/Tor IP | 완전히 새로운 IP |
| guardduty-blocked-ips | GuardDuty 탐지 후 차단된 IP | 탐지 전 첫 요청 |
| global-rate-limit | 고속 반복 공격 (2000 req/5min 초과) | 임계값 미만 저속 스텔스 공격 |

세 레이어의 조합이 각각의 공백을 상호 보완한다.
단, 완전히 새롭고 조용한 공격자의 첫 요청은 어떤 레이어로도 막을 수 없다는 것이 현실적인 한계다.
