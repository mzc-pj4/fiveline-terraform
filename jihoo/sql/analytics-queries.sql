-- =============================================================================
-- fiveline / mzc-pj4 — Athena 분석 쿼리 풀세트
-- =============================================================================
-- 작성자  : 김지호 (팀원 #2 데이터 파이프라인)
-- DB     : mzc_pj4_jihoo_data_lake_dev
-- 워크그룹: mzc-pj4-jihoo-analytics-dev    (쿼리당 10GB 제한)
-- 결과   : s3://<data-lake>/athena-results/analytics/
--
-- 테이블 구조 요약
--   service_events  (EKS Control Plane 로그)
--     파티션  : year, month, day, hour  (모두 string)
--     컬럼   : messagetype, owner, loggroup, logstream,
--             subscriptionfilters array<string>,
--             logevents array<struct<id:string, timestamp:bigint, message:string>>
--   resource_check (리소스 점검 결과)
--     파티션  : partition_0
--     컬럼   : checkedat string,
--             findings array<struct<checkType, resourceType, resourceId,
--                                   status, reason, sizeGb, missingTags>>
-- =============================================================================


-- =============================================================================
-- A. service_events 기본 통계
-- =============================================================================

-- A1. 총 적재된 로그 이벤트 수
SELECT COUNT(*) AS total_events
FROM service_events
CROSS JOIN UNNEST(logevents) AS t(ev);

-- A2. 시간대별 로그 양 (hour 파티션 활용 - 파티션 프루닝되어 빠름)
SELECT hour,
       COUNT(*) AS event_count
FROM service_events
CROSS JOIN UNNEST(logevents) AS t(ev)
GROUP BY hour
ORDER BY hour;

-- A3. 일자별 누적 로그 (최근 7일)
SELECT year || '-' || month || '-' || day AS date,
       COUNT(*) AS event_count
FROM service_events
CROSS JOIN UNNEST(logevents) AS t(ev)
GROUP BY year, month, day
ORDER BY year DESC, month DESC, day DESC
LIMIT 7;

-- A4. messageType 분포 (DATA_MESSAGE / CONTROL_MESSAGE 비중)
SELECT messagetype,
       COUNT(*) AS leaf_records
FROM service_events
GROUP BY messagetype
ORDER BY leaf_records DESC;


-- =============================================================================
-- B. 로그 메시지 키워드 분석
-- =============================================================================

-- B1. 에러/경고 키워드 카운트 (ERROR / Warning / failed / exception)
SELECT
  SUM(CASE WHEN regexp_like(ev.message, '(?i)error')     THEN 1 ELSE 0 END) AS error_count,
  SUM(CASE WHEN regexp_like(ev.message, '(?i)warning')   THEN 1 ELSE 0 END) AS warning_count,
  SUM(CASE WHEN regexp_like(ev.message, '(?i)failed')    THEN 1 ELSE 0 END) AS failed_count,
  SUM(CASE WHEN regexp_like(ev.message, '(?i)exception') THEN 1 ELSE 0 END) AS exception_count,
  COUNT(*)                                                                  AS total_messages
FROM service_events
CROSS JOIN UNNEST(logevents) AS t(ev);

-- B2. 로그 스트림별 분포 (어떤 컴포넌트가 로그를 가장 많이 내는가)
SELECT logstream,
       COUNT(*) AS msg_count
FROM service_events
CROSS JOIN UNNEST(logevents) AS t(ev)
GROUP BY logstream
ORDER BY msg_count DESC
LIMIT 10;

-- B3. 최근 1시간 에러 메시지 샘플 (운영 점검용)
SELECT
  from_unixtime(ev.timestamp / 1000) AS event_time,
  logstream,
  substr(ev.message, 1, 200) AS message_preview
FROM service_events
CROSS JOIN UNNEST(logevents) AS t(ev)
WHERE regexp_like(ev.message, '(?i)error|failed|exception')
ORDER BY ev.timestamp DESC
LIMIT 10;

-- B4. 시간대(hour) × 에러 발생 결합 (어느 시간에 에러 몰림)
SELECT hour,
       SUM(CASE WHEN regexp_like(ev.message, '(?i)error|failed|exception')
                THEN 1 ELSE 0 END) AS error_count,
       COUNT(*)                    AS total_in_hour
FROM service_events
CROSS JOIN UNNEST(logevents) AS t(ev)
GROUP BY hour
ORDER BY error_count DESC
LIMIT 10;


-- =============================================================================
-- C. resource_check 분석 (FinOps)
-- =============================================================================

-- C1. checkType별 카운트 (어떤 점검에서 가장 많이 걸렸나)
SELECT f.checkType    AS check_type,
       COUNT(*)       AS finding_count
FROM resource_check r
CROSS JOIN UNNEST(r.findings) AS t(f)
GROUP BY f.checkType
ORDER BY finding_count DESC;

-- C2. resourceType별 카운트 (EC2 / EBS / RDS / 등 어느 자원에 이슈 많은가)
SELECT f.resourceType AS resource_type,
       COUNT(*)       AS finding_count
FROM resource_check r
CROSS JOIN UNNEST(r.findings) AS t(f)
GROUP BY f.resourceType
ORDER BY finding_count DESC;

-- C3. 태그 누락 상위 — 어떤 태그가 가장 많이 빠졌나
SELECT missing_tag,
       COUNT(*) AS miss_count
FROM resource_check r
CROSS JOIN UNNEST(r.findings) AS t(f)
CROSS JOIN UNNEST(f.missingTags) AS t2(missing_tag)
WHERE f.checkType = 'MISSING_TAGS'
GROUP BY missing_tag
ORDER BY miss_count DESC;

-- C4. 미사용 리소스의 낭비되는 용량 합계 (EBS GB 기준)
SELECT f.resourceType AS resource_type,
       COUNT(*)                            AS count,
       COALESCE(SUM(f.sizeGb), 0)          AS total_wasted_gb
FROM resource_check r
CROSS JOIN UNNEST(r.findings) AS t(f)
WHERE f.checkType = 'UNUSED_RESOURCE'
GROUP BY f.resourceType
ORDER BY total_wasted_gb DESC;


-- =============================================================================
-- D. 결합·이상 탐지
-- =============================================================================

-- D1. 시간대별 로그 양 (피크 탐지용)
SELECT year, month, day, hour,
       COUNT(*) AS events_per_hour
FROM service_events
CROSS JOIN UNNEST(logevents) AS t(ev)
GROUP BY year, month, day, hour
ORDER BY events_per_hour DESC
LIMIT 10;

-- D2. 로그 스트림 + 에러율 (어느 노드/컴포넌트가 가장 불안정한가)
SELECT logstream,
       COUNT(*)                                                AS total,
       SUM(CASE WHEN regexp_like(ev.message, '(?i)error|failed|exception')
                THEN 1 ELSE 0 END)                              AS errors,
       ROUND(100.0 * SUM(CASE WHEN regexp_like(ev.message, '(?i)error|failed|exception')
                              THEN 1 ELSE 0 END) / COUNT(*), 2) AS error_pct
FROM service_events
CROSS JOIN UNNEST(logevents) AS t(ev)
GROUP BY logstream
HAVING COUNT(*) >= 10
ORDER BY error_pct DESC
LIMIT 10;

-- D3. 가장 최근 적재 데이터 5건 (헬스체크용)
SELECT messagetype, owner, year, month, day, hour, loggroup
FROM service_events
ORDER BY year DESC, month DESC, day DESC, hour DESC
LIMIT 5;
