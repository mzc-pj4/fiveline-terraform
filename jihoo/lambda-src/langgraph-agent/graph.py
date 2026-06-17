"""
LangGraph State Machine — Bedrock Claude 3 Haiku + 4 Tools

흐름:
1. reasoning_node: LLM이 다음에 무엇을 할지 판단 (도구 호출 또는 최종 응답)
2. tool_node: 도구 실행
3. 도구 결과 받아서 다시 reasoning_node로 (loop)
4. LLM이 도구 호출 없이 응답하면 END
"""

from typing import Annotated, Sequence
from typing_extensions import TypedDict

from langchain_core.messages import BaseMessage, SystemMessage
from langchain_aws import ChatBedrockConverse
from langgraph.graph import StateGraph, END
from langgraph.graph.message import add_messages
from langgraph.prebuilt import ToolNode

from tools import TOOLS


SYSTEM_PROMPT = """당신은 AWS 운영 자동화 플랫폼의 한국어 SRE 어시스턴트입니다 (LangGraph V2).

# 사용 가능한 도구 (6개)
- get_dashboard_summary(date?): 일간 운영 요약 (totalLogEvents, errorRate, peakHour, topErrorStream, findings)
- get_resource_check(limit?): 리소스 점검 (UNUSED_RESOURCE, MISSING_TAGS 등)
- get_recent_alarms(limit?): 최근 CloudWatch 알람 (alarmName, status, timestamp)
- get_metrics(minutes?): 최근 ALB·RDS 메트릭 (CPU, connections, 5xx, latency)
- query_athena(sql): Athena SELECT (service_events, events_hourly, resource_findings_daily, cw_metrics)
- search_reports(question, top_k?): 과거 일간 리포트(마크다운) 의미 검색 (RAG, Bedrock Titan Embed v2 + DDB 코사인 유사도).

# 도구 선택 우선순위 (★ 도구 호출 전 키워드 점검)
질문에 다음 키워드 1개라도 포함되면 **반드시 search_reports 먼저** 호출하라:
  - 시간: "지난주", "지난달", "어제", "최근 N일", "과거", "이전"
  - 문서: "리포트", "보고서", "보고", "리뷰"
  - 분석: "트렌드", "추이", "패턴", "변화", "이력", "히스토리"
예) "지난주 RDS 이슈 있었어?", "어제 리포트 요약", "최근 일주일 트렌드"
→ 이런 질문은 현재 시점 데이터(get_dashboard_summary 등)가 아닌 과거 누적 리포트 검색이 정답이다.

현재 시점 질문이면 다른 도구 사용:
  "지금 미사용 리소스" → get_resource_check
  "오늘 알람" → get_recent_alarms
  "방금 메트릭" → get_metrics

# 멀티스텝 추론 원칙 (★ 핵심)
1. **단순 질문**: 도구 1번 호출 후 바로 답변.
2. **복합·원인 분석 질문**: 반드시 도구 2~5개를 순차 호출.
   - 예) "어제 매출 떨어진 원인" → summary → alarms → metrics → athena
   - 한 도구 결과를 보고 **다음 어떤 도구를 부를지** 명시적으로 결정.
3. **모르면 데이터 가져오기**. 추측 금지.

# 답변 형식
- 사실 인용: "errorRate 8.01% (출처: dashboard_summary 2026-06-09)"
- 인과 추정: "X가 Y의 원인으로 추정됨 (근거: ...)"
- 권고: **즉시 / 단기 / 장기** 세 가지로 구분.

# 절대 규칙
- 데이터에 없는 수치 만들기 X
- 도구 결과를 그대로 출력 X (반드시 한국어로 종합 정리)
- 모든 출처를 답변 끝에 한 줄 명시
"""


class AgentState(TypedDict):
    messages: Annotated[Sequence[BaseMessage], add_messages]


def _get_llm():
    """Bedrock Claude 3 Haiku 클라이언트 (도구 바인딩 포함)"""
    llm = ChatBedrockConverse(
        model_id="anthropic.claude-3-haiku-20240307-v1:0",
        region_name="ap-northeast-2",
        temperature=0.2,    # V2: 더 결정적·논리적
        max_tokens=3072,    # V2: 멀티스텝 후 종합 답변용 여유
    )
    return llm.bind_tools(TOOLS)


def reasoning_node(state: AgentState) -> dict:
    """LLM이 도구 호출 또는 최종 응답 생성"""
    llm = _get_llm()
    msgs = [SystemMessage(content=SYSTEM_PROMPT)] + list(state["messages"])
    response = llm.invoke(msgs)
    return {"messages": [response]}


def should_continue(state: AgentState) -> str:
    """마지막 메시지에 tool_calls가 있으면 도구 실행, 없으면 END"""
    last = state["messages"][-1]
    if hasattr(last, "tool_calls") and last.tool_calls:
        return "tools"
    return END


def build_graph():
    workflow = StateGraph(AgentState)
    workflow.add_node("reasoning", reasoning_node)
    workflow.add_node("tools", ToolNode(TOOLS))

    workflow.set_entry_point("reasoning")
    workflow.add_conditional_edges("reasoning", should_continue, {"tools": "tools", END: END})
    workflow.add_edge("tools", "reasoning")

    return workflow.compile()


# 콜드 스타트 시 1회만 컴파일
GRAPH = build_graph()
