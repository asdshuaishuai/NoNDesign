// 诊断脚本（不进运行时）：完全照搬 runDartAgent 的 LLM 调用形状（genkit +
// genkit_openai 直连），复现「agent 执行异常结束」并抓原始异常。
// 用法：cd app && dart run tool/repro_agent_stream.dart [--timeout=SECONDS]
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:genkit_openai/genkit_openai.dart';
import 'package:schemantic/schemantic.dart';

Future<Map<String, dynamic>> _loadSettings() async {
  final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME']!;
  final f = File('$home/.nondesign/settings.json');
  return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
}

Future<void> main(List<String> args) async {
  final timeoutMin = int.parse(args
      .firstWhere((a) => a.startsWith('--timeout='), orElse: () => '--timeout=4')
      .split('=')[1]);
  final s = await _loadSettings();
  final baseUrl = (s['baseUrl'] as String?) ?? '';
  final model = (s['modelId'] as String?) ?? '';
  final apiKey = (s['apiKey'] as String?) ?? '';
  final thinking = (s['thinkingLevel'] as String?) ?? 'auto';
  stdout.writeln(
      'baseUrl=$baseUrl model=$model thinkingLevel=$thinking key=…${apiKey.substring(apiKey.length - 4)}');

  final ai = Genkit(plugins: [
    openAI(name: 'repro', apiKey: apiKey, baseUrl: baseUrl),
  ]);
  final controller = CancellationController();
  final timer = Timer(Duration(minutes: timeoutMin), () => controller.cancel('repro timeout'));

  // 与 dart_agent 的 providerThinkingOptions 同形（'auto' → null 不注入）。
  final effort = (thinking.isEmpty || thinking == 'auto') ? null : thinking;

  // 与 _buildTools 同形的最小工具面（原始 JSON schema 直通）。
  Tool<dynamic, dynamic> mk(String name, String description, Map<String, dynamic> jsonSchema) =>
      ai.defineTool<Map<String, dynamic>, Map<String, dynamic>>(
        name: name,
        description: description,
        inputSchema: SchemanticType.from<Map<String, dynamic>>(
          jsonSchema: jsonSchema,
          parse: (m) => (m as Map).cast<String, dynamic>(),
        ),
        fn: (input, _) async => ToolResult<Map<String, dynamic>>.response({'ok': true}),
      );

  final tools = <Tool<dynamic, dynamic>>[
    mk('write_doc', "Write or replace the product PRD (kind='prd') or per-screen UI "
        "spec (kind='ui'). Full markdown, real copy.", {
      'type': 'object',
      'properties': {
        'kind': {'type': 'string', 'enum': ['prd', 'ui']},
        'content': {'type': 'string'},
      },
      'required': ['kind', 'content'],
    }),
    mk('write_design_spec', 'Write the project design system.', {
      'type': 'object',
      'properties': {
        'spec': {'type': 'object'},
      },
      'required': ['spec'],
    }),
    mk('finish', 'Call when the task is complete.', {
      'type': 'object',
      'properties': {},
    }),
  ];

  var chunks = 0, textLen = 0, reasoningLen = 0, toolDeltas = 0;
  final sw = Stopwatch()..start();
  try {
    final result = await ai.generate<Map<String, dynamic>, dynamic>(
      model: openAI.model(model, namespace: 'repro'),
      prompt: "做一个SaaS 仪表盘：先写 PRD 与 UI 说明，再生成完整可交互原型。移动端优先，风格现代克制。\n"
          "MUST call write_doc(kind='prd'), write_doc(kind='ui'), "
          "write_design_spec, then finish. Do not reply with prose only.",
      maxTurns: 4,
      tools: tools,
      cancel: controller.token,
      config: effort == null ? null : OpenAIChatOptions(reasoningEffort: effort),
      onChunk: (chunk) {
        chunks++;
        for (final part in chunk.content) {
          if (part.isReasoning) {
            reasoningLen += (part.reasoningPart?.reasoning ?? '').length;
          } else if (part.isText) {
            textLen += (part.text ?? '').length;
          } else if (part.isToolRequest) {
            toolDeltas++;
          }
        }
        if (chunks == 1) {
          stdout.writeln(
              'first chunk at ${sw.elapsedMilliseconds}ms');
        }
      },
    );
    stdout.writeln(
        'OK in ${sw.elapsed}: chunks=$chunks text=$textLen reasoning=$reasoningLen '
        'toolDeltas=$toolDeltas finish=${result.finishReason.value}');
    final text = result.text;
    stdout.writeln(
        'text head: ${text.isEmpty ? '(empty)' : text.substring(0, text.length > 200 ? 200 : text.length)}');
    stdout.writeln(
        'turns(model messages)=${result.messages.where((m) => m.role == Role.model).length}');
  } catch (e, st) {
    stdout.writeln('EXCEPTION after ${sw.elapsed}: ${e.runtimeType}');
    stdout.writeln('toString: $e');
    stdout.writeln('stack head: ${st.toString().split('\n').take(8).join('\n')}');
  } finally {
    timer.cancel();
    exit(0);
  }
}
