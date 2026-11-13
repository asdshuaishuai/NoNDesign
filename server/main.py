#!/usr/bin/env python3
"""NoNDesign local server: MoonViz engine + OpenAI Agents SDK + DDP.

Flutter talks to 127.0.0.1 over HTTP/SSE. No Bun, no Tauri, no JS runtime.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
from pathlib import Path
from typing import Any, AsyncIterator

from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

SERVER_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SERVER_DIR))

from agent import AgentRunManager, AgentRunRequest  # noqa: E402
from context import clear_session_file, parse_metadata, with_metadata  # noqa: E402
from ddp import DdpError, decrypt_ddp, encrypt_ddp  # noqa: E402
from engine import EngineHost, EngineError  # noqa: E402
from models_store import load_models, refresh_models  # noqa: E402

APP_VERSION = "0.1.0"
APP_DIR = Path.home() / ".nondesign"
SESSION_DIR = Path(os.environ.get("NONDESIGN_SESSION_DIR", APP_DIR / "sessions"))
WORKSPACE_DIR = Path(os.environ.get("NONDESIGN_WORKSPACE", Path.home() / "Documents" / "NoNDesign"))

app = FastAPI(title="NoNDesign", version=APP_VERSION)
runs = AgentRunManager(str(SESSION_DIR))
_engine: EngineHost | None = None


def engine() -> EngineHost:
    global _engine
    if _engine is None:
        _engine = EngineHost.shared()
    return _engine


class RenderRequest(BaseModel):
    mbt: str


class ApplyRequest(BaseModel):
    mbt: str
    op: str
    gate: str = "human"


class SessionRequest(BaseModel):
    mbt: str
    name: str
    arg: str | None = None


class GenerateRequest(BaseModel):
    mbt: str
    intent: str
    name: str = ""
    spec: dict[str, Any] = Field(default_factory=dict)


class TapRequest(BaseModel):
    mbt: str
    artboard: str
    x: float
    y: float


class ConstrainRequest(BaseModel):
    mbt: str
    artboard: str
    intent: str


class EventRequest(BaseModel):
    mbt: str
    artboard: str
    spec: str


class HistoryRequest(BaseModel):
    mbt: str
    command: str


class SaveProjectRequest(BaseModel):
    mbt: str
    path: str
    password: str = ""
    docs: dict[str, Any] = Field(default_factory=dict)


class OpenProjectRequest(BaseModel):
    path: str
    password: str = ""


class CancelRequest(BaseModel):
    run_id: int


class ClearSessionRequest(BaseModel):
    key: str


@app.get("/health")
async def health() -> dict[str, Any]:
    try:
        info = engine().version_info()
        return {
            "ok": True,
            "version": APP_VERSION,
            "engine": info,
            "stats": engine().stats(),
            "workspace": str(WORKSPACE_DIR),
        }
    except Exception as exc:
        return {"ok": False, "version": APP_VERSION, "error": str(exc)}


@app.get("/models")
async def models() -> dict[str, Any]:
    return {"ok": True, "snapshot": load_models()}


@app.post("/models/refresh")
async def models_refresh() -> dict[str, Any]:
    try:
        snapshot = await refresh_models()
        return {"ok": True, "snapshot": snapshot}
    except Exception as exc:
        return {"ok": False, "error": str(exc)}


@app.get("/engine/templates")
async def templates() -> dict[str, Any]:
    return {"ok": True, "templates": engine().list_templates()}


@app.get("/engine/components")
async def components() -> dict[str, Any]:
    return {"ok": True, "components": engine().list_components()}


@app.get("/engine/themes")
async def themes() -> dict[str, Any]:
    return {"ok": True, "themes": engine().list_themes()}


@app.get("/engine/ops")
async def ops() -> dict[str, Any]:
    return {"ok": True, "ops": engine().list_ops()}


@app.post("/engine/render")
async def render(req: RenderRequest) -> dict[str, Any]:
    try:
        # wasm 调用是同步阻塞的：直接跑在事件循环上会冻结整个服务
        # （/agent/cancel、/health、SSE 推送一并停摆）。RLock 已保证与
        # agent 工具线程的互斥，丢线程池执行即可。
        return await asyncio.to_thread(engine().render, req.mbt)
    except EngineError as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc


@app.post("/engine/validate")
async def validate(req: RenderRequest) -> dict[str, Any]:
    return await asyncio.to_thread(engine().validate, req.mbt)


@app.post("/engine/apply")
async def apply(req: ApplyRequest) -> dict[str, Any]:
    return await asyncio.to_thread(engine().apply, req.mbt, req.op, gate=req.gate)


@app.post("/engine/session")
async def session(req: SessionRequest) -> dict[str, Any]:
    return await asyncio.to_thread(engine().session, req.name, req.mbt, req.arg)


@app.post("/engine/generate")
async def generate(req: GenerateRequest) -> dict[str, Any]:
    return await asyncio.to_thread(engine().generate, req.mbt, req.intent, req.name, req.spec)


@app.post("/engine/tap")
async def engine_tap(req: TapRequest) -> dict[str, Any]:
    """Simulate a tap at artboard coordinates; returns the engine envelope as-is
    ({ok, changes[], current, mbt}). Demo mode consumes it: nav via `current`,
    toast via `changes`, live re-render via a changed `mbt`. Nothing here writes
    back to the project document — runtime state lives in the session only."""
    return await asyncio.to_thread(engine().tap, req.mbt, req.artboard, req.x, req.y)


@app.post("/engine/constrain")
async def engine_constrain(req: ConstrainRequest) -> dict[str, Any]:
    """Apply a layout intent (session_constrain) to one artboard. `intent` is a
    natural-language phrase the engine parses (居中 | 等间距 | 网格 3 | …); a
    cannot_parse failure carries the vocabulary in `error`. Success returns the
    canonical envelope {ok, id, x, mbt} — callers re-render before committing."""
    return await asyncio.to_thread(engine().constrain, req.mbt, req.artboard, req.intent)


@app.post("/engine/event")
async def engine_event(req: EventRequest) -> dict[str, Any]:
    """Simulate a demo-mode gesture on an artboard (session_event). `spec` is a
    raw event token — probed: `key_enter` ok, JSON shapes rejected as
    unknown_event. Envelope matches /engine/tap ({ok, changes[], current, mbt});
    runtime state stays in the session, the project document is untouched."""
    return await asyncio.to_thread(engine().event, req.mbt, req.artboard, req.spec)


@app.post("/engine/history")
async def engine_history(req: HistoryRequest) -> dict[str, Any]:
    """Engine-side version control (session_history). `command` is the
    sub-command expression: `init <artboard>`, `commit`, `log`, `undo`, `redo`,
    `diff <from> <to>`. undo/redo success carries the jumped-to canonical mbt;
    log returns a human-readable `log` string."""
    return await asyncio.to_thread(engine().session, "session_history", req.mbt, req.command)


@app.post("/engine/export-html")
async def export_html(req: RenderRequest) -> dict[str, Any]:
    return await asyncio.to_thread(engine().export_html, req.mbt)


@app.post("/project/save")
async def project_save(req: SaveProjectRequest) -> dict[str, Any]:
    path = Path(req.path).expanduser()
    if path.suffix.lower() != ".ddp":
        path = path.with_suffix(".ddp")
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        # Always persist docs in the canonical document (single source of truth).
        canonical = with_metadata(req.mbt, req.docs) if req.docs else req.mbt
        payload = encrypt_ddp(canonical, req.password)
        path.write_bytes(payload)
        return {"ok": True, "path": str(path), "bytes": len(payload)}
    except DdpError as exc:
        return {"ok": False, "error": str(exc)}
    except Exception as exc:
        return {"ok": False, "error": f"ddp_write_failed:{exc}"}


@app.post("/project/open")
async def project_open(req: OpenProjectRequest) -> dict[str, Any]:
    path = Path(req.path).expanduser()
    if not path.exists():
        return {"ok": False, "error": "file_not_found"}
    try:
        data = path.read_bytes()
    except Exception as exc:
        return {"ok": False, "error": f"ddp_read_failed:{exc}"}
    try:
        mbt = decrypt_ddp(data, req.password)
    except DdpError as exc:
        if str(exc) in {"ddp_password_required", "ddp_authentication_failed"}:
            return {"ok": False, "need_password": True, "path": str(path), "error": str(exc)}
        return {"ok": False, "error": str(exc)}
    docs = parse_metadata(mbt)
    return {"ok": True, "path": str(path), "mbt": mbt, "docs": docs, "bytes": len(data)}


@app.get("/project/list")
async def project_list(dir: str | None = None) -> dict[str, Any]:
    target = Path(dir).expanduser() if dir else WORKSPACE_DIR
    target.mkdir(parents=True, exist_ok=True)
    items = []
    for path in sorted(target.glob("*.ddp")):
        try:
            stat = path.stat()
        except OSError:
            continue
        items.append(
            {
                "path": str(path),
                "name": path.stem,
                "bytes": stat.st_size,
                "modified": stat.st_mtime,
            }
        )
    items.sort(key=lambda x: x["modified"], reverse=True)
    return {"ok": True, "dir": str(target), "projects": items}


@app.post("/agent/cancel")
async def agent_cancel(req: CancelRequest) -> dict[str, Any]:
    return {"ok": runs.cancel(req.run_id)}


@app.post("/agent/session/clear")
async def clear_session(req: ClearSessionRequest) -> dict[str, Any]:
    return {"ok": True, "removed": clear_session_file(SESSION_DIR, req.key)}


def _sse(event: dict[str, Any]) -> str:
    return f"data: {json.dumps(event, ensure_ascii=False)}\n\n"


@app.post("/agent/run")
async def agent_run(req: AgentRunRequest) -> StreamingResponse:
    run = runs.start(req)

    async def stream() -> AsyncIterator[str]:
        try:
            async for event in run.stream():
                yield _sse(event)
        except asyncio.CancelledError:
            yield _sse({"type": "failed", "error": "cancelled", "stopReason": "cancelled"})
        except Exception as exc:  # noqa: BLE001
            yield _sse({"type": "failed", "error": f"{type(exc).__name__}: {exc}", "stopReason": "failed"})
        finally:
            runs.finish(req.run_id)

    return StreamingResponse(
        stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no", "Connection": "keep-alive"},
    )


def main() -> None:
    import uvicorn

    parser = argparse.ArgumentParser(description="NoNDesign server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--reload", action="store_true")
    args = parser.parse_args()
    APP_DIR.mkdir(parents=True, exist_ok=True)
    SESSION_DIR.mkdir(parents=True, exist_ok=True)
    WORKSPACE_DIR.mkdir(parents=True, exist_ok=True)

    port = args.port
    if port == 0:
        import socket

        probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()

    import atexit

    meta_path = APP_DIR / "server.json"
    meta_path.write_text(json.dumps({"port": port, "pid": os.getpid()}), "utf-8")
    atexit.register(lambda: meta_path.unlink(missing_ok=True))

    parent_pid = int(os.environ.get("NONDESIGN_PARENT_PID", "0") or 0)
    if parent_pid:
        import threading
        import time as _time

        def _watch_parent() -> None:
            while True:
                _time.sleep(2)
                if os.getppid() != parent_pid:
                    os._exit(0)

        threading.Thread(target=_watch_parent, name="parent-watch", daemon=True).start()

    print(f"[nondesign] engine={engine().version_info().get('version')} workspace={WORKSPACE_DIR}", flush=True)
    print(f"[nondesign] listening on http://{args.host}:{port}", flush=True)
    uvicorn.run(app, host=args.host, port=port, reload=args.reload, log_level="info")


if __name__ == "__main__":
    main()
