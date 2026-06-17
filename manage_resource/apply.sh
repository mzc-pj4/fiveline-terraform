#!/bin/bash
# 출근 시 실행 — RDS 시작 + 준비 대기
set -e

PROFILE="ljm"
REGION="ap-northeast-2"

echo "=== RDS 시작 ==="
for DB in fiveline-rds-primary fiveline-rds-replica-c fiveline-rds-replica-a; do
  aws rds start-db-instance \
    --profile $PROFILE --region $REGION \
    --db-instance-identifier "$DB" > /dev/null 2>&1 \
    && echo "  OK: $DB 시작" || echo "  이미 실행 중: $DB"
done

echo ""
echo "RDS 준비 대기 중... (5~10분)"
aws rds wait db-instance-available \
  --profile $PROFILE --region $REGION \
  --db-instance-identifier fiveline-rds-primary
echo "완료."
