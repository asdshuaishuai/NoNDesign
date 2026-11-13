# 上下文与缓存策略

NoNDesign 的 Agent 上下文按 **稳定 → 易变** 排序，目标不是"塞更多"，而是让同一项目
跨 run 命中尽可能长的 provider 前缀缓存，同时让模型在最新 token 位置看到最新真相。

## 分层

| 层 | 内容 | 变化频率 | 缓存含义 |
|---|---|---|---|
| L0 | 模式化静态指令 + 工具 schema | 版本级 | 跨 run / 跨项目命中 |
| L1 | PROJECT MAP（画板、节点 id、flows、theme） | 项目内稳定 | 同项目多个 run 命中 |
| L2 | DESIGN SPEC + PRD/UI 文档 | 编辑后变化 | 编辑前多轮命中 |
| L3 | 会话记忆（压缩摘要 + 最近条目） | 每轮追加 | 追加式，不重写历史 |
| L4 | 最新 `state`（rev / 各板节点数 / flow 数） | 每个变更 op | 追加在 tool 结果尾部 |

- 提示词中**没有时间戳**、没有随机排序、没有每次 run 变化的 id；`compose_project_map`
  按文档顺序输出，节点 id 截断 24/板。
- 工具结果只保留摘要 + `state`；canonical 与 SVG 剥离，旧 `read_mbt`/`inspect` 结果
  由会话压缩替换为占位摘要（supercede）。
- 变更不改写历史：模型看到的是"追加的最新状态"，而不是被重写的前缀——这是前缀缓存
  能持续命中的前提。

## 会话记忆

`server/context.py::CompactingSession`

- 阈值：超过 80 条或估算 token > 55% 模型窗口时压缩。
- 保留最近 18 条逐字；更早的 user/assistant 文本进入确定性摘要（≤1400 字）。
- 摘要作为一条 `[SESSION MEMORY]` user 消息插在历史前部；不额外调用 LLM。
- 会话文件：`~/.nondesign/sessions/<project-key>.json`；`/agent/session/clear` 删除。
- 上下文窗口来自 models.dev `limit.context`，由 Flutter 随请求传入；服务端再次夹紧
  下限 16K。

## 工具结果整形

`server/engine.py::compact_envelope`

- 去 `mbt`、`render`；
- 去 `artboards[].svg`、`nodes[].style`；
- 节点截断 24、`data` 数组截断 40；
- 成功变更后追加 `state=rev=N boards=[id:n] flows=M`。

## 缓存遥测

- 聚合 `raw_responses[].usage`：requests / input / output / total；
- 从 `input_tokens_details.cached_tokens` 读取缓存命中 token；
- SSE 末尾发 `usage` 事件；Flutter 状态栏 / NoN 头部 / 设置页展示
  `ctx` 与 `⚡命中率`。

## 测量方式

用真实 provider 跑两轮同项目 BUILD/REFINE，观察第二轮 `usage.cachedTokens / inputTokens`；
若命中率低，优先检查：
1. 提示词是否混入时间/随机内容；
2. PROJECT MAP 是否按文档顺序稳定；
3. 工具结果是否被无谓重写；
4. 会话压缩是否过于频繁。
