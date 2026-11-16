"""OpenAI Agents SDK loop for NoNDesign.

Python owns the agent, the engine, and the stream. Flutter only renders events —
there is no JS runtime, no Bun, no Tauri.
"""

from __future__ import annotations

import asyncio
import base64
import json
import os
import time
from dataclasses import dataclass, field
from typing import Any, AsyncIterator

from agents import Agent, ModelSettings, RunConfig, Runner, function_tool
from agents.models.openai_chatcompletions import OpenAIChatCompletionsModel
from openai import AsyncOpenAI
from openai.types.shared import Reasoning
from pydantic import BaseModel, Field

from context import (
    CompactingSession,
    artboard_section,
    compose_project_map,
    design_for_agent,
    normalize_design,
    parse_revision,
    state_summary,
)
from engine import EngineHost, compact_envelope
from prompts import compose_instructions, user_message

SEED_BOARD = "__seed"
EMPTY_MBT = ""


class AgentRunRequest(BaseModel):
    run_id: int = 0
    mode: str = "build"
    instruction: str = ""
    mbt: str = ""
    docs: dict[str, Any] = Field(default_factory=dict)
    design_spec: dict[str, Any] = Field(default_factory=dict)
    model: str = ""
    base_url: str = ""
    api_key: str = ""
    protocol: str = "openai"
    thinking_level: str = "auto"
    max_steps: int = 300
    session_key: str = "unsaved"
    context_window: int = 128000


def build_model(req: AgentRunRequest) -> Any:
    """Construct the model backend for this run.

    Single path, by design (用户决策 2026-11-13): every provider — MiniMax
    included — is accessed through its OpenAI-compatible chat-completions
    endpoint. No LiteLLM, no Anthropic Messages wire format.
    """
    if (req.protocol or "").strip().lower() not in ("openai", ""):
        raise ValueError(f"unsupported_protocol:{req.protocol} — use an OpenAI-compatible endpoint")
    client = AsyncOpenAI(api_key=req.api_key or "missing", base_url=req.base_url or None)
    return OpenAIChatCompletionsModel(model=req.model or "gpt-5.1", openai_client=client)


def seed_doc(board: str, width: int = 390, height: int = 844) -> str:
    return (
        "---\nmoonviz:\n  format: visual-document\n  revision: 1\n"
        f"  entry: {board}\n---\n\n# {board}\n\n"
        f"<!-- moonviz:artboard {board} -->\n```mbt\n"
        f"fn visual_{board}() -> @decl.Prototype {{\n"
        f'  let page = @decl.prototype(name="{board}", width={width}.0, height={height}.0)\n'
        "  page\n}\n```\n"
    )


def _tool_events(ctx: "AgentContext", name: str, args: dict[str, Any]) -> dict[str, Any]:
    if name == "design_op":
        return {"op": args.get("op")}
    if name == "generate_page":
        return {"intent": args.get("intent"), "name": args.get("name")}
    if name == "inspect":
        return {"kind": args.get("kind"), "artboard": args.get("artboard")}
    if name == "read_mbt":
        return {"artboard": args.get("artboard")}
    if name == "write_doc":
        return {"kind": args.get("kind"), "chars": len(args.get("content") or "")}
    return {}


def _preview(value: Any, limit: int = 360) -> str:
    raw = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
    return raw if len(raw) <= limit else raw[:limit] + "…"


@dataclass
class AgentContext:
    engine: EngineHost
    mode: str
    mbt: str
    docs: dict[str, Any]
    design_spec: dict[str, Any]
    queue: asyncio.Queue
    finished: dict[str, Any] = field(default_factory=lambda: {"value": False, "summary": "", "stop_reason": "done"})
    ops: list[str] = field(default_factory=list)
    cleanup: list[str] = field(default_factory=list)
    remote_calls: int = 0
    preview_seq: int = 0
    cancelled: bool = False

    def emit(self, event: dict[str, Any]) -> None:
        self.queue.put_nowait(event)

    def revision(self) -> int:
        return parse_revision(self.mbt)

    def state(self) -> str:
        return state_summary(self.engine, self.mbt, self.revision())

    def preview(self) -> None:
        self.preview_seq += 1
        self.emit(
            {
                "type": "preview",
                "mbt_b64": base64.b64encode(self.mbt.encode("utf-8")).decode("ascii"),
                "seq": self.preview_seq,
            }
        )


def _commit(ctx: AgentContext, op_label: str, envelope: dict[str, Any]) -> dict[str, Any]:
    ok = envelope.get("ok") is True
    if ok and isinstance(envelope.get("mbt"), str):
        ctx.mbt = envelope["mbt"]
        ctx.ops.append(op_label)
        ctx.preview()
    out = compact_envelope(envelope)
    if ok:
        out["state"] = ctx.state()
    return out


def _make_tools(ctx: AgentContext) -> list[Any]:
    tools: list[Any] = []

    if ctx.mode != "plan":

        async def _generate_page(intent: str, name: str | None = None, spec: dict[str, Any] | None = None) -> dict[str, Any]:
            """Generate a whole screen from an intent. This is the default build path:
            the engine picks a template, applies the design spec, self-repairs and scores.
            Pass the project design spec on every call."""
            started = time.time()
            ctx.emit({"type": "tool_start", "tool": "generate_page", "args": {"intent": intent, "name": name}})
            ctx.remote_calls += 1
            effective = spec or ctx.design_spec or {}
            # 同步 wasm 调用不进事件循环：generate 可达秒级，直调会冻结
            # /agent/cancel 与 SSE 推送。RLock 保证与 REST 路由线程互斥。
            env = await asyncio.to_thread(ctx.engine.generate, ctx.mbt, intent, name or "", effective)
            out = _commit(ctx, f"generate {intent}", env)
            ctx.emit(
                {
                    "type": "tool_end",
                    "tool": "generate_page",
                    "ok": out.get("ok") is not False,
                    "ms": int((time.time() - started) * 1000),
                    "preview": _preview(out),
                    "error": out.get("error"),
                }
            )
            if out.get("ok") is not False:
                ctx.emit(
                    {
                        "type": "page_generated",
                        "artboard": out.get("artboard"),
                        "template": out.get("template"),
                        "score": out.get("score"),
                        "summary": out.get("summary"),
                    }
                )
            return out

        tools.append(
            function_tool(
                _generate_page,
                name_override="generate_page",
                strict_mode=False,
            )
        )

        async def _design_op(op: str) -> dict[str, Any]:
            """Run ONE mutating MoonViz op (place/update/move/flow/delete/reorder/
            interact/theme/token/fix…). The engine AgentGate validates it. Use this
            for refinements and flow wiring; do not hand-place whole screens."""
            started = time.time()
            ctx.emit({"type": "tool_start", "tool": "design_op", "args": {"op": op}})
            ctx.remote_calls += 1
            # session_apply_agent 快路径（session API，SESSION_MUTATING 在册）：
            # 无状态 apply 每次把整篇 canonical 按 4 字节分块重压 in 槽，成本随
            # 文档字节线性放大；会话路径按 canonical 键控缓存、成功信封的 mbt
            # 回写缓存。信封只带 {ok, mbt}（无 artboards 面）——compact_envelope
            # 与 state 卡均可承接。同时丢线程池，不阻塞事件循环。
            env = await asyncio.to_thread(ctx.engine.session, "session_apply_agent", ctx.mbt, op)
            out = _commit(ctx, op, env)
            ctx.emit(
                {
                    "type": "tool_end",
                    "tool": "design_op",
                    "ok": out.get("ok") is not False,
                    "ms": int((time.time() - started) * 1000),
                    "preview": _preview(out),
                    "error": out.get("error"),
                }
            )
            return out

        tools.append(function_tool(_design_op, name_override="design_op", strict_mode=False))

        async def _read_mbt(artboard: str | None = None) -> dict[str, Any]:
            """Read the document. No args returns a compact outline (boards, node ids,
            flows). With artboard, returns that board's source block for exact values."""
            if not artboard:
                return {"ok": True, "outline": compose_project_map(ctx.engine, ctx.mbt)}
            section = artboard_section(ctx.mbt, artboard)
            if section is None:
                return {"ok": False, "error": f"unknown_artboard:{artboard}"}
            return {"ok": True, "artboard": artboard, "source": section}

        tools.append(function_tool(_read_mbt, name_override="read_mbt", strict_mode=False))

        async def _inspect(kind: str, artboard: str | None = None) -> dict[str, Any]:
            """Read-only engine inspection: query_nodes, interactions, states, lint,
            critique, spec, export_svg, flows, artboards. Use critique/lint to verify."""
            mapping = {
                "query_nodes": "session_query_nodes",
                "interactions": "session_interactions",
                "states": "session_states",
                "lint": "session_lint",
                "critique": "session_critique",
                "spec": "session_spec",
                "export_svg": "session_export_svg",
                "flows": "session_flows",
                "artboards": "session_list_artboards",
            }
            fn = mapping.get(kind)
            if not fn:
                return {"ok": False, "error": f"unknown_inspect_kind:{kind}"}
            needs_board = kind in {"query_nodes", "interactions", "states", "lint", "critique", "spec", "export_svg"}
            if needs_board and not artboard:
                return {"ok": False, "error": "artboard_required"}
            # 会话读面同样可能压整篇 canonical（首次 open），丢线程池执行。
            env = await asyncio.to_thread(ctx.engine.session, fn, ctx.mbt, artboard or "")
            if kind == "export_svg" and isinstance(env.get("data"), dict) and isinstance(env["data"].get("svg"), str):
                svg = env["data"]["svg"]
                env["data"] = {"ok": True, "chars": len(svg), "preview": svg[:1200]}
            env["state"] = ctx.state()
            return env

        tools.append(function_tool(_inspect, name_override="inspect", strict_mode=False))

        async def _list_templates() -> dict[str, Any]:
            """List engine page templates (id, name, description, device)."""
            return {"ok": True, "templates": await asyncio.to_thread(ctx.engine.list_templates)}

        async def _list_components() -> dict[str, Any]:
            """List engine components with categories and descriptions."""
            return {"ok": True, "components": ctx.engine.list_components()}

        tools.append(function_tool(_list_templates, name_override="list_templates", strict_mode=False))
        tools.append(function_tool(_list_components, name_override="list_components", strict_mode=False))

    async def _read_docs(kind: str) -> dict[str, Any]:
        """Read the full PRD or UI spec stored with this project."""
        text = ctx.docs.get(kind, "")
        if not text:
            return {"ok": False, "error": f"no_{kind}_doc"}
        return {"ok": True, "kind": kind, "content": text[:12000] + ("\n…[truncated]" if len(text) > 12000 else "")}

    tools.append(function_tool(_read_docs, name_override="read_docs", strict_mode=False))

    async def _write_doc(kind: str, content: str) -> dict[str, Any]:
        """Write or replace the product PRD (kind='prd') or per-screen UI spec
        (kind='ui'). Full markdown, real copy. In PLAN mode write both."""
        started = time.time()
        ctx.emit({"type": "tool_start", "tool": "write_doc", "args": {"kind": kind, "chars": len(content)}})
        if kind not in {"prd", "ui"} or not content.strip():
            out = {"ok": False, "error": "doc_kind_must_be_prd_or_ui"}
        else:
            ctx.docs[kind] = content
            ctx.emit({"type": "doc_written", "kind": kind, "chars": len(content), "content": content})
            out = {"ok": True, "kind": kind, "chars": len(content)}
        ctx.emit(
            {
                "type": "tool_end",
                "tool": "write_doc",
                "ok": out.get("ok") is not False,
                "ms": int((time.time() - started) * 1000),
                "preview": _preview(out),
                "error": out.get("error"),
            }
        )
        return out

    tools.append(function_tool(_write_doc, name_override="write_doc", strict_mode=False))

    async def _write_design_spec(
        palette: dict[str, str],
        typography: dict[str, float],
        spacing: list[float],
        radius: dict[str, float],
        rules: list[str] | None = None,
        notes: str | None = None,
    ) -> dict[str, Any]:
        """Write the project design system (palette, typography, spacing, radius,
        rules). Coherent, accessible colors; no pure black backgrounds."""
        spec = normalize_design(
            {
                "palette": palette,
                "typography": typography,
                "spacing": spacing,
                "radius": radius,
                "rules": rules or [],
                "notes": notes or "",
            }
        )
        ctx.design_spec = design_for_agent({"design": spec})
        ctx.docs["design"] = spec
        ctx.emit({"type": "design_spec_written", "spec": spec})
        return {"ok": True, "palette": len(spec["palette"]), "rules": len(spec["rules"])}

    tools.append(function_tool(_write_design_spec, name_override="write_design_spec", strict_mode=False))

    async def _finish(summary: str, stop_reason: str | None = None) -> dict[str, Any]:
        """End the task. The summary is shown to the user; include what was built
        and what to click first."""
        ctx.finished["value"] = True
        ctx.finished["summary"] = summary
        ctx.finished["stop_reason"] = stop_reason or "done"
        ctx.emit({"type": "assistant_text", "text": summary, "final": True})
        return {"ok": True}

    tools.append(function_tool(_finish, name_override="finish", strict_mode=False))
    return tools


def _aggregate_usage(raw_responses: list[Any]) -> dict[str, int]:
    total = {"requests": 0, "inputTokens": 0, "outputTokens": 0, "totalTokens": 0, "cachedTokens": 0}
    for response in raw_responses or []:
        usage = getattr(response, "usage", None)
        if usage is None:
            continue
        total["requests"] += 1
        total["inputTokens"] += int(getattr(usage, "input_tokens", 0) or 0)
        total["outputTokens"] += int(getattr(usage, "output_tokens", 0) or 0)
        total["totalTokens"] += int(getattr(usage, "total_tokens", 0) or 0)
        details = getattr(usage, "input_tokens_details", None)
        total["cachedTokens"] += int(getattr(details, "cached_tokens", 0) or 0) if details else 0
    return total


class AgentRun:
    def __init__(self, request: AgentRunRequest, session_dir: str) -> None:
        self.request = request
        self.session_dir = session_dir
        self.queue: asyncio.Queue = asyncio.Queue()
        self.cancelled = False
        self.result = None
        self.ctx: AgentContext | None = None

    def cancel(self) -> None:
        self.cancelled = True
        if self.result is not None:
            try:
                self.result.cancel("immediate")
            except Exception:
                pass

    def _drain(self) -> list[dict[str, Any]]:
        out = []
        while not self.queue.empty():
            out.append(self.queue.get_nowait())
        return out

    async def stream(self) -> AsyncIterator[dict[str, Any]]:
        req = self.request
        engine = EngineHost.shared()
        mbt = req.mbt or seed_doc(SEED_BOARD)
        docs = dict(req.docs or {})
        design_spec = req.design_spec or design_for_agent(docs)
        ctx = AgentContext(
            engine=engine,
            mode=req.mode,
            mbt=mbt,
            docs=docs,
            design_spec=design_spec,
            queue=self.queue,
        )
        self.ctx = ctx

        project_map = compose_project_map(engine, mbt)
        templates = await asyncio.to_thread(engine.list_templates)
        cfg = {
            "mode": req.mode,
            "instruction": req.instruction,
            "docs": docs,
            "design_spec": design_spec,
            "templates": templates,
            "components": [c.get("id") for c in engine.list_components() if isinstance(c, dict)],
        }
        instructions = compose_instructions(cfg, project_map)
        tools = _make_tools(ctx)

        model = build_model(req)
        settings = ModelSettings()
        if req.thinking_level not in {"", "auto"}:
            effort = req.thinking_level
            if effort in {"none", "minimal", "low", "medium", "high", "xhigh", "max"}:
                settings = ModelSettings(reasoning=Reasoning(effort=effort))
        agent = Agent(
            name="NoN",
            instructions=instructions,
            tools=tools,
            model=model,
            model_settings=settings,
        )
        session = CompactingSession(self.session_dir, req.session_key, req.context_window)
        text_parts: list[str] = []
        text_sent = False
        usage = {"requests": 0, "inputTokens": 0, "outputTokens": 0, "totalTokens": 0, "cachedTokens": 0}

        async def consume(prompt: str) -> None:
            nonlocal text_sent, usage
            result = Runner.run_streamed(
                agent,
                input=prompt,
                max_turns=max(4, min(600, req.max_steps or 300)),
                session=session,
                run_config=RunConfig(tracing_disabled=True),
            )
            self.result = result
            async for event in result.stream_events():
                for queued in self._drain():
                    yield queued  # type: ignore[misc]
                etype = getattr(event, "type", "")
                if etype == "raw_response_event":
                    data = getattr(event, "data", None)
                    dtype = getattr(data, "type", "")
                    if dtype == "response.output_text.delta":
                        delta = getattr(data, "delta", "") or ""
                        if delta:
                            text_parts.append(delta)
                            text_sent = True
                            yield {"type": "assistant_delta", "text": delta}
                    elif dtype in {"response.reasoning_text.delta", "response.reasoning_summary_text.delta"}:
                        delta = getattr(data, "delta", "") or ""
                        if delta:
                            yield {"type": "thinking_delta", "text": delta}
                elif etype == "run_item_stream_event":
                    name = getattr(event, "name", "")
                    if name == "message_output_created" and not text_sent:
                        item = getattr(event, "item", None)
                        content = getattr(item, "content", None) or []
                        text = "".join(
                            c.get("text", "") for c in content if isinstance(c, dict) and isinstance(c.get("text"), str)
                        )
                        if text:
                            text_parts.append(text)
                            yield {"type": "assistant_text", "text": text}
            for queued in self._drain():
                yield queued
            usage = _aggregate_usage(getattr(result, "raw_responses", []))
            final = getattr(result, "final_output", None)
            if isinstance(final, str) and final and not text_sent and not ctx.finished["value"]:
                text_parts.append(final)

        try:
            yield {"type": "note", "label": "NoN 开始", "detail": f"{req.mode} · {req.model}"}
            async for item in consume(user_message(cfg)):
                yield item
            missing_docs = req.mode == "plan" and not (docs.get("prd") and docs.get("ui") and docs.get("design"))
            no_work = req.mode != "plan" and ctx.remote_calls == 0
            if not ctx.finished["value"] and (missing_docs or no_work):
                yield {
                    "type": "note",
                    "label": "NoN 继续执行",
                    "detail": "上一次回复没有交付文档 / 画布操作，继续调用工具。",
                }
                nudge = (
                    "You replied without calling tools. Deliver now: call write_doc(kind='prd'), "
                    "write_doc(kind='ui'), write_design_spec, then finish. Do not reply with prose only."
                    if req.mode == "plan"
                    else "You replied without changing the canvas. Proceed now with the actual tool calls "
                    "(generate_page / design_op / inspect), then finish. Do not reply with prose only."
                )
                async for item in consume(nudge):
                    yield item
            if req.mode == "plan" and not (docs.get("prd") and docs.get("ui")):
                yield {
                    "type": "failed",
                    "error": "doc_not_written",
                    "text": "".join(text_parts),
                    "docs": docs,
                    "designSpec": design_spec,
                    "stopReason": "failed",
                }
                return
            await _cleanup_document(ctx)

            # ---- RSI 视觉修复循环（3DCodeVerse harness 三反馈的 2D 映射：
            # engine critique = 测量+视觉评审，auto_fix = 定向修复）----
            # 逐屏 critique，评分<95 或违例>0 的屏先 auto_fix 再复评，
            # 至多 2 轮；全程时间线可见。
            if req.mode != "plan":
                for rnd in range(1, 3):
                    # to_thread：engine.session 是同步 wasm 直调（engine.py:321
                    # 普通 def + RLock）——在 async 流里直调会阻塞事件循环，
                    # 冻结 /agent/cancel、/health 与 SSE 推送；同函数 critique/
                    # auto_fix 均已走 to_thread，此漏网点补齐（2026-11-16）。
                    arts = await asyncio.to_thread(ctx.engine.session, "session_list_artboards", ctx.mbt)
                    boards = (arts.get("data") or []) if isinstance(arts, dict) else []
                    targets = []
                    for b in boards:
                        if not isinstance(b, dict) or not b.get("id"):
                            continue
                        bid = b["id"]
                        if bid == SEED_BOARD or (b.get("nodes") or 0) in (0, None):
                            continue
                        try:
                            c = await asyncio.to_thread(
                                ctx.engine.session, "session_critique", ctx.mbt, bid)
                            data = c.get("data") if isinstance(c, dict) else None
                            # 信封实形（真机探针）：data.results = [{principle,
                            # score(1-5), verdict(poor/good), observation, advice}]。
                            # 触发条件：任一原则 verdict=poor。
                            results = (data or {}).get("results", []) if isinstance(data, dict) else []
                            poor = [r for r in results
                                    if isinstance(r, dict) and r.get("verdict") == "poor"]
                            if poor:
                                targets.append((bid, len(results), len(poor)))
                        except Exception:
                            continue
                    if not targets:
                        if rnd == 1:
                            ctx.emit({"type": "note", "label": "质量审查", "detail": "全部屏幕通过原则评审（无 poor 项）"})
                        break
                    ctx.emit({"type": "review_round", "round": rnd,
                              "detail": "、".join(f"{b}:{p}项poor" for b, _s, p in targets)})
                    for bid, _n, poor_n in targets:
                        ctx.emit({"type": "note", "label": "修复轮", "detail": f"{bid} · {poor_n} 项 poor → auto_fix"})
                        fixed = await asyncio.to_thread(
                            ctx.engine.session, "session_auto_fix", ctx.mbt, bid)
                        # canonical 必须回灌：信封顶层带 mbt（SESSION_MUTATING 面，
                        # engine.session:335）。此前返回值被丢弃——复评永远看
                        # 修复前的文档，且最终交付的 mbt 缺 auto_fix 成果。
                        if isinstance(fixed, dict) and fixed.get("ok") and isinstance(fixed.get("mbt"), str):
                            ctx.mbt = fixed["mbt"]
                    await asyncio.sleep(0)

            final_text = ctx.finished["summary"] or "".join(text_parts)
            stop_reason = ctx.finished["stop_reason"] if ctx.finished["value"] else ("text_only" if req.mode != "plan" and ctx.remote_calls == 0 else "done")
            yield {"type": "usage", **usage, "contextWindow": req.context_window}
            if ctx.cleanup:
                yield {"type": "cleanup", "removed": ctx.cleanup}
            final_design = design_for_agent({"design": docs.get("design")}) if docs.get("design") else design_spec
            yield {
                "type": "done",
                "text": final_text,
                "mbt_b64": base64.b64encode(ctx.mbt.encode("utf-8")).decode("ascii"),
                "ops": ctx.ops,
                "docs": docs,
                "designSpec": final_design,
                "usage": usage,
                "stopReason": stop_reason,
                "cleanup": ctx.cleanup,
            }
        except asyncio.CancelledError:
            yield {"type": "failed", "error": "cancelled", "stopReason": "cancelled", "mbt_b64": base64.b64encode(ctx.mbt.encode("utf-8")).decode("ascii"), "docs": docs}
        except Exception as exc:  # noqa: BLE001 - the run must always produce a terminal event
            yield {
                "type": "failed",
                "error": f"{type(exc).__name__}: {exc}",
                "stopReason": "cancelled" if self.cancelled else "failed",
                "mbt_b64": base64.b64encode(ctx.mbt.encode("utf-8")).decode("ascii"),
                "docs": docs,
                "text": "".join(text_parts),
            }


async def _cleanup_document(ctx: AgentContext) -> None:
    boards = await asyncio.to_thread(ctx.engine.session, "session_list_artboards", ctx.mbt)
    data = boards.get("data") or [] if isinstance(boards, dict) else []
    if len(data) <= 1:
        return
    entry = ""
    for line in ctx.mbt.splitlines()[:60]:
        if line.strip().startswith("entry:"):
            entry = line.split(":", 1)[1].strip()
            break
    targets = []
    for board in data:
        if not isinstance(board, dict):
            continue
        bid = board.get("id", "")
        nodes = int(board.get("nodes", 0) or 0)
        if not bid:
            continue
        if bid == entry and bid != SEED_BOARD:
            continue
        if bid == SEED_BOARD or nodes <= 1:
            targets.append(bid)
    for bid in targets:
        current = await asyncio.to_thread(ctx.engine.session, "session_list_artboards", ctx.mbt)
        if len((current.get("data") or [])) <= 1:
            break
        # 与 design_op 同走 session_apply_agent 快路径（AgentGate 同门分发）。
        env = await asyncio.to_thread(ctx.engine.session, "session_apply_agent", ctx.mbt, f"delete-artboard {bid}")
        if env.get("ok") and isinstance(env.get("mbt"), str):
            ctx.mbt = env["mbt"]
            ctx.cleanup.append(bid)


class AgentRunManager:
    def __init__(self, session_dir: str) -> None:
        self.session_dir = session_dir
        self.runs: dict[int, AgentRun] = {}

    def start(self, request: AgentRunRequest) -> AgentRun:
        run = AgentRun(request, self.session_dir)
        self.runs[request.run_id] = run
        return run

    def cancel(self, run_id: int) -> bool:
        run = self.runs.get(run_id)
        if run is None:
            return False
        run.cancel()
        return True

    def finish(self, run_id: int) -> None:
        self.runs.pop(run_id, None)
