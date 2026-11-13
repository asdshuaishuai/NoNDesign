#!/usr/bin/env bash
# Gate: flutter analyze must report zero errors (infos/warnings allowed).
set -u
cd "$(dirname "$0")/../../app" || exit 1
export PATH="$HOME/.flutter_sdk/bin:$PATH"
out=$(flutter analyze --no-pub --no-fatal-infos --no-fatal-warnings 2>&1)
status=$?
echo "$out"
if [ $status -ne 0 ]; then exit $status; fi
if echo "$out" | grep -q " error • "; then exit 1; fi
exit 0
