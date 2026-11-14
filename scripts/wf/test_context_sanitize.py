#!/usr/bin/env python3
"""tool 配对消毒单测：压缩切断配对是 400 的根因（2026-11-14 真机实证）。

用法：.venv/bin/python scripts/wf/test_context_sanitize.py （退出码 0 = 全绿）
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "server"))

from context import _sanitize_tool_pairing  # noqa: E402


def call(cid: str) -> dict:
    return {"type": "function_call", "call_id": cid, "name": "moonviz_op", "arguments": "{}"}


def output(cid: str) -> dict:
    return {"type": "function_call_output", "call_id": cid, "output": "{}"}


def msg(role: str, text: str = "x") -> dict:
    return {"type": "message", "role": role, "content": [{"type": "output_text", "text": text}]}


def main() -> int:
    failures: list[str] = []

    def check(name: str, cond: bool, detail: str = "") -> None:
        if not cond:
            failures.append(f"{name}: {detail}")

    # 1) 完整配对原样保留
    items = [msg("user"), call("a"), output("a"), msg("assistant")]
    kept = _sanitize_tool_pairing(items)
    check("complete pair kept", kept == items, repr(kept))

    # 2) 孤立调用（中断未执行）被剔除
    items = [msg("user"), call("a"), output("b"), msg("assistant", "after")]
    kept = _sanitize_tool_pairing(items)
    check("orphan call dropped", not any(i.get("type") == "function_call" for i in kept), repr(kept))
    check("orphan output dropped too", not any(i.get("type") == "function_call_output" for i in kept), repr(kept))
    check("plain messages kept", sum(1 for i in kept if i.get("type") == "message") == 2, repr(kept))

    # 3) 结果存在但调用被压缩切掉 → 结果剔除、后续消息保留
    items = [output("gone"), msg("user", "next"), call("a"), output("a")]
    kept = _sanitize_tool_pairing(items)
    check("orphan output removed", all(i.get("call_id") != "gone" for i in kept), repr(kept))
    check("valid pair survives", {"a"} == {i.get("call_id") for i in kept if i.get("type") == "function_call"}, repr(kept))
    check("order preserved", [i.get("type") for i in kept] == ["message", "function_call", "function_call_output"], repr(kept))

    # 4) 非 dict / 无 type 条目原样保留（防御）
    kept = _sanitize_tool_pairing(["raw", {"role": "user"}])
    check("opaque items kept", kept == ["raw", {"role": "user"}], repr(kept))

    if failures:
        print("FAIL")
        for f in failures:
            print(" -", f)
        return 1
    print("sanitize: all cases green")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
