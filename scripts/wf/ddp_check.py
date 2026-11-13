#!/usr/bin/env python3
"""Deterministic DDP gate: decrypt + render a real .ddp, print a JSON summary.

Exit 0 only when the container opens and the engine renders it.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "server"))

from ddp import decrypt_ddp  # noqa: E402
from engine import EngineHost  # noqa: E402


def main() -> int:
    path = sys.argv[1]
    password = os.environ.get("NONDESIGN_DDP_PASSWORD", "")
    with open(path, "rb") as fh:
        data = fh.read()
    magic = data[:4].decode("ascii", errors="replace")
    try:
        mbt = decrypt_ddp(data, password)
    except Exception as exc:
        print(json.dumps({"ok": False, "magic": magic, "error": f"decrypt_failed:{exc}"}))
        return 1
    host = EngineHost()
    env = host.render(mbt)
    boards = env.get("artboards") or []
    summary = {
        "ok": bool(env.get("ok")) and bool(boards),
        "magic": magic,
        "boards": len(boards),
        "nodes": sum(len(b.get("nodes") or []) for b in boards if isinstance(b, dict)),
        "flows": len(env.get("flows") or []),
        "revision": env.get("revision"),
        "error": env.get("error"),
    }
    print(json.dumps(summary, ensure_ascii=False))
    return 0 if summary["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
