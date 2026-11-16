# AGENTS.md — NoNDesign

AI 原生创作工作台。**一句话 → 产品需求设计文档 → 完整可交互原型**；同一工作台
还能做 3D 场景、代码生成视频与带 SQLite 数据库的 NoN 热应用。

**技术栈（用户决策，2026-11-13）：Flutter 3.50（macOS 主目标；linux/windows 平台壳已就位）+ Python OpenAI Agents SDK。
不要重新引入 Bun、Tauri 或任何 JS 前端运行时。**

## 架构边界（改代码前先读）

```
app/          Flutter UI + 原生 CustomPainter 画布（无 WebView、无 HTML；
              3D 工作台落地后唯一 WebView 是应用内预览，见插件轨道）
server/       Python FastAPI + OpenAI Agents SDK + wasmtime 引擎宿主 + DDP
engine/       MoonViz classic wasm（纯 WASM MVP、零 import）+ components.json
figma-plugin/ Figma 双向插件（manifest.json 开发目录，可编辑图层双向桥）
plugins/      独立插件：video-engine/ 代码生成视频（零 Flutter/服务器依赖）
app/lib/plugins/  插件工作台注册表（3D/视频独立 UI，与设计板块解耦）
```

- **NoN 热应用引擎 + 作品集（2026-11-16 立项，灵闪/Dots 式）**：热应用 =
  **自包含单 HTML + SQLite**（全内联零外链，动画优先 canvas/SVG/CSS keyframes）——
  「热更新」= 覆盖文件 + WebView reload（与 3D 同构；Flutter 热更新无官方
  能力不务实）。server/hotapp_agent.py（generate/refine/page/list/delete +
  **db_exec** + fail-closed：结构校验不过拒绝覆盖——旧版仍在热更新无损坏风险）。
  **持久层统一 SQLite**：每应用 `app.db`，页面经注入的
  `window.NoN.db.exec(sql, params)` 调 `POST /hotapp/db/{name}/exec`
  （单语句、参数化、禁 ATTACH/DETACH/PRAGMA/VACUUM/LOAD_EXTENSION；
  业务数据禁 localStorage/IndexedDB/cookie——WebView 重载即丢）。
  应用目录 `~/Documents/NoNDesign/hotapps`（旧 `hotapp`/`a2ui` 目录启动时
  自动并入，作品集旧条目归一为 hotapp）；**作品集横切收藏夹**
  （portfolio/index.json 聚合 hotapp/video/three 三类，存量 mp4/3d 自动补扫）；
  客户端 hotapp_workspace.dart（对话式修改条即热更新入口）+
  portfolio_view.dart（类型过滤网格/打开直达/移除）；registry 第 3 插件
  hotapp（⌘7），portfolio 独立视图（主页卡 + 标题栏入口）。
  v1 质量环 = 结构/外链校验（全内联零外链硬门；服务端在 `</body>` 前注入
  DB 桥 + window.onerror/unhandledrejection → NONHOTAPP 桥回传，页面 CSP
  `connect-src 'self'` 第二道防线）；视觉截图（canvas toDataURL）v2。
- **移动客户端（2026-11-16 立项，双层架构）**：ios/android 平台目标已生成
  （iOS debug 构建 38.7s 实证通过；**Android toolchain 缺失**——SDK 未装，
  apk 构建待装后验证）。主页 welcome 加「工作台」插件区（注册表驱动）。
  手机两层模式：① **连接桌面**——settings.serverUrl（设置面板输入）→
  ServerLauncher.manualBaseUrl → launch 优先连接桌面服务器（LAN 全功能，
  引擎 MoonViz 无法在移动端运行）；② **PLAN 直连**——无服务器时 Dart
  AI SDK（ai_sdk_dart 3.1 + ai_sdk_openai，**非官方 OpenAI Agents SDK，
  Dart 生态无官方版**）本地跑文档生成（core/mobile_agent.dart，
  write_doc 工具语义对齐 server PLAN；工具参数无流式增量，事件式而非
  逐字直播；RSI 依赖引擎不在直连范围）。store._runAgent 分流：
  api==null && mode==plan && 有 key → _runMobilePlan。
- **移动端真机验证（2026-11-16 晚，iPhone 17 / iOS 27.2 模拟器）**：Xcode 27 的
  Simulator runtime 已装；`flutter build ios --simulator --debug` 30–46s。真机截图
  抓出 Welcome 桌面双栏在 402×874 下右溢 198px、底溢 327px（右列被压成单字竖排、
  开始按钮叠到作品集卡上）→ 窄屏改单列滚动 + SafeArea + 输入卡 chips 换行
  （welcome.dart 的 `_mobileBody`/`_briefCard`）；`app/test/welcome_mobile_test.dart`
  锚定 402/390/375 无溢出、1440 保持双栏；`integration_test/mobile_smoke_test.dart`
  在模拟器实测 Welcome→3D 工作台→返回。**Android**：SDK platforms/build-tools/NDK
  28.2 已装，但 `flutter build apk --debug` 在 Gradle 9.5/AGP 9.3.1 下启动即挂起
  （daemon 无网络活动、无任务输出），待专项排查。
- **移动端第二轮优化（2026-11-16 深夜，402×874 全界面真实渲染审计）**：文档视图
  tab 行右溢 58px、文档工具条/底部提示条各右溢 246px、空画布卡固定 520 宽、
  视频工作台 300px 固定配置列把帧预览压到 102px、设置弹窗 860×600 被夹成 310 宽、
  Workspace/插件/作品集全无 SafeArea。修复：统一 SafeArea；DocsView 工具条窄屏
  收紧（tab 紧凑、动作改图标态、键盘提示隐藏）；空画布卡限宽 + Expanded + Wrap；
  视频窄屏改单列滚动（配置在上、预览固定 280 高）；设置弹窗窄屏全屏 + 顶部横向
  导航条；状态栏/画布 HUD 的桌面键盘提示在窄屏隐藏。回归：
  `app/test/mobile_surfaces_test.dart`（402/390 × 视频/3D/热应用/作品集/文档/设计/
  演示/设置/底部 sheet 共 19 项 + 宽屏视频双栏）；全量 48 项测试绿；模拟器截图
  复核文档/设计/视频/设置四屏。
- **响应式字号与 iPad 三档布局（2026-11-16 深夜）**：字号在渲染期统一缩放——
  `theme.dart::responsiveTextScale`（手机 +10% / 平板 +5% / 桌面 1.0，与系统
  文字大小相乘并钳 1.0–1.3），`NonApp.builder` 经 `withResponsiveTextScale`
  注入，测试走同一路径；字号声明仍守 8 档字阶，不为手机另维护一套字号。
  Workspace 三档断点：手机 <700（左右栏均底部 sheet）、平板 700–1024
  （左栏常驻 + 右栏 sheet）、宽屏 ≥1024（三栏全开）；Welcome 双栏断点降到
  700（iPad 竖屏不再走手机单列）。**测试基建修正**：`setSurfaceSize` 只改渲染
  表面、不改 MediaQuery（builder 里恒 800×600）——手机/平板测试必须设
  `tester.view.physicalSize`；修正前「手机宽度」测试实际跑的是桌面分支。
  回归：`tablet_layout_test.dart`（768 竖屏双栏/左栏+右栏 sheet、1024 横屏
  三栏、视频/热应用/作品集/设置）+ 手机测试全量 **54 项绿**；模拟器 iPad Pro 11
  竖屏与 iPhone 17 截图复核。
- **移动端能力面实测与第三方智能体禁用（2026-11-16 深夜）**：① **ACP 在移动端
  禁用**（用户裁决）：设置页隐藏「外部智能体」、Agent 面板强制 NoN 内置
  （残留 acpAgentId 不生效）、`store.runAcp` 在 iOS/Android 直接拒绝并提示。
  ② **真机 DDP 渲染验证**：iPhone 17 连接桌面服务打开 `nopass.ddp` → 引擎解密/
  渲染 3 块 390×844 画板 / 34 节点，CanvasView 正常出图（OpenResult.opened）。
  ③ **3D 真机空白根因**：`/three/scene/{name}.js` 以 text/plain 返回，WKWebView
  拒绝模块脚本（"'text/plain' is not a valid JavaScript MIME type for module
  script"）→ 改 `application/javascript`，iPhone 上土星场景正常渲染。
  ④ **视频端点脚本启动漏注册**：`if __name__ == "__main__": main()` 位于
  /video/* 路由之前，桌面 App/移动端按脚本启动时 `/video/sample` 等 404 →
  入口移到文件末尾；真机验证示例加载、环② spec 对照 PASS（8.0s）、后台渲染
  出帧条带。回归锚点 `scripts/wf/test_server_routes.py`（入口顺序 + scene MIME +
  六条路由在场）。**能力矩阵**：设计/画布/3D/视频/热应用 在移动端均需连接桌面
  服务（引擎 wasm、three 预览、resvg/ffmpeg、LLM 都在桌面）；离线移动端只有
  PLAN 直连文档（Dart SDK），不承诺引擎能力。
- **插件工作台 UI 与设计板块解耦**（用户裁决 2026-11-16 二次确认）：
  `app/lib/plugins/registry.dart` 是注册表——每插件一个 PluginDef（id/
  图标/builder），视图路由 `plugin:<id>`，顶栏入口与 ⌘5/⌘6… 快捷键按
  注册顺序动态派生（workspace.dart 的 _pluginDigitKeys 数字键池容量 =
  并存插件上限）。新增插件零散落接线：写工作台 widget + 注册一条即可。
  3D 项目名持久化在 AppSettings.threeProjectName（工作台视图切换即
  dispose，不持久化会「切走再回来全丢」）。
- **插件轨道与引擎解耦**（用户裁决 2026-11-16，详见 docs/plan-plugins.md）：
  **Figma 双向桥 / 3D 制作工作台 / 代码生成视频 = 客户端能力加强**，不改
  引擎、不依赖引擎产物；**RSI 递归视觉修复例外——design 模块内置质量环**
  （run 循环里逐屏 critique → auto_fix ≤2 轮），不是插件。
- **Figma**（已落地）：服务端 `/project/export/figma`（SVG 包 +
  nondesign.json manifest）+ figma-plugin/ 双向桥。⚠️ 事故登记×2：
  ① 路由曾错挂 `/acp/prompt`（FastAPI 同路径先注册者胜出 → ACP 对话
  全部命中导出函数 422）——改 `/project/export/figma` + RenderRequest
  body（大 mbt 不能走 query，h11 头 16KB 上限）；② 插件 Import 曾读
  顶层 n.x/n.w——引擎 manifest 几何在 `n.rect`（真机 dump 实证），
  顶层字段全 undefined，导入图层塌到原点——geomOf() 兼容读取。
- **代码生成视频**（已落地，`plugins/video-engine/`，独立管线；视频工作台
  UI + /video/* 端点已接——sample/review 环②/render 后台 job 轮询/帧
  serve；**无声版**，用户裁决音轨旁白暂不做。⚠️ 真 bug×3 登记：① mp4
  产物名错位（render.py 写 frames.mp4，job 查 <jobid>.mp4）；② spec
  落盘曾固定 spec.json 文件名——art-sketch 引 screenplay.json 会 miss
  （load_spec 相对引用），必须按 timeline 引用名落盘；③ to_thread 直传
  sp.run 的 kwargs dict 会落进 bufsize 位置参数——lambda 包齐。）：
  timeline DSL → 逐帧确定性 SVG → resvg（CJK 已验证）→ ffmpeg。
  **双强制纪律是管线硬门不是提示词**：① spec 先行（science/screenplay
  两形态，`spec_missing` exit 2）；② expr 符号声明闭包（自定义标识符
  必须在 spec.params ∪ spec.formulas，`undeclared_symbol` 拒绝——
  「想当然」的裸坐标进不来）。RSI 三环：结构校验（render 内）→
  spec 对照（review.py 机械）→ 抽帧+提示词给评审 agent vision 打分
  （scripts do enforcement; agent vision does judgment）。
  ⚠️ 真 bug 登记：**含 t/T 的公式曾在 T=0 常量化**——时间相关公式必须
  求值期展开（Expr 留在 env，Name 求值时递归），否则运动钉死在起点、
  读数恒 0（首版冒烟真机抓出）。渲染前全量预编译（fail-closed：
  语法/符号错误在第一帧前报干净）。三标杆示例在 examples/（物理摩擦力
  = 真实性门面，读数 v=17.47=x·T 实测吻合）。
- **审查批次（2026-11-16 下午，9c2e246 + 31f6eac）**：36 条发现（四路审计 + 逐条独立复核）→ 两批落地 29 项。关键面：op 在飞串行队列（丢更新整类消除）、EngineSvgPrep svg 兼容预处理（feDropShadow 改写白名单链 + 网络 image 预取 data:——flutter_svg 渲染链只支持 data: URL 的实锤复现）、3D 状态机竞态封堵（run_pass await 后重读盘上状态只写 status）、done 终态 500、turntable 四方位取证 + spec 手编回灌、插件视图三出路（返回按钮/根级 ⌘5⌘6/Esc）、检查器补原版外观与布局入口（阴影/描边/斜体/dash/尺寸模式/容器布局）、**演示墨迹随项目文档持久**（nondesign:ink 尾块幂等注入/打开解析，对齐原版 inkPersist）、**3D 预览离线化**（three.module.js vendored + MiniOrbit 自实现轨道，unpkg 单点消除）、**PLAN 文档流式直播**（_DocDeltaExtractor 提取 write_doc 参数 content 增量，7 例单测；客户端 docs_view 自动切流式渲染视图）。
- **3D 制作工作台**（C1 骨架已落地，方案见 docs/plan-plugins.md 轨道 C；server/three_agent.py + /three/* 端点 + widgets/three_workspace.dart，mock LLM 全链 E2E 11 步绿）：
  LLM 生成 three.js 场景代码，**应用内 WebView 即执行面**（不引外部
  浏览器/headless）——执行错误 window.onerror 回传、场景几何自检、
  canvas.toDataURL 截图给 vision 评审，三反馈驱动 RSI 修复轮。
  吸收 img2threejs：spec 先行 + 分 pass 生成（blockout→structure→form→
  material→lighting）+ build-state.json 状态门禁 + 确定性几何门先行
  （turntable 四方位/自相交/锚点）、AI vision 殿后 + fail-closed（门不过
  不交付）。3D 项目独立存储（~/Documents/NoNDesign/3d/），不走 .mbt.md/
  .ddp（「唯一事实源」纪律只管 2D 原型线）。平台注册：wkwebview 3.27.2
  真实 API 是 `WebKitWebViewPlatform.registerWith()`（无 endorsed macOS
  实现，首次使用前幂等注册）。

- **唯一事实源**：一份 canonical `.mbt.md`。人类画布操作（HumanGate）与 Agent 操作
  （AgentGate）都必须经引擎校验后回写同一份文档；`.ddp` 只是它的认证加密容器。
- **Flutter 不解释视觉语义**：它只渲染引擎返回的 `artboards[].nodes[]`、发送 op、
  展示事件。不要在 Dart 里"顺手"改布局/属性——变更必须回到引擎。
- **Python 是唯一 Agent 宿主**：`server/agent.py` 拥有 Agent 循环、tools、上下文与
  会话；Flutter 只消费 SSE 事件。不要在前端复刻 LLM 协议。
- **引擎宿主只有一处**：`server/engine.py`（wasmtime）。所有 `_in` 槽协议、
  字符串读 ABI、session 缓存、epoch 超时都在这里；Flutter 不直接碰 wasm。
- **上下文分层**：静态指令 → PROJECT MAP → 设计规范/文档 → 会话记忆 + 最新 state。
  稳定前缀不要插入时间戳/随机序；变更走追加式 state 卡，不重写历史。
- **模型与端点**：`server/models.json` 是 models.dev 的 vendored 快照；`server/models_store.py`
  负责刷新。不要硬编码模型能力，能力轴以快照为准；线上方言（thinking 等）单独裁决。

## 常用命令

```bash
# Python
python3 -m venv .venv
.venv/bin/pip install -r server/requirements.txt
cd server && ../.venv/bin/python main.py --port 8799
.venv/bin/python -m compileall server

# 引擎 / 模型
.venv/bin/python scripts/sync_engine.py           # 校验/下载 wasm，真机 render 探针
.venv/bin/python scripts/sync_models.py           # 刷新 models.dev 快照

# Flutter
cd app
flutter analyze
flutter test                                      # widget + SSE 测试
flutter run -d macos                              # 自动拉起 Python 服务
flutter build macos --debug
```

服务端默认绑定 `127.0.0.1` 的临时端口，Flutter 启动时读取
`~/.nondesign/server.json` / stdout 拿到端口。`NONDESIGN_SERVER` 可指向已运行服务。

## 引擎 ABI（不要凭猜测改）

- 写方向：`in/arg/arg2` 三槽，UTF-8 分块（每块小端 4 字节 + 有效长度），调用
  `*_in()` 变体。`server/engine.py::_slot` 是唯一实现。
- 读方向：引擎返回字符串指针，布局 `[len@ptr-4][UTF-16LE@ptr]`；
  `_read_str` 是唯一实现。
- 每次调用（包括 `version_info`）都要重设 epoch deadline；ticker 线程持续推进时钟，
  闲置后不重设会立即 trap。trap 后必须丢弃 session 并重建实例。
- 会话 API 按 canonical MBT 键控；变更信封的 `mbt` 必须回写缓存。任何 trap/腐坏读
  都弃缓存。
- `list_components` 用 `engine/components.json` 快照；`list_templates` 直接问引擎。

## Agent 层约定

- `server/prompts.py`：Plan / Build / Refine 三套静态提示词 + 公共 footer。改提示词时
  守住"生成优先"、"按钮不卡文案"、"对比度硬规则"、"列表分隔线"、"flow 绑容器"这些引擎规范。
- `server/agent.py`：tools 用 `@function_tool(strict_mode=False)`；参数用普通类型，
  不要依赖 strict JSON schema（兼容网关会碎）。
- 续跑策略：模型只回文本、没有交付文档/画布操作时，自动再跑一轮 nudge；Plan 模式仍缺
  文档则返回 `doc_not_written`，不伪装成澄清。
- 工具结果必须整形（`compact_envelope`）：剥离 `mbt`/`svg`，节点截断 24、数据截断 40，
  追加 `state`。
- 会话：`CompactingSession` 保留最近 18 条 + 确定性摘要；>80 条压缩；不额外调用 LLM。
- 取消：`/agent/cancel` → `RunResultStreaming.cancel()`；SSE 必须始终有终态事件。

## DDP

- DDP1：`DDP1` + version + salt16 + nonce24 + XChaCha20-Poly1305(zstd(payload))，
  AAD = header。Argon2id m=19*1024 KiB, t=2, p=1, len=32。
- DDP2：`DDP2` + version + CRC32LE + zstd(payload)。
- 与 deepDesign Studio 的 Rust codec 已做双向交叉验证；改 codec 必须重新对账。
- 文档标记：`<!-- nondesign:design {...} -->` / `<!-- nondesign:docs {...} -->` 放文末；
  JSON 中 `>` 必须转义为 `\u003e`，否则引擎注释扫描器会在 `-->` 截断。

## Flutter 约定

- 状态：`AppStore extends ChangeNotifier`（provider）。所有会改项目的异步操作串行
  经过 store；不要绕过 store 直接调 API。
- **右栏结构（2026-11-13 拆分）**：`right_panel.dart` 只是 91 行壳（RightPanel 组合），
  `agent_panel.dart`（Agent 面板/时间线/模式芯片）与 `inspector_panel.dart`（检查器/
  字段件/交互/状态/页面健康）走 `part of` 共享私有类——**part 文件不得带 import**，
  全部依赖声明在库文件（right_panel.dart）头部；往右栏加类时先问归属（Agent vs
  Inspector），别再往任一 part 塞对方领域的东西。
- 画布：`CanvasView` + `ArtboardPainter`；节点命中区用透明 `Positioned` 覆盖；
  拖动只更新本地 ghost，松手才发 `move` op。
- 设计令牌：`core/theme.dart` 的 `NonPalette` 是唯一颜色源；不要在 widget 里散落硬编码色。
- 本地化：当前简体中文；文案集中在 widgets，后续接入 i18n 时再抽表。
- **快捷键（2026-11-13 起，全平台）**：绑定与展示标签统一走 `core/keys.dart` 的
  `modKey()`（macOS=meta/⌘，Windows/Linux=control/Ctrl）与 `modCombo()`（标签把
  ⌘→Ctrl+、⇧⌘→Ctrl+Shift+）。**不要在 workspace/docs 里手写
  `SingleActivator(..., meta: true)`、也不要散落硬编码 ⌘ 标签**——加新快捷键时绑定与
  标签各取一处助手，两处缺一就是「按得动但看不见」或「看得见但按不动」。
- 平台壳：macOS 为主开发目标；`linux/` `windows/` 由 `flutter create
  --platforms=linux,windows` 生成（2026-11-13），窗口标题 NoNDesign，快捷键即经
  keys.dart 自适应；跨平台构建未在本机验证（无 Linux/Windows 环境），首次在对应平台
  构建时先补依赖再跑门禁。
- macOS Runner 已关闭 App Sandbox（本地 Python 子进程 + `~/.nondesign`）；不要随手加回
  sandbox 而不补 network client / app container。
- 窗口：`MainFlutterWindow.swift` 固定在主显示器居中，避免 macOS 恢复离线显示器坐标。
- **动效与控件一致性（2026-11-13）**：时长/曲线只取 `NonMotion`
  （fast 120 / base 180 / slow 240ms，easeOutCubic）——不要散落裸 Duration。
  对话框统一 `showNonDialog`
  ——注意：nonSelect 底层是 **M3 DropdownMenu**（菜单行 MenuItemButton，高度可收敛
  32px）；经典 DropdownButtonFormField 有运行时断言 `itemHeight >= 48`（2026-11-14
  红屏实证，analyzer 抓不到 runtime assert——改它必须跑一次真机/测试打开菜单）。
  entry 高度对必须规范化：`Size.fromWidth` 的隐含高度是 Infinity，与
  `maximumSize` 高 32 组成 min>max 即崩。回归锚：test/nonselect_test.dart。（fade+scale 入场，barrierColor 可覆盖）；下拉统一
  `nonSelect(context, …)`（菜单配色/圆角 10/高度上限 280/箭头一处定义，
  inspector/settings 全部 DropdownButtonFormField 走它）；右键菜单与浮层走
  popupMenuTheme/dialogTheme 全局主题。改这些助手时全端生效，别在调用点
  再写一份局部样式。

- **引擎渐变/italic 真相（2026-11-16 探针修正）**：引擎原生支持渐变与
  斜体——语法是 **Paint v2 DSL**：`fill=linear:#c1:#c2@deg`（radial 同形
  无 @deg）、`italic=true`；**不是 CSS `linear-gradient(...)`**（写入会
  以原始串存 fill，svg 输出非法属性）。R2 曾把 CSS 解析加进
  ArtboardPainter——保留为旧信封回退，SVG 在场时由引擎渲染（defs 合成
  + fill url 引用自动完成）。NoN 侧不再需要自解析新渐变。
  已知边界：place k=v 对 rotate=/blur= 仍静默丢弃（update 路径 ok），
  上游 issue 材料已备。

- **引擎自渲染为内容层唯一真源（2026-11-16 用户定案）**：引擎 0.2-dev 的
  render 信封每板携带完整 svg（<style> 系统字体/defs 三档 feDropShadow/
  rotate transform/网络 <image>+clip-path/板底 rect 全在，真机探针实证）——
  **客户端不重复实现节点渲染**：canvas_view/play_view 内容层 = `SvgPicture.
  string(board.svg)`（flutter_svg），ArtboardPainter 降为覆盖层（overlayOnly：
  选区环/悬停/手柄/拖拽幽灵框；旧信封无 svg 才回落整节点绘制）。
  演示入场呼吸改对整 svg 层 FadeTransition。已知引擎侧边界（登记不修）：
  fill=linear-gradient(…) 以原始串写入 fill 属性、未合成 defs（svg 规范外，
  上游修）；italic 未落 svg。/engine/render 保留 svg（仅提板底色），agent
  工具结果的 compact_envelope 仍剥 svg（LLM 上下文不需要）。
  锚点：test/engine_svg_test.dart（真机 svg fixture 解析契约）。

- **deepDesign 对账补齐（2026-11-15，用户要求对照原版核对）**：
  ① docs dispose 先 flush 防抖编辑（syncPrdFromEditor 教训——否则 ⌘↵ 生成
  用旧 PRD）；② build 终态 **designFromEngine**：规范仍是默认时自动从入口
  板 extract-design-system 合并真实配色（判默认 = palette 与 defaults 全等
  且 rules 数相同），PLAN 写过/手编过不覆盖；合并逻辑下沉
  `store.mergeExtractedPalette`，规范页提取与终态钩子共用；③ 源码模式
  从只读升级为可编辑 +「应用并渲染」（`store.applySource` 走 render 面，
  比 op 严——deepDesign 整篇 canonical 流程对齐）；④ 演示起始板 = 交互根
  （出边最多的板，demoStartBoard 教训：落在最后编辑板 = 零热区）。
  有意差异（不改）：run 中画布编辑 deepDesign 走 rebase_agent_ops，
  NoNDesign 用 agentBusy 拒绝（op 队列是单独一轮）；撤销是本地快照栈
  非引擎 history；无 i18n/多窗口。

- **ACP 白名单文档核实（2026-11-15 二轮）**：kimi 官方文档证实 `kimi acp`
  子命令（catalog 形态已对）；**Solon Code 是 Java 项目**（opensolon/
  soloncodecli，Java 17+），ACP 经配置启用（acpEnabled + acpTransport:
  stdio），无独立子命令——note 写明文档指引；mcode 原生 `mcode acp` 存在
  但 new_session 要求 `mcode login`（认证不代劳，note 指引）。
  **node 切换升级：按主版本去重**（每个 major 取最新，v24/v22/v20 覆盖，
  limit 3）——pi 的 bun shim 只在 node22 活，只重试两个 v24 会错过。
  本机终态 7 verified：qwen/pi(npx)/claude/codex/dsh/stepcode(自研)/omp。
  已知噪音：probe 期偶发 "cannot reuse already awaited coroutine" 打印
  （SDK 后台 task 清理，不影响结果正确性），未根治。

- **ACP 最终标准（2026-11-15 用户定案）**：白名单收敛 12 个——qwen/pi/
  claude/codex/dsh/stepcode/mcode/kimi/omp/gemini/pivot(灰)/solon，cline 等
  移除。适配策略：有第三方适配走 npx/中间适配器；**只有 stepcode 自研**
  （`server/acp_adapters/step_adapter.py`：把 `step -p` 打流包成 ACP，
  stdin 必须 DEVNULL——step 继承 stdin 管道等永不到来的 EOF 会挂起，
  适配器首版全链路挂起 120s 实证）。多 node 环境：native 候选默认环境
  失败后按 nvm 版本（新→旧，最多 2 个）切换 PATH 重试（`_alt_node_envs`）。
  pi 更新实录：`~/.npmrc` 把全局 prefix 钉在 node20（装哪都进 v20），
  pi@latest 需 node≥22 → `npm i -g --prefix ~/.nvm/versions/node/v24.22.2`
  强制装 v24；brew 遗留坏副本删除；`_which`/`_scan_dirs` nvm 新版优先，
  `_child_env()` 让 ACP 子进程（含适配器内部再 spawn）都解析到好副本。
  **探测/启动/静态解析三条路径必须共用 `_candidate_command`**——
  `_resolve_entry` 曾与它分叉（静态适配器被跳过 → create 回落 step acp
  挂起）。真机终态：qwen/pi/claude/codex/dsh(deepseek-harness-acp)/
  stepcode(自研)/omp(oh-my-pi) 七个 verified 全链路；mcode/kimi/gemini/
  solon 未安装诚实列出；pivot 置灰。

- **ACP 协议级探测（2026-11-15，用户反馈「通过 acp 协议探测一下」）**：
  静态猜 argv 不可靠——`probe_entry`/`probe_all` 对每个候选形态真实
  spawn + initialize + new_session 实测（npx 候选 90s/二进制 15s 超时），
  verified 才 selectable，失败诚实标注「协议探测失败：<原因>」。
  `/acp/agents?probe=1` 等待 ≤45s；服务启动即后台热探测。**实测收获：
  omp=oh-my-pi（pi 系，native `omp acp` 通过）；step 无任何 ACP 入口
  （`--acp` Unknown option、`acp` 挂起无协议响应）→ StepCode failed 是
  诚实判定**，等官方适配器往 candidates 加一行即通。pi 本体在本机因
  node/undici 兼容崩溃（非我方问题）；pi 条目保留 `pi acp` + npx 两候选。
  探测 fixture 走 _which（X_OK）——fake agent 要 shebang + chmod 755。

- **ACP 扫描完全性（2026-11-15，用户反馈实证）**：R1 目录只探适配器二进制 +
  用进程裸 PATH——用户装了 claude/codex/pi/stepcode 却全部 MISS。已修：
  ① 目录升级 candidates 链（适配器二进制 → **npx 官方包** → CLI 本体），
  claude/codex/pi 的 npx 形态 `npx -y @zed-industries/claude-code-acp` 等
  （npm view 核实包名）；② `_which()` 合并登录 shell PATH（zsh -lc 缓存）+
  `~/.local/bin`、`~/.stepcode/bin`、nvm 全部版本 bin——codex 就在 nvm 路径；
  ③ detect 返回 `selectable`（= 可启动形态存在且非 grayed）——「CLI 在但无
  适配器」（StepCode → `step` 可执行在 ~/.stepcode/bin）列出让用户看见但不可
  选。真机验收集：claude-code/codex/pi（npx）/stepcode/omp/pivot/qwen/cline。
  claude 适配器真机握手通过（spawn→initialize→new_session→close）。
  改适配器 argv 前先 `npm view <pkg> version` 核实包名。

- **外部智能体 ACP（2026-11-14）**：`server/acp_bridge.py`——模块名**不能叫
  acp.py**（会遮蔽 site-packages 的 SDK 包 `acp`，ImportError circular）。
  官方 SDK `agent-client-protocol`（导入名 acp）路由按 **kwargs 直传 hook
  参数（`session_update(session_id, update)` / `fs_write_text_file(session_id,
  path, content)`），`on_connect` 是同步调用；SDK 的 Client 钩子事件必须桥进
  prompt 的 sink 队列（曾因双队列丢失全部 delta——单会话串行 prompt，一个
  sink 即可）。权限自动放行（选第一个 allow 选项）+ fs 读写限制在工作区。
  目录在 `AGENT_CATALOG`（Claude Code/Codex/Kimi/Pi/StepCode/MiniMax/OMP/
  Pivot(置灰)/Gemini/Qwen/Cline），PATH 探测即可见；锚点
  `scripts/wf/test_acp_client.py`（fake agent 裸 JSON-RPC over stdio）。
  Flutter：设置 → 外部智能体选 agent（acpAgentId 持久化），AgentPanel 发送
  分流 `store.runAcp`，会话按 projectPath+agent 幂等，切项目/新建即失效重建。

- **tool 配对消毒（2026-11-14，真机 400 实证）**：压缩（`_compact`/`_budget`）
  按条目数切历史会把 `function_call` 与 `function_call_output` 切散 → chat wire
  上就是 `role 'tool' must be a response to a preceding message with
  'tool_calls'` 的 400。`context.py::_sanitize_tool_pairing` 在 `_load` 与
  `get_items` 出口只保留 call_id 双向齐全的配对（孤立调用=中断未执行、孤立结果=
  调用被压缩，一并剔除），旧会话文件自动自愈。**改压缩逻辑时不要去掉这层消毒**；
  锚点：`scripts/wf/test_context_sanitize.py`。默认步数 300（server 默认、
  Dart 默认、UI clamp 4–600）。

- **半程任务恢复（2026-11-14）**：`recovery.json` 在运行期也落盘——run 起点
  （force）、每次 doc_written、每次 preview canonical 渲染成功、终态 finally
  各写一档；快照新增 `run:{phase,instruction,startedAt,partialMbt}`，非空即
  「上次运行未正常结束」。重启后 `restoreRecovery` **优先用 partialMbt**
  （构建进度）并提示阶段（撰写文档/构建原型/调整原型）。改恢复路径时守住：
  ① doc_written 不置 dirty，别把 guard 收回 `dirty` 条件；② 终态快照必须
  force（agentBusy=false 后 run 标记随之清空）。

- **提示文案对比度地板（2026-11-15，用户反馈实证）**：ink4（hint/占位/次级
  说明）对 panel2/panel 的 WCAG 对比度曾只有 2.1–2.4:1——「看不清」的根源。
  已调整：dark ink4 4D5464→6B7383（3.6–3.9:1）、dark ink3 737B8D→8A93A6（5.6:1）、
  light ink4 A7ADBA→83899B（3.0+:1）、light ink3 7A8292→6B7383（4.5:1）。
  **纪律：提示性文案 ≥3:1（WCAG 图形档），正文 ≥4.5:1；改调色板先跑对比度
  计算再落值，层级 ink2 > ink3 > ink4 的排序必须保持。**

- **字阶与文案（2026-11-14）**：全应用 8 档字阶 10/11/12/13/15/18/22/34，
  10px 可读性地板（17 档→8 档已重映射 254 处）；加文案先查这档表。运行时栈名
  （Flutter/Python 等）不进产品文案。已知缺口（深度优化轮分诊 deferred，审查轮
  2026-11-14 复核：③ 已修，⑦⑧ 新增 to_thread 遗漏已修，其余仍成立，勿丢）：
  ① `applyOp` 无在飞排队——HTTP 在飞窗口内第二个 op 以陈旧 mbt 提交并覆盖
  （resize 在飞+方向键可复现，high）；② `_jumpHistory` 无在飞守卫（连按 ⌘Z
  合并成一步，与①同根应随队列一并做）；~~③ `_NodeInteractionsEditor._entries`
  拉回从未渲染~~（已修，2026-11-14：补渲染 + 解绑按钮；父级 `_ensureNodeInteractions`
  与本组件各自独立拉取 session_interactions 仍是重复请求，未合并——数据流改动
  留给专门一轮）；④ SSE 事件契约零测试锚点（已部分缓解：`test/store_test.dart`
  覆盖 applyOp/undo/redo 核心路径，`/agent/run` SSE 事件契约本身仍无锚点）；
  ⑤ 多选拖拽 N 次串行 HTTP（正解是引擎批量 move op，上游提 issue）；⑥ 门禁加固
  （capability/ddp 不验 sha、compileall 只查语法、ddp_check 依赖本机文件路径）；
  ~~⑦ `list_templates`/`list_themes` 两端点 + agent compose 阶段 + `_list_templates`
  工具函数未经 `to_thread`~~（已修，2026-11-14）；~~⑧ `_cleanup_document` 三处
  `engine.session` 同步调用，每轮 run 收尾必经路径~~（已修，2026-11-14：函数改
  `async def` + 逐处 `to_thread`）。

- **语义树全局关闭（2026-11-14，崩溃报告实证）**：Flutter macOS 引擎的
  AccessibilityBridge 在 macOS 27.2 上被 AX 客户端激活后，逐帧语义更新触发
  `doesNotRecognizeSelector` → SIGABRT（MacOSEventsFromAXEvent）。应用根级
  `ExcludeSemantics`（main.dart）整树排除——引擎侧不再产生 AX 事件，崩溃
  不可达；副作用是被 AX 激活驱动的 ~20fps 空闲泵帧同步消失（216 帧/10s →
  21 帧/10s）。上游修复前不要移除；若要恢复 a11y，先在 macOS 27 上真机回归
  崩溃面。设置镜像：`saveSettings` 双写 `~/.nondesign/settings.json`
  （含 apiKey，本机单用户）——SharedPreferences 落 plist，探针/e2e 从镜像
  文件读。

- **实测与模式纪律（2026-11-14，VM Service 探针实证）**：性能判断先跑
  `/tmp` 式探针（websockets 连 VM Service：getMemoryUsage + setVMTimelineFlags
  'all' + getVMTimeline 的 B/E 配对时长），别靠感觉。debug（JIT）与
  profile（AOT）实测差距：帧均 7.7ms→1.1ms、p90 6.4→0.6ms、堆 122MB→16MB、
  单消息尖峰 1660ms→53ms——**「卡」的第一嫌疑永远是 debug 模式本身**，
  `./scripts/dev.sh --profile` 是真实手感。仍待查：空闲期 ~20fps 的
  BeginFrame 泵（profile 下 1.1ms/帧无害，但来源未定位）；SEMANTICS 每帧
  走查（canvas 已 ExcludeSemantics，面板未包）。

- **综合性能面（2026-11-14）**：长列表一律 `ListView.builder` 惰性构建
  （Agent 时间线、设置模型清单——`ListView(children:)` 每次通知重建全部行）；
  时间线行淡入只给尾部 3 行（`animate` 参数），旧行从 1 起始，滚动回看不重播；
  SSE 分片直接窄化 `Map<String, dynamic>`（dart:convert 本就产出该形状，
  `Map.from` 整表拷贝是每秒几十次的白功）；NodeImageCache 经 ResizeImage
  钳 1024px 解码宽（原图几十 MB 位图进内存只为一枚头像节点）；
  CanvasView 的 layoutBoards 按 envelope 列表引用记忆化（identical 检查）。

- **渲染性能（2026-11-13）**：① SSE 思考/文档流式增量一律走 80ms 合帧
  （`_deltaBuffer`/`_thinkingBuffer` + Timer，事件头 `_handleAgentEvent` 入口与
  finally 双处冲刷）——逐片 notifyListeners 是全树重建放大器，别再手写直推。
  ② 画布两个 painter（FlowPainter 整层 + ArtboardPainter 每板）都有
  RepaintBoundary 图层隔离；painter 的 shouldRepaint 是字段级对比，改 painter
  参数时必须保持（新增字段记得加进对比链）。

## 测试与验收

- `flutter test`：Welcome / Canvas / Workspace / Docs 无头渲染 + SSE 解析。
- Python 端到端：`server/main.py` + mock OpenAI SSE → Plan/Build 两种 run，
  验证文档、生成页面、preview、cleanup、canonical 回写。
- 引擎：`scripts/sync_engine.py` 的 render 探针；`server/engine.py` 的
  render/apply/generate/session 冒烟。
- DDP：Python 自身往返 + Rust `vendor` 交叉（历史验证；当前仓库不再 vendored Rust）。
- 改引擎版本：更新 `scripts/sync_engine.py` 锚点 → 跑 sync → 跑 Python/Flutter 测试。
- **本地集成模式（ENGINE_LOCAL 标记，2026-11-13，用户决策）**：`engine/ENGINE_LOCAL`
  （gitignored，一行=构建路径）在场时 sync 默认取 `../moonviz-dev` 本地构建——dev 跑法
  持续使用本地引擎，rebuild 后重跑 `scripts/sync_engine.py` 即接回；**不会被 Release
  产物静默覆盖**。标记缺省才回落「校验现存 / 拉取 Release」；`--release` 是显式
  发布锚定（标记在场时告警）。引擎自报版本可能滞后 dev 构建（0.2 自报 0.1.11），
  能力面以 manifest `build_line`（行为探针判定）为准。首次设锚：
  `.venv/bin/python scripts/sync_engine.py --local ../moonviz-dev/_build/wasm/release/build/wasm/wasm.wasm`。

## 已知限制（v0.1）

- 单一 OpenAI 兼容路径（用户决策 2026-11-13：撤掉 LiteLLM/Anthropic 桥；MiniMax 走 OpenAI 兼容 /v1）。非 openai 协议在 store 与 agent.py 双层拦截。
- API Key 明文存本机 SharedPreferences；Keychain 未接。
- 画布图片节点已支持网络图（cover 裁切，异步缓存）。
- 演示模式使用 flow + 内置返回；尚未接 `session_event` 手势全量状态机。
- 本地服务无鉴权，仅绑定 loopback；不要暴露到局域网。
- App Sandbox 关闭；正式分发需重新设计 App Container/entitlement。

## 版本

`VERSION` = `0.1.0`（唯一版本源；`app/pubspec.yaml` 与 `server/main.py` 同步）。
