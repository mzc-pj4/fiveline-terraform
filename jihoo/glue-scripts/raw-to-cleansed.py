"""
Glue ETL Job: raw/resource-check/ → cleansed/resource-check/
- JSON 원본 읽기
- findings 배열을 행 단위로 분해 (explode)
- year/month/day 컬럼 추출
- Parquet + Snappy 압축으로 Hive 파티셔닝 저장
"""

import sys
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.sql.functions import explode, col, to_timestamp, year, month, dayofmonth

# Glue Job이 전달한 인자 받기
args = getResolvedOptions(sys.argv, ["JOB_NAME", "source_path", "target_path"])

sc = SparkContext()
glue_ctx = GlueContext(sc)
spark = glue_ctx.spark_session
job = Job(glue_ctx)
job.init(args["JOB_NAME"], args)

# 1. raw JSON 재귀적으로 읽기
df = spark.read.option("recursiveFileLookup", "true").json(args["source_path"])

# 2. checkedAt 문자열을 timestamp 타입으로 변환
df_ts = df.withColumn("ts", to_timestamp("checkedAt"))

# 3. findings 배열을 row 단위로 풀어줌 (1 finding = 1 row)
exploded = df_ts.select(
    col("checkedAt"),
    col("ts"),
    explode("findings").alias("finding"),
).select(
    col("checkedAt"),
    col("ts"),
    col("finding.checkType").alias("checkType"),
    col("finding.resourceType").alias("resourceType"),
    col("finding.resourceId").alias("resourceId"),
    col("finding.status").alias("status"),
    col("finding.reason").alias("reason"),
)

# 4. 파티션 컬럼 추가 (year/month/day)
partitioned = (
    exploded
    .withColumn("year", year("ts"))
    .withColumn("month", month("ts"))
    .withColumn("day", dayofmonth("ts"))
)

# 5. Parquet으로 Hive 파티셔닝 저장 (year=2026/month=5/day=26/...)
partitioned.write.mode("overwrite").partitionBy("year", "month", "day").parquet(
    args["target_path"]
)

job.commit()
