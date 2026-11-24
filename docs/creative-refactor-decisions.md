# 创意工作台大重构 R0 契约冻结决策台账

> 状态：**草案（R0 契约冻结，2026-11-23）· 契约核心已落地 / 模块未施工**。本文是 R0 的
> 冻结记录：只写默认值、状态、影响批次与回退方案，不写施工步骤，不把方案当现状。
> R0 已落地的代码与测试见 §6；四份模块契约本身仍是未施工目标态。
>
> 相关：[README.md](README.md) §2（决策台账）·
> [plan-creative-workbench.md](plan-creative-workbench.md) §1/§7（四件套与批次）·
> [plan-music-module.md](plan-music-module.md) §9（音乐批次）·
> [skills/creative-workbench/references/judging.md](skills/creative-workbench/references/judging.md)
> （盲评、caps、best round）。

## 0. R0 边界与状态口径

* R0 = **契约冻结**：交付四份模块契约（[design](design-contract.md) /
  [three](three-contract.md) / [video-screenplay](video-screenplay-contract.md) /
  [music](music-contract.md)）与本决策台账（共五份新文档）；**不接工具、不改 agent 层、
  不动 `app/` 代码**。
* **2026-11-23 追加裁决**：保留并完成 Genkit 迁移、移除 ai_sdk（见 §2）；
  R0 契约核心不受影响。
* 状态词：**冻结** = 本轮已定默认，施工按此实现；**blocked** = 有外部冲突，等用户裁决；
  **待 R? 冻结** = 数据不足，进 §3 缺口，不发明数值；**暂定** = 有默认但未校准。
* 「影响批次」指 plan-creative-workbench §7 的批次编号。本文出现的工具名一律是
  **拟实现**，施工前不得当现状引用（README §4）。

## 1. 冻结表

| 决策 | 默认与状态 | 影响批次 | 回退方案 |
| --- | --- | --- | --- |
| **轮次版本化** | 默认 **git-first**：每轮 `src/` 提交 + `rNN` tag，`judge/rNN/` 证据随轮落盘；`judge/rNN/src` 快照只作无 git / 标签被清时回退（**冻结**，R1 实现） | 1b / 4 / 5b；最佳轮交付 | 无 git 或标签丢失 → 按 `judge/rNN/src` 快照恢复，**重跑 `check` 才交付**；不接受「最后一轮」代替最佳轮（judging.md §6） |
| **blind judge 通道** | 默认 **fresh context** judge，只看 `brief.md` + 图片；调用前做**视觉模型能力探测**（模型/端点能否读图），失败**不静默**：本轮标 `self_judged` 并按降级上报（**冻结**，R1 实现） | 1b / 4 / 5b | 无可用视觉 judge → 不得声称盲评分数；交付降级标记 + 人工 judge 通道；探测失败也必须留证据，不吞错 |
| **Phaser 版本** | **建议锁 4.2.1**；**3.90** 为老 WebGL / 回退版本；最终由 **5a spike** 定；两版都 vendored manifest/SHA256，**不浮动升级**（**待 5a 冻结**） | 5a | spike 不达标 → 回退 3.90（v3 最后版本，Canvas/WebGL 双渲染）；回退同样锁版本 + manifest，桥/解释器契约不变 |
| **ink_line 是否进首版** | **不进首版**；等 **I0 spike**（Canvas2D 笔触 1080p30 单帧 <16ms、站立脚不滑、帧条通过）后再定（**待 I0 冻结**） | 5b / 5c；拉伸 I0–I5 | 不进首版 → `silly_skit` / `line_toon` 先交付；`style` 枚举已预留 `ink_line`，不改 `screenplay.json` 字段 |
| **TTS 模型随包策略** | 主路径 **sherpa-onnx**（Apache-2.0，Dart FFI 五端）；模型体积 / 语言分包 / 随包 vs 首次下载**待 5b 冻结**；OS 音色只做草稿且必须标注「个人非商业」（**部分冻结**） | 5b | 不随包 → 首次下载 + sha256 校验（MediaPipe 同族纪律）；下载不可用 → 如实降级草稿，不假装可发布；导出仍屏蔽 |
| **`scene.json` 双 authoring** | **scene / code 两种事实源**：scene 模式 `scene.json` 是事实源；code 模式 `src/*.js` 是事实源、`scene.json` 是**派生投影**（只读/受限编辑）。新空场景默认 scene，一句生成/harness 默认 code（**冻结**） | 4 | 双模式不成立 → 二选一需用户裁决；任何情况下禁止 `scene.json` 与 `src/` 同时写（会造第二真相）。详见 [three-contract.md](three-contract.md) §2 |
| **评分默认参数** | `passThreshold = 0.85`（暂定）、penalty 默认 `0`、floors 暂空、tie 容差 `0.03`；**均待校准**（固定 artifact bank，rubric 冻结后 A/B）（**暂定**） | 4 / 5b（score/passed 语义） | 校准前只输出 `overall`/caps 与 improvement list，`passed` 不单独作为交付门；校准后回填本表与 rubric |
| **Genkit 迁移（2026-11-23 用户裁决）** | **已裁决并实施：保留 Genkit、移除 ai_sdk**（工作树；专项见 §2）；R0 契约/文档已回填，agent 层测试全绿 | R1 起全部 agent 层 | 不再回退 ai_sdk；若未来更换 LLM SDK，重新走裁决并先补「分类/重试/方言」契约测试 |

## 2. Genkit 迁移（2026-11-23 用户裁决：已采纳并完成）

**裁决**：保留工作树中的 `ai_sdk → genkit` 迁移，并完成收口；`ai_sdk_dart` /
`ai_sdk_openai` 不再作为依赖或代码路径。

**落地事实（2026-11-23）**：

* 依赖：`app/pubspec.yaml` = `genkit ^1.0.3` + `genkit_openai ^1.0.3` +
  `schemantic ^1.0.0`；`pubspec.lock` 无 ai_sdk 包；依赖注释写明「不要再引入」。
* 代码：`dart_agent.dart` / `hotapp_service.dart` / `three_service.dart` /
  `remote/rpc_methods.dart` / `store.dart` / `widgets/a2ui_card.dart` 使用 genkit；
  `agent_model_middleware.dart` 与 `stream_tool_name_guard_test.dart` 已删除。
* 行为面：模型错误不抛异常，统一收敛为 `finishReason` + `cause`，循环翻回异常形状后
  仍走 `classifyLlmError`（`GenkitException.status.httpStatus` → `llm_http_<code>`，
  `unknown tool` / `Tool … not found` → `llm_no_such_tool`）；`llm_no_such_tool` 的
  重试轮仍追加 `Available tools: …`；近名改写/流内空名回填是 ai_sdk 方言 workaround，
  **随迁移退场**。
* 文档回填：AGENTS.md Agent 层约定、README 内置智能体行、本台账、
  plan-flutter-3.50-adoption.md §2/§4、plan-dart-agent-migration.md、
  plan-chat-stream-shell.md、plan-a2ui-web-spike.md。
* 验证：`flutter analyze --no-pub` 绿；`flutter test` 全量 1202 passed / 1 既有环境失败
  （容器 loopback 的 `desktop_rpc_host_test`，与迁移无关）；`architecture_guard_test`
  新增「ai_sdk 依赖/import 不得回归」「旧 middleware 不得回归」锚点。

**仍未验证（诚实登记）**：StepFun step_plan 的「后续 delta 空工具名」方言是 ai_sdk
解析器的 bug 表现；genkit 下是否仍出现，需要真实 StepFun 端点抓包（本机无可用 Key）。
发现回归时先补契约测试再改流解析，不要凭猜测改 genkit 内部。

## 3. R0 未决缺口（不发明，施工前必须冻结）

| 缺口 | 归属批次 | 现状 |
| --- | --- | --- |
| ~~`prototype/` 目录形态与 manifest 字段~~ | R1 / 设计批次 3 | **已冻结（2026-11-24）**：`.ddp` docs 元数据 `prototype` 段（`nan.design.prototype/1`），字段见 [design-contract.md](design-contract.md) §2；无 sidecar。 |
| 幕 → 场 → 镜头层级 vs `schemas.md` 的扁平 `shots[]` | R1 / 5b | plan §5.1 写层级，schemas/video-pipeline 用扁平 shots；形态待 R1，契约先按扁平字段摘要 |
| TimingCompiler 落点：回写 `durationFrames` vs 带 hash 派生 timing 文件 | R1 / 5b | 两者都禁运行时估算；落点待 R1 二选一 |
| 覆盖验证的画板/连线清单来源：canonical 解析 vs 原型 manifest | R1 / 批次 3 | 待 R1 定；不得让模型自报清单 |
| `docs/video-engine-contract.md` 是否另立（plan §5.0 提到） | 5a | R0 交付 [video-screenplay-contract.md](video-screenplay-contract.md)；引擎契约合并处待 5a 冻结 |
| graphics 轨 plan 字段（schemas.md 只有 common + 对象/场景） | 4 | 先按 common 段 + 帧验收；具体字段待 R1 |
| 旧视频项目（`timeline.json` / `spec.json` / `video.json`）迁移策略 | R1 / 5b | 先做兼容读取；惰性重写 vs 显式迁移待 R1 |
| `verifyScore` 各乐器音域表（plan 只给 tempo/轨道/小节上限） | 6 | 结构门先跑；音域表待 R1 冻结 |
| 评分校准 artifact bank（3D 对象/场景/视频各多少件） | 4 / 5b | plan/research 均未给数量；校准前 `passThreshold` 仅暂定 |
| Phaser 4.2.1 与 3.90 spike 验收项（帧预算 / Canvas 回退） | 5a | 待 spike 写进 §1 冻结行 |
| `ink_line` 性能回退（预烘焙笔触图集）触发阈值 | I0 | research 只建议「不达标再评估」，阈值待 I0 |

## 4. R0 登记的口径冲突（不擅自改方案文档，等回填）

1. **Genkit**：已裁决并实施（2026-11-23），见 §2。
2. **Phaser 3 vs 4.2.1**：[video-clip-contract.md](video-clip-contract.md) 与 README §1.3
   记「Phaser 3」为规划渲染面；plan §5.0 版本回填与
   [research/video-animation-howto.md](research/video-animation-howto.md) §0 建议锁
   **4.2.1**（3.90 回退）。R0 按冻结表的「5a spike 定」处理，契约不写死版本。
3. **`hotapp_from_prototype` 是否已实施**：[hotapp-from-prototype.md](hotapp-from-prototype.md)
   §4 记「agent 工具尚未实施（2026-11-19 复核）」，但 `app/lib/core/dart_agent.dart`
   已有该工具分支（2026-11-23 实测）。本文不改 hotapp 文档；迁移到
   `design_verify_prototype`（拟实现）时一并回填两处。
4. **音乐字段口径**：[plan-music-module.md](plan-music-module.md) §2 示例是 `"v": 1`、
   note 级 `pitch: "C5"` 与 `tie: "start"`；
   [research/music-arrangement-howto.md](research/music-arrangement-howto.md) §1.2 要求
   `schemaVersion`、`pitch {step, alter, octave}` 与关系对象 `Beam/Tie/Slur`（明确反对
   note 级 tie/beam 标记）。R0 契约按 research 口径冻结，plan 示例待 R1 回填修订。
5. **轨数上限表述**：plan-music §2 写「轨道数上限 8（音轨 6 + 鼓轨 2）」，契约统一写
   「轨道 ≤8」；6+2 只是其中一种配置，不写进校验器错误文案。
6. **视频渲染面计数**：video-clip-contract 记「两种渲染面并存」，plan §5.0 记「三渲染面」。
   R0 契约按**三渲染面**（矢量算式 / DOM 动效合成 / 引擎短片）表述，v1 契约本身不动。
7. **五线谱字形来源**：plan-music §3 写「谱号代码画而非 SMuFL 字体，零依赖」；
   research/music-arrangement-howto.md §2.2 写 SMuFL 度量 + Bravura（SIL OFL）。
   R0 契约按 CustomPainter + SMuFL 度量 + Bravura（可嵌入）冻结，谱号等字形最终用
   代码画还是 Bravura 字形待 R1 定——两者都不影响 score.json 事实源。

## 5. 交付纪律

* 本轮五份新文档（含本台账）的状态行统一 `草案（R0 契约冻结，2026-11-23）· 未施工`；
  施工回填落地锚点时同步改 [README.md](README.md) §1.4 与 §2，不单独改本台账历史行。
* 契约测试模板（plan §1.2）：schema roundtrip、校验器清单、编译器确定性、工具接线、
  落盘扫描；每份契约末尾「验收锚点」只给**拟写测试名**。

## 6. R0 落地锚点（2026-11-23）

R0 的**契约核心代码与测试已落地**；四份模块契约本身仍是未施工目标态。

* 契约模型/校验器：`app/lib/core/creative/creative_schema.dart`（schema 常量、枚举、
  JSON 指针、安全路径、轮次 id）、`creative_spec.dart`、`creative_plan.dart`（3D/video）、
  `creative_gates.dart`、`creative_judgment.dart`、`creative_score.dart`（rubric / penalty /
  floor / cap / best-round）、`creative_workspace.dart`（轮次路径与 round manifest）。
* fixtures：`app/test/fixtures/creative/*.json`（10 份 spec/plan/gates/judgment 正负例）。
* 契约测试：`app/test/creative_{spec,plan,gates,judgment_score,workspace}_test.dart`
  + `app/test/creative_contracts_docs_test.dart`（文档门：五份文档在位、状态行、
  已进 `docs/README.md` 索引、Genkit 迁移裁决记录）。
* 本轮验证：`flutter analyze --no-pub` 仅剩 genkit 迁移文件的 2 条既有 info；
  `flutter test --no-pub` 全量 **1202 passed / 1 failed**——唯一失败是既有环境项
  `desktop_rpc_host_test` 的「对端消失 → keep-alive 取消」（无 root linglong 容器
  loopback 观测不到，非 R0 回归）；R0 相关测试 39 + 12 全绿。
* Agent 流（2026-11-24）：workspace 工具面按 `workspaceHint` 收窄（three/video/hotapp）；
  统一创作 skill 蒸馏文本经 `app/lib/core/creative/creative_skill.dart` 注入设计/workspace run；
  盲评通道 = `creative_judge.dart`（fresh context、无工具、brief+MediaPart 图、坏 JSON/无图/模型错
  一律显性降级）+ agent 工具 `creative_judge`（仅 3D/视频 workspace run；图像必须在本机项目目录内）。
  已再落：双面组件 `workspace_progress.dart`/`workspace_artifact_card.dart` 接入设计模块
  （阶段 build/verify/persist + 结果卡 + 覆盖检查对话框）；剩余：3D/视频/音乐工作台接入同一双面骨架。
* 下一步 R1 顺序：creative workspace store（按本文轮次协议）→ 双面组件
  （进度线/产物卡）→ judge pack/score 接线骨架；judge 的模型调用通道按 Genkit 接线（2026-11-23 裁决），契约/stub 先行。
