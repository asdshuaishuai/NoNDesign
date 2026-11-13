"""Context construction + persistent session memory.

Project metadata lives inside the canonical document as HTML comments, exactly
like annotations: it travels with the DDP and needs no sidecar store. Markers
are always last; `>` is escaped so the engine's comment scanner never sees `-->`.
"""

from __future__ import annotations

import asyncio
import json
import re
import time
from pathlib import Path
from typing import Any

from agents.memory.session import Session

DESIGN_RE = re.compile(r"<!--\s*nondesign:design\s+([\s\S]*?)\s*-->")
DOCS_RE = re.compile(r"<!--\s*nondesign:docs\s+([\s\S]*?)\s*-->")

DEFAULT_DESIGN = {
    "v": 1,
    "palette": {
        "primary": "#6E7BFF",
        "background": "#F7F8FA",
        "surface": "#FFFFFF",
        "text": "#14161A",
        "muted": "#6B7280",
        "danger": "#DC2626",
        "success": "#16A34A",
    },
    "typography": {"h1": 32, "h2": 24, "body": 14},
    "spacing": [4, 8, 12, 16, 24, 32],
    "radius": {"sm": 8, "md": 12, "lg": 16},
    "rules": ["正文对比度 ≥ 4.5", "8pt 间距节奏", "按钮圆角 8", "列表 3 行以上加分隔线", "按钮文案 2–4 字"],
    "notes": "",
}


def default_docs() -> dict[str, Any]:
    return {"prd": "", "ui": "", "design": json.loads(json.dumps(DEFAULT_DESIGN))}


def normalize_design(value: Any) -> dict[str, Any]:
    design = json.loads(json.dumps(DEFAULT_DESIGN))
    if not isinstance(value, dict):
        return design
    for key in ("palette", "typography", "radius"):
        if isinstance(value.get(key), dict):
            design[key].update(value[key])
    if isinstance(value.get("spacing"), list) and value["spacing"]:
        design["spacing"] = [int(x) for x in value["spacing"] if isinstance(x, (int, float))]
    if isinstance(value.get("rules"), list):
        design["rules"] = [str(x) for x in value["rules"]]
    if isinstance(value.get("notes"), str):
        design["notes"] = value["notes"]
    design["v"] = 1
    return design


def _encode(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).replace(">", "\\u003e")


def strip_metadata(mbt: str) -> str:
    cleaned = DESIGN_RE.sub("", mbt)
    cleaned = DOCS_RE.sub("", cleaned)
    cleaned = re.sub(r"\n{3,}", "\n\n", cleaned)
    return cleaned.rstrip()


def with_metadata(mbt: str, docs: dict[str, Any]) -> str:
    base = strip_metadata(mbt)
    design = _encode(docs.get("design") or DEFAULT_DESIGN)
    payload = _encode({"prd": docs.get("prd", ""), "ui": docs.get("ui", "")})
    return f"{base}\n\n<!-- nondesign:design {design} -->\n<!-- nondesign:docs {payload} -->\n"


def parse_metadata(mbt: str) -> dict[str, Any]:
    docs = default_docs()
    if not mbt:
        return docs
    match = DESIGN_RE.search(mbt)
    if match:
        try:
            docs["design"] = normalize_design(json.loads(match.group(1)))
        except Exception:
            pass
    match = DOCS_RE.search(mbt)
    if match:
        try:
            value = json.loads(match.group(1))
            docs["prd"] = value.get("prd", "") if isinstance(value.get("prd"), str) else ""
            docs["ui"] = value.get("ui", "") if isinstance(value.get("ui"), str) else ""
        except Exception:
            pass
    return docs


def design_for_agent(docs: dict[str, Any]) -> dict[str, Any]:
    design = normalize_design(docs.get("design"))
    return {
        "v": 1,
        "palette": design["palette"],
        "typography": design["typography"],
        "spacing": design["spacing"],
        "radius": design["radius"],
    }


def _frontmatter_value(mbt: str, key: str) -> str:
    for line in mbt.splitlines()[:60]:
        stripped = line.strip()
        if stripped.startswith(key + ":"):
            value = stripped[len(key) + 1 :].strip().strip('"')
            if value:
                return value
    return ""


def parse_revision(mbt: str) -> int:
    for line in mbt.splitlines()[:40]:
        stripped = line.strip()
        if stripped.startswith("revision:"):
            try:
                return int(stripped.split(":", 1)[1].strip())
            except ValueError:
                return 0
    return 0


def artboard_section(mbt: str, artboard: str) -> str | None:
    marker = f"<!-- moonviz:artboard {artboard} -->"
    start = mbt.find(marker)
    if start < 0:
        return None
    after = mbt[start + len(marker) :]
    fence = after.find("```mbt")
    if fence < 0:
        return None
    body_start = after.find("\n", fence)
    if body_start < 0:
        return None
    rest = after[body_start + 1 :]
    end = rest.find("\n```")
    if end < 0:
        return None
    body = rest[:end].strip()
    return body[:24000] + ("…[truncated]" if len(body) > 24000 else "")


def compose_project_map(engine: Any, mbt: str) -> str:
    boards = engine.session("session_list_artboards", mbt)
    flows = engine.session("session_flows", mbt)
    theme = _frontmatter_value(mbt, "theme") or "light"
    entry = _frontmatter_value(mbt, "entry") or "?"
    rev = parse_revision(mbt)
    lines = [
        "PROJECT MAP · authoritative snapshot from the canonical document",
        f"rev={rev} entry={entry} theme={theme}",
        "boards:",
    ]
    for board in (boards.get("data") or []) if isinstance(boards, dict) else []:
        if not isinstance(board, dict):
            continue
        bid = board.get("id", "?")
        if bid == "__seed":
            continue
        w = board.get("width", 0)
        h = board.get("height", 0)
        n = board.get("nodes", 0)
        line = f"- {bid} {w}x{h} nodes={n}"
        queried = engine.session("session_query_nodes", mbt, bid)
        ids = [
            node.get("id")
            for node in (queried.get("data") or [])
            if isinstance(node, dict) and node.get("id")
        ][:24]
        if ids:
            line += " ids=[" + ",".join(ids) + "]"
        lines.append(line)
    flow_bits = []
    for flow in (flows.get("data") or []) if isinstance(flows, dict) else []:
        if not isinstance(flow, dict):
            continue
        flow_bits.append(f"{flow.get('from')}->{flow.get('to')}@{flow.get('trigger', '')}")
    lines.append("flows: " + ("; ".join(flow_bits[:40]) if flow_bits else "(none)"))
    return "\n".join(lines)


def state_summary(engine: Any, mbt: str, revision: int) -> str:
    boards = engine.session("session_list_artboards", mbt)
    flows = engine.session("session_flows", mbt)
    bits = []
    for board in (boards.get("data") or []) if isinstance(boards, dict) else []:
        if isinstance(board, dict):
            bits.append(f"{board.get('id')}:{board.get('nodes', 0)}")
    flow_count = len(flows.get("data") or []) if isinstance(flows, dict) else 0
    return f"rev={revision} boards=[{','.join(bits)}] flows={flow_count}"


def estimate_tokens(value: Any) -> int:
    raw = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
    return max(1, len(raw) // 3)


def _item_text(item: Any) -> str:
    if not isinstance(item, dict):
        return ""
    content = item.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(
            c.get("text", "") for c in content if isinstance(c, dict) and isinstance(c.get("text"), str)
        )
    return ""


class CompactingSession(Session):
    """JSON-file session with deterministic compaction.

    The SDK appends items; we keep a recent suffix verbatim and a compact
    summary of older turns. Compaction never calls an LLM, so the prompt prefix
    stays stable and cheap.
    """

    def __init__(self, directory: str | Path, key: str, context_window: int = 128000) -> None:
        self.session_settings = None
        self.context_window = max(16000, int(context_window or 128000))
        safe = re.sub(r"[^A-Za-z0-9_.-]", "_", (key or "unsaved")[:120]) or "unsaved"
        self._path = Path(directory) / f"{safe}.json"
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = asyncio.Lock()
        self.session_id = f"sess_{int(time.time() * 1000)}"
        self._items: list[Any] = []
        self._summary = ""
        self._load()

    def _load(self) -> None:
        try:
            raw = json.loads(self._path.read_text("utf-8"))
            self.session_id = raw.get("id") or self.session_id
            self._summary = raw.get("summary") or ""
            self._items = raw.get("items") or []
        except Exception:
            self._items = []

    def _save(self) -> None:
        tmp = self._path.with_suffix(".tmp")
        tmp.write_text(
            json.dumps(
                {
                    "id": self.session_id,
                    "summary": self._summary,
                    "items": self._items,
                    "updatedAt": int(time.time() * 1000),
                },
                ensure_ascii=False,
            ),
            "utf-8",
        )
        tmp.replace(self._path)

    def _compact(self) -> None:
        if len(self._items) <= 80:
            return
        cut = len(self._items) - 18
        older, keep = self._items[:cut], self._items[cut:]
        users, assistants = [], []
        for item in older:
            text = _item_text(item).strip()
            if not text:
                continue
            role = item.get("role") if isinstance(item, dict) else ""
            (users if role == "user" else assistants).append(text)
        parts = []
        if self._summary:
            parts.append(self._summary)
        if users:
            parts.append("Earlier requests: " + " | ".join(users[-6:]))
        if assistants:
            parts.append("Earlier outcomes: " + " | ".join(assistants[-4:]))
        self._summary = "\n".join(parts)[-1400:]
        self._items = keep

    def _budget(self, items: list[Any]) -> list[Any]:
        budget = int(self.context_window * 0.55)
        tokens = estimate_tokens(items) + estimate_tokens(self._summary)
        if tokens <= budget:
            return items
        cut = max(0, len(items) - 18)
        kept = items[cut:]
        if len(self._summary) < 200:
            bits = [_item_text(i) for i in items[:cut]]
            self._summary = " | ".join(b for b in bits if b)[-1400:]
            self._save()
        return kept

    async def get_items(self, limit: int | None = None) -> list[Any]:
        async with self._lock:
            self._compact()
            items = self._budget(self._items)
            if limit and limit > 0 and len(items) > limit:
                items = items[-limit:]
            if not self._summary:
                return items
            summary_item = {
                "role": "user",
                "content": f"[SESSION MEMORY — compacted earlier turns]\n{self._summary}",
            }
            return [summary_item, *items]

    async def add_items(self, items: list[Any]) -> None:
        if not items:
            return
        async with self._lock:
            self._items.extend(items)
            self._compact()
            self._save()

    async def pop_item(self) -> Any | None:
        async with self._lock:
            item = self._items.pop() if self._items else None
            self._save()
            return item

    async def clear_session(self) -> None:
        async with self._lock:
            self._items = []
            self._summary = ""
            self._save()


def clear_session_file(directory: str | Path, key: str) -> bool:
    safe = re.sub(r"[^A-Za-z0-9_.-]", "_", (key or "unsaved")[:120]) or "unsaved"
    path = Path(directory) / f"{safe}.json"
    try:
        path.unlink()
        return True
    except FileNotFoundError:
        return False
