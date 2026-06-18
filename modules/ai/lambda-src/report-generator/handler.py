"""
Report Generator Lambda
- DynamoDB dashboard_summary, check_results 조회
- Bedrock Claude 3.5 Sonnet으로 4섹션 일간 운영 리포트 생성
- Markdown 리포트 → S3 reports/daily/
- 메타데이터 → DynamoDB report_metadata
"""

import json
import os
from datetime import datetime, timezone

import boto3

BUCKET = os.environ["BUCKET_NAME"]
REPORT_TABLE = os.environ["REPORT_TABLE"]
DASHBOARD_TABLE = os.environ.get("DASHBOARD_TABLE", "")
CHECK_TABLE = os.environ.get("CHECK_TABLE", "")
MODEL_ID = os.environ.get("MODEL_ID", "anthropic.claude-3-5-sonnet-20241022-v2:0")

bedrock = boto3.client("bedrock-runtime")
ddb = boto3.resource("dynamodb")
s3 = boto3.client("s3")


def get_dashboard_summary(date_str):
    """오늘 대시보드 요약 1건"""
    if not DASHBOARD_TABLE:
        return None
    try:
        resp = ddb.Table(DASHBOARD_TABLE).get_item(Key={"summaryDate": date_str})
        return resp.get("Item")
    except Exception as e:
        print(f"dashboard fetch error: {e}")
        return None


def get_recent_findings(limit=20):
    """최근 리소스 점검 결과"""
    if not CHECK_TABLE:
        return []
    try:
        resp = ddb.Table(CHECK_TABLE).scan(Limit=limit)
        return resp.get("Items", [])
    except Exception as e:
        print(f"check fetch error: {e}")
        return []


def build_prompt(date_str, dashboard, findings):
    """입력 데이터 → Claude 프롬프트"""
    blocks = []

    if dashboard:
        blocks.append(
            "### 대시보드 요약\n```\n"
            + json.dumps(dashboard, ensure_ascii=False, indent=2, default=str)
            + "\n```"
        )
    else:
        blocks.append("### 대시보드 요약\n(데이터 없음)")

    if findings:
        finding_lines = []
        by_type = {}
        for f in findings:
            t = f.get("checkType", "UNKNOWN")
            by_type[t] = by_type.get(t, 0) + 1
            finding_lines.append(
                f"- [{t}] {f.get('resourceType')} {f.get('resourceId')}: {f.get('reason')}"
            )
        blocks.append(
            f"### 리소스 점검 결과 (총 {len(findings)}건)\n"
            + f"카테고리: {by_type}\n\n"
            + "\n".join(finding_lines[:15])
        )
    else:
        blocks.append("### 리소스 점검 결과\n(데이터 없음)")

    data_section = "\n\n".join(blocks)

    return f"""당신은 AWS 운영 분석 전문가입니다. 아래 운영 데이터를 분석해 한국어 일간 운영 리포트를 작성해주세요.

## 입력 데이터
{data_section}

## 출력 형식 (Markdown)
정확히 아래 4섹션 구조로 작성해주세요. 데이터가 없는 항목은 "데이터 없음"으로 명시.

# {date_str} 일간 운영 리포트

## 1. 운영 요약
(3줄 이내 핵심 요약)

## 2. 핵심 지표
- 서비스별 주요 수치 (있는 데이터 기반)

## 3. 이상 징후
- 임계값 초과 또는 주의가 필요한 항목
- 보안 위험, 미사용 리소스, 태그 누락 등 포함

## 4. 권고 사항
- **즉시 조치**: (긴급한 것)
- **단기 개선**: (1주일 내)
- **장기 검토**: (월 단위)

## 작성 규칙
- 한국어로 작성
- 데이터에 없는 내용 추측·창작 금지
- 구체적 수치 인용
"""


def call_bedrock(prompt):
    """Claude 3.5 Sonnet 호출 (Converse API)"""
    resp = bedrock.converse(
        modelId=MODEL_ID,
        messages=[{"role": "user", "content": [{"text": prompt}]}],
        inferenceConfig={
            "maxTokens": 4096,
            "temperature": 0.3,
        },
    )
    text = resp["output"]["message"]["content"][0]["text"]
    usage = resp.get("usage", {})
    return text, usage


def handler(event, context):
    # 날짜 결정 — event에 date 있으면 그 날짜, 없으면 오늘
    date_str = event.get("date") or datetime.now(timezone.utc).strftime("%Y-%m-%d")

    # 1. 데이터 수집
    dashboard = get_dashboard_summary(date_str)
    findings = get_recent_findings()

    # 2. Bedrock 호출
    prompt = build_prompt(date_str, dashboard, findings)
    report_md, usage = call_bedrock(prompt)

    # 3. S3 저장
    report_key = f"reports/daily/{date_str}.md"
    s3.put_object(
        Bucket=BUCKET,
        Key=report_key,
        Body=report_md.encode("utf-8"),
        ContentType="text/markdown; charset=utf-8",
    )

    # 4. DynamoDB 메타데이터
    created_at = datetime.now(timezone.utc).isoformat()
    ddb.Table(REPORT_TABLE).put_item(Item={
        "reportType": "daily",
        "createdAt": created_at,
        "reportDate": date_str,
        "title": f"{date_str} 일간 운영 리포트",
        "s3Url": f"s3://{BUCKET}/{report_key}",
        "summaryPreview": report_md[:300],
        "tokenUsage": usage,
    })

    return {
        "reportType": "daily",
        "reportDate": date_str,
        "s3Url": f"s3://{BUCKET}/{report_key}",
        "length": len(report_md),
        "tokenUsage": usage,
    }
