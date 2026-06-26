# WAF 개인 고도화 — 이커머스 특화 Rate Limit

> 이커머스 비즈니스 구조를 이해하고 설계한 커스텀 Rate Limit 룰.
> 관리형 룰셋이 탐지하지 못하는 "정상처럼 생긴 이커머스 특화 공격"을 방어한다.

---

## 배경

AWS 관리형 룰셋은 **공격 패턴**(SQL 구문, 악성 스크립트, 알려진 악성 IP)을 기준으로 탐지한다.
이커머스를 실제로 위협하는 공격들은 HTTP 형식이 완전히 정상이어서 관리형 룰셋으로는 탐지 불가능하다.
이커머스의 비즈니스 구조(로그인, 결제, 상품 조회)를 이해한 커스텀 룰이 별도로 필요하다.

---

## 구성 요소

| 룰 | WAF 위치 | Priority | 상태 |
|----|----------|----------|------|
| ecommerce-login-ratelimit | CloudFront WAF | 0 | ✅ 배포 완료 |
| ecommerce-orders-ratelimit | CloudFront WAF | 1 | ✅ 배포 완료 |
| ecommerce-products-ratelimit | CloudFront WAF | 2 | ✅ 배포 완료 |

---

## 공격 시나리오

**① 크리덴셜 스터핑 (Credential Stuffing)**

다크웹에서 유출된 ID/PW 데이터베이스를 자동화 도구로 `/api/auth/login`에 대량 대입한다.
탐지 불가 이유: SQL 구문도 없고, 악성 패턴도 없는 완전히 정상적인 로그인 요청.
피해: 계정 탈취 → 포인트/결제수단 도용, 개인정보 유출.

**② 카드 BIN 어택 (Card BIN Attack)**

훔친 카드번호의 유효성을 `/api/orders` 결제 엔드포인트에서 대량으로 검증한다.
탐지 불가 이유: 형식이 정상적인 주문 API 요청.
피해: 카드 유효성 확인 후 불법 결제, 결제사 제재로 매출 손실.

**③ 가격 스크래핑 (Price Scraping)**

경쟁사 봇이 `/api/products` 전 상품을 주기적으로 수집한다.
탐지 불가 이유: 정상적인 상품 조회 요청.
피해: 실시간 가격 추적으로 경쟁 우위 상실, 불필요한 서버 부하.

---

## 목적

관리형 룰셋이 잡지 못하는 이커머스 특화 공격을 **엔드포인트별 요청 빈도 제한**으로 차단한다.

---

## 왜 이렇게 구현했는가

**세 룰 모두 CloudFront WAF에 배치한 이유**

Regional WAF는 ALB 앞에 위치해 CloudFront Edge IP만 본다. `aggregate_key_type = "IP"`로 설정된 rate-based rule은 실제 공격자 IP가 아닌 CloudFront Edge IP 기준으로 집계되어, 개별 공격자 차단이 불가능하다.

실제 클라이언트 IP가 보이는 CloudFront WAF에 모든 이커머스 특화 rate limit을 배치해야 IP 기반 차단이 의도대로 동작한다.

**엔드포인트별 임계값을 다르게 설정한 이유**

각 엔드포인트의 정상 사용 패턴이 다르다. 획일적 임계값은 정상 사용자 차단 또는 공격 탐지 실패 중 하나를 야기한다.

| 엔드포인트 | 임계값 | 설정 근거 |
|-----------|--------|---------|
| `/api/auth/login` | 100 req/5min | 정상 사용자는 5분에 100번 로그인하지 않는다 |
| `/api/orders` | 100 req/5min | 결제는 소량 반복이 공격 패턴, 정상 사용자는 저빈도 |
| `/api/products` | 500 req/5min | 상품 조회는 정상 트래픽 자체가 많아 낮은 임계값이면 정상 사용자 차단 위험 |

---

## 한계

- IP 기반 차단이므로 프록시/봇넷으로 IP를 교체하며 공격하면 우회 가능
- AWS WAF rate-based rule 최솟값이 100 req/5min → 그 이하 저속 스텔스 공격은 탐지 불가
- WAF 단독으로는 완전한 방어 불가. 애플리케이션 레이어 Rate Limit + Account Lockout과 계층화 필요
