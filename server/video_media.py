"""艺术架视频媒体面：把 mp4 产物作为可 seek 的 HTTP 资源 serve 给播放面。

端点：``GET /video/mp4?path=<绝对路径>``

归属：shelf 独占模块，只被 nonapp 路由层在 main.py 里挂载
（``app.include_router(video_media.router)``）。不直接写进 main.py 的
``@app.get`` 面——视频播放是艺术架的消费方，与引擎 / agent 解耦。

**白名单双根（缺一即「持久化失败的产物永远打不开」）**：
- ``VIDEOS_ROOT``        ~/Documents/NoNDesign/videos —— render done 时
  ``_persist_video_mp4`` 落到 ``videos/<job>/frames.mp4`` 的持久产物；
- ``VIDEO_RUNTIME_ROOT`` ~/Documents/NoNDesign/video  —— job 中间目录：复制
  到持久目录失败时 ``_persist_video_mp4`` 回退返回 ``video/<job>/frames.mp4``
  （server/main.py 的 `return str(mp4)` 分支），只认 videos/ 会让这批产物
  永远打不开。该目录受容量轮换管辖（终态 job 会被清理），所以过期 404 是
  合法语义。

形状纪律：只接受 ``<root>/<job>/frames.mp4`` 这一种深度。``job`` 段不得为
``.``/``..``、不得含路径分隔符；越界一律 400 ``invalid_video_path``，
白名单内文件缺失 404 ``no_video``。
"""

from __future__ import annotations

from pathlib import Path

from fastapi import APIRouter, HTTPException
from fastapi.responses import FileResponse

router = APIRouter()

VIDEOS_ROOT = Path.home() / "Documents" / "NoNDesign" / "videos"
VIDEO_RUNTIME_ROOT = Path.home() / "Documents" / "NoNDesign" / "video"

_MP4_NAME = "frames.mp4"


def _roots() -> set[Path]:
    """resolve 后的白名单根（每次读模块常量——测试可整根替换）。"""
    return {VIDEOS_ROOT.resolve(), VIDEO_RUNTIME_ROOT.resolve()}


def _resolve_video(path: str) -> Path:
    raw = Path(path)
    if not raw.is_absolute() or raw.name != _MP4_NAME:
        raise HTTPException(status_code=400, detail="invalid_video_path")
    job = raw.parent.name
    # 原始（未 resolve）路径的 job 段先过一遍：`..` 在这里就该被挡，
    # 而不是靠 resolve 归一到别处之后再判（那时形状可能已合法）。
    if job in ("", ".", "..") or "/" in job or "\\" in job:
        raise HTTPException(status_code=400, detail="invalid_video_path")
    resolved = raw.resolve()
    if resolved.name != _MP4_NAME:
        raise HTTPException(status_code=400, detail="invalid_video_path")
    # 深度恰为 <root>/<job>/frames.mp4：job 的父目录必须精确等于白名单根
    # （resolve 后比较——符号链接与 `videos/../..` 都在这里落地为越界）。
    if resolved.parent.parent not in _roots():
        raise HTTPException(status_code=400, detail="invalid_video_path")
    if not resolved.is_file():
        raise HTTPException(status_code=404, detail="no_video")
    return resolved


@router.api_route("/video/mp4", methods=["GET", "HEAD"])
async def video_mp4(path: str) -> FileResponse:
    """serve 单个 mp4 产物（GET 播放 / HEAD 探测）。

    Starlette 1.10.0 的 FileResponse 自带 ``accept-ranges: bytes`` 与 Range /
    206 处理，WebView 的播放与拖动进度条依赖它（不要改成 PlainTextResponse /
    手工 read_bytes——会把 seek 变成整文件重下）。HEAD 走
    ``send_header_only``（FileResponse.__call__），媒体探活/门禁脚本用它。
    """
    return FileResponse(_resolve_video(path), media_type="video/mp4")
