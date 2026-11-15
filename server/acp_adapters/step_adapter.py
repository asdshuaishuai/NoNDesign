#!/usr/bin/env python3
"""StepCode 的 NoN 自研 ACP 适配层（2026-11-15）。

step CLI 当前没有 ACP 入口（`--acp` 拒绝、`acp` 无协议响应），但有稳定的
非交互形态：`step -p "<prompt>"`（--non-interactive-approval allow 自动放行
工具审批）。本适配层把它包成 ACP agent：prompt 进来 spawn step -p，
stdout 逐行打成 agent_message_chunk 流，进程退出即 end_turn。

局限（诚实边界）：text 流拿不到结构化 tool_call 事件——step 的工具执行
在子进程内部完成，只回显最终文本与过程输出。等 step 官方出 ACP/rpc 面
（`--mode rpc`/`--sdk-stdio` 已埋线）再换原生实现。

协议面：initialize / session/new / session/prompt / session/cancel，
newline-delimited JSON-RPC（与 acp SDK 的 stdio framing 一致）。
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
import uuid

PROTOCOL_VERSION = 1
_agent_info = {"name": "StepCode", "version": "non-adapter-1"}
_sessions: dict[str, dict[str, asyncio.subprocess.Process | None]] = {}


def _send(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def _reply(req_id, result: dict) -> None:
    _send({"jsonrpc": "2.0", "id": req_id, "result": result})


def _update(session_id: str, update: dict) -> None:
    _send({"jsonrpc": "2.0", "method": "session/update",
           "params": {"sessionId": session_id, "update": update}})


def _step_command(prompt: str) -> list[str]:
    exe = None
    for d in os.environ.get("PATH", "").split(":"):
        cand = os.path.join(d, "step")
        if os.access(cand, os.X_OK):
            exe = cand
            break
    argv = [exe] if exe else ["step"]
    return [*argv, "-p", "--non-interactive-approval", "allow", "--no-session", prompt]


async def run_prompt(session_id: str, prompt: str, req_id) -> None:
    child = await asyncio.create_subprocess_exec(
        *_step_command(prompt),
        cwd=os.getcwd(),
        # stdin=DEVNULL：step 继承 adapter 的 stdin 管道会等待永不到来的
        # EOF 而挂起（2026-11-15 实证）；非交互 oneshot 不需要 stdin。
        stdin=asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )
    _sessions[session_id]["child"] = child
    assert child.stdout is not None
    while True:
        line = await child.stdout.readline()
        if not line:
            break
        text = line.decode("utf-8", errors="replace").rstrip("\n")
        if text.strip():
            _update(session_id, {
                "sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": text + "\n"},
            })
    code = await child.wait()
    _sessions[session_id]["child"] = None
    _reply(req_id, {"stopReason": "end_turn" if code == 0 else "refused"})


async def handle(req: dict) -> None:
    method = req.get("method", "")
    req_id = req.get("id")
    params = req.get("params") or {}
    if method == "initialize":
        _reply(req_id, {"protocolVersion": PROTOCOL_VERSION, "agentCapabilities": {"prompts": True}})
    elif method == "session/new":
        sid = "step-" + uuid.uuid4().hex[:8]
        _sessions[sid] = {"child": None}
        _reply(req_id, {"sessionId": sid})
    elif method == "session/prompt":
        sid = params.get("sessionId", "")
        text = "".join(
            b.get("text", "") for b in params.get("prompt", [])
            if isinstance(b, dict) and b.get("type") == "text"
        ).strip()
        if not text:
            _reply(req_id, {"stopReason": "refused"})
            return
        asyncio.create_task(run_prompt(sid, text, req_id))
    elif method == "session/cancel":
        st = _sessions.get(params.get("sessionId", ""))
        if st and st.get("child") and st["child"].returncode is None:
            st["child"].terminate()
    elif req_id is not None:
        _reply(req_id, {})


async def main() -> None:
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader()
    await loop.connect_read_pipe(
        lambda: asyncio.StreamReaderProtocol(reader), sys.stdin
    )
    while True:
        line = await reader.readline()
        if not line:
            return
        try:
            req = json.loads(line.decode("utf-8"))
        except Exception:
            continue
        if isinstance(req, dict) and req.get("method"):
            await handle(req)


if __name__ == "__main__":
    asyncio.run(main())
