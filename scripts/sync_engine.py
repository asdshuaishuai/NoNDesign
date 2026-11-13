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
    MANIFEST.write_text(
        json.dumps(
            {
                "version": version.get("version"),
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
        f"[sync_engine] ✓ {version.get('version')} · {len(templates)} templates / "
        f"{len(components)} components / render ok"
    )


if __name__ == "__main__":
    main()
