#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ ! -d .venv ]; then
  python3 -m venv .venv
fi
.venv/bin/pip install -q -r server/requirements.txt

# dev 跑法先对齐引擎：ENGINE_LOCAL 在场 → 本地构建（moonviz-dev）；缺省 → 校验现存。
.venv/bin/python scripts/sync_engine.py

cd app
# --profile：AOT + 插桩（真实手感 + 可用 DevTools 采样）；--release：完全 AOT。
# debug（默认）是 JIT + 断言 + debug 绘制税，帧成本高一个量级——别拿 debug 模式评价流畅度。
for arg in "$@"; do
  case "$arg" in
    --profile) shift_args+=(--profile) ;;
    --release) shift_args+=(--release) ;;
    *) shift_args+=("$arg") ;;
  esac
done
exec flutter run -d macos "${shift_args[@]}"
