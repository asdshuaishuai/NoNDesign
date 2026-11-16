#!/usr/bin/env python3
"""Sync / verify the MoonViz classic wasm artifact.

Usage:
  python scripts/sync_engine.py              resolve per ENGINE_LOCAL marker (see below)
  python scripts/sync_engine.py --local PATH copy a local dev build AND write the marker
  python scripts/sync_engine.py --release    explicit fallback to the pinned GitHub Release asset

本地集成模式（ENGINE_LOCAL 标记，gitignored）：
  标记在场（一行 = 本地构建 wasm 路径）时，默认同步从该路径取引擎——dev 跑法
  持续使用本地构建，rebuild 后重跑本脚本即可；不会被 Release 产物静默覆盖。
  标记缺省才走「校验现存 / 缺失时拉 Release」。

⚠️ --release 当前是死路（2026-11-17 登记）：本仓跑 0.2 能力线，上游尚未发布
0.2 Release——锚定的 engine-v0.1.11 资产缺 0.2 面（无 session_event_in 导出，
真机验证 51 vs 53 个 session 导出），下载后必被 probe_engine_02 拒绝，脚本会
在下载前 fail-fast。上游 0.2 出线后同步 RELEASE_TAG/RELEASE_ASSET/RELEASE_SHA512
即自动恢复「生产锚定 Release」语义；在那之前唯一能过探针的来源是本地 dev
构建（--local / ENGINE_LOCAL 标记）。
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import sys
import urllib.request
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
ENGINE_DIR = ROOT / "engine"
WASM = ENGINE_DIR / "moonviz.wasm"
MANIFEST = ENGINE_DIR / "manifest.json"
ENGINE_LOCAL = ENGINE_DIR / "ENGINE_LOCAL"
RELEASE_TAG = "engine-v0.1.11"
RELEASE_ASSET = "moonviz-wasm-classic-0.1.11.wasm"
RELEASE_SHA512 = "sha512-3z5jItQ5FHzeQ6nGuBzBQbIOtTsDnB9JIlSs9DH0GQNT+w17sfLkgh6pnN57ut9tacBS1GKO5Jf1g0jP7PRQZA=="
URL = f"https://github.com/asdshuaishuai/moonviz/releases/download/{RELEASE_TAG}/{RELEASE_ASSET}"
# moonviz-dev worktree 的默认构建产物路径（与仓库同级，deepDesign 同源）。
DEFAULT_LOCAL_BUILD = ROOT.parent / "moonviz-dev" / "_build" / "wasm" / "release" / "build" / "wasm" / "wasm.wasm"


def sha512(data: bytes) -> str:
    return "sha512-" + base64.b64encode(hashlib.sha512(data).digest()).decode()


def marker_path() -> Path | None:
    """ENGINE_LOCAL 标记内容即本地构建路径；空文件回落默认构建路径。"""
    if not ENGINE_LOCAL.exists():
        return None
    text = ENGINE_LOCAL.read_text("utf-8").strip()
    return Path(text) if text else DEFAULT_LOCAL_BUILD


def _release_anchor_predates_02() -> bool:
    """RELEASE_TAG 锚点是否早于 0.2 能力线（"engine-v0.1.11" → minor 1）。

    真机验证：0.1.11 Release 资产无 session_event_in 导出，probe_engine_02 必拒。
    锚点升到 v0.2.x 后本判定自动放行——无需再改这里。"""
    import re as _re

    m = _re.search(r"engine-v(\d+)\.(\d+)", RELEASE_TAG)
    return not m or int(m.group(2)) < 2


def _fetch_release() -> bytes:
    """下载锚定的 Release 资产并校验 sha512；锚点早于 0.2 面时 fail-fast。"""
    if _release_anchor_predates_02():
        raise SystemExit(
            f"pinned release predates the 0.2 capability face: RELEASE_TAG={RELEASE_TAG}\n"
            "  真机验证：该资产缺 session_event_in 等 0.2 导出，下载后必被 probe_engine_02 拒绝。\n"
            "  上游发布 0.2 Release 后同步 RELEASE_TAG/RELEASE_ASSET/RELEASE_SHA512 再锚定；\n"
            "  当前唯一能过探针的引擎来源是本地 dev 构建：scripts/sync_engine.py --local ../moonviz-dev/_build/wasm/release/build/wasm/wasm.wasm"
        )
    print(f"[sync_engine] downloading {URL}")
    with urllib.request.urlopen(URL, timeout=60) as response:
        data = response.read()
    got = sha512(data)
    if got != RELEASE_SHA512:
        raise SystemExit(f"sha512 mismatch\n  expected {RELEASE_SHA512}\n  actual   {got}")
    return data


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--local", help="copy a local wasm build (writes the ENGINE_LOCAL marker)")
    parser.add_argument("--release", action="store_true", help="download the pinned release (overrides the marker for this run)")
    args = parser.parse_args()
    ENGINE_DIR.mkdir(parents=True, exist_ok=True)

    if args.local:
        src = Path(args.local)
        if not src.exists():
            raise SystemExit(f"local wasm missing: {src}")
        data = src.read_bytes()
        source = f"local: {src}"
        ENGINE_LOCAL.write_text(f"{src}\n", "utf-8")
        print(f"[sync_engine] ENGINE_LOCAL marker → {src}")
    elif args.release:
        if ENGINE_LOCAL.exists():
            print(f"[sync_engine] ⚠️ ENGINE_LOCAL 在场（{marker_path()}）——本次显式锚定 Release 产物；删除标记或重跑 --local 恢复本地集成模式")
        data = _fetch_release()
        source = URL
    else:
        local = marker_path()
        if local is not None:
            if not local.exists():
                raise SystemExit(
                    f"ENGINE_LOCAL 指向的本地构建缺失：{local}\n"
                    f"  先在 moonviz-dev 构建：cd {local.parents[4]} && moon build --release --target wasm wasm\n"
                    "  （--release 不是可用回落：锚定的 0.1.11 资产缺 0.2 面，探针必拒——"
                    "上游 0.2 出线并更新锚点前，本地构建是唯一能过探针的来源）"
                )
            data = local.read_bytes()
            source = f"local: {local}"
        elif WASM.exists():
            data = WASM.read_bytes()
            source = "existing engine/moonviz.wasm"
        else:
            data = _fetch_release()
            source = URL

    WASM.write_bytes(data)
    digest = sha512(data)
    print(f"[sync_engine] {len(data) / 1024:.0f} KB · {digest[:28]}…")

    # Real contract probe through the Python host.
    sys.path.insert(0, str(ROOT / "server"))
    import os

    os.environ["NONDESIGN_WASM"] = str(WASM)
    from engine import EngineHost

    host = EngineHost()
    version = host.version_info()
    templates = host.list_templates()
    components = host.list_components()
    seed = (
        "---\nmoonviz:\n  format: visual-document\n  revision: 1\n  entry: __seed\n---\n\n"
        "# __seed\n\n<!-- moonviz:artboard __seed -->\n```mbt\n"
        'fn visual___seed() -> @decl.Prototype {\n  let page = @decl.prototype(name="__seed", width=390.0, height=844.0)\n  page\n}\n```\n'
    )
    rendered = host.render(seed)
    if not rendered.get("ok"):
        raise SystemExit(f"render probe failed: {rendered}")
    if len(templates) < 15:
        raise SystemExit(f"template registry shrank: {len(templates)}")
    if len(components) < 40:
        raise SystemExit(f"component registry shrank: {len(components)}")
    # 活注册表对账：快照条数只跟自己比，抓不住引擎组件面的增删——
    # wasm 有 list_components 活导出（真机验证 65/65 id 一致），必须逐 id 对账。
    live_ids = {c.get("id") for c in host.list_components_live() if isinstance(c, dict)}
    snap_ids = {c.get("id") for c in components if isinstance(c, dict)}
    if live_ids != snap_ids:
        raise SystemExit(
            "engine/components.json 快照与 wasm 活注册表漂移\n"
            f"  引擎有而快照缺：{sorted(live_ids - snap_ids)}\n"
            f"  快照有而引擎无：{sorted(snap_ids - live_ids)}\n"
            "  → 引擎组件面变更后必须重制 components.json 快照（agent 工具面与前端共用它）"
        )
    build_line = probe_engine_02(host, seed)
    MANIFEST.write_text(
        json.dumps(
            {
                "version": version.get("version"),
                # 引擎自报版本可能滞后于 dev 构建（0.2 dev 自报 0.1.11）——
                # build_line 是行为探针判定的事实，别拿 version 当能力面依据。
                "build_line": build_line,
                "source": source,
                "sha512": digest,
                "bytes": len(data),
                "templates": len(templates),
                "components": len(components),
            },
            indent=2,
        )
        + "\n",
        "utf-8",
    )
    print(
        f"[sync_engine] ✓ {version.get('version')} ({build_line}) · {len(templates)} templates / "
        f"{len(components)} components / render ok"
    )


def _apply(host: Any, doc: str, op: str) -> str:
    out = host.session("session_apply_human", doc, op)
    if not out.get("ok"):
        raise SystemExit(f"engine-0.2 probe: op {op!r} rejected: {out.get('error')}")
    return out["mbt"]


def probe_engine_02(host: Any, seed: str) -> str:
    """Behavior anchors for the engine-0.2 capability face. A true 0.1.11
    release wasm fails here — this repo runs the 0.2 line, and the self-reported
    version string may lag the dev build (probed: 0.2 dev self-reports 0.1.11).
    Every anchor below was verified against the real artifact before being
    pinned."""
    import json as _json
    import re as _re

    # 1) session_event export face.
    if not host.has_export("session_event_in"):
        raise SystemExit("engine-0.2 probe: session_event_in export missing (0.1.x wasm?)")

    # 2) spec style preset → frontmatter theme (needs the complete spec shape;
    #    a bare {"style":...} is silently ignored by the engine).
    spec = _json.dumps(
        {
            "v": 1,
            "style": "apple",
            "palette": {"primary": "#2F6B4F", "background": "#FFFFFF", "surface": "#F2F7F4",
                        "text": "#14201A", "muted": "#5F7A6B", "danger": "#DC2626", "success": "#16A34A"},
            "typography": {"h1": 30, "body": 14, "caption": 12},
            "spacing": [4, 8, 12, 16, 24, 32],
            "radius": {"sm": 8, "md": 12, "lg": 16},
        }
    )
    gen = host.generate(seed, "探针页 as probe_page", "probe_page", spec)
    if not gen.get("ok"):
        raise SystemExit(f"engine-0.2 probe: generate failed: {gen.get('error')}")
    if not _re.search(r"theme:\s*apple", gen.get("mbt", "")):
        raise SystemExit("engine-0.2 probe: spec style preset did not land (theme: apple missing)")

    # 3) gesture end-to-end: long_press on an interact marker navigates boards.
    doc = _apply(host, seed, "create probe_detail")
    doc = _apply(host, doc, "place __seed button probe_btn - 30 110 140 44 text=下一页")
    doc = _apply(host, doc, "flow __seed probe_detail probe_btn")
    doc = _apply(host, doc, "interact __seed probe_btn long_press navigate_to:probe_detail")
    ev = host.event(doc, "__seed", "long_press:100:130:500")
    if not (ev.get("ok") and ev.get("current") == "probe_detail"):
        raise SystemExit(f"engine-0.2 probe: gesture long_press did not navigate: {ev}")

    # 4) flow transition vocabulary: frontmatter `transition:` is accepted and
    #    surfaced by session_flows; an unknown value is rejected at render.
    doc_fade = _re.sub(r"([ ]+trigger: tap:\S+)", r"\1\n      transition: fade", doc, count=1)
    flows = host.session("session_flows", doc_fade)
    edges = (flows.get("data") or []) if isinstance(flows, dict) else []
    if not any(e.get("transition") == "fade" for e in edges):
        raise SystemExit(f"engine-0.2 probe: transition:fade not honored: {flows}")
    doc_bad = _re.sub(r"([ ]+trigger: tap:\S+)", r"\1\n      transition: bogus_xyz", doc, count=1)
    if host.render(doc_bad).get("ok"):
        raise SystemExit("engine-0.2 probe: unknown transition was NOT rejected")

    return "0.2-dev"


if __name__ == "__main__":
    main()
