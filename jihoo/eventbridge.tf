# ── EventBridge: Report Generator 스케줄 ────────────────────────────────────

# 일간 리포트 — 매일 06:00 UTC (한국 15:00)
resource "aws_cloudwatch_event_rule" "report_daily" {
  name                = "mzc-pj4-${local.owner}-report-daily-${local.env}"
  description         = "일간 운영 리포트 — 매일 KST 15:00"
  schedule_expression = "cron(0 6 * * ? *)"
  state               = "ENABLED"

  tags = {
    Service = "data-lake"
    Name    = "mzc-pj4-${local.owner}-report-daily-${local.env}"
  }
}

resource "aws_cloudwatch_event_target" "report_daily" {
  rule      = aws_cloudwatch_event_rule.report_daily.name
  target_id = "lambda"
  arn       = aws_lambda_function.report_generator.arn
  input     = jsonencode({ type = "daily" })
}

resource "aws_lambda_permission" "allow_eb_daily" {
  statement_id  = "AllowDailyReport"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.report_generator.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.report_daily.arn
}

# 주간 리포트 — 매주 화요일 06:05 UTC (한국 15:05)
resource "aws_cloudwatch_event_rule" "report_weekly" {
  name                = "mzc-pj4-${local.owner}-report-weekly-${local.env}"
  description         = "주간 운영 리포트 — 매주 화요일 KST 15:05"
  schedule_expression = "cron(5 6 ? * TUE *)"
  state               = "ENABLED"

  tags = {
    Service = "data-lake"
    Name    = "mzc-pj4-${local.owner}-report-weekly-${local.env}"
  }
}

resource "aws_cloudwatch_event_target" "report_weekly" {
  rule      = aws_cloudwatch_event_rule.report_weekly.name
  target_id = "lambda"
  arn       = aws_lambda_function.report_generator.arn
  input     = jsonencode({ type = "weekly" })
}

resource "aws_lambda_permission" "allow_eb_weekly" {
  statement_id  = "AllowWeeklyReport"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.report_generator.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.report_weekly.arn
}
