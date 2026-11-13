#!/usr/bin/env python3
"""Sync / verify the MoonViz classic wasm artifact.

Usage:
  python scripts/sync_engine.py              verify engine/moonviz.wasm (download if missing)
  python scripts/sync_engine.py --release    download the pinned GitHub Release asset
  python scripts/sync_engine.py --local PATH copy a local dev build
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
RELEASE_TAG = "engine-v0.1.11"
RELEASE_ASSET = "moonviz-wasm-classic-0.1.11.wasm"
RELEASE_SHA512 = "sha512-3z5jItQ5FHzeQ6nGuBzBQbIOtTsDnB9JIlSs9DH0GQNT+w17sfLkgh6pnN57ut9tacBS1GKO5Jf1g0jP7PRQZA=="
URL = f"https://github.com/asdshuaishuai/moonviz/releases/download/{RELEASE_TAG}/{RELEASE_ASSET}"


def sha512(data: bytes) -> str:
    return "sha512-" + base64.b64encode(hashlib.sha512(data).digest()).decode()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--local", help="copy a local wasm build")
    parser.add_argument("--release", action="store_true", help="download the pinned release")
    args = parser.parse_args()
    ENGINE_DIR.mkdir(parents=True, exist_ok=True)

    if args.local:
        src = Path(args.local)
        if not src.exists():
            raise SystemExit(f"local wasm missing: {src}")
        data = src.read_bytes()
        source = f"local: {src}"
    elif args.release or not WASM.exists():
        print(f"[sync_engine] downloading {URL}")
        with urllib.request.urlopen(URL, timeout=60) as response:
            data = response.read()
        got = sha512(data)
        if got != RELEASE_SHA512:
            raise SystemExit(f"sha512 mismatch\n  expected {RELEASE_SHA512}\n  actual   {got}")
        source = URL
    else:
        data = WASM.read_bytes()
        source = "existing engine/moonviz.wasm"

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
