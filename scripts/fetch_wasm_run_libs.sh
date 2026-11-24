#!/usr/bin/env bash
# Fetch / verify the prebuilt wasm_run native libraries.
#
# Why this exists
# ---------------
# `wasm_run` ships its native executor (wasmtime on desktop/Android, wasmi on
# iOS) as prebuilt dynamic libraries and its stock build hook downloads them
# from GitHub at build time (`BuildModeEnum.fetch`). That makes builds depend
# on the network and on a GitHub release that can move. This project vendors
# the libraries instead and uses a local copy hook
# (`third_party/wasm_run/hook/build.dart`), so `flutter build` works offline
# and every binary is pinned by sha256.
#
# The sha256 table below is a frozen copy of the `assetsSha256` map in
# wasm_run 0.2.0+2's `hook/build.dart`. `--check` compares the vendored files
# against it, and — when the hosted package is present in the pub cache — also
# compares the frozen table itself against the package, so bumping wasm_run
# fails loudly until this file is refreshed.
#
# Usage
# -----
#   bash scripts/fetch_wasm_run_libs.sh            # download every missing lib
#   bash scripts/fetch_wasm_run_libs.sh --force     # re-download everything
#   bash scripts/fetch_wasm_run_libs.sh --check     # verify vendored files + drift
#   bash scripts/fetch_wasm_run_libs.sh --target aarch64-apple-darwin
#   bash scripts/fetch_wasm_run_libs.sh --list
#
# Exit codes: 0 ok, 1 verification/download failure, 2 usage error.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBS_DIR="$ROOT/third_party/wasm_run/libs"
UPSTREAM_ASSETS="$ROOT/third_party/wasm_run/upstream-assets.json"
PKG_VERSION="0.2.0+2"
RELEASE_TAG="wasm_run-v0.2.0"
RELEASE_BASE="https://github.com/juancastillo0/wasm_run/releases/download/${RELEASE_TAG}/"

# rust-target:sha256 — frozen from wasm_run 0.2.0+2 hook/build.dart.
# Keep this list identical to upstream's assetsSha256 map, EXCEPT for the
# entries in LOCAL_OVERRIDES below.
#
# LOCAL_OVERRIDES（2026-11-19 / 2026-11-23）：上游 release 的 **Windows x64 与
# Linux x86_64** 资产都是 wasmi 后端——没有 SIMD，编译不了本应用的引擎 wasm
# （`SIMD support is not enabled`，是两边兜底引擎起不来的根因；macOS 资产才是
# upstream wasmtime）。这两个条目改为**自建** wasmtime 后端的固定产物：源
# wasm_run main@23e36bdf（FRB v2，与 vendored Dart 侧多包绑定配对）。Windows
# 由 .github/workflows/desktop-release.yml 的 windows-engine-dll job 构建
# （CI 已实证 43/43 引擎冒烟全过）；Linux x86_64 于 2026-11-23 按同一源码/命令
# 本地构建（wasmtime 14.0.4 + 原生 Cranelift，engine_host_test +
# engine_contract_test 42/42 全绿）。字节与 sha256 固化在
# third_party/wasm_run/libs/。更新它 = 换源码 commit 重跑构建再回填。
# aarch64-pc-windows-msvc / aarch64-unknown-linux-gnu 仍是上游 wasmi 资产
# （ARM64 未覆盖，已知缺口；x64 是实际用户面）。
LOCAL_OVERRIDES="\
wasm_run_dart-dynamic-x86_64-pc-windows-msvc
wasm_run_dart-dynamic-x86_64-unknown-linux-gnu
"
ASSETS="\
wasm_run_dart-dynamic-aarch64-apple-ios:afb7ed40a7b19b496bf568d42121deddf6263cb1b0a52ec067c1aca6edb93145
wasm_run_dart-dynamic-aarch64-apple-ios-sim:9484c9a60234ffe5cec88d2d438ebfc8a483c6841324273c35aa39e1f6e74e5f
wasm_run_dart-dynamic-x86_64-apple-ios:c59128e7431dcb0ce0315e358acdb61ab74b8988d593bcc10b324fcc1cd93306
wasm_run_dart-dynamic-x86_64-linux-android:5a95b4529715b5ed33e881b5fd4009050025e653f9d01f4c8b5e6a9c6f6e5f19
wasm_run_dart-dynamic-i686-linux-android:1447b88b9e5fd5d4e95a8218519037152fb1ebd13fbc11673a16cbfd57e500f8
wasm_run_dart-dynamic-armv7-linux-androideabi:0f72f5e5e5ccb26c92504e79c9be019192be64de885bbbb90ba9d0de11306ede
wasm_run_dart-dynamic-aarch64-linux-android:a81fae4074d0702bc9ff18b8de6b3ea5947ca8c8cef68db976460feae0024506
wasm_run_dart-dynamic-aarch64-apple-darwin:1654553b0782eca999cd5ce3ae9610d5f338e27fcb82a5856e0cdf67acf1b2d9
wasm_run_dart-dynamic-x86_64-apple-darwin:aa7cfd700e79815c3f04485c8ebb723751c02fb97f27eede1d1270ab3f5829db
wasm_run_dart-dynamic-armv7-unknown-linux-gnueabihf:c5acb2bacb78a397b10d8f5b5afe8e30705395569a625683888c017a967210ce
wasm_run_dart-dynamic-aarch64-unknown-linux-gnu:7b292f2e2ed7edae34de22c8813ac453830e63450b9d1bd2d277f389379964ee
wasm_run_dart-dynamic-riscv64gc-unknown-linux-gnu:78255e9397080a62f8cfa55d685c26445845ec071943ffd6033205f7f9c02da9
wasm_run_dart-dynamic-x86_64-unknown-linux-gnu:617738d6a09c71c4ec707e093720610d8d98c4e1612633ae61a7a1b5410623e2
wasm_run_dart-dynamic-x86_64-pc-windows-msvc:07d75e175eb2098457f9258f241b4001ff981fa74a7d966b4b952e468ac9678b
wasm_run_dart-dynamic-aarch64-pc-windows-msvc:9998fd1553f672a5e81c3771290a65e8138e57e997133f8d3c88fbbb8f15ad61
"

die() { echo "error: $*" >&2; exit 1; }
usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

asset_names() { printf '%s\n' "$ASSETS" | sed '/^$/d' | cut -d: -f1; }
asset_hash() { printf '%s\n' "$ASSETS" | awk -F: -v a="$1" '$1==a{print $2}'; }
asset_target() { printf '%s' "${1#wasm_run_dart-dynamic-}"; }

# Compare the frozen table with the hosted package's hook, when it is cached.
# A mismatch means wasm_run was bumped/patched upstream: refresh ASSETS above
# and third_party/wasm_run/upstream-assets.json together.
check_upstream_drift() {
  local hook
  hook="$(find "${PUB_CACHE:-$HOME/.pub-cache}/hosted/pub.dev" -maxdepth 3 \
    -path "*wasm_run-${PKG_VERSION}/hook/build.dart" 2>/dev/null | head -1)"
  if [ -z "$hook" ]; then
    echo "  · upstream package wasm_run-${PKG_VERSION} not in pub cache; skipping drift check"
    return 0
  fi
  local drift=0
  while IFS=: read -r name hash; do
    [ -n "$name" ] || continue
    # 自建条目（LOCAL_OVERRIDES）不与上游 hook 对表：哈希本来就不同。
    if printf '%s\n' "$LOCAL_OVERRIDES" | grep -qx "$name"; then
      echo "  · ${name} 是自建条目（LOCAL_OVERRIDES），跳过上游漂移对表"
      continue
    fi
    if ! grep -q "$name" "$hook"; then
      echo "  ✗ ${name} is missing from the upstream hook" >&2
      drift=1
      continue
    fi
    if ! grep -A2 "$name" "$hook" | grep -q "$hash"; then
      echo "  ✗ ${name} sha256 differs from the upstream hook" >&2
      drift=1
    fi
  done <<< "$ASSETS"
  if [ "$drift" -ne 0 ]; then
    die "vendored sha256 table drifted from ${hook}; update this script before building"
  fi
  echo "  ✓ sha256 table matches ${hook}"
}

write_manifest() {
  mkdir -p "$(dirname "$UPSTREAM_ASSETS")"
  {
    echo "{"
    echo "  \"package\": \"wasm_run\","
    echo "  \"version\": \"${PKG_VERSION}\","
    echo "  \"release_base\": \"${RELEASE_BASE}\","
    echo "  \"note\": \"Frozen copy of wasm_run ${PKG_VERSION} hook/build.dart assetsSha256. Verified by scripts/fetch_wasm_run_libs.sh --check. EXCEPTION: x86_64-pc-windows-msvc is a LOCAL BUILD (wasmtime 50 + pulley interpreter backend, wasm_run main@23e36bdf + NoNDesign trap-transport patch; upstream release asset is wasmi without SIMD and cannot run this app's engine; native cranelift traps abort cdylib hosts on Windows — pulley interpreter returns traps as plain Rust errors) — see LOCAL_OVERRIDES in scripts/fetch_wasm_run_libs.sh.\","
    echo "  \"assets\": {"
    local first=1
    while IFS=: read -r name hash; do
      [ -n "$name" ] || continue
      if [ "$first" -eq 1 ]; then first=0; else echo ","; fi
      printf '    "%s": "%s"' "$name" "$hash"
    done <<< "$ASSETS"
    echo ""
    echo "  }"
    echo "}"
  } > "$UPSTREAM_ASSETS"
}

verify_one() {
  local name="$1" expected="$2" path="$LIBS_DIR/$1"
  if [ ! -f "$path" ]; then
    echo "  ✗ missing $name"
    return 1
  fi
  local actual
  actual="$(sha256_of "$path")"
  if [ "$actual" != "$expected" ]; then
    echo "  ✗ $name sha256 mismatch"
    echo "      expected $expected"
    echo "      actual   $actual"
    return 1
  fi
  echo "  ✓ $name"
  return 0
}

cmd_check() {
  echo "[wasm-libs] checking vendored wasm_run ${PKG_VERSION} libraries"
  [ -d "$LIBS_DIR" ] || die "missing $LIBS_DIR (run this script without --check first)"
  local failed=0
  while IFS=: read -r name hash; do
    [ -n "$name" ] || continue
    verify_one "$name" "$hash" || failed=1
  done <<< "$ASSETS"
  # Manifest must exist and describe exactly the same table.
  [ -f "$UPSTREAM_ASSETS" ] || { echo "  ✗ missing $UPSTREAM_ASSETS" >&2; failed=1; }
  if [ -f "$UPSTREAM_ASSETS" ]; then
    while IFS=: read -r name hash; do
      [ -n "$name" ] || continue
      grep -q "\"$name\": \"$hash\"" "$UPSTREAM_ASSETS" || {
        echo "  ✗ manifest row out of date: $name" >&2
        failed=1
      }
    done <<< "$ASSETS"
  fi
  check_upstream_drift || failed=1
  if [ "$failed" -ne 0 ]; then
    echo "[wasm-libs] FAILED" >&2
    exit 1
  fi
  echo "[wasm-libs] ok: $(asset_names | wc -l | tr -d ' ') libraries pinned"
}

fetch_one() {
  local name="$1" hash="$2" path="$LIBS_DIR/$1"
  local url="${RELEASE_BASE}${name}"
  local tmp="${path}.download"
  mkdir -p "$LIBS_DIR"
  echo "  ↓ $name"
  if ! curl -fsSL --retry 3 --retry-delay 2 --max-time 180 -o "$tmp" "$url"; then
    rm -f "$tmp"
    echo "  ✗ download failed: $url" >&2
    return 1
  fi
  local actual
  actual="$(sha256_of "$tmp")"
  if [ "$actual" != "$hash" ]; then
    rm -f "$tmp"
    echo "  ✗ $name sha256 mismatch after download" >&2
    echo "      expected $hash" >&2
    echo "      actual   $actual" >&2
    return 1
  fi
  mv -f "$tmp" "$path"
  echo "  ✓ $name"
}

cmd_fetch() {
  local force="$1" only="$2"
  mkdir -p "$LIBS_DIR"
  write_manifest
  local failed=0
  while IFS=: read -r name hash; do
    [ -n "$name" ] || continue
    if [ -n "$only" ] && [ "$(asset_target "$name")" != "$only" ]; then
      continue
    fi
    local path="$LIBS_DIR/$name"
    if [ "$force" -eq 0 ] && [ -f "$path" ] && [ "$(sha256_of "$path")" = "$hash" ]; then
      echo "  · $name already vendored"
      continue
    fi
    # 自建条目没有上游下载源：URL 上的资产是 wasmi（无 SIMD），拉下来也过
    # 不了哈希校验。明确指路 CI job。
    if printf '%s\n' "$LOCAL_OVERRIDES" | grep -qx "$name"; then
      echo "  ✗ $name 是自建条目（LOCAL_OVERRIDES），上游没有对应资产" >&2
      echo "      Windows：跑 .github/workflows/desktop-release.yml 的" >&2
      echo "      windows-engine-dll job（wasm_run main@23e36bdf +" >&2
      echo "      config_api.sh wasmtime），下载 artifact 回填；" >&2
      echo "      Linux：同一 commit 跑 bash scripts/config_api.sh wasmtime &&" >&2
      echo "      cargo build --release -p wasm_run_dart，产物回填" >&2
      echo "      third_party/wasm_run/libs/$name 并更新本表 sha256。" >&2
      failed=1
      continue
    fi
    fetch_one "$name" "$hash" || failed=1
  done <<< "$ASSETS"
  [ "$failed" -eq 0 ] || die "some libraries could not be fetched"
  echo "[wasm-libs] ok"
}

MODE="fetch"
FORCE=0
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE="check" ;;
    --force) FORCE=1 ;;
    --target) shift; [ $# -gt 0 ] || usage; ONLY="$1" ;;
    --list) asset_names; exit 0 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
  shift
done

if [ "$MODE" = "check" ]; then
  cmd_check
else
  cmd_fetch "$FORCE" "$ONLY"
fi
