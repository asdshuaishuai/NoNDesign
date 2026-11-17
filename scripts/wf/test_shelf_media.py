#!/usr/bin/env python3
"""艺术架视频媒体面（server/video_media.py）契约。

用法：.venv/bin/python scripts/wf/test_shelf_media.py （退出码 0 = 全绿）

覆盖：
  1) videos/（持久产物根）下 job/frames.mp4 → 200 + accept-ranges: bytes；
  2) Range: bytes=0-1023 → 206 + content-range，seek 可用（WebView 播放硬前提）；
  3) HEAD（curl -sI 的媒体探活路径）200 + accept-ranges: bytes，不带 body；
  4) video/（轮换 job 根，_persist_video_mp4 复制失败的回退路径）同样 200
     ——只认 videos/ 会让持久化失败的产物永远打不开；
  5) `..` 穿越 400；两根之外的绝对路径 400；非 frames.mp4 400；缺失 404。
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "server"))

from fastapi import FastAPI  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

import video_media  # noqa: E402


def main() -> int:
    failures: list[str] = []

    def check(name: str, cond: bool, detail: str = "") -> None:
        if not cond:
            failures.append(f"{name}: {detail}")

    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        videos = base / "videos"
        runtime = base / "video"
        # 双根都在临时目录里（绝不读真实 ~/Documents）。
        video_media.VIDEOS_ROOT = videos
        video_media.VIDEO_RUNTIME_ROOT = runtime

        payload = bytes(range(256)) * 16  # 4096 字节，Range 分片有意义

        persist_dir = videos / "job-persist"
        persist_dir.mkdir(parents=True)
        persist_mp4 = persist_dir / "frames.mp4"
        persist_mp4.write_bytes(payload)

        runtime_dir = runtime / "job-runtime"
        runtime_dir.mkdir(parents=True)
        runtime_mp4 = runtime_dir / "frames.mp4"
        runtime_mp4.write_bytes(payload)

        # 形状合法但文件缺失（job 目录在、mp4 不在）
        missing_dir = videos / "job-missing"
        missing_dir.mkdir()

        # 非 frames.mp4 产物名
        wrong_name = persist_dir / "other.mp4"
        wrong_name.write_bytes(b"x")

        # 两根之外的绝对路径
        outside_dir = base / "elsewhere" / "job"
        outside_dir.mkdir(parents=True)
        outside_mp4 = outside_dir / "frames.mp4"
        outside_mp4.write_bytes(payload)

        app = FastAPI()
        app.include_router(video_media.router)
        client = TestClient(app)

        res = client.get("/video/mp4", params={"path": str(persist_mp4)})
        check("videos root serves 200", res.status_code == 200, f"status={res.status_code} body={res.text[:200]}")
        check("videos root accept-ranges", res.headers.get("accept-ranges") == "bytes",
              f"accept-ranges={res.headers.get('accept-ranges')!r}")
        check("videos root content-type", res.headers.get("content-type", "").startswith("video/mp4"),
              f"content-type={res.headers.get('content-type')!r}")
        check("videos root body", res.content == payload, f"len={len(res.content)}")

        res = client.get("/video/mp4", params={"path": str(persist_mp4)},
                         headers={"Range": "bytes=0-1023"})
        check("range 206", res.status_code == 206, f"status={res.status_code}")
        check("range length", len(res.content) == 1024, f"len={len(res.content)}")
        check("range content-range", res.headers.get("content-range") == "bytes 0-1023/4096",
              f"content-range={res.headers.get('content-range')!r}")
        check("range body prefix", res.content == payload[:1024], "range body mismatch")

        # HEAD（curl -sI 的探活路径）：200 + accept-ranges，无 body。
        res = client.head("/video/mp4", params={"path": str(persist_mp4)})
        check("HEAD 200", res.status_code == 200, f"status={res.status_code}")
        check("HEAD accept-ranges", res.headers.get("accept-ranges") == "bytes",
              f"accept-ranges={res.headers.get('accept-ranges')!r}")
        check("HEAD content-length", res.headers.get("content-length") == str(len(payload)),
              f"content-length={res.headers.get('content-length')!r}")
        check("HEAD empty body", res.content == b"", f"len={len(res.content)}")

        res = client.get("/video/mp4", params={"path": str(runtime_mp4)})
        check("runtime root serves 200", res.status_code == 200,
              f"status={res.status_code} body={res.text[:200]}")
        check("runtime root accept-ranges", res.headers.get("accept-ranges") == "bytes",
              f"accept-ranges={res.headers.get('accept-ranges')!r}")

        traversal = str(videos / ".." / "evil" / "job" / "frames.mp4")
        res = client.get("/video/mp4", params={"path": traversal})
        check("traversal rejected 400", res.status_code == 400, f"status={res.status_code}")
        check("traversal detail", res.json().get("detail") == "invalid_video_path", res.text[:200])

        res = client.get("/video/mp4", params={"path": str(outside_mp4)})
        check("outside root rejected 400", res.status_code == 400, f"status={res.status_code}")
        check("outside root detail", res.json().get("detail") == "invalid_video_path", res.text[:200])

        res = client.get("/video/mp4", params={"path": str(wrong_name)})
        check("non frames.mp4 rejected 400", res.status_code == 400, f"status={res.status_code}")
        check("non frames.mp4 detail", res.json().get("detail") == "invalid_video_path", res.text[:200])

        res = client.get("/video/mp4", params={"path": "relative/job/frames.mp4"})
        check("relative path rejected 400", res.status_code == 400, f"status={res.status_code}")

        res = client.get("/video/mp4", params={"path": str(missing_dir / "frames.mp4")})
        check("missing file 404", res.status_code == 404, f"status={res.status_code}")
        check("missing file detail", res.json().get("detail") == "no_video", res.text[:200])

    if failures:
        print(f"test_shelf_media: {len(failures)} failure(s)")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("test_shelf_media: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
