# fiveline AWS 리소스 네이밍 컨벤션

## 1. 네이밍 규칙 원칙

### AWS Name 태그 패턴 (AWS 콘솔에서 보이는 이름)

```
{project}-{resource_type}[-{az_or_identifier}]
```

| 구성 요소 | 값 | 설명 |
|---|---|---|
| `project` | `fiveline` | 프로젝트 고정값 (`local.project`) |
| `resource_type` | `vpc`, `subnet`, `nat-gw`, `eks` 등 | AWS 리소스 유형 |
| `az_or_identifier` | `2a`, `2c`, `primary`, `ondemand` 등 | AZ 구분 또는 역할 식별자 (선택) |

**예시**

```
fiveline-vpc
fiveline-public-2a
fiveline-nat-gw-2a
fiveline-eks
fiveline-ondemand-ng
fiveline-rds-primary
fiveline-rds-replica
fiveline-redis
```

### AZ 식별자 규칙

| AZ | 식별자 |
|---|---|
| ap-northeast-2a | `2a` |
| ap-northeast-2c | `2c` |

리소스가 특정 AZ에 귀속될 때는 `-2a` / `-2c` 접미사를 붙인다. AZ에 독립적인 리소스(공유 라우트 테이블, 서브넷 그룹 등)는 접미사를 생략한다.

---

## 2. Terraform 식별자 vs AWS Name 태그 구분

| 구분 | 위치 | 형태 | 예시 |
|---|---|---|---|
| **Terraform 식별자** | HCL 코드 내 리소스 참조 이름 | `{resource_category}_{identifier}` | `aws_vpc.fiveline_vpc` |
| **AWS Name 태그** | AWS 콘솔에서 보이는 이름 | `{project}-{resource_type}[-{az}]` | `fiveline-vpc` |

Terraform 식별자는 HCL 내부 참조용으로 언더스코어(`_`)를 구분자로 사용하며, AWS Name 태그는 하이픈(`-`)을 구분자로 사용한다. 두 값은 서로 독립적으로 관리된다.

---

## 3. 현재 구성된 리소스 전체 목록

### 네트워크 리소스

| Terraform 식별자 | AWS 리소스 타입 | AWS Name 태그 | 용도 |
|---|---|---|---|
| `aws_vpc.fiveline_vpc` | `aws_vpc` | `fiveline-vpc` | 메인 VPC (10.10.0.0/16) |
| `aws_subnet.public_2a` | `aws_subnet` | `fiveline-public-2a` | 퍼블릭 서브넷 — ap-northeast-2a (10.10.0.0/24) |
| `aws_subnet.public_2c` | `aws_subnet` | `fiveline-public-2c` | 퍼블릭 서브넷 — ap-northeast-2c (10.10.1.0/24) |
| `aws_subnet.private_eks_2a` | `aws_subnet` | `fiveline-private-eks-2a` | EKS 프라이빗 서브넷 — ap-northeast-2a (10.10.10.0/24) |
| `aws_subnet.private_eks_2c` | `aws_subnet` | `fiveline-private-eks-2c` | EKS 프라이빗 서브넷 — ap-northeast-2c (10.10.11.0/24) |
| `aws_subnet.private_rds_2a` | `aws_subnet` | `fiveline-private-rds-2a` | RDS 프라이빗 서브넷 — ap-northeast-2a (10.10.20.0/24) |
| `aws_subnet.private_rds_2c` | `aws_subnet` | `fiveline-private-rds-2c` | RDS 프라이빗 서브넷 — ap-northeast-2c (10.10.21.0/24) |
| `aws_subnet.private_cache_2a` | `aws_subnet` | `fiveline-private-cache-2a` | ElastiCache 프라이빗 서브넷 — ap-northeast-2a (10.10.30.0/24) |
| `aws_subnet.private_cache_2c` | `aws_subnet` | `fiveline-private-cache-2c` | ElastiCache 프라이빗 서브넷 — ap-northeast-2c (10.10.31.0/24) |
| `aws_internet_gateway.fiveline_igw` | `aws_internet_gateway` | `fiveline-igw` | VPC 인터넷 게이트웨이 |
| `aws_eip.nat_2a` | `aws_eip` | `fiveline-eip-nat-2a` | NAT Gateway(2a)용 Elastic IP |
| `aws_eip.nat_2c` | `aws_eip` | `fiveline-eip-nat-2c` | NAT Gateway(2c)용 Elastic IP |
| `aws_nat_gateway.nat_2a` | `aws_nat_gateway` | `fiveline-nat-gw-2a` | NAT Gateway — ap-northeast-2a 퍼블릭 서브넷 |
| `aws_nat_gateway.nat_2c` | `aws_nat_gateway` | `fiveline-nat-gw-2c` | NAT Gateway — ap-northeast-2c 퍼블릭 서브넷 |
| `aws_route_table.public_rt` | `aws_route_table` | `fiveline-rt-public` | 퍼블릭 라우트 테이블 (IGW 경유) |
| `aws_route_table.private_eks_2a_rt` | `aws_route_table` | `fiveline-rt-private-eks-2a` | EKS 프라이빗 라우트 테이블 — 2a (nat_2a 경유) |
| `aws_route_table.private_eks_2c_rt` | `aws_route_table` | `fiveline-rt-private-eks-2c` | EKS 프라이빗 라우트 테이블 — 2c (nat_2c 경유) |
| `aws_route_table.private_rds_rt` | `aws_route_table` | `fiveline-rt-private-rds` | RDS 라우트 테이블 (완전 격리, 아웃바운드 없음) |
| `aws_route_table.private_cache_rt` | `aws_route_table` | `fiveline-rt-private-cache` | ElastiCache 라우트 테이블 (완전 격리, 아웃바운드 없음) |
| `aws_route_table_association.public_2a` | `aws_route_table_association` | — | public_2a ↔ public_rt 연결 |
| `aws_route_table_association.public_2c` | `aws_route_table_association` | — | public_2c ↔ public_rt 연결 |
| `aws_route_table_association.private_eks_2a` | `aws_route_table_association` | — | private_eks_2a ↔ private_eks_2a_rt 연결 |
| `aws_route_table_association.private_eks_2c` | `aws_route_table_association` | — | private_eks_2c ↔ private_eks_2c_rt 연결 |
| `aws_route_table_association.private_rds_2a` | `aws_route_table_association` | — | private_rds_2a ↔ private_rds_rt 연결 |
| `aws_route_table_association.private_rds_2c` | `aws_route_table_association` | — | private_rds_2c ↔ private_rds_rt 연결 |
| `aws_route_table_association.private_cache_2a` | `aws_route_table_association` | — | private_cache_2a ↔ private_cache_rt 연결 |
| `aws_route_table_association.private_cache_2c` | `aws_route_table_association` | — | private_cache_2c ↔ private_cache_rt 연결 |

### EKS 리소스

| Terraform 식별자 | AWS 리소스 타입 | AWS Name 태그 | 용도 |
|---|---|---|---|
| `aws_eks_cluster.fiveline_eks` | `aws_eks_cluster` | `fiveline-eks` | EKS 컨트롤플레인 (k8s 1.35) |
| `aws_eks_node_group.ondemand` | `aws_eks_node_group` | `fiveline-ondemand-ng` | On-Demand 노드 그룹 (t3.medium, 2~4대) |
| `aws_eks_node_group.spot` | `aws_eks_node_group` | `fiveline-spot-ng` | Spot 노드 그룹 (t3.medium+t3a.medium, 0~2대) |
| `aws_eks_addon.vpc_cni` | `aws_eks_addon` | — | VPC CNI 애드온 |
| `aws_eks_addon.kube_proxy` | `aws_eks_addon` | — | kube-proxy 애드온 |
| `aws_eks_addon.coredns` | `aws_eks_addon` | — | CoreDNS 애드온 |
| `aws_eks_addon.pod_identity` | `aws_eks_addon` | — | EKS Pod Identity Agent 애드온 |
| `aws_eks_addon.metrics_server` | `aws_eks_addon` | — | Metrics Server 애드온 |

### IAM 리소스

| Terraform 식별자 | AWS 리소스 타입 | AWS Name 태그 | 용도 |
|---|---|---|---|
| `aws_iam_role.eks_cluster_role` | `aws_iam_role` | `fiveline-eks-cluster-role` | EKS 컨트롤플레인 IAM 역할 |
| `aws_iam_role.eks_node_role` | `aws_iam_role` | `fiveline-eks-node-role` | EKS 워커 노드 IAM 역할 |
| `aws_iam_role_policy_attachment.eks_cluster_policy` | `aws_iam_role_policy_attachment` | — | AmazonEKSClusterPolicy 연결 |
| `aws_iam_role_policy_attachment.eks_worker_node_policy` | `aws_iam_role_policy_attachment` | — | AmazonEKSWorkerNodePolicy 연결 |
| `aws_iam_role_policy_attachment.eks_cni_policy` | `aws_iam_role_policy_attachment` | — | AmazonEKS_CNI_Policy 연결 |
| `aws_iam_role_policy_attachment.eks_ecr_readonly` | `aws_iam_role_policy_attachment` | — | AmazonEC2ContainerRegistryReadOnly 연결 |
| `aws_iam_role_policy_attachment.eks_ssm` | `aws_iam_role_policy_attachment` | — | AmazonSSMManagedInstanceCore 연결 |

### RDS 리소스

| Terraform 식별자 | AWS 리소스 타입 | AWS Name 태그 | 용도 |
|---|---|---|---|
| `aws_security_group.rds_sg` | `aws_security_group` | `fiveline-rds-sg` | RDS 보안 그룹 (EKS SG에서 5432 허용) |
| `aws_db_subnet_group.rds_subnet_group` | `aws_db_subnet_group` | `fiveline-rds-subnet-group` | RDS 전용 프라이빗 서브넷 그룹 |
| `aws_db_instance.rds_primary` | `aws_db_instance` | `fiveline-rds-primary` | RDS PostgreSQL 16.3 Primary (Multi-AZ, db.t3.medium) |
| `aws_db_instance.rds_replica` | `aws_db_instance` | `fiveline-rds-replica` | RDS Read Replica (db.t3.medium, 2c) |

### ElastiCache 리소스

| Terraform 식별자 | AWS 리소스 타입 | AWS Name 태그 | 용도 |
|---|---|---|---|
| `aws_security_group.elasticache_sg` | `aws_security_group` | `fiveline-elasticache-sg` | ElastiCache 보안 그룹 (EKS SG에서 6379 허용) |
| `aws_elasticache_subnet_group.cache_subnet_group` | `aws_elasticache_subnet_group` | `fiveline-cache-subnet-group` | ElastiCache 전용 프라이빗 서브넷 그룹 |
| `aws_elasticache_parameter_group.cache_params` | `aws_elasticache_parameter_group` | `fiveline-cache-params` | Redis 7 파라미터 그룹 |
| `aws_elasticache_replication_group.redis_cluster` | `aws_elasticache_replication_group` | `fiveline-redis` | Redis Replication Group (Primary + Replica, cache.t3.micro) |

---

## 4. 태그 전략

### 공통 태그 (default_tags — providers.tf)

모든 리소스에 자동으로 적용되며 `providers.tf`의 `default_tags` 블록에서 관리한다.

| 태그 키 | 값 | 설명 |
|---|---|---|
| `Project` | `fiveline` | 프로젝트 식별자 |
| `ManagedBy` | `terraform` | IaC 관리 도구 명시 |

### 리소스별 태그 (각 tf 파일)

각 리소스 블록 내 `tags` 인자에 추가하며, `default_tags`와 병합된다.

| 태그 키 | 예시 값 | 설명 |
|---|---|---|
| `Service` | `network`, `eks`, `rds`, `cache` | 리소스가 속한 서비스 레이어 |
| `Name` | `fiveline-vpc` | AWS 콘솔 표시 이름 (네이밍 컨벤션 준수) |

### Service 태그 값 규칙

| Service 값 | 해당 리소스 |
|---|---|
| `network` | VPC, 서브넷, IGW, EIP, NAT Gateway, 라우트 테이블 |
| `eks` | EKS 클러스터, 노드 그룹, IAM 역할 |
| `rds` | RDS 인스턴스, 서브넷 그룹, 보안 그룹 |
| `cache` | ElastiCache 복제 그룹, 서브넷 그룹, 파라미터 그룹, 보안 그룹 |

---

## 5. 향후 추가 예정 리소스 네이밍 예시

### 보안 리소스

| Terraform 식별자 (예정) | AWS Name 태그 (예정) | 용도 |
|---|---|---|
| `aws_wafv2_web_acl.regional_waf` | `fiveline-waf-regional` | ALB용 WAF WebACL (ap-northeast-2) |
| `aws_wafv2_web_acl.cloudfront_waf` | `fiveline-waf-cloudfront` | CloudFront용 WAF WebACL (us-east-1) |
| `aws_kms_key.eks_etcd` | `fiveline-kms-eks-etcd` | EKS etcd 시크릿 암호화 KMS CMK |
| `aws_kms_key.data_lake` | `fiveline-kms-data-lake` | S3 Data Lake 암호화 KMS CMK |
| `aws_cloudtrail.main_trail` | `fiveline-cloudtrail` | 전 리전 API 감사 로그 CloudTrail |
| `aws_security_group.bastion_sg` | `fiveline-bastion-sg` | Bastion Host 보안 그룹 |
| `aws_instance.bastion` | `fiveline-bastion` | Bastion Host EC2 인스턴스 |

### CDN / DNS 리소스

| Terraform 식별자 (예정) | AWS Name 태그 (예정) | 용도 |
|---|---|---|
| `aws_cloudfront_distribution.frontend` | `fiveline-cf-frontend` | 프론트엔드 S3 CDN 배포 |
| `aws_s3_bucket.frontend` | `fiveline-s3-frontend` | 프론트엔드 정적 파일 버킷 |
| `aws_route53_zone.fiveline_zone` | `fiveline-r53-zone` | Route 53 호스팅 존 |
| `aws_acm_certificate.fiveline_cert` | `fiveline-acm-cert` | ACM SSL/TLS 인증서 |

### 모니터링 / 데이터 파이프라인 리소스

| Terraform 식별자 (예정) | AWS Name 태그 (예정) | 용도 |
|---|---|---|
| `aws_s3_bucket.data_lake` | `fiveline-s3-data-lake` | S3 Data Lake 버킷 |
| `aws_kinesis_firehose_delivery_stream.metrics_stream` | `fiveline-firehose-metrics` | Kinesis Firehose 메트릭 스트리밍 |
| `aws_glue_catalog_database.analytics_db` | `fiveline-glue-analytics` | Glue ETL 카탈로그 데이터베이스 |
| `aws_dynamodb_table.alarm_history` | `fiveline-ddb-alarm-history` | 알람 이력 DynamoDB 테이블 |
| `aws_lambda_function.alarm_handler` | `fiveline-lambda-alarm-handler` | 알람 처리 Lambda 함수 |
| `aws_lambda_function.report_generator` | `fiveline-lambda-report-gen` | 리포트 생성 Lambda 함수 |
| `aws_sns_topic.alarm_topic` | `fiveline-sns-alarm` | 알람 SNS 토픽 |
| `aws_cloudwatch_log_group.eks_logs` | `fiveline-cw-eks-logs` | EKS 컨트롤플레인 CloudWatch 로그 그룹 |

### CI/CD 리소스

| Terraform 식별자 (예정) | AWS Name 태그 (예정) | 용도 |
|---|---|---|
| `aws_ecr_repository.user_service` | `fiveline-ecr-user-service` | user-service 컨테이너 이미지 레지스트리 |
| `aws_ecr_repository.product_service` | `fiveline-ecr-product-service` | product-service 컨테이너 이미지 레지스트리 |
| `aws_ecr_repository.order_service` | `fiveline-ecr-order-service` | order-service 컨테이너 이미지 레지스트리 |
| `aws_iam_role.github_actions_role` | `fiveline-iam-github-actions` | GitHub Actions OIDC IAM 역할 |

### ALB / Ingress 리소스

| Terraform 식별자 (예정) | AWS Name 태그 (예정) | 용도 |
|---|---|---|
| `aws_lb.public_alb` | `fiveline-alb-public` | 퍼블릭 Application Load Balancer |
| `aws_security_group.alb_sg` | `fiveline-alb-sg` | ALB 보안 그룹 (80/443 인바운드) |
| `aws_iam_role.alb_controller_role` | `fiveline-iam-alb-controller` | AWS Load Balancer Controller IRSA 역할 |
