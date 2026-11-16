"""A2UI 小应用引擎（用户点名方向：灵闪/Dots 式自成一体小应用）。

LLM 生成**自包含单 HTML**（内联 JS/CSS，动画优先：requestAnimationFrame /
canvas / SVG / CSS keyframes，零外链依赖离线可用），落盘即「热更新」：
覆盖文件 + WebView reload 即生效（与 3D 工作台同构，WebView 即执行面）。
Flutter 热更新无官方能力（AOT），HTML 是唯一即时路线——且动画生态
（canvas/SVG/CSS）正是「视频和动画」类小应用的母语。

作品集（portfolio）：横切收藏夹——聚合 a2ui 小应用 / 视频 mp4 / 3D 场景
三类产物，index.json 索引 + 每条 preview 缩略提示，供快速查看与打开。

诚实边界：v1 的质量环为结构校验（生成 HTML 非空含 <body>）+ WebView 桥
错误回传（window.onerror → NONA2UI channel）；视觉自动截图（canvas
toDataURL）留给 v2。
"""
from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

from openai import AsyncOpenAI

A2UI_ROOT = Path.home() / "Documents" / "NoNDesign" / "a2ui"
PORTFOLIO_FILE = Path.home() / "Documents" / "NoNDesign" / "portfolio" / "index.json"

SYSTEM_GENERATE = (
    "你是 A2UI 小应用生成器：输出**自包含单 HTML 文件**（一个 mini app）。"
    "硬规则：\n"
    "1. 全部内联（<style> 与 <script> 都在文件内），零外链依赖（无 CDN/图片外链/字体外链）"
    "——必须离线可用。\n"
    "2. 动画优先：视觉主体用 CSS keyframes / requestAnimationFrame + canvas / SVG 动画实现，"
    "让应用「动起来」——这是动画/演示类小应用，不是静态页面。\n"
    "3. 可交互：至少一个可操作控件（按钮/滑杆/点击），操作有真实反馈（改变动画参数/状态）。\n"
    "4. 自适应：body 满容器（width:100%;height:100vh），深色背景优先，随窗口缩放重排。\n"
    "5. <body> 之外不要多余散文；只输出完整 HTML（```html 围栏或裸码）。\n"
    "6. 视觉质量：统一配色（2-3 主色）、克制排版、缓动自然（easeOut 类），禁止生硬跳变。"
)

SYSTEM_REFINE = (
    "你是 A2UI 小应用修改器：在现有 HTML 基础上按指令修改，其余保持不变。"
    "输出修改后的**完整 HTML**（不是 diff、不是片段）；硬规则同生成器（全内联、零外链、动画优先）。"
)


class A2uiError(Exception):
    """fail-closed 业务拒绝（端点层转 400）。"""


def _app_dir(name: str) -> Path:
    safe = "".join(c for c in name if c.isalnum() or c in "-_")
    if not safe or safe != name:
        raise A2uiError(f"invalid_name:{name} —— 只允许字母数字-下划线")
    return A2UI_ROOT / safe


def _meta(name: str) -> dict[str, Any]:
    f = _app_dir(name) / "meta.json"
    return json.loads(f.read_text("utf-8")) if f.exists() else {}


def _write_meta(name: str, meta: dict[str, Any]) -> None:
    (_app_dir(name) / "meta.json").write_text(json.dumps(meta, ensure_ascii=False, indent=1), "utf-8")


def _html_ok(html: str) -> bool:
    """结构校验（v1 质量环）：非空且含 <body 与 </html>。"""
    lower = html.lower()
    return "<body" in lower and "</html>" in lower and len(html) > 200


def _extract_html(text: str) -> str:
    if "```" in text:
        for seg in text.split("```"):
            seg = seg.strip()
            if seg.startswith(("html", "")):
                seg = seg.split("\n", 1)[1] if "\n" in seg and seg.lower().startswith("html") else seg
            if "<!doctype" in seg.lower() or "<html" in seg.lower():
                return seg.strip() + "\n"
    if "<html" in text.lower():
        start = text.lower().index("<!doctype") if "<!doctype" in text.lower() else text.lower().index("<html")
        return text[start:].strip() + "\n"
    raise A2uiError("html_parse_failed: 模型回复不含 HTML 文档")


async def _chat(model: str, base_url: str, api_key: str, system: str, user: str) -> str:
    """单轮生成（AsyncOpenAI 原生 await——不可 to_thread 包 coroutine）。"""
    client = AsyncOpenAI(api_key=api_key or "missing", base_url=base_url or None)
    resp = await client.chat.completions.create(
        model=model or "deepseek-chat", temperature=0.5,
        messages=[{"role": "system", "content": system}, {"role": "user", "content": user}])
    return resp.choices[0].message.content or ""


async def generate(name: str, brief: str, model: str, base_url: str, api_key: str) -> dict[str, Any]:
    """生成新小应用：brief → 自包含 HTML → 落盘 + 作品集登记。"""
    d = _app_dir(name)
    if d.exists():
        raise A2uiError(f"app_exists:{name}")
    raw = await _chat(model, base_url, api_key, SYSTEM_GENERATE,
                      f"生成一个小应用。需求：{brief}\n优先形态：动画/演示/可玩的交互（用户会直接使用它）。")
    html = _extract_html(raw)
    if not _html_ok(html):
        raise A2uiError("html_invalid: 生成的 HTML 缺少 body/html 结构（v1 结构校验门）")
    d.mkdir(parents=True, exist_ok=True)
    (d / "index.html").write_text(html, "utf-8")
    meta = {"name": name, "title": brief[:60], "brief": brief,
            "createdAt": int(time.time()), "updatedAt": int(time.time()), "kind": "a2ui"}
    _write_meta(name, meta)
    portfolio_upsert(kind="a2ui", ref=name, title=brief[:60], path=str(d / "index.html"))
    return {"ok": True, "name": name, "dir": str(d), "bytes": len(html)}


async def refine(name: str, instruction: str, model: str, base_url: str, api_key: str) -> dict[str, Any]:
    """对话式修改（快速热更新）：读现有 HTML + 指令 → 覆盖 → WebView reload 即生效。"""
    d = _app_dir(name)
    html_file = d / "index.html"
    if not html_file.exists():
        raise A2uiError(f"no_app:{name}")
    current = html_file.read_text("utf-8")
    raw = await _chat(model, base_url, api_key, SYSTEM_REFINE,
                      f"# 现有小应用\n```html\n{current}\n```\n\n# 修改指令\n{instruction}\n\n输出修改后的完整 HTML。")
    html = _extract_html(raw)
    if not _html_ok(html):
        raise A2uiError("html_invalid: 修改后的 HTML 缺少结构（拒绝覆盖——旧版仍在，热更新无损坏风险）")
    html_file.write_text(html, "utf-8")
    meta = _meta(name)
    meta["updatedAt"] = int(time.time())
    _write_meta(name, meta)
    return {"ok": True, "name": name, "bytes": len(html), "reload": True}


def page_html(name: str) -> str:
    f = _app_dir(name) / "index.html"
    if not f.exists():
        raise A2uiError(f"no_app:{name}")
    return f.read_text("utf-8")


def list_apps() -> dict[str, Any]:
    items = []
    if A2UI_ROOT.exists():
        for d in sorted(A2UI_ROOT.iterdir()):
            m = d / "meta.json"
            if m.exists():
                meta = json.loads(m.read_text("utf-8"))
                items.append({"name": meta.get("name") or d.name,
                              "title": meta.get("title") or d.name,
                              "updatedAt": meta.get("updatedAt")})
    return {"ok": True, "apps": items}


def delete_app(name: str) -> dict[str, Any]:
    import shutil
    d = _app_dir(name)
    if not d.exists():
        raise A2uiError(f"no_app:{name}")
    shutil.rmtree(d)
    portfolio_remove(kind="a2ui", ref=name)
    return {"ok": True}


# ---------- 作品集（横切收藏夹：a2ui / video / three） ----------

def _portfolio() -> dict[str, Any]:
    PORTFOLIO_FILE.parent.mkdir(parents=True, exist_ok=True)
    if PORTFOLIO_FILE.exists():
        try:
            return json.loads(PORTFOLIO_FILE.read_text("utf-8"))
        except json.JSONDecodeError:
            pass
    return {"items": []}


def _save_portfolio(p: dict[str, Any]) -> None:
    PORTFOLIO_FILE.parent.mkdir(parents=True, exist_ok=True)
    PORTFOLIO_FILE.write_text(json.dumps(p, ensure_ascii=False, indent=1), "utf-8")


def portfolio_upsert(kind: str, ref: str, title: str, path: str, detail: str = "") -> None:
    p = _portfolio()
    entry = {"kind": kind, "ref": ref, "title": title, "path": path,
             "detail": detail, "ts": int(time.time())}
    p["items"] = [e for e in p["items"] if not (e["kind"] == kind and e["ref"] == ref)]
    p["items"].insert(0, entry)
    _save_portfolio(p)


def portfolio_remove(kind: str, ref: str) -> None:
    p = _portfolio()
    p["items"] = [e for e in p["items"] if not (e["kind"] == kind and e["ref"] == ref)]
    _save_portfolio(p)


def portfolio_list() -> dict[str, Any]:
    """聚合三类产物：index.json 登记 + 存在性校验（文件被手删的条目剔除）。"""
    p = _portfolio()
    items = []
    for e in p.get("items", []):
        if Path(e.get("path", "")).exists():
            items.append(e)
    # 存量补扫：workspace 里已有但未登记的 mp4 / 3D html（首次启用作品集即可见历史产物）
    video_root = Path.home() / "Documents" / "NoNDesign" / "video"
    known = {(e["kind"], e["ref"]) for e in items}
    if video_root.exists():
        for mp4 in sorted(video_root.glob("*/frames.mp4")):
            ref = str(mp4)
            if ("video", ref) not in known:
                items.append({"kind": "video", "ref": ref, "title": mp4.parent.name,
                              "path": str(mp4), "detail": "视频渲染产物", "ts": int(mp4.stat().st_mtime)})
    three_root = Path.home() / "Documents" / "NoNDesign" / "3d"
    if three_root.exists():
        for d in sorted(three_root.iterdir()):
            scene = d / "scene.js"
            if scene.exists() and ("three", d.name) not in known:
                items.append({"kind": "three", "ref": d.name, "title": f"3D · {d.name}",
                              "path": str(scene), "detail": "three.js 场景", "ts": int(scene.stat().st_mtime)})
    items.sort(key=lambda e: -int(e.get("ts", 0)))
    return {"ok": True, "items": items}


def portfolio_delete(kind: str, ref: str) -> dict[str, Any]:
    """从作品集移除条目（a2ui 同时删源目录；video/three 仅移除登记不删产物）。"""
    if kind == "a2ui":
        d = A2UI_ROOT / ref
        if d.exists():
            import shutil
            shutil.rmtree(d)
    portfolio_remove(kind=kind, ref=ref)
    return {"ok": True}
