#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/../../app" || exit 1
export PATH="$HOME/.flutter_sdk/bin:$PATH"
exec flutter test
