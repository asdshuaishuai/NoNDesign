"""`.nonapp` 包的四条端点（导出 / 导入 / a2ui 读取 / 应用信息）。

挂载在 server/main.py 的 `app` 上（可降级：模块缺失不阻止服务启动）：

    POST /hotapp/export          {name} → application/zip + Content-Disposition
    POST /hotapp/import          原始 zip body → 落 hotapps + 作品集登记
    GET  /hotapp/a2ui/{name}     → {ok,name,title,messages:[...]}
    GET  /hotapp/info/{name}     → {ok,name,title,renderer,exists}

导入是大体积不可信输入：**先看 Content-Length 预检（超 8MiB 直接 413，不读
body），再流式累加、超限立刻 413**——不得 `await request.body()` 一次读满
（那样恶意大方包会先占满内存才被拒）。所有失败走稳定 code（`nonapp_*` /
`app_exists:*` / `no_app:*`），端点层统一 400 原样 detail。
"""
from __future__ import annotations

from typing import Any

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import Response
from pydantic import BaseModel

import hotapp_agent as hotapp
import nonapp_agent as nonapp

router = APIRouter()


def _guard(fn, *args):
    """与 main.py::_hotapp_guard 同语义（非 app 路由不能 import main：循环依赖）。"""
    try:
        return fn(*args)
    except hotapp.HotAppError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except (OSError, ValueError) as e:
        raise HTTPException(status_code=500, detail=f"nonapp_io_error: {e}")


async def _guard_async(coro_fn, *args):
    try:
        return await coro_fn(*args)
    except hotapp.HotAppError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except (OSError, ValueError) as e:
        raise HTTPException(status_code=500, detail=f"nonapp_io_error: {e}")


class NonAppExportRequest(BaseModel):
    name: str


@router.post("/hotapp/export")
async def hotapp_export(req: NonAppExportRequest) -> Response:
    """应用 → `.nonapp`（zip bytes）。客户端必须用 POST（本端点只注册 POST）。"""
    data = _guard(nonapp.build_package, req.name)
    # name 已经过 _app_dir 白名单（ASCII 字母数字/-_），可安全进响应头。
    return Response(
        content=data,
        media_type="application/zip",
        headers={
            "Content-Disposition": f'attachment; filename="{req.name}.nonapp"',
            "Cache-Control": "no-store",
        },
    )


@router.post("/hotapp/import")
async def hotapp_import(request: Request) -> dict[str, Any]:
    """原始 zip body → 安装（atomic replace）+ 作品集登记。"""
    limit = nonapp.MAX_PACKAGE_BYTES
    declared = request.headers.get("content-length")
    if declared is not None:
        try:
            if int(declared) > limit:
                raise HTTPException(status_code=413, detail="nonapp_too_large")
        except ValueError:
            raise HTTPException(status_code=400, detail="nonapp_invalid_content_length")

    chunks: list[bytes] = []
    total = 0
    async for chunk in request.stream():
        total += len(chunk)
        if total > limit:
            # 不缓存剩余 body：读完超限立刻断开（不做 drain，避免被拖住）
            raise HTTPException(status_code=413, detail="nonapp_too_large")
        chunks.append(chunk)
    if total == 0:
        raise HTTPException(status_code=400, detail="nonapp_empty_body")

    # filename hint 只作日志：目录名唯一来源是 manifest.name。
    hint = request.query_params.get("name") or request.headers.get("x-nonapp-filename")
    return await _guard_async(nonapp.install_package, b"".join(chunks), hint)


@router.get("/hotapp/a2ui/{name}")
async def hotapp_a2ui(name: str) -> dict[str, Any]:
    return _guard(nonapp.read_a2ui, name)


@router.get("/hotapp/info/{name}")
async def hotapp_info(name: str) -> dict[str, Any]:
    return _guard(nonapp.app_info, name)
