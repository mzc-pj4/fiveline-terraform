# ── GuardDuty + SNS 알림 ──────────────────────────────────────────────────────
# SEC: CloudTrail(사후 감사) + GuardDuty(실시간 탐지) 조합
#
# GuardDuty = SIEM 기능: ML 기반으로 위협 패턴 자동 분석
#  - 크립토 마이닝 탐지 (비정상 CPU 스파이크 + 외부 마이닝 풀 통신)
#  - Tor 노드 접속 탐지
#  - IAM 자격증명 이상 사용 탐지 (예: 새 지역에서 갑자기 API 호출)
#  - EKS 감사 로그 분석 (컨테이너 탈출 시도, 권한 상승 등)
#  - S3 버킷 이상 접근 탐지 (대량 데이터 유출 시도)
#
# Severity 기준:
#  - LOW (1-3.9): 정보성, 자동 알림 불필요
#  - MEDIUM (4-6.9): 운영팀 검토 권장 → SNS 알림
#  - HIGH (7-10): 즉시 대응 필요 → SNS 알림 (같은 토픽, 심각도 표시)

resource "aws_guardduty_detector" "fiveline" {
  enable = true

  datasources {
    s3_logs {
      enable = true  # S3 버킷 이상 접근 탐지
    }
    kubernetes {
      audit_logs {
        enable = true  # EKS 권한 상승/컨테이너 탈출 탐지
      }
    }
    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes {
          enable = true  # EC2 EBS 볼륨 맬웨어 스캔
        }
      }
    }
  }

  tags = {
    Service = "guardduty"
    Name    = "${local.project}-guardduty"
  }
}

# ── SNS 토픽 (보안 알림 수신) ─────────────────────────────────────────────────

resource "aws_sns_topic" "security_alerts" {
  name              = "${local.project}-security-alerts"
  kms_master_key_id = aws_kms_key.secrets_manager.arn  # SEC: 보안 알림 전송 중 암호화

  tags = {
    Service = "guardduty"
    Name    = "${local.project}-security-alerts"
  }
}

# ── CloudWatch Events Rule → GuardDuty Finding 탐지 ──────────────────────────
# Severity >= 4 (MEDIUM 이상)만 알림 — LOW는 노이즈 제거

resource "aws_cloudwatch_event_rule" "guardduty_findings" {
  name        = "${local.project}-guardduty-findings"
  description = "GuardDuty MEDIUM+ 심각도 Finding 실시간 탐지"

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
    detail = {
      severity = [{ numeric = [">=", 4] }]
    }
  })

  tags = {
    Service = "guardduty"
    Name    = "${local.project}-guardduty-rule"
  }
}

resource "aws_cloudwatch_event_target" "guardduty_to_sns" {
  rule      = aws_cloudwatch_event_rule.guardduty_findings.name
  target_id = "GuardDutyToSNS"
  arn       = aws_sns_topic.security_alerts.arn

  input_transformer {
    input_paths = {
      severity    = "$.detail.severity"
      type        = "$.detail.type"
      description = "$.detail.description"
      account     = "$.detail.accountId"
      region      = "$.region"
      time        = "$.time"
    }
    input_template = <<-EOT
      "GuardDuty 보안 알림"
      "계정: <account>"
      "리전: <region>"
      "시간: <time>"
      "심각도: <severity>"
      "유형: <type>"
      "설명: <description>"
      "AWS Console: https://ap-northeast-2.console.aws.amazon.com/guardduty/home?region=ap-northeast-2#/findings"
    EOT
  }
}

# SNS 토픽이 EventBridge 이벤트를 수신하도록 허용
resource "aws_sns_topic_policy" "guardduty_alerts" {
  arn = aws_sns_topic.security_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowEventBridgePublish"
      Effect = "Allow"
      Principal = {
        Service = "events.amazonaws.com"
      }
      Action   = "SNS:Publish"
      Resource = aws_sns_topic.security_alerts.arn
      Condition = {
        ArnLike = {
          "aws:SourceArn" = aws_cloudwatch_event_rule.guardduty_findings.arn
        }
      }
    }]
  })
}

# ── SNS 이메일 구독 (운영팀 알림) ─────────────────────────────────────────────
# 이메일 주소는 terraform.tfvars 또는 환경변수로 주입 (하드코딩 금지)
# 구독 확인 이메일이 수신되면 클릭하여 활성화 필요

resource "aws_sns_topic_subscription" "security_alerts_email" {
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = var.security_alert_email
}
