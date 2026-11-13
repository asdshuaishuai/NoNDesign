#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/../.." || exit 1
exec .venv/bin/python -m compileall -q server
