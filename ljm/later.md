# 나중에 할 작업

## 1. RDS Zone Affinity 애플리케이션 레벨 구현

**배경**: rds.tf에 Replica-A(2a), Replica-C(2c) 2개를 배치하는 설계는 완료됨.
현재는 앱이 Read 트래픽을 두 Replica로 구분 라우팅하지 않음.

**해야 할 것**:
- `fiveline_manifest_guide.md`의 `externalsecret.yaml`에 `DB_READ_HOST` 환경변수 추가
  - 2a Pod → `rds-replica-a` 엔드포인트
  - 2c Pod → `rds-replica-c` 엔드포인트
- Python Flask 서비스(product-service 등)에서 Read 쿼리를 `DB_READ_HOST`로 라우팅하는 로직 추가

**우선순위**: 낮음 — 시연에 직접 영향 없음. Replica 1개만 있어도 CQRS/HA 입증 가능.
