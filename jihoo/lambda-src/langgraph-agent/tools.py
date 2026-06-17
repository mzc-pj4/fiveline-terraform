"""
LangGraph Agent Tools — DynamoDB·Athena 접근 도구 + 경량 RAG (search_reports)
LangChain @tool 데코레이터로 정의 → graph.py에서 bind_tools로 LLM에 연결
"""

import json
import math
import os
import time
from decimal import Decimal
from datetime import datetime, timezone
from typing import Optional

import boto3
from langchain_core.tools import tool

DASHBOARD_TABLE = os.environ["DASHBOARD_TABLE"]
CHECK_TABLE     = os.environ["CHECK_TABLE"]
ALARM_TABLE     = os.environ.get("ALARM_TABLE", "")
ATHENA_DB       = os.environ["ATHENA_DB"]
ATHENA_OUTPUT   = os.environ["ATHENA_OUTPUT"]
EMBED_TABLE     = os.environ.get("EMBED_TABLE", "")
EMBED_MODEL     = os.environ.get("EMBED_MODEL", "amazon.titan-embed-text-v2:0")

ddb     = boto3.resource("dynamodb")
athena  = boto3.client("athena")
bedrock = boto3.client("bedrock-runtime")


def _to_json(obj):
    if isinstance(obj, list):
        return [_to_json(x) for x in obj]
    if isinstance(obj, dict):
        return {k: _to_json(v) for k, v in obj.items()}
    if isinstance(obj, Decimal):
        return float(obj) if obj % 1 else int(obj)
    return obj


@tool
def get_dashboard_summary(date: Optional[str] = None) -> str:
    """특정 날짜의 일간 운영 대시보드 요약 조회.
    총 주문 수, 성공/실패율, 평균/p99 응답시간, 활성 알람 수 등을 반환.

    Args:
        date: 조회 날짜 YYYY-MM-DD 형식. 생략 시 오늘.
    """
    if not date:
        date = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    resp = ddb.Table(DASHBOARD_TABLE).get_item(Key={"summaryDate": date})
    item = resp.get("Item")
    if not item:
        return json.dumps({"summaryDate": date, "found": False, "message": "해당 날짜 데이터 없음"})
    return json.dumps(_to_json(item), ensure_ascii=False)


@tool
def get_resource_check(limit: int = 20) -> str:
    """미사용 리소스(EBS·EIP·Snapshot), 태그 누락, 보안 위반(SG 0.0.0.0/0, RDS Public) 점검 결과 조회.

    Args:
        limit: 조회할 항목 수 (기본 20).
    """
    items = ddb.Table(CHECK_TABLE).scan(Limit=int(limit)).get("Items", [])
    by_type = {}
    for it in items:
        t = it.get("checkType", "UNKNOWN")
        by_type[t] = by_type.get(t, 0) + 1
    return json.dumps({
        "total": len(items),
        "byType": by_type,
        "items": _to_json(items[:5]),
    }, ensure_ascii=False)


@tool
def get_recent_alarms(limit: int = 10) -> str:
    """최근 발생한 CloudWatch 알람 이력 조회. 모니터링 담당자가 만든 테이블 사용.

    Args:
        limit: 조회할 알람 수 (기본 10).
    """
    if not ALARM_TABLE:
        return json.dumps({"alarms": [], "message": "alarm_history 테이블 미존재 (모니터링 담당 영역)"})
    items = ddb.Table(ALARM_TABLE).scan(Limit=int(limit)).get("Items", [])
    return json.dumps({"alarms": _to_json(items)}, ensure_ascii=False)


@tool
def query_athena(sql: str) -> str:
    """Athena SQL 쿼리 실행. SELECT만 허용, DML(INSERT/UPDATE/DELETE/DROP) 금지.

    # 사용 가능한 테이블 + 컬럼 (이거 외 추측 금지)

    ## service_events (EKS·앱 Pod 원시 로그)
      파티션: year, month, day, hour   (모두 string)
      컬럼:   messagetype string, owner string, loggroup string, logstream string,
              logevents array<struct<id:string, timestamp:bigint, message:string>>
      예) SELECT COUNT(*) FROM service_events
              CROSS JOIN UNNEST(logevents) AS t(ev)

    ## events_hourly (시간×스트림 집계, aggregated)
      파티션: year, month, day  (string)
      컬럼:   hour int, logstream string,
              total_events bigint, error_count bigint, warning_count bigint,
              error_pct double
      예) SELECT logstream, error_pct FROM events_hourly
            WHERE total_events >= 100 ORDER BY error_pct DESC LIMIT 5

    ## resource_findings_daily (일별 점검 집계)
      파티션: year, month, day  (string)
      컬럼:   checktype string, resourcetype string, finding_count bigint

    ## cw_metrics (ALB·RDS CloudWatch 메트릭)
      파티션: year, month, day, hour  (string)
      컬럼:   collectedat string, starttime string, endtime string,
              metrics array<struct<id:string, label:string,
                                   values:array<struct<t:string, v:double>>>>
      예) SELECT collectedat, metrics FROM cw_metrics
            ORDER BY collectedat DESC LIMIT 1

    ## resource_check (리소스 점검 원본)
      파티션: partition_0
      컬럼:   checkedat string,
              findings array<struct<checkType, resourceType, resourceId,
                                    status, reason, sizeGb, missingTags>>

    Args:
        sql: 실행할 SELECT SQL 쿼리. 위 스키마만 사용.
    """
    sql_lower = sql.lower().strip()
    if not sql_lower.startswith("select"):
        return json.dumps({"error": "SELECT 쿼리만 허용"})
    if any(kw in sql_lower for kw in ["drop", "delete", "update", "insert", "alter"]):
        return json.dumps({"error": "데이터 변경 쿼리 금지"})

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
            return json.dumps({"error": info["QueryExecution"]["Status"].get("StateChangeReason", state)})
        time.sleep(1)
    else:
        return json.dumps({"error": "쿼리 시간 초과 (30초)"})

    rows = athena.get_query_results(QueryExecutionId=qid, MaxResults=10)["ResultSet"]["Rows"]
    if not rows:
        return json.dumps({"rows": []})
    headers = [c.get("VarCharValue", "") for c in rows[0]["Data"]]
    data = [dict(zip(headers, [c.get("VarCharValue", "") for c in r["Data"]])) for r in rows[1:]]
    return json.dumps({"rowCount": len(data), "rows": data}, ensure_ascii=False)


@tool
def get_metrics(minutes: int = 15) -> str:
    """최근 N분간의 인프라 메트릭 조회 (ALB 요청수·5xx·응답시간 / RDS CPU·연결수·복제지연).
    cw_metrics 테이블에서 시간 정렬 내림차순으로 가장 최근 데이터 1건 반환.
    RDS는 primary + replica-a + replica-c 분리되어 있음.

    Args:
        minutes: 조회 윈도우(분). 기본 15분 (사용 안 함, 메트릭 수집 주기 5분 기반 최신 1건).
    """
    sql = (
        "SELECT collectedat, metrics FROM cw_metrics "
        "ORDER BY collectedat DESC LIMIT 1"
    )
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
                return json.dumps({"error": state})
            time.sleep(1)
        rows = athena.get_query_results(QueryExecutionId=qid)["ResultSet"]["Rows"]
        if len(rows) < 2:
            return json.dumps({"metrics": [], "message": "데이터 없음"})
        # rows[1] = 첫 결과. metrics 컬럼이 JSON 문자열
        data_cols = [c.get("VarCharValue", "") for c in rows[1]["Data"]]
        return json.dumps({
            "collectedAt":   data_cols[0],
            "metricsRaw":    data_cols[1][:1500],  # 너무 길면 컷
        }, ensure_ascii=False)
    except Exception as e:
        return json.dumps({"error": str(e)})


@tool
def search_reports(question: str, top_k: int = 3) -> str:
    """과거 일간 운영 리포트(마크다운)를 의미 기반(RAG)으로 검색.
    "지난주 RDS 지연 언급 있었어?", "최근 트래픽 이상 패턴 보고서?" 같은
    과거 시점·트렌드 질문에 사용.

    동작: 질문을 Bedrock Titan Embed v2로 1024차원 벡터화 → DDB report_embeddings
    스캔 → 코사인 유사도 Top-K 리포트 반환 (각 미리보기 1500자).

    Args:
        question: 검색 질의 (자연어 한국어/영어).
        top_k: 반환할 리포트 수 (기본 3, 최대 5).
    """
    if not EMBED_TABLE:
        return json.dumps({"error": "report_embeddings 테이블 미설정"})

    top_k = max(1, min(int(top_k), 5))

    # 1) 질문 임베딩
    try:
        resp = bedrock.invoke_model(
            modelId=EMBED_MODEL,
            body=json.dumps({"inputText": question, "dimensions": 1024, "normalize": True}),
        )
        q_vec = json.loads(resp["body"].read())["embedding"]
    except Exception as e:
        return json.dumps({"error": f"임베딩 실패: {e}"})

    # 2) DDB Scan (소규모 — 30~100건 가정)
    items = []
    last_key = None
    while True:
        kwargs = {}
        if last_key:
            kwargs["ExclusiveStartKey"] = last_key
        resp = ddb.Table(EMBED_TABLE).scan(**kwargs)
        items.extend(resp.get("Items", []))
        last_key = resp.get("LastEvaluatedKey")
        if not last_key:
            break

    if not items:
        return json.dumps({"results": [], "message": "임베딩된 리포트 없음 (Embedder Lambda 미실행)"})

    # 3) 코사인 유사도 (normalize=True라 내적 = 코사인)
    def cos(a, b):
        return sum(float(x) * float(y) for x, y in zip(a, b))

    scored = []
    for it in items:
        emb = it.get("embedding") or []
        if not emb:
            continue
        score = cos(q_vec, emb)
        scored.append((score, it))

    scored.sort(key=lambda x: x[0], reverse=True)
    top = scored[:top_k]

    results = [{
        "reportId": it["reportId"],
        "reportDate": it.get("reportDate", ""),
        "score": round(float(score), 4),
        "s3Key": it.get("s3Key", ""),
        "preview": (it.get("content") or "")[:1500],
    } for score, it in top]

    return json.dumps({"question": question, "results": results}, ensure_ascii=False)


TOOLS = [get_dashboard_summary, get_resource_check, get_recent_alarms, get_metrics, query_athena, search_reports]
