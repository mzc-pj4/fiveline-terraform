# ══════════════════════════════════════════════
# CloudWatch Dashboard — fiveline-dashboard
# 골든 시그널 4행: Latency / Traffic / Errors / Saturation
# ══════════════════════════════════════════════
resource "aws_cloudwatch_dashboard" "fiveline" {
  dashboard_name = "fiveline-dashboard"

  dashboard_body = jsonencode({
    widgets = [

      # ── Row 1: Latency ─────────────────────────────────────
      { type = "text", x = 0, y = 0, width = 24, height = 1
        properties = { markdown = "## Latency" } },

      { type = "metric", x = 0, y = 1, width = 12, height = 6
        properties = {
          title = "ALB 응답시간 P50 / P95 / P99"
          region = data.aws_region.current.name
          view = "timeSeries", period = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, { stat = "p50", label = "P50" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, { stat = "p95", label = "P95" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, { stat = "p99", label = "P99", color = "#d62728" }]
          ]
        }
      },

      { type = "metric", x = 12, y = 1, width = 12, height = 6
        properties = {
          title = "RDS 쓰기 지연 / Replica Lag (초)"
          region = data.aws_region.current.name
          view = "timeSeries", period = 300
          metrics = [
            ["AWS/RDS", "WriteLatency", "DBInstanceIdentifier", var.rds_instance_id, { stat = "Average", label = "WriteLatency" }],
            ["AWS/RDS", "ReplicaLag", "DBInstanceIdentifier", var.rds_instance_id, { stat = "Maximum", label = "ReplicaLag" }]
          ]
        }
      },

      # ── Row 2: Traffic ─────────────────────────────────────
      { type = "text", x = 0, y = 7, width = 24, height = 1
        properties = { markdown = "## Traffic" } },

      { type = "metric", x = 0, y = 8, width = 12, height = 6
        properties = {
          title = "ALB 요청 수 (RPS)"
          region = data.aws_region.current.name
          view = "timeSeries", period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum", label = "RequestCount" }]
          ]
        }
      },

      { type = "metric", x = 12, y = 8, width = 12, height = 6
        properties = {
          title = "RDS 동시 접속 수"
          region = data.aws_region.current.name
          view = "timeSeries", period = 300
          metrics = [
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", var.rds_instance_id, { stat = "Maximum", label = "Connections" }]
          ]
        }
      },

      # ── Row 3: Errors ──────────────────────────────────────
      { type = "text", x = 0, y = 14, width = 24, height = 1
        properties = { markdown = "## Errors" } },

      { type = "metric", x = 0, y = 15, width = 12, height = 6
        properties = {
          title = "ALB 5xx 에러율 (%)"
          region = data.aws_region.current.name
          view = "timeSeries", period = 300
          metrics = [
            [{ expression = "m1/m2*100", label = "5xx Rate (%)", id = "error_rate" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.alb_arn_suffix, { id = "m1", visible = false, stat = "Sum" }],
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix, { id = "m2", visible = false, stat = "Sum" }]
          ]
        }
      },

      { type = "metric", x = 12, y = 15, width = 12, height = 6
        properties = {
          title = "Pod 재시작 횟수"
          region = data.aws_region.current.name
          view = "timeSeries", period = 300
          metrics = [
            ["ContainerInsights", "pod_number_of_container_restarts", "ClusterName", var.eks_cluster_name, { stat = "Maximum", label = "PodRestarts" }]
          ]
        }
      },

      # ── Row 4: Saturation ──────────────────────────────────
      { type = "text", x = 0, y = 21, width = 24, height = 1
        properties = { markdown = "## Saturation" } },

      { type = "metric", x = 0, y = 22, width = 6, height = 6
        properties = {
          title = "EKS 클러스터 CPU (%)"
          region = data.aws_region.current.name
          view = "timeSeries", period = 300
          metrics = [
            ["ContainerInsights", "cluster_cpu_utilization", "ClusterName", var.eks_cluster_name, { stat = "Average", label = "CPU %" }]
          ]
        }
      },

      { type = "metric", x = 6, y = 22, width = 6, height = 6
        properties = {
          title = "Redis Hit Rate (%)"
          region = data.aws_region.current.name
          view = "timeSeries", period = 300
          metrics = [
            [{ expression = "m1/(m1+m2)*100", label = "Hit Rate (%)", id = "hit_rate" }],
            ["AWS/ElastiCache", "GetHits", "ReplicationGroupId", var.redis_replication_group_id, { id = "m1", visible = false, stat = "Sum" }],
            ["AWS/ElastiCache", "GetMisses", "ReplicationGroupId", var.redis_replication_group_id, { id = "m2", visible = false, stat = "Sum" }]
          ]
        }
      },

      { type = "metric", x = 12, y = 22, width = 6, height = 6
        properties = {
          title = "Redis Replication Lag (초)"
          region = data.aws_region.current.name
          view = "timeSeries", period = 300
          metrics = [
            ["AWS/ElastiCache", "ReplicationLag", "ReplicationGroupId", var.redis_replication_group_id, { stat = "Maximum", label = "ReplicationLag" }]
          ]
        }
      },

      { type = "metric", x = 18, y = 22, width = 6, height = 6
        properties = {
          title = "RDS 여유 스토리지 (GiB)"
          region = data.aws_region.current.name
          view = "timeSeries", period = 300
          metrics = [
            [{ expression = "m1/1024/1024/1024", label = "Free Storage (GiB)", id = "storage_gib" }],
            ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", var.rds_instance_id, { id = "m1", visible = false, stat = "Minimum" }]
          ]
        }
      }
    ]
  })
}

# 공통 설정
# datapoints_to_alarm = 2, evaluation_periods = 2, treat_missing_data = "notBreaching"
# 예외: fiveline-alarm-ca-pending-pods (period=60, eval=4, dtp=4)
#       fiveline-alarm-burn-rate-1h    (period=3600, eval=1, dtp=1)

locals {
  # 5 GiB (bytes)
  rds_storage_threshold_bytes = 5368709120
}

# ══════════════════════════════════════════════
# ALB 알람 — ALB(Ingress) 생성 후 활성화
# CI/CD 담당자 작업 완료 후 alb_arn_suffix 변수 채워서 apply
# ══════════════════════════════════════════════

# ALB 5xx 에러율 > 1%
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "fiveline-alarm-alb-5xx"
  alarm_description   = "[Critical] ALB 백엔드 5xx 에러율 1% 초과"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 1
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "error_rate"
    expression  = "m1/m2*100"
    label       = "5xx Error Rate (%)"
    return_data = true
  }
  metric_query {
    id = "m1"
    metric {
      metric_name = "HTTPCode_Target_5XX_Count"
      namespace   = "AWS/ApplicationELB"
      period      = 300
      stat        = "Sum"
      dimensions  = { LoadBalancer = var.alb_arn_suffix }
    }
  }
  metric_query {
    id = "m2"
    metric {
      metric_name = "RequestCount"
      namespace   = "AWS/ApplicationELB"
      period      = 300
      stat        = "Sum"
      dimensions  = { LoadBalancer = var.alb_arn_suffix }
    }
  }

  alarm_actions = [aws_sns_topic.alarm.arn]
  ok_actions    = [aws_sns_topic.alarm.arn]

  tags = {
    Name     = "fiveline-alarm-alb-5xx"
    Service  = "monitoring"
    Severity = "critical"
  }
}

# ALB 503 (ELB 측 5xx — healthy target 없을 때 발생)
resource "aws_cloudwatch_metric_alarm" "alb_503" {
  alarm_name          = "fiveline-alarm-alb-503"
  alarm_description   = "[Warning] ALB ELB 5xx 발생 (503 포함 — healthy target 없음 의심)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  alarm_actions = [aws_sns_topic.alarm.arn]
  ok_actions    = [aws_sns_topic.alarm.arn]

  tags = {
    Name     = "fiveline-alarm-alb-503"
    Service  = "monitoring"
    Severity = "warning"
  }
}

# ══════════════════════════════════════════════
# RDS 알람
# ══════════════════════════════════════════════

# RDS 동시 접속 수 > 136 (max_connections 170 기준 80%)
resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name          = "fiveline-alarm-rds-connections"
  alarm_description   = "[Warning] RDS 동시 접속 수 136 초과 (max_connections 80%)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 136
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = var.rds_instance_id
  }

  alarm_actions = [aws_sns_topic.alarm.arn]
  ok_actions    = [aws_sns_topic.alarm.arn]

  tags = {
    Name     = "fiveline-alarm-rds-connections"
    Service  = "monitoring"
    Severity = "warning"
  }
}

# RDS 쓰기 지연 > 100ms
resource "aws_cloudwatch_metric_alarm" "rds_write_latency" {
  alarm_name          = "fiveline-alarm-rds-write-latency"
  alarm_description   = "[Critical] RDS 쓰기 지연 100ms 초과"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  metric_name         = "WriteLatency"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 0.1
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = var.rds_instance_id
  }

  alarm_actions = [aws_sns_topic.alarm.arn]
  ok_actions    = [aws_sns_topic.alarm.arn]

  tags = {
    Name     = "fiveline-alarm-rds-write-latency"
    Service  = "monitoring"
    Severity = "critical"
  }
}

# RDS Replica Lag > 30초
resource "aws_cloudwatch_metric_alarm" "rds_replica_lag" {
  alarm_name          = "fiveline-alarm-rds-replica-lag"
  alarm_description   = "[Warning] RDS Replica Lag 30초 초과"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  metric_name         = "ReplicaLag"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 30
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = var.rds_instance_id
  }

  alarm_actions = [aws_sns_topic.alarm.arn]
  ok_actions    = [aws_sns_topic.alarm.arn]

  tags = {
    Name     = "fiveline-alarm-rds-replica-lag"
    Service  = "monitoring"
    Severity = "warning"
  }
}

# RDS 여유 스토리지 < 5 GiB
resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  alarm_name          = "fiveline-alarm-rds-storage"
  alarm_description   = "[Warning] RDS 여유 스토리지 5GiB 미만"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Minimum"
  threshold           = local.rds_storage_threshold_bytes
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = var.rds_instance_id
  }

  alarm_actions = [aws_sns_topic.alarm.arn]
  ok_actions    = [aws_sns_topic.alarm.arn]

  tags = {
    Name     = "fiveline-alarm-rds-storage"
    Service  = "monitoring"
    Severity = "warning"
  }
}

# ══════════════════════════════════════════════
# Redis (ElastiCache) 알람
# ══════════════════════════════════════════════

# Redis Hit Rate < 80% (Warning) — Metric Math
resource "aws_cloudwatch_metric_alarm" "redis_hitrate_warn" {
  alarm_name          = "fiveline-alarm-redis-hitrate-warn"
  alarm_description   = "[Warning] Redis Hit Rate 80% 미만"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 80
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "hit_rate"
    expression  = "m1/(m1+m2)*100"
    label       = "Hit Rate (%)"
    return_data = true
  }
  metric_query {
    id = "m1"
    metric {
      metric_name = "GetHits"
      namespace   = "AWS/ElastiCache"
      period      = 300
      stat        = "Sum"
      dimensions  = { ReplicationGroupId = var.redis_replication_group_id }
    }
  }
  metric_query {
    id = "m2"
    metric {
      metric_name = "GetMisses"
      namespace   = "AWS/ElastiCache"
      period      = 300
      stat        = "Sum"
      dimensions  = { ReplicationGroupId = var.redis_replication_group_id }
    }
  }

  alarm_actions = [aws_sns_topic.alarm.arn]
  ok_actions    = [aws_sns_topic.alarm.arn]

  tags = {
    Name     = "fiveline-alarm-redis-hitrate-warn"
    Service  = "monitoring"
    Severity = "warning"
  }
}

# Redis Hit Rate < 60% (Critical) — Metric Math
resource "aws_cloudwatch_metric_alarm" "redis_hitrate_crit" {
  alarm_name          = "fiveline-alarm-redis-hitrate-crit"
  alarm_description   = "[Critical] Redis Hit Rate 60% 미만"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 60
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "hit_rate"
    expression  = "m1/(m1+m2)*100"
    label       = "Hit Rate (%)"
    return_data = true
  }
  metric_query {
    id = "m1"
    metric {
      metric_name = "GetHits"
      namespace   = "AWS/ElastiCache"
      period      = 300
      stat        = "Sum"
      dimensions  = { ReplicationGroupId = var.redis_replication_group_id }
    }
  }
  metric_query {
    id = "m2"
    metric {
      metric_name = "GetMisses"
      namespace   = "AWS/ElastiCache"
      period      = 300
      stat        = "Sum"
      dimensions  = { ReplicationGroupId = var.redis_replication_group_id }
    }
  }

  alarm_actions = [aws_sns_topic.alarm.arn]
  ok_actions    = [aws_sns_topic.alarm.arn]

  tags = {
    Name     = "fiveline-alarm-redis-hitrate-crit"
    Service  = "monitoring"
    Severity = "critical"
  }
}

# Redis Replication Lag > 10초
resource "aws_cloudwatch_metric_alarm" "redis_replication_lag" {
  alarm_name          = "fiveline-alarm-redis-replication-lag"
  alarm_description   = "[Warning] Redis Replication Lag 10초 초과"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  metric_name         = "ReplicationLag"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Maximum"
  threshold           = 10
  treat_missing_data  = "notBreaching"

  dimensions = {
    ReplicationGroupId = var.redis_replication_group_id
  }

  alarm_actions = [aws_sns_topic.alarm.arn]
  ok_actions    = [aws_sns_topic.alarm.arn]

  tags = {
    Name     = "fiveline-alarm-redis-replication-lag"
    Service  = "monitoring"
    Severity = "warning"
  }
}

# ══════════════════════════════════════════════
# EKS / Pod 알람 (Container Insights 필요)
# ══════════════════════════════════════════════

# Pod 재시작 횟수 > 3 (30분 내)
resource "aws_cloudwatch_metric_alarm" "pod_restart" {
  alarm_name          = "fiveline-alarm-pod-restart"
  alarm_description   = "[Warning] Pod 재시작 30분 내 3회 초과"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  metric_name         = "pod_number_of_container_restarts"
  namespace           = "ContainerInsights"
  period              = 1800
  statistic           = "Maximum"
  threshold           = 3
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.eks_cluster_name
  }

  alarm_actions = [aws_sns_topic.alarm.arn]
  ok_actions    = [aws_sns_topic.alarm.arn]

  tags = {
    Name     = "fiveline-alarm-pod-restart"
    Service  = "monitoring"
    Severity = "warning"
  }
}

# HPA 최대 레플리카 도달 (currentReplicas = 6)
# kube-state-metrics → ADOT → ContainerInsights/Prometheus 필요
resource "aws_cloudwatch_metric_alarm" "hpa_maxreplicas" {
  alarm_name          = "fiveline-alarm-hpa-maxreplicas"
  alarm_description   = "[Critical] HPA가 최대 레플리카(6)에 도달 — 용량 부족 가능성"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  metric_name         = "kube_hpa_status_current_replicas"
  namespace           = "ContainerInsights/Prometheus"
  period              = 300
  statistic           = "Maximum"
  threshold           = 6
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.eks_cluster_name
  }

  alarm_actions = [aws_sns_topic.alarm.arn]
  ok_actions    = [aws_sns_topic.alarm.arn]

  tags = {
    Name     = "fiveline-alarm-hpa-maxreplicas"
    Service  = "monitoring"
    Severity = "critical"
  }
}

# CA Pending Pod > 0 (4분 지속) — CA 미동작 감지
resource "aws_cloudwatch_metric_alarm" "ca_pending_pods" {
  alarm_name          = "fiveline-alarm-ca-pending-pods"
  alarm_description   = "[Warning] Pending Pod 4분 이상 지속 — Cluster Autoscaler 미동작 의심"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 4
  datapoints_to_alarm = 4
  metric_name         = "pod_number_of_pending"
  namespace           = "ContainerInsights"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.eks_cluster_name
  }

  alarm_actions = [aws_sns_topic.alarm.arn]
  ok_actions    = [aws_sns_topic.alarm.arn]

  tags = {
    Name     = "fiveline-alarm-ca-pending-pods"
    Service  = "monitoring"
    Severity = "warning"
  }
}

# ══════════════════════════════════════════════
# SLO 알람
# ══════════════════════════════════════════════

# order-service P99 응답시간 > 2초 (ALB 생성 후 활성화)
resource "aws_cloudwatch_metric_alarm" "order_p99_latency" {
  alarm_name          = "fiveline-alarm-order-p99-latency"
  alarm_description   = "[Critical] order-service P99 응답시간 2초 초과"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  extended_statistic  = "p99"
  threshold           = 2
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  alarm_actions = [aws_sns_topic.alarm.arn]
  ok_actions    = [aws_sns_topic.alarm.arn]

  tags = {
    Name     = "fiveline-alarm-order-p99-latency"
    Service  = "monitoring"
    Severity = "critical"
  }
}

# Error Budget Burn Rate > 14.4 (1시간 내 에러 예산 소진 위험)
# 애플리케이션이 fiveline/SLO 네임스페이스로 커스텀 메트릭을 푸시해야 동작
resource "aws_cloudwatch_metric_alarm" "burn_rate_1h" {
  alarm_name          = "fiveline-alarm-burn-rate-1h"
  alarm_description   = "[Critical] 에러 예산 소진율 14.4 초과 (1시간 내 1% 에러 예산 소진 위험)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  metric_name         = "ErrorBudgetBurnRate"
  namespace           = "fiveline/SLO"
  period              = 3600
  statistic           = "Maximum"
  threshold           = 14.4
  treat_missing_data  = "notBreaching"

  dimensions = {
    Service = "order-service"
  }

  alarm_actions = [aws_sns_topic.alarm.arn]
  ok_actions    = [aws_sns_topic.alarm.arn]

  tags = {
    Name     = "fiveline-alarm-burn-rate-1h"
    Service  = "monitoring"
    Severity = "critical"
  }
}
