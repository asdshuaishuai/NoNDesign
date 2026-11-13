#!/usr/bin/env python3
"""Deterministic matrix: MoonViz engine capability surface vs NoNDesign usage.

Dumps the engine's op registry + wasm export names, then greps the NoNDesign
codebase (server/ + app/lib) for each token. Exit 0 always (audit is data).
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "server"))

from engine import EngineHost  # noqa: E402


def usage_count(token: str) -> int:
    """Count source files referencing the token in server/ + app/lib."""
    hits = 0
    for base in ("server", os.path.join("app", "lib")):
        try:
            out = subprocess.run(
                ["grep", "-rl", "--", token, os.path.join(ROOT, base)],
                capture_output=True, text=True, timeout=30,
            )
            files = [f for f in out.stdout.splitlines() if f.strip()]
            hits += len(files)
        except Exception:
            pass
    return hits


def main() -> int:
    host = EngineHost()
    ops = host.list_ops()
    op_rows = []
    for o in ops if isinstance(ops, list) else []:
        if isinstance(o, dict) and o.get("op"):
            op_rows.append({
                "op": o["op"],
                "gates": o.get("gates") or {},
                "usage_files": usage_count(str(o["op"])),
            })

    # session API presence + usage
    session_names = [
        "session_apply_agent", "session_apply_human", "session_export_svg", "session_lint",
        "session_critique", "session_auto_fix", "session_query_nodes", "session_list_artboards",
        "session_flows", "session_interactions", "session_states", "session_spec",
        "session_constrain", "session_infer_page_type", "session_infer_missing",
        "session_extract_design_system", "session_generate_responsive", "session_benchmark",
        "session_save", "session_component_compile_b64", "session_library_snapshot",
        "session_tap", "session_history", "session_generate", "session_snapshot",
        "session_generate_spec", "session_event",
    ]
    session_rows = []
    inst_export_check = None
    for name in session_names:
        session_rows.append({
            "session": name,
            "usage_files": usage_count(name),
        })

    matrix = {
        "engine_version": host.version_info().get("version"),
        "ops": op_rows,
        "sessions": session_rows,
        "unused_ops": [r["op"] for r in op_rows if r["usage_files"] == 0],
        "unused_sessions": [r["session"] for r in session_rows if r["usage_files"] == 0],
    }
    print(json.dumps(matrix, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
