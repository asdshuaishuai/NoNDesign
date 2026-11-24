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
`docs/skills/creative-workbench/SKILL.md`（统一创作 skill 契约，未接线）。
**已落地**：`docs/plan-cross-platform-runtime.md`（批次 A/B1：webview_all 全平台 +
引擎 classic wasm 进离屏 WebView；wasm_run 仅兜底；flutter_scene 不采用）。
方案文档写的是目标态，不要当作现状引用；两者冲突时以文档总纲的决策台账为准。

## 架构边界（改代码前先读）

```
app/                 Flutter UI + 原生画布 + Dart 本地核心
  lib/core/engine/   MoonViz 引擎宿主：
                     · webview_engine_host.dart + assets/engine/engine_web_host.js
                       （**主路径**：classic wasm 跑在离屏 webview_all 会话里）
                     · engine_host.dart / engine_worker.dart（wasm_run 兜底）
                     · engine_backend.dart（两者同一接口，EngineService 面向它编程）
  lib/core/          DDP / 项目库 / 3D / 热应用 / 视频 / 内置智能体 / 设置
  lib/core/remote/   「连接桌面」协议、token、方法表、Dart RPC 宿主
  lib/widgets/       壳层（ChatPiPShell / DesktopShell）、工作台、画布、设置
  assets/            engine 产物、components 快照、models.json、3D/视频示例
engine/              moonviz.wasm + components.json + manifest（构建源）
scripts/engine_web_probe.mjs  经典 wasm JS 宿主的 Node 契约探针（与 WebView 同字节）
third_party/wasm_run/ vendored wasm 执行器（**仅兜底路径**；主路径不加载）
scripts/             开发期同步 / 对拍 / 发布检查（不参与运行时）
figma-plugin/        Figma 双向插件
plugins/             独立插件资产（视频制作说明）
```

必须守住的边界：

- **唯一事实源**：一份 canonical `.mbt.md`。人类画布操作（HumanGate）与智能体操作
  （AgentGate）都必须经引擎校验后回写同一份文档；`.ddp` 只是它的认证加密容器。
- **Dart 不解释视觉语义**：只渲染引擎返回的 `artboards[].nodes[]`/`svg`、发送 op、
  展示事件。不要在 Dart 里"顺手"改布局/属性——变更必须回到引擎。
- **引擎宿主只有一处**：`app/lib/core/engine/`。`EngineService` 面向
  `EngineBackend` 编程，生产默认 `WebViewEngineHost`（classic wasm 的 JS 宿主跑在
  离屏 `webview_all` 会话里），`EngineHost`（wasm_run isolate）只作启动失败兜底。
  `engine_worker.dart` 的 `_in` 槽 ABI / UTF-16 读 / 会话缓存是 JS 宿主
  `assets/engine/engine_web_host.js` 的对照实现，两边改一处必须改另一处并跑
  `scripts/engine_web_probe.mjs`。
  画布与内置智能体共用同一个 `EngineService`；不要旁路直写 mbt。
- **运行时决策（2026-11-20）**：引擎提供两种 wasm SDK——classic（WASM MVP、0 imports、
  `_in` 槽 ABI，任何 WebView 都能跑，**主路径**）与 wasm-gc（≈90KB、JS String Builtins，
  需 Chrome 119+/Safari 18.2+，**不作为全平台基线**，只保留为未来 V8 快路径）。
  WebView 内 JS 调用不能从 Dart 中断，但跑在平台 Web 进程而非 Flutter UI isolate；
  看门狗超时即销毁并重建离屏会话。**不要**把引擎调用搬回 UI isolate，也不要恢复
  「原生 wasmtime + 平台动态库」作为主路径。
- **外部创作工具只参考、不引入（2026-11-21 用户裁决；下列「创作线引入例外」优先）**：OpenMotion、HyperFrames
  及同类第三方创作产品/运行时**不做依赖、不内置进程、不套壳、不设导出适配器**；
  只借鉴它们的规范、协议与交互（如 Motion.md、版本/导出/MCP 纪律）。我们是做
  自己的产品，不是别人的工作台。**3D 栈（three.js / three-live）是明确例外**；
  视频工作台此前已裁决的 Phaser 3 引擎选型不因这次调研改变（若用户进一步收紧，
  再单独改方案）。**代码/技能包同理**：`JDhruv14/line-art-animation`（MIT）只作为
  `ink_line` 墨线手绘风格的规则参考，不复制其代码、不依赖其 TypeScript/SVG 运行时；
  方案线的风格包渲染走自研 Canvas2D 矢量笔触（未施工，I0 spike 验证）。
  `mromidev/claude-animated-shorts`（MIT 代码/文档）同样只参考：只借 8 段脚本、
  词级时间、镜头表、look 数值与 QA；**不引入 Remotion / `@remotion/three` / React /
  Node / Chromium**，不复制其参考帧/角色/脚本/镜头/配音/音乐。`toon_3d`
  （2D 角色 + 3D 世界）是候选风格，待裁决与 spike。
- **2026-11-24 追加两个「只参考」候选**：`shinyobjectz/raea`（FSL-1.1-ALv2）技术上
  覆盖 3D/短剧，但它是 230 crate 的完整 Rust/Bevy + React/TS 应用、SDK 私有，且
  *Competing Use* 限制商业替代品——**不 vendor、不捆绑、不引 Bevy/React/JS 运行时**，
  只借 composition/词级时间/`check`/story 契约（未来重开需商业许可或满两年转
  Apache-2.0 + 有边界 API + 产品裁决）。`alla2001/material-painter`（GPL-3.0-or-later）
  能力面覆盖全领域 3D 材质，但仅 GUI 二进制、无 `[lib]`——**不嵌入、不链接、不随包
  分发**；v1 自建 `nan.material/1` PBR 层，可选外部 MCP 工作站是**未裁决**的外部
  工具例外。详见 `docs/research/raea.md` 与 `docs/research/material-painter.md`。
- **创作线引入例外（2026-11-22 用户裁决）**：
  ① **3D 线直接引入** `threejs-live`（已在库）+ **3dcodeverse skill/harness 契约**
  （Apache-2.0：plan schema、确定性门阈值、blind judge rubric、spec/src/artifacts/judge
  工作区）。**不引 Python/Blender/CadQuery/URDF/moderngl 运行时**；检查器用 Dart/JS
  等价实现；3DCodeVerse-2M 数据集（CC-BY-NC-SA）不随产品分发。3D 项目双 authoring：
  `scene`（`scene.json` 事实源）/ `code`（`src/*.js` 事实源，3dcodeverse harness）。
  ② **视频 VFX 直接引入** `pixelfx` **特效子集**（MIT）：火焰/冰霜/风/爆炸/闪电等；
  **不引人物**——`actor.js`/`rig.js`/`poses.js`/`act.js`/`moves/` 与 `meta.actor`/
  `o.actor`/on-body 特效一律不引入，角色仍用我们自己的 rig。
  ③ **`awesome-opus5-5-videos` 只借结构**：六段 prompt（inputs/direction/structure/
  build/gotchas/start）+ seek(t)/beat grid/帧证据进统一 skill，不复制作品/服务。
  ④ **统一 skill**：`docs/skills/creative-workbench/SKILL.md` 是视频/3D/设计的
  intake→direction→structure→build→check→blind judge→refine→deliver 契约。
- **两道门是不同的门**：画布走 `apply_human_op_in`，智能体走 `apply_agent_op_in`
  （`gate:'agent'`）。只读命令走 session/检视路由，绝不能进变更路径。
- **移动端本地引擎默认开启**（2026-11-20 起）：classic wasm 跑在 iOS/Android 的
  WebView 里，旧「wasmi 无 SIMD」阻塞已消失；WebView 启动失败时如实降级为
  「连接桌面」并保留真因。`NONDESIGN_MOBILE_LOCAL_ENGINE=false` 可强制关回旧门。
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
- **四工作台外壳统一（用户裁决 2026-11-20）**：设计 / 3D / 视频 / 热应用四个工作区
  都用同一套 `WorkspaceChrome`（`widgets/workspace_chrome.dart`）：标题栏（项目下拉/
  设置/主题）+ 左侧图标轨 + 主区 + 底部状态栏；插件工作台内容是主区槽
  `WorkspaceMainArea`（与设计画布同一内边距/边框语义），插件自己只保留内容顶部
  46px 工具条。**不要**再给 `plugin:*` 视图裸 `Scaffold` 早退。`play` / `portfolio`
  仍是全屏早退；手机/iPad 竖屏仍由 `ChatPiPShell` 整屏渲染插件工作台。
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
| 画布 / 设计校验（本地引擎） | ✅ classic wasm 跑在离屏 WebView | ✅ 同左（真机 smoke 待补） | ✅ 同左（真机 smoke 待补） |
| 项目保存 / 打开（DDP） | ✅ | ✅ | ✅ |
| 内置智能体（Dart 循环） | ✅ | ✅（文档/PLAN 无需引擎；画布 op 用本地 WebView 引擎） | ✅ |
| 3D 工作台 | ✅（webview_all：WKWebView / WebView2 / WebKitGTK） | 本机预览受 `ThreeWebViewGate` 门控（待真机验收） | 同左 |
| 热应用 / `.nonapp` | ✅（webview_all 统一应用内预览；数据库桥走 JS channel） | ✅ 本地库/查看；本地数据库依赖平台绑定 | ✅ 本地库；构建待验证 |
| 视频工作台 | ✅ 代码动画全平台；mp4 产物内嵌播放随 webview_all 全平台（编码器随 WebView 运行时） | 同左（纯 Dart 矢量逐帧） | 同左 |
| 外部智能体（ACP） | ✅ | ❌ 设计禁用 | ❌ |
| 连接桌面（客户端） | ✅ 可填地址/连接码 | ✅ | ✅ |
| 连接桌面（桌面宿主） | ✅ 设置卡启停/地址/连接码 | — | — |
| 系统分享 / 导出面板 | ❌ 未装插件 | ❌ | ❌ |

> 上表描述**当前实现**（2026-11-20 晚）。WebView 已统一到 `webview_all`（macOS/iOS
> WKWebView、Windows WebView2、Linux WebKitGTK、Android WebView；OHOS 的离屏会话
> 尚未实现，见已知限制）。本地引擎已切到**引擎 classic wasm + JS 宿主**，wasm_run
> 仅启动失败兜底；`EngineService.startAuto` 选路，`runtime.runtime == 'webview'`
> 即主路径命中。台账见 [docs/README.md](docs/README.md) §2，细节见
> [docs/plan-cross-platform-runtime.md](docs/plan-cross-platform-runtime.md)。

## 常用命令

```bash
# Flutter（主门禁）
cd app
flutter analyze --no-pub
flutter test
flutter run -d macos
flutter build macos --release
# 真 WebView 引擎 smoke（WKWebView；Windows/Linux 用同一用例在对应机器跑）
flutter test integration_test/engine_webview_test.dart -d macos

# 发布包桌面状态（构建后；批次 15 新增）
cd ..
dart run scripts/wf/check_desktop_release.dart \
  --app app/build/macos/Build/Products/Release/NaN.app --home /tmp/nd-home

# 开发期同步（可选，不参与运行时）
python3 scripts/sync_engine.py        # 校验/下载 wasm，真机 render 探针
python3 scripts/sync_models.py        # 刷新 models.dev 快照 → app/assets/models.json
node scripts/engine_web_probe.mjs     # classic wasm JS 宿主契约（与 WebView 同字节）
```

`scripts/wf/test.sh` 只跑 `flutter test`；Python 回归锚点已随 `server/` 删除，
不要再往它里面加 Python 测试。

## 引擎 ABI（不要凭猜测改）

- 权威产物：`app/assets/engine/moonviz.wasm`（classic，WASM MVP、0 imports、
  `memory` 导出）。**两份同构实现必须同步改**：`engine_worker.dart`（wasm_run 兜底
  / 纯 Dart 测试）与 `assets/engine/engine_web_host.js`（生产 WebView 主路径）。
- 写方向：`in/arg/arg2` 三槽，UTF-8 分块（每块小端 4 字节 + 有效长度），调用
  `*_in()` 变体。JS 宿主在 WebView 内部本地循环，不逐块过 Dart 桥。
- 读方向：引擎返回字符串指针，布局 `[len@ptr-4][UTF-16LE@ptr]`；UTF-16 读必须处理
  代理对，且 `memory.grow` 后旧 `WasmMemory.view` / `DataView` 失效（用前重取）。
- **fuel 只存在于 wasm_run 兜底**；WebView 没有 fuel。看门狗超时 = 销毁离屏会话 +
  重建，不能从 Dart 中断 JS 调用；trap 后同样弃 session 重建实例。
- 会话 API 按 canonical 文本键控；变更信封的 `mbt` 必须回写缓存。任何 trap/腐坏读
  都弃缓存。JS 宿主的会话集合（handle-only / special / mutating / unsupported）
  与 `engine_types.dart` 逐项对齐，改一处必须改另一处。
- `list_components` 用 `app/assets/engine/components.json` 快照；`list_templates`
  直接问引擎。快照与 wasm 活注册表的一致性由 `scripts/sync_engine.py` 探针逐 id 对账。
- 引擎自渲染 SVG 是内容层唯一真源：画布/演示的内容层用引擎返回的 `svg`，
  本地 painter 只做选区/悬停/手柄等覆盖层。

## Agent 层约定（Dart）

- 循环在 `app/lib/core/dart_agent.dart`；`design_op` 必须经
  `EngineGateBridge`（生产是进程内 `EngineService`，`gate:'agent'`），绝不直写 mbt。
- 生产 LLM 调用套 `StreamToolNameGuard`（`app/lib/core/agent_model_middleware.dart`）：
  StepFun step_plan 流式把工具名只放首个 delta、后续 delta 重复 `name:""`，
  ai_sdk_openai_compatible 逐 delta 覆盖会以空名发出工具调用
  （`AiNoSuchToolError` 打死整轮）；守护按 toolCallId 回填首个非空名。换 SDK
  版本时抓包复核该方言是否仍在。
- **工具修复（tool fix，2026-11-20）**：守护同时做模型笔误的近名修复——先严格同名，
  再命名规范变体归一（`namespace.tool` 逐段剥前缀 / `tool()` 去括号 / 结尾冒号分号 /
  前后空白 / 全角折叠 / 大小写 / `_-.` 空格归一），最后编辑距离 ≤4 且唯一最近且
  公共前缀 ≥2 才改写（宁可不修不可修错）；`llm_no_such_tool` 的等待重试轮会在
  prompt 顶部追加 `Available tools: …` 清单，让模型从真实工具名里挑正确的，
  而不是同一错名再撞一次。新增工具/改名时同步 `knownTools` 来源（`_buildTools` keys）。
- **模型方言（MiniMax）**：M3.x「自适应思考」模型强制开启思考，
  `thinking.type=disabled` / `reasoning.effort=none` 会 400；且 `auto`
  默认单轮 60–163 s。`providerThinkingOptions` 把 `auto/off/none/minimal/空`
  统一落线为 `reasoning_effort: low`（实测 ~19.5 s/轮，工具调用正常），
  显式档位原样透传。新增 provider 前先抓包/探针确认方言，再写映射。
- **答题卡纪律（2026-11-20 用户裁决变更）**：`ask_user` 在**所有模式**（含钉死工作台的
  workspace run）都真能出答题卡——不再有 `ask_user_unavailable` 拒答死路。内容/方向
  决策照常问；只有「确实需要换到另一个工作台」时才带 `switch_to`（工作台枚举）。
  用户答案回流 `handleChatAction` 时**真正切换** chatWorkspaceMode + 视图再续跑——
  答案必须改变执行路径，不是换个措辞再问一遍。选 `design` 时视图回到设计画布
  （`_switchViewForWorkspace`）。**只有最后一张答题卡可点**（历史卡灰化禁点）；
  run 中最后一张可点，答案入队等本轮收尾续跑。
- **工作区产物认领（2026-11-20）**：工作区 run 里成功的 `three_create/three_pass/
  three_status/three_continue/three_feedback`、`hotapp_generate/refine/inspect/
  from_prototype`、`video_create` 由 `AppStore._handleAgentEvent` 的
  `_rememberWorkspaceArtifact`/`_adoptWorkspaceArtifact` 写进
  `settings.threeProjectName` / `hotappApp` / `videoProjectName` 并 notify；各工作台
  监听 store 自动切项目/刷新列表/重挂预览。**没有这一步就是「run 说做完了，工作台里
  没有东西」**。工具失败不认领（失败的项目不存在）。新增产出型工作区工具必须同时
  接这条链 + `toolLabel`/`toolFailureMessage` 映射。
- **视频生成工具（2026-11-20）**：视频是代码动画，生成落地面 =
  `VideoProjectStore`（`core/video_project.dart`，`<项目根>/video/<name>/` 的
  timeline.json + spec.json + video.json，先过 `VideoDocument.build` 预编译再原子落盘）。
  工具三件套：`video_sample`（拿 3 个内置示例的完整 timeline+spec JSON 学格式）→
  `video_create`（name/timeline/spec/title，失败码统一 `video_<code>`）→
  `video_review`（机械对照）；`video_list` 列生成项目 + 内置示例。**成片导出仍屏蔽**
  （`video_render` 只回 `video_export_disabled`，不落 mp4）。
  **方案线（未施工）**：视频新增第三种风格 `ink_line`（墨线手绘，2026-11-22 用户裁决）——
  只借 line-art-animation 的笔宽/开放双笔触/步态求解/昼夜/帧条验收规则，不引入其
  TS/SVG 库；`silly_skit` / `line_toon` 与 Phaser 3 裁决不变。VFX 层直接引入
  **pixelfx 特效子集**（只取火焰/冰霜/风/爆炸等，不取人物/stock actor/moves），
  以 `{f,type:"vfx",cue,...}` 事件接入 `screenplay.json`；cue 走 allowlist。
  统一创作流程见 `docs/skills/creative-workbench/SKILL.md`。
  **候选风格 `toon_3d`（2D 角色 + 3D 世界，2026-11-24 调研，待裁决）**：参考
  claude-animated-shorts 的 8 段脚本/词级时间/镜头表/look/QA，执行面用 three-live；
  不引入 Remotion/React/Node/Chromium。见
  `docs/research/claude-animated-shorts.md` 与
  `docs/skills/creative-workbench/references/story-short.md`。
  详见 `docs/research/line-art-animation.md`、`docs/research/pixelfx.md`、
  `docs/research/awesome-opus5-5-videos.md`。
- **终态诚实**：`done.stopReason == 'text_only'`（模型只回文字、零操作）不算
  成功——不做假「已更新」；failed/done 到达即收进度卡与在途工具行，不留转圈。
- **卡死锁自愈**：`agentBusy` 超过 35 分钟自动解锁（`_clearStaleAgentLock`，
  正常 run 死线 30 分钟），另有 `debugForceIdle()` 供自动化。
- LLM 请求失败走「分类 → 等待重试 → 人话文案」三段（`classifyLlmError` /
  `isRetryableLlmError` / `toolFailureMessage`）：网络（含 `HttpException` /
  `Connection closed|reset` 断流）、限流（429）、网关 5xx、超时一律最多
  **10 次重试、每次 30 秒**（用户裁决 2026-11-20；`debugRetryWaitsOverride`
  供测试压到毫秒）。失败事件 `error` 带分类码、`detail` 保留原始异常。
- **交付水位前移后断线 → 断线续跑，不重发、不判死**：重建新鲜项目地图/
  文档上下文（`_continuationPrompt`），让模型从断点接着做完，最多 10 次；
  已完成内容绝不重复执行也绝不丢弃。
- `toolLabel()` 是工具名的唯一出口；新增工具必须同时补文案映射与失败码映射。
- 流式事件面保持稳定：`assistant_text` / `assistant_thinking`（仅文档阶段）/
  `thinking_delta` / `doc_delta` / `tool_start` / `tool_end` / `doc_written` /
  `page_generated` / `preview` / `done` / `failed`。`done` 与 `failed` 必须成对
  可判——**每条 run 都要有终态**，不能静默结束。
- 续跑策略：模型只回文本、没有交付文档/画布操作时，自动再跑一轮 nudge；文档阶段仍缺
  文档则报 `doc_not_written`，不伪装成澄清。
- **工具结果必须整形**（剥 mbt/svg、节点/数据截断、追加 `state` 卡），避免吃光上下文。
- **源码编码纪律（2026-11-20 事故）**：本机 `pwsh` 是 Windows PowerShell 5.1，用
  `(Get-Content -Raw) | Set-Content/Out-File` 往返 UTF-8 源码会把中文尾字节写成 `?`
  并偶发吞掉相邻 ASCII（一次 `-replace` 就毁掉 `dart_agent.dart` 757 处中文，全仓测试
  编译失败）。**禁止用 pwsh 管道重写源码文本**；只允许 `write`/`edit` 工具或显式
  UTF-8 的 Python/Dart（`encoding='utf-8'`, `newline=''`）。PowerShell 显示中文乱码
  ≠ 文件损坏，判断一律以严格 UTF-8 解码 / `dart format --output=none` 为准；
  `dart analyze` 对非法 UTF-8 会误报 No issues，不能当编码校验。
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
- 平台壳：macOS 为主开发目标。**所有应用内 WebView 统一走 `webview_all`**
  （macOS/iOS WKWebView、Windows WebView2、Linux WebKitGTK、Android WebView）：
  3D 预览、热应用、视频播放和个人资料页共用同一套 `WebViewController`；
  不要再新增 `Platform.isWindows` 的 WebView 分支或第二套 WebView 依赖。
  视频工作台的矢量代码动画全平台一致（纯 Dart 逐帧）；mp4 内嵌播放随
  `webview_all` 全平台，能否解码取决于系统 WebView 自带编码器。
  见 `docs/plan-cross-platform-runtime.md` §1。
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
- **工作台链路锚点（2026-11-20）**：`workspace_chrome_test.dart`（四工作台共用外壳；
  面板/主区/状态栏一致）、`workspace_artifact_adoption_test.dart`（成功工具事件 →
  `settings.*ProjectName` 认领 + notify）、`video_project_test.dart`（视频项目落盘
  硬门/原子性/坏项目隔离）、`video_workspace_test.dart`（生成项目自动切换 + 读失败
  人话）、`hotapp_workspace_agent_test.dart`（热应用自动切应用/精修后按 epoch 重挂
  WebView2）、`dart_agent_tools_test.dart` 的 `workspace mode tool surface`（workspace
  run 必须暴露 three_*/video_*/hotapp_*，且不含画布/文档工具）。改这些链路必须同步
  跑对应锚点。
- **Windows 逐字节契约（2026-11-20）**：`app/assets/a2ui_web/**` 与
  `app/test/fixtures/**` 由 `.gitattributes` 钉成 LF，DDP 容器 `.ddp` 标 `-text`
  二进制——这些是 sha256 / golden 逐字节断言，别再让 `core.autocrlf` 改字节。
  **`app/assets/three/**` 全部 `-text`**：`three.module.js` 被 `three_service.dart`
  按 `threeModuleByteLength = 1272972` + sha256 硬校验，CRLF 会让它变 1,326,016 B，
  Windows 上直接报「预览文件缺失」（2026-11-20 实机复现并修复）；`app/assets/engine/*.wasm`
  同样 `-text`。新增「哈希/golden/字节锁定产物」目录时同样加 `.gitattributes` 规则。
- **Windows 真机冒烟（2026-11-20，仓库外 diag/）**：`flutter run -d windows --debug`
  + VM Service 直驱（`diag/vm_smoke_drive.dart` / `diag/smoke_run.ps1`）在真实应用里
  依次打开设计/3D/视频/热应用四个工作台并截图，验证「同一套外壳」；`diag/seed_video_project.py`
  造一个生成项目后视频工作台能显示并逐帧播放（实测 240 帧 / 8s，与 seeded 项目一致）；
  `diag/vm_three_drive.dart` + `diag/smoke_run3d.ps1` 调 `ThreeService.preparePreview`
  后 3D 工作台 WebView2 真渲染（这条冒烟就是抓出 three 资源 CRLF 字节漂移的入口）。
- **Windows 路径/时序纪律（2026-11-20）**：源扫描守卫与路径断言必须先把 `\` 归一
  成 `/` 再比较（`architecture_guard_test` / `acceptance_local_core_test` /
  `toast_test` / `project_service_test` 已修）；`wasm_run` 的 Windows 加载器会给
  无扩展名路径补 `.dll`：wasm-spike 测试在缺 `.dll` 垫片时会把 vendored 库复制到
  带 `.dll` 的临时路径再加载（工作树里不再要求垫片；本机若放垫片也不计入 15 个
  vendored 目标库）；RPC 宿主超限请求体先有界排空再回 413；`desktop_rpc_host_test`
  的「对端消失 → keep-alive 取消」在 Windows loopback 不可观测（测试平台跳过，
  取消链路由 `agent.cancel` 用例覆盖）。`engine_host_test` 的移动端首帧/p95 预算
  按桌面原生执行器定，Windows（pulley 解释器）上测试按 ×4 余量判定
  （`budgetFor()`，只放宽预算不断言语义）。

## 已知限制（v0.1，2026-11-18 清理后）

- **Windows 执行器 = wasmtime 50 + pulley 解释器（仅 wasm_run 兜底，2026-11-20）**：
  生产主路径已不走它（classic wasm 在 WebView2 里执行）；下面记录保留，供兜底排障：
  原生 Cranelift 陷阱传输在 cdylib+宿主（dart/flutter_tester）环境必然
  `panic in a function that cannot unwind` abort（wasmtime 20/26/30/50 ×
  rustc 1.90/1.100 实测；纯 Rust exe 全部正常，属 Windows cdylib 平台缺陷）。
  vendored DLL 改用 pulley 解释器 target（`config_api.sh wasmtime` +
  `config.rs` 里 `target("pulley64-unknown-none")`），陷阱回落普通 Rust Err
  → fuel 看门狗/超时恢复链路可用（engine_host_test 42/42 全绿，含此前在
  Windows 从未跑通的 fuel spin 用例）。代价 ~5-15x 执行减速，render/apply
  预算余量充足。DLL sha256 pin 在 `fetch_wasm_run_libs.sh`（07d75e17…）。
  源码补丁（相对上游 main@23e36bdf）：wasmtime 依赖升级 + WASI 路径移除 +
  fuel API 迁移（get/set_fuel u64 + 本地记账）+ wasm 执行点 catch_unwind。

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
- 移动端本地引擎默认开启（WebView 内 classic wasm）；iOS/Android 真机 smoke 与
  p95 证据仍待补，失败时如实回落「连接桌面」。
- **OHOS 离屏 WebView 缺口**：`webview_all_ohos` 目前没有 `supportsOffscreenWebViews`
  实现，OHOS 上 `startAuto` 会回落到 wasm_run（若该目标没有执行器则 engine_unavailable）；
  补法是等上游实现或给 OHOS 走隐藏 `WebViewWidget` 宿主。
- **Windows/Linux WebView 引擎尚未本机真机复验**：macOS WKWebView 已由
  `integration_test/engine_webview_test.dart` 实跑通过；Windows WebView2 / Linux
  WebKitGTK 采用同一 `OffscreenWebViewSession` 契约，需在对应机器上跑同一测试。
- Android debug APK 构建链已修复（`MainActivity.kt` 非空收窄，1fa3a78），可
  产出 debug APK（本会话未复跑 build 复证产物）；本机无 Android 设备/AVD，
  arm64 wasmtime 加载与 `_in` ABI 的真机验收仍未完成。
- 外部智能体（ACP）桌面独占；移动端按设计禁用。
- **应用内 WebView 已统一**：3D / 热应用 / 视频 / 资料页共用 `webview_all`
  （macOS/iOS WKWebView、Windows WebView2、Linux WebKitGTK、Android WebView）；
  旧的 `webview_windows` 依赖与 `*_preview_win.dart` 已删除。视频 mp4 产物内嵌
  播放的可用性取决于系统 WebView 编码器；失败仍保留「复制路径/在文件夹中显示」
  降级面（`shelf_video_player_test.dart` 按能力矩阵断言）。
- API Key 明文存本机 `SharedPreferences`（并镜像 `~/.nondesign/settings.json`）；
  Keychain 未接。

## 版本

`VERSION` = `0.1.0`（唯一版本源；`app/pubspec.yaml` 同步）。文档状态见
[docs/README.md](docs/README.md)（已实施 / 方案定稿 / 历史快照三态总纲）。
