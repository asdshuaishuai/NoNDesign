// agent 自等待重试 + LLM 错误分类 回归锚点。
//
// 场景（2026-11-20 线上实锤）：StepFun 限流/网关抖动/推理超时会把整轮 run
// 直接打死，用户只看到「这次操作没有成功，请重试」。修复后：瞬时故障由
// agent 按退避等待自动重试（交付水位前移则不重试，避免重复执行已生效的
// 工具）；错误码分类后映射成人话文案，原始异常只进折叠的技术详情。
//
import 'dart:async';

import 'package:genkit/genkit.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/genkit_test_model.dart';

import 'package:nondesign/core/dart_agent.dart';

/// 逐步骤脚本模型：步骤是内容部件列表（正常放流）或异常对象（抛出——
/// genkit 把 fn 抛出的异常收敛为 finishReason: failed + cause）。
class _FlakyScriptedModel {
  _FlakyScriptedModel(this.steps) {
    model = Model<dynamic>(
      name: 'flaky/flaky-scripted-model',
      fn: (ModelRequest req,
              ActionFnArg<ModelResponseChunk, ModelRequest, void> ctx) async {
        // 每次调用实际收到的用户消息（校验重试轮提示词用）。
        calls.add(req);
        prompts.add(req.messages
            .where((m) => m.role == Role.user)
            .expand((m) => m.content.where((p) => p.isText))
            .map((p) => p.text ?? '')
            .join('\n'));
        final i = stepsTaken;
        stepsTaken++;
        final step = i < steps.length
              ? steps[i]
              : <Part>[scriptText('done')];
        if (step is! List<Part>) {
          throw step;
        }
        for (final part in step) {
          if (part is ToolRequestPart) continue;
          ctx.sendChunk(ModelResponseChunk(content: [part], role: Role.model));
        }
        return ModelResponse(
          message: Message(role: Role.model, content: step),
          finishReason: FinishReason.stop,
        );
      },
    );
  }

  final List<Object> steps;
  int stepsTaken = 0;

  /// 每次模型调用实际收到的用户 prompt（校验重试轮提示词用）。
  final List<String> prompts = <String>[];

  /// 每次调用的完整参数（校验工具面用）。
  final List<ModelRequest> calls = <ModelRequest>[];

  late final Model<dynamic> model;
}

DartAgentRequest _req({String mode = 'workspace', String hint = 'auto'}) =>
      DartAgentRequest(
        mode: mode,
        instruction: '做一个记账 App',
        model: 'flaky-scripted-model',
        baseUrl: 'https://example.invalid/v1',
        apiKey: 'k',
        docs: const {},
        workspaceHint: mode == 'workspace' ? hint : '',
      );

void main() {
  setUp(() => debugRetryWaitsOverride = <int>[0]);
  tearDown(() => debugRetryWaitsOverride = null);

  group('classifyLlmError / isRetryableLlmError', () {
    test('带 statusCode 的 API 错误 → llm_http_<status>', () {
      // genkit：HTTP 等价码经 GenkitException.status.httpStatus 提供
      // （resourceExhausted→429、unauthenticated→401）。
      expect(
        classifyLlmError(
            GenkitException('rate limited', status: StatusCode.resourceExhausted)),
        'llm_http_429',
      );
      expect(
        classifyLlmError(
            GenkitException('no key', status: StatusCode.unauthenticated)),
        'llm_http_401',
      );
    });

    test('TimeoutException → llm_timeout；无 statusCode 的传输错误 → llm_network',
        () {
      expect(classifyLlmError(TimeoutException('deadline')), 'llm_timeout');
      expect(
        classifyLlmError(Exception(
            'DioException [connection timeout]: The request connection took longer than 0:00:05')),
        'llm_network',
      );
    });

    test('重试白名单：网络/超时/429/5xx 可重试，401/400/未知不可', () {
      expect(isRetryableLlmError('llm_timeout'), isTrue);
      expect(isRetryableLlmError('llm_network'), isTrue);
      expect(isRetryableLlmError('llm_http_429'), isTrue);
      expect(isRetryableLlmError('llm_http_503'), isTrue);
      expect(isRetryableLlmError('llm_http_401'), isFalse);
      expect(isRetryableLlmError('llm_http_400'), isFalse);
      expect(isRetryableLlmError('AiNoSuchToolError: x'), isFalse);
    });
  });

  group('toolFailureMessage（LLM 分类码人话）', () {
    test('HTTP 状态分档', () {
      expect(toolFailureMessage('llm_http_401'), contains('API Key'));
      expect(toolFailureMessage('llm_http_429'), contains('正忙'));
      expect(toolFailureMessage('llm_http_503'), contains('暂时不可用'));
      expect(toolFailureMessage('llm_http_400'), contains('没有响应'));
    });
    test('超时 / 网络 / 工具名异常', () {
      expect(toolFailureMessage('llm_timeout'), contains('耗时过长'));
      expect(toolFailureMessage('llm_network'), contains('网络'));
      expect(toolFailureMessage('llm_no_such_tool'), contains('不可用的操作'));
    });
  });

  group('runDartAgent 自等待重试', () {
    test('瞬时 503：等待后重试成功，事件里出现「NaN 等待重试」', () async {
      final events = <Map<String, dynamic>>[];
      final model = _FlakyScriptedModel([
        GenkitException('gateway boom', status: StatusCode.unavailable), // → 503
        [scriptText('done')],
        [scriptText('done')], // nudge 轮
      ]);
      final result = await runDartAgent(
        request: _req(),
        modelOverride: model.model,
        onEvent: events.add,
      );
      expect(result.ok, isTrue, reason: '重试后正常完成');
      expect(events.any((e) => e['label'] == 'NaN 等待重试'), isTrue);
      expect(model.stepsTaken, 3, reason: '失败 1 次 + 成功 1 次 + nudge 1 次');
    });

    test('交付水位前移后断线：带进度续跑而不是判死（已完成内容保留）', () async {
      final events = <Map<String, dynamic>>[];
      final model = _FlakyScriptedModel([
        [scriptToolCall(toolName: 'write_doc', input: {'kind': 'prd', 'content': '# PRD'})],
        GenkitException('gateway boom', status: StatusCode.unavailable), // → 503
        [scriptText('done')],
        [scriptText('done')],
      ]);
      final result = await runDartAgent(
        request: _req(mode: 'plan'),
        modelOverride: model.model,
        onEvent: events.add,
      );
      // 已交付后不改判死：断线续跑，带着已写文档继续。
      expect(events.any((e) => e['label'] == 'NaN 断线续跑'), isTrue);
      expect(model.stepsTaken, greaterThanOrEqualTo(3));
      expect(result.docs['prd'], '# PRD', reason: '已完成内容必须保留');
    });

    test('连续失败 10 次重试后放弃（不是无限重试）', () async {
      final events = <Map<String, dynamic>>[];
      final model = _FlakyScriptedModel([
        for (var i = 0; i < 12; i++) TimeoutException('deadline'),
      ]);
      final result = await runDartAgent(
        request: _req(),
        modelOverride: model.model,
        onEvent: events.add,
      );
      expect(result.ok, isFalse);
      expect(result.stopReason, 'failed');
      expect(model.stepsTaken, llmRetryMaxRetries + 1,
          reason: '首轮 + 10 次重试后必须收敛');
      expect(events.any((e) => e['label'] == 'NaN 等待重试'), isTrue);
      final failed = events.lastWhere((e) => e['type'] == 'failed');
      expect(failed['message'], contains('耗时过长'));
    });

    test('工具名拼错（llm_no_such_tool）：重试轮 prompt 追加可用工具清单', () async {
      final events = <Map<String, dynamic>>[];
      final model = _FlakyScriptedModel(<Object>[
        // 模型捏造了不存在的工具名 → SDK 抛 AiNoSuchToolError（线上曾把整轮打死）。
        <Part>[
          scriptToolCall(toolName: 'write_docx', input: <String, dynamic>{'kind': 'prd'}),
        ],
        <Part>[
          scriptToolCall(
            toolName: 'write_doc',
            input: <String, dynamic>{'kind': 'prd', 'content': '# PRD'},
          ),
        ],
        <Part>[
          scriptToolCall(
            toolName: 'write_doc',
            input: <String, dynamic>{'kind': 'ui', 'content': '# UI'},
          ),
        ],
        <Part>[
          scriptToolCall(
            toolName: 'write_design_spec',
            input: <String, dynamic>{
              'palette': <String, dynamic>{'primary': '#3366FF'},
              'typography': <String, dynamic>{'base': 14},
              'spacing': <num>[4, 8, 16],
              'radius': <String, dynamic>{'sm': 4},
            },
          ),
        ],
        <Part>[
          scriptToolCall(toolName: 'finish', input: <String, dynamic>{'summary': '完成'}),
        ],
      ]);
      final result = await runDartAgent(
        request: _req(mode: 'build'),
        modelOverride: model.model,
        onEvent: events.add,
      );
      expect(result.ok, isTrue);
      expect(events.any((e) => e['label'] == 'NaN 等待重试'), isTrue);
      expect(model.prompts.length, greaterThanOrEqualTo(2));
      // 重试轮不是原样重发：明确给出本轮可用工具名，让模型从清单里挑。
      expect(model.prompts[1], contains('Available tools:'));
      expect(model.prompts[1], contains('write_doc'));
      expect(model.prompts[1], contains('finish'));
      expect(model.prompts[1], contains('do not invent names'));
      expect(model.prompts[1], isNot(equals(model.prompts[0])));
    });
  });
group('ask_user 与常规 agent 循环一致（用户裁决变更 2026-11-20）', () {
  test('workspace + 明确 hint：ask_user 仍可用，答题卡照常产出（不再拒答）', () async {
    final events = <Map<String, dynamic>>[];
    final model = _FlakyScriptedModel(<Object>[
      <Part>[
        scriptToolCall(
          toolName: 'ask_user',
          input: <String, dynamic>{
            'question': '这一段用什么风格？',
            'options': <String>['纪实', '卡通'],
          },
        ),
      ],
      <Part>[
        scriptToolCall(toolName: 'finish', input: <String, dynamic>{'summary': '等你选'}),
      ],
    ]);
    final result = await runDartAgent(
      request: _req(mode: 'workspace', hint: 'video'),
      modelOverride: model.model,
      onEvent: events.add,
    );
    expect(result.ok, isTrue);
    final toolNames = (model.calls.first.tools ?? const <ToolDefinition>[])
        .map((t) => t.name)
        .toSet();
    expect(toolNames, contains('ask_user'), reason: '钉死工作台也暴露 ask_user');
    final a2ui = events.firstWhere((e) => e['type'] == 'a2ui');
    expect(a2ui['text'], '这一段用什么风格？');
    final toolEnd = events.firstWhere(
      (e) => e['type'] == 'tool_end' && e['tool'] == 'ask_user',
    );
    expect(toolEnd['ok'], isTrue);
    expect(toolEnd['error'], isNull);
    expect(
      events.any((e) => e['error'] == 'ask_user_unavailable'),
      isFalse,
      reason: '「钉死工作台就拒答」的死路已删除',
    );
  });

  test('workspace + 明确 hint：真要换工作台时 switch_to 随答题卡透传', () async {
    final events = <Map<String, dynamic>>[];
    final model = _FlakyScriptedModel(<Object>[
      <Part>[
        scriptToolCall(
          toolName: 'ask_user',
          input: <String, dynamic>{
            'question': '这个需求更像交互应用，要去热应用工作台吗？',
            'options': <String>['去热应用', '留在这里'],
            'switch_to': 'hotapp',
          },
        ),
      ],
      <Part>[
        scriptToolCall(toolName: 'finish', input: <String, dynamic>{'summary': '等你选'}),
      ],
    ]);
    final result = await runDartAgent(
      request: _req(mode: 'workspace', hint: 'video'),
      modelOverride: model.model,
      onEvent: events.add,
    );
    expect(result.ok, isTrue);
    final a2ui = events.firstWhere((e) => e['type'] == 'a2ui');
    // store 侧 handleChatAction 消费 switch_to 后真正切工作台 + 续跑；
    // 循环只负责把用户的选择原样透传，不改写。
    expect(a2ui['switch_to'], 'hotapp');
    final toolEnd = events.firstWhere(
      (e) => e['type'] == 'tool_end' && e['tool'] == 'ask_user',
    );
    expect(toolEnd['ok'], isTrue);
  });

  test('workspace + auto：ask_user 保留（内容决策仍有价值）', () async {
    final events = <Map<String, dynamic>>[];
    final model = _FlakyScriptedModel(<Object>[
      <Part>[
        scriptToolCall(toolName: 'ask_user', input: <String, dynamic>{'question': '布局？', 'options': ['左右', '上下']}),
      ],
      <Part>[
        scriptToolCall(toolName: 'finish', input: <String, dynamic>{'summary': '等你选'}),
      ],
    ]);
    final result = await runDartAgent(
      request: _req(mode: 'workspace', hint: 'auto'),
      modelOverride: model.model,
      onEvent: events.add,
    );
    expect(result.ok, isTrue);
    final toolEnd = events.firstWhere((e) => e['type'] == 'tool_end' && e['tool'] == 'ask_user');
    expect(toolEnd['ok'], isTrue);
  });
});
}

