#!/usr/bin/env python3
"""Deterministic coverage gate: the engine capabilities this run must wire into
the NoNDesign app. Each entry = (label, grep token, search roots). Exit 0 only
when every token is referenced in at least one searched root.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))

REQUIRED = [
    ("组件状态切换 set-state", "set-state", ["app/lib"]),
    ("布局意图 constrain", "/engine/constrain", ["app/lib"]),
    ("引擎版本控制 engineHistory 调用点", ".engineHistory(", ["app/lib"]),
    ("设计规范提取 extract_design_system", "session_extract_design_system", ["app/lib"]),
    ("缺失体检 infer_missing", "session_infer_missing", ["app/lib"]),
    ("页型判定 infer_page_type", "session_infer_page_type", ["app/lib"]),
    ("演示手势 /engine/event", "/engine/event", ["app/lib"]),
    ("翻转 flip", "flip", ["app/lib"]),
    ("响应式适配 responsive", "responsive", ["app/lib"]),
    ("体检物化 autofill", "autofill", ["app/lib"]),
    ("state/set-state 提示词教学", "state <artboard> <node> <state_name>", ["server"]),
]


def used(token: str, roots: list[str]) -> bool:
    for root in roots:
        target = os.path.join(ROOT, root)
        if not os.path.isdir(target):
            continue
        out = subprocess.run(
            ["grep", "-rlF", "--", token, target],
            capture_output=True, text=True, timeout=30,
        )
        if out.stdout.strip():
            return True
    return False


def main() -> int:
    missing = []
    for label, token, roots in REQUIRED:
        if not used(token, roots):
            missing.append(f"{label} (token: {token})")
    if missing:
        print("COVERAGE GAPS — these engine capabilities are still not wired:")
        for m in missing:
            print(f"  ✗ {m}")
        return 1
    print("COVERAGE OK — all required engine capabilities are wired into the app.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
