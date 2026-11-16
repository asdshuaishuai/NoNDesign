#!/usr/bin/env python3
"""agent run 基本可用性单测（@dataclass 回归 + 事件循环不阻塞契约）。

用法：.venv/bin/python scripts/wf/test_agent_run.py （退出码 0 = 全绿）

覆盖：
  1) AgentContext 必须是 @dataclass：装饰器曾随 _DocDeltaExtractor 的插入
     被顶掉（31f6eac），此后每个 /agent/run 在构造 ctx 时即 TypeError、
     零事件失败——四个 Python 测试无一引用 AgentRun，回归静默穿越多提交。
  2) AgentRun.stream 端到端冒烟（真引擎 + 死端点 LLM）：流必须产出
     首个 note 事件并以 failed 终态收尾（异常转事件，不是逃出生成器）。
  3) run 起点的 compose_project_map 是同步 wasm 直调（会话缓存 miss 时压
     整篇 canonical 分块入槽，100KB≈324ms 实测）——必须走 to_thread；
     用慢速假引擎 + 心跳时间戳度量事件循环停顿（直调 ≥ 单次调用时长，
     to_thread 应保持 < 200ms）。
  4) 源码契约：agent.py 四处同步 wasm 调用点（project map ×2 / state 卡 ×2）
     均以 to_thread 包裹，_commit 为 async 且两处调用点均 await。
"""

from __future__ import annotations

import asyncio
import sys
import tempfile
import time
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "server"))

import agent as agent_mod  # noqa: E402
from agent import AgentContext, AgentRun, AgentRunRequest  # noqa: E402

AGENT_SOURCE = (ROOT / "server" / "agent.py").read_text("utf-8")
DEAD_ENDPOINT = "http://127.0.0.1:1"  # 连接即拒：LLM 调用快速失败，无网络依赖


def _req(**overrides) -> AgentRunRequest:
    base = dict(
        run_id=1,
        mode="plan",
        instruction="测试",
        api_key="k",
        base_url=DEAD_ENDPOINT,
        model="test-model",
        max_steps=4,
    )
    base.update(overrides)
    return AgentRunRequest(**base)


class _SlowFakeEngine:
    """慢速假引擎：session() 每次阻塞 BLOCK 秒，模拟缓存 miss 压槽。"""

    BLOCK = 0.3

    def __init__(self) -> None:
        self.session_calls = 0

    def session(self, name: str, mbt: str, arg: str | None = None) -> dict:
        time.sleep(self.BLOCK)
        self.session_calls += 1
        return {"ok": True, "data": []}

    def list_templates(self) -> list:
        return []

    def list_components(self) -> list:
        return []


class _FakeEngineHost:
    _fake: _SlowFakeEngine | None = None

    @classmethod
    def shared(cls) -> _SlowFakeEngine:
        if cls._fake is None:
            cls._fake = _SlowFakeEngine()
        return cls._fake


async def _collect(run: AgentRun) -> list[dict]:
    events: list[dict] = []
    async for event in run.stream():
        events.append(event)
    return events


async def test_stream_smoke() -> list[str]:
    """真引擎 + 死端点：流有首事件、有终态，异常不逃出生成器。"""
    failures: list[str] = []
    with tempfile.TemporaryDirectory() as td:
        run = AgentRun(_req(), td)
        try:
            events = await _collect(run)
        except Exception as exc:  # noqa: BLE001
            return [f"stream raised out of generator: {type(exc).__name__}: {exc}"]
        kinds = [e.get("type") for e in events]
        if not events:
            failures.append("stream produced zero events")
        if kinds and kinds[0] != "note":
            failures.append(f"first event is {kinds[0]!r}, expected 'note'")
        if not kinds or kinds[-1] not in ("failed", "done"):
            failures.append(f"stream has no terminal event, tail={kinds[-3:]}")
        if any("AgentContext" in str(e.get("error", "")) for e in events):
            failures.append("AgentContext TypeError leaked into events")
    return failures


async def test_project_map_off_loop() -> list[str]:
    """慢引擎心跳度量：run 起点的 project map 必须不阻塞事件循环。"""
    failures: list[str] = []
    stamps: list[float] = []
    stop = asyncio.Event()

    async def ticker() -> None:
        while not stop.is_set():
            await asyncio.sleep(0.02)
            stamps.append(time.monotonic())

    fake = _FakeEngineHost
    fake._fake = None
    with tempfile.TemporaryDirectory() as td, \
            mock.patch.object(agent_mod, "EngineHost", _FakeEngineHost):
        beat = asyncio.create_task(ticker())
        # 先落几个心跳基线：project map 阻塞发生在流的首次 __anext__ 里，
        # 没有前置基线就量不到横跨阻塞段的 gap（首轮变异验证踩过）。
        await asyncio.sleep(0.1)
        try:
            run = AgentRun(_req(), td)
            events = await _collect(run)
        except Exception as exc:  # noqa: BLE001
            failures.append(f"stream raised: {type(exc).__name__}: {exc}")
            events = []
        finally:
            stop.set()
            await beat
    gaps = [b - a for a, b in zip(stamps, stamps[1:])]
    max_gap = max(gaps) if gaps else 0.0
    engine = fake._fake
    if engine is None or engine.session_calls < 2:
        failures.append(f"slow engine barely used (calls={engine and engine.session_calls})")
    if max_gap >= 0.2:
        failures.append(
            f"event loop stalled {max_gap:.3f}s during run start "
            f"(project map must go through to_thread; block={_SlowFakeEngine.BLOCK}s)"
        )
    if not any(e.get("type") in ("failed", "done") for e in events):
        failures.append("no terminal event in slow-engine run")
    return failures


def test_source_contract() -> list[str]:
    """源码契约：四处同步 wasm 调用点 + dataclass 装饰器。"""
    failures: list[str] = []
    if "@dataclass\nclass AgentContext:" not in AGENT_SOURCE:
        failures.append("AgentContext lost its @dataclass decorator")
    if AGENT_SOURCE.count("await asyncio.to_thread(compose_project_map") != 2:
        failures.append(
            "compose_project_map must run via to_thread at both call sites "
            "(run-start project map + read_mbt outline)"
        )
    if AGENT_SOURCE.count("await asyncio.to_thread(ctx.state)") != 2:
        failures.append("ctx.state() must run via to_thread in _commit and _inspect")
    if "async def _commit(" not in AGENT_SOURCE:
        failures.append("_commit must be async (it awaits to_thread for the state card)")
    if AGENT_SOURCE.count("await _commit(") != 2:
        failures.append("both _commit call sites (generate/design_op) must await")
    return failures


def test_context_is_dataclass() -> list[str]:
    failures: list[str] = []
    import dataclasses

    if not dataclasses.is_dataclass(AgentContext):
        return ["AgentContext is not a dataclass — AgentRun cannot construct it"]
    try:
        AgentContext(
            engine=SimpleNamespace(),
            mode="plan",
            mbt="",
            docs={},
            design_spec={},
            queue=asyncio.Queue(),
        )
    except TypeError as exc:
        failures.append(f"AgentContext() rejected kwargs: {exc}")
    return failures


async def run_all() -> int:
    failures: list[str] = []
    for name, result in (
        ("context is dataclass", test_context_is_dataclass()),
        ("source contract", test_source_contract()),
        ("stream smoke (real engine, dead endpoint)", await test_stream_smoke()),
        ("project map off event loop", await test_project_map_off_loop()),
    ):
        if result:
            print(f" - {name}:")
            for line in result:
                print(f"   {line}")
            failures.extend(result)
    if failures:
        print("FAIL")
        return 1
    print("agent run: all cases green")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(run_all()))
