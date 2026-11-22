// 诊断脚本（不进运行时）：完全照搬 runDartAgent 的 LLM 调用形状，
// 复现「agent 执行异常结束」并抓原始异常。
// 用法：cd app && dart run tool/repro_agent_stream.dart [--timeout=SECONDS]
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_sdk_dart/ai_sdk_dart.dart';
import 'package:ai_sdk_openai/ai_sdk_openai.dart';

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

  final provider = OpenAIProvider(apiKey: apiKey, baseUrl: baseUrl);

  final timeout =
      TimeoutConfiguration(total: Duration(minutes: timeoutMin));

  // 与 dart_agent 的 thinkingProviderOptions 同形（'auto' → null 不注入）。
  final effort = (thinking.isEmpty || thinking == 'auto') ? null : thinking;
  final providerOptions = effort == null
      ? null
      : <String, Map<String, dynamic>>{
          'openai': <String, dynamic>{'reasoning_effort': effort},
        };

  // 与 _buildTools 同形的最小工具面。
  final tools = <String, Tool<dynamic, dynamic>>{
    'write_doc': tool(
      description: "Write or replace the product PRD (kind='prd') or per-screen UI "
          "spec (kind='ui'). Full markdown, real copy.",
      inputSchema: Schema(
        jsonSchema: {
          'type': 'object',
          'properties': {
            'kind': {'type': 'string', 'enum': ['prd', 'ui']},
            'content': {'type': 'string'},
          },
          'required': ['kind', 'content'],
        },
        fromJson: (m) => m,
      ),
      execute: (input, _) async => {'ok': true},
    ),
    'write_design_spec': tool(
      description: 'Write the project design system.',
      inputSchema: Schema(
        jsonSchema: {
          'type': 'object',
          'properties': {
            'spec': {'type': 'object'},
          },
          'required': ['spec'],
        },
        fromJson: (m) => m,
      ),
      execute: (input, _) async => {'ok': true},
    ),
    'finish': tool(
      description: 'Call when the task is complete.',
      inputSchema: Schema(
        jsonSchema: {'type': 'object', 'properties': {}},
        fromJson: (m) => m,
      ),
      execute: (input, _) async => {'ok': true},
    ),
  };

  var chunks = 0, textLen = 0, reasoningLen = 0, toolDeltas = 0;
  final sw = Stopwatch()..start();
  try {
    final result = await streamText(
      model: provider.call(model),
      prompt: "做一个SaaS 仪表盘：先写 PRD 与 UI 说明，再生成完整可交互原型。移动端优先，风格现代克制。\n"
          "MUST call write_doc(kind='prd'), write_doc(kind='ui'), "
          "write_design_spec, then finish. Do not reply with prose only.",
      maxSteps: 4,
      tools: tools,
      timeout: timeout,
      providerOptions: providerOptions,
      onChunk: (chunk) {
        chunks++;
        if (chunk is StreamTextReasoningChunk) {
          reasoningLen += chunk.delta.length;
        } else if (chunk is StreamTextTextChunk) {
          textLen += chunk.text.length;
        } else if (chunk is StreamTextToolCallChunk) {
          toolDeltas++;
        }
        if (chunks == 1) {
          stdout.writeln(
              'first chunk at ${sw.elapsedMilliseconds}ms type=${chunk.runtimeType}');
        }
      },
    );
    final text = await result.text;
    final steps = await result.steps;
    stdout.writeln(
        'OK in ${sw.elapsed}: chunks=$chunks text=$textLen reasoning=$reasoningLen toolDeltas=$toolDeltas steps=${steps.length}');
    stdout.writeln(
        'text head: ${text.isEmpty ? '(empty)' : text.substring(0, text.length > 200 ? 200 : text.length)}');
    for (final st in steps) {
      stdout.writeln(
          'step: finish=${st.finishReason} toolCalls=${st.toolCalls.map((t) => t.toolName).toList()}');
    }
  } catch (e, st) {
    stdout.writeln('EXCEPTION after ${sw.elapsed}: ${e.runtimeType}');
    stdout.writeln('toString: $e');
    stdout.writeln('stack head: ${st.toString().split('\n').take(8).join('\n')}');
  } finally {
    provider.dispose();
    exit(0);
  }
}
