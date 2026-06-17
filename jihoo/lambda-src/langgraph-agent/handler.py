"""
Lambda Entry Point — LangGraph V2 + Checkpointer Lite

호출 형식:
  {"input": "오늘 미사용 리소스 알려줘"}
    → 새 세션 생성 + 답변 + 새 session_id 반환
  {"input": "그거 자세히", "session_id": "<이전 session_id>"}
    → 이전 대화 컨텍스트 자동 로드 + 답변

응답:
  {
    "answer": "...한국어 답변...",
    "session_id": "...",
    "trace": [메시지 1, 메시지 2, ...]
  }

Checkpointer Lite 동작:
  1. session_id 받음 (없으면 새로 생성)
  2. DDB conversation_history 에서 이전 메시지 로드
  3. 이전 메시지 + 새 질문 → LangGraph 실행
  4. 결과 메시지 전체 → DDB 다시 저장 (TTL 30일)
"""

import os
import time
import uuid

import boto3
from langchain_core.messages import HumanMessage, AIMessage

from graph import GRAPH

CONV_TABLE = os.environ.get("CONVERSATION_TABLE", "")
TTL_DAYS = int(os.environ.get("CONVERSATION_TTL_DAYS", "30"))
MAX_HISTORY = int(os.environ.get("MAX_HISTORY_MESSAGES", "20"))  # 너무 길면 컨텍스트 비용 ↑

ddb = boto3.resource("dynamodb")


def _serialize_message(msg):
    """LangChain Message → JSON dict (trace 출력용)"""
    msg_type = msg.__class__.__name__
    content = getattr(msg, "content", None)

    if isinstance(content, list):
        text_parts = []
        for part in content:
            if isinstance(part, dict) and "text" in part:
                text_parts.append(part["text"])
            elif isinstance(part, str):
                text_parts.append(part)
        content = "\n".join(text_parts) if text_parts else None

    tool_calls = getattr(msg, "tool_calls", None)
    serialized = {
        "type": msg_type,
        "content": content[:1000] if isinstance(content, str) else content,
    }
    if tool_calls:
        serialized["tool_calls"] = [
            {"name": tc.get("name"), "args": tc.get("args", {})}
            for tc in tool_calls
        ]
    return serialized


def _msg_to_dict(msg):
    """LangChain Message → 저장용 간단 dict (Human/AI 텍스트만, 도구 결과 제외)"""
    cls = msg.__class__.__name__
    content = getattr(msg, "content", "")
    if isinstance(content, list):
        text = "\n".join(p.get("text", "") if isinstance(p, dict) else str(p) for p in content)
    else:
        text = content or ""
    if cls == "HumanMessage":
        return {"role": "user", "text": text}
    if cls == "AIMessage" and text.strip():
        return {"role": "assistant", "text": text}
    return None  # 도구 호출/결과는 저장 안 함 (다음 턴에 재실행)


def _dict_to_msg(d):
    """저장 dict → LangChain Message (재주입용)"""
    if d["role"] == "user":
        return HumanMessage(content=d["text"])
    return AIMessage(content=d["text"])


def load_history(session_id):
    """DDB에서 이전 대화 메시지 목록 로드"""
    if not CONV_TABLE or not session_id:
        return []
    try:
        resp = ddb.Table(CONV_TABLE).get_item(Key={"session_id": session_id})
        item = resp.get("Item")
        if not item:
            return []
        return item.get("messages", [])
    except Exception as e:
        print(f"load_history error: {e}")
        return []


def save_history(session_id, messages):
    """대화 메시지 전체를 DDB에 저장 (TTL 30일)"""
    if not CONV_TABLE or not session_id:
        return
    # 너무 긴 히스토리는 앞부분 자름
    trimmed = messages[-MAX_HISTORY:] if len(messages) > MAX_HISTORY else messages
    expires_at = int(time.time()) + (TTL_DAYS * 86400)
    try:
        ddb.Table(CONV_TABLE).put_item(Item={
            "session_id": session_id,
            "messages": trimmed,
            "expires_at": expires_at,
            "updated_at": int(time.time()),
        })
    except Exception as e:
        print(f"save_history error: {e}")


def handler(event, context):
    user_input = event.get("input", "")
    if not user_input:
        return {"error": "input 필드 필수. 예: {\"input\":\"오늘 미사용 리소스 알려줘\"}"}

    session_id = event.get("session_id") or str(uuid.uuid4())

    # 1) 이전 대화 로드
    history_dicts = load_history(session_id)
    history_msgs = [_dict_to_msg(d) for d in history_dicts]

    # 2) 새 질문 + 이전 컨텍스트 = 입력
    input_messages = history_msgs + [HumanMessage(content=user_input)]

    # 3) LangGraph 실행 (V2: recursion_limit=16 → 도구 호출 최대 약 8 라운드)
    try:
        result = GRAPH.invoke(
            {"messages": input_messages},
            config={"recursion_limit": 16},
        )
    except Exception as e:
        return {"error": str(e), "errorType": type(e).__name__, "session_id": session_id}

    messages = result.get("messages", [])
    final = messages[-1] if messages else None

    # 4) 최종 답변 추출
    answer = ""
    if final:
        content = getattr(final, "content", "")
        if isinstance(content, list):
            for part in content:
                if isinstance(part, dict) and "text" in part:
                    answer += part["text"]
                elif isinstance(part, str):
                    answer += part
        else:
            answer = content

    # 5) 대화 메시지를 DDB에 저장 (Human/AI 텍스트만 — 도구 결과 제외)
    to_save = [d for d in (_msg_to_dict(m) for m in messages) if d]
    save_history(session_id, to_save)

    return {
        "answer": answer,
        "session_id": session_id,
        "historyMessageCount": len(to_save),
        "trace": [_serialize_message(m) for m in messages],
    }
