# 메가존 클라우드 파이널 프로젝트 컨텍스트

## 프로젝트 개요

**주관**: 메가존 클라우드 파이널 프로젝트  
**기간**: 2025년 5월 11일 ~ 7월 8일  
**주제**: Data Analytics 및 CI/CD 환경의 컨테이너 기반 아키텍처 설계 및 구현

## 교육 기반

- MSP 기초 교육 및 AWS 공인 교육 기반 Tech 기술 활용
  - 테크니컬 에센셜
  - 아키텍처 기본/심화
- 시나리오 기반 프로젝트 진행
- 시나리오 목표: **고객환경 이해 → 인프라 기술 습득 → 구축 및 운영**

## 프로젝트 진행 방안

- **팀(공통) 프로젝트**: 시나리오를 구체화한 후, 시나리오에 해당하는 프로젝트를 안정적으로 구축·운영할 수 있는 핵심 코어 서비스 + AI 기능
- **개인 프로젝트**: 핵심 코어 서비스에 추가·확장하여 개인 역량 발휘
  - 기능 추가뿐 아니라 기존 핵심 코어 서비스를 **보안, 운영, 안정성** 관점에서 강화하는 것도 고려
  - 개인 프로젝트를 위한 핵심 코어 서비스를 구축하는 과정이 아님

## 아키텍처 구성

### 네트워크 / 컴퓨팅

| 구성 요소 | 설명 |
|---|---|
| VPC | 퍼블릭/프라이빗 서브넷, 멀티 AZ 구성 |
| Public Subnet | NAT Gateway, Bastion Host |
| Private Subnet (EKS) | EKS Worker Node (멀티 AZ) |
| Private Subnet (RDS) | RDS Primary(2a) / Standby(2c, Multi-AZ 자동) + Read Replica × 2 (Replica-A: 2a, Replica-C: 2c) |
| Private Subnet (Cache) | ElastiCache Primary / Replica |
| EKS Cluster | Kubernetes 기반 컨테이너 오케스트레이션 |
| ALB | Application Load Balancer |
| Ingress | EKS Ingress Controller |
| ArgoCD | GitOps 기반 배포 도구 |

### CDN / DNS / 보안

| 구성 요소 | 설명 |
|---|---|
| CloudFront | CDN, S3 Frontend 배포 연동 |
| Route 53 | DNS 관리 |
| ACM | SSL/TLS 인증서 관리 |
| WAF | Web Application Firewall (SQLi/XSS/Rate Limiting) |
| KMS | 키 관리 서비스 |
| Secrets Manager | 시크릿/자격증명 관리 |
| IAM | 권한 및 역할 관리 (IRSA 포함) |
| CloudTrail | 전 리전 API 호출 감사 로그 |
| VPC Flow Logs | 네트워크 트래픽 감사 |

### CI/CD

| 구성 요소 | 설명 |
|---|---|
| GitHub Repo | 소스 코드 저장소 |
| GitHub Actions | CI/CD 파이프라인 |
| ECR | 컨테이너 이미지 레지스트리 |
| Manifest Repo | Kubernetes 매니페스트 저장소 (GitOps) |
| ArgoCD | Image Tag 업데이트 후 자동 배포 |

### Observability & Analytics

| 구성 요소 | 설명 |
|---|---|
| CloudWatch | 모니터링 및 로그 수집 |
| Firehose | 실시간 데이터 스트리밍 |
| S3 Data Lake | 데이터 레이크 스토리지 |
| Glue | ETL 데이터 처리 |
| Athena | S3 데이터 쿼리 분석 |
| SNS | 알림 메시징 서비스 |
| Lambda (Alarm) | 알람 처리 Lambda |
| DynamoDB | alarm_history, dashboard_summary 테이블 |
| EventBridge | 이벤트 기반 트리거 |
| Lambda (Report) | 리포트 생성 Lambda |
| Bedrock | AI 기반 리포트 생성 |
| S3 (Report) | 리포트 저장소 |

## Claude Code 사용 지침

> **중요**: 모든 질문에 대해 해당 질문과 관련된 전문 에이전트를 활용하여 답변한다.

- Terraform/IaC 관련 → `voltagent-infra:terraform-engineer` 에이전트
- Kubernetes/EKS 관련 → `voltagent-infra:kubernetes-specialist` 에이전트
- 네트워크 설계 관련 → `voltagent-infra:network-engineer` 에이전트
- CI/CD 파이프라인 관련 → `voltagent-infra:deployment-engineer` 에이전트
- 보안/IAM 관련 → `voltagent-infra:security-engineer` 에이전트
- 전체 아키텍처 설계 관련 → `voltagent-infra:cloud-architect` 에이전트
- 데이터베이스 관련 → `voltagent-infra:database-administrator` 에이전트
- DevOps/운영 관련 → `voltagent-infra:devops-engineer` 에이전트
- SRE/안정성 관련 → `voltagent-infra:sre-engineer` 에이전트

## 저장소 구조

```
fiveline-terraform/
├── backend.tf         # Terraform S3 Remote Backend + DynamoDB Lock (팀 협업 State 관리)
├── providers.tf       # 공급자 설정 (AWS ap-northeast-2 + us-east-1 CloudFront WAF용)
├── variables.tf       # 변수 정의
├── network.tf         # VPC, 서브넷, NAT Gateway 등 네트워크
├── eks.tf             # EKS 클러스터 및 노드 그룹 (On-Demand 70% / Spot 30%)
├── iam.tf             # IAM 역할, 정책, IRSA (서비스별 Pod Identity)
├── rds.tf             # RDS PostgreSQL (Primary Multi-AZ + Read Replica)
├── elasticache.tf     # ElastiCache Redis (Primary + Replica)
├── cloudtrail.tf      # CloudTrail (감사 로그), VPC Flow Logs
├── waf.tf             # WAF WebACL REGIONAL (ALB용, ap-northeast-2)
├── waf_cloudfront.tf  # WAF WebACL CLOUDFRONT (CDN용, us-east-1 필수)
├── kms.tf             # KMS CMK (EKS etcd + Data Lake용)
├── data_pipeline.tf   # S3 Data Lake, Kinesis Firehose, Glue, Athena
├── dynamodb.tf        # DynamoDB 6개 테이블 (alarm_history 등)
├── lambda.tf          # Lambda 5개 함수 (metrics-collector, alarm-handler 등)
├── eventbridge.tf     # EventBridge 스케줄 5개
├── outputs.tf         # 출력값 정의
├── k8s/               # Kubernetes 매니페스트
│   ├── serviceaccount.yaml         # IRSA 바인딩 ServiceAccount (3개 서비스)
│   ├── user-service.yaml           # RollingUpdate(0/1), preStop, terminationGracePeriod
│   ├── product-service.yaml
│   ├── order-service.yaml
│   ├── hpa.yaml                    # HPA (user/product: 70%, order: 60%)
│   ├── pdb.yaml                    # PodDisruptionBudget (minAvailable: 1)
│   ├── fluent-bit-configmap.yaml   # Fluent Bit 설정 (cri 파서, EKS 로그 수집)
│   └── fluent-bit-daemonset.yaml   # Fluent Bit DaemonSet (Spot toleration 포함)
└── fiveline/          # 설계 문서
    ├── CLAUDE.md
    ├── fiveline_service.md
    ├── fiveline_requirement.md
    └── fiveline_data_pipeline.md  # 데이터 파이프라인 상세 설계
```
