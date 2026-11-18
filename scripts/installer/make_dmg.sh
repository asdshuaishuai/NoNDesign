#!/usr/bin/env bash
# NaN macOS 安装包（.dmg）构建脚本。
#
# 产物：dist/NaN-<版本>-macos-<架构>.dmg，卷内包含：
#   - NaN.app（直接可拖走的应用本体）
#   - Applications 拖拽链接（拖进系统「应用程序」目录）
#   - 卷标 "NaN <版本>"
#   - 卷图标（从 app 内的 1024 图标生成 .VolumeIcon.icns）
#
# 签名：ad-hoc（codesign --force --deep -s -）。仓库没有 Apple 开发者证书，
# 也不做公证，所以首次打开需要右键 → 打开。签名失败只给可见告警，不阻断打包。
#
# 用法（在仓库根目录执行）：
#   bash scripts/installer/make_dmg.sh
#   bash scripts/installer/make_dmg.sh --app path/to/NaN.app --version 0.1.0 --out dist
#   bash scripts/installer/make_dmg.sh --skip-sign --skip-icon
#
# 只能跑在 macOS 上（依赖 ditto / hdiutil / codesign / sips / iconutil / SetFile）。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_PATH="$ROOT_DIR/app/build/macos/Build/Products/Release/NaN.app"
OUT_DIR="$ROOT_DIR/dist"
ARCH="arm64"
VERSION=""
VOLUME_NAME=""
ICON_SRC="$ROOT_DIR/app/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png"
DO_SIGN=1
DO_ICON=1

usage() {
  cat <<'EOF'
用法: bash scripts/installer/make_dmg.sh [选项]

  --app <NaN.app>     应用包路径（默认 app/build/macos/Build/Products/Release/NaN.app）
  --out <dir>         输出目录（默认 dist）
  --version <x.y.z>   版本号（默认读取仓库根 VERSION）
  --arch <arch>       文件名里的架构标识（默认 arm64）
  --volume-name <名>  DMG 卷标（默认 "NaN <版本>"）
  --icon <png>        卷图标源图（默认 app 的 1024 应用图标）
  --skip-sign         不做 ad-hoc 签名，直接用构建时的签名
  --skip-icon         不生成卷图标
  -h, --help          显示本帮助
EOF
}

need_value() {
  # $1 = 选项名；$2 = 值（可能未设置）
  if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
    echo "选项 $1 需要一个值" >&2
    usage >&2
    exit 2
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app)
      need_value "$1" "${2:-}"
      APP_PATH="$2"
      shift 2
      ;;
    --out)
      need_value "$1" "${2:-}"
      OUT_DIR="$2"
      shift 2
      ;;
    --version)
      need_value "$1" "${2:-}"
      VERSION="$2"
      shift 2
      ;;
    --arch)
      need_value "$1" "${2:-}"
      ARCH="$2"
      shift 2
      ;;
    --volume-name)
      need_value "$1" "${2:-}"
      VOLUME_NAME="$2"
      shift 2
      ;;
    --icon)
      need_value "$1" "${2:-}"
      ICON_SRC="$2"
      shift 2
      ;;
    --skip-sign)
      DO_SIGN=0
      shift
      ;;
    --skip-icon)
      DO_ICON=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$(uname -s)" != "Darwin" ]; then
  echo "本脚本只能在 macOS 上运行（当前系统: $(uname -s)）" >&2
  exit 2
fi
for tool in ditto hdiutil codesign; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "缺少命令: $tool" >&2
    exit 2
  fi
done

if [ -z "$VERSION" ]; then
  VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION" 2>/dev/null || true)"
fi
if [ -z "$VERSION" ]; then
  echo "无法确定版本号：请用 --version 指定，或在仓库根提供 VERSION 文件" >&2
  exit 2
fi
if [ -z "$VOLUME_NAME" ]; then
  VOLUME_NAME="NaN $VERSION"
fi

DMG_PATH="$OUT_DIR/NaN-${VERSION}-macos-${ARCH}.dmg"

echo "==> NaN macOS 安装包"
echo "    应用包: $APP_PATH"
echo "    版本:   $VERSION"
echo "    架构:   $ARCH"
echo "    输出:   $DMG_PATH"

if [ ! -d "$APP_PATH" ]; then
  echo "::error::找不到应用包: $APP_PATH" >&2
  echo "--- 实际构建目录（便于排查）---" >&2
  for dir in \
    "$ROOT_DIR/app/build/macos/Build/Products/Release" \
    "$ROOT_DIR/app/build/macos/Build/Products" \
    "$ROOT_DIR/app/build/macos"; do
    if [ -d "$dir" ]; then
      echo "[$dir]" >&2
      ls -la "$dir" >&2 || true
    fi
  done
  exit 1
fi
if [ ! -x "$APP_PATH/Contents/MacOS/NaN" ]; then
  echo "::error::$APP_PATH 不是完整的 .app（缺少 Contents/MacOS/NaN）" >&2
  ls -la "$APP_PATH/Contents" >&2 || true
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nan-dmg.XXXXXX")"
STAGE_DIR="$WORK_DIR/stage"
MOUNT_DIR="$WORK_DIR/mnt"
RW_DMG="$WORK_DIR/NaN-${VERSION}-macos-${ARCH}.rw.dmg"
MOUNTED=0

cleanup() {
  set +e
  if [ "$MOUNTED" = "1" ]; then
    hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || \
      hdiutil detach "$MOUNT_DIR" -force -quiet >/dev/null 2>&1
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$OUT_DIR" "$STAGE_DIR"

echo "==> 复制应用包到临时目录"
ditto "$APP_PATH" "$STAGE_DIR/NaN.app"
ln -s /Applications "$STAGE_DIR/Applications"

if [ "$DO_SIGN" = "1" ]; then
  echo "==> ad-hoc 签名（无开发者证书，不公证）"
  if codesign --force --deep --sign - "$STAGE_DIR/NaN.app" 2>&1; then
    echo "    签名完成"
  else
    echo "::warning::ad-hoc 签名失败，回退到 Flutter 构建时的原始签名（首次打开仍需右键 → 打开）"
    rm -rf "$STAGE_DIR/NaN.app"
    ditto "$APP_PATH" "$STAGE_DIR/NaN.app"
  fi
  echo "--- 签名信息 ---"
  codesign -dv "$STAGE_DIR/NaN.app" 2>&1 | sed -n '1,8p' || true
  if codesign --verify --deep --strict "$STAGE_DIR/NaN.app" 2>&1; then
    echo "    签名校验通过（ad-hoc）"
  else
    echo "::warning::签名校验未通过；用户首次打开需要右键 → 打开"
  fi
else
  echo "==> 跳过 ad-hoc 签名（--skip-sign）"
fi

if [ "$DO_ICON" = "1" ] && [ -f "$ICON_SRC" ] && \
   command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
  echo "==> 生成卷图标"
  ICONSET="$WORK_DIR/AppIcon.iconset"
  mkdir -p "$ICONSET"
  sips -z 16 16 "$ICON_SRC" --out "$ICONSET/icon_16x16.png" >/dev/null
  sips -z 32 32 "$ICON_SRC" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$ICON_SRC" --out "$ICONSET/icon_32x32.png" >/dev/null
  sips -z 64 64 "$ICON_SRC" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$ICON_SRC" --out "$ICONSET/icon_128x128.png" >/dev/null
  sips -z 256 256 "$ICON_SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$ICON_SRC" --out "$ICONSET/icon_256x256.png" >/dev/null
  sips -z 512 512 "$ICON_SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$ICON_SRC" --out "$ICONSET/icon_512x512.png" >/dev/null
  cp "$ICON_SRC" "$ICONSET/icon_512x512@2x.png"
  if iconutil -c icns "$ICONSET" -o "$STAGE_DIR/.VolumeIcon.icns" 2>&1; then
    echo "    卷图标文件已写入"
  else
    echo "::warning::卷图标生成失败，继续打包（应用图标不受影响）"
  fi
else
  echo "==> 跳过卷图标（缺少图标源或 sips/iconutil）"
fi

echo "==> 生成 DMG（卷标: ${VOLUME_NAME}）"
# 先做可读写镜像：卷图标除了 .VolumeIcon.icns 文件，还需要卷根带有
# 「自定义图标」Finder 标记；只读压缩镜像无法再改这个标记。
rm -f "$DMG_PATH" "$RW_DMG"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDRW \
  "$RW_DMG"

if [ -f "$STAGE_DIR/.VolumeIcon.icns" ] && command -v SetFile >/dev/null 2>&1; then
  echo "==> 写入卷图标标记"
  mkdir -p "$MOUNT_DIR"
  hdiutil attach -nobrowse -mountpoint "$MOUNT_DIR" "$RW_DMG" >/dev/null
  MOUNTED=1
  if SetFile -a C "$MOUNT_DIR"; then
    echo "    卷根自定义图标标记已写入"
  else
    echo "::warning::卷根自定义图标标记写入失败，卷图标可能不显示"
  fi
  hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || \
    hdiutil detach "$MOUNT_DIR" -force -quiet >/dev/null 2>&1
  MOUNTED=0
else
  echo "::warning::没有卷图标文件或缺少 SetFile，跳过卷图标标记（安装包不受影响）"
fi

echo "==> 压缩为只读 DMG"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"

echo "==> 校验 DMG"
hdiutil verify "$DMG_PATH"

echo "==> 挂载检查卷内结构"
mkdir -p "$MOUNT_DIR"
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_DIR" "$DMG_PATH" >/dev/null
MOUNTED=1
if [ ! -d "$MOUNT_DIR/NaN.app" ]; then
  echo "::error::DMG 里没有 NaN.app" >&2
  ls -la "$MOUNT_DIR" >&2 || true
  exit 1
fi
if [ ! -L "$MOUNT_DIR/Applications" ]; then
  echo "::error::DMG 里没有 Applications 拖拽链接" >&2
  ls -la "$MOUNT_DIR" >&2 || true
  exit 1
fi
echo "    NaN.app + Applications 链接都在"
if command -v GetFileInfo >/dev/null 2>&1; then
  vol_attrs="$(GetFileInfo -a "$MOUNT_DIR" 2>/dev/null || true)"
  case "$vol_attrs" in
    *C*) echo "    卷图标标记存在" ;;
    *) echo "::warning::卷根没有自定义图标标记（attrs=${vol_attrs:-空}），卷图标可能不显示" ;;
  esac
fi
if codesign --verify --deep --strict "$MOUNT_DIR/NaN.app" 2>&1; then
  echo "    卷内应用签名校验通过"
else
  echo "::warning::卷内应用签名校验未通过（ad-hoc 签名属预期，首次打开需右键 → 打开）"
fi
hdiutil detach "$MOUNT_DIR" -quiet >/dev/null
MOUNTED=0

echo "==> 完成"
ls -lh "$DMG_PATH"
if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$DMG_PATH"
fi
