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
from typing import Any

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


# 握手成功但 new_session 回伪响应、随后长眠：让 start() 在 new_session
# 校验处快速抛错（不等 30s 超时），子进程仍挂着——正是泄漏形态。
LEAKING_AGENT = r"""
import json, sys, time

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

for raw in sys.stdin:
    req = json.loads(raw)
    m, i = req.get("method"), req.get("id")
    if m == "initialize":
        send({"jsonrpc": "2.0", "id": i, "result": {"protocolVersion": 1, "agentCapabilities": {}}})
    elif m == "session/new":
        send({"jsonrpc": "2.0", "id": i, "result": {"bogus": True}})
        time.sleep(300)
"""


async def test_start_failure_terminates_child() -> list[str]:
    """start() 失败（握手超时/伪响应）必须 terminate 已 spawn 的 CLI 子进程。

    此前失败路径直接抛回 create()：会话未入注册表、close() 永不可达，
    每次失败泄漏一个孤儿进程（agent-4/server-3）。"""
    from acp_bridge import AcpSession

    failures: list[str] = []
    with tempfile.TemporaryDirectory() as ws:
        script = Path(ws) / "leaking_agent.py"
        script.write_text(LEAKING_AGENT, "utf-8")
        session = AcpSession("leak-t", "fake", [sys.executable, str(script)], ws)
        raised = False
        try:
            await session.start()
        except Exception:  # noqa: BLE001 - 任何失败形态都算
            raised = True
        if not raised:
            failures.append("start() should fail on bogus session/new response")
            await session.close()
            return failures
        # SIGTERM 递送需要一点时间；0.5s 后仍活着 = 泄漏。
        for _ in range(10):
            if session.proc is not None and session.proc.returncode is not None:
                break
            await asyncio.sleep(0.05)
        rc = session.proc.returncode if session.proc is not None else None
        if rc is None:
            failures.append(
                "spawned CLI child still alive after failed start() — orphan process leak")
    return failures


async def test_concurrent_prompt_sink_lifecycle() -> list[str]:
    """并发 prompt：先结束者不得摘掉后来者的 sink（agent-3）。

    AcpSession.lock 只覆盖装配不覆盖 prompt 生命周期——两个并发 prompt 时
    后者换掉 client.sink；先结束者的 finally 若无条件置 None，后一个
    prompt 的全部 assistant_delta 丢失。假 conn 以事件门控制完成顺序。"""
    from acp.schema import AgentMessageChunk, TextContentBlock

    from acp_bridge import AcpSession

    failures: list[str] = []

    class _GatedConn:
        def __init__(self) -> None:
            self.gates: dict[str, asyncio.Event] = {}

        async def prompt(self, req: Any) -> Any:
            chunk = req.prompt[0] if req.prompt else None
            text = getattr(chunk, "text", "") or ""
            await self.gates.setdefault(text, asyncio.Event()).wait()
            return type("R", (), {"stop_reason": "end_turn"})()

        async def cancel(self, session_id: str) -> None:  # close() 会试探
            return None

    with tempfile.TemporaryDirectory() as ws:
        session = AcpSession("sink-t", "fake", [sys.executable, "-c", "pass"], ws)
        conn = _GatedConn()
        session.conn = conn  # type: ignore[assignment]
        session.remote_session = "remote-1"

        pa = await session.prompt("A")
        pb = await session.prompt("B")  # 并发：sink 已被 B 接管

        conn.gates.setdefault("A", asyncio.Event()).set()
        terminal_a = await asyncio.wait_for(pa.queue.get(), timeout=5)
        if terminal_a.get("type") != "done":
            failures.append(f"prompt A terminal is {terminal_a!r}")
        await asyncio.sleep(0.05)  # 让 A 的 finally 先跑完

        # A 已结束；此刻 B 的 delta 必须仍能进 B 的队列。
        await session.client.session_update(
            "remote-1",
            AgentMessageChunk(content=TextContentBlock(type="text", text="B 的增量")),
        )
        conn.gates.setdefault("B", asyncio.Event()).set()

        b_events = []
        while True:
            ev = await asyncio.wait_for(pb.queue.get(), timeout=5)
            b_events.append(ev)
            if ev.get("type") in ("done", "failed"):
                break
        deltas = [e for e in b_events if e.get("type") == "assistant_delta"]
        if not any("B 的增量" in (e.get("text") or "") for e in deltas):
            failures.append(
                f"prompt B lost its deltas after A finished (sink torn down cross-prompt): {b_events!r}")
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
    leak_failures = _aio.run(test_start_failure_terminates_child())
    if leak_failures:
        print("START-FAILURE CLEANUP FAIL")
        for f in leak_failures:
            print(" -", f)
        code = code or 1
    else:
        print("start-failure cleanup: child terminated green")
    sink_failures = _aio.run(test_concurrent_prompt_sink_lifecycle())
    if sink_failures:
        print("SINK LIFECYCLE FAIL")
        for f in sink_failures:
            print(" -", f)
        code = code or 1
    else:
        print("concurrent prompt sink lifecycle: green")
    raise SystemExit(code)
