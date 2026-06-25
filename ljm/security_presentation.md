# Fiveline 보안 고도화 — 개인 발표 구성안

> 담당: 이재민 | 전략: 이커머스 특화 보안 고도화 스토리텔링

---

## 발표 흐름

| 파트 | 내용 |
|------|------|
| 오프닝 | 이커머스 보안 고도화 배경 소개 |
| 고도화 1 | **WAF Custom Rate Limit — 크리덴셜 스터핑 차단** ← 오늘 집중 |
| 고도화 2~5 | 로그 위조 차단 / 파이프라인 무력화 탐지 / Ghost Query / UEBA (추후 발표) |

---

## 발표 멘트 전문

---

### 1. 고도화 아이디어 소개

"제가 고도화한 첫 번째 보안 요소는 **이커머스 특화 WAF Custom Rate Limit**입니다.

저희 서비스에는 기본적으로 AWS 관리형 WAF 룰셋이 적용되어 있습니다. SQL Injection이나 XSS 같은, 악성 코드가 포함된 요청들을 자동으로 차단해주는 룰들입니다.

그런데 이 관리형 룰셋이 탐지하지 못하는 공격이 있습니다. 바로 **형식 자체는 완전히 정상인 요청**으로 이루어지는 공격입니다. 그 대표적인 예가 크리덴셜 스터핑입니다."

---

### 2. 크리덴셜 스터핑 설명

"크리덴셜 스터핑이란, 다크웹이나 해킹 포럼 등에서 유출된 이메일과 비밀번호 조합 데이터를 가져다가, 저희 서비스 로그인 창에 하나씩 전부 넣어보는 공격입니다.

쉽게 말하면, 어딘가에서 이미 털린 아이디와 비밀번호 목록을 자동화 스크립트로 수만 번 로그인 시도해보는 겁니다. 사람들이 여러 서비스에 같은 비밀번호를 쓰는 경향이 있기 때문에, 이 방법으로 실제 계정을 탈취할 수 있습니다.

2024년 한 해 동안 크리덴셜 스터핑으로 인한 전 세계 피해액은 약 60억 달러로 추산됩니다. 이커머스 서비스는 포인트, 저장된 결제 수단이 있기 때문에 특히 매력적인 타깃입니다.

문제는, 이 공격이 WAF 입장에서는 완전히 정상적인 로그인 요청처럼 보인다는 겁니다. 형식도 맞고, 경로도 맞고, 뭐 하나 이상한 게 없습니다. 그래서 관리형 룰셋으로는 탐지할 수가 없습니다."

---

### 3. Before 설명 — 기존 구조와 취약점

"Before 상태에서 공격자가 어떻게 움직이는지 흐름으로 설명드리겠습니다.

공격자가 유출된 이메일, 비밀번호 목록 10만 건을 가지고 스크립트를 실행합니다. 요청은 CloudFront를 통해 들어오고, ALB를 거쳐 로그인 API에 도달합니다. 이 사이에 Regional WAF가 있긴 합니다.

그런데 Regional WAF로는 이걸 막을 수가 없었습니다. 이유가 있습니다.

CloudFront는 중간에서 프록시 역할을 합니다. 사용자가 직접 ALB에 접근하지 못하도록, CloudFront가 중간에서 요청을 받아 전달하는 구조입니다. 이 덕분에 백엔드 서버가 직접 노출되지 않습니다.

그런데 여기서 아이러니가 생깁니다. Regional WAF는 ALB 앞에 있기 때문에, ALB에 오는 요청의 출처 IP를 봅니다. 그 IP가 뭐냐면, 공격자의 실제 IP가 아니라 **CloudFront Edge 노드의 IP**입니다. CloudFront가 프록시로 요청을 전달할 때 자신의 IP로 바꿔서 보내기 때문입니다.

CloudFront Edge는 전 세계 수많은 사용자가 공유하는 노드입니다. Regional WAF 입장에서는 공격자 요청이 CloudFront IP에서 오는 수많은 정상 요청 중 하나로 보일 뿐입니다. 공격자가 누구인지 알 수 없으니, 차단도 할 수 없습니다.

결과적으로 공격 스크립트는 막힘 없이 실행되고, 실제 사용자 계정이 탈취됩니다. 이 화면이 Before 데모 결과입니다."

*(데모 화면: \[SUCCESS\] a123@gmail.com / JWT 토큰 발급 화면)*

---

### 4. After 설명 — CloudFront WAF 추가

"이 취약점을 보완하기 위해 **CloudFront WAF에 이커머스 로그인 Rate Limit 룰을 추가**했습니다.

핵심은 위치입니다. 왜 Regional WAF가 아니라 CloudFront WAF인지가 중요합니다.

CloudFront WAF는 CloudFront 자체에 붙어있습니다. CloudFront가 클라이언트와 직접 연결을 맺는 그 지점, 즉 요청이 들어오는 가장 첫 번째 관문에서 동작합니다. 그렇기 때문에 공격자의 실제 IP를 정확하게 봅니다. 중간에 프록시를 거치기 전이니까요.

여기에 다음 룰을 추가했습니다.

ecommerce-login-ratelimit. 동일 IP에서 /api/auth/login 경로로 5분 안에 100회를 초과하면 차단합니다.

After 흐름은 이렇습니다. 공격자 스크립트가 실행되면, 1번부터 100번 요청까지는 CloudFront WAF를 통과합니다. 그러나 101번째 요청부터는 CloudFront WAF가 동일 IP에서 임계치를 초과했음을 감지하고 429 Too Many Requests로 차단합니다. 그 이후 요청은 전부 차단됩니다.

공격자 입장에서는 더 이상 로그인 시도를 이어갈 수 없게 됩니다."

*(데모 화면: \[BLOCKED WAF\] 화면)*

---

### 5. Regional WAF 한계 — 왜 근본 해결이 아닌가

"그러면 Regional WAF에서 막을 수 있는 방법은 아예 없었냐, 궁금하실 수 있습니다.

실제로 X-Forwarded-For라는 HTTP 헤더가 있습니다. CloudFront가 요청을 전달할 때 원래 클라이언트 IP를 이 헤더에 담아서 넘겨줍니다. 그래서 정보가 아예 없는 건 아닙니다.

Regional WAF의 Rate Limit 설정에서 aggregate_key_type을 FORWARDED_IP로 바꾸면, 이 헤더의 IP를 기준으로 차단할 수 있습니다.

하지만 이건 근본적인 해결이 아닙니다. 왜냐하면 HTTP 헤더는 클라이언트가 직접 조작할 수 있기 때문입니다. 공격자가 매 요청마다 X-Forwarded-For 헤더에 다른 가짜 IP를 넣으면, WAF는 매번 새로운 IP로 인식해서 Rate Limit을 우회할 수 있습니다.

CloudFront WAF는 이 문제가 없습니다. 클라이언트와 직접 TCP 연결을 맺는 주체가 CloudFront 자신이기 때문에, 헤더가 아닌 실제 연결 소스 IP를 봅니다. 공격자가 헤더를 아무리 조작해도 CloudFront는 속지 않습니다.

이것이 CloudFront WAF에 룰을 배치한 이유입니다. 단순히 룰을 추가한 게 아니라, 올바른 레이어에 배치했다는 점이 핵심입니다."

---

### 6. 현재 방식의 남은 한계

"다만 솔직하게 말씀드리면, 지금 구현한 방식에도 한계가 있습니다.

현재 룰은 동일 IP 기준으로 차단합니다. 공격자가 VPN이나 프록시를 이용해서 요청마다 IP를 바꾸거나, 봇넷처럼 수천 개의 서로 다른 IP에서 분산 공격을 하면, 각 IP당 100회 미만으로 유지하면서 WAF를 우회할 수 있습니다.

즉, 단일 IP 기반 대규모 자동화 공격은 막을 수 있지만, IP를 분산하는 정교한 공격자는 완전히 막기 어렵습니다."

---

---

## GuardDuty 자동 대응 고도화 — 발표 멘트 (슬라이드 5)

### 2-1. Reactive SOAR: GuardDuty → Lambda → WAF

**도입**

"두 번째 고도화는 GuardDuty 탐지와 실제 차단 사이의 공백을 없애는 자동화입니다.

GuardDuty는 VPC Flow Logs와 CloudTrail을 분석해서 악성 IP, 비정상 API 호출, 계정 탈취 시도 같은 위협을 탐지합니다. 탐지 결과를 Finding으로 생성합니다.

문제는 탐지 후 차단을 사람이 직접 해야 했다는 겁니다. 보안 담당자가 콘솔에 접속해서 WAF 규칙을 수동으로 추가하는 동안, 공격은 계속됩니다. 빠르게 대응해도 수 분, 늦으면 수 시간 공백이 생깁니다."

**구현 설명**

"이 공백을 없애기 위해 EventBridge와 Lambda를 사이에 끼웠습니다.

GuardDuty가 Finding을 생성하면 EventBridge가 이벤트를 감지합니다. 심각도 기준으로 두 개의 룰로 분리했습니다.

MEDIUM 이상이면 SNS를 통해 이메일 알림을 즉시 발송합니다. HIGH 이상이면 Lambda를 트리거합니다.

Lambda는 Finding에서 악성 IP를 추출하고, WAF API를 호출해서 guardduty-blocked-ips IP Set에 해당 IP를 자동으로 추가합니다. CloudFront WAF는 이 IP Set을 참조하기 때문에, 등록 즉시 이후 요청부터 403으로 차단됩니다.

HIGH finding이 발생하면 두 룰이 동시에 발화하기 때문에 이메일 알림과 자동 차단이 함께 수행됩니다.

별도 SOAR 솔루션 없이 AWS 네이티브 서비스 조합으로 Auto-remediation을 구현했습니다. 수 분에서 수 초로 대응 시간을 단축한 것이 핵심입니다."

**2-1 한계 언급**

"다만 이 구조에 한계가 있습니다. GuardDuty는 반복적인 악성 패턴을 탐지합니다. 탐지하기 전 첫 번째 요청은 CloudFront를 통과해서 EKS까지 도달할 수 있습니다. 탐지 후 대응하는 Reactive 구조이기 때문입니다."

---

### 2-2. Proactive 추가: IP Reputation List + Rate-based Rule

**전환 멘트**

"이 한계를 보완하기 위해 두 가지 Proactive 레이어를 추가했습니다."

**IP Reputation List**

"첫 번째는 AWS Managed Rules의 IP Reputation List입니다. AWS가 직접 관리하는 악성 IP 데이터베이스입니다. 봇, C&C 서버, Tor 출구 노드처럼 이미 알려진 악성 IP들을 담고 있습니다. 이 룰을 WAF에 추가하면 Reputation List에 있는 IP는 GuardDuty 탐지 이전, 첫 요청부터 차단됩니다. 별도 운영 비용 없이 Managed Rule Group 하나만 추가하면 됩니다."

**Rate-based Rule**

"두 번째는 전체 트래픽 Rate-based Rule입니다. 동일 IP에서 5분 내 2000회를 초과하는 요청이 들어오면 자동 차단합니다. 슬라이드 4에서 설명한 로그인 엔드포인트 Rate Limit은 특정 경로를 노리는 공격을 막습니다. 이 룰은 모든 엔드포인트에 걸쳐 고속 반복 트래픽 자체를 GuardDuty 탐지 이전에 선제 차단합니다."

**3중 방어 정리**

"세 레이어를 정리하면 이렇습니다.

첫째, IP Reputation List — 이미 알려진 악성 IP는 첫 요청부터 차단합니다. 둘째, Rate-based Rule — 고속 반복 공격은 임계치 초과 즉시 차단합니다. 셋째, GuardDuty → Lambda — 앞의 두 레이어를 통과한 신규 악성 IP를 탐지하고 수 초 내 차단합니다.

이 세 레이어가 조합되면 알려진 악성 IP, 고속 공격, 신규 미탐지 IP까지 커버하는 Defense-in-Depth가 완성됩니다. AWS Well-Architected Framework의 다계층 방어 원칙을 실제로 구현한 구조입니다."

---

### 7. 다른 계층에서의 추가 보완점

"그렇기 때문에 실제 운영 환경에서는 WAF 한 계층만으로는 충분하지 않고, 다층 방어 구조가 필요합니다.

세 가지 계층을 설명드리겠습니다.

첫 번째는 애플리케이션 레이어 Rate Limit입니다. WAF의 100회 기준보다 훨씬 세밀하게, IP당 1분에 10회 같은 제한을 앱 레벨에서 추가로 적용하는 방식입니다. 이렇게 하면 IP를 바꾸지 않는 공격자는 WAF에 걸리기 훨씬 전에 차단됩니다.

두 번째는 계정 잠금, Account Lockout입니다. 동일 계정에서 5회 연속 로그인 실패 시 30분간 계정을 잠그는 방식입니다. IP를 계속 바꾸는 공격자라도, 특정 계정을 집중적으로 노리면 잡힙니다.

세 번째는 MFA, 다중 인증입니다. 설령 공격자가 올바른 비밀번호를 알아내더라도, 추가 인증 수단이 없으면 로그인 자체가 불가능합니다. 크리덴셜 스터핑에 대한 가장 강력한 방어 수단입니다. 다만 이는 서비스 UX와의 트레이드오프가 있어, 별도 기획이 필요한 부분입니다.

저는 SA로서 인프라 레이어인 CloudFront WAF를 구현했고, 나머지 두 계층은 애플리케이션 레벨에서 추가로 보완할 수 있는 방향을 제안드립니다."

---

## Defense-in-Depth (다중 방어 레이어 전략) — 개념 및 설계 참고

> 발표 Q&A 또는 심화 질문 대비용 레퍼런스

---

### Defense-in-Depth란 무엇인가

**"한 레이어가 뚫려도 다음 레이어가 막는다"** 는 군사 전략에서 온 보안 개념이다.

단일 방어선(예: WAF 하나만)이 뚫리면 시스템 전체가 노출된다. 반면 여러 레이어를 순차적으로 통과해야 하는 구조라면, 공격자가 각 레이어를 우회하는 데 드는 비용과 시간이 기하급수적으로 늘어난다. 공격을 "불가능하게" 만드는 것이 아니라, **공격 비용을 기대 수익보다 높게 만드는 것**이 목표다.

---

### 레이어 구조

```
인터넷
  │
  ▼ Layer 1: 경계 방어 (Perimeter)
  [CloudFront + WAF]
  ├─ IP Reputation List        ← 알려진 악성 IP 첫 요청부터 차단
  ├─ Rate-based Rule           ← 고속 반복 공격 선제 차단
  ├─ ecommerce-login-ratelimit ← 이커머스 특화 로그인 Rate Limit
  └─ Managed Rules (SQLi/XSS) ← 알려진 공격 패턴 자동 차단
  │
  ▼ Layer 2: 네트워크 (Network)
  [VPC + Security Group + NACL]
  └─ EKS private endpoint, SG 참조 ingress, ALB 직접 접근 차단
  │
  ▼ Layer 3: 신원 (Identity)
  [IAM + IRSA + K8s RBAC]
  └─ Pod별 최소 권한 AWS 자격증명, K8s access entry 제한
  │
  ▼ Layer 4: 워크로드 (Workload)
  [EKS + VPC CNI NetworkPolicy + IMDSv2]
  └─ Pod 간 동서 트래픽 격리, SSRF 공격 경로 차단
  │
  ▼ Layer 5: 데이터 (Data)
  [KMS CMK + RDS 암호화 + pgAudit]
  └─ 저장 데이터 암호화, SQL 접근 감사 로그
  │
  ▼ Layer 6: 탐지 및 대응 (Detection & Response)
  [GuardDuty + CloudTrail + Lambda SOAR]
  └─ 실시간 위협 탐지 → EventBridge → Lambda → WAF 자동 차단
```

공격자는 Layer 1을 우회하더라도 Layer 2~6을 모두 통과해야 한다. 각 레이어가 독립적으로 동작하므로 한 레이어의 실패가 전체 실패로 이어지지 않는다.

---

### 현업에서 어떻게 설계하는가

#### 대형 이커머스 (쿠팡, 네이버 수준)

| 레이어 | 사용 기술 | 비고 |
|--------|---------|------|
| 경계 | CloudFront + WAF + AWS Shield Advanced | DDoS 대응 포함 |
| 봇 탐지 | AWS WAF Bot Control | ML 기반 행동 분석, 추가 비용 |
| 인증 | OAuth 2.0 + MFA + 계정 잠금 | 사용자 신원 보호 |
| 위협 인텔리전스 | Recorded Future, CrowdStrike 등 상용 Threat Feed | 최신 악성 IP/도메인 실시간 구독 |
| SIEM | Splunk / AWS Security Hub | 전사 로그 통합 분석 |
| SOAR | Splunk SOAR / Palo Alto XSOAR | 자동 대응 플레이북 관리 |
| 제로데이 대응 | WAF 가상 패치 | 취약점 공개 즉시 룰 적용 |

핵심은 각 레이어가 독립적으로 동작하면서, 탐지 정보를 공유해 다음 레이어를 강화하는 **피드백 루프** 구조다. 예: GuardDuty가 탐지한 악성 IP를 WAF에 자동 등록(우리가 구현한 것), SIEM이 분석한 공격 패턴을 WAF 룰에 반영 등.

---

### 우리 아키텍처에서 구현된 것

| 레이어 | 구현 여부 | 구현 내용 |
|--------|---------|---------|
| Layer 1 경계 | ✅ 완료 | CloudFront WAF — IP Reputation + Rate-based + 이커머스 Rate Limit + Managed Rules |
| Layer 2 네트워크 | ✅ 완료 | VPC + SG 참조 ingress + EKS private endpoint + ALB 직접 접근 차단 |
| Layer 3 신원 | ✅ 완료 | IRSA 8종 최소 권한 + K8s RBAC access entry |
| Layer 4 워크로드 | ✅ 완료 | VPC CNI NetworkPolicy + IMDSv2 hop_limit=1 |
| Layer 5 데이터 | ✅ 완료 | KMS CMK 3종 + RDS 암호화 + pgAudit 접근 감사 |
| Layer 6 탐지/대응 | ✅ 완료 | GuardDuty + CloudTrail + Lambda SOAR (2-1) + WAF 3중 방어 (2-2) |

**6개 레이어 전부 구현 완료.** 스타트업~중견기업 수준의 Defense-in-Depth를 AWS 네이티브 서비스만으로 구성한 구조다.

---

### 명확한 한계

#### ① 제로데이 공격 (Zero-day)
아직 알려지지 않은 취약점을 이용한 공격은 어떤 레이어도 사전에 막을 수 없다. 현업 대형 기업도 동일하다. 탐지 후 WAF 가상 패치를 신속하게 적용하는 것이 현실적인 최선이다.

#### ② 완전히 새로운 악성 IP의 첫 요청
IP Reputation List에 없고, Rate Limit도 초과하지 않은 새로운 악성 IP의 첫 번째 요청은 2-2 구조에서도 통과한다. 이는 네트워크 보안의 본질적 한계다. GuardDuty가 반복 패턴을 탐지한 후 Lambda가 IP Set에 등록하면 이후 요청부터 차단된다.

#### ③ 내부자 위협 (Insider Threat)
정상 권한을 가진 내부 사용자의 악의적 행동은 WAF나 GuardDuty가 탐지하기 어렵다. pgAudit이 SQL 접근을 기록하고 Ghost Query 탐지(항목 3)가 부분적으로 커버하지만, 완전한 내부자 위협 탐지는 별도 UEBA(User and Entity Behavior Analytics) 솔루션이 필요하다.

#### ④ ML 기반 정교한 봇
AWS WAF Bot Control은 추가 비용($10/백만 요청)이 발생하는 유료 기능이라 현재 미적용이다. 사람처럼 느리게 행동하거나 브라우저 핑거프린트를 모방하는 정교한 봇은 Rate Limit으로 탐지되지 않는다.

#### ⑤ 대규모 DDoS
AWS Shield Standard는 기본 포함이지만 L3/L4 대규모 DDoS에는 Shield Advanced($3,000/월)가 필요하다. 현재 미적용. 소규모 DDoS는 Rate-based Rule로 부분 완화 가능하다.

---

### 정리 — SA 어필 포인트

> "저희 아키텍처는 전용 SIEM/SOAR 솔루션 구매 없이, AWS 네이티브 서비스 조합만으로 6개 레이어의 Defense-in-Depth를 완성했습니다.
> 완전한 제로데이 방어나 정교한 봇 탐지는 추가 투자가 필요하지만, 스타트업 수준의 예산으로 구현 가능한 최대치를 달성했습니다.
> 그리고 이 구조는 AWS Well-Architected Framework 보안 원칙의 '다계층 방어'와 정확히 일치합니다."
