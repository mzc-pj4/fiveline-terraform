"""
Dashboard API Lambda
- Function URL로 노출, 브라우저에서 직접 호출
- 4 endpoint: /summary, /resource-check, /query-athena, /chat
- CORS 헤더 포함 (S3 도메인에서 호출 가능)
"""

import json
import os
import time
from decimal import Decimal
from datetime import datetime, timezone

import boto3

DASHBOARD_TABLE  = os.environ["DASHBOARD_TABLE"]
CHECK_TABLE      = os.environ["CHECK_TABLE"]
ATHENA_DB        = os.environ["ATHENA_DB"]
ATHENA_OUTPUT    = os.environ["ATHENA_OUTPUT"]
LANGGRAPH_LAMBDA = os.environ["LANGGRAPH_LAMBDA"]

ddb     = boto3.resource("dynamodb")
athena  = boto3.client("athena")
lambda_ = boto3.client("lambda")

CORS_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
    "Content-Type": "application/json; charset=utf-8",
}


def _to_json(obj):
    if isinstance(obj, list):
        return [_to_json(x) for x in obj]
    if isinstance(obj, dict):
        return {k: _to_json(v) for k, v in obj.items()}
    if isinstance(obj, Decimal):
        return float(obj) if obj % 1 else int(obj)
    return obj


def _response(status, body):
    return {
        "statusCode": status,
        "headers": CORS_HEADERS,
        "body": json.dumps(body, ensure_ascii=False, default=str),
    }


# ── Endpoints ───────────────────────────────────────────────────────────────

def get_summary(query_params):
    date_str = (query_params or {}).get("date") or datetime.now(timezone.utc).strftime("%Y-%m-%d")
    resp = ddb.Table(DASHBOARD_TABLE).get_item(Key={"summaryDate": date_str})
    item = resp.get("Item")
    if not item:
        return _response(200, {"summaryDate": date_str, "found": False, "message": "해당 날짜 데이터 없음"})
    return _response(200, _to_json(item))


def get_resource_check(query_params):
    limit = int((query_params or {}).get("limit", "50"))
    items = ddb.Table(CHECK_TABLE).scan(Limit=limit).get("Items", [])
    by_type = {}
    for it in items:
        t = it.get("checkType", "UNKNOWN")
        by_type[t] = by_type.get(t, 0) + 1
    return _response(200, {
        "total": len(items),
        "byType": by_type,
        "items": _to_json(items),
    })


def query_athena_endpoint(body):
    sql = (body or {}).get("sql", "")
    sql_lower = sql.lower().strip()
    if not sql_lower.startswith("select"):
        return _response(400, {"error": "SELECT 쿼리만 허용"})
    if any(kw in sql_lower for kw in ["drop", "delete", "update", "insert", "alter"]):
        return _response(400, {"error": "데이터 변경 쿼리 금지"})

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
            return _response(500, {"error": info["QueryExecution"]["Status"].get("StateChangeReason", state)})
        time.sleep(1)
    else:
        return _response(504, {"error": "쿼리 시간 초과 (30초)"})

    rows = athena.get_query_results(QueryExecutionId=qid, MaxResults=50)["ResultSet"]["Rows"]
    if not rows:
        return _response(200, {"rows": []})
    headers = [c.get("VarCharValue", "") for c in rows[0]["Data"]]
    data = [dict(zip(headers, [c.get("VarCharValue", "") for c in r["Data"]])) for r in rows[1:]]
    return _response(200, {"rowCount": len(data), "rows": data, "headers": headers})


def chat_endpoint(body):
    """LangGraph Lambda 호출 → 자연어 답변 (멀티턴 session_id 지원)"""
    user_input = (body or {}).get("input", "")
    session_id = (body or {}).get("session_id", "")
    if not user_input:
        return _response(400, {"error": "input 필수"})

    payload = {"input": user_input}
    if session_id:
        payload["session_id"] = session_id

    resp = lambda_.invoke(
        FunctionName=LANGGRAPH_LAMBDA,
        InvocationType="RequestResponse",
        Payload=json.dumps(payload).encode("utf-8"),
    )
    result = json.loads(resp["Payload"].read())
    return _response(200, result)


# ── Router ──────────────────────────────────────────────────────────────────

def handler(event, context):
    # Function URL 이벤트 형식
    http = event.get("requestContext", {}).get("http", {})
    method = http.get("method", "GET")
    path = event.get("rawPath", "/")
    query_params = event.get("queryStringParameters") or {}

    # CORS preflight
    if method == "OPTIONS":
        return {"statusCode": 200, "headers": CORS_HEADERS, "body": ""}

    # Body 파싱 (API Gateway HTTP API v2 = base64 가능, Function URL = raw)
    body = {}
    raw_body = event.get("body")
    if raw_body:
        try:
            # base64 인코딩 감지 → 디코드
            if event.get("isBase64Encoded"):
                import base64
                raw_body = base64.b64decode(raw_body).decode("utf-8")
            # UTF-8 BOM 제거
            if raw_body.startswith("﻿"):
                raw_body = raw_body[1:]
            body = json.loads(raw_body)
        except Exception as e:
            return _response(400, {
                "error": "JSON body 파싱 실패",
                "detail": str(e),
                "rawBodyPreview": str(raw_body)[:200],
                "isBase64Encoded": event.get("isBase64Encoded", False),
            })

    try:
        if path == "/" or path == "":
            return _response(200, {
                "service": "dashboard-api",
                "endpoints": ["/summary", "/resource-check", "/query-athena", "/chat"],
            })
        elif path == "/summary" and method == "GET":
            return get_summary(query_params)
        elif path == "/resource-check" and method == "GET":
            return get_resource_check(query_params)
        elif path == "/query-athena" and method == "POST":
            return query_athena_endpoint(body)
        elif path == "/chat" and method == "POST":
            return chat_endpoint(body)
        else:
            return _response(404, {"error": f"Unknown route: {method} {path}"})
    except Exception as e:
        return _response(500, {"error": str(e), "errorType": type(e).__name__})
