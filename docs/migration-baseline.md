# 迁移基线（批次 00）

> 日期：2026-11-18　仓库：`/Volumes/data/dev/coding/deepcodeUI/deepStudio/NoNDesign`
> 分支：`main`（`git branch -a` 只有 `main` / `origin/main`，本仓无 dev 线）
> 本文件是后续批次（01/05/11/12/13/15…）的**继承基线**：门禁数字以这里为准，
> 不要把本文件的 9 failures 当成本轮新回归。

## 1. 在途改动冻结

| 项 | 值 |
|---|---|
| 冻结前 HEAD | `db10ad9` — `fix(audit): round-7 new-capability verification repairs` |
| 在途改动 | `M app/lib/core/models.dart`、`M app/lib/widgets/settings_dialog.dart`（`git diff --stat` = 2 files, +95 / -206） |
| 冻结方式 | **基线提交** `9a93522` — `chore(baseline): freeze in-flight settings/model runtime edits before migration batch 00` |
| stash id | **无**（`git stash list` 为空；按「需要基线就提交，不要重置」改用提交冻结，未使用 stash） |
| 冻结后状态 | `git status --short` 为空（干净） |

在途改动的内容是「单一内置运行时 + 内置服务商端点只读 + 设置导航改版」的**半成品**；
它属于设置第二轮方向（`settings_dialog/models` 唯一属主 = 批次 11）。批次 00 只冻结、
不改写、不继续实现。见 §4 的失败归因（这 5 条失败正是该半成品与旧测试的冲突）。

## 2. 环境基线

| 组件 | 版本 / 位置 |
|---|---|
| Flutter | 3.50.0 stable（`/Users/kelthas/.flutter_sdk`），Dart 3.14.0 |
| Xcode | 27.2（CocoaPods 1.16.2） |
| Java | OpenJDK 25.0.1（sdkman） |
| Gradle | 9.5.0-all（wrapper，已缓存 767MB） |
| AGP | 9.3.1；Kotlin 2.4.20（`app/android/settings.gradle.kts`） |
| Android SDK | 36.0.0；platforms `android-35/36`；NDK `28.2.13676358`；**无 cmdline-tools、无 emulator** |
| 设备 | `adb devices` → 空列表；Flutter 连接设备仅 iOS 模拟器 / macOS / Chrome |
| 其它 | `app/android/gradle.properties` 已含 `android.newDsl=false`、`android.builtInKotlin=false`（原样保留，未改动） |

## 3. `flutter analyze --no-pub` 基线

命令：`cd app && flutter analyze --no-pub`

```
92 issues found. (ran in 6.4s)
```

| 严重度 | 数量 | 备注 |
|---|---|---|
| error | **0** | 与盘点一致（92 issues / 0 error） |
| warning | 1 | `lib/widgets/rail.dart:6:8` — `unused_import`（`common.dart`） |
| info | 91 | 主因是 Flutter 3.50 把 `package:flutter/material.dart` 标记弃用（`deprecated_member_use`，应换 `material_ui`），覆盖 lib+test 各文件；另有 `lib/widgets/workspace.dart:388:16` `use_build_context_synchronously`、`test/nonapp_hotapp_mount_test.dart:16:8` 与 `test/nonapp_offline_test.dart:19:8` 的 `depend_on_referenced_packages` |

结论：**0 error 基线成立**。批次 00 不清理 info 噪音（属各 owner 顺带治理）。

## 4. `flutter test` 基线：9 failures

命令：`cd app && flutter test`（完整输出保存在 `/tmp/nondesign_baseline_test.log`）
结果：`00:31 +283 -9: Some tests failed.`（exit 1）

### 4.1 失败清单与归因

| # | 测试（文件: 用例） | 错误签名 | 归因 |
|---|---|---|---|
| 1 | `test/dart_agent_test.dart` — AppSettings.agentRuntime toJson/fromJson 往返与容错 | `Expected: server / Actual: dart` | **A** |
| 2 | `test/dart_agent_test.dart` — 默认按平台解析；宿主 macOS 上默认 server | 同上 | **A** |
| 3 | `test/settings_dialog_test.dart` — saveSteps：写盘在飞期间关闭弹窗不触发 setState-after-dispose | `Expected: <1> / Actual: <2>`（`saveSettings` 调用次数，test:83） | **A** |
| 4 | `test/settings_mobile_test.dart` — phone settings: 分组根页，无顶部 tab | `Found 0 widgets with text "上下文与缓存"`（test:68）——该导航项已被改名为「智能体」 | **A** |
| 5 | `test/settings_mobile_test.dart` — phone settings: 下钻单列 + 输入/触控尺寸 + 返回 | `Found 0 widgets with key [<'settings-m-server'>]`（test:99） | **A** |
| 6 | `test/store_test.dart` — a stalled agent stream releases agentBusy via the idle-timeout terminal | `MissingPluginException(No implementation found for method getAll on channel plugins.flutter.io/shared_preferences)` @ `store.dart:440` | **B** |
| 7 | `test/store_test.dart` — orphaned run events are dropped — terminal canonical never commits | 同上 | **B** |
| 8 | `test/store_test.dart` — pending doc_delta flush timer does not notify after dispose | 同上（dispose 后仍 notify） | **B** |
| 9 | `test/store_test.dart` — run start drains the op queue so the run mbt snapshot is fresh | 同上 | **B** |

归因 A（5 条）——**冻结的半成品与旧测试冲突**：
`models.dart` 的 `defaultAgentRuntime()` 现在恒返 `dart`、`fromJson` 把旧 `server`
迁移成 `dart`；`settings_dialog.dart` 删除了运行时选择器（`settings-m-server` 键消失）、
并在打开设置时用微任务补写 `baseUrl`（`Future.microtask(store.saveSettings)`——冻结 diff 里
唯一新增的 `saveSettings` 调用点，即该用例多出的那次写盘）。
**owner = 批次 11**：完成设置第二轮时同步更新这 5 条测试（预期：运行时选择器退役、
端点只读、`saveSettings` 次数语义重写）。批次 00 不动它们。

归因 B（4 条）——**测试基建缺口（非产品回归）**：
`store_test` 的用例走到了 `AppStore.saveSettings` → `SharedPreferences.getInstance()`，
但测试没有装 mock。修法：`TestWidgetsFlutterBinding.ensureInitialized()` +
`SharedPreferences.setMockInitialValues({})`（在 `setUp` 里）。
登记为基线债：谁先改 `store_test`（批次 05 的 store/api 线或 12）谁清；批次 00 不修。

### 4.2 对后续批次的含义

- 01/05/11 的全量 `flutter test` 门会**继承这 9 条红**：期望红名单稳定，不新增即可。
- 批次 11 收尾时必须让 A 类 5 条转绿；B 类 4 条不属于任何 UI 批次，需显式清理，
  否则 15 的「零残留」不可达。

## 5. Android N3 判定（本轮核心）

三次实测（完整日志：`/tmp/nondesign_baseline_apk.log`、`_apk2.log`、`/tmp/probe_apk.log`）：

### 5.1 第 1 次：原始树 → 失败（65.9s）

```
Unsupported operation: mediapipe_retrieval runs Google's MediaPipe library,
which needs Android 9 (API 28); this app targets API 24.
Set minSdk = 28 in android/app/build.gradle(.kts).
Target build_hooks failed: Error: Building native assets failed.
```

- 根因链：`mediapipe_retrieval-0.3.0/hook/build.dart` →
  `mediapipe_core-0.3.0/lib/src/native_assets/family_runtimes.dart:335-338`；
  Flutter 3.50 默认 `minSdkVersion = 24`
  （`.flutter_sdk/packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt:26`）。
- **注意**：失败发生在 native-assets 装备阶段，**不是 Gradle/AGP 挂起**。

### 5.2 第 2 次：`minSdk = 28` 后 → Kotlin 编译失败（5m32s）

改动（批次文件内，保留）：`app/android/app/build.gradle.kts` 的
`minSdk = flutter.minSdkVersion` → `minSdk = 28`（附注释说明 mediapipe 依赖）。

构建推进到 `:app:compileDebugKotlin`，报**唯一 1 个**错误：

```
e: .../MainActivity.kt:63:32 Argument type mismatch:
   actual type is 'Uri?', but 'Uri' was expected.
```

- Gradle 9.5 / AGP 9.3.1 / Kotlin 2.4.20 完成配置与执行，**未挂起**（5m32s 内正常失败）。
- 期间打印 9 次 `File modified during build. Build must be rerun.`：native-assets
  首次生成（安装 CMake 3.22.1、解出 mediapipe 原生库）期间 Gradle 的重跑提示；
  没有形成死循环。增量构建时该提示归零（见 5.3）。
- Kotlin 错误位置：`MainActivity.kt:58` 声明 `val uri: Uri? = when (...) ?: return`，
  显式可空类型让 `:63` 的 `materialize(uri: Uri)` 收到 `Uri?`。

### 5.3 第 3 次：一次性探针（临时改一行 → 构建成功后已原样还原）

目的：只判定「除这一行外还有没有别的阻断」，**不作为对 `MainActivity.kt` 的正式修改**
（该文件不在批次 00 的 `batch.files`，正式修复交批次 07）。

- 临时把 `MainActivity.kt:58` 改成 `val uri: Uri = when (intent.action) { ... } ?: return`；
- `flutter build apk --debug` → **成功**：

```
Running Gradle task 'assembleDebug'...   75.0s
✓ Built build/app/outputs/flutter-apk/app-debug.apk
```

- 产物：`app/build/app/outputs/flutter-apk/app-debug.apk`，319,688,968 B（≈305 MiB，
  mediapipe 多族原生库所致），sha1 `24115b0a33de9e7dd73a0da3ce172546b6f531fb`。
- **已还原**：从构建前备份 `/tmp/MainActivity.kt.orig` 拷回，
  sha256 `981e96d5…2a1c50` 与修改前一致；`git status --short` 不再包含该文件
  （还原脚本第一次用了 `cd app` 后的相对路径、失败一次，已立即人工重做并校验哈希）。
- 该 APK 是**探针产物**（源码比当前树多那一行修复），不代表当前树可直接构建；
  正式二进制应由批次 07 修好 `MainActivity.kt:63` 后重出。

### 5.4 `adb install` / `launch`

**未执行**：`adb devices` 为空；SDK 无 `emulator` 二进制、无 `cmdline-tools`；
`flutter doctor` 的 Android toolchain 为 `[!]`（cmdline-tools missing / license unknown）。
因此**Android 真机验收不能宣称通过**。

### 5.5 判定

| 问题 | 结论 |
|---|---|
| 「Gradle 9.5/AGP 9.3.1 启动即挂起」 | **未复现**。配置、执行、Kotlin 编译、native-assets（含 CMake 自动安装）都能走完：首次全量（含装 CMake/解 mediapipe 原生库）5m32s 后停在业务 Kotlin 错误；修复后增量构建 **75.0s 成功**。 |
| 当前树 `flutter build apk --debug`（批次 00 基线时） | **失败（exit 1）**，根因 `MainActivity.kt:63` 一行类型错误（owner 07 / nonapp-2）。**2026-11-18 更新**：该行已修复，工作树已有 debug APK 产物（本轮未重跑构建）；真机运行仍未验证。 |
| 修复后是否还有别的阻断 | 就构建而言**没有**：探针构建产出完整 APK。 |
| Android 本地能力能否进本轮 can-do | **不能（运行证据缺失）**。构建已通，但无设备/AVD：Android arm64 的 wasmtime 加载、`_in` ABI、内存回收均未在设备上验证。解锁条件 = 设备/AVD 安装启动 + wasm/性能门（见总架构）。 |
| 新增前置 | `minSdk = 28`（Android 9）；这会抬高 Android 门槛，产品口径需同步（Android 9 以下不再支持）。 |

## 6. 复现命令

```bash
cd /Volumes/data/dev/coding/deepcodeUI/deepStudio/NoNDesign

git log --oneline -2                      # 9a93522 (baseline) / db10ad9

cd app
flutter analyze --no-pub                  # 92 issues / 0 error
flutter test                              # +283 -9（红名单见 §4）

# Android（脚本口径见 scripts/wf/android_build.sh）：
export PATH="$HOME/.flutter_sdk/bin:$HOME/Library/Android/sdk/platform-tools:$PATH"
flutter build apk --debug                 # 当前树：exit 1（MainActivity.kt:63）；修后应绿

cd ..
bash scripts/wf/android_build.sh          # 0=构建+安装成功 / 1=构建失败 / 2=无设备 / 3=安装失败
# 当前树实测：SCRIPT_EXIT=1（2s 内报 MainActivity.kt:63，与直接 flutter build 一致）
```

## 7. 交给后续批次的入口条件

1. **工作树**：批次 00 交付后除下列四个文件外干净——
   `M app/android/app/build.gradle.kts`（minSdk 28）、
   `?? docs/migration-baseline.md`、`?? docs/round7-residuals.md`、
   `?? scripts/wf/android_build.sh`。批次 00 不代流程提交这些交付物
   （只有 §1 的基线冻结提交 `9a93522` 是本批要求的 commit）。
2. **analyze 0 error**；info/warning 维持 92 条基线，不新增。
3. **test 红名单 = §4.1 的 9 条**；新增红一律视为回归。
4. **Android**：只有 `scripts/wf/android_build.sh` 退出码 0 才算通过；
   当前必须按「远程/PLAN」叙述，不得写「Android 本地可用」。
5. **文案**：`shelf-2` 的离线条（`portfolio_view.dart:732`）等内部词仍在，
   由 07 按术语表替换；批次 00 不提前改文案。
