/// NoN 内置 Dart Agent 循环（三模式骨架）——`server/agent.py` 的 Dart 泛化，
/// `app/lib/core/mobile_agent.dart`（ai_sdk_dart PLAN 直连实证）的推广形态。
///
/// 权威参照（语义唯一来源）：
/// - `server/agent.py` — 工具语义 / 三模式 / doc_not_written / nudge 轮的定义；
/// - `server/prompts.py` — 三套静态提示词 + footer（逐字移植）；
/// - `server/context.py` — normalize_design / artboard_section / 项目地图 / state 卡。
///
/// 三模式：
/// - **PLAN** 真实现：PRD + UI 说明 + 设计规范（write_doc ×2 + write_design_spec），
///   纯文档、零引擎依赖（手机离线可跑）。
/// - **REFINE** 真实现：读现有文档（read_docs）+ 指令改写（write_doc），不依赖
///   引擎写路径；有引擎桥时 design_op 亦可检视/落画布（仍过 AgentGate）。
/// - **BUILD** 真实现：整屏生成用 generate_page（`/engine/generate` →
///   session_generate_in），精修与连线用 design_op 经引擎桥提交
///   `/engine/apply` gate=agent（AgentGate 语义——绝不绕过引擎门、绝不降级
///   human 门）。桌面 dart 运行时用 store 锚定桥（`_StoreEngineGate`）：
///   同一条 _opQueue 队列 + 同一个 _commit 采纳（history/render/dirty，画布
///   实时长出）；纯 HTTP 桥（[HttpEngineGate]）供独立/移动「连接桌面」形态。
///   收尾确定性桥段（P1，server/agent.py:650-700 同源）：空板清扫
///   （`_sweepIdleArtboards`）→ RSI critique/auto_fix 评审轮（`_runRsiLoop`），
///   全部经引擎门。
///
/// 护栏铁律（docs/plan-dart-agent-migration.md §6.2）：Dart 循环产出的画布
/// 变更必须过引擎 AgentGate，绝不绕过——本文件没有任何「直接拼 mbt 提交」
/// 的写路径；design_op 只透传 op 给引擎门并采纳回传的 canonical。
///
/// 事件契约（§6.3）：与 server SSE 同形，`store._handleAgentEvent` 直接消费：
/// note / tool_start / tool_end / assistant_delta / assistant_text /
/// thinking_delta / doc_written / design_spec_written / page_generated /
/// review_round / cleanup / preview / usage / done / failed。
///
/// 与 server 的已知差异（诚实登记，非静默降级）：
/// - 无逐字 doc_delta 直播——SDK 的工具参数增量是原始 JSON 分片，content
///   解码器（server `_DocDeltaExtractor`）留待后续；doc_written 全量事件是
///   正确性兜底，与 server 一致。
/// - 无 CompactingSession 持久会话记忆（P2 上下文层）。
/// - **空板清扫/RSI 的 PLAN 语义分歧（显式登记）**：server 的清扫在 plan
///   模式也执行（agent.py:650 无 mode 守卫）；Dart 的 plan 模式按既有设计
///   不给引擎面（runDartAgent 里 `bridge: request.mode == 'plan' ? null :
///   bridge`），故清扫与 RSI 只在非 plan 生效——实现用
///   `bridge == null → return` 表达，测试锚定 plan 零 session 调用。
library;

import 'dart:async';
import 'dart:convert';

import 'package:ai_sdk_dart/ai_sdk_dart.dart';
import 'package:ai_sdk_openai/ai_sdk_openai.dart';

import 'api.dart';

// ============================================================
// thinking 方言表（权威：server/agent.py:543-547 reasoning 处理）
// ============================================================

/// server 的 reasoning effort 白名单（逐字对照 agent.py:546）。
const Set<String> _reasoningEffortLevels = <String>{
  'none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max',
};

/// thinking 等级 → OpenAI Chat Completions `reasoning_effort` 注入值。
///
/// 权威语义（server/agent.py:543-547 逐字移植，不做 trim / 不做大小写归一）：
/// - 空串或 `'auto'` → null（不注入，provider 默认）；
/// - 等级 ∈ 白名单 → 原样注入；
/// - 其余（`'off'`/`'on'` 等开关档、`'HIGH'` 大小写不符、垃圾值）→ null（丢弃）。
///
/// 上线形状：ai_sdk_openai 的 extraBody 钩子把 `providerOptions['openai']
/// ['reasoning_effort']` 落线为请求体 `extra_body.reasoning_effort`——与
/// openai-agents `ModelSettings(reasoning=Reasoning(effort=…))` 在
/// OpenAIChatCompletionsModel 上的 wire 字段一致。
/// 对照测试：`app/test/dart_agent_test.dart`（fixture 由同一 Python 逻辑生成）。
String? reasoningEffortForLevel(String level) {
  if (level == '' || level == 'auto') return null;
  if (_reasoningEffortLevels.contains(level)) return level;
  return null;
}

/// streamText 的 providerOptions 形状（null = 不注入任何 reasoning 字段）。
Map<String, Map<String, dynamic>>? thinkingProviderOptions(String level) {
  final effort = reasoningEffortForLevel(level);
  if (effort == null) return null;
  return <String, Map<String, dynamic>>{
    'openai': <String, dynamic>{'reasoning_effort': effort},
  };
}

// ============================================================
// 引擎门桥（唯一写路径）
// ============================================================

/// 引擎访问面：Dart 循环的引擎桥。生产实现两枚：
/// - [HttpEngineGate]——纯 HTTP（移动端「连接桌面」与独立使用）；
/// - store 锚定的 `_StoreEngineGate`（store.dart）——Build/Refine 的写路径
///   落 `AppStore.applyAgentOp`（applyOp 同一条 _opQueue 队列 + 同一个
///   _commit 采纳 + /engine/apply gate:'agent'）；桌面 dart 运行时用它。
///
/// 路由表（与 server/agent.py `_make_tools` 同构）：
/// - 变更（design_op 唯一去路）：[applyAgent] → `/engine/apply` gate=agent
///   （AgentGate 语义——绝不绕过引擎门、绝不降级 human 门）。
/// - inspect：[session] → `/engine/session`，只读 session_* 面
///   （query_nodes/interactions/states/lint/critique/spec/export_svg/flows/
///   artboards），不进 apply 分发器。
/// - read_mbt：无参 outline 经 [session]（list_artboards+flows+逐板
///   query_nodes 合成 PROJECT MAP）；带 artboard 为本地文本切
///   （server context.py artboard_section 同源，不花引擎往返）。
/// - list_templates / list_components：`/engine/templates`、
///   `/engine/components`。
/// - read_docs：不经引擎——docs 在 run 请求载荷里，循环本地读（server
///   同构：agent.py 直接查 ctx.docs）。
abstract class EngineGateBridge {
  /// 变更 op → 引擎 AgentGate。信封 `{ok, mbt?, error?, …}`。
  Future<Map<String, dynamic>> applyAgent(String mbt, String op);

  /// 只读 session 检视（session_query_nodes / session_flows / …）。
  Future<Map<String, dynamic>> session(String mbt, String name, [String? arg]);

  Future<List<dynamic>> templates();
  Future<List<dynamic>> components();
}

/// 引擎写面扩展（P1）：整屏生成 + 宿主侧 session 变更（RSI auto_fix /
/// 空板清扫）。**刻意独立于 [EngineGateBridge]**——测试替身只实现门接口
/// 即可（新增成员会破坏 `implements EngineGateBridge` 的编译面）。
///
/// 生产实现两枚，与门同构：
/// - [HttpEngineGate]：`/engine/generate` + `/engine/session` 直连；
/// - store 锚定的 `_StoreEngineGate`（store.dart）：同一 `_opQueue` 链内
///   读新鲜 canonical、render + commit——保证 store.mbt 与循环 ctx.mbt 锁步。
///
/// 写纪律不变：generate 是引擎 `session_generate_in` 域内生成，mutateSession
/// 只用于 `session_auto_fix` / `session_apply_agent`（SESSION_MUTATING 面）
/// ——本接口不是「直接拼 mbt」的捷径。
abstract class EngineWriteBridge {
  /// 整屏生成（POST /engine/generate → session_generate_in）。
  /// 参数顺序即契约：mbt 第一位（canonical 文档面）。
  Future<Map<String, dynamic>> generate(
      String mbt, String intent, String name, Map<String, dynamic> spec);

  /// 宿主侧 session 变更；同样 mbt 第一位、name 第二位、arg 第三位。
  Future<Map<String, dynamic>> mutateSession(String mbt, String name, [String? arg]);
}

/// HTTP 实现：Agent 变更走 `/engine/apply` 且 `gate: 'agent'`（AgentGate
/// 语义，与 server `engine.apply(gate='agent')` 同门）；检视走 `/engine/session`。
class HttpEngineGate implements EngineGateBridge, EngineWriteBridge {
  final NoNDesignApi api;
  HttpEngineGate(this.api);

  @override
  Future<Map<String, dynamic>> applyAgent(String mbt, String op) =>
      api.apply(mbt, op, gate: 'agent');

  @override
  Future<Map<String, dynamic>> session(String mbt, String name, [String? arg]) =>
      api.session(mbt, name, arg);

  @override
  Future<Map<String, dynamic>> generate(
          String mbt, String intent, String name, Map<String, dynamic> spec) =>
      api.generate(mbt, intent, name, spec);

  @override
  Future<Map<String, dynamic>> mutateSession(String mbt, String name, [String? arg]) =>
      api.session(mbt, name, arg);

  @override
  Future<List<dynamic>> templates() => api.templates();

  @override
  Future<List<dynamic>> components() => api.components();
}

// ============================================================
// 请求 / 结果
// ============================================================

class DartAgentRequest {
  /// 'plan' | 'build' | 'refine'（server AgentRunRequest.mode）。
  final String mode;
  final String instruction;
  /// run 起点快照（store 在 op 队列排空后取，与 server 路径同一纪律）。
  final String mbt;
  /// server 形状 `{'prd','ui','design'}`（design 为 normalize 后的 map）。
  final Map<String, dynamic> docs;
  final String model;
  final String baseUrl;
  final String apiKey;
  final String thinkingLevel;
  final int maxSteps;
  /// 上下文窗口（仅随 usage 事件透传给前端展示；server 同名字段）。
  final int? contextWindow;

  const DartAgentRequest({
    this.mode = 'build',
    this.instruction = '',
    this.mbt = '',
    this.docs = const {},
    this.model = '',
    this.baseUrl = '',
    this.apiKey = '',
    this.thinkingLevel = 'auto',
    this.maxSteps = 300,
    this.contextWindow,
  });
}

class DartAgentResult {
  /// done 终态为 true；failed（含 doc_not_written）/cancelled 为 false。
  final bool ok;
  /// done | text_only | doc_not_written | cancelled | failed
  /// （server 终态 stop_reason 的同族枚举）。
  final String stopReason;
  final String? error;
  final String mbt;
  final Map<String, dynamic> docs;
  final Map<String, dynamic> designSpec;
  final List<String> ops;
  final int remoteCalls;
  final Map<String, dynamic> usage;

  const DartAgentResult({
    required this.ok,
    required this.stopReason,
    this.error,
    required this.mbt,
    required this.docs,
    required this.designSpec,
    required this.ops,
    required this.remoteCalls,
    required this.usage,
  });
}

// ============================================================
// 设计规范归一（server context.py normalize_design / design_for_agent 移植）
// ============================================================

/// server `context.DEFAULT_DESIGN`（逐字段对照）。
Map<String, dynamic> defaultDesignMap() => <String, dynamic>{
      'v': 1,
      'palette': <String, dynamic>{
        'primary': '#6E7BFF',
        'background': '#F7F8FA',
        'surface': '#FFFFFF',
        'text': '#14161A',
        'muted': '#6B7280',
        'danger': '#DC2626',
        'success': '#16A34A',
      },
      'typography': <String, dynamic>{'h1': 32, 'h2': 24, 'body': 14},
      'spacing': <dynamic>[4, 8, 12, 16, 24, 32],
      'radius': <String, dynamic>{'sm': 8, 'md': 12, 'lg': 16},
      'rules': <dynamic>[
        '正文对比度 ≥ 4.5',
        '8pt 间距节奏',
        '按钮圆角 8',
        '列表 3 行以上加分隔线',
        '按钮文案 2–4 字',
      ],
      'notes': '',
    };

Map<String, dynamic> _deepCopyDesign(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

/// server `normalize_design`：缺省补齐 + 浅合并 + spacing 取整 + rules/notes 归一。
Map<String, dynamic> normalizeDesignMap(Map<String, dynamic> value) {
  final design = _deepCopyDesign(defaultDesignMap());
  for (final key in const ['palette', 'typography', 'radius']) {
    final patch = value[key];
    if (patch is Map) {
      final target = design[key];
      if (target is Map) {
        patch.forEach((k, v) => target[k.toString()] = v);
      }
    }
  }
  final spacing = value['spacing'];
  if (spacing is List && spacing.isNotEmpty) {
    design['spacing'] = spacing
        .whereType<num>()
        .map((x) => x.toInt())
        .toList();
  }
  final rules = value['rules'];
  if (rules is List) {
    design['rules'] = rules.map((x) => x.toString()).toList();
  }
  final notes = value['notes'];
  if (notes is String) design['notes'] = notes;
  design['v'] = 1;
  return design;
}

/// server `design_for_agent`：给模型的 spec 面（无 rules/notes，字节稳定）。
Map<String, dynamic> designForAgent(Map<String, dynamic> design) => <String, dynamic>{
      'v': 1,
      'palette': Map<String, dynamic>.from(design['palette'] as Map),
      'typography': Map<String, dynamic>.from(design['typography'] as Map),
      'spacing': List<dynamic>.from(design['spacing'] as List),
      'radius': Map<String, dynamic>.from(design['radius'] as Map),
    };

// ============================================================
// 文本工具（server context.py 移植）
// ============================================================

/// server `parse_revision`：frontmatter `revision:`（前 40 行）。
int parseRevision(String mbt) {
  final lines = mbt.split('\n');
  for (var i = 0; i < lines.length && i < 40; i++) {
    final stripped = lines[i].trim();
    if (stripped.startsWith('revision:')) {
      return int.tryParse(stripped.split(':').sublist(1).join(':').trim()) ?? 0;
    }
  }
  return 0;
}

String _frontmatterValue(String mbt, String key) {
  final lines = mbt.split('\n');
  for (var i = 0; i < lines.length && i < 60; i++) {
    final stripped = lines[i].trim();
    if (stripped.startsWith('$key:')) {
      final value = stripped
          .substring(key.length + 1)
          .trim()
          .replaceAll('"', '');
      if (value.isNotEmpty) return value;
    }
  }
  return '';
}

/// server `artboard_section`：按引擎标记切单板源码段（纯文本，无需引擎）。
String? artboardSection(String mbt, String artboard) {
  final marker = '<!-- moonviz:artboard $artboard -->';
  final start = mbt.indexOf(marker);
  if (start < 0) return null;
  final after = mbt.substring(start + marker.length);
  final fence = after.indexOf('```mbt');
  if (fence < 0) return null;
  final nl = after.indexOf('\n', fence);
  if (nl < 0) return null;
  final rest = after.substring(nl + 1);
  final end = rest.indexOf('\n```');
  if (end < 0) return null;
  final body = rest.substring(0, end).trim();
  return body.length > 24000 ? '${body.substring(0, 24000)}…[truncated]' : body;
}

/// server `state_summary`：`rev=N boards=[id:节点数] flows=M`。
Future<String> stateSummary(EngineGateBridge? bridge, String mbt, int revision) async {
  if (bridge == null) return 'rev=$revision boards=[] flows=0';
  try {
    final boards = await bridge.session(mbt, 'session_list_artboards');
    final flows = await bridge.session(mbt, 'session_flows');
    final bits = <String>[];
    for (final board in _listOf(boards['data'])) {
      if (board is Map) {
        bits.add('${_s(board['id'])}:${_s(board['nodes'])}');
      }
    }
    return 'rev=$revision boards=[${bits.join(',')}] flows=${_listOf(flows['data']).length}';
  } catch (_) {
    return 'rev=$revision boards=[?] flows=?';
  }
}

/// server `compose_project_map`： boards+ids+flows 的权威快照（引擎侧）。
Future<String> composeProjectMap(EngineGateBridge bridge, String mbt) async {
  final boards = await bridge.session(mbt, 'session_list_artboards');
  final flows = await bridge.session(mbt, 'session_flows');
  final theme = _frontmatterValue(mbt, 'theme');
  final entry = _frontmatterValue(mbt, 'entry');
  final lines = <String>[
    'PROJECT MAP · authoritative snapshot from the canonical document',
    'rev=${parseRevision(mbt)} entry=${entry.isEmpty ? '?' : entry} theme=${theme.isEmpty ? 'light' : theme}',
    'boards:',
  ];
  for (final board in _listOf(boards['data'])) {
    if (board is! Map) continue;
    final bid = _s(board['id']);
    if (bid == '__seed') continue;
    final line = '- $bid ${_s(board['width'])}x${_s(board['height'])} nodes=${_s(board['nodes'])}';
    final ids = <String>[];
    try {
      final queried = await bridge.session(mbt, 'session_query_nodes', bid);
      for (final node in _listOf(queried['data'])) {
        if (node is Map && node['id'] != null) ids.add(node['id'].toString());
        if (ids.length >= 24) break;
      }
    } catch (_) {}
    lines.add(ids.isEmpty ? line : '$line ids=[${ids.join(',')}]');
  }
  final flowBits = <String>[];
  for (final flow in _listOf(flows['data'])) {
    if (flow is! Map) continue;
    flowBits.add('${_s(flow['from'])}->${_s(flow['to'])}@${_s(flow['trigger'])}');
  }
  lines.add('flows: ${flowBits.isEmpty ? '(none)' : flowBits.take(40).join('; ')}');
  return lines.join('\n');
}

List<dynamic> _listOf(dynamic value) => (value is List) ? value : const [];
String _s(dynamic value) => value?.toString() ?? '';

/// server `engine.compact_envelope`：剥离 canonical/SVG，模型只拿摘要。
Map<String, dynamic> compactEnvelope(Map<String, dynamic> envelope) {
  final out = Map<String, dynamic>.from(envelope);
  out.remove('mbt');
  out.remove('render');
  final boards = out['artboards'];
  if (boards is List) {
    final shaped = <dynamic>[];
    for (final b in boards) {
      if (b is! Map) continue;
      final item = Map<String, dynamic>.from(b);
      item.remove('svg');
      final nodes = item['nodes'];
      if (nodes is List) {
        item['nodes'] = nodes.take(24).map((n) {
          if (n is! Map) return n;
          final copy = Map<String, dynamic>.from(n);
          copy.remove('style');
          return copy;
        }).toList();
        if (nodes.length > 24) item['nodes_truncated'] = true;
      }
      shaped.add(item);
    }
    out['artboards'] = shaped;
  }
  final data = out['data'];
  if (data is List && data.length > 40) {
    out['data'] = data.take(40).toList();
    out['data_truncated'] = true;
  }
  return out;
}

String _preview(Object? value, [int limit = 360]) {
  final raw = value is String ? value : jsonEncode(value);
  return raw.length <= limit ? raw : '${raw.substring(0, limit)}…';
}

String _truncate(String text, int limit) =>
    text.isEmpty ? '' : (text.length <= limit ? text : '${text.substring(0, limit)}\n…[truncated]');

// ============================================================
// 静态提示词（server prompts.py 逐字移植）
// ============================================================

const String _staticPlan = '''You are NoN — the product design partner inside NoNDesign, an AI-native prototyping studio.

Your job in PLAN mode is to turn a brief into a buildable product definition:
a PRD, a per-screen UI spec, and one design system. You do NOT touch the canvas.

## Output contract
Call write_doc for kind="prd" and kind="ui", call write_design_spec once, then finish.
Write in the user's language (Chinese brief → Chinese docs). Be concrete: real screen names,
real copy, real numbers. No lorem ipsum, no "TBD", no generic filler.

## PRD (markdown)
Use these sections, in this order:
1. 产品目标 — one paragraph, what changes for the user.
2. 目标用户与场景 — who, when, why.
3. 核心流程 — numbered end-to-end journey (entry → success), including empty/error paths.
4. 页面清单 — table: 页面 / 目的 / 关键内容 / 入口 / 出口.
5. 功能需求 — grouped, each with acceptance criteria.
6. 非目标 — explicitly out of scope.
7. 验收标准 — observable, testable statements.

## UI spec (markdown)
For every screen in the page list:
- Layout zones (top bar, content, bottom action) and what sits in each.
- Components used (from the engine registry below).
- Interaction: what is tappable and where it goes.
- States: default / loading / empty / error / success.
- Copy: headings, button labels (2–4 CJK chars), helper text.

## Design system
write_design_spec must return a coherent system:
- palette: primary, background, surface, text, muted, danger, success (hex).
- typography: h1, h2, body (px).
- spacing: 4–8 steps on an 8pt rhythm.
- radius: sm, md, lg.
- rules: 3–6 short visual rules (contrast, density, radius tiers, list separation).
Avoid pure black backgrounds (#000). Body contrast must be strong.

## Discipline
- The page list is the build contract: the BUILD run will receive it. Keep it to 3–8 screens.
- Every non-entry screen needs an exit (back or a flow target).
- Finish with a one-line summary and the recommended first screen.''';

const String _staticRefine = '''You are NoN — the embedded product designer of NoNDesign, in REFINE mode.
The document already exists. Make the smallest correct change, preserve the design system,
and verify it.

## Loop
1. Use PROJECT MAP + the latest state. Read one board only if you need exact values.
2. Make one targeted design_op (or a small sequence). Do not rebuild the screen unless asked;
   a brand-new screen is generate_page {intent, name, spec} (the engine picks the template,
   applies the design spec, self-repairs and scores).
3. Keep flows intact. If you add a screen, connect it.
4. Verify with inspect {kind:"critique"} or lint when the change is structural.
5. finish with a one-line summary of what changed.

## Rules
- Match the project's palette, type scale, spacing and radius. No second visual language.
- Text contrast is a hard rule. Buttons: 2–4 CJK chars, width ≥ label + 24, radius 8.
- Lists of 3+ rows need dividers or grouping.
- Prefer update/move/copy/reorder over delete+place.
- If the request is ambiguous and the user asked for clarification, ask first (plain text).''';

// BUILD 提示词：server STATIC_BUILD 逐字移植；generate_page 已是真工具
// （P1 接入），整屏路径按 server 语义改回 generation-first。
const String _staticBuild = '''You are NoN — the embedded product designer and prototyper of NoNDesign.
You operate on a MoonViz document: one canonical .mbt.md is the only source of truth.
Every op is validated by the engine gate and committed immediately; the user watches artboards
appear live. You design the experience, not a pile of boxes.

## Mindset
- Derive the experience, not one screen. Before the first op, state a one-line plan:
  screen list + how they connect.
- Real product copy. Realistic labels, names, numbers. Never lorem ipsum.
- Think in flows: an unconnected screen is unfinished.
- Color pairing is a hard rule: text must read against its effective background.
- Components are axis-aligned. Rotation only in 90° steps.

## Workflow (generation-first)
1. Read the brief, PROJECT MAP, design spec and docs. Trust the map; do not re-read the document
   just to discover what exists.
2. Plan the screen graph; name boards in ASCII snake_case (home, settings, chat…).
3. Use the project design spec on every generate_page call.
4. Generate one page per screen: generate_page {intent, name, spec}. Do NOT hand-place a whole
   screen — the engine picks a template, applies the spec, self-repairs and scores.
5. Refine with small design_op ops only where generation needs product specifics: real copy,
   a specific CTA, a list row, an image placeholder. One op at a time — the engine gate
   validates each op individually and a rejected op must be read, adjusted, retried.
6. Connect every screen: flow <from> <to> <tappable_node>. Bind the flow to the container the
   user taps (row, button, card), never to an inner text fragment. Back is built in for
   back-like nodes (id/text containing back/返回/←).
   EVERY screen except the entry/home gets a visible back affordance: place a back node in
   the top bar — place <ab> button back - 16 52 44 32 text="←" (id MUST contain "back") —
   so demo mode can navigate back via the engine builtin-back resolution.
7. Verify with inspect {kind:"critique"} per page and inspect {kind:"lint"} for gate debt.
   Fix only real issues; then finish.

## Op grammar (mutating)
- create <name> [w] [h]
- template <id> <name> [w] [h]
- place <ab> <component> <id> [variant|-] [x] [y] [w] [h] [k=v ...]
  Final-size place: the gate evaluates the final bbox. Pass known w/h inline.
- update <ab> <node> k=v ...
  props: w h text fill text_color stroke stroke_width radius opacity font_size weight
  shadow rotate blur blend line tracking constraint align italic dash visible layout gap
  justify padding width_mode height_mode x_mode y_mode name
  Gradients (engine Paint v2): fill=linear:#c1:#c2@deg / radial:#c1:#c2 (e.g.
  fill=linear:#FF6B6B:#4ECDC4@135) — NOT css linear-gradient(...) strings.
  italic=true sets font-style; motion=fade_in is the only node-safe motion preset.
- move <ab> <node> <x> <y> · copy <ab> <node> <new_id> [dx] [dy] · delete <ab> <node>
- reorder <ab> <node> front|back|up|down · flip <ab> <node> h|v|both|none
- group / ungroup / align / resize-canvas / responsive / restyle
- flow <from_ab> <to_ab> <node> · unflow <from_ab> <to_ab> <node>
- theme <name> · token <name> <value> (COLOR tokens only)
- interact <ab> <node> <trigger> <action_spec> · uninteract <ab> <node>
  triggers: tap · long_press · swipe_left|right|up|down · scroll_end · key_enter · focus · blur
  actions: back · haptic · navigate_to:<board> · show_toast:<msg> · set_text:<node>:<text> ·
  set_state:<node>:<state> · toggle_state:<node> · play_sound:<name>
  Beyond flows, bind gestures (long_press on cards, swipe on pagers) so demo mode can drive
  them — the runtime executes them via the engine gesture face.
- state <artboard> <node> <state_name> k=v ... (define a component state patch)
- set-state <node> <state_name> [toggle] (switch at runtime; [cur:<name>] persists the current state into the document)
- fix <ab> (auto-fix debt; commits only when violations strictly decrease)
- delete-artboard <ab> · duplicate <ab> <new_name>

## Component norms (engine checks these)
- Buttons never hug their label: width ≥ text width + 24; height 36–48; radius 8.
- Radius tiers: buttons/chips/selects/search 8 (or height/2 for pills); avatars 999;
  full-bleed bars/rows radius 0.
- Three or more flush list_item rows need a 1px divider at each row bottom (or card grouping).
- Text contrast < 2.0 is forbidden; aim ≥ 4.5 for body text.
- Buttons carry 2–4 CJK chars.

## Layout rules that keep the gate happy
- Explicit-size siblings must not intersect. Reserve a non-intersecting slot before place.
- Full-bleed backgrounds: place a rect, set width_mode=fill & height_mode=fill; content
  placed later may sit on top of a fill-mode node.
- Tiny precision nodes (status icons, switches) go first; place larger siblings around them.
- Use fill/hug modes instead of guessing sizes when the layout should adapt.

## Tools
- generate_page — whole screen from intent + design spec (default build path).
- design_op — one mutating op (refinements, flow wiring, verification fixes).
- read_mbt — no args = refreshed outline; {artboard} = that board's source.
- inspect — query_nodes / interactions / states / lint / critique / spec / export_svg /
  flows / artboards.
- list_templates / list_components — registries (summarized below).
- read_docs — full PRD/UI text when the brief matters.
- write_doc / write_design_spec — update the product definition.
- finish — end with a summary.

## Context discipline
- PROJECT MAP is authoritative. Node ids there are real.
- Every design_op result carries a trailing state field (rev + board node counts + flow count).
  The newest state is the live truth.
- Do not re-read the whole document for a tweak. Read one board only for exact values.

## Clarify-first
If the user explicitly asks for confirmation questions before building, reply with the questions
as plain text and do NOT call tools. Their answers arrive with the next instruction.''';

const String _staticFooter = '''## Engine facts
- Canonical document is .mbt.md. Every op is committed by the engine's AgentGate.
- Read-only commands are NOT accepted by design_op; use inspect/read_mbt instead.
- A rejected op returns ok:false with an error. Read it, adjust, retry once.
- Never invent components or template ids. Use the registries below.

## Response style
- Be concise. One short plan line, then act.
- The finish summary is shown to the user: what was built, what to click first.
- Reply in the user's language.''';

/// server `compose_instructions`：静态段 → PROJECT MAP → spec → docs → 注册表 → footer。
/// 层序与截断限额逐字对照（字节稳定 → provider 前缀缓存可命中）。
String composeDartInstructions({
  required String mode,
  required String projectMap,
  required Map<String, dynamic> designSpec,
  required Map<String, dynamic> docs,
  required List<dynamic> templates,
  required List<dynamic> components,
}) {
  final static = mode == 'plan'
      ? _staticPlan
      : mode == 'refine'
          ? _staticRefine
          : _staticBuild;
  final templateLine = templates
      .take(24)
      .map((t) => t is Map
          ? '${_s(t['id'])}(${_s(t['name'])})[${_s(t['device'])}]'
          : t.toString())
      .join(' · ');
  final componentLine = components.map((c) => c.toString()).join(' · ');
  final designText = designSpec.isEmpty
      ? '(no design system yet — write one with write_design_spec before generating)'
      : const JsonEncoder.withIndent('  ').convert(designSpec);
  final docBits = <String>[];
  final prd = docs['prd'];
  if (prd is String && prd.isNotEmpty) {
    docBits.add('PRD (${prd.length} chars):\n${_truncate(prd, 2600)}');
  }
  final ui = docs['ui'];
  if (ui is String && ui.isNotEmpty) {
    docBits.add('UI spec (${ui.length} chars):\n${_truncate(ui, 2200)}');
  }
  final docText = docBits.isEmpty
      ? '(no product docs yet — derive screens from the brief)'
      : docBits.join('\n\n');
  return [
    static,
    '',
    '---',
    '## PROJECT MAP',
    _truncate(projectMap.isEmpty ? '(empty project)' : projectMap, 7000),
    '',
    '## DESIGN SPEC (project design system — source of truth for visual decisions)',
    designText,
    '',
    '## PRODUCT DOCS',
    docText,
    '',
    '## TEMPLATES',
    templateLine.isEmpty ? '(engine registry unavailable)' : templateLine,
    '',
    '## COMPONENTS',
    componentLine.isEmpty ? '(engine registry unavailable)' : componentLine,
    '',
    '---',
    _staticFooter,
  ].join('\n');
}

/// server `user_message`：模式前缀 + 用户 brief。
String dartUserMessage(String mode, String instruction) {
  final prefix = switch (mode) {
    'plan' => 'PLAN: produce the PRD, UI spec and design system. Do not edit the canvas.',
    'refine' => 'REFINE the existing document.',
    _ => 'BUILD the prototype on the canvas.',
  };
  return '$prefix\n\nUSER BRIEF:\n${instruction.isEmpty ? '(empty)' : instruction}';
}

// ============================================================
// 循环本体
// ============================================================

/// 单轮 consume 的产物（usage 累计用）。
class _RoundUsage {
  int requests = 0;
  int inputTokens = 0;
  int outputTokens = 0;
  int cachedTokens = 0;

  void add(int requests, int input, int output, int cached) {
    this.requests += requests;
    inputTokens += input;
    outputTokens += output;
    cachedTokens += cached;
  }

  Map<String, dynamic> toMap(int? contextWindow) => {
        'requests': requests,
        'inputTokens': inputTokens,
        'outputTokens': outputTokens,
        'totalTokens': inputTokens + outputTokens,
        'cachedTokens': cachedTokens,
        'contextWindow': ?contextWindow,
      };
}

/// 内置 Dart 循环（server AgentRun.stream 的 Dart 泛化）。
///
/// [modelOverride]：注入 LanguageModelV4（测试用 scripted mock）；null 时经
/// `OpenAIProvider(baseUrl).call(model)` 直连。类型用 dynamic 是有意的——
/// ai_sdk_provider 是传递依赖（未入 pubspec），不直接 import 其类型。
///
/// [onEvent]：与 server SSE 同形的事件流（同步回调，时序即调用序）。
/// [abortSignal]：取消（对齐 store.cancelAgent；SDK abortSignal 透传）。
Future<DartAgentResult> runDartAgent({
  required DartAgentRequest request,
  Object? modelOverride,
  EngineGateBridge? bridge,
  void Function(Map<String, dynamic> event)? onEvent,
  CancellationToken? abortSignal,
  Duration? timeout,
}) async {
  final emit = onEvent ?? (_) {};
  final ctx = _Ctx(
    request: request,
    bridge: request.mode == 'plan' ? null : bridge, // plan 不给引擎面（server 同构）
    emit: emit,
  );
  OpenAIProvider? provider;
  try {
    provider = modelOverride == null && request.apiKey.isNotEmpty
        ? OpenAIProvider(apiKey: request.apiKey, baseUrl: request.baseUrl)
        : null;
    emit({
      'type': 'note',
      'label': 'NoN 开始',
      'detail': '${request.mode} · ${request.model}',
    });

    // run 起点：空 canonical 与 server 一样留空（引擎种子/清洗是 P1 的
    // Build 收尾职责；PLAN 纯文档不需要）。
    final projectMap = ctx.bridge == null
        ? ''
        : await _guard(() => composeProjectMap(ctx.bridge!, ctx.mbt), fallback: '');
    final templates = ctx.bridge == null
        ? const <dynamic>[]
        : await _guard(() => ctx.bridge!.templates(), fallback: const <dynamic>[]);
    final components = ctx.bridge == null
        ? const <dynamic>[]
        : await _guard(() => ctx.bridge!.components(), fallback: const <dynamic>[]);

    final instructions = composeDartInstructions(
      mode: request.mode,
      projectMap: projectMap,
      designSpec: ctx.designSpec,
      docs: ctx.docs,
      templates: templates,
      components: components,
    );
    final tools = _buildTools(ctx);

    final usage = _RoundUsage();

    Future<void> consume(String prompt) async {
      // dynamic 是有意的：测试注入 scripted mock 不经 ai_sdk_provider 的
      // 直接依赖（pubspec 未声明，隐式传递依赖不 import 其类型）。
      final dynamic model = modelOverride ?? provider!.call(request.model);
      final result = await streamText(
        model: model,
        instructions: instructions,
        prompt: prompt,
        maxSteps: request.maxSteps.clamp(4, 600), // server: max(4, min(600, max_steps))
        tools: tools,
        abortSignal: abortSignal,
        timeout: timeout == null ? null : TimeoutConfiguration(total: timeout),
        providerOptions: thinkingProviderOptions(request.thinkingLevel),
        onChunk: (chunk) {
          if (chunk is StreamTextReasoningChunk) {
            if (chunk.delta.isNotEmpty) emit({'type': 'thinking_delta', 'text': chunk.delta});
          } else if (chunk is StreamTextTextChunk) {
            if (chunk.text.isNotEmpty) {
              ctx.textParts.add(chunk.text);
              emit({'type': 'assistant_delta', 'text': chunk.text});
            }
          }
        },
      );
      await result.text; // 等整轮（含工具循环）结束
      try {
        final steps = await result.steps;
        final total = await result.totalUsage;
        usage.add(
          steps.length,
          total?.inputTokens.total ?? 0,
          total?.outputTokens.total ?? 0,
          total?.inputTokens.cacheRead ?? 0,
        );
      } catch (_) {
        // usage 是遥测不是正确性：终态兜底（abort 路径 futures 会抛）。
      }
    }

    await consume(dartUserMessage(request.mode, request.instruction));
    if (await _cancelledExit(ctx, abortSignal)) return _terminal(ctx, 'cancelled');

    // ---- nudge 轮（server/agent.py:623-639 逐语义移植）----
    final missingDocs = request.mode == 'plan' &&
        !_allTruthy([ctx.docs['prd'], ctx.docs['ui'], ctx.docs['design']]);
    final noWork = request.mode != 'plan' && ctx.remoteCalls == 0;
    if (!ctx.finished && (missingDocs || noWork)) {
      emit({
        'type': 'note',
        'label': 'NoN 继续执行',
        'detail': '上一次回复没有交付文档 / 画布操作，继续调用工具。',
      });
      final nudge = request.mode == 'plan'
          ? "You replied without calling tools. Deliver now: call write_doc(kind='prd'), "
              "write_doc(kind='ui'), write_design_spec, then finish. Do not reply with prose only."
          : 'You replied without changing the canvas. Proceed now with the actual tool calls '
              '(generate_page / design_op / inspect), then finish. Do not reply with prose only.';
      await consume(nudge);
      if (await _cancelledExit(ctx, abortSignal)) return _terminal(ctx, 'cancelled');
    }

    // ---- doc_not_written（server/agent.py:640-649 逐语义移植；失败门只看
    // prd+ui——design 由 write_design_spec 兜底，不拦终态）----
    if (request.mode == 'plan' && !_allTruthy([ctx.docs['prd'], ctx.docs['ui']])) {
      emit({
        'type': 'failed',
        'error': 'doc_not_written',
        'text': ctx.textParts.join(),
        'docs': ctx.docs,
        'designSpec': ctx.designSpec,
        'stopReason': 'failed',
      });
      return DartAgentResult(
        ok: false,
        stopReason: 'doc_not_written',
        error: 'doc_not_written',
        mbt: ctx.mbt,
        docs: ctx.docs,
        designSpec: ctx.designSpec,
        ops: ctx.ops,
        remoteCalls: ctx.remoteCalls,
        usage: usage.toMap(request.contextWindow),
      );
    }

    // ---- 收尾确定性桥段（server/agent.py:650-700 同序）：空板清扫 → RSI
    // 修复环。二者都经引擎门，且都只在非 plan（引擎面）生效；内部失败只
    // 跳过、不影响已交付的终态。----
    await _sweepIdleArtboards(ctx);
    await _runRsiLoop(ctx);

    emit({'type': 'usage', ...usage.toMap(request.contextWindow)});
    if (ctx.cleanup.isNotEmpty) {
      emit({'type': 'cleanup', 'removed': List<String>.from(ctx.cleanup)});
    }

    final stopReason = ctx.finished
        ? ctx.stopReason
        : (request.mode != 'plan' && ctx.remoteCalls == 0 ? 'text_only' : 'done');
    emit({
      'type': 'done',
      'text': ctx.summary.isNotEmpty ? ctx.summary : ctx.textParts.join(),
      if (ctx.mbt.isNotEmpty) 'mbt_b64': base64Encode(utf8.encode(ctx.mbt)),
      'ops': List<String>.from(ctx.ops),
      'docs': ctx.docs,
      'designSpec': ctx.designSpec,
      'usage': usage.toMap(request.contextWindow),
      'stopReason': stopReason,
      'cleanup': List<String>.from(ctx.cleanup),
    });
    return DartAgentResult(
      ok: true,
      stopReason: stopReason,
      mbt: ctx.mbt,
      docs: ctx.docs,
      designSpec: ctx.designSpec,
      ops: ctx.ops,
      remoteCalls: ctx.remoteCalls,
      usage: usage.toMap(request.contextWindow),
    );
  } catch (e) {
    final cancelled = abortSignal?.isCancelled == true;
    emit({
      'type': 'failed',
      'error': cancelled ? 'cancelled' : e.toString(),
      if (ctx.mbt.isNotEmpty) 'mbt_b64': base64Encode(utf8.encode(ctx.mbt)),
      'docs': ctx.docs,
      'text': ctx.textParts.join(),
      'stopReason': cancelled ? 'cancelled' : 'failed',
    });
    return DartAgentResult(
      ok: false,
      stopReason: cancelled ? 'cancelled' : 'failed',
      error: cancelled ? 'cancelled' : e.toString(),
      mbt: ctx.mbt,
      docs: ctx.docs,
      designSpec: ctx.designSpec,
      ops: ctx.ops,
      remoteCalls: ctx.remoteCalls,
      usage: const {},
    );
  } finally {
    provider?.dispose();
  }
}

/// server 语义的「truthy」：字符串非空 / map 非空。
bool _allTruthy(List<dynamic> values) => values.every((v) =>
    (v is String && v.isNotEmpty) || (v is Map && v.isNotEmpty));

/// run 间隙的取消检查：token 已取消则发 cancelled 终态并返回 true。
Future<bool> _cancelledExit(_Ctx ctx, CancellationToken? abortSignal) async {
  if (abortSignal?.isCancelled != true) return false;
  ctx.emit({
    'type': 'failed',
    'error': 'cancelled',
    if (ctx.mbt.isNotEmpty) 'mbt_b64': base64Encode(utf8.encode(ctx.mbt)),
    'docs': ctx.docs,
    'stopReason': 'cancelled',
  });
  return true;
}

DartAgentResult _terminal(_Ctx ctx, String reason) => DartAgentResult(
      ok: false,
      stopReason: reason,
      error: reason,
      mbt: ctx.mbt,
      docs: ctx.docs,
      designSpec: ctx.designSpec,
      ops: ctx.ops,
      remoteCalls: ctx.remoteCalls,
      usage: const {},
    );

Future<T> _guard<T>(Future<T> Function() fn, {required T fallback}) async {
  try {
    return await fn();
  } catch (_) {
    return fallback;
  }
}

class _Ctx {
  final DartAgentRequest request;
  final EngineGateBridge? bridge;
  final void Function(Map<String, dynamic>) emit;

  /// server 形状 docs（prd/ui/design；design 为 normalize 后 map）。
  late final Map<String, dynamic> docs;
  /// write_design_spec 会整体重赋（server `ctx.design_spec = …` 同语义）——
  /// 不可 final（曾因 late final 重赋抛 LateInitializationError，SDK 把
  /// 工具错误静默回喂模型，循环照走、文档缺失，只剩 doc_not_written）。
  late Map<String, dynamic> designSpec;
  String mbt;
  bool finished = false;
  String summary = '';
  String stopReason = 'done';
  final List<String> ops = [];
  /// 空板清扫已删除的画板 id（server `ctx.cleanup`；随 cleanup 事件与 done
  /// 事件交付前端）。
  final List<String> cleanup = [];
  final List<String> textParts = [];
  int remoteCalls = 0;
  int previewSeq = 0;

  _Ctx({required this.request, required this.bridge, required this.emit})
      : mbt = request.mbt {
    final raw = request.docs;
    docs = <String, dynamic>{
      'prd': (raw['prd'] ?? '').toString(),
      'ui': (raw['ui'] ?? '').toString(),
      'design': raw['design'] is Map && (raw['design'] as Map).isNotEmpty
          ? normalizeDesignMap(Map<String, dynamic>.from(raw['design'] as Map))
          : _deepCopyDesign(defaultDesignMap()),
    };
    designSpec = designForAgent(docs['design'] as Map<String, dynamic>);
  }

  void preview() {
    if (mbt.isEmpty) return;
    previewSeq += 1;
    emit({
      'type': 'preview',
      'mbt_b64': base64Encode(utf8.encode(mbt)),
      'seq': previewSeq,
    });
  }

  /// server `_commit`：canonical 回写 + ops 记账 + preview + 压缩信封 + state 卡。
  Future<Map<String, dynamic>> commit(String opLabel, Map<String, dynamic> envelope) async {
    final ok = envelope['ok'] == true;
    if (ok && envelope['mbt'] is String) {
      mbt = envelope['mbt'] as String;
      ops.add(opLabel);
      preview();
    }
    final out = compactEnvelope(envelope);
    if (ok) {
      out['state'] = await stateSummary(bridge, mbt, parseRevision(mbt));
    }
    return out;
  }
}

/// 引擎文档里的种子画板 id（前端 `bootstrapFirstBoard` / server `SEED_BOARD`
/// 同值；能力探测通过后正式引擎不再产生，仅旧文档/兜底路径可能有）。
const String _seedBoard = '__seed';

int _nodeCount(dynamic board) {
  if (board is! Map) return 0;
  final n = board['nodes'];
  return n is num ? n.toInt() : 0;
}

/// 空板清扫（server `_cleanup_document` 的 Dart 移植，agent.py:732-762）：
/// 保留 entry，删除 `__seed` 与 nodes<=1 的板；删前复核板数>1（永不删到最后
/// 一块），删除走 `session_apply_agent` 的 `delete-artboard <id>`（AgentGate
/// 同门分发——破坏性操作也不绕门）。
///
/// **PLAN 语义分歧（显式登记）**：server 的清扫在 plan 模式也执行（agent.py:650
/// 无 mode 守卫）；Dart 的 plan 模式按既有设计不给引擎面（runDartAgent 的
/// `bridge: request.mode == 'plan' ? null : bridge`），所以这里以
/// `bridge == null → return` 表达「只在非 plan 生效」——是刻意的守卫，不是漏写。
/// 清扫失败（桥缺失/门拒绝/异常）一律只跳过，绝不让已交付的 run 变 failed。
Future<void> _sweepIdleArtboards(_Ctx ctx) async {
  final write = ctx.bridge is EngineWriteBridge ? ctx.bridge as EngineWriteBridge : null;
  final bridge = ctx.bridge;
  if (write == null || bridge == null) return;
  try {
    final listed = await bridge.session(ctx.mbt, 'session_list_artboards');
    final data = _listOf(listed['data']);
    if (data.length <= 1) return;
    final entry = _frontmatterValue(ctx.mbt, 'entry');
    final targets = <String>[];
    for (final board in data) {
      if (board is! Map) continue;
      final bid = _s(board['id']);
      if (bid.isEmpty) continue;
      if (bid == entry && bid != _seedBoard) continue; // 交互根永不删
      if (bid == _seedBoard || _nodeCount(board) <= 1) targets.add(bid);
    }
    for (final bid in targets) {
      final current = await bridge.session(ctx.mbt, 'session_list_artboards');
      if (_listOf(current['data']).length <= 1) break;
      final env = await write.mutateSession(
          ctx.mbt, 'session_apply_agent', 'delete-artboard $bid');
      if (env['ok'] == true && env['mbt'] is String) {
        ctx.mbt = env['mbt'] as String;
        ctx.cleanup.add(bid);
      }
    }
  } catch (_) {
    // 清扫是收尾卫生：异常不上抛（server 同语义——只有成功信封才记账）。
  }
}

/// 收尾 RSI 视觉修复环（server agent.py:652-700 的 Dart 移植）：
/// 逐板 `session_critique`（只读）→ 任一原则 verdict=='poor' 时
/// `session_auto_fix` 定向修复，并把信封 canonical 回灌 ctx.mbt（复评必须看
/// 修复后的文档）；最多 2 轮。
///
/// **实参顺序是硬契约**：[EngineGateBridge.session] 的签名是
/// `session(mbt, name, [arg])`——板 id 必须在 arg 位。写成两参会把
/// 'session_critique' 当 canonical 发出去，引擎必报错，RSI 静默退化成 no-op。
/// 信封实形（server 真机探针）：`data.results = [{principle, score(1-5),
/// verdict(poor/good), observation, advice}]`；解析不出 results 时按「无目标」
/// 处理（break），绝不抛异常。PLAN 不给引擎面（见 `_sweepIdleArtboards` 的
/// 分歧登记）。
Future<void> _runRsiLoop(_Ctx ctx) async {
  final write = ctx.bridge is EngineWriteBridge ? ctx.bridge as EngineWriteBridge : null;
  final bridge = ctx.bridge;
  if (write == null || bridge == null) return;
  if (ctx.request.mode == 'plan') return;
  try {
    for (var rnd = 1; rnd <= 2; rnd++) {
      final listed = await bridge.session(ctx.mbt, 'session_list_artboards');
      // 目标：非 seed、非空板的板（与 server 过滤一致），值为 poor 项数。
      final targets = <String, int>{};
      for (final board in _listOf(listed['data'])) {
        if (board is! Map) continue;
        final bid = _s(board['id']);
        if (bid.isEmpty || bid == _seedBoard || _nodeCount(board) <= 0) continue;
        try {
          final critique = await bridge.session(ctx.mbt, 'session_critique', bid);
          final data = critique['data'];
          final results =
              (data is Map && data['results'] is List) ? data['results'] as List : const [];
          final poor = results.where((r) => r is Map && r['verdict'] == 'poor').length;
          if (poor > 0) targets[bid] = poor;
        } catch (_) {
          continue; // 单板检视失败跳过，不中断整轮
        }
      }
      if (targets.isEmpty) {
        if (rnd == 1) {
          ctx.emit({'type': 'note', 'label': '质量审查', 'detail': '全部屏幕通过原则评审（无 poor 项）'});
        }
        break;
      }
      ctx.emit({
        'type': 'review_round',
        'round': rnd,
        'detail': targets.entries.map((e) => '${e.key}:${e.value}项poor').join('、'),
      });
      for (final entry in targets.entries) {
        ctx.emit({
          'type': 'note',
          'label': '修复轮',
          'detail': '${entry.key} · ${entry.value} 项 poor → auto_fix',
        });
        try {
          final fixed = await write.mutateSession(ctx.mbt, 'session_auto_fix', entry.key);
          if (fixed['ok'] == true && fixed['mbt'] is String) {
            ctx.mbt = fixed['mbt'] as String;
          }
        } catch (_) {
          continue; // 单板修复失败跳过（服务端语义：只跳过该板）
        }
      }
      await Future<void>.delayed(Duration.zero);
    }
  } catch (_) {
    // 评审环是收尾增强：引擎不可达/信封异常不得把已交付的 run 变成 failed。
  }
}

// ============================================================
// 工具面（server/agent.py `_make_tools` 九工具对齐）
// ============================================================

Map<String, String> _strArgs(Object? input) =>
    (input as Map?)?.map((k, v) => MapEntry(k.toString(), v?.toString() ?? '')) ?? const {};

ToolSet _buildTools(_Ctx ctx) {
  final emit = ctx.emit;
  final tools = <String, Tool<dynamic, dynamic>>{};

  // ---- write_doc（server:406-429）----
  tools['write_doc'] = tool(
    description: "Write or replace the product PRD (kind='prd') or per-screen UI spec "
        "(kind='ui'). Full markdown, real copy. In PLAN mode write both.",
    inputSchema: Schema(
      jsonSchema: {
        'type': 'object',
        'properties': {
          'kind': {'type': 'string', 'enum': ['prd', 'ui']},
          'content': {'type': 'string', 'description': 'Full markdown document body'},
        },
        'required': ['kind', 'content'],
      },
      fromJson: (m) => m,
    ),
    execute: (input, _) async {
      final m = _strArgs(input);
      final kind = m['kind'] ?? '';
      final content = m['content'] ?? '';
      final sw = Stopwatch()..start();
      emit({'type': 'tool_start', 'tool': 'write_doc', 'args': {'kind': kind, 'chars': content.length}});
      Map<String, dynamic> out;
      if ((kind != 'prd' && kind != 'ui') || content.trim().isEmpty) {
        out = {'ok': false, 'error': 'doc_kind_must_be_prd_or_ui'};
      } else {
        ctx.docs[kind] = content;
        emit({'type': 'doc_written', 'kind': kind, 'chars': content.length, 'content': content});
        out = {'ok': true, 'kind': kind, 'chars': content.length};
      }
      emit({
        'type': 'tool_end',
        'tool': 'write_doc',
        'ok': out['ok'] != false,
        'ms': sw.elapsedMilliseconds,
        'preview': _preview(out),
        'error': out['error'],
      });
      return out;
    },
  );

  // ---- write_design_spec（server:431-456）----
  tools['write_design_spec'] = tool(
    description: 'Write the project design system (palette, typography, spacing, radius, '
        'rules). Coherent, accessible colors; no pure black backgrounds.',
    inputSchema: Schema(
      jsonSchema: {
        'type': 'object',
        'properties': {
          'palette': {'type': 'object'},
          'typography': {'type': 'object'},
          'spacing': {'type': 'array', 'items': {'type': 'number'}},
          'radius': {'type': 'object'},
          'rules': {'type': 'array', 'items': {'type': 'string'}},
          'notes': {'type': 'string'},
        },
        'required': ['palette', 'typography', 'spacing', 'radius'],
      },
      fromJson: (m) => m,
    ),
    execute: (input, _) async {
      final raw = (input as Map?) ?? const {};
      final spec = normalizeDesignMap(<String, dynamic>{
        'palette': raw['palette'] is Map ? Map<String, dynamic>.from(raw['palette'] as Map) : <String, dynamic>{},
        'typography': raw['typography'] is Map ? Map<String, dynamic>.from(raw['typography'] as Map) : <String, dynamic>{},
        'spacing': raw['spacing'] is List ? List<dynamic>.from(raw['spacing'] as List) : <dynamic>[],
        'radius': raw['radius'] is Map ? Map<String, dynamic>.from(raw['radius'] as Map) : <String, dynamic>{},
        'rules': raw['rules'] is List ? List<dynamic>.from(raw['rules'] as List) : <dynamic>[],
        'notes': (raw['notes'] ?? '').toString(),
      });
      ctx.designSpec = designForAgent(spec);
      ctx.docs['design'] = spec;
      emit({'type': 'design_spec_written', 'spec': spec});
      return {
        'ok': true,
        'palette': (spec['palette'] as Map).length,
        'rules': (spec['rules'] as List).length,
      };
    },
  );

  // ---- finish（server:458-467）----
  tools['finish'] = tool(
    description: 'End the task. The summary is shown to the user; include what was built '
        'and what to click first.',
    inputSchema: Schema(
      jsonSchema: {
        'type': 'object',
        'properties': {
          'summary': {'type': 'string'},
          'stop_reason': {'type': 'string'},
        },
        'required': ['summary'],
      },
      fromJson: (m) => m,
    ),
    execute: (input, _) async {
      final m = _strArgs(input);
      ctx.finished = true;
      ctx.summary = m['summary'] ?? '';
      ctx.stopReason = (m['stop_reason']?.isEmpty ?? true) ? 'done' : m['stop_reason']!;
      emit({'type': 'assistant_text', 'text': ctx.summary, 'final': true});
      return {'ok': true};
    },
  );

  // ---- read_docs（server:397-404，全模式）----
  tools['read_docs'] = tool(
    description: 'Read the full PRD or UI spec stored with this project.',
    inputSchema: Schema(
      jsonSchema: {
        'type': 'object',
        'properties': {
          'kind': {'type': 'string', 'description': "prd | ui | design"},
        },
        'required': ['kind'],
      },
      fromJson: (m) => m,
    ),
    execute: (input, _) async {
      final kind = _strArgs(input)['kind'] ?? '';
      final text = ctx.docs[kind];
      if (text is! String || text.isEmpty) {
        return {'ok': false, 'error': 'no_${kind}_doc'};
      }
      return {
        'ok': true,
        'kind': kind,
        'content': text.length > 12000 ? '${text.substring(0, 12000)}\n…[truncated]' : text,
      };
    },
  );

  // ---- 以下为非 plan 模式工具（server:270-395 同构：plan 不暴露引擎面）----
  if (ctx.request.mode != 'plan') {
    // ---- generate_page（server:272-312；整屏生成 = 默认建屏路径）----
    tools['generate_page'] = tool(
      description: 'Generate a whole screen from an intent. This is the default build path: '
          'the engine picks a template, applies the design spec, self-repairs and scores. '
          'Pass the project design spec on every call.',
      inputSchema: Schema(
        jsonSchema: {
          'type': 'object',
          'properties': {
            'intent': {'type': 'string'},
            'name': {'type': 'string'},
            'spec': {'type': 'object'},
          },
          'required': ['intent'],
        },
        fromJson: (m) => m,
      ),
      execute: (input, _) async {
        final raw = (input as Map?) ?? const {};
        final intent = (raw['intent'] ?? '').toString();
        final name = (raw['name'] ?? '').toString();
        final spec = raw['spec'] is Map
            ? Map<String, dynamic>.from(raw['spec'] as Map)
            : <String, dynamic>{};
        final sw = Stopwatch()..start();
        emit({
          'type': 'tool_start',
          'tool': 'generate_page',
          'args': {'intent': intent, 'name': name},
        });
        ctx.remoteCalls += 1;
        // spec 缺省取项目设计规范（server `spec or ctx.design_spec or {}`）。
        final effective = spec.isNotEmpty ? spec : ctx.designSpec;
        final write =
            ctx.bridge is EngineWriteBridge ? ctx.bridge as EngineWriteBridge : null;
        Map<String, dynamic> out;
        if (write == null) {
          out = {'ok': false, 'error': 'generate_unavailable'};
        } else {
          try {
            // 参数顺序即契约：generate(mbt, intent, name, spec)——mbt 第一位。
            final env = await write.generate(ctx.mbt, intent, name, effective);
            out = await ctx.commit('generate $intent', env);
          } catch (e) {
            out = {'ok': false, 'error': 'engine_generate_failed:$e'};
          }
        }
        emit({
          'type': 'tool_end',
          'tool': 'generate_page',
          'ok': out['ok'] != false,
          'ms': sw.elapsedMilliseconds,
          'preview': _preview(out),
          'error': out['error'],
        });
        if (out['ok'] != false) {
          emit({
            'type': 'page_generated',
            'artboard': out['artboard'],
            'template': out['template'],
            'score': out['score'],
            'summary': out['summary'],
          });
        }
        return out;
      },
    );

    // ---- design_op（server:314-340；写路径唯一入口 = 引擎 AgentGate）----
    tools['design_op'] = tool(
      description: 'Run ONE mutating MoonViz op (place/update/move/flow/delete/reorder/'
          'interact/theme/token/fix…). The engine AgentGate validates it. Use this for '
          'refinements and flow wiring; do not hand-place whole screens.',
      inputSchema: Schema(
        jsonSchema: {
          'type': 'object',
          'properties': {
            'op': {'type': 'string', 'description': 'One MoonViz op expression'},
          },
          'required': ['op'],
        },
        fromJson: (m) => m,
      ),
      execute: (input, _) async {
        final op = _strArgs(input)['op'] ?? '';
        final sw = Stopwatch()..start();
        emit({'type': 'tool_start', 'tool': 'design_op', 'args': {'op': op}});
        ctx.remoteCalls += 1;
        Map<String, dynamic> out;
        final bridge = ctx.bridge;
        if (bridge == null) {
          out = {'ok': false, 'error': 'engine_unavailable'};
        } else {
          try {
            final env = await bridge.applyAgent(ctx.mbt, op); // AgentGate——唯一写路径
            out = await ctx.commit(op, env);
          } catch (e) {
            out = {'ok': false, 'error': 'engine_gate_failed:$e'};
          }
        }
        emit({
          'type': 'tool_end',
          'tool': 'design_op',
          'ok': out['ok'] != false,
          'ms': sw.elapsedMilliseconds,
          'preview': _preview(out),
          'error': out['error'],
        });
        return out;
      },
    );

    // ---- read_mbt（server:342-354；outline 走引擎，单板源码段纯文本本地切）----
    tools['read_mbt'] = tool(
      description: 'Read the document. No args returns a compact outline (boards, node ids, '
          'flows). With artboard, returns that board\'s source block for exact values.',
      inputSchema: Schema(
        jsonSchema: {
          'type': 'object',
          'properties': {
            'artboard': {'type': 'string'},
          },
        },
        fromJson: (m) => m,
      ),
      execute: (input, _) async {
        final artboard = _strArgs(input)['artboard'] ?? '';
        if (artboard.isEmpty) {
          final bridge = ctx.bridge;
          if (bridge == null) return {'ok': false, 'error': 'engine_unavailable'};
          try {
            return {'ok': true, 'outline': await composeProjectMap(bridge, ctx.mbt)};
          } catch (e) {
            return {'ok': false, 'error': 'engine_session_failed:$e'};
          }
        }
        final section = artboardSection(ctx.mbt, artboard);
        if (section == null) return {'ok': false, 'error': 'unknown_artboard:$artboard'};
        return {'ok': true, 'artboard': artboard, 'source': section};
      },
    );

    // ---- inspect（server:356-384；只读 session 面，不进 apply 分发器）----
    const inspectMapping = <String, String>{
      'query_nodes': 'session_query_nodes',
      'interactions': 'session_interactions',
      'states': 'session_states',
      'lint': 'session_lint',
      'critique': 'session_critique',
      'spec': 'session_spec',
      'export_svg': 'session_export_svg',
      'flows': 'session_flows',
      'artboards': 'session_list_artboards',
    };
    tools['inspect'] = tool(
      description: 'Read-only engine inspection: query_nodes, interactions, states, lint, '
          'critique, spec, export_svg, flows, artboards. Use critique/lint to verify.',
      inputSchema: Schema(
        jsonSchema: {
          'type': 'object',
          'properties': {
            'kind': {'type': 'string', 'enum': inspectMapping.keys.toList()},
            'artboard': {'type': 'string'},
          },
          'required': ['kind'],
        },
        fromJson: (m) => m,
      ),
      execute: (input, _) async {
        final m = _strArgs(input);
        final kind = m['kind'] ?? '';
        final artboard = m['artboard'] ?? '';
        final fn = inspectMapping[kind];
        if (fn == null) return {'ok': false, 'error': 'unknown_inspect_kind:$kind'};
        const needsBoard = {
          'query_nodes', 'interactions', 'states', 'lint', 'critique', 'spec', 'export_svg',
        };
        if (needsBoard.contains(kind) && artboard.isEmpty) {
          return {'ok': false, 'error': 'artboard_required'};
        }
        final bridge = ctx.bridge;
        if (bridge == null) return {'ok': false, 'error': 'engine_unavailable'};
        try {
          final env = Map<String, dynamic>.from(
              await bridge.session(ctx.mbt, fn, artboard.isEmpty ? null : artboard));
          if (kind == 'export_svg') {
            final data = env['data'];
            final svg = data is Map ? data['svg'] : null;
            if (svg is String) {
              env['data'] = {'ok': true, 'chars': svg.length, 'preview': svg.substring(0, svg.length < 1200 ? svg.length : 1200)};
            }
          }
          env['state'] = await stateSummary(bridge, ctx.mbt, parseRevision(ctx.mbt));
          return env;
        } catch (e) {
          return {'ok': false, 'error': 'engine_session_failed:$e'};
        }
      },
    );

    // ---- list_templates / list_components（server:386-395）----
    tools['list_templates'] = tool(
      description: 'List engine page templates (id, name, description, device).',
      inputSchema: Schema(jsonSchema: {'type': 'object', 'properties': {}}, fromJson: (m) => m),
      execute: (_, _) async {
        final bridge = ctx.bridge;
        if (bridge == null) return {'ok': false, 'error': 'engine_unavailable'};
        try {
          return {'ok': true, 'templates': await bridge.templates()};
        } catch (e) {
          return {'ok': false, 'error': 'engine_unavailable:$e'};
        }
      },
    );
    tools['list_components'] = tool(
      description: 'List engine components with categories and descriptions.',
      inputSchema: Schema(jsonSchema: {'type': 'object', 'properties': {}}, fromJson: (m) => m),
      execute: (_, _) async {
        final bridge = ctx.bridge;
        if (bridge == null) return {'ok': false, 'error': 'engine_unavailable'};
        try {
          return {'ok': true, 'components': await bridge.components()};
        } catch (e) {
          return {'ok': false, 'error': 'engine_unavailable:$e'};
        }
      },
    );
  }

  return tools;
}
