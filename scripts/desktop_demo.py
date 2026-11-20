"""Write synthetic client logs and count the usage they describe."""

from dataclasses import dataclass
from datetime import datetime, time, timedelta
import json
import random


CLAUDE_SESSION_ID = "00000000-0000-4000-8000-000000000601"
CODEX_WEEK_BOUNDARY_ID = "demo-codex-week-boundary"
MODELS = {
    "claude": ("claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"),
    "codex": ("gpt-6.1-sol", "gpt-5.3-codex"),
    "gemini": ("gemini-3.8-flash", "gemini-3.1-pro-preview"),
    "pi": ("deepseek-flash", "demo-unpriced-model"),
    "qwen": ("qwen3-coder-flash",),
}
PROJECTS = (r"D:\work\atlas", "/home/dev/lumen", "/home/dev/orbit", r"D:\work\cedar")
PROMPT = "[Synthetic prompt]"
REPLY = "[Synthetic reply]"


@dataclass(frozen=True)
class Usage:
    timestamp: str
    input_tokens: int
    output_tokens: int
    cache_read: int


@dataclass
class Totals:
    sessions: int = 0
    records: int = 0
    tokens: int = 0


def write_jsonl(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes("".join(json.dumps(row) + "\n" for row in rows).encode("utf-8"))


def write_session(home, tool, session_id, model, project, records):
    cwd = {"cwd": project} if project is not None else {}
    match tool:
        case "claude":
            write_jsonl(home / ".claude/projects/demo" / f"{session_id}.jsonl", (
                {
                    "type": "assistant", **cwd, "sessionId": session_id, "timestamp": row.timestamp,
                    "message": {
                        "id": f"msg_{session_id}_{index}", "model": model,
                        "content": [{"type": "text", "text": REPLY}],
                        "usage": {"input_tokens": row.input_tokens, "output_tokens": row.output_tokens,
                                  "cache_read_input_tokens": row.cache_read},
                    },
                }
                for index, row in enumerate(records)
            ))
        case "codex":
            rows = [{"type": "session_meta", "payload": {"session_id": session_id, "model": model, **cwd}}]
            rows.extend({
                "type": "token_usage_record", "timestamp": row.timestamp,
                "payload": {
                    "response_id": f"resp_{session_id}_{index}",
                    "usage": {"input_tokens": row.input_tokens + row.cache_read,
                              "cached_input_tokens": row.cache_read, "output_tokens": row.output_tokens},
                },
            } for index, row in enumerate(records))
            write_jsonl(home / ".codex/sessions" / f"rollout-{session_id}.jsonl", rows)
        case "gemini":
            path = home / ".gemini/sessions" / f"session-{session_id}.json"
            path.parent.mkdir(parents=True, exist_ok=True)
            messages = [{"role": "user", "text": PROMPT}]
            messages.extend({
                "role": "model", "timestamp": row.timestamp, "id": f"{session_id}-{index}",
                "model": model, "text": REPLY,
                "usageMetadata": {
                    "promptTokenCount": row.input_tokens + row.cache_read,
                    "cachedContentTokenCount": row.cache_read, "candidatesTokenCount": row.output_tokens,
                },
            } for index, row in enumerate(records))
            path.write_bytes((json.dumps({
                "sessionId": session_id, "startTime": records[0].timestamp, "messages": messages,
            }) + "\n").encode("utf-8"))
        case "pi":
            rows = [{"type": "session", "id": session_id, **cwd},
                    {"type": "model_change", "modelId": model}]
            rows.extend({
                "type": "message", "timestamp": row.timestamp, "id": f"{session_id}-{index}",
                "message": {
                    "role": "assistant", "content": [{"type": "text", "text": REPLY}],
                    "usage": {"input": row.input_tokens, "output": row.output_tokens,
                              "cacheRead": row.cache_read},
                },
            } for index, row in enumerate(records))
            write_jsonl(home / ".pi/agent/sessions/demo" / f"{session_id}.jsonl", rows)
        case "qwen":
            write_jsonl(home / ".qwen/usage" / f"demo-usage-{session_id}.jsonl", (
                {
                    "timestamp": row.timestamp, "model": model, "sessionId": session_id,
                    "id": f"{session_id}-{index}", "inputTokens": row.input_tokens + row.cache_read,
                    "cachedTokens": row.cache_read, "outputTokens": row.output_tokens,
                }
                for index, row in enumerate(records)
            ))


def generate_logs(home, today):
    rng = random.Random(6301)
    totals = {tool: Totals() for tool in MODELS}

    def add(tool, session_id, model, project, times, scale):
        records = [
            Usage(stamp.astimezone().isoformat(), rng.randint(400, 2100) * scale,
                  rng.randint(80, 520) * scale, rng.randint(0, 1500) * scale)
            for stamp in times
        ]
        write_session(home, tool, session_id, model, project, records)
        total = totals[tool]
        total.sessions += 1
        total.records += len(records)
        total.tokens += sum(row.input_tokens + row.output_tokens + row.cache_read for row in records)

    monday = today - timedelta(days=today.weekday())
    days = [today - timedelta(days=offset) for offset in range(89, -1, -1)]
    eligible = [day for day in days if day.day != 1 and day < today and day != monday - timedelta(days=1)]
    days_off = set(rng.sample(eligible, 6))
    for day in days:
        if day in days_off:
            continue
        weekend = day.weekday() >= 5
        scale = rng.choice((1, 2) if weekend else (2, 4, 8, 14))
        for tool, models in MODELS.items():
            count = 1 if weekend else rng.randint(1, 3)
            for number in range(count):
                session_id = f"demo-{tool}-{day}-{number}"
                project = rng.choice((*PROJECTS, None))
                if day == today and tool == "claude" and number == 0:
                    session_id = CLAUDE_SESSION_ID
                    project = PROJECTS[0]
                start = datetime.combine(day, time(9 + number * 4, rng.randrange(60)))
                times = [start + timedelta(minutes=2 * turn) for turn in range(rng.randint(2, 6))]
                add(tool, session_id, rng.choice(models), project, times, scale)

    # Keep the resumed session visible in this week's recent sessions.
    add("codex", CODEX_WEEK_BOUNDARY_ID, MODELS["codex"][0], PROJECTS[1], [
        datetime.combine(monday - timedelta(days=1), time(23, 50)),
        datetime.combine(today, time(22, 50)),
    ], 4)
    return totals
