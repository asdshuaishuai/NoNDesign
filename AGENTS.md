# AGENTS.md — NaN

AI 原生创作工作台。**一句话 → 产品需求设计文档 → 完整可交互原型**；同一工作台
还能做 3D 场景、代码动画视频与带本地数据库的 NaN 热应用。
（2026-11-20 方案线：定位升级为「创意工作台」并加入音乐/编曲，未施工，见文档总纲。）

**愿景（2026-11-20，方向与取舍的唯一事实源）：代码创造世界。**
人提出世界，Agent 写出世界的源代码，工作台让世界可进入、可修改、可验证、可带走；
设计 / 3D / 视频 / 音乐四个工作台是同一底座的四视图。新功能先过
[docs/vision.md](docs/vision.md) §7 的五问滤镜，答不上来就不做。

**技术栈（用户决策，2026-11-13 / 2026-11-18）：Flutter 3.50 + 纯 Dart 本地核心。
没有 Python 服务、没有固定端口、没有端口文件。Python 只保留为开发期同步工具
（`scripts/sync_engine.py` / `scripts/sync_models.py`），不参与应用运行时。
不要重新引入 Bun、Tauri 或任何 JS 前端运行时。**

**文档入口（2026-11-20 起）**：[docs/README.md](docs/README.md) 是文档总纲——
文档分层、决策台账、状态口径与施工顺序都在那里。当前**未施工**的方案线：
`docs/plan-creative-workbench.md`（交互升级 + 四模块 + 强绑定强规范）、
`docs/plan-music-module.md`（音乐/编曲）、
`docs/plan-cross-platform-runtime.md`（webview_all / 引擎 wasm SDK / flutter_scene 裁决）。
方案文档写的是目标态，不要当作现状引用；两者冲突时以文档总纲的决策台账为准。

## 架构边界（改代码前先读）

```
app/                 Flutter UI + 原生画布 + Dart 本地核心
  lib/core/engine/   MoonViz classic wasm 宿主（wasm_run FFI / isolate 队列）
  lib/core/          DDP / 项目库 / 3D / 热应用 / 视频 / 内置智能体 / 设置
  lib/core/remote/   「连接桌面」协议、token、方法表、Dart RPC 宿主
  lib/widgets/       壳层（ChatPiPShell / DesktopShell）、工作台、画布、设置
  assets/            engine 产物、components 快照、models.json、3D/视频示例
engine/              moonviz.wasm + components.json + manifest（构建源）
third_party/wasm_run/ vendored wasm 执行器（桌面动态库 / 移动 native 资产）
scripts/             开发期同步 / 对拍 / 发布检查（不参与运行时）
figma-plugin/        Figma 双向插件
plugins/             独立插件资产（视频制作说明）
```

必须守住的边界：

- **唯一事实源**：一份 canonical `.mbt.md`。人类画布操作（HumanGate）与智能体操作
  （AgentGate）都必须经引擎校验后回写同一份文档；`.ddp` 只是它的认证加密容器。
- **Dart 不解释视觉语义**：只渲染引擎返回的 `artboards[].nodes[]`/`svg`、发送 op、
  展示事件。不要在 Dart 里"顺手"改布局/属性——变更必须回到引擎。
- **引擎宿主只有一处**：`app/lib/core/engine/`（`engine_host.dart` 负责 isolate 与
  看门狗，`engine_worker.dart` 负责 `_in` 槽 ABI / UTF-16 读 / 会话缓存 / fuel）。
  画布与内置智能体共用同一个 `EngineService`；不要旁路直写 mbt。
- **两道门是不同的门**：画布走 `apply_human_op_in`，智能体走 `apply_agent_op_in`
  （`gate:'agent'`）。只读命令走 session/检视路由，绝不能进变更路径。
- **移动端本地引擎默认关闭**：`WasmRuntimeGate.mobileLocalEngineEnabled` 只有在真机
  p95 / 内存 / fuel 验收通过后才允许打开；未通过时移动端只能「连接桌面」。
- **可选「连接桌面」**：客户端只允许 `/v1/health`、`/v1/capabilities`、`/v1/rpc`
  契约（`remote_desktop_client.dart`）；桌面宿主默认关闭、默认 loopback、token 必填，
  LAN 必须显式开关。**没有免鉴权模式、没有固定端口、没有端口文件。**
- **能力缺失不得静默**：不要用 `api == null` 代表"功能不可用"；向
  `CapabilityHub` 要 `CapabilityAvailability`，并把 `message` 显示出来
  （原始诊断只放折叠的「技术详情」）。
- **模型与端点**：`app/assets/models.json` 是 models.dev 的 vendored 快照；
  `scripts/sync_models.py` 只写这一份。能力轴以快照为准，线上方言（thinking 等）
  单独裁决。

## 产品裁决（四个面不统一）

| 宿主 + 朝向 | 壳 |
| --- | --- |
| 手机（锁竖屏） | `ChatPiPShell`：聊天全屏 + 工作区画中画 |
| iPad 竖屏（含 768×1024） | `ChatPiPShell`（明确裁决：3:4 太窄，画布+聊天栏会不可用） |
| iPad 横屏 | `DesktopShell`：Workspace/Welcome + 右侧 320–420 可折叠聊天栏 |
| macOS / Windows / Linux | `DesktopShell` |
| play / portfolio | 整壳全幅 |
| 3D / 视频 / 热应用（`plugin:*`） | 留在响应式壳内：桌面壳左侧固定工作区 +
  右侧常驻 NaN 窄栏；手机/iPad 竖屏由 `ChatPiPShell` 整屏渲染工作区 |

- **方向门（用户裁决 2026-11-19）**：手机端不允许横竖切换，锁定竖屏；平板跟随系统旋转
  （横屏=桌面壳、竖屏=聊天优先壳），桌面无方向概念。唯一实现源是
  `app/lib/core/orientation.dart`；运行时门在 `main.dart`，每次度量变化（旋转 / 分屏 /
  折叠屏展开）都重钉方向，手机永远被压回竖屏。
- **工作台切换 = 项目切换**（用户裁决 2026-11-19）：一个项目只对应它自己的工作台
  类型，项目内部不摆工作区切换条；右侧 NaN 窄栏只有 NaN / 检查两个 tab。
  切换入口是顶栏项目下拉（设计项目 / 3D 场景 / 热应用 / 视频 / 新建 / 打开 / 回主页），
  以及主页作品集、艺术架、各工作台自己的项目菜单。没有 ⌘5–⌘7 工作台直跳键。
- 断点与判据唯一来源是 `app/lib/core/layout.dart`；`shell_host.dart` 只做路由。
- 聊天窄栏默认 360、折叠后 44px；窄 PC（<1100）默认折叠，<1024 强制折叠。
- 设置面板四档（手机 / iPad 竖 / iPad 横 / 桌面）不共用同一套堆叠；内置服务商端点
  打开即填且只读，模型选择走底部 sheet；「连接桌面」是一张合并卡片
  （地址 + 检测连接 + 内置/连接桌面二选一 + 人话文案）。
- Toast 统一走 `ToastService`：圆角胶囊 + 毛玻璃 + 顶部左侧堆叠 + 1–5s 分级。
  通知历史**只是服务内部缓冲**（去重刷新 / replay 入参），没有回看界面——通知
  中心 UI 已随 2026-11-19 死代码清理退役（`app/test/toast_test.dart` 的
  「无历史入口」锚定测试防守，重新回接 UI 需先推翻该登记）。**不要在
  `ToastHost` 之外直接 `ScaffoldMessenger.showSnackBar`。**
- 用户可见文案遵守 `docs/copy-glossary.md`：不出现 Python / server / wasm /
  MoonViz / DDP / mbt / canonical / nonapp / ACP / AgentGate / engine / session_*/
  tool_* / JSONL / localhost / 端口 / 构建代号。工具名必须经 `toolLabel()` 映射；
  失败提示按错误码映射；原始错误只进折叠的「技术详情」。`app/test/copy_guard_test.dart`
  是自动门（`COPY_GUARD_STRICT=true` 时 allowlist 为零）。

### 能力矩阵（与实现同步；改了要一起改）

| 能力 | macOS / Windows / Linux | iPhone / iPad | Android |
| --- | --- | --- | --- |
| 画布 / 设计校验（本地引擎） | ✅ 进程内 wasm | ⚠️ 默认关闭，真机 spike 通过才开 | ⚠️ 同左（构建目前受阻） |
| 项目保存 / 打开（DDP） | ✅ | ✅ | ✅ |
| 内置智能体（Dart 循环） | ✅ | ✅（文档/PLAN 无需引擎；画布 op 需引擎或连接桌面） | ✅ |
| 3D 工作台 | ✅（应用内 WebView） | 连接桌面后可看；本机预览降级 | 连接桌面；WebView 待验证 |
| 热应用 / `.nonapp` | ✅ | ✅ 本地库/查看；本地数据库依赖平台绑定 | ✅ 本地库；构建待验证 |
| 视频工作台 | ✅ 代码动画实时播放 + 编辑/对照 | 同左（纯 Dart 矢量逐帧） | 同左 |
| 外部智能体（ACP） | ✅ | ❌ 设计禁用 | ❌ |
| 连接桌面（客户端） | ✅ 可填地址/连接码 | ✅ | ✅ |
| 连接桌面（桌面宿主） | ✅ 设置卡启停/地址/连接码 | — | — |
| 系统分享 / 导出面板 | ❌ 未装插件 | ❌ | ❌ |

> 上表描述**当前实现**（2026-11-20）。同日定稿的全平台运行时方案（未施工）会改变
> WebView / wasm 宿主两行：`webview_all` 让 Windows/Linux 也具备应用内 WebView，
> 引擎 wasm SDK 跑进 WebView 后 iOS/Android 的本地引擎路径重新评估。台账见
> [docs/README.md](docs/README.md) §2，细节见
> [docs/plan-cross-platform-runtime.md](docs/plan-cross-platform-runtime.md)。

## 常用命令

```bash
# Flutter（主门禁）
cd app
flutter analyze --no-pub
flutter test
flutter run -d macos
flutter build macos --release

# 发布包桌面状态（构建后；批次 15 新增）
cd ..
dart run scripts/wf/check_desktop_release.dart \
  --app app/build/macos/Build/Products/Release/NaN.app --home /tmp/nd-home

# 开发期同步（可选，不参与运行时）
python3 scripts/sync_engine.py        # 校验/下载 wasm，真机 render 探针
python3 scripts/sync_models.py        # 刷新 models.dev 快照 → app/assets/models.json
```

`scripts/wf/test.sh` 只跑 `flutter test`；Python 回归锚点已随 `server/` 删除，
不要再往它里面加 Python 测试。

## 引擎 ABI（不要凭猜测改）

- 写方向：`in/arg/arg2` 三槽，UTF-8 分块（每块小端 4 字节 + 有效长度），调用
  `*_in()` 变体。唯一实现是 `engine_worker.dart` 的槽写入；不要在别处复制。
- 读方向：引擎返回字符串指针，布局 `[len@ptr-4][UTF-16LE@ptr]`；UTF-16 读必须处理
  代理对，且 `memory.grow` 后旧 `WasmMemory.view` 失效（用前重取）。
- 每次调用都要重设 fuel/看门狗；trap 后丢弃 session 并重建实例。Dart 不能中断
  同步 wasm 调用——没有 fuel 的执行器拒绝启动（`requireEngineAbi` 门）。
- 会话 API 按 canonical 文本键控；变更信封的 `mbt` 必须回写缓存。任何 trap/腐坏读
  都弃缓存。
- `list_components` 用 `app/assets/engine/components.json` 快照；`list_templates`
  直接问引擎。快照与 wasm 活注册表的一致性由 `scripts/sync_engine.py` 探针逐 id 对账。
- 引擎自渲染 SVG 是内容层唯一真源：画布/演示的内容层用引擎返回的 `svg`，
  本地 painter 只做选区/悬停/手柄等覆盖层。

## Agent 层约定（Dart）

- 循环在 `app/lib/core/dart_agent.dart`；`design_op` 必须经
  `EngineGateBridge`（生产是进程内 `EngineService`，`gate:'agent'`），绝不直写 mbt。
- `toolLabel()` 是工具名的唯一出口；新增工具必须同时补文案映射与失败码映射。
- 流式事件面保持稳定：`assistant_text` / `assistant_thinking`（仅文档阶段）/
  `thinking_delta` / `doc_delta` / `tool_start` / `tool_end` / `doc_written` /
  `page_generated` / `preview` / `done` / `failed`。`done` 与 `failed` 必须成对
  可判——**每条 run 都要有终态**，不能静默结束。
- 续跑策略：模型只回文本、没有交付文档/画布操作时，自动再跑一轮 nudge；文档阶段仍缺
  文档则报 `doc_not_written`，不伪装成澄清。
- 工具结果必须整形（剥 mbt/svg、节点/数据截断、追加 `state` 卡），避免吃光上下文。
- 上下文分层：静态指令 → 项目地图 → 设计规范/文档 → 会话记忆 + 最新 state；
  稳定前缀不要插入时间戳/随机序，变更走追加式 state 卡。
- 取消：`CancellationToken`；取消后也必须发终态事件。
- 步数预算：`AppSettings.effectiveMaxSteps` 是唯一来源；`unlimitedSteps` 打开时使用
  `agentUnlimitedSteps` 哨兵（1<<20）并解除本地 run 的 10 分钟总时长（取消仍有效）。
  不要在循环、设置 UI 或远程参数里写死 600。

## DDP

- DDP1：`DDP1` + version + salt16 + nonce24 + XChaCha20-Poly1305(zstd(payload))，
  AAD = header。Argon2id m=19*1024 KiB, t=2, p=1, len=32。
- DDP2：`DDP2` + version + CRC32LE + zstd(payload)（免密）。
- 字节权威是 Rust `vendor/moonviz-ddp`；Dart 实现与它在固定 salt/nonce fixture 下
  逐字节一致。DDP1 生产写入因随机 salt/nonce 不逐字节，这是密码学设计，不是缺陷。
- 文档标记：`<!-- nondesign:design {...} -->` / `<!-- nondesign:docs {...} -->` 放文末；
  JSON 中 `>` 必须转义为 `\u003e`，否则引擎注释扫描器会在 `-->` 截断。

## Flutter 约定

- 状态：`AppStore extends ChangeNotifier`（provider）。所有会改项目的异步操作串行
  经过 store；不要绕过 store 直接调 API。`_opQueue` 是 op 串行化的唯一入口。
- 画布：`CanvasView` + 引擎 SVG 内容层；拖动只更新本地 ghost，松手才发 `move` op。
- 设计令牌：`core/theme.dart` 的 `NonPalette` 是唯一颜色源；不要在 widget 里散落硬编码色。
- 动效：只取 `NonMotion`（fast 120 / base 180 / slow 240ms，easeOutCubic）。
- 下拉：统一 `nonSelect(context, …)`（M3 DropdownMenu；经典 DropdownButton 的
  `itemHeight >= 48` 运行时断言是历史红屏来源，改它必须跑真机/测试）。
- 快捷键：绑定与展示标签统一走 `core/keys.dart` 的 `modKey()` / `modCombo()`；
  不要手写 `SingleActivator(meta:true)` 或散落硬编码 ⌘ 标签。
- 演示模式：进入态判定必须在 `mode=m` 赋值**前**捕获；起始板 = 交互根；前进导航
  统一走 `playGo` 单点收口；热区清单 = 出边 flow ∪ 引擎 interactions 导出。
- 平台壳：macOS 为主开发目标；Linux/Windows 目前无应用内 WebView（3D/热应用/视频播放
  降级）。**计划中**：`webview_all` 全平台替换，见
  `docs/plan-cross-platform-runtime.md` §1（方案定稿；批次 A 工作区已改、未提交）。
- macOS Runner 已关闭 App Sandbox（本地文件 + `~/.nondesign`）；不要随手加回 sandbox
  而不补 network client / app container。

## 测试与验收

- `flutter test` 是唯一运行时门禁。发布前必须跑：
  `flutter analyze --no-pub` + `flutter test` + `flutter build macos --release` +
  `scripts/wf/check_desktop_release.dart`。
- `app/test/acceptance_local_core_test.dart` 是发布验收入口：DDP 往返、项目列表、
  本地引擎 render + 两道门、3D/热应用/视频 smoke、`app/lib` 无 Python 服务启动面。
- 发布包检查（`check_desktop_release.dart`）：bundle 无 `.py/.pyc/server/.venv`；
  默认启动无 TCP/UDP 监听、无 Python 子孙进程、无 `~/.nondesign/server.json`；
  宿主源码契约默认 loopback + `port=0` + Bearer token。
- 文案门：`copy_guard_test.dart`（严格模式）+ `copy_screen_test.dart`（五尺寸运行时
  文本）。改用户可见字符串后必须跑。
- 引擎：`scripts/sync_engine.py` 的 render 探针；`engine_contract_test.dart` /
  `engine_host_test.dart` 锁定导出面、槽 ABI、UTF-16、会话缓存、trap 恢复与内存回收。
- DDP：`ddp_test.dart` 覆盖 DDP1/DDP2 往返、错误码与固定 fixture 字节一致。
- 远程：`desktop_rpc_host_test.dart` + `remote_host_integration_test.dart` 锁定
  默认无监听、token、限额、SSE 与真客户端全链。
- **本地集成模式**：`engine/ENGINE_LOCAL`（gitignored）在场时 `sync_engine.py` 可指向
  本地引擎构建；发布构建应锚定仓库自带产物。改引擎版本先跑 sync 再跑全部测试。

## 已知限制（v0.1，2026-11-18 清理后）

- **「连接桌面」宿主已接线**：桌面设置「运行方式」卡内可启停宿主、查看地址与
  一次性连接码、切换 loopback/局域网并轮换连接码（默认关闭/临时端口/token 必须）。
  后续项：暂无二维码配对；局域网地址只列 IPv4。
- **旧 HTTP 路由已清零**：`api_shelf.dart` / `api_nonapp.dart`（死代码）已删除；
  `play_view.dart` 的热区点击改走 `NoNDesignApi.tap`（本地引擎或 `/v1/rpc`）；
  `dart_agent.dart` 的 `HttpEngineGate` 已删除（生产桥只有 `LocalEngineGate` 与
  `_StoreEngineGate`）；`api.dart` 的 `getJson/postJson` 原始 HTTP 逃生口已删除。
  `app/test/acceptance_local_core_test.dart` 的源码守卫会扫描 `app/lib`（去注释），
  禁止旧运行时/旧路由回归；`assets/engine|three|video/` 这类资产路径与
  `core/remote/` 的 `/v1` 契约是允许的。
- `scripts/wf` 只保留开发期工具：`sync_engine.py`、`sync_models.py`、
  `video_golden_check.py` 与 shell 入口。只服务旧 Python 服务端的测试/工具
  （含 `engine_parity.py`、`compileall.sh`）已删除，不要再加回来。
- 演示模式的热区点击在引擎不可用时仍会回落到本地 flow 导航（不是静默失败）。
- `api == null` 仍被若干面板当作"未就绪"的早退条件（`inspector_panel.dart`、
  `left_panel.dart` 等，文件归属批次 11/13）；这些入口在引擎/桌面都不可用时
  仍是静默 return，需要改成 `CapabilityHub` 的显式提示。发布验收把它列为未清项。
- **视频是代码动画**（用户裁决 2026-11-18）：时间线脚本 + 规范编译成算式，
  逐帧 `frameSvg(t)` 在应用内实时播放，全平台同一套行为；**成片导出暂时屏蔽**
  （`VideoService` 渲染代码保留，界面无入口）。既有 mp4 产物仍由艺术架播放。
- 移动端本地引擎默认关闭；iOS/Android 是否启用取决于真机 wasm spike 证据。
- Android debug APK 构建链已修复（`MainActivity.kt` 非空收窄，1fa3a78），可
  产出 debug APK（本会话未复跑 build 复证产物）；本机无 Android 设备/AVD，
  arm64 wasmtime 加载与 `_in` ABI 的真机验收仍未完成。
- 外部智能体（ACP）桌面独占；移动端按设计禁用。
- 3D/热应用在 Linux/Windows 没有应用内 WebView，预览降级为浏览器或路径
  （全平台 WebView 替换方案见 `docs/plan-cross-platform-runtime.md` §1，未施工）。
- API Key 明文存本机 `SharedPreferences`（并镜像 `~/.nondesign/settings.json`）；
  Keychain 未接。

## 版本

`VERSION` = `0.1.0`（唯一版本源；`app/pubspec.yaml` 同步）。文档状态见
[docs/README.md](docs/README.md)（已实施 / 方案定稿 / 历史快照三态总纲）。
