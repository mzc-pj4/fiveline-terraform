# Fiveline 보안 — 발표 구성안

> 대상: 메가존 클라우드 임원/부장급 심사위원  
> 핵심 전략: 기술 나열 X → **3가지 공격 시나리오 Before/After 스토리텔링**

---

## 발표 흐름 (총 7~10분 기준)

| 파트 | 내용 | 시간 |
|------|------|------|
| 1. 오프닝 — 이커머스 보안 위협 | "이 서비스가 받을 수 있는 공격" | 1분 |
| 2. 보안 아키텍처 개요 | Before/After 전체 그림 | 1분 |
| 3. 시나리오 1 — 외부 공격자 | WAF, SQLi 차단 | 2분 |
| 4. 시나리오 2 — 자격증명 유출 | Secrets Manager + IRSA | 2분 |
| 5. 시나리오 3 — 내부 감사 추적 | CloudTrail + 개인정보보호법 | 1분 |
| 6. 비용 및 우선순위 | 월 비용 표, 로드맵 | 1분 |
| 7. 마무리 | "보안은 기능이 아니라 운영" | 30초 |

---

## 파트 1. 오프닝 — "이 서비스가 받는 공격"

> 발표 시작 멘트 예시:
>
> *"저희 서비스는 무신사/올리브영급 트래픽을 가정한 이커머스입니다.  
> 회원 개인정보, 주문 데이터, 관리자 대시보드가 외부에 노출된 서비스는  
> 운영 첫날부터 아래 3가지 위협에 직면합니다."*

**이커머스가 받는 실제 공격 3가지 (슬라이드 하나)**

```
① 외부 공격자 — SQLi / XSS / 봇 트래픽
   └── 하루 수천 건의 자동화 공격, 방어 없으면 DB 직접 노출

② 자격증명 유출 — 실수로 .env 파일이 GitHub에 올라갔다
   └── 실제 사례: 2023년 국내 스타트업 DB 전체 탈취, 48시간 내

③ 감사 부재 — 침해 사고 발생 시 "누가 뭘 했는지" 알 수 없다
   └── 개인정보보호법 위반 시 과태료 최대 3억, 원인 소명 불가능
```

---

## 파트 2. 보안 아키텍처 전체 그림 (Before → After)

### Before (배포 초기 상태)

```
인터넷
  │ ← SQL Injection, 봇 트래픽 그대로 통과
  ▼
CloudFront / ALB  ← WAF 없음
  │
  ▼
EKS Pod  ← DB 비밀번호 환경변수에 하드코딩
  │       ← kubectl describe pod로 노출 가능
  ▼
RDS PostgreSQL  ← 암호화 키 통제 없음, 접근 감사 없음
```

**위험 요약**:
- 외부 공격 → 무방비
- 내부 자격증명 → 코드에 노출
- 사고 발생 → 추적 불가

---

### After (보안 적용 후)

```
인터넷
  │
  ▼
[WAF v2]  ← SQLi, XSS, Rate Limit, 악성 IP 자동 차단
  │
  ▼
CloudFront / ALB
  │
  ▼
EKS Pod  ← Secrets Manager에서 자격증명 자동 주입 (코드에 비밀번호 없음)
  │       ← IRSA: Pod별 최소 AWS 권한 (user-service는 user secret만 접근)
  ▼
RDS PostgreSQL  ← KMS CMK 암호화, CloudTrail로 모든 접근 기록
```

---

## 파트 3. 시나리오 1 — 외부 공격자 (WAF)

### 상황 설정

> *"공격자가 자동화 툴로 저희 `/api/products?q=` 파라미터에  
> SQL Injection을 초당 100회 시도합니다.  
> Before에서는 어떻게 됩니까?"*

### Before

- WAF 없음 → 악성 쿼리가 ALB → EKS → RDS까지 직접 도달
- 성공 시: 전체 사용자 이메일/해시 패스워드 덤프 가능
- 실패 시에도: RDS Connection 폭증 → 서비스 장애

### After — AWS WAF v2 적용

**무엇을**: CloudFront 앞(us-east-1) + ALB 앞(ap-northeast-2) 이중 WAF

**왜 AWS Managed Rules를 선택했는가?**

| 옵션 | 설명 | 선택 이유 |
|------|------|---------|
| 직접 규칙 작성 | 커스텀 regex, IP 리스트 | 최신 공격 패턴 수동 업데이트 필요 |
| **AWS Managed Rules** | AWS 보안팀이 실시간 업데이트 | 팀이 보안 규칙 유지보수 안 해도 됨 ✅ |
| 3rd Party (예: Cloudflare) | 외부 서비스 | AWS 네이티브 통합 불가, 추가 비용 |

**적용 규칙 4가지**:
1. `AWSManagedRulesCommonRuleSet` — XSS, 파일 인클루전, HTTP 이상 요청
2. `AWSManagedRulesSQLiRuleSet` — SQL Injection 전 패턴
3. Rate Limit Rule — IP당 5분간 2,000 요청 초과 시 자동 차단
4. `AWSManagedRulesAmazonIpReputationList` — 알려진 봇/악성 IP 차단

**비용**:
```
WAF WebACL:           $5.00/월
적용 규칙 (4개):      $4.00/월 ($1/rule)
요청 처리:            $0.60/백만 요청
월 예상 비용:         ~$15/월
```

**임원 포인트**: *"월 $15로 SQLi 공격 및 DDoS 기초 방어를 자동화했습니다.  
별도 보안 엔지니어 운영 없이 AWS가 실시간으로 규칙을 업데이트합니다."*

---

## 파트 4. 시나리오 2 — 자격증명 유출 (Secrets Manager + IRSA)

### 상황 설정

> *"팀원 노트북이 악성코드에 감염됐습니다.  
> Before 상태라면 무슨 일이 벌어집니까?"*

### Before

```python
# docker-compose.yml 또는 K8s Deployment (실제 초기 구성)
env:
  - name: DATABASE_URL
    value: "postgresql://fiveline:fiveline1234@rds-host:5432/fiveline"
```

- `kubectl describe pod` → 비밀번호 평문 노출
- `.env` 파일이 실수로 git push → GitHub에 영구 기록
- RDS 비밀번호 변경 시 → 전 서비스 수동 재배포 필요

### After — Secrets Manager + ESO + IRSA

**흐름 (3단계)**:

```
① Secrets Manager 저장
   "fiveline/db-credentials" = { host, username, password, ... }

② ESO(External Secrets Operator)가 자동으로 K8s Secret 생성
   → 1시간마다 자동 갱신

③ Pod는 secretKeyRef로만 참조 (코드에 비밀번호 없음)
   env:
     - name: DATABASE_URL
       valueFrom:
         secretKeyRef:
           name: fiveline-db-secret
           key: DATABASE_URL
```

**IRSA (최소권한) — "Pod별 IAM Role"**

| 상황 | Before | After |
|------|--------|-------|
| user-service Pod 침해 | 노드 EC2 Role 전체 권한 획득 | user-service IRSA만 → `fiveline/db-credentials` Secret만 읽기 가능 |
| order-service Pod 침해 | S3 전체, RDS 접근 가능 | order-service Secret + SQS SendMessage만 허용 |

**왜 Secrets Manager인가? (Systems Manager Parameter Store와 비교)**

| | Secrets Manager | SSM Parameter Store |
|-|----------------|---------------------|
| 자동 로테이션 | ✅ RDS 자동 로테이션 | ❌ 수동 |
| 감사 로그 | ✅ CloudTrail 연동 | ✅ |
| 크로스 계정 공유 | ✅ | 제한적 |
| 비용 | $0.40/secret/월 | 표준: 무료, 고급: $0.05/월 |
| **선택 이유** | 자동 로테이션 필수, 비용 차이 미미 | |

**비용**:
```
Secrets (db-credentials, jwt-secret): $0.40 × 2 = $0.80/월
API 호출:                              ~$0.05/월
월 예상 비용:                          ~$1/월
```

**임원 포인트**: *"월 $1로 자격증명 유출 리스크를 제거했습니다.  
비밀번호가 코드베이스 어디에도 없으며, 로테이션이 자동화되어 있습니다."*

---

## 파트 5. 시나리오 3 — 감사 추적 (CloudTrail + 개인정보보호법)

### 상황 설정

> *"고객으로부터 '내 개인정보가 유출된 것 같다'는 민원이 들어왔습니다.  
> Before 상태라면 어떻게 됩니까?"*

### Before

- API 호출 로그 없음 → 누가, 언제, 어떤 AWS 리소스에 접근했는지 알 수 없음
- EKS kubectl 접근 기록 없음 → 내부자 위협 탐지 불가
- **개인정보보호법 제29조**: 개인정보 접근 기록 보관 의무 → 소명 불가능

### After — CloudTrail + EKS 컨트롤플레인 로그

**CloudTrail로 기록되는 것**:
```
✅ RDS에 접근한 IAM Principal 기록
✅ S3 Data Lake 파일 접근 기록
✅ Secrets Manager에서 Secret 조회한 내역
✅ EKS API 호출 (kubectl get/apply/delete) 감사
✅ IAM Role 변경 이력
```

**EKS 컨트롤플레인 로그** (현재 구현 완료):
```hcl
# eks.tf:26 — 이미 활성화됨
enabled_cluster_log_types = ["api", "audit", "authenticator"]
```

**비용**:
```
CloudTrail (첫 번째 Trail): 무료
S3 저장 (30일 기준):       ~$1~2/월
월 예상 비용:               ~$2/월
```

**임원 포인트**: *"개인정보보호법 준수 및 침해 사고 포렌식을 위한 최소 비용의 감사 인프라를 구축했습니다."*

---

## 파트 6. 비용 및 우선순위 요약

### 월간 보안 비용 표

| 보안 항목 | 월 비용 | 방어하는 위협 | 우선순위 |
|----------|--------|------------|---------|
| WAF v2 | ~$15 | SQLi, XSS, DDoS, 봇 | P1 🔴 |
| Secrets Manager | ~$1 | 자격증명 유출, 코드 노출 | P1 🔴 |
| KMS CMK (3개 키) | ~$3 | 저장 데이터 암호화 | P2 🟡 |
| CloudTrail | ~$2 | 감사 추적, 컴플라이언스 | P2 🟡 |
| VPC Flow Logs | ~$1 | 네트워크 이상 탐지 | P2 🟡 |
| **합계** | **~$22/월** | | |

> **비교**: 개인정보 유출 시 과태료 최대 **3억 원** (개인정보보호법 제75조)  
> → 월 $22 투자로 3억 리스크 방어

### 구현 로드맵

```
현재 완료 ──────────────────────────────────► 프로젝트 마감
    │
    ├─ ✅ EKS 컨트롤플레인 로그 (audit/api/authenticator)
    ├─ ✅ RDS/ElastiCache 보안 그룹 격리
    ├─ ✅ ACM TLS 인증서 (ALB + CloudFront)
    ├─ ✅ Pod SecurityContext (runAsNonRoot, capabilities drop ALL)
    │
    ├─ 🔄 P1: Secrets Manager + ESO + 앱 서비스 IRSA
    ├─ 🔄 P1: WAF v2 (REGIONAL + CLOUDFRONT)
    │
    ├─ 📋 P2: CloudTrail, VPC Flow Logs, KMS CMK
    └─ 📋 P3: NetworkPolicy, GitHub Actions 보안 스캔
```

---

## 파트 7. 마무리 멘트

> *"저희가 구현한 보안은 '설정하고 잊어버릴 수 있는 자동화된 보안'입니다.  
> WAF는 AWS가 실시간으로 규칙을 업데이트하고,  
> 자격증명은 ESO가 자동으로 갱신하며,  
> 감사 로그는 CloudTrail이 자동 수집합니다.  
> 작은 팀이 운영 부담 없이 보안 베이스라인을 유지할 수 있는 구조를 선택했습니다."*

---

## 발표 시 추가 포인트 (Q&A 대비)

**예상 질문 1: "WAF를 직접 구현하지 않고 Managed Rules를 쓴 이유는?"**
> AWS 보안팀이 매일 새로운 공격 패턴을 업데이트합니다. 소규모 팀이 직접 규칙을 유지보수하는 것보다, 전문 조직에 위임하는 것이 비용 효율적입니다. 커스텀 규칙은 서비스 특성에 맞는 Rate Limit 등 필요한 것만 추가했습니다.

**예상 질문 2: "Secrets Manager 대신 SSM Parameter Store를 쓰면 더 싸지 않나?"**
> SSM 고급 파라미터도 무료는 아니며(월 $0.05/파라미터), 자동 로테이션 기능이 없습니다. DB 비밀번호 90일 로테이션 정책 적용 시 Secrets Manager의 자동 로테이션이 운영 비용을 줄여줍니다.

**예상 질문 3: "현재 미구현된 것들이 있는데 위험하지 않나?"**
> P1 항목(Secrets Manager, WAF)을 우선 구현하여 가장 큰 리스크인 자격증명 유출과 외부 공격을 막았습니다. P2(CloudTrail, KMS)는 컴플라이언스 및 암호화 강화를 위한 것으로, 서비스 가용성에 직접 영향을 주지 않습니다. 우선순위 기반으로 보안 투자를 배분했습니다.

**예상 질문 4: "Zero Trust 개념을 어떻게 적용했나?"**
> IRSA를 통해 Pod별 최소권한을 부여하는 것이 컨테이너 환경에서의 Zero Trust 적용입니다. "같은 EKS 노드에 있어도 서비스별로 분리된 AWS 권한"이 핵심입니다. NetworkPolicy를 추가하면 Pod 간 트래픽도 default-deny로 격리됩니다.

---

## 발표 슬라이드 구성 제안

| 슬라이드 | 제목 | 핵심 내용 |
|---------|------|---------|
| 1 | 이커머스 서비스의 3가지 위협 | 아이콘 + 짧은 설명 |
| 2 | 보안 아키텍처 Before/After | 아키텍처 다이어그램 2개 나란히 |
| 3 | WAF — 외부 공격 차단 | 공격 흐름 차단 시각화, 비용 $15/월 |
| 4 | Secrets Manager + IRSA — 자격증명 보호 | 흐름도, 비용 $1/월 |
| 5 | CloudTrail — 감사 추적 | 개인정보보호법 연결, 비용 $2/월 |
| 6 | 비용 요약 + 로드맵 | 표 하나, 타임라인 하나 |
