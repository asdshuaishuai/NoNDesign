/// NaN 内置 Dart Agent 循环（三模式）——迁移前参考实现的 Dart 泛化，
/// 现在**全部工具走本地服务**：引擎在进程内（[LocalEngineGate] → 批次 02 的
/// `EngineService`），3D / 热应用 / 视频 / 应用包 / Figma 导出由
/// [AgentWorkspaceServices] 接到批次 06/07/08 的本地工作台。没有 HTTP 路由、
/// 没有固定端口、没有 Python。
///
/// 语义参照（迁移前的权威实现，行为已逐条移植并对账）：
/// - 旧参考实现 — 工具语义 / 三模式 / doc_not_written / nudge 轮；
/// - 旧参考实现 — 三套静态提示词 + footer；
/// - 旧参考实现 — normalize_design / artboard_section / 项目地图 / state 卡。
///
/// 三模式：
/// - **PLAN** 真实现：PRD + UI 说明 + 设计规范（write_doc ×2 + write_design_spec），
///   纯文档、零引擎依赖（手机离线可跑）。
/// - **REFINE** 真实现：读现有文档（read_docs）+ 指令改写（write_doc）；有引擎
///   桥时 design_op 落画布（仍过 AgentGate）。
/// - **BUILD** 真实现：整屏生成用 generate_page（session_generate_in），精修与
///   连线用 design_op；生产默认桥是 [LocalEngineGate]（进程内直调，`gate:
///   'agent'`），store 锚定桥（`_StoreEngineGate`）保留同队列采纳语义。
///   收尾确定性桥段（P1，与迁移前参考实现同源）：空板清扫
///   （`_sweepIdleArtboards`）→ RSI critique/auto_fix 评审轮（`_runRsiLoop`，
///   最多 2 轮），全部经引擎门。
///
/// 护栏铁律：Dart 循环产出的画布变更必须过引擎 AgentGate，绝不绕过——本文件
/// 没有任何「直接拼 canonical 提交」的写路径；design_op 只透传 op 给引擎门并
/// 采纳回传的文档。
///
/// 用户可见文案（本批治理）：
/// - 工具名一律经 [toolLabel]（design_op → 设计变更、read_mbt → 读取设计稿、
///   three_* → 3D 场景 …）；未知工具回落「智能体操作」，绝不回显代码代号。
/// - 失败先取服务层的人类句子（`out['message']`），否则按错误码经
///   [toolFailureMessage] 映射；原始码/诊断只在 `error`/`detail` 里，供折叠的
///   「技术详情」使用。
///
/// 事件契约：与迁移前的 SSE 同形，`store._handleAgentEvent` 直接消费：
/// note / tool_start / tool_end / assistant_delta / assistant_text /
/// thinking_delta / doc_written / design_spec_written / page_generated /
/// review_round / cleanup / preview / usage / done / failed。
/// `tool_end` 新增 `message`（人话）与 `detail`（原始诊断）两个字段，`error`
/// 保留机器码以兼容历史消费者。
///
/// 与旧实现的已知差异（诚实登记，非静默降级）：
/// - 无逐字 doc_delta 直播——SDK 的工具参数增量是原始 JSON 分片；doc_written
///   全量事件是正确性兜底。
/// - 无 CompactingSession 持久会话记忆（P2 上下文层）。
/// - **空板清扫/RSI 的 PLAN 语义分歧（显式登记）**：旧实现里清扫在 plan 模式
///   也执行；Dart 的 plan 模式按既有设计不给引擎面（runDartAgent 里
///   `bridge: request.mode == 'plan' ? null : bridge`），故清扫与 RSI 只在非
///   plan 生效——实现用 `bridge == null → return` 表达，测试锚定 plan 零
///   session 调用。
/// - 工作区工具只在宿主注入 [AgentWorkspaceServices] 时暴露；手机或不支持
///   的宿主看不到入口（能力判据由宿主决定，不在循环里猜）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:ai_sdk_dart/ai_sdk_dart.dart';
import 'package:ai_sdk_openai/ai_sdk_openai.dart';

import 'agent_model_middleware.dart';
import 'api.dart';
import 'figma_export.dart';
import 'hotapp_service.dart';
import 'models.dart';
import 'nonapp_library.dart';
import 'three_service.dart';
import 'video_project.dart';
import 'video_samples.dart';
import 'video_service.dart';

// ============================================================
// thinking 方言表（权威：迁移前参考实现的 reasoning 处理）
// ============================================================

/// reasoning effort 白名单（逐字对照迁移前实现）。
const Set<String> _reasoningEffortLevels = <String>{
  'none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max',
};

/// thinking 等级 → OpenAI Chat Completions `reasoning_effort` 注入值。
///
/// 权威语义（迁移前参考实现逐字移植，不做 trim / 不做大小写归一）：
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

/// 线上方言裁决：MiniMax「自适应思考」模型（M3.x）强制开启思考，
/// `thinking.type=disabled`/`reasoning.effort=none` 会被 400 拒绝
/// （"requires adaptive thinking"）。实测同一请求单轮耗时：
/// auto ≈ 60–163 s、low ≈ 19.5 s、medium ≈ 34 s、high ≈ 103 s——
/// auto 的默认思考预算把每一轮都拖到分钟级，一轮 run 十几轮直接爆表。
/// 因此 `auto`/`off`/`none`/`minimal`/空 一律落线为 `low`；显式档位
/// （low/medium/high/xhigh/max）原样透传，尊重用户选择。
Map<String, Map<String, dynamic>>? providerThinkingOptions(DartAgentRequest request) {
  final base = request.baseUrl.toLowerCase();
  final model = request.model.toLowerCase();
  // StepFun step_plan 实测（2026-11-20）：auto 70s/轮、medium 33s/轮、
  // low 47s、minimal 58s。auto 同样吃满思考预算，落线 medium。
  final stepFun = base.contains('stepfun') || model.startsWith('step-');
  if (stepFun) {
    final level = request.thinkingLevel.trim();
    const neutral = <String>{'', 'auto', 'off', 'none'};
    final effort = neutral.contains(level)
        ? 'medium'
        : (level == 'minimal' ? 'medium' : level);
    final safe = _reasoningEffortLevels.contains(effort) ? effort : 'medium';
    return <String, Map<String, dynamic>>{
      'openai': <String, dynamic>{'reasoning_effort': safe},
    };
  }
  final miniMax = base.contains('minimax') || model.startsWith('minimax');
  if (!miniMax) return thinkingProviderOptions(request.thinkingLevel);
  final level = request.thinkingLevel.trim();
  const light = <String>{'', 'auto', 'off', 'none', 'minimal'};
  final effort = light.contains(level) ? 'low' : level;
  final safe = _reasoningEffortLevels.contains(effort) ? effort : 'low';
  return <String, Map<String, dynamic>>{
    'openai': <String, dynamic>{'reasoning_effort': safe},
  };
}

// ============================================================
// LLM 错误分类与自动重试（agent 自己的等待重试）
// ============================================================

/// 把 LLM 请求异常归成稳定错误码。
///
/// 有意的 dynamic 抽取（`AiApiCallError.statusCode`）：ai_sdk_provider 是
/// 传递依赖（未入 pubspec，见 runDartAgent 的同款注释），不 import 其类型。
/// 返回值：
/// - `llm_http_<status>`——服务端返回了非 2xx（含 401/429/5xx）；
/// - `llm_timeout`——请求超时（TimeoutException，含 SDK OperationScope 死线）；
/// - `llm_no_such_tool`——模型调了不存在的工具（StepFun 空名方言的兜底）；
/// - `llm_network`——连接层失败（dio / socket / TLS）；
/// - 其余原样返回（未知异常，交给通用文案）。
String classifyLlmError(Object e) {
  if (e is TimeoutException) return 'llm_timeout';
  try {
    final dynamic d = e;
    final status = d.statusCode;
    if (status is int && status >= 100) return 'llm_http_$status';
    // AiApiCallError 有时把状态码藏在 cause（DioException.response）里。
    final dynamic cause = d.cause;
    final dynamic inner = cause?.response?.statusCode;
    if (inner is int && inner >= 100) return 'llm_http_$inner';
  } catch (_) {
    // 不是带 statusCode 的类型，走字符串面分类。
  }
  final s = e.toString();
  if (s.startsWith('AiNoSuchToolError') || s.contains('unknown tool')) {
    return 'llm_no_such_tool';
  }
  const transportMarkers = <String>[
    'DioException', 'SocketException', 'HandshakeException',
    'ClientException', 'HttpException', 'Connection error',
    'Connection refused', 'Connection closed', 'Connection reset',
    'Connection was closed', 'Network is unreachable', 'Connection timed out',
    'Broken pipe', 'Stream has been aborted',
  ];
  for (final m in transportMarkers) {
    if (s.contains(m)) return 'llm_network';
  }
  return s;
}

/// 瞬时故障才值得等待重试：网络层失败、限流/网关类 HTTP 码、超时。
bool isRetryableLlmError(String code) {
  if (code == 'llm_timeout' || code == 'llm_network') return true;
  // 模型捏造工具名（拼错/近义变体）：重试一轮通常自愈。
  if (code == 'llm_no_such_tool') return true;
  if (code.startsWith('llm_http_')) {
    final status = int.tryParse(code.substring('llm_http_'.length));
    return status != null &&
        const <int>{408, 425, 429, 500, 502, 503, 504}.contains(status);
  }
  return false;
}

/// 重试策略（用户裁决 2026-11-20）：瞬时故障最多重试 10 次，每次等待
/// 30 秒，绝不第一下就判死——模型服务中途断连/限流是常态，硬失败会把
/// 已经做了大半的 run 整个作废。
const int llmRetryMaxRetries = 10;
const int llmRetryWaitSeconds = 30;

/// 测试注入：把 30 秒等待压到毫秒级（生产恒 null）。
@visibleForTesting
List<int>? debugRetryWaitsOverride;

int llmRetryWaitFor(int attempt) {
  final override = debugRetryWaitsOverride;
  if (override != null && override.isNotEmpty) {
    return override[attempt.clamp(0, override.length - 1)];
  }
  return llmRetryWaitSeconds;
}

/// 断线续跑的指令：告诉模型「上一步中断，从当前状态接着做」，不重复已完成。
String _continuationPrompt(String mode) => switch (mode) {
      'plan' => 'The previous reply was interrupted by a network error. The docs written '
          'so far are attached above. Continue: write only the missing docs '
          '(write_doc prd/ui, write_design_spec as needed), then finish.',
      'workspace' => 'The previous reply was interrupted by a network error. The workspace '
          'state so far is shown above. Continue the task from there: inspect current '
          'state first if unsure, then finish the remaining work and call finish.',
      _ => 'The previous reply was interrupted by a network error. The canvas already '
          'contains the progress shown above. Continue from there: do NOT redo existing '
          'screens; generate only the missing pages, wires and fixes, then call finish.',
    };

/// `llm_no_such_tool` 的重试轮提示：明确列出本轮可用的工具名。
///
/// 背景：模型把工具名拼错/捏造时 SDK 直接抛 `AiNoSuchToolError`，整轮
/// 重发同一条 prompt 往往还会再错一次。把可用工具清单带进 prompt，让模型
/// 从清单里挑正确名字——这是工具修复（self-heal）的提示词一侧。
String _noSuchToolRetryPrompt(String prompt, ToolSet tools) {
  final names = tools.keys.toList()..sort();
  return '$prompt\n\n[RETRY] Your previous reply called a tool that does not exist. '
      'Available tools: ${names.join(', ')}. '
      'Call EXACTLY one of them (spelling matters; do not invent names), then continue '
      'the task, or call finish with the result so far.';
}

/// 失败详情（只进折叠的「技术详情」）：provider 的 status/响应体/上游
/// 异常是排查线上方言的唯一线索——`AiApiCallError: openai API error`
/// 这种脱敏字符串对上 MiniMax 的 400 毫无信息量（2026-11-20 实测）。
String llmErrorDetail(Object e) {
  final base = e.toString();
  try {
    final dynamic d = e;
    final status = d.statusCode;
    final body = d.responseBody;
    final cause = d.cause;
    final bits = <String>[
      if (status != null) 'status=$status',
      if (body != null && '$body'.trim().isNotEmpty) 'body=${'$body'}',
      if (cause != null && '$cause'.trim().isNotEmpty) 'cause=$cause',
    ];
    if (bits.isEmpty) return base;
    return '$base | ${bits.join(' | ')}';
  } catch (_) {
    return base;
  }
}

/// 本轮交付水位：prd/ui 长度 + ops 数 + 引擎/工作区调用数。
///
/// 失败时水位前移说明这一轮已有工具/文档真实落地——自动重试会重复执行
/// 已生效的操作，这种情况绝不重试，直接浮出错误（配好人话文案）。
String _deliveryWatermark(_Ctx ctx) =>
    '${ctx.docs['prd']?.length ?? 0}|${ctx.docs['ui']?.length ?? 0}|'
    '${ctx.ops.length}|${ctx.remoteCalls}';

// ============================================================
// 引擎门桥（唯一写路径）
// ============================================================

/// 引擎访问面：Dart 循环的引擎桥。生产实现两枚：
/// - [LocalEngineGate]——**当前默认**：直接调批次 02 的进程内引擎宿主
///   （[LocalEngine]），design_op 走 `gate:'agent'`（AgentGate 语义）；
/// - store 锚定的 `_StoreEngineGate`（store.dart）——Build/Refine 的写路径
///   落 `AppStore.applyAgentOp`（applyOp 同一条 _opQueue 队列 + 同一个
///   _commit 采纳）。
///
/// 路由表：
/// - 变更（design_op 唯一去路）：[applyAgent] → AgentGate
///   （绝不绕过引擎门、绝不降级 human 门）。
/// - inspect：[session] → 只读 session_* 面
///   （query_nodes/interactions/states/lint/critique/spec/export_svg/flows/
///   artboards），不进 apply 分发器。
/// - read_mbt：无参 outline 经 [session]（list_artboards+flows+逐板
///   query_nodes 合成 PROJECT MAP）；带 artboard 为本地文本切
///   （artboard_section 同源，不花引擎往返）。
/// - list_templates / list_components：引擎注册表。
/// - read_docs：不经引擎——docs 在 run 请求载荷里，循环本地读。
abstract class EngineGateBridge {
  /// 变更 op → 引擎 AgentGate。信封 `{ok, mbt?, error?, …}`。
  Future<Map<String, dynamic>> applyAgent(String mbt, String op);

  /// 只读 session 检视（session_query_nodes / session_flows / …）。
  Future<Map<String, dynamic>> session(String mbt, String name, [String? arg]);

  Future<List<dynamic>> templates();
  Future<List<dynamic>> components();
}

/// 引擎渲染面（Figma 导出消费每板 `svg`）。独立于 [EngineGateBridge]：
/// 测试替身只实现门接口即可，新增成员不破坏 `implements` 编译面。
abstract class EngineRenderBridge {
  Future<Map<String, dynamic>> render(String mbt);
}

/// 引擎写面扩展（P1）：整屏生成 + 宿主侧 session 变更（RSI auto_fix /
/// 空板清扫）。**刻意独立于 [EngineGateBridge]**——测试替身只实现门接口
/// 即可（新增成员会破坏 `implements EngineGateBridge` 的编译面）。
///
/// 生产实现两枚，与门同构：
/// - [LocalEngineGate]：进程内直调（[LocalEngine]）；
/// - store 锚定的 `_StoreEngineGate`（store.dart）：同一 `_opQueue` 链内
///   读新鲜 canonical、render + commit——保证 store.mbt 与循环 ctx.mbt 锁步。
///
/// 写纪律不变：generate 是引擎 `session_generate_in` 域内生成，mutateSession
/// 只用于 `session_auto_fix` / `session_apply_agent`（SESSION_MUTATING 面）
/// ——本接口不是「直接拼 mbt」的捷径。
abstract class EngineWriteBridge {
  /// 整屏生成（`session_generate` 面）。
  /// 参数顺序即契约：mbt 第一位（canonical 文档面）。
  Future<Map<String, dynamic>> generate(
      String mbt, String intent, String name, Map<String, dynamic> spec);

  /// 宿主侧 session 变更；同样 mbt 第一位、name 第二位、arg 第三位。
  Future<Map<String, dynamic>> mutateSession(String mbt, String name, [String? arg]);
}

/// 本地引擎实现（批次 02 的 [LocalEngine]，**当前生产默认**）。
///
/// design_op 必须带 `gate: 'agent'`（AgentGate），只读检视走 session 面，
/// 整屏生成走 generate，宿主侧变更（auto_fix / 清扫）走 session。引擎没
/// 就绪时返回 `engine_unavailable` 信封——绝不静默降级、绝不假装成功。
class LocalEngineGate implements EngineGateBridge, EngineWriteBridge, EngineRenderBridge {
  LocalEngineGate(this.engine);

  final LocalEngine engine;

  static Map<String, dynamic> get _missing =>
      <String, dynamic>{'ok': false, 'error': 'engine_unavailable'};

  bool get _ready => engine.isReady;

  @override
  Future<Map<String, dynamic>> applyAgent(String mbt, String op) =>
      _ready ? engine.apply(mbt, op, gate: 'agent') : Future.value(_missing);

  @override
  Future<Map<String, dynamic>> session(String mbt, String name, [String? arg]) =>
      _ready ? engine.session(mbt, name, arg) : Future.value(_missing);

  @override
  Future<Map<String, dynamic>> generate(
          String mbt, String intent, String name, Map<String, dynamic> spec) =>
      _ready ? engine.generate(mbt, intent, name, spec) : Future.value(_missing);

  @override
  Future<Map<String, dynamic>> mutateSession(String mbt, String name, [String? arg]) =>
      _ready ? engine.session(mbt, name, arg) : Future.value(_missing);

  @override
  Future<Map<String, dynamic>> render(String mbt) =>
      _ready ? engine.render(mbt) : Future.value(_missing);

  @override
  Future<List<dynamic>> templates() async => _ready ? engine.templates() : const <dynamic>[];

  @override
  Future<List<dynamic>> components() async => _ready ? engine.components() : const <dynamic>[];
}

// ============================================================
// 工具名与失败文案（用户可见层：绝不出现内部代号）
// ============================================================

/// 工具名 → 用户可见标签。
///
/// 术语表（docs/copy-glossary.md）：`design_op` → 设计变更、`read_mbt` →
/// 读取设计稿、`inspect` → 检查、`generate_page` → 生成页面、`write_doc` →
/// 撰写文档、`write_design_spec` → 更新设计规范、`three_*` → 3D 场景、
/// `hotapp_*` → 热应用、`video_*` → 视频、`nonapp_*` → 应用包。
///
/// 未知工具一律回落「智能体操作」——**绝不把原始工具名（snake_case 代码
/// 代号）回显给用户**。
String toolLabel(String tool) {
  switch (tool) {
    case 'ask_user':
      return '向你确认';
    case 'design_op':
      return '设计变更';
    case 'read_mbt':
      return '读取设计稿';
    case 'inspect':
      return '检查';
    case 'generate_page':
      return '生成页面';
    case 'write_doc':
      return '撰写文档';
    case 'write_design_spec':
      return '更新设计规范';
    case 'read_docs':
      return '读取文档';
    case 'list_templates':
      return '查看模板';
    case 'list_components':
      return '查看组件';
    case 'finish':
      return '完成';
    case 'figma_export':
      return '导出 Figma 包';
    case 'three_list':
      return '3D 场景';
    case 'three_create':
      return '3D 场景 · 新建';
    case 'three_status':
      return '3D 场景 · 查看';
    case 'three_pass':
      return '3D 场景 · 生成';
    case 'three_continue':
      return '3D 场景 · 推进';
    case 'three_feedback':
      return '3D 场景 · 反馈';
    case 'hotapp_list':
      return '热应用';
    case 'hotapp_generate':
      return '热应用 · 生成';
    case 'hotapp_refine':
      return '热应用 · 精修';
    case 'hotapp_inspect':
      return '热应用 · 查看';
    case 'hotapp_from_prototype':
      return '热应用 · 由原型生成';
    case 'video_create':
      return '视频 · 新建';
    case 'video_list':
      return '视频';
    case 'video_sample':
      return '视频 · 示例';
    case 'video_review':
      return '视频 · 对照检查';
    case 'video_render':
      return '视频 · 渲染';
    case 'nonapp_list':
      return '应用包';
    case 'nonapp_inspect':
      return '应用包 · 查看';
  }
  if (tool.startsWith('three_')) return '3D 场景';
  if (tool.startsWith('hotapp_')) return '热应用';
  if (tool.startsWith('video_')) return '视频';
  if (tool.startsWith('nonapp_')) return '应用包';
  return '智能体操作';
}

/// 运行阶段 → 用户可见标签（`plan`/`build`/`refine` 是内部代号）。
String _modeLabel(String mode) => switch (mode) {
      'plan' => '梳理需求',
      'refine' => '调整设计',
      'workspace' => '执行任务',
      _ => '生成原型',
    };

/// 失败码 → 用户可见的一句话。
///
/// 映射表（docs/copy-glossary.md §4）：
/// `engine_unavailable` → 设计服务暂时不可用，请稍后重试；
/// `mbt_gate_block` → 这次改动未通过设计校验；
/// `render_failed` → 预览生成失败；`download_failed` → 模型下载失败；
/// `sha256_mismatch` → 模型文件校验失败，已删除，请重试；
/// `nonapp_unsupported_version` → 应用版本过新，请更新本应用；
/// `llm_http_<status>` → 按 401/403、404、429、5xx 分档；
/// `llm_timeout` / `llm_network` / `llm_no_such_tool` → 各自的人话。
///
/// 复合错误（`engine_generate_failed:…`）只取冒号前的基码；未知码回落
/// 「这次操作没有成功，请重试」——原始码只进折叠的技术详情。
String toolFailureMessage(String? rawError) {
  final code = normalizedErrorCode(rawError);
  if (code.startsWith('llm_http_')) {
    final status = int.tryParse(code.substring('llm_http_'.length));
    if (status == 401 || status == 403) return '模型服务认证失败，请检查 API Key';
    if (status == 404) return '模型或服务地址不存在，请检查模型设置';
    if (status == 429) return '模型服务正忙，请稍等片刻再试';
    if (status == 402) return '模型服务额度不足，请充值或换一个模型';
    if (status != null && status >= 500) return '模型服务暂时不可用，请稍后重试';
    return '模型这次没有响应，请稍后重试';
  }
  switch (code) {
    case 'engine_unavailable':
      return '设计服务暂时不可用，请稍后重试';
    case 'engine_timeout':
      return '这次操作耗时过长，已安全停止';
    case 'engine_trap':
      return '设计服务刚刚重启，请重试';
    case 'engine_fuel_exhausted':
      return '这次操作太大，已安全停止，可以拆小再试';
    case 'engine_session_failed':
    case 'engine_session_open_failed':
      return '检查没有完成，请重试';
    case 'engine_generate_failed':
    case 'generate_unavailable':
      return '页面生成没有完成，请重试';
    case 'canvas_empty':
      return '画布还是空的：先用 generate_page 生成第一屏，再做设计操作';
    case 'unknown_component':
      return '这个组件名不存在：先用 list_components 查合法组件名';
    case 'unknown_variant':
      return '这个变体名不存在：换该组件的合法变体，或把变体槽写成 -';
    case 'place_invalid_arg':
      return 'place 参数不对：place <板> <组件> <id> [变体|-] [x] [y] [w] [h]';
    case 'place_unknown_key':
      return 'place 的 k=v 键不在编辑词表里（text/fill/stroke/radius/opacity/motion…）';
    case 'id_exists':
      return '这个 id 已经存在：换一个新 id';
    case 'mixed_parents':
      return '一次操作混用了不同父节点：拆成多次，每次同一父节点';
    case 'generate_multi_too_many':
      return '一次生成的画板数超限：拆成多次 generate_page';
    case 'mbt_operation_unknown_key':
      return 'op 里的键不在词表里：对照检查规范的键名';
    case 'not_renderable_visual_logic':
      return '文档里有渲染不了的过程式逻辑：改用声明式节点语法';
    case 'engine_gate_failed':
    case 'mbt_gate_block':
      return '这次改动未通过设计校验';
    case 'render_failed':
      return '预览生成失败';
    case 'download_failed':
      return '模型下载失败';
    case 'sha256_mismatch':
      return '模型文件校验失败，已删除，请重试';
    case 'nonapp_unsupported_version':
      return '应用版本过新，请更新本应用';
    case 'prototype_empty':
      return '画布上还没有原型，先生成原型再转热应用';
    case 'doc_kind_must_be_prd_or_ui':
      return '文档类型不对，请重试';
    case 'doc_not_written':
      return '这次没有生成文档，请重试';
    case 'no_prd_doc':
    case 'no_ui_doc':
    case 'no_design_doc':
      return '还没有这份文档';
    case 'unknown_artboard':
    case 'artboard_required':
    case 'unknown_inspect_kind':
      return '找不到这个画板，请重试';
    case 'invalid_args':
      return '参数格式不对，请重试';
    case 'llm_error':
      return '模型这次没有响应，请稍后重试';
    case 'llm_timeout':
      return '这次操作耗时过长，已安全停止';
    case 'llm_network':
      return '连不上模型服务，请检查网络后重试';
    case 'llm_no_such_tool':
      return '模型调用了一个不可用的操作，请重试';
    case 'three_unavailable':
      return '3D 场景需要先连接桌面';
    case 'three_failed':
      return '3D 场景这次没有完成，请重试';
    case 'hotapp_unavailable':
      return '热应用需要先连接桌面';
    case 'hotapp_failed':
      return '热应用这次没有完成，请重试';
    case 'video_unavailable':
      return '视频工作区需要先连接桌面';
    case 'video_failed':
      return '视频这次没有完成，请重试';
    // 视频生成落盘（video_create）的稳定失败码：每一码都有一句可执行的人话
    // （docs/copy-glossary.md：不出现裸代号；原始诊断只进技术详情）。
    case 'video_invalid_name':
      return '视频名只能用字母、数字、下划线和连字符';
    case 'video_project_exists':
      return '已经有同名视频了，换一个名字再新建（已生成的视频不会被覆盖）';
    case 'video_no_project':
      return '没有找到这个视频项目';
    case 'video_spec_missing':
      return '这份脚本还缺一份说明规范，先补齐规范再新建';
    case 'video_spec_invalid':
      return '说明规范不完整，请按模板补齐后再试';
    case 'video_timeline_invalid':
      return '脚本格式不对，请检查括号、引号与逗号';
    case 'video_no_scenes':
      return '脚本里还没有任何场景';
    case 'video_no_frames':
      return '所有场景的时长都是 0，算不出画面';
    case 'video_io_error':
      return '视频项目没有保存成功，请检查磁盘空间后重试';
    case 'video_sample_missing':
      return '内置示例没能加载，请重新安装应用';
    case 'video_render_unavailable':
      return '视频导出只在电脑上可用';
    case 'video_export_disabled':
      // 视频模块是代码动画（用户裁决 2026-11-18）：不落 mp4。
      return '视频现在是代码动画，直接在工作台里播放；暂不导出成片';
    case 'nonapp_unavailable':
      return '应用包暂时不可用';
    case 'figma_unavailable':
      return '导出 Figma 包需要先打开一个设计稿';
    case 'figma_mobile_unavailable':
      return figmaFailureMessage('figma_mobile_unavailable');
    case 'figma_nothing_to_export':
      return figmaFailureMessage('figma_nothing_to_export');
    case 'figma_write_failed':
      return figmaFailureMessage('figma_write_failed');
    case 'figma_directory_required':
      return '先选一个导出位置再试';
    case 'ask_user_invalid':
      return '选项没有准备好，请重试';
    case 'ask_user_unavailable':
      // 旧「钉死工作台拒答」的码（2026-11-20 用户裁决变更后不再产生）。
      // 历史事件可能仍带它：映射人话，绝不回显裸代号。
      return '可以继续问：这个工作台里的内容决策不受限制';
    case 'acp_desktop_only':
      return '外部智能体只在电脑上可用';
    default:
      // 工作台服务的细分失败码统一带模块前缀（`three_invalid_name` /
      // `hotapp_name_taken` / `video_expr_syntax_error` …）：按模块自己的
      // 人话表映射，避免每加一个码就漏一句文案。
      if (code.startsWith('video_')) return videoFailureMessage(code.substring(6));
      if (code.startsWith('three_')) return threeFailureMessage(ThreeFailure(code.substring(6)));
      if (code.startsWith('hotapp_')) return hotAppFailureMessage(HotAppFailure(code.substring(7)));
      if (code.startsWith('nonapp_')) return '应用包这次没有完成，请重试';
      return '这次操作没有成功，请重试';
  }
}

/// 取复合错误码的基码：`engine_generate_failed: timeout` → `engine_generate_failed`。
String normalizedErrorCode(String? rawError) {
  final raw = (rawError ?? '').trim();
  if (raw.isEmpty) return '';
  final cut = raw.indexOf(RegExp(r'[:：\s]'));
  return cut < 0 ? raw : raw.substring(0, cut);
}

// ============================================================
// 本地工作区服务（3D / 热应用 / 视频 / 应用包 / Figma）
// ============================================================

/// Agent 可用的本地工作区服务契约。
///
/// 本批只做**接线**：3D 场景由批次 06、热应用由 07、视频由 08 提供实现；
/// 这里的 [LocalWorkspaceServices] 把它们的公开 API 适配成统一信封。
///
/// 约定：
///  * 每个方法返回引擎同构信封 `{ok, error?, message?, detail?, …}`；
///  * `error` 是机器码（只进技术详情），`message` 是用户可见的一句话；
///  * 能力不可用（手机上没装渲染器、没有本地库）→ `{ok:false, error:
///    …_unavailable, message: …}`，绝不 "点了没反应"。
abstract class AgentWorkspaceServices {
  // -- 3D 场景（批次 06） --
  Future<Map<String, dynamic>> threeList();
  Future<Map<String, dynamic>> threeCreate({required String name, required String brief});
  Future<Map<String, dynamic>> threeStatus(String name);
  Future<Map<String, dynamic>> threePass(String name);
  Future<Map<String, dynamic>> threeContinue(String name, [String summary]);
  Future<Map<String, dynamic>> threeFeedback({
    required String name,
    required String kind,
    required Object? payload,
  });

  // -- 热应用（批次 07） --
  Future<Map<String, dynamic>> hotAppList();
  Future<Map<String, dynamic>> hotAppGenerate({required String name, required String brief});
  Future<Map<String, dynamic>> hotAppRefine({required String name, required String instruction});
  Future<Map<String, dynamic>> hotAppInspect(String name);

  /// 设计 → 热应用（唯一允许的模块间关联）：由原型生成**可验证**的热应用。
  /// 屏与跳转由调用方从原型提取；生成后跑确定性覆盖验证（每屏 data-screen、
  /// 每条连线 data-nav），结果如实带 verified / 未通过项。
  Future<Map<String, dynamic>> hotAppFromPrototype({
    required String name,
    required String prototypeMbt,
    required List<PrototypeScreenSpec> screens,
    required List<PrototypeLinkSpec> flows,
  });

  // -- 视频（批次 08；渲染只在桌面） --
  Future<Map<String, dynamic>> videoReview({
    required Map<String, dynamic> timeline,
    Map<String, dynamic>? spec,
  });
  Future<Map<String, dynamic>> videoRender({
    required Map<String, dynamic> timeline,
    Map<String, dynamic>? spec,
  });

  /// 视频是**代码动画**（用户裁决 2026-11-18）：时间线脚本 + 规范预校验后
  /// 落盘成工作台项目（[VideoProjectStore]），逐帧现算、在工作台里实时播放；
  /// 不落 mp4。这三个方法就是「生成有落地」的接口面：
  ///  * [videoSample] —— 内置示例的完整 timeline + spec JSON（模型学格式的
  ///    唯一途径）；
  ///  * [videoList] —— 生成项目 + 内置示例清单（先看现状再决定新建/改写）；
  ///  * [videoCreate] —— 先过 [VideoDocument.build] 预校验再写盘，失败不留
  ///    半成品目录，返回片长/帧数。
  Future<Map<String, dynamic>> videoCreate({
    required String name,
    required Map<String, dynamic> timeline,
    Map<String, dynamic>? spec,
    String title = '',
  });
  Future<Map<String, dynamic>> videoList();
  Future<Map<String, dynamic>> videoSample({int index = 0});

  // -- 应用包（批次 07） --
  Future<Map<String, dynamic>> nonAppList();
  Future<Map<String, dynamic>> nonAppInspect(String name);

  // -- Figma 导出（本批） --
  Future<Map<String, dynamic>> figmaExport({
    required RenderEnvelope render,
    required String directory,
  });
}

/// 生产适配：把三个本地工作台 + 应用库 + Figma 导出器接进 Agent。
///
/// 模型连接参数随 run 请求传入（3D/热应用的生成走当前选中的模型）。
/// 工厂可注入（测试不落用户文档目录、不打网络）。
class LocalWorkspaceServices implements AgentWorkspaceServices {
  LocalWorkspaceServices({
    required this.model,
    required this.baseUrl,
    required this.apiKey,
    this.thinkingLevel = 'auto',
    Future<ThreeService> Function()? threeFactory,
    Future<HotAppService> Function()? hotAppFactory,
    Future<NonAppLibrary> Function()? nonAppFactory,
    VideoService? video,
    VideoProjectStore? videoProjects,
    FigmaExporter? figma,
  })  : _threeFactory = threeFactory ?? (() => ThreeService.open()),
        _hotAppFactory = hotAppFactory ?? (() => HotAppService.open()),
        _nonAppFactory = nonAppFactory ?? (() => NonAppLibrary.open()),
        _video = video ?? VideoService.instance,
        _videoProjects = videoProjects ?? VideoProjectStore.instance,
        _figma = figma ?? FigmaExporter();

  final String model;
  final String baseUrl;
  final String apiKey;
  final String thinkingLevel;

  final Future<ThreeService> Function() _threeFactory;
  final Future<HotAppService> Function() _hotAppFactory;
  final Future<NonAppLibrary> Function() _nonAppFactory;
  final VideoService _video;

  /// 视频生成项目的本地库（工作台与工具共用同一存储；测试注入临时根）。
  final VideoProjectStore _videoProjects;

  final FigmaExporter _figma;

  ThreeLlmConfig get _threeConfig => ThreeLlmConfig(
        model: model,
        baseUrl: baseUrl,
        apiKey: apiKey,
        thinkingLevel: thinkingLevel,
      );

  HotAppLlmConfig get _hotAppConfig => HotAppLlmConfig(
        model: model,
        baseUrl: baseUrl,
        apiKey: apiKey,
        thinkingLevel: thinkingLevel,
      );

  static Map<String, dynamic> _failure(String code, String message, [String? detail]) =>
      <String, dynamic>{
        'ok': false,
        'error': code,
        'message': message,
        if (detail != null && detail.isNotEmpty) 'detail': detail,
      };

  // -- 3D -------------------------------------------------------------------

  @override
  Future<Map<String, dynamic>> threeList() async {
    try {
      final service = await _threeFactory();
      final projects = await service.listProjects();
      return <String, dynamic>{
        'ok': true,
        'scenes': [
          for (final p in projects)
            <String, dynamic>{'name': p.name, 'current': p.current, 'blocked': p.blocked},
        ],
      };
    } catch (error) {
      return _failure(_threeCode(error), threeFailureMessage(error), '$error');
    }
  }

  @override
  Future<Map<String, dynamic>> threeCreate({required String name, required String brief}) async {
    try {
      final service = await _threeFactory();
      final snapshot = await service.newProject(
        name: name,
        brief: brief,
        config: _threeConfig,
      );
      return <String, dynamic>{
        'ok': true,
        'scene': snapshot.name,
        'current': snapshot.state['current'],
        'spec': snapshot.spec,
      };
    } catch (error) {
      return _failure(_threeCode(error), threeFailureMessage(error), '$error');
    }
  }

  @override
  Future<Map<String, dynamic>> threeStatus(String name) async {
    try {
      final service = await _threeFactory();
      final snapshot = await service.readProject(name);
      return <String, dynamic>{
        'ok': true,
        'scene': snapshot.name,
        'current': snapshot.state['current'],
        'blocked': snapshot.state['blocked'] == true,
        'blockedReason': snapshot.state['blocked_reason'],
        'spec': snapshot.spec,
        'sceneChars': snapshot.sceneJs.length,
      };
    } catch (error) {
      return _failure(_threeCode(error), threeFailureMessage(error), '$error');
    }
  }

  @override
  Future<Map<String, dynamic>> threePass(String name) async {
    try {
      final service = await _threeFactory();
      final result = await service.runPass(name, _threeConfig);
      return <String, dynamic>{
        'ok': true,
        'scene': name,
        'pass': result.pass,
        'stale': result.stale,
        'chars': result.chars,
        'current': result.state['current'],
      };
    } catch (error) {
      return _failure(_threeCode(error), threeFailureMessage(error), '$error');
    }
  }

  @override
  Future<Map<String, dynamic>> threeContinue(String name, [String summary = '']) async {
    try {
      final service = await _threeFactory();
      final result = await service.continuePass(name, summary);
      return <String, dynamic>{
        'ok': true,
        'scene': name,
        'current': result.current,
        'done': result.done,
      };
    } catch (error) {
      return _failure(_threeCode(error), threeFailureMessage(error), '$error');
    }
  }

  @override
  Future<Map<String, dynamic>> threeFeedback({
    required String name,
    required String kind,
    required Object? payload,
  }) async {
    try {
      final service = await _threeFactory();
      final result = await service.feedback(name, kind, payload);
      return <String, dynamic>{
        'ok': true,
        'scene': name,
        'pass': result.pass,
        'status': result.status,
        'attempts': result.attempts,
      };
    } catch (error) {
      return _failure(_threeCode(error), threeFailureMessage(error), '$error');
    }
  }

  // -- 热应用 ---------------------------------------------------------------

  @override
  Future<Map<String, dynamic>> hotAppList() async {
    try {
      final service = await _hotAppFactory();
      final apps = await service.list();
      return <String, dynamic>{
        'ok': true,
        'apps': [
          for (final app in apps)
            <String, dynamic>{
              'name': app.name,
              'title': app.title,
              'renderer': app.renderer,
              'corrupt': app.corrupt,
            },
        ],
      };
    } catch (error) {
      return _hotAppFailureEnvelope(error);
    }
  }

  @override
  Future<Map<String, dynamic>> hotAppGenerate({
    required String name,
    required String brief,
  }) async {
    try {
      final service = await _hotAppFactory();
      final app = await service.generate(name: name, brief: brief, config: _hotAppConfig);
      return <String, dynamic>{
        'ok': true,
        'app': app.name,
        'title': app.title,
        'bytes': app.payloadBytes,
      };
    } catch (error) {
      return _hotAppFailureEnvelope(error);
    }
  }

  @override
  Future<Map<String, dynamic>> hotAppRefine({
    required String name,
    required String instruction,
  }) async {
    try {
      final service = await _hotAppFactory();
      final app = await service.refine(
        name: name,
        instruction: instruction,
        config: _hotAppConfig,
      );
      return <String, dynamic>{
        'ok': true,
        'app': app.name,
        'title': app.title,
        'bytes': app.payloadBytes,
      };
    } catch (error) {
      return _hotAppFailureEnvelope(error);
    }
  }

  @override
  Future<Map<String, dynamic>> hotAppInspect(String name) async {
    try {
      final service = await _hotAppFactory();
      final app = await service.read(name);
      if (app == null) {
        return _failure('hotapp_failed', '没有找到这个应用', 'no_app: $name');
      }
      final surface = app.isA2ui ? await service.surface(name) : null;
      return <String, dynamic>{
        'ok': true,
        'app': app.name,
        'title': app.title,
        'renderer': app.renderer,
        'brief': app.brief,
        'bytes': app.payloadBytes,
        if (surface != null) 'surfaceNodes': surface.length,
      };
    } catch (error) {
      return _hotAppFailureEnvelope(error);
    }
  }

  @override
  Future<Map<String, dynamic>> hotAppFromPrototype({
    required String name,
    required String prototypeMbt,
    required List<PrototypeScreenSpec> screens,
    required List<PrototypeLinkSpec> flows,
  }) async {
    try {
      final service = await _hotAppFactory();
      final result = await service.generateFromPrototype(
        name: name,
        config: HotAppLlmConfig(
          model: model,
          baseUrl: baseUrl,
          apiKey: apiKey,
          thinkingLevel: thinkingLevel,
        ),
        prototypeMbt: prototypeMbt,
        screens: screens,
        flows: flows,
      );
      return <String, dynamic>{
        'ok': true,
        'app': result.app.name,
        'title': result.app.title,
        'bytes': result.app.payloadBytes,
        'screens': screens.length,
        'flows': flows.length,
        'verified': result.verified,
        if (!result.verified) 'failures': result.failureSummary,
      };
    } catch (error) {
      return _hotAppFailureEnvelope(error);
    }
  }

  static HotAppFailure? _hotAppFailure(Object error) =>
      error is HotAppFailure ? error : HotAppFailure('store_error', '$error');

  /// 热应用失败信封：错误码带 `hotapp_` 模块前缀（`hotapp_name_taken` …），
  /// 文案由模块自己的人话表产出；未知异常仍回 `hotapp_failed`。
  static Map<String, dynamic> _hotAppFailureEnvelope(Object error) {
    final failure = _hotAppFailure(error);
    final code = failure == null ? 'hotapp_failed' : 'hotapp_${failure.code}';
    return _failure(code, hotAppFailureMessage(failure), '$error');
  }

  /// 3D 失败信封：同理，`three_invalid_name` / `three_blocked` 等带模块前缀。
  static String _threeCode(Object error) =>
      error is ThreeFailure ? 'three_${error.code}' : 'three_failed';

  // -- 视频 -----------------------------------------------------------------

  @override
  Future<Map<String, dynamic>> videoReview({
    required Map<String, dynamic> timeline,
    Map<String, dynamic>? spec,
  }) async {
    try {
      final result = _video.review(timeline: timeline, spec: spec);
      return <String, dynamic>{
        'ok': result.ok,
        'summary': result.summary,
        'problems': result.problems,
        'notes': result.notes,
        'seconds': result.totalSeconds,
        if (!result.ok) 'error': 'video_review_failed',
        if (!result.ok) 'message': result.summary,
        if (result.technical.isNotEmpty) 'detail': result.technical.join(' | '),
      };
    } catch (error) {
      return _failure('video_failed', videoFailureMessage(error), '$error');
    }
  }

  @override
  Future<Map<String, dynamic>> videoRender({
    required Map<String, dynamic> timeline,
    Map<String, dynamic>? spec,
  }) async {
    // 视频模块是**代码动画**：时间线脚本 + 规范编译成算式，逐帧画面在应用内
    // 实时播放，不落 mp4。导出成片暂时关闭（用户裁决 2026-11-18）。
    try {
      final document = VideoDocument.build(timeline: timeline, spec: spec);
      return <String, dynamic>{
        'ok': false,
        'error': 'video_export_disabled',
        'message': '视频现在是代码动画，直接在视频工作台里播放；暂不导出成片',
        'seconds': document.totalSeconds,
        'frames': (document.totalSeconds * 10).round(),
      };
    } catch (error) {
      final rejected = error is VideoRejected ? error : null;
      return _failure(
        rejected == null ? 'video_failed' : 'video_${rejected.code}',
        videoFailureMessage(error),
        '$error',
      );
    }
  }

  /// 内置示例的片长/帧率（示例文本是金标准；坏示例按「读不出来」处理）。
  static ({double seconds, int fps}) _sampleTiming(VideoSampleInfo sample) {
    try {
      final document = VideoDocument.fromScripts(
        timelineJson: sample.timelineJson,
        specJson: sample.specJson,
      );
      return (seconds: document.totalSeconds, fps: document.fps);
    } catch (_) {
      return (seconds: 0.0, fps: 30);
    }
  }

  /// 示例 JSON 的上下文防爆上限：超过就截断（内置三个示例都在上限内）。
  static const int _videoSampleJsonLimit = 24000;

  static String _capVideoJson(String text) =>
      text.length <= _videoSampleJsonLimit
          ? text
          : '${text.substring(0, _videoSampleJsonLimit)}\n…[truncated]';

  @override
  Future<Map<String, dynamic>> videoCreate({
    required String name,
    required Map<String, dynamic> timeline,
    Map<String, dynamic>? spec,
    String title = '',
  }) async {
    try {
      final snapshot = await _videoProjects.create(
        name: name,
        timeline: timeline,
        spec: spec,
        title: title,
      );
      return <String, dynamic>{
        'ok': true,
        'video': snapshot.name,
        'title': snapshot.title,
        'seconds': snapshot.document.totalSeconds,
        'frames': snapshot.document.frameCount(),
      };
    } on VideoProjectFailure catch (error) {
      final code = 'video_${error.code}';
      return _failure(code, toolFailureMessage(code), error.technical);
    } catch (error) {
      return _failure(
        'video_io_error',
        toolFailureMessage('video_io_error'),
        '$error',
      );
    }
  }

  @override
  Future<Map<String, dynamic>> videoList() async {
    final List<VideoProjectEntry> projects;
    try {
      projects = await _videoProjects.list();
    } on VideoProjectFailure catch (error) {
      final code = 'video_${error.code}';
      return _failure(code, toolFailureMessage(code), error.technical);
    } catch (error) {
      return _failure(
        'video_io_error',
        toolFailureMessage('video_io_error'),
        '$error',
      );
    }
    final videos = <Map<String, dynamic>>[];
    for (final entry in projects) {
      videos.add(<String, dynamic>{
        'name': entry.name,
        'title': entry.title.isEmpty ? entry.name : entry.title,
        'seconds': entry.seconds,
        'frames': (entry.seconds * entry.fps).floor(),
        'builtin': false,
        if (entry.corrupt) 'corrupt': true,
      });
    }
    for (var i = 0; i < videoSamples.length; i++) {
      final sample = videoSamples[i];
      final timing = _sampleTiming(sample);
      videos.add(<String, dynamic>{
        'name': sample.id,
        'title': sample.label,
        'note': sample.note,
        'seconds': timing.seconds,
        'frames': (timing.seconds * timing.fps).floor(),
        'builtin': true,
        'index': i,
      });
    }
    return <String, dynamic>{'ok': true, 'videos': videos, 'count': videos.length};
  }

  @override
  Future<Map<String, dynamic>> videoSample({int index = 0}) async {
    if (videoSamples.isEmpty) {
      return _failure(
        'video_sample_missing',
        toolFailureMessage('video_sample_missing'),
      );
    }
    // 越界不报错：回落第一个示例（模型通常只是忘了下标）。
    final i = (index >= 0 && index < videoSamples.length) ? index : 0;
    final sample = videoSamples[i];
    final Map<String, dynamic> timeline;
    final Map<String, dynamic> spec;
    final ({double seconds, int fps}) timing;
    try {
      final decodedTimeline = jsonDecode(sample.timelineJson);
      final decodedSpec = jsonDecode(sample.specJson);
      if (decodedTimeline is! Map || decodedSpec is! Map) {
        throw const FormatException('示例根节点必须是对象');
      }
      timeline = Map<String, dynamic>.from(decodedTimeline);
      spec = Map<String, dynamic>.from(decodedSpec);
      timing = _sampleTiming(sample);
    } catch (error) {
      return _failure(
        'video_sample_missing',
        toolFailureMessage('video_sample_missing'),
        '$error',
      );
    }
    final sampleTimeline = _capVideoJson(sample.timelineJson);
    final sampleSpec = _capVideoJson(sample.specJson);
    return <String, dynamic>{
      'ok': true,
      'index': i,
      'count': videoSamples.length,
      'name': sample.id,
      'label': sample.label,
      'note': sample.note,
      'seconds': timing.seconds,
      'fps': timing.fps,
      'timeline': timeline,
      'spec': spec,
      'specName': sample.specName,
      // 原文同时给一份（模型对整个文件形状（含字段顺序外的写法）更敏感）。
      'timelineJson': sampleTimeline,
      'specJson': sampleSpec,
      'timelineChars': sampleTimeline.length,
      'specChars': sampleSpec.length,
      'guide': 'Use this sample as the shape reference. Then call '
          'video_create {name, timeline, spec, title}: name is ASCII a-z0-9_- and '
          'must be new; timeline/spec are pre-validated and written to the video '
          'workspace (played live, no file export). Review with video_review.',
    };
  }

  // -- 应用包 ---------------------------------------------------------------

  @override
  Future<Map<String, dynamic>> nonAppList() async {
    try {
      final library = await _nonAppFactory();
      final apps = await library.scan();
      return <String, dynamic>{
        'ok': true,
        'apps': [
          for (final app in apps)
            <String, dynamic>{
              'name': app.name,
              'title': app.title,
              'renderer': app.renderer,
              'corrupt': app.corrupt,
            },
        ],
      };
    } catch (error) {
      return _failure('nonapp_failed', '应用包列表读不出来，请重试', '$error');
    }
  }

  @override
  Future<Map<String, dynamic>> nonAppInspect(String name) async {
    try {
      final library = await _nonAppFactory();
      final app = await library.read(name);
      if (app == null) {
        return _failure('nonapp_failed', '没有找到这个应用', 'no_app: $name');
      }
      return <String, dynamic>{
        'ok': true,
        'app': app.name,
        'title': app.title,
        'renderer': app.renderer,
        'brief': app.brief,
        'bytes': app.payloadBytes,
        'corrupt': app.corrupt,
      };
    } catch (error) {
      return _failure('nonapp_failed', '这个应用读不出来，请重试', '$error');
    }
  }

  // -- Figma ----------------------------------------------------------------

  @override
  Future<Map<String, dynamic>> figmaExport({
    required RenderEnvelope render,
    required String directory,
  }) async {
    if (directory.trim().isEmpty) {
      return _failure(
        'figma_directory_required',
        toolFailureMessage('figma_directory_required'),
      );
    }
    final result = await _figma.export(render: render, directory: directory);
    if (!result.ok) {
      return _failure(
        result.error ?? 'figma_write_failed',
        result.message ?? figmaFailureMessage(result.error),
        result.technical,
      );
    }
    return <String, dynamic>{
      'ok': true,
      'dir': result.dir,
      'boards': result.boards,
      'files': result.files,
    };
  }
}

// ============================================================
// 请求 / 结果
// ============================================================

class DartAgentRequest {
  /// 'plan' | 'build' | 'refine' | 'workspace'。
  ///
  /// `workspace` = 用户从主页选中了 3D / 视频 / 热应用工作台：一次直接执行的
  /// run，不写文档、不碰设计画布（工具面见 `_buildTools`）。
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

  /// workspace 模式的目标工作台（`three` / `video` / `hotapp` / `auto`）。
  final String workspaceHint;

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
    this.workspaceHint = '',
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

/// 空画布判定以引擎为准（session_list_artboards）：真引擎在空画布上返回
/// 空表；查询失败/双打不支持时**不拦**（fail-open）——拦错了比不拦更伤。
Future<bool> _canvasIsEmpty(EngineGateBridge bridge, String mbt) async {
  try {
    final boards = await bridge.session(mbt, 'session_list_artboards');
    final data = boards['data'];
    if (data is! List) return false;
    return data.isEmpty;
  } catch (_) {
    return false;
  }
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

/// 工具入参进轨迹前的裁剪（长源码/整篇文档/嵌套时间线不进 tool_start 标题）。
///
/// 视频/热应用工具的参数可以带整份时间线或规范（KB 级）：`tool_start` 事件
/// 只需给用户一条可读标题，嵌套对象/数组压成形状摘要，避免事件流被撑爆。
Map<String, dynamic> _shortArgs(Map<String, dynamic> args) => <String, dynamic>{
      for (final entry in args.entries) entry.key: _shortArgValue(entry.value),
    };

Object? _shortArgValue(Object? value) {
  if (value is String) {
    return value.length > 120 ? '${value.substring(0, 120)}…' : value;
  }
  if (value is Map) return '<object ${value.length} keys>';
  if (value is List) return '<list ${value.length}>';
  return value;
}

String _truncate(String text, int limit) =>
    text.isEmpty ? '' : (text.length <= limit ? text : '${text.substring(0, limit)}\n…[truncated]');

/// 统一的 tool_end 事件。
///
/// 三个字段各司其职（改呈现前先读）：
///  * `error` —— 原始机器码，**只进折叠的技术详情**（历史消费者兼容）；
///  * `message` —— 用户可见的一句话（[toolFailureMessage] 映射），时间线
///    直接显示这一条；
///  * `detail` —— 服务层原始诊断（模型回包片段、文件异常），同样只在技术
///    详情里展开。
void _emitToolEnd(
  void Function(Map<String, dynamic>) emit,
  String tool,
  Stopwatch watch,
  Map<String, dynamic> out,
) {
  final raw = out['error']?.toString();
  emit(<String, dynamic>{
    'type': 'tool_end',
    'tool': tool,
    'ok': out['ok'] != false,
    'ms': watch.elapsedMilliseconds,
    'preview': _preview(out),
    'error': raw,
    if (raw != null && raw.isNotEmpty)
      'message': (out['message'] is String && (out['message'] as String).isNotEmpty)
          ? out['message']
          : toolFailureMessage(raw),
    if (out['detail'] != null) 'detail': out['detail'].toString(),
  });
}

// ============================================================
// 静态提示词（server prompts.py 逐字移植）
// ============================================================

const String _staticPlan = '''You are NaN — the product design partner inside NaN, an AI-native prototyping studio.

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
- A list/item area is a hard rule, not a nice-to-have: rows must be separable — a 1px
  divider at each row bottom, or ≥12px vertical spacing between rows — the list container
  carries inner padding, and icon / label / trailing value each get their own
  non-overlapping slot (icons never sit on text or on the next row).
Avoid pure black backgrounds (#000). Body contrast must be strong.

## Discipline
- The page list is the build contract: the BUILD run will receive it. Keep it to 3–8 screens.
- Every non-entry screen needs an exit (back or a flow target).
- Finish with a one-line summary and the recommended first screen.''';

const String _staticRefine = '''You are NaN — the embedded product designer of NaN, in REFINE mode.
The document already exists. Make the smallest correct change, preserve the design system,
and verify it.

## Loop
1. Use PROJECT MAP + the latest state. Read one board only if you need exact values.
2. Make one targeted design_op (or a small sequence). Do not rebuild the screen unless asked;
   a brand-new screen is generate_page {intent, name, spec} (the engine picks the template,
   applies the design spec, self-repairs and scores).
3. Keep flows intact. If you add a screen, connect it.
4. Verify with inspect {kind:"critique"} or lint when the change is structural; after
   adding/moving list rows run `fix <ab>` so the engine autofix settles dividers/padding.
5. finish with a one-line summary of what changed.

## Rules
- Match the project's palette, type scale, spacing and radius. No second visual language.
- Text contrast is a hard rule. Buttons: 2–4 CJK chars, width ≥ label + 24, radius 8.
- Lists of 3+ rows need dividers or grouping.
- Prefer update/move/copy/reorder over delete+place.
- If the request is ambiguous and the user asked for clarification, ask first (plain text).''';

// BUILD 提示词：server STATIC_BUILD 逐字移植；generate_page 已是真工具
// （P1 接入），整屏路径按 server 语义改回 generation-first。
const String _staticBuild = '''You are NaN — the embedded product designer and prototyper of NaN.
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
   BATCH YOUR TURNS (latency matters): submit up to 4 generate_page calls in ONE assistant
   turn (parallel tool calls) instead of one per turn — the engine commits them in order.
   Same for flows: wire all screens in one turn. Keep the screen list lean: 3–5 screens is
   a complete prototype for a normal brief; do not exceed 6 unless the brief demands it.
   EMPTY CANVAS (0 boards): the FIRST canvas action MUST be generate_page — design_op and
   inspect cannot run before the first board exists; retrying them only burns steps.
   OP BUDGET PER SCREEN: after generate_page, you may hand-place at most 3 design_op
   refinements on that screen (real copy / one CTA / one row). If a screen needs more,
   regenerate it with a clearer intent instead of stacking ops — hundreds of tiny ops
   are slow and fragile.
   READ THE ENVELOPE: `autofix{fixes,detail}` is what the engine already healed; `missing[]`
   is what the page type expects but lacks — materialize it with `autofill <ab>` (idempotent)
   or place the blocks yourself; `skipped[]` are combined-intent segments that matched no page
   (regenerate them separately); `score.grade` C/D means the intent missed the template —
   regenerate with a clearer intent instead of stacking ops.
5. Refine with small design_op ops only where generation needs product specifics: real copy,
   a specific CTA, a list row, an image placeholder. One op at a time — the engine gate
   validates each op individually and a rejected op must be read, adjusted, retried.
6. Connect every screen: flow <from> <to> <tappable_node>. Bind the flow to the container the
   user taps (row, button, card), never to an inner text fragment. Back is built in for
   back-like nodes (id/text containing back/返回/←).
   EVERY screen except the entry/home gets a visible back affordance: place a back node in
   the top bar — place <ab> button back - 16 52 44 32 text="←" (id MUST contain "back") —
   so demo mode can navigate back via the engine builtin-back resolution.
7. Verify before finishing: batch the checks into ONE turn — inspect {kind:"critique"} once per
   page in the same turn (9 dimensions incl. norms), then `fix <ab>` in the next turn only for
   pages that reported debt, and confirm with one lint pass for all pages. Do not alternate
   critique/fix page by page — each turnaround costs a full model round. `fix` IS the engine's debt auto-fix (the 自动修复 capability):
   it inserts missing 1px row dividers, settles padding/radius/touch/contrast/overlap debt
   deterministically — a page with fixable debt left is unfinished, never finish on a
   critique you did not act on.

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
- fix <ab> (engine debt auto-fix: dividers/norms/touch/contrast/overlap; commits only when
  violations strictly decrease — the same capability as 自动修复)
- autofill <ab> (materialize the page's missing[] report: shells + placeholder copy,
  idempotent; engine auto-fix then settles the overlaps it introduces)
- delete-artboard <ab> · duplicate <ab> <new_name>

## Component norms (engine checks these)
- Buttons never hug their label: width ≥ text width + 24; height 36–48; radius 8.
- Radius tiers: buttons/chips/selects/search 8 (or height/2 for pills); avatars 999;
  full-bleed bars/rows radius 0.
- Three or more flush list_item rows need a 1px divider at each row bottom (or card grouping).
- Every list / menu / settings area must read row-by-row (this is a hard requirement, not a
  suggestion): give each row either a 1px divider at its bottom or ≥12px vertical spacing,
  pad the list container (≥16px horizontal), and never let an icon overlap its label, a
  trailing value, or the neighboring row. A wall of rows with no separation is a defect.
- Build list rows as flush `list_item` siblings (same width, 0 gap): the engine's own
  norms/auto-fix pass only recognizes flush `list_item` runs and inserts their 1px row
  dividers. After hand-placing any 3+ row list, call `fix <ab>` — the engine's debt
  auto-fix (the same capability behind 自动修复) settles missing dividers, padding,
  radius and touch-target debt deterministically; don't approximate it with your own
  decorative lines.
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
- design_op — one mutating op (refinements, flow wiring, verification fixes, fix/autofill).
- read_mbt — no args = refreshed outline; {artboard} = that board's source.
- inspect — query_nodes / interactions / states / lint / critique / spec / export_svg /
  flows / artboards / missing (what the page type lacks) / page_type.
- list_templates / list_components — registries (summarized below).
- read_docs — full PRD/UI text when the brief matters.
- write_doc / write_design_spec — update the product definition.
- ask_user — show a short choice card when a product decision materially changes the build.
- finish — end with a summary.

## Context discipline
- PROJECT MAP is authoritative. Node ids there are real.
- Every design_op result carries a trailing state field (rev + board node counts + flow count).
  The newest state is the live truth.
- Do not re-read the whole document for a tweak. Read one board only for exact values.

## Clarify-first
If the user explicitly asks for confirmation questions before building, reply with the questions
as plain text and do NOT call tools. Their answers arrive with the next instruction.''';


/// workspace 模式（3D / 视频 / 热应用）的静态指令。
///
/// 与 PLAN/BUILD 的关键区别：不写 PRD、不碰设计画布——四个工作区互相独立，
/// 用户已经在主页选好了目标工作台。工具面由 [_buildTools] 收窄到工作区工具。
const String _staticWorkspace = '''You are NaN — the embedded creative agent of NaN, working in WORKSPACE mode.
The user picked a target workspace. Stay inside it and complete the task with the
workspace tools of that module. Do not write product docs, do not call design_op or
generate_page, do not describe a canvas prototype.

## Workspaces
- 3D scene: three_list / three_create / three_status / three_pass / three_continue / three_feedback
  (create from a one-line brief, then pass by pass; report the new scene length after each pass).
- Hot app: hotapp_list / hotapp_generate / hotapp_refine / hotapp_inspect
  (single-file HTML app with local data; verify it before claiming done).
- Design → hot app: hotapp_from_prototype (the sanctioned cross-module link). When the user
  wants the canvas prototype as a runnable app, call it — screens and flows are extracted
  from the prototype automatically and the result reports verified or what is missing.
- Video: video_list / video_sample / video_create / video_review
  Video is a CODE-DRIVEN ANIMATION: a timeline script (scenes of vector elements whose
  x/y/w/... can be formula-driven by t/T) plus a spec (kind science or screenplay).
  There is NO video-file export — the workspace compiles the formulas and plays the
  animation live. Work order: video_sample first (index 0-2) to copy the exact JSON
  shape → video_create {name, timeline, spec, title} to WRITE the project to disk
  (name ASCII a-z0-9_-, must be new; the document is pre-validated before anything
  is written) → video_review to mechanically check the same timeline before finish.
  video_list shows generated projects plus the built-in samples (builtin=true).
- App packages: nonapp_list / nonapp_inspect (read-only inventory).
- Figma: figma_export (only when explicitly asked, absolute folder path).

## Asking the user
- ask_user works in every run, including a workspace pinned by the user. Use it for
  content / direction decisions inside this workspace (tone, structure, which story
  beat, level of detail …) whenever the answer genuinely changes the work.
- Set `switch_to` ONLY when the request truly belongs to a DIFFERENT workspace
  (e.g. the brief is an interactive app but this run is a video animation): the user's
  pick then really switches workspace and the run continues there. Never use switch_to
  for content decisions, and never ask just to re-confirm the workspace you are in.

## Discipline
- Call a workspace tool in the first turn. Prose alone delivers nothing.
- One module per task. If the request clearly belongs to another workspace, use ask_user
  (with switch_to) instead of silently doing the wrong thing.
- Report what changed in one line; reply in the user's language.''';

const String _staticFooter = '''## Engine facts
- Canonical document is .mbt.md. Every op is committed by the engine's AgentGate.
- Read-only commands are NOT accepted by design_op; use inspect/read_mbt instead.
- A rejected op returns ok:false with an error. Read it, adjust, retry once.
- Never invent components or template ids. Use the registries below.
- The tool list above is EXHAUSTIVE. Never invent tool names (there is no
  delete-artboard tool): deleting/cleaning empty artboards happens automatically
  after the run. Do what you can with the listed tools, then call finish.

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
  bool hasWorkspaceTools = false,
  String workspaceHint = '',
}) {
  final static = mode == 'plan'
      ? _staticPlan
      : mode == 'refine'
          ? _staticRefine
          : mode == 'workspace'
              ? _staticWorkspace
              : _staticBuild;
  // workspace 模式给一份精简上下文：设计文档/画板地图/模板注册表与
  // 3D/视频/热应用无关，塞进去只会把模型往设计画布上带。
  if (mode == 'workspace') {
    final target = workspaceHint.trim().isEmpty ? 'auto' : workspaceHint.trim();
    return [
      static,
      '',
      '---',
      '## TARGET WORKSPACE',
      '- mode: $target',
      if (workspaceHint.isNotEmpty)
        '- 用户在主页选的是这个工作台；只做这一件事。',
      '',
      if (hasWorkspaceTools) ...<String>[
        '## WORKSPACE TOOLS (this device)',
        '- 3D scenes: three_list / three_create / three_status / three_pass / '
            'three_continue / three_feedback',
        '- Hot apps: hotapp_list / hotapp_generate / hotapp_refine / hotapp_inspect',
        '- Design → hot app: hotapp_from_prototype (builds from the canvas prototype; '
        'reports verified coverage)',
        '- Video: video_list / video_sample / video_create / video_review '
            '(code-driven animation: sample → create on disk → review; no file export)',
        '- App packages: nonapp_list / nonapp_inspect',
        '- Figma: figma_export (pass an absolute folder path)',
        '',
      ] else ...<String>[
        '## WORKSPACE TOOLS',
        '(this host exposes none — report that plainly instead of pretending)',
        '',
      ],
      '---',
      _staticFooter,
    ].join('\n');
  }
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
  final wsTarget = workspaceHint.trim().isEmpty ? 'auto' : workspaceHint.trim();
  final wsPinned = mode == 'workspace' && wsTarget != 'auto';
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
    if (hasWorkspaceTools) ...<String>[
      '## WORKSPACE TOOLS (this device)',
      // wsTarget/wsPinned：workspaceHint 由 runDartAgent 传入（用户在主页
      // 选定的目标工作台；auto 交给模型判断）。
      '- 3D scenes: three_list / three_create / three_status / three_pass / '
          'three_continue / three_feedback',
      '- Hot apps: hotapp_list / hotapp_generate / hotapp_refine / hotapp_inspect',
        '- Design → hot app: hotapp_from_prototype (builds from the canvas prototype; '
        'reports verified coverage)',
      '- Video: video_list / video_sample / video_create / video_review '
          '(code-driven animation: sample → create on disk → review; no file export)',
      '- App packages: nonapp_list / nonapp_inspect',
      '- Figma: figma_export (pass an absolute folder path)',
      'This run works only inside the target workspace: canvas editing tools are not '
          'available here. hotapp_from_prototype may READ the current prototype '
          '(screens and links) when converting it into an app.',
      if (wsPinned)
        'This run is PINNED to the $wsTarget workspace by the user. Execute with the $wsTarget '
            'tools only. Do not ask which workspace to use and do not suggest switching unless '
            'the request truly belongs to another workspace (switch_to is for that only). If '
            'the request does not fit this workspace, say so honestly in the finish summary. '
            'ask_user still works here: use it freely for content/direction decisions inside '
            'this workspace; only a workspace change needs switch_to.',
      '',
    ],
    '---',
    _staticFooter,
  ].join('\n');
}

/// server `user_message`：模式前缀 + 用户 brief。
String dartUserMessage(String mode, String instruction, {String workspaceHint = ''}) {
  final prefix = switch (mode) {
    'plan' => 'PLAN: produce the PRD, UI spec and design system. Do not edit the canvas.',
    'refine' => 'REFINE the existing document.',
    'workspace' => 'WORKSPACE: act inside the ${workspaceHint.isEmpty ? 'chosen' : workspaceHint} '
        'workspace with its tools. Do not touch the design canvas.',
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
  /// 本地工作区服务（3D / 热应用 / 视频 / 应用包 / Figma）。null = 这些工具
  /// 不暴露（手机或未接线的宿主）——模型看不到入口，就不会点了没反应。
  AgentWorkspaceServices? workspace,
  void Function(Map<String, dynamic> event)? onEvent,
  CancellationToken? abortSignal,
  Duration? timeout,
}) async {
  final emit = onEvent ?? (_) {};
  final ctx = _Ctx(
    request: request,
    // plan 不给引擎面（server 同构）。workspace 保留只读桥：3D/视频/热应用
    // 不改画布，但 hotapp_from_prototype（设计→热应用）需要读当前原型的
    // 画板与连线（2026-11-20：此前置 null 让该工具恒报 prototype_empty）。
    // 画布写工具仍由 _buildTools 按模式关掉。
    bridge: request.mode == 'plan' ? null : bridge,
    workspace: request.mode == 'plan' ? null : workspace,
    emit: emit,
  );
  OpenAIProvider? provider;
  try {
    provider = modelOverride == null && request.apiKey.isNotEmpty
        ? OpenAIProvider(apiKey: request.apiKey, baseUrl: request.baseUrl)
        : null;
    emit({
      'type': 'note',
      'label': 'NaN 开始',
      'detail': '${_modeLabel(request.mode)} · ${request.model}',
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
      hasWorkspaceTools: ctx.workspace != null,
      workspaceHint: request.workspaceHint,
    );
    final tools = _buildTools(ctx);

    final usage = _RoundUsage();

    Future<void> consume(String prompt,
        {String? instructionsOverride, int continuation = 0}) async {
      // dynamic 是有意的：测试注入 scripted mock 不经 ai_sdk_provider 的
      // 直接依赖（pubspec 未声明，隐式传递依赖不 import 其类型）。
      // 生产路径套 StreamToolNameGuard：StepFun step_plan 流式把工具名只放
      // 首个 delta、后续 delta 重复 name:""，SDK 逐 delta 覆盖会把真名覆盖
      // 成空 → AiNoSuchToolError 打死整轮（见 agent_model_middleware.dart）。
      // 测试注入的 scripted mock 保持原样（覆写 doStream 的形状自持）。
      final dynamic model = modelOverride ??
          wrapLanguageModel(
            model: provider!.call(request.model),
            middleware: StreamToolNameGuard(knownTools: tools.keys.toSet()),
          );
      // 等待重试（瞬时故障自愈）：网络抖动 / 限流 / 网关 5xx / 超时——
      // agent 不直接判死，按退避等待后原样重发这一轮。交付水位前移则
      // 不重试（工具已真实落地，重复执行会双写画布/文档）。
      final watermark = _deliveryWatermark(ctx);
      // 本轮实际下发 prompt：工具名拼错（llm_no_such_tool）重试时会在原
      // prompt 后追加可用工具清单，让模型从清单里挑正确的名字（自愈而不是
      // 原样重发）；其余重试仍原样重发。
      var roundPrompt = prompt;
      for (var attempt = 0; ; attempt++) {
        final roundSw = Stopwatch()..start();
        try {
          final result = await streamText(
            model: model,
            instructions: instructionsOverride ?? instructions,
            prompt: roundPrompt,
            // maxSteps 是「一次 streamText 内允许的模型步数」。设置值（常见
            // 500）在推理模型上等于无上限：一步一轮 20-70s，几十轮就爆表。
            // 按模式收紧到产品需要的轮数（用户设置只在其下生效）。
            maxSteps: request.maxSteps
                .clamp(4, switch (request.mode) {
                  'plan' => 12,
                  'refine' => 20,
                  'workspace' => 25,
                  _ => 40,
                }),
            tools: tools,
            abortSignal: abortSignal,
            timeout: timeout == null ? null : TimeoutConfiguration(total: timeout),
            providerOptions: providerThinkingOptions(request),
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
          assert(() {
            // ignore: avoid_print
            print('[agent] round done in ${roundSw.elapsedMilliseconds}ms '
                '(mode=${request.mode}, attempt=$attempt)');
            return true;
          }());
          return;
        } catch (e) {
          assert(() {
            // ignore: avoid_print
            print('[agent] round failed in ${roundSw.elapsedMilliseconds}ms '
                '(mode=${request.mode}, attempt=$attempt): $e');
            return true;
          }());
          if (abortSignal?.isCancelled == true) rethrow;
          final code = classifyLlmError(e);
          // 共 10 次重试（首轮失败后还能再试 10 次），每次 30 秒。
          const maxAttempts = llmRetryMaxRetries + 1;
          final delivered = _deliveryWatermark(ctx) != watermark;
          if (attempt >= maxAttempts - 1 || !isRetryableLlmError(code)) {
            rethrow;
          }
          // 已交付（画布/文档已有真实进展）+ 瞬时故障：续跑而不是重发——
          // 重建新鲜上下文（项目地图/文档按当前状态重算），让模型从断点
          // 接着做完；最多 2 次，绝不无限续。
          if (delivered) {
            if (continuation >= llmRetryMaxRetries) rethrow;
            final freshMap = ctx.bridge == null
                ? ''
                : await _guard(() => composeProjectMap(ctx.bridge!, ctx.mbt),
                    fallback: '');
            final freshTemplates = ctx.bridge == null
                ? const <dynamic>[]
                : await _guard(() => ctx.bridge!.templates(),
                    fallback: const <dynamic>[]);
            final freshComponents = ctx.bridge == null
                ? const <dynamic>[]
                : await _guard(() => ctx.bridge!.components(),
                    fallback: const <dynamic>[]);
            final contInstructions = composeDartInstructions(
              mode: request.mode,
              projectMap: freshMap,
              designSpec: ctx.designSpec,
              docs: ctx.docs,
              templates: freshTemplates,
              components: freshComponents,
              hasWorkspaceTools: ctx.workspace != null,
              workspaceHint: request.workspaceHint,
            );
            final wait = llmRetryWaitFor(continuation);
            emit({
              'type': 'note',
              'label': 'NaN 断线续跑',
              'detail': '模型连接中断，$wait 秒后带着当前进度继续'
                  '（第 ${continuation + 1} 次，已完成的内容保留）',
            });
            await Future<void>.delayed(Duration(seconds: wait));
            if (abortSignal?.isCancelled == true) rethrow;
            return consume(
              _continuationPrompt(request.mode),
              instructionsOverride: contInstructions,
              continuation: continuation + 1,
            );
          }
          final wait = llmRetryWaitFor(attempt);
          // 工具名拼错：重试轮把可用工具清单追加进 prompt（自愈而不是原样
          // 重发）；其它瞬时故障仍是原样重发。
          roundPrompt = code == 'llm_no_such_tool'
              ? _noSuchToolRetryPrompt(prompt, tools)
              : prompt;
          emit({
            'type': 'note',
            'label': 'NaN 等待重试',
            'detail': '模型刚才没有响应，$wait 秒后自动重试'
                '（第 ${attempt + 1} 次，共 ${maxAttempts - 1} 次机会）',
          });
          await Future<void>.delayed(Duration(seconds: wait));
          if (abortSignal?.isCancelled == true) rethrow;
        }
      }
    }

    await consume(dartUserMessage(
      request.mode,
      request.instruction,
      workspaceHint: request.workspaceHint,
    ));
    if (await _cancelledExit(ctx, abortSignal)) return _terminal(ctx, 'cancelled');

    // ---- nudge 轮（迁移前参考实现逐语义移植）----
    final missingDocs = request.mode == 'plan' &&
        !_allTruthy([ctx.docs['prd'], ctx.docs['ui'], ctx.docs['design']]);
    final noWork = request.mode != 'plan' && ctx.remoteCalls == 0;
    if (!ctx.finished && (missingDocs || noWork)) {
      emit({
        'type': 'note',
        'label': 'NaN 继续执行',
        'detail': '上一次回复没有交付文档 / 画布操作，继续调用工具。',
      });
      final nudge = request.mode == 'plan'
          ? "You replied without calling tools. Deliver now: call write_doc(kind='prd'), "
              "write_doc(kind='ui'), write_design_spec, then finish. Do not reply with prose only."
          : request.mode == 'workspace'
              ? 'You replied without calling a workspace tool. Act now: call the tool for the '
                  'target workspace (three_* / hotapp_* / video_*), then finish with one summary '
                  'line. Do not reply with prose only.'
              : 'You replied without changing the canvas. Proceed now with the actual tool calls '
                  '(generate_page / design_op / inspect), then finish. Do not reply with prose only.';
      await consume(nudge);
      if (await _cancelledExit(ctx, abortSignal)) return _terminal(ctx, 'cancelled');
    }

    // ---- doc_not_written（迁移前参考实现逐语义移植；失败门只看
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

    // ---- 收尾确定性桥段（迁移前参考实现同序）：空板清扫 → RSI
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
    // error 带分类码（供文案映射），detail 保留原始异常（技术详情）。
    final code = cancelled ? 'cancelled' : classifyLlmError(e);
    // PLAN 文档三件套已齐时的收尾笔误（finish 拼成近义名 → 撞
    // llm_no_such_tool，重试后仍错）：交付物已落地，按完成收尾——终态
    // 判定看交付物，不因收尾客套步骤把已成功的 run 判死（2026-11-20
    // 四模块回归实测：PRD/UI/规范全 ✓ 后 finish 拼错 → 整轮 failed）。
    final docsDelivered = request.mode == 'plan' &&
        _allTruthy([ctx.docs['prd'], ctx.docs['ui']]);
    // build/refine/workspace：画布/工作区已有真实调用（remoteCalls>0）同样
    // 视为已交付——收尾笔误不把做了实事的 run 判死。
    final workDelivered = ctx.remoteCalls > 0;
    if (!cancelled &&
        code == 'llm_no_such_tool' &&
        (docsDelivered || workDelivered)) {
      // usage 统计在 try 作用域内，此处兜底空遥测（failed 路径同款）。
      emit({
        'type': 'done',
        'text': ctx.summary.isNotEmpty
            ? ctx.summary
            : (ctx.textParts.join().isNotEmpty
                ? ctx.textParts.join()
                : '文档已交付'),
        if (ctx.mbt.isNotEmpty) 'mbt_b64': base64Encode(utf8.encode(ctx.mbt)),
        'ops': List<String>.from(ctx.ops),
        'docs': ctx.docs,
        'designSpec': ctx.designSpec,
        'usage': const <String, dynamic>{},
        'stopReason': 'done',
        'cleanup': List<String>.from(ctx.cleanup),
      });
      return DartAgentResult(
        ok: true,
        stopReason: 'done',
        mbt: ctx.mbt,
        docs: ctx.docs,
        designSpec: ctx.designSpec,
        ops: ctx.ops,
        remoteCalls: ctx.remoteCalls,
        usage: const {},
      );
    }
    emit({
      'type': 'failed',
      'error': code,
      // 用户可见的一句话；原始异常只进 error/detail（折叠的技术详情）。
      'message': cancelled ? '已取消这一轮' : toolFailureMessage(code),
      'detail': llmErrorDetail(e),
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

  /// 本地工作区服务（非 plan 模式且宿主提供时非 null）。
  final AgentWorkspaceServices? workspace;
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

  _Ctx({
    required this.request,
    required this.bridge,
    required this.workspace,
    required this.emit,
  }) : mbt = request.mbt {
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
/// 逐板 `session_critique`（只读）→ 有可修债务时 `session_auto_fix` 定向修复
/// （引擎的 autofix 通道：norm_list_divider 补 1px 行分割线、组件规范 v1、
/// 触控 44×44、撞色翻转、谓词重叠/溢出清偿），并把信封 canonical 回灌
/// ctx.mbt（复评必须看修复后的文档）；最多 2 轮。
///
/// **触发面**：`verdict=='poor'` 的维度 **或** norms 维度的
/// observation「N 处规范偏差」>0。只看 poor 会漏掉引擎明明能修的债——
/// critique 的 norms 是「>4 处偏差才 poor」（0 处 9 分 / ≤2 处 7 分 / ≤4 处
/// 5 分），而「3 行齐缝列表没有 1px 分割线」这类单点结构债只报 1 处，
/// 永远等不到 auto_fix，用户看到的就是整片列表糊在一起。v2 检测项
/// （字号阶/密度/gap 网格）没有 autofix 通道，修不动时也只是空转（≤2 轮
/// 上限），信封 `fixes:0` 不会被误判成失败。
///
/// **模式边界**：norms 债务触发只对 `build` / `refine`（设计工作台）生效；
/// `workspace`（3D/视频/热应用）沿用 server 原语义，只有 `verdict=='poor'`
/// 才动画布——一次工作区任务不应顺手改设计稿。
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
  // 设计工作台的 autofix 只对该模式的画布负责；workspace（3D/视频/热应用）
  // 沿用 server 原语义（只看 poor），不让一次工作区任务去改设计稿。
  final designMode = ctx.request.mode == 'build' || ctx.request.mode == 'refine';
  try {
    for (var rnd = 1; rnd <= 2; rnd++) {
      final listed = await bridge.session(ctx.mbt, 'session_list_artboards');
      // 目标：非 seed、非空板的板（与 server 过滤一致），值为可修债务数。
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
          final debt = _critiqueFixableDebt(results, includeNormDebt: designMode);
          if (debt > 0) targets[bid] = debt;
        } catch (_) {
          continue; // 单板检视失败跳过，不中断整轮
        }
      }
      if (targets.isEmpty) {
        if (rnd == 1) {
          ctx.emit({'type': 'note', 'label': '质量审查', 'detail': '全部屏幕通过质量检查'});
        }
        break;
      }
      ctx.emit({
        'type': 'review_round',
        'round': rnd,
        'detail': targets.entries.map((e) => '${e.key} · ${e.value} 处待改进').join('、'),
      });
      for (final entry in targets.entries) {
        ctx.emit({
          'type': 'note',
          'label': '修复轮',
          'detail': '${entry.key} · 正在自动优化 ${entry.value} 处',
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

/// 评审结果 → 交给引擎 autofix 的待修点数。
///
/// - 任一维度 `verdict=='poor'`：+1（保持 server 原语义）；
/// - norms 维度：解析 observation 的「N 处规范偏差」，N>0 即 +N——
///   verdict 仍可能是 good/fair（阈值 >4 才 poor），但这些偏差里包含
///   `fix <ab>` / `session_auto_fix` 能确定性修复的 list_divider / 触控 /
///   圆角 / 撞色 / 谓词债，放弃触发等于把引擎能力闲置。
/// 解析不出的（旧引擎没有 norms 维度、或文案变了）按 0 处理，不误触发。
int _critiqueFixableDebt(List results, {bool includeNormDebt = false}) {
  var debt = 0;
  for (final r in results) {
    if (r is! Map) continue;
    if (r['verdict'] == 'poor') {
      debt += 1; // 该维度已计入，norms 再报数时不重复加
      continue;
    }
    if (!includeNormDebt || r['principle'] != 'norms') continue;
    final obs = _s(r['observation']);
    final n = int.tryParse(RegExp(r'\d+').firstMatch(obs)?.group(0) ?? '');
    if (n != null && n > 0) debt += n;
  }
  return debt;
}

// ============================================================
// 工具面（迁移前参考实现的九工具对齐）
// ============================================================

Map<String, String> _strArgs(Object? input) =>
    (input as Map?)?.map((k, v) => MapEntry(k.toString(), v?.toString() ?? '')) ?? const {};

/// ask_user 的 A2UI v1.0 basic 目录载荷：一个问题 + 若干按钮。
///
/// 只使用官方 basic 目录组件（Text / Button / Column），按钮动作是协议
/// 标准的 `event` 形状——渲染器与 `.nonapp` 查看器走同一条 A2UI 路径。
List<Object?> _askUserSurface({
  required String question,
  required List<String> options,
  String switchTo = '',
}) {
  final surfaceId = 'ask-${DateTime.now().microsecondsSinceEpoch}';
  final components = <Map<String, Object?>>[
    {
      'id': 'root',
      'component': 'Column',
      'children': [
        'question',
        for (var i = 0; i < options.length; i++) 'option$i',
      ],
    },
    {'id': 'question', 'component': 'Text', 'text': question},
  ];
  for (var i = 0; i < options.length; i++) {
    components.add({
      'id': 'option$i',
      'component': 'Button',
      'child': 'option${i}Label',
      'action': {
        'event': {
          'name': options[i],
          'context': {
            'question': question,
            if (switchTo.isNotEmpty) 'switch_to': switchTo,
          },
        },
      },
    });
    components.add({'id': 'option${i}Label', 'component': 'Text', 'text': options[i]});
  }
  return [
    {
      'version': '1.0',
      'createSurface': {
        'surfaceId': surfaceId,
        'catalogId': 'https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json',
        'components': components,
      },
    },
  ];
}

ToolSet _buildTools(_Ctx ctx) {
  final emit = ctx.emit;
  final tools = <String, Tool<dynamic, dynamic>>{};

  // 有真实产出的工作区工具：成功调用会移动交付水位（见 addWorkspaceTool）。
  const workspaceWriteTools = <String>{
    'three_create',
    'three_pass',
    'three_continue',
    'three_feedback',
    'hotapp_generate',
    'hotapp_refine',
    'hotapp_from_prototype',
    'video_create',
    'figma_export',
  };

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
        if (out['error'] != null) 'message': toolFailureMessage(out['error']?.toString()),
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

  // ---- ask_user（A2UI 交互卡的真实生产者）----
  // 与常规 agent 循环一致（用户裁决变更 2026-11-20）：ask_user 在所有模式
  // 都可用，包括用户已经钉死工作台的 workspace run。曾经的「钉死工作台就
  // 拒答（ask_user_unavailable）」死路已删除——内容/方向决策的确认卡在该
  // 工作台里同样有价值；只有「真要换工作台」才带 switch_to（store 侧
  // handleChatAction 会真正切换 chatWorkspaceMode + 视图再续跑）。
  tools['ask_user'] = tool(
    description: 'Show a quick choice card when a product decision materially changes the build '
        '(layout direction, navigation model, tone, story beat, level of detail). Works in '
        'EVERY run, including a workspace run pinned by the user: content/direction decisions '
        'are always fair to ask. Two to six short options; the user picks one and the choice '
        'comes back as the next instruction. Do not use it for trivial confirmations; keep '
        'working when the answer is obvious.',
    inputSchema: Schema(
      jsonSchema: {
        'type': 'object',
        'properties': {
          'question': {'type': 'string', 'description': 'One short question in the user language.'},
          'options': {
            'type': 'array',
            'items': {'type': 'string'},
            'minItems': 2,
            'maxItems': 6,
          },
          'switch_to': {
            'type': 'string',
            'enum': ['design', 'three', 'video', 'hotapp'],
            'description': 'Set ONLY when the user must pick another workspace for this request '
                '(e.g. the brief is an interactive app but this run is pinned to video). '
                'Value is the workspace the user should switch to. Never set it for '
                'product/content decisions.',
          },
        },
        'required': ['question', 'options'],
      },
      fromJson: (m) => m,
    ),
    execute: (input, _) async {
      final raw = (input as Map?) ?? const {};
      final question = (raw['question'] ?? '').toString().trim();
      final rawOptions = raw['options'];
      final switchTo = (raw['switch_to'] ?? '').toString().trim();
      final options = <String>[
        if (rawOptions is List)
          for (final value in rawOptions)
            if (value.toString().trim().isNotEmpty) value.toString().trim(),
      ].take(6).toList();
      final sw = Stopwatch()..start();
      emit({
        'type': 'tool_start',
        'tool': 'ask_user',
        'args': {'question': question, 'options': options.length},
      });
      if (question.isEmpty || options.length < 2) {
        emit({
          'type': 'tool_end',
          'tool': 'ask_user',
          'ok': false,
          'ms': sw.elapsedMilliseconds,
          'error': 'ask_user_invalid',
          'message': '选项没有准备好，请重试',
        });
        return {'ok': false, 'error': 'ask_user_invalid'};
      }
      final messages =
          _askUserSurface(question: question, options: options, switchTo: switchTo);
      emit({
        'type': 'a2ui',
        'messages': messages,
        'text': question,
        if (switchTo.isNotEmpty) 'switch_to': switchTo,
      });
      emit({
        'type': 'tool_end',
        'tool': 'ask_user',
        'ok': true,
        'ms': sw.elapsedMilliseconds,
        'preview': '${options.length} 个选项',
      });
      return {'ok': true, 'options': options.length};
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

  // ---- 以下为设计画布工具（plan / workspace 都不注册：工作区 run 不允许
  // 改画布，hotapp_from_prototype 走 workspace 工具块单独读取）----
  if (ctx.request.mode != 'plan' && ctx.request.mode != 'workspace') {
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
          if (out['error'] != null) 'message': toolFailureMessage(out['error']?.toString()),
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
          'interact/theme/token/fix/autofill…). The engine AgentGate validates it. Use this '
          'for refinements and flow wiring; do not hand-place whole screens.',
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
        } else if (await _canvasIsEmpty(bridge, ctx.mbt)) {
          // 空画布上 design_op 必然失败（没有画板可挂，session 打不开）——
          // 显性给出唯一正确动作，避免模型在同一个门上连环重试。
          out = {'ok': false, 'error': 'canvas_empty'};
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
          if (out['error'] != null) 'message': toolFailureMessage(out['error']?.toString()),
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
        final sw = Stopwatch()..start();
        emit({
          'type': 'tool_start',
          'tool': 'read_mbt',
          'args': {'artboard': artboard},
        });
        Map<String, dynamic> out;
        if (artboard.isEmpty) {
          final bridge = ctx.bridge;
          if (bridge == null) {
            out = {'ok': false, 'error': 'engine_unavailable'};
          } else {
            try {
              out = {'ok': true, 'outline': await composeProjectMap(bridge, ctx.mbt)};
            } catch (e) {
              out = {'ok': false, 'error': 'engine_session_failed:$e'};
            }
          }
        } else {
          final section = artboardSection(ctx.mbt, artboard);
          out = section == null
              ? {'ok': false, 'error': 'unknown_artboard:$artboard'}
              : {'ok': true, 'artboard': artboard, 'source': section};
        }
        _emitToolEnd(emit, 'read_mbt', sw, out);
        return out;
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
      // 页面体检（迁移前 deepDesign 的 missing <ab> / 页型判定）：引擎只读面
      // session_infer_missing / session_infer_page_type。补齐内容缺口与
      // autofill 是 autofix 收尾前的「查缺」入口。
      'missing': 'session_infer_missing',
      'page_type': 'session_infer_page_type',
    };
    tools['inspect'] = tool(
      description: 'Read-only engine inspection: query_nodes, interactions, states, lint, '
          'critique, spec, export_svg, flows, artboards, missing, page_type. '
          'Use critique/lint to verify and missing to find content gaps before autofill.',
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
        final sw = Stopwatch()..start();
        emit({
          'type': 'tool_start',
          'tool': 'inspect',
          'args': {'kind': kind, 'artboard': artboard},
        });
        Map<String, dynamic> out;
        final fn = inspectMapping[kind];
        if (fn == null) {
          out = {'ok': false, 'error': 'unknown_inspect_kind:$kind'};
        } else {
          const needsBoard = {
            'query_nodes', 'interactions', 'states', 'lint', 'critique', 'spec', 'export_svg',
            'missing', 'page_type',
          };
          final bridge = ctx.bridge;
          if (needsBoard.contains(kind) && artboard.isEmpty) {
            out = {'ok': false, 'error': 'artboard_required'};
          } else if (bridge == null) {
            out = {'ok': false, 'error': 'engine_unavailable'};
          } else {
            try {
              final env = Map<String, dynamic>.from(
                  await bridge.session(ctx.mbt, fn, artboard.isEmpty ? null : artboard));
              if (kind == 'export_svg') {
                final data = env['data'];
                final svg = data is Map ? data['svg'] : null;
                if (svg is String) {
                  env['data'] = {
                    'ok': true,
                    'chars': svg.length,
                    'preview': svg.substring(0, svg.length < 1200 ? svg.length : 1200),
                  };
                }
              }
              env['state'] = await stateSummary(bridge, ctx.mbt, parseRevision(ctx.mbt));
              out = env;
            } catch (e) {
              out = {'ok': false, 'error': 'engine_session_failed:$e'};
            }
          }
        }
        _emitToolEnd(emit, 'inspect', sw, out);
        return out;
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

  // ---- 本地工作区工具（3D / 热应用 / 视频 / 应用包 / Figma 导出）----
  //
  // 只在宿主注入服务时暴露（手机或未接线的宿主看不到入口，模型不会
  // 点了没反应）。每个工具的统一纪律：
  //   tool_start → 服务信封 → tool_end（失败句经 toolFailureMessage 映射，
  //   原始码只在 error/detail 的技术详情里）。
  final workspace = ctx.workspace;
  if (workspace != null) {
    void addWorkspaceTool(
      String name,
      String description,
      Map<String, dynamic> properties,
      List<String> required,
      Future<Map<String, dynamic>> Function(Map<String, dynamic> args) run,
    ) {
      tools[name] = tool(
        description: description,
        inputSchema: Schema(
          jsonSchema: {
            'type': 'object',
            'properties': properties,
            if (required.isNotEmpty) 'required': required,
          },
          fromJson: (m) => m,
        ),
        execute: (input, _) async {
          final raw = (input as Map?) ?? const {};
          final args = <String, dynamic>{
            for (final entry in raw.entries) entry.key.toString(): entry.value,
          };
          final sw = Stopwatch()..start();
          emit({'type': 'tool_start', 'tool': name, 'args': _shortArgs(args)});
          Map<String, dynamic> out;
          try {
            out = await run(args);
          } catch (error) {
            out = <String, dynamic>{
              'ok': false,
              'error': '${name}_failed',
              'detail': '$error',
            };
          }
          // 成功的**产出型**工作区调用就是真实交付：记进交付水位（网络中断
          // 后走「带进度续跑」而不是重发整轮），也让 workspace run 的终态从
          // text_only 更正为 done（工具确实落地了，不能谎报没做事）。只读
          // 类（*_list / *_inspect / *_status / video_review）不移动水位。
          if (out['ok'] != false && workspaceWriteTools.contains(name)) {
            ctx.remoteCalls += 1;
          }
          _emitToolEnd(emit, name, sw, out);
          return out;
        },
      );
    }

    String str(Map<String, dynamic> args, String key) => (args[key] ?? '').toString();

    addWorkspaceTool(
      'three_list',
      'List 3D scene projects on this device (name, current pass, blocked).',
      const <String, dynamic>{},
      const <String>[],
      (_) => workspace.threeList(),
    );
    addWorkspaceTool(
      'three_create',
      'Start a 3D scene project from a one-line brief: writes the scene spec and the '
          'layered plan (components + acceptance).',
      const <String, dynamic>{
        'name': {'type': 'string', 'description': 'ASCII name (a-z0-9_-)'},
        'brief': {'type': 'string'},
      },
      const <String>['name', 'brief'],
      (args) => workspace.threeCreate(name: str(args, 'name'), brief: str(args, 'brief')),
    );
    addWorkspaceTool(
      'three_status',
      'Read one 3D scene project: current pass, blocked state, spec summary.',
      const <String, dynamic>{
        'name': {'type': 'string'},
      },
      const <String>['name'],
      (args) => workspace.threeStatus(str(args, 'name')),
    );
    addWorkspaceTool(
      'three_pass',
      'Generate the current 3D pass (one layer) from the scene spec, then report the '
          'new scene length so the preview can be checked.',
      const <String, dynamic>{
        'name': {'type': 'string'},
      },
      const <String>['name'],
      (args) => workspace.threePass(str(args, 'name')),
    );
    addWorkspaceTool(
      'three_continue',
      'Accept the current 3D pass (only after it has evidence) and move to the next '
          'layer; the last pass finishes the scene.',
      const <String, dynamic>{
        'name': {'type': 'string'},
        'summary': {'type': 'string'},
      },
      const <String>['name'],
      (args) => workspace.threeContinue(str(args, 'name'), str(args, 'summary')),
    );
    addWorkspaceTool(
      'three_feedback',
      'Record feedback for the current 3D pass. kind=error counts a failed attempt '
          '(blocks after the loop limit); kind=metrics records measurements only.',
      const <String, dynamic>{
        'name': {'type': 'string'},
        'kind': {'type': 'string', 'enum': ['error', 'metrics']},
        'note': {'type': 'string'},
      },
      const <String>['name', 'kind', 'note'],
      (args) => workspace.threeFeedback(
        name: str(args, 'name'),
        kind: str(args, 'kind'),
        payload: str(args, 'note'),
      ),
    );

    addWorkspaceTool(
      'hotapp_list',
      'List installed hot apps (small interactive apps) on this device.',
      const <String, dynamic>{},
      const <String>[],
      (_) => workspace.hotAppList(),
    );
    addWorkspaceTool(
      'hotapp_generate',
      'Generate a new hot app from a one-line brief: one self-contained offline page '
          '(no external references) plus its local data store.',
      const <String, dynamic>{
        'name': {'type': 'string', 'description': 'lowercase ASCII (a-z0-9_-)'},
        'brief': {'type': 'string'},
      },
      const <String>['name', 'brief'],
      (args) => workspace.hotAppGenerate(name: str(args, 'name'), brief: str(args, 'brief')),
    );
    addWorkspaceTool(
      'hotapp_refine',
      'Refine an existing hot app in place (hot update). The old page is replaced only '
          'after the new one passes validation.',
      const <String, dynamic>{
        'name': {'type': 'string'},
        'instruction': {'type': 'string'},
      },
      const <String>['name', 'instruction'],
      (args) => workspace.hotAppRefine(
        name: str(args, 'name'),
        instruction: str(args, 'instruction'),
      ),
    );
    addWorkspaceTool(
      'hotapp_inspect',
      'Read one hot app: title, renderer, original brief and payload size.',
      const <String, dynamic>{
        'name': {'type': 'string'},
      },
      const <String>['name'],
      (args) => workspace.hotAppInspect(str(args, 'name')),
    );
    addWorkspaceTool(
      'hotapp_from_prototype',
      'Generate a verifiable hot app FROM the current design prototype — the sanctioned '
          'design→hot-app link. Screens and navigation flows are extracted automatically '
          'from the prototype on the canvas; after generation a deterministic coverage '
          'check verifies every screen (data-screen) and every link (data-nav), so the '
          'result honestly reports verified=true or what is missing. Use it when the '
          'user wants a runnable app version of the prototype. Requires the canvas to '
          'have at least one real screen.',
      const <String, dynamic>{
        'name': {
          'type': 'string',
          'description': 'lowercase ASCII app name (a-z0-9_-); pick a fresh name, '
              'existing names are refused',
        },
      },
      const <String>['name'],
      (args) async {
        final bridge = ctx.bridge;
        if (bridge == null || ctx.mbt.trim().isEmpty) {
          return <String, dynamic>{
            'ok': false,
            'error': 'prototype_empty',
            'message': toolFailureMessage('prototype_empty'),
          };
        }
        final screens = <PrototypeScreenSpec>[];
        final flows = <PrototypeLinkSpec>[];
        try {
          final boards = await bridge.session(ctx.mbt, 'session_list_artboards');
          for (final board in _listOf(boards['data'])) {
            if (board is! Map) continue;
            final id = _s(board['id']);
            if (id.isEmpty || id == '__seed') continue;
            screens.add(PrototypeScreenSpec(id: id, title: _s(board['name'])));
          }
          final fs = await bridge.session(ctx.mbt, 'session_flows');
          for (final f in _listOf(fs['data'])) {
            if (f is! Map) continue;
            flows.add(PrototypeLinkSpec(from: _s(f['from']), to: _s(f['to'])));
          }
        } catch (error) {
          return <String, dynamic>{
            'ok': false,
            'error': 'engine_unavailable',
            'message': toolFailureMessage('engine_unavailable'),
            'detail': '$error',
          };
        }
        if (screens.isEmpty) {
          return <String, dynamic>{
            'ok': false,
            'error': 'prototype_empty',
            'message': toolFailureMessage('prototype_empty'),
          };
        }
        // 与 store 路径同一上限：超长原型只给摘要面，屏/跳转已结构化提取。
        final doc = ctx.mbt.length > 12000 ? ctx.mbt.substring(0, 12000) : ctx.mbt;
        return workspace.hotAppFromPrototype(
          name: str(args, 'name'),
          prototypeMbt: doc,
          screens: screens,
          flows: flows,
        );
      },
    );

    addWorkspaceTool(
      'video_list',
      'List every video project on this device: generated projects (builtin=false) plus '
          'the built-in samples (builtin=true with their sample index). Look before you '
          'create so you do not collide with an existing name.',
      const <String, dynamic>{},
      const <String>[],
      (_) => workspace.videoList(),
    );
    addWorkspaceTool(
      'video_sample',
      'Return one built-in video sample as the FULL timeline + spec JSON — the '
          'authoritative format reference for a code-driven animation (scenes, elements, '
          'formula-driven coordinates, spec kind/params/beats). Call it before you '
          'video_create; index is 0-based (default 0).',
      const <String, dynamic>{
        'index': {
          'type': 'integer',
          'description': '0-based built-in sample index (default 0)',
        },
      },
      const <String>[],
      (args) {
        final raw = args['index'];
        final index = raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '') ?? 0;
        return workspace.videoSample(index: index);
      },
    );
    addWorkspaceTool(
      'video_create',
      'Create a code-driven animation project from a timeline script + spec. The document '
          'is pre-validated (spec kinds, declared symbols, formulas, frame count) BEFORE '
          'anything is written to disk; on success the project is saved under the video '
          'workspace and plays live. name is ASCII a-z0-9_- and must be new (existing '
          'videos are never overwritten); title is optional. There is no video-file export.',
      const <String, dynamic>{
        'name': {
          'type': 'string',
          'description': 'ASCII project name (a-z0-9_-), must be unique',
        },
        'timeline': {
          'type': 'object',
          'description': 'Timeline script: fps/width/height/background + scenes[] '
              'with elements[] (rect/arrow/line/polyline/text/path …)',
        },
        'spec': {
          'type': 'object',
          'description': 'Spec: kind science (subject/laws/assumptions/facts/params/'
              'formulas) or screenplay (style/beats/params/formulas)',
        },
        'title': {
          'type': 'string',
          'description': 'Human-readable title shown in the video workspace',
        },
      },
      const <String>['name', 'timeline'],
      (args) {
        final timeline = args['timeline'];
        final spec = args['spec'];
        if (timeline is! Map) {
          return Future.value(<String, dynamic>{
            'ok': false,
            'error': 'invalid_args',
            'message': '时间线格式不对：先看一份完整示例，再按同样结构填写',
          });
        }
        if (spec != null && spec is! Map) {
          return Future.value(<String, dynamic>{
            'ok': false,
            'error': 'invalid_args',
            'message': '说明规范格式不对：先看一份完整示例，再按同样结构填写',
          });
        }
        return workspace.videoCreate(
          name: str(args, 'name'),
          timeline: Map<String, dynamic>.from(timeline),
          spec: spec is Map ? Map<String, dynamic>.from(spec) : null,
          title: str(args, 'title'),
        );
      },
    );
    addWorkspaceTool(
      'video_review',
      'Mechanical review of a video timeline against its spec (timing, formulas, '
          'declared symbols). Timeline and spec are JSON objects; no rendering.',
      const <String, dynamic>{
        'timeline': {'type': 'object'},
        'spec': {'type': 'object'},
      },
      const <String>['timeline'],
      (args) {
        final timeline = args['timeline'];
        if (timeline is! Map) {
          return Future.value(<String, dynamic>{
            'ok': false,
            'error': 'invalid_args',
            'message': toolFailureMessage('invalid_args'),
          });
        }
        final spec = args['spec'];
        return workspace.videoReview(
          timeline: Map<String, dynamic>.from(timeline),
          spec: spec is Map ? Map<String, dynamic>.from(spec) : null,
        );
      },
    );
    addWorkspaceTool(
      'video_render',
      'Legacy export entry. Video is code-driven animation played live in the workspace; '
          'exporting a video file is disabled, so this returns a plain explanation.',
      const <String, dynamic>{
        'timeline': {'type': 'object'},
        'spec': {'type': 'object'},
      },
      const <String>['timeline'],
      (args) {
        final timeline = args['timeline'];
        if (timeline is! Map) {
          return Future.value(<String, dynamic>{
            'ok': false,
            'error': 'invalid_args',
            'message': toolFailureMessage('invalid_args'),
          });
        }
        final spec = args['spec'];
        return workspace.videoRender(
          timeline: Map<String, dynamic>.from(timeline),
          spec: spec is Map ? Map<String, dynamic>.from(spec) : null,
        );
      },
    );

    addWorkspaceTool(
      'nonapp_list',
      'List installed app packages (imported or generated) on this device.',
      const <String, dynamic>{},
      const <String>[],
      (_) => workspace.nonAppList(),
    );
    addWorkspaceTool(
      'nonapp_inspect',
      'Read one app package: title, renderer, original brief and payload size.',
      const <String, dynamic>{
        'name': {'type': 'string'},
      },
      const <String>['name'],
      (args) => workspace.nonAppInspect(str(args, 'name')),
    );

    addWorkspaceTool(
      'figma_export',
      'Export every artboard of the current design as a Figma import package: one SVG '
          'per board plus a node manifest, written to a folder on this device.',
      const <String, dynamic>{
        'directory': {
          'type': 'string',
          'description': 'Absolute folder path to write the package into',
        },
      },
      const <String>['directory'],
      (args) async {
        final candidate = ctx.bridge;
        EngineRenderBridge? renderer;
        if (candidate is EngineRenderBridge) renderer = candidate as EngineRenderBridge;
        if (renderer == null) {
          return <String, dynamic>{
            'ok': false,
            'error': 'figma_unavailable',
            'message': toolFailureMessage('figma_unavailable'),
          };
        }
        final envelope = await renderer.render(ctx.mbt);
        final render = RenderEnvelope.fromJson(envelope);
        return workspace.figmaExport(
          render: render,
          directory: str(args, 'directory'),
        );
      },
    );
  }

  // workspace 模式（3D / 视频 / 热应用）只暴露工作区工具与 ask_user：
  // 画布/文档工具在这里没有意义，暴露出去只会让模型写 PRD 或改画布。
  if (ctx.request.mode == 'workspace') {
    for (final name in const <String>[
      'write_doc',
      'write_design_spec',
      'design_op',
      'generate_page',
      'read_mbt',
      'inspect',
    ]) {
      tools.remove(name);
    }
  }

  return tools;
}
