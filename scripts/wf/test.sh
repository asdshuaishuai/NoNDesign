#!/usr/bin/env bash
# 门禁：Python 回归锚点（hotapp / 路由在场 / tool 配对消毒 / ACP 客户端 /
# write_doc 流式增量）全部先跑，任何一份红即止；最后 flutter test。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

PY="$ROOT/.venv/bin/python"
if [ ! -x "$PY" ]; then
  echo "test.sh: missing $PY" >&2
  echo "  先建环境：python3 -m venv .venv && .venv/bin/pip install -r server/requirements.txt" >&2
  exit 1
fi

for t in test_hotapp test_video_jobs test_three test_server_routes test_context_sanitize test_acp_client test_doc_delta test_engine_server_cleanup test_agent_run; do
  echo "== python scripts/wf/$t.py =="
  "$PY" "$ROOT/scripts/wf/$t.py" || exit 1
done

cd "$ROOT/app" || exit 1
export PATH="$HOME/.flutter_sdk/bin:$PATH"
exec flutter test
