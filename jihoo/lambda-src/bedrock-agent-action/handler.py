"""
Bedrock Agent Action Lambda
- 4 Action 처리: get_dashboard_summary, get_resource_check, get_recent_alarms, query_athena
- Bedrock Agent 형식과 직접 호출(테스트) 형식 둘 다 지원
"""

import json
import os
import time
from decimal import Decimal
from datetime import datetime, timezone

import boto3

DASHBOARD_TABLE = os.environ["DASHBOARD_TABLE"]
CHECK_TABLE     = os.environ["CHECK_TABLE"]
ALARM_TABLE     = os.environ.get("ALARM_TABLE", "")
ATHENA_DB       = os.environ["ATHENA_DB"]
ATHENA_OUTPUT   = os.environ["ATHENA_OUTPUT"]

ddb    = boto3.resource("dynamodb")
athena = boto3.client("athena")

def _to_json(obj):
    if isinstance(obj, list):
        return [_to_json(x) for x in obj]
    if isinstance(obj, dict):
        return {k: _to_json(v) for k, v in obj.items()}
    if isinstance(obj, Decimal):
        return float(obj) if obj % 1 else int(obj)
    return obj

def _get_param(params, name, default=None):
    for p in params or []:
        if p.get("name") == name:
            return p.get("value", default)
    return default

# ── Actions ─────────────────────────────────────────────────────────────────

def get_dashboard_summary(params):
    date_str = _get_param(params, "date") or datetime.now(timezone.utc).strftime("%Y-%m-%d")
    resp = ddb.Table(DASHBOARD_TABLE).get_item(Key={"summaryDate": date_str})
    item = resp.get("Item")
    if not item:
        return {"summaryDate": date_str, "found": False, "message": "해당 날짜 데이터 없음"}
    return _to_json(item)

def get_resource_check(params):
    limit = int(_get_param(params, "limit", "20"))
    items = ddb.Table(CHECK_TABLE).scan(Limit=limit).get("Items", [])
    by_type = {}
    for it in items:
        t = it.get("checkType", "UNKNOWN")
        by_type[t] = by_type.get(t, 0) + 1
    return {
        "total": len(items),
        "byType": by_type,
        "items": _to_json(items[:5]),
    }

def get_recent_alarms(params):
    if not ALARM_TABLE:
        return {"alarms": [], "message": "alarm_history 테이블 미존재 (모니터링 #3 영역)"}
    try:
        limit = int(_get_param(params, "limit", "10"))
        items = ddb.Table(ALARM_TABLE).scan(Limit=limit).get("Items", [])
        return {"alarms": _to_json(items)}
    except Exception as e:
        return {"alarms": [], "error": str(e)}

def query_athena(params):
    sql = _get_param(params, "sql", "")
    sql_lower = sql.lower().strip()
    if not sql_lower.startswith("select"):
        return {"error": "SELECT 쿼리만 허용"}
    if any(kw in sql_lower for kw in ["drop", "delete", "update", "insert", "alter"]):
        return {"error": "데이터 변경 쿼리 금지"}

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
            return {"error": info["QueryExecution"]["Status"].get("StateChangeReason", state)}
        time.sleep(1)
    else:
        return {"error": "쿼리 시간 초과"}

    rows = athena.get_query_results(QueryExecutionId=qid, MaxResults=10)["ResultSet"]["Rows"]
    if not rows:
        return {"rows": []}
    headers = [c.get("VarCharValue", "") for c in rows[0]["Data"]]
    data = [dict(zip(headers, [c.get("VarCharValue", "") for c in r["Data"]])) for r in rows[1:]]
    return {"rowCount": len(data), "rows": data}

ACTIONS = {
    "get_dashboard_summary": get_dashboard_summary,
    "get_resource_check":    get_resource_check,
    "get_recent_alarms":     get_recent_alarms,
    "query_athena":          query_athena,
}

# ── Handler ─────────────────────────────────────────────────────────────────

def handler(event, context):
    function_name = event.get("function", "")
    parameters    = event.get("parameters", [])

    if function_name not in ACTIONS:
        result = {"error": f"Unknown function: {function_name}", "available": list(ACTIONS.keys())}
    else:
        try:
            result = ACTIONS[function_name](parameters)
        except Exception as e:
            result = {"error": str(e)}

    # Bedrock Agent 형식 응답
    if "messageVersion" in event:
        return {
            "messageVersion": "1.0",
            "response": {
                "actionGroup": event.get("actionGroup", ""),
                "function": function_name,
                "functionResponse": {
                    "responseBody": {
                        "TEXT": {"body": json.dumps(result, ensure_ascii=False)}
                    }
                }
            }
        }

    # 직접 호출 (테스트용)
    return result
