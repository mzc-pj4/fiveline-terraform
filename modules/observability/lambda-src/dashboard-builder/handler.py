"""
Dashboard Builder Lambda
- EventBridge가 5분마다 호출 (혹은 수동 invoke)
- 4가지 데이터 수집: 오늘 요약, 리소스 점검, Athena 쿼리, 채팅 샘플
- JSON으로 묶어서 S3에 업로드 → 브라우저가 직접 fetch
"""

import json
import os
import time
from decimal import Decimal
from datetime import datetime, timezone, timedelta

import boto3

DASHBOARD_TABLE   = os.environ["DASHBOARD_TABLE"]
CHECK_TABLE       = os.environ["CHECK_TABLE"]
REPORT_TABLE      = os.environ.get("REPORT_TABLE", "mzc-pj4-jihoo-report-metadata-dev")
MONITORING_TABLE  = os.environ.get("MONITORING_DASHBOARD_TABLE", "dashboard_summary")
MONITORING_SVC    = os.environ.get("MONITORING_SERVICE_KEY", "ecommerce")
ATHENA_DB         = os.environ["ATHENA_DB"]
ATHENA_OUTPUT     = os.environ["ATHENA_OUTPUT"]
BUCKET            = os.environ["BUCKET_NAME"]
JSON_KEY          = os.environ.get("JSON_KEY", "data.json")

ddb    = boto3.resource("dynamodb")
athena = boto3.client("athena")
s3     = boto3.client("s3")


def _to_json(obj):
    if isinstance(obj, list):
        return [_to_json(x) for x in obj]
    if isinstance(obj, dict):
        return {k: _to_json(v) for k, v in obj.items()}
    if isinstance(obj, Decimal):
        return float(obj) if obj % 1 else int(obj)
    if hasattr(obj, "isoformat"):
        return obj.isoformat()
    return obj


def get_summary_today():
    """오늘 데이터 없으면 최근 7일 중 가장 최신. 모니터링#3 테이블 값이 있으면 카드에 우선 표시."""
    base = {"found": False, "message": "최근 7일 내 데이터 없음"}
    for delta in range(7):
        date_str = (datetime.now(timezone.utc) - timedelta(days=delta)).strftime("%Y-%m-%d")
        resp = ddb.Table(DASHBOARD_TABLE).get_item(Key={"summaryDate": date_str})
        item = resp.get("Item")
        if item:
            base = _to_json(item)
            break

    # 모니터링 #3의 dashboard_summary (service+date PK) merge
    mon = get_monitoring_summary()
    if mon:
        base["operatorMetrics"] = mon          # 운영 카드용 (총주문 / 실패율 / 응답 / 알람)
        base["operatorMetricsSource"] = "monitoring-team"
    else:
        base["operatorMetrics"] = None
        base["operatorMetricsSource"] = "none"
    return base


def get_monitoring_summary():
    """모니터링#3의 dashboard_summary 조회 (service=ecommerce, date=오늘~어제). 없으면 None."""
    try:
        for delta in range(2):  # 오늘 → 어제까지
            date_str = (datetime.now(timezone.utc) - timedelta(days=delta)).strftime("%Y-%m-%d")
            resp = ddb.Table(MONITORING_TABLE).get_item(
                Key={"service": MONITORING_SVC, "date": date_str}
            )
            item = resp.get("Item")
            if item:
                return _to_json(item)
        return None
    except Exception as e:
        return {"_error": str(e)}


def get_resource_check():
    items = ddb.Table(CHECK_TABLE).scan(Limit=50).get("Items", [])
    by_type = {}
    for it in items:
        t = it.get("checkType", "UNKNOWN")
        by_type[t] = by_type.get(t, 0) + 1
    return {
        "total": len(items),
        "byType": by_type,
        "items": _to_json(items),
    }


def run_athena_query(label, sql):
    try:
        resp = athena.start_query_execution(
            QueryString=sql,
            QueryExecutionContext={"Database": ATHENA_DB},
            ResultConfiguration={"OutputLocation": ATHENA_OUTPUT},
        )
        qid = resp["QueryExecutionId"]
        for _ in range(30):
            info = athena.get_query_execution(QueryExecutionId=qid)
            state = info["QueryExecution"]["Status"]["State"]
            if state == "SUCCEEDED":
                break
            if state in ("FAILED", "CANCELLED"):
                return {"label": label, "sql": sql, "error": state}
            time.sleep(1)
        else:
            return {"label": label, "sql": sql, "error": "timeout"}

        rows = athena.get_query_results(QueryExecutionId=qid, MaxResults=20)["ResultSet"]["Rows"]
        if not rows:
            return {"label": label, "sql": sql, "rows": []}
        headers = [c.get("VarCharValue", "") for c in rows[0]["Data"]]
        data = [dict(zip(headers, [c.get("VarCharValue", "") for c in r["Data"]])) for r in rows[1:]]
        return {"label": label, "sql": sql, "headers": headers, "rows": data, "rowCount": len(data)}
    except Exception as e:
        return {"label": label, "sql": sql, "error": str(e)}


def get_athena_queries():
    """발표용 분석 쿼리 (events_hourly / resource_findings_daily 집계 테이블 활용)"""
    queries = [
        ("총 로그 이벤트 + 에러 합계",
         "SELECT SUM(total_events) total, SUM(error_count) errors, "
         "ROUND(100.0*SUM(error_count)/SUM(total_events), 2) error_pct "
         "FROM events_hourly"),
        ("스트림별 에러율 TOP 5",
         "SELECT logstream, total_events, error_count, error_pct "
         "FROM events_hourly WHERE total_events>=100 "
         "ORDER BY error_pct DESC LIMIT 5"),
        ("리소스 점검 타입별",
         "SELECT checktype, SUM(finding_count) cnt FROM resource_findings_daily "
         "GROUP BY checktype ORDER BY cnt DESC"),
        ("리소스 타입별",
         "SELECT resourcetype, SUM(finding_count) cnt FROM resource_findings_daily "
         "GROUP BY resourcetype ORDER BY cnt DESC"),
    ]
    return [run_athena_query(label, sql) for label, sql in queries]


def get_hourly_chart():
    """시간대별 로그·에러 추이 (차트용)"""
    sql = (
        "SELECT year, month, day, hour, "
        "SUM(total_events) total, SUM(error_count) errors "
        "FROM events_hourly "
        "GROUP BY year, month, day, hour "
        "ORDER BY year, month, day, hour"
    )
    result = run_athena_query("hourly_chart", sql)
    rows = result.get("rows", [])
    # 차트용 labels / datasets
    labels = [
        f"{r['year']}-{r['month'].zfill(2)}-{r['day'].zfill(2)} {r['hour'].zfill(2)}h"
        for r in rows
    ]
    return {
        "labels":      labels,
        "totals":      [int(r["total"] or 0) for r in rows],
        "errors":      [int(r["errors"] or 0) for r in rows],
        "rowCount":    len(rows),
    }


def get_report_list():
    """report_metadata에서 최근 10건 리포트"""
    try:
        items = ddb.Table(REPORT_TABLE).scan(Limit=50).get("Items", [])
        # createdAt 기준 내림차순 정렬
        items.sort(key=lambda x: x.get("createdAt", ""), reverse=True)
        items = items[:10]
        return [
            {
                "reportDate":    it.get("reportDate", ""),
                "createdAt":     it.get("createdAt", ""),
                "title":         it.get("title", ""),
                "reportType":    it.get("reportType", ""),
                "s3Url":         it.get("s3Url", ""),
                "summaryPreview": (it.get("summaryPreview", "") or "")[:200],
            }
            for it in items
        ]
    except Exception as e:
        return [{"error": str(e)}]


def get_sample_chat():
    """발표용 미리 정한 Q&A 샘플 (LangGraph 실제 호출 결과 캐시 가능)"""
    return [
        {
            "question": "오늘 미사용 리소스 알려줘",
            "answer": "현재 확인된 미사용 및 태그 누락 리소스: EBS 1건, EC2 2건 태그 누락, EBS 2건 태그 누락 등 총 5건입니다.",
        },
        {
            "question": "service_events 테이블 로그 몇 건이야?",
            "answer": "service_events 테이블에 적재된 EKS Control Plane 로그가 약 1,400건 이상입니다 (60초마다 자동 적재 중).",
        },
        {
            "question": "어제 운영 상황 어땠어?",
            "answer": "어제(2026-06-02) 운영 요약: 총 주문 1,247건, 실패율 3.9% (49건 실패), 평균 응답 850ms, P99 2.4초, DB_TIMEOUT 다발.",
        },
    ]


def handler(event, context):
    data = {
        "generatedAt":   datetime.now(timezone.utc).isoformat(),
        "chatApiBase":   os.environ.get("CHAT_API_BASE", ""),  # 브라우저 챗봇이 사용할 API URL
        "summary":       get_summary_today(),
        "resourceCheck": get_resource_check(),
        "hourlyChart":   get_hourly_chart(),
        "reports":       get_report_list(),
        "athenaQueries": get_athena_queries(),
        "chatSamples":   get_sample_chat(),
    }

    s3.put_object(
        Bucket=BUCKET,
        Key=JSON_KEY,
        Body=json.dumps(data, ensure_ascii=False, default=str).encode("utf-8"),
        ContentType="application/json; charset=utf-8",
        CacheControl="max-age=60",
    )

    return {
        "ok": True,
        "key": JSON_KEY,
        "generatedAt": data["generatedAt"],
        "summary_found": data["summary"].get("found", True),
        "resource_count": data["resourceCheck"]["total"],
        "athena_queries": len(data["athenaQueries"]),
    }
