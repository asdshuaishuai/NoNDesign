# 连接桌面：桌面 RPC 宿主（批次 10）

**一句话**：桌面 App 里跑一个 `dart:io` HttpServer，让手机/iPad 通过显式配对可选地
使用桌面能力。没有 Python 服务、没有固定端口、没有端口文件；默认关闭、默认只听
loopback、token 必填。

代码归属（本批次新增，全部是独立文件）：

| 文件 | 职责 |
| --- | --- |
| `app/lib/core/remote/rpc_protocol.dart` | 线协议常量：版本、方法名、限额、错误码、用户文案、SSE 帧 |
| `app/lib/core/remote/rpc_auth.dart` | 配对 token：安全随机生成、常量时间比较、`Bearer` 解析 |
| `app/lib/core/remote/rpc_methods.dart` | 方法表：每个方法委托给本地引擎 / 项目库 / 3D / 热应用 / 视频 / 应用包 / 内置智能体 / 外部智能体 |
| `app/lib/core/remote/desktop_rpc_host.dart` | HttpServer：绑定、鉴权、限额、SSE、启停与 token 轮换 |
| `app/test/desktop_rpc_host_test.dart` | 宿主侧门禁（36 例） |
| `app/test/remote_host_integration_test.dart` | 真客户端 ↔ 真宿主 loopback 端到端（6 例） |

客户端**没有第二套协议**：`app/lib/core/remote_desktop_client.dart` 与
`app/lib/core/api.dart` 里的方法名就是本宿主的方法名（`remote_rpc_contract_test.dart`
锁客户端侧形状，本批次锁宿主侧实现）。

---

## 1. 绑定与生命周期

| 状态 | 绑定 | 端口 | token |
| --- | --- | --- | --- |
| 未开启（默认） | 无监听 | — | 生成但不使用 |
| 已开启（默认） | `127.0.0.1` | `0`（系统分配临时端口） | 必填 |
| 已开启 + 「允许手机连接」 | `0.0.0.0` | `0` | 必填 |

* 构造 `DesktopRpcHost(...)` **不打开任何 socket**。只有 `start()` 才绑定。
* 每次 `start()`（含 loopback ↔ LAN 切换、stop 后再开）都会**重新生成 token**，
  旧 token 立即失效；`regenerateToken()` 可随时手动轮换。
* `stop()` 立即关闭监听（`HttpServer.close(force: true)`）并取消在飞的智能体 run。
* 状态对象 `RpcHostStatus` 提供给设置卡片：
  `running / address / port / baseUrl / token / lanEnabled / lanAddresses /
  warning / loopbackOnly / error`。LAN 模式下 `warning` 固定返回
  「手机连接已开启，请只在信任的网络里使用」。
* 绑定失败不抛异常：`status.error` 带诊断文本，`running=false`。设置面板把
  `error` 放进折叠的「技术详情」。

界面上「这台设备能不能用桌面能力」仍由 `CapabilityHub` 决定；
`/v1/capabilities` 的布尔表只描述这个宿主暴露了哪些面。

### 桌面必须保持打开

宿主活在桌面 App 进程里。桌面退出 = 连接断开；这是设计而非缺陷，文案里必须写明
（连接桌面卡片常驻这一句）。

## 2. 认证

* 每个请求（除下面说的资源 GET）都必须带
  `authorization: Bearer <token>`；缺 token / 错 token → **HTTP 401**，
  body `{ok:false, error:"unauthorized", message:"连接码不正确，请在桌面端重新获取"}`。
* 没有「免鉴权 loopback」模式——旧 Python 服务在局域网裸奔正是要消灭的东西。
* token 格式：24 字节 `Random.secure()` → base64url 无填充（32 字符，
  可用手机键盘输入）。
* 比较：UTF-8 字节常量时间比较（长度不同直接 false；长度本身在 HTTP 帧里可见，
  不构成额外泄漏）。
* token 展示：设置卡片显示完整 token（手机要输入）；日志/状态栏只用
  `abcd…wxyz` 短形（`RpcAuthToken.hint`）。**不要把完整 token 写日志。**
* `/v1/assets/<kind>/<name>` 是 WebView 顶层导航，无法设置请求头，因此**只对
  GET 资源**接受 `?token=<同一个 token>`；其它任何路径都不接受 query token。
* 建议（未在本批次实现）：token 只应一次性使用后轮换；设置面板可在「已连接设备」
  列表里做主动失效——当前实现提供手动「重新生成」按钮。

## 3. 限额

| 限额 | 值 | 行为 |
| --- | --- | --- |
| 请求体 | 16 MiB（`RpcLimits.maxBodyBytes`） | 超出即断连；客户端看到 `payload_too_large` 或连接关闭 |
| 并发请求 | 8（`RpcLimits.maxConcurrentRequests`） | 第 9 个及以后 → `503 busy`；`/v1/health`、`/v1/capabilities` 不计入 |
| 流式空闲 | 600 s（`RpcLimits.streamIdleTimeout`） | 无事件时宿主主动写 `failed(stream_idle_timeout)` 并收尾；**这是空闲预算，不是总时长上限**，一直有事件的生成不会被砍 |
| 流式保活 | 20 s（`RpcLimits.keepAliveInterval`） | 写 SSE 注释 `: ping`；每次 flush 有 `2×` 保活周期的截止时间，超时视为对端消失并取消 run |
| 连接空闲 | 5 min（非流式） | `HttpServer.idleTimeout` |

`dart:io` 对「对端已消失」既不一定抛错、也不保证 `HttpResponse.done` 触发——
写可能挂住。因此断线检测是**写驱动**的：保活注释的 flush 超过截止时间 → 取消
本次 run（`RpcStreamHandle.onClientGone`）。即使断线检测失效，600 s 空闲终态仍然
兜底，手机端不会永远卡在「生成中」。

## 4. 接口

```
GET  /v1/health        → {ok, protocol, version, name, engine, uptime_s, loopback}
GET  /v1/capabilities  → {ok, protocol, version, capabilities:{engine, projects,
                          agent, three, hotapp, nonapp, video, acp, models, figma}}
POST /v1/rpc           → {ok:true, result:{...}}                （单次调用）
                       → text/event-stream（流式方法，见下）
GET  /v1/assets/three/<name>?token=…   → 3D 预览页（自包含 HTML，严格 CSP）
GET  /v1/assets/hotapp/<name>?token=…  → 热应用页面；A2UI 应用回 surface JSON
```

* 未知路径 → `404 {ok:false,error:"not_found"}`；已知路径错动词 → `405`。
* 请求体不是 JSON 对象 / 缺 `method` / `params` 不是对象 → `400 bad_request`。
* `/v1/rpc` 的 body：`{method: string, params?: object, protocol?: number}`。
* 合法请求的单次调用**总是** HTTP 200 + `{ok:true, result}`；业务失败在 `result` 里
  （`{ok:false, error, detail?, message?}`），客户端因此能拿到精确错误码。
* 方法不存在 → `result.error = "unknown_method"`（200），`detail` 带方法名；
  这样客户端能看到真实原因，而不是被 HTTP 404 折成「桌面太旧」。
* 协议版本：当前 `1`（`rpcProtocolVersion`）。客户端 `protocol` 超出
  `[1,1]` → `result.error = "unsupported_protocol"`，`message` =
  「桌面端和这台设备的版本不匹配，请更新桌面端」。不带 `protocol` 视为 1。

### 流式方法

`agent.run`、`agent.external.prompt`（别名 `acp.prompt`）返回
`text/event-stream`，一行一个事件：

```
data: {"type":"started","run_id":42}
data: {"type":"note","label":"开始"}
data: {"type":"done","stopReason":"done", …}
```

* 第一帧固定是 `started`（带本次 `run_id`；客户端可自带 `run_id`）。
* 终止帧只有 `done` / `failed`；宿主保证**一定**发一个终止帧——包括源流意外
  结束（`agent_incomplete`）、空闲超时（`stream_idle_timeout`）、客户端消失
  （取消 run；能写就补一帧 `failed`）。
* 取消：另一个请求发 `agent.cancel {run_id}`（生效返回 `{ok:true,cancelled:true}`，
  没在跑返回 `cancelled:false`）。
* 背压：SSE 是单向流，宿主按事件即时 flush；不缓冲整个运行结果。客户端读取慢时
  写会自然变慢（TCP 背压），空闲预算仍然生效。

## 5. 方法表

`RpcMethod.all` 是唯一清单（`rpc_protocol.dart`），宿主必须全部注册
（`desktop_rpc_host_test.dart` 的覆盖测试锚定）；`RpcMethod.aliases` 里的
`acp.*` 是同一处理器的别名。

| 组 | 方法 | 委托到 |
| --- | --- | --- |
| 探针 | `health` `capabilities` | 宿主自身 |
| 引擎 | `engine.render` `engine.validate` `engine.apply` `engine.session` `engine.generate` `engine.tap` `engine.constrain` `engine.event` `engine.history` `engine.exportHtml` `engine.tokens` `engine.version` `engine.templates` `engine.components` `engine.themes` `engine.ops` `engine.stats` `engine.recycle` | `LocalCore.engine`（批次 02） |
| 项目 | `project.save` `project.open` `project.list` `project.exportFigma` | `LocalCore.projects`（批次 03）/ `FigmaExporter` |
| 内置智能体 | `agent.run`(流) `agent.cancel` `agent.session.clear` | `dart_agent.runDartAgent`（批次 09）+ `LocalEngineGate` |
| 外部智能体 | `agent.external.agents/session/prompt`(流)`/cancel/close/permission`（别名 `acp.*`） | `AcpClient`（桌面独占，批次 09） |
| 3D | `three.projects` `three.project` `three.project.new` `three.pass` `three.feedback` `three.continue` `three.spec` `three.delete` `three.preview` | `ThreeService`（批次 06） |
| 热应用 | `hotapp.list` `hotapp.read` `hotapp.generate` `hotapp.refine` `hotapp.inspect` `hotapp.delete` `hotapp.export` | `HotAppService`（批次 07） |
| 应用包 | `nonapp.list` `nonapp.inspect` `nonapp.export` `nonapp.delete` | `NonAppLibrary`（批次 07） |
| 视频 | `video.review` `video.render` `video.jobs` `video.job` `video.cancel` `video.samples` `video.sample` | `VideoService` / 纯函数 `reviewVideoScript`（批次 08） |
| 作品集 | `portfolio.list` `portfolio.delete` | 本地聚合（热应用 + 原型 + 3D + 视频） |
| 模型快照 | `models.snapshot` `models.refresh` | 宿主注入（批次 11/12 接线） |

**画布写入纪律**：`engine.apply` 只接受 `gate ∈ {human, agent}` 并原样透传；
`engine.session` 只接受 `session_*` 名字。宿主从不解释 Markdown/op，也从不自己
改文档——所有变更仍过引擎门。

**路径纪律**：`project.save` / `project.open` 只接受以 `.ddp` 结尾的路径；
工作区名字走各服务自己的 ASCII 校验。token 是完整信任凭据（等同密码），但不能
顺带变成任意文件读写原语。

## 6. 错误码

| 码 | HTTP | 含义 / 客户端可见句子 |
| --- | --- | --- |
| `unauthorized` | 401 | 连接码不正确，请在桌面端重新获取 |
| `not_found` | 404 | 桌面端没有这个功能，请更新后再试 |
| `method_not_allowed` | 405 | 同上 |
| `payload_too_large` | 413 | 这次同步的内容太大，请分几次保存 |
| `busy` | 503 | 桌面端正忙，请稍后再试 |
| `bad_request` | 400 | 桌面端没能读懂这次请求，请重试 |
| `invalid_params` | 200（result 内） | 这次请求缺少必要内容，请重试 |
| `unknown_method` | 200（result 内） | 桌面端还不支持这个操作，请更新桌面端 |
| `unsupported_protocol` | 200（result 内） | 桌面端和这台设备的版本不匹配，请更新桌面端 |
| `internal_error` | 500 / result 内 | 桌面端暂时出了点问题，请稍后重试 |
| `stream_idle_timeout` | 流内 `failed` | 桌面端长时间没有回应，请重试 |

域内错误码（`engine_unavailable`、`ddp_password_required`、`three_*`、
`hotapp_*`、`video_*`、`nonapp_*`、`acp_*`）**原样**从 `result.error` 透传，
由客户端既有的错误码→文案映射处理；`detail` 只进折叠的「技术详情」。
见 `docs/copy-glossary.md`。

## 7. 安全清单

* 默认关闭；默认 loopback；LAN 必须显式开关 + 警告。桌面设置「运行方式」卡内
  「手机连接这台电脑」提供启停开关，并显示实际地址与一次性连接码。
* token 必填、安全随机、每次 start 轮换、可手动轮换、常量时间比较。
* 请求体 16 MiB、并发 8、流式空闲 600 s，全部有测试。
* 不 spawn 进程、不读固定端口文件；唯一监听是宿主自己绑的临时端口。
* 3D / 热应用页面带严格 CSP：`default-src 'none'; script-src 'unsafe-inline';
  style-src 'unsafe-inline'; img-src data: blob:; connect-src 'none';
  frame-ancestors 'none'`——页面没有外联通道（应用内 WebView 的导航白名单是
  另一道门，批次 07/12）。
* 不设置 CORS 头：浏览器跨源读被默认同源策略拦住；顶层导航（资源页）仍受 token
  保护。

## 8. 已知边界（如实登记）

* **AGENTS.md 的旧口号未改**：仓库根 `AGENTS.md:503` 仍写着「本地服务无鉴权，
  仅绑定 loopback；不要暴露到局域网」。本批次的实现已改为「默认关闭/loopback，
  LAN 需显式开关 + token」。`AGENTS.md` 不在本批次文件清单内（共享文件单一归属），
  故未修改——需要由文档归属方改成新纪律。
* **iOS 模拟器 / 真机 LAN 验收未执行**：本批次跑的是 macOS 上的 Dart VM loopback
  端到端（`remote_host_integration_test.dart`）。同一份客户端代码在 iOS 上运行，
  但「iOS 模拟器连 macOS 宿主」与「真机同网段 + 防火墙」仍是人工验收项。
* **资源页 token 走 query**：`api.dart` 的 `threePreviewUrl` / `hotAppPageUrl`
  目前返回不带 token 的 URL。宿主已支持 `?token=`，但客户端拼接尚未更新
  （`api.dart` 属批次 05，不在本批次文件清单）。未拼 token 时资源页会 401，
  不会泄漏内容。
* **模型快照注入未接线**：`models.snapshot` 需要批次 11/12 把随包快照传进来；
  未接线时诚实返回 `models_unavailable`。
* **`models.refresh` 不联网**：随包快照是权威；未注入刷新函数时返回
  `models_local_only`。
* **`portfolio.delete` 不支持删除原型项目**：艺术架不拥有项目文件
  （shelf-2 裁决），返回 `not_supported`。
* **视频渲染仍依赖本机外部程序**（桌面 `resvg`/`ffmpeg`，批次 08 的边界）；
  宿主只转发，不改变这条事实。`video.review` 是纯函数，任何宿主都能跑。
* **ACP 是桌面独占**：手机端宿主不会出现（`systemAcp` 默认只在桌面三平台开启）。
  `AcpClient` 的权限请求经流内 `permission` 事件 + `agent.external.permission`
  往返完成，2 分钟无答复按拒绝处理。
* **`agent.session.clear` 是空操作**：Dart 内置循环无持久会话记忆，返回
  `{ok:true, cleared:true}` 只是为了保持客户端契约。
* **没有做的**：TLS（loopback/LAN 明文 + token；局域网威胁模型按「可信网络」，
  设置卡片明示警告）、mDNS 发现（用户手输地址）、多设备配额/审计。

## 9. 接线（批次 11/12 的接口）

```dart
// main（批次 12）：启动后构造一次，不 start
final rpc = RpcServices(
  core: LocalCore(engine: EngineServiceAdapter(engineService), projects: projectService),
  // 随包模型快照的 JSON 形状（{providers, fetched_at}）；未接线时诚实报
  // models_unavailable。批次 11/12 负责从 store/资产里取。
  modelSnapshot: () async => snapshotJson,
);
final host = DesktopRpcHost(services: rpc);

// 设置面板（批次 11）
await host.start();                    // 默认 loopback + 新 token
host.status.token;                     // 显示给用户
await host.start(allowLan: true);      // 重启到 0.0.0.0 + warning
host.regenerateToken();
await host.stop();
host.dispose();                        // 应用退出
```

手机端不需要新接口：设置里的 `serverUrl` 填 `host.status.baseUrl`（LAN 时用
`host.status.lanUrls` 里的地址），`serverToken` 填 `host.status.token`，
「检测连接」走 `RemoteDesktopClient.probe()`。
