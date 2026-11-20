// StreamToolNameGuard 回归锚点（StepFun step_plan 方言）。
//
// 线上证据（2026-11-20 抓包）：step-5-preview 流式工具调用只在首个 delta 带
// `function.name`，后续 delta 重复 `name: ""`；ai_sdk_openai_compatible 3.1.0
// 逐 delta 覆盖后以空名发出 StreamPartToolCall → AiNoSuchToolError 打死整轮
// agent run。本测试锁定：守护把空名回填为该工具流的首个非空名，其余原样透传。
//
// ai_sdk_provider 是 ai_sdk_dart 的传递依赖（pubspec 未声明）；流片段类型
// 与 test/dart_agent_test.dart 同一处理方式。
import 'dart:async';

import 'package:ai_sdk_dart/ai_sdk_dart.dart';
// ignore: depend_on_referenced_packages
import 'package:ai_sdk_provider/ai_sdk_provider.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/agent_model_middleware.dart';

/// 按脚本原样放流的假模型（不做任何工具名加工）。
class _RawStreamModel extends LanguageModelV4 {
  _RawStreamModel(this.parts);

  final List<LanguageModelV4StreamPart> parts;

  @override
  String get provider => 'raw-stream';

  @override
  String get modelId => 'raw-stream-model';

  @override
  String get specificationVersion => 'v4';

  @override
  Future<LanguageModelV4GenerateResult> doGenerate(
    LanguageModelV4CallOptions options,
  ) async {
    throw UnimplementedError('generate not exercised here');
  }

  @override
  Future<LanguageModelV4StreamResult> doStream(
    LanguageModelV4CallOptions options,
  ) async {
    final controller = StreamController<LanguageModelV4StreamPart>();
    for (final part in parts) {
      controller.add(part);
    }
    unawaited(controller.close());
    return LanguageModelV4StreamResult(stream: controller.stream);
  }
}

LanguageModelV4StreamPart _finish() => StreamPartFinish(
      finishReason: LanguageModelV4FinishReason.toolCalls,
      rawFinishReason: 'tool_calls',
    );

LanguageModelV4CallOptions _options() => LanguageModelV4CallOptions(
      prompt: LanguageModelV4Prompt(messages: const []),
    );

void main() {
  test('StepFun 方言：首 delta 带名、后续 name:""，空名被回填为首个非空名',
      () async {
    final model = wrapLanguageModel(
      model: _RawStreamModel([
        StreamPartToolInputStart(id: 'tool-0', toolName: 'write_doc'),
        StreamPartToolInputDelta(id: 'tool-0', delta: '{"kind"'),
        // StepFun 后续 delta 的形状：name 为空串（非缺省）。
        StreamPartToolInputDelta(id: 'tool-0', delta: ':"prd"}'),
        StreamPartToolCall(
          toolCall: LanguageModelV4ToolCallPart(
            toolCallId: 'tool-0',
            toolName: '',
            input: const {'kind': 'prd'},
          ),
        ),
        _finish(),
      ]),
      middleware: const StreamToolNameGuard(),
    );

    final result = await model.doStream(_options());
    final emitted = await result.stream.toList();

    final calls = emitted.whereType<StreamPartToolCall>().toList();
    expect(calls, hasLength(1));
    expect(calls.single.toolCall.toolCallId, 'tool-0');
    // 关键断言：空名被回填，run 不再死于 AiNoSuchToolError。
    expect(calls.single.toolCall.toolName, 'write_doc');
    expect(calls.single.toolCall.input, const {'kind': 'prd'});
  });

  test('多工具并发流：各自按 id 回填，互不串名', () async {
    final model = wrapLanguageModel(
      model: _RawStreamModel([
        StreamPartToolInputStart(id: 'tool-0', toolName: 'write_doc'),
        StreamPartToolInputStart(id: 'tool-1', toolName: 'write_design_spec'),
        StreamPartToolCall(
          toolCall: LanguageModelV4ToolCallPart(
            toolCallId: 'tool-1',
            toolName: '',
            input: const {},
          ),
        ),
        StreamPartToolCall(
          toolCall: LanguageModelV4ToolCallPart(
            toolCallId: 'tool-0',
            toolName: '',
            input: const {},
          ),
        ),
        _finish(),
      ]),
      middleware: const StreamToolNameGuard(),
    );

    final result = await model.doStream(_options());
    final emitted = await result.stream.toList();

    final byId = <String, String>{
      for (final part in emitted.whereType<StreamPartToolCall>())
        part.toolCall.toolCallId: part.toolCall.toolName,
    };
    expect(byId['tool-0'], 'write_doc');
    expect(byId['tool-1'], 'write_design_spec');
  });

  test('正常方言（无空名）原样透传，不做任何改写', () async {
    final model = wrapLanguageModel(
      model: _RawStreamModel([
        StreamPartToolInputStart(id: 'tool-0', toolName: 'finish'),
        StreamPartToolCall(
          toolCall: LanguageModelV4ToolCallPart(
            toolCallId: 'tool-0',
            toolName: 'finish',
            input: const {},
          ),
        ),
        StreamPartFinish(finishReason: LanguageModelV4FinishReason.stop),
      ]),
      middleware: const StreamToolNameGuard(),
    );

    final result = await model.doStream(_options());
    final emitted = await result.stream.toList();

    final calls = emitted.whereType<StreamPartToolCall>().toList();
    expect(calls.single.toolCall.toolName, 'finish');
    // InputStart 原样保留。
    expect(
      emitted.whereType<StreamPartToolInputStart>().single.toolName,
      'finish',
    );
  });

  test('模型笔误（finwork → finish）近名修复：InputStart 与 ToolCall 一致改写',
      () async {
    final model = wrapLanguageModel(
      model: _RawStreamModel([
        const StreamPartToolInputStart(id: 'tool-0', toolName: 'finwork'),
        const StreamPartToolCall(
          toolCall: LanguageModelV4ToolCallPart(
            toolCallId: 'tool-0',
            toolName: 'finwork',
            input: {'summary': '完成'},
          ),
        ),
        _finish(),
      ]),
      middleware: StreamToolNameGuard(
        knownTools: const {'write_doc', 'write_design_spec', 'finish'},
      ),
    );

    final result = await model.doStream(_options());
    final emitted = await result.stream.toList();

    expect(
      emitted.whereType<StreamPartToolInputStart>().single.toolName,
      'finish',
    );
    expect(
      emitted.whereType<StreamPartToolCall>().single.toolCall.toolName,
      'finish',
      reason: '一次模型手滑不该打死整轮 run',
    );
  });

  test('可信度不足的未知工具名不乱修（宁可不修不可修错）', () async {
    final model = wrapLanguageModel(
      model: _RawStreamModel([
        const StreamPartToolInputStart(id: 'tool-0', toolName: 'zzzzzz'),
        const StreamPartToolCall(
          toolCall: LanguageModelV4ToolCallPart(
            toolCallId: 'tool-0',
            toolName: 'zzzzzz',
            input: {},
          ),
        ),
        _finish(),
      ]),
      middleware: StreamToolNameGuard(
        knownTools: const {'write_doc', 'finish'},
      ),
    );

    final result = await model.doStream(_options());
    final emitted = await result.stream.toList();

    // zzzzzz 与任何已知名都不可信地接近：原样保留，交由 SDK 抛错并按
    // llm_no_such_tool 映射人话文案。
    expect(
      emitted.whereType<StreamPartToolCall>().single.toolCall.toolName,
      'zzzzzz',
    );
  });

  group('工具名变体修复（namespace / 调用语法 / 全角 / 大小写 / 连字符）', () {
    const known = <String>{
      'write_doc',
      'write_design_spec',
      'finish',
      'video_create',
      'three_list',
    };
    const guard = StreamToolNameGuard(knownTools: known);

    test('namespace.tool 取末段；tool() / 结尾冒号 / 前后空白归一', () {
      expect(guard.repairToolName('mcp.video_create'), 'video_create');
      expect(guard.repairToolName('builtin.finish'), 'finish');
      expect(guard.repairToolName('finish()'), 'finish');
      expect(guard.repairToolName('video_create({"name":"x"})'), 'video_create');
      expect(guard.repairToolName('finish:'), 'finish');
      expect(guard.repairToolName('  finish  '), 'finish');
    });

    test('全角 / 大小写 / 连字符 / 点号变体 → 规范名', () {
      expect(guard.repairToolName('ｗｒｉｔｅ＿ｄｏｃ'), 'write_doc');
      expect(guard.repairToolName('Write_Doc'), 'write_doc');
      expect(guard.repairToolName('VIDEO-CREATE'), 'video_create');
      expect(guard.repairToolName('write.doc'), 'write_doc');
      expect(guard.repairToolName('three list'), 'three_list');
    });

    test('已知名本身不误改（大小写完全一致的规范名返回 null）', () {
      expect(guard.repairToolName('finish'), isNull);
      expect(guard.repairToolName('write_design_spec'), isNull);
      expect(guard.repairToolName('video_create'), isNull);
    });

    test('歧义等距 / 公共前缀不足的未知名不乱修（宁可不修不可修错）', () {
      const ambiguous = StreamToolNameGuard(
        knownTools: {'three_pass', 'three_past'},
      );
      expect(
        ambiguous.repairToolName('three_pazz'),
        isNull,
        reason: '到 three_pass / three_past 距离等距 → 二义，不修',
      );
      expect(
        guard.repairToolName('inish'),
        isNull,
        reason: '与 finish 公共前缀 0 → 不像笔误，不修',
      );
      expect(guard.repairToolName('totally_unrelated'), isNull);
    });

    test('流式 InputStart 与 ToolCall 上的变体名一致改写', () async {
      final model = wrapLanguageModel(
        model: _RawStreamModel([
          const StreamPartToolInputStart(id: 'tool-0', toolName: 'builtin.finish'),
          const StreamPartToolCall(
            toolCall: LanguageModelV4ToolCallPart(
              toolCallId: 'tool-0',
              toolName: 'builtin.finish',
              input: {'summary': '完成'},
            ),
          ),
          _finish(),
        ]),
        middleware: const StreamToolNameGuard(knownTools: {'finish'}),
      );

      final result = await model.doStream(_options());
      final emitted = await result.stream.toList();

      expect(
        emitted.whereType<StreamPartToolInputStart>().single.toolName,
        'finish',
      );
      expect(
        emitted.whereType<StreamPartToolCall>().single.toolCall.toolName,
        'finish',
      );
    });
  });
}
