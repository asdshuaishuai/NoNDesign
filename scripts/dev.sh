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
exec flutter run -d macos "$@"
