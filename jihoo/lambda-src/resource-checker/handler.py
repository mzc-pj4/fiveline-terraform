"""
Resource Checker Lambda
- 미사용 EBS, 미연결 EIP, 오래된 Snapshot, 태그 누락 리소스
- 보안그룹 0.0.0.0/0 오픈, RDS Public Access 위험 탐지
- 결과 → DynamoDB + S3
"""

import json
import os
from datetime import datetime, timezone

import boto3

TABLE_NAME = os.environ["TABLE_NAME"]
BUCKET_NAME = os.environ["BUCKET_NAME"]
SNAPSHOT_AGE_DAYS = int(os.environ.get("SNAPSHOT_AGE_DAYS", "30"))
REQUIRED_TAGS = os.environ.get("REQUIRED_TAGS", "Project,Environment,Owner").split(",")

ec2 = boto3.client("ec2")
rds = boto3.client("rds")
ddb = boto3.resource("dynamodb").Table(TABLE_NAME)
s3 = boto3.client("s3")


def find_unused_ebs():
    resp = ec2.describe_volumes(Filters=[{"Name": "status", "Values": ["available"]}])
    return [
        {
            "checkType": "UNUSED_RESOURCE",
            "resourceType": "EBS",
            "resourceId": v["VolumeId"],
            "status": "UNUSED",
            "reason": f"Volume not attached (size={v['Size']}GB)",
            "sizeGb": v["Size"],
        }
        for v in resp["Volumes"]
    ]


def find_unused_eip():
    resp = ec2.describe_addresses()
    return [
        {
            "checkType": "UNUSED_RESOURCE",
            "resourceType": "EIP",
            "resourceId": a["AllocationId"],
            "status": "UNUSED",
            "reason": f"EIP not associated (publicIp={a.get('PublicIp')})",
        }
        for a in resp["Addresses"]
        if "AssociationId" not in a
    ]


def find_old_snapshots():
    now = datetime.now(timezone.utc)
    resp = ec2.describe_snapshots(OwnerIds=["self"])
    findings = []
    for s in resp["Snapshots"]:
        age_days = (now - s["StartTime"]).days
        if age_days > SNAPSHOT_AGE_DAYS:
            findings.append({
                "checkType": "STALE_RESOURCE",
                "resourceType": "EBS_SNAPSHOT",
                "resourceId": s["SnapshotId"],
                "status": "OLD",
                "reason": f"{age_days}일 경과 (임계 {SNAPSHOT_AGE_DAYS}일)",
                "ageDays": age_days,
                "sizeGb": s["VolumeSize"],
            })
    return findings


def find_missing_tags():
    """EC2, EBS, RDS, Snapshot 대상으로 필수 태그 누락 체크"""
    findings = []

    for v in ec2.describe_volumes()["Volumes"]:
        tags = {t["Key"]: t["Value"] for t in v.get("Tags", [])}
        missing = [t for t in REQUIRED_TAGS if t not in tags]
        if missing:
            findings.append({
                "checkType": "MISSING_TAGS",
                "resourceType": "EBS",
                "resourceId": v["VolumeId"],
                "status": "VIOLATION",
                "reason": f"필수 태그 누락: {','.join(missing)}",
                "missingTags": missing,
            })

    for inst_pages in ec2.get_paginator("describe_instances").paginate():
        for r in inst_pages["Reservations"]:
            for i in r["Instances"]:
                tags = {t["Key"]: t["Value"] for t in i.get("Tags", [])}
                missing = [t for t in REQUIRED_TAGS if t not in tags]
                if missing:
                    findings.append({
                        "checkType": "MISSING_TAGS",
                        "resourceType": "EC2",
                        "resourceId": i["InstanceId"],
                        "status": "VIOLATION",
                        "reason": f"필수 태그 누락: {','.join(missing)}",
                        "missingTags": missing,
                    })
    return findings


def find_open_security_groups():
    """0.0.0.0/0 으로 열린 보안그룹 (SSH/RDP/DB 포트 위험)"""
    DANGEROUS_PORTS = {22, 3389, 3306, 5432, 6379, 27017, 9200}
    findings = []
    for sg in ec2.describe_security_groups()["SecurityGroups"]:
        for rule in sg.get("IpPermissions", []):
            for ip in rule.get("IpRanges", []):
                if ip.get("CidrIp") == "0.0.0.0/0":
                    from_port = rule.get("FromPort")
                    to_port = rule.get("ToPort")
                    risky = bool(from_port is None or any(
                        from_port <= p <= to_port for p in DANGEROUS_PORTS
                    ))
                    if risky:
                        findings.append({
                            "checkType": "SECURITY_RISK",
                            "resourceType": "SECURITY_GROUP",
                            "resourceId": sg["GroupId"],
                            "status": "OPEN_TO_INTERNET",
                            "reason": f"0.0.0.0/0 → port {from_port}-{to_port} (위험 포트 포함)",
                            "protocol": rule.get("IpProtocol"),
                            "fromPort": from_port,
                            "toPort": to_port,
                        })
    return findings


def find_public_rds():
    findings = []
    for db in rds.describe_db_instances()["DBInstances"]:
        if db.get("PubliclyAccessible"):
            findings.append({
                "checkType": "SECURITY_RISK",
                "resourceType": "RDS",
                "resourceId": db["DBInstanceIdentifier"],
                "status": "PUBLIC_ACCESS",
                "reason": "RDS 인스턴스가 Public Access 허용 상태",
                "endpoint": db.get("Endpoint", {}).get("Address"),
            })
    return findings


def handler(event, context):
    checked_at = datetime.now(timezone.utc).isoformat()

    findings = (
        find_unused_ebs()
        + find_unused_eip()
        + find_old_snapshots()
        + find_missing_tags()
        + find_open_security_groups()
        + find_public_rds()
    )

    # DynamoDB 적재
    for f in findings:
        ddb.put_item(Item={**f, "checkedAt": checked_at})

    # S3 적재
    date_str = checked_at[:10]
    s3_key = f"raw/resource-check/{date_str}/{checked_at}.json"
    s3.put_object(
        Bucket=BUCKET_NAME,
        Key=s3_key,
        Body=json.dumps({"checkedAt": checked_at, "findings": findings}),
        ContentType="application/json",
    )

    # 카테고리별 카운트
    by_type = {}
    for f in findings:
        by_type[f["checkType"]] = by_type.get(f["checkType"], 0) + 1

    return {
        "checkedAt": checked_at,
        "totalCount": len(findings),
        "byType": by_type,
        "s3Key": s3_key,
    }
