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


1. "왜?"를 먼저 말하는 사람 "왜?"를 먼저 말하는 사람 — 도구 이름 나열이 아니라 비즈니스 리스크를 먼저 제시하면 기술을 모르는 임원도 고개를 끄덕입니다.

2. 트레이드오프를 아는 사람 — "SSM Parameter Store 대신 Secrets Manager를 선택한 이유", "Managed Rules vs 직접 작성" 같은 비교를 스스로 꺼내면 "이 사람이 공부를 제대로 했구나" 인상을 줍니다.

3. 숫자로 말하는 사람 — "월 $22로 과태료 3억 리스크 방어" 이 한 줄이 5분 설명보다 효과적입니다.

4. 미구현 사항을 당당하게 말하는 사람 — "P2는 아직 구현 중이지만 P1 두 가지로 가장 큰 리스크를 먼저 처리했습니다"가 "전부 다 완성했습니다(거짓말)"보다 훨씬 신뢰를 줍니다.

