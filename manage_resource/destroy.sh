#!/bin/bash
# 퇴근 시 실행 — RDS 중지 (EKS/Helm/K8s 상태 유지)
set -e

PROFILE="ljm"
REGION="ap-northeast-2"

echo "=== RDS 중지 ==="
for DB in fiveline-rds-primary fiveline-rds-replica-c fiveline-rds-replica-a; do
  aws rds stop-db-instance \
    --profile $PROFILE --region $REGION \
    --db-instance-identifier "$DB" > /dev/null 2>&1 \
    && echo "  OK: $DB" || echo "  이미 중지됨: $DB"
done

echo ""
echo "완료. EKS/Helm/K8s 상태 유지됨."
