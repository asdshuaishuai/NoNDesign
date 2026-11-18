# wasm_run 本地化（vendoring）与离线构建

> 批次 01 建立（2026-11-18）。本文记录：为什么 vendored、vendored 了什么、怎么校验、
> 实测证据、以及仍未验证 / 明确做不到的部分。

## 1. 结论速览

| 项 | 状态 |
|---|---|
| 宿主（macOS arm64, wasmtime 14.0.4）加载 `moonviz.wasm` 并驱动 `_in` ABI | **已实测通过**（`test/wasm_run_spike_test.dart`） |
| 15 个目标平台的预编译动态库入库（sha256 固定） | **已完成**（`bash scripts/fetch_wasm_run_libs.sh --check` 全绿） |
| 离线构建（不访问 GitHub / pub.dev） | **已实测**：macOS debug 与 iOS `--no-codesign` 均构建通过、日志零下载；wasm_run hook 只从 `third_party/wasm_run/libs/` 拷贝，sqlite3 改用系统库（见 §9/§5.4） |
| iOS 本地引擎 | **不可行（已实测）**：wasmi 0.31 不支持 SIMD，MoonViz 模块含 SIMD 指令 → iOS 只能「连接桌面」，见 §7.1 |
| Android 本地引擎 | **运行未验证，打包已可见**：`MainActivity.kt` 的类型错误修复后，工作树已有 debug APK 产物（本轮未重跑构建）；APK 内 `lib/arm64-v8a/libwasm_run_dart.so` 与 `assets/engine/moonviz.wasm` 均在位。但当前无 Android 设备/AVD，**wasmtime arm64 加载与 `_in` ABI 未在设备上跑过** |
| 移动端默认启用本地引擎 | **否**（`WasmRuntimeGate.mobileLocalEngineEnabled = false`） |

## 2. 为什么必须 vendored

`wasm_run 0.2.0+2`（pub.dev）的两个事实让直接依赖不可用：

1. **依赖冲突**：它的构建 hook 依赖 `build_rust_binaries ^0.1.0` → `hooks ^1.0.0`；
   本仓库同时依赖 `mediapipe_core 0.3.0`（`hooks >=2.0.0`）。同一份依赖解析里
   hooks 1.x 与 2.x 不能共存，`flutter pub add wasm_run_flutter:0.2.0+1` 直接求解失败
   （原话：`wasm_run_flutter >=0.2.0 is incompatible with mediapipe_core >=0.3.0`）。
2. **构建期联网**：stock hook 用 `BuildModeEnum.fetch` 从 GitHub Releases 下载
   `wasm_run_dart-dynamic-*`。CI/离线机器无法构建，且 release 资产可能被替换。

因此：把 `wasm_run` 包源码 vendored 进仓库，换成 **hooks 2.x + 本地拷贝** 的构建 hook，
预编译库也入库并按 sha256 固定。

## 3. 目录结构

```
third_party/wasm_run/                 # = wasm_run 0.2.0+2 的 Dart 源码（MIT）
  pubspec.yaml                        #   去掉 build_rust_binaries，frb 精确钉 2.12.0
  hook/build.dart                     #   自写：hooks 2.x，从 libs/ 拷贝，不联网
  lib/                                #   与上游 0.2.0+2 一致（删除了仅 CLI 用的 config_api.dart）
  libs/                               #   15 个 wasm_run_dart-dynamic-<rust-target>
  upstream-assets.json                #   上游 hook 的 sha256 表冻结副本（脚本生成/校验）
  wasm_run_flutter/                   # wasm_run_flutter 0.2.0+1 的 vendored 副本
    lib/, ios/, macos/, pubspec.yaml  #   iOS/macOS 原生桩已中和（见 §6）
scripts/fetch_wasm_run_libs.sh        # 下载 / 校验 / --check
```

`app/pubspec.yaml` 用 `dependency_overrides` 指向这两个路径；`wasm_run_flutter` 仍是
direct dependency（版本号与上游同号 `0.2.0+1`），对外 API 不变。

## 4. 构建 hook 的行为

```dart
// 伪代码（third_party/wasm_run/hook/build.dart）
target = rustTarget(input.config.code);          // iOS 模拟器 → aarch64-apple-ios-sim
src    = <packageRoot>/libs/wasm_run_dart-dynamic-<target>
dst    = <outputDirectory>/libwasm_run_dart.dylib
copy(src → dst)
output.assets.code.add(CodeAsset(
  package: 'wasm_run', name: 'src/rust/frb_generated.io.dart',
  linkMode: DynamicLoadingBundled(), file: dst))
```

- 目标缺失时直接报错并给出 `--target` 修复命令，不做静默回退；
- 可用 `hooks.user_defines.wasm_run.libsPath` 指向别处的库目录（备用，未使用）；
- 资产名沿用上游 `build_rust_binaries` 的默认值，保持 FRB/工具链一致。

## 5. 校验与实测

### 5.1 sha256 校验

```bash
$ bash scripts/fetch_wasm_run_libs.sh --check
[wasm-libs] checking vendored wasm_run 0.2.0+2 libraries
  ✓ wasm_run_dart-dynamic-aarch64-apple-ios
  …（15 行）
  ✓ sha256 table matches /Users/…/.pub-cache/hosted/pub.dev/wasm_run-0.2.0+2/hook/build.dart
[wasm-libs] ok: 15 libraries pinned
```

脚本的 sha256 表是 `wasm_run 0.2.0+2` 的 `hook/build.dart` 中 `assetsSha256` 的冻结副本；
`--check` 在 pub cache 存在该包时会**逐条比对上游 hook**，上游升级/更换资产会直接失败。

### 5.2 宿主 spike（macOS arm64）

命令：`cd app && flutter test test/wasm_run_spike_test.dart`

```
{"runtime":"wasmtime 14.0.4","engineVersion":"0.1.11",
 "nonInSessionExports":31,"inSessionExports":22,
 "emptyDocValid":true,"seedRenders":true,"specialSignaturesOk":true,
 "growSafe":true,"fuelSupported":true,"fuelPerRender":2212626,
 "coldStartMs":132.752,"p50RenderMs":0.304,"p95RenderMs":0.33,
 "peakMemoryBytes":458752,"rssBytes":231211008, ...}
```

要点：

- **导出面**：31 个非 `_in` session 导出 + 22 个 `_in` 导出，与 Python/Rust 宿主一致；
- **空文档合法**：`validate_mbt('')` → `{"ok":true,...,"artboards":[]}`；
- **种子渲染**：`render_mbt_in` 返回 `ok/render/flows/artboards`；
- **特殊签名**：`session_event_in`（arg=画板, in=spec）、`session_tap_in`（handle+f64 x/y）、
  `session_constrain_in`（arg/arg2）、`session_generate_in`（in=spec, arg=intent,
  arg2=name）、`session_apply_human_in`（op 走 **arg** 槽）全部实测可用；
- **memory.grow**：grow 1 页后重新取 `WasmMemory.view` 再做 `_in` 往返，ABI 正常；
- **fuel**：wasmtime 支持 fuel；render ≈ 2.3M、apply ≈ 2.5M、generate ≈ 136.6M
  fuel 单位 → `WasmRuntimeGate.fuelPerCallBudget = 500_000_000`（约 3.7× 余量）；
- **延迟**：p50 0.304ms / p95 0.33ms（种子文档渲染）；
- **内存**：引擎线性内存峰值 448 KiB；测试进程 RSS ≈ 231 MB（含 Flutter 测试宿主）。

### 5.3 离线构建实测（2026-11-18）

```bash
cd app
flutter build macos --debug --no-pub     # ✓ Built …/NoNDesign.app
flutter build ios --no-codesign --no-pub # ✓ Built build/ios/iphoneos/Runner.app (86.4MB)
```

产物核对：

- macOS `NoNDesign.app/Contents/Frameworks/wasm_run_dart.framework`（vendored 动态库被
  native assets 包成 framework）；
- iOS `Runner.app/Frameworks/wasm_run_dart.framework`；
- 两个产物都含 `flutter_assets/assets/engine/{moonviz.wasm,components.json,manifest.json}`；
- 两次构建日志 `grep -ic download` = **0**（唯一 "error" 字样是 Flutter 的 SPM 未来告警）。

说明：`--no-pub` 只跳过依赖解析；构建期的 native-assets hook 才是网络风险点，
它们现在要么读 `third_party/wasm_run/libs/`、要么用系统 SQLite。

### 5.4 引擎资产同步

```bash
$ python3 scripts/sync_engine.py --check
[sync_engine] check ok: app/assets/engine matches manifest (805952 B · sha512-W4aOY6PyUVLHxcMc5BPKY… · 17 templates / 65 components)
```

`sync_engine.py` 现在同时写 `engine/` 与 `app/assets/engine/`；`--check` 校验两边的
sha512/bytes、manifest 字节相等、components 计数与 id 唯一性，且不导入 Python 引擎宿主。
`app/test/engine_asset_drift_test.dart` 是第二道锁：当 `ENGINE_LOCAL` 指向的本地构建
哈希与 manifest 不一致（即重建后忘记同步）时**必红**。

## 6. 为什么 wasm_run_flutter 也要 vendored

上游 `wasm_run_flutter` 的 iOS/macOS 原生桩（`Classes/EnforceBundling.swift`）：

```swift
public func dummyMethodToEnforceBundling() -> Int64 {
  return dummy_method_to_enforce_bundling()   // FRB 的 Rust 符号
}
```

它假设 Rust 库以**静态库**形式链进 Pod。本项目走的是**动态库**（native assets
`DynamicLoadingBundled`），静态符号不存在，iOS 链接因此失败：

```
Error (Xcode): Undefined symbol: _wire_create_function__method__WasmRunModuleId
… Undefined symbol: _wire_get_memory_pages__method__WasmRunModuleId
Linker command failed with exit code 1
```

vendored 副本只把该桩换成不引用 Rust 符号的空函数，Dart 面（`registerWith`、
web asset loader）与 pubspec 平台声明保持不变。

## 7. 仍未验证 / 做不到

### 7.1 iOS：wasmi 0.31 不支持 SIMD（已坐实，cannot-do）

实跑 `cd app && flutter test integration_test/wasm_spike_test.dart -d <iPhone 模拟器>`：

1. 动态库加载**已打通**：Flutter native assets 把 vendored 动态库包成
   `Runner.app/Frameworks/wasm_run_dart.framework`，`WasmRunLibrary.setUp()` 经
   `ExternalLibrary.process()` 成功初始化（链接失败已由中和桩解决）；
2. 但 `compileWasmModule(moonviz.wasm)` 直接失败：

```
AnyhowException(SIMD support is not enabled (at offset 0x261))
  wasm_run/src/wasm_bindings/_wasm_interop_native.dart:38 compileWasmModule
  test/wasm_run_spike_test.dart:204 MoonVizProbe.load
```

原因：iOS 上 wasm_run 用 **wasmi 0.31**（解释器），其验证器不支持 WebAssembly SIMD；
MoonViz 的 wasm 产物包含 SIMD 指令（MoonBit 默认代码生成），`ModuleConfigWasmi`
也没有 `simd` 开关可打开。

**结论**：iOS **不能**本地跑引擎，只能「连接桌面」。`WasmRuntimeGate.mobileLocalEngineEnabled`
保持 `false`。集成测试把该错误登记为已知平台限制（`markTestSkipped` + 明确文案），
其它任何异常仍会失败。

**解除条件**（二选一，均在本仓之外）：
- 引擎提供无 SIMD 的 iOS 专用构建（上游）；或
- wasm_run 在 iOS 换成支持 SIMD 的运行时（如 wasmtime 的 iOS 构建）。

在那之前，任何「iOS 本地引擎」的说法都是不成立的。
2. **iOS 代码签名 / 真机**：`--no-codesign` 只覆盖编译链接；真机安装、签名与
   `Frameworks/` 内 `wasm_run_dart.framework` 的嵌套签名未验证（模拟器可运行）。
3. **Android**：构建侧已不再是「Gradle/AGP 环境阻断」——修复 `MainActivity.kt`
   的类型错误后可产出 debug APK，arm64 `libwasm_run_dart.so` 与引擎 wasm 均在包内。
   但**真机/模拟器运行未验证**：本机 `adb devices` 为空、无 emulator/AVD，
   wasmtime 14 在 Android arm64 上加载 `moonviz.wasm`、`_in` 槽 ABI、trap 恢复与
   内存回收都没有设备证据；`WasmRuntimeGate.mobileLocalEngineEnabled` 保持 false。
4. **wasmi 0.31 的 fuel 可中断性**：iOS 用 wasmi，`ModuleConfig.consumeFuel` 是否生效、
   单次调用能否被 fuel 打断，未在 iOS 上验证（spike 的 `fuelSupported` 会如实报告）。
5. **移动端预算结论**：见 §1，`WasmRuntimeGate.mobileLocalEngineEnabled` 保持 false。

## 8. 升级 wasm_run 的步骤

1. 改 `scripts/fetch_wasm_run_libs.sh` 的 `PKG_VERSION` / `RELEASE_TAG` / `ASSETS` 表
   （sha256 从新版本 `hook/build.dart` 抄）；
2. 用新版源码覆盖 `third_party/wasm_run/lib`，保留本仓的 `hook/build.dart` 与
   `pubspec.yaml` 中 hooks 2.x / frb 精确钉版两处修改；
3. `bash scripts/fetch_wasm_run_libs.sh --force`，再 `--check`；
4. `cd app && flutter pub get && flutter test test/wasm_run_spike_test.dart
   test/architecture_guard_test.dart`；
5. 若 FRB codegen 版本变化，同步 `third_party/wasm_run/pubspec.yaml` 的
   `flutter_rust_bridge` 精确版本（运行时会对不上直接报错）。

## 9. sqlite3 的离线化（同一类问题）

`sqlite3 3.9.1` 的构建 hook 默认也从 GitHub 下载预编译库
（`libsqlite3.<arch>.<os>.dylib`）。iOS 首次构建实测：

```
By default, this package downloads a pre-compiled SQLite library.
This failed (… libsqlite3.arm64.ios_sim.dylib) …
HttpException: Operation timed out
```

处理：`app/pubspec.yaml` 增加

```yaml
hooks:
  user_defines:
    sqlite3:
      source: system
```

即使用系统自带的 SQLite（macOS/iOS/Linux/Android 均有），构建全程离线。

**已知缺口（登记给批次 07）**：Windows 默认没有 `sqlite3.dll`，
`source: system` 在 Windows 上会让「应用数据」能力不可用。接通 app.db 前必须
补 vendored SQLite 源码（`source: source` + amalgamation）或随包二进制；
在那之前 Windows 的该能力必须显式显示为不可用，不能静默失败。

## 10. 体积

`third_party/wasm_run/libs` 共约 **73 MB**（15 个平台）。这是离线构建的代价；
若后续采用 git-lfs 或按需下载，保持 `--check` 的 sha256 门不变即可。
