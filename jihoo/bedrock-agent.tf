# ── Bedrock Agent IAM Role ───────────────────────────────────────────────────

resource "aws_iam_role" "bedrock_agent" {
  name = "mzc-pj4-${local.owner}-bedrock-agent-${local.env}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Service = "data-lake"
    Name    = "mzc-pj4-${local.owner}-bedrock-agent-${local.env}"
  }
}

resource "aws_iam_role_policy" "bedrock_agent" {
  name = "bedrock-agent-policy"
  role = aws_iam_role.bedrock_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "InvokeFoundationModel"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = "arn:aws:bedrock:*::foundation-model/anthropic.claude-3-*"
      },
      {
        Sid    = "MarketplaceSubscribe"
        Effect = "Allow"
        Action = [
          "aws-marketplace:ViewSubscriptions",
          "aws-marketplace:Subscribe",
        ]
        Resource = "*"
      },
    ]
  })
}

# ── Bedrock Agent ────────────────────────────────────────────────────────────

resource "aws_bedrockagent_agent" "ops_assistant" {
  agent_name              = "mzc-pj4-${local.owner}-ops-assistant-${local.env}"
  agent_resource_role_arn = aws_iam_role.bedrock_agent.arn
  foundation_model        = "anthropic.claude-3-haiku-20240307-v1:0"

  instruction = <<-EOT
당신은 AWS 운영 자동화 플랫폼의 한국어 어시스턴트입니다. 운영자의 질문에 데이터를 기반으로 답합니다.

사용 가능한 도구:
- get_dashboard_summary: 특정 날짜의 일간 운영 요약 (총 주문 수, 성공/실패, 응답시간, 알람 수)
- get_resource_check: 미사용 리소스, 태그 누락, 보안 위반 점검 결과
- get_recent_alarms: 최근 발생한 CloudWatch 알람 이력
- query_athena: 자유 SQL 쿼리 (service_events 등 분석)

답변 규칙:
- 추측하지 말 것. 데이터에 없으면 "데이터 없음"이라고 명시
- 구체적 수치를 인용할 것
- 한국어로 친절하게 설명
- 필요 시 여러 도구를 차례로 사용
EOT

  idle_session_ttl_in_seconds = 600
}

# ── Bedrock Agent Action Group ───────────────────────────────────────────────

resource "aws_bedrockagent_agent_action_group" "ops_actions" {
  action_group_name          = "ops-data-actions"
  agent_id                   = aws_bedrockagent_agent.ops_assistant.agent_id
  agent_version              = "DRAFT"
  skip_resource_in_use_check = true

  action_group_executor {
    lambda = aws_lambda_function.bedrock_agent_action.arn
  }

  function_schema {
    member_functions {
      functions {
        name        = "get_dashboard_summary"
        description = "특정 날짜의 일간 운영 대시보드 요약 조회. 총 주문 수, 성공/실패율, 평균/p99 응답시간, 활성 알람 수 등 반환."
        parameters {
          map_block_key = "date"
          type          = "string"
          description   = "조회 날짜 YYYY-MM-DD 형식. 생략 시 오늘 날짜."
          required      = false
        }
      }

      functions {
        name        = "get_resource_check"
        description = "미사용 리소스(EBS·EIP·Snapshot), 태그 누락, 보안그룹 0.0.0.0/0 오픈, RDS Public Access 등 점검 결과 조회."
        parameters {
          map_block_key = "limit"
          type          = "string"
          description   = "조회 항목 수 (기본 20)"
          required      = false
        }
      }

      functions {
        name        = "get_recent_alarms"
        description = "최근 발생한 CloudWatch 알람 이력 조회 (모니터링 담당자 영역, 데이터 없을 수 있음)."
        parameters {
          map_block_key = "limit"
          type          = "string"
          description   = "조회 항목 수 (기본 10)"
          required      = false
        }
      }

      functions {
        name        = "query_athena"
        description = "Athena SQL 쿼리 실행. service_events(EKS 로그), cleansed, raw 테이블에서 SELECT 가능. DML 금지."
        parameters {
          map_block_key = "sql"
          type          = "string"
          description   = "실행할 SELECT SQL 쿼리"
          required      = true
        }
      }
    }
  }
}

# ── Lambda Permission: Bedrock Agent가 Lambda 호출 허용 ─────────────────────

resource "aws_lambda_permission" "bedrock_agent_invoke" {
  statement_id  = "AllowBedrockAgentInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.bedrock_agent_action.function_name
  principal     = "bedrock.amazonaws.com"
  source_arn    = aws_bedrockagent_agent.ops_assistant.agent_arn
}

# ── Bedrock Agent Alias (호출용 안정 별칭) ─────────────────────────────────

resource "aws_bedrockagent_agent_alias" "production" {
  agent_alias_name = "production"
  agent_id         = aws_bedrockagent_agent.ops_assistant.agent_id

  depends_on = [
    aws_bedrockagent_agent_action_group.ops_actions,
  ]
}

# ── 출력: 테스트용 ID ───────────────────────────────────────────────────────

output "bedrock_agent_id" {
  value       = aws_bedrockagent_agent.ops_assistant.agent_id
  description = "Bedrock Agent ID (테스트용)"
}

output "bedrock_agent_alias_id" {
  value       = aws_bedrockagent_agent_alias.production.agent_alias_id
  description = "Agent Alias ID (호출 시 사용)"
}
