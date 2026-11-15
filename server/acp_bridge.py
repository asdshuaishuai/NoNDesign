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
import os
import shutil
import sys
import tempfile
import time
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
ROOT_DIR = Path(__file__).resolve().parent.parent

# 服务端由 Flutter 拉起，PATH 常缺用户 shell 的私有目录（nvm/npm-global/
# ~/.local 等）——codex 就装在 ~/.nvm/versions/node/*/bin。检测合并：
# ① 登录 shell 的 PATH（缓存一次）② 常见安装目录 ③ nvm 全部 node 版本 bin。
_EXTRA_DIRS = ("~/.local/bin", "~/.stepcode/bin", "~/bin", "/opt/homebrew/bin",
               "/usr/local/bin", "/opt/homebrew/sbin", "/usr/local/sbin")
_login_path_cache: str | None = None


def _login_path() -> str:
    global _login_path_cache
    if _login_path_cache is None:
        try:
            import subprocess
            out = subprocess.run(
                ["/bin/zsh", "-lc", "echo $PATH"],
                capture_output=True, text=True, timeout=8,
            )
            _login_path_cache = out.stdout.strip() if out.returncode == 0 else ""
        except Exception:
            _login_path_cache = ""
    return _login_path_cache


def _scan_dirs() -> list[str]:
    """探测目录序：nvm 版本 bin（新版降序优先）→ 登录 PATH → 常见目录 → 进程 PATH。"""
    dirs: list[str] = []
    home = Path.home()
    nvm_root = home / ".nvm" / "versions" / "node"
    if nvm_root.is_dir():
        for vdir in sorted(nvm_root.iterdir(), key=lambda p: p.name, reverse=True):
            bins = vdir / "bin"
            if bins.is_dir():
                dirs.append(str(bins))
    for chunk in _login_path().split(":"):
        if chunk:
            dirs.append(chunk)
    for d in _EXTRA_DIRS:
        dirs.append(str(home / d[2:]) if d.startswith("~") else d)
    if "PATH" in os.environ:
        dirs.extend(p for p in os.environ["PATH"].split(":") if p)
    seen: set[str] = set()
    out: list[str] = []
    for d in dirs:
        if d not in seen:
            seen.add(d)
            out.append(d)
    return out


def _child_env() -> dict[str, str]:
    """ACP 子进程环境：PATH 前置强化目录——适配器内部再 spawn `pi`/`node`
    等也能解析到好副本（pi-acp 的 new_session 就栽在裸 PATH 上）。"""
    env = dict(os.environ)
    env["PATH"] = ":".join(_scan_dirs())
    return env


def _which(name: str) -> str | None:
    """登录 PATH + 常见目录 + nvm 版本 bin（新版优先）+ 进程 PATH 兜底。

    nvm 排在最前（版本号降序）：同名的坏旧副本（如 brew 遗留的 pi）不该
    遮蔽新装的可执行。
    """
    for d in _scan_dirs():
        cand = Path(d) / name
        if cand.is_file() and os.access(cand, os.X_OK):
            return str(cand)
    return None


@dataclass
class Candidate:
    """一个可启动形态：execs 命中即用 argv（{exe} 替换为命中路径）。"""

    execs: list[str]
    argv: list[str]


@dataclass
class AgentCatalogEntry:
    """目录项：按序探测 candidates（适配器二进制 → npx 官方包 → CLI 本体）。"""

    id: str
    name: str
    candidates: list[Candidate]
    note: str
    grayed: bool = False


# 最终白名单（用户定案 2026-11-15，就这几个，其他不考虑）：
# qwen / pi / claude / codex / dsh / stepcode / mcode / kimi / omp / gemini /
# pivot(置灰) / solon。适配策略：有第三方适配走 npx/中间适配器；只有
# stepcode 完全没有 → NoN 自研适配层（server/acp_adapters/step_adapter.py）。
AGENT_CATALOG: list[AgentCatalogEntry] = [
    AgentCatalogEntry("qwen", "Qwen Code", [
        Candidate(["qwen"], ["{exe}", "--experimental-acp"]),
    ], "gemini-cli 分支，--experimental-acp 旗标"),
    AgentCatalogEntry("pi", "Pi", [
        Candidate(["pi"], ["{exe}", "acp"]),
        Candidate(["pi-acp"], ["{exe}"]),
        Candidate(["npx"], ["npx", "-y", "pi-acp"]),
    ], "pi 系 ACP 入口为 <exe> acp 子命令（oh-my-pi 实证同形态）"),
    AgentCatalogEntry("claude-code", "Claude Code", [
        Candidate(["claude-code-acp", "claude-agent-acp"], ["{exe}"]),
        Candidate(["npx"], ["npx", "-y", "@zed-industries/claude-code-acp"]),
    ], "经 Zed 官方适配器（本机无适配器二进制时经 npx 拉取）"),
    AgentCatalogEntry("codex", "Codex CLI", [
        Candidate(["codex-acp"], ["{exe}"]),
        Candidate(["npx"], ["npx", "-y", "@zed-industries/codex-acp"]),
    ], "经 Zed 官方适配器 codex-acp"),
    AgentCatalogEntry("dsh", "DSH", [
        Candidate(["dsh"], ["{exe}", "acp"]),
    ], "DeepSeek CLI；acp 子命令形态待协议探测裁决"),
    AgentCatalogEntry("stepcode", "StepCode", [
        Candidate([], [sys.executable, str(ROOT_DIR / "server" / "acp_adapters" / "step_adapter.py")]),
        Candidate(["step", "stepcode"], ["{exe}", "acp"]),
    ], "NoN 自研适配层：经 step -p 打流（文本流，工具事件不可见）"),
    AgentCatalogEntry("mcode", "MiniMax Code", [
        Candidate(["mcode", "minimax-code", "minimax"], ["{exe}", "acp"]),
    ], "MiniMax Code 官方 acp 子命令；new_session 要求先 mcode login"),
    AgentCatalogEntry("kimi", "Kimi Code", [
        Candidate(["kimi"], ["{exe}", "acp"]),
    ], "Kimi CLI 的 acp 子命令"),
    AgentCatalogEntry("omp", "OMP", [
        Candidate(["omp"], ["{exe}", "acp"]),
    ], "oh-my-pi（pi 系发行版，实测 native ACP）"),
    AgentCatalogEntry("gemini", "Gemini CLI", [
        Candidate(["gemini"], ["{exe}", "--experimental-acp"]),
    ], "Google 官方 CLI，--experimental-acp 旗标"),
    AgentCatalogEntry("pivot", "Pivot", [
        Candidate(["pivot"], ["{exe}", "acp"]),
    ], "我们自己的智能体 · 即将接入", grayed=True),
    AgentCatalogEntry("solon", "Solon Code", [
        Candidate(["solon", "solon-code", "soloncodecli"], ["{exe}", "acp"]),
    ], "Java 版（opensolon/soloncodecli，需 Java 17+）：ACP 经配置启用"
       "（solon.code.cli: acpEnabled + acpTransport: stdio），无独立子命令"),
]


def _resolve_entry(entry: AgentCatalogEntry) -> dict[str, Any] | None:
    """按序探测候选形态，返回 {command, via} 或 None。

    统一走 _candidate_command（含 npx/静态适配器/本体三形态的解析）——
    此前它与 probe 面分叉：静态适配器（execs 空）在这里被跳过，create
    回落到 step acp 挂起（2026-11-15 实证）。
    """
    for cand in entry.candidates:
        command = _candidate_command(cand)
        if command:
            return {"command": command, "via": _via_of(cand)}
    return None


def detect_agents() -> list[dict[str, Any]]:
    """按目录探测（强化 PATH），返回给前端的清单。

    installed = 存在可启动形态（适配器二进制或 npx 官方包）或检测到 CLI 本体；
    selectable = installed 且有可启动形态且非 grayed。「CLI 在但无适配器」的
    条目（如 StepCode）installed=True 但 command 为空 → 不可选，note 说明。
    """
    out: list[dict[str, Any]] = []
    for entry in AGENT_CATALOG:
        probe = _probe_cache.get(entry.id)
        resolved = _resolve_entry(entry)
        command = resolved["command"] if resolved else []
        via = resolved["via"] if resolved else ""
        cli_path = next((_which(e) for c in entry.candidates for e in c.execs
                         if e != "npx" and _which(e)), None)
        installed = resolved is not None or cli_path is not None
        note = entry.note
        # 协议探测结果优先于静态猜测：verified 用实测命令；failed 诚实标注。
        if probe is not None and probe.state == "verified":
            command = probe.command
            via = probe.via
            note = "%s · %s" % (entry.note, probe.detail)
        elif probe is not None and probe.state == "failed":
            command = []
            via = ""
            note = "协议探测失败（%s）——%s" % (probe.detail, entry.note)
        selectable = bool(command) and not entry.grayed and not (
            probe is not None and probe.state == "failed")
        out.append(
            {
                "id": entry.id,
                "name": entry.name,
                "installed": installed,
                "selectable": selectable,
                "executable": cli_path,
                "command": command,
                "via": via,
                "note": note,
                "grayed": entry.grayed,
                "probeState": probe.state if probe is not None else "unprobed",
            }
        )
    return out


# ---------- 协议级探测（spawn + initialize/new_session 实测） ----------


@dataclass
class ProbeResult:
    state: str  # verified | failed | grayed
    via: str = ""
    command: list[str] = field(default_factory=list)
    detail: str = ""
    probed_at: float = 0.0


_probe_cache: dict[str, ProbeResult] = {}
_probe_lock = asyncio.Lock()


def _candidate_command(cand: Candidate) -> list[str] | None:
    if cand.argv and cand.argv[0] == "npx":
        npx = _which("npx")
        return [npx, *cand.argv[1:]] if npx else None
    if not cand.execs:
        # 静态 argv（自研适配层）：适配器脚本在场即用
        return list(cand.argv) if Path(cand.argv[0]).is_file() else None
    found = next((_which(e) for e in cand.execs if _which(e)), None)
    if not found:
        return None
    return [found if a == "{exe}" else a for a in cand.argv]


def _via_of(cand: Candidate) -> str:
    if cand.argv and cand.argv[0] == "npx":
        return "npx-adapter"
    if cand.argv and cand.argv[0].endswith("python") and "acp_adapters" in " ".join(cand.argv):
        return "builtin-adapter"
    return "native" if len(cand.argv) > 1 else "adapter"


async def _probe_command(command: list[str], timeout_s: int, workspace: str, env: dict[str, str] | None = None) -> tuple[bool, str]:
    """spawn + initialize + new_session 实测。返回 (ok, detail)。"""
    proc = await asyncio.create_subprocess_exec(
        *command,
        cwd=workspace,
        env=env or _child_env(),
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
        limit=4 * 1024 * 1024,
    )
    try:
        client = _NoNDesignAcpClient(workspace)
        conn = ClientSideConnection(client, proc.stdin, proc.stdout)
        init = await asyncio.wait_for(conn.initialize(PROTOCOL_VERSION), timeout=timeout_s)
        name = getattr(getattr(init, "agent_info", None), "name", "") or ""
        try:
            ns = await asyncio.wait_for(conn.new_session(cwd=workspace, mcp_servers=[]), timeout=timeout_s)
            ok = bool(getattr(ns, "session_id", ""))
            detail = "initialize+new_session ok" + (f" ({name})" if name else "")
        except Exception as exc:  # noqa: BLE001
            ok, detail = False, f"new_session failed: {type(exc).__name__}: {exc}"
        return ok, detail
    except asyncio.TimeoutError:
        return False, f"timeout {timeout_s}s（无 ACP 响应）"
    except Exception as exc:  # noqa: BLE001
        return False, f"{type(exc).__name__}: {exc}"
    finally:
        if proc.returncode is None:
            try:
                proc.terminate()
            except ProcessLookupError:
                pass


def _alt_node_envs(limit: int = 3) -> list[dict[str, str]]:
    """多 node 环境切换：按主版本去重（每个 major 取最新），新版优先。

    pi 的 bun shim 只在 node22 下能跑（用户实证）——只重试两个 v24 会
    错过它，必须覆盖到不同主版本。
    """
    home = Path.home()
    nvm_root = home / ".nvm" / "versions" / "node"
    if not nvm_root.is_dir():
        return []
    by_major: dict[str, Path] = {}
    for vdir in sorted(nvm_root.iterdir(), key=lambda p: p.name, reverse=True):
        major = vdir.name.split(".")[0]
        if major not in by_major and (vdir / "bin").is_dir():
            by_major[major] = vdir
    out: list[dict[str, str]] = []
    for vdir in by_major.values():
        env = dict(os.environ)
        env["PATH"] = str(vdir / "bin") + ":" + ":".join(_scan_dirs())
        out.append(env)
        if len(out) >= limit:
            break
    return out


async def probe_entry(entry: AgentCatalogEntry) -> ProbeResult:
    """逐候选形态实测 ACP 握手，首个通过者胜出。

    native 候选在默认环境失败后，用其余 nvm node 版本各重试一次
    （用户定案：多 nodejs 环境尝试切换 node；npx 候选不重试——包自身
    已绑定拉取时的 node）。
    """
    if entry.grayed:
        result = ProbeResult("grayed", detail=entry.note, probed_at=time.time())
        _probe_cache[entry.id] = result
        return result
    last_detail = ""
    alt_envs = _alt_node_envs()
    with tempfile.TemporaryDirectory() as ws:
        for cand in entry.candidates:
            command = _candidate_command(cand)
            if not command:
                continue
            is_npx = command[0].endswith("npx")
            timeout_s = 90 if is_npx else 15
            attempts = [(command, _child_env())]
            if not is_npx:
                attempts.extend((command, env) for env in alt_envs)
            for attempt_i, (cmd, env) in enumerate(attempts):
                suffix = "" if attempt_i == 0 else "（node 切换重试）"
                ok, detail = await _probe_command(cmd, timeout_s, ws, env=env)
                if ok:
                    result = ProbeResult("verified", via=_via_of(cand), command=cmd,
                                         detail=detail + suffix, probed_at=time.time())
                    _probe_cache[entry.id] = result
                    return result
                last_detail = "%s…: %s%s" % (" ".join(cmd[:3]), detail, suffix)
    result = ProbeResult("failed", detail=last_detail or "无可启动形态", probed_at=time.time())
    _probe_cache[entry.id] = result
    return result


async def probe_all() -> None:
    """全目录并行实测（幂等：持锁期间重入直接跳过）。"""
    if _probe_lock.locked():
        return
    async with _probe_lock:
        # 未探测的先标 probing，让前端立即看到状态
        for e in AGENT_CATALOG:
            if e.id not in _probe_cache:
                _probe_cache[e.id] = ProbeResult("probing")
        results = await asyncio.gather(*(probe_entry(e) for e in AGENT_CATALOG), return_exceptions=True)
        for e, r in zip(AGENT_CATALOG, results):
            if isinstance(r, BaseException):
                # 单条探测崩掉不拖垮全目录；标记 failed 并保留原因
                _probe_cache[e.id] = ProbeResult("failed", detail=f"{type(r).__name__}: {r}", probed_at=time.time())


def probe_state_of(agent_id: str) -> str:
    return _probe_cache[agent_id].state if agent_id in _probe_cache else "unprobed"


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
            env=_child_env(),
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            # stderr=DEVNULL：无人消费的 PIPE 在子进程写满时死锁（stepcode
            # 适配层 create 挂起 30s 实证；probe 面因 DEVNULL 从未复现）。
            stderr=asyncio.subprocess.DEVNULL,
            limit=4 * 1024 * 1024,
        )
        assert self.proc.stdin is not None and self.proc.stdout is not None
        self.conn = ClientSideConnection(self.client, self.proc.stdin, self.proc.stdout)
        # 会话建立也实测（probe 已验证过的命令同样可能偶发挂起）——30s 无响应
        # 视为启动失败，交由上层报错而非永久悬挂。
        await asyncio.wait_for(self.conn.initialize(PROTOCOL_VERSION), timeout=30)
        resp = await asyncio.wait_for(self.conn.new_session(cwd=self.workspace, mcp_servers=[]), timeout=30)
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
        # 协议探测 verified 的命令最可信；否则回退静态解析。
        probe = _probe_cache.get(entry.id)
        if probe is not None and probe.state == "verified":
            argv = probe.command
        else:
            resolved = _resolve_entry(entry)
            if resolved is None or entry.grayed:
                return {"ok": False, "error": "agent_not_startable", "note": entry.note}
            argv = resolved["command"]
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
