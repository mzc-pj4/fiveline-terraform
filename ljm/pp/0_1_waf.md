# WAF 기본 인프라 보안 (공통 발표)

> 이커머스가 아니어도 모든 웹 서비스에 동일하게 필요한 WAF 설정.
> "당연히 해야 하는 것을 빠짐없이 구축했다"는 메시지로 정리.

---

## 아키텍처: WAF 이중 계층 구조

CloudFront WAF (us-east-1) + Regional WAF (ap-northeast-2) 두 개를 운영한다.

**왜 두 개인가?**

AWS 제약으로 CloudFront에 연결하는 WAF는 반드시 `CLOUDFRONT` scope이고 us-east-1에만 생성할 수 있다. Regional WAF(ALB용)는 ap-northeast-2에 별도로 생성해야 한다.

| WAF | 위치 | 역할 |
|-----|------|------|
| CloudFront WAF | 엣지 (us-east-1) | 전 세계 사용자 요청 최초 수신 지점에서 차단 |
| Regional WAF | ALB 앞 (ap-northeast-2) | API 서버 직전 최후 방어선 |

---

## Regional WAF — 구성 요소

ALB로 들어오는 모든 API 트래픽을 검사한다.

| 룰 | WCU | 목적 |
|-----|-----|------|
| block-direct-alb-access | 2 | CloudFront를 우회한 ALB 직접 접근 차단 |
| AWSManagedRulesAmazonIpReputationList | 25 | 알려진 봇넷/C&C 서버 IP 차단 |
| AWSManagedRulesCommonRuleSet | 700 | OWASP Top 10 일반 공격 차단 (XSS, 경로 탐색 등) |
| AWSManagedRulesSQLiRuleSet | 200 | SQL 인젝션 전용 강화 탐지 |
| AWSManagedRulesKnownBadInputsRuleSet | 200 | Log4Shell, SSRF 등 알려진 CVE 악용 패턴 차단 |
| AWSManagedRulesAnonymousIpList | 50 | VPN/Tor/프록시 익명 접근 차단 |
| **합계** | **1,277** | **(한도 1,500 WCU, 여유 223)** |

### block-direct-alb-access 상세

CloudFront가 요청 전달 시 `x-origin-verify` 시크릿 헤더를 함께 포함한다.
Regional WAF가 이 헤더 유무를 검사해 헤더 없는 요청(ALB 직접 접근)을 즉시 차단한다.

효과: CloudFront WAF의 모든 보안 룰을 우회해서 ALB를 직접 공격하는 경로를 원천 차단.

---

## CloudFront WAF — 구성 요소

CloudFront 엣지에 위치. 모든 외부 요청의 최초 수신 지점.

| 룰 | WCU | 목적 |
|-----|-----|------|
| AWSManagedRulesAmazonIpReputationList | 25 | 알려진 악성 IP를 엣지에서 선제 차단 |
| AWSManagedRulesCommonRuleSet | 700 | OWASP Top 10 일반 공격 |
| AWSManagedRulesSQLiRuleSet | 200 | SQL 인젝션 강화 탐지 |
| AWSManagedRulesKnownBadInputsRuleSet | 200 | Log4Shell, SSRF 등 알려진 CVE 악용 패턴 |
| AWSManagedRulesAnonymousIpList | 50 | VPN/Tor/프록시 차단 |
| AWSManagedRulesLinuxRuleSet | 200 | Linux LFI/RCE 패턴 차단 |
| **합계 (고도화 룰 제외)** | **1,375** | **(한도 1,500 WCU, 여유 125)** |

---

## 두 WAF 룰 구성 비교

| 룰 | CloudFront WAF | Regional WAF | 비대칭 이유 |
|----|:--------------:|:------------:|------------|
| AmazonIpReputationList | ✅ | ✅ | 양쪽 방어 |
| CommonRuleSet | ✅ | ✅ | 양쪽 방어 |
| SQLiRuleSet | ✅ | ✅ | 양쪽 방어 |
| KnownBadInputsRuleSet | ✅ | ✅ | 양쪽 방어 |
| AnonymousIpList | ✅ | ✅ | 양쪽 방어 |
| LinuxRuleSet | ✅ | ❌ | 엣지에서 차단으로 충분, Python 컨테이너 백엔드는 OS 셸 미노출 |
| block-direct-alb-access | ❌ | ✅ | ALB 직접 접근 차단 — Regional WAF만 의미 있음 |

---

## 이커머스 서비스에 왜 필요한가

| 룰 | 이커머스 위협 연결 |
|----|-----------------|
| CommonRuleSet + SQLiRuleSet | 회원 DB, 주문 DB를 겨냥한 SQL 인젝션 한 번으로 전 회원 정보 유출 가능 |
| AmazonIpReputationList | 이커머스는 봇 트래픽 비중이 높음. 악성 IP 선제 차단으로 서버 부하와 공격 가능성 동시 완화 |
| AnonymousIpList | 카드 사기, 계정 탈취 공격은 VPN/프록시 뒤에서 자주 발생 |
| KnownBadInputsRuleSet | Log4Shell 같은 광범위 CVE는 서비스 유형 무관하게 전체 인터넷을 스캐닝함 |
| block-direct-alb-access | CloudFront WAF 전체를 우회해서 ALB를 직접 공격하면 모든 WAF 보호가 무력화됨 |
| LinuxRuleSet | EKS 노드(Linux 기반) 대상 명령어 인젝션 시도 — 엣지에서 차단 |
