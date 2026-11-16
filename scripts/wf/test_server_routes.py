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

    sys.path.insert(0, str(MAIN.parent))
    import main as server_main  # noqa: E402  (import registers all routes)

    paths = {getattr(route, "path", "") for route in server_main.app.routes}
    for path in (
        "/video/sample",
        "/video/review",
        "/video/render",
        "/video/render/status",
        "/video/frame",
        "/three/scene/{name}.js",
    ):
        if path not in paths:
            failures.append(f"missing route {path}")

    if failures:
        print("FAIL")
        for item in failures:
            print(" -", item)
        return 1
    print("server routes: all cases green")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
