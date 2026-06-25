# 보안 파트 PPT 가이드 — 개인 발표 (이재민)

> 발표 시간: 8~10분 (슬라이드 7장)
> 핵심 메시지: "이커머스를 겨냥한 공격은 다르다. 그 공격에 맞춘 보안을 설계했다."

---

## 발표 전략 요약

### 공통 발표 (기본 인프라 보안 — 팀원이 담당)
HTTPS, S3 OAC, RDS 암호화, ACM, GuardDuty, CloudTrail, KMS, WAF 관리형 룰셋 등
→ "당연히 해야 하는 것"이기 때문에 개인 발표에서는 언급만 하고 넘긴다

### 개인 발표 (이커머스 특화 고도화 — 내가 발표)
1. EKS Zero Trust 접근 경로 설계
2. 이커머스 특화 WAF Custom Rate Limit
3. Zero Trust 완성: IRSA(N-S) + VPC CNI NetworkPolicy(E-W)
4. 웹스키밍 방어: CSP unsafe-inline 결함 발견 + 수정
5. PII 데이터 감사: pgaudit

---

## 슬라이드 1 — 표지 (30초)

**제목**: 이커머스를 겨냥한 공격, 다르게 방어한다

**발표 시작 멘트**:
> "일반 인프라 보안은 'SQL 인젝션을 막아라, 암호화를 켜라' 입니다.
> 그런데 이커머스를 실제로 망하게 하는 공격은 따로 있습니다.
> 저는 fiveline이 받는 특화된 위협을 분석하고, 그 위협에 맞게 설계했습니다."

**레이아웃**:
- 중앙: "이커머스 보안 설계 — 이재민"
- 하단: AWS 아이콘 나열 (WAF, EKS, IAM, RDS, CloudFront)
- 배경: 다크 네이비

---

## 슬라이드 2 — 이커머스 특화 위협 모델 (1.5분)

**제목**: SQL 인젝션은 누구나 막는다. 이커머스는 이걸 막아야 한다.

**레이아웃**: 좌측 (일반 보안) / 우측 (이커머스 특화)

```
일반 인프라 보안 ❌           이커머스 특화 공격 ✅ (우리가 집중할 것)
────────────────────────────────────────────────────────────────────
SQL Injection                  크리덴셜 스터핑
XSS                               유출된 ID/PW를 로그인 엔드포인트에 초당 수천 건 전송
악성 IP 차단                      → 계정 탈취 → 포인트/결제수단 도용 (정상 요청처럼 보임)

이것들은 관리형              재고 선점 봇
룰셋이 잘 막는다                  한정판 상품을 봇이 자동 선점 → 실고객 구매 불가
                                  (나이키 SNKRS, 콘솔 대란 동일 방식)

                              카드 BIN 어택
                                  훔친 카드번호를 결제 엔드포인트에 대량 검증
                                  → 결제사 제재, 매출 손실

                              웹스키밍 (Magecart)
                                  결제 페이지에 악성 스크립트 삽입
                                  → 카드번호 실시간 탈취
                                  (British Airways 50만 건, $230M 과징금)
```

**핵심 멘트**:
> "이 4가지 공격의 공통점은 **정상 HTTP 요청처럼 보인다**는 것입니다.
> WAF 관리형 룰셋이 못 잡는 이유입니다.
> 다음 슬라이드부터 각각 어떻게 방어했는지 설명하겠습니다."

---

## 슬라이드 3 — EKS Zero Trust 접근 경로 설계 (1.5분)

**제목**: K8s API 서버를 인터넷에서 완전히 차단하다

**레이아웃**: Before/After 아키텍처 다이어그램

```
BEFORE                              AFTER
──────────────────────────────────  ────────────────────────────────────
인터넷                              인터넷
  ↓                                   ↓
EKS API 서버 (0.0.0.0/0 오픈)       [SSM Session Manager]
  ↓                                   ↓ (포트 22 없음, IAM 기반)
kubectl 명령 가능 (누구든)          Workstation EC2 (private subnet)
                                      ↓
                                    kubectl → EKS API 서버
                                               (443, private endpoint only)
                                               ↑
                                         SG 참조 ingress (CIDR 아닌 SG ID)
```

**5-layer 설계** (하나라도 빠지면 동작 안 함):

| 레이어 | 변경 내용 | 없으면 |
|--------|---------|--------|
| 네트워크 | Workstation → private subnet + NAT 라우팅 | SSM Agent AWS 통신 불가 |
| SG | EKS 클러스터 SG에 Workstation SG → 443 ingress | kubectl i/o timeout |
| IAM | eks:DescribeCluster + DescribeNodegroup ARN 제한 | AccessDeniedException |
| RBAC | access_entry + ClusterAdminPolicy | credentials error |

**발표 멘트**:
> "이것은 설정 변경이 아닙니다.
> 네트워크 / 보안 그룹 / IAM / RBAC 4개 레이어가 모두 맞물려야 동작합니다.
> 하나라도 빠지면 kubectl 접근이 안 됩니다. 직접 디버깅하며 완성했습니다."

**비주얼**: 좌우 분할 + 화살표 + 레이어별 체크리스트
**스크린샷**: SSM Session Manager로 접속한 화면 (sh-5.2$ 프롬프트) 1장

---

## 슬라이드 4 — 이커머스 특화 WAF Custom Rate Limit (2분)

**제목**: 관리형 룰셋이 못 막는 공격을 막는다

**상단 — 문제 제기**:

```
현재 WAF (관리형 룰셋만):
  SQLi 차단 ✅   XSS 차단 ✅   악성 IP 차단 ✅
  크리덴셜 스터핑 ❌   재고 봇 ❌   카드 BIN 어택 ❌

이유: 모두 정상 POST 요청 형태 → 룰셋이 악성으로 분류하지 않음
```

**중단 — 구현: 엔드포인트별 Rate Limit**:

```
공격               엔드포인트              Rate Limit
──────────────────────────────────────────────────────
크리덴셜 스터핑   /api/auth/login         IP당 5분 100회 초과 → 자동 차단
카드 BIN 어택     /api/orders/from-cart   IP당 5분 20회 초과 → 자동 차단
가격 스크래핑     /api/products           IP당 1분 200회 초과 → 자동 차단
```

**하단 — 구현 포인트**:

```hcl
# waf.tf — aws_wafv2_rule_group.ecommerce_ratelimit
# Regional WAF에 priority=0으로 연결 → 관리형 룰셋보다 먼저 평가
# CloudWatch Metric → 차단 횟수 실시간 모니터링
```

**발표 멘트**:

*[Before 화면 보여주며]*
> "2024년 한 해 동안 크리덴셜 스터핑으로 인한 피해액이 전 세계 60억 달러입니다.
> 저희 이커머스 서비스도 동일한 위협에 노출되어 있습니다.
> 다크웹에서 유출된 10만 개 DB를 이 스크립트처럼 자동으로 대입하면,
> WAF가 없을 때 실제 계정이 이렇게 탈취됩니다."

*[After 화면 보여주며]*
> "이를 막기 위해 AWS WAF + 애플리케이션 레이어 + 계정 잠금, 3중 방어 아키텍처를 설계했습니다.
> WAF 단독으로는 IP 변경 공격에 취약합니다.
> 그래서 Defense-in-Depth 구조로 각 레이어가 서로 보완하도록 설계했습니다.
> 이는 AWS Well-Architected Framework 보안 원칙과도 일치합니다."

*[전체 멘트]*
> "관리형 룰셋은 AWS가 관리하는 알려진 공격을 막습니다.
> 이커머스를 겨냥한 공격은 **우리 비즈니스 로직을 이해한 커스텀 룰**이 필요합니다.
> 로그인 엔드포인트에 Rate Limit을 걸면 크리덴셜 스터핑을 원천 차단할 수 있습니다."

**Before/After 데모 구성**:

| | Before | After |
|--|--------|-------|
| 화면 | `[SUCCESS] a123@gmail.com JWT: eyJ...` | `[BLOCKED 429] a123@gmail.com` |
| 상태 | WAF COUNT 모드 (차단 없음) | WAF + App Rate Limit + Account Lockout |
| 결과 | 3 accounts compromised | 0 accounts compromised |

**비주얼**: 상/중/하 3단 구성 + 공격 시나리오 화살표

---

## 슬라이드 5 — Zero Trust 완성: IRSA + NetworkPolicy (1.5분)

**제목**: AWS 권한은 격리했다. 이제 Pod 간 통신도 격리한다.

**상단 — 현재의 GAP**:

```
구현된 것:
  Pod → AWS (남북 축):  IRSA 8종으로 격리 ✅
    user-sa     → SES SendEmail (fiveline.store 도메인만)
    product-sa  → S3 product-images/ 만
    order-sa    → SNS fiveline-* 토픽만

빠진 것:
  Pod ↔ Pod (동서 축):  무방비 ❌
    order-service 침해 → user-service DB 직접 접근 가능
    Pod 하나 탈취 → 네임스페이스 전체 서비스 노출
```

**하단 — 해결: VPC CNI NetworkPolicy 활성화**:

```
Terraform: enableNetworkPolicy = "true" (eks.tf)
  → NetworkPolicy YAML을 적용할 수 있는 인프라 레이어 구축 완료

Policy 적용 시:
  default-deny (namespace 전체 차단)
  + allow-order-to-product (order → product:8000 만)
  + allow-egress-rds (모든 Pod → RDS:5432)
  = Pod가 침해되어도 인접 서비스로 이동 불가
```

**완성된 Zero Trust 그림**:

```
         인터넷
           ↓
       [WAF + 보안헤더]        ← 경계 방어
           ↓
       [EKS private endpoint]  ← 접근 경로 통제
           ↓
    IRSA: Pod → AWS 권한 격리  ← 남북 통제
    NetworkPolicy: Pod ↔ Pod   ← 동서 통제
           ↓
       [RDS/ElastiCache]       ← 데이터 계층
```

**발표 멘트**:
> "IRSA는 Pod가 AWS 서비스에 접근하는 권한을 남북으로 제한합니다.
> VPC CNI NetworkPolicy는 Pod 간 동서 통신을 격리합니다.
> 둘이 함께 있어야 진짜 Zero Trust입니다."

**비주얼**: 2단 (GAP → 해결) + Zero Trust 다이어그램

---

## 슬라이드 6 — 웹스키밍 방어 + PII 데이터 감사 (1.5분)

**제목**: 결제 카드 탈취를 막고, 내부자 조회도 기록한다

**좌측 — CSP 강화 (웹스키밍 방어)**:

```
Magecart 공격:
  XSS로 결제 페이지에 악성 스크립트 삽입
  → 카드번호 입력 시 공격자 서버로 전송
  → British Airways 2018: 50만 건, $230M 과징금

발견한 결함:
  script-src 'self' 'unsafe-inline'
                    ^^^^^^^^^^^^^^^
                    인라인 스크립트 허용 → CSP 무력화

수정 (cloudfront.tf):
  script-src 'self'
  (unsafe-inline 제거 → 브라우저가 인라인 스크립트 실행 자체를 차단)
```

**우측 — pgaudit (PII 데이터 감사)**:

```
RDS storage_encrypted=true 의 한계:
  디스크 도난 → ✅ 막음
  SQL로 정상 접근 → ❌ 평문 그대로

pgaudit 적용 후 (rds.tf):
  누가(user=admin) 어디서(client=10.10.2.15)
  어떤 쿼리로(SELECT * FROM users LIMIT 100000)
  언제 실행했는지 → CloudWatch에 기록

= 내부자가 회원 100만 건 조회 시 즉시 탐지
= 개인정보보호법 제29조 (접근 기록 6개월 보관) 준수
```

**발표 멘트**:
> "두 가지 모두 '아무도 못 보는 디테일'입니다.
> 보안 헤더를 달았다고 끝이 아닙니다. unsafe-inline 하나가 XSS 방어 전체를 무력화합니다.
> RDS 암호화를 켰다고 끝이 아닙니다. SQL로 접근하면 평문입니다. pgaudit이 그 접근을 기록합니다."

**비주얼**: 좌/우 2분할. Before/After 코드 블록 (검은 배경)

---

## 슬라이드 7 — 종합 아키텍처 + 마무리 (1분)

**제목**: 이커머스 보안 — 위협에서 설계까지

**상단 — 위협 → 방어 매핑**:

| 이커머스 특화 위협 | 방어 설계 | 상태 |
|----------------|---------|------|
| 크리덴셜 스터핑 / 재고 봇 / 카드 BIN | WAF Custom Rate Limit | ✅ |
| K8s API 인터넷 노출 | EKS private endpoint + SSM 접근 경로 | ✅ |
| Pod 침해 후 내부 이동 | IRSA(N-S) + VPC CNI NetworkPolicy(E-W) | ✅ |
| 결제 페이지 웹스키밍 | CSP unsafe-inline 제거 | ✅ |
| 내부자 PII 무단 조회 | pgaudit 감사 로그 | ✅ |

**하단 — 기본 베이스라인 (공통 발표 항목)**:
```
HTTPS · ACM · S3 OAC · RDS 암호화 · KMS CMK · IMDSv2
GuardDuty · CloudTrail · VPC Flow Logs · WAF 관리형 룰셋
CloudFront 보안 헤더 · CloudFront Standard Logging v2
→ 기본 인프라 보안 전 항목 완료 (공통 발표 참조)
```

**클로징 멘트**:
> "fiveline에서 보안은 체크리스트가 아닙니다.
> 이커머스가 실제로 당하는 공격을 먼저 정의하고,
> 그 공격에 맞는 설계 결정을 내렸습니다.
> 기본 베이스라인 위에 이커머스 특화 방어를 얹은 구조입니다."

---

## 디자인 가이드

| 항목 | 규칙 |
|------|------|
| 배경 | 다크 네이비 (#1A237E) 또는 흰색으로 통일 |
| Before (문제) | 빨간 테두리 + ❌ 아이콘 |
| After (해결) | 초록 테두리 + ✅ 아이콘 |
| 코드 블록 | 검은 배경 (#1E1E1E), Consolas 14pt |
| 강조 숫자/키워드 | 오렌지 (#FF9900) 또는 볼드 |
| 슬라이드당 글자 | 핵심만 — 설명은 입으로, 슬라이드에는 키워드만 |
| 스크린샷 | SSM 접속 화면 1장만 사용 (슬라이드 3) |

---

## 예상 Q&A

**Q: NetworkPolicy는 Terraform이 아닌데?**
> A: "EKS VPC CNI의 Network Policy 기능 활성화는 Terraform으로 했습니다.
> 이 설정 없이는 kubectl apply -f network-policy.yaml을 해도 아무 효과가 없습니다.
> 인프라 레이어 활성화가 제 역할, 실제 Policy YAML은 앱팀 K8s manifest에서 관리합니다."

**Q: Custom WAF Rule이 정상 사용자를 차단하지 않는가?**
> A: "Rate Limit은 IP당 5분 100회입니다. 정상 사용자가 5분에 100번 로그인을 시도하지 않습니다.
> 봇은 초당 수백 건 시도하므로 명확히 구분됩니다."

**Q: pgaudit을 켜면 로그가 너무 많지 않나?**
> A: "read,write,ddl 레벨만 수집하고 CloudWatch에서 테이블 필터링이 가능합니다.
> PIPA 요건인 '접근 기록 6개월 보관'을 충족하면서 CloudWatch 30일 보관으로 비용을 관리합니다."

**Q: IRSA는 이미 있는데 왜 NetworkPolicy를 또 해야 하나?**
> A: "IRSA는 Pod가 AWS API를 호출하는 권한을 제한합니다.
> NetworkPolicy는 Pod 간 직접 TCP 통신을 제한합니다.
> 공격자가 Pod를 탈취했을 때 AWS API가 아닌 인접 서비스를 직접 찌르는 경우를 막는 것이 NetworkPolicy입니다."

---

## 발표 타임라인

| 슬라이드 | 내용 | 시간 |
|---------|------|------|
| 1 | 표지 + 도입 | 30초 |
| 2 | 이커머스 위협 모델 | 1분 30초 |
| 3 | EKS 접근 경로 설계 | 1분 30초 |
| 4 | 이커머스 WAF Custom Rate Limit | 2분 |
| 5 | Zero Trust 완성 | 1분 30초 |
| 6 | CSP + pgaudit | 1분 30초 |
| 7 | 종합 + 클로징 | 1분 |
| | **합계** | **~9.5분** |
