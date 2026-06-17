"""
Report Embedder Lambda — 경량 RAG
- S3 reports/daily/*.md 마크다운 읽기
- Bedrock Titan Embed v2 → 1024차원 벡터
- DynamoDB report_embeddings에 저장
- LangGraph가 search_reports 도구로 코사인 유사도 검색
"""

import json
import os
from datetime import datetime, timezone
from decimal import Decimal

import boto3

BUCKET = os.environ["BUCKET_NAME"]
PREFIX = os.environ.get("REPORTS_PREFIX", "reports/daily/")
EMBED_TABLE = os.environ["EMBED_TABLE"]
EMBED_MODEL = os.environ.get("EMBED_MODEL", "amazon.titan-embed-text-v2:0")
MAX_CHARS = int(os.environ.get("MAX_CHARS", "8000"))

s3 = boto3.client("s3")
bedrock = boto3.client("bedrock-runtime")
ddb = boto3.resource("dynamodb")


def list_reports():
    paginator = s3.get_paginator("list_objects_v2")
    keys = []
    for page in paginator.paginate(Bucket=BUCKET, Prefix=PREFIX):
        for obj in page.get("Contents", []):
            if obj["Key"].endswith(".md"):
                keys.append(obj["Key"])
    return keys


def read_md(key):
    body = s3.get_object(Bucket=BUCKET, Key=key)["Body"].read().decode("utf-8")
    return body[:MAX_CHARS]


def embed_text(text):
    resp = bedrock.invoke_model(
        modelId=EMBED_MODEL,
        body=json.dumps({"inputText": text, "dimensions": 1024, "normalize": True}),
    )
    payload = json.loads(resp["body"].read())
    return payload["embedding"]


def existing_report_ids():
    table = ddb.Table(EMBED_TABLE)
    ids = set()
    last_key = None
    while True:
        kwargs = {"ProjectionExpression": "reportId"}
        if last_key:
            kwargs["ExclusiveStartKey"] = last_key
        resp = table.scan(**kwargs)
        for it in resp.get("Items", []):
            ids.add(it["reportId"])
        last_key = resp.get("LastEvaluatedKey")
        if not last_key:
            break
    return ids


def report_id_from_key(key):
    # reports/daily/2026-06-11.md → daily-2026-06-11
    parts = key.split("/")
    date = parts[-1].replace(".md", "")
    return f"{parts[-2]}-{date}"


def handler(event, context):
    force = bool(event.get("force", False))
    keys = list_reports()
    print(f"found {len(keys)} reports")

    skip_ids = set() if force else existing_report_ids()
    print(f"skipping {len(skip_ids)} already-embedded")

    table = ddb.Table(EMBED_TABLE)
    embedded = []
    errors = []

    for key in keys:
        rid = report_id_from_key(key)
        if rid in skip_ids:
            continue
        try:
            content = read_md(key)
            vec = embed_text(content)
            # DDB는 Decimal 필요 (float → Decimal)
            vec_dec = [Decimal(str(round(v, 6))) for v in vec]
            table.put_item(Item={
                "reportId": rid,
                "reportType": rid.split("-")[0],
                "reportDate": "-".join(rid.split("-")[1:]),
                "s3Key": key,
                "content": content[:4000],   # 검색 결과로 반환할 미리보기
                "embedding": vec_dec,
                "embeddedAt": datetime.now(timezone.utc).isoformat(),
            })
            embedded.append(rid)
            print(f"embedded {rid}")
        except Exception as e:
            errors.append({"key": key, "error": str(e)})
            print(f"ERROR {key}: {e}")

    return {
        "totalReports": len(keys),
        "newlyEmbedded": len(embedded),
        "skipped": len(skip_ids),
        "errors": errors,
        "embeddedIds": embedded[:10],
    }
