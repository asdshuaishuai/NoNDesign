"""models.dev snapshot store: bundled baseline + optional runtime refresh."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

BUNDLED = Path(__file__).resolve().parent / "models.json"
APP_DIR = Path.home() / ".nondesign"
REFRESHED = APP_DIR / "models.json"

CURATED = [
    ("openai", "https://api.openai.com/v1", "openai"),
    ("deepseek", "https://api.deepseek.com", "openai"),
    ("zhipuai", "https://open.bigmodel.cn/api/paas/v4", "openai"),
    ("zai", "https://api.z.ai/api/paas/v4", "openai"),
    ("moonshotai-cn", "https://api.moonshot.cn/v1", "openai"),
    ("moonshotai", "https://api.moonshot.ai/v1", "openai"),
    ("minimax-cn", "https://api.minimax.cn/v1", "openai"),
    ("minimax", "https://api.minimax.io/v1", "openai"),
    ("google", "https://generativelanguage.googleapis.com/v1beta/openai", "openai"),
    ("stepfun", "https://api.stepfun.com/v1", "openai"),
    ("alibaba", "https://dashscope-intl.aliyuncs.com/compatible-mode/v1", "openai"),
    ("openrouter", "https://openrouter.ai/api/v1", "openai"),
    ("groq", "https://api.groq.com/openai/v1", "openai"),
    ("xai", "https://api.x.ai/v1", "openai"),
    ("mistral", "https://api.mistral.ai/v1", "openai"),
    ("cerebras", "https://api.cerebras.ai/v1", "openai"),
    ("togetherai", "https://api.together.xyz/v1", "openai"),
    ("perplexity", "https://api.perplexity.ai", "openai"),
    ("zhipuai-coding-plan", "https://open.bigmodel.cn/api/coding/paas/v4", "openai"),
    ("zai-coding-plan", "https://api.z.ai/api/coding/paas/v4", "openai"),
    ("kimi-code-plan-cn", "https://api.kimi.com/coding/v1", "openai"),
    ("stepfun-step-plan", "https://api.stepfun.com/step_plan/v1", "openai"),
]


def load_models() -> dict[str, Any]:
    for path in (REFRESHED, BUNDLED):
        try:
            data = json.loads(path.read_text("utf-8"))
            if isinstance(data, dict) and data.get("providers"):
                return data
        except Exception:
            continue
    return {"source": "", "fetched_at": "", "providers": {}}


def _trim(raw: dict[str, Any]) -> dict[str, Any]:
    providers: dict[str, Any] = {}
    for pid, api, protocol in CURATED:
        p = raw.get(pid)
        if not isinstance(p, dict):
            continue
        entries = list((p.get("models") or {}).items())
        entries.sort(key=lambda kv: 0 if (kv[1] or {}).get("tool_call") else 1)
        models = {}
        for mid, m in entries[:80]:
            if not isinstance(m, dict):
                continue
            models[mid] = {
                "name": m.get("name") or mid,
                "reasoning": m.get("reasoning", False),
                "tool_call": m.get("tool_call", False),
                "structured_output": m.get("structured_output", False),
                **({"reasoning_options": m["reasoning_options"]} if m.get("reasoning_options") else {}),
                **({"limit": m["limit"]} if m.get("limit") else {}),
                **({"cost": m["cost"]} if m.get("cost") else {}),
            }
        npm = p.get("npm") if isinstance(p.get("npm"), str) else ""
        providers[pid] = {
            "id": pid,
            "name": p.get("name") or pid,
            "api": api or p.get("api") or "",
            "protocol": protocol or ("anthropic" if "anthropic" in npm else "openai"),
            "npm": npm,
            "model_count": len(models),
            "models": models,
        }
    return {
        "source": "https://models.dev/api.json",
        "license": "MIT (models.dev)",
        "fetched_at": __import__("datetime").date.today().isoformat(),
        "note": "runtime-refreshed capability snapshot",
        "providers": providers,
    }


async def refresh_models() -> dict[str, Any]:
    import httpx

    async with httpx.AsyncClient(timeout=20, headers={"User-Agent": "NoNDesign/0.1"}) as client:
        response = await client.get("https://models.dev/api.json")
        response.raise_for_status()
        raw = response.json()
    snapshot = _trim(raw)
    APP_DIR.mkdir(parents=True, exist_ok=True)
    REFRESHED.write_text(json.dumps(snapshot, ensure_ascii=False, indent=2), "utf-8")
    return snapshot
