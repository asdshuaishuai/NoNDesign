// 内置 Dart 循环 P1 补齐的锚点测试（server/agent.py 三项能力的 Dart 移植）：
// - generate_page 工具（server agent.py:272-312）：仅非 plan 注册；spec 缺省取
//   ctx.designSpec；成功经 ctx.commit 推进 canonical 并发 page_generated；
//   桥不实现写接口 → generate_unavailable（不改文档）。
// - 收尾 RSI 环（server agent.py:652-700）：session_critique 的实参顺序
//   （mbt 第一位、board 在 arg 位——两参错位会让 RSI 静默退化）、poor →
//   session_auto_fix 一次/板/轮 + canonical 回灌、全 good 只发 note、最多 2 轮。
// - 空板清扫（server agent.py:732-762）：删 __seed 与 nodes<=1 的板、保留
//   entry、剩 1 板停手；cleanup 事件与 done.cleanup 一致。
// - PLAN 语义分歧（显式登记）：Dart 的 plan 模式不给引擎面，故清扫/RSI 零
//   session 调用（server 的清扫在 plan 也执行，agent.py:650 无 mode 守卫）。
//
// 桥替身自建（不引用 dart_agent_test 的私有 fake）：_RecordingBridge 同时
// 实现门与写接口，按调用序记录实参——RSI 的参数错位是本次最大的静默失效面。
import 'dart:convert';

import 'package:ai_sdk_dart/test.dart';
// ai_sdk_provider 是 ai_sdk_dart 的传递依赖（pubspec 未声明）；工具清单
// 断言需要其类型来读出 options.tools 的名字。
// ignore: depend_on_referenced_packages
import 'package:ai_sdk_provider/ai_sdk_provider.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/dart_agent.dart';

/// 多轮脚本化模型：每次 doStream 依序取下一步响应；脚本耗尽回纯文本
/// 'done'（防死循环）。
class _ScriptedModel extends MockLanguageModelV4 {
  final List<List<LanguageModelV4ContentPart>> script;
  int _i = 0;
  _ScriptedModel(this.script) : super(provider: 'scripted', modelId: 'scripted-model');

  @override
  Future<LanguageModelV4StreamResult> doStream(LanguageModelV4CallOptions options) async {
    streamCalls.add(options);
    final step = _i < script.length ? script[_i++] : <LanguageModelV4ContentPart>[mockText('done')];
    var seq = 0;
    String nextId() => 'id-${seq++}';
    final parts = <LanguageModelV4StreamPart>[const StreamPartStreamStart(warnings: [])];
    for (final part in step) {
      if (part is LanguageModelV4TextPart) {
        final id = nextId();
        parts.add(StreamPartTextStart(id: id));
        parts.add(StreamPartTextDelta(id: id, delta: part.text));
        parts.add(StreamPartTextEnd(id: id));
      } else if (part is LanguageModelV4ToolCallPart) {
        parts.add(StreamPartToolInputStart(id: part.toolCallId, toolName: part.toolName));
        parts.add(StreamPartToolInputDelta(id: part.toolCallId, delta: jsonEncode(part.input)));
        parts.add(StreamPartToolInputEnd(id: part.toolCallId));
        parts.add(StreamPartToolCall(toolCall: part));
      }
    }
    parts.add(const StreamPartFinish(
      finishReason: LanguageModelV4FinishReason.stop,
      rawFinishReason: 'stop',
    ));
    return LanguageModelV4StreamResult(stream: Stream.fromIterable(parts));
  }
}

/// 门 + 写接口的录制替身：session 调用按实参成对记录（name/arg/mbt），
/// 变更走 mutateSession（该接口就是 auto_fix 与 delete-artboard 的去路）。
class _RecordingBridge implements EngineGateBridge, EngineWriteBridge {
  String canonical;
  List<Map<String, dynamic>> boards;
  /// board id → 'poor' | 'good'（ critiques 按此回 verdict）。
  Map<String, String> verdicts;
  /// auto_fix 是否真的修好（false = 复评仍 poor，用于锚定「最多 2 轮」）。
  final bool autoFixFixes;

  final List<String> sessionMbts = [];
  final List<String> sessionNames = [];
  final List<String?> sessionArgs = [];
  final List<String> mutateMbts = [];
  final List<String> mutateNames = [];
  final List<String?> mutateArgs = [];
  final List<String> generateMbts = [];
  final List<String> generateIntents = [];
  final List<String> generateNames = [];
  final List<Map<String, dynamic>> generateSpecs = [];

  _RecordingBridge({
    this.canonical = '',
    List<Map<String, dynamic>>? boards,
    Map<String, String>? verdicts,
    this.autoFixFixes = true,
  })  : boards = List<Map<String, dynamic>>.from(boards ?? const []),
        verdicts = Map<String, String>.from(verdicts ?? const {});

  @override
  Future<Map<String, dynamic>> generate(
      String mbt, String intent, String name, Map<String, dynamic> spec) async {
    generateMbts.add(mbt);
    generateIntents.add(intent);
    generateNames.add(name);
    generateSpecs.add(spec);
    canonical = '$mbt\n<!-- generated: $intent -->';
    final artboard = name.isNotEmpty ? name : 'generated';
    if (!boards.any((b) => b['id'] == artboard)) {
      boards = [
        ...boards,
        {'id': artboard, 'nodes': 4},
      ];
    }
    return {
      'ok': true,
      'mbt': canonical,
      'artboard': artboard,
      'template': 'pc_app',
      'score': 92.5,
      'summary': '整屏生成完成',
    };
  }

  @override
  Future<Map<String, dynamic>> mutateSession(String mbt, String name, [String? arg]) async {
    mutateMbts.add(mbt);
    mutateNames.add(name);
    mutateArgs.add(arg);
    if (name == 'session_apply_agent') {
      final op = arg ?? '';
      if (op.startsWith('delete-artboard ')) {
        final bid = op.substring('delete-artboard '.length);
        boards = boards.where((b) => b['id'] != bid).toList();
        canonical = '$mbt\n<!-- deleted: $bid -->';
        return {'ok': true, 'mbt': canonical};
      }
      return {'ok': false, 'error': 'unsupported_op'};
    }
    if (name == 'session_auto_fix') {
      if (autoFixFixes && arg != null) verdicts[arg] = 'good';
      canonical = '$mbt\n<!-- fixed: $arg -->';
      return {'ok': true, 'mbt': canonical};
    }
    return {'ok': false, 'error': 'unknown_session_op'};
  }

  @override
  Future<Map<String, dynamic>> session(String mbt, String name, [String? arg]) async {
    sessionMbts.add(mbt);
    sessionNames.add(name);
    sessionArgs.add(arg);
    switch (name) {
      case 'session_list_artboards':
        return {
          'ok': true,
          'data': [
            for (final b in boards)
              {'id': b['id'], 'nodes': b['nodes'], 'width': 390, 'height': 844},
          ],
        };
      case 'session_flows':
        return {'ok': true, 'data': []};
      case 'session_query_nodes':
        return {'ok': true, 'data': []};
      case 'session_critique':
        final verdict = verdicts[arg ?? ''] ?? 'good';
        return {
          'ok': true,
          'data': {
            'results': [
              {
                'principle': 'contrast',
                'score': verdict == 'poor' ? 1 : 5,
                'verdict': verdict,
                'observation': 'x',
                'advice': '',
              },
            ],
          },
        };
    }
    return {'ok': true, 'data': []};
  }

  @override
  Future<Map<String, dynamic>> applyAgent(String mbt, String op) async {
    canonical = '$mbt\n<!-- applied: $op -->';
    return {'ok': true, 'mbt': canonical, 'op': op};
  }

  @override
  Future<List<dynamic>> templates() async => const [
        {'id': 'pc_app', 'name': 'PC App', 'device': 'pc'},
      ];

  @override
  Future<List<dynamic>> components() async => const ['button', 'text'];
}

/// 只实现门接口的桥（不支持 generate/mutate）：generate_page 必须诚实返回
/// generate_unavailable，且清扫/RSI 静默跳过（write == null）。
class _GateOnlyBridge implements EngineGateBridge {
  final List<String> sessionNames = [];

  @override
  Future<Map<String, dynamic>> applyAgent(String mbt, String op) async =>
      {'ok': true, 'mbt': '$mbt\n<!-- applied: $op -->', 'op': op};

  @override
  Future<Map<String, dynamic>> session(String mbt, String name, [String? arg]) async {
    sessionNames.add(name);
    if (name == 'session_list_artboards') {
      return {
        'ok': true,
        'data': [
          {'id': 'home', 'nodes': 3, 'width': 390, 'height': 844},
        ],
      };
    }
    return {'ok': true, 'data': []};
  }

  @override
  Future<List<dynamic>> templates() async => const [];

  @override
  Future<List<dynamic>> components() async => const [];
}

const String _mbt0 = '---\nrevision: 1\nentry: home\n---\n# doc';

DartAgentRequest _buildReq({
  String mbt = _mbt0,
  Map<String, dynamic> docs = const {},
}) =>
    DartAgentRequest(
      mode: 'build',
      instruction: '搭一个记账首页',
      mbt: mbt,
      docs: docs,
      model: 'scripted-model',
      baseUrl: 'https://example.invalid/v1',
      apiKey: 'k',
    );

DartAgentRequest _planReq() => const DartAgentRequest(
      mode: 'plan',
      instruction: '做一个记账 App',
      model: 'scripted-model',
      baseUrl: 'https://example.invalid/v1',
      apiKey: 'k',
    );

Set<String> _toolNames(MockLanguageModelV4 model) => model.streamCalls.first.tools
    .whereType<LanguageModelV4FunctionTool>()
    .map((t) => t.name)
    .toSet();

void main() {
  group('generate_page（server agent.py:272-312）', () {
    test('非 plan 注册、plan 不注册', () async {
      final build = _ScriptedModel([
        [mockToolCall(toolName: 'finish', input: {'summary': 'ok'})],
      ]);
      await runDartAgent(
        request: _buildReq(),
        modelOverride: build,
        bridge: _RecordingBridge(canonical: _mbt0),
        onEvent: (_) {},
      );
      final buildTools = _toolNames(build);
      expect(buildTools, contains('generate_page'));
      expect(buildTools, contains('design_op'));

      final plan = _ScriptedModel([
        [
          mockToolCall(toolName: 'write_doc', input: {'kind': 'prd', 'content': '# PRD'}),
          mockToolCall(toolName: 'write_doc', input: {'kind': 'ui', 'content': '## UI'}),
          mockToolCall(toolName: 'write_design_spec', input: {
            'palette': {'primary': '#3366FF'},
            'typography': {'h1': 30, 'h2': 22, 'body': 15},
            'spacing': [4, 8, 16],
            'radius': {'sm': 6, 'md': 10, 'lg': 14},
          }),
        ],
        [mockToolCall(toolName: 'finish', input: {'summary': '完成'})],
      ]);
      final planned = await runDartAgent(
        request: _planReq(),
        modelOverride: plan,
        bridge: _RecordingBridge(canonical: _mbt0),
        onEvent: (_) {},
      );
      expect(planned.ok, isTrue);
      final planTools = _toolNames(plan);
      expect(planTools, isNot(contains('generate_page')), reason: 'PLAN 无引擎面');
      expect(planTools, contains('write_doc'));
    });

    test('spec 缺省取 ctx.designSpec；canonical 前进 + page_generated 事件', () async {
      final bridge = _RecordingBridge(canonical: _mbt0);
      final events = <Map<String, dynamic>>[];
      final model = _ScriptedModel([
        [
          mockToolCall(toolName: 'generate_page', input: {
            'intent': '记账首页',
            'name': 'home',
          }),
        ],
        [mockToolCall(toolName: 'finish', input: {'summary': '首页生成'})],
      ]);
      final result = await runDartAgent(
        request: _buildReq(),
        modelOverride: model,
        bridge: bridge,
        onEvent: events.add,
      );

      expect(bridge.generateMbts.single, _mbt0, reason: 'mbt 在第一位');
      expect(bridge.generateIntents.single, '记账首页');
      expect(bridge.generateNames.single, 'home');
      // spec 缺省 = ctx.designSpec（design_for_agent 面：含 palette、无 rules/notes）。
      final spec = bridge.generateSpecs.single;
      expect(spec['palette'], isA<Map>());
      expect(spec.containsKey('rules'), isFalse);
      // 生成信封的 canonical 经 ctx.commit 采纳（ops 记账 + mbt 前进）。
      expect(result.mbt, allOf(contains('<!-- generated: 记账首页 -->'), contains('revision: 1')));
      expect(result.ops, contains('generate 记账首页'));
      expect(events.any((e) => e['type'] == 'tool_start' && e['tool'] == 'generate_page'), isTrue);
      final ends = events.where((e) => e['type'] == 'tool_end' && e['tool'] == 'generate_page').toList();
      expect(ends, hasLength(1));
      expect(ends.single['ok'], isTrue);
      final page = events.where((e) => e['type'] == 'page_generated').toList();
      expect(page, hasLength(1));
      expect(page.single['artboard'], 'home');
      expect(page.single['template'], 'pc_app');
      expect(page.single['score'], 92.5);
      expect(page.single['summary'], '整屏生成完成');
    });

    test('显式 spec 原样透传（不回落 ctx.designSpec）', () async {
      final bridge = _RecordingBridge(canonical: _mbt0);
      const explicit = <String, dynamic>{
        'v': 1,
        'palette': {'primary': '#123456'},
      };
      await runDartAgent(
        request: _buildReq(),
        modelOverride: _ScriptedModel([
          [
            mockToolCall(toolName: 'generate_page', input: {
              'intent': '设置页',
              'spec': explicit,
            }),
          ],
          [mockToolCall(toolName: 'finish', input: {'summary': 'ok'})],
        ]),
        bridge: bridge,
        onEvent: (_) {},
      );
      expect(bridge.generateSpecs.single, explicit);
      expect(bridge.generateNames.single, '', reason: 'name 可选，缺省空串（server name or ""）');
    });

    test('桥不实现写接口 → generate_unavailable，文档不变', () async {
      final gate = _GateOnlyBridge();
      final events = <Map<String, dynamic>>[];
      final result = await runDartAgent(
        request: _buildReq(),
        modelOverride: _ScriptedModel([
          [
            mockToolCall(toolName: 'generate_page', input: {'intent': 'x'}),
          ],
          [mockToolCall(toolName: 'finish', input: {'summary': 'done'})],
        ]),
        bridge: gate,
        onEvent: events.add,
      );
      expect(result.mbt, _mbt0);
      expect(events.any((e) => e['type'] == 'page_generated'), isFalse);
      final end = events.singleWhere((e) => e['type'] == 'tool_end' && e['tool'] == 'generate_page');
      expect(end['ok'], isFalse);
      expect(end['error'], 'generate_unavailable');
    });
  });

  group('RSI 收尾环（server agent.py:652-700）', () {
    test('session_critique 实参顺序（mbt 第一位、board 在 arg）+ poor → auto_fix 回灌',
        () async {
      final bridge = _RecordingBridge(
        canonical: _mbt0,
        boards: [
          {'id': 'home', 'nodes': 3},
        ],
        verdicts: {'home': 'poor'},
      );
      final events = <Map<String, dynamic>>[];
      final result = await runDartAgent(
        request: _buildReq(),
        modelOverride: _ScriptedModel([
          [
            mockToolCall(toolName: 'design_op', input: {'op': 'create home 390 844'}),
          ],
          [mockToolCall(toolName: 'finish', input: {'summary': '首页'})],
        ]),
        bridge: bridge,
        onEvent: events.add,
      );

      final ci = bridge.sessionNames.indexOf('session_critique');
      expect(ci, isNonNegative, reason: 'RSI 必须真的发起 critique');
      expect(bridge.sessionArgs[ci], 'home', reason: '板 id 在 arg 位');
      expect(bridge.sessionMbts[ci], isNotEmpty);
      expect(bridge.sessionMbts[ci], contains('revision: 1'),
          reason: 'mbt 在第一位（两参错位会把 name 当 canonical 发出去）');

      // 一板一轮一次 auto_fix；信封 canonical 回灌进终态。
      final fixes = bridge.mutateNames.where((n) => n == 'session_auto_fix').toList();
      expect(fixes, hasLength(1));
      final fi = bridge.mutateNames.indexOf('session_auto_fix');
      expect(bridge.mutateArgs[fi], 'home');
      expect(bridge.mutateMbts[fi], contains('<!-- applied: create home 390 844 -->'));
      expect(result.mbt, contains('<!-- fixed: home -->'));

      final round = events.where((e) => e['type'] == 'review_round').toList();
      expect(round, hasLength(1));
      expect(round.single['round'], 1);
      expect(round.single['detail'], contains('home · 1 处待改进'));
      expect(
        events.any((e) =>
            e['type'] == 'note' &&
            e['label'] == '修复轮' &&
            '${e['detail']}'.contains('自动优化')),
        isTrue,
      );
    });

    test('全 good → 只发一条质量审查 note，零 auto_fix', () async {
      final bridge = _RecordingBridge(
        canonical: _mbt0,
        boards: [
          {'id': 'home', 'nodes': 3},
        ],
      );
      final events = <Map<String, dynamic>>[];
      await runDartAgent(
        request: _buildReq(),
        modelOverride: _ScriptedModel([
          [mockToolCall(toolName: 'finish', input: {'summary': 'ok'})],
        ]),
        bridge: bridge,
        onEvent: events.add,
      );
      expect(events.any((e) => e['type'] == 'review_round'), isFalse);
      expect(bridge.mutateNames, isEmpty);
      final notes = events.where((e) => e['type'] == 'note' && e['label'] == '质量审查').toList();
      expect(notes, hasLength(1));
      expect(notes.single['detail'], contains('全部屏幕通过质量检查'));
    });

    test('最多 2 轮：auto_fix 未能修复时只跑两轮', () async {
      final bridge = _RecordingBridge(
        canonical: _mbt0,
        boards: [
          {'id': 'home', 'nodes': 3},
        ],
        verdicts: {'home': 'poor'},
        autoFixFixes: false,
      );
      final events = <Map<String, dynamic>>[];
      await runDartAgent(
        request: _buildReq(),
        modelOverride: _ScriptedModel([
          [mockToolCall(toolName: 'finish', input: {'summary': 'ok'})],
        ]),
        bridge: bridge,
        onEvent: events.add,
      );
      final rounds = events.where((e) => e['type'] == 'review_round').map((e) => e['round']).toList();
      expect(rounds, [1, 2]);
      expect(bridge.mutateNames.where((n) => n == 'session_auto_fix').length, 2);
    });
  });

  group('空板清扫（server agent.py:732-762）', () {
    test('删 __seed 与空板、保留 entry；cleanup 事件与 done.cleanup 一致', () async {
      final bridge = _RecordingBridge(
        canonical: _mbt0,
        boards: [
          {'id': 'home', 'nodes': 3},
          {'id': '__seed', 'nodes': 1},
          {'id': 'blank', 'nodes': 1},
          {'id': 'dead', 'nodes': 0},
        ],
      );
      final events = <Map<String, dynamic>>[];
      final result = await runDartAgent(
        request: _buildReq(),
        modelOverride: _ScriptedModel([
          [mockToolCall(toolName: 'finish', input: {'summary': 'ok'})],
        ]),
        bridge: bridge,
        onEvent: events.add,
      );

      final deletes = bridge.mutateNames.where((n) => n == 'session_apply_agent').toList();
      expect(deletes, hasLength(3));
      expect(
        bridge.mutateArgs.whereType<String>().toList(),
        ['delete-artboard __seed', 'delete-artboard blank', 'delete-artboard dead'],
        reason: 'entry(home) 永不删、按顺序逐板走门',
      );
      expect(result.mbt, allOf(contains('<!-- deleted: __seed -->'), contains('<!-- deleted: dead -->')));
      // entry 留在文档里（清扫目标里没有 home）。
      expect(bridge.boards.map((b) => b['id']).toList(), ['home']);

      final cleanup = events.where((e) => e['type'] == 'cleanup').toList();
      expect(cleanup, hasLength(1));
      expect(cleanup.single['removed'], ['__seed', 'blank', 'dead']);
      final done = events.lastWhere((e) => e['type'] == 'done');
      expect(done['cleanup'], cleanup.single['removed'],
          reason: '先行 cleanup 事件与 done.cleanup 必须一致');
    });

    test('删到只剩 1 板即停手（删前复核板数>1）', () async {
      final bridge = _RecordingBridge(
        canonical: '---\nrevision: 1\n---\n# doc', // 无 entry
        boards: [
          {'id': 'a', 'nodes': 1},
          {'id': 'b', 'nodes': 0},
          {'id': 'c', 'nodes': 1},
        ],
      );
      final events = <Map<String, dynamic>>[];
      await runDartAgent(
        request: _buildReq(mbt: '---\nrevision: 1\n---\n# doc'),
        modelOverride: _ScriptedModel([
          [mockToolCall(toolName: 'finish', input: {'summary': 'ok'})],
        ]),
        bridge: bridge,
        onEvent: events.add,
      );
      // 目标 a/b/c 全列，但删掉 a、b 后剩 1 板 → c 之前 break。
      expect(
        bridge.mutateArgs.whereType<String>().where((a) => a.startsWith('delete-artboard ')).toList(),
        ['delete-artboard a', 'delete-artboard b'],
      );
      expect(bridge.boards.map((b) => b['id']).toList(), ['c']);
      final cleanup = events.where((e) => e['type'] == 'cleanup').toList();
      expect(cleanup.single['removed'], ['a', 'b']);
    });
  });

  group('PLAN 语义分歧（Dart 无引擎面 → 零 session 调用）', () {
    test('plan 模式即便传入桥也不清扫、不 RSI、不 generate', () async {
      final bridge = _RecordingBridge(
        canonical: _mbt0,
        boards: [
          {'id': '__seed', 'nodes': 1},
          {'id': 'home', 'nodes': 0},
        ],
        verdicts: {'home': 'poor'},
      );
      final result = await runDartAgent(
        request: _planReq(),
        modelOverride: _ScriptedModel([
          [
            mockToolCall(toolName: 'write_doc', input: {'kind': 'prd', 'content': '# PRD'}),
            mockToolCall(toolName: 'write_doc', input: {'kind': 'ui', 'content': '## UI'}),
            mockToolCall(toolName: 'write_design_spec', input: {
              'palette': {'primary': '#3366FF'},
              'typography': {'h1': 30, 'h2': 22, 'body': 15},
              'spacing': [4, 8, 16],
              'radius': {'sm': 6, 'md': 10, 'lg': 14},
            }),
          ],
          [mockToolCall(toolName: 'finish', input: {'summary': '完成'})],
        ]),
        bridge: bridge,
        onEvent: (_) {},
      );
      expect(result.ok, isTrue);
      expect(bridge.sessionNames, isEmpty, reason: 'plan 的 ctx.bridge 恒 null');
      expect(bridge.mutateNames, isEmpty);
      expect(bridge.generateIntents, isEmpty);
    });
  });
}
