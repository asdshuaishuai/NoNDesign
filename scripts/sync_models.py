#!/usr/bin/env python3
"""Refresh the models.dev capability snapshot used by the desktop app."""

from __future__ import annotations

import json
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "server"))
from models_store import _trim  # noqa: E402

SOURCE = "https://models.dev/api.json"
OUT = ROOT / "server" / "models.json"


def main() -> None:
    print(f"[sync_models] fetching {SOURCE} …")
    request = urllib.request.Request(SOURCE, headers={"User-Agent": "NoNDesign/0.1 (+models.dev snapshot)"})
    with urllib.request.urlopen(request, timeout=60) as response:
        raw = json.loads(response.read().decode("utf-8"))
    snapshot = _trim(raw)
    snapshot["fetched_at"] = __import__("datetime").date.today().isoformat()
    OUT.write_text(json.dumps(snapshot, ensure_ascii=False, indent=2) + "\n", "utf-8")
    providers = len(snapshot.get("providers", {}))
    models = sum(len(p.get("models", {})) for p in snapshot.get("providers", {}).values())
    print(f"[sync_models] ✓ {providers} providers / {models} models → {OUT}")


if __name__ == "__main__":
    main()
