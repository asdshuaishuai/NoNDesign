#!/usr/bin/env bash
# frames-<ts>/ PNG 序列 → demo.mp4（ffmpeg 缺失时给安装指引）
set -euo pipefail
D="${1:-.}"; OUT="${2:-demo.mp4}"
command -v ffmpeg >/dev/null || { echo "ffmpeg 未安装：brew install ffmpeg"; exit 1; }
ffmpeg -framerate 30 -pattern_type glob -i "$D/frames-*.png" -c:v libx264 -pix_fmt yuv420p "$OUT"
echo "✓ $OUT"
