#!/usr/bin/env python3
"""NoNDesign local server: MoonViz engine + OpenAI Agents SDK + DDP.

Flutter talks to 127.0.0.1 over HTTP/SSE. No Bun, no Tauri, no JS runtime.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Any, AsyncIterator

from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

SERVER_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SERVER_DIR))

import acp_bridge  # noqa: E402
from acp_bridge import AcpRegistry, detect_agents, probe_all as acp_bridge_probe_all  # noqa: E402
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


# 每板 svg 里与画板同尺寸的第一个背景 rect（探针实证：紧跟 </defs>，
# light #F8F9FB / dark #0F1114 / harmony #F1F3F5；n_root 内的 fill="none"
# rect 不带 #，不会误中）。剥 svg 前把 fill 提为 artboard.background。
_RECT_TAG_RE = re.compile(r"<rect\b[^>]*>")


def _board_background(svg: str | None, width: float, height: float) -> str:
    for tag in _RECT_TAG_RE.findall(svg or ""):
        def attr(name: str) -> str:
            m = re.search(rf'{name}="([^"]+)"', tag)
            return m.group(1) if m else ""

        try:
            tw, th = float(attr("width")), float(attr("height"))
        except ValueError:
            continue
        if abs(tw - width) <= 0.5 and abs(th - height) <= 0.5:
            fill = attr("fill")
            if fill.startswith("#"):
                return fill
    return ""


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
    return {"ok": True, "templates": await asyncio.to_thread(engine().list_templates)}


@app.get("/engine/components")
async def components() -> dict[str, Any]:
    return {"ok": True, "components": engine().list_components()}


@app.get("/engine/themes")
async def themes() -> dict[str, Any]:
    return {"ok": True, "themes": await asyncio.to_thread(engine().list_themes)}


@app.get("/engine/ops")
async def ops() -> dict[str, Any]:
    return {"ok": True, "ops": engine().list_ops()}


@app.post("/engine/render")
async def render(req: RenderRequest) -> dict[str, Any]:
    try:
        # wasm 调用是同步阻塞的：直接跑在事件循环上会冻结整个服务
        # （/agent/cancel、/health、SSE 推送一并停摆）。RLock 已保证与
        # agent 工具线程的互斥，丢线程池执行即可。
        env = await asyncio.to_thread(engine().render, req.mbt)
    except EngineError as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    # 引擎自渲染（用户定案 2026-11-16）：每板 svg 是内容层的唯一真源，
    # Flutter 经 flutter_svg 直上屏——客户端不再重复实现节点渲染
    # （阴影/字体/rotate/<image>/板底全由引擎 svg 携带）。仅提取板底色
    # 备用（容器底/缩略图背景），svg 本体保留在信封里。
    boards = env.get("artboards")
    if isinstance(boards, list):
        for b in boards:
            if isinstance(b, dict):
                svg = b.get("svg")
                if isinstance(svg, str):
                    bg = _board_background(svg, float(b.get("width") or 0), float(b.get("height") or 0))
                    if bg:
                        b["background"] = bg
    return env


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


# ---------- ACP 外部智能体 ----------

acp_registry = AcpRegistry()


class AcpNewSessionRequest(BaseModel):
    agent: str
    cwd: str | None = None


class AcpPromptRequest(BaseModel):
    session_id: str
    text: str


class AcpCancelRequest(BaseModel):
    session_id: str


@app.on_event("startup")
async def _acp_warm_probe() -> None:
    # 启动即后台实测全目录（npx 首拉可能较慢，不阻塞请求面）。
    asyncio.get_running_loop().create_task(acp_bridge_probe_all())


@app.get("/acp/agents")
async def acp_agents(probe: int = 0) -> dict[str, Any]:
    if probe:
        try:
            await asyncio.wait_for(acp_bridge_probe_all(), timeout=45)
        except asyncio.TimeoutError:
            pass  # 未完成的条目以 probing 状态返回，前端可重试
    return {"ok": True, "agents": detect_agents()}


@app.post("/acp/session")
async def acp_new_session(req: AcpNewSessionRequest) -> dict[str, Any]:
    workspace = req.cwd or str(Path.home() / "Documents" / "NoNDesign")
    workspace_path = Path(workspace)
    if not workspace_path.exists():
        workspace_path.mkdir(parents=True, exist_ok=True)
    return await acp_registry.create(req.agent, str(workspace_path))


@app.get("/project/export/3d")
async def export_3d(mbt: str, board: str) -> dict[str, Any]:
    """轨道 C（3DCodeVerse 式插件）：画板 → 自包含 three.js 场景 HTML。

    节点树无损映射（rect→拉伸盒 + z 按层级、text→CanvasTexture 贴图平面、
    fill→材质色），摄像机初始正视可旋转/缩放——空间维度让布局关系一眼
    可见（对照 arXiv:2610.22341 的执行/测量/视觉三反馈，浏览器即执行面）。"""
    env = await asyncio.to_thread(engine().render, mbt)
    if not env.get("ok"):
        raise HTTPException(status_code=400, detail=str(env.get("error")))
    ab = next((b for b in env.get("artboards") or []
               if isinstance(b, dict) and b.get("id") == board), None)
    if ab is None:
        raise HTTPException(status_code=404, detail="board not found")
    nodes = []
    for n in ab.get("nodes") or []:
        st = n.get("style") or {}
        if st.get("visible") is False:
            continue
        nodes.append({
            "x": n.get("x", 0), "y": n.get("y", 0),
            "w": n.get("w", 0), "h": n.get("h", 0),
            "z": float(n.get("order", 0)) * 2,
            "fill": (st.get("fill") or "#DDDDDD").strip(),
            "radius": st.get("radius", 0),
            "text": (n.get("text") or "").strip()[:120],
            "fontSize": st.get("font_size", 14),
            "textColor": (st.get("text_color") or "#333333").strip(),
        })
    html = _THREE_TEMPLATE.replace("__BOARD_JSON__", json.dumps({
        "width": ab.get("width", 390), "height": ab.get("height", 844),
        "name": ab.get("name") or board, "nodes": nodes,
    }, ensure_ascii=False))
    ws = Path.home() / "Documents" / "NoNDesign"
    ws.mkdir(parents=True, exist_ok=True)
    out = ws / f"board-{board}-3d.html"
    out.write_text(html, "utf-8")
    return {"ok": True, "file": str(out), "nodes": len(nodes)}


_THREE_TEMPLATE = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>NoNDesign 3D</title>
<style>body{margin:0;overflow:hidden;background:#0b0d12}#info{position:fixed;top:10px;left:10px;color:#8a93a6;font:12px monospace}</style>
</head><body><div id="info">拖动旋转 · 滚轮缩放 · 右键平移</div>
<script type="importmap">{"imports":{"three":"https://unpkg.com/three@0.160.0/build/three.module.js","three/addons/":"https://unpkg.com/three@0.160.0/examples/jsm/"}}</script>
<script type="module">
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
const DATA = __BOARD_JSON__;
const scene = new THREE.Scene();
scene.background = new THREE.Color(0x0b0d12);
const camera = new THREE.PerspectiveCamera(45, innerWidth/innerHeight, 1, 8000);
camera.position.set(DATA.width/2, -DATA.height/2, 900);
const renderer = new THREE.WebGLRenderer({antialias:true});
renderer.setSize(innerWidth, innerHeight);
document.body.appendChild(renderer.domElement);
new OrbitControls(camera, renderer.domElement);
scene.add(new THREE.AmbientLight(0xffffff, 1.1));
const dl = new THREE.DirectionalLight(0xffffff, 0.7); dl.position.set(400, -400, 600); scene.add(dl);
function txtMesh(n) {
  const c = document.createElement('canvas'); c.width = 512; c.height = Math.max(64, Math.ceil(512 * n.h / Math.max(1, n.w)));
  const g = c.getContext('2d'); g.fillStyle = '#ffffff'; g.fillRect(0,0,c.width,c.height);
  g.fillStyle = n.textColor; g.font = `${Math.round(n.fontSize*2)}px sans-serif`;
  const lines = (n.text||'').split('\n'); lines.forEach((l,i)=>g.fillText(l, 16, 40+i*Math.round(n.fontSize*2.4)));
  const t = new THREE.CanvasTexture(c); t.colorSpace = THREE.SRGBColorSpace;
  return new THREE.Mesh(new THREE.BoxGeometry(n.w, n.h, 2), [
    new THREE.MeshBasicMaterial({color:0xcccccc}),
    new THREE.MeshBasicMaterial({color:0xcccccc}),
    new THREE.MeshBasicMaterial({map:t}),
    new THREE.MeshBasicMaterial({color:0xcccccc}),
    new THREE.MeshBasicMaterial({color:0xcccccc}),
    new THREE.MeshBasicMaterial({color:0xcccccc}),
  ]);
}
for (const n of DATA.nodes) {
  const color = new THREE.Color(n.fill && n.fill[0]==='#' ? n.fill : 0xdddddd);
  const mesh = n.text
    ? txtMesh(n)
    : new THREE.Mesh(new THREE.BoxGeometry(n.w, n.h, 6), new THREE.MeshStandardMaterial({color, roughness:.85}));
  mesh.position.set(n.x + n.w/2, n.y + n.h/2, n.z);
  scene.add(mesh);
}
const grid = new THREE.GridHelper(Math.max(DATA.width, DATA.height)*2, 20, 0x223, 0x1a1e28);
grid.position.set(DATA.width/2, DATA.height/2, -12); scene.add(grid);
function loop(){ requestAnimationFrame(loop); renderer.render(scene, camera); }
loop();
</script></body></html>"""


@app.post("/acp/prompt")
async def export_figma(mbt: str) -> dict[str, Any]:
    """NoN → Figma 导出包：每板引擎自渲染 SVG + 节点树 manifest
    （figma-plugin/ 双向插件消费 nondesign.json 建真实可编辑图层；
    board-*.svg 可直接拖入 Figma 成为矢量图层）。落工作区目录。"""
    env = await asyncio.to_thread(engine().render, mbt)
    if not env.get("ok"):
        raise HTTPException(status_code=400, detail=str(env.get("error")))
    ts = int(time.time())
    ws = Path.home() / "Documents" / "NoNDesign"
    ws.mkdir(parents=True, exist_ok=True)
    out_dir = ws / f"NoNDesign-figma-{ts}"
    out_dir.mkdir(exist_ok=True)
    manifest = {"exportedAt": ts, "boards": []}
    for b in env.get("artboards") or []:
        if not isinstance(b, dict):
            continue
        bid = b.get("id") or "board"
        (out_dir / f"board-{bid}.svg").write_text(b.get("svg") or "", "utf-8")
        manifest["boards"].append({
            "id": bid,
            "name": b.get("name") or bid,
            "width": b.get("width"),
            "height": b.get("height"),
            "background": b.get("background") or "#FFFFFF",
            "nodes": b.get("nodes") or [],
        })
    (out_dir / "nondesign.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=1), "utf-8")
    (out_dir / "README.txt").write_text(
        "NoNDesign → Figma 导出包\n"
        "======================\n"
        "方式一（插件，可编辑图层）：Figma → Plugins → Development → Import plugin from manifest\n"
        "  选择 NoNDesign 仓库 figma-plugin/manifest.json，运行插件导入本目录 nondesign.json。\n"
        "方式二（矢量）：把 board-*.svg 拖进 Figma 画布，自动成为可编辑矢量图层。\n",
        "utf-8")
    return {"ok": True, "dir": str(out_dir),
            "boards": len(manifest["boards"]),
            "files": [f.name for f in sorted(out_dir.iterdir())]}


@app.post("/acp/prompt")
async def acp_prompt(req: AcpPromptRequest) -> StreamingResponse:
    session = acp_registry.get(req.session_id)
    if session is None:
        raise HTTPException(status_code=404, detail="session not found")
    pending = await session.prompt(req.text)

    async def stream() -> AsyncIterator[str]:
        try:
            while True:
                event = await asyncio.wait_for(pending.queue.get(), timeout=600)
                yield _sse(event)
                if event.get("type") in ("done", "failed"):
                    break
        except asyncio.TimeoutError:
            yield _sse({"type": "failed", "error": "prompt_timeout", "stopReason": "failed"})
        except asyncio.CancelledError:
            yield _sse({"type": "failed", "error": "cancelled", "stopReason": "cancelled"})

    return StreamingResponse(
        stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no", "Connection": "keep-alive"},
    )


@app.post("/acp/cancel")
async def acp_cancel(req: AcpCancelRequest) -> dict[str, Any]:
    session = acp_registry.get(req.session_id)
    if session is None:
        return {"ok": False, "error": "session not found"}
    session.cancel()
    return {"ok": True}


@app.post("/acp/close")
async def acp_close(req: AcpCancelRequest) -> dict[str, Any]:
    await acp_registry.close(req.session_id)
    return {"ok": True}


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
