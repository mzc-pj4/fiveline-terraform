"""
Metrics Collector Lambda
- CloudWatch GetMetricData로 운영 메트릭 수집
- S3 raw/cw-metrics/year=YYYY/month=MM/day=DD/hour=HH/ 에 적재
"""

import json
import os
from datetime import datetime, timedelta, timezone

import boto3

BUCKET = os.environ["BUCKET_NAME"]
PREFIX = os.environ.get("S3_PREFIX", "raw/cw-metrics")

cw = boto3.client("cloudwatch")
s3 = boto3.client("s3")

ALB_LB     = os.environ.get("ALB_LB_NAME",     "app/fiveline-alb/46f3ca3db6fcf6f3")
RDS_PRIMARY = os.environ.get("RDS_PRIMARY",    "fiveline-rds-primary")
RDS_REPLICA_A = os.environ.get("RDS_REPLICA_A", "fiveline-rds-replica-a")
RDS_REPLICA_C = os.environ.get("RDS_REPLICA_C", "fiveline-rds-replica-c")

# Dimension 명시 → 진짜 단일 리소스 메트릭. (Container Insights는 미활성이라 EKS Pod 메트릭 제외)
METRICS = [
    {"id": "alb_req",   "ns": "AWS/ApplicationELB", "name": "RequestCount",              "stat": "Sum",     "dim": {"LoadBalancer": ALB_LB}},
    {"id": "alb_5xx",   "ns": "AWS/ApplicationELB", "name": "HTTPCode_Target_5XX_Count", "stat": "Sum",     "dim": {"LoadBalancer": ALB_LB}},
    {"id": "alb_rt",    "ns": "AWS/ApplicationELB", "name": "TargetResponseTime",        "stat": "Average", "dim": {"LoadBalancer": ALB_LB}},
    {"id": "rds_cpu_p", "ns": "AWS/RDS",            "name": "CPUUtilization",            "stat": "Average", "dim": {"DBInstanceIdentifier": RDS_PRIMARY}},
    {"id": "rds_conn_p","ns": "AWS/RDS",            "name": "DatabaseConnections",       "stat": "Average", "dim": {"DBInstanceIdentifier": RDS_PRIMARY}},
    {"id": "rds_cpu_a", "ns": "AWS/RDS",            "name": "CPUUtilization",            "stat": "Average", "dim": {"DBInstanceIdentifier": RDS_REPLICA_A}},
    {"id": "rds_lag_a", "ns": "AWS/RDS",            "name": "ReplicaLag",                "stat": "Average", "dim": {"DBInstanceIdentifier": RDS_REPLICA_A}},
    {"id": "rds_cpu_c", "ns": "AWS/RDS",            "name": "CPUUtilization",            "stat": "Average", "dim": {"DBInstanceIdentifier": RDS_REPLICA_C}},
    {"id": "rds_lag_c", "ns": "AWS/RDS",            "name": "ReplicaLag",                "stat": "Average", "dim": {"DBInstanceIdentifier": RDS_REPLICA_C}},
]


def handler(event, context):
    end_time = datetime.now(timezone.utc).replace(second=0, microsecond=0)
    start_time = end_time - timedelta(minutes=5)

    queries = [
        {
            "Id": m["id"],
            "MetricStat": {
                "Metric": {
                    "Namespace": m["ns"],
                    "MetricName": m["name"],
                    "Dimensions": [{"Name": k, "Value": v} for k, v in m["dim"].items()],
                },
                "Period": 60,
                "Stat": m["stat"],
            },
            "ReturnData": True,
        }
        for m in METRICS
    ]

    resp = cw.get_metric_data(
        MetricDataQueries=queries,
        StartTime=start_time,
        EndTime=end_time,
    )

    output = {
        "collectedAt": end_time.isoformat(),
        "startTime": start_time.isoformat(),
        "endTime": end_time.isoformat(),
        "metrics": [
            {
                "id": r["Id"],
                "label": r.get("Label"),
                "values": [
                    {"t": t.isoformat(), "v": v}
                    for t, v in zip(r["Timestamps"], r["Values"])
                ],
            }
            for r in resp["MetricDataResults"]
        ],
    }

    ts = end_time
    key = (
        f"{PREFIX}/year={ts.year}/month={ts.month:02d}/day={ts.day:02d}"
        f"/hour={ts.hour:02d}/{ts.isoformat()}.json"
    )
    s3.put_object(
        Bucket=BUCKET,
        Key=key,
        Body=json.dumps(output),
        ContentType="application/json",
    )

    total = sum(len(m["values"]) for m in output["metrics"])
    return {"s3Key": key, "metricSeries": len(output["metrics"]), "dataPoints": total}
