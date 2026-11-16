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
import shutil
import sys
import time
from pathlib import Path
from typing import Any, AsyncIterator

from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from fastapi.responses import HTMLResponse, PlainTextResponse

SERVER_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SERVER_DIR))

import acp_bridge  # noqa: E402
import three_agent as three  # noqa: E402（轨道 C：3D 工作台，依赖 SERVER_DIR 已入 path）
import a2ui_agent as a2ui  # noqa: E402（A2UI 小应用引擎 + 作品集，同上）
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
    # 只读列出：不再对调用方任意 dir mkdir（此前 GET 参数即可在磁盘任意
    # 位置创建目录）；目录不存在直接 400。
    if not target.exists():
        raise HTTPException(status_code=400, detail=f"dir_not_found:{target}")
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


@app.post("/project/export/figma")
async def export_figma(req: RenderRequest) -> dict[str, Any]:
    """NoN → Figma 导出包：每板引擎自渲染 SVG + 节点树 manifest
    （figma-plugin/ 双向插件消费 nondesign.json 建真实可编辑图层；
    board-*.svg 可直接拖入 Figma 成为矢量图层）。落工作区目录。
    ⚠️ 路由曾错挂 /acp/prompt（FastAPI 同路径先注册者胜出 → ACP 对话
    请求全部命中本函数，mbt 缺参 422）；mbt 走 body（大文档不能进
    query，h11 头 16KB 上限会拦）。"""
    env = await asyncio.to_thread(engine().render, req.mbt)
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


# ---------- 轨道 C：3D 制作工作台（客户端插件，与引擎解耦） ----------

class ThreeNewRequest(BaseModel):
    name: str
    brief: str
    model: str = ""
    base_url: str = ""
    api_key: str = ""
    thinking_level: str = "auto"


class ThreeRunRequest(BaseModel):
    name: str
    model: str = ""
    base_url: str = ""
    api_key: str = ""
    thinking_level: str = "auto"


class ThreeFeedbackRequest(BaseModel):
    name: str
    kind: str
    payload: Any = None


class ThreeContinueRequest(BaseModel):
    name: str
    summary: str = ""


class ThreeSpecSaveRequest(BaseModel):
    name: str
    spec: dict[str, Any]


def _three_guard(fn, *args):
    try:
        return fn(*args)
    except three.ThreeError as e:
        raise HTTPException(status_code=400, detail=str(e))


async def _three_guard_async(coro_fn, *args, **kwargs):
    try:
        return await coro_fn(*args, **kwargs)
    except three.ThreeError as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.post("/three/project/new")
async def three_new(req: ThreeNewRequest) -> dict[str, Any]:
    """spec 阶段（img2threejs 纪律：先 spec 后代码，fail-closed）。"""
    return await _three_guard_async(three.new_project, req.name, req.brief, req.model,
                                    req.base_url, req.api_key, req.thinking_level)


@app.post("/three/pass")
async def three_pass(req: ThreeRunRequest) -> dict[str, Any]:
    """执行当前 pass（状态门禁：blocked 拒绝、生成后未收反馈拒绝重复生成）。"""
    return await _three_guard_async(three.run_pass, req.name, req.model, req.base_url,
                                    req.api_key, req.thinking_level)


@app.post("/three/feedback")
async def three_feedback(req: ThreeFeedbackRequest) -> dict[str, Any]:
    """三反馈入口（WebView 桥回传）：error 修复轮+1 / metrics 记录 /
    screenshot 落盘 evidence/。"""
    return await _three_guard_async(three.feedback, req.name, req.kind, req.payload)


@app.post("/three/continue")
async def three_continue(req: ThreeContinueRequest) -> dict[str, Any]:
    """评审通过推进下一 pass（必须有 evidence——每步必带证据）。"""
    return _three_guard(three.continue_pass, req.name, req.summary)


@app.post("/three/spec/save")
async def three_spec_save(req: ThreeSpecSaveRequest) -> dict[str, Any]:
    """规范手编回灌（img2threejs：手改落 spec，不许只改代码）。"""
    return _three_guard(three.save_spec, req.name, req.spec)


@app.get("/three/spec")
async def three_spec(name: str) -> dict[str, Any]:
    return _three_guard(three.read_spec, name)


@app.get("/three/project")
async def three_project(name: str) -> dict[str, Any]:
    return _three_guard(three.read_project, name)


@app.get("/three/projects")
async def three_projects() -> dict[str, Any]:
    return three.list_projects()


@app.get("/three/preview/{name}", response_class=HTMLResponse)
async def three_preview(name: str) -> str:
    """应用内 WebView 的执行面：three.js CDN importmap + 错误/测量/截图三桥。"""
    return _three_guard(three.preview_html, name)


@app.get("/three/scene/{name}.js", response_class=PlainTextResponse)
async def three_scene(name: str) -> str:
    return _three_guard(three.scene_js, name)


_THREE_VENDOR_WHITELIST = {"three.module.js": "application/javascript"}


@app.get("/three/vendor/{filename}")
async def three_vendor(filename: str) -> PlainTextResponse:
    """本地 vendored three.js（离线可用）——白名单单文件，不接受任意路径。"""
    mime = _THREE_VENDOR_WHITELIST.get(filename)
    if mime is None:
        raise HTTPException(status_code=404, detail=f"vendor_not_found:{filename}")
    f = Path(__file__).resolve().parent / "three_vendor" / filename
    if not f.exists():
        raise HTTPException(status_code=404, detail="vendor_missing")
    return PlainTextResponse(f.read_text("utf-8"), media_type=mime)


# ---------- A2UI 小应用引擎 + 作品集（灵闪/Dots 式自成一体小应用） ----------

class A2uiGenerateRequest(BaseModel):
    name: str
    brief: str
    model: str = ""
    base_url: str = ""
    api_key: str = ""


class A2uiRefineRequest(BaseModel):
    name: str
    instruction: str
    model: str = ""
    base_url: str = ""
    api_key: str = ""


class A2uiDeleteRequest(BaseModel):
    name: str


class PortfolioDeleteRequest(BaseModel):
    kind: str
    ref: str


def _a2ui_guard(fn, *args):
    try:
        return fn(*args)
    except a2ui.A2uiError as e:
        raise HTTPException(status_code=400, detail=str(e))


async def _a2ui_guard_async(coro_fn, *args):
    try:
        return await coro_fn(*args)
    except a2ui.A2uiError as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.post("/a2ui/generate")
async def a2ui_generate(req: A2uiGenerateRequest) -> dict[str, Any]:
    """一句话 → 自包含动画 HTML 小应用（落盘即热更新）。"""
    return await _a2ui_guard_async(a2ui.generate, req.name, req.brief, req.model,
                                   req.base_url, req.api_key)


@app.post("/a2ui/refine")
async def a2ui_refine(req: A2uiRefineRequest) -> dict[str, Any]:
    """对话式修改（reload=true 提示 WebView 重载）。"""
    return await _a2ui_guard_async(a2ui.refine, req.name, req.instruction, req.model,
                                   req.base_url, req.api_key)


@app.get("/a2ui/page/{name}", response_class=HTMLResponse)
async def a2ui_page(name: str) -> str:
    return _a2ui_guard(a2ui.page_html, name)


@app.get("/a2ui/list")
async def a2ui_list() -> dict[str, Any]:
    return _a2ui_guard(a2ui.list_apps)


@app.post("/a2ui/delete")
async def a2ui_delete(req: A2uiDeleteRequest) -> dict[str, Any]:
    return _a2ui_guard(a2ui.delete_app, req.name)


@app.get("/portfolio")
async def portfolio_list() -> dict[str, Any]:
    """作品集聚合：a2ui / video / three 三类产物（存量自动补扫）。"""
    return _a2ui_guard(a2ui.portfolio_list)


@app.post("/portfolio/delete")
async def portfolio_delete(req: PortfolioDeleteRequest) -> dict[str, Any]:
    return _a2ui_guard(a2ui.portfolio_delete, req.kind, req.ref)


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


# ---------- 轨道 B 客户端面：视频工作台（调独立插件 plugins/video-engine/，
# 端点只是调用方——引擎本身零服务器依赖，subprocess 独立进程） ----------

class VideoRenderRequest(BaseModel):
    timeline: dict[str, Any]
    # spec 与 timeline 成对（管线硬门：render/review 都要求 spec 同目录）。
    spec: dict[str, Any] | None = None
    fps: int = 10  # 工作台冒烟预览默认降帧（全量 30fps 逐帧光栅化很慢）


_VIDEO_JOBS: dict[str, dict[str, Any]] = {}
_VIDEO_ROOT = Path.home() / "Documents" / "NoNDesign" / "video"


@app.post("/video/render")
async def video_render(req: VideoRenderRequest) -> dict[str, Any]:
    """后台跑 render.py（job 轮询制：255 帧全量要 1-2 分钟，HTTP 同步会超时）。
    无声版（用户裁决：音轨/旁白暂不做）。"""
    import uuid
    job = uuid.uuid4().hex[:12]
    _VIDEO_ROOT.mkdir(parents=True, exist_ok=True)
    d = _VIDEO_ROOT / job
    d.mkdir(exist_ok=True)
    tl_file = d / "timeline.json"
    tl_file.write_text(json.dumps(req.timeline, ensure_ascii=False, indent=1), "utf-8")
    if isinstance(req.spec, dict):
        # 按 timeline 引用名落盘（art-sketch 引 screenplay.json、其余 spec.json——
        # 固定文件名会让 load_spec 的相对引用 miss：art 渲染 failed 实证）
        (d / Path(str(req.timeline.get("spec") or "spec.json")).name).write_text(
            json.dumps(req.spec, ensure_ascii=False, indent=1), "utf-8")
    _VIDEO_JOBS[job] = {"status": "running", "dir": str(d / "frames"), "log": "", "mp4": "", "frames": 0}
    _prune_video_jobs()
    script = Path(__file__).resolve().parent.parent / "plugins" / "video-engine" / "render.py"

    def _run() -> None:
        import subprocess as sp
        py = str(Path(sys.executable))
        try:
            proc = sp.run([py, str(script), str(tl_file), str(d / "frames"),
                           "--fps", str(max(1, min(30, req.fps)))],
                          capture_output=True, text=True, timeout=600)
        except Exception as e:
            # 子进程异常（含 TimeoutExpired）必须落终态，否则 job 永远 running、
            # 客户端轮询无终结（2026-11-16 登记：/video/render future 逃逸）。
            _VIDEO_JOBS[job] = {**_VIDEO_JOBS.get(job, {}), "status": "failed",
                                "log": (f"{type(e).__name__}: {e}")[-2000:]}
            return
        j = _VIDEO_JOBS.get(job)
        if j is None:
            return  # 已被 _prune_video_jobs 容量轮换清理：终态无处落，直接结束
        j["log"] = (proc.stdout + proc.stderr)[-2000:]
        if proc.returncode == 0:
            # render.py 的 mp4 产物名 = <frames 目录名>.mp4 → d/frames.mp4
            mp4 = d / "frames.mp4"
            j["status"] = "done"
            j["mp4"] = str(mp4) if mp4.exists() else ""
            j["frames"] = len(list((d / "frames").glob("frame_*.png")))
        else:
            j["status"] = "failed"
        _VIDEO_JOBS[job] = j

    asyncio.get_running_loop().run_in_executor(None, _run)
    return {"ok": True, "job": job}


def _prune_video_jobs(keep: int = 20) -> None:
    """_VIDEO_JOBS 与 _VIDEO_ROOT 的 job 目录只保留最近 keep 个（dict 插入序
    = 创建序，删最旧）；running 中的 job 一样按容量轮换（上限内不受影响）。"""
    jobs = list(_VIDEO_JOBS.keys())
    while len(jobs) > keep:
        old = jobs.pop(0)
        info = _VIDEO_JOBS.pop(old, None)
        if not info:
            continue
        d = Path(str(info.get("dir", ""))).parent  # dir 指向 frames，父目录即 job 目录
        try:
            if d != _VIDEO_ROOT and d.resolve().is_relative_to(_VIDEO_ROOT.resolve()) and d.exists():
                shutil.rmtree(d, ignore_errors=True)
        except OSError:
            pass


@app.get("/video/render/status")
async def video_render_status(job: str) -> dict[str, Any]:
    j = _VIDEO_JOBS.get(job)
    if j is None:
        raise HTTPException(status_code=404, detail=f"no_job:{job}")
    return {"ok": True, **j}


@app.get("/video/frame")
async def video_frame(path: str, n: int = 0) -> PlainTextResponse:
    """serve 渲染帧（path 必须精确命中某个已注册 job 的 frames 目录——
    防目录穿越；不再按注册序抢第一个命中帧：多 job 并发时客户端拿到的
    是自己 job 的帧而非别的 job）。"""
    want = Path(path).resolve()
    for j in _VIDEO_JOBS.values():
        frames_dir = j.get("dir", "")
        base = Path(frames_dir).resolve()
        if want != base:
            continue
        target = (base / f"frame_{n:05d}.png").resolve()
        if str(target).startswith(str(base)) and target.exists():
            return PlainTextResponse(target.read_bytes(), media_type="image/png")
        break
    raise HTTPException(status_code=404, detail="frame_not_found")


@app.get("/video/sample")
async def video_sample(timeline: str, spec: str) -> dict[str, Any]:
    """读仓库标杆示例（timeline+spec 成对）。路径白名单校验（防穿越）。"""
    _VIDEO_ROOT.mkdir(parents=True, exist_ok=True)
    base = (Path(__file__).resolve().parent.parent / "plugins" / "video-engine" / "examples").resolve()
    tl_path = (base / timeline).resolve()
    sp_path = (base / spec).resolve()
    for f in (tl_path, sp_path):
        # 前缀 startswith 会被兄弟目录（examples-evil）绕过——resolve 后要求
        # 精确落在 base 之内（path 相对判定，False 即拒）。
        if base not in f.parents or not f.exists():
            raise HTTPException(status_code=400, detail=f"invalid_sample:{f.name}")
    return {"ok": True,
            "timeline": json.loads(tl_path.read_text("utf-8")),
            "spec": json.loads(sp_path.read_text("utf-8"))}


@app.post("/video/review")
async def video_review(req: VideoRenderRequest) -> dict[str, Any]:
    """环②机械对照（review.py）：符号闭包/beats 落片长/facts 形状。"""
    import subprocess as sp
    import uuid
    _VIDEO_ROOT.mkdir(parents=True, exist_ok=True)
    # 并发评审互不覆盖输入（共享 review-tmp 曾相互覆写 timeline/spec）
    d = _VIDEO_ROOT / f"review-{uuid.uuid4().hex[:8]}"
    d.mkdir(parents=True)
    tl_file = d / "timeline.json"
    tl_file.write_text(json.dumps(req.timeline, ensure_ascii=False, indent=1), "utf-8")
    if isinstance(req.spec, dict):
        # 同 render：按 timeline 引用名落盘
        (d / Path(str(req.timeline.get("spec") or "spec.json")).name).write_text(
            json.dumps(req.spec, ensure_ascii=False, indent=1), "utf-8")
    script = Path(__file__).resolve().parent.parent / "plugins" / "video-engine" / "review.py"
    # to_thread 不能带 kwargs 直传 sp.run 的第二位置参数（bufsize）——lambda 包齐
    proc = await asyncio.to_thread(lambda: sp.run(
        [sys.executable, str(script), str(tl_file)],
        capture_output=True, text=True, timeout=60,
        cwd=str(Path(__file__).resolve().parent.parent)))
    return {"ok": proc.returncode == 0, "exit": proc.returncode,
            "output": (proc.stdout + proc.stderr)[-3000:]}
