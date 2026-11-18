#!/usr/bin/env bash
# Gate: Android 构建与安装（批次 00 的 N3 判定入口）。
#
# 结论口径（2026-11-18 实测，见 docs/migration-baseline.md §5）：
#   - Gradle 9.5.0 + AGP 9.3.1 + Kotlin 2.4.20 本身**不挂起**；
#   - 真正的构建前置是 minSdk = 28（mediapipe_retrieval 的 native-assets
#     hook 硬性要求 Android 9 / API 28，Flutter 默认 24 会在装备阶段直接失败）；
#   - 设备/模拟器不是构建前置：没有设备时本脚本只构建、不安装（退出码 2）。
#
# 退出码：
#   0  构建成功且（若有设备）安装+启动成功
#   1  构建失败
#   2  构建成功，但没有可安装的设备/模拟器（不算失败，但 Android 真机验收未完成）
#   3  构建成功且有设备，但 adb install / launch 失败
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/app"
PKG="com.example.nondesign"
ACTIVITY="$PKG/.MainActivity"

export PATH="$HOME/.flutter_sdk/bin:$PATH"

if [ ! -d "$APP" ]; then
  echo "android_build.sh: missing $APP" >&2
  exit 1
fi

# Android SDK 路径：显式 ANDROID_HOME > local.properties > macOS 默认位置。
ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$ANDROID_SDK" ] && [ -f "$APP/android/local.properties" ]; then
  ANDROID_SDK="$(sed -n 's/^sdk\.dir=//p' "$APP/android/local.properties" | head -n 1)"
fi
if [ -z "$ANDROID_SDK" ] && [ -d "$HOME/Library/Android/sdk" ]; then
  ANDROID_SDK="$HOME/Library/Android/sdk"
fi
if [ -n "$ANDROID_SDK" ] && [ -d "$ANDROID_SDK/platform-tools" ]; then
  export PATH="$PATH:$ANDROID_SDK/platform-tools"
fi

cd "$APP" || exit 1
echo "== flutter build apk --debug =="
flutter build apk --debug
build_status=$?
if [ $build_status -ne 0 ]; then
  echo "android_build.sh: build failed (exit $build_status)" >&2
  exit 1
fi

APK="$APP/build/app/outputs/flutter-apk/app-debug.apk"
if [ ! -f "$APK" ]; then
  echo "android_build.sh: build reported success but $APK is missing" >&2
  exit 1
fi
echo "apk: $APK ($(du -h "$APK" | awk '{print $1}'))"

if ! command -v adb >/dev/null 2>&1; then
  echo "android_build.sh: adb not found — skip install/launch" >&2
  exit 2
fi

# 只认已就绪设备（device 状态）；offline/unauthorized 不尝试安装。
serial="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
if [ -z "$serial" ]; then
  echo "android_build.sh: no ready device/emulator — build ok, install skipped" >&2
  echo "  需要真机验收时：连设备后重跑本脚本，或先创建 AVD（SDK 需 cmdline-tools+emulator）。" >&2
  exit 2
fi

echo "== adb install -r ($serial) =="
if ! adb -s "$serial" install -r "$APK"; then
  echo "android_build.sh: adb install failed" >&2
  exit 3
fi

echo "== adb shell am start $ACTIVITY =="
if ! adb -s "$serial" shell am start -n "$ACTIVITY"; then
  echo "android_build.sh: launch failed" >&2
  exit 3
fi

echo "android_build.sh: OK ($serial)"
exit 0
