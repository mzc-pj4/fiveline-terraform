"""
Pipeline Orchestrator Lambda
- EventBridge가 N시간마다 호출
- 4단계 자동 실행:
  ① MSCK REPAIR TABLE service_events  (새 시간 파티션을 Glue Catalog에 등록)
  ② Glue Job cleansed-to-aggregated   (events_hourly + findings_daily 재생성)
  ③ Summary Writer Lambda invoke      (DDB dashboard_summary 갱신)
  ④ Dashboard Builder Lambda invoke    (S3 data.json 갱신)
- 끝-끝 약 2~3분 소요. Lambda timeout 7분 여유.
"""

import json
import os
import time

import boto3

GLUE_JOB          = os.environ["GLUE_JOB_NAME"]
SUMMARY_WRITER    = os.environ["SUMMARY_WRITER_NAME"]
DASHBOARD_BUILDER = os.environ["DASHBOARD_BUILDER_NAME"]
ATHENA_DB         = os.environ["ATHENA_DB"]
ATHENA_OUTPUT     = os.environ["ATHENA_OUTPUT"]

glue    = boto3.client("glue")
lambda_ = boto3.client("lambda")
athena  = boto3.client("athena")


def msck_repair(table):
    """Athena MSCK REPAIR — 새 Hive 파티션을 Glue Catalog에 등록"""
    try:
        qid = athena.start_query_execution(
            QueryString=f"MSCK REPAIR TABLE {table}",
            QueryExecutionContext={"Database": ATHENA_DB},
            ResultConfiguration={"OutputLocation": ATHENA_OUTPUT},
        )["QueryExecutionId"]
        for _ in range(60):
            st = athena.get_query_execution(QueryExecutionId=qid)["QueryExecution"]["Status"]["State"]
            if st == "SUCCEEDED":
                return {"ok": True, "qid": qid}
            if st in ("FAILED", "CANCELLED"):
                reason = athena.get_query_execution(QueryExecutionId=qid)["QueryExecution"]["Status"].get("StateChangeReason", "")
                return {"ok": False, "qid": qid, "state": st, "reason": reason}
            time.sleep(1)
        return {"ok": False, "qid": qid, "state": "TIMEOUT"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


def wait_glue(run_id, max_polls=150):
    """150 × 5sec = 12.5분 polling"""
    for _ in range(max_polls):
        info = glue.get_job_run(JobName=GLUE_JOB, RunId=run_id)
        state = info["JobRun"]["JobRunState"]
        if state == "SUCCEEDED":
            return state
        if state in ("FAILED", "ERROR", "STOPPED", "TIMEOUT"):
            return state
        time.sleep(5)
    return "POLL_TIMEOUT"


def invoke_lambda(name):
    resp = lambda_.invoke(
        FunctionName=name,
        InvocationType="RequestResponse",
        Payload=b"{}",
    )
    try:
        body = json.loads(resp["Payload"].read())
    except Exception:
        body = {"raw": "non-json"}
    return {"statusCode": resp["StatusCode"], "result": body}


def handler(event, context):
    steps = []

    # ① 파티션 등록 (서비스 로그가 매시간 새 폴더 생성하므로 필요)
    msck = msck_repair("service_events")
    steps.append({"step": "msck_repair", **msck})

    # ② Glue ETL aggregated
    run_id = glue.start_job_run(JobName=GLUE_JOB)["JobRunId"]
    glue_state = wait_glue(run_id)
    steps.append({"step": "glue_etl", "run_id": run_id, "state": glue_state})
    if glue_state != "SUCCEEDED":
        return {"ok": False, "failedAt": "glue_etl", "steps": steps}

    # ②.5 Glue가 만든 새 파티션을 Catalog에 등록 (Athena·Summary Writer가 보게)
    for tbl in ["events_hourly", "resource_findings_daily"]:
        m = msck_repair(tbl)
        steps.append({"step": f"msck_{tbl}", **m})

    # ③ Summary Writer
    sw = invoke_lambda(SUMMARY_WRITER)
    steps.append({"step": "summary_writer", **sw})

    # ④ Dashboard Builder
    db = invoke_lambda(DASHBOARD_BUILDER)
    steps.append({"step": "dashboard_builder", **db})

    return {"ok": True, "steps": steps}
