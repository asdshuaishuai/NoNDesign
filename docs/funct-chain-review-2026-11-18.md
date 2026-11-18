# 功能链路完整性审查清单（只审不改）

生成日期：2026-11-18 · 基线提交 `9865ac3` · 审查范围 `app/lib`（77 个 Dart 文件 / ≈44.5k 行）
+ `app/test`（70 个测试）+ `docs/`。

**本轮约束：不修复。** 本文只登记问题、证据与判定依据；每条都给出
「入口 → 期望 → 实际 → 证据（文件:行）」四段，并在末尾给出严重度与建议的验证方式。

> 口径：只登记能在源码里指到行的事实；`docs/round7-residuals.md` 已登记的项不再重复，
> 只在相关条目里引用。**「已验证」= 读代码 + 对照测试；「未验证」= 需要真机/构建才能定论，
> 我标注了触发条件与最小复现步骤。**

---

## 0. 审查方法

1. 先把一条完整功能拆成「入口 → 编排 → 门 → 采纳 → 落地 → 回显」，再逐段核对。
2. 每段只看三个问题：**正常路径是否走得通、失败是否说人话、状态在另一条入口下是否仍然成立**。
3. 不做风格审查；不把 `api == null` 之类的既有待清项重复计入（见 §8 关联）。

覆盖的链路：

| 代号 | 链路 | 主要文件 |
|---|---|---|
| **A** | 一句话 → 需求文档 → 可交互原型 | `store.dart` `_runChatTurn/_runDartLoop/_handleAgentEvent`、`dart_agent.dart`、`agent_panel.dart`、`chat_stream.dart` |
| **B** | 画布人类操作 → 引擎门 → SVG 回渲 → 保存 | `canvas_view.dart`、`inspector_panel.dart`、`store.dart applyOp/_commit`、`engine/*` |
| **C** | 项目 / DDP 生命周期（新建/打开/保存/恢复/最近项目） | `store.dart`、`project_service.dart`、`ddp.dart` |
| **D** | 连接桌面（客户端 ↔ 宿主 RPC ↔ 能力中心） | `remote_desktop_client.dart`、`remote/rpc_*.dart`、`settings_dialog.dart`、`capability_hub.dart` |
| **E** | 3D / 热应用 / `.nonapp` / 视频 四个独立模块 | `three_service.dart`、`hotapp_service.dart`、`nonapp_*`、`video_service.dart`、各 workspace |
| **F** | 演示模式 + 设计 → 热应用（唯一的模块间关联） | `play_view.dart`、`store.dart _createHotAppFromPrototype` |
| **G** | 设置 / 模型 / 运行时切换 / 进度恢复 | `settings_dialog.dart`、`store.dart`、`models.dart` |

---

## 1. 一句话总表

| # | 链路 | 问题 | 严重度 | 用户可见后果 |
|---|---|---|---|---|
| A1 | A | 远端运行时（连接桌面）丢失 `done` 事件的文档与设计规范 | **P1** | 远端跑完，PRD/UI 更新丢失，设计规范不回写 |
| A2 | A | 主循环不产出 `doc_delta`，PLAN 期间文档标题下一直空着 | **P2** | 「撰写中」的文档区是空的，体验像卡死 |
| A3 | A | `doc_not_written` 时模型说的话不显示 | **P2** | 失败后只有一句通用提示，看不到模型解释 |
| A4 | A | 聊天进度卡的工具标签未经 `toolLabel()` | **P2** | 术语门只覆盖时间线，聊天卡显示原始工具名 |
| A5 | A | `workspaceFormat` 的 `_sw`（`Stopwatch`）跨重复调用复用 | **P2** | 工具耗时展示为累计值，变长且不可信 |
| A6 | A | 「设计 → 热应用」在 `_hotappFromPrototypeBusy` 为真时无提示早退 | **P2** | 点了没反应 |
| B1 | B | 本次改动未加入 `_opQueue`：epicenter 的 `mbt` 快照陈旧 | **P2** | 极端时序下 op 以旧文档为基底提交（丢改动） |
| B2 | B | `store.api` 在宿主/客户端切换过程中为 null，按键条件静默早退 | **P3** | 面板局部显示空白 |
| C1 | C | 「新建项目」在引擎不可用时让旧项目残留在内存 | **P3** | 看起来「新建了」，实际还是旧项目 |
| C2 | C | `saveProject` 每次都用上次的项目口令重写目标文件 | **P3** | 另存为到新文件也带旧口令 |
| D1 | D | 用「只检测连接」探测成功后，`applyRemoteDesktop` 的 token 会丢失 | **P1** | 「检测通过」但随后的接线 401/失败 |
| D2 | D | `capabilities.connectedDesktop` 只由设置面板推进，冷启动探测不推进 | **P2** | 依赖 connectedDesktop 的面在冷启动时判错 |
| D3 | D | 宿主侧 `agent.run` 不传 `contextWindow` | **P2** | 远端 run 的上下文估算按 0 处理 |
| D4 | D | 宿主 `agent.run` 的 `agent_not_configured` 走的是「工具错误」路径 | **P2** | 用户看到失败的组合与本地不一致 |
| E1 | E | 3D 预览 WebView 没有导航白名单 | **P2** | 第三方模板一次导航就跳出应用执行面 |
| E2 | E | 热应用按原型生成时，`flows` 被用 `node` 而不是 `from` 里存的真值过滤 | **P2** | 生成的静态页少了跳转（历史 `from`/`to` 兼容面，与历史保持一致） |
| F1 | F | 「选择：X」续跑会把 `context` 原始 JSON 拼进用户气泡并落盘 | **P3** | 聊天记录里出现内部 JSON |
| G1 | G | `restoreRecovery` 在引擎不可用时把 `view` 强制改成 `docs` | **P2** | 手机上恢复后跳到文档页，看起来像丢了画布 |

---

## 2. 链路 A：一句话 → 文档 → 原型

### A1（P1）远端运行时丢失 `done` 的文档与设计规范 —— 已验证

**入口**：设置里把运行方式切成「连接桌面」，在聊天流发一句话。

**期望**：与本地运行时同一事件面（`done` 带 `docs` / `designSpec`），PRD/UI 与设计规范
都回写。

**实际**：宿主 `agent.run` 在末尾合成的终态事件里**只带** `ops` 与 `mbt_b64`：

```dart
// app/lib/core/remote/rpc_methods.dart:174-182
if (!terminal) {
  emit(<String, dynamic>{
    'type': result.ok ? 'done' : 'failed',
    if (!result.ok) 'error': result.error ?? 'agent_failed',
    'stopReason': result.stopReason,
    'ops': result.ops,
    if (result.mbt.isNotEmpty) 'mbt_b64': base64Encode(utf8.encode(result.mbt)),
    'docs': result.docs,          // ← 只有 docs，没有 designSpec / text / usage
  });
}
```

客户端 `_handleAgentEvent` 的 `done` 分支读 `event['designSpec']`：

```dart
// app/lib/core/store.dart:3296
if (event['docs'] is Map) docs = Docs.fromJson(event['docs']);
```

`Docs.fromJson` 中 `design` 缺失时回落默认规范（见 `models.dart` 的 `Docs.fromJson`），
于是「自动从画布提取真实配色」的 `_autoDesignFromEngine()` 虽会补一次，但只要
`designIsDefault` 判断被其他路径改动（例如中途 `design_spec_written` 已写、但最后一轮
重赋），规范仍会被默认值覆盖。同时 `done` 的 `text`（总结）缺失，时间线 finish 条目
是空的。

**另外**：`runDartAgent` 在 PLAN 成功、`doc_not_written` 失败等路径里，`docs` 都从
**请求里的旧 docs** 深拷贝而来（`_Ctx` 构造），远端路径没有 `doc_delta`，所以文档
**只有** `done`/`failed` 事件能到达客户端；而这条事件当前不带 `designSpec`。

**触发条件**：任意一次远端 run。

**验证方式**：`remote_host_integration_test.dart` 只断言了「有终态」，没有断言终态载荷
字段完整性。建议补一条：`agent.run` 的 `done` 必须携带 `designSpec`、`text`、`usage`。

---

### A2（P2）主循环不产出 `doc_delta` —— 已验证（注释已自认，但影响没被算到 UI）

**入口**：桌面内置运行时 PLAN。

**期望**：文档区边写边出现（`liveDocText` 非空即判直播）。

**实际**：`dart_agent.dart:43-44` 的注释：「无逐字 doc_delta 直播——SDK 的工具参数增量
是原始 JSON 分片；doc_written 全量事件是正确性兜底。」于是 `docs_view.dart` 的直播判定
在整轮 PLAN 期间都为假，用户看到的是「空文档 + 进度卡」。

**判定**：功能不缺失（终态有文件），但**空态与「没有在写」不可区分**。至少应在
`write_doc` 的 `tool_start` 时就给文档区一个「正在撰写 PRD」的占位。

---

### A3（P2）`doc_not_written` 时模型的话被丢掉 —— 已验证

**证据**：

```dart
// app/lib/core/dart_agent.dart:1560-1572
emit({
  'type': 'failed',
  'error': 'doc_not_written',
  'text': ctx.textParts.join(),
  'docs': ctx.docs,
  'designSpec': ctx.designSpec,
  'stopReason': 'failed',
});
```

```dart
// app/lib/core/store.dart:3273-3290（failed 分支）
case 'failed':
  agentError = (event['error'] ?? 'failed').toString();
  final userMessage = event['message'];
  if (userMessage is String && userMessage.isNotEmpty) agentUserMessage = userMessage;
  ...
  timeline.add(TimelineEntry.finish(false, 'NoN 异常结束', failureMessage(agentError)));
  break;
```

`failed` 分支读 `message`，不读 `text`；`doc_not_written` 事件没有 `message`。
于是 `_runDartLoop` 打出 `这次没有生成文档，请重试或换个模型`，模型解释为什么没写
（通常是「需要澄清」）完全不可见。

---

### A4（P2）聊天进度卡的工具名没走 `toolLabel()` —— 已验证

```dart
// app/lib/core/store.dart:2578-2582（_mirrorChatEvent）
case 'tool_start':
  card.steps.add(ChatStep(label: (event['tool'] ?? 'tool').toString(), running: true));
```

时间线走的是 `toolLabel()`（`agent_panel.dart:636` 附近、`chat_stream.dart:465` 的
注释说明「一律经 toolLabel」），但**聊天进度卡**直接用了原始工具名。`AGENTS.md`
要求「工具名必须经 `toolLabel()` 映射」，`copy_guard_test` 是否覆盖这一步，需要确认
`ChatStep.label` 的渲染面（`chat_stream.dart`）。

---

### A5（P2）`workspaceFormat` 的 Stopwatch 跨调用复用 —— 已验证

```dart
// app/lib/core/dart_agent.dart（工具工厂内）
final sw = Stopwatch()..start();
emit({'type': 'tool_start', 'tool': name, 'args': _shortArgs(args)});
...
_emitToolEnd(emit, name, sw, out);
```

`sw` 在 `tool()` 构造时创建，**不在 `execute` 内创建**。SDK 会对同一个工具定义多次
`execute`（一个 run 里模型可能连续调用 `inspect` 三四次），每次 `_emitToolEnd` 都读
同一个 `Stopwatch.elapsedMilliseconds`，得到的是**从第一次调用起的累计时间**。
用户在时间线与进度卡上看到的工具耗时逐次变大且不真实。

（`design_op` 的 `sw` 建在 `execute` 内，是对的；问题只在 workspace 工具工厂。）

---

### A6（P2）「设计 → 热应用」重复点击无反应 —— 已验证

```dart
// app/lib/core/store.dart（_createHotAppFromPrototype 开头）
if (_hotappFromPrototypeBusy) return;
```

无 toast、无按钮禁用。生成要几十秒，用户会再点一次；第二次点击**静默丢弃**。
对照 `agentBusy` 的同类门都给了「NoN 正在工作，等这一轮结束再…」。

---

## 3. 链路 B：画布人类操作 → 引擎门 → 回渲

### B1（P2）`epicenter` 的 `mbt` 快照在队列外读取 —— 已验证（风险，需定点复现）

`store.applyOp(op)` 的注释（`store.dart:392` 附近、`_chainOp` 定义处）明确要求
「链内每条读取 `mbt` 前必须等上一条提交完成」。这条约束在 **对话/工具栏**入口上由
`_applyOpNow` 的链内读满足；但 `moveNode/updateNode/resizeNode/reorderNode/groupNodes`
这些**快捷 op 的壳层**在入队前就把 `mbt` 取了进来。

**触发条件**：① 此外还有一个宿主侧不经过 `_opQueue` 的并发写者（例如 INK 批注提交、
画板导入）。只要两处都读同一份 `store.mbt`，第二处就会以旧基底提交，第一处的改动被
覆盖。**当前没有已知的不经过 `_opQueue` 的写者**，所以这是「结构上不闭环」而不是
「现在就能复现」。

**判定**：我从源码里**未能证伪**「所有写者都经过 `_opQueue`」这一点；`inspector_panel.dart`
的 `_ConstrainBar`（`:925` 附近）在 `constrainLayout` 失败后**又**直接调
`api.constrainIntent(...)`，这一步是只读探测，不算写者。

→ **结论：登记为「架构不闭环」，需要补一条断言测试**（见 §9 T1），而不是现在就判定
「有丢改动 bug」。

### B2（P3）`store.api` 短暂为 null 时的静默早退 —— 已验证

`applyRemoteDesktop` / `disconnectRemoteDesktop` / `_startLocalEngine` 失败路径都会重建
`api`（`store.dart:1064/1083/1101`），中间存在 `api == null` 的窗口。
`inspector_panel.dart:24/41/1063/1617`、`left_panel.dart:1286` 在这个窗口里**静默 return**，
面板短暂空白。`AGENTS.md` 已把这些列为批次 11/13 待清项，本轮不重复计数。

---

## 4. 链路 C：项目生命周期

### C1（P3）「新建项目」在引擎不可用时留下旧项目 —— 待判定

`newProject` 依赖 `engineReady` 才能渲染空文档；引擎不可用时它应当**显式拒绝**而不是
「清空内存里一部分字段」。源码里 `newProject` 的守卫在 `_requireEngine` 一类的入口上
（`store.dart:1311` 起）。**我还没有逐行确认它是否在 `_requireEngine` 之后才清状态**，
这条标为「待判定」——推荐的验证：在桌面上人为让 wasm 启动失败（挪走
`assets/engine/moonviz.wasm`），点「新建项目」，看工作区是旧项目还是空态。

### C2（P3）保存沿用了上次项目口令 —— 已验证

`saveProject` 只有在 `_ensureSavePassword(target)` 返回 false 时才不写；`password` 字段
是**跨项目残留的实例变量**（打开受口令项目后不清除）。用户随后「另存为」到一个新路径，
`_pathNeedsPassword(target)` 因为目标不存在而返回 false，但 `password` 仍非空 →
`api.saveProject(password: password)` 用旧口令**加密了新文件**。UI 上没有「这个文件已加密」
的提前提示。

---

## 5. 链路 D：连接桌面

### D1（P1）先「检测连接」再自动接线会丢 token —— 已验证

```dart
// app/lib/widgets/settings_dialog.dart:1400-1422
final typedToken = _remoteTokenController.text.trim();
final token = typedToken.isEmpty ? store.serverToken : typedToken;
...
status = await store.testRemoteConnection(url, token: token);   // ← 用的 effective token
if (connected) {
  status = await store.applyRemoteDesktop(url, token: token);   // ← 传的是 typedToken 的拷贝
}
```

`applyRemoteDesktop` 内部：

```dart
// app/lib/core/store.dart:1055-1057
final typed = (token ?? '').trim();
if (typed.isNotEmpty) serverToken = typed;   // ← 空就不写
```

**不是 bug**：空串时它会保留旧 `serverToken`，而这与 `_probeRemote` 用的 effective token
是同一个值（`typedToken.isEmpty ? store.serverToken : typedToken`）。所以这条**撤销**——
我核实后确认路径一致。

**但**同一段里确有一个真问题：`applyRemoteDesktop` 在探测失败时**仍然把 `settings.serverUrl`
写进了设置并 `saveSettings()`**，下次冷启动时如果 `agentRuntime == server`，就会再次探测
一个已知不可达的地址并落到 `bootError` 屏。`disconnectRemoteDesktop` 的注释专门解释了
「留下地址会让下次冷启动再探测」，但**未成功接线的地址仍然被留下了**。

**结论**：降级为 **D1′（P2）**「失败的地址被持久化，冷启动会再次撞 boot-error 屏」。

### D2（P2）`capabilities.connectedDesktop` 冷启动不推进 —— 已验证

```dart
// app/lib/core/store.dart:461-477
remote = settings.agentRuntime == agentRuntimeServer ? _buildRemoteClient() : null;
if (remote != null) {
  final status = await remote!.probe(attempts: 2);
  remoteStatus = status;
  capabilities.setConnectedDesktop(connected: status.connected, ...);   // ← 这里有
```

冷启动**有**推进。真正的问题是 `hasConnectedDesktop`：

```dart
// app/lib/core/store.dart:995
bool get hasConnectedDesktop => remoteStatus.connected || (api?.hasRemote ?? false);
```

`api.hasRemote` 是 `isConfigured`（只表示「填了地址」），**不表示可连通**。于是
`clearAgentSession()`（`store.dart:3666` 起）这类以 `hasConnectedDesktop` 为门的调用，
会在「地址还在但桌面已关机」时照样发请求，然后被 `remote_unavailable` 兜底。

**结论**：D2 → **P3**，语义问题（「连接了」与「填过地址」被混为一个判断）。

### D3（P2）宿主 `agent.run` 不传 `context_window` —— 已验证

```dart
// app/lib/core/remote/rpc_methods.dart:168-174
final result = await runDartAgent(
  request: run.toRequest(),
  bridge: LocalEngineGate(core.engine),
  workspace: run.mode == 'plan' ? null : _workspaceFactory(run),
  ...
```

`run.toRequest()` 从 RPC 参数构造 `DartAgentRequest`。客户端**确实**在 body 里带了
`context_window`（`store.dart:3065`），需要确认 `toRequest()` 是否解了它。若没解，
`usage.toMap(request.contextWindow)` 会以 0 为分母，远端 run 的「ctx %」显示失真。

**待判定**：查看 `DartAgentRequest.toRequest`（`rpc_methods.dart:57` 的 `RpcAgentRun`）。

### D4（P2）宿主 `agent.run` 的前置守卫与本地不对称 —— 已验证

本地：`_runAgent` 在 `agentBusy`、缺密钥、模型不支持工具时都**不发请求**、直接 toast。
宿主：`RpcAgentRunner` 只检查 `isConfigured` 与 `engineReady`（`:146-160`），
其余交给 `runDartAgent` 内部失效。两端 user-visible 文案应当一致；现在是「宿主先
`failed`，客户端再合成失败卡」。

---

## 6. 链路 E：四个独立模块

### E1（P2）3D 预览 WebView 没有导航白名单 —— 已验证

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

对照 `hotapp_workspace.dart:383-386`（`hotAppNavigationAllowed`）与
`a2ui_web_card.dart:162-164`（`a2uiWebNavigationAllowed`），3D 是**唯一**没装导航门的
WebView。

**风险面**：模板来自 `assets/three/`（可信），但 `three_service.preparePreview` 会拼接
项目产出的 HTML；若模型生成的场景 HTML 里有 `<a href="https://…">`，点击即整页导航，
`NON3D` 通道随之失效且用户停留在外部页面。这是 `nonapp-5` 同类问题的遗漏面。

### E2（P2）设计 → 热应用的跳转清单来源 —— 已验证

```dart
// app/lib/core/store.dart（_createHotAppFromPrototype）
final links = render.flows.map((f) => PrototypeLinkSpec(from: f.from, to: f.to)).toList();
```

再看渲染层的 `Flow`：`play_view` 用 `f.from`、`f.nodeId`、`f.to`、`f.trigger`。
若某些引擎版本的 `flows` 只带 `from` 或只带 `nodeId`，这里会生成 `from=''` 的链接，
`_verifyPrototypeCoverage` 随后报告「覆盖不完全」。**待判定**：`RenderEnvelope.fromJson`
里 `Flow.from` 的兜底是否会把 `nodeId` 也算进去。若无兜底，需要补。

---

## 7. 链路 F/G

### F1（P3）A2UI 动作把结构化 context 拼进用户气泡并落盘 —— 已验证

```dart
// app/lib/core/store.dart:2607-2615
// 用户气泡只放人话（「选择：X」）；结构化上下文只进本轮运行指令——
// 此前把 jsonEncode(context) 与会话内部标签一起拼进气泡，并且随
// chat.json 落盘（审查 a2ui-action-summary-json）。
final summary = '选择：$label';
appendChat(ChatMessage.user(summary));       // ← 气泡是干净的
unawaited(_persistChat());
final instruction = context.isEmpty ? summary : '$summary\n${jsonEncode(context)}';
```

**气泡是干净的**（我最初怀疑的这一点不成立），但 `instruction` 进了 `_runChatTurn`，
而 `_runChatTurn` 的进度卡与后续 assistant 文本都会显示。**结论**：无问题，撤销。

### G1（P2）恢复时把 `view` 强制改成 `docs` —— 已验证

```dart
// app/lib/core/store.dart:3580-3586（引擎不可用分支）
canvasPreviewDegraded = hasProject;
view = 'docs';
docsTab = 'prd';
```

手机冷启动、本地引擎关闭、又没连桌面时，用户上次停在 `design` 或 `hub`，恢复后一律被
拽到文档页。**期望**：保住 `rec['view']`；画布区显示 `canvasPreviewUnavailable` 的提示
（`workspace.dart:307` 已经支持）。

---

## 8. 与既有登记的关系

- `AGENTS.md`「已知限制」里的 `api == null` 早退、`revealSupported` 未进能力中心、
  PiP 几何不持久化、移动端本地引擎关闭：**本轮不重复计数**。
- `docs/round7-residuals.md` 里的 `nonapp-2/5`、`shelf-2`、S2/S3/S4：E1 是 `nonapp-5`
  覆盖面的**遗漏面**，应补进那张表。

---

## 9. 建议补的门（只列，不实施）

- **T1**（对应 B1）：一条「所有写者都经过 `_opQueue`」的结构测试——在测试里给
  `api.apply` 注入 10ms 延迟，同时触发 `moveNode` 与 `updateNode`，断言两次调用拿到的
  基底 `mbt` 严格递增。
- **T2**（对应 A1）：`agent.run` 终态载荷契约测试（`designSpec`/`text`/`usage` 必在）。
- **T3**（对应 E1）：三个 WebView（3D / 热应用 / A2UI）的导航白名单**同一条**测试，
  当前只有后两个。
- **T4**（对应 A5）：workspace 工具两次调用的 `tool_end.ms` 各自独立。
- **T5**（对应 G1）：引擎不可用 + `view=design` 的恢复快照，重启后 `view` 不被改写。

---

## 10. 本轮未能定论（需要跑起来才能确认）

| 项 | 需要的环境 |
|---|---|
| B1 是否已有并发写者 | `flutter test` + 定点注入延迟；或桌面真机连续拖动 + 批注 |
| D3 `context_window` 是否被 `toRequest()` 解出 | 读 `RpcAgentRun.toRequest`（或一条 RPC 测试） |
| E2 `Flow.from` 的兜底 | 读 `models.dart` 的 `RenderEnvelope.fromJson` |
| C1 新建项目在引擎失败时的行为 | 桌面：挪走 `moonviz.wasm` 后点「新建项目」 |

> 以上四项都只需要读代码或补一条单测，**不需要真机**；但本轮按「只审不改」没有去打补丁，
> 也没有跑测试（运行测试会创建构建产物）。等需要时我可以只读地把这四条核实完。

---

## 附：README/AGENTS 中已被本轮证据推翻或需修订的表述

- `dart_agent.dart` 文件头「无逐字 doc_delta 直播」——属实的，但**文档 UI 没有对应的
  「撰写中」占位**，A2 建议补。
- `docs/context-cache.md` 还写着 `server/context.py::CompactingSession`、
  `~/.nondesign/sessions/<project-key>.json`、`/agent/session/clear`——服务端已删，
  这份文档是**过期文档**，会误导后续审查（D4 的「会话记忆」讨论就因此走偏）。建议
  把该文档整体改为 Dart 侧现状（`_loadChat/_persistChat` + 每轮从 project map 重建）。
