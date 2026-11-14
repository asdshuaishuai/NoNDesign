"""ACP（Agent Client Protocol）外部智能体接入。

自动检测本机已安装的主流 ACP 智能体 CLI（Claude Code / Codex / Kimi / Pi /
StepCode / MiniMax Code / OMP / Gemini / Qwen / Cline…），经官方 Python SDK
（agent-client-protocol，导入名 acp）以 stdio JSON-RPC 连接。Pivot 是我们自己的
智能体，目录中占位置灰（coming soon）。

MVP 范围：initialize → session/new（cwd=工作区）→ prompt（文本）→
session/update 流式转发（消息增量/思考/工具调用/计划）；权限请求自动放行并记录；
fs 读写回调限制在工作区目录内。
"""

from __future__ import annotations

import asyncio
import shutil
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from acp import Client, ClientSideConnection, PromptRequest
from acp.schema import (
    AgentMessageChunk,
    AgentThoughtChunk,
    Plan,
    StopReason,
    ToolCall,
    ToolCallUpdate,
    UserMessageChunk,
)

PROTOCOL_VERSION = 1


@dataclass
class AgentCatalogEntry:
    """目录项：探测可执行名 + 启动 argv + 展示信息。"""

    id: str
    name: str
    execs: list[str]
    argv: list[str]  # {exe} 占位符替换为探测到的可执行路径
    note: str
    grayed: bool = False


AGENT_CATALOG: list[AgentCatalogEntry] = [
    AgentCatalogEntry("claude-code", "Claude Code", ["claude-code-acp", "claude-agent-acp"], ["{exe}"], "经 Zed 官方 ACP 适配器（claude-code-acp）"),
    AgentCatalogEntry("codex", "Codex CLI", ["codex-acp"], ["{exe}"], "经 codex-acp 适配器"),
    AgentCatalogEntry("kimi", "Kimi Code", ["kimi"], ["{exe}", "acp"], "Kimi CLI 的 acp 子命令"),
    AgentCatalogEntry("pi", "Pi", ["pi-acp"], ["{exe}"], "经 pi-acp 适配器"),
    AgentCatalogEntry("stepcode", "StepCode", ["stepcode", "stepcode-acp"], ["{exe}", "acp"], "StepFun 智能体 CLI"),
    AgentCatalogEntry("minimax-code", "MiniMax Code", ["minimax-code", "minimax"], ["{exe}", "acp"], "MiniMax 智能体 CLI"),
    AgentCatalogEntry("omp", "OMP", ["omp"], ["{exe}", "acp"], "检测到 omp 即列出；若为同名非 ACP 程序，连接时会报错"),
    AgentCatalogEntry("pivot", "Pivot", ["pivot"], ["{exe}", "acp"], "我们自己的智能体 · 即将接入", grayed=True),
    AgentCatalogEntry("gemini", "Gemini CLI", ["gemini"], ["{exe}", "--experimental-acp"], "Google 官方，--experimental-acp 旗标"),
    AgentCatalogEntry("qwen", "Qwen Code", ["qwen"], ["{exe}", "--experimental-acp"], "gemini-cli 分支，同旗标"),
    AgentCatalogEntry("cline", "Cline", ["cline"], ["{exe}", "acp"], "Cline CLI 的 acp 子命令"),
]


def detect_agents() -> list[dict[str, Any]]:
    """按目录探测 PATH，返回给前端的清单（installed/grayed/命令）。"""
    out: list[dict[str, Any]] = []
    for entry in AGENT_CATALOG:
        found = next((shutil.which(e) for e in entry.execs if shutil.which(e)), None)
        out.append(
            {
                "id": entry.id,
                "name": entry.name,
                "installed": found is not None,
                "executable": found,
                "command": [found if a == "{exe}" else a for a in entry.argv] if found else [],
                "note": entry.note,
                "grayed": entry.grayed,
            }
        )
    return out


@dataclass
class _PendingPrompt:
    queue: asyncio.Queue[dict[str, Any]] = field(default_factory=asyncio.Queue)
    done: bool = False


class _NoNDesignAcpClient(Client):
    """把 agent 的 session/update 回调转成内部事件队列。"""

    def __init__(self, workspace: str) -> None:
        self.workspace = Path(workspace).resolve()
        # 当前 prompt 的事件汇（AcpSession.prompt 挂上、终态后摘除）。
        # 单会话串行 prompt（AcpSession.lock 串行化），一个 sink 足够。
        self.sink: asyncio.Queue[dict[str, Any]] | None = None
        self._tool_seq = 0

    # ---- 事件泵 ----
    def _emit(self, event: dict[str, Any]) -> None:
        if self.sink is not None:
            self.sink.put_nowait(event)

    # ---- session/update 流 ----
    async def session_update(self, session_id: str, update: UserMessageChunk | AgentMessageChunk | AgentThoughtChunk | Plan | ToolCall | ToolCallUpdate, **kwargs: Any) -> None:  # noqa: ANN401
        kind = getattr(update, "session_update", None) or type(update).__name__
        if isinstance(update, AgentMessageChunk):
            text = getattr(update.content, "text", "") or ""
            if text:
                self._emit({"type": "assistant_delta", "text": text})
        elif isinstance(update, AgentThoughtChunk):
            text = getattr(update.content, "text", "") or ""
            if text:
                self._emit({"type": "thinking_delta", "text": text})
        elif isinstance(update, ToolCall):
            self._tool_seq += 1
            self._emit({"type": "tool_start", "tool": update.title or update.kind or "tool", "seq": self._tool_seq})
        elif isinstance(update, ToolCallUpdate) and getattr(update, "status", None) in ("completed", "failed"):
            self._emit({"type": "tool_end", "ok": update.status == "completed", "title": update.title or ""})
        elif isinstance(update, Plan):
            self._emit({"type": "note", "label": "计划更新", "detail": " · ".join(getattr(e, "content", "") or "" for e in (update.entries or [])[:6])})
        else:
            # UserMessageChunk 等回显忽略
            return

    # ---- 权限：MVP 自动放行并记录（SDK 路由按 kwargs 直传）----
    async def request_permission(self, session_id: str, tool_call: Any, options: list[Any], **kwargs: Any) -> Any:  # noqa: ANN401
        opts = options or []
        chosen = next((o for o in opts if "allow" in (o.kind or "")), opts[0] if opts else None)
        self._emit({"type": "note", "label": "权限放行", "detail": f"{getattr(tool_call, 'title', '') or 'tool'} → {chosen.name if chosen else 'auto'}"})
        from acp.schema import RequestPermissionResponse

        return RequestPermissionResponse(option_id=chosen.option_id if chosen else None)

    # ---- fs 回调：限制在工作区 ----
    def _resolve(self, path: str) -> Path | None:
        try:
            resolved = Path(path).resolve()
            resolved.relative_to(self.workspace)
            return resolved
        except (ValueError, OSError):
            return None

    async def read_text_file(self, session_id: str, path: str, line: int | None = None, limit: int | None = None, **kwargs: Any) -> Any:  # noqa: ANN401
        target = self._resolve(path)
        if target is None or not target.is_file():
            raise FileNotFoundError(path)
        lines = target.read_text("utf-8", errors="replace").splitlines(keepends=True)
        start = (line or 1) - 1 if line else 0
        end = start + limit if limit else None
        from acp.schema import ReadTextFileResponse

        return ReadTextFileResponse(content="".join(lines[start:end]))

    async def write_text_file(self, session_id: str, path: str, content: str, **kwargs: Any) -> Any:  # noqa: ANN401
        target = self._resolve(path)
        if target is None:
            raise PermissionError(f"outside workspace: {path}")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, "utf-8")
        from acp.schema import WriteTextFileResponse

        return WriteTextFileResponse()

    # 其余 hook：安静缺省（on_connect 是同步调用）
    def on_connect(self, conn: Any) -> None:  # noqa: ANN401
        self._agent = conn


class AcpSession:
    """一个外部智能体会话：子进程 + 连接 + 事件队列。"""

    def __init__(self, session_id: str, agent_id: str, argv: list[str], workspace: str) -> None:
        self.id = session_id
        self.agent_id = agent_id
        self.argv = argv
        self.workspace = workspace
        self.client = _NoNDesignAcpClient(workspace)
        self.proc: asyncio.subprocess.Process | None = None
        self.conn: ClientSideConnection | None = None
        self.remote_session: str | None = None
        self.lock = asyncio.Lock()
        self.pending: _PendingPrompt | None = None

    async def start(self) -> None:
        self.proc = await asyncio.create_subprocess_exec(
            *self.argv,
            cwd=self.workspace,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            limit=4 * 1024 * 1024,
        )
        assert self.proc.stdin is not None and self.proc.stdout is not None
        self.conn = ClientSideConnection(self.client, self.proc.stdin, self.proc.stdout)
        await self.conn.initialize(PROTOCOL_VERSION)
        resp = await self.conn.new_session(cwd=self.workspace, mcp_servers=[])
        self.remote_session = resp.session_id

    async def prompt(self, text: str) -> _PendingPrompt:
        async with self.lock:
            pending = _PendingPrompt()
            self.pending = pending
            conn = self.conn
            remote = self.remote_session
            if conn is None or remote is None:
                raise RuntimeError("session not started")

            self.client.sink = pending.queue

            async def _run() -> None:
                try:
                    resp = await conn.prompt(
                        PromptRequest(session_id=remote, prompt=[{"type": "text", "text": text}])
                    )
                    stop = resp.stop_reason if isinstance(resp.stop_reason, str) else str(resp.stop_reason)
                    pending.queue.put_nowait({"type": "done", "stopReason": stop})
                except asyncio.CancelledError:
                    pending.queue.put_nowait({"type": "done", "stopReason": "cancelled"})
                except Exception as exc:  # noqa: BLE001
                    pending.queue.put_nowait({"type": "failed", "error": f"{type(exc).__name__}: {exc}"})
                finally:
                    pending.done = True
                    self.client.sink = None

            self._task = asyncio.create_task(_run())
            return pending

    def cancel(self) -> None:
        if self.conn is not None and self.remote_session:
            try:
                asyncio.get_running_loop().create_task(self.conn.cancel(self.remote_session))
            except RuntimeError:
                pass

    async def close(self) -> None:
        self.cancel()
        if self.proc and self.proc.returncode is None:
            try:
                self.proc.terminate()
            except ProcessLookupError:
                pass


class AcpRegistry:
    """会话注册表：id → AcpSession。进程内存活，服务重启即重建（外部智能体本就无持久状态承诺）。"""

    def __init__(self) -> None:
        self.sessions: dict[str, AcpSession] = {}
        self._seq = 0
        self._lock = asyncio.Lock()

    async def create(self, agent_id: str, workspace: str) -> dict[str, Any]:
        entry = next((e for e in AGENT_CATALOG if e.id == agent_id), None)
        if entry is None:
            return {"ok": False, "error": "unknown_agent"}
        if entry.grayed:
            return {"ok": False, "error": "agent_grayed", "note": entry.note}
        executable = next((shutil.which(e) for e in entry.execs if shutil.which(e)), None)
        if executable is None:
            return {"ok": False, "error": "agent_not_installed", "note": entry.note}
        argv = [executable if a == "{exe}" else a for a in entry.argv]
        async with self._lock:
            self._seq += 1
            session = AcpSession(f"acp-{self._seq}", agent_id, argv, workspace)
            try:
                await session.start()
            except Exception as exc:  # noqa: BLE001
                return {"ok": False, "error": f"{type(exc).__name__}: {exc}", "note": entry.note}
            self.sessions[session.id] = session
            return {"ok": True, "sessionId": session.id, "agent": agent_id}

    def get(self, session_id: str) -> AcpSession | None:
        return self.sessions.get(session_id)

    async def close(self, session_id: str) -> None:
        session = self.sessions.pop(session_id, None)
        if session:
            await session.close()
