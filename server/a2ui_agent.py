"""A2UI 小应用引擎（用户点名方向：灵闪/Dots 式自成一体小应用）。

LLM 生成**自包含单 HTML**（内联 JS/CSS，动画优先：requestAnimationFrame /
canvas / SVG / CSS keyframes，零外链依赖离线可用），落盘即「热更新」：
覆盖文件 + WebView reload 即生效（与 3D 工作台同构，WebView 即执行面）。
Flutter 热更新无官方能力（AOT），HTML 是唯一即时路线——且动画生态
（canvas/SVG/CSS）正是「视频和动画」类小应用的母语。

作品集（portfolio）：横切收藏夹——聚合 a2ui 小应用 / 视频 mp4 / 3D 场景
三类产物，index.json 索引 + 每条 preview 缩略提示，供快速查看与打开。

诚实边界：v1 的质量环为结构/外链校验（生成 HTML 非空含 <body>，且
http(s)/协议相对/绝对路径外链一律拒绝）+ WebView 桥错误回传（page_html
在 </body> 前注入 window.onerror/unhandledrejection 包装脚本 → NONA2UI
channel；/a2ui/page 另加 CSP 作第二道防线）；视觉自动截图（canvas
toDataURL）留给 v2。
"""
from __future__ import annotations

import asyncio
import json
import os
import re
import shutil
import tempfile
import time
from pathlib import Path
from typing import Any

from openai import AsyncOpenAI

A2UI_ROOT = Path.home() / "Documents" / "NoNDesign" / "a2ui"
PORTFOLIO_FILE = Path.home() / "Documents" / "NoNDesign" / "portfolio" / "index.json"

# 应用名长度上限：留足文件系统余量（fs 通常 255 字节，64 字符远低于上限），
# 同时把「超长名 mkdir 失败」提前成显式业务拒绝而不是裸 OSError。
MAX_APP_NAME = 64
PORTFOLIO_KINDS = ("a2ui", "video", "three")

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
    """应用目录（唯一入口）：名称白名单 + 长度上限 + 不出 A2UI_ROOT。

    名称是不可信字符串（HTTP body 直达）：路径分隔符、``..``、绝对路径、
    超长名一律业务拒绝。``d.parent == A2UI_ROOT`` 是显式断言——即使未来
    白名单放宽，也不能让删除路径逃出应用根。
    """
    if not isinstance(name, str) or not name:
        raise A2uiError(f"invalid_name:{name} —— 只允许字母数字-下划线")
    if len(name) > MAX_APP_NAME:
        raise A2uiError(f"invalid_name:{name} —— 名称过长（上限 {MAX_APP_NAME}）")
    safe = "".join(c for c in name if c.isascii() and (c.isalnum() or c in "-_"))
    if not safe or safe != name:
        raise A2uiError(f"invalid_name:{name} —— 只允许字母数字-下划线")
    d = A2UI_ROOT / safe
    if d.parent != A2UI_ROOT:
        raise A2uiError(f"invalid_name:{name} —— 路径越界")
    return d


def _atomic_write(path: Path, text: str) -> None:
    """同目录临时文件 + os.replace：写盘永不 truncate 出半截文件。"""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _read_json(path: Path, default: Any) -> Any:
    """容错读 JSON：损坏文件改名 .bak 保留证据，返回默认值（不静默覆盖）。"""
    if not path.exists():
        return default
    try:
        value = json.loads(path.read_text("utf-8"))
        return value
    except (json.JSONDecodeError, OSError, ValueError):
        try:
            os.replace(path, path.with_name(path.name + ".bak"))
        except OSError:
            pass
        return default


def _meta(name: str) -> dict[str, Any]:
    raw = _read_json(_app_dir(name) / "meta.json", {})
    return raw if isinstance(raw, dict) else {}


def _write_meta(name: str, meta: dict[str, Any]) -> None:
    _atomic_write(_app_dir(name) / "meta.json",
                  json.dumps(meta, ensure_ascii=False, indent=1))


# ---- 全内联零外链（产品硬规则的可执行点） ----
_ATTR_REF_RE = re.compile(
    r"""<(?:script|link|img)\b[^>]*?\b(?:src|href|srcset)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))""",
    re.I | re.S,
)
_CSS_URL_RE = re.compile(r"""url\(\s*(?:"([^"]*)"|'([^']*)'|([^)]*))\s*\)""", re.I)
_CSS_IMPORT_RE = re.compile(
    r"""@import\s+(?:url\(\s*)?(?:"([^"]*)"|'([^']*)'|([^\s;)]+))""", re.I
)


def _is_external_ref(value: str) -> bool:
    v = value.strip()
    if not v:
        return False
    low = v.lower()
    return low.startswith(("http://", "https://", "//")) or low.startswith("/")


def _external_refs(html: str) -> list[str]:
    found: list[str] = []

    def scan(value: str) -> None:
        # srcset 是逗号分隔的候选列表（URL 后的 2x 描述符丢弃）
        for candidate in value.split(","):
            token = candidate.strip().split(" ")[0] if candidate.strip() else ""
            if _is_external_ref(token):
                found.append(token)

    for m in _ATTR_REF_RE.finditer(html):
        scan(m.group(1) or m.group(2) or m.group(3) or "")
    for m in _CSS_URL_RE.finditer(html):
        scan(m.group(1) or m.group(2) or m.group(3) or "")
    for m in _CSS_IMPORT_RE.finditer(html):
        scan(m.group(1) or m.group(2) or m.group(3) or "")
    return found


def _html_ok(html: str) -> bool:
    """结构校验（v1 质量环）：非空含 <body>/</html>，且全内联零外链。

    外链（http(s)、协议相对 //、绝对路径）会以本机服务同源执行并可联网
    加载，且断网即白屏——直接抛 A2uiError（端点层 400），fail-closed。
    """
    lower = html.lower()
    refs = _external_refs(html)
    if refs:
        preview = ", ".join(refs[:3])
        raise A2uiError(
            f"html_external_refs: 检测到外链引用（{preview}）—— 小应用必须全内联零外链"
        )
    if not ("<body" in lower and "</html>" in lower and len(html) > 200):
        return False
    return True


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


# 读 → await LLM → 写 的窗口内，同名的 generate/refine/delete 必须串行：
# 否则两个 refine 都读旧版、后写覆盖先写且都回 ok；delete 也会在 await
# 期间删掉目录让写盘裸 FileNotFoundError。锁按应用名分片，不阻塞其他应用。
_app_locks: dict[str, asyncio.Lock] = {}


def _lock_for(name: str) -> asyncio.Lock:
    lock = _app_locks.get(name)
    if lock is None:
        lock = asyncio.Lock()
        _app_locks[name] = lock
    return lock


async def generate(name: str, brief: str, model: str, base_url: str, api_key: str) -> dict[str, Any]:
    """生成新小应用：brief → 自包含 HTML → 落盘 + 作品集登记。"""
    d = _app_dir(name)
    async with _lock_for(name):
        if d.exists():
            raise A2uiError(f"app_exists:{name}")
        raw = await _chat(model, base_url, api_key, SYSTEM_GENERATE,
                          f"生成一个小应用。需求：{brief}\n优先形态：动画/演示/可玩的交互（用户会直接使用它）。")
        html = _extract_html(raw)
        if not _html_ok(html):
            raise A2uiError("html_invalid: 生成的 HTML 缺少 body/html 结构（v1 结构校验门）")
        try:
            d.mkdir(parents=True, exist_ok=True)
            _atomic_write(d / "index.html", html)
            meta = {"name": name, "title": brief[:60], "brief": brief,
                    "createdAt": int(time.time()), "updatedAt": int(time.time()), "kind": "a2ui"}
            _write_meta(name, meta)
        except OSError as e:
            # 半成品目录会挡住同名重试（app_exists）：失败即清干净。
            shutil.rmtree(d, ignore_errors=True)
            raise A2uiError(f"app_write_failed:{e}") from e
        portfolio_upsert(kind="a2ui", ref=name, title=brief[:60], path=str(d / "index.html"))
        return {"ok": True, "name": name, "dir": str(d), "bytes": len(html)}


async def refine(name: str, instruction: str, model: str, base_url: str, api_key: str) -> dict[str, Any]:
    """对话式修改（快速热更新）：读现有 HTML + 指令 → 覆盖 → WebView reload 即生效。"""
    d = _app_dir(name)
    async with _lock_for(name):
        html_file = d / "index.html"
        if not html_file.exists():
            raise A2uiError(f"no_app:{name}")
        current = html_file.read_text("utf-8")
        # meta 先读/校验（坏 meta 不再造成「HTML 已覆盖、meta 半成功」）
        meta = _meta(name)
        raw = await _chat(model, base_url, api_key, SYSTEM_REFINE,
                          f"# 现有小应用\n```html\n{current}\n```\n\n# 修改指令\n{instruction}\n\n输出修改后的完整 HTML。")
        html = _extract_html(raw)
        if not _html_ok(html):
            raise A2uiError("html_invalid: 修改后的 HTML 缺少结构（拒绝覆盖——旧版仍在，热更新无损坏风险）")
        try:
            if not d.exists():
                raise A2uiError(f"no_app:{name}")  # await 期间被外部删除
            _atomic_write(html_file, html)
            meta["name"] = meta.get("name") or name
            meta["kind"] = meta.get("kind") or "a2ui"
            meta.setdefault("createdAt", int(time.time()))
            meta.setdefault("title", name)
            meta["updatedAt"] = int(time.time())
            _write_meta(name, meta)
        except OSError as e:
            raise A2uiError(f"app_write_failed:{e}") from e
        return {"ok": True, "name": name, "bytes": len(html), "reload": True}


_BRIDGE_SCRIPT = (
    "<script>(function(){"
    "function send(m){try{if(window.NONA2UI&&window.NONA2UI.postMessage){"
    "window.NONA2UI.postMessage(JSON.stringify({kind:\"error\",message:String(m).slice(0,500)}));"
    "}}catch(e){}}"
    "window.onerror=function(m,s,l,c){send(\"运行错误: \"+m+\" @ \"+(l||0)+\":\"+(c||0));};"
    "window.addEventListener(\"unhandledrejection\",function(e){"
    "var r=e.reason;send(\"未处理的 Promise 拒绝: \"+(r&&r.message?r.message:r));});"
    "})();</script>"
)


def _inject_bridge(html: str) -> str:
    """在 </body>（无则 </html>）前注入错误回传桥——WebView onerror 进 refine。"""
    lower = html.lower()
    for tag in ("</body>", "</html>"):
        idx = lower.rfind(tag)
        if idx >= 0:
            return html[:idx] + _BRIDGE_SCRIPT + html[idx:]
    return html + _BRIDGE_SCRIPT


def page_html(name: str) -> str:
    f = _app_dir(name) / "index.html"
    if not f.exists():
        raise A2uiError(f"no_app:{name}")
    return _inject_bridge(f.read_text("utf-8"))


def list_apps() -> dict[str, Any]:
    items = []
    if A2UI_ROOT.exists():
        for d in sorted(A2UI_ROOT.iterdir()):
            m = d / "meta.json"
            if not d.is_dir() or not m.exists():
                continue
            # 单个坏 meta 不让整个列表 500：跳过该应用（下一次写入自愈）。
            try:
                meta = json.loads(m.read_text("utf-8"))
                if not isinstance(meta, dict):
                    raise ValueError("meta is not an object")
            except (json.JSONDecodeError, OSError, ValueError):
                continue
            items.append({"name": meta.get("name") or d.name,
                          "title": meta.get("title") or d.name,
                          "updatedAt": meta.get("updatedAt")})
    return {"ok": True, "apps": items}


async def delete_app(name: str) -> dict[str, Any]:
    d = _app_dir(name)
    async with _lock_for(name):
        if not d.exists():
            raise A2uiError(f"no_app:{name}")
        shutil.rmtree(d)
        portfolio_remove(kind="a2ui", ref=name)
    return {"ok": True}


# ---------- 作品集（横切收藏夹：a2ui / video / three） ----------

def _portfolio() -> dict[str, Any]:
    raw = _read_json(PORTFOLIO_FILE, {"items": [], "hidden": []})
    if not isinstance(raw, dict):
        raw = {"items": [], "hidden": []}
    if not isinstance(raw.get("items"), list):
        raw["items"] = []
    if not isinstance(raw.get("hidden"), list):
        raw["hidden"] = []
    return raw


def _save_portfolio(p: dict[str, Any]) -> None:
    _atomic_write(PORTFOLIO_FILE, json.dumps(p, ensure_ascii=False, indent=1))


def _hidden_set(p: dict[str, Any]) -> set[tuple[str, str]]:
    out: set[tuple[str, str]] = set()
    for h in p.get("hidden", []):
        if isinstance(h, dict):
            out.add((str(h.get("kind", "")), str(h.get("ref", ""))))
    return out


def _unhide(p: dict[str, Any], kind: str, ref: str) -> None:
    p["hidden"] = [h for h in p.get("hidden", [])
                   if not (isinstance(h, dict) and h.get("kind") == kind and h.get("ref") == ref)]


def portfolio_upsert(kind: str, ref: str, title: str, path: str, detail: str = "") -> None:
    p = _portfolio()
    entry = {"kind": kind, "ref": ref, "title": title, "path": path,
             "detail": detail, "ts": int(time.time())}
    p["items"] = [e for e in p["items"]
                  if not (isinstance(e, dict) and e.get("kind") == kind and e.get("ref") == ref)]
    p["items"].insert(0, entry)
    _unhide(p, kind, ref)  # 重新登记 = 用户重新要它（video/three 从隐藏恢复）
    _save_portfolio(p)


def portfolio_remove(kind: str, ref: str) -> None:
    p = _portfolio()
    p["items"] = [e for e in p["items"]
                  if not (isinstance(e, dict) and e.get("kind") == kind and e.get("ref") == ref)]
    _save_portfolio(p)


def portfolio_list() -> dict[str, Any]:
    """聚合三类产物：index.json 登记 + 存在性校验（文件被手删的条目剔除）。"""
    p = _portfolio()
    hidden = _hidden_set(p)
    items = []
    for e in p.get("items", []):
        if not isinstance(e, dict):
            continue
        if (str(e.get("kind", "")), str(e.get("ref", ""))) in hidden:
            continue
        if Path(e.get("path", "")).exists():
            items.append(e)
    # 存量补扫：workspace 里已有但未登记的 mp4 / 3D html（首次启用作品集即可见历史产物）
    video_root = Path.home() / "Documents" / "NoNDesign" / "video"
    known = {(e.get("kind"), e.get("ref")) for e in items} | hidden
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
    """从作品集移除条目（a2ui 同时删源目录；video/three 仅隐藏不删产物）。

    a2ui 的 ref 必须经 ``_app_dir`` 全量校验并断言不出 ``A2UI_ROOT``——
    ref 来自 HTTP body，空串/``..``/绝对路径/null 字节都曾在旧实现里
    直达 ``shutil.rmtree``（空串会删整个应用根）。
    """
    if kind not in PORTFOLIO_KINDS:
        raise A2uiError(f"invalid_kind:{kind} —— 只允许 {'/'.join(PORTFOLIO_KINDS)}")
    if kind == "a2ui":
        d = _app_dir(ref)
        if d.parent != A2UI_ROOT:  # 显式断言：删除目标只能落在应用根下一层
            raise A2uiError(f"invalid_ref:{ref} —— 路径越界")
        if d.exists():
            shutil.rmtree(d)
        portfolio_remove(kind=kind, ref=ref)
        p = _portfolio()
        _unhide(p, kind, ref)  # 源码已删：收藏隐藏标记不再有意义
        _save_portfolio(p)
    else:
        # video/three 的 ref 是产物路径/目录名，产物本身不归作品集所有：
        # 删除 = 只从收藏夹隐藏（补扫时跳过 hidden），否则删完又被扫回来。
        p = _portfolio()
        if (kind, ref) not in _hidden_set(p):
            p.setdefault("hidden", []).append({"kind": kind, "ref": ref})
        _save_portfolio(p)
    return {"ok": True}
