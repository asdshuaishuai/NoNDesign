#!/usr/bin/env python3
"""视频服务端 job 生命周期单测（持久化 / 容量治理 / 去重回归）。

覆盖（2026-11-16 批量实测的三个流程缺陷）：
  1) 渲染完成：frames.mp4 落持久目录 videos/<job>/，终态 mp4 指向持久路径，
     frames 计数与原 job 目录产物齐全（旧 video/ job 目录受 20 容量轮换管辖，
     完成品住在那里会随轮换静默蒸发——video 是三类作品里唯一会被系统自动
     删除产物的，作品集条目随之消失）。
  2) 渲染失败：无 mp4 不落持久目录，终态 failed 照常可轮询。
  3) 容量轮换只清终态 job：running 的 job 目录与记录绝不逐出（目录被
     rmtree 时 render.py 还在写帧，用户视角「提交成功的渲染凭空消失」）；
     超容量的终态 job 照常轮换、全部 running 超容量一个都不清。
  4) 在飞打满容量：/video/render 返回 429，不逐出在飞任务、不新建 job、
     不 spawn render.py；同 payload 已有在飞时去重优先于容量 429。
  5) 相同 payload 的在飞 job 按 payload 哈希去重返回既有 job（dedup=true，
     只建一个 job 目录）；终态 job 不参与去重（done 后再提交 = 真实重渲）。

用法：.venv/bin/python scripts/wf/test_video_jobs.py （退出码 0 = 全绿）
"""

from __future__ import annotations

import asyncio
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from unittest import mock

from fastapi import HTTPException

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "server"))

import hotapp_agent as hotapp  # noqa: E402  (作品集补扫：video 扫描根对账)
import main as server_main  # noqa: E402  (import registers all routes)


def _wait_terminal(job: str, timeout: float = 5.0) -> dict | None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        info = server_main._VIDEO_JOBS.get(job)
        if info and info.get("status") != "running":
            return info
        time.sleep(0.02)
    return server_main._VIDEO_JOBS.get(job)


def main() -> int:
    failures: list[str] = []

    def check(name: str, cond: bool, detail: str = "") -> None:
        if not cond:
            failures.append(f"{name}: {detail}")

    timeline = {"beats": [{"t": 0.0, "d": 1.0}]}
    spec = {"kind": "science", "params": {}}
    req = server_main.VideoRenderRequest(timeline=timeline, spec=spec, fps=10)

    # ---- 1) 渲染完成：mp4 落持久目录 videos/<job>/（轮换够不着），终态指向它 ----
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        # persist_root 摆在 tmp 伪装的 HOME 下（Documents/NoNDesign/videos），
        # 与 hotapp_agent.portfolio_list 的扫描根同一条路径
        video_root = tmp / "video"
        persist_root = tmp / "Documents" / "NoNDesign" / "videos"

        def fake_render_ok(cmd, **kwargs):
            d = Path(cmd[2]).parent  # cmd = [py, render.py, tl_file, frames_dir, ...]
            frames = d / "frames"
            frames.mkdir(parents=True, exist_ok=True)
            (frames / "frame_00000.png").write_text("png", "utf-8")
            (frames / "frame_00001.png").write_text("png", "utf-8")
            (d / "frames.mp4").write_text("mp4", "utf-8")
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

        with mock.patch.object(server_main, "_VIDEO_ROOT", video_root), \
                mock.patch.object(server_main, "_VIDEO_PERSIST_ROOT", persist_root), \
                mock.patch("subprocess.run", fake_render_ok), \
                mock.patch("pathlib.Path.home", return_value=tmp):
            server_main._VIDEO_JOBS.clear()
            res = asyncio.run(server_main.video_render(req))
            job = str(res.get("job", ""))
            check("submit ok", res.get("ok") is True and len(job) == 12, repr(res))
            info = _wait_terminal(job)
            check("job reaches done", bool(info) and info["status"] == "done", repr(info))
            persisted = persist_root / job / "frames.mp4"
            check("mp4 persisted to videos/<job>/", persisted.exists(), str(persist_root))
            check("terminal mp4 points at persisted copy",
                  bool(info) and info.get("mp4") == str(persisted), repr(info and info.get("mp4")))
            check("frames counted from job dir",
                  bool(info) and info.get("frames") == 2, repr(info and info.get("frames")))
            check("job dir still holds original mp4", (video_root / job / "frames.mp4").exists())

            # 作品集补扫根（videos/）能扫到持久产物——条目随持久化存活
            with mock.patch.object(hotapp, "PORTFOLIO_FILE", tmp / "portfolio" / "index.json"):
                listed = hotapp.portfolio_list()["items"]
            entry = next((e for e in listed if e["kind"] == "video" and e["ref"] == str(persisted)), None)
            check("portfolio scan finds persisted mp4", entry is not None, repr(listed))

            # 终态不参与去重：同 payload 完成后再提交 = 新 job（真实重渲）
            res2 = asyncio.run(server_main.video_render(req))
            check("done job not deduped",
                  res2.get("job") != job and "dedup" not in res2, repr(res2))
            _wait_terminal(str(res2.get("job", "")))
            server_main._VIDEO_JOBS.clear()

    # ---- 2) 渲染失败：无 mp4、不落持久目录、终态 failed 可轮询 ----
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        video_root, persist_root = tmp / "video", tmp / "videos"

        def fake_render_fail(cmd, **kwargs):
            return subprocess.CompletedProcess(cmd, 3, stdout="", stderr="boom")

        fail_req = server_main.VideoRenderRequest(timeline={"beats": []}, spec=None, fps=10)
        with mock.patch.object(server_main, "_VIDEO_ROOT", video_root), \
                mock.patch.object(server_main, "_VIDEO_PERSIST_ROOT", persist_root), \
                mock.patch("subprocess.run", fake_render_fail):
            server_main._VIDEO_JOBS.clear()
            res = asyncio.run(server_main.video_render(fail_req))
            info = _wait_terminal(str(res.get("job", "")))
            check("failed job stays failed", bool(info) and info["status"] == "failed", repr(info))
            check("no persist dir on failure", not persist_root.exists(), str(persist_root))
            server_main._VIDEO_JOBS.clear()

    # ---- 3) 轮换只清终态：running 绝不逐出（连目录带记录） ----
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        video_root = tmp / "video"

        def seed(jid: str, status: str) -> None:
            d = video_root / jid
            (d / "frames").mkdir(parents=True)
            (d / "frames" / "frame_00000.png").write_text("p", "utf-8")
            (d / "frames.mp4").write_text("m", "utf-8")
            server_main._VIDEO_JOBS[jid] = {"status": status, "dir": str(d / "frames"),
                                            "log": "", "mp4": "", "frames": 1}

        with mock.patch.object(server_main, "_VIDEO_ROOT", video_root):
            server_main._VIDEO_JOBS.clear()
            seed("old_done_1", "done")
            seed("old_done_2", "done")
            seed("old_failed", "failed")
            seed("live_run", "running")
            server_main._prune_video_jobs(keep=3)
            check("prune evicts oldest terminal job", "old_done_1" not in server_main._VIDEO_JOBS)
            check("prune removes evicted job dir", not (video_root / "old_done_1").exists())
            check("prune lands within budget", len(server_main._VIDEO_JOBS) == 3,
                  repr(list(server_main._VIDEO_JOBS)))
            check("running job survives rotation",
                  server_main._VIDEO_JOBS.get("live_run", {}).get("status") == "running")
            check("running job dir intact",
                  (video_root / "live_run" / "frames" / "frame_00000.png").exists())

            # 全部 running 超容量：一个都不清（429 由端点负责，不逐出在飞任务）
            server_main._VIDEO_JOBS.clear()
            for i in range(3):
                seed(f"run{i}", "running")
            server_main._prune_video_jobs(keep=2)
            check("all-running over budget evicts nothing",
                  len(server_main._VIDEO_JOBS) == 3, repr(list(server_main._VIDEO_JOBS)))
            check("all-running job dirs intact",
                  all((video_root / f"run{i}" / "frames.mp4").exists() for i in range(3)))
            server_main._VIDEO_JOBS.clear()

    # ---- 4) 在飞打满容量：429 拒绝新提交，不逐出在飞、不 spawn render ----
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        video_root = tmp / "video"
        spawned: list[list[str]] = []

        def fake_run_spy(cmd, **kwargs):
            spawned.append(list(cmd))
            return subprocess.CompletedProcess(cmd, 1, stdout="", stderr="")

        with mock.patch.object(server_main, "_VIDEO_ROOT", video_root), \
                mock.patch.object(server_main, "_VIDEO_PERSIST_ROOT", tmp / "videos"), \
                mock.patch("subprocess.run", fake_run_spy):
            server_main._VIDEO_JOBS.clear()
            for i in range(server_main._VIDEO_MAX_JOBS):
                d = video_root / f"run{i}" / "frames"
                d.mkdir(parents=True)
                server_main._VIDEO_JOBS[f"run{i}"] = {"status": "running", "dir": str(d),
                                                      "log": "", "mp4": "", "frames": 0}
            try:
                asyncio.run(server_main.video_render(req))
                check("capacity full rejected", False, "no HTTPException raised")
            except HTTPException as e:
                check("capacity full returns 429", e.status_code == 429, str(e.status_code))
                check("429 detail names capacity", "video_capacity_full" in e.detail, repr(e.detail))
            check("429 creates no job record",
                  len(server_main._VIDEO_JOBS) == server_main._VIDEO_MAX_JOBS,
                  repr(len(server_main._VIDEO_JOBS)))
            check("429 spawns no render.py", not spawned, repr(spawned))
            check("in-flight jobs untouched by 429",
                  all(server_main._VIDEO_JOBS.get(f"run{i}", {}).get("status") == "running"
                      for i in range(server_main._VIDEO_MAX_JOBS)))
            check("no job dir leaked on 429",
                  {p.name for p in video_root.iterdir()}
                  == {f"run{i}" for i in range(server_main._VIDEO_MAX_JOBS)},
                  repr(sorted(p.name for p in video_root.iterdir())))

            # 同 payload 已有在飞：去重优先于容量 429，返回既有 job
            server_main._VIDEO_JOBS["run0"]["phash"] = server_main._video_payload_hash(req)
            res = asyncio.run(server_main.video_render(req))
            check("dedup wins over capacity 429",
                  res.get("job") == "run0" and res.get("dedup") is True, repr(res))
            check("dedup keeps record count",
                  len(server_main._VIDEO_JOBS) == server_main._VIDEO_MAX_JOBS)
            server_main._VIDEO_JOBS.clear()

    # ---- 5) 并发重复提交去重：相同 payload 两个请求只建一个在飞 job ----
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        video_root = tmp / "video"
        gate = threading.Event()

        def fake_render_blocking(cmd, **kwargs):
            gate.wait(timeout=5)  # 挡住 render：两次提交必须都落在「在飞」窗口内
            return subprocess.CompletedProcess(cmd, 1, stdout="", stderr="blocked")

        async def _submit_twice():
            res1, res2 = await asyncio.gather(server_main.video_render(req),
                                              server_main.video_render(req))
            gate.set()  # 放行 fake render，shutdown_default_executor 不再等待
            return res1, res2

        with mock.patch.object(server_main, "_VIDEO_ROOT", video_root), \
                mock.patch.object(server_main, "_VIDEO_PERSIST_ROOT", tmp / "videos"), \
                mock.patch("subprocess.run", fake_render_blocking):
            server_main._VIDEO_JOBS.clear()
            res1, res2 = asyncio.run(_submit_twice())
            job1, job2 = str(res1.get("job", "")), str(res2.get("job", ""))
            check("concurrent duplicate submits share one job", job1 == job2 and job1,
                  f"{job1} vs {job2}")
            check("dedup flag present on second response", res2.get("dedup") is True, repr(res2))
            _wait_terminal(job1)
            check("single job record kept",
                  list(server_main._VIDEO_JOBS) == [job1], repr(list(server_main._VIDEO_JOBS)))
            check("single job dir created",
                  [p.name for p in video_root.iterdir()] == [job1],
                  repr([p.name for p in video_root.iterdir()]))
            server_main._VIDEO_JOBS.clear()

    server_main._VIDEO_JOBS.clear()

    if failures:
        print("FAIL")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("PASS — video job lifecycle: persist / terminal-only prune / 429 capacity / dedup")
    return 0


if __name__ == "__main__":
    sys.exit(main())
