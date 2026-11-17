#!/usr/bin/env python3
"""3D 工作台服务回归（blocked 死锁解除 / 删除端点 / 错误面包 ThreeError）。

用法：.venv/bin/python scripts/wf/test_three.py （退出码 0 = 全绿）

覆盖（2026-11-17 审查批次 three-1/3/4）：
  1) _proj_dir 名称校验：ASCII 字母数字-_ 白名单——中文/路径分隔符/.. 一律
     invalid_name（旧 isalnum 过滤放行 CJK 落盘，与 UI 提示矛盾）；合法名放行。
  2) save_spec 解封（blocked 死锁解除）：blocked 状态 + blocked pass 计数
     满载时回灌合法 spec → blocked 清零、attempts 归零、状态回 pending，
     run_pass 不再被 blocked 门拒绝；无 blocked 时原样返回；缺项目/坏 spec 拒绝。
  3) delete_project 真删：目录删除、根外哨兵必存活、坏 name（空串/../绝对
     路径/中文）拒绝且不越界、缺项目 no_project；THREE_ROOT 临时化。
  4) _chat 包 openai 异常：AuthenticationError（401 mock）→ ThreeError
     llm_error 带类型与状态码；空 choices 同门。
  5) _extract_json 包 JSONDecodeError：含花括号的非 JSON → spec_parse_failed
     带诊断；合法围栏 JSON 照常解析。
  6) spec 损坏读取面：read_spec / read_project / run_pass（生成路径）对损坏
     three-spec.json 一律 ThreeError spec_corrupt，绝不裸 JSONDecodeError
     直达 500（与 build-state 的自愈不同：spec 如实报错，出路是 spec/save）。

LLM 全程 mock（AsyncOpenAI / _chat 直接替身）；THREE_ROOT 指向临时目录，
绝不写 ~/Documents。
"""

from __future__ import annotations

import asyncio
import json
import sys
import tempfile
from pathlib import Path
from unittest import mock

import httpx
import openai

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "server"))

import three_agent as three  # noqa: E402


def _spec(**over) -> dict:
    base = {"title": "saturn", "components": [{"id": "planet", "what": "球体"}],
            "acceptance": ["行星可见"]}
    base.update(over)
    return base


def _make_project(name: str, spec: dict | None = None) -> Path:
    d = three._proj_dir(name)
    d.mkdir(parents=True, exist_ok=True)
    (d / "three-spec.json").write_text(
        json.dumps(spec or _spec(), ensure_ascii=False, indent=1), "utf-8")
    three.write_state(name, three._initial_state())
    return d


async def _fake_chat_ok(model, base_url, api_key, thinking, system, user) -> str:
    return "```js\nexport default function build(THREE, scene, camera, controls, renderer) {}\n```"


class _FakeCompletions:
    def __init__(self, owner: "_FakeClient"):
        self._o = owner

    async def create(self, **kwargs):
        if self._o._exc is not None:
            raise self._o._exc
        class _Msg:
            content = "hi"
        class _Choice:
            message = _Msg()
        class _Resp:
            choices = [] if self._o._empty else [_Choice()]
        return _Resp()


class _FakeChat:
    def __init__(self, owner: "_FakeClient"):
        self.completions = _FakeCompletions(owner)


class _FakeClient:
    """AsyncOpenAI 替身：exc 在场即抛（_chat 必须包成 ThreeError），
    否则返回 choices（empty_choices=True 时给空补全）。"""

    def __init__(self, exc: Exception | None = None, empty_choices: bool = False):
        self._exc = exc
        self._empty = empty_choices
        self.chat = _FakeChat(self)


def main() -> int:
    failures: list[str] = []

    def check(name: str, cond: bool, detail: str = "") -> None:
        if not cond:
            failures.append(f"{name}: {detail}")

    def expect_error(name: str, fn, needle: str = "") -> None:
        try:
            fn()
        except three.ThreeError as e:
            check(name, needle in str(e), str(e))
        except Exception as e:  # noqa: BLE001 - 测试要区分错误类型
            check(name, False, f"wrong exception {type(e).__name__}: {e}")
        else:
            check(name, False, "no exception raised")

    async def expect_error_async(name: str, coro, needle: str = "") -> None:
        try:
            await coro
        except three.ThreeError as e:
            check(name, needle in str(e), str(e))
        except Exception as e:  # noqa: BLE001
            check(name, False, f"wrong exception {type(e).__name__}: {e}")
        else:
            check(name, False, "no exception raised")

    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        root = tmp / "3d"
        root.mkdir()
        outside = tmp / "outside"
        outside.mkdir()
        sentinel = outside / "keep.txt"
        sentinel.write_text("do not delete", "utf-8")
        home = tmp / "home"
        (home / "Documents").mkdir(parents=True)

        with mock.patch.object(three, "THREE_ROOT", root), \
                mock.patch("pathlib.Path.home", return_value=home):
            # ---- 1) _proj_dir 名称校验（three-4：ASCII 白名单） ----
            d = three._proj_dir("saturn-demo")
            check("valid name maps under root", d == root / "saturn-demo", str(d))
            check("underscore/digits accepted", three._proj_dir("ring_1").name == "ring_1")
            for bad in ("", "..", ".", "a/b", "a\\b", "../escape", "/tmp/evil",
                        "中文项目", "saturn 土星", "a b", "a\x00b"):
                expect_error(f"reject name {bad!r}",
                             lambda b=bad: three._proj_dir(b), "invalid_name")

            # ---- 4) _chat 包 openai 异常（three-3） ----
            auth_err = openai.AuthenticationError(
                "401 Incorrect API key",
                response=httpx.Response(401, request=httpx.Request("POST", "http://t")),
                body=None)
            with mock.patch.object(three, "AsyncOpenAI", lambda **kw: _FakeClient(auth_err)):
                asyncio.run(expect_error_async(
                    "401 wrapped as ThreeError",
                    three.new_project("llm-err", "brief", "m", "http://x", "k", "auto"),
                    "llm_error:AuthenticationError:401"))
            check("401 failure leaves no project dir",
                  not (root / "llm-err").exists())
            with mock.patch.object(three, "AsyncOpenAI",
                                   lambda **kw: _FakeClient(empty_choices=True)):
                asyncio.run(expect_error_async(
                    "empty choices wrapped",
                    three.new_project("llm-empty", "brief", "m", "http://x", "k", "auto"),
                    "llm_error"))

            # ---- 5) _extract_json 包 JSONDecodeError（three-3） ----
            expect_error("non-json with braces → spec_parse_failed",
                         lambda: three._extract_json("好的，这是方案 {不是 json 吧}}"),
                         "spec_parse_failed")
            check("fenced json parses",
                  three._extract_json('```json\n{"a": 1}\n```') == {"a": 1})

            # ---- 2) save_spec 解封（three-1：blocked 死锁解除） ----
            name = "saturn-demo"
            _make_project(name)
            state = three.read_state(name)
            state["blocked"] = True
            state["blocked_reason"] = "structure 连续 3 轮执行失败"
            cur = next(p for p in state["passes"] if p["id"] == state["current"])
            check("initial pass is blockout", cur["id"] == "blockout", cur["id"])
            cur["attempts"] = 3
            cur["status"] = "blocked"
            three.write_state(name, state)

            res = three.save_spec(name, _spec(title="saturn v2"))
            check("save_spec ok", res.get("ok") is True)
            check("save_spec reports unblocked", res.get("unblocked") is True)
            st = three.read_state(name)
            check("blocked flag cleared", st.get("blocked") is False)
            check("blocked_reason cleared", st.get("blocked_reason") == "")
            cur2 = next(p for p in st["passes"] if p["id"] == "blockout")
            check("attempts reset to 0", cur2["attempts"] == 0, str(cur2["attempts"]))
            check("status back to pending", cur2["status"] == "pending", cur2["status"])

            # 解封后 run_pass 不再被 blocked 门拒绝（LLM mock 走通整条生成路径）
            with mock.patch.object(three, "_chat", _fake_chat_ok):
                rp = asyncio.run(three.run_pass(name, "m", "http://x", "k", "auto"))
            check("run_pass proceeds after unblock",
                  rp.get("ok") is True and rp.get("pass") == "blockout", str(rp)[:200])

            # 无 blocked 的常规保存：不误报 unblocked、状态不动
            _make_project("calm-app")
            res2 = three.save_spec("calm-app", _spec())
            check("normal save not flagged unblocked", res2.get("unblocked") is False)
            st2 = three.read_state("calm-app")
            check("normal save keeps pending pass",
                  st2["passes"][0]["status"] == "pending", st2["passes"][0]["status"])

            expect_error("save_spec on missing project",
                         lambda: three.save_spec("ghost-app", _spec()), "no_project")
            expect_error("save_spec rejects spec without acceptance",
                         lambda: three.save_spec("calm-app", _spec(acceptance=[])),
                         "spec_invalid")

            # ---- 3) delete_project 真删 + 越界防护（three-1 / portfolio 纪律） ----
            good = _make_project("doomed-app")
            check("doomed project exists", good.exists())
            res3 = three.delete_project("doomed-app")
            check("delete ok", res3.get("ok") is True)
            check("dir really removed", not good.exists())
            check("sentinel survives valid delete", sentinel.exists())
            check("root survives valid delete", root.exists())
            expect_error("delete missing project → no_project",
                         lambda: three.delete_project("doomed-app"), "no_project")
            for bad in ("", "..", str(outside), "../outside", "中文项目", "a/b"):
                expect_error(f"delete rejects name {bad!r}",
                             lambda b=bad: three.delete_project(b), "invalid_name")
                check(f"sentinel survives bad delete {bad!r}", sentinel.exists())
                check(f"root survives bad delete {bad!r}", root.exists())

            # 越界纵深防御：白名单收紧后 _proj_dir 已不可能返回根外路径，
            # 但 delete_project 的显式断言是 portfolio_delete 纪律的复制——
            # 「即使未来白名单放宽，删除路径也不能逃出项目根」。直接替身
            # _proj_dir 返回根外目标锚定这条不变量（否则断言成了不可测死码）。
            with mock.patch.object(three, "_proj_dir",
                                   lambda n: root.parent / "escape"):
                expect_error("delete refuses escaped target",
                             lambda: three.delete_project("anything"), "路径越界")
            check("sentinel survives escaped target", sentinel.exists())
            check("root survives escaped target", root.exists())

            # ---- 6) spec 损坏读取面包 ThreeError（three-3） ----
            broken = _make_project("broken-spec")
            (broken / "three-spec.json").write_text("not json{{{", "utf-8")
            expect_error("read_spec on corrupt spec",
                         lambda: three.read_spec("broken-spec"), "spec_corrupt")
            expect_error("read_project on corrupt spec",
                         lambda: three.read_project("broken-spec"), "spec_corrupt")
            with mock.patch.object(three, "_chat", _fake_chat_ok):
                try:
                    asyncio.run(three.run_pass("broken-spec", "m", "http://x", "k", "auto"))
                except three.ThreeError as e:
                    check("run_pass on corrupt spec → spec_corrupt", "spec_corrupt" in str(e), str(e))
                except Exception as e:  # noqa: BLE001
                    check("run_pass on corrupt spec → spec_corrupt", False,
                          f"wrong exception {type(e).__name__}: {e}")
                else:
                    check("run_pass on corrupt spec → spec_corrupt", False, "no exception")

            # read_state 的自愈路径不受影响（对照：build-state 损坏仍自愈）
            (broken / "build-state.json").write_text("half json", "utf-8")
            st3 = three.read_state("broken-spec")
            check("build-state corrupt still self-heals",
                  st3.get("current") == "blockout", str(st3)[:120])
            check("state bak kept as evidence",
                  (broken / "build-state.json.bak").exists())

    if failures:
        print("FAIL")
        for item in failures:
            print(" -", item)
        return 1
    print("three agent: all cases green")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
