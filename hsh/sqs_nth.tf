# ──────────────────────────────────────────────
# SQS Queue — Node Termination Handler 전용
# ──────────────────────────────────────────────
resource "aws_sqs_queue" "nth" {
  name                       = "fiveline-prod-nth-queue"
  message_retention_seconds  = 300  # Spot 인터럽션 2분 대응 후 불필요
  visibility_timeout_seconds = 30

  tags = {
    Name    = "fiveline-prod-nth-queue"
    Service = "monitoring"
  }
}

# EventBridge → SQS 전송 허용 정책
resource "aws_sqs_queue_policy" "nth" {
  queue_url = aws_sqs_queue.nth.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowEventBridgeSend"
      Effect = "Allow"
      Principal = {
        Service = "events.amazonaws.com"
      }
      Action   = "sqs:SendMessage"
      Resource = aws_sqs_queue.nth.arn
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = [
            aws_cloudwatch_event_rule.spot_interruption.arn,
            aws_cloudwatch_event_rule.asg_lifecycle.arn,
            aws_cloudwatch_event_rule.rebalance.arn,
          ]
        }
      }
    }]
  })
}

# ──────────────────────────────────────────────
# EventBridge Rule 1: Spot 인터럽션 (2분 전 경고)
# ──────────────────────────────────────────────
resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "fiveline-prod-spot-interruption"
  description = "EC2 Spot Instance Interruption Warning → NTH SQS"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })

  tags = {
    Name    = "fiveline-prod-spot-interruption"
    Service = "monitoring"
  }
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  rule = aws_cloudwatch_event_rule.spot_interruption.name
  arn  = aws_sqs_queue.nth.arn
}

# ──────────────────────────────────────────────
# EventBridge Rule 2: ASG 인스턴스 종료 Lifecycle
# ──────────────────────────────────────────────
resource "aws_cloudwatch_event_rule" "asg_lifecycle" {
  name        = "fiveline-prod-asg-lifecycle"
  description = "ASG Instance Terminate Lifecycle Action → NTH SQS"

  event_pattern = jsonencode({
    source      = ["aws.autoscaling"]
    detail-type = ["EC2 Instance-terminate Lifecycle Action"]
  })

  tags = {
    Name    = "fiveline-prod-asg-lifecycle"
    Service = "monitoring"
  }
}

resource "aws_cloudwatch_event_target" "asg_lifecycle" {
  rule = aws_cloudwatch_event_rule.asg_lifecycle.name
  arn  = aws_sqs_queue.nth.arn
}

# ──────────────────────────────────────────────
# EventBridge Rule 3: EC2 Rebalance 권고
# ──────────────────────────────────────────────
resource "aws_cloudwatch_event_rule" "rebalance" {
  name        = "fiveline-prod-ec2-rebalance"
  description = "EC2 Instance Rebalance Recommendation → NTH SQS"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance Rebalance Recommendation"]
  })

  tags = {
    Name    = "fiveline-prod-ec2-rebalance"
    Service = "monitoring"
  }
}

resource "aws_cloudwatch_event_target" "rebalance" {
  rule = aws_cloudwatch_event_rule.rebalance.name
  arn  = aws_sqs_queue.nth.arn
}
