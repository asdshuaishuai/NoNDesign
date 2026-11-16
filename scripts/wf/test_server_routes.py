#!/usr/bin/env python3
"""server/main.py 启动面契约（真机 404 / MIME 实证的回归锚点）。

① 入口 `if __name__ == "__main__": main()` 必须在文件末尾：视频路由定义在
   它之前，提前运行 uvicorn 会让「脚本启动路径」（桌面 App 与移动端连接所用）
   漏注册 /video/* —— iPhone 17 上视频工作台请求 /video/sample 404 的根因。
② /three/scene/*.js 必须以 application/javascript 返回：3D 预览模板用动态
   import() 加载 scene.js，text/plain 会被 WKWebView/Chromium 拒绝（iPhone 17
   实证 "'text/plain' is not a valid JavaScript MIME type for module script"）。

用法：.venv/bin/python scripts/wf/test_server_routes.py （退出码 0 = 全绿）
"""

from __future__ import annotations

import sys
from pathlib import Path

MAIN = Path(__file__).resolve().parent.parent.parent / "server" / "main.py"


def main() -> int:
    source = MAIN.read_text("utf-8")
    failures: list[str] = []

    entry = source.rindex('if __name__ == "__main__":')
    last_route = source.rindex("@app.")
    if entry < last_route:
        failures.append("entrypoint is before the last route decorator (script launch misses routes)")

    if 'media_type="application/javascript"' not in source:
        failures.append("three scene endpoint is missing application/javascript MIME")

    if "connect-src 'self'" not in source:
        failures.append("hotapp page CSP must allow same-origin SQLite bridge")

    if '"Cache-Control": "no-store"' not in source:
        failures.append("hotapp page must disable caching (hot update reload)")

    # 事件循环纪律：/health 与 /engine/ops 的 wasm 直调必须走 to_thread——
    # engine RLock 被 agent 线程持有时，事件循环直调可被阻塞至单次调用
    # 上限 30s，/health 冻结即全服务冻结（/engine/render 注释自证的不变量）。
    if "await asyncio.to_thread(engine().version_info)" not in source:
        failures.append("/health must call version_info via to_thread (event-loop freeze)")
    if "await asyncio.to_thread(engine().list_ops)" not in source:
        failures.append("/engine/ops must call list_ops via to_thread (event-loop freeze)")

    # SQLite 桥必须经应用锁（与 generate/refine/delete 串行）：无锁时
    # sqlite3.connect 会在半删目录里凭空重建 app.db，同名重建被 app_exists 卡死。
    if "hotapp.db_exec_locked" not in source:
        failures.append("/hotapp/db route must go through db_exec_locked (per-app lock)")

    sys.path.insert(0, str(MAIN.parent))
    import main as server_main  # noqa: E402  (import registers all routes)

    paths = {getattr(route, "path", "") for route in server_main.app.routes}
    # hotapp 全路由面 + 作品集两条：入口顺序漏注册（/video 404 同类缺陷）
    # 在新功能面上也必须被抓住，不能只锚 db 桥一条。
    for path in (
        "/video/sample",
        "/video/review",
        "/video/render",
        "/video/render/status",
        "/video/frame",
        "/three/scene/{name}.js",
        "/hotapp/generate",
        "/hotapp/refine",
        "/hotapp/page/{name}",
        "/hotapp/list",
        "/hotapp/delete",
        "/hotapp/db/{name}/exec",
        "/portfolio",
        "/portfolio/delete",
    ):
        if path not in paths:
            failures.append(f"missing route {path}")

    # 死路由不许回潮（2026-11-17 审查批次删除）：/project/export/3d 全仓零
    # 调用方，且 mbt 走 GET query——真实文档必撞 h11 头 16KB 上限直接 400
    # （与 /project/export/figma 留档修复的同款 bug：大 mbt 必须走 body）。
    if "/project/export/3d" in paths:
        failures.append("dead route /project/export/3d must stay removed (zero callers + mbt-in-query h11 16KB bug)")
    if "export_3d" in source or "_THREE_TEMPLATE" in source:
        failures.append("export_3d/_THREE_TEMPLATE dead code must stay removed")

    if failures:
        print("FAIL")
        for item in failures:
            print(" -", item)
        return 1
    print("server routes: all cases green")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
