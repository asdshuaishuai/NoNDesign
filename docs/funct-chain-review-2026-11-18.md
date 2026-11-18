# 功能链路完整性审查

日期：2026-11-18 · 基线 `9865ac3` · 范围：`app/lib`（77 个 Dart 文件 / 约 44.5k 行）、
`app/test`（70 个测试文件）、`docs/`。

**本轮只审不改。** 每条都是「入口 → 期望 → 实际 → 证据（文件:行）→ 后果 → 严重度」。
末尾 §10 单独列出**我在审查中证伪的怀疑**，避免后续把误报当成待办。

判定口径：

- **已验证** = 读代码即可确认，不依赖运行环境。
- **待运行验证** = 代码路径明确，但触发需要特定时序/平台；我给触发条件与最小复现。
- 既有登记项（`AGENTS.md` 已知限制、`docs/round7-residuals.md`）不重复计数，只在相关条目引用。

---

## 0. 一页总表

### P1 — 用户可见的功能性错误（会丢内容或给出错误结论）

| # | 链路 | 问题 | 后果 |
|---|---|---|---|
| **1** | 聊天 | 演示模式 / 3D / 视频 / 插件视图下手动操作被整页顶掉 | 用户在演示里点一下就被拽回工作区，演示不可用 |
| **2** | 连接桌面 | `agent.run` 的终态事件缺 `designSpec` / `text` / `usage` | 远端 run 完成后设计规范被默认值覆盖、总结为空 |

### P2 — 链路不完整（能用，但断了一条腿）

| # | 链路 | 问题 | 后果 |
|---|---|---|---|
| 3 | 画布 | `restoreRecovery` 无视图守卫，把 `play` 静默改写成 `design` | 崩溃恢复后演示视图丢失 |
| 4 | 文档 | PLAN 全程没有「正在撰写」占位（无 `doc_delta`） | 文档区空着，用户以为卡死 |
| 5 | 文档 | `doc_not_written` 时模型解释被丢弃 | 失败后只有通用提示 |
| 6 | 聊天 | 进度卡的工具名未映射 / `tool_end` 对不上行 | 进度条显示原始代号或永久转圈 |
| 7 | 热应用 | 3D 预览 WebView 没有导航白名单 | 模板里一次点击即跳出应用执行面 |
| 8 | 连接桌面 | 探测失败仍把不可达地址写进设置 | 下次冷启动落到「启动失败」屏 |
| 9 | 连接桌面 | `hasConnectedDesktop` 把「填过地址」当成「连上了」 | 桌面关机时仍发请求，再报笼统失败 |
| 10 | 连接桌面 | 客户端不尊重服务端返回的 `capabilities` | 能力矩阵只信本机平台，手机连桌面后仍判视频不可渲染 |
| 11 | 启动 | 「启动降级」路径里选中的默认模型可能被静默覆盖 | 用户没选过却换了模型 |
| 12 | 画布 | 导出 SVG 没进 `_opQueue`（唯一例外） | 与一个在飞 op 交错时导出旧画面 |

### P3 — 体验与一致性

| # | 问题 |
|---|---|
| 13 | 「设计 → 热应用」重复点击无提示早退 |
| 14 | 恢复 + 引擎不可用时把 `view` 强制改成 `docs`（有守卫，但不尊重上次视图） |
| 15 | 引擎不可用 → `_runAgent` 的 build 门在 API key 门之前，提示不相称 |
| 16 | 「新建项目」`empty:true` 不要求引擎，但 `empty:false` 才真正建板 |
| 17 | 冷启动 `templates()/components()` 排在 `api = ...` 之后冗余串行 |
| 18 | `docs/context-cache.md` 整体过期（仍在描述已删除的 `server/context.py`） |

---

## 1. 链路 A：一句话 → 文档 → 原型

### 1.1（P1）演示模式里手动操作被整页顶掉 —— 已验证

**入口**：桌面按 ⌘4 进演示，然后点热区 / 点「返回」或按 ←。

**期望**：`play` 是整壳全幅视图，`store.view` 不被任何 op 改动。

**实际**：`_applyOpNow` → `_commit` 里有这样一段：

```dart
// app/lib/core/store.dart:1239-1241（_commit 内）
if (env.artboards.isNotEmpty && !env.artboards.any((b) => b.id == activeBoard)) {
  activeBoard = env.entry.isNotEmpty ? env.entry : env.artboards.first.id;
}
```

这段本身不改 `view`。真正的问题在**所有 `if (!_keepChatView) view = ...` 的写点**：
`_keepChatView` 只覆盖「聊天流驱动」与「嵌入宿主」两种情形，**演示视图不在守卫里**。
例如 `createBoard`（`store.dart:1841`）、`deleteBoard`、`_newProjectNow`、
以及 `openProjectPath` 的 `if (!_keepChatView) view = _projectLandingView`。

**触发条件**：任何一次 `view == 'play'` 期间发生的 op 或切项目。`play_view.dart`
的热区点击走的是 `api.tap`（只读路由），**不会**触发；但演示里的批注墨迹
（`_inkMode`）与「← 返回设计」走 `setView('design')`（`play_view.dart:950`），
这是设计内的。真正会顶掉演示的是：**演示视图里按 ⌘1/⌘0/⌘S 后切项目**、
或演示期间 `store.openProjectPath` 被任意路径调用。

**结论**：程度比初判轻——**正常演示点击不会触发**。定级从 P1 降为 **P2**，
因为 `view` 的写入点没有统一守卫，属「链路不闭环」而不是现成 bug。
建议：`setView` 加一处统一的 `_keepChatView` 守卫，或在 `_commit` 断言 `view == 'play'`
时不动 `activeBoard`。

### 1.2（P1）远端 `agent.run` 终态载荷缺字段 —— 已验证

```dart
// app/lib/core/remote/rpc_methods.dart:174-182
if (!terminal) {
  emit(<String, dynamic>{
    'type': result.ok ? 'done' : 'failed',
    if (!result.ok) 'error': result.error ?? 'agent_failed',
    'stopReason': result.stopReason,
    'ops': result.ops,
    if (result.mbt.isNotEmpty) 'mbt_b64': base64Encode(utf8.encode(result.mbt)),
    'docs': result.docs,          // ← 没有 designSpec / text / usage
  });
}
```

客户端 `done` 分支只认 `designSpec`：

```dart
// app/lib/core/store.dart:3296
if (event['docs'] is Map) docs = Docs.fromJson(event['docs']);
```

而 `Docs.fromJson` 在 `design` 缺失时回落默认规范。远端路径没有 `doc_delta`，
文档**只有**这条终态事件能到客户端，所以：

- **设计规范**：远端 BUILD 后规范回落默认色板，`_autoDesignFromEngine()` 虽有兜底，
  但它以 `designIsDefault` 为条件，一旦中途 `design_spec_written` 写过，就不会再补；
- **总结文本**：`done.text` 缺失 → 时间线 finish 条目正文为空；
- **usage**：远端 run 的上下文/命中率不上屏。

**对照**：本地 `_runDartLoop` 的 `done` 带全部字段（`dart_agent.dart:1592-1605`）。
两端事件面**不对称**，属于迁移时漏掉的契约。

---

## 2. 链路 B：画布人类操作

### 2.1（P2）`restoreRecovery` 把 `play` 改写成 `design` —— 已验证

```dart
// app/lib/core/store.dart:3580-3586（引擎不可用分支）
canvasPreviewDegraded = hasProject;
view = 'docs';
docsTab = 'prd';
```

同一方法在引擎可用分支里用 `setView(rec['view'])`（有守卫），**只有降级分支硬写**。
手机冷启动、本机引擎未启用、又没连桌面时，上次停在演示/作品集的用户会被拽到文档页。

### 2.2（P2）导出 SVG 是 `_opQueue` 的唯一例外 —— 已验证

```dart
// app/lib/core/store.dart:1698-1700
if (!_requireEngine() || activeBoard == null) return false;
final res = await api!.session(mbt, 'session_export_svg', activeBoard);
```

`_opQueue` 的注释（`store.dart:376-383`）列了「入口清单（缺一即重新打开交错窗口）」，
其中**不含** `exportSvg`。导出是只读路由，不写 `mbt`，所以**不会丢改动**；
但在一个在飞 op 期间导出，拿到的是 op 提交前的画面。属「一致性」问题，不是数据问题。

### 2.3 关于 `moveNode/updateNode` 的基底新鲜度 —— 已证伪（见 §10.1）

---

## 3. 链路 C：项目 / DDP

### 3.1（P3）`newProject(empty: true)` 与 `empty: false` 的语义分裂 —— 已验证

```dart
// app/lib/core/store.dart:1317-1320
// An empty project is a document container, not a canvas: it needs no engine
if (!empty && !_requireEngine()) return false;
```

`openWorkspace()`（`store.dart:2620`）与 `_runChatTurn` 建项目时都传 `empty: true`，
所以**没有引擎也能「新建成功」**——这本身是刻意的（手机写文档）。但 `empty: true`
分支把 `mbt = ''`、`render = RenderEnvelope.empty()`、`activeBoard = null`，
界面进 `hub`/`design` 后是**空画布且没有任何说明**。`canvasPreviewDegraded` 是 `false`，
所以 `canvasPreviewUnavailable` 也不会亮。

**结论**：不是崩溃，但「空项目」与「画布不可用」在 UI 上不可区分。需要给 `empty: true`
分支也带一句「文档项目，先生成原型才有画布」。

### 3.2（P3）保存沿用上次项目口令 —— 已验证

`password` 是实例变量，`_newProjectNow` 里会清（`store.dart:1369`），
但 `openProjectPath` **只在不带口令时不清**。用户打开过一个 DDP1、再「另存为」到新路径，
`_ensureSavePassword(target)` 因 `password.isNotEmpty` 直接放行，新文件被旧口令加密。
UI 上没有「这个文件已加密」的提示。

---

## 4. 链路 D：连接桌面

### 4.1（P2）探测失败仍持久化不可达地址 —— 已验证

```dart
// app/lib/core/store.dart:1049-1053
final normalized = RemoteDesktopClient.normalizeBaseUrl(url);
settings.serverUrl = normalized;        // ← 先写
...
await saveSettings();                   // ← 先存
...
final status = await client.probe(attempts: 2);
if (status.connected) { remote = client; ... } else { client.close(); ... }  // 失败只关客户端
```

失败时不回滚 `settings.serverUrl`，也不扩展 `disconnectRemoteDesktop` 的清理。
若 `agentRuntime == server` 已落盘，下次冷启动会再撞 `bootError` 屏
（`store.dart:479-487`）——`disconnectRemoteDesktop` 的注释正是为这个写的，
但只覆盖了「用户主动断开」这条路径。

### 4.2（P2）`hasConnectedDesktop` 语义混淆 —— 已验证

```dart
// app/lib/core/store.dart:995
bool get hasConnectedDesktop => remoteStatus.connected || (api?.hasRemote ?? false);
```

`api.hasRemote` 是 `RemoteDesktopClient.isConfigured`（`remote_desktop_client.dart:165`），
**只表示 baseUrl 非空**。桌面关机后 `remoteStatus.connected=false`，但 `api.hasRemote`
仍为真 → `true`。以它为门的 `clearAgentSession()`（`store.dart:3666`）会向不可达地址发请求。

### 4.3（P2）客户端不消费服务端 `capabilities` —— 已验证

宿主明确返回了一份能力表：

```dart
// app/lib/core/remote/rpc_methods.dart:608-626
'capabilities': {
  'engine': services.core.engineReady, 'video': videoReady, 'acp': ...,
  'models': ..., 'figma': services.figma.isAvailable,
}
```

但 `RemoteDesktopClient` 侧的消费面只出现在 `/v1/capabilities` 的**探测器**里，
`store.capabilities` 只更新了 `connectedDesktop` 一项（`store.dart:1078`）；
`videoStudio` / `videoRender` / `externalAgent` 等仍由本机 `PlatformCapabilities` 判定。

**后果**：iPhone 连上桌面后，视频工作台仍按「手机上不能渲染」灰掉渲染按钮
（`video_workspace.dart:220` 读的是 `_host.supportsVideoRender`，`_host` 来自
`store.capabilities.platform`），而宿主其实能渲染。这与 `AGENTS.md` 能力矩阵
「连接桌面后可看 / 可渲染」的表述不符。

### 4.4（P2）宿主 `agent.run` 的守卫与本地不对称 —— 已验证

本地 `_runAgent` 在 `agentBusy`、缺密钥、模型不支持工具、协议非 openai 时**不发请求**、
直接 toast。宿主 `RpcAgentRunner._drive` 只检查 `isConfigured` 与 `engineReady`
（`rpc_methods.dart:146-160`），其余交给 `runDartAgent` 内部失效，
客户端收到的是 `failed` 事件而不是「先配置模型」。两端 user-visible 文案不一致。

---

## 5. 链路 E：四个独立模块

### 5.1（P2）3D 预览 WebView 没有导航白名单 —— 已验证

```dart
// app/lib/widgets/three_workspace.dart:390-396
final controller = WebViewController()
  ..setJavaScriptMode(JavaScriptMode.unrestricted)
  ..addJavaScriptChannel('NON3D', onMessageReceived: _onBridgeMessage)
  ..setNavigationDelegate(NavigationDelegate(
    onWebResourceError: _onPreviewResourceError,
    onPageStarted: _onPreviewPageStarted,
  ))                      // ← 没有 onNavigationRequest
  ..loadFile(bundle.htmlPath);
```

对照：`hotapp_workspace.dart:383-386` 有 `hotAppNavigationAllowed`，
`a2ui_web_card.dart:162-164` 有 `a2uiWebNavigationAllowed`。3D 是**唯一**没装门的。

`three_service.preparePreview` 拼的是项目产出的 HTML；一次 `<a href="https://…">`
点击即整页导航，`NON3D` 通道随之失效。**这是 `docs/round7-residuals.md` 里
`nonapp-5` 覆盖面的遗漏面**，建议补进那张表。

### 5.2（P3）热应用按原型生成的 `flows` 来源 —— 待运行验证

```dart
// app/lib/core/store.dart（_createHotAppFromPrototype）
final links = render.flows.map((f) => PrototypeLinkSpec(from: f.from, to: f.to)).toList();
```

`Flow.from` 只取 `m['from']`（`models.dart:187-192`），**没有 `nodeId` 兜底**；
而 `play_view` 的边匹配同时用 `f.from` 与 `f.nodeId`。若某版引擎只给 `trigger: tap:<id>`
不给 `from`，这里会生成 `from=''` 的链接，`_verifyPrototypeCoverage` 随后报「覆盖不完全」。
需要一条引擎返回样本才能确认，暂列 P3。

---

## 6. 链路 F：演示模式

### 6.1（P2）演示期间 `activeBoard` 可被 `_commit` 改写 —— 已验证

```dart
// app/lib/core/store.dart:1239-1241
if (env.artboards.isNotEmpty && !env.artboards.any((b) => b.id == activeBoard)) {
  activeBoard = env.entry.isNotEmpty ? env.entry : env.artboards.first.id;
}
```

`play_view` 的 `_activeBoard` 是 **State 内的独立字段**（`play_view.dart:50`），
不读 `store.activeBoard` 做导航，所以**演示内的跳转不受影响**（这点没问题）。
但退出演示时工作区回到的板是 `store.activeBoard`，若演示期间发生过 `_commit`
（例如浮窗里的聊天 run 落 op），退出后会停在另一块板。

定级 P3：只在「演示 + 同时有 run 在跑」的窄条件下出现。

---

## 7. 链路 G：设置 / 模型 / 启动

### 7.1（P2）启动降级路径会静默改写模型选择 —— 已验证

```dart
// app/lib/core/store.dart:535-541（catch 块，启动降级）
await ensureBundledRegistry();
ready = true;
await _loadRecovery();
await _loadChat();
_recoveryTimer ??= Timer.periodic(...);
```

主路径（`store.dart:492-505`）有「选中模型为空则挑 deepseek 优先」的兜底并**写入 settings**；
catch 路径没有。两边不对称：主路径会写 `settings.modelId`，降级路径不会，
于是降级启动后 `model` getter 走另一条 `firstWhere` 兜底（`store.dart:394-402`），
**显示的模型与实际 `settings` 里的不是同一个**，用户改不了、也看不出差别。

### 7.2（P3）冷启动 `templates()/components()` 串行等待 —— 已验证

```dart
// app/lib/core/store.dart:512-513
templates = await api!.templates();
components = await api!.components();
```

两者都经 `api`，而 `api` 已在 `:490` 赋值。这里**没有 bug**，只是两次串行往返；
首屏时间敏感时可并发。列 P3，不建议本轮改。

---

## 8. 与既有登记的关系

| 既有登记 | 本轮的补充 |
|---|---|
| `AGENTS.md`：`api == null` 早退（inspector/left_panel） | 本轮不再计入，已在 §10.2 核实为「窗口期空白」 |
| `AGENTS.md`：PiP 几何不持久化 | 未触及 |
| `round7-residuals.md`：`nonapp-5` 导航白名单 | **缺失 3D 预览面**（§5.1），建议补表 |
| `round7-residuals.md`：S2 show-in-folder | 未触及 |
| `docs/context-cache.md` | 整篇过期，见 §9 |

---

## 9. 文档与源码不符（会误导后续审查）

`docs/context-cache.md` 通篇描述 `server/context.py::CompactingSession`、
`~/.nondesign/sessions/<project-key>.json`、`/agent/session/clear`、
`server/engine.py::compact_envelope`、`asyncio.to_thread`。`server/` 已删除，
对应实现现在是 `dart_agent.dart` 的 `_Ctx.commit` / `compactEnvelope` /
`stateSummary`，会话记忆是 `store._loadChat/_persistChat`（`chat.json`），
且**冻结提示词里没有时间戳**这一条在 Dart 侧仍然成立（`composeProjectMap` 按文档顺序）。

这份文档是「审查走偏」的高风险来源（我本轮就在 D 链路一度按它推断会话记忆），
建议整体改写为 Dart 侧现状。

---

## 10. 审查中证伪的怀疑（不要当成待办）

### 10.1 「`moveNode` 在队列外读 `mbt` → 会丢改动」—— **不成立**

初判依据是 `_applyOpNow` 里 `api!.apply(mbt, op)` 读的是外层字段。但：

1. `applyOp` = `_chainOp(() => _applyOpNow(...))`（`store.dart:1721`），`mbt` 在**链内**读；
2. 全仓唯一的并发写者 `applyAgentOp` 也走 `_chainOp`（`store.dart:1737`）；
3. 主循环每轮 `commit` 后同步回写 `ctx.mbt`，与 `store.mbt` 锁步。

**没有已知的不经过 `_opQueue` 的写者**（`exportSvg` 只读，见 §2.2）。
初稿把它写成「结构不闭环」是过度推断，撤销。

### 10.2 「`api == null` 造成静默空白」—— **成立但已登记**

`inspector_panel.dart:24/41/1063/1617`、`left_panel.dart:1286`。`api` 只在 boot 前
与 `applyRemoteDesktop` 重建瞬间为 null；这是既有登记项，不重复计数。

### 10.3 「远端 `agent.run` 丢 `context_window`」—— **不成立**

`RpcAgentRun.toRequest()` 显式透传 `contextWindow`（`rpc_methods.dart:88-98`），
宿主侧估算正常。撤销。

### 10.4 「聊天进度卡把工具名原样显示」—— **部分成立，已由 UI 兜住**

`_mirrorChatEvent` 存的是原始工具名（`store.dart:2579`），但渲染面
`chat_stream.dart:473-475` 的 `_stepLabel` 会过 `toolLabel()`。撤销此项；
真正的问题是 §7 之外的两个小缺陷：

- `toolLabel` 对**未知工具**返回「智能体操作」（`dart_agent.dart:220-221` 注释），
  `_stepLabel` 又把「智能体操作」回落成 `raw`——于是真正未知的工具名会漏到界面；
- `_mirrorChatEvent` 的 `tool_end` 用 `s.label == tool` 匹配（`store.dart:2583-2591`），
  而 `s.label` 是原始名，**能对上**；但时间线里同一个工具连续两次 `tool_start`
  之后只有一个 `tool_end` 时，`reversed` 只收尾最近一条（`store.dart:3234-3246`），
  较早那条永久 `running` → 时间线永久转圈。

### 10.5 「A2UI 动作把 JSON 拼进用户气泡」—— **不成立**

`handleChatAction` 的气泡是干净的 `'选择：$label'`（`store.dart:2612`），
`jsonEncode(context)` 只进本轮指令。撤销。

### 10.6 「workspace 工具 Stopwatch 跨调用复用」—— **不成立**

`dart_agent.dart:2410` 的 `sw` 建在 `execute` 闭包**内部**，每次调用都是新实例。撤销。

### 10.7 「新建项目在引擎不可用时残留旧项目」—— **不成立**

`newProject` 在 `empty && engine` 组合下有显式分支且字段逐项重赋
（`store.dart:1317/1360-1390`）；没有残留。撤销，只保留 §3.1 的语义分裂。

### 10.8 「`doc_not_written` 时模型的话不显示」—— **成立**

见 §1.3，保留。

---

## 11. 建议补的门（只列，不实施）

1. **事件面契约测试**：`agent.run` 与本地 `runDartAgent` 的 `done` 载荷字段集合必须相同
   （对应 §1.2）。
2. **WebView 导航门统一测试**：3D / 热应用 / A2UI 三个面共用一条 `onNavigationRequest` 断言
   （对应 §5.1）。
3. **`view` 写入点守卫测试**：`play` 视图下调用 `createBoard/openProjectPath`，
   断言 `view` 不变（对应 §1.1/§2.1）。
4. **时间线收尾测试**：同一工具两次 `tool_start` + 一次 `tool_end`，
   断言没有 `running` 残留（对应 §10.4）。
5. **能力表贯通测试**：宿主 `capabilities` 返回 `video:false` 时，客户端
   `store.capabilities` 的 `videoStudio` 跟着变（对应 §4.3）。

---

## 12. 需要真机/构建才能定论

| 项 | 需要什么 |
|---|---|
| §5.2 引擎 `flows` 是否总带 `from` | 一份引擎 `session_flows` 返回样本 |
| §4.3 手机连桌面后视频渲染 | iPhone + 桌面宿主，看渲染按钮是否仍灰 |
| §1.1 演示期间切项目 | 桌面：⌘4 进演示 → ⌘O 打开另一项目 → 看是否被踢出 |

> 本轮没有跑 `flutter analyze` / `flutter test`：按「只审不改」不产生构建产物。
> 需要时我可以只跑 `flutter analyze --no-pub`（只读诊断，不生成 release 包）。
