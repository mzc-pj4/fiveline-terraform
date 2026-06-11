# 보안 파트 PPT 제작 가이드 (상세)

> 발표 전략/멘트: `security_presentation.md` 참고  
> 이 파일: **슬라이드별 구성 + 추가 보안 항목 정의 + 제작 순서**

---

## 추가 구현 보안 항목 (WAF·Secrets Manager·IRSA 외)

현재 코드를 분석한 결과, 이미 구현된 것이 생각보다 많다.  
아래 표를 기준으로 발표 범위를 결정할 것.

### 현재 구현 현황 전체

| 항목 | 위치 | 상태 |
|------|------|------|
| HTTPS 강제 리다이렉트 + TLSv1.2_2021 | `cloudfront.tf` (`redirect-to-https`) | ✅ 구현 완료 |
| 커스텀 도메인 | `route53.tf` + `acm.tf` | ✅ fiveline.store / dashboard.fiveline.store |
| ACM 와일드카드 인증서 | `acm.tf` | ✅ fiveline.store + *.fiveline.store (us-east-1) |
| WAF v2 (2-Tier) | `waf.tf` | ✅ CloudFront WAF + Regional WAF |
| S3 OAC (CloudFront만 S3 접근) | `cloudfront.tf:17`, `s3_frontend.tf:41` | ✅ 구현 완료 |
| S3 Public Access Block | `s3_frontend.tf:22` | ✅ 구현 완료 |
| S3 Versioning | `s3_frontend.tf:32` | ✅ 구현 완료 |
| RDS 저장 데이터 암호화 | `rds.tf:155` (`storage_encrypted=true`) | ✅ 구현 완료 |
| RDS TLS 전송 암호화 | `rds.tf:175` (`ca_cert_identifier`) | ✅ 구현 완료 |
| RDS 보안 그룹 격리 | `rds.tf:8` (EKS SG + Bastion SG만 허용) | ✅ 구현 완료 |
| RDS 자동 백업 (7일) | `rds.tf:180` | ✅ 구현 완료 |
| EKS 컨트롤플레인 로그 | `eks.tf:26` (api/audit/authenticator) | ✅ 구현 완료 |
| Pod SecurityContext | K8s manifest | ✅ 구현 완료 |
| OIDC + 인프라 IRSA 3종 | `iam.tf:277,335,401` | ✅ 구현 완료 |
| Secrets Manager + ESO | 미작성 | 🔄 P1 구현 |
| 앱 서비스 IRSA 5개 | 미작성 | 🔄 P1 구현 |
| **보안 HTTP 헤더** | 미작성 | 📋 P2 추가 |
| **CloudTrail** | 미작성 | 📋 P2 추가 |
| **KMS CMK** (현재 AWS 관리형) | 미작성 | 📋 P2 추가 |
| **ECR 이미지 취약점 스캔** | 미작성 | 📋 P2 추가 |
| **JWT HttpOnly Cookie** | 코드 수정 필요 | 📋 P3 추가 |

---

### 추가 구현 항목 상세 (P2~P3)

#### A. 보안 HTTP 헤더 (CloudFront Response Headers Policy)

**무엇인가**: 서버 응답에 브라우저 보안 정책을 지시하는 헤더  
**왜 필요한가**: WAF가 서버를 지키면, 보안 헤더는 브라우저를 지킨다

| 헤더 | 설정값 | 방어하는 공격 |
|------|--------|------------|
| `Strict-Transport-Security` | max-age=31536000; includeSubDomains | SSL Stripping (HTTP 강제 다운그레이드) |
| `X-Frame-Options` | DENY | Clickjacking (iframe으로 사이트 임베드 후 클릭 유도) |
| `X-Content-Type-Options` | nosniff | MIME 타입 변조 (JS 파일을 이미지로 속여 실행) |
| `Referrer-Policy` | strict-origin-when-cross-origin | 타 사이트 이동 시 URL 정보 유출 |
| `Content-Security-Policy` | 기본값 | XSS 스크립트 실행 제한 |

**구현 방법**: Terraform 리소스 하나 추가 (cloudfront.tf에 붙임)

```hcl
resource "aws_cloudfront_response_headers_policy" "security_headers" {
  name = "${local.project}-security-headers"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      override                   = true
    }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    content_type_options {
      override = true
    }
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
  }
}
```

`default_cache_behavior`에 `response_headers_policy_id` 추가.  
**비용**: 무료 (CloudFront 기본 포함)

---

#### B. ECR 이미지 취약점 스캔 (Enhanced Scanning)

**무엇인가**: Docker 이미지 push 시 Amazon Inspector가 CVE 자동 분석  
**왜 필요한가**: OS 패키지 + Python 라이브러리 취약점을 배포 전에 감지

```hcl
resource "aws_ecr_registry_scanning_configuration" "main" {
  scan_type = "ENHANCED"   # Basic은 OS만, Enhanced는 언어 패키지도 스캔

  rule {
    scan_frequency = "SCAN_ON_PUSH"
    repository_filter {
      filter      = "fiveline-*"
      filter_type = "WILDCARD"
    }
  }
}
```

스캔 결과에서 Critical/High 발견 시 → SNS 알림 → 배포 중단 가능  
**비용**: Inspector ~$0.09/image layer/월 (이미지 10개 기준 ~$3/월)

---

#### C. CloudTrail (API 감사)

**무엇인가**: AWS 계정 내 모든 API 호출 기록  
**왜 필요한가**: 개인정보보호법 제29조 — 접근 기록 보관 의무  
(위반 시 과태료 최대 3억 원)

**기록되는 것**:
- Secrets Manager `GetSecretValue` 호출 내역 (누가 언제 Secret 읽었는지)
- `kubectl apply/delete` 동작 (EKS API 호출)
- S3 Data Lake 파일 접근
- IAM Role 변경, EC2 인스턴스 수정

**비용**: 첫 번째 Trail 무료, S3 저장 ~$2/월

---

#### D. JWT HttpOnly Cookie 전환 (코드 레벨)

**현재 문제**: JWT를 `localStorage`에 저장  
→ XSS 공격 성공 시 `document.cookie`로 토큰 탈취 가능

**개선**: `HttpOnly` 쿠키로 변경  
→ JavaScript에서 접근 불가 (XSS로 탈취 불가능)

```python
# user-service 로그인 응답 (FastAPI)
# Before
return {"access_token": token, "token_type": "bearer"}

# After
response = JSONResponse({"message": "login success"})
response.set_cookie(
    key="access_token",
    value=token,
    httponly=True,      # JS 접근 차단
    secure=True,        # HTTPS 전용
    samesite="strict",  # CSRF 방지
    max_age=1800        # 30분
)
return response
```

**비용**: 없음 (코드 수정만)

---

## PPT 슬라이드 구성 (총 8장)

### 발표 프레임: "Defense in Depth (다층 방어)"

```
인터넷 → [레이어 1: 경계 방어] → [레이어 2: 자격증명] → [레이어 3: 데이터] → [레이어 4: 감사]
```

이 구조로 발표하면 "단편적으로 보안 기능을 추가한 것이 아니라, 체계적으로 레이어를 설계했다"는 인상을 준다.

---

### 슬라이드 1 — 표지

**제목**: 이커머스 보안 설계 — Defense in Depth  
**부제**: 이재민 | 보안 파트

**레이아웃**:
- 중앙: 프로젝트 로고 또는 보안 아이콘 (방패)
- 오른쪽 하단: AWS 서비스 아이콘 나열 (WAF, Secrets Manager, CloudTrail, KMS, IAM)
- 배경: 다크 계열 (네이비 또는 차콜)

**발표 시작 멘트**:
> "이커머스 서비스는 운영 첫날부터 공격을 받습니다.  
> 저는 외부 공격, 자격증명 유출, 감사 부재라는 3가지 위협에 대해  
> 레이어별로 방어 설계를 수립하고 구현했습니다."

---

### 슬라이드 2 — 이커머스가 받는 위협과 방어 전략

**제목**: 3가지 위협 → 4개 방어 레이어

**레이아웃**: 상단에 위협 → 하단에 레이어 매핑

**상단 (위협 3개, 박스)**:
```
[① 외부 공격]         [② 자격증명 유출]       [③ 감사/추적 불가]
 SQLi · XSS · DDoS     DB 비밀번호 코드 노출    개인정보보호법 위반
 봇 트래픽             kubectl describe 노출    사고 원인 소명 불가
```

**하단 (레이어 → 위협 매핑)**:
```
레이어 1: 경계 방어   ─── WAF + HTTPS + 보안 헤더          → 위협 ①
레이어 2: 자격증명    ─── Secrets Manager + IRSA             → 위협 ②
레이어 3: 데이터 보호 ─── S3 OAC + RDS 암호화 + ECR 스캔    → 위협 ①②
레이어 4: 가시성      ─── CloudTrail + ALB Logs + EKS 로그  → 위협 ③
```

**비주얼**: 화살표로 위협 → 레이어 연결, 색상으로 구분

---

### 슬라이드 3 — Before / After 전체 아키텍처

**제목**: 보안 적용 전/후

**레이아웃**: 좌(Before) / 우(After) 2분할, 텍스트 + 아이콘

```
BEFORE (빨간 배경 테두리)    |    AFTER (초록 배경 테두리)
─────────────────────────────|─────────────────────────────
인터넷                        |    인터넷
  ↓ 공격 그대로 통과           |      ↓
CloudFront / ALB              |    [WAF] ← SQLi, 봇 차단
  ↓                           |      ↓
EKS Pod                       |    CloudFront (HTTPS 강제)
  env: DB_URL=pass@rds...      |      ↓ 보안 헤더 포함 응답
  ↓ 비밀번호 코드 노출         |    EKS Pod
RDS                           |      ← Secrets Manager 자동 주입
  저장 암호화 없음             |      ← IRSA 최소권한
  감사 없음                    |    RDS (암호화 ✅ + 로그 ✅)
                               |    CloudTrail ← 전 API 감사
```

**핵심 포인트 텍스트**:
- Before: "비밀번호가 코드에 있고, 공격이 DB까지 도달하며, 사고 추적이 불가능"
- After: "외부 공격은 WAF가, 자격증명은 Secrets Manager가, 감사는 CloudTrail이"

**비주얼**: AWS 아이콘 사용, 색상 대비 강조  
**스크린샷 없음** → 다이어그램으로만 구성

---

### 슬라이드 4 — 레이어 1: 경계 방어 (WAF + HTTPS + 보안 헤더)

**제목**: 레이어 1 — 공격이 서버에 도달하기 전에 차단

**레이아웃**: 3개 항목 세로 배치 (각 Before/After)

#### 항목 1: WAF v2 — 2-Tier 방어 구조 ✅ 구현 완료

```
인터넷 → [CloudFront WAF, us-east-1] → CloudFront → [Regional WAF, ap-northeast-2] → ALB
```

| | Before | After |
|-|--------|-------|
| SQLi 공격 | RDS까지 전달 | CloudFront WAF 엣지에서 즉시 차단 |
| 봇/악성 IP | 서버 과부하 | IP Reputation List 자동 차단 |
| CloudFront 우회 | ALB 직접 노출 | Regional WAF 2차 방어 |
| 규칙 유지보수 | 팀이 직접 | AWS 보안팀 실시간 자동 업데이트 |

**왜 2-Tier인가**: 공격자가 ALB DNS를 직접 아는 경우 CloudFront WAF 우회 가능 → Regional WAF가 두 번째 방어선  
**왜 관리형 룰셋인가**: 새로운 CVE 발생 시 AWS가 자동 업데이트, 팀 운영 부담 없음

#### 항목 2: HTTPS 강제 ← **이미 구현 완료** ✅

```
cloudfront.tf: viewer_protocol_policy = "redirect-to-https"
```

HTTP로 접속해도 자동으로 HTTPS로 리다이렉트.  
중간자 공격(MITM)으로 평문 트래픽 탈취 불가.

#### 항목 3: 보안 HTTP 헤더 (Response Headers Policy)

| 헤더 | 방어 공격 |
|------|---------|
| HSTS | SSL Stripping 방지 |
| X-Frame-Options: DENY | Clickjacking |
| X-Content-Type-Options: nosniff | MIME 변조 |
| Referrer-Policy | URL 정보 유출 |

"단 Terraform 리소스 1개 추가로 브라우저 레벨 보안 정책 전부 적용"

**비용 요약 (이 슬라이드 하단)**:
```
WAF:         ~$15/월
보안 헤더:   무료 (CloudFront 포함)
HTTPS:       무료 (ACM 포함)
```

**비주얼**: 텍스트 표 + 간단한 흐름도 (인터넷→WAF→CloudFront)  
**스크린샷 없음**

---

### 슬라이드 5 — 레이어 2: 자격증명 보호 (Secrets Manager + IRSA)

**제목**: 레이어 2 — 비밀번호가 코드에 없다

**레이아웃**: 상단 코드 Before/After + 하단 IRSA 다이어그램

**상단 — Before/After 코드 비교** (가장 임팩트 있는 부분):

```yaml
# ❌ BEFORE — env에 평문 노출
env:
  - name: DATABASE_URL
    value: "postgresql://fiveline:pass123@rds-host:5432/fiveline"
# → kubectl describe pod 명령 한 줄로 노출됨
# → git에 실수로 push하면 영구 기록

# ✅ AFTER — 코드에 비밀번호 없음
env:
  - name: DATABASE_URL
    valueFrom:
      secretKeyRef:
        name: fiveline-db-secret   # ESO가 자동 생성한 K8s Secret
        key: DATABASE_URL
```

**하단 — IRSA 다이어그램**:

```
user-service Pod (ServiceAccount: user-service-sa)
  └── IRSA: fiveline-user-service-role
        └── 허용: GetSecretValue (fiveline/db-credentials 만)
              ← RDS 직접 접근 불가
              ← 다른 서비스 Secret 읽기 불가
              ← S3, EC2, 기타 AWS API 불가

 비교: BEFORE — 노드 EC2 Role 상속 → 모든 AWS 서비스 권한
```

**Secrets Manager 자동 로테이션 강조**:
> "90일마다 DB 비밀번호를 자동으로 교체합니다.  
> 팀원이 수동으로 비밀번호를 바꾸고 전 서비스를 재배포할 필요가 없습니다."

**비용**:
```
Secrets Manager: $0.40 × 2 = $0.80/월
IRSA:           무료 (IAM 포함)
```

**비주얼**: 코드 블록 (검은 배경) + 텍스트 다이어그램  
**스크린샷 없음**

---

### 슬라이드 6 — 레이어 3: 데이터 보호 (OAC + 암호화 + ECR)

**제목**: 레이어 3 — 데이터가 저장되고 이동되는 모든 곳을 보호

**레이아웃**: 3열 배치 (S3 / RDS / 이미지)

#### 열 1: S3 Frontend ← **이미 구현 완료** ✅

```
✅ OAC: CloudFront만 S3 접근 가능
✅ Public Access Block: S3 URL 직접 접근 불가
✅ Versioning: 파일 변조 시 이전 버전 복원 가능

→ 공격자가 S3 URL을 알아도 직접 접근 불가
```

#### 열 2: RDS PostgreSQL ← **이미 구현 완료** ✅

```
✅ storage_encrypted = true   저장 데이터 암호화
✅ ca_cert_identifier        TLS 전송 암호화 (sslmode=require)
✅ 보안 그룹 격리             EKS/Bastion만 허용, 인터넷 접근 불가
✅ 자동 백업 7일              랜섬웨어 공격 시 복구

📋 추가: KMS CMK로 교체       AWS 관리형 키 → 직접 통제하는 키
```

#### 열 3: ECR 이미지 스캔 (추가)

```
📋 Before: 취약한 Python 패키지 포함 이미지 배포 가능
   After:  push 시 Amazon Inspector 자동 CVE 스캔
           Critical 발견 → SNS 알림 → 배포 중단

비용: ~$3/월
```

**핵심 메시지**:
> "저장 데이터, 전송 데이터, 컨테이너 이미지까지  
> 데이터가 있는 모든 레이어를 암호화/검증합니다."

**비용**:
```
S3 OAC + 암호화:  무료
RDS 암호화:       무료 (이미 적용)
KMS CMK:          ~$3/월
ECR 스캔:         ~$3/월
```

**비주얼**: 3열 카드 레이아웃, 각 열 아이콘 (S3 / RDS / ECR)  
**스크린샷 없음**

---

### 슬라이드 7 — 레이어 4: 가시성/감사 (CloudTrail + EKS 로그)

**제목**: 레이어 4 — "무슨 일이 있었는가"를 언제나 알 수 있다

**레이아웃**: 상단 법적 근거 + 하단 기술 구성

**상단 — 법적 근거 강조 박스**:
```
개인정보보호법 제29조
"개인정보에 대한 접근 기록 보관 의무"

위반 시: 과태료 최대 3억 원

→ CloudTrail 없으면 침해 사고 시 "접근 기록이 없다"는 것 자체가 위반
```

**중단 — 감사 레이어 구성**:

| 감사 레이어 | 기록 내용 | 상태 |
|------------|---------|------|
| EKS 컨트롤플레인 로그 | kubectl 명령, API 호출 | ✅ 완료 |
| RDS 커넥션 로그 | 접속 시도/해제 기록 | ✅ 완료 (log_connections) |
| CloudTrail | AWS 전 API 호출 감사 | 📋 구현 예정 |
| ALB Access Logs | HTTP 요청 전체 기록 | 📋 구현 예정 |

**하단 — CloudTrail이 잡아내는 것 예시**:
```
시나리오: 팀원 계정 탈취 후 공격자가 IAM Role을 수정하려 시도

CloudTrail 이벤트:
  EventName: UpdateAssumeRolePolicy
  UserAgent:  aws-cli/2.0
  SourceIPAddress: 183.xxx.xxx.xxx (해외 IP)
  EventTime: 2026-06-09T03:14:22Z (새벽 3시)

→ 즉각 탐지 → SNS 알림 발송
```

**비용**:
```
CloudTrail (첫 Trail): 무료
S3 저장:               ~$2/월
EKS 로그:              ~$1/월 (CloudWatch)
```

**비주얼**: 텍스트 표 + 이벤트 예시 코드 블록 (스크린샷 대신)  
**스크린샷**: 선택 사항 (CloudTrail 이벤트 1장만, 있으면 좋음)

---

### 슬라이드 8 — 구현 현황 + 비용 요약 + 로드맵

**제목**: 월 $26로 구축한 다층 방어 체계

**상단 — 비용 표**:

| 레이어 | 항목 | 방어 위협 | 월 비용 | 상태 |
|--------|------|---------|--------|------|
| 경계 | WAF v2 (2-Tier) | SQLi, XSS, 악성 IP, 봇 | ~$15 | ✅ |
| 경계 | HTTPS + TLSv1.2_2021 | 평문 탈취, 다운그레이드 | 무료 | ✅ |
| 경계 | 커스텀 도메인 + ACM | — | ~$0 (도메인 연간비용) | ✅ |
| 경계 | 보안 HTTP 헤더 | Clickjacking, MIME 변조 | 무료 | 📋 |
| 자격증명 | Secrets Manager | 자격증명 유출 | ~$1 | 🔄 |
| 데이터 | KMS CMK | 키 통제 강화 | ~$3 | 📋 |
| 데이터 | ECR 이미지 스캔 | 취약 이미지 배포 | ~$3 | 📋 |
| 감사 | CloudTrail | 컴플라이언스 | ~$2 | 📋 |
| 기타 | ALB Access Logs | HTTP 감사 | ~$1 | 📋 |
| | | **합계** | **~$25/월** | |

**이미 구현 (추가 비용 없음)**:
HTTPS 강제 · S3 OAC · RDS 암호화 · EKS 감사 로그 · Pod SecurityContext

**중단 — 임팩트 강조 박스**:
```
개인정보 유출 시 과태료:   최대 3억 원
DDoS로 인한 서비스 중단:   분당 수백만 원 매출 손실

→ 월 $25 투자로 방어
```

**하단 — 구현 로드맵** (타임라인 형식):

```
     ✅ 완료                    🔄 P1 (진행 중)       📋 P2 (예정)
─────────────────────────────────────────────────────────────────►
HTTPS + TLSv1.2_2021    Secrets Manager    CloudTrail
커스텀 도메인            앱 IRSA 5개        KMS CMK
WAF v2 (2-Tier)                            ECR 스캔
S3 OAC / RDS 암호화                        보안 헤더
EKS 감사 로그                              ALB Logs
Pod SecurityContext
```

---

## 슬라이드 제작 시 유의사항

### AWS 콘솔 스크린샷 사용 기준

콘솔 스크린샷은 최소화. 아래 경우에만 사용:

| 상황 | 권장 대안 |
|------|---------|
| WAF 규칙 목록 | 텍스트 표로 대체 |
| Secrets Manager Secret 목록 | 텍스트로 "fiveline/db-credentials, fiveline/jwt-secret-key" 명시 |
| CloudTrail 이벤트 | 이벤트 JSON 코드 블록으로 대체 (더 명확함) |
| **EKS 로그 확인** | ← 이것만 스크린샷 1장 사용 가능 (실제 audit log 보여주기) |

이유: 스크린샷은 발표 흐름을 끊고, 뒷자리에서 잘 안 보이며, 다이어그램/코드가 더 전달력이 높음

### 디자인 원칙

| 항목 | 규칙 |
|------|------|
| 배경 | 다크 네이비(#1A237E) 또는 흰색 중 하나로 통일 |
| Before 강조 | 빨간 텍스트 또는 빨간 테두리 박스 |
| After 강조 | 초록 텍스트 또는 초록 테두리 박스 |
| 구현 완료 | ✅ 초록 아이콘 |
| 구현 예정 | 📋 회색 또는 파란 아이콘 |
| 비용 강조 | AWS 오렌지(#FF9900) 또는 볼드 |
| 폰트 | 제목 36pt+, 본문 20pt+ (뒤에서도 보여야 함) |
| 슬라이드당 텍스트 | 핵심만, 설명은 입으로 — 글자 너무 많으면 안 읽음 |

### 코드 블록 스타일 (Before/After 비교)

```
배경: 검은색 (#1E1E1E, VS Code 다크 테마)
폰트: Consolas 또는 D2Coding
크기: 14~16pt
Before: 빨간 테두리 또는 ❌ 아이콘
After:  초록 테두리 또는 ✅ 아이콘
```

---

## 제작 순서

```
STEP 1. 구현 완료 (P1 항목)
   ├─ WAF v2 terraform 작성 + apply
   ├─ Secrets Manager Secret 2개 생성
   ├─ ESO SecretStore + ExternalSecret 적용
   └─ 앱 서비스 IRSA 5개 terraform apply

STEP 2. P2 항목 추가 구현 (시간 있으면)
   ├─ CloudFront Response Headers Policy (Terraform 리소스 1개)
   ├─ CloudTrail 활성화
   └─ ECR Enhanced Scanning

STEP 3. PPT 틀 잡기 (도구: PowerPoint / Google Slides)
   └─ 슬라이드 8장 레이아웃 배치 (빈 틀만)

STEP 4. 콘텐츠 채우기
   ├─ 슬라이드 3: Before/After 아키텍처 다이어그램 작성
   │   (draw.io 또는 PPT 도형으로)
   ├─ 슬라이드 4~7: 표 + 코드 블록 삽입
   └─ 슬라이드 8: 비용 표 + 로드맵 타임라인

STEP 5. 리허설 (8~10분 목표)
   └─ 슬라이드당 1~1.5분
      멘트: security_presentation.md 참고

STEP 6. Q&A 준비
   └─ security_presentation.md "예상 질문 4개" 숙지
```

---

## 핵심 메시지 (발표 전 반복 읽기)

> **"저희 보안은 4개 레이어로 구성됩니다.**  
> WAF가 경계를 지키고, Secrets Manager가 자격증명을 지키고,  
> S3 OAC와 RDS 암호화가 데이터를 지키고,  
> CloudTrail이 모든 것을 기록합니다.  
> 그리고 이 대부분은 자동으로 동작합니다.  
> 작은 팀이 운영 부담 없이 이커머스 보안을 유지하는 구조입니다."**
