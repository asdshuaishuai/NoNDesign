#!/usr/bin/env python3
"""ACP 客户端全链路单测：fake agent（裸 JSON-RPC over stdio）× AcpSession。

用法：.venv/bin/python scripts/wf/test_acp_client.py （退出码 0 = 全绿）
覆盖：initialize 握手、session/new、prompt 流式 delta（assistant/thinking/
tool）、fs write 回调的工作区限制、stopReason=done 终态。
"""

from __future__ import annotations

import asyncio
import json
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "server"))

from acp_bridge import AcpRegistry  # noqa: E402

FAKE_AGENT = r"""
import json, sys, pathlib

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

for raw in sys.stdin:
    req = json.loads(raw)
    m, i = req.get("method"), req.get("id")
    if m == "initialize":
        send({"jsonrpc": "2.0", "id": i, "result": {"protocolVersion": 1, "agentCapabilities": {}}})
    elif m == "session/new":
        send({"jsonrpc": "2.0", "id": i, "result": {"sessionId": "fake-1"}})
    elif m == "session/prompt":
        sid = req["params"]["sessionId"]
        # 流式：thinking → assistant 增量 ×2 → tool 调用+完成 → done
        def upd(u):
            send({"jsonrpc": "2.0", "method": "session/update",
                  "params": {"sessionId": sid, "update": u}})
        upd({"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "想一下"}})
        upd({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "你好"}})
        upd({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "，世界"}})
        upd({"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "写文件", "kind": "other"})
        # fs 写请求（独立 id）：下一行 stdin 就是客户端的 fs 响应，回收后收尾
        send({"jsonrpc": "2.0", "id": 9001, "method": "fs/write_text_file",
              "params": {"sessionId": sid, "path": str(pathlib.Path(sys.argv[1]) / "acp_probe.txt"), "content": "from agent"}})
        resp = json.loads(sys.stdin.readline())
        assert resp.get("id") == 9001, resp
        upd({"sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed"})
        send({"jsonrpc": "2.0", "id": i, "result": {"stopReason": "end_turn"}})
    elif m == "session/cancel":
        pass
    elif m == "fs/write_text_file":
        pass  # 不会走到（客户端是 responder）
"""


async def main() -> int:
    failures: list[str] = []

    def check(name: str, cond: bool, detail: str = "") -> None:
        if not cond:
            failures.append(f"{name}: {detail}")

    with tempfile.TemporaryDirectory() as ws:
        agent_script = Path(ws) / "fake_agent.py"
        agent_script.write_text(FAKE_AGENT.replace("sys.argv[1]", repr(ws)), "utf-8")
        (Path(ws) / "acp_probe.txt").unlink(missing_ok=True)

        registry = AcpRegistry()
        # 直接用 python 跑 fake agent（绕过目录探测）
        from acp_bridge import AcpSession

        session = AcpSession("t1", "fake", [sys.executable, str(agent_script), ws], ws)
        await session.start()
        check("remote session id", session.remote_session == "fake-1", str(session.remote_session))

        pending = await session.prompt("你好")
        events = []
        while True:
            ev = await asyncio.wait_for(pending.queue.get(), timeout=15)
            events.append(ev)
            if ev.get("type") in ("done", "failed"):
                break

        kinds = [e.get("type") for e in events]
        check("thinking streamed", "thinking_delta" in kinds, str(kinds))
        deltas = [e for e in events if e.get("type") == "assistant_delta"]
        check("assistant deltas x2", len(deltas) == 2, str(kinds))
        check("delta text joined", "".join(e["text"] for e in deltas) == "你好，世界", str([e.get("text") for e in deltas]))
        check("tool_start seen", "tool_start" in kinds, str(kinds))
        check("tool_end seen", "tool_end" in kinds, str(kinds))
        done = events[-1]
        check("done stopReason", done.get("type") == "done" and done.get("stopReason") == "end_turn", str(done))

        # fs 回调落盘（工作区内允许）
        probe = Path(ws) / "acp_probe.txt"
        check("fs write callback landed", probe.exists() and probe.read_text() == "from agent",
              str(probe.exists()))

        # 工作区外写入被拒
        outside = session.client._resolve("/etc/hosts")
        check("outside workspace rejected", outside is None, str(outside))

        await registry.close("nonexistent")  # 幂等
        await session.close()

    if failures:
        print("FAIL")
        for f in failures:
            print(" -", f)
        return 1
    print("acp client: all cases green")
    return 0


async def test_probe() -> list[str]:
    """协议级探测单测：verified / failed 两例。"""
    from acp_bridge import AgentCatalogEntry, Candidate, probe_entry

    failures: list[str] = []
    with tempfile.TemporaryDirectory() as ws:
        agent_script = Path(ws) / "fake_probe_agent.py"
        # 探针走 _which（X_OK 检查）：补 shebang + 执行位
        agent_script.write_text("#!/usr/bin/env python3\n" + FAKE_AGENT.replace("sys.argv[1]", repr(ws)), "utf-8")
        agent_script.chmod(0o755)
        good = await probe_entry(AgentCatalogEntry("fake-good", "Fake", [
            Candidate([str(agent_script)], ["{exe}"]),
        ], "probe fixture"))
        failures.append("probe verified") if good.state != "verified" else None
        failures.append(f"probe command {good.command}") if not good.command else None
        bad = await probe_entry(AgentCatalogEntry("fake-bad", "Echo", [
            Candidate(["echo"], ["{exe}", "not-acp"]),
        ], "probe fixture"))
        failures.append("probe failed expected") if bad.state != "failed" else None
    return failures


async def run_all() -> int:
    failures = []
    r = await main.__wrapped__() if hasattr(main, "__wrapped__") else None
    return failures


if __name__ == "__main__":
    import asyncio as _aio

    code = _aio.run(main())
    probe_failures = _aio.run(test_probe())
    if probe_failures:
        print("PROBE FAIL")
        for f in probe_failures:
            print(" -", f)
        code = code or 1
    else:
        print("probe: verified/failed cases green")
    raise SystemExit(code)
