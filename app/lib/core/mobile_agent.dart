import 'dart:convert';

import 'package:ai_sdk_dart/ai_sdk_dart.dart';
import 'package:ai_sdk_openai/ai_sdk_openai.dart';

/// 移动端 PLAN 直连循环（Dart AI SDK）：手机客户端无 Python 服务器时，
/// 用 ai_sdk_dart 直连 LLM 独立产出 PRD/UI 文档（write_doc 工具语义与
/// server/agent.py 的 PLAN 阶段对齐）。设计/画布仍需连接桌面服务器
/// （引擎 MoonViz 无法在移动端运行）。
///
/// 边界（诚实声明）：SDK 的工具参数不暴露流式增量——本循环为事件式
/// （步骤 note + 完成回调），无逐字直播；RSI review 轮依赖引擎，不在
/// 移动直连范围。
class MobilePlanResult {
  const MobilePlanResult({
    required this.prd,
    required this.ui,
    required this.steps,
    required this.notes,
  });

  final String prd;
  final String ui;
  final int steps;
  final List<String> notes;

  bool get ok => prd.trim().isNotEmpty;
}

/// PLAN 直连：一句话 → PRD + UI 说明（两份 write_doc，doc_not_written 语义同服）。
/// [abortSignal]/[timeout] 透传 ai_sdk_dart：移动端无服务器取消端点，
/// 只能靠本地 token 中断在飞请求。
Future<MobilePlanResult> runMobilePlan({
  required String instruction,
  required String model,
  required String baseUrl,
  required String apiKey,
  void Function(String note)? onNote,
  int maxSteps = 12,
  CancellationToken? abortSignal,
  Duration? timeout,
}) async {
  String? prd;
  String? ui;
  final notes = <String>[];
  void note(String m) {
    notes.add(m);
    onNote?.call(m);
  }

  final writeDoc = tool(
    description:
        'Write a design document. In PLAN mode write the PRD first, then the UI '
        'specification — both documents are required to finish.',
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
      final m = (input as Map).cast<String, dynamic>();
      final kind = (m['kind'] ?? '').toString();
      final content = (m['content'] ?? '').toString();
      if (kind == 'prd') {
        prd = content;
        note('PRD 已完成（${content.length} 字）');
      } else if (kind == 'ui') {
        ui = content;
        note('UI 说明已完成（${content.length} 字）');
      }
      return {'ok': true, 'kind': kind, 'chars': content.length};
    },
  );

  final provider = OpenAIProvider(apiKey: apiKey, baseUrl: baseUrl);
  try {
    final result = await streamText(
      model: provider.call(model),
      maxSteps: maxSteps,
      tools: {'write_doc': writeDoc},
      abortSignal: abortSignal,
      timeout: timeout == null ? null : TimeoutConfiguration(total: timeout),
      prompt:
          '你是 NoNDesign 的产品设计师。根据用户需求依次完成两份文档：\n'
          '1) write_doc(kind="prd")：产品需求文档（Markdown：目标用户、核心流程、功能列表、非目标）。\n'
          '2) write_doc(kind="ui")：UI 说明（每屏一句话职责 + 关键元素列表）。\n'
          '两份都写完即结束，不要输出多余散文。\n\n用户需求：$instruction',
    );
    await result.text; // 等循环结束（工具结果已在上面的 execute 里收集）
    if (prd == null && ui == null) {
      note('模型未调用 write_doc——无文档产出（doc_not_written 语义）');
    }
    return MobilePlanResult(prd: prd ?? '', ui: ui ?? '', steps: notes.length, notes: notes);
  } finally {
    provider.dispose();
  }
}

/// 恢复用：MobilePlanResult → Docs 形状的 JSON（与 server docs 字段对齐）。
Map<String, dynamic> mobilePlanToDocs(MobilePlanResult r) => {
      'prd': r.prd,
      'ui': r.ui,
      'design': '',
    };

/// 调试辅助：NDJSON 化 notes。
String mobilePlanNotesJson(MobilePlanResult r) =>
    jsonEncode(r.notes.map((n) => {'note': n}).toList());
