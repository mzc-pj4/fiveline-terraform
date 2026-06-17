"""
Glue ETL Job: cleansed → aggregated
- 두 가지 집계 산출:
  1) events_hourly:        raw/service-events/   → 시간×스트림별 에러율 집계
  2) resource_findings_daily: cleansed/resource-check/ → 일별 checkType 집계
- 출력 포맷: Parquet + Snappy + Hive 파티셔닝 (year/month/day)
- 목적: Athena/대시보드가 32K row 스캔 대신 집계 결과만 읽도록
"""

import sys
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.sql.functions import (
    explode, col, count, lit,
    sum as _sum,
    when, year, month, dayofmonth,
    hour as _hour,
    round as _round,
)

args = getResolvedOptions(sys.argv, [
    "JOB_NAME",
    "catalog_db",
    "events_table",
    "events_target_path",
    "findings_source_path",
    "findings_target_path",
])

sc = SparkContext()
glue_ctx = GlueContext(sc)
spark = glue_ctx.spark_session
job = Job(glue_ctx)
job.init(args["JOB_NAME"], args)


# ─────────────────────────────────────────────────────────────────────────────
# 1) events_hourly — service_events 시간대별 집계
# ─────────────────────────────────────────────────────────────────────────────

# Glue Catalog 통해 읽기 (Crawler가 CloudWatch Logs 형식 디코딩 방법 알고 있음)
events_dyf = glue_ctx.create_dynamic_frame.from_catalog(
    database=args["catalog_db"],
    table_name=args["events_table"],
)
events_raw = events_dyf.toDF()

# logevents 배열을 한 row 한 메시지로 풀기 (Catalog 컬럼명은 소문자)
events_exploded = events_raw.select(
    col("owner"),
    col("logstream"),
    col("messagetype"),
    explode("logevents").alias("event"),
).select(
    col("owner"),
    col("logstream").alias("logStream"),
    col("messagetype").alias("messageType"),
    col("event.timestamp").alias("ts_millis"),
    col("event.message").alias("message"),
)

# timestamp(ms) → timestamp 타입 + 에러/경고 플래그
events_classified = (
    events_exploded
    .withColumn("ts", (col("ts_millis") / 1000).cast("timestamp"))
    .withColumn(
        "is_error",
        when(col("message").rlike("(?i)error|failed|exception"), 1).otherwise(0),
    )
    .withColumn(
        "is_warning",
        when(col("message").rlike("(?i)warning"), 1).otherwise(0),
    )
    .withColumn("year",  year("ts"))
    .withColumn("month", month("ts"))
    .withColumn("day",   dayofmonth("ts"))
    .withColumn("hr",    _hour("ts"))  # 'hour' 키워드 충돌 회피
)

events_hourly = (
    events_classified
    .groupBy("year", "month", "day", "hr", "logStream")
    .agg(
        count("*").alias("total_events"),
        _sum("is_error").alias("error_count"),
        _sum("is_warning").alias("warning_count"),
    )
    .withColumn(
        "error_pct",
        _round((col("error_count") * 100.0) / col("total_events"), 2),
    )
    .withColumnRenamed("hr", "hour")
)

events_hourly.write.mode("overwrite").partitionBy("year", "month", "day").parquet(
    args["events_target_path"]
)


# ─────────────────────────────────────────────────────────────────────────────
# 2) resource_findings_daily — 일별 checkType × resourceType 집계
# ─────────────────────────────────────────────────────────────────────────────

# cleansed/resource-check/ 는 이미 explode·파티셔닝 된 Parquet
findings_df = spark.read.option("basePath", args["findings_source_path"]).parquet(
    args["findings_source_path"]
)

findings_daily = findings_df.groupBy(
    "year", "month", "day", "checkType", "resourceType"
).agg(
    count("*").alias("finding_count"),
)

findings_daily.write.mode("overwrite").partitionBy("year", "month", "day").parquet(
    args["findings_target_path"]
)


job.commit()
