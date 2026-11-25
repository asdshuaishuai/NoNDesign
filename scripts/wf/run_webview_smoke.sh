#!/usr/bin/env bash
# 真 WebView 冒烟：在 Linux 桌面（WebKitGTK / webview_all）里跑
# `integration_test/webview_pages_test.dart`，覆盖音乐播放页、3D 视频预览页
# 与 3D 视口控制（__non3d_view / __non3d_grid）三条真实页面。
#
# 用法：
#   scripts/wf/run_webview_smoke.sh                  # Linux 桌面（有完整系统库）
#   scripts/wf/run_webview_smoke.sh 2>&1 | tail -40  # 只关注测试输出
#
# 容器环境（本机 linglong 容器没有 /usr/lib 的 WebKitGTK 开发/运行文件）：
# 宿主 rootfs 挂在 /run/host/rootfs 下，而 WebKitGTK 把库路径硬编码在
# /usr/lib/x86_64-linux-gnu/webkit2gtk-4.1，因此需要在用户命名空间里做一次
# bind mount 再跑（脚本会自动检测并 re-exec，不需要手工 unshare）。
#
# 需要：DISPLAY + XAUTHORITY（真机桌面或 X 转发）、Linux 构建工具链。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# 容器内自动进入用户命名空间并挂宿主库目录（幂等：只做一次）。
if [ "${NAN_WEBVIEW_SMOKE_IN_NS:-}" != "1" ] \
   && [ -d /run/host/rootfs/usr/lib/x86_64-linux-gnu ] \
   && [ ! -d /usr/lib/x86_64-linux-gnu/webkit2gtk-4.1 ]; then
  exec unshare -rm env NAN_WEBVIEW_SMOKE_IN_NS=1 bash -c \
    'mount --bind /run/host/rootfs/usr/lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu \
       && exec "$0" "$@"' "${BASH_SOURCE[0]}" "$@"
fi

cd "$ROOT/app"

# 本地开发桥（不随仓库提交、不存在时跳过）：容器里 ninja/pkg-config/clang
# 与若干系统库来自宿主 rootfs 的本地副本，位置由开发机自己的 README 约定。
if [ -d "${HOME}/.local/nan-dev/bin" ]; then
  export PATH="${HOME}/.local/nan-dev/bin:${PATH}"
fi
if [ -d "${HOME}/.local/dd-sysroot/usr/lib/x86_64-linux-gnu" ]; then
  export LD_LIBRARY_PATH="${HOME}/.local/dd-sysroot/usr/lib/x86_64-linux-gnu:${HOME}/.local/nan-dev/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
fi

# WebKitGTK 在容器/无沙箱权限时默认关闭 Web 进程沙箱；桌面有正常权限时该变量无害。
export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS="${WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS:-1}"

exec flutter test integration_test/webview_pages_test.dart -d linux "$@"
