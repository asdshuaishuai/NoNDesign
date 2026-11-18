#!/usr/bin/env bash
# 桌面端开发启动（无 Python 运行时、无本地服务）。
#
# 只做两件事：
#   1) 用仓库自带的 Python 开发工具校验/同步引擎资产（sync_engine.py 是
#      开发期工具，不会进入应用运行时；缺省用系统 python3，不建 venv）。
#   2) 启动 Flutter（默认 debug；--profile / --release 原样透传）。
set -euo pipefail
cd "$(dirname "$0")/.."

# dev 跑法先对齐引擎：ENGINE_LOCAL 在场 → 本地构建（moonviz-dev）；缺省 → 校验现存。
python3 scripts/sync_engine.py

cd app
# --profile：AOT + 插桩（真实手感 + 可用 DevTools 采样）；--release：完全 AOT。
# debug（默认）是 JIT + 断言 + debug 绘制税，帧成本高一个量级——别拿 debug 模式评价流畅度。
shift_args=()
for arg in "$@"; do
  case "$arg" in
    --profile) shift_args+=(--profile) ;;
    --release) shift_args+=(--release) ;;
    *) shift_args+=("$arg") ;;
  esac
done
# bash 3.2 + set -u：空数组展开也必须带默认值。
exec flutter run -d macos ${shift_args[@]+"${shift_args[@]}"}
