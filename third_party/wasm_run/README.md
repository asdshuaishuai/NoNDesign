# Vendored wasm_run

This directory vendors the WebAssembly executor used by the in-process design
engine. **Do not edit the Dart sources by hand** unless you are re-vendoring a
new upstream release — the only intentional changes are listed below.

## Provenance

| Item | Value |
|---|---|
| Upstream | https://github.com/juancastillo0/wasm_run |
| Package | `wasm_run` 0.2.0+2 (MIT, see `LICENSE` / `CHANGELOG.md`) |
| Native assets | https://github.com/juancastillo0/wasm_run/releases/tag/wasm_run-v0.2.0 (`wasm_run_dart-dynamic-*`, 15 targets) |
| Fetch/verify | `bash scripts/fetch_wasm_run_libs.sh` / `--check` |
| Flutter plugin | `wasm_run_flutter` 0.2.0+1, vendored under `wasm_run_flutter/` |

## Intentional changes vs. upstream

1. `pubspec.yaml`
   - removed `build_rust_binaries` (it pins `hooks ^1.0.0`, incompatible with
     `mediapipe_core`'s `hooks >=2.0.0`);
   - `flutter_rust_bridge` pinned to exactly `2.12.0` (FRB refuses to run when
     the generated-code version and runtime version differ);
   - `publish_to: none`.
2. `hook/build.dart` rewritten against hooks 2.x: copies
   `libs/wasm_run_dart-dynamic-<rust-target>` into the build output and adds a
   `CodeAsset` (`DynamicLoadingBundled`). No network access.
3. Removed `bin/build_binaries.dart` and `lib/src/ffi/config_api.dart` (only
   used by the removed CLI tooling).
4. `wasm_run_flutter/ios|macos/Classes/EnforceBundling.swift` neutralised: the
   upstream stub references the FRB Rust symbols at link time, which only works
   with a statically linked library. We ship the dynamic library, so the stub
   must not reference those symbols.
5. `wasm_run_flutter/pubspec.yaml` declares `android` / `linux` / `windows` as
   Dart-only platforms (`dartPluginClass` only, no `ffiPlugin`). Upstream marks
   them `ffiPlugin` because it ships empty CMake stubs in those directories;
   this vendored copy keeps only `lib/`, `ios/` and `macos/`, so a native plugin
   declaration made Flutter's Gradle/CMake integration look for a directory that
   does not exist (Android gate: `Plugin directory does not exist:
   …/wasm_run_flutter/android`). The executor library itself is still delivered
   by the `wasm_run` hook as a `CodeAsset`, and the Dart registration
   (`WasmRunFlutterNative.registerWith`) still runs on every platform.

## Updating

See `docs/wasm-run-vendoring.md` §8. In short: bump `PKG_VERSION` /
`RELEASE_TAG` / the sha256 table in `scripts/fetch_wasm_run_libs.sh`, refresh
`lib/` from the new upstream release, keep the pubspec changes and the
custom hook, then run the script with `--force` + `--check` and the spike test.
