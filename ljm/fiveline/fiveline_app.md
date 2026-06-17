# Fiveline 애플리케이션 구성 상세

> 이커머스 서비스 + 운영자 서비스 실제 구성 기준  
> 최종 업데이트: 2026-06-09 (EKS 배포 완료 기준)

---

## 1. 서비스 구성 개요

Fiveline 애플리케이션은 **이커머스 사용자 서비스**와 **운영자 서비스** 두 개의 독립 UI와, 5개의 FastAPI 마이크로서비스 백엔드로 구성된다.

| 구분 | URL | 설명 |
|------|-----|------|
| 이커머스 (사용자) | https://d330d0cjfkz4e7.cloudfront.net | React SPA, CloudFront + S3 배포 |
| 운영자 | http://ab7cb469745664b3892b997388cf021a-239075982.ap-northeast-2.elb.amazonaws.com:8004 | admin-service (FastAPI + React 정적 서빙, ELB 직접 노출) |

### 아키텍처 구성

```
[사용자 브라우저]
      │
      ▼
[CloudFront] ──── [S3: fiveline-frontend-089955620282] (정적 파일)
      │
      ▼
[ALB (ap-northeast-2)] ← WAF 미적용 (예정)
      │
[EKS Ingress Controller]
      ├── /api/auth, /api/users      → user-service (8001)
      ├── /api/products              → product-service (8002)
      ├── /api/orders, /api/cart     → order-service (8003)
      └── /api/notifications         → notification-service (8005)

[운영자 브라우저]
      │
      ▼
[admin-service ELB:8004] ──── 정적 파일(React) + API 동시 서빙
      │
      ▼
[admin-service Pod] ──── PostgreSQL (user/product/order 스키마 직접 조회)
```

---

## 2. 이커머스 서비스 (Customer Frontend)

### 2.1 기술 스택

| 항목 | 내용 |
|------|------|
| 프레임워크 | React 18 + TypeScript + Vite |
| 스타일 | Tailwind CSS (CDN) |
| HTTP 클라이언트 | Axios |
| 빌드 | Docker multi-stage (node:20-slim → python:3.12-slim) |
| 배포 | S3 정적 파일 → CloudFront 배포 |

### 2.2 페이지 구성

| 라우트 | 페이지 | 인증 필요 | 주요 기능 |
|--------|--------|-----------|---------|
| `/` | 홈 | ❌ | 히어로 배너, 최신 상품, 브랜드 쇼케이스 |
| `/products` | 상품 목록 | ❌ | 검색(키워드), 필터(카테고리/브랜드/가격), 정렬(최신순/가격순) |
| `/products/:id` | 상품 상세 | ❌ | 상품 정보, 리뷰 목록/작성, 장바구니 담기 |
| `/login` | 로그인 | ❌ | 이메일 + 비밀번호, JWT 발급 |
| `/signup` | 회원가입 | ❌ | 이름/이메일/비밀번호 (전화번호 선택) |
| `/profile` | 프로필 | ✅ | 이름/전화번호 수정 |
| `/cart` | 장바구니 | ✅ | 담긴 상품 목록, 수량 수정/삭제, 주문 생성 |
| `/orders` | 주문 내역 | ✅ | 전체 주문 목록, 상태(SUCCESS/PENDING/FAILED) 표시 |

### 2.3 주요 사용자 흐름

```
[회원가입] → POST /api/auth/signup
[로그인]   → POST /api/auth/login → JWT 저장 (localStorage)

[상품 검색] → GET /api/products?q=키워드&category=&brand=&sort=newest
[상품 상세] → GET /api/products/{id}
[리뷰 작성] → POST /api/products/{id}/reviews (인증 필요)

[장바구니 담기] → POST /api/cart/items
[장바구니 조회] → GET /api/cart
[수량 변경]    → PATCH /api/cart/items/{id}
[항목 삭제]    → DELETE /api/cart/items/{id}

[주문 생성]   → POST /api/orders/from-cart → 장바구니 전체 주문화
[주문 내역]   → GET /api/orders/me

[알림 조회]   → GET /api/notifications
[알림 읽음]   → POST /api/notifications/read/{id}
```

### 2.4 상품 데이터

- 무신사 크롤링 데이터 **9,997개** 상품 RDS 삽입 완료
- 카테고리: 상의, 하의, 아우터, 신발, 가방, 모자 등 패션 전 카테고리
- 다수 브랜드 포함, 가격대 다양

---

## 3. 운영자 서비스 (Admin Service)

### 3.1 기술 스택

| 항목 | 내용 |
|------|------|
| 백엔드 | FastAPI (Python 3.12) |
| 프론트엔드 | React 18 + TypeScript + Vite (FastAPI 서버에서 정적 서빙) |
| 인증 | employee_id 기반 JWT (30분 만료) |
| DB 접근 | user/product/order 스키마 모두 직접 SQL 조회 |

### 3.2 로그인 방식

일반 사용자와 분리된 관리자 전용 인증:

```
POST /api/auth/admin/register   관리자 등록 (name + email + employee_id)
POST /api/auth/admin/login      관리자 로그인 (name + employee_id)
```

- `employee_id` 는 사용자 테이블의 별도 컬럼 (일반 사용자 ID와 무관)
- 로그인 성공 시 JWT 발급, 관리자 UI 진입

### 3.3 대시보드 탭 구성

#### 탭 1. 대시보드 (홈)

KPI 종합 현황 한눈에 파악:

| 지표 | 설명 |
|------|------|
| 총 주문 수 | 전체 주문 건수 |
| 총 매출 | 성공 주문 기준 합산 |
| 총 사용자 수 | 가입 회원 수 |
| 총 상품 수 | 등록 상품 수 |
| 주문 상태별 현황 | SUCCESS / PENDING / FAILED 건수 |
| 인기 상품 TOP 5 | 판매량 기준 상위 5개 |
| 최근 주문 목록 | 최신 주문 10건 |

API: `GET /api/admin/dashboard`

#### 탭 2. 주문 관리

- 전체 주문 목록 조회 (사용자명, 금액, 상태, 주문일시)
- 상태별 필터 (SUCCESS / PENDING / FAILED)
- 실패 주문 원인 코드 표시 (DB_TIMEOUT, OUT_OF_STOCK 등)

API: `GET /api/admin/orders`

#### 탭 3. 사용자 관리

- 전체 가입 회원 목록 (이름, 이메일, 가입일)
- admin 계정 제외 (일반 사용자만 표시)

API: `GET /api/admin/users`

#### 탭 4. 상품 관리

- 전체 상품 목록 (이름, 카테고리, 가격, 재고)
- 재고 수량 직접 수정 가능

API:
```
GET   /api/admin/products
PATCH /api/admin/products/{id}/stock   {"stock_quantity": N}
```

---

## 4. 백엔드 마이크로서비스 상세

### 4.1 서비스 구성 요약

| 서비스 | 포트 | DB 스키마 | HPA CPU | 특이사항 |
|--------|------|----------|---------|---------|
| user-service | 8001 | user_schema | 70% | JWT 발급, 관리자/일반 구분 |
| product-service | 8002 | product_schema | 70% | 상품 9,997개, 리뷰 포함 |
| order-service | 8003 | order_schema | 60% | Product Service 병렬 호출, 실패 시뮬레이션 |
| admin-service | 8004 | user+product+order | 70% | React SPA 동시 서빙 |
| notification-service | 8005 | notification_schema | 70% | SQS 연동 예정 (현재 내부 API 방식) |

### 4.2 서비스 간 통신

```
order-service
  └── asyncio.gather() → product-service (상품 상세 병렬 조회, N+1 최적화)
  └── POST /api/notifications/internal → notification-service (주문 완료 알림)

admin-service
  └── PostgreSQL SQL JOIN → user_schema + product_schema + order_schema
```

### 4.3 전체 API 엔드포인트

| 서비스 | Method | 엔드포인트 | 설명 |
|--------|--------|-----------|------|
| user | POST | `/api/auth/signup` | 회원가입 |
| user | POST | `/api/auth/login` | 로그인 (JWT) |
| user | POST | `/api/auth/admin/register` | 관리자 등록 |
| user | POST | `/api/auth/admin/login` | 관리자 로그인 |
| user | GET | `/api/users/me` | 내 프로필 조회 |
| user | PUT | `/api/users/me` | 내 프로필 수정 |
| product | GET | `/api/products` | 상품 목록 (q/category/brand/price/sort/page) |
| product | GET | `/api/products/brands` | 브랜드 목록 |
| product | GET | `/api/products/{id}` | 상품 상세 |
| product | POST | `/api/products` | 상품 등록 (관리자) |
| product | GET | `/api/products/{id}/reviews` | 리뷰 목록 |
| product | POST | `/api/products/{id}/reviews` | 리뷰 작성 |
| order | GET | `/api/cart` | 장바구니 조회 |
| order | POST | `/api/cart/items` | 장바구니 담기 |
| order | PATCH | `/api/cart/items/{id}` | 수량 수정 |
| order | DELETE | `/api/cart/items/{id}` | 항목 삭제 |
| order | POST | `/api/orders/from-cart` | 장바구니 기반 주문 |
| order | GET | `/api/orders/me` | 내 주문 내역 |
| order | GET | `/api/error-test` | 장애 시뮬레이션 |
| order | GET | `/api/slow-test` | 지연 시뮬레이션 |
| admin | POST | `/api/auth/admin/register` | 관리자 등록 |
| admin | POST | `/api/auth/admin/login` | 관리자 로그인 |
| admin | GET | `/api/admin/dashboard` | 대시보드 통계 |
| admin | GET | `/api/admin/orders` | 전체 주문 목록 |
| admin | GET | `/api/admin/users` | 전체 사용자 목록 |
| admin | GET | `/api/admin/products` | 전체 상품 목록 |
| admin | PATCH | `/api/admin/products/{id}/stock` | 재고 수정 |
| notification | GET | `/api/notifications` | 알림 목록 (page/size/unread_only) |
| notification | POST | `/api/notifications/read/{id}` | 알림 읽음 처리 |
| notification | POST | `/api/notifications/internal` | 내부 알림 생성 |
| all | GET | `/api/health` | 헬스체크 |

### 4.4 DB 스키마

| 스키마 | 테이블 | 주요 컬럼 |
|--------|--------|----------|
| `user_schema` | `users` | id, email, password_hash, name, phone, role(customer/admin), employee_id |
| `product_schema` | `products` | id, name, description, category, brand, price, original_price, stock_quantity, image_url |
| `product_schema` | `reviews` | id, product_id, user_id, reviewer_name, rating(1-5), content |
| `order_schema` | `cart_items` | id, user_id, product_id, quantity, product_name(캐시), product_price(캐시) |
| `order_schema` | `orders` | id, user_id, total_price, status(PENDING/SUCCESS/FAILED), error_code, response_time_ms |
| `order_schema` | `order_items` | id, order_id, product_id, product_name(스냅샷), quantity, price |
| `notification_schema` | `notifications` | id, user_id, type, title, message, is_read |

### 4.5 주문 실패/지연 시뮬레이션

order-service는 데이터 파이프라인 분석 및 알람 동작 검증용 시뮬레이션 기능 내장:

- **실패율**: 평상시 5%, 프로모션 모드 15%
- **지연율**: 3% 확률로 2~5초 응답 지연
- **실패 코드**: `OUT_OF_STOCK`, `PAYMENT_FAILED_SIMULATED`, `DB_TIMEOUT`, `INTERNAL_SERVER_ERROR`
- **목적**: HPA 발동, CloudWatch 알람, Bedrock 분석 리포트 시나리오 생성

---

## 5. 로컬 개발 환경

### 5.1 환경 구성

```bash
# PostgreSQL 18 로컬 설치 (DB: fiveline, user: fiveline)
# 각 서비스별 .env 파일 (DATABASE_URL 등)

# 프론트엔드 로컬 실행 (vite proxy 모드)
VITE_USE_PROXY=true npm run dev   # → 127.0.0.1:8001~8005 proxy
```

### 5.2 환경변수 구성 (.env 파일별)

| 서비스 | 주요 환경변수 |
|--------|-------------|
| user-service | `DATABASE_URL`, `JWT_SECRET_KEY` |
| product-service | `DATABASE_URL` |
| order-service | `DATABASE_URL`, `PRODUCT_SERVICE_URL` |
| admin-service | `DATABASE_URL` |
| notification-service | `DATABASE_URL`, `SQS_QUEUE_URL` (로컬: 빈 값) |

### 5.3 Docker 빌드 주의사항

- OneDrive 경로에 한글 포함 시 Docker build 실패 → `C:\tmp\` 에 복사 후 빌드
- ECR push 전 `aws ecr get-login-password --profile ljm | docker login ...` 필요
- `DOCKER_BUILDKIT=0` 설정 시 Bash tool에서 빌드 안정성 향상

---

## 6. 보완 필요 사항

### 6.1 서비스(코드) 측면

| 항목 | 현재 상태 | 보완 방향 |
|------|----------|---------|
| SQS 연동 | `SQS_QUEUE_URL=''` (비활성) | order-service → SQS → notification-service 비동기 연동 완성 |
| ElastiCache Redis 활용 | 연결만 설정, 실제 캐싱 미적용 | 상품 목록/세션 캐싱 적용 |
| 상품 이미지 | 무신사 외부 URL 의존 | S3 이미지 업로드 + CloudFront URL로 교체 |
| 재고 실시간 동기화 | 주문 시 재고 차감 없음 | `orders/from-cart` 처리 시 `stock_quantity` 차감 트랜잭션 추가 |
| 비밀번호 변경 | 엔드포인트 없음 | `PUT /api/users/me/password` 추가 |
| 관리자 검색기능 | 주문/사용자/상품 검색 없음 | 각 관리 탭에 키워드 검색 추가 |

### 6.2 인프라 측면

| 항목 | 현재 상태 | 보완 방향 |
|------|----------|---------|
| admin-service 노출 방식 | 별도 ELB:8004 임시 노출 | ALB Ingress에 통합 (`/` + `/api/admin` 경로 분리) |
| WAF | 미적용 | REGIONAL(ALB) + CLOUDFRONT(us-east-1) WAF v2 적용 |
| Secrets Manager + ESO | 미구현, 환경변수 직접 주입 | IRSA → Secrets Manager → ESO → K8s Secret 전환 |
| CI/CD 자동화 | ECR 수동 push, ArgoCD 수동 sync | GitHub Actions 파이프라인 + ArgoCD auto-sync 완성 |
| Cluster Autoscaler | 미구현 | HPA와 연계한 노드 자동 확장 완성 |
| CloudTrail | 미구현 | 전 리전 API 감사 로그 활성화 |
| NetworkPolicy | 미적용 | default-deny 후 서비스 간 필요 통신만 허용 |
| Terraform Remote State | 로컬 tfstate | S3 + DynamoDB Lock 전환 (팀 협업) |
