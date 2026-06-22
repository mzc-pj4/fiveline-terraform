\# AWS AI Ops 플랫폼 (지호) — 구현 변경 사항 및 트러블슈팅



> 8주차 프로젝트 중 팀원 2 (지호) R\&R 영역 (데이터 + AI 에이전트, 평가 비중 40%).

> 원래 W1 계획 대비 실제 구현 차이 + 발생한 주요 트러블슈팅 정리.



\## 📂 폴더 구조



```

jihoo/

├── \*.tf                              Terraform IaC (19개 파일)

├── lambda-src/                       Lambda 소스 코드

│   ├── langgraph-agent/              LangGraph V2 컨테이너 (handler.py, graph.py, tools.py, Dockerfile)

│   ├── pipeline-orchestrator/        3시간 자동 Glue 체인

│   ├── resource-checker/             5분 자동 미사용 리소스 스캔

│   ├── metrics-collector/            5분 자동 CW 메트릭 수집

│   ├── report-generator/             매일 자동 4섹션 마크다운 리포트

│   ├── report-embedder/              매일 자동 Bedrock Titan Embed → DDB

│   ├── dashboard-builder/            5분 자동 data.json 생성

│   ├── dashboard-api/                API Gateway 진입점 (chatbot API)

│   ├── bedrock-agent-action/         Bedrock Agent 액션 그룹

│   └── summary-writer/               시간별 요약

├── glue-scripts/                     PySpark ETL 스크립트

│   ├── raw-to-cleansed.py            JSON → Parquet (60줄)

│   └── cleansed-to-aggregated.py     시간별·일별 집계 (123줄)

├── dashboard-web/                    정적 대시보드 (HTML/JS/Tailwind/Chart.js)

└── CHANGES.md                        이 문서

```



\## 📊 원래 계획 vs 실제 구현 — 7가지 변경



\### 1. 대시보드: Grafana → 자체 정적 사이트



\*\*원래\*\*: Managed Grafana (또는 self-hosted)



\*\*바꾼 거\*\*: S3 정적 호스팅 + HTML 157줄 + JS 248줄 (Tailwind + Chart.js) + Dashboard Builder Lambda 234줄



\*\*이유\*\*:

\- 비용: Managed Grafana = 사용자당 약 9,000원/월. 팀 5명 × 8주 = 약 360,000원 누적.

\- 통합 어려움: 모니터링 #3가 만든 DDB 테이블을 Grafana는 별도 데이터소스 플러그인 필요.

\- AI 챗봇 통합 X: Grafana UI 중심. 우리 LangGraph 챗봇은 JSON 데이터 직접 사용 필요.

\- 학습 가치: Grafana는 설정만, 코드 작성 없음.



\*\*효과\*\*:

\- 비용: 9,000원 → 약 50원/월 (1/180)

\- AI 챗봇과 같은 data.json 공유 — 통합 즉시

\- HTML/CSS/JS 자유 — 우리 디자인 가능



\### 2. AI 에이전트: Bedrock Agent + Action Group → LangGraph 멀티스텝



\*\*원래\*\*: Bedrock Agent (콘솔 정의) + Action Group + Lambda 핸들러 별도



\*\*바꾼 거\*\*: LangGraph V2.1 컨테이너 이미지 1개 + 6개 도구 통합 (tools.py 277줄) + 멀티스텝 추론



\*\*이유\*\*:

\- Bedrock Agent IaC 한계: Action Group 추가 시 콘솔 일일이 클릭.

\- 단일 라운드 한계: Agent는 도구 1회 호출 → 답변. "어제 매출 떨어진 원인" 같은 복합 질문 처리 어려움.

\- 도구별 Lambda 분리 비효율: Action Group마다 별도 Lambda → 콜드스타트 ×N.

\- 로컬 개발 X: Bedrock Agent는 콘솔에서만 테스트.

\- 멘토 권장: "LangGraph 사용해보라" 가이드.



\*\*효과\*\*:

\- 멀티스텝 추론: "복합 질문" → 도구 2\~5개 자동 순차 호출

\- 컨테이너 1개로 통합 → 콜드스타트 1/6

\- IaC 100% (Terraform) + 로컬 invoke 테스트 가능

\- 한국어 SRE 페르소나 + 출처 명시 + 즉시/단기/장기 분류



\### 3. AI 검색: 진짜 Bedrock KB → KB Lite (Titan Embed + DDB)



\*\*원래\*\*: Bedrock Knowledge Base + OpenSearch Serverless



\*\*바꾼 거\*\*: Embedder Lambda + DDB report\_embeddings + LangGraph search\_reports 도구 (DDB Scan + 코사인 유사도)



\*\*이유\*\*:

\- 비용 폭탄: OpenSearch Serverless 최소 2 OCU 상시 = 월 약 400,000원.

\- 데이터 작음: 매일 1리포트 × 8주 = 60개 미만. OpenSearch 과스펙.

\- 8주 단발 프로젝트: 영구 인프라 부담 X.

\- 학습 가치: KB는 black box. 직접 만들면 벡터 임베딩 + 코사인 유사도 원리 학습.



\*\*효과\*\*:

\- 비용: 월 400,000원 → 수백원 (1/1000)

\- 효과 90% (60개 정도 데이터에서 충분)

\- "비용 효율적 RAG" 명확한 차별점

\- SYSTEM\_PROMPT 강화로 "리포트/지난주/과거/트렌드" 키워드 자동 라우팅



\### 4. 데이터 수집: 단순 Logs → Fluent Bit + Firehose + Glue Workflow



\*\*원래\*\*: CloudWatch Logs 적재 → 수동 Crawler → Athena



\*\*바꾼 거\*\*: Fluent Bit DaemonSet (cjw EKS) → CW Logs → Firehose × 2 → S3 (raw/cleansed/aggregated 3단) → Glue Workflow DAG → Athena 7개 테이블 → Pipeline Orchestrator 3시간 자동 (V2.2)



\*\*이유\*\*:

\- CloudWatch Logs Insights 비용: 쿼리당 스캔 데이터 GB당 비싸.

\- `.gz` 직접 스캔 느림: 30초\~5분.

\- 수동 작업 한계: 매번 사람이 시작 = 자동화 부족.

\- 분당 50\~70 records 누적 = 사람이 못 따라감.



\*\*효과\*\*:

\- 쿼리 비용: TB당 $5 → $0.50 (Parquet, 1/10)

\- 쿼리 시간: 30초\~5분 → 1\~10초 (1/100)

\- 사용자 클릭 → 1초 CW → 1분 S3 → 3시간 분석 가능 (완전 자동)

\- 7개 테이블 (raw, cleansed, service\_events, events\_hourly, resource\_findings\_daily, cw\_metrics, resource\_check)



\### 5. 자동화: 수동 트리거 → 5개 자동 Lambda



\*\*원래\*\*: 수동 또는 단순 Lambda



\*\*바꾼 거\*\*:



| Lambda | 주기 | 역할 |

|---|---|---|

| Pipeline Orchestrator | 3시간 | Glue 전체 체인 + MSCK |

| Resource Checker | 5분 | EBS/RDS/EKS/Lambda 미사용·태그 누락 |

| Metrics Collector | 5분 | CloudWatch 메트릭 → S3 |

| Report Generator | 매일 15:00 KST | Bedrock Claude → 4섹션 리포트 |

| Report Embedder | 매일 16:00 KST | Titan Embed v2 → DDB 벡터 |



\*\*이유\*\*:

\- 운영자 추격 불가능 (분당 50\~70 records).

\- 매일 자동 리포트가 RAG 검색용 데이터로 누적.

\- 미사용 리소스 5분마다 자동 스캔이 가치.



\*\*효과\*\*:

\- 운영자 0명

\- 미사용 EBS 1GB 자동 발견 → 실제 청소까지 (월 100원 절감 + 발견 자체가 가치)

\- 매일 리포트 13+ 개 누적 → KB Lite RAG 데이터



\### 6. EKS: ECS Fargate만 → 별도 jihoo EKS 환경 (학습용)



\*\*원래\*\*: ECS Fargate 백엔드



\*\*바꾼 거\*\*: 별도 jihoo EKS (terraform/jihoo/eks.tf). 끄고 켜기 가능.



\*\*이유\*\*:

\- EKS 학습 필요 (커리큘럼).

\- 다른 팀원 fiveline-eks 영향 방지.



\*\*효과\*\*:

\- 학습: EKS 직접 구성 경험

\- 비용 조절: 평소엔 끄고 발표 직전만 켬 (4,760원/일)



\### 7. 통합: 분리 R\&R → 다른 팀원 4개 자원 통합



\*\*원래\*\*: 각 팀원 R\&R 독립



\*\*바꾼 거\*\*:

\- \*\*B\*\*. `alarm\_history` (모니터링 #3) → LangGraph 도구 `get\_recent\_alarms`

\- \*\*C\*\*. `dashboard\_summary` (모니터링 #3) → 대시보드 카드 + fallback

\- \*\*D\*\*. RDS/ALB 메트릭 → `cw\_metrics` Athena 테이블 + 도구 `get\_metrics`

\- \*\*F\*\*. Fluent Bit DaemonSet → cjw `fiveline-eks` 에 우리가 설치 + IAM 격리



\*\*이유\*\*: 시너지 + 발표 임팩트 + 챗봇 한 자리 답변



\*\*효과\*\*: "팀원 5명이 하나의 운영 플랫폼" 차별점



\## 🚨 트러블슈팅 — 실제 발생한 주요 사례



\### 사례 1. Glue Trigger 폭주 (2026-06-10)



\*\*증상\*\*: Pipeline Orchestrator Lambda가 `ConcurrentRunsExceededException` 반복. Glue Job이 자동으로 RUNNING 상태로 계속 시작됨.



\*\*진단\*\*:

\- 우리 EventBridge orchestrator-schedule = DISABLED

\- 그런데 Glue Job이 분당 새로 시작

\- Glue Trigger 조사 → `etl\_to\_aggregated` (CONDITIONAL on raw-to-cleansed SUCCEEDED), `crawler\_to\_etl` (CONDITIONAL on Crawler SUCCEEDED) 가 chain reaction

\- raw-to-cleansed SUCCEEDED → etl\_to\_aggregated 자동 fire → cleansed-to-aggregated 시작 → 끝나면 다음 raw 처리 → 무한 반복



\*\*해결\*\*: 자동 Trigger 두 개 DEACTIVATED + Glue Job MaxConcurrentRuns 1 → 2 (race condition 대응) + timeout 10 → 30분 (누적 데이터 증가 대응)



\*\*교훈\*\*: Glue Workflow DAG 사용 시 Trigger 체인을 명시적으로 관리해야 함. Orchestrator Lambda가 직접 호출하면 Trigger는 비활성화 권장.



\### 사례 2. Lambda Function URL 403 — MZC SCP 차단 (2026-06-16\~17)



\*\*증상\*\*: 대시보드 챗봇 UI 추가 시 브라우저에서 `/chat` 호출 → HTTP 403 Forbidden + `x-amzn-ErrorType: AccessDeniedException`



\*\*진단 과정\*\*:

1\. Function URL Config 확인 → AuthType=NONE, CORS 정상

2\. Lambda Policy 확인 → `lambda:InvokeFunctionUrl` + Principal=`\*` + FunctionUrlAuthType=NONE 조건 정확

3\. CLI로 add-permission 추가 → 여전히 403

4\. Function URL 삭제 + Terraform 재생성 → 새 URL도 동일하게 403

5\. Lambda 직접 invoke (SDK) → 200 정상 응답

6\. \*\*결론\*\*: Lambda 코드/권한 모두 정상. 인증 계층 위에서 차단 = MZC 조직 SCP가 Lambda Function URL 공개 호출 자체를 차단.



\*\*1차 우회 시도 — CloudFront + OAC (실패)\*\*:

\- CloudFront 배포 + Origin Access Control + Lambda Function URL AWS\_IAM 인증

\- GET 요청도 403 AccessDeniedException

\- POST 요청은 InvalidSignatureException ("서명 안 맞음")

\- `signing\_behavior` always → no-override 변경 시도해도 동일

\- \*\*원인\*\*: OAC + Lambda Function URL의 POST 요청 body 서명 처리에 알려진 한계 있음 (body hash 불일치)



\*\*2차 우회 — API Gateway HTTP API (성공)\*\*:

\- CloudFront + OAC + Function URL AWS\_IAM 모두 제거

\- aws\_apigatewayv2\_api (HTTP API) + aws\_apigatewayv2\_integration (AWS\_PROXY) + Lambda permission 추가

\- 결과: 한글 POST 200 + 완벽한 LangGraph 응답 (멀티턴 + KB Lite RAG 모두 작동)



\*\*핸들러 보강\*\*: API Gateway HTTP API v2.0의 `isBase64Encoded` 플래그 처리 + UTF-8 BOM 제거 + 에러 시 `rawBodyPreview` 디버그 정보 응답.



\*\*교훈\*\*:

\- 조직 차원 SCP는 IAM Policy로 우회 불가능 — 다른 패턴 사용

\- Lambda Function URL은 매력적이지만 OAC + POST 조합은 약함

\- API Gateway HTTP API가 가장 표준이고 안정적인 패턴

\- 진단 시 Lambda 직접 invoke로 코드 정상 여부 확인이 핵심



\### 사례 3. Docker Desktop 손상 → CloudShell 우회 (2026-06-15)



\*\*증상\*\*: LangGraph 컨테이너 이미지 빌드 시 `input/output error` + `read-only file system`. WSL 리셋, Docker Desktop 완전 재시작 모두 실패.



\*\*해결\*\*: AWS CloudShell (브라우저 터미널) 에서 빌드 + ECR 푸시. 로컬 Docker 의존성 제거.



\*\*교훈\*\*: Docker Desktop 손상 시 즉시 CloudShell 대안 활용. 로컬 환경에 묶이지 않게.



\### 사례 4. 한국어 PowerShell 인코딩 (반복 발생)



\*\*증상\*\*: PowerShell + curl.exe에서 한글 JSON body 전송 시 글자 깨짐 (`?? RDS ?? ??`).



\*\*원인\*\*: PowerShell 기본 인코딩이 UTF-16 LE, curl.exe는 시스템 코드페이지 사용.



\*\*해결\*\*: UTF-8 BOM 없는 파일로 저장 후 `--data-binary` 사용

```powershell

\[System.IO.File]::WriteAllBytes("req.json", \[System.Text.UTF8Encoding]::new($false).GetBytes('{"input":"한글"}'))

curl.exe -X POST $url --data-binary "@req.json"

```



\*\*교훈\*\*: 한국어 환경 PowerShell 명령은 항상 UTF-8 파일 우회.



\### 사례 5. LangGraph 도구 선택 오류 — SYSTEM\_PROMPT 강화 (2026-06-15)



\*\*증상\*\*: "지난주 RDS 이슈 보고서 있어?" 질문 시 search\_reports 대신 get\_dashboard\_summary 호출.



\*\*원인\*\*: Claude Haiku가 키워드 ("RDS") 보고 가장 익숙한 도구 선택. "리포트/지난주" 의도 약하게 인식.



\*\*해결\*\*: SYSTEM\_PROMPT에 명시적 키워드 라우팅 규칙 추가:

```

"리포트", "지난주", "과거", "트렌드", "보고서" 키워드 있으면

반드시 search\_reports 먼저 호출.

```



\*\*교훈\*\*: LLM 도구 선택은 SYSTEM\_PROMPT 안내문 한 줄로 크게 개선 가능.



\## 🎯 최종 아키텍처



```

사용자 사이트 (cjw / 프론트엔드)

&#x20;   ↓

CloudFront → ALB → fiveline-eks Pod (cjw 백엔드)

&#x20;   ↓ stdout

Fluent Bit DaemonSet (우리 설치, amazon-cloudwatch 격리)

&#x20;   ↓

CloudWatch Logs

&#x20;   ↓

Firehose × 2 (service-events, alarms)

&#x20;   ↓

S3 Data Lake (raw/cleansed/aggregated 3단 + Parquet)

&#x20;   ↓

Glue Workflow DAG (Crawler + Job 1 + Job 2)

&#x20;   ↓ Pipeline Orchestrator (3시간 자동)

Athena 7개 테이블

&#x20;   ↓

LangGraph V2.1 (Bedrock Claude 3 Haiku + 6 도구)

\+ KB Lite (Titan Embed v2 + DDB report\_embeddings)

\+ Checkpointer Lite (DDB conversation\_history, TTL 30일)

&#x20;   ↓

API Gateway HTTP API (SCP 우회용 표준 패턴)

&#x20;   ↓

대시보드 (S3 정적 + HTML/JS/Tailwind/Chart.js)

\+ data.json 5분 자동 갱신 (Dashboard Builder Lambda)

```



\## 📈 성과 요약



| 항목 | 결과 |

|---|---|

| Terraform 파일 | 19개 |

| Lambda 함수 | 9개 (+1 컨테이너 LangGraph) |

| DynamoDB 테이블 | 6개 (check-results, dashboard-summary, hourly-order-summary, infra-health-summary, report-metadata, report-embeddings, conversation-history) |

| Athena 테이블 | 7개 |

| Glue Job | 2개 (PySpark 183줄) |

| 자동화 Lambda | 5개 |

| 통합 자원 (다른 팀원) | 4개 (B/C/D/F) |

| Python 코드 | 약 1,500줄 |

| Terraform 코드 | 약 2,500줄 |

| 실제 운영 가치 | 미사용 EBS 1GB 자동 발견 → 청소 |

| End-to-End 검증 | 14 단계 통과 |



\## 🔗 관련



\- 개인 작업 레포: https://github.com/Kjihoo/aws-aiops-platform

\- 발표일: 2026-06-19

\- 평가 비중: Data 25% + AI 에이전트 15% = 40%



