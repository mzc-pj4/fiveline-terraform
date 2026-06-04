# ──────────────────────────────────────────────
# SNS Topic
# ──────────────────────────────────────────────
resource "aws_sns_topic" "alarm" {
  name = "fiveline-prod-alarm-topic"

  tags = {
    Name    = "fiveline-prod-alarm-topic"
    Service = "monitoring"
  }
}

# CloudWatch가 SNS에 publish할 수 있도록 허용
resource "aws_sns_topic_policy" "alarm" {
  arn = aws_sns_topic.alarm.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudWatchPublish"
        Effect = "Allow"
        Principal = {
          Service = "cloudwatch.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.alarm.arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" = "arn:aws:cloudwatch:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:alarm:*"
          }
        }
      }
    ]
  })
}

# ──────────────────────────────────────────────
# 구독: Lambda (알람 핸들러)
# ──────────────────────────────────────────────
resource "aws_sns_topic_subscription" "lambda" {
  topic_arn = aws_sns_topic.alarm.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.alarm_handler.arn
}

# ──────────────────────────────────────────────
# 구독: 이메일 (선택 — alarm_email 변수가 있을 때만 생성)
# ──────────────────────────────────────────────
resource "aws_sns_topic_subscription" "email" {
  count = var.alarm_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.alarm.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}
