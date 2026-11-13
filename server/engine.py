"""MoonViz classic wasm host for NoNDesign (Python).

The engine is a pure WASM MVP module with zero imports. Writes go through the
`_in` byte-slot contract (UTF-8 chunks: LE u32 + length), reads come back as
engine-allocated UTF-16 strings ([len@ptr-4][utf16@ptr]). One instance is shared
by REST handlers and the agent thread; every call is serialized by a lock.

Session handles are keyed by canonical MBT text, mirroring the Rust host:
a miss closes the old handle and opens a fresh session. Any trap/timeout evicts
the cache so a retry can never land on a ghost commit.
"""

from __future__ import annotations

import json
import os
import threading
import time
from pathlib import Path
from typing import Any

from wasmtime import Config, Engine, Instance, Memory, Module, Store

ROOT = Path(__file__).resolve().parent.parent
ENGINE_DIR = ROOT / "engine"
WASM_PATH = Path(os.environ.get("NONDESIGN_WASM", ENGINE_DIR / "moonviz.wasm"))
COMPONENTS_PATH = ENGINE_DIR / "components.json"

LEN_MASK = 0x0FFF_FFFF
SLOT_CHUNK = 4
MEMORY_RECYCLE_BYTES = 176 * 1024 * 1024
CALL_TIMEOUT_SECONDS = 30
EPOCH_TICK_MS = 100

SESSION_MUTATING = {
    "session_apply_agent",
    "session_apply_human",
    "session_auto_fix",
    "session_constrain",
    "session_tap",
    "session_generate_responsive",
    "session_component_compile_b64",
    "session_generate",
    "session_event",
    # undo/redo return the jumped-to canonical mbt; init/commit/log return no
    # mbt so the guard below simply never fires for them.
    "session_history",
}

NO_ARG_SESSION = {
    "session_flows",
    "session_benchmark",
    "session_list_artboards",
    "session_save",
    "session_library_snapshot",
    "session_snapshot",
    "session_generate_spec",
}


class EngineError(RuntimeError):
    pass


class EngineHost:
    _instance: "EngineHost | None" = None
    _instance_lock = threading.Lock()

    @classmethod
    def shared(cls) -> "EngineHost":
        with cls._instance_lock:
            if cls._instance is None:
                cls._instance = cls()
            return cls._instance

    def __init__(self) -> None:
        if not WASM_PATH.exists():
            raise EngineError(f"engine artifact missing: {WASM_PATH} (run scripts/sync_engine.py)")
        self.lock = threading.RLock()
        cfg = Config()
        cfg.epoch_interruption = True
        self.engine = Engine(cfg)
        self.module = Module.from_file(self.engine, str(WASM_PATH))
        self._ticker = threading.Thread(target=self._tick, name="moonviz-epoch", daemon=True)
        self._ticker.start()
        self.components: list[Any] = []
        try:
            self.components = json.loads(COMPONENTS_PATH.read_text("utf-8"))
        except Exception:
            self.components = []
        self.store: Store | None = None
        self.instance: Instance | None = None
        self.memory: Memory | None = None
        self.exports: dict[str, Any] = {}
        self.sess_mbt: str | None = None
        self.sess_handle: int | None = None
        self.hits = 0
        self.misses = 0
        self._build()

    # ---------- lifecycle ----------

    def _tick(self) -> None:
        while True:
            time.sleep(EPOCH_TICK_MS / 1000)
            try:
                self.engine.increment_epoch()
            except Exception:
                return

    def _build(self) -> None:
        self.store = Store(self.engine)
        # default deadline is 0; set one before instantiation so start code can run
        self.store.set_epoch_deadline(CALL_TIMEOUT_SECONDS * 1000 // EPOCH_TICK_MS + 1)
        self.instance = Instance(self.store, self.module, [])
        self.memory = self.instance.exports(self.store)["memory"]
        self.exports = self.instance.exports(self.store)
        self.sess_mbt = None
        self.sess_handle = None

    def _ensure(self) -> None:
        with self.lock:
            if self.store is None or self.instance is None:
                self._build()
                return
            if self.memory is not None and self.memory.data_len(self.store) > MEMORY_RECYCLE_BYTES:
                self.close_session()
                self._build()

    def _reset_instance(self) -> None:
        try:
            self.close_session()
        finally:
            try:
                self._build()
            except Exception:
                self.store = None
                self.instance = None
                self.memory = None
                self.exports = {}

    def _set_deadline(self) -> None:
        assert self.store is not None
        self.store.set_epoch_deadline(CALL_TIMEOUT_SECONDS * 1000 // EPOCH_TICK_MS + 1)

    # ---------- ABI helpers ----------

    def _call_raw(self, name: str, *args: Any) -> int:
        assert self.store is not None
        func = self.exports.get(name)
        if func is None:
            raise EngineError(f"unknown_fn:{name}")
        # The epoch ticker runs continuously; every call (including a cheap
        # version_info) needs a fresh deadline or an idle store traps instantly.
        self._set_deadline()
        try:
            out = func(self.store, *args)
        except Exception as exc:
            # A trap leaves the instance state untrusted. Drop the session and
            # rebuild; the next call gets a clean engine.
            self.sess_handle = None
            self.sess_mbt = None
            try:
                self._build()
            except Exception:
                self.store = None
                self.instance = None
                self.memory = None
                self.exports = {}
            raise EngineError(f"engine_trap:{exc}") from exc
        return int(out or 0)

    def _read_str(self, ptr: int) -> str:
        assert self.store is not None and self.memory is not None
        size = self.memory.data_len(self.store)
        if ptr < 4 or ptr > size:
            return ""
        header = self.memory.read(self.store, ptr - 4, ptr)
        length = int.from_bytes(header, "little") & LEN_MASK
        length = min(length, (size - ptr) // 2)
        if length <= 0:
            return ""
        data = self.memory.read(self.store, ptr, ptr + length * 2)
        return data.decode("utf-16-le", errors="replace")

    def _slot(self, reset: str, push: str, text: str) -> None:
        self._call_raw(reset)
        raw = text.encode("utf-8")
        for i in range(0, len(raw), SLOT_CHUNK):
            chunk = raw[i : i + SLOT_CHUNK]
            le = int.from_bytes(chunk + b"\x00" * (SLOT_CHUNK - len(chunk)), "little")
            self._call_raw(push, le, len(chunk))

    def _slot_in(self, text: str) -> None:
        self._slot("in_reset", "in_push", text)

    def _slot_arg(self, text: str) -> None:
        self._slot("arg_reset", "arg_push", text)

    def _slot_arg2(self, text: str) -> None:
        self._slot("arg2_reset", "arg2_push", text)

    def _parse(self, ptr: int) -> dict[str, Any]:
        raw = self._read_str(ptr)
        if not raw:
            return {"ok": False, "error": "engine_empty_result"}
        try:
            value = json.loads(raw)
            return value if isinstance(value, dict) else {"ok": True, "data": value}
        except Exception:
            return {"ok": False, "error": "engine_non_json", "raw": raw[:400]}

    # ---------- public API ----------

    def version_info(self) -> dict[str, Any]:
        with self.lock:
            self._ensure()
            return self._parse(self._call_raw("version_info"))

    def list_templates(self) -> list[Any]:
        with self.lock:
            self._ensure()
            out = self._parse(self._call_raw("list_templates"))
            return out if isinstance(out, list) else out.get("data", [])

    def list_ops(self) -> list[Any]:
        with self.lock:
            self._ensure()
            out = self._parse(self._call_raw("list_ops"))
            return out if isinstance(out, list) else out.get("data", [])

    def list_themes(self) -> list[Any]:
        with self.lock:
            self._ensure()
            out = self._parse(self._call_raw("list_themes"))
            return out if isinstance(out, list) else out.get("data", [])

    def list_tokens(self) -> dict[str, Any]:
        with self.lock:
            self._ensure()
            return self._parse(self._call_raw("list_tokens"))

    def list_components(self) -> list[Any]:
        return list(self.components)

    def validate(self, mbt: str) -> dict[str, Any]:
        with self.lock:
            self._ensure()
            self._slot_in(mbt)
            self._set_deadline()
            return self._parse(self._call_raw("validate_mbt_in"))

    def render(self, mbt: str) -> dict[str, Any]:
        with self.lock:
            self._ensure()
            self._slot_in(mbt)
            self._set_deadline()
            return self._parse(self._call_raw("render_mbt_in"))

    def apply(self, mbt: str, op: str, gate: str = "human") -> dict[str, Any]:
        fn = "apply_human_op_in" if gate == "human" else "apply_agent_op_in"
        with self.lock:
            self._ensure()
            try:
                self._slot_in(mbt)
                self._slot_arg(op)
                self._set_deadline()
                return self._parse(self._call_raw(fn))
            except Exception as exc:
                # a trap means the engine state is untrusted for this call
                self._reset_instance()
                return {"ok": False, "error": f"engine_trap:{exc}"}

    def export_html(self, mbt: str) -> dict[str, Any]:
        with self.lock:
            self._ensure()
            self._slot_in(mbt)
            self._set_deadline()
            return self._parse(self._call_raw("export_html_in"))

    # ---------- session ----------

    def _open(self, mbt: str) -> int:
        if self.sess_mbt == mbt and self.sess_handle is not None:
            self.hits += 1
            return self.sess_handle
        self.misses += 1
        self.close_session()
        self._slot_in(mbt)
        self._set_deadline()
        handle = self._call_raw("session_open_in")
        if handle < 0:
            raise EngineError(f"session_open_failed:{handle}")
        self.sess_mbt = mbt
        self.sess_handle = handle
        return handle

    def close_session(self) -> None:
        if self.sess_handle is not None and self.store is not None:
            try:
                self._call_raw("session_close", self.sess_handle)
            except Exception:
                pass
        self.sess_handle = None
        self.sess_mbt = None

    def _evict(self) -> None:
        try:
            self.close_session()
        except Exception:
            pass

    def session(self, name: str, mbt: str, arg: str | None = None) -> dict[str, Any]:
        with self.lock:
            self._ensure()
            try:
                handle = self._open(mbt)
                self._set_deadline()
                if name in NO_ARG_SESSION:
                    out = self._parse(self._call_raw(name, handle))
                else:
                    if arg is not None:
                        self._slot_arg(arg)
                    in_name = f"{name}_in"
                    fn = in_name if in_name in self.exports else name
                    out = self._parse(self._call_raw(fn, handle))
                if name in SESSION_MUTATING and out.get("ok") and isinstance(out.get("mbt"), str):
                    self.sess_mbt = out["mbt"]
                return out
            except Exception as exc:
                self._evict()
                return {"ok": False, "error": f"engine_session_failed:{exc}"}

    def generate(self, mbt: str, intent: str, name: str, spec: Any) -> dict[str, Any]:
        with self.lock:
            self._ensure()
            try:
                handle = self._open(mbt)
                spec_text = spec if isinstance(spec, str) else json.dumps(spec or {}, ensure_ascii=False)
                self._slot_in(spec_text)
                self._slot_arg(intent)
                self._slot_arg2(name or "")
                self._set_deadline()
                out = self._parse(self._call_raw("session_generate_in", handle))
                if out.get("ok") and isinstance(out.get("mbt"), str):
                    self.sess_mbt = out["mbt"]
                return out
            except Exception as exc:
                self._evict()
                return {"ok": False, "error": f"engine_generate_failed:{exc}"}

    def tap(self, mbt: str, artboard: str, x: float, y: float) -> dict[str, Any]:
        with self.lock:
            self._ensure()
            try:
                handle = self._open(mbt)
                self._slot_arg(artboard)
                self._set_deadline()
                out = self._parse(self._call_raw("session_tap_in", handle, float(x), float(y)))
                if out.get("ok") and isinstance(out.get("mbt"), str):
                    self.sess_mbt = out["mbt"]
                return out
            except Exception as exc:
                self._evict()
                return {"ok": False, "error": f"engine_tap_failed:{exc}"}

    def constrain(self, mbt: str, artboard: str, intent: str) -> dict[str, Any]:
        """session_constrain dual-slot contract (probed on engine 0.1.11):
        arg=artboard, arg2=intent. Success is a canonical envelope
        ({ok, id, x, mbt} — no render face); cannot_parse failures carry the
        intent vocabulary in `error` (居中 | 垂直居中 | 垂直排列 | 水平排列 |
        等宽 | 等高 | 等间距 | 网格 N | 顶部 | 底部 | 放大 N | 缩小 N | 边距 N | 间距 N).
        It is a layout-intent parser only — no z-order/hierarchy."""
        with self.lock:
            self._ensure()
            try:
                handle = self._open(mbt)
                self._slot_arg(artboard)
                self._slot_arg2(intent)
                self._set_deadline()
                out = self._parse(self._call_raw("session_constrain_in", handle))
                if out.get("ok") and isinstance(out.get("mbt"), str):
                    self.sess_mbt = out["mbt"]
                return out
            except Exception as exc:
                self._evict()
                return {"ok": False, "error": f"engine_constrain_failed:{exc}"}

    def event(self, mbt: str, artboard: str, spec: str) -> dict[str, Any]:
        """session_event dual-slot (arg=artboard, in=spec). `spec` is the raw
        event token, not JSON — probed: `key_enter` (ok) vs {"type":"key",...}
        (unknown_event). Envelope matches tap: {ok, changes[], current, mbt}."""
        with self.lock:
            self._ensure()
            try:
                handle = self._open(mbt)
                self._slot_arg(artboard)
                self._slot_in(spec)
                self._set_deadline()
                out = self._parse(self._call_raw("session_event_in", handle))
                if out.get("ok") and isinstance(out.get("mbt"), str):
                    self.sess_mbt = out["mbt"]
                return out
            except Exception as exc:
                self._evict()
                return {"ok": False, "error": f"engine_event_failed:{exc}"}

    def project_json(self, mbt: str) -> dict[str, Any]:
        return self.session("session_save", mbt)

    def stats(self) -> dict[str, Any]:
        return {
            "hits": self.hits,
            "misses": self.misses,
            "wasm_bytes": WASM_PATH.stat().st_size if WASM_PATH.exists() else 0,
        }


def compact_envelope(envelope: dict[str, Any]) -> dict[str, Any]:
    """Strip canonical + SVG from tool results; the model gets summaries."""
    out = dict(envelope)
    out.pop("mbt", None)
    out.pop("render", None)
    boards = out.get("artboards")
    if isinstance(boards, list):
        shaped = []
        for b in boards:
            if not isinstance(b, dict):
                continue
            item = {k: v for k, v in b.items() if k != "svg"}
            nodes = item.get("nodes")
            if isinstance(nodes, list):
                item["nodes"] = [
                    {k: v for k, v in n.items() if k != "style"} if isinstance(n, dict) else n
                    for n in nodes[:24]
                ]
                if len(nodes) > 24:
                    item["nodes_truncated"] = True
            shaped.append(item)
        out["artboards"] = shaped
    data = out.get("data")
    if isinstance(data, list) and len(data) > 40:
        out["data"] = data[:40]
        out["data_truncated"] = True
    return out
