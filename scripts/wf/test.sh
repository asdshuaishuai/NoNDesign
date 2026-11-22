#!/usr/bin/env bash
# 门禁：Flutter 全量测试。
#
# 2026-11-18（批次 15）：Python 服务端已整体退役——server/、.venv 以及
# scripts/wf/test_*.py 里的 Python 回归锚点全部删除。本脚本不再循环任何
# Python 测试，也不再要求 .venv；Dart/Flutter 测试是唯一的运行时门禁。
#
# 仍保留的 Python 文件只是**开发期同步/黄金对照工具**（sync_engine.py /
# sync_models.py / video_golden_check.py），不参与应用运行时，也不在这个
# 门禁里执行。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

cd "$ROOT/app" || exit 1
export PATH="$HOME/.flutter_sdk/bin:$PATH"
exec flutter test
