#!/usr/bin/env python3
"""引擎脚本与服务端清理批次的回归锚点（2026-11-17 审查批次）。

覆盖七条修复：
① server-6 /project/export/3d 死路由删除（路由面断言在 test_server_routes）。
② engine-5 ddp.py save_ddp/load_ddp 死函数删除（project_save/open 直用
   encrypt/decrypt；死代码带陈旧读上限约定，留着易被误用）。
③ engine-2 sync_engine --release 死路：锚定 engine-v0.1.11 缺 0.2 面
   （session_event_in），下载前必须 fail-fast 而不是下载后探针才炸。
④ engine-4 components.json 快照与 wasm 活注册表逐 id 对账（快照条数只跟
   自己比抓不住引擎组件面增删）。
⑤ engine-3 /engine/session 省略 arg 不得复用上一次调用残留的 arg 槽
   （query a1 后无参调用曾返回 a1 节点且 ok:true——真机探针实证）。
⑥ server-5 /video/review 临时目录即用即删 + 残留清扫（曾无界增长）。
⑦ agent-2 three build-state.json 原子写 + 损坏自愈（.bak + 重置初始 pass）
   + list/read 容错（单个坏项目不得 500 整个列表）。

用法：.venv/bin/python scripts/wf/test_engine_server_cleanup.py （退出码 0 = 全绿）
"""
from __future__ import annotations

import asyncio
import importlib.util
import json
import os
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
SERVER = ROOT / "server"
sys.path.insert(0, str(SERVER))

failures: list[str] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    print(f"  {'✓' if ok else '✗'} {name}" + (f" —— {detail}" if detail and not ok else ""))
    if not ok:
        failures.append(name)


# ---------- ② ddp 死函数删除 + 编解码往返无恙 ----------

import ddp  # noqa: E402


def check_ddp() -> None:
    print("[2] ddp dead functions removed")
    check("save_ddp removed", not hasattr(ddp, "save_ddp"))
    check("load_ddp removed", not hasattr(ddp, "load_ddp"))
    mbt = "# T\n\n<!-- moonviz:artboard a -->\n```mbt\nfn v() -> @decl.Prototype {\n  @decl.prototype(name=\"a\")\n}\n```\n"
    for pw in ("", "secret-pw"):
        blob = ddp.encrypt_ddp(mbt, pw)
        back = ddp.decrypt_ddp(blob, pw)
        check(f"roundtrip (password={'yes' if pw else 'no'})", back == mbt)


# ---------- ③ sync_engine --release 死路 fail-fast ----------

def load_sync_engine():
    spec = importlib.util.spec_from_file_location(
        "sync_engine_under_test", ROOT / "scripts" / "sync_engine.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def check_sync_release() -> None:
    print("[3] sync_engine --release dead-end guidance")
    sync = load_sync_engine()
    check("anchor engine-v0.1.11 predates 0.2", sync._release_anchor_predates_02(),
          f"RELEASE_TAG={sync.RELEASE_TAG}")
    # fail-fast 必须发生在下载之前：锚点早于 0.2 时 _fetch_release 直接 SystemExit
    try:
        sync._fetch_release()
        check("_fetch_release fails fast on pre-0.2 anchor", False, "no SystemExit raised")
    except SystemExit as exc:
        msg = str(exc)
        check("_fetch_release fails fast on pre-0.2 anchor",
              "probe_engine_02" in msg and "0.2" in msg, f"message: {msg[:120]}")
    # 本地构建缺失的报错不得再把 --release 当可用回落指路
    src = (ROOT / "scripts" / "sync_engine.py").read_text("utf-8")
    check("local-missing error no longer offers --release as a working fallback",
          "--release 不是可用回落" in src)
    # 锚点升到 0.2.x 后判定自动放行（不是写死的永久拒绝）
    old = sync.RELEASE_TAG
    try:
        sync.RELEASE_TAG = "engine-v0.2.0"
        check("guard auto-unlocks on a 0.2 anchor", not sync._release_anchor_predates_02())
    finally:
        sync.RELEASE_TAG = old


# ---------- ⑤ engine-3 arg 槽残留 + ④ 活组件对账（真机 wasm） ----------

TWO_BOARD_SEED = (
    "---\nmoonviz:\n  format: visual-document\n  revision: 1\n  entry: a1\n---\n\n"
    "# a1\n\n<!-- moonviz:artboard a1 -->\n```mbt\n"
    'fn visual_a1() -> @decl.Prototype {\n  let page = @decl.prototype(name="a1", width=390.0, height=844.0)\n  page\n}\n```\n\n'
    "# a2\n\n<!-- moonviz:artboard a2 -->\n```mbt\n"
    'fn visual_a2() -> @decl.Prototype {\n  let page = @decl.prototype(name="a2", width=390.0, height=844.0)\n  page\n}\n```\n'
)


def check_engine() -> None:
    print("[4/5] engine host (real wasm)")
    from engine import EngineHost

    host = EngineHost()
    out = host.session("session_apply_human", TWO_BOARD_SEED,
                       "place a1 button b1 - 30 110 140 44 text=hi")
    if not out.get("ok"):
        check("seed place op", False, str(out.get("error")))
        return
    doc = out["mbt"]
    r1 = host.session("session_query_nodes", doc, "a1")
    ok1 = r1.get("ok") and any(n.get("id") == "b1" for n in (r1.get("data") or []))
    check("query with explicit artboard a1 returns b1", bool(ok1))
    r2 = host.session("session_query_nodes", doc, None)
    stale = r2.get("ok") and any(n.get("id") == "b1" for n in (r2.get("data") or []))
    check("omitted arg never answers with the previous artboard's nodes",
          not stale, f"got: {json.dumps(r2, ensure_ascii=False)[:160]}")
    check("omitted arg surfaces an explicit engine error instead",
          r2.get("ok") is False and "unknown_artboard" in str(r2.get("error")))

    live = host.list_components_live()
    snap = host.list_components()
    live_ids = {c.get("id") for c in live if isinstance(c, dict)}
    snap_ids = {c.get("id") for c in snap if isinstance(c, dict)}
    check("live registry is a non-empty id set", len(live_ids) > 0)
    check("snapshot ids == live wasm registry ids", live_ids == snap_ids,
          f"live-only={sorted(live_ids - snap_ids)[:6]} snap-only={sorted(snap_ids - live_ids)[:6]}")


# ---------- ⑥ /video/review 临时目录清理 ----------

def check_video_review() -> None:
    print("[6] video review scratch dirs")
    import main as server_main

    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        old_dir = root / "review-deadbeef"
        old_dir.mkdir()
        (old_dir / "timeline.json").write_text("{}", "utf-8")
        stale_legacy = root / "review-tmp"  # 旧共享目录残留
        stale_legacy.mkdir()
        fresh = root / "review-fresh01"
        fresh.mkdir()
        two_h_ago = time.time() - 7200
        os.utime(old_dir, (two_h_ago, two_h_ago))
        os.utime(stale_legacy, (two_h_ago, two_h_ago))

        saved = server_main._VIDEO_ROOT
        server_main._VIDEO_ROOT = root
        try:
            server_main._sweep_review_dirs()
            check("sweep removes stale review-* dirs", not old_dir.exists())
            check("sweep removes legacy review-tmp", not stale_legacy.exists())
            check("sweep keeps fresh dirs (not in flight)", fresh.exists())
            fresh.rmdir()  # 清掉本测试自己的 fixture，下面的「用后即删」只看端点产物

            req = server_main.VideoRenderRequest(timeline={"scenes": []})
            resp = asyncio.run(server_main.video_review(req))
            check("review endpoint returns a verdict",
                  isinstance(resp.get("exit"), int) and "output" in resp)
            leftovers = sorted(p.name for p in root.glob("review-*"))
            check("review dir deleted after the call (finally)", not leftovers,
                  f"leftovers: {leftovers}")
        finally:
            server_main._VIDEO_ROOT = saved


# ---------- ⑦ three build-state 原子写 + 自愈 ----------

def check_three_state() -> None:
    print("[7] three build-state atomic write + self-heal")
    import three_agent as three

    with tempfile.TemporaryDirectory() as td:
        saved = three.THREE_ROOT
        three.THREE_ROOT = Path(td)
        try:
            # 正常路径：原子写往返 + 无 .tmp 残留
            three.write_state("alpha", {"current": "lighting", "passes": [], "loop_max": 3})
            st = json.loads((Path(td) / "alpha" / "build-state.json").read_text("utf-8"))
            check("write_state roundtrip", st["current"] == "lighting")
            check("atomic write leaves no .tmp files",
                  not list((Path(td) / "alpha").glob("*.tmp")))

            # 损坏（半截 JSON）→ .bak + 重置初始 pass + 历史登记
            (Path(td) / "alpha" / "build-state.json").write_text('{"current": "lig', "utf-8")
            healed = three.read_state("alpha")
            check("corrupt state self-heals to initial pass",
                  healed["current"] == three.PASSES[0]["id"] and not healed["blocked"])
            check("corrupt state backed up to .bak",
                  (Path(td) / "alpha" / "build-state.json.bak").exists())
            hist = (Path(td) / "alpha" / "history.jsonl").read_text("utf-8")
            check("state-corrupt-reset recorded in history", "state-corrupt-reset" in hist)

            # 非 dict JSON 同样按损坏处理
            (Path(td) / "alpha" / "build-state.json").write_text("[1,2]", "utf-8")
            healed2 = three.read_state("alpha")
            check("non-object state treated as corrupt", healed2["current"] == three.PASSES[0]["id"])

            # 列表容错：健康项目正常列出、损坏项目标 corrupt（不得抛异常）
            (Path(td) / "beta").mkdir()
            (Path(td) / "beta" / "build-state.json").write_text('{"current": "form", "blocked": false}', "utf-8")
            (Path(td) / "gamma").mkdir()
            (Path(td) / "gamma" / "build-state.json").write_text('{"bad', "utf-8")
            listing = three.list_projects()
            names = {p["name"]: p for p in listing["projects"]}
            check("list_projects keeps healthy projects", names.get("beta", {}).get("current") == "form")
            check("list_projects marks corrupt instead of 500",
                  names.get("gamma", {}).get("current") == "corrupt")

            # read_project：history 半行跳过，不炸整个项目读取
            (Path(td) / "beta" / "history.jsonl").write_text(
                '{"ts": 1, "action": "new"}\n{"ts": 2, "act', "utf-8")
            proj = three.read_project("beta")
            check("torn history line skipped",
                  len(proj["history"]) == 1 and proj["history"][0]["action"] == "new")

            # 缺项目仍诚实报 no_project
            try:
                three.read_state("missing_proj")
                check("missing project raises no_project", False)
            except three.ThreeError as e:
                check("missing project raises no_project", "no_project" in str(e))
        finally:
            three.THREE_ROOT = saved


def main() -> int:
    check_ddp()
    check_sync_release()
    check_engine()
    check_video_review()
    check_three_state()
    if failures:
        print("FAIL")
        for item in failures:
            print(" -", item)
        return 1
    print("engine/server cleanup: all cases green")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
