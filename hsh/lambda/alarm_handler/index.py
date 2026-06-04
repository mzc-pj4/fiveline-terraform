import json
import os
import uuid
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone

import boto3

dynamodb = boto3.resource("dynamodb")
s3_client = boto3.client("s3")

TABLE_NAME = os.environ["DYNAMODB_TABLE"]
SUMMARY_TABLE_NAME = os.environ["DYNAMODB_SUMMARY_TABLE"]
S3_BUCKET = os.environ["S3_BUCKET"]
SLACK_WEBHOOK_URL = os.environ["SLACK_WEBHOOK_URL"]


def _service_from_alarm(alarm_name: str) -> str:
    for svc in ("alb", "rds", "redis", "eks", "hpa", "pod", "ca"):
        if svc in alarm_name.lower():
            return svc
    return "other"


def _save_to_dynamodb(alarm_id: str, alarm_name: str, status: str, metric: str, timestamp: str) -> None:
    ttl_value = int(datetime.now(timezone.utc).timestamp()) + 90 * 24 * 3600  # 90일 TTL
    table = dynamodb.Table(TABLE_NAME)
    table.put_item(
        Item={
            "alarmId": alarm_id,
            "timestamp": timestamp,
            "alarmName": alarm_name,
            "status": status,
            "metric": metric,
            "slackSent": False,
            "ttl": ttl_value,
        }
    )


def _update_dashboard_summary(alarm_name: str, status: str, timestamp: str) -> None:
    service = _service_from_alarm(alarm_name)
    date = timestamp[:10]  # YYYY-MM-DD
    table = dynamodb.Table(SUMMARY_TABLE_NAME)
    table.update_item(
        Key={"service": service, "date": date},
        UpdateExpression=(
            "ADD totalCount :one, criticalCount :crit "
            "SET lastAlarmTime = :t, lastAlarmName = :n, lastStatus = :s"
        ),
        ExpressionAttributeValues={
            ":one":  1,
            ":crit": 1 if "crit" in alarm_name.lower() else 0,
            ":t":    timestamp,
            ":n":    alarm_name,
            ":s":    status,
        },
    )


def _save_to_s3(alarm_id: str, payload: dict, timestamp: str) -> None:
    date_prefix = timestamp[:10]  # YYYY-MM-DD
    key = f"raw/alarm-events/{date_prefix}/{alarm_id}.json"
    s3_client.put_object(
        Bucket=S3_BUCKET,
        Key=key,
        Body=json.dumps(payload, ensure_ascii=False),
        ContentType="application/json",
    )


def _send_slack(alarm_name: str, status: str, reason: str, metric: str) -> None:
    color = "#FF0000" if status == "ALARM" else "#36A64F"
    payload = {
        "attachments": [
            {
                "color": color,
                "title": f":bell: CloudWatch Alarm: {status}",
                "fields": [
                    {"title": "Alarm", "value": alarm_name, "short": True},
                    {"title": "Status", "value": status, "short": True},
                    {"title": "Metric", "value": metric, "short": True},
                    {"title": "Reason", "value": reason, "short": False},
                ],
                "footer": "mzc-pj4 | AWS CloudWatch",
                "ts": int(datetime.now(timezone.utc).timestamp()),
            }
        ]
    }
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        SLACK_WEBHOOK_URL,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        if resp.status != 200:
            raise RuntimeError(f"Slack webhook returned HTTP {resp.status}")


def handler(event, context):
    record = event["Records"][0]["Sns"]
    sns_message = json.loads(record["Message"])

    alarm_name = sns_message.get("AlarmName", "Unknown")
    status = sns_message.get("NewStateValue", "UNKNOWN")
    reason = sns_message.get("NewStateReason", "")
    metric = sns_message.get("Trigger", {}).get("MetricName", "")
    timestamp = sns_message.get("StateChangeTime", datetime.now(timezone.utc).isoformat())
    alarm_id = str(uuid.uuid4())

    results: dict[str, str] = {}

    def task_dynamodb():
        _save_to_dynamodb(alarm_id, alarm_name, status, metric, timestamp)
        return "dynamodb"

    def task_s3():
        _save_to_s3(alarm_id, sns_message, timestamp)
        return "s3"

    def task_slack():
        _send_slack(alarm_name, status, reason, metric)
        return "slack"

    slack_sent = False

    with ThreadPoolExecutor(max_workers=3) as executor:
        future_map = {
            executor.submit(task_dynamodb): "dynamodb",
            executor.submit(task_s3): "s3",
            executor.submit(task_slack): "slack",
        }
        for future in as_completed(future_map):
            task_name = future_map[future]
            try:
                future.result()
                results[task_name] = "success"
                if task_name == "slack":
                    slack_sent = True
            except Exception as exc:
                results[task_name] = f"error: {exc}"

    # alarm_history에 Slack 발송 여부 업데이트
    if results.get("dynamodb") == "success":
        try:
            table = dynamodb.Table(TABLE_NAME)
            table.update_item(
                Key={"alarmId": alarm_id},
                UpdateExpression="SET slackSent = :s",
                ExpressionAttributeValues={":s": slack_sent},
            )
        except Exception:
            pass

    # dashboard_summary 집계 업데이트 (ALARM 상태일 때만)
    if status == "ALARM":
        try:
            _update_dashboard_summary(alarm_name, status, timestamp)
        except Exception:
            pass

    print(json.dumps({"alarmId": alarm_id, "alarmName": alarm_name, "results": results}))
    return {"statusCode": 200, "body": json.dumps(results)}
