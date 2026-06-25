locals {
  project = "fiveline"
}

data "aws_caller_identity" "current" {}

# ════════════════════════════════════════════════════════════════════════════
# GuardDuty
# ════════════════════════════════════════════════════════════════════════════

resource "aws_guardduty_detector" "fiveline" {
  enable = true

  datasources {
    s3_logs {
      enable = true
    }
    kubernetes {
      audit_logs {
        enable = true
      }
    }
    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes {
          enable = true
        }
      }
    }
  }

  tags = {
    Service = "guardduty"
    Name    = "${local.project}-guardduty"
  }
}

resource "aws_sns_topic" "security_alerts" {
  name              = "${local.project}-security-alerts"
  kms_master_key_id = var.kms_secrets_arn

  tags = {
    Service = "guardduty"
    Name    = "${local.project}-security-alerts"
  }
}

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

resource "aws_sns_topic_subscription" "security_alerts_email" {
  count     = var.security_alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = var.security_alert_email
}

# ════════════════════════════════════════════════════════════════════════════
# GuardDuty Auto-remediation: Lambda → WAF IP Set 자동 차단
# ════════════════════════════════════════════════════════════════════════════

resource "aws_iam_role" "guardduty_auto_block" {
  name = "${local.project}-guardduty-auto-block"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Service = "guardduty"
    Name    = "${local.project}-guardduty-auto-block-role"
  }
}

resource "aws_iam_role_policy" "guardduty_auto_block" {
  name = "${local.project}-guardduty-auto-block-policy"
  role = aws_iam_role.guardduty_auto_block.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["wafv2:GetIPSet", "wafv2:UpdateIPSet"]
        Resource = var.guardduty_blocked_ip_set_arn
      },
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.security_alerts.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

data "archive_file" "guardduty_auto_block" {
  type        = "zip"
  output_path = "${path.module}/guardduty_auto_block.zip"

  source {
    content  = <<-EOT
      import boto3, json, os

      def lambda_handler(event, context):
          detail = event.get('detail', {})
          action = detail.get('service', {}).get('action', {})

          remote_ip = None
          if 'networkConnectionAction' in action:
              remote_ip = action['networkConnectionAction']['remoteIpDetails']['ipAddressV4']
          elif 'awsApiCallAction' in action:
              remote_ip = action['awsApiCallAction'].get('remoteIpDetails', {}).get('ipAddressV4')
          elif 'portProbeAction' in action:
              probes = action['portProbeAction'].get('portProbeDetails', [])
              if probes:
                  remote_ip = probes[0]['remoteIpDetails']['ipAddressV4']

          if not remote_ip:
              print(f"No IP in finding: {detail.get('type', 'unknown')}")
              return {'statusCode': 200, 'body': 'No IP to block'}

          ip_cidr = f"{remote_ip}/32"
          waf = boto3.client('wafv2', region_name='us-east-1')

          resp = waf.get_ip_set(
              Name=os.environ['WAF_IP_SET_NAME'],
              Scope='CLOUDFRONT',
              Id=os.environ['WAF_IP_SET_ID']
          )
          addresses = resp['IPSet']['Addresses']

          if ip_cidr not in addresses:
              waf.update_ip_set(
                  Name=os.environ['WAF_IP_SET_NAME'],
                  Scope='CLOUDFRONT',
                  Id=os.environ['WAF_IP_SET_ID'],
                  Addresses=addresses + [ip_cidr],
                  LockToken=resp['LockToken']
              )
              boto3.client('sns').publish(
                  TopicArn=os.environ['SNS_TOPIC_ARN'],
                  Subject='[Fiveline] GuardDuty 자동 차단 완료',
                  Message=f"악성 IP {ip_cidr} WAF IP Set 자동 추가 완료\n유형: {detail.get('type','unknown')}\n심각도: {detail.get('severity','unknown')}"
              )
              print(f"Blocked: {ip_cidr}")
          else:
              print(f"Already blocked: {ip_cidr}")

          return {'statusCode': 200, 'body': ip_cidr}
    EOT
    filename = "lambda_function.py"
  }
}

resource "aws_cloudwatch_log_group" "guardduty_auto_block" {
  name              = "/aws/lambda/${local.project}-guardduty-auto-block"
  retention_in_days = 30

  tags = {
    Service = "guardduty"
    Name    = "${local.project}-guardduty-auto-block-logs"
  }
}

resource "aws_lambda_function" "guardduty_auto_block" {
  filename         = data.archive_file.guardduty_auto_block.output_path
  function_name    = "${local.project}-guardduty-auto-block"
  role             = aws_iam_role.guardduty_auto_block.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.12"
  source_code_hash = data.archive_file.guardduty_auto_block.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      WAF_IP_SET_ID   = var.guardduty_blocked_ip_set_id
      WAF_IP_SET_NAME = "${local.project}-guardduty-blocked-ips"
      SNS_TOPIC_ARN   = aws_sns_topic.security_alerts.arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.guardduty_auto_block]

  tags = {
    Service = "guardduty"
    Name    = "${local.project}-guardduty-auto-block"
  }
}

resource "aws_cloudwatch_event_rule" "guardduty_high_findings" {
  name        = "${local.project}-guardduty-high-findings"
  description = "GuardDuty HIGH 심각도 Finding → Lambda 자동 차단"

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
    detail = {
      severity = [{ numeric = [">=", 7] }]
    }
  })

  tags = {
    Service = "guardduty"
    Name    = "${local.project}-guardduty-high-rule"
  }
}

resource "aws_lambda_permission" "guardduty_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.guardduty_auto_block.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.guardduty_high_findings.arn
}

resource "aws_cloudwatch_event_target" "guardduty_to_lambda" {
  rule      = aws_cloudwatch_event_rule.guardduty_high_findings.name
  target_id = "GuardDutyToLambda"
  arn       = aws_lambda_function.guardduty_auto_block.arn
}

# ════════════════════════════════════════════════════════════════════════════
# ════════════════════════════════════════════════════════════════════════════
# CloudTrail + VPC Flow Logs
# ════════════════════════════════════════════════════════════════════════════

resource "aws_s3_bucket" "cloudtrail" {
  bucket        = "${local.project}-cloudtrail-${data.aws_caller_identity.current.account_id}"
  force_destroy = false

  tags = {
    Service = "cloudtrail"
    Name    = "${local.project}-cloudtrail"
  }
}

resource "aws_s3_bucket_logging" "cloudtrail" {
  bucket        = aws_s3_bucket.cloudtrail.id
  target_bucket = aws_s3_bucket.cloudtrail.id
  target_prefix = "s3-access/"
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_secrets_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    id     = "cloudtrail-retention"
    status = "Enabled"

    filter {}

    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }

    expiration {
      days = 365
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.cloudtrail.arn
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      },
      {
        Sid       = "DenyHTTP"
        Effect    = "Deny"
        Principal = "*" # nosonar — HTTPS 강제 Deny 정책 (보안 강화)
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.cloudtrail.arn,
          "${aws_s3_bucket.cloudtrail.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.cloudtrail]
}

resource "aws_cloudtrail" "fiveline" {
  name                          = "${local.project}-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true

  dynamic "event_selector" {
    for_each = var.s3_frontend_arn != "" ? [1] : []
    content {
      read_write_type           = "All"
      include_management_events = true

      data_resource {
        type   = "AWS::S3::Object"
        values = ["${var.s3_frontend_arn}/"]
      }
    }
  }

  tags = {
    Service = "cloudtrail"
    Name    = "${local.project}-trail"
  }

  depends_on = [aws_s3_bucket_policy.cloudtrail]
}

resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/aws/vpc/flowlogs/${local.project}"
  retention_in_days = 30

  tags = {
    Service = "cloudtrail"
    Name    = "${local.project}-vpc-flow-logs"
  }
}

resource "aws_iam_role" "vpc_flow_logs_role" {
  name = "${local.project}-vpc-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Service = "cloudtrail"
    Name    = "${local.project}-vpc-flow-logs-role"
  }
}

resource "aws_iam_role_policy" "vpc_flow_logs_policy" {
  name = "${local.project}-vpc-flow-logs-policy"
  role = aws_iam_role.vpc_flow_logs_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "${aws_cloudwatch_log_group.vpc_flow_logs.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups"]
        Resource = "*" # nosonar
      }
    ]
  })
}

resource "aws_flow_log" "fiveline_vpc" {
  vpc_id          = var.vpc_id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.vpc_flow_logs_role.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_logs.arn

  tags = {
    Service = "cloudtrail"
    Name    = "${local.project}-vpc-flow-log"
  }
}

# ════════════════════════════════════════════════════════════════════════════
# WAF v2 — Regional (ap-northeast-2)
# CloudFront WAF는 cdn 모듈에서 관리 (cloudfront distribution과 동일 모듈)
# ════════════════════════════════════════════════════════════════════════════

# ── 이커머스 특화 Custom Rule Group (REGIONAL) ────────────────────────────

resource "aws_wafv2_rule_group" "ecommerce_ratelimit" {
  name        = "${local.project}-ecommerce-ratelimit"
  scope       = "REGIONAL"
  capacity    = 100
  description = "E-commerce Rate Limit rules - blocks credential stuffing and card BIN attacks"

  rule {
    name     = "login-rate-limit"
    priority = 1

    statement {
      rate_based_statement {
        limit              = 100
        aggregate_key_type = "IP"

        scope_down_statement {
          byte_match_statement {
            search_string         = "/api/auth/login"
            positional_constraint = "STARTS_WITH"
            field_to_match {
              uri_path {}
            }
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
      }
    }

    action {
      block {}
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "login-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "checkout-rate-limit"
    priority = 2

    statement {
      rate_based_statement {
        limit              = 100
        aggregate_key_type = "IP"

        scope_down_statement {
          byte_match_statement {
            search_string         = "/api/orders"
            positional_constraint = "STARTS_WITH"
            field_to_match {
              uri_path {}
            }
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
      }
    }

    action {
      block {}
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "checkout-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "product-scraping-limit"
    priority = 3

    statement {
      rate_based_statement {
        limit              = 500
        aggregate_key_type = "IP"

        scope_down_statement {
          byte_match_statement {
            search_string         = "/api/products"
            positional_constraint = "STARTS_WITH"
            field_to_match {
              uri_path {}
            }
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
      }
    }

    action {
      block {}
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "product-scraping-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.project}-ecommerce-ratelimit"
    sampled_requests_enabled   = true
  }

  tags = {
    Name    = "${local.project}-ecommerce-ratelimit"
    Service = "waf"
  }
}

# ── Regional WAF (ap-northeast-2) ────────────────────────────────────────

resource "aws_wafv2_web_acl" "regional" {
  name        = "${local.project}-regional-waf"
  scope       = "REGIONAL"
  description = "Fiveline ALB WAF - API layer defense in depth"

  default_action {
    allow {}
  }

  rule {
    name     = "block-direct-alb-access"
    priority = 0

    statement {
      not_statement {
        statement {
          byte_match_statement {
            search_string = var.cloudfront_origin_secret
            field_to_match {
              single_header {
                name = "x-origin-verify"
              }
            }
            positional_constraint = "EXACTLY"
            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
      }
    }

    action {
      block {}
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "block-direct-alb-access"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "ecommerce-ratelimit"
    priority = 1

    statement {
      rule_group_reference_statement {
        arn = aws_wafv2_rule_group.ecommerce_ratelimit.arn
      }
    }

    override_action {
      none {}
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "ecommerce-ratelimit-group"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RegionalAWSManagedRulesAmazonIpReputationList"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RegionalAWSManagedRulesCommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 4

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RegionalAWSManagedRulesSQLiRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesAnonymousIpList"
    priority = 5

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAnonymousIpList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RegionalAWSManagedRulesAnonymousIpList"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesLinuxRuleSet"
    priority = 6

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesLinuxRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RegionalAWSManagedRulesLinuxRuleSet"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.project}-regional-waf"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "${local.project}-regional-waf"
  }
}

resource "aws_cloudwatch_log_group" "waf_regional" {
  name              = "aws-waf-logs-${local.project}-regional"
  retention_in_days = 90

  tags = {
    Service = "waf"
    Name    = "${local.project}-waf-regional-logs"
  }
}

resource "aws_wafv2_web_acl_logging_configuration" "regional" {
  log_destination_configs = [aws_cloudwatch_log_group.waf_regional.arn]
  resource_arn            = aws_wafv2_web_acl.regional.arn
}
