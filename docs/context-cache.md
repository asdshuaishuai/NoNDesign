# 上下文与缓存策略

> 本文描述的是 **Dart 进程内 Agent**（`app/lib/core/dart_agent.dart`）的现状。
> 早期的 Python 服务端实现（server/context.py / server/engine.py）已随
> de-Python 迁移退场（批次 15，2026-11-18，见
> `docs/plan-dart-agent-migration.md` 与 `docs/round7-residuals.md` 头部登记）；
> 本文全文按 Dart 侧现状书写，不再描述任何已删除的服务端行为。

NaN 的 Agent 上下文按 **稳定 → 易变** 排序，目标不是「塞更多」，而是让同一项目
跨 run 命中尽可能长的 provider 前缀缓存，同时让模型在最新 token 位置看到最新真相。

## 分层

| 层 | 内容 | 变化频率 | 缓存含义 | Dart 锚点 |
|---|---|---|---|---|
| L0 | 模式化静态指令 + 工具 schema | 版本级 | 跨 run / 跨项目命中 | `composeDartInstructions`（dart_agent.dart:1377）+ `_buildTools` |
| L1 | PROJECT MAP（画板、节点 id、flows、theme/entry） | 项目内稳定 | 同项目多个 run 命中 | `composeProjectMap`（dart_agent.dart:1029） |
| L2 | DESIGN SPEC + PRD/UI 文档 | 编辑后变化 | 编辑前多轮命中 | instructions 的 DESIGN SPEC / PRODUCT DOCS 节（dart_agent.dart:1454 起） |
| L3 | 会话记忆（压缩摘要 + 最近条目） | — | **未实施（P2）** | 见下「会话记忆」节的诚实登记 |
| L4 | 最新 `state`（rev / 各板节点数 / flow 数） | 每个变更 op | 追加在 tool 结果尾部 | `stateSummary`（dart_agent.dart:1011） |

- 提示词中**没有时间戳**、没有随机排序、没有每次 run 变化的 id；`composeProjectMap`
  按文档顺序输出（先 boards 后 flows），节点 id 截断 24/板（`ids.length >= 24` 即断）、
  flows 截断 40 条；注入 instructions 时 PROJECT MAP 整段截断 7000 字符
  （dart_agent.dart:1451）。PROJECT MAP 在 run 起点现查现新
  （`session_list_artboards` / `session_query_nodes` / `session_flows`），随后
  整段字节稳定，provider 前缀缓存整段命中。
- 变更不改写历史：模型看到的是「追加的最新状态」，而不是被重写的前缀——这是前缀缓存
  能持续命中的前提。

## 会话记忆（未实施，P2）

**Dart 侧没有 CompactingSession**——`dart_agent.dart` 头部差异清单的诚实登记原文：
「无 CompactingSession 持久会话记忆（P2 上下文层）」（dart_agent.dart:45）。

- 每轮 `streamText` 只带 `instructions` + 本轮 prompt，**不携带上一轮的消息列表**；
  run 与 run 之间没有对话记忆层，跨 run 项目理解完全靠 L1 的 PROJECT MAP
  （每次 run 起点重新合成）。
- 聊天流里的用户/进度/A2UI/产物卡消息随 `chat.json` 落盘
  （store.dart:2949-2961，`$recoveryDir/chat.json`，与 recovery 同目录）——
  那是**界面记录**，不进 provider 上下文。
- 若未来实施压缩摘要：阈值、保留条数、`[SESSION MEMORY]` 插入位置等参数在
  Dart 侧尚未定型，不要照抄旧服务端数值。

## 上下文窗口与预算

- 窗口来自模型元数据 `limit.context`（models.dart:400/425，未命中回落 128000），
  由 store.dart:3134 随 run 传入（`contextWindow: selected?.context`）。
- **当前用途只有遥测展示**：随 `usage` 事件透传给前端
  （dart_agent.dart:844-845 注释「仅随 usage 事件透传给前端展示」）。
  Dart 侧目前**没有**逐模型预算守卫、没有超窗裁剪、没有上下文夹紧——
  超窗行为交给 provider 报错兜底。旧实现「超 70% 激进裁剪 / 服务端夹紧 16K」
  均未移植；把预算守卫列为 P2 时一并登记。

## 工具结果整形

`compactEnvelope`（dart_agent.dart:1067，引擎信封统一出口）：

- 去 `mbt`、`render`；
- 去 `artboards[].svg`、`nodes[].style`；
- 节点截断 24（超出置 `nodes_truncated`）、`data` 数组截断 40（置 `data_truncated`）；
- 成功变更后追加 `state=rev=N boards=[id:n] flows=M`（`stateSummary`，挂载点
  dart_agent.dart:1846 会话路径 / :2494 无状态路径）。
- `read_docs` 不经引擎——docs 在 run 请求载荷里，循环本地读（dart_agent.dart:126），
  内容截断 12000 字符（dart_agent.dart:2258）。
- **没有跨轮 supersede**：旧实现的「旧 read 结果被会话压缩替换为占位摘要」在
  Dart 侧不存在；同一 run 内旧工具结果原样保留在消息历史里（不删消息、不重写）。

## 缓存遥测

- `_RoundUsage`（dart_agent.dart:1499-1520）逐轮聚合 requests / input / output /
  total，`cachedTokens` 累加自 provider 回显的 `cached_tokens`；
- 每轮结束发 `usage` 事件（dart_agent.dart:1687，携带 `contextWindow`）；
- 前端展示：右栏（right_panel.dart:81）与设置页（settings_dialog.dart:1445、2197）
  用 `cachedTokens / inputTokens` 算命中率。
- `usage` 是遥测不是正确性：abort 路径 futures 会抛，终态有兜底
  （dart_agent.dart:1623 注释）。

## 测量方式

用真实 provider 跑两轮同项目 BUILD/REFINE，观察第二轮 `usage.cachedTokens / inputTokens`；
若命中率低，优先检查：
1. 提示词是否混入时间/随机内容（instructions 必须是纯函数——同输入同字节）；
2. PROJECT MAP 是否按文档顺序稳定（`composeProjectMap` 的输出顺序）；
3. 工具结果是否被无谓重写（追加 `state` 而不是改历史）；
4. 会话压缩（L3）是否已实施并在过于频繁地打断前缀——当前未实施，此项暂不适用。
