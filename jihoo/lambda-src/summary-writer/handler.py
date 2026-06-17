"""
Summary Writer Lambda (V2)
- 새로 만든 aggregated 테이블(events_hourly, resource_findings_daily)을 활용
- Athena 집계 결과를 DynamoDB dashboard_summary에 풍부하게 저장
- 호출: 수동 (test) 또는 EventBridge (일간)
"""

import os
import time
from datetime import datetime, timezone
from decimal import Decimal

import boto3

ATHENA_DB     = os.environ["ATHENA_DB"]
ATHENA_OUTPUT = os.environ["ATHENA_OUTPUT"]
TABLE_NAME    = os.environ["TABLE_NAME"]

athena = boto3.client("athena")
ddb    = boto3.resource("dynamodb").Table(TABLE_NAME)


# ─── Athena 헬퍼 ────────────────────────────────────────────────────────────

def run_athena(sql, timeout_sec=60):
    resp = athena.start_query_execution(
        QueryString=sql,
        QueryExecutionContext={"Database": ATHENA_DB},
        ResultConfiguration={"OutputLocation": ATHENA_OUTPUT},
    )
    qid = resp["QueryExecutionId"]
    for _ in range(timeout_sec):
        info = athena.get_query_execution(QueryExecutionId=qid)
        st = info["QueryExecution"]["Status"]["State"]
        if st == "SUCCEEDED":
            break
        if st in ("FAILED", "CANCELLED"):
            reason = info["QueryExecution"]["Status"].get("StateChangeReason", "")
            raise Exception(f"Athena {st}: {reason}\nSQL: {sql}")
        time.sleep(1)
    else:
        raise Exception(f"Athena timeout: {sql}")

    rows = athena.get_query_results(QueryExecutionId=qid)["ResultSet"]["Rows"]
    if not rows:
        return [], []
    headers = [c.get("VarCharValue", "") for c in rows[0]["Data"]]
    data = [
        {headers[i]: c.get("VarCharValue", "") for i, c in enumerate(r["Data"])}
        for r in rows[1:]
    ]
    return headers, data


def D(v):
    """Decimal 변환 (DynamoDB Number 타입 호환)"""
    if v is None or v == "":
        return Decimal("0")
    try:
        return Decimal(str(v))
    except Exception:
        return Decimal("0")


# ─── 집계 쿼리들 ───────────────────────────────────────────────────────────

def collect_event_stats():
    """events_hourly로 로그·에러 통계 집계"""
    _, rows = run_athena("""
        SELECT
            SUM(total_events)   AS total_events,
            SUM(error_count)    AS total_errors,
            SUM(warning_count)  AS total_warnings
        FROM events_hourly
    """)
    if not rows:
        return {"totalLogEvents": 0, "totalErrors": 0, "totalWarnings": 0, "errorRate": 0}

    r = rows[0]
    total  = int(r["total_events"]   or 0)
    errors = int(r["total_errors"]   or 0)
    warns  = int(r["total_warnings"] or 0)
    rate   = round(100.0 * errors / total, 2) if total > 0 else 0

    return {
        "totalLogEvents": total,
        "totalErrors":    errors,
        "totalWarnings":  warns,
        "errorRate":      rate,
    }


def collect_peak_hour():
    """가장 로그가 많이 몰린 시간대"""
    _, rows = run_athena("""
        SELECT year, month, day, hour, SUM(total_events) AS events
        FROM events_hourly
        GROUP BY year, month, day, hour
        ORDER BY events DESC
        LIMIT 1
    """)
    if not rows:
        return {"peakHour": None, "peakHourEvents": 0}
    r = rows[0]
    label = f"{r['year']}-{r['month'].zfill(2)}-{r['day'].zfill(2)} {r['hour'].zfill(2)}:00"
    return {"peakHour": label, "peakHourEvents": int(r["events"])}


def collect_top_error_stream():
    """에러율 가장 높은 스트림 (충분히 큰 표본만)"""
    _, rows = run_athena("""
        SELECT logstream, total_events, error_count, error_pct
        FROM events_hourly
        WHERE total_events >= 100
        ORDER BY error_pct DESC
        LIMIT 1
    """)
    if not rows:
        return {"topErrorStream": None, "topErrorPct": 0}
    r = rows[0]
    return {
        "topErrorStream": r["logstream"],
        "topErrorPct":    float(r["error_pct"] or 0),
    }


def collect_findings():
    """resource_findings_daily — 점검 통계"""
    _, by_check = run_athena("""
        SELECT checktype, SUM(finding_count) AS cnt
        FROM resource_findings_daily
        GROUP BY checktype
    """)
    _, by_resource = run_athena("""
        SELECT resourcetype, SUM(finding_count) AS cnt
        FROM resource_findings_daily
        GROUP BY resourcetype
    """)

    by_check_map    = {r["checktype"]:    int(r["cnt"]) for r in by_check}
    by_resource_map = {r["resourcetype"]: int(r["cnt"]) for r in by_resource}
    total = sum(by_check_map.values())

    return {
        "totalFindings":          total,
        "findingsByCheckType":    by_check_map,
        "findingsByResourceType": by_resource_map,
    }


# ─── 메인 ──────────────────────────────────────────────────────────────────

def handler(event, context):
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    now   = datetime.now(timezone.utc).isoformat()

    event_stats   = collect_event_stats()
    peak          = collect_peak_hour()
    top_error     = collect_top_error_stream()
    findings      = collect_findings()

    item = {
        "summaryDate":            today,
        "updatedAt":              now,
        # — 로그 분석
        "totalLogEvents":         D(event_stats["totalLogEvents"]),
        "totalErrors":            D(event_stats["totalErrors"]),
        "totalWarnings":          D(event_stats["totalWarnings"]),
        "errorRate":              D(event_stats["errorRate"]),
        "peakHour":               peak["peakHour"] or "N/A",
        "peakHourEvents":         D(peak["peakHourEvents"]),
        "topErrorStream":         top_error["topErrorStream"] or "N/A",
        "topErrorPct":            D(top_error["topErrorPct"]),
        # — 리소스 점검
        "totalFindings":          D(findings["totalFindings"]),
        "findingsByCheckType":    {k: D(v) for k, v in findings["findingsByCheckType"].items()},
        "findingsByResourceType": {k: D(v) for k, v in findings["findingsByResourceType"].items()},
    }

    ddb.put_item(Item=item)

    # 반환은 사람 친화 형태 (Decimal 제거)
    return {
        "summaryDate":            today,
        "totalLogEvents":         event_stats["totalLogEvents"],
        "totalErrors":            event_stats["totalErrors"],
        "errorRate":              event_stats["errorRate"],
        "peakHour":               peak["peakHour"],
        "topErrorStream":         top_error["topErrorStream"],
        "topErrorPct":            top_error["topErrorPct"],
        "totalFindings":          findings["totalFindings"],
        "findingsByCheckType":    findings["findingsByCheckType"],
        "findingsByResourceType": findings["findingsByResourceType"],
    }
