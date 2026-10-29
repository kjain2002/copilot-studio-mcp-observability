import hashlib
import json
from datetime import UTC, datetime
from typing import Any

FIELDS = (
    "ConversationId", "TurnId", "UserId", "BotName", "BotId", "ToolCallTime", "ToolName",
    "ToolCategory", "ToolCallId", "SqlQuery", "Status", "DurationMs", "QueryResult",
    "UserMessage", "AgentResponse", "ErrorCode", "ErrorMessage", "HttpStatusCode",
    "EnvironmentId", "TranscriptId", "RecordId", "SourceModifiedOn", "CorrelationQuality",
    "QueryAvailability", "SourceEvent", "SchemaVersion",
)


def object_value(value: Any, context: str) -> dict[str, Any]:
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except json.JSONDecodeError:
            raise ValueError(f"Invalid JSON in {context}; payload omitted for privacy") from None
    if not isinstance(value, dict):
        raise ValueError(f"Expected object in {context}; verify transcript contract")
    return value


def timestamp(activity: dict[str, Any]) -> int:
    value = activity.get("timestampMs")
    if value is not None:
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ValueError("Invalid activity timestampMs")
        return int(value)
    if activity.get("timestamp"):
        parsed = datetime.fromisoformat(activity["timestamp"].replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError("Activity timestamp must include a timezone")
        return int(parsed.timestamp() * 1000)
    raise ValueError("Activity has no usable timestamp")


def query_text(start: dict[str, Any] | None) -> str:
    if start is None:
        return ""
    value = object_value(start.get("value"), "tool start")
    parameters = value.get("hiddenFilledParameters", {})
    if not isinstance(parameters, dict):
        raise ValueError("Unsupported hiddenFilledParameters shape")
    body = parameters.get("body")
    if isinstance(body, str) and body.lstrip().startswith("{"):
        body = object_value(body, "tool parameters")
    if isinstance(body, dict):
        for key in ("sqlQuery", "query", "daxQuery"):
            if isinstance(body.get(key), str):
                return body[key]
        return ""
    return body if isinstance(body, str) else ""


def result_summary(value: dict[str, Any]) -> str:
    if value.get("errorCode"):
        return f"ERROR: {value['errorCode']} - {value.get('errorMessage', '')}"[:500]
    result = value.get("result")
    if result is None:
        return ""
    if isinstance(result, str):
        try:
            parsed = json.loads(result)
        except json.JSONDecodeError:
            parsed = result
    else:
        parsed = result
    if isinstance(parsed, dict) and isinstance(parsed.get("content"), list):
        texts = [part["text"] for part in parsed["content"]
                 if isinstance(part, dict) and isinstance(part.get("text"), str)]
        text = "\n".join(texts)
        if "ReferenceId:" in text and "\n" in text:
            candidate = text.split("\n", 1)[1]
            try:
                data = json.loads(candidate)
            except json.JSONDecodeError:
                data = None
            if isinstance(data, dict) and isinstance(data.get("rows"), list):
                columns = ", ".join(str(c) for c in data.get("columns", []))
                preview = "\n".join(" | ".join(str(v) for v in row) for row in data["rows"][:5])
                text = f"OK: {data.get('row_count', 'unknown')} rows [{columns}]\n{preview}"
                if data.get("truncated"):
                    text += "\n(truncated)"
    else:
        text = parsed if isinstance(parsed, str) else json.dumps(parsed, ensure_ascii=True)
    return text if len(text) <= 500 else text[:500] + "\n(truncated)"


def is_consent(value: dict[str, Any]) -> bool:
    result = value.get("result")
    if isinstance(result, str):
        try:
            result = json.loads(result)
        except json.JSONDecodeError:
            return False
    return isinstance(result, dict) and result.get("status") == "suspended_for_consent"


def parse_transcript(
    transcript: dict[str, Any], environment_id: str,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    transcript_id = transcript["conversationtranscriptid"]
    meta = object_value(transcript.get("metadata"), "metadata")
    content = object_value(transcript.get("content"), "content")
    if not isinstance(content.get("activities"), list):
        raise ValueError("Transcript lacks activities array; verify recording and payload contract")
    activities = sorted(content["activities"], key=timestamp)
    bot_id = str(meta.get("BotId", ""))
    conversation_ids = {a["conversation"]["id"] for a in activities
                        if isinstance(a.get("conversation"), dict) and a["conversation"].get("id")}
    if len(conversation_ids) > 1:
        raise ValueError("Multiple conversation IDs in one transcript")
    conversation_id = next(iter(conversation_ids), "")
    name = transcript.get("name", "")
    if not conversation_id and bot_id and name.endswith("_" + bot_id):
        conversation_id = name[:-(len(bot_id) + 1)]
    if not conversation_id:
        raise ValueError("Cannot establish conversation ID without guessing")
    users = [a for a in activities if a.get("type") == "message"
             and a.get("from", {}).get("role") in (1, "user")]
    replies = [a for a in activities if a.get("type") == "message"
               and a.get("from", {}).get("role") in (0, "bot", "assistant") and a.get("text")]
    pending: dict[str, tuple[int, dict[str, Any]]] = {}
    rows: list[dict[str, Any]] = []
    coverage = {
        "TranscriptId": transcript_id, "BotId": bot_id, "ConversationId": conversation_id,
        "SourceModifiedOn": transcript.get("modifiedon"),
        "ToolEvents": 0, "Completed": 0, "Failed": 0, "Suspended": 0,
        "MissingStart": 0, "MissingCompletion": 0, "MissingQuery": 0,
        "MessagePairing": "TemporalWithinUserBoundary",
    }

    def row(start: dict[str, Any] | None, end: dict[str, Any], event_index: int,
            forced_status: str | None = None) -> dict[str, Any]:
        value = object_value(end.get("value"), "tool event")
        start_value = object_value(start.get("value"), "tool start") if start else {}
        start_time = timestamp(start or end)
        end_time = timestamp(end)
        before = [a for a in users if timestamp(a) <= start_time]
        after = [a for a in users if timestamp(a) > start_time]
        user = before[-1] if before else {}
        boundary = timestamp(after[0]) if after else float("inf")
        responses = [a for a in replies if end_time <= timestamp(a) < boundary]
        reply = responses[0] if responses and forced_status not in ("Pending", "Suspended") else {}
        query = query_text(start)
        if not query:
            coverage["MissingQuery"] += 1
        identity = (start or end).get("id") or event_index
        key = "|".join((environment_id, transcript_id, str(value["toolCallId"]), str(identity)))
        status = forced_status or (
            "Failed" if end.get("name") == "ToolCallTrace:Failed" or value.get("errorCode")
            else value.get("toolCallStatus") or "Unknown"
        )
        return dict(zip(FIELDS, (
            conversation_id, f"{user.get('id', '')}__{reply.get('id', '')}",
            user.get("from", {}).get("aadObjectId"), meta.get("BotName"), bot_id,
            datetime.fromtimestamp(start_time / 1000, UTC).isoformat(),
            value.get("toolDisplayName") or start_value.get("toolDisplayName"),
            value.get("toolCategory") or start_value.get("toolCategory"),
            value["toolCallId"], query, status, value.get("durationMs"),
            result_summary(value), user.get("text", ""), reply.get("text", ""),
            value.get("errorCode"), value.get("errorMessage"), value.get("httpStatusCode"),
            environment_id, transcript_id, hashlib.sha256(key.encode()).hexdigest(),
            transcript.get("modifiedon"), "MatchedToolCallId;TemporalMessages" if start else "MissingStart",
            "Observed" if query else "NotExposed", end.get("name"), "1.0",
        ), strict=True))

    for index, activity in enumerate(activities):
        event = activity.get("name", "")
        if not event.startswith("ToolCallTrace:"):
            continue
        coverage["ToolEvents"] += 1
        if event not in ("ToolCallTrace:Started", "ToolCallTrace:Completed", "ToolCallTrace:Failed"):
            raise ValueError("Unknown ToolCallTrace event; update adapter before advancing checkpoint")
        value = object_value(activity.get("value"), "tool event")
        call_id = value.get("toolCallId")
        if not isinstance(call_id, str) or not call_id:
            raise ValueError("Tool event is missing toolCallId")
        if event == "ToolCallTrace:Started":
            if call_id in pending:
                old_index, old = pending.pop(call_id)
                rows.append(row(old, old, old_index, "Pending"))
                coverage["MissingCompletion"] += 1
            pending[call_id] = (index, activity)
            continue
        match = pending.pop(call_id, None)
        start = match[1] if match else None
        if start is None:
            coverage["MissingStart"] += 1
        if is_consent(value):
            coverage["Suspended"] += 1
            rows.append(row(start, activity, index, "Suspended"))
        else:
            coverage["Failed" if event == "ToolCallTrace:Failed" or value.get("errorCode") else "Completed"] += 1
            rows.append(row(start, activity, index))
    for index, start in pending.values():
        rows.append(row(start, start, index, "Pending"))
        coverage["MissingCompletion"] += 1
    coverage["State"] = "ObservedToolEvents" if coverage["ToolEvents"] else "NoObservedToolTrace"
    return rows, coverage
