#!/usr/bin/env python3
"""Refresh the models.dev capability snapshot used by the desktop app.

批次 15（2026-11-18）：Python 服务端已退役，本脚本不再 import
`server/models_store.py`，也不再写 `server/models.json`。唯一输出是
`app/assets/models.json`——随包分发的离线注册表（`store.ensureBundledRegistry`
与 `app/test/mobile_offline_test.dart` 的数据源）。

仍用 Python（而不是 Dart）是开发期工具选择：它只需要标准库，不参与应用
运行时，也不要求 .venv 之外的依赖。
"""

from __future__ import annotations

import datetime
import json
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = "https://models.dev/api.json"
OUT = ROOT / "app" / "assets" / "models.json"

# 与服务商预设一一对应；端点/协议以本表为权威（models.dev 的 npm 字段只作兜底）。
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


def _trim(raw: dict) -> dict:
    """Keep the curated providers and at most 80 models each (tool-capable first)."""
    providers: dict[str, object] = {}
    for pid, api, protocol in CURATED:
        provider = raw.get(pid)
        if not isinstance(provider, dict):
            continue
        entries = list((provider.get("models") or {}).items())
        entries.sort(key=lambda kv: 0 if (kv[1] or {}).get("tool_call") else 1)
        models: dict[str, object] = {}
        for mid, model in entries[:80]:
            if not isinstance(model, dict):
                continue
            trimmed = {
                "name": model.get("name") or mid,
                "reasoning": model.get("reasoning", False),
                "tool_call": model.get("tool_call", False),
                "structured_output": model.get("structured_output", False),
            }
            if model.get("reasoning_options"):
                trimmed["reasoning_options"] = model["reasoning_options"]
            if model.get("limit"):
                trimmed["limit"] = model["limit"]
            if model.get("cost"):
                trimmed["cost"] = model["cost"]
            models[mid] = trimmed
        npm = provider.get("npm") if isinstance(provider.get("npm"), str) else ""
        providers[pid] = {
            "id": pid,
            "name": provider.get("name") or pid,
            "api": api or provider.get("api") or "",
            "protocol": protocol or ("anthropic" if "anthropic" in npm else "openai"),
            "npm": npm,
            "model_count": len(models),
            "models": models,
        }
    return {
        "source": SOURCE,
        "license": "MIT (models.dev)",
        "fetched_at": datetime.date.today().isoformat(),
        "note": "runtime-refreshed capability snapshot",
        "providers": providers,
    }


def main() -> None:
    print(f"[sync_models] fetching {SOURCE} …")
    request = urllib.request.Request(
        SOURCE, headers={"User-Agent": "NaN/0.1 (+models.dev snapshot)"}
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        raw = json.loads(response.read().decode("utf-8"))
    snapshot = _trim(raw)
    payload = json.dumps(snapshot, ensure_ascii=False, indent=2) + "\n"
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(payload, "utf-8")
    providers = len(snapshot.get("providers", {}))
    models = sum(len(p.get("models", {})) for p in snapshot.get("providers", {}).values())
    print(f"[sync_models] ✓ {providers} providers / {models} models → {OUT}")


if __name__ == "__main__":
    main()
